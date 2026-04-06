#!/usr/bin/env bash
set -euo pipefail

# Shared functions sourced by all KODO scripts

readonly KODO_HOME="${KODO_HOME:-$HOME/.kodo}"
readonly KODO_DB="${KODO_DB:-$KODO_HOME/kodo.db}"
readonly KODO_LOCK_DIR="$KODO_HOME"
readonly KODO_LOG_DIR="$KODO_HOME/logs"

# Initialize database if it doesn't exist
# WAL mode + busy timeout for concurrent access from multiple engines
kodo_init_db() {
    if [[ ! -f "$KODO_DB" ]]; then
        mkdir -p "$(dirname "$KODO_DB")"
        sqlite3 "$KODO_DB" < "$KODO_HOME/sql/schema.sql"
    fi
    local pragma_out
    pragma_out=$(sqlite3 "$KODO_DB" "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;" 2>&1) || {
        kodo_log "WARNING: DB pragma failed: $pragma_out"
    }
}

# SQLite wrapper with busy timeout (5s wait on lock instead of instant fail)
kodo_sql() {
    sqlite3 -cmd ".timeout 5000" "$KODO_DB" "$1"
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
    kodo_sql "INSERT INTO budget_ledger (model, repo, domain, tokens_in, tokens_out, cost_usd)
        VALUES ('${model//\'/\'\'}', '${repo//\'/\'\'}', '${domain//\'/\'\'}', $tokens_in, $tokens_out, $cost_usd);"
}

# Check if repo is in shadow mode (returns 0 if shadow)
kodo_is_shadow() {
    local repo_toml="$1"
    local mode
    mode="$(kodo_toml_get "$repo_toml" "mode")"
    [[ "$mode" == "shadow" ]]
}

# ── Budget Enforcement ───────────────────────────────────────
# Hard limits per model (monthly). Checked before every LLM invocation.
# Alert at 80% via Telegram. Hard-block at 100%.

declare -A KODO_BUDGET_LIMITS=(
    ["claude"]=200
    ["codex"]=20
    ["gemini"]=0
    ["qwen"]=0
)

# Get monthly spend for a model
# Usage: kodo_get_spend <model>
kodo_get_spend() {
    local model="$1"
    kodo_sql "SELECT COALESCE(SUM(cost_usd), 0.0)
        FROM budget_ledger
        WHERE model = '${model//\'/\'\'}' AND invoked_at > date('now', 'start of month');"
}

