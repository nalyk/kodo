#!/usr/bin/env bash
set -euo pipefail
# Weekly slow-truth calibration for autoevolve.
# Cron: Sunday 04:00 (flock protected)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kodo-lib.sh
source "$SCRIPT_DIR/kodo-lib.sh"
kodo_init_db
readonly LOCK_FILE="/tmp/autoevolve-calibrate.lock"
readonly AUTOEVOLVE_DIR="$KODO_HOME/autoevolve"
readonly TSV_FILE="$KODO_HOME/autoevolve_calibration.tsv"
readonly AUTO_TOML="$SCRIPT_DIR/../repos/_autoevolve.toml"
readonly BASELINE_FILE="$AUTOEVOLVE_DIR/baseline.json"
readonly FIXTURE_DIR="$SCRIPT_DIR/../test/fixtures/autoevolve-slow-truth"
cal_log() {
    kodo_log "AUTOEVOLVE: calibrate: $*"
}
sql_escape() {
    kodo_sql_escape "$1"
}
send_alert() {
    local msg="$1"
    if declare -F kodo_telegram >/dev/null 2>&1; then
        kodo_telegram "$msg" || true
    elif declare -F kodo_send_telegram >/dev/null 2>&1; then
        kodo_send_telegram "$msg" || true
    else
        local token chat_id
        token="$(kodo_toml_get "$KODO_HOME/telegram.conf" "bot_token" 2>/dev/null || true)"
        chat_id="$(kodo_toml_get "$KODO_HOME/telegram.conf" "chat_id" 2>/dev/null || true)"
        if [[ -n "$token" && -n "$chat_id" ]]; then
            curl -s -o /dev/null -X POST \
                "https://api.telegram.org/bot${token}/sendMessage" \
                -d chat_id="$chat_id" \
                -d text="$msg" \
                -d parse_mode="Markdown" >/dev/null 2>&1 || true
        fi
    fi
}
ensure_tables() {
    sqlite3 -cmd ".timeout 5000" "$KODO_DB" < "$SCRIPT_DIR/../sql/schema-heartbeat-autoevolve.sql"
}
column_exists() {
    local table="$1" column="$2"
    kodo_sql "PRAGMA table_info($table);" | awk -F'|' -v c="$column" '$2 == c { found=1 } END { exit found ? 0 : 1 }'
}
trial_time_expr() {
    if column_exists autoevolve_trials trial_ts; then
        printf 'trial_ts'
    else
        printf 'created_at'
    fi
}
trial_delta_expr() {
    if column_exists autoevolve_trials delta; then
        printf 'delta'
    elif column_exists autoevolve_trials fast_delta; then
        printf 'fast_delta'
    else
        printf '0.0'
    fi
}
trial_description_expr() {
    if column_exists autoevolve_trials description; then
        printf 'description'
    elif column_exists autoevolve_trials plan_json; then
        printf 'plan_json'
    else
        printf "''"
    fi
}
append_tsv() {
    local trial_id="$1" simulated="$2" observed="$3" status="$4"
    if [[ ! -f "$TSV_FILE" ]]; then
        printf 'calibrated_at\ttrial_id\tsimulated_delta\tobserved_delta\tstatus\n' >> "$TSV_FILE"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$trial_id" "$simulated" "$observed" "$status" >> "$TSV_FILE"
}
baseline_json() {
    if [[ -f "$BASELINE_FILE" ]]; then
        cat "$BASELINE_FILE"
    else
        jq -nc '{
            cost_per_resolution_usd: 0.0,
            median_time_to_resolution_s: 0.0
        }'
    fi
}
measure_window() {
    local start="$1" end="$2" baseline bc bt
    baseline="$(baseline_json)"
    bc="$(jq -r '.cost_per_resolution_usd // 0' <<< "$baseline")"
    bt="$(jq -r '.median_time_to_resolution_s // 0' <<< "$baseline")"
    sqlite3 -cmd ".timeout 5000" -json "$KODO_DB" "
        WITH
        events AS (
            SELECT COUNT(DISTINCT event_id) AS total
            FROM pipeline_state
            WHERE created_at > '$start' AND created_at <= '$end'
        ),
        clean AS (
            SELECT COUNT(*) AS n
            FROM pipeline_state
            WHERE state IN ('resolved','published','reported','closed')
              AND retry_count = 0
              AND updated_at > '$start' AND updated_at <= '$end'
        ),
        deferred AS (
            SELECT COUNT(*) AS n
            FROM pipeline_state
            WHERE state='deferred'
              AND updated_at > '$start' AND updated_at <= '$end'
        ),
        incidents AS (
            SELECT COUNT(*) AS n
            FROM merge_outcomes
            WHERE outcome IN ('reverted','hotfixed')
              AND merged_at > '$start' AND merged_at <= '$end'
        ),
        merges AS (
            SELECT COUNT(*) AS n
            FROM merge_outcomes
            WHERE merged_at > '$start' AND merged_at <= '$end'
        ),
        budget AS (
            SELECT COALESCE(SUM(cost_usd), 0.0) AS usd
            FROM budget_ledger
            WHERE invoked_at > '$start' AND invoked_at <= '$end'
        ),
        resolved AS (
            SELECT (julianday(updated_at) - julianday(created_at)) * 86400.0 AS secs
            FROM pipeline_state
            WHERE state IN ('resolved','published','reported')
              AND updated_at > '$start' AND updated_at <= '$end'
            ORDER BY secs
        ),
        med AS (
            SELECT COALESCE(
                (SELECT secs FROM resolved LIMIT 1 OFFSET (SELECT COUNT(*)/2 FROM resolved)),
                0.0
            ) AS secs
        )
        SELECT
            events.total AS events_total,
            clean.n AS clean_resolution,
            deferred.n AS deferred_count,
            incidents.n AS incidents_count,
            budget.usd AS total_budget,
            med.secs AS median_time,
            CASE WHEN events.total > 0 THEN CAST(clean.n AS REAL) / events.total ELSE 0.0 END AS automation_rate,
            CASE WHEN merges.n > 0 THEN CAST(incidents.n AS REAL) / merges.n ELSE 0.0 END AS incident_rate,
            CASE WHEN events.total > 0 THEN CAST(deferred.n + incidents.n AS REAL) / events.total ELSE 0.0 END AS alerts_per_event,
            CASE WHEN clean.n > 0 THEN budget.usd / clean.n ELSE 0.0 END AS cost_per_resolution,
            $bc AS baseline_cost,
            $bt AS baseline_time
        FROM events, clean, deferred, incidents, merges, budget, med;" \
        | jq -c '.[0]'
}
score_window() {
    local m="$1"
    awk \
        -v automation="$(jq -r '.automation_rate // 0' <<< "$m")" \
        -v incident="$(jq -r '.incident_rate // 0' <<< "$m")" \
        -v alerts="$(jq -r '.alerts_per_event // 0' <<< "$m")" \
        -v cost="$(jq -r '.cost_per_resolution // 0' <<< "$m")" \
        -v median="$(jq -r '.median_time // 0' <<< "$m")" \
        -v baseline_cost="$(jq -r '.baseline_cost // 0' <<< "$m")" \
        -v baseline_time="$(jq -r '.baseline_time // 0' <<< "$m")" \
        'BEGIN {
            f_automation = automation
            f_quality = 1.0 - incident
            if (f_quality < 0) f_quality = 0
            f_autonomy = exp(-alerts)
            if (baseline_cost <= 0) f_cost = 1.0
            else {
                if (cost < 0.01) cost = 0.01
                f_cost = baseline_cost / cost
                if (f_cost > 10.0) f_cost = 10.0
            }
            if (baseline_time <= 0) f_speed = 1.0
            else {
                if (median < 1.0) median = 1.0
                f_speed = baseline_time / median
                if (f_speed > 2.0) f_speed = 2.0
            }
            printf "%.4f", f_automation * f_quality * f_autonomy * f_cost * f_speed
        }'
}
record_calibration() {
    local trial_id="$1" simulated="$2" observed="$3" status="$4"
    kodo_sql "INSERT INTO autoevolve_calibration
        (trial_id, simulated_delta, observed_delta, status, calibrated_at)
        VALUES ('$(sql_escape "$trial_id")', $simulated, $observed,
        '$(sql_escape "$status")', datetime('now'));"
    append_tsv "$trial_id" "$simulated" "$observed" "$status"
}
create_failure_fixture() {
    local trial_id="$1" simulated="$2" observed="$3"
    local n dir
    n="$(kodo_sql "SELECT COUNT(*) + 1 FROM autoevolve_calibration WHERE status='revert';" 2>/dev/null || echo 1)"
    dir="$FIXTURE_DIR/$(printf '%03d' "$n")"
    mkdir -p "$dir"
    jq -nc \
        --arg trial_id "$trial_id" \
        --argjson simulated "$simulated" \
        --argjson observed "$observed" \
        '{
            trial_id: $trial_id,
            simulated_delta: $simulated,
            observed_delta: $observed,
            status: "revert",
            captured_at: now | todate
        }' > "$dir/case.json"
}
open_revert_pr() {
    local trial_id="$1" description="$2"
    local merge_sha
    merge_sha="$(jq -r '.merge_sha // .merge_commit_sha // empty' <<< "$description" 2>/dev/null || true)"
    if [[ -n "$merge_sha" && -f "$AUTO_TOML" ]]; then
        "$SCRIPT_DIR/kodo-git.sh" pr-revert "$AUTO_TOML" "$merge_sha" "$trial_id" "autoevolve regression $trial_id" >/dev/null 2>&1
        return $?
    fi
    if [[ -f "$AUTO_TOML" ]]; then
        "$SCRIPT_DIR/kodo-git.sh" issue-create "$AUTO_TOML" \
            "[kodo-autoevolve] revert required for $trial_id" \
            "Slow-truth calibration found a negative observed delta. Merge metadata was unavailable, so operator revert is required." >/dev/null 2>&1 || true
    fi
    return 0
}
proxy_drift_count() {
    kodo_sql "SELECT COUNT(*) FROM (
        SELECT status FROM autoevolve_calibration
        ORDER BY id DESC LIMIT 10
    ) WHERE status='proxy_drift';" 2>/dev/null || echo 0
}
candidate_trials() {
    local ts_col delta_col desc_col
    ts_col="$(trial_time_expr)"
    delta_col="$(trial_delta_expr)"
    desc_col="$(trial_description_expr)"
    kodo_sql "
        SELECT trial_id, $ts_col, $delta_col, $desc_col
        FROM autoevolve_trials
        WHERE status='keep'
          AND datetime($ts_col) <= datetime('now', '-7 days')
          AND trial_id NOT IN (SELECT trial_id FROM autoevolve_calibration)
        ORDER BY datetime($ts_col) ASC;"
}
calibrate_trial() {
    local trial_id="$1" merge_time="$2" simulated="$3" description="$4"
    local pre_start pre_end post_start post_end pre_score post_score observed status
    pre_end="$merge_time"
    pre_start="$(date -d "$merge_time - 7 days" '+%Y-%m-%d %H:%M:%S')"
    post_start="$merge_time"
    post_end="$(date -d "$merge_time + 7 days" '+%Y-%m-%d %H:%M:%S')"
    pre_score="$(score_window "$(measure_window "$pre_start" "$pre_end")")"
    post_score="$(score_window "$(measure_window "$post_start" "$post_end")")"
    observed="$(awk -v post="$post_score" -v pre="$pre_score" 'BEGIN { printf "%.4f", post - pre }')"
    if awk -v d="$observed" 'BEGIN { exit (d < 0) ? 0 : 1 }'; then
        status="revert"
        open_revert_pr "$trial_id" "$description" || true
        create_failure_fixture "$trial_id" "$simulated" "$observed"
        send_alert "autoevolve ${trial_id} regressed in production (simulated ${simulated}, observed ${observed}) - revert opened, new fixture added"
    elif awk -v s="$simulated" -v o="$observed" 'BEGIN { exit (s - o >= 0.04) ? 0 : 1 }'; then
        status="proxy_drift"
    else
        status="confirmed"
    fi
    record_calibration "$trial_id" "$simulated" "$observed" "$status"
    if [[ "$status" == "proxy_drift" && "$(proxy_drift_count)" -ge 3 ]]; then
        send_alert "KODO autoevolve proxy drifting: 3+ calibration misses in the last 10 checks. Add slow-truth fixtures."
    fi
    cal_log "$trial_id status=$status simulated=$simulated observed=$observed"
}
main() {
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        exit 0
    fi
    ensure_tables
    local rows
    rows="$(candidate_trials)"
    [[ -n "$rows" ]] || exit 0
    while IFS='|' read -r trial_id merge_time simulated description; do
        [[ -n "$trial_id" && -n "$merge_time" ]] || continue
        simulated="${simulated:-0}"
        description="${description:-{}}"
        calibrate_trial "$trial_id" "$merge_time" "$simulated" "$description"
    done <<< "$rows"
}
main "$@"
