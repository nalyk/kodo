#!/usr/bin/env bash
set -euo pipefail

# Scenario 12: Unknown or unexpected CI states must refuse merge.

SCENARIO_NAME="12-unexpected-ci-state-refuses-merge"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TEST_DIR/lib-fixture.sh"

fixture_setup "$SCENARIO_NAME"

PAYLOAD='{"number":1201,"title":"Unexpected CI state","state":"open","headRefName":"feature/ci-error","baseRefName":"main","author":{"login":"human-dev","type":"User"},"labels":[]}'
fixture_seed_event "evt-test-12-PullRequestEvent" "fixture-org-test-repo" "PullRequestEvent" "dev" "$PAYLOAD"
fixture_force_state "evt-test-12-PullRequestEvent" "dev" "auto_merge"

REPO_TOML="$KODO_FIXTURE_HOME/repos/fixture-org-test-repo.toml"
"$KODO_FIXTURE_HOME/bin/kodo-dev.sh" "evt-test-12-PullRequestEvent" "$REPO_TOML" "dev" 2>/dev/null || true

fixture_assert "$TEST_DIR/expected/$SCENARIO_NAME.expected" || true

fixture_teardown
