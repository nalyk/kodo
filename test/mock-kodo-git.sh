#!/usr/bin/env bash
set -euo pipefail

# Mock kodo-git.sh — drop-in replacement for fixture tests
# Returns fixture-driven responses. No real git provider calls.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/kodo-lib.sh"

kodo_init_db

# ── Fixture Data Lookup ─────────────────────────────────────

# Return fixture file content if it exists, else return the default
# Usage: _fixture_or_default <action> <default_json>
_fixture_or_default() {
    local action="$1" default="$2"
    local fixture_file="${KODO_FIXTURE_DIR:-}/${KODO_FIXTURE_SCENARIO:-default}/${action}.json"
    if [[ -f "$fixture_file" ]]; then
        cat "$fixture_file"
    else
        echo "$default"
    fi
}

# Log a mock call for later verification
_mock_log() {
    local action="$1"
    shift
    echo "$action $*" >> "${KODO_FIXTURE_HOME:-/tmp}/mock-calls.log" 2>/dev/null || true
}

# ── Local Operations ────────────────────────────────────────

# Create a minimal git repo for code gen scenarios
_mock_repo_clone() {
    local branch="${1:-main}"
    local work_dir
    work_dir=$(mktemp -d "${KODO_FIXTURE_HOME:-.}/.workdir/clone-XXXXXX")
    (
        cd "$work_dir"
        git init -q
        git checkout -q -b main 2>/dev/null || true
        echo "# fixture repo" > README.md
        git add README.md
        git commit -q -m "init" --no-verify
        # Set self as origin so `git fetch origin <branch>` succeeds
        git remote add origin "$work_dir" 2>/dev/null || true
        # Create requested branch if different from main
        if [[ -n "$branch" && "$branch" != "main" ]]; then
            git checkout -q -b "$branch" 2>/dev/null || true
        fi
        # Read payload to pre-create the PR branch if it exists
        # This ensures `git fetch origin <headRefName> && git checkout <headRefName>` works
        local head_ref=""
        head_ref="${KODO_FIXTURE_PR_BRANCH:-}"
        if [[ -n "$head_ref" && "$head_ref" != "$branch" ]]; then
            git checkout -q -b "$head_ref" 2>/dev/null || true
        fi
        # Update self-remote refs
        git fetch -q origin 2>/dev/null || true
        # Return to the requested branch
        git checkout -q "$branch" 2>/dev/null || git checkout -q main 2>/dev/null || true
    ) >/dev/null 2>&1
    echo "$work_dir"
}

_mock_branch_create() {
    local work_dir="$1" branch_name="$2"
    (cd "$work_dir" && git checkout -q -b "$branch_name" 2>/dev/null) || true
}

_mock_cleanup_workdir() {
    local work_dir="$1"
    if [[ -d "$work_dir" && "$work_dir" == *"/.workdir/"* ]]; then
        rm -rf "$work_dir"
    fi
}

# ── Main Dispatcher ─────────────────────────────────────────

