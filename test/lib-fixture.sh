#!/usr/bin/env bash
set -euo pipefail

# Shared test helpers for fixture-based regression harness

# Resolve paths relative to this file
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

# ── Setup / Teardown ────────────────────────────────────────

fixture_setup() {
    local scenario_name="${1:-default}"
    export KODO_FIXTURE_HOME="/tmp/kodo-fixtures-$$-${scenario_name}"
    export KODO_HOME="$KODO_FIXTURE_HOME"
    export KODO_DB="$KODO_FIXTURE_HOME/kodo.db"
    export KODO_FIXTURE_SCENARIO="$scenario_name"
    export KODO_FIXTURE_DIR="$TEST_DIR/fixtures"

    # Clean slate
    rm -rf "$KODO_FIXTURE_HOME"
    mkdir -p "$KODO_FIXTURE_HOME"/{bin,repos,schemas,context,logs,.workdir}

    # Copy production code into isolated home
    cp "$REPO_ROOT"/bin/*.sh "$KODO_FIXTURE_HOME/bin/"
    cp "$REPO_ROOT"/schemas/*.json "$KODO_FIXTURE_HOME/schemas/"
    cp "$REPO_ROOT"/sql/schema.sql "$KODO_FIXTURE_HOME/sql/schema.sql" 2>/dev/null || {
        mkdir -p "$KODO_FIXTURE_HOME/sql"
        cp "$REPO_ROOT/sql/schema.sql" "$KODO_FIXTURE_HOME/sql/schema.sql"
    }
    if [[ -f "$REPO_ROOT/context/runtime-rules.md" ]]; then
        cp "$REPO_ROOT/context/runtime-rules.md" "$KODO_FIXTURE_HOME/context/runtime-rules.md"
    else
        echo "# Runtime rules (fixture stub)" > "$KODO_FIXTURE_HOME/context/runtime-rules.md"
    fi

    # Copy fixture repo configs
    cp "$TEST_DIR"/fixtures/repos/*.toml "$KODO_FIXTURE_HOME/repos/" 2>/dev/null || true
    cp "$TEST_DIR"/fixtures/repos/*.kodo.md "$KODO_FIXTURE_HOME/repos/" 2>/dev/null || true
    cp "$TEST_DIR"/fixtures/repos/*.voice.md "$KODO_FIXTURE_HOME/repos/" 2>/dev/null || true

    # Replace kodo-git.sh with mock
    cp "$TEST_DIR/mock-kodo-git.sh" "$KODO_FIXTURE_HOME/bin/kodo-git.sh"
    chmod +x "$KODO_FIXTURE_HOME/bin/kodo-git.sh"

    # Install mock CLIs — engines check `command -v` so these must be on PATH
    for cli in claude codex qwen gemini semgrep; do
        cp "$TEST_DIR/mock-cli.sh" "$KODO_FIXTURE_HOME/bin/$cli"
        chmod +x "$KODO_FIXTURE_HOME/bin/$cli"
    done
    export PATH="$KODO_FIXTURE_HOME/bin:$PATH"

    # Dummy telegram config (prevents curl calls)
    cat > "$KODO_FIXTURE_HOME/telegram.conf" <<'EOF'
bot_token = ""
chat_id = ""
EOF

    # Initialize database
    sqlite3 "$KODO_DB" < "$KODO_FIXTURE_HOME/sql/schema.sql"

    # Mock call log
    : > "$KODO_FIXTURE_HOME/mock-calls.log"
}

fixture_teardown() {
    if [[ -n "${KODO_FIXTURE_HOME:-}" && -d "$KODO_FIXTURE_HOME" ]]; then
        rm -rf "$KODO_FIXTURE_HOME"
    fi
}

# ── Event Seeding ───────────────────────────────────────────

# Seed an event into pending_events + create pipeline_state at pending
# Usage: fixture_seed_event <event_id> <repo_id> <event_type> <domain> <payload_json>
fixture_seed_event() {
    local event_id="$1" repo_id="$2" event_type="$3" domain="$4" payload_json="$5"

    sqlite3 "$KODO_DB" "INSERT OR IGNORE INTO pending_events (event_id, repo, event_type, payload_json)
        VALUES ('$event_id', '$repo_id', '$event_type', '$payload_json');"

    export KODO_TRANSITION_REPO="$repo_id"
    export KODO_TRANSITION_PAYLOAD="$payload_json"
    "$KODO_FIXTURE_HOME/bin/kodo-transition.sh" "$event_id" '*' pending "$domain"
}

# Set pipeline metadata without going through an engine
# Usage: fixture_set_metadata <event_id> <domain> <key> <value>
fixture_set_metadata() {
    local event_id="$1" domain="$2" key="$3" value="$4"
    if [[ "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        sqlite3 "$KODO_DB" "UPDATE pipeline_state
            SET metadata_json = json_set(COALESCE(metadata_json, '{}'), '\$.${key}', ${value})
            WHERE event_id = '${event_id}' AND domain = '${domain}';"
    else
        sqlite3 "$KODO_DB" "UPDATE pipeline_state
            SET metadata_json = json_set(COALESCE(metadata_json, '{}'), '\$.${key}', '${value}')
            WHERE event_id = '${event_id}' AND domain = '${domain}';"
    fi
}

# Force a pipeline_state row to a specific state (for mid-pipeline scenarios)
# Usage: fixture_force_state <event_id> <domain> <state>
fixture_force_state() {
    local event_id="$1" domain="$2" state="$3"
    sqlite3 "$KODO_DB" "UPDATE pipeline_state SET state = '${state}'
        WHERE event_id = '${event_id}' AND domain = '${domain}';"
}

# ── State Dump ──────────────────────────────────────────────

# Dump normalized state for comparison against expected output
# Usage: fixture_dump > result.txt
fixture_dump() {
    echo "=== pipeline_state ==="
    sqlite3 "$KODO_DB" "SELECT event_id, domain, state FROM pipeline_state ORDER BY event_id, domain;"

    echo "=== merge_outcomes ==="
    sqlite3 "$KODO_DB" "SELECT event_id, outcome FROM merge_outcomes ORDER BY event_id;"

    echo "=== deferred_queue ==="
    sqlite3 "$KODO_DB" "SELECT event_id, domain, reason FROM deferred_queue ORDER BY event_id;"

    echo "=== community_log ==="
    sqlite3 "$KODO_DB" "SELECT repo, author, action FROM community_log ORDER BY repo, author;"

    echo "=== mock_calls ==="
    if [[ -f "$KODO_FIXTURE_HOME/mock-calls.log" ]]; then
        # Show only write actions (the interesting ones for verification)
        grep -E '^(pr-merge|pr-create|pr-comment|pr-revert|issue-comment|issue-close|branch-push)' \
            "$KODO_FIXTURE_HOME/mock-calls.log" | sort || true
    fi
}

# ── Assertion ───────────────────────────────────────────────

# Compare dump against expected file
# Usage: fixture_assert <expected_file>
# Sets FIXTURE_RESULT=PASS or FIXTURE_RESULT=FAIL
fixture_assert() {
    local expected_file="$1"
    local actual
    actual=$(fixture_dump)

    if [[ ! -f "$expected_file" ]]; then
        echo "  MISSING expected file: $expected_file"
        echo "  Actual output:"
        echo "$actual" | while IFS= read -r line; do printf '    %s\n' "$line"; done
        export FIXTURE_RESULT="FAIL"
        return 1
    fi

    local expected
    expected=$(cat "$expected_file")

    if [[ "$actual" == "$expected" ]]; then
        export FIXTURE_RESULT="PASS"
        return 0
    else
        FIXTURE_RESULT="FAIL"
        echo "  DIFF (expected vs actual):"
        diff <(echo "$expected") <(echo "$actual") | sed 's/^/    /' || true
        return 1
    fi
}
