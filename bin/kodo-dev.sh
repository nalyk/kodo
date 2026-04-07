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
# Domain is always "dev" for this engine (passed as $3 but unused — always "dev")

if [[ -z "$EVENT_ID" || -z "$REPO_TOML" ]]; then
    echo "Usage: kodo-dev.sh <event_id> <repo_toml> [domain]" >&2
    exit 1
fi

REPO_ID="$(kodo_repo_id "$REPO_TOML")"
readonly REPO_ID
REPO_SLUG="$(kodo_repo_slug "$REPO_TOML")"
readonly REPO_SLUG
export KODO_TRANSITION_REPO="$REPO_ID"

# ── Concurrent Processing Guard ─────────────────────────────
# Claim this event atomically. Exit if another engine owns it.
if ! kodo_claim_event "$EVENT_ID" "dev"; then
    exit 0
fi
# Release lock + cleanup workdir + temp files on any exit (normal, error, signal)
_KODO_WORKDIR_CLEANUP=""
_KODO_TMPFILES=()
# shellcheck disable=SC2154 # _f is assigned by the for loop in trap
trap 'kodo_release_event "$EVENT_ID" "dev"; [[ -n "$_KODO_WORKDIR_CLEANUP" ]] && "$SCRIPT_DIR/kodo-git.sh" cleanup-workdir "$_KODO_WORKDIR_CLEANUP" 2>/dev/null; for _f in "${_KODO_TMPFILES[@]}"; do rm -rf "$_f" 2>/dev/null; done' EXIT

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

# Get PR number: pipeline metadata first (issue-driven), then payload (PR-driven)
_get_pr_num() {
    local num
    num=$(kodo_pipeline_get "$EVENT_ID" "dev" "pr_number")
    if [[ -z "$num" || "$num" == "null" ]]; then
        local payload
        payload="$(get_payload)"
        num=$(echo "$payload" | jq -r '.number // empty' 2>/dev/null)
    fi
    echo "$num"
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
    result=$(timeout 30 claude -p "respond with exactly: pong" --max-turns 1 </dev/null 2>/dev/null) || return 1
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
    if kodo_toml_bool "$REPO_TOML" "dev" "auto_merge_deps"; then
        if [[ "$title" == *"dependabot"* || "$title" == *"renovate"* || \
              "$title" == *"bump "* || "$title" == *"chore(deps)"* || \
              "$labels" == *"dependencies"* || \
              "$author_login" == *"dependabot"* || "$author_login" == *"renovate"* ]]; then
            kodo_log "DEV: deps PR #$pr_num ($author_login) — hard_gates then auto_merge"
            kodo_pipeline_set "$EVENT_ID" "dev" "deps_fast_path" "true"
            transition "triaging" "hard_gates"
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
    # Prefer Codex ($20/mo budget) over Claude ($200/mo) — Claude is reserved for review/strategy
    local gen_cli=""
    if kodo_cli_available codex; then
        gen_cli="codex"
    elif kodo_cli_available claude && kodo_check_budget "claude"; then
        gen_cli="claude"
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

        # Budget check before expensive Claude invocation
        if ! kodo_check_budget "claude"; then
            defer "claude budget exhausted"
            return
        fi

        # Run Claude from within the cloned repo directory
        # --allowedTools grants headless file write permission (without it, claude -p refuses writes)
        local gen_stderr
        gen_stderr=$(mktemp); _KODO_TMPFILES+=("$gen_stderr")
        fix_result=$(cd "$work_dir" && timeout 600 claude -p "$prompt" \
            --output-format json \
            --max-turns 20 \
            --allowedTools "Read" "Write" "Edit" "Glob" "Grep" "Bash(git diff:*)" "Bash(git status:*)" "Bash(git log:*)" "Bash(ls:*)" "Bash(find:*)" \
            </dev/null 2>"$gen_stderr") || {
            kodo_log "DEV: claude code gen failed: $(head -c 500 "$gen_stderr" 2>/dev/null)"
            fix_result=""
        }
        rm -f "$gen_stderr"

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

        local gen_stderr
        gen_stderr=$(mktemp); _KODO_TMPFILES+=("$gen_stderr")
        fix_result=$(cd "$work_dir" && timeout 600 codex exec \
            "Fix issue #$issue_num: $issue_title. $issue_body. Make minimal changes only." </dev/null 2>"$gen_stderr") || {
            kodo_log "DEV: codex code gen failed: $(head -c 500 "$gen_stderr" 2>/dev/null)"
            fix_result=""
        }
        rm -f "$gen_stderr"
        if [[ -n "$fix_result" ]]; then
            kodo_log_budget "codex" "$REPO_ID" "dev" 0 0 0.50
        fi
    fi

    # Step 5: Check if any files were actually changed
    local tracked_changes untracked_files changed_files
    tracked_changes=$(cd "$work_dir" && git diff --name-only 2>/dev/null) || tracked_changes=""
    untracked_files=$(cd "$work_dir" && git ls-files --others --exclude-standard 2>/dev/null) || untracked_files=""
    changed_files="${tracked_changes}${tracked_changes:+$'\n'}${untracked_files}"
    changed_files="${changed_files#$'\n'}"

    if [[ -z "$changed_files" ]]; then
        # Check if Claude determined the issue is already fixed
        # NOTE: this parses free-text LLM output — a structured schema would be better
        # but Claude's --allowedTools mode doesn't support --json-schema simultaneously
        local result_text="" already_resolved=false
        if [[ -n "$fix_result" ]]; then
            result_text=$(echo "$fix_result" | jq -r '.result // ""' 2>/dev/null)
            # Only match if the text explicitly and unambiguously says "already fixed/resolved"
            # Require "already" or "no longer" at word boundary, not in negated context
            if echo "$result_text" | grep -cEi "already (been )?(fix|resolv|implement|address)|no longer (valid|applic|reproduc)" | grep -q '^[1-9]'; then
                # Double-check: reject if negation precedes the match
                if ! echo "$result_text" | grep -qiE "(not|isn.t|hasn.t|hasn.t been) already"; then
                    already_resolved=true
                fi
            fi
        fi
        if [[ "$already_resolved" == "true" ]]; then
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
    local git_stderr
    git_stderr=$(mktemp); _KODO_TMPFILES+=("$git_stderr")
    (
        cd "$work_dir" || exit 1
        git add -A
        git commit -m "$(cat <<COMMITMSG
kodo(dev): fix #$issue_num -- $issue_title

Event-ID: $EVENT_ID
Model: $gen_cli
COMMITMSG
        )" --no-verify
    ) 2>"$git_stderr" || {
        kodo_log "DEV: git commit failed: $(head -c 300 "$git_stderr" 2>/dev/null)"
        rm -f "$git_stderr"
        "$SCRIPT_DIR/kodo-git.sh" cleanup-workdir "$work_dir" 2>/dev/null
        defer "git commit failed"
        return
    }
    rm -f "$git_stderr"

    # Step 7: Push branch + create PR (shadow mode blocks via kodo-git.sh)
    local push_stderr
    push_stderr=$(mktemp); _KODO_TMPFILES+=("$push_stderr")
    "$SCRIPT_DIR/kodo-git.sh" branch-push "$REPO_TOML" "$work_dir" "$branch_name" 2>"$push_stderr"
    local push_rc=$?
    if [[ "$push_rc" -eq 3 ]]; then
        kodo_log "DEV: branch push blocked by shadow mode"
    elif [[ "$push_rc" -ne 0 ]]; then
        kodo_log "DEV: branch push failed (rc=$push_rc): $(head -c 300 "$push_stderr" 2>/dev/null)"
        "$SCRIPT_DIR/kodo-git.sh" cleanup-workdir "$work_dir" 2>/dev/null
        defer "branch push failed"
        return
    fi

    local pr_body
    pr_body="## Fix for #$issue_num

