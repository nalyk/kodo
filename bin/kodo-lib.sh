#!/usr/bin/env bash
set -euo pipefail

# Shared functions sourced by all KODO scripts

readonly KODO_HOME="${KODO_HOME:-$HOME/.kodo}"
readonly KODO_DB="${KODO_DB:-$KODO_HOME/kodo.db}"
readonly KODO_LOCK_DIR="$KODO_HOME"
readonly KODO_LOG_DIR="$KODO_HOME/logs"

# Initialize database if it doesn't exist
kodo_init_db() {
    if [[ ! -f "$KODO_DB" ]]; then
        mkdir -p "$(dirname "$KODO_DB")"
        sqlite3 "$KODO_DB" < "$KODO_HOME/sql/schema.sql"
    fi
}

# Parse a value from a flat TOML file
# Usage: kodo_toml_get <file> <key>
kodo_toml_get() {
    local file="$1" key="$2"
    grep -m1 "^${key}[[:space:]]*=" "$file" 2>/dev/null \
        | sed 's/^[^=]*=[[:space:]]*//' \
        | sed 's/^"//;s/"[[:space:]]*$//' \
        | sed "s/^'//;s/'[[:space:]]*$//"
}

# Parse a boolean from TOML (returns 0 for true, 1 for false)
kodo_toml_bool() {
    local val
    val="$(kodo_toml_get "$1" "$2")"
    [[ "$val" == "true" ]]
}

# Log a CLI invocation to budget_ledger
# Usage: kodo_log_budget <model> <repo> <domain> <tokens_in> <tokens_out> <cost_usd>
kodo_log_budget() {
    local model="$1" repo="$2" domain="$3"
    local tokens_in="${4:-0}" tokens_out="${5:-0}" cost_usd="${6:-0.0}"
    sqlite3 "$KODO_DB" "INSERT INTO budget_ledger (model, repo, domain, tokens_in, tokens_out, cost_usd)
        VALUES ('${model//\'/\'\'}', '${repo//\'/\'\'}', '${domain//\'/\'\'}', $tokens_in, $tokens_out, $cost_usd);"
}

# Check if repo is in shadow mode (returns 0 if shadow)
kodo_is_shadow() {
    local repo_toml="$1"
    local mode
    mode="$(kodo_toml_get "$repo_toml" "mode")"
    [[ "$mode" == "shadow" ]]
}

# Check monthly budget for a model
# Usage: kodo_check_budget <model> <limit_usd>
# Returns 0 if within budget, 1 if exceeded
kodo_check_budget() {
    local model="$1" limit="$2"
    local spent
    spent=$(sqlite3 "$KODO_DB" "SELECT COALESCE(SUM(cost_usd), 0.0)
        FROM budget_ledger
        WHERE model = '${model//\'/\'\'}' AND invoked_at > date('now', 'start of month');")
    awk "BEGIN { exit ($spent >= $limit) ? 1 : 0 }"
}

# Check if a CLI is available
kodo_cli_available() {
    command -v "$1" >/dev/null 2>&1
}

# Send a Telegram message
# Usage: kodo_send_telegram <message>
kodo_send_telegram() {
    local msg="$1"
    local token chat_id
    token="$(kodo_toml_get "$KODO_HOME/telegram.conf" "bot_token" 2>/dev/null)"
    chat_id="$(kodo_toml_get "$KODO_HOME/telegram.conf" "chat_id" 2>/dev/null)"
    if [[ -n "$token" && -n "$chat_id" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
            -d chat_id="$chat_id" \
            -d text="$msg" \
            -d parse_mode="Markdown" >/dev/null 2>&1
    fi
}

# Get repo identifier from TOML file
# Returns "owner-repo" format
kodo_repo_id() {
    local toml="$1"
    local owner name
    owner="$(kodo_toml_get "$toml" "owner")"
    name="$(kodo_toml_get "$toml" "name")"
    echo "${owner}-${name}"
}

# Get repo slug from TOML file
# Returns "owner/repo" format
kodo_repo_slug() {
    local toml="$1"
    local owner name
    owner="$(kodo_toml_get "$toml" "owner")"
    name="$(kodo_toml_get "$toml" "name")"
    echo "${owner}/${name}"
}

# Generate a unique event ID
kodo_event_id() {
    echo "evt-$(date +%s)-$$-$RANDOM"
}

# Log a message with timestamp
kodo_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# SQL-safe string escaping (single quotes)
kodo_sql_escape() {
    echo "${1//\'/\'\'}"
}

# Load shared runtime rules for injection into LLM prompts
# Usage: local ctx; ctx="$(kodo_runtime_context)"
#        prompt="$ctx\n\nYour specific task: ..."
kodo_runtime_context() {
    local rules_file="$KODO_HOME/context/runtime-rules.md"
    if [[ -f "$rules_file" ]]; then
        cat "$rules_file"
    else
        echo "[WARN: runtime-rules.md not found at $rules_file]"
    fi
}

# Build a prompt with runtime context prepended
# Usage: kodo_prompt <specific_instructions>
kodo_prompt() {
    local instructions="$1"
    local ctx
    ctx="$(kodo_runtime_context)"
    printf '%s\n\n---\n\n%s' "$ctx" "$instructions"
}

# Ensure logs directory exists
mkdir -p "$KODO_LOG_DIR" 2>/dev/null || true
