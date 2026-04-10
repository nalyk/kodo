#!/usr/bin/env bash
set -euo pipefail

# Mock CLI — replaces claude, codex, qwen, gemini, semgrep
# Symlinked under each name. Uses $0 basename to determine identity.
# Returns fixture-driven responses matching each CLI's output format.

CLI_NAME="$(basename "$0")"
FIXTURE_DIR="${KODO_FIXTURE_DIR:-}"
SCENARIO="${KODO_FIXTURE_SCENARIO:-default}"

# Fixture file for this CLI in the current scenario
_fixture_file() {
    local name="$1"
    echo "${FIXTURE_DIR}/${SCENARIO}/cli-${name}.json"
}

# ── semgrep mock ────────────────────────────────────────────

if [[ "$CLI_NAME" == "semgrep" ]]; then
    fixture="$(_fixture_file semgrep)"
    if [[ -f "$fixture" ]]; then
        cat "$fixture"
    else
        # Default: no findings
        echo '{"results":[]}'
    fi
    exit 0
fi

# ── LLM CLI mocks ──────────────────────────────────────────

fixture="$(_fixture_file "$CLI_NAME")"

# Parse arguments to understand what format the caller expects
has_json_schema=false
has_output_json=false
has_full_auto=false
cd_dir=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json-schema)  has_json_schema=true; shift 2 || shift ;;
        --output-format)
            [[ "${2:-}" == "json" ]] && has_output_json=true
            shift 2 || shift
            ;;
        --full-auto)    has_full_auto=true; shift ;;
        --cd)           cd_dir="${2:-}"; shift 2 || shift ;;
        -p)             shift 2 || shift ;;  # skip prompt text
        *)              shift ;;
    esac
done

# Load fixture response (the structured JSON the engine expects)
fixture_content=""
if [[ -f "$fixture" ]]; then
    fixture_content="$(cat "$fixture")"
fi

case "$CLI_NAME" in
    claude)
        # Claude with --json-schema + --output-format json wraps in structured_output
        if $has_json_schema && $has_output_json; then
            if [[ -n "$fixture_content" ]]; then
                # Wrap fixture as claude's structured output format
                printf '{"result":"","structured_output":%s,"total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":50}}' "$fixture_content"
            else
                printf '{"result":"","structured_output":{"score":85,"summary":"mock review","risks":[]},"total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":50}}'
            fi
        elif $has_output_json; then
            # Claude with --output-format json but no schema (Phase A plan)
            if [[ -n "$fixture_content" ]]; then
                printf '{"result":%s,"total_cost_usd":0.30,"usage":{"input_tokens":500,"output_tokens":200}}' "$(echo "$fixture_content" | jq -Rs '.')"
            else
                printf '{"result":"Implementation plan: modify src/index.ts to fix the bug.","total_cost_usd":0.30,"usage":{"input_tokens":500,"output_tokens":200}}'
            fi
        else
            echo "${fixture_content:-pong}"
        fi
        ;;
    codex)
        # Codex exec --full-auto: if fixture has codex-changes dir, simulate file edits
        if $has_full_auto && [[ -n "$cd_dir" ]]; then
            local_changes="${FIXTURE_DIR}/${SCENARIO}/codex-changes"
            if [[ -d "$local_changes" ]]; then
                cp -r "$local_changes"/* "$cd_dir/" 2>/dev/null || true
            fi
        fi
        echo "${fixture_content:-}"
        ;;
    qwen|gemini)
        # Free-tier CLIs: return raw text that _extract_json can parse
        if [[ -n "$fixture_content" ]]; then
            echo "$fixture_content"
        else
            echo '{"score":70,"summary":"mock review","risks":[]}'
        fi
        ;;
esac

exit 0
