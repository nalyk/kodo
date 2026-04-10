#!/usr/bin/env bash
set -euo pipefail

# Scenario 01: Dependabot dependency bump → auto-merge
# Expected path: pending → triaging → hard_gates → auto_merge → releasing → resolved
# (No monitoring because pr-merge-sha returns empty → graceful skip)

SCENARIO_NAME="01-dependabot-auto-merge"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TEST_DIR/lib-fixture.sh"

fixture_setup "$SCENARIO_NAME"

# Seed a PR event from dependabot
PAYLOAD='{"number":101,"title":"Bump lodash from 4.17.20 to 4.17.21","state":"open","headRefName":"dependabot/npm_and_yarn/lodash-4.17.21","baseRefName":"main","author":{"login":"dependabot[bot]","type":"Bot"},"labels":["dependencies"]}'

fixture_seed_event "evt-test-01-PullRequestEvent" "fixture-org-test-repo" "PullRequestEvent" "dev" "$PAYLOAD"

# Run the dev engine
REPO_TOML="$KODO_FIXTURE_HOME/repos/fixture-org-test-repo.toml"
"$KODO_FIXTURE_HOME/bin/kodo-dev.sh" "evt-test-01-PullRequestEvent" "$REPO_TOML" "dev" 2>/dev/null || true

# Assert
fixture_assert "$TEST_DIR/expected/$SCENARIO_NAME.expected" || true

fixture_teardown
