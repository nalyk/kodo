#!/usr/bin/env bash
set -euo pipefail

# kodo-capability.sh — THE IMMUTABLE EVALUATOR FOR AUTOEVOLVE
#
# Companion to kodo-health.sh. Where health measures "is KODO working right
# now" (log-driven, fast signals), capability measures "is KODO GOOD at its
# job over time" (DB-driven, slow signals, compared against a frozen baseline).
#
# Same discipline as kodo-health.sh:
#   - NEVER writes to kodo.db (except to lazily create a read-only baseline
#     snapshot file on first invocation)
#   - NEVER appends to any log file
#   - NEVER invokes any LLM CLI
#   - NEVER depends on autoevolve internals (autoevolve cannot edit this file)
#
# Output: exactly one JSON line to stdout matching schemas/capability.schema.json.
#
# Modes:
#   --mode observed    (default) — compute 'current' from live kodo.db 7d window
#   --mode simulated   — read 'current' from $KODO_HOME/autoevolve/simulated-current.json
#                        written by kodo-autoevolve.sh after a fixture harness run
#
# Baseline handling:
#   First invocation with no baseline → captures from last 7 days of DB, freezes.
#   Subsequent invocations → read frozen baseline from autoevolve/baseline.json.
#   --recapture-baseline → nuclear option, refuses unless KODO_CONFIRM_BASELINE_RESET=yes.
#
# Formula (fixed and public, reproduced from AUTOEVOLVE.md §Evaluator):
#
#   capability_score = f_automation * f_quality * f_autonomy * f_cost * f_speed
#
#   f_automation = current.automation_rate
#   f_quality    = 1 - current.incident_rate
#   f_autonomy   = exp(-current.alerts_per_event)
#   f_cost       = min(10.0, baseline.cost_per_resolution / max(current.cost_per_resolution, 0.01))
#   f_speed      = min(2.0,  baseline.median_time / max(current.median_time, 1))
#
# At Day 0, f_cost = 1.0, f_speed = 1.0, so capability_score = automation * quality * autonomy.
# A healthy Day-0 KODO with 0.9 automation, 0.02 incidents, 0.1 alerts/event scores ~0.80.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kodo-lib.sh
source "$SCRIPT_DIR/kodo-lib.sh"

readonly CAPABILITY_SCHEMA_VERSION="1"
readonly WINDOW_SECONDS_DEFAULT=$(( 7 * 24 * 3600 ))
readonly AUTOEVOLVE_DIR="$KODO_HOME/autoevolve"
readonly BASELINE_FILE="$AUTOEVOLVE_DIR/baseline.json"
readonly SIMULATED_FILE="$AUTOEVOLVE_DIR/simulated-current.json"
readonly START_TS=$(date +%s)
readonly CAPTURED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

MODE="observed"
RECAPTURE_BASELINE="false"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)              MODE="$2"; shift 2 ;;
        --recapture-baseline) RECAPTURE_BASELINE="true"; shift ;;
        *)                   echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ "$MODE" != "observed" && "$MODE" != "simulated" ]]; then
    echo "invalid --mode: $MODE (must be observed|simulated)" >&2
    exit 2
fi

# ── Crash envelope ──────────────────────────────────────────────────────

emit_crash() {
    local reason="$1"
    local elapsed=$(( $(date +%s) - START_TS ))
    # Even on crash, emit a valid JSON so autoevolve's loop can parse it.
    # capability_score=0 means "regression confirmed" → autoevolve will revert.
    jq -n \
        --arg v "$CAPABILITY_SCHEMA_VERSION" \
        --arg ts "$CAPTURED_AT" \
        --arg mode "$MODE" \
        --argjson wc "$elapsed" \
        --arg reason "$reason" \
        '{
            version: $v,
            captured_at: $ts,
            trial_wallclock_s: $wc,
            capability_score: 0.0,
            mode: $mode,
            baseline: {
                captured_at: "1970-01-01T00:00:00Z",
                automation_rate: 0.0,
                incident_rate: 0.0,
                alerts_per_event: 0.0,
                cost_per_resolution_usd: 0.0,
                median_time_to_resolution_s: 0.0
            },
            current: {
                window_seconds: 0,
                automation_rate: 0.0,
                incident_rate: 0.0,
                alerts_per_event: 0.0,
                cost_per_resolution_usd: 0.0,
                median_time_to_resolution_s: 0.0
            },
            factors: {
                f_automation: 0.0,
                f_quality: 0.0,
                f_autonomy: 0.0,
                f_cost: 0.0,
                f_speed: 0.0
            },
            counts: {
                events_total: 0,
                events_clean_resolution: 0,
                events_deferred: 0,
                events_incidents: 0,
                operator_alerts: 0,
                total_budget_usd: 0.0
            },
            _crash: $reason
        }'
    exit 0
}

