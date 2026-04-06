#!/usr/bin/env bash
set -euo pipefail

# Event classification and routing
# Reads pending_events, classifies by event type + labels + author (deterministic, NO LLM)
# Routes to domain engines as background processes
# Cron: * * * * * (flock protected)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kodo-lib.sh
source "$SCRIPT_DIR/kodo-lib.sh"

kodo_init_db

# Ensure single instance via flock
readonly LOCK_FILE="$KODO_LOCK_DIR/.brain.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    exit 0
fi

# ── Classification Logic (deterministic, no LLM) ────────────

# Extract labels from JSON payload as space-separated lowercase list
_extract_labels() {
    local payload="$1"
    echo "$payload" | jq -r '
        (.labels // []) | if type == "array" then
            [.[] | if type == "object" then .name else . end] | .[]
        else empty end
    ' 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr '\n' ' '
}

# Check if author is an external contributor (not a bot, not org member)
_is_external() {
    local payload="$1"
    local author_type
    author_type=$(echo "$payload" | jq -r '.author.type // .author.is_bot // ""' 2>/dev/null)
    # Bots are not external contributors
    [[ "$author_type" != "Bot" && "$author_type" != "true" ]]
}

# Classify event into domain(s)
# Returns space-separated list: "dev" "mkt" "pm" or combinations
classify_event() {
    local event_type="$1" payload="$2"
    local domains=""
    local labels
    labels="$(_extract_labels "$payload")"

    case "$event_type" in
        PullRequestEvent)
            domains="dev"
            # If from external contributor, also route to mkt for welcome
            if _is_external "$payload"; then
                domains="dev mkt"
            fi
            ;;
        PushEvent)
            domains="dev"
            ;;
        IssuesEvent)
            # Route by labels
            if [[ "$labels" == *"bug"* || "$labels" == *"feature"* || "$labels" == *"enhancement"* ]]; then
                domains="dev"
            fi
            if [[ "$labels" == *"question"* || "$labels" == *"help"* || "$labels" == *"help-wanted"* ]]; then
                domains="${domains:+$domains }mkt"
            fi
            if [[ "$labels" == *"priority"* || "$labels" == *"roadmap"* || "$labels" == *"planning"* ]]; then
                domains="${domains:+$domains }pm"
            fi
            # Default: if no label match, route to dev (most common)
            if [[ -z "$domains" ]]; then
                domains="dev"
            fi
            # External contributor issues also go to mkt
            if _is_external "$payload" && [[ "$domains" != *"mkt"* ]]; then
                domains="$domains mkt"
            fi
            ;;
        IssueCommentEvent)
            if _is_external "$payload"; then
                domains="mkt"
            fi
            # Technical comments also go to dev
            domains="${domains:+$domains }dev"
            ;;
        ReleaseEvent)
            domains="mkt"
            ;;
        ForkEvent|WatchEvent)
            domains="mkt"
            ;;
        DiscussionEvent)
            domains="mkt"
            ;;
        MilestoneEvent)
            domains="pm"
            ;;
        *)
            kodo_log "BRAIN: unknown event type '$event_type' — routing to dev"
            domains="dev"
            ;;
    esac

    echo "$domains"
}

# ── Engine Dispatch ──────────────────────────────────────────