# Check monthly budget for a model
# Returns 0 if within budget, 1 if exceeded
kodo_check_budget() {
    local model="$1" limit="${2:-}"
    # Use explicit limit or look up from defaults
    if [[ -z "$limit" ]]; then
        limit="${KODO_BUDGET_LIMITS[$model]:-0}"
    fi
    # Free-tier models always pass
    if [[ "$limit" == "0" ]]; then
        return 0
    fi
    local spent
    spent=$(kodo_get_spend "$model")
    # Validate numeric before awk arithmetic
    if ! [[ "$spent" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        kodo_log "BUDGET: invalid spend value for $model: $spent — blocking"
        return 1
    fi
    # Alert at 80%
    local threshold
    threshold=$(awk "BEGIN { printf \"%.2f\", $limit * 0.80 }")
    if awk "BEGIN { exit ($spent >= $threshold && $spent < $limit) ? 0 : 1 }" 2>/dev/null; then
        # Only alert once per day (check deferred_queue for today's alert)
        local alert_exists
        alert_exists=$(kodo_sql "SELECT COUNT(*) FROM deferred_queue
            WHERE event_id = 'budget-alert-${model}' AND queued_at > date('now');")
        if [[ "$alert_exists" -eq 0 ]]; then
            kodo_log "BUDGET: ⚠ $model at \$${spent}/\$${limit} ($(awk "BEGIN { printf \"%.0f\", ($spent/$limit)*100 }")%)"
            kodo_send_telegram "⚠ KŌDŌ Budget Alert: *${model}* at \$${spent}/\$${limit} this month"
            kodo_sql "INSERT INTO deferred_queue (event_id, repo, domain, reason)
                VALUES ('budget-alert-${model}', 'system', 'dev', 'budget alert sent');"
        fi
    fi
    # Hard block at 100%
    if awk "BEGIN { exit ($spent >= $limit) ? 0 : 1 }" 2>/dev/null; then
        kodo_log "BUDGET: ✖ $model BLOCKED — \$${spent} >= \$${limit} monthly limit"
        kodo_send_telegram "🛑 KŌDŌ Budget BLOCKED: *${model}* at \$${spent} — monthly limit \$${limit} reached"
        return 1
    fi
    return 0
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
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            "https://api.telegram.org/bot${token}/sendMessage" \
            -d chat_id="$chat_id" \
            -d text="$msg" \
            -d parse_mode="Markdown" 2>/dev/null) || http_code="000"
        if [[ "$http_code" != "200" ]]; then
            kodo_log "TELEGRAM: send failed (HTTP $http_code) — ${msg:0:80}"
        fi
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

# ── Concurrent Processing Guard ──────────────────────────────
# Atomic claim-before-process. Prevents two engine instances from
# processing the same event_id+domain simultaneously.
# Uses PID-based ownership with stale PID detection.

# Claim an event for processing. Returns 0 if claimed, 1 if already claimed.
# Usage: kodo_claim_event <event_id> <domain>
kodo_claim_event() {
    local event_id="$1" domain="$2"
    local my_pid=$$
    local eid dom
    eid="$(kodo_sql_escape "$event_id")"
    dom="$(kodo_sql_escape "$domain")"

    # Atomic claim: UPDATE + changes() in single sqlite3 invocation
    # (changes() only works within the same connection)
    # Step 1: try claiming NULL/self pid (common case, no race)
    local rows_changed
    rows_changed=$(sqlite3 -cmd ".timeout 5000" "$KODO_DB" "
        UPDATE pipeline_state
        SET processing_pid = ${my_pid}, updated_at = datetime('now')
        WHERE event_id = '${eid}' AND domain = '${dom}'
        AND (processing_pid IS NULL OR processing_pid = ${my_pid});
        SELECT changes();")

    if [[ "${rows_changed:-0}" -gt 0 ]]; then
        kodo_log "LOCK: $event_id [$domain] claimed by PID $my_pid"
        return 0
    fi

    # Step 2: someone else holds it — check if alive
    local current_pid
    current_pid=$(kodo_sql "SELECT processing_pid FROM pipeline_state
        WHERE event_id = '${eid}' AND domain = '${dom}';")

    if [[ -n "$current_pid" && "$current_pid" != "NULL" ]]; then
        if kill -0 "$current_pid" 2>/dev/null; then
            kodo_log "LOCK: $event_id [$domain] owned by PID $current_pid (alive) — skipping"
            return 1
        fi
        # Dead PID — reclaim atomically (single connection)
        kodo_log "LOCK: $event_id [$domain] stale PID $current_pid (dead) — reclaiming"
        rows_changed=$(sqlite3 -cmd ".timeout 5000" "$KODO_DB" "
            UPDATE pipeline_state
            SET processing_pid = ${my_pid}, updated_at = datetime('now')
            WHERE event_id = '${eid}' AND domain = '${dom}'
            AND processing_pid = '$(kodo_sql_escape "$current_pid")';
            SELECT changes();")

        if [[ "${rows_changed:-0}" -gt 0 ]]; then
            kodo_log "LOCK: $event_id [$domain] reclaimed by PID $my_pid"
            return 0
        fi
    fi

    kodo_log "LOCK: $event_id [$domain] claim failed"
    return 1
}

# Release an event after processing
# Usage: kodo_release_event <event_id> <domain>
kodo_release_event() {
    local event_id="$1" domain="$2"
    local my_pid=$$
    kodo_sql "UPDATE pipeline_state
        SET processing_pid = NULL
        WHERE event_id = '$(kodo_sql_escape "$event_id")'
        AND domain = '$(kodo_sql_escape "$domain")'
        AND processing_pid = ${my_pid};"
}

# ── Robust JSON Extraction ───────────────────────────────────
# Extracts a JSON object from messy LLM output (fences, preamble, mixed text)

_extract_json() {
    local input="$1"
    [[ -z "$input" ]] && return 1

    # Fast path: input is already valid JSON object
    if echo "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
        echo "$input" | jq -c '.'
        return 0
    fi

    # Robust path: python3 handles nested braces, code fences, preamble
    if command -v python3 >/dev/null 2>&1; then
        local result
        result=$(python3 -c '
import sys, json, re

text = sys.stdin.read()

# 1: direct parse
try:
    obj = json.loads(text.strip())
    if isinstance(obj, dict):
        print(json.dumps(obj))
        sys.exit(0)
except: pass

# 2: extract from ```json ... ``` fences
for block in re.findall(r"```(?:json)?\s*\n(.*?)\n```", text, re.DOTALL):
    try:
        obj = json.loads(block.strip())
        if isinstance(obj, dict):
            print(json.dumps(obj))
            sys.exit(0)
    except: pass

# 3: brace-matched extraction (handles nested JSON)
start = text.find("{")
if start >= 0:
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{": depth += 1
        elif text[i] == "}": depth -= 1
        if depth == 0:
            try:
                obj = json.loads(text[start:i+1])
                if isinstance(obj, dict):
                    print(json.dumps(obj))
                    sys.exit(0)
            except: pass
            break

sys.exit(1)
' <<< "$input" 2>/dev/null)
        if [[ -n "$result" ]]; then
            echo "$result"
            return 0
        fi
    fi

    # Fallback: sed + jq for simple cases (no python3)
    local stripped
    stripped=$(echo "$input" | sed -n '/^```json$/,/^```$/{//!p;}')
    if [[ -n "$stripped" ]] && echo "$stripped" | jq -e 'type == "object"' >/dev/null 2>&1; then
        echo "$stripped" | jq -c '.'
        return 0
    fi
    stripped=$(echo "$input" | sed -n '/^```$/,/^```$/{//!p;}')
    if [[ -n "$stripped" ]] && echo "$stripped" | jq -e 'type == "object"' >/dev/null 2>&1; then
        echo "$stripped" | jq -c '.'
        return 0
    fi

    return 1
}

# ── Unified LLM Invocation ──────────────────────────────────
# All 4 CLIs return structured JSON through one interface.
# Claude: --json-schema + --output-format json → .structured_output
# Gemini/Qwen: schema injected into prompt → _extract_json
# Codex: schema injected into prompt → _extract_json
#
# Usage: kodo_invoke_llm <cli> <prompt> [--schema <file>] [--timeout <s>]
#        [--repo <id>] [--domain <name>] [--max-turns <n>]
# Stdout: validated JSON object
# Exit: 0 = valid JSON returned, 1 = failure

kodo_invoke_llm() {
    local cli="$1" prompt="$2"
    shift 2

    local schema_file="" timeout_s=120 repo="" domain="" max_turns=3

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --schema)    schema_file="$2"; shift 2 ;;
            --timeout)   timeout_s="$2"; shift 2 ;;
            --repo)      repo="$2"; shift 2 ;;
            --domain)    domain="$2"; shift 2 ;;
            --max-turns) max_turns="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local schema_content=""
    if [[ -n "$schema_file" && -f "$schema_file" ]]; then
        schema_content="$(cat "$schema_file")"
    fi

    local raw_output="" result="" cost=0 tokens_in=0 tokens_out=0

    # Budget gate: check BEFORE invoking (prevents surprise bills)
    if ! kodo_check_budget "$cli"; then
        kodo_log "BUDGET: $cli call blocked for ${repo:-unknown}/${domain:-unknown}"
        return 1
    fi

    local llm_stderr_file
    llm_stderr_file=$(mktemp)

    case "$cli" in
        claude)
            if [[ -n "$schema_content" ]]; then
                raw_output=$(timeout "$timeout_s" claude -p "$prompt" \
                    --json-schema "$schema_content" \
                    --output-format json \
                    --max-turns "$max_turns" 2>"$llm_stderr_file") || {
                    local exit_code=$?
                    _llm_log_fail "$cli" "$repo" "$domain" "exit=$exit_code $(head -c 200 "$llm_stderr_file" 2>/dev/null)"
                    rm -f "$llm_stderr_file"; return 1
                }
                result=$(echo "$raw_output" | jq -c '.structured_output // empty' 2>/dev/null)
                [[ "$result" == "null" || -z "$result" ]] && {
                    _llm_log_fail "$cli" "$repo" "$domain" "no structured_output in response"
                    rm -f "$llm_stderr_file"; return 1
                }
            else
                raw_output=$(timeout "$timeout_s" claude -p "$prompt" \
                    --output-format json \
                    --max-turns "$max_turns" 2>"$llm_stderr_file") || {
                    local exit_code=$?
                    _llm_log_fail "$cli" "$repo" "$domain" "exit=$exit_code $(head -c 200 "$llm_stderr_file" 2>/dev/null)"
                    rm -f "$llm_stderr_file"; return 1
                }
                local text_result
                text_result=$(echo "$raw_output" | jq -r '.result // empty' 2>/dev/null)
                result=$(_extract_json "$text_result") || result=""
            fi
            cost=$(echo "$raw_output" | jq -r '.total_cost_usd // 0' 2>/dev/null)
            tokens_in=$(echo "$raw_output" | jq -r '.usage.input_tokens // 0' 2>/dev/null)
            tokens_out=$(echo "$raw_output" | jq -r '.usage.output_tokens // 0' 2>/dev/null)
            ;;
        gemini|qwen)
            local structured_prompt="$prompt"
            if [[ -n "$schema_content" ]]; then
                structured_prompt="${prompt}

CRITICAL INSTRUCTION: Respond with ONLY a raw JSON object. No markdown, no code fences, no explanation, no preamble. Output must be valid JSON matching this schema:
${schema_content}"
            fi
            raw_output=$(timeout "$timeout_s" "$cli" -p "$structured_prompt" 2>"$llm_stderr_file") || {
                local exit_code=$?
                _llm_log_fail "$cli" "$repo" "$domain" "exit=$exit_code $(head -c 200 "$llm_stderr_file" 2>/dev/null)"
                rm -f "$llm_stderr_file"; return 1
            }
            result=$(_extract_json "$raw_output") || {
                _llm_log_fail "$cli" "$repo" "$domain" "json extraction failed"
                rm -f "$llm_stderr_file"; return 1
            }
            ;;
        codex)
            local structured_prompt="$prompt"
            if [[ -n "$schema_content" ]]; then
                structured_prompt="${prompt}

