#!/usr/bin/env bash
set -euo pipefail

# Scenario 02: Human PR with medium confidence → ballot → no consensus → deferred
# Expected path: pending → triaging → auditing → scanning → balloting → deferred

SCENARIO_NAME="02-subtle-bug-defers"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TEST_DIR/lib-fixture.sh"

fixture_setup "$SCENARIO_NAME"

PAYLOAD='{"number":102,"title":"Optimize calculate function","state":"open","headRefName":"feature/optimize-calc","baseRefName":"main","author":{"login":"human-dev","type":"User"},"labels":[]}'

fixture_seed_event "evt-test-02-PullRequestEvent" "fixture-org-test-repo" "PullRequestEvent" "dev" "$PAYLOAD"

REPO_TOML="$KODO_FIXTURE_HOME/repos/fixture-org-test-repo.toml"
"$KODO_FIXTURE_HOME/bin/kodo-dev.sh" "evt-test-02-PullRequestEvent" "$REPO_TOML" "dev" 2>/dev/null || true

fixture_assert "$TEST_DIR/expected/$SCENARIO_NAME.expected" || true

fixture_teardown
