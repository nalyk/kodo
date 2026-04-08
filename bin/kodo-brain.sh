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
            # Only route technical comments to dev (keyword heuristic)
            local comment_body
            comment_body=$(echo "$payload" | jq -r '.body // ""' 2>/dev/null | tr '[:upper:]' '[:lower:]')
            if echo "$comment_body" | grep -qiE "bug|fix|error|crash|stack.?trace|regression|patch|PR|pull.?request|commit|branch|merge|test|lint|CI|build|fail|broken|null|undefined|exception|segfault|panic|deadlock"; then
                domains="${domains:+$domains }dev"
            fi
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
    if ! "$SCRIPT_DIR/kodo-transition.sh" "$event_id" "*" "pending" "$domain" >> "$KODO_LOG_DIR/${domain}.log" 2>&1; then
        kodo_log "BRAIN: FAILED to create pipeline state for $event_id [$domain] — event stays in pending"
        return 1
    fi

    # Dispatch engine as background process
    "$engine_script" "$event_id" "$toml" "$domain" >> "$KODO_LOG_DIR/${domain}.log" 2>&1 &
    kodo_log "BRAIN: dispatched $event_id → $domain (pid $!)"
}

# ── Main ─────────────────────────────────────────────────────

main() {
    local processed=0

    # Throttle: max 3 concurrent engine processes across all phases
    # Use local counter to avoid race condition (background PIDs not yet in DB)
    local max_concurrent=3
    local active_count
    active_count=$(kodo_sql "SELECT COUNT(*) FROM pipeline_state
        WHERE processing_pid IS NOT NULL AND processing_pid > 0
        AND state NOT IN ('resolved', 'closed', 'published', 'reported', 'deferred');")
    active_count="${active_count:-0}"

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
            local dispatch_ok=true
            for domain in $domains; do
                # Check if already in pipeline for this domain (any state = skip)
                local existing
                existing=$(kodo_sql "SELECT COUNT(*) FROM pipeline_state
                    WHERE event_id = '$(kodo_sql_escape "$event_id")' AND domain = '$(kodo_sql_escape "$domain")';")
                if [[ "$existing" -gt 0 ]]; then
                    continue
                fi
                # Throttle: skip if too many engines running
                if [[ "$active_count" -ge "$max_concurrent" ]]; then
                    kodo_log "BRAIN: throttled — $active_count engines running (max $max_concurrent)"
                    dispatch_ok=false
                    break 2
                fi
                dispatch_engine "$domain" "$event_id" "$repo" "$payload" && active_count=$((active_count + 1)) || dispatch_ok=false
            done

            # Only remove from pending if all dispatches succeeded
            if [[ "$dispatch_ok" == "true" ]]; then
                kodo_sql "DELETE FROM pending_events WHERE event_id = '$(kodo_sql_escape "$event_id")';"
                processed=$((processed + 1))
            else
                kodo_log "BRAIN: keeping $event_id in pending — dispatch failed for some domains"
            fi

        done <<< "$events"
    fi

    # Phase 2a: Reap stale PIDs — dead processes leave events orphaned
    # Check processing_pid for events stuck > 60s with a non-null PID
    local stale_pids
    stale_pids=$(kodo_sql "SELECT event_id, domain, processing_pid FROM pipeline_state
        WHERE state NOT IN ('resolved', 'closed', 'published', 'reported')
        AND processing_pid IS NOT NULL AND processing_pid > 0
        AND updated_at < datetime('now', '-60 seconds')
        ORDER BY updated_at ASC LIMIT 20;")

    if [[ -n "$stale_pids" ]]; then
        while IFS='|' read -r event_id domain pid; do
            [[ -z "$event_id" || -z "$pid" ]] && continue
            if ! kill -0 "$pid" 2>/dev/null; then
                kodo_log "BRAIN: reaping dead PID $pid for $event_id [$domain]"
                kodo_sql "UPDATE pipeline_state SET processing_pid = NULL, updated_at = datetime('now')
                    WHERE event_id = '$(kodo_sql_escape "$event_id")' AND domain = '$(kodo_sql_escape "$domain")'
                    AND processing_pid = '$(kodo_sql_escape "$pid")';"
            fi
        done <<< "$stale_pids"
    fi

    # Phase 2b: Advance events stuck in intermediate states
    # Re-dispatch engines for events that need further processing
    # Monitoring events use a slower 900s cadence to avoid GitHub API rate-limit pressure
    local stalled
    stalled=$(kodo_sql "SELECT event_id, repo, domain, state FROM pipeline_state
        WHERE state NOT IN ('resolved', 'closed', 'published', 'reported', 'deferred', 'monitoring')
        AND (processing_pid IS NULL OR processing_pid = 0)
        AND updated_at < datetime('now', '-300 seconds')
        ORDER BY updated_at ASC LIMIT 15;")

    # Monitoring events: 15-minute re-dispatch cadence
    local monitoring_stalled
    monitoring_stalled=$(kodo_sql "SELECT event_id, repo, domain, state FROM pipeline_state
        WHERE state = 'monitoring'
        AND (processing_pid IS NULL OR processing_pid = 0)
        AND updated_at < datetime('now', '-900 seconds')
        ORDER BY updated_at ASC LIMIT 5;")
    if [[ -n "$monitoring_stalled" ]]; then
        if [[ -n "$stalled" ]]; then
            stalled="${stalled}
${monitoring_stalled}"
        else
            stalled="$monitoring_stalled"
        fi
    fi

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

            # Throttle check
            if [[ "$active_count" -ge "$max_concurrent" ]]; then
                kodo_log "BRAIN: throttled stall recovery — $active_count engines running"
                break
            fi

            # Max re-dispatch guard: defer after 10 failed re-dispatches
            local redispatch_count
            redispatch_count=$(kodo_sql "SELECT COALESCE(json_extract(metadata_json, '\$.redispatch_count'), 0)
                FROM pipeline_state WHERE event_id = '$(kodo_sql_escape "$event_id")' AND domain = '$(kodo_sql_escape "$domain")';")
            redispatch_count="${redispatch_count:-0}"
            if [[ "$redispatch_count" -ge 10 ]]; then
                kodo_log "BRAIN: $event_id [$domain] stuck after $redispatch_count re-dispatches — deferring"
                "$SCRIPT_DIR/kodo-transition.sh" "$event_id" "$state" "deferred" "$domain" 2>/dev/null || true
                continue
            fi

            kodo_log "BRAIN: advancing stalled $event_id [$domain] (state: $state, redispatch: $redispatch_count)"
            kodo_sql "UPDATE pipeline_state SET metadata_json = json_set(COALESCE(metadata_json, '{}'), '\$.redispatch_count', $((redispatch_count + 1)))
                WHERE event_id = '$(kodo_sql_escape "$event_id")' AND domain = '$(kodo_sql_escape "$domain")';"
            "$engine_script" "$event_id" "$toml" "$domain" >> "$KODO_LOG_DIR/${domain}.log" 2>&1 &
            active_count=$((active_count + 1))

        done <<< "$stalled"
    fi

    # Phase 3: Retry deferred events (deferred → pending, max 2 retries)
    # Events deferred due to transient failures (CI pending, CLI timeout, rate limits)
    # get a second chance. Permanent failures (max retries) auto-close.
    local deferred
    deferred=$(kodo_sql "SELECT event_id, repo, domain, retry_count FROM pipeline_state
        WHERE state = 'deferred'
        AND (processing_pid IS NULL OR processing_pid = 0)
        AND updated_at < datetime('now', '-5 minutes')
        ORDER BY updated_at ASC LIMIT 5;")

    if [[ -n "$deferred" ]]; then
        while IFS='|' read -r event_id repo domain retry_count; do
            [[ -z "$event_id" ]] && continue

            local toml="$KODO_HOME/repos/${repo}.toml"
            [[ ! -f "$toml" ]] && continue

            export KODO_TRANSITION_REPO="$repo"

            if [[ "$retry_count" -ge 2 ]]; then
                # Max retries exhausted — auto-close
                kodo_log "BRAIN: $event_id [$domain] max retries ($retry_count) — closing"
                "$SCRIPT_DIR/kodo-transition.sh" "$event_id" "deferred" "closed" "$domain" 2>&1 || true
            else
                # Retry: deferred → pending (transition increments retry_count)
                kodo_log "BRAIN: retrying $event_id [$domain] (attempt $((retry_count + 1))/2)"
                "$SCRIPT_DIR/kodo-transition.sh" "$event_id" "deferred" "pending" "$domain" 2>&1 || true

                # Re-dispatch engine for the now-pending event
                local engine_script
                case "$domain" in
                    dev) engine_script="$SCRIPT_DIR/kodo-dev.sh" ;;
                    mkt) engine_script="$SCRIPT_DIR/kodo-mkt.sh" ;;
                    pm)  engine_script="$SCRIPT_DIR/kodo-pm.sh" ;;
                    *)   continue ;;
                esac
                if [[ -x "$engine_script" ]]; then
                    "$engine_script" "$event_id" "$toml" "$domain" >> "$KODO_LOG_DIR/${domain}.log" 2>&1 &
                fi
            fi

        done <<< "$deferred"
    fi

    kodo_log "BRAIN: processed $processed new events"
}

main "$@"
