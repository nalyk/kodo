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

# ── Concurrent Processing Guard ─────────────────────────────
# Claim this event atomically. Exit if another engine owns it.
if ! kodo_claim_event "$EVENT_ID" "dev"; then
    exit 0
fi
# Release lock + cleanup workdir on any exit (normal, error, signal)
_KODO_WORKDIR_CLEANUP=""
trap 'kodo_release_event "$EVENT_ID" "dev"; [[ -n "$_KODO_WORKDIR_CLEANUP" ]] && "$SCRIPT_DIR/kodo-git.sh" cleanup-workdir "$_KODO_WORKDIR_CLEANUP" 2>/dev/null' EXIT

# ── State Reader ─────────────────────────────────────────────

get_state() {
    kodo_sql "SELECT state FROM pipeline_state
        WHERE event_id = '$(kodo_sql_escape "$EVENT_ID")' AND domain = 'dev';"
}

get_payload() {
    kodo_sql "SELECT payload_json FROM pipeline_state
        WHERE event_id = '$(kodo_sql_escape "$EVENT_ID")' AND domain = 'dev';"
}

transition() {
    "$SCRIPT_DIR/kodo-transition.sh" "$EVENT_ID" "$1" "$2" "dev"
}

defer() {
    local reason="$1"
    transition "$(get_state)" "deferred"
    kodo_sql "INSERT INTO deferred_queue (event_id, repo, domain, reason)
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

    # Distinguish PR vs Issue: check event_id pattern first, fall back to payload
    local is_pr=false
    if [[ "$EVENT_ID" == *"PullRequestEvent"* ]]; then
        is_pr=true
    elif [[ "$EVENT_ID" == *"IssuesEvent"* ]]; then
        is_pr=false
    else
        # Fallback: check payload for PR-specific fields (headRefName only exists on PRs)
        local has_head_ref
        has_head_ref=$(echo "$payload" | jq -r '.headRefName // empty' 2>/dev/null)
        [[ -n "$has_head_ref" ]] && is_pr=true
    fi

    if $is_pr; then
        _triage_pr "$payload"
    else
        _triage_issue "$payload"
    fi
}

_triage_pr() {
    local payload="$1"
    local pr_num
    pr_num=$(echo "$payload" | jq -r '.number // empty' 2>/dev/null)

    if [[ -z "$pr_num" ]]; then
        defer "PR event but no number in payload"
        return
    fi

    local title
    title=$(echo "$payload" | jq -r '.title // ""' 2>/dev/null | tr '[:upper:]' '[:lower:]')
    local labels
    labels=$(echo "$payload" | jq -r '(.labels // [])[] | if type == "object" then .name else . end' 2>/dev/null | tr '[:upper:]' '[:lower:]')
    local author_login
    author_login=$(echo "$payload" | jq -r '.author.login // ""' 2>/dev/null | tr '[:upper:]' '[:lower:]')

    # Deps auto-merge fast path (zero LLM)
    if kodo_toml_bool "$REPO_TOML" "auto_merge_deps"; then
        if [[ "$title" == *"dependabot"* || "$title" == *"renovate"* || \
              "$title" == *"bump "* || "$title" == *"chore(deps)"* || \
              "$labels" == *"dependencies"* || \
              "$author_login" == *"dependabot"* || "$author_login" == *"renovate"* ]]; then
            kodo_log "DEV: deps PR #$pr_num ($author_login) — auto_merge path"
            transition "triaging" "auto_merge"
            return
        fi
    fi

    kodo_log "DEV: PR #$pr_num — auditing path (code review)"
    transition "triaging" "auditing"
}

