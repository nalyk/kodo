#!/usr/bin/env bash
set -euo pipefail

# kodo-health.sh — THE IMMUTABLE EVALUATOR
#
# This script is the ground-truth health oracle for KODO, consumed by
# kodo-heartbeat.sh. It is INTENTIONALLY read-only:
#
#   - NEVER writes to kodo.db
#   - NEVER appends to any log file
#   - NEVER invokes any LLM CLI
#   - NEVER touches the filesystem outside /tmp
#   - NEVER depends on heartbeat internals (heartbeat cannot edit this file,
#     nor can heartbeat propose PRs that change kodo-health.sh without
#     operator review — this is enforced by heartbeat's mutable-surface whitelist)
#
# Output: exactly one JSON line to stdout matching schemas/health.schema.json.
# Errors: to stderr, plus a synthetic "crash" JSON object on stdout so the
# caller always has something parseable.
#
# Weights in the scoring formula are public and deterministic. If you change
# them, bump the schema "version" field and add a note in HEARTBEAT.md §Evaluator.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kodo-lib.sh
source "$SCRIPT_DIR/kodo-lib.sh"

readonly HEALTH_SCHEMA_VERSION="1"
readonly STUCK_THRESHOLD_SECONDS=600          # 10 minutes
readonly LOOP_WINDOW_SECONDS=60               # count loop events in last 60s
readonly FAST_WINDOW_SECONDS=3600             # 1h window for fast signals
readonly START_TS=$(date +%s)
readonly CAPTURED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Emit a crash JSON and exit. Used on any catastrophic read failure so that
# heartbeat always has something to parse.
emit_crash() {
    local reason="$1"
    local elapsed=$(( $(date +%s) - START_TS ))
    jq -n \
        --arg v "$HEALTH_SCHEMA_VERSION" \
        --arg ts "$CAPTURED_AT" \
        --argjson wc "$elapsed" \
        --arg reason "$reason" \
        '{
            version: $v,
            captured_at: $ts,
            trial_wallclock_s: $wc,
            health_score: 0.0,
            signals: {
                stuck_events_ratio: 1.0,
                loop_rate_per_min: 0.0,
                schema_drift_errors_1h: 0,
                db_lock_errors_1h: 0,
                llm_failure_rate_1h: 1.0,
                deferred_growth_1h: 0,
                successful_resolutions_1h: 0,
                pm_schema_violation_rate: 0.0,
                merge_incident_rate_30d: 0.0
            },
            cohorts: { dev: 0.0, mkt: 0.0, pm: 0.0 },
            counts: {
                pipeline_rows_total: 0,
                pipeline_rows_stuck: 0,
                pipeline_rows_terminal_1h: 0,
                llm_invocations_1h: 0,
                llm_failures_1h: 0,
                pm_log_lines_1h: 0,
                pm_violation_lines_1h: 0
            },
            _crash: $reason
        }'
    exit 0
}

trap 'emit_crash "unexpected shell error line $LINENO"' ERR

# ── DB reads ────────────────────────────────────────────────────────────

# Fail-safe wrapper: if kodo.db doesn't exist or schema is missing columns,
# we emit a crash record rather than propagating failure.
if [[ ! -f "$KODO_DB" ]]; then
    emit_crash "kodo.db does not exist at $KODO_DB"
fi

# Guard against schema drift by checking the columns we need BEFORE running
# the main queries. This is how we detect the "no such column: processing_pid"
# class of errors up front rather than mid-query.
required_columns=$(kodo_sql "PRAGMA table_info(pipeline_state);" 2>/dev/null \
    | awk -F'|' '{print $2}' | tr '\n' ' ') || required_columns=""
for col in event_id domain state processing_pid updated_at metadata_json; do
    if [[ " $required_columns " != *" $col "* ]]; then
        emit_crash "schema drift: pipeline_state missing column '$col'"
    fi
done

# --- Pipeline state counts ---