dispatch_engine() {
    local domain="$1" event_id="$2" repo="$3" payload="$4"

    # Find the repo TOML
    local toml="$KODO_HOME/repos/${repo}.toml"
    if [[ ! -f "$toml" ]]; then
        kodo_log "BRAIN: no config for repo '$repo' — skipping"
        return 0
    fi

    # Check if domain engine is enabled
    local engine_script
    case "$domain" in
        dev) engine_script="$SCRIPT_DIR/kodo-dev.sh" ;;
        mkt) engine_script="$SCRIPT_DIR/kodo-mkt.sh" ;;
        pm)  engine_script="$SCRIPT_DIR/kodo-pm.sh" ;;
        *)   return 0 ;;
    esac

    if [[ ! -x "$engine_script" ]]; then
        kodo_log "BRAIN: engine $engine_script not executable — skipping"
        return 0
    fi

    # Create pipeline state (with payload for engines to read)
    export KODO_TRANSITION_REPO="$repo"
    export KODO_TRANSITION_PAYLOAD="$payload"
    "$SCRIPT_DIR/kodo-transition.sh" "$event_id" "*" "pending" "$domain" 2>&1 || true

    # Dispatch engine as background process
    "$engine_script" "$event_id" "$toml" "$domain" >> "$KODO_LOG_DIR/${domain}.log" 2>&1 &
    kodo_log "BRAIN: dispatched $event_id → $domain (pid $!)"
}

# ── Main ─────────────────────────────────────────────────────

main() {
    local processed=0

    # Phase 1: Process new pending events
    local events
    events=$(kodo_sql "SELECT event_id, repo, event_type, payload_json
        FROM pending_events ORDER BY detected_at ASC LIMIT 20;")

    if [[ -n "$events" ]]; then
        while IFS='|' read -r event_id repo event_type payload; do
            [[ -z "$event_id" ]] && continue

            # Check repo is registered
            if [[ ! -f "$KODO_HOME/repos/${repo}.toml" ]]; then
                kodo_log "BRAIN: unregistered repo '$repo' — removing event $event_id"
                kodo_sql "DELETE FROM pending_events WHERE event_id = '$(kodo_sql_escape "$event_id")';"
                continue
            fi

            # Classify
            local domains
            domains="$(classify_event "$event_type" "$payload")"
            kodo_log "BRAIN: $event_id ($event_type) on $repo → [$domains]"

            # Dispatch to each domain
            for domain in $domains; do
                # Check if already in pipeline for this domain
                local existing
                existing=$(kodo_sql "SELECT COUNT(*) FROM pipeline_state
                    WHERE event_id = '$(kodo_sql_escape "$event_id")' AND domain = '$(kodo_sql_escape "$domain")'
                    AND state NOT IN ('resolved', 'closed');")
                if [[ "$existing" -gt 0 ]]; then
                    continue
                fi
                dispatch_engine "$domain" "$event_id" "$repo" "$payload"
            done

            # Remove from pending queue
            kodo_sql "DELETE FROM pending_events WHERE event_id = '$(kodo_sql_escape "$event_id")';"
            processed=$((processed + 1))

        done <<< "$events"
    fi

    # Phase 2: Advance events stuck in intermediate states
    # Re-dispatch engines for events that need further processing
    local stalled
    stalled=$(kodo_sql "SELECT event_id, repo, domain, state FROM pipeline_state
        WHERE state NOT IN ('pending', 'resolved', 'closed', 'published', 'reported', 'deferred')
        AND updated_at < datetime('now', '-5 seconds')
        ORDER BY updated_at ASC LIMIT 15;")

    if [[ -n "$stalled" ]]; then
        while IFS='|' read -r event_id repo domain state; do
            [[ -z "$event_id" ]] && continue

            local toml="$KODO_HOME/repos/${repo}.toml"
            [[ ! -f "$toml" ]] && continue

            local engine_script
            case "$domain" in
                dev) engine_script="$SCRIPT_DIR/kodo-dev.sh" ;;
                mkt) engine_script="$SCRIPT_DIR/kodo-mkt.sh" ;;
                pm)  engine_script="$SCRIPT_DIR/kodo-pm.sh" ;;
                *)   continue ;;
            esac

            [[ ! -x "$engine_script" ]] && continue

            kodo_log "BRAIN: advancing stalled $event_id [$domain] (state: $state)"
            "$engine_script" "$event_id" "$toml" "$domain" >> "$KODO_LOG_DIR/${domain}.log" 2>&1 &

        done <<< "$stalled"
    fi

    kodo_log "BRAIN: processed $processed new events"
}

main "$@"
