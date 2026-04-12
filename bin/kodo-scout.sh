#!/usr/bin/env bash
set -euo pipefail

# Event detection across all registered repos
# Polls GitHub/GitLab APIs via kodo-git.sh, dedup-inserts into pending_events
# Cron: */2 * * * *

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kodo-lib.sh
source "$SCRIPT_DIR/kodo-lib.sh"

kodo_init_db

# ── Event Detection ──────────────────────────────────────────

# Generate deterministic event ID from type + repo + unique key
_event_key() {
    local repo="$1" event_type="$2" unique="$3"
    echo "evt-${repo}-${event_type}-${unique}" | tr '/' '-'
}

# Check if event already exists in pending_events or pipeline_state
# Uses a single SELECT to avoid multi-row parsing fragility
_event_exists() {
    local event_id="$1"
    local eid
    eid="$(kodo_sql_escape "$event_id")"
    local count
    count=$(kodo_sql "SELECT
        (SELECT COUNT(*) FROM pending_events WHERE event_id = '${eid}')
      + (SELECT COUNT(*) FROM pipeline_state WHERE event_id = '${eid}');" 2>/dev/null) || count=1
    # Default to "exists" on DB error — safer than re-inserting duplicates
    [[ "${count:-1}" -gt 0 ]]
}

# Insert a new pending event (OR IGNORE prevents crash on race-condition duplicates)
_insert_event() {
    local event_id="$1" repo="$2" event_type="$3" payload="$4"
    kodo_sql "INSERT OR IGNORE INTO pending_events (event_id, repo, event_type, payload_json)
        VALUES ('$(kodo_sql_escape "$event_id")', '$(kodo_sql_escape "$repo")', '$(kodo_sql_escape "$event_type")', '$(kodo_sql_escape "$payload")');"
    kodo_log "SCOUT: detected $event_type on $repo → $event_id"
}

# ── Scan Functions ───────────────────────────────────────────

scan_pull_requests() {
    local toml="$1" repo_id="$2"
    local prs
    prs=$("$SCRIPT_DIR/kodo-git.sh" pr-list "$toml" 2>/dev/null) || { kodo_log "SCOUT: pr-list failed for $repo_id"; return 0; }

    echo "$prs" | jq -c '.[]' 2>/dev/null | while IFS= read -r pr; do
        local pr_num pr_state updated_at
        pr_num=$(echo "$pr" | jq -r '.number')
        pr_state=$(echo "$pr" | jq -r '.state // "OPEN"' | tr '[:upper:]' '[:lower:]')
        updated_at=$(echo "$pr" | jq -r '.updatedAt // .updated_at // .createdAt // .created_at // ""' 2>/dev/null)

        [[ "$pr_state" != "open" ]] && continue

        # Skip PRs created by KODO (kodo/ branch prefix) — already tracked as IssuesEvents
        local head_branch
        head_branch=$(echo "$pr" | jq -r '.headRefName // ""' 2>/dev/null)
        [[ "$head_branch" == kodo/* ]] && continue

        local event_id
        event_id="$(_event_key "$repo_id" "PullRequestEvent" "${pr_num}-${updated_at}")"

        if ! _event_exists "$event_id"; then
            _insert_event "$event_id" "$repo_id" "PullRequestEvent" "$pr"
        fi
    done
}

scan_issues() {
    local toml="$1" repo_id="$2"
    local issues
    issues=$("$SCRIPT_DIR/kodo-git.sh" issue-list "$toml" 2>/dev/null) || { kodo_log "SCOUT: issue-list failed for $repo_id"; return 0; }

    echo "$issues" | jq -c '.[]' 2>/dev/null | while IFS= read -r issue; do
        local issue_num issue_state updated_at
        issue_num=$(echo "$issue" | jq -r '.number')
        issue_state=$(echo "$issue" | jq -r '.state // "OPEN"' | tr '[:upper:]' '[:lower:]')
        updated_at=$(echo "$issue" | jq -r '.updatedAt // .updated_at // .createdAt // .created_at // ""' 2>/dev/null)

        [[ "$issue_state" != "open" ]] && continue

        local event_id
        event_id="$(_event_key "$repo_id" "IssuesEvent" "${issue_num}-${updated_at}")"

        if ! _event_exists "$event_id"; then
            _insert_event "$event_id" "$repo_id" "IssuesEvent" "$issue"
        fi

        local comments
        comments=$("$SCRIPT_DIR/kodo-git.sh" issue-comments "$toml" "$issue_num" 2>/dev/null) || comments="[]"
        echo "$comments" | jq -c '.[]' 2>/dev/null | while IFS= read -r comment; do
            local comment_id comment_updated comment_event_id comment_payload
            comment_id=$(echo "$comment" | jq -r '.id // empty' 2>/dev/null)
            comment_updated=$(echo "$comment" | jq -r '.updatedAt // .updated_at // .createdAt // .created_at // ""' 2>/dev/null)
            [[ -z "$comment_id" ]] && continue
            comment_event_id="$(_event_key "$repo_id" "IssueCommentEvent" "${issue_num}-${comment_id}-${comment_updated}")"
            if ! _event_exists "$comment_event_id"; then
                comment_payload=$(jq -nc --argjson issue "$issue" --argjson comment "$comment" '
                    $comment + {
                        issue_number: $issue.number,
                        title: $issue.title,
                        labels: ($issue.labels // []),
                        number: $issue.number
                    }')
                _insert_event "$comment_event_id" "$repo_id" "IssueCommentEvent" "$comment_payload"
            fi
        done
    done
}

scan_provider_events() {
    local toml="$1" repo_id="$2"
    local events
    events=$("$SCRIPT_DIR/kodo-git.sh" event-list "$toml" 2>/dev/null) || return 0

    echo "$events" | jq -c '.[]' 2>/dev/null | while IFS= read -r event; do
        local provider_id event_type created_at event_id payload
        provider_id=$(echo "$event" | jq -r '.id // empty' 2>/dev/null)
        event_type=$(echo "$event" | jq -r '.type // empty' 2>/dev/null)
        created_at=$(echo "$event" | jq -r '.created_at // .createdAt // ""' 2>/dev/null)
        [[ -z "$provider_id" || -z "$event_type" ]] && continue

        case "$event_type" in
            PushEvent|ForkEvent|WatchEvent|DiscussionEvent) ;;
            *) continue ;;
        esac

        event_id="$(_event_key "$repo_id" "$event_type" "${provider_id}-${created_at}")"
        if ! _event_exists "$event_id"; then
            payload=$(echo "$event" | jq -c '.payload + {author: .actor, provider_event_id: .id}' 2>/dev/null)
            [[ -z "$payload" || "$payload" == "null" ]] && payload="$event"
            _insert_event "$event_id" "$repo_id" "$event_type" "$payload"
        fi
    done
}

scan_releases() {
    local toml="$1" repo_id="$2"
    local releases
    releases=$("$SCRIPT_DIR/kodo-git.sh" release-list "$toml" 2>/dev/null) || { kodo_log "SCOUT: release-list failed for $repo_id"; return 0; }

    echo "$releases" | jq -c '.[]' 2>/dev/null | head -5 | while IFS= read -r rel; do
        local tag
        tag=$(echo "$rel" | jq -r '.tagName')

        local event_id
        event_id="$(_event_key "$repo_id" "ReleaseEvent" "$tag")"

        if ! _event_exists "$event_id"; then
            _insert_event "$event_id" "$repo_id" "ReleaseEvent" "$rel"
        fi
    done
}

scan_milestones() {
    local toml="$1" repo_id="$2"
    local milestones
    milestones=$("$SCRIPT_DIR/kodo-git.sh" milestone-list "$toml" 2>/dev/null) || { kodo_log "SCOUT: milestone-list failed for $repo_id"; return 0; }
    [[ -z "$milestones" ]] && return 0

    echo "$milestones" | jq -c 'if type == "array" then .[] else . end' 2>/dev/null | while IFS= read -r ms; do
        local ms_num
        ms_num=$(echo "$ms" | jq -r '.number')

        [[ -z "$ms_num" || "$ms_num" == "null" ]] && continue

        local event_id
        event_id="$(_event_key "$repo_id" "MilestoneEvent" "$ms_num")"

        if ! _event_exists "$event_id"; then
            _insert_event "$event_id" "$repo_id" "MilestoneEvent" "$ms"
        fi
    done
}

# ── Main ─────────────────────────────────────────────────────

main() {
    kodo_log "SCOUT: starting scan cycle"

    local toml_count=0

    for toml in "$KODO_HOME/repos/"*.toml; do
        [[ "$(basename "$toml")" == "_template.toml" ]] && continue
        [[ "$(basename "$toml")" == _*.toml ]] && continue
        [[ ! -f "$toml" ]] && continue

        local repo_id
        repo_id="$(kodo_repo_id "$toml")"
        toml_count=$((toml_count + 1))

        # Skip disabled repos (check [repo].enabled, not [dev].enabled)
        if ! kodo_toml_bool "$toml" "repo" "enabled" 2>/dev/null; then
            kodo_log "SCOUT: $repo_id disabled — skipping"
            continue
        fi

        scan_pull_requests "$toml" "$repo_id"
        scan_issues "$toml" "$repo_id"
        scan_releases "$toml" "$repo_id"
        scan_milestones "$toml" "$repo_id"
        scan_provider_events "$toml" "$repo_id"
    done

    local new_events
    new_events=$(kodo_sql "SELECT COUNT(*) FROM pending_events
        WHERE detected_at > datetime('now', '-3 minutes');")

    kodo_log "SCOUT: scanned $toml_count repos, $new_events new events"
}

main "$@"
