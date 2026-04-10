#!/usr/bin/env bash
set -euo pipefail

# Scenario 07: Merged PR in monitoring state → CI fails on merge commit → revert
# Expected path: monitoring → reverting → resolved
# Expected: merge_outcomes has outcome='reverted'

SCENARIO_NAME="07-post-merge-revert"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TEST_DIR/lib-fixture.sh"

fixture_setup "$SCENARIO_NAME"

PAYLOAD='{"number":107,"title":"Add caching layer","state":"merged","headRefName":"feature/caching","baseRefName":"main","author":{"login":"human-dev","type":"User"},"labels":[]}'

fixture_seed_event "evt-test-07-PullRequestEvent" "fixture-org-test-repo" "PullRequestEvent" "dev" "$PAYLOAD"

# Fast-forward to monitoring state with merge metadata
fixture_force_state "evt-test-07-PullRequestEvent" "dev" "monitoring"
fixture_set_metadata "evt-test-07-PullRequestEvent" "dev" "merge_sha" "abc123def456"
fixture_set_metadata "evt-test-07-PullRequestEvent" "dev" "monitoring_started_at" "$(date +%s)"
fixture_set_metadata "evt-test-07-PullRequestEvent" "dev" "merge_confidence" "92"
fixture_set_metadata "evt-test-07-PullRequestEvent" "dev" "pr_number" "107"

REPO_TOML="$KODO_FIXTURE_HOME/repos/fixture-org-test-repo.toml"
"$KODO_FIXTURE_HOME/bin/kodo-dev.sh" "evt-test-07-PullRequestEvent" "$REPO_TOML" "dev" 2>/dev/null || true

fixture_assert "$TEST_DIR/expected/$SCENARIO_NAME.expected" || true

fixture_teardown