main() {
    local action="${1:-}"

    if [[ -z "$action" ]]; then
        echo "Usage: mock-kodo-git.sh <action> [args...]" >&2
        exit 1
    fi

    # Local operations — no provider needed
    case "$action" in
        branch-create)
            shift; _mock_branch_create "$@"; return 0 ;;
        cleanup-workdir)
            shift; _mock_cleanup_workdir "$@"; return 0 ;;
    esac

    local toml="${2:-}"
    shift 2 || shift $# || true

    # Shadow mode guard — check TOML if provided
    local write_actions="pr-comment pr-merge pr-create branch-push issue-comment issue-close issue-label issue-create release-edit discussion-create pr-apply-suggestion pr-rebase pr-revert"
    if [[ " $write_actions " == *" $action "* && -n "$toml" && -f "$toml" ]]; then
        local mode
        mode=$(grep -m1 '^mode' "$toml" 2>/dev/null | sed 's/.*=[[:space:]]*//' | tr -d '"' | tr -d "'" || echo "live")
        if [[ "$mode" == "shadow" ]]; then
            kodo_log "SHADOW BLOCK: $action — log only"
            return 3
        fi
    fi

    # Provider capabilities
    if [[ "$action" == "provider-capabilities" ]]; then
        echo '["pr-list","pr-comment","pr-merge","pr-checks","pr-diff","issue-list","issue-comment","issue-close","issue-label","release-get","release-edit","release-list","user-info","discussion-create","milestone-list","compare","repo-info","issue-create","repo-clone","pr-create","issue-get","branch-push","pr-mergeable","pr-rebase","pr-reviews","pr-review-comments","pr-apply-suggestion","pr-merge-sha","commit-checks","pr-revert","issue-labels-get","comment-reactions"]'
        return 0
    fi

    case "$action" in
        # ── Read operations — return fixture or sensible default ──
        pr-list)
            _fixture_or_default "pr-list" '[]'
            ;;
        issue-list)
            _fixture_or_default "issue-list" '[]'
            ;;
        pr-diff)
            _fixture_or_default "pr-diff" ""
            ;;
        pr-checks)
            _fixture_or_default "pr-checks" '{"state":"SUCCESS","pass":1,"fail":0,"pending":0,"total":1}'
            ;;
        pr-mergeable)
            _fixture_or_default "pr-mergeable" '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"feature","baseRefName":"main"}'
            ;;
        pr-merge-sha)
            _fixture_or_default "pr-merge-sha" ""
            ;;
        commit-checks)
            _fixture_or_default "commit-checks" '{"state":"SUCCESS","pass":1,"fail":0,"pending":0,"total":1}'
            ;;
        issue-get)
            _fixture_or_default "issue-get" '{"number":1,"title":"test","body":"test body","labels":[],"comment_count":0,"last_comments":[]}'
            ;;
        issue-labels-get)
            _fixture_or_default "issue-labels-get" '[]'
            ;;
        comment-reactions)
            _fixture_or_default "comment-reactions" '{"thumbs_up":0,"thumbs_down":0}'
            ;;
        pr-reviews)
            _fixture_or_default "pr-reviews" '[]'
            ;;
        pr-review-comments)
            _fixture_or_default "pr-review-comments" '[]'
            ;;
        release-list)
            _fixture_or_default "release-list" '[]'
            ;;
        milestone-list)
            _fixture_or_default "milestone-list" '[]'
            ;;
        user-info)
            _fixture_or_default "user-info" '{"login":"test-user","name":"Test User","type":"User"}'
            ;;

        # ── Write operations — log and return success ──
        repo-clone)
            _mock_log "repo-clone" "${toml:-}" "$@"
            _mock_repo_clone "${1:-main}"
            ;;
        pr-merge)
            _mock_log "pr-merge" "$@"
            ;;
        pr-create)
            _mock_log "pr-create" "$@"
            echo "https://github.com/fixture-org/test-repo/pull/999"
            ;;
        branch-push)
            _mock_log "branch-push" "$@"
            ;;
        issue-comment)
            _mock_log "issue-comment" "$@"
            echo "https://github.com/fixture-org/test-repo/issues/1#issuecomment-12345"
            ;;
        pr-comment)
            _mock_log "pr-comment" "$@"
            ;;
        issue-close)
            _mock_log "issue-close" "$@"
            ;;
        issue-label)
            _mock_log "issue-label" "$@"
            ;;
        pr-rebase)
            _mock_log "pr-rebase" "$@"
            return 0
            ;;
        pr-revert)
            _mock_log "pr-revert" "$@"
            _fixture_or_default "pr-revert" "" >/dev/null
            # Check if fixture says revert should fail
            local revert_fixture="${KODO_FIXTURE_DIR:-}/${KODO_FIXTURE_SCENARIO:-default}/pr-revert-fail"
            if [[ -f "$revert_fixture" ]]; then
                return 1
            fi
            return 0
            ;;
        pr-apply-suggestion)
            _mock_log "pr-apply-suggestion" "$@"
            ;;
        *)
            _mock_log "$action" "$@"
            _fixture_or_default "$action" '{}'
            ;;
    esac
}

main "$@"