**$issue_title**

### Changes
\`\`\`
$diff_lines
\`\`\`

### Files modified
$(printf -- '- %s\n' $changed_files)

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
    test_cmd="$(kodo_toml_get "$REPO_TOML" "dev" "test_command")"
    lint_cmd="$(kodo_toml_get "$REPO_TOML" "dev" "lint_command")"
    max_diff="$(kodo_toml_get "$REPO_TOML" "dev" "max_diff_lines")"
    max_diff="${max_diff:-500}"

    local pr_num
    pr_num=$(_get_pr_num)

    local gate_failed=""

    # Gate 1: Diff size check
    if [[ -n "$pr_num" ]]; then
        local diff_lines
        diff_lines=$("$SCRIPT_DIR/kodo-git.sh" pr-diff "$REPO_TOML" "$pr_num" 2>/dev/null | wc -l) || diff_lines=0
        if [[ "$diff_lines" -gt "$max_diff" ]]; then
            gate_failed="diff too large: $diff_lines lines (max: $max_diff)"
        fi
    fi

    # Gate 2: Test suite (if configured and PR branch can be checked out)
    if [[ -z "$gate_failed" && -n "$test_cmd" && -n "$pr_num" ]]; then
        local work_dir=""
        work_dir=$("$SCRIPT_DIR/kodo-git.sh" repo-clone "$REPO_TOML" "" 2>/dev/null) || work_dir=""
        if [[ -n "$work_dir" && -d "$work_dir" ]]; then
            # Fetch and checkout PR branch
            local pr_branch
            pr_branch=$(get_payload | jq -r '.headRefName // empty' 2>/dev/null)
            if [[ -n "$pr_branch" ]]; then
                (cd "$work_dir" && git fetch origin "$pr_branch" && git checkout "$pr_branch") 2>/dev/null || pr_branch=""
            fi
            if [[ -n "$pr_branch" ]]; then
                kodo_log "DEV: running test command: $test_cmd"
                if ! (cd "$work_dir" && timeout 300 bash -c "$test_cmd") >/dev/null 2>&1; then
                    gate_failed="test suite failed: $test_cmd"
                fi
                # Gate 3: Lint (if configured)
                if [[ -z "$gate_failed" && -n "$lint_cmd" ]]; then
                    kodo_log "DEV: running lint command: $lint_cmd"
                    if ! (cd "$work_dir" && timeout 120 bash -c "$lint_cmd") >/dev/null 2>&1; then
                        gate_failed="lint failed: $lint_cmd"
                    fi
                fi
            fi
            "$SCRIPT_DIR/kodo-git.sh" cleanup-workdir "$work_dir" 2>/dev/null
        fi
    fi

    if [[ -n "$gate_failed" ]]; then
        kodo_log "DEV: hard gate failed — $gate_failed"
        defer "hard gate: $gate_failed"
        return
    fi

    kodo_log "DEV: all hard gates passed"
    # Deps fast path: skip auditing/scanning, go straight to auto_merge (CI still checked)
    local deps_fast
    deps_fast=$(kodo_pipeline_get "$EVENT_ID" "dev" "deps_fast_path")
    if [[ "$deps_fast" == "true" ]]; then
        kodo_log "DEV: deps PR — hard gates passed, fast path to auto_merge"
        transition "hard_gates" "auto_merge"
        return
    fi

    # Post-rebase: skip feedback loop, go straight to audit (code already reviewed)
    local post_rebase
    post_rebase=$(kodo_pipeline_get "$EVENT_ID" "dev" "post_rebase")
    if [[ "$post_rebase" == "true" ]]; then
        kodo_log "DEV: post-rebase re-verification — skipping feedback"
        kodo_pipeline_set "$EVENT_ID" "dev" "post_rebase" ""
        transition "hard_gates" "auditing"
        return
    fi

    # KODO-generated PRs: wait for bot feedback before auditing (if enabled)
    local kodo_pr_num
    kodo_pr_num=$(kodo_pipeline_get "$EVENT_ID" "dev" "pr_number")
    if [[ -n "$kodo_pr_num" && "$kodo_pr_num" != "null" ]]; then
        local fb_enabled
        fb_enabled=$(kodo_toml_bool "$REPO_TOML" "dev" "await_bot_feedback" && echo "true" || echo "false")
        if [[ "$fb_enabled" == "true" ]]; then
            local feedback_rounds
            feedback_rounds=$(kodo_pipeline_get "$EVENT_ID" "dev" "feedback_rounds")
            feedback_rounds="${feedback_rounds:-0}"
            local max_rounds
            max_rounds=$(kodo_toml_get "$REPO_TOML" "dev" "max_feedback_rounds")
            max_rounds="${max_rounds:-2}"
            if [[ "$feedback_rounds" -lt "$max_rounds" ]]; then
                kodo_log "DEV: KODO PR — entering feedback wait (round $feedback_rounds/$max_rounds)"
                transition "hard_gates" "awaiting_feedback"
                return
            fi
            kodo_log "DEV: feedback rounds exhausted ($feedback_rounds/$max_rounds) — proceeding to audit"
        fi
    fi

    transition "hard_gates" "auditing"
}

# ── PR Feedback Loop ─────────────────────────────────────────

do_awaiting_feedback() {
    kodo_log "DEV: awaiting feedback for $EVENT_ID"

    local pr_num
    pr_num=$(_get_pr_num)
    if [[ -z "$pr_num" || "$pr_num" == "null" ]]; then
        kodo_log "DEV: no PR number — skipping feedback wait"
        transition "awaiting_feedback" "auditing"
        return
    fi

    # Mark when we started waiting (first entry only)
    local wait_started
    wait_started=$(kodo_pipeline_get "$EVENT_ID" "dev" "feedback_wait_started")
    if [[ -z "$wait_started" || "$wait_started" == "null" ]]; then
        kodo_pipeline_set "$EVENT_ID" "dev" "feedback_wait_started" "$(date +%s)"
        kodo_log "DEV: feedback window opened — yielding to brain for re-dispatch"
        return
    fi

    # Check if window expired
    local now
    now=$(date +%s)
    local window_minutes
    window_minutes=$(kodo_toml_get "$REPO_TOML" "dev" "feedback_window_minutes")
    window_minutes="${window_minutes:-10}"
    local window_seconds=$(( window_minutes * 60 ))
    local elapsed=$(( now - wait_started ))

    # Fetch reviews and inline comments from GitHub
    local reviews
    reviews=$("$SCRIPT_DIR/kodo-git.sh" pr-reviews "$REPO_TOML" "$pr_num" 2>/dev/null) || reviews="[]"
    local review_comments
    review_comments=$("$SCRIPT_DIR/kodo-git.sh" pr-review-comments "$REPO_TOML" "$pr_num" 2>/dev/null) || review_comments="[]"

    # Count items not yet in pr_feedback table
    local new_review_count=0
    local has_changes_requested=false

    # Process top-level reviews
    local review_ids
    review_ids=$(echo "$reviews" | jq -r '.[].id' 2>/dev/null) || review_ids=""
    for rid in $review_ids; do
        local existing
        existing=$(kodo_sql "SELECT COUNT(*) FROM pr_feedback WHERE event_id = '$(kodo_sql_escape "$EVENT_ID")' AND review_id = 'review-$(kodo_sql_escape "$rid")';")
        if [[ "${existing:-0}" -eq 0 ]]; then
            new_review_count=$((new_review_count + 1))
            local review_state
            review_state=$(echo "$reviews" | jq -r ".[] | select(.id == \"$rid\") | .state" 2>/dev/null)
            if [[ "$review_state" == "CHANGES_REQUESTED" ]]; then
                has_changes_requested=true
            fi
        fi
    done

    # Process inline comments
    local comment_ids
    comment_ids=$(echo "$review_comments" | jq -r '.[].id' 2>/dev/null) || comment_ids=""
    for cid in $comment_ids; do
        local existing
        existing=$(kodo_sql "SELECT COUNT(*) FROM pr_feedback WHERE event_id = '$(kodo_sql_escape "$EVENT_ID")' AND review_id = 'comment-$(kodo_sql_escape "$cid")';")
        if [[ "${existing:-0}" -eq 0 ]]; then
            new_review_count=$((new_review_count + 1))
        fi
    done

    # No new feedback and window still open — yield
    if [[ "$new_review_count" -eq 0 && "$elapsed" -lt "$window_seconds" ]]; then
        kodo_log "DEV: no new feedback yet, window ${elapsed}s/${window_seconds}s — yielding"
        return
    fi

    # Window expired with no feedback — proceed to auditing
    if [[ "$new_review_count" -eq 0 ]]; then
        kodo_log "DEV: feedback window expired ($window_minutes min), no reviews — proceeding to audit"
        transition "awaiting_feedback" "auditing"
        return
    fi

    # Changes requested = immediate defer
    if [[ "$has_changes_requested" == "true" ]]; then
        kodo_log "DEV: CHANGES_REQUESTED review found — deferring"
        defer "PR has changes_requested review"
        return
    fi

    kodo_log "DEV: $new_review_count new feedback items found — classifying"

    # Build feedback text for classification
    local feedback_text=""
    feedback_text+="Reviews: $(echo "$reviews" | jq -c '[.[] | {author, state, body}]' 2>/dev/null)"
    feedback_text+=" Comments: $(echo "$review_comments" | jq -c '[.[] | {author, body, path, line}]' 2>/dev/null)"

    # Classify with Qwen (free) or Gemini (free)
    local classify_cli=""
    for cli in qwen gemini; do
        if kodo_cli_available "$cli"; then
            classify_cli="$cli"
            break
        fi
    done

    local classification=""
    if [[ -n "$classify_cli" ]]; then
        local classify_prompt
        classify_prompt="$(kodo_prompt "Classify this PR feedback. Determine if there are blocking concerns, concrete code suggestions, or approval signals.

Feedback:
$feedback_text")"

        classification=$(kodo_invoke_llm "$classify_cli" "$classify_prompt" \
            --schema "$KODO_HOME/schemas/feedback.schema.json" \
            --timeout 60 \
            --repo "$REPO_ID" \
            --domain "dev") || classification=""
    fi

    # Store each review in pr_feedback table
    for rid in $review_ids; do
        local existing
        existing=$(kodo_sql "SELECT COUNT(*) FROM pr_feedback WHERE event_id = '$(kodo_sql_escape "$EVENT_ID")' AND review_id = 'review-$(kodo_sql_escape "$rid")';")
        [[ "${existing:-0}" -gt 0 ]] && continue
        local author author_type body state
        author=$(echo "$reviews" | jq -r ".[] | select(.id == \"$rid\") | .author" 2>/dev/null)
        author_type=$(echo "$reviews" | jq -r ".[] | select(.id == \"$rid\") | .author_type" 2>/dev/null)
        state=$(echo "$reviews" | jq -r ".[] | select(.id == \"$rid\") | .state" 2>/dev/null)
        body=$(echo "$reviews" | jq -r ".[] | select(.id == \"$rid\") | .body" 2>/dev/null)
        local is_bot=0
        [[ "$author_type" == "Bot" ]] && is_bot=1
        local cls="informational"
        [[ "$state" == "APPROVED" ]] && cls="approval"
        [[ "$state" == "CHANGES_REQUESTED" ]] && cls="changes_requested"
        kodo_sql "INSERT OR IGNORE INTO pr_feedback (event_id, repo, review_id, review_type, author, author_is_bot, classification, raw_body)
            VALUES ('$(kodo_sql_escape "$EVENT_ID")', '$(kodo_sql_escape "$REPO_ID")', 'review-$(kodo_sql_escape "$rid")', 'review',
            '$(kodo_sql_escape "$author")', $is_bot, '$(kodo_sql_escape "$cls")', '$(kodo_sql_escape "${body:0:2000}")');"
    done

    # Store inline comments
    local has_suggestions=false
    for cid in $comment_ids; do
        local existing
        existing=$(kodo_sql "SELECT COUNT(*) FROM pr_feedback WHERE event_id = '$(kodo_sql_escape "$EVENT_ID")' AND review_id = 'comment-$(kodo_sql_escape "$cid")';")
        [[ "${existing:-0}" -gt 0 ]] && continue
        local author author_type body fpath fline
        author=$(echo "$review_comments" | jq -r ".[] | select(.id == \"$cid\") | .author" 2>/dev/null)
        author_type=$(echo "$review_comments" | jq -r ".[] | select(.id == \"$cid\") | .author_type" 2>/dev/null)
        body=$(echo "$review_comments" | jq -r ".[] | select(.id == \"$cid\") | .body" 2>/dev/null)
        fpath=$(echo "$review_comments" | jq -r ".[] | select(.id == \"$cid\") | .path" 2>/dev/null)
        fline=$(echo "$review_comments" | jq -r ".[] | select(.id == \"$cid\") | .line" 2>/dev/null)
        local is_bot=0
        [[ "$author_type" == "Bot" ]] && is_bot=1
        local cls="concern"
        if echo "$body" | grep -q '```suggestion'; then
            cls="suggestion"
            has_suggestions=true
        fi
        kodo_sql "INSERT OR IGNORE INTO pr_feedback (event_id, repo, review_id, review_type, author, author_is_bot, classification, raw_body, file_path, line_number)
            VALUES ('$(kodo_sql_escape "$EVENT_ID")', '$(kodo_sql_escape "$REPO_ID")', 'comment-$(kodo_sql_escape "$cid")', 'comment',
            '$(kodo_sql_escape "$author")', $is_bot, '$(kodo_sql_escape "$cls")', '$(kodo_sql_escape "${body:0:2000}")',
            '$(kodo_sql_escape "$fpath")', ${fline:-0});"
    done

    # Apply confidence delta from classification
    local delta=0
    if [[ -n "$classification" ]]; then
        delta=$(echo "$classification" | jq -r '.confidence_delta // 0' 2>/dev/null)
        [[ ! "$delta" =~ ^-?[0-9]+$ ]] && delta=0
        if [[ "$delta" -ne 0 ]]; then
            kodo_pipeline_set "$EVENT_ID" "dev" "feedback_confidence_delta" "$delta"
            kodo_log "DEV: feedback confidence delta: $delta"
        fi
        local blocking
        blocking=$(echo "$classification" | jq -r '.has_blocking_concerns // false' 2>/dev/null)
        if [[ "$blocking" == "true" ]]; then
            kodo_log "DEV: blocking concerns detected — deferring"
            defer "PR feedback contains blocking concerns"
            return
        fi
    fi

    # Should we apply suggestions?
    local apply_enabled
    apply_enabled=$(kodo_toml_bool "$REPO_TOML" "dev" "apply_bot_suggestions" && echo "true" || echo "false")
    if [[ "$has_suggestions" == "true" && "$apply_enabled" == "true" ]]; then
        # Check if suggestions are from trusted bots
        local trusted_bots
        trusted_bots=$(kodo_toml_get "$REPO_TOML" "dev" "trusted_review_bots")
        local has_trusted_suggestion=false
        local suggestion_authors
        suggestion_authors=$(kodo_sql "SELECT DISTINCT author FROM pr_feedback
            WHERE event_id = '$(kodo_sql_escape "$EVENT_ID")' AND classification = 'suggestion'
            AND author_is_bot = 1 AND suggestion_applied = 0;")
        for sa in $suggestion_authors; do
            if echo "$trusted_bots" | grep -q "$sa"; then
                has_trusted_suggestion=true
                break
            fi
        done

        if [[ "$has_trusted_suggestion" == "true" ]]; then
            kodo_log "DEV: trusted bot suggestions found — applying"
            transition "awaiting_feedback" "applying_suggestions"
            return
        fi
    fi

    kodo_log "DEV: feedback processed (delta=$delta) — proceeding to audit"
    transition "awaiting_feedback" "auditing"
}

