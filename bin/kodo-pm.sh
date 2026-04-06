#!/usr/bin/env bash
set -euo pipefail

# Project Management Ops Engine
# Handles: roadmap, backlog triage, velocity reporting, feature evaluation
# Modes: event-driven | --daily-triage | --weekly
# Usage: kodo-pm.sh <event_id> <repo_toml> [domain]
#        kodo-pm.sh --daily-triage
#        kodo-pm.sh --weekly <repo_toml>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kodo-lib.sh
source "$SCRIPT_DIR/kodo-lib.sh"

kodo_init_db

# ── Daily Triage Mode ────────────────────────────────────────

do_daily_triage() {
    kodo_log "PM: starting daily triage"

    for toml in "$KODO_HOME/repos/"*.toml; do
        [[ "$(basename "$toml")" == "_template.toml" ]] && continue
        [[ ! -f "$toml" ]] && continue

        if ! kodo_toml_bool "$toml" "daily_triage"; then
            continue
        fi

        local repo_id repo_slug
        repo_id="$(kodo_repo_id "$toml")"
        repo_slug="$(kodo_repo_slug "$toml")"

        kodo_log "PM: triaging $repo_id"

        # Get open issues
        local issues
        issues=$("$SCRIPT_DIR/kodo-git.sh" issue-list "$toml" 2>/dev/null) || continue

        local issue_count
        issue_count=$(echo "$issues" | jq 'length' 2>/dev/null) || issue_count=0

        if [[ "$issue_count" -eq 0 ]]; then
            kodo_log "PM: no open issues for $repo_id"
            continue
        fi

        # Use Qwen for triage (free tier, high volume)
        if ! kodo_cli_available qwen; then
            # Fallback to gemini
            if ! kodo_cli_available gemini; then
                kodo_log "PM: no triage CLI available for $repo_id — skipping"
                continue
            fi
        fi

        local prompt
        prompt="$(kodo_prompt "Triage these open issues for $repo_slug.
For each issue: suggest priority (P0-P3), suggest labels, flag if duplicate, flag if stale (>30 days no activity).

Issues:
$(echo "$issues" | jq -c '.[] | {number, title, labels: [.labels[]?.name], created: .createdAt, comments: (.comments // 0)}' 2>/dev/null)")"

        local triage_output
        if kodo_cli_available qwen; then
            triage_output=$(timeout 120 qwen -p "$prompt" \
                --json-schema "$KODO_HOME/schemas/triage.schema.json" 2>/dev/null) || triage_output=""
            kodo_log_budget "qwen" "$repo_id" "pm" 0 0 0.0
        else
            triage_output=$(timeout 120 gemini -p "$prompt" \
                --json-schema "$KODO_HOME/schemas/triage.schema.json" 2>/dev/null) || triage_output=""
            kodo_log_budget "gemini" "$repo_id" "pm" 0 0 0.0
        fi

        if [[ -z "$triage_output" ]]; then
            kodo_log "PM: triage failed for $repo_id"
            continue
        fi

        # Apply triage suggestions
        echo "$triage_output" | jq -c '.issues[]' 2>/dev/null | while IFS= read -r suggestion; do
            local issue_num is_stale stale_action
            issue_num=$(echo "$suggestion" | jq -r '.number')
            is_stale=$(echo "$suggestion" | jq -r '.is_stale // false')
            stale_action=$(echo "$suggestion" | jq -r '.stale_action // null')

            # Auto-close stale issues
            if [[ "$is_stale" == "true" && "$stale_action" == "close" ]]; then
                local close_msg="This issue has been automatically flagged as stale (no activity for 30+ days). Closing for housekeeping. Please reopen if still relevant.

_KODO PM triage_"
                "$SCRIPT_DIR/kodo-git.sh" issue-comment "$toml" "$issue_num" "$close_msg" 2>/dev/null || true
                "$SCRIPT_DIR/kodo-git.sh" issue-close "$toml" "$issue_num" 2>/dev/null || true
            fi

            # Apply suggested labels
            local labels
            labels=$(echo "$suggestion" | jq -r '.suggested_labels[]' 2>/dev/null) || true
            for label in $labels; do
                "$SCRIPT_DIR/kodo-git.sh" issue-label "$toml" "$issue_num" "$label" 2>/dev/null || true
            done
        done

        # Store triage artifact
        sqlite3 "$KODO_DB" "INSERT INTO pm_artifacts (repo, type, data_json)
            VALUES ('$(kodo_sql_escape "$repo_id")', 'triage', '$(kodo_sql_escape "$triage_output")');"

        kodo_log "PM: triage complete for $repo_id"
    done

    kodo_log "PM: daily triage finished"
}

# ── Weekly Report Mode ───────────────────────────────────────

