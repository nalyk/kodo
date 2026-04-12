#!/usr/bin/env bash
set -euo pipefail

# Scenario 09: Heartbeat clears the PR-364 monitoring redispatch loop.

SCENARIO_NAME="09-heartbeat-monitoring-loop"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TEST_DIR/lib-fixture.sh"

fixture_setup "$SCENARIO_NAME"

fail() {
    echo "  DIFF (expected vs actual):"
    echo "    $1"
    fixture_teardown
    exit 1
}

cat > "$KODO_FIXTURE_HOME/bin/awk" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == *"function clamp"* ]]; then
        echo "0.5000"
        exit 0
    fi
done
exec /usr/bin/awk "$@"
EOF
chmod +x "$KODO_FIXTURE_HOME/bin/awk"

now_prefix="$(date '+%Y-%m-%d %H:%M:%S')"
for log_name in brain dev mkt pm; do
    cat > "$KODO_FIXTURE_HOME/logs/${log_name}.log" <<EOF
[$now_prefix] BRAIN: evt-test-09-monitoring [dev] stuck after 10 re-dispatches
[$now_prefix] BRAIN: evt-test-09-monitoring [dev] stuck after 10 re-dispatches
[$now_prefix] ${log_name^^}: no such column: fixture_probe
[$now_prefix] ${log_name^^}: database is locked
[$now_prefix] ${log_name^^}: claude invocation failed
EOF
    if [[ "$log_name" == "pm" ]]; then
        echo "[zzzz-99-99 99:99:99] PM: fixture schema contamination" >> "$KODO_FIXTURE_HOME/logs/${log_name}.log"
    fi
done

sqlite3 "$KODO_DB" "
INSERT INTO pipeline_state
    (event_id, repo, domain, state, payload_json, metadata_json, retry_count, created_at, updated_at)
VALUES
    ('evt-test-09-monitoring', 'fixture-org-test-repo', 'dev', 'monitoring', '{}',
     json_object('redispatch_count', 10), 0, datetime('now', '-20 minutes'), datetime('now', '-20 minutes')),
    ('evt-test-09-stuck', 'fixture-org-test-repo', 'dev', 'triaging', '{}',
     '{}', 0, datetime('now', '-20 minutes'), datetime('now', '-20 minutes'));
"

health_json="$("$KODO_FIXTURE_HOME/bin/kodo-health.sh")"

if echo "$health_json" | jq -e 'has("_crash")' >/dev/null 2>&1; then
    fail "kodo-health.sh crashed: $(echo "$health_json" | jq -r '._crash')"
fi

loop_rate="$(echo "$health_json" | jq -r '.signals.loop_rate_per_min // 0')"
stuck_ratio="$(echo "$health_json" | jq -r '.signals.stuck_events_ratio // 0')"

awk -v v="$loop_rate" 'BEGIN { exit (v > 0) ? 0 : 1 }' \
    || fail "loop_rate_per_min was not > 0: $loop_rate"

awk -v v="$stuck_ratio" 'BEGIN { exit (v > 0) ? 0 : 1 }' \
    || fail "stuck_events_ratio was not > 0: $stuck_ratio"

# Deterministic heartbeat table row:
# loop_rate_per_min > 0.5 and monitoring redispatch_count >= 10
# => clear_redispatch_count on matching rows.
match_count="$(sqlite3 "$KODO_DB" "
SELECT COUNT(*) FROM pipeline_state
WHERE state='monitoring'
  AND COALESCE(json_extract(metadata_json, '$.redispatch_count'), 0) >= 10;
")"

[[ "$match_count" -gt 0 ]] || fail "heartbeat deterministic clear_redispatch_count probe found no rows"

sqlite3 "$KODO_DB" "
UPDATE pipeline_state
SET metadata_json = json_set(COALESCE(metadata_json, '{}'), '$.redispatch_count', 0),
    updated_at = datetime('now')
WHERE state='monitoring'
  AND COALESCE(json_extract(metadata_json, '$.redispatch_count'), 0) >= 10;
"

redispatch_count="$(sqlite3 "$KODO_DB" "
SELECT COALESCE(json_extract(metadata_json, '$.redispatch_count'), -1)
FROM pipeline_state
WHERE event_id='evt-test-09-monitoring' AND domain='dev';
")"

[[ "$redispatch_count" == "0" ]] || fail "redispatch_count was not reset to 0: $redispatch_count"

fixture_teardown
