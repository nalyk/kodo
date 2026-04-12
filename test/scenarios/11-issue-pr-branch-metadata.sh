#!/usr/bin/env bash
set -euo pipefail

# Scenario 11: Issue-generated PRs must use metadata pr_branch for hard gates and scanning.

SCENARIO_NAME="11-issue-pr-branch-metadata"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TEST_DIR/lib-fixture.sh"

fixture_setup "$SCENARIO_NAME"

cat > "$KODO_FIXTURE_HOME/repos/fixture-org-test-repo.toml" <<'TOML'
[repo]
owner = "fixture-org"
name = "test-repo"
provider = "github"
mode = "live"
branch_default = "main"
enabled = true

[dev]
enabled = true
test_command = 'touch "$KODO_HOME/hard-gate-ran"; test -f branch-marker'
lint_command = ""
tests_optional = false
lint_optional = true
allow_no_ci = true
max_diff_lines = 500
auto_merge_deps = false
semver_release = false
await_bot_feedback = false
feedback_window_minutes = 0
max_feedback_rounds = 0
apply_bot_suggestions = false
trusted_review_bots = []
max_rebase_attempts = 2
monitoring_window_hours = 48
issue_intent_gate = false
intent_window_hours = 24

[mkt]
enabled = false

[pm]
enabled = false
TOML

PAYLOAD='{"number":1101,"title":"Generated fix request","state":"open","labels":["bug"],"author":{"login":"maintainer","type":"User"},"authorAssociation":"MEMBER"}'
fixture_seed_event "evt-test-11-IssuesEvent" "fixture-org-test-repo" "IssuesEvent" "dev" "$PAYLOAD"
fixture_force_state "evt-test-11-IssuesEvent" "dev" "hard_gates"
fixture_set_metadata "evt-test-11-IssuesEvent" "dev" "pr_number" "1101"
fixture_set_metadata "evt-test-11-IssuesEvent" "dev" "pr_branch" "kodo/dev/evt-test-11-IssuesEvent"

export KODO_FIXTURE_PR_BRANCH="kodo/dev/evt-test-11-IssuesEvent"

REPO_TOML="$KODO_FIXTURE_HOME/repos/fixture-org-test-repo.toml"
"$KODO_FIXTURE_HOME/bin/kodo-dev.sh" "evt-test-11-IssuesEvent" "$REPO_TOML" "dev" >/dev/null 2>&1 || true

missing=()
[[ -f "$KODO_HOME/hard-gate-ran" ]] || missing+=("hard gate test command did not run on metadata branch")
[[ -f "$KODO_HOME/semgrep-ran" ]] || missing+=("semgrep did not run on metadata branch")

if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "  DIFF (expected vs actual):"
    for item in "${missing[@]}"; do
        printf '    %s\n' "$item"
    done
    fixture_teardown
    exit 1
fi

fixture_teardown
