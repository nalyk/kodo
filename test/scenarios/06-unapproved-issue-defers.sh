#!/usr/bin/env bash
set -euo pipefail

# Scenario 06: Issue with intent gate enabled, no approval → window expires → deferred
# Expected path: pending → triaging → awaiting_intent → deferred

SCENARIO_NAME="06-unapproved-issue-defers"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TEST_DIR/lib-fixture.sh"

fixture_setup "$SCENARIO_NAME"

PAYLOAD='{"number":55,"title":"Add dark mode","state":"open","labels":["enhancement"],"author":{"login":"contributor","type":"User"}}'

fixture_seed_event "evt-test-06-IssuesEvent" "fixture-org-test-repo" "IssuesEvent" "dev" "$PAYLOAD"

# Simulate: intent comment was posted a long time ago, no reactions
# Set intent_comment_id so the engine skips posting and goes to check
fixture_set_metadata "evt-test-06-IssuesEvent" "dev" "intent_comment_id" "12345"
# Set intent_comment_at to a timestamp well beyond the 24h window (48h ago)
PAST_TS=$(( $(date +%s) - 172800 ))
fixture_set_metadata "evt-test-06-IssuesEvent" "dev" "intent_comment_at" "$PAST_TS"

# Fast-forward to awaiting_intent state (triaging already happened)
fixture_force_state "evt-test-06-IssuesEvent" "dev" "awaiting_intent"

REPO_TOML="$KODO_FIXTURE_HOME/repos/fixture-org-test-repo.toml"
"$KODO_FIXTURE_HOME/bin/kodo-dev.sh" "evt-test-06-IssuesEvent" "$REPO_TOML" "dev" 2>/dev/null || true

fixture_assert "$TEST_DIR/expected/$SCENARIO_NAME.expected" || true

fixture_teardown