do_weekly_report() {
    local toml="$1"
    local repo_id repo_slug
    repo_id="$(kodo_repo_id "$toml")"
    repo_slug="$(kodo_repo_slug "$toml")"

    kodo_log "PM: generating weekly report for $repo_id"

    if ! kodo_toml_bool "$toml" "weekly_report"; then
        return
    fi

    # Gather data
    local issues milestones
    issues=$("$SCRIPT_DIR/kodo-git.sh" issue-list "$toml" 2>/dev/null) || issues="[]"
    milestones=$("$SCRIPT_DIR/kodo-git.sh" milestone-list "$toml" 2>/dev/null) || milestones="[]"

    # Get metrics from DB
    local metrics
    metrics=$(sqlite3 "$KODO_DB" "SELECT merge_count, avg_confidence, avg_time_to_merge, incident_rate_30d
        FROM repo_metrics WHERE repo = '$(kodo_sql_escape "$repo_id")';" 2>/dev/null) || metrics=""

    # Load domain knowledge if exists
    local domain_knowledge=""
    local kodo_md="$KODO_HOME/repos/${repo_id}.kodo.md"
    if [[ -f "$kodo_md" ]]; then
        domain_knowledge=$(head -200 "$kodo_md")
    fi

    if ! kodo_cli_available claude; then
        kodo_log "PM: claude unavailable for weekly report — skipping $repo_id"
        return
    fi

    local prompt
    prompt="$(kodo_prompt "Generate a weekly PM report for $repo_slug.

Open issues: $(echo "$issues" | jq 'length' 2>/dev/null)
Milestones: $milestones
Metrics: $metrics

${domain_knowledge:+Domain context:
$domain_knowledge}

Analyze: velocity trends, priority recommendations, roadmap status, technical debt candidates.")"

    local report
    report=$(timeout 180 claude -p "$prompt" \
        --json-schema "$KODO_HOME/schemas/pm-report.schema.json" \
        --max-turns 3 2>/dev/null) || {
        kodo_log "PM: weekly report generation failed for $repo_id"
        return
    }
    kodo_log_budget "claude" "$repo_id" "pm" 0 0 1.50

    # Post report as GitHub issue
    local report_body
    report_body=$(echo "$report" | jq -r '
        "## Velocity\n- PRs merged: \(.velocity.prs_merged)\n- Issues closed: \(.velocity.issues_closed)\n- Issues opened: \(.velocity.issues_opened)\n- Trend: \(.velocity.trend)\n\n## Priority Recommendations\n" +
        ([.priorities[] | "- **P\(.priority)** #\(.issue_number): \(.title)"] | join("\n")) +
        "\n\n## Roadmap\n" +
        ([.roadmap_status[] | "- \(.milestone): \(.progress_pct)% \(if .at_risk then "⚠️ AT RISK" else "" end)"] | join("\n")) +
        "\n\n---\n_KODO PM Weekly | \(now | strftime("%Y-%m-%d"))_"
    ' 2>/dev/null) || report_body="Report generation error"

    # Store artifact
    sqlite3 "$KODO_DB" "INSERT INTO pm_artifacts (repo, type, data_json)
        VALUES ('$(kodo_sql_escape "$repo_id")', 'weekly', '$(kodo_sql_escape "$report")');"

    # Send Telegram digest if enabled
    if kodo_toml_bool "$toml" "telegram_digest"; then
        local digest="*KODO Weekly — $repo_slug*
$(echo "$report" | jq -r '"PRs: \(.velocity.prs_merged) | Issues: \(.velocity.issues_closed)/\(.velocity.issues_opened) | Trend: \(.velocity.trend)"' 2>/dev/null)"
        kodo_send_telegram "$digest"
    fi

    kodo_log "PM: weekly report complete for $repo_id"
}

# ── Event-Driven Mode ───────────────────────────────────────

do_event() {
    local event_id="$1" toml="$2"
    local repo_id repo_slug
    repo_id="$(kodo_repo_id "$toml")"
    repo_slug="$(kodo_repo_slug "$toml")"

    export KODO_TRANSITION_REPO="$repo_id"

    local state
    state=$(sqlite3 "$KODO_DB" "SELECT state FROM pipeline_state
        WHERE event_id = '$(kodo_sql_escape "$event_id")' AND domain = 'pm';")

    case "$state" in
        pending)
            "$SCRIPT_DIR/kodo-transition.sh" "$event_id" "pending" "analyzing" "pm"

            # Feature evaluation via Claude
            if kodo_cli_available claude; then
                local payload="{}"
                local prompt
                prompt="$(kodo_prompt "Evaluate this event for $repo_slug. Assess feasibility, alignment, effort, and priority.")"

                local result
                result=$(timeout 120 claude -p "$prompt" \
                    --json-schema "$KODO_HOME/schemas/pm-report.schema.json" \
                    --max-turns 2 2>/dev/null) || {
                    "$SCRIPT_DIR/kodo-transition.sh" "$event_id" "analyzing" "deferred" "pm"
                    return
                }
                kodo_log_budget "claude" "$repo_id" "pm" 0 0 1.00

                sqlite3 "$KODO_DB" "INSERT INTO pm_artifacts (repo, type, data_json)
                    VALUES ('$(kodo_sql_escape "$repo_id")', 'evaluation', '$(kodo_sql_escape "$result")');"
            fi

            "$SCRIPT_DIR/kodo-transition.sh" "$event_id" "analyzing" "reported" "pm"
            kodo_log "PM: event $event_id analyzed for $repo_id"
            ;;
        analyzing)
            kodo_log "PM: $event_id still analyzing"
            ;;
        reported)
            kodo_log "PM: $event_id already reported"
            ;;
        deferred)
            kodo_log "PM: $event_id deferred"
            ;;
    esac
}

# ── Main ─────────────────────────────────────────────────────

main() {
    case "${1:-}" in
        --daily-triage)
            do_daily_triage
            ;;
        --weekly)
            local toml="${2:-}"
            if [[ -z "$toml" ]]; then
                # Run for all repos
                for t in "$KODO_HOME/repos/"*.toml; do
                    [[ "$(basename "$t")" == "_template.toml" ]] && continue
                    [[ ! -f "$t" ]] && continue
                    do_weekly_report "$t"
                done
            else
                do_weekly_report "$toml"
            fi
            ;;
        *)
            # Event-driven mode
            local event_id="${1:-}" toml="${2:-}"
            if [[ -n "$event_id" && -n "$toml" ]]; then
                do_event "$event_id" "$toml"
            else
                echo "Usage: kodo-pm.sh --daily-triage | --weekly [repo_toml] | <event_id> <repo_toml>" >&2
                exit 1
            fi
            ;;
    esac
}

main "$@"