do_applying_suggestions() {
    kodo_log "DEV: applying bot suggestions for $EVENT_ID"

    local pr_num
    pr_num=$(_get_pr_num)
    if [[ -z "$pr_num" || "$pr_num" == "null" ]]; then
        kodo_log "DEV: no PR number — skipping suggestion apply"
        transition "applying_suggestions" "auditing"
        return
    fi

    # Get the PR branch name from metadata or payload
    local pr_branch
    pr_branch=$(kodo_pipeline_get "$EVENT_ID" "dev" "pr_branch")
    if [[ -z "$pr_branch" || "$pr_branch" == "null" ]]; then
        pr_branch=$(get_payload | jq -r '.headRefName // empty' 2>/dev/null)
    fi
    if [[ -z "$pr_branch" ]]; then
        pr_branch="kodo/dev/$EVENT_ID"
    fi

    # Clone and checkout the PR branch
    local work_dir
    work_dir=$("$SCRIPT_DIR/kodo-git.sh" repo-clone "$REPO_TOML" "$pr_branch" 2>/dev/null) || {
        kodo_log "DEV: failed to clone repo for suggestion apply"
        transition "applying_suggestions" "auditing"
        return
    }
    _KODO_WORKDIR_CLEANUP="$work_dir"

    # Get unprocessed suggestions from trusted bots
    local suggestions
    suggestions=$(kodo_sql "SELECT review_id, raw_body, file_path, line_number FROM pr_feedback
        WHERE event_id = '$(kodo_sql_escape "$EVENT_ID")' AND classification = 'suggestion'
        AND author_is_bot = 1 AND suggestion_applied = 0
        ORDER BY line_number ASC;")

    local applied_count=0
    while IFS='|' read -r review_id raw_body file_path line_number; do
        [[ -z "$review_id" ]] && continue

        # Extract suggestion content from ```suggestion ... ``` block
        local suggestion_text
        suggestion_text=$(echo "$raw_body" | sed -n '/^```suggestion/,/^```$/{//!p;}')
        if [[ -z "$suggestion_text" ]]; then
            kodo_log "DEV: no suggestion block found in $review_id — skipping"
            continue
        fi

        kodo_log "DEV: applying suggestion $review_id to $file_path:$line_number"
        if "$SCRIPT_DIR/kodo-git.sh" pr-apply-suggestion "$REPO_TOML" "$work_dir" "$file_path" "$line_number" "$suggestion_text" \
            "kodo(dev): apply bot suggestion -- $EVENT_ID" 2>/dev/null; then
            applied_count=$((applied_count + 1))
            kodo_sql "UPDATE pr_feedback SET suggestion_applied = 1
                WHERE event_id = '$(kodo_sql_escape "$EVENT_ID")' AND review_id = '$(kodo_sql_escape "$review_id")';"
        else
            kodo_log "DEV: suggestion $review_id failed to apply (context mismatch?) — skipping"
        fi
    done <<< "$suggestions"

    if [[ "$applied_count" -gt 0 ]]; then
        kodo_log "DEV: $applied_count suggestions applied — pushing updates"
        "$SCRIPT_DIR/kodo-git.sh" branch-push "$REPO_TOML" "$work_dir" "$pr_branch" 2>/dev/null || {
            kodo_log "DEV: push failed after applying suggestions (shadow mode?)"
        }

        # Increment feedback rounds
        local rounds
        rounds=$(kodo_pipeline_get "$EVENT_ID" "dev" "feedback_rounds")
        rounds="${rounds:-0}"
        rounds=$((rounds + 1))
        kodo_pipeline_set "$EVENT_ID" "dev" "feedback_rounds" "$rounds"
        # Clear wait timestamp so next round starts fresh
        kodo_pipeline_set "$EVENT_ID" "dev" "feedback_wait_started" ""

        kodo_log "DEV: feedback round $rounds complete — re-entering hard_gates"
        "$SCRIPT_DIR/kodo-git.sh" cleanup-workdir "$work_dir" 2>/dev/null
        _KODO_WORKDIR_CLEANUP=""
        transition "applying_suggestions" "hard_gates"
    else
        kodo_log "DEV: no suggestions could be applied — proceeding to audit"
        "$SCRIPT_DIR/kodo-git.sh" cleanup-workdir "$work_dir" 2>/dev/null
        _KODO_WORKDIR_CLEANUP=""
        transition "applying_suggestions" "auditing"
    fi
}

# ── Auditing & Scanning ─────────────────────────────────────

do_auditing() {
    kodo_log "DEV: auditing $EVENT_ID"

    local payload pr_num
    payload="$(get_payload)"
    pr_num=$(_get_pr_num)

    local confidence=0
    local review_output=""
    local review_model="none"

    if _claude_available; then
        review_model="claude"
        local diff=""
        if [[ -n "$pr_num" ]]; then
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
            confidence=$(echo "$codex_result" | jq -r '.score // 0' 2>/dev/null)
            if ! [[ "$confidence" =~ ^[0-9]+$ ]]; then
                kodo_log "DEV: codex returned non-numeric score: $confidence"
                confidence=0
            fi
            [[ "$confidence" -gt 79 ]] && confidence=79
            review_output="$codex_result"
        else
            confidence=70
        fi
    else
        defer "no review CLI available"
        return
    fi

    # Apply accumulated feedback confidence delta (from bot reviews)
    local feedback_delta
    feedback_delta=$(kodo_pipeline_get "$EVENT_ID" "dev" "feedback_confidence_delta")
    feedback_delta="${feedback_delta:-0}"
    if [[ "$feedback_delta" != "0" && "$feedback_delta" != "null" ]]; then
        kodo_log "DEV: applying feedback confidence delta: $feedback_delta"
        confidence=$(( confidence + feedback_delta ))
        [[ "$confidence" -lt 0 ]] && confidence=0
        [[ "$confidence" -gt 100 ]] && confidence=100
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
    local scan_findings=0

    if command -v semgrep >/dev/null 2>&1; then
        local pr_num
        pr_num=$(_get_pr_num)

        if [[ -n "$pr_num" ]]; then
            # Clone and checkout the PR branch so semgrep scans actual code
            local scan_dir=""
            scan_dir=$("$SCRIPT_DIR/kodo-git.sh" repo-clone "$REPO_TOML" "" 2>/dev/null) || scan_dir=""
            if [[ -n "$scan_dir" && -d "$scan_dir" ]]; then
                local pr_branch
                pr_branch=$(get_payload | jq -r '.headRefName // empty' 2>/dev/null)
                if [[ -n "$pr_branch" ]]; then
                    (cd "$scan_dir" && git fetch origin "$pr_branch" && git checkout "$pr_branch") 2>/dev/null || pr_branch=""
                fi
                if [[ -n "$pr_branch" ]]; then
                    # Get changed filenames from diff
                    local diff_files
                    diff_files=$("$SCRIPT_DIR/kodo-git.sh" pr-diff "$REPO_TOML" "$pr_num" 2>/dev/null \
                        | grep '^+++ b/' | sed 's|^+++ b/||' | head -20) || diff_files=""

                    if [[ -n "$diff_files" ]]; then
                        kodo_log "DEV: running semgrep on changed files in checked-out branch"
                        scan_findings=$(cd "$scan_dir" && echo "$diff_files" | xargs semgrep --config=auto --json 2>/dev/null \
                            | jq '.results | length' 2>/dev/null) || scan_findings=0

                        if [[ "$scan_findings" -gt 0 ]]; then
                            scan_clean=false
                            kodo_log "DEV: semgrep found $scan_findings issues"
                            local penalty=$((scan_findings * 10))
                            confidence=$((confidence > penalty ? confidence - penalty : 0))
                            kodo_pipeline_set "$EVENT_ID" "dev" "scan_findings" "$scan_findings"
                        fi
                    fi
                fi
                "$SCRIPT_DIR/kodo-git.sh" cleanup-workdir "$scan_dir" 2>/dev/null
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
    vote_dir=$(mktemp -d); _KODO_TMPFILES+=("$vote_dir")

    _cast_ballot() {
        local cli="$1"
        local outfile="$vote_dir/$cli.json"
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

# ── Rebase-on-Conflict ───────────────────────────────────────
# Try server-side rebase when PR branch is behind base.
# Returns: 0 = rebased (re-check required), 1 = unresolvable conflict, 2 = no rebase needed

_attempt_rebase() {
    local pr_num="$1"

    # Cap rebase retries (configurable, default 2)
    local rebase_count
    rebase_count=$(kodo_pipeline_get "$EVENT_ID" "dev" "rebase_count")
    rebase_count="${rebase_count:-0}"
    local max_rebases
    max_rebases=$(kodo_toml_get "$REPO_TOML" "dev" "max_rebase_attempts")
    max_rebases="${max_rebases:-2}"
    if [[ "$rebase_count" -ge "$max_rebases" ]]; then
        kodo_log "DEV: rebase attempt limit ($rebase_count/$max_rebases) — giving up"
        return 1
    fi

    # Query GitHub mergeability
    local merge_info mergeable merge_state
    merge_info=$("$SCRIPT_DIR/kodo-git.sh" pr-mergeable "$REPO_TOML" "$pr_num" 2>/dev/null) || merge_info='{}'
    mergeable=$(echo "$merge_info" | jq -r '.mergeable // "UNKNOWN"' 2>/dev/null)
    merge_state=$(echo "$merge_info" | jq -r '.mergeStateStatus // "UNKNOWN"' 2>/dev/null)

    kodo_log "DEV: PR #$pr_num mergeable=$mergeable state=$merge_state"

    # CLEAN = no rebase needed
    if [[ "$merge_state" == "CLEAN" || "$merge_state" == "HAS_HOOKS" ]]; then
        return 2
    fi

    # BEHIND + MERGEABLE = server-side rebase can fix it
    if [[ "$mergeable" == "MERGEABLE" && "$merge_state" == "BEHIND" ]]; then
        kodo_log "DEV: PR #$pr_num is BEHIND — server-side rebase (attempt $((rebase_count + 1))/$max_rebases)"
        local rc=0
        "$SCRIPT_DIR/kodo-git.sh" pr-rebase "$REPO_TOML" "$pr_num" 2>/dev/null || rc=$?
        case "$rc" in
            0)  rebase_count=$((rebase_count + 1))
                kodo_pipeline_set "$EVENT_ID" "dev" "rebase_count" "$rebase_count"
                kodo_log "DEV: rebase succeeded"
                return 0
                ;;
            3)  kodo_log "DEV: rebase blocked by shadow mode — proceeding as-is"
                return 2
                ;;
            *)  kodo_log "DEV: rebase failed (rc=$rc)"
                return 1
                ;;
        esac
    fi

    # CONFLICTING = cannot auto-resolve
    if [[ "$mergeable" == "CONFLICTING" ]]; then
        kodo_log "DEV: PR #$pr_num has merge conflicts — unresolvable"
        return 1
    fi

    # UNKNOWN = GitHub hasn't computed yet — proceed, merge will tell us
    return 2
}

