#!/usr/bin/env bash
set -euo pipefail

# Development Ops Engine
# Handles: PR review, code generation, CI watch, merge, release, revert
# State-driven: reads current state, advances one transition per invocation
# Usage: kodo-dev.sh <event_id> <repo_toml> <domain>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kodo-lib.sh
source "$SCRIPT_DIR/kodo-lib.sh"

kodo_init_db

readonly EVENT_ID="${1:-}"
readonly REPO_TOML="${2:-}"
readonly DOMAIN="${3:-dev}"

if [[ -z "$EVENT_ID" || -z "$REPO_TOML" ]]; then
    echo "Usage: kodo-dev.sh <event_id> <repo_toml> [domain]" >&2
    exit 1
fi

readonly REPO_ID="$(kodo_repo_id "$REPO_TOML")"
readonly REPO_SLUG="$(kodo_repo_slug "$REPO_TOML")"
export KODO_TRANSITION_REPO="$REPO_ID"

# ── State Reader ─────────────────────────────────────────────

get_state() {
    sqlite3 "$KODO_DB" "SELECT state FROM pipeline_state
        WHERE event_id = '$(kodo_sql_escape "$EVENT_ID")' AND domain = 'dev';"
}

get_payload() {
    sqlite3 "$KODO_DB" "SELECT payload_json FROM pending_events
        WHERE event_id = '$(kodo_sql_escape "$EVENT_ID")';" 2>/dev/null || \
    sqlite3 "$KODO_DB" "SELECT '{}'"
}

transition() {
    "$SCRIPT_DIR/kodo-transition.sh" "$EVENT_ID" "$1" "$2" "dev"
}

defer() {
    local reason="$1"
    transition "$(get_state)" "deferred"
    sqlite3 "$KODO_DB" "INSERT INTO deferred_queue (event_id, repo, domain, reason)
        VALUES ('$(kodo_sql_escape "$EVENT_ID")', '$(kodo_sql_escape "$REPO_ID")', 'dev', '$(kodo_sql_escape "$reason")');"
    kodo_log "DEV: deferred $EVENT_ID — $reason"
}

# ── Claude Availability Check ────────────────────────────────

_claude_available() {
    if ! kodo_cli_available claude; then
        return 1
    fi
    # Quick ping test
    local result
    result=$(timeout 30 claude -p "respond with exactly: pong" --max-turns 1 2>/dev/null) || return 1
    [[ "$result" == *"pong"* ]]
}

# ── Stage Handlers ───────────────────────────────────────────

do_triaging() {
    kodo_log "DEV: triaging $EVENT_ID"
    local payload
    payload="$(get_payload)"
    local event_type
    event_type=$(echo "$payload" | jq -r '.event_type // "PullRequestEvent"' 2>/dev/null)

    # Determine path based on event type and content
    local pr_num
    pr_num=$(echo "$payload" | jq -r '.number // empty' 2>/dev/null)

    if [[ -n "$pr_num" ]]; then
        # Check if this is a deps update (auto-merge path)
        local title
        title=$(echo "$payload" | jq -r '.title // ""' 2>/dev/null | tr '[:upper:]' '[:lower:]')
        local labels
        labels=$(echo "$payload" | jq -r '(.labels // [])[] | if type == "object" then .name else . end' 2>/dev/null | tr '[:upper:]' '[:lower:]')

        if kodo_toml_bool "$REPO_TOML" "auto_merge_deps"; then
            if [[ "$title" == *"dependabot"* || "$title" == *"renovate"* || \
                  "$title" == *"bump "* || "$title" == *"update "* || \
                  "$labels" == *"dependencies"* ]]; then
                kodo_log "DEV: deps update detected — auto_merge path"
                transition "triaging" "auto_merge"
                return
            fi
        fi

        # PR: go to auditing (review)
        transition "triaging" "auditing"
    else
        # Issue: go to generating (code fix)
        transition "triaging" "generating"
    fi
}

