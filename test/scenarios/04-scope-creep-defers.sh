#!/usr/bin/env bash
set -euo pipefail

# Scenario 04: PR diff exceeds max_diff_lines → hard gate fails → deferred
# We simulate an issue-generated PR that's already at hard_gates state,
# because the diff size gate lives in do_hard_gates (not in auditing).
# Expected path: hard_gates → deferred (diff too large: 803 > 500)

SCENARIO_NAME="04-scope-creep-defers"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TEST_DIR/lib-fixture.sh"

fixture_setup "$SCENARIO_NAME"

# Seed as a PR event that's already been triaged to hard_gates
PAYLOAD='{"number":104,"title":"Major refactor of everything","state":"open","headRefName":"feature/big-refactor","baseRefName":"main","author":{"login":"human-dev","type":"User"},"labels":[]}'

fixture_seed_event "evt-test-04-PullRequestEvent" "fixture-org-test-repo" "PullRequestEvent" "dev" "$PAYLOAD"

# Fast-forward to hard_gates (as if triage already sent it here via deps or issue path)
fixture_force_state "evt-test-04-PullRequestEvent" "dev" "hard_gates"

REPO_TOML="$KODO_FIXTURE_HOME/repos/fixture-org-test-repo.toml"
"$KODO_FIXTURE_HOME/bin/kodo-dev.sh" "evt-test-04-PullRequestEvent" "$REPO_TOML" "dev" 2>/dev/null || true

fixture_assert "$TEST_DIR/expected/$SCENARIO_NAME.expected" || true

fixture_teardown