Respond with ONLY valid JSON matching this schema: ${schema_content}"
            fi
            raw_output=$(timeout "$timeout_s" codex exec "$structured_prompt" 2>"$llm_stderr_file") || {
                local exit_code=$?
                _llm_log_fail "$cli" "$repo" "$domain" "exit=$exit_code $(head -c 200 "$llm_stderr_file" 2>/dev/null)"
                rm -f "$llm_stderr_file"; return 1
            }
            result=$(_extract_json "$raw_output") || {
                _llm_log_fail "$cli" "$repo" "$domain" "json extraction failed"
                rm -f "$llm_stderr_file"; return 1
            }
            cost=0.10
            ;;
        *) rm -f "$llm_stderr_file"; return 1 ;;
    esac

    rm -f "$llm_stderr_file"

    # Log budget
    if [[ -n "$repo" && -n "$domain" ]]; then
        kodo_log_budget "$cli" "$repo" "$domain" "$tokens_in" "$tokens_out" "$cost"
    fi

    [[ -z "$result" || "$result" == "null" ]] && return 1

    echo "$result"
    return 0
}

_llm_log_fail() {
    local cli="${1:-?}" repo="${2:-?}" domain="${3:-?}" reason="${4:-unknown}"
    kodo_log "LLM: $cli invocation failed (repo: $repo, domain: $domain, reason: $reason)"
    # Log failed attempts to budget_ledger for visibility (cost=0)
    if [[ "$repo" != "?" && "$domain" != "?" ]]; then
        kodo_log_budget "$cli" "$repo" "$domain" 0 0 0.0 2>/dev/null || true
    fi
}

