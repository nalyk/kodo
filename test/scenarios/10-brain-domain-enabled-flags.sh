#!/usr/bin/env bash
set -euo pipefail

# Scenario 10: Brain must not dispatch domains disabled in repo TOML.

SCENARIO_NAME="10-brain-domain-enabled-flags"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TEST_DIR/lib-fixture.sh"

fixture_setup "$SCENARIO_NAME"

cat > "$KODO_FIXTURE_HOME/repos/fixture-org-disabled-repo.toml" <<'TOML'
[repo]
owner = "fixture-org"
name = "disabled-repo"
provider = "github"
mode = "shadow"
branch_default = "main"
enabled = true

[dev]
enabled = false
issue_intent_gate = true

[mkt]
enabled = false

[pm]
enabled = false
TOML

PAYLOAD='{"number":1001,"title":"Bug from member","state":"open","labels":["bug"],"author":{"login":"maintainer","type":"User"},"authorAssociation":"MEMBER"}'
sqlite3 "$KODO_DB" "INSERT INTO pending_events (event_id, repo, event_type, payload_json)
    VALUES ('evt-test-10-IssuesEvent', 'fixture-org-disabled-repo', 'IssuesEvent', '$(printf "%s" "$PAYLOAD" | sed "s/'/''/g")');"

"$KODO_FIXTURE_HOME/bin/kodo-brain.sh" >/dev/null 2>&1 || true
sleep 1

fixture_assert "$TEST_DIR/expected/$SCENARIO_NAME.expected" || true

fixture_teardown