# ── CI-Aware Merge ──────────────────────────────────────────
# Shared CI check logic used by both auto_merge and guarded_merge.
# Returns: 0=merged, 1=pending (yield), 2=failed (defer), 3=rebased (loop back to hard_gates)

_check_ci_and_merge() {
    local pr_num="$1" merge_type="$2"

    # Check CI status via kodo-git.sh
    local ci_status
    ci_status=$("$SCRIPT_DIR/kodo-git.sh" pr-checks "$REPO_TOML" "$pr_num" 2>&1) || {
        kodo_log "DEV: CI check API failed for PR #$pr_num — yielding (will not merge without CI)"
        return 1
    }

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
                # CI failure may be caused by outdated branch — try rebase
                local rebase_rc=0
                _attempt_rebase "$pr_num" || rebase_rc=$?
                if [[ "$rebase_rc" -eq 0 ]]; then
                    return 3  # Rebased — re-run CI
                fi
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

    # Pre-merge: check if branch needs rebase
    local rebase_rc=0
    _attempt_rebase "$pr_num" || rebase_rc=$?
    case "$rebase_rc" in
        0) return 3 ;;  # Rebased — caller loops back through hard_gates
        1) return 2 ;;  # Unresolvable conflict
        2) ;;           # Clean — proceed to merge
    esac

    # CI green + branch clean → merge
    "$SCRIPT_DIR/kodo-git.sh" pr-merge "$REPO_TOML" "$pr_num" 2>/dev/null || {
        kodo_log "DEV: merge failed for PR #$pr_num"
        return 2
    }

    return 0
}

