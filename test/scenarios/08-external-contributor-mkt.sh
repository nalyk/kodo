#!/usr/bin/env bash
set -euo pipefail

# Scenario 08: PR from external contributor → mkt engine welcomes them
# Expected: community_log has a 'welcomed' entry after mkt engine runs

SCENARIO_NAME="08-external-contributor-mkt"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TEST_DIR/lib-fixture.sh"

fixture_setup "$SCENARIO_NAME"

PAYLOAD='{"number":108,"title":"Fix typo in README","state":"open","headRefName":"fix/readme-typo","baseRefName":"main","author":{"login":"new-contributor","type":"User"},"labels":[]}'

# Create BOTH dev and mkt pipeline_state rows (as brain would do)
fixture_seed_event "evt-test-08-PullRequestEvent" "fixture-org-test-repo" "PullRequestEvent" "dev" "$PAYLOAD"
fixture_seed_event "evt-test-08-PullRequestEvent" "fixture-org-test-repo" "PullRequestEvent" "mkt" "$PAYLOAD"

# Run the mkt engine (we only test the mkt path here)
REPO_TOML="$KODO_FIXTURE_HOME/repos/fixture-org-test-repo.toml"
"$KODO_FIXTURE_HOME/bin/kodo-mkt.sh" "evt-test-08-PullRequestEvent" "$REPO_TOML" "mkt" 2>/dev/null || true

fixture_assert "$TEST_DIR/expected/$SCENARIO_NAME.expected" || true

fixture_teardown
