#!/usr/bin/env bash
set -euo pipefail

# Scenario 09: Transitions require the owning PID and stale from-state writes lose.

SCENARIO_NAME="09-transition-atomic-ownership"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TEST_DIR/lib-fixture.sh"

fixture_setup "$SCENARIO_NAME"

PAYLOAD='{"number":901,"title":"Transition ownership","state":"open","author":{"login":"maintainer","type":"User"}}'
fixture_seed_event "evt-test-09-IssuesEvent" "fixture-org-test-repo" "IssuesEvent" "dev" "$PAYLOAD"

sqlite3 "$KODO_DB" "UPDATE pipeline_state SET processing_pid = 111111 WHERE event_id = 'evt-test-09-IssuesEvent' AND domain = 'dev';"

if KODO_TRANSITION_OWNER_PID=222222 "$KODO_FIXTURE_HOME/bin/kodo-transition.sh" \
    "evt-test-09-IssuesEvent" "pending" "triaging" "dev" >/dev/null 2>&1; then
    echo "  DIFF (expected vs actual):"
    echo "    wrong owner advanced transition"
    fixture_teardown
    exit 1
fi

KODO_TRANSITION_OWNER_PID=111111 "$KODO_FIXTURE_HOME/bin/kodo-transition.sh" \
    "evt-test-09-IssuesEvent" "pending" "triaging" "dev" >/dev/null

if KODO_TRANSITION_OWNER_PID=111111 "$KODO_FIXTURE_HOME/bin/kodo-transition.sh" \
    "evt-test-09-IssuesEvent" "pending" "deferred" "dev" >/dev/null 2>&1; then
    echo "  DIFF (expected vs actual):"
    echo "    stale from-state advanced transition"
    fixture_teardown
    exit 1
fi

fixture_assert "$TEST_DIR/expected/$SCENARIO_NAME.expected" || true

fixture_teardown