trap 'emit_crash "unexpected shell error line $LINENO"' ERR

if [[ ! -f "$KODO_DB" ]]; then
    emit_crash "kodo.db does not exist at $KODO_DB"
fi

# ── Measurement functions (DB-driven, read-only) ────────────────────────
#
# Each function computes one of the five capability factors' inputs from
# kodo.db over a given time window. These are used both for capturing the
# baseline AND for measuring current observed state. Simulated mode bypasses
# these entirely — it reads from SIMULATED_FILE.

# Arg: window_seconds. Echoes a JSON object with all six measurements.
_measure_window() {
    local window="$1"

    local events_total events_clean events_deferred events_incidents
    local operator_alerts total_budget median_time_to_resolution

    # Total events that started pipeline processing in window
    events_total=$(kodo_sql "
        SELECT COUNT(DISTINCT event_id) FROM pipeline_state
        WHERE created_at > datetime('now', '-$window seconds');
    " 2>/dev/null) || events_total=0
    events_total="${events_total:-0}"

    # Clean resolutions: reached terminal state with retry_count = 0
    # (first-try success — a good proxy for "no human intervention needed")
    events_clean=$(kodo_sql "
        SELECT COUNT(*) FROM pipeline_state
        WHERE state IN ('resolved','published','reported','closed')
          AND retry_count = 0
          AND updated_at > datetime('now', '-$window seconds');
    " 2>/dev/null) || events_clean=0
    events_clean="${events_clean:-0}"

    # Deferred events in window (proxies "bothered a human")
    events_deferred=$(kodo_sql "
        SELECT COUNT(*) FROM pipeline_state
        WHERE state = 'deferred'
          AND updated_at > datetime('now', '-$window seconds');
    " 2>/dev/null) || events_deferred=0
    events_deferred="${events_deferred:-0}"

    # Incidents: reverts + hotfixes in window
    events_incidents=$(kodo_sql "
        SELECT COUNT(*) FROM merge_outcomes
        WHERE outcome IN ('reverted', 'hotfixed')
          AND merged_at > datetime('now', '-$window seconds');
    " 2>/dev/null) || events_incidents=0
    events_incidents="${events_incidents:-0}"

    # Operator alerts proxy: deferred + incidents (every deferral or revert
    # corresponds to at least one operator notification in practice)
    operator_alerts=$(( events_deferred + events_incidents ))

    # Total budget in window
    total_budget=$(kodo_sql "
        SELECT COALESCE(ROUND(SUM(cost_usd), 4), 0.0) FROM budget_ledger
        WHERE invoked_at > datetime('now', '-$window seconds');
    " 2>/dev/null) || total_budget="0.0"
    total_budget="${total_budget:-0.0}"

    # Median time-to-resolution for events that reached terminal state in window
    # SQLite has no MEDIAN aggregate, so compute via percentile query
    median_time_to_resolution=$(kodo_sql "
        WITH resolved AS (
            SELECT
                (julianday(updated_at) - julianday(created_at)) * 86400.0 AS secs
            FROM pipeline_state
            WHERE state IN ('resolved','published','reported')
              AND updated_at > datetime('now', '-$window seconds')
            ORDER BY secs
        )
        SELECT COALESCE(
            (SELECT secs FROM resolved LIMIT 1 OFFSET (SELECT COUNT(*)/2 FROM resolved)),
            0.0
        );
    " 2>/dev/null) || median_time_to_resolution="0.0"
    median_time_to_resolution="${median_time_to_resolution:-0.0}"

    # Derived: automation_rate, incident_rate, alerts_per_event, cost_per_resolution
    local automation_rate incident_rate alerts_per_event cost_per_resolution
    automation_rate=$(awk -v c="$events_clean" -v t="$events_total" \
        'BEGIN { if (t>0) printf "%.4f", c/t; else printf "0.0000" }')
    # Incident rate denominator: count of completed merges in window
    # (we want reverted / attempted_merges, not reverted / all_events)
    local merges_total
    merges_total=$(kodo_sql "
        SELECT COUNT(*) FROM merge_outcomes
        WHERE merged_at > datetime('now', '-$window seconds');
    " 2>/dev/null) || merges_total=0
    merges_total="${merges_total:-0}"
    incident_rate=$(awk -v i="$events_incidents" -v t="$merges_total" \
        'BEGIN { if (t>0) printf "%.4f", i/t; else printf "0.0000" }')
    alerts_per_event=$(awk -v a="$operator_alerts" -v t="$events_total" \
        'BEGIN { if (t>0) printf "%.4f", a/t; else printf "0.0000" }')
    cost_per_resolution=$(awk -v b="$total_budget" -v c="$events_clean" \
        'BEGIN { if (c>0) printf "%.4f", b/c; else printf "0.0000" }')

    jq -n -c \
        --argjson ws "$window" \
        --argjson et "$events_total" \
        --argjson ec "$events_clean" \
        --argjson ed "$events_deferred" \
        --argjson ei "$events_incidents" \
        --argjson oa "$operator_alerts" \
        --argjson tb "$total_budget" \
        --argjson ar "$automation_rate" \
        --argjson ir "$incident_rate" \
        --argjson ape "$alerts_per_event" \
        --argjson cpr "$cost_per_resolution" \
        --argjson mttr "$median_time_to_resolution" \
        '{
            window_seconds: $ws,
            events_total: $et,
            events_clean_resolution: $ec,
            events_deferred: $ed,
            events_incidents: $ei,
            operator_alerts: $oa,
            total_budget_usd: $tb,
            automation_rate: $ar,
            incident_rate: $ir,
            alerts_per_event: $ape,
            cost_per_resolution_usd: $cpr,
            median_time_to_resolution_s: $mttr
        }'
}

# ── Baseline handling ──────────────────────────────────────────────────

mkdir -p "$AUTOEVOLVE_DIR"

if [[ "$RECAPTURE_BASELINE" == "true" ]]; then
    if [[ "${KODO_CONFIRM_BASELINE_RESET:-}" != "yes" ]]; then
        emit_crash "--recapture-baseline refused: export KODO_CONFIRM_BASELINE_RESET=yes to confirm"
    fi
    [[ -f "$BASELINE_FILE" ]] && mv "$BASELINE_FILE" "$BASELINE_FILE.$(date +%s).bak"
fi

if [[ ! -f "$BASELINE_FILE" ]]; then
    # First-time capture: freeze current 7-day window as Day 0
    initial_measurement=$(_measure_window "$WINDOW_SECONDS_DEFAULT")
    baseline_json=$(echo "$initial_measurement" | jq -c \
        --arg ts "$CAPTURED_AT" \
        '{
            captured_at: $ts,
            automation_rate: .automation_rate,
            incident_rate: .incident_rate,
            alerts_per_event: .alerts_per_event,
            cost_per_resolution_usd: .cost_per_resolution_usd,
            median_time_to_resolution_s: .median_time_to_resolution_s
        }')
    echo "$baseline_json" > "$BASELINE_FILE.tmp"
    mv "$BASELINE_FILE.tmp" "$BASELINE_FILE"
fi

baseline=$(cat "$BASELINE_FILE")

# ── Current measurement ────────────────────────────────────────────────

if [[ "$MODE" == "simulated" ]]; then
    if [[ ! -f "$SIMULATED_FILE" ]]; then
        emit_crash "simulated mode requested but $SIMULATED_FILE does not exist — run fixture harness first"
    fi
    current=$(cat "$SIMULATED_FILE")
    # Validate it has the required fields
    if ! echo "$current" | jq -e '.window_seconds,.automation_rate,.incident_rate,.alerts_per_event,.cost_per_resolution_usd,.median_time_to_resolution_s' > /dev/null 2>&1; then
        emit_crash "simulated-current.json malformed"
    fi
else
    current=$(_measure_window "$WINDOW_SECONDS_DEFAULT")
fi

# ── Compute factors and capability_score ───────────────────────────────

b_automation=$(echo "$baseline" | jq -r '.automation_rate')
b_incident=$(echo "$baseline" | jq -r '.incident_rate')
b_alerts=$(echo "$baseline" | jq -r '.alerts_per_event')
b_cost=$(echo "$baseline" | jq -r '.cost_per_resolution_usd')
b_time=$(echo "$baseline" | jq -r '.median_time_to_resolution_s')

c_automation=$(echo "$current" | jq -r '.automation_rate')
c_incident=$(echo "$current" | jq -r '.incident_rate')
c_alerts=$(echo "$current" | jq -r '.alerts_per_event')
c_cost=$(echo "$current" | jq -r '.cost_per_resolution_usd')
c_time=$(echo "$current" | jq -r '.median_time_to_resolution_s')

# Factors
read -r f_automation f_quality f_autonomy f_cost f_speed capability_score <<<"$(awk \
    -v ca="$c_automation" -v ci="$c_incident" -v cal="$c_alerts" \
    -v cc="$c_cost" -v ct="$c_time" \
    -v bc="$b_cost" -v bt="$b_time" \
    'BEGIN {
        f_automation = ca
        f_quality    = 1.0 - ci
        if (f_quality < 0) f_quality = 0
        # exp(-x) via series for small x; for correctness use exp() if awk has it
        f_autonomy = exp(-cal)
        # Cost factor: baseline / current, capped at 10×
        if (cc < 0.01) cc = 0.01
        f_cost = bc / cc
        if (f_cost > 10.0) f_cost = 10.0
        if (f_cost < 0.0) f_cost = 0.0
        # At Day 0 baseline, bc == cc so f_cost == 1.0
        # If baseline cost was 0 (no data), default factor to 1.0 to avoid multiplicative zero
        if (bc <= 0.0) f_cost = 1.0
        # Speed factor: baseline / current, capped at 2×
        if (ct < 1.0) ct = 1.0
        f_speed = bt / ct
        if (f_speed > 2.0) f_speed = 2.0
        if (f_speed < 0.0) f_speed = 0.0
        if (bt <= 0.0) f_speed = 1.0
        score = f_automation * f_quality * f_autonomy * f_cost * f_speed
        printf "%.4f %.4f %.4f %.4f %.4f %.4f", f_automation, f_quality, f_autonomy, f_cost, f_speed, score
    }')"

# ── Emit ───────────────────────────────────────────────────────────────

trial_wallclock_s=$(( $(date +%s) - START_TS ))

jq -n -c \
    --arg v "$CAPABILITY_SCHEMA_VERSION" \
    --arg ts "$CAPTURED_AT" \
    --arg mode "$MODE" \
    --argjson wc "$trial_wallclock_s" \
    --argjson cs "$capability_score" \
    --argjson baseline "$baseline" \
    --argjson current "$current" \
    --argjson fa "$f_automation" \
    --argjson fq "$f_quality" \
    --argjson fau "$f_autonomy" \
    --argjson fc "$f_cost" \
    --argjson fs "$f_speed" \
    '{
        version: $v,
        captured_at: $ts,
        trial_wallclock_s: $wc,
        capability_score: $cs,
        mode: $mode,
        baseline: $baseline,
        current: {
            window_seconds: $current.window_seconds,
            automation_rate: $current.automation_rate,
            incident_rate: $current.incident_rate,
            alerts_per_event: $current.alerts_per_event,
            cost_per_resolution_usd: $current.cost_per_resolution_usd,
            median_time_to_resolution_s: $current.median_time_to_resolution_s
        },
        factors: {
            f_automation: $fa,
            f_quality: $fq,
            f_autonomy: $fau,
            f_cost: $fc,
            f_speed: $fs
        },
        counts: {
            events_total: $current.events_total,
            events_clean_resolution: $current.events_clean_resolution,
            events_deferred: $current.events_deferred,
            events_incidents: $current.events_incidents,
            operator_alerts: $current.operator_alerts,
            total_budget_usd: $current.total_budget_usd
        }
    }'
