#!/usr/bin/env bash
set -euo pipefail

# Scenario 16: DEV closes duplicate issue events and non-issue push events without generating branches.

SCENARIO_NAME="16-dev-duplicate-and-push-events"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TEST_DIR/lib-fixture.sh"

fixture_setup "$SCENARIO_NAME"

export KODO_FIXTURE_DIR="$KODO_FIXTURE_HOME/fixtures"
mkdir -p "$KODO_FIXTURE_DIR/$SCENARIO_NAME"
cat > "$KODO_FIXTURE_DIR/$SCENARIO_NAME/pr-checks.json" <<'JSON'
{"pr_state":"OPEN","state":"SUCCESS","pass":1,"fail":0,"pending":0,"total":1}
JSON

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
test_command = "true"
lint_command = ""
tests_optional = true
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

REPO_TOML="$KODO_FIXTURE_HOME/repos/fixture-org-test-repo.toml"
ISSUE_PAYLOAD='{"number":42,"title":"Fix duplicate processing","state":"open","labels":["bug"],"author":{"login":"maintainer","type":"User"}}'
PUSH_PAYLOAD='{"ref":"refs/heads/main","head":"abc123","author":{"login":"maintainer","type":"User"}}'

fixture_seed_event "evt-existing-issue-42" "fixture-org-test-repo" "IssuesEvent" "dev" "$ISSUE_PAYLOAD"
fixture_force_state "evt-existing-issue-42" "dev" "awaiting_feedback"
fixture_set_metadata "evt-existing-issue-42" "dev" "pr_number" "77"
fixture_set_metadata "evt-existing-issue-42" "dev" "pr_url" "https://github.com/fixture-org/test-repo/pull/77"
fixture_set_metadata "evt-existing-issue-42" "dev" "pr_branch" "kodo/dev/evt-existing-issue-42"

fixture_seed_event "evt-duplicate-issue-42" "fixture-org-test-repo" "IssueCommentEvent" "dev" "$ISSUE_PAYLOAD"
"$KODO_FIXTURE_HOME/bin/kodo-dev.sh" "evt-duplicate-issue-42" "$REPO_TOML" "dev" >/dev/null 2>&1 || true

fixture_seed_event "evt-push-no-issue" "fixture-org-test-repo" "PushEvent" "dev" "$PUSH_PAYLOAD"
"$KODO_FIXTURE_HOME/bin/kodo-dev.sh" "evt-push-no-issue" "$REPO_TOML" "dev" >/dev/null 2>&1 || true

duplicate_state=$(sqlite3 "$KODO_DB" "SELECT state FROM pipeline_state WHERE event_id='evt-duplicate-issue-42' AND domain='dev';")
duplicate_pr=$(sqlite3 "$KODO_DB" "SELECT json_extract(metadata_json, '$.pr_number') FROM pipeline_state WHERE event_id='evt-duplicate-issue-42' AND domain='dev';")
duplicate_of=$(sqlite3 "$KODO_DB" "SELECT json_extract(metadata_json, '$.duplicate_of_event') FROM pipeline_state WHERE event_id='evt-duplicate-issue-42' AND domain='dev';")
push_state=$(sqlite3 "$KODO_DB" "SELECT state FROM pipeline_state WHERE event_id='evt-push-no-issue' AND domain='dev';")
push_reason=$(sqlite3 "$KODO_DB" "SELECT json_extract(metadata_json, '$.closed_reason') FROM pipeline_state WHERE event_id='evt-push-no-issue' AND domain='dev';")

missing=()
[[ "$duplicate_state" == "closed" ]] || missing+=("duplicate event was not closed")
[[ "$duplicate_pr" == "77" ]] || missing+=("duplicate event did not inherit existing PR number")
[[ "$duplicate_of" == "evt-existing-issue-42" ]] || missing+=("duplicate event did not record source event")
[[ "$push_state" == "closed" ]] || missing+=("push event was not closed")
[[ "$push_reason" == "non-issue event — no issue number in payload" ]] || missing+=("push event did not record non-issue close reason")
if grep -qE '^(branch-push|pr-create)' "$KODO_FIXTURE_HOME/mock-calls.log"; then
    missing+=("duplicate/non-issue events generated branch or PR writes")
fi

if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "  DIFF (expected vs actual):"
    for item in "${missing[@]}"; do
        printf '    %s\n' "$item"
    done
    fixture_teardown
    exit 1
fi

fixture_teardown