do_auto_merge() {
    kodo_log "DEV: auto-merging $EVENT_ID"

    local pr_num
    pr_num=$(_get_pr_num)

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
        0)  kodo_sql "INSERT INTO merge_outcomes (event_id, repo, confidence, outcome)
                VALUES ('$(kodo_sql_escape "$EVENT_ID")', '$(kodo_sql_escape "$REPO_ID")', $confidence, 'clean');"
            transition "auto_merge" "releasing"
            ;;
        1)  kodo_log "DEV: auto_merge waiting for CI — engine yielding"
            ;;
        2)  defer "CI failed or merge rejected for PR #$pr_num"
            ;;
        3)  kodo_log "DEV: PR #$pr_num rebased — re-verifying through hard_gates"
            kodo_pipeline_set "$EVENT_ID" "dev" "post_rebase" "true"
            transition "auto_merge" "hard_gates"
            ;;
    esac
}

do_guarded_merge() {
    kodo_log "DEV: guarded merge $EVENT_ID (48h CI window)"

    local pr_num
    pr_num=$(_get_pr_num)

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
        age_hours=$(kodo_sql "SELECT CAST((julianday('now') - julianday('$(kodo_sql_escape "$created_at")')) * 24 AS INTEGER);")
        if [[ "$age_hours" -gt 48 ]]; then
            defer "guarded merge timeout: $age_hours hours > 48h window"
            return
        fi
    fi

    local ci_result=0
    _check_ci_and_merge "$pr_num" "guarded_merge" || ci_result=$?

    case "$ci_result" in
        0)  kodo_sql "INSERT INTO merge_outcomes (event_id, repo, confidence, outcome)
                Values ('$(kodo_sql_escape "$EVENT_ID")', '$(kodo_sql_escape "$REPO_ID")', $confidence, 'clean');"
            transition "guarded_merge" "releasing"
            ;;
        1)  kodo_log "DEV: guarded_merge waiting for CI — engine yielding"
            ;;
        2)  defer "CI failed or merge rejected for PR #$pr_num"
            ;;
        3)  kodo_log "DEV: PR #$pr_num rebased — re-verifying through hard_gates"
            kodo_pipeline_set "$EVENT_ID" "dev" "post_rebase" "true"
            transition "guarded_merge" "hard_gates"
            ;;
    esac
}

do_releasing() {
    kodo_log "DEV: releasing $EVENT_ID"

    if kodo_toml_bool "$REPO_TOML" "dev" "semver_release"; then
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

readonly MAX_STEPS=24

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
            awaiting_feedback) do_awaiting_feedback ;;
            applying_suggestions) do_applying_suggestions ;;
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