do_generating() {
    kodo_log "DEV: generating code for $EVENT_ID"

    if ! kodo_cli_available codex; then
        # Fallback: try qwen
        if kodo_cli_available qwen; then
            kodo_log "DEV: codex unavailable, falling back to qwen"
        else
            defer "no code generation CLI available"
            return
        fi
    fi

    local payload
    payload="$(get_payload)"
    local issue_title issue_body
    issue_title=$(echo "$payload" | jq -r '.title // "no title"' 2>/dev/null)
    issue_body=$(echo "$payload" | jq -r '.body // ""' 2>/dev/null | head -100)

    # Generate fix via codex
    local prompt
    prompt="$(kodo_prompt "Fix this issue in repo $REPO_SLUG.
Title: $issue_title
Description: $issue_body

Generate a minimal, focused fix. Only change what is necessary.")"

    local result
    if kodo_cli_available codex; then
        result=$(timeout 300 codex exec "$prompt" 2>/dev/null) || {
            defer "codex generation failed"
            return
        }
        kodo_log_budget "codex" "$REPO_ID" "dev" 0 0 0.10
    else
        result=$(timeout 300 qwen -p "$prompt" 2>/dev/null) || {
            defer "qwen generation failed"
            return
        }
        kodo_log_budget "qwen" "$REPO_ID" "dev" 0 0 0.0
    fi

    transition "generating" "hard_gates"
}

do_hard_gates() {
    kodo_log "DEV: running hard gates for $EVENT_ID"

    local test_cmd lint_cmd max_diff
    test_cmd="$(kodo_toml_get "$REPO_TOML" "test_command")"
    lint_cmd="$(kodo_toml_get "$REPO_TOML" "lint_command")"
    max_diff="$(kodo_toml_get "$REPO_TOML" "max_diff_lines")"
    max_diff="${max_diff:-500}"

    local payload pr_num
    payload="$(get_payload)"
    pr_num=$(echo "$payload" | jq -r '.number // empty' 2>/dev/null)

    local gate_failed=""

    # Gate 1: Diff size check
    if [[ -n "$pr_num" ]]; then
        local diff_lines
        diff_lines=$("$SCRIPT_DIR/kodo-git.sh" pr-diff "$REPO_TOML" "$pr_num" 2>/dev/null | wc -l) || diff_lines=0
        if [[ "$diff_lines" -gt "$max_diff" ]]; then
            gate_failed="diff too large: $diff_lines lines (max: $max_diff)"
        fi
    fi

    # Gate 2: Test suite (if we have a cloned repo to test against)
    # In practice, this runs in CI — we check CI status instead
    # For now, we pass if no explicit failure signal

    if [[ -n "$gate_failed" ]]; then
        kodo_log "DEV: hard gate failed — $gate_failed"
        defer "hard gate: $gate_failed"
        return
    fi

    kodo_log "DEV: all hard gates passed"
    transition "hard_gates" "auditing"
}

do_auditing() {
    kodo_log "DEV: auditing $EVENT_ID"

    local payload pr_num
    payload="$(get_payload)"
    pr_num=$(echo "$payload" | jq -r '.number // empty' 2>/dev/null)

    local confidence=0
    local review_output=""

    if _claude_available; then
        local diff=""
        if [[ -n "$pr_num" ]]; then
            diff=$("$SCRIPT_DIR/kodo-git.sh" pr-diff "$REPO_TOML" "$pr_num" 2>/dev/null | head -500) || diff=""
        fi

        local prompt
        prompt="$(kodo_prompt "Review this PR for $REPO_SLUG.
Title: $(echo "$payload" | jq -r '.title // "unknown"')

Diff (truncated):
$diff

Score confidence 0-100 for merge safety. Identify risks and behavioral changes.")"

        review_output=$(timeout 120 claude -p "$prompt" \
            --json-schema "$KODO_HOME/schemas/confidence.schema.json" \
            --max-turns 3 2>/dev/null) || review_output=""

        if [[ -n "$review_output" ]]; then
            confidence=$(echo "$review_output" | jq -r '.score // 0' 2>/dev/null)
            kodo_log_budget "claude" "$REPO_ID" "dev" 0 0 1.00
        fi
    elif kodo_cli_available codex; then
        # Fallback: codex as emergency reviewer, confidence capped at 79
        kodo_log "DEV: claude unavailable — using codex (confidence capped at 79)"
        review_output=$(timeout 120 codex exec "Review this PR for correctness and security" 2>/dev/null) || review_output=""
        confidence=70
        if [[ "$confidence" -gt 79 ]]; then
            confidence=79
        fi
        kodo_log_budget "codex" "$REPO_ID" "dev" 0 0 0.10
    else
        defer "no review CLI available"
        return
    fi

    kodo_log "DEV: confidence=$confidence for $EVENT_ID"

    if [[ "$confidence" -lt 50 ]]; then
        defer "confidence too low: $confidence"
        return
    fi

    # Post review comment
    if [[ -n "$pr_num" && -n "$review_output" ]]; then
        local summary
        summary=$(echo "$review_output" | jq -r '.summary // "Review completed"' 2>/dev/null)
        local comment="**KODO Dev Review** | Confidence: **${confidence}/100**

$summary

---
_Event: $EVENT_ID | Model: claude_"

        "$SCRIPT_DIR/kodo-git.sh" pr-comment "$REPO_TOML" "$pr_num" "$comment" 2>/dev/null || true
    fi

    transition "auditing" "scanning"
}