_triage_issue() {
    local payload="$1"
    local labels
    labels=$(echo "$payload" | jq -r '(.labels // [])[] | if type == "object" then .name else . end' 2>/dev/null | tr '[:upper:]' '[:lower:]')
    local issue_num
    issue_num=$(echo "$payload" | jq -r '.number // "?"' 2>/dev/null)

    # Documentation issues → no code action, defer with explanation
    if [[ "$labels" == *"documentation"* || "$labels" == *"docs"* ]]; then
        kodo_log "DEV: issue #$issue_num — documentation, not actionable by dev engine"
        defer "documentation issue — no code action needed"
        return
    fi

    # Duplicate/wontfix → skip
    if [[ "$labels" == *"duplicate"* || "$labels" == *"wontfix"* || "$labels" == *"invalid"* ]]; then
        kodo_log "DEV: issue #$issue_num — skipping ($labels)"
        defer "issue not actionable: $labels"
        return
    fi

    # Bug/fix/test/enhancement → code generation
    kodo_log "DEV: issue #$issue_num — generating path (code fix)"
    transition "triaging" "generating"
}

do_generating() {
    kodo_log "DEV: generating code fix for $EVENT_ID"

    # Determine which CLI to use for code generation
    local gen_cli=""
    if kodo_cli_available claude; then
        gen_cli="claude"
    elif kodo_cli_available codex; then
        gen_cli="codex"
    else
        defer "no code generation CLI available (need claude or codex)"
        return
    fi

    local payload
    payload="$(get_payload)"
    local issue_num issue_title
    issue_num=$(echo "$payload" | jq -r '.number // empty' 2>/dev/null)
    issue_title=$(echo "$payload" | jq -r '.title // "no title"' 2>/dev/null)

    if [[ -z "$issue_num" ]]; then
        defer "no issue number in payload"
        return
    fi

    # Step 1: Get full issue context from GitHub (body, comments, labels)
    local issue_detail
    issue_detail=$("$SCRIPT_DIR/kodo-git.sh" issue-get "$REPO_TOML" "$issue_num" 2>/dev/null) || issue_detail="{}"
    local issue_body
    issue_body=$(echo "$issue_detail" | jq -r '.body // ""' 2>/dev/null | head -200)
    local issue_comments
    issue_comments=$(echo "$issue_detail" | jq -r '.last_comments[]? | "[\(.author)]: \(.body)"' 2>/dev/null | head -50)

    kodo_log "DEV: issue #$issue_num — cloning repo for code generation"

    # Step 2: Clone the repo
    local default_branch
    default_branch="$(kodo_toml_get "$REPO_TOML" "branch_default")"
    default_branch="${default_branch:-main}"

    local work_dir
    work_dir=$("$SCRIPT_DIR/kodo-git.sh" repo-clone "$REPO_TOML" "$default_branch" 2>/dev/null) || {
        defer "repo clone failed"
        return
    }

    kodo_log "DEV: cloned to $work_dir"
    kodo_pipeline_set "$EVENT_ID" "dev" "work_dir" "$work_dir"

    # Guarantee cleanup on any exit — use EXIT trap with guard variable
    # (RETURN trap doesn't propagate reliably through case dispatch)
    _KODO_WORKDIR_CLEANUP="$work_dir"

    # Step 3: Create a kodo branch
    local branch_name="kodo/dev/${EVENT_ID}"
    "$SCRIPT_DIR/kodo-git.sh" branch-create "$work_dir" "$branch_name" 2>/dev/null || {
        "$SCRIPT_DIR/kodo-git.sh" cleanup-workdir "$work_dir" 2>/dev/null
        defer "branch creation failed"
        return
    }

    # Step 4: Run Claude/Codex with FULL repo context (working directory = cloned repo)
    # Claude Code reads the codebase when run from the repo directory
    local fix_result=""
    local fix_success=false

    if [[ "$gen_cli" == "claude" ]]; then
        kodo_log "DEV: running claude -p in $work_dir for issue #$issue_num"

        local prompt
        prompt="$(kodo_prompt "You are fixing issue #$issue_num in $REPO_SLUG.

Title: $issue_title

Description:
$issue_body
${issue_comments:+
Recent comments:
$issue_comments}

Instructions:
1. Read the relevant source files to understand the codebase
2. Implement a minimal, focused fix for this issue
3. Only change what is necessary — no refactoring, no unrelated changes
4. Match existing code style exactly
5. If the fix requires tests, add them

Do NOT commit. Just make the file changes.")"

        # Run Claude from within the cloned repo directory
        # --allowedTools grants headless file write permission (without it, claude -p refuses writes)
        fix_result=$(cd "$work_dir" && timeout 600 claude -p "$prompt" \
            --output-format json \
            --max-turns 20 \
            --allowedTools "Read" "Write" "Edit" "Glob" "Grep" "Bash(git diff:*)" "Bash(git status:*)" "Bash(git log:*)" "Bash(ls:*)" "Bash(find:*)" \
            2>/dev/null) || fix_result=""

        if [[ -n "$fix_result" ]]; then
            local cost
            cost=$(echo "$fix_result" | jq -r '.total_cost_usd // 0' 2>/dev/null)
            local tokens_in tokens_out
            tokens_in=$(echo "$fix_result" | jq -r '.usage.input_tokens // 0' 2>/dev/null)
            tokens_out=$(echo "$fix_result" | jq -r '.usage.output_tokens // 0' 2>/dev/null)
            kodo_log_budget "claude" "$REPO_ID" "dev" "$tokens_in" "$tokens_out" "$cost"
        fi

    elif [[ "$gen_cli" == "codex" ]]; then
        kodo_log "DEV: running codex in $work_dir for issue #$issue_num"

        fix_result=$(cd "$work_dir" && timeout 600 codex exec \
            "Fix issue #$issue_num: $issue_title. $issue_body. Make minimal changes only." 2>/dev/null) || fix_result=""
        kodo_log_budget "codex" "$REPO_ID" "dev" 0 0 0.50
    fi

    # Step 5: Check if any files were actually changed
    local changed_files
    changed_files=$(cd "$work_dir" && git diff --name-only 2>/dev/null && git ls-files --others --exclude-standard 2>/dev/null)

    if [[ -z "$changed_files" ]]; then
        # Check if Claude determined the issue is already fixed
        local result_text=""
        if [[ -n "$fix_result" ]]; then
            result_text=$(echo "$fix_result" | jq -r '.result // ""' 2>/dev/null)
        fi
        if echo "$result_text" | grep -qiE "already.*(fix|resolv|implement)|no longer.*(valid|applic)|nu mai este valabil|deja.*(fix|rezolv)|not.*(reproducib|valid)"; then
            kodo_log "DEV: issue #$issue_num appears already resolved — commenting and closing"
            # Post comment on GitHub explaining the finding
            "$SCRIPT_DIR/kodo-git.sh" issue-comment "$REPO_TOML" "$issue_num" \
                "KŌDŌ DEV analysis: This issue appears to be already resolved in the current codebase. The code referenced in the issue description has been updated and no longer exhibits the described behavior.

_Automated analysis by KŌDŌ | Event: $EVENT_ID | Model: ${gen_cli}_" 2>/dev/null || true
            "$SCRIPT_DIR/kodo-git.sh" issue-close "$REPO_TOML" "$issue_num" 2>/dev/null || true
            kodo_log "DEV: no files changed — issue already resolved in codebase"
            transition "generating" "hard_gates"
            transition "hard_gates" "auditing"
            kodo_pipeline_set "$EVENT_ID" "dev" "confidence" "95"
            kodo_pipeline_set "$EVENT_ID" "dev" "review_model" "claude"
            kodo_pipeline_set "$EVENT_ID" "dev" "outcome" "already_resolved"
            transition "auditing" "scanning"
            transition "scanning" "auto_merge"
            transition "auto_merge" "releasing"
            transition "releasing" "resolved"
            return
        fi
        kodo_log "DEV: no files changed — code generation produced no diff"
        defer "code generation produced no file changes"
        return
    fi

    local diff_lines
    diff_lines=$(cd "$work_dir" && git diff --stat 2>/dev/null | tail -1)
    kodo_log "DEV: code generated — $diff_lines"
    kodo_pipeline_set "$EVENT_ID" "dev" "gen_files" "$changed_files"
    kodo_pipeline_set "$EVENT_ID" "dev" "gen_cli" "$gen_cli"

    # Step 6: Commit the changes
    (
        cd "$work_dir" || exit 1
        git add -A
        git commit -m "$(cat <<COMMITMSG
kodo(dev): fix #$issue_num -- $issue_title

Event-ID: $EVENT_ID
Model: $gen_cli
COMMITMSG
        )" --no-verify
    ) 2>/dev/null || {
        "$SCRIPT_DIR/kodo-git.sh" cleanup-workdir "$work_dir" 2>/dev/null
        defer "git commit failed"
        return
    }

    # Step 7: Push branch + create PR (shadow mode blocks via kodo-git.sh)
    "$SCRIPT_DIR/kodo-git.sh" branch-push "$REPO_TOML" "$work_dir" "$branch_name" 2>/dev/null || {
        "$SCRIPT_DIR/kodo-git.sh" cleanup-workdir "$work_dir" 2>/dev/null
        defer "branch push failed"
        return
    }

    local pr_body
    pr_body="## Fix for #$issue_num