# ── Pipeline Metadata ───────────────────────────────────────
# Inter-state data flow: engines store data (confidence, model, votes)
# that downstream states read. Not a state change — no transition needed.

kodo_pipeline_set() {
    local event_id="$1" domain="$2" key="$3" value="$4"
    # Validate key is a safe identifier (prevents SQL/JSON path injection)
    if [[ ! "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        kodo_log "ERROR: invalid pipeline metadata key: $key"
        return 1
    fi
    local eid dom
    eid="$(kodo_sql_escape "$event_id")"
    dom="$(kodo_sql_escape "$domain")"
    if [[ "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        # Numeric value
        kodo_sql "UPDATE pipeline_state
            SET metadata_json = json_set(COALESCE(metadata_json, '{}'), '\$.${key}', ${value})
            WHERE event_id = '${eid}' AND domain = '${dom}';"
    else
        # String value
        kodo_sql "UPDATE pipeline_state
            SET metadata_json = json_set(COALESCE(metadata_json, '{}'), '\$.${key}', '$(kodo_sql_escape "$value")')
            WHERE event_id = '${eid}' AND domain = '${dom}';"
    fi
}

kodo_pipeline_get() {
    local event_id="$1" domain="$2" key="$3"
    if [[ ! "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        kodo_log "ERROR: invalid pipeline metadata key: $key"
        return 1
    fi
    kodo_sql "SELECT json_extract(metadata_json, '\$.${key}')
        FROM pipeline_state
        WHERE event_id = '$(kodo_sql_escape "$event_id")' AND domain = '$(kodo_sql_escape "$domain")';"
}

# Ensure logs directory exists
mkdir -p "$KODO_LOG_DIR" 2>/dev/null || true