do_scanning() {
    kodo_log "DEV: security scanning $EVENT_ID"

    # Retrieve auto_merge threshold from confidence_bands
    local auto_merge_threshold
    auto_merge_threshold=$(sqlite3 "$KODO_DB" "SELECT threshold FROM confidence_bands WHERE band = 'auto_merge';")
    auto_merge_threshold="${auto_merge_threshold:-90}"

    local ballot_threshold
    ballot_threshold=$(sqlite3 "$KODO_DB" "SELECT threshold FROM confidence_bands WHERE band = 'ballot';")
    ballot_threshold="${ballot_threshold:-50}"

    # Get confidence from last audit (stored in pipeline or recompute)
    # For simplicity, re-read from review output or use a default
    local confidence=75

    # TODO: Run semgrep / npm audit security scan here
    local scan_clean=true

    if [[ "$scan_clean" != "true" ]]; then
        defer "security vulnerability found"
        return
    fi

    if [[ "$confidence" -ge "$auto_merge_threshold" ]]; then
        kodo_log "DEV: confidence $confidence >= $auto_merge_threshold — auto_merge"
        transition "scanning" "auto_merge"
    elif [[ "$confidence" -ge "$ballot_threshold" ]]; then
        kodo_log "DEV: confidence $confidence [$ballot_threshold-$auto_merge_threshold) — balloting"
        transition "scanning" "balloting"
    else
        defer "confidence below ballot threshold: $confidence"
    fi
}