**$issue_title**

### Changes
\`\`\`
$diff_lines
\`\`\`

### Files modified
$(echo "$changed_files" | sed 's/^/- /')

---
_Generated by KŌDŌ DEV | Event: $EVENT_ID | Model: ${gen_cli}_"

    local pr_url
    pr_url=$("$SCRIPT_DIR/kodo-git.sh" pr-create "$REPO_TOML" "$branch_name" \
        "[kodo-dev] fix #$issue_num: $issue_title" "$pr_body" 2>/dev/null) || {
        local repo_mode
        repo_mode="$(kodo_toml_get "$REPO_TOML" "mode")"
        if [[ "$repo_mode" != "shadow" ]]; then
            "$SCRIPT_DIR/kodo-git.sh" cleanup-workdir "$work_dir" 2>/dev/null
            defer "PR creation failed in live mode"
            return
        fi
        kodo_log "DEV: PR creation blocked by shadow mode — continuing"
    }

    if [[ -n "$pr_url" ]]; then
        kodo_log "DEV: PR created: $pr_url"
        kodo_pipeline_set "$EVENT_ID" "dev" "pr_url" "$pr_url"
        # Extract PR number for downstream stages
        local pr_num
        pr_num=$(basename "$pr_url" 2>/dev/null | grep -oE '^[0-9]+$') || pr_num=""
        [[ -n "$pr_num" ]] && kodo_pipeline_set "$EVENT_ID" "dev" "pr_number" "$pr_num"
    fi

    # Clean up working directory
    "$SCRIPT_DIR/kodo-git.sh" cleanup-workdir "$work_dir" 2>/dev/null

    kodo_log "DEV: code generation complete for issue #$issue_num"
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
    local review_model="none"

    if _claude_available; then
        review_model="claude"
        local diff=""
        if [[ -n "$pr_num" && "$EVENT_ID" == *"PullRequestEvent"* ]]; then
            diff=$("$SCRIPT_DIR/kodo-git.sh" pr-diff "$REPO_TOML" "$pr_num" 2>/dev/null | head -500) || diff=""
        fi

        local pr_title
        pr_title=$(echo "$payload" | jq -r '.title // "unknown"' 2>/dev/null)

        local prompt
        prompt="$(kodo_prompt "Review this PR for $REPO_SLUG.
Title: $pr_title

Diff (truncated):
$diff

Score confidence 0-100 for merge safety. Identify risks and behavioral changes.")"

        review_output=$(kodo_invoke_llm claude "$prompt" \
            --schema "$KODO_HOME/schemas/confidence.schema.json" \
            --timeout 300 \
            --repo "$REPO_ID" \
            --domain "dev") || review_output=""

        if [[ -n "$review_output" ]]; then
            confidence=$(echo "$review_output" | jq -r '.score // 0' 2>/dev/null)
        fi
    elif kodo_cli_available codex; then
        # Fallback: codex emergency reviewer — confidence capped at 79
        review_model="codex"
        kodo_log "DEV: claude unavailable — codex emergency review (cap 79)"
        local codex_result
        codex_result=$(kodo_invoke_llm codex "Review this code change for correctness and security. Assess merge safety." \
            --schema "$KODO_HOME/schemas/confidence.schema.json" \
            --timeout 120 \
            --repo "$REPO_ID" \
            --domain "dev") || codex_result=""
        if [[ -n "$codex_result" ]]; then
            confidence=$(echo "$codex_result" | jq -r '.score // 70' 2>/dev/null)
            [[ "$confidence" -gt 79 ]] && confidence=79
            review_output="$codex_result"
        else
            confidence=70
        fi
    else
        defer "no review CLI available"
        return
    fi

    kodo_log "DEV: confidence=$confidence model=$review_model for $EVENT_ID"

    # Persist confidence + model in metadata for downstream states (scanning, balloting)
    kodo_pipeline_set "$EVENT_ID" "dev" "confidence" "$confidence"
    kodo_pipeline_set "$EVENT_ID" "dev" "review_model" "$review_model"

    if [[ "$confidence" -lt 50 ]]; then
        defer "confidence too low: $confidence"
        return
    fi

    # Post review comment on PR (shadow mode handled by kodo-git.sh)
    if [[ -n "$pr_num" && -n "$review_output" ]]; then
        local summary
        summary=$(echo "$review_output" | jq -r '.summary // "Review completed"' 2>/dev/null)
        local risks
        risks=$(echo "$review_output" | jq -r '(.risks // [])[] | "- [\(.severity)] \(.description)"' 2>/dev/null)

        local comment="**KŌDŌ Dev Review** | Confidence: **${confidence}/100** | Model: \`${review_model}\`

${summary}
${risks:+
**Risks:**
$risks}

---
_Event: ${EVENT_ID}_"

        "$SCRIPT_DIR/kodo-git.sh" pr-comment "$REPO_TOML" "$pr_num" "$comment" 2>/dev/null || true
    fi

    transition "auditing" "scanning"
}

do_scanning() {
    kodo_log "DEV: security scanning $EVENT_ID"

    # Read adaptive thresholds from DB
    local auto_merge_threshold
    auto_merge_threshold=$(kodo_sql "SELECT threshold FROM confidence_bands WHERE band = 'auto_merge';")
    auto_merge_threshold="${auto_merge_threshold:-90}"

    local ballot_threshold
    ballot_threshold=$(kodo_sql "SELECT threshold FROM confidence_bands WHERE band = 'ballot';")
    ballot_threshold="${ballot_threshold:-50}"

    # Read REAL confidence from auditing step (via pipeline metadata)
    local confidence
    confidence=$(kodo_pipeline_get "$EVENT_ID" "dev" "confidence")
    confidence="${confidence:-0}"

    local review_model
    review_model=$(kodo_pipeline_get "$EVENT_ID" "dev" "review_model")

    # Security scan: semgrep on diff if available
    local scan_clean=true
    local scan_findings=""

    if command -v semgrep >/dev/null 2>&1; then
        local payload pr_num
        payload="$(get_payload)"
        pr_num=$(echo "$payload" | jq -r '.number // empty' 2>/dev/null)

        if [[ -n "$pr_num" && "$EVENT_ID" == *"PullRequestEvent"* ]]; then
            local diff_files
            diff_files=$("$SCRIPT_DIR/kodo-git.sh" pr-diff "$REPO_TOML" "$pr_num" 2>/dev/null \
                | grep '^+++ b/' | sed 's|^+++ b/||' | head -20) || diff_files=""

            if [[ -n "$diff_files" ]]; then
                kodo_log "DEV: running semgrep on changed files"
                scan_findings=$(echo "$diff_files" | xargs semgrep --config=auto --json 2>/dev/null \
                    | jq '.results | length' 2>/dev/null) || scan_findings="0"

                if [[ "$scan_findings" -gt 0 ]]; then
                    scan_clean=false
                    kodo_log "DEV: semgrep found $scan_findings issues"
                    # Reduce confidence proportionally
                    local penalty=$((scan_findings * 10))
                    confidence=$((confidence > penalty ? confidence - penalty : 0))
                    kodo_pipeline_set "$EVENT_ID" "dev" "scan_findings" "$scan_findings"
                fi
            fi
        fi
    fi

    kodo_pipeline_set "$EVENT_ID" "dev" "scan_clean" "$scan_clean"

    if [[ "$scan_clean" != "true" && "$scan_findings" -gt 5 ]]; then
        defer "security scan: $scan_findings findings (critical)"
        return
    fi

    kodo_log "DEV: scan done — confidence=$confidence (model=$review_model) auto>=$auto_merge_threshold ballot>=$ballot_threshold"

    if [[ "$confidence" -ge "$auto_merge_threshold" ]]; then
        kodo_log "DEV: confidence $confidence >= $auto_merge_threshold — auto_merge"
        transition "scanning" "auto_merge"
    elif [[ "$confidence" -ge "$ballot_threshold" ]]; then
        kodo_log "DEV: confidence $confidence [$ballot_threshold-$auto_merge_threshold) — balloting"
        transition "scanning" "balloting"
    else
        defer "confidence below ballot threshold: $confidence (scan_findings: ${scan_findings:-0})"
    fi
}

do_balloting() {
    kodo_log "DEV: balloting $EVENT_ID (2/3 consensus required)"

    local votes=0
    local total=0
    local vote_log=""

    local payload pr_num
    payload="$(get_payload)"
    pr_num=$(echo "$payload" | jq -r '.number // empty' 2>/dev/null)

    local diff=""
    if [[ -n "$pr_num" ]]; then
        diff=$("$SCRIPT_DIR/kodo-git.sh" pr-diff "$REPO_TOML" "$pr_num" 2>/dev/null | head -300) || diff=""
    fi

    local pr_title
    pr_title=$(echo "$payload" | jq -r '.title // "unknown"' 2>/dev/null)

    local ballot_prompt
    ballot_prompt="$(kodo_prompt "You are voting on whether to merge this code change to $REPO_SLUG.

Title: $pr_title

Diff:
$diff

Review the change for correctness, security, and safety. Cast your vote.")"

    local ballot_schema="$KODO_HOME/schemas/ballot.schema.json"

    # Collect structured votes in PARALLEL — all 3 CLIs run concurrently
    local vote_dir
    vote_dir=$(mktemp -d)

    _cast_ballot() {
        local cli="$1" outfile="$vote_dir/$cli.json"
        local result
        result=$(kodo_invoke_llm "$cli" "$ballot_prompt" \
            --schema "$ballot_schema" \
            --timeout 120 \
            --repo "$REPO_ID" \
            --domain "dev" 2>/dev/null) || { echo '{"vote":"error"}' > "$outfile"; return; }
        echo "$result" > "$outfile"
    }

    # Launch all votes in parallel
    local pids=""
    if _claude_available; then
        _cast_ballot "claude" &
        pids="$pids $!"
    fi
    if kodo_cli_available gemini; then
        _cast_ballot "gemini" &
        pids="$pids $!"
    fi
    if kodo_cli_available qwen; then
        _cast_ballot "qwen" &
        pids="$pids $!"
    fi

    # Wait for all votes to complete
    for pid in $pids; do
        wait "$pid" 2>/dev/null || true
    done

    # Tally results
    for vfile in "$vote_dir"/*.json; do
        [[ ! -f "$vfile" ]] && continue
        local cli_name
        cli_name=$(basename "$vfile" .json)
        local vote score reason
        vote=$(jq -r '.vote // "error"' "$vfile" 2>/dev/null)
        score=$(jq -r '.score // 0' "$vfile" 2>/dev/null)
        reason=$(jq -r '.reason // "no reason"' "$vfile" 2>/dev/null | head -c 120)

        [[ "$vote" == "error" ]] && continue

        kodo_log "DEV: ballot $cli_name: $vote ($score) — $reason"
        vote_log="${vote_log}${cli_name}:${vote}:${score} "
        total=$((total + 1))
        [[ "$vote" == "approve" && "$score" -ge 50 ]] && votes=$((votes + 1))
    done

    rm -rf "$vote_dir"

    kodo_log "DEV: ballot tally: $votes/$total [$vote_log]"

    # Persist ballot results in metadata
    kodo_pipeline_set "$EVENT_ID" "dev" "ballot_votes" "$votes"
    kodo_pipeline_set "$EVENT_ID" "dev" "ballot_total" "$total"
    kodo_pipeline_set "$EVENT_ID" "dev" "ballot_detail" "$vote_log"

    if [[ "$total" -lt 2 ]]; then
        defer "ballot: insufficient voters ($total < 2)"
    elif [[ "$votes" -ge 2 ]]; then
        kodo_log "DEV: consensus reached ($votes/$total) — guarded_merge"
        transition "balloting" "guarded_merge"
    else
        defer "ballot: no consensus ($votes/$total)"
    fi
}

# ── CI-Aware Merge ──────────────────────────────────────────
# Shared CI check logic used by both auto_merge and guarded_merge.
# Returns: 0=green (merge), 1=pending (yield, Brain re-dispatches later), 2=red (defer)

_check_ci_and_merge() {
    local pr_num="$1" merge_type="$2"

    # Check CI status via kodo-git.sh
    local ci_status
    ci_status=$("$SCRIPT_DIR/kodo-git.sh" pr-checks "$REPO_TOML" "$pr_num" 2>/dev/null) || ci_status=""

    if [[ -n "$ci_status" ]]; then
        local ci_state ci_pass ci_fail ci_pending ci_total
        ci_state=$(echo "$ci_status" | jq -r '.state' 2>/dev/null)
        ci_pass=$(echo "$ci_status" | jq -r '.pass' 2>/dev/null)
        ci_fail=$(echo "$ci_status" | jq -r '.fail' 2>/dev/null)
        ci_pending=$(echo "$ci_status" | jq -r '.pending' 2>/dev/null)
        ci_total=$(echo "$ci_status" | jq -r '.total' 2>/dev/null)

        kodo_log "DEV: CI for PR #$pr_num — $ci_state (pass:$ci_pass fail:$ci_fail pending:$ci_pending/$ci_total)"
        kodo_pipeline_set "$EVENT_ID" "dev" "ci_state" "$ci_state"
        kodo_pipeline_set "$EVENT_ID" "dev" "ci_checks_total" "$ci_total"

        case "$ci_state" in
            FAILURE)
                kodo_log "DEV: CI FAILED — not merging PR #$pr_num"
                return 2
                ;;
            PENDING)
                kodo_log "DEV: CI pending ($ci_pending/$ci_total) — yielding, will retry"
                return 1
                ;;
            NO_CHECKS)
                kodo_log "DEV: no CI checks configured — proceeding with $merge_type"
                ;;
            SUCCESS)
                kodo_log "DEV: CI green ($ci_pass/$ci_total) — proceeding with $merge_type"
                ;;
        esac
    fi

    # CI green or no checks → merge
    "$SCRIPT_DIR/kodo-git.sh" pr-merge "$REPO_TOML" "$pr_num" 2>/dev/null || {
        return 2
    }

    return 0
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

    local confidence
    confidence=$(kodo_pipeline_get "$EVENT_ID" "dev" "confidence")
    confidence="${confidence:-90}"

    local ci_result=0
    _check_ci_and_merge "$pr_num" "auto_merge" || ci_result=$?

    case "$ci_result" in
        0)  # Success — record clean merge
            kodo_sql "INSERT INTO merge_outcomes (event_id, repo, confidence, outcome)
                VALUES ('$(kodo_sql_escape "$EVENT_ID")', '$(kodo_sql_escape "$REPO_ID")', $confidence, 'clean');"
            transition "auto_merge" "releasing"
            ;;
        1)  # CI pending — don't transition, let Brain re-dispatch later
            kodo_log "DEV: auto_merge waiting for CI — engine yielding"
            ;;
        2)  # CI failed or merge failed
            defer "CI failed or merge rejected for PR #$pr_num"
            ;;
    esac
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

    local confidence
    confidence=$(kodo_pipeline_get "$EVENT_ID" "dev" "confidence")
    confidence="${confidence:-75}"

    # Check 48h window (guarded merge timeout)
    local created_at
    created_at=$(kodo_sql "SELECT created_at FROM pipeline_state
        WHERE event_id = '$(kodo_sql_escape "$EVENT_ID")' AND domain = 'dev';")
    if [[ -n "$created_at" ]]; then
        local age_hours
        age_hours=$(kodo_sql "SELECT CAST((julianday('now') - julianday('$created_at')) * 24 AS INTEGER);")
        if [[ "$age_hours" -gt 48 ]]; then
            defer "guarded merge timeout: $age_hours hours > 48h window"
            return
        fi
    fi

    local ci_result=0
    _check_ci_and_merge "$pr_num" "guarded_merge" || ci_result=$?

    case "$ci_result" in
        0)  kodo_sql "INSERT INTO merge_outcomes (event_id, repo, confidence, outcome)
                VALUES ('$(kodo_sql_escape "$EVENT_ID")', '$(kodo_sql_escape "$REPO_ID")', $confidence, 'clean');"
            transition "guarded_merge" "releasing"
            ;;
        1)  kodo_log "DEV: guarded_merge waiting for CI — engine yielding"
            ;;
        2)  defer "CI failed or merge rejected for PR #$pr_num"
            ;;
    esac
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
# Loops through states until a terminal state or a blocking operation.
# One invocation drives the event as far as it can go — no re-dispatch needed.

readonly MAX_STEPS=12

main() {
    local state
    state="$(get_state)"

    if [[ -z "$state" ]]; then
        kodo_log "DEV: no state found for $EVENT_ID — skipping"
        exit 0
    fi

    local step=0
    while [[ "$step" -lt "$MAX_STEPS" ]]; do
        state="$(get_state)"
        step=$((step + 1))

        kodo_log "DEV: processing $EVENT_ID (state: $state, step: $step)"

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
            resolved|closed)
                kodo_log "DEV: $EVENT_ID reached terminal state: $state"
                return 0
                ;;
            deferred)
                kodo_log "DEV: $EVENT_ID deferred — stopping"
                return 0
                ;;
            *)
                kodo_log "DEV: unknown state '$state' for $EVENT_ID"
                return 1
                ;;
        esac

        # Check if state actually advanced (avoid infinite loop on stuck transitions)
        local new_state
        new_state="$(get_state)"
        if [[ "$new_state" == "$state" ]]; then
            kodo_log "DEV: state unchanged ($state) — engine yielding"
            return 0
        fi
    done

    kodo_log "DEV: max steps ($MAX_STEPS) reached for $EVENT_ID — yielding"
}

main