pipeline_rows_total=$(kodo_sql "
    SELECT COUNT(*) FROM pipeline_state
    WHERE state NOT IN ('resolved','closed','published','reported');
" 2>/dev/null) || pipeline_rows_total=0
pipeline_rows_total="${pipeline_rows_total:-0}"

pipeline_rows_stuck=$(kodo_sql "
    SELECT COUNT(*) FROM pipeline_state
    WHERE state NOT IN ('resolved','closed','published','reported','deferred','monitoring')
      AND updated_at < datetime('now', '-$STUCK_THRESHOLD_SECONDS seconds');
" 2>/dev/null) || pipeline_rows_stuck=0
pipeline_rows_stuck="${pipeline_rows_stuck:-0}"

# Per-domain stuck ratios for cohort scoring
dev_inflight=$(kodo_sql "SELECT COUNT(*) FROM pipeline_state WHERE domain='dev' AND state NOT IN ('resolved','closed','deferred');" 2>/dev/null) || dev_inflight=0
dev_stuck=$(kodo_sql "SELECT COUNT(*) FROM pipeline_state WHERE domain='dev' AND state NOT IN ('resolved','closed','deferred','monitoring') AND updated_at < datetime('now', '-$STUCK_THRESHOLD_SECONDS seconds');" 2>/dev/null) || dev_stuck=0

mkt_inflight=$(kodo_sql "SELECT COUNT(*) FROM pipeline_state WHERE domain='mkt' AND state NOT IN ('published','deferred');" 2>/dev/null) || mkt_inflight=0
mkt_stuck=$(kodo_sql "SELECT COUNT(*) FROM pipeline_state WHERE domain='mkt' AND state NOT IN ('published','deferred') AND updated_at < datetime('now', '-$STUCK_THRESHOLD_SECONDS seconds');" 2>/dev/null) || mkt_stuck=0

pm_inflight=$(kodo_sql "SELECT COUNT(*) FROM pipeline_state WHERE domain='pm' AND state NOT IN ('reported','deferred');" 2>/dev/null) || pm_inflight=0
pm_stuck=$(kodo_sql "SELECT COUNT(*) FROM pipeline_state WHERE domain='pm' AND state NOT IN ('reported','deferred') AND updated_at < datetime('now', '-$STUCK_THRESHOLD_SECONDS seconds');" 2>/dev/null) || pm_stuck=0

# --- Terminal resolutions in last hour ---

pipeline_rows_terminal_1h=$(kodo_sql "
    SELECT COUNT(*) FROM pipeline_state
    WHERE state IN ('resolved','published','reported')
      AND updated_at > datetime('now', '-$FAST_WINDOW_SECONDS seconds');
" 2>/dev/null) || pipeline_rows_terminal_1h=0

# --- Deferred growth in last hour ---

deferred_now=$(kodo_sql "
    SELECT COUNT(*) FROM pipeline_state WHERE state='deferred';
" 2>/dev/null) || deferred_now=0
deferred_1h_ago=$(kodo_sql "
    SELECT COUNT(*) FROM pipeline_state
    WHERE state='deferred'
      AND updated_at < datetime('now', '-$FAST_WINDOW_SECONDS seconds');
" 2>/dev/null) || deferred_1h_ago=0
deferred_growth_1h=$(( deferred_now - deferred_1h_ago ))

# --- LLM invocations via budget_ledger (1h window) ---

llm_invocations_1h=$(kodo_sql "
    SELECT COUNT(*) FROM budget_ledger
    WHERE invoked_at > datetime('now', '-$FAST_WINDOW_SECONDS seconds');
" 2>/dev/null) || llm_invocations_1h=0

# --- Merge incident rate (slow signal, from existing view) ---

merge_incident_rate_30d=$(kodo_sql "
    SELECT COALESCE(
        ROUND(
            CAST(SUM(incident_count) AS REAL) / NULLIF(SUM(total), 0),
            4
        ), 0.0)
    FROM merge_outcome_stats_30d;
" 2>/dev/null) || merge_incident_rate_30d="0.0"
merge_incident_rate_30d="${merge_incident_rate_30d:-0.0}"

# ── Log reads ──────────────────────────────────────────────────────────
#
# Log parsing is windowed: we tail only the last N lines and filter by
# timestamp prefix. This keeps kodo-health.sh O(1) in log size.

LOG_WINDOW_LINES=5000
BRAIN_LOG="$KODO_LOG_DIR/brain.log"
DEV_LOG="$KODO_LOG_DIR/dev.log"
MKT_LOG="$KODO_LOG_DIR/mkt.log"
PM_LOG="$KODO_LOG_DIR/pm.log"

# Timestamp boundaries: "now minus X seconds" formatted as log prefix
ts_1h_ago=$(date -d "@$(( START_TS - FAST_WINDOW_SECONDS ))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -r "$(( START_TS - FAST_WINDOW_SECONDS ))" '+%Y-%m-%d %H:%M:%S')
ts_60s_ago=$(date -d "@$(( START_TS - LOOP_WINDOW_SECONDS ))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -r "$(( START_TS - LOOP_WINDOW_SECONDS ))" '+%Y-%m-%d %H:%M:%S')

# Filter a log file to lines newer than a timestamp cutoff.
# Log prefix format: [YYYY-MM-DD HH:MM:SS]
_log_since() {
    local logfile="$1" cutoff="$2"
    [[ -f "$logfile" ]] || return 0
    tail -n "$LOG_WINDOW_LINES" "$logfile" 2>/dev/null | awk -v cutoff="[$cutoff" '
        {
            if (substr($0,1,1) != "[") next
            if (substr($0,1,20) >= cutoff) print
        }
    '
}

_grep_count() {
    local pattern="$1"
    grep -cE "$pattern" 2>/dev/null || true
}

# --- Loop rate: "stuck after N re-dispatches" in last 60s ---
loop_rate_per_min=0
if [[ -f "$BRAIN_LOG" ]]; then
    loop_rate_per_min=$(_log_since "$BRAIN_LOG" "$ts_60s_ago" \
        | _grep_count "stuck after .* re-dispatches")
    loop_rate_per_min="${loop_rate_per_min:-0}"
fi

# --- Schema drift errors in last hour (all logs) ---
schema_drift_errors_1h=0
for lg in "$BRAIN_LOG" "$DEV_LOG" "$MKT_LOG" "$PM_LOG"; do
    [[ -f "$lg" ]] || continue
    n=$(_log_since "$lg" "$ts_1h_ago" \
        | _grep_count "no such (column|table)")
    schema_drift_errors_1h=$(( schema_drift_errors_1h + n ))
done

# --- DB lock errors in last hour (all logs) ---
db_lock_errors_1h=0
for lg in "$BRAIN_LOG" "$DEV_LOG" "$MKT_LOG" "$PM_LOG"; do
    [[ -f "$lg" ]] || continue
    n=$(_log_since "$lg" "$ts_1h_ago" \
        | _grep_count "database is locked")
    db_lock_errors_1h=$(( db_lock_errors_1h + n ))
done

# --- LLM failures in last hour (all logs) ---
llm_failures_1h=0
for lg in "$BRAIN_LOG" "$DEV_LOG" "$MKT_LOG" "$PM_LOG"; do
    [[ -f "$lg" ]] || continue
    n=$(_log_since "$lg" "$ts_1h_ago" \
        | _grep_count "(claude|codex|gemini|qwen) (invocation failed|code gen failed)")
    llm_failures_1h=$(( llm_failures_1h + n ))
done

# llm_failure_rate denominator prefers budget_ledger (authoritative).
# If budget_ledger is empty but we saw failures in logs, use max(failures, 1)
# to avoid divide-by-zero inflating the rate falsely.
if [[ "$llm_invocations_1h" -gt 0 ]]; then
    llm_failure_rate_1h=$(awk -v f="$llm_failures_1h" -v t="$llm_invocations_1h" \
        'BEGIN { r = f/t; if (r > 1) r = 1; printf "%.4f", r }')
else
    if [[ "$llm_failures_1h" -gt 0 ]]; then
        llm_failure_rate_1h="1.0000"
    else
        llm_failure_rate_1h="0.0000"
    fi
fi

# --- PM schema violation rate (last hour) ---
# A "violation line" is a pm.log line that is NOT a bracketed event log
# AND matches a free-text contamination pattern (bare URL, stray prose).
# The canonical well-formed pm.log line starts with "[YYYY-MM-DD HH:MM:SS]".
pm_log_lines_1h=0
pm_violation_lines_1h=0
if [[ -f "$PM_LOG" ]]; then
    pm_window=$(_log_since "$PM_LOG" "$ts_1h_ago")
    if [[ -n "$pm_window" ]]; then
        pm_log_lines_1h=$(printf '%s\n' "$pm_window" | wc -l | tr -d ' ')
        pm_violation_lines_1h=$(printf '%s\n' "$pm_window" \
            | _grep_count '^[^[]|^\[[^0-9]|^\[[0-9]{0,3}[^0-9]')
    fi
fi
pm_log_lines_1h="${pm_log_lines_1h:-0}"
pm_violation_lines_1h="${pm_violation_lines_1h:-0}"

if [[ "$pm_log_lines_1h" -gt 0 ]]; then
    pm_schema_violation_rate=$(awk -v v="$pm_violation_lines_1h" -v t="$pm_log_lines_1h" \
        'BEGIN { r = v/t; if (r > 1) r = 1; printf "%.4f", r }')
else
    pm_schema_violation_rate="0.0000"
fi

# --- Stuck events ratio ---
if [[ "$pipeline_rows_total" -gt 0 ]]; then
    stuck_events_ratio=$(awk -v s="$pipeline_rows_stuck" -v t="$pipeline_rows_total" \
        'BEGIN { r = s/t; if (r > 1) r = 1; printf "%.4f", r }')
else
    stuck_events_ratio="0.0000"
fi

# ── Scoring ─────────────────────────────────────────────────────────────
#
# Global formula (weights are FIXED and PUBLIC — do not change without
# bumping schema version):
#
#   penalty =
#       0.25 * clamp(stuck_events_ratio, 0, 1)
#     + 0.20 * clamp(loop_rate_per_min / 2.0, 0, 1)
#     + 0.15 * min(1.0, schema_drift_errors_1h / 3.0)
#     + 0.10 * min(1.0, db_lock_errors_1h / 10.0)
#     + 0.15 * clamp(llm_failure_rate_1h, 0, 1)
#     + 0.05 * clamp(max(deferred_growth_1h, 0) / 20.0, 0, 1)
#     + 0.10 * clamp(pm_schema_violation_rate, 0, 1)
#
#   health_score = max(0, 1.0 - penalty)
#
# Weights sum to 1.00. A maximally broken system scores 0, a clean one 1.
# successful_resolutions_1h and merge_incident_rate_30d are observed but
# do not enter the global scalar — the former is a positive signal used
# for cohort scoring, the latter is a slow signal for weekly ratcheting.

health_score=$(awk \
    -v ser="$stuck_events_ratio" \
    -v lrpm="$loop_rate_per_min" \
    -v sde="$schema_drift_errors_1h" \
    -v dbl="$db_lock_errors_1h" \
    -v lfr="$llm_failure_rate_1h" \
    -v dg="$deferred_growth_1h" \
    -v psv="$pm_schema_violation_rate" \
    'function clamp(x, lo, hi) { if (x<lo) return lo; if (x>hi) return hi; return x }
    BEGIN {
        p_stuck   = 0.25 * clamp(ser, 0, 1)
        p_loop    = 0.20 * clamp(lrpm/2.0, 0, 1)
        p_drift   = 0.15 * clamp(sde/3.0, 0, 1)
        p_lock    = 0.10 * clamp(dbl/10.0, 0, 1)
        p_llm     = 0.15 * clamp(lfr, 0, 1)
        p_def     = 0.05 * clamp((dg>0?dg:0)/20.0, 0, 1)
        p_pm      = 0.10 * clamp(psv, 0, 1)
        score = 1.0 - (p_stuck + p_loop + p_drift + p_lock + p_llm + p_def + p_pm)
        if (score < 0) score = 0
        printf "%.4f", score
    }')

# --- Cohort scores (per-domain, simplified: 1 - stuck_ratio - weighted_failures) ---
_cohort_score() {
    local stuck="$1" total="$2"
    awk -v s="$stuck" -v t="$total" \
        'BEGIN {
            if (t <= 0) { printf "1.0000"; exit }
            r = s/t; if (r > 1) r = 1
            printf "%.4f", 1.0 - r
        }'
}

cohort_dev=$(_cohort_score "$dev_stuck" "$dev_inflight")
cohort_mkt=$(_cohort_score "$mkt_stuck" "$mkt_inflight")
# PM cohort: also factor in schema violation rate directly — the PM bug
# you're hunting lives entirely in this cohort.
cohort_pm=$(awk -v s="$pm_stuck" -v t="$pm_inflight" -v psv="$pm_schema_violation_rate" \
    'BEGIN {
        r = (t>0) ? s/t : 0; if (r>1) r=1
        base = 1.0 - r
        adj = base - 0.5 * psv
        if (adj < 0) adj = 0
        printf "%.4f", adj
    }')

# ── Emit ────────────────────────────────────────────────────────────────

trial_wallclock_s=$(( $(date +%s) - START_TS ))

jq -n -c \
    --arg v "$HEALTH_SCHEMA_VERSION" \
    --arg ts "$CAPTURED_AT" \
    --argjson wc "$trial_wallclock_s" \
    --argjson hs "$health_score" \
    --argjson ser "$stuck_events_ratio" \
    --argjson lrpm "$loop_rate_per_min" \
    --argjson sde "$schema_drift_errors_1h" \
    --argjson dbl "$db_lock_errors_1h" \
    --argjson lfr "$llm_failure_rate_1h" \
    --argjson dg "$deferred_growth_1h" \
    --argjson sr "$pipeline_rows_terminal_1h" \
    --argjson psv "$pm_schema_violation_rate" \
    --argjson mir "$merge_incident_rate_30d" \
    --argjson cdev "$cohort_dev" \
    --argjson cmkt "$cohort_mkt" \
    --argjson cpm "$cohort_pm" \
    --argjson prt "$pipeline_rows_total" \
    --argjson prs "$pipeline_rows_stuck" \
    --argjson prt1 "$pipeline_rows_terminal_1h" \
    --argjson li "$llm_invocations_1h" \
    --argjson lf "$llm_failures_1h" \
    --argjson pml "$pm_log_lines_1h" \
    --argjson pmv "$pm_violation_lines_1h" \
    '{
        version: $v,
        captured_at: $ts,
        trial_wallclock_s: $wc,
        health_score: $hs,
        signals: {
            stuck_events_ratio: $ser,
            loop_rate_per_min: $lrpm,
            schema_drift_errors_1h: $sde,
            db_lock_errors_1h: $dbl,
            llm_failure_rate_1h: $lfr,
            deferred_growth_1h: $dg,
            successful_resolutions_1h: $sr,
            pm_schema_violation_rate: $psv,
            merge_incident_rate_30d: $mir
        },
        cohorts: { dev: $cdev, mkt: $cmkt, pm: $cpm },
        counts: {
            pipeline_rows_total: $prt,
            pipeline_rows_stuck: $prs,
            pipeline_rows_terminal_1h: $prt1,
            llm_invocations_1h: $li,
            llm_failures_1h: $lf,
            pm_log_lines_1h: $pml,
            pm_violation_lines_1h: $pmv
        }
    }'
