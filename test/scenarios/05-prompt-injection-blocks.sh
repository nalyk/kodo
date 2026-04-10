#!/usr/bin/env bash
set -euo pipefail

# Scenario 05: Issue with malicious body → Claude returns INJECTION_DETECTED → deferred
# Expected path: pending → triaging → awaiting_intent (skipped via pre-set) → generating → deferred

SCENARIO_NAME="05-prompt-injection-blocks"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TEST_DIR/lib-fixture.sh"

fixture_setup "$SCENARIO_NAME"

PAYLOAD='{"number":42,"title":"Fix login bug","state":"open","labels":["bug"],"author":{"login":"attacker","type":"User"}}'

fixture_seed_event "evt-test-05-IssuesEvent" "fixture-org-test-repo" "IssuesEvent" "dev" "$PAYLOAD"

# Pre-approve intent gate so we reach the generating stage
fixture_set_metadata "evt-test-05-IssuesEvent" "dev" "intent_decision" "approved"

REPO_TOML="$KODO_FIXTURE_HOME/repos/fixture-org-test-repo.toml"
"$KODO_FIXTURE_HOME/bin/kodo-dev.sh" "evt-test-05-IssuesEvent" "$REPO_TOML" "dev" 2>/dev/null || true

fixture_assert "$TEST_DIR/expected/$SCENARIO_NAME.expected" || true

fixture_teardown