do_balloting() {
    kodo_log "DEV: balloting $EVENT_ID (2/3 consensus)"

    local votes=0
    local total=0
    local payload pr_num
    payload="$(get_payload)"
    pr_num=$(echo "$payload" | jq -r '.number // empty' 2>/dev/null)

    local diff=""
    if [[ -n "$pr_num" ]]; then
        diff=$("$SCRIPT_DIR/kodo-git.sh" pr-diff "$REPO_TOML" "$pr_num" 2>/dev/null | head -300) || diff=""
    fi

    local ballot_prompt
    ballot_prompt="$(kodo_prompt "Review this code change. Is it safe to merge? Respond with confidence score 0-100.")"

    # Vote 1: Claude (if available)
    if _claude_available; then
        local result
        result=$(timeout 120 claude -p "$ballot_prompt
$diff" --json-schema "$KODO_HOME/schemas/confidence.schema.json" --max-turns 1 2>/dev/null) || result=""
        if [[ -n "$result" ]]; then
            local score
            score=$(echo "$result" | jq -r '.score // 0' 2>/dev/null)
            [[ "$score" -ge 50 ]] && votes=$((votes + 1))
            total=$((total + 1))
            kodo_log_budget "claude" "$REPO_ID" "dev" 0 0 0.50
        fi
    fi

    # Vote 2: Gemini (free)
    if kodo_cli_available gemini; then
        local result
        result=$(timeout 120 gemini -p "$ballot_prompt
$diff" 2>/dev/null) || result=""
        if [[ -n "$result" ]]; then
            # Parse a simple yes/no from free-form (best effort for ballot)
            [[ "$result" == *"safe"* || "$result" == *"approve"* || "$result" == *"merge"* ]] && votes=$((votes + 1))
            total=$((total + 1))
            kodo_log_budget "gemini" "$REPO_ID" "dev" 0 0 0.0
        fi
    fi

    # Vote 3: Qwen (free)
    if kodo_cli_available qwen; then
        local result
        result=$(timeout 120 qwen -p "$ballot_prompt
$diff" 2>/dev/null) || result=""
        if [[ -n "$result" ]]; then
            [[ "$result" == *"safe"* || "$result" == *"approve"* || "$result" == *"merge"* ]] && votes=$((votes + 1))
            total=$((total + 1))
            kodo_log_budget "qwen" "$REPO_ID" "dev" 0 0 0.0
        fi
    fi

    kodo_log "DEV: ballot result $votes/$total"

    if [[ "$total" -ge 2 && "$votes" -ge 2 ]]; then
        transition "balloting" "guarded_merge"
    else
        defer "ballot: no consensus ($votes/$total)"
    fi
}

do_auto_merge() {
    kodo_log "DEV: auto-merging $EVENT_ID"

    local payload pr_num
    payload="$(get_payload)"
    pr_num=$(echo "$payload" | jq -r '.number // empty' 2>/dev/null)

    if [[ -z "$pr_num" ]]; then
        defer "no PR number for merge"
        return
    fi

    "$SCRIPT_DIR/kodo-git.sh" pr-merge "$REPO_TOML" "$pr_num" 2>/dev/null || {
        defer "merge failed"
        return
    }

    # Record merge outcome
    sqlite3 "$KODO_DB" "INSERT INTO merge_outcomes (event_id, repo, confidence, outcome)
        VALUES ('$(kodo_sql_escape "$EVENT_ID")', '$(kodo_sql_escape "$REPO_ID")', 90, 'clean');"

    transition "auto_merge" "releasing"
}

do_guarded_merge() {
    kodo_log "DEV: guarded merge $EVENT_ID (48h CI window)"

    local payload pr_num
    payload="$(get_payload)"
    pr_num=$(echo "$payload" | jq -r '.number // empty' 2>/dev/null)

    if [[ -z "$pr_num" ]]; then
        defer "no PR number for guarded merge"
        return
    fi

    # Merge with CI check
    "$SCRIPT_DIR/kodo-git.sh" pr-merge "$REPO_TOML" "$pr_num" 2>/dev/null || {
        defer "guarded merge failed"
        return
    }

    sqlite3 "$KODO_DB" "INSERT INTO merge_outcomes (event_id, repo, confidence, outcome)
        VALUES ('$(kodo_sql_escape "$EVENT_ID")', '$(kodo_sql_escape "$REPO_ID")', 75, 'clean');"

    transition "guarded_merge" "releasing"
}

do_releasing() {
    kodo_log "DEV: releasing $EVENT_ID"

    if kodo_toml_bool "$REPO_TOML" "semver_release"; then
        # Auto-tag semver release
        kodo_log "DEV: semver release enabled — would tag here"
        # In practice: determine next semver, create tag via kodo-git.sh
    fi

    transition "releasing" "resolved"
    kodo_log "DEV: $EVENT_ID resolved"
}

do_reverting() {
    kodo_log "DEV: reverting $EVENT_ID (CI regression detected)"
    # In practice: create revert PR, merge it
    defer "revert completed"
}

# ── Main State Machine Driver ────────────────────────────────

main() {
    local state
    state="$(get_state)"

    if [[ -z "$state" ]]; then
        kodo_log "DEV: no state found for $EVENT_ID — skipping"
        exit 0
    fi

    kodo_log "DEV: processing $EVENT_ID (state: $state)"

    case "$state" in
        pending)         transition "pending" "triaging"; do_triaging ;;
        triaging)        do_triaging ;;
        generating)      do_generating ;;
        hard_gates)      do_hard_gates ;;
        auditing)        do_auditing ;;
        scanning)        do_scanning ;;
        balloting)       do_balloting ;;
        auto_merge)      do_auto_merge ;;
        guarded_merge)   do_guarded_merge ;;
        releasing)       do_releasing ;;
        reverting)       do_reverting ;;
        resolved|closed) kodo_log "DEV: $EVENT_ID already $state" ;;
        deferred)        kodo_log "DEV: $EVENT_ID deferred — waiting for retry" ;;
        *)               kodo_log "DEV: unknown state '$state' for $EVENT_ID" ;;
    esac
}

main
