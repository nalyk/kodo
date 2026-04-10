#!/usr/bin/env bash
set -euo pipefail

# Scenario 03: PR with SQL injection vulnerabilities → semgrep catches → deferred
# Expected path: pending → triaging → auditing → scanning → deferred
# (6 semgrep findings > 5 critical threshold)

SCENARIO_NAME="03-sql-injection-blocks"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TEST_DIR/lib-fixture.sh"

fixture_setup "$SCENARIO_NAME"

PAYLOAD='{"number":103,"title":"Add raw query support","state":"open","headRefName":"feature/raw-queries","baseRefName":"main","author":{"login":"human-dev","type":"User"},"labels":[]}'

fixture_seed_event "evt-test-03-PullRequestEvent" "fixture-org-test-repo" "PullRequestEvent" "dev" "$PAYLOAD"

# Tell mock repo-clone to pre-create the PR branch for scanning
export KODO_FIXTURE_PR_BRANCH="feature/raw-queries"

REPO_TOML="$KODO_FIXTURE_HOME/repos/fixture-org-test-repo.toml"
"$KODO_FIXTURE_HOME/bin/kodo-dev.sh" "evt-test-03-PullRequestEvent" "$REPO_TOML" "dev" 2>/dev/null || true

fixture_assert "$TEST_DIR/expected/$SCENARIO_NAME.expected" || true

fixture_teardown
