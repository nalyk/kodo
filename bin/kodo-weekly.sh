#!/usr/bin/env bash
set -euo pipefail

# Weekly self-health check + PM weekly reports + Telegram digest
# Cron: 0 9 * * 1 (Monday 09:00)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kodo-lib.sh
source "$SCRIPT_DIR/kodo-lib.sh"

kodo_init_db

# ── Self-Health Check ────────────────────────────────────────

do_health_check() {
    kodo_log "WEEKLY: starting self-health check"
    local issues=0

    echo "=== KODO Self-Health Check ==="
    echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    # Check CLIs
    echo "--- CLI Availability ---"
    for cli in claude codex gemini qwen; do
        if kodo_cli_available "$cli"; then
            echo "  $cli: OK"
        else
            echo "  $cli: MISSING"
            issues=$((issues + 1))
        fi
    done

    # Check Claude specifically (ping test)
    if kodo_cli_available claude; then
        local ping_result
        ping_result=$(timeout 30 claude -p "respond: pong" --max-turns 1 </dev/null 2>/dev/null) || ping_result=""
        if [[ "$ping_result" == *"pong"* ]]; then
            echo "  claude ping: OK"
        else
            echo "  claude ping: FAILED (may be rate limited)"
            issues=$((issues + 1))
        fi
    fi

    # Check git provider CLIs
    echo ""
    echo "--- Git Providers ---"
    if kodo_cli_available gh; then
        if gh auth status >/dev/null 2>&1; then
            echo "  gh: authenticated"
        else
            echo "  gh: NOT authenticated"
            issues=$((issues + 1))
        fi
    else
        echo "  gh: MISSING"
    fi

    if kodo_cli_available glab; then
        echo "  glab: available"
    fi

    # Check database integrity
    echo ""
    echo "--- Database ---"
    local integrity
    integrity=$(kodo_sql "PRAGMA integrity_check;" 2>/dev/null)
    if [[ "$integrity" == "ok" ]]; then
        echo "  integrity: OK"
    else
        echo "  integrity: FAILED"
        issues=$((issues + 1))
    fi

    # Pipeline stats
    local pending in_progress deferred
    pending=$(kodo_sql "SELECT COUNT(*) FROM pipeline_state WHERE state = 'pending';")
    in_progress=$(kodo_sql "SELECT COUNT(*) FROM pipeline_state WHERE state NOT IN ('pending','resolved','closed','deferred');")
    deferred=$(kodo_sql "SELECT COUNT(*) FROM pipeline_state WHERE state = 'deferred';")
    echo "  pending events: $pending"
    echo "  in-progress: $in_progress"
    echo "  deferred: $deferred"

    # Budget status
    echo ""
    echo "--- Budget (this month) ---"
    local claude_spent codex_spent
    claude_spent=$(kodo_sql "SELECT COALESCE(SUM(cost_usd), 0.0) FROM budget_ledger
        WHERE model = 'claude' AND invoked_at > date('now', 'start of month');")
    codex_spent=$(kodo_sql "SELECT COALESCE(SUM(cost_usd), 0.0) FROM budget_ledger
        WHERE model = 'codex' AND invoked_at > date('now', 'start of month');")
    echo "  claude: \$${claude_spent}/\$200"
    echo "  codex: \$${codex_spent}/\$20"

    # Registered repos
    echo ""
    echo "--- Repos ---"
    local repo_count=0
    for toml in "$KODO_HOME/repos/"*.toml; do
        [[ "$(basename "$toml")" == "_template.toml" ]] && continue
        [[ ! -f "$toml" ]] && continue
        local rid mode
        rid="$(kodo_repo_id "$toml")"
        mode="$(kodo_toml_get "$toml" "mode")"
        echo "  $rid: $mode"
        repo_count=$((repo_count + 1))
    done
    echo "  Total: $repo_count repos"

    # Error rate
    echo ""
    echo "--- Errors (last 7 days) ---"
    local error_count
    error_count=$(kodo_sql "SELECT COUNT(*) FROM deferred_queue
        WHERE queued_at > datetime('now', '-7 days');")
    echo "  deferred events: $error_count"

    echo ""
    if [[ "$issues" -eq 0 ]]; then
        echo "=== Health: ALL CLEAR ==="
    else
        echo "=== Health: $issues ISSUES FOUND ==="
    fi

    # Cap at 125 to avoid exit code wrap (256→0)
    return $(( issues > 125 ? 125 : issues ))
}

# ── Shadow → Live Promotion Check ───────────────────────────

check_shadow_promotion() {
    kodo_log "WEEKLY: checking shadow promotions"

    for toml in "$KODO_HOME/repos/"*.toml; do
        [[ "$(basename "$toml")" == "_template.toml" ]] && continue
        [[ ! -f "$toml" ]] && continue

        if ! kodo_is_shadow "$toml"; then
            continue
        fi

        local repo_id
        repo_id="$(kodo_repo_id "$toml")"

        # Check if shadow has been running long enough
        local event_count
        event_count=$(kodo_sql "SELECT COUNT(*) FROM pipeline_state
            WHERE repo = '$(kodo_sql_escape "$repo_id")';")

        if [[ "$event_count" -lt 10 ]]; then
            kodo_log "WEEKLY: $repo_id shadow needs more events ($event_count/10)"
            continue
        fi

        # Check accuracy (no deferred events from errors)
        local deferred_count
        deferred_count=$(kodo_sql "SELECT COUNT(*) FROM deferred_queue
            WHERE repo = '$(kodo_sql_escape "$repo_id")'
            AND queued_at > datetime('now', '-7 days');")

        local resolved_count
        resolved_count=$(kodo_sql "SELECT COUNT(*) FROM pipeline_state
            WHERE repo = '$(kodo_sql_escape "$repo_id")' AND state IN ('resolved', 'published', 'reported');")

        if [[ "$resolved_count" -gt 0 && "$deferred_count" -lt 3 ]]; then
            kodo_log "WEEKLY: $repo_id ready for live promotion (resolved: $resolved_count, deferred: $deferred_count)"
            # Don't auto-promote — just notify
            kodo_send_telegram "KODO: $repo_id is ready for live mode promotion. Edit repos/${repo_id}.toml to set mode = \"live\"."
        fi
    done
}

# ── PM Weekly Reports ────────────────────────────────────────

run_pm_weekly() {
    kodo_log "WEEKLY: running PM weekly reports"
    "$SCRIPT_DIR/kodo-pm.sh" --weekly
}

# ── Telegram Summary ─────────────────────────────────────────

send_weekly_summary() {
    local health_status="$1"

    local repo_count
    repo_count=$(find "$KODO_HOME/repos/" -name "*.toml" ! -name "_template.toml" 2>/dev/null | wc -l)

    local events_processed
    events_processed=$(kodo_sql "SELECT COUNT(*) FROM pipeline_state
        WHERE updated_at > datetime('now', '-7 days');")

    local claude_spent
    claude_spent=$(kodo_sql "SELECT COALESCE(SUM(cost_usd), 0.0) FROM budget_ledger
        WHERE model = 'claude' AND invoked_at > date('now', 'start of month');")

    local msg
    msg="*KODO Weekly Summary*
Repos: $repo_count | Events: $events_processed (7d)
Budget: \$${claude_spent}/\$200 (claude)
Health: $([ "$health_status" -eq 0 ] && echo "ALL CLEAR" || echo "$health_status issues")"

    kodo_send_telegram "$msg"
}

# ── Confidence Band Calibration ─────────────────────────────

calibrate_confidence_bands() {
    kodo_log "CALIBRATION: starting confidence band calibration"

    # Read current thresholds
    local auto_merge_threshold ballot_threshold
    auto_merge_threshold=$(kodo_sql "SELECT threshold FROM confidence_bands WHERE band = 'auto_merge';")
    ballot_threshold=$(kodo_sql "SELECT threshold FROM confidence_bands WHERE band = 'ballot';")

    # Fallback to defaults if missing
    auto_merge_threshold="${auto_merge_threshold:-90}"
    ballot_threshold="${ballot_threshold:-50}"

    # Validate thresholds are integers
    if ! [[ "$auto_merge_threshold" =~ ^[0-9]+$ ]] || ! [[ "$ballot_threshold" =~ ^[0-9]+$ ]]; then
        kodo_log "CALIBRATION: invalid thresholds (auto_merge=${auto_merge_threshold}, ballot=${ballot_threshold}), aborting"
        return 1
    fi

    # Query 30-day outcomes bucketed by current thresholds
    local high_total high_incidents med_total med_incidents
    high_total=$(kodo_sql "SELECT COUNT(*) FROM merge_outcomes
        WHERE merged_at > datetime('now', '-30 days')
        AND confidence >= ${auto_merge_threshold};")
    high_incidents=$(kodo_sql "SELECT COUNT(*) FROM merge_outcomes
        WHERE merged_at > datetime('now', '-30 days')
        AND confidence >= ${auto_merge_threshold}
        AND outcome IN ('reverted', 'hotfixed');")
    med_total=$(kodo_sql "SELECT COUNT(*) FROM merge_outcomes
        WHERE merged_at > datetime('now', '-30 days')
        AND confidence >= ${ballot_threshold}
        AND confidence < ${auto_merge_threshold};")
    med_incidents=$(kodo_sql "SELECT COUNT(*) FROM merge_outcomes
        WHERE merged_at > datetime('now', '-30 days')
        AND confidence >= ${ballot_threshold}
        AND confidence < ${auto_merge_threshold}
        AND outcome IN ('reverted', 'hotfixed');")

    local changes_made=0

    # --- High band: target ≤ 2%, range [85, 95] ---
    _calibrate_band "auto_merge" "$auto_merge_threshold" "$high_total" "$high_incidents" \
        0.02 85 95 && changes_made=1

    # --- Medium band: target ≤ 10%, range [40, 60] ---
    _calibrate_band "ballot" "$ballot_threshold" "$med_total" "$med_incidents" \
        0.10 40 60 && changes_made=1

    if [[ "$changes_made" -eq 0 ]]; then
        kodo_log "CALIBRATION: no threshold changes this cycle"
    fi

    kodo_log "CALIBRATION: complete"
}

# Calibrate a single band. Returns 0 if threshold changed, 1 otherwise.
# Usage: _calibrate_band <band> <threshold> <total> <incidents> <target_rate> <min> <max>
_calibrate_band() {
    local band="$1" threshold="$2" total="$3" incidents="$4"
    local target_rate="$5" bound_min="$6" bound_max="$7"

    if [[ "$total" -lt 20 ]]; then
        kodo_log "CALIBRATION: ${band} band insufficient data (n=${total}), skipping"
        return 1
    fi

    local rate pct
    rate=$(awk "BEGIN { printf \"%.4f\", ${incidents} / ${total} }")
    pct=$(awk "BEGIN { printf \"%.1f\", ${incidents} * 100.0 / ${total} }")
    local target_pct
    target_pct=$(awk "BEGIN { printf \"%.0f\", ${target_rate} * 100 }")
    local half_target
    half_target=$(awk "BEGIN { printf \"%.4f\", ${target_rate} / 2 }")
    local half_pct
    half_pct=$(awk "BEGIN { printf \"%.0f\", ${target_rate} * 50 }")

    local new_threshold="$threshold"

    # Rate exceeds target → raise threshold by 2
    if awk "BEGIN { exit (${rate} > ${target_rate}) ? 0 : 1 }" 2>/dev/null; then
        new_threshold=$(( threshold + 2 ))
        [[ "$new_threshold" -gt "$bound_max" ]] && new_threshold="$bound_max"
        if [[ "$new_threshold" -ne "$threshold" ]]; then
            kodo_log "CALIBRATION: ${band} band incident rate ${pct}% > ${target_pct}%, raising threshold ${threshold} → ${new_threshold}"
            kodo_send_telegram "KŌDŌ Calibration: ${band} band incident rate ${pct}% > ${target_pct}% target. Threshold ${threshold} → ${new_threshold} (n=${total})"
            kodo_sql "INSERT INTO calibration_history (band, old_threshold, new_threshold, incident_rate, sample_size, reason)
                VALUES ('$(kodo_sql_escape "$band")', ${threshold}, ${new_threshold}, ${rate}, ${total},
                'incident rate ${pct}% exceeds ${target_pct}% target');"
            kodo_sql "UPDATE confidence_bands SET threshold = ${new_threshold}, incident_rate_30d = ${rate}, updated_at = datetime('now')
                WHERE band = '$(kodo_sql_escape "$band")';"
            return 0
        else
            kodo_log "CALIBRATION: ${band} band incident rate ${pct}% > ${target_pct}% but threshold already at bound (${threshold})"
        fi
    # Rate below half target → lower threshold by 1
    elif awk "BEGIN { exit (${rate} < ${half_target}) ? 0 : 1 }" 2>/dev/null; then
        if [[ "$threshold" -gt "$bound_min" ]]; then
            new_threshold=$(( threshold - 1 ))
            [[ "$new_threshold" -lt "$bound_min" ]] && new_threshold="$bound_min"
            kodo_log "CALIBRATION: ${band} band incident rate ${pct}% < ${half_pct}%, lowering threshold ${threshold} → ${new_threshold}"
            kodo_sql "INSERT INTO calibration_history (band, old_threshold, new_threshold, incident_rate, sample_size, reason)
                VALUES ('$(kodo_sql_escape "$band")', ${threshold}, ${new_threshold}, ${rate}, ${total},
                'incident rate ${pct}% below ${half_pct}% floor');"
            kodo_sql "UPDATE confidence_bands SET threshold = ${new_threshold}, incident_rate_30d = ${rate}, updated_at = datetime('now')
                WHERE band = '$(kodo_sql_escape "$band")';"
            return 0
        else
            kodo_log "CALIBRATION: ${band} band incident rate ${pct}% < ${half_pct}% but threshold already at bound (${threshold})"
        fi
    else
        kodo_log "CALIBRATION: ${band} band incident rate ${pct}% within target (n=${total}), no change"
    fi

    # No change — still update the observed rate
    kodo_sql "UPDATE confidence_bands SET incident_rate_30d = ${rate}, updated_at = datetime('now')
        WHERE band = '$(kodo_sql_escape "$band")';"
    return 1
}

# ── Main ─────────────────────────────────────────────────────

main() {
    # Support isolated calibration for testing
    if [[ "${1:-}" == "--calibrate-only" ]]; then
        calibrate_confidence_bands
        return
    fi

    kodo_log "WEEKLY: starting weekly cycle"

    # 1. Self-health check
    local health_status=0
    do_health_check || health_status=$?

    # 2. Shadow promotion checks
    check_shadow_promotion

    # 3. PM weekly reports
    run_pm_weekly

    # 4. Calibrate confidence bands from merge outcome data
    calibrate_confidence_bands

    # 5. Weekly summary to Telegram
    send_weekly_summary "$health_status"

    kodo_log "WEEKLY: cycle complete"
}

main "$@"
