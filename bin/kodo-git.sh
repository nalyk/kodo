#!/usr/bin/env bash
set -euo pipefail

# Git provider abstraction layer
# ALL git operations MUST go through this script
# Usage: kodo-git.sh <action> <repo-toml-path> [args...]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kodo-lib.sh
source "$SCRIPT_DIR/kodo-lib.sh"

kodo_init_db

# ── Helpers ──────────────────────────────────────────────────

_resolve_provider() {
    local toml="$1"
    kodo_toml_get "$toml" "provider"
}

_resolve_slug() {
    kodo_repo_slug "$1"
}

_resolve_api_base() {
    local toml="$1"
    kodo_toml_get "$toml" "api_base" 2>/dev/null || true
}

# Shadow mode guard: blocks write operations in shadow mode
_guard_write() {
    local toml="$1" action="$2"
    if kodo_is_shadow "$toml"; then
        kodo_log "SHADOW BLOCK: $action on $(kodo_repo_id "$toml") — log only"
        return 1
    fi
    return 0
}

# ── GitHub (gh) ──────────────────────────────────────────────

_gh_pr_list() {
    local slug="$1"
    gh pr list --repo "$slug" --json number,title,state,headRefName,author,labels,createdAt,updatedAt --limit 50
}

_gh_pr_comment() {
    local slug="$1" pr_num="$2" body="$3"
    gh pr comment "$pr_num" --repo "$slug" --body "$body"
}

_gh_pr_merge() {
    local slug="$1" pr_num="$2"
    # No --auto: KODO already verified CI green before calling merge.
    # --auto queues for later; without it, merge executes immediately.
    gh pr merge "$pr_num" --repo "$slug" --merge
}

# Check CI status for a PR
# gh pr checks uses: state = PENDING | SUCCESS | FAILURE | CANCELLED | ERROR | EXPECTED | NEUTRAL | STALE | SKIPPED
_gh_pr_checks() {
    local slug="$1" pr_num="$2"
    gh pr checks "$pr_num" --repo "$slug" --json name,state,bucket 2>/dev/null | jq -c '{
        total: length,
        pass: [.[] | select(.bucket == "pass")] | length,
        fail: [.[] | select(.bucket == "fail")] | length,
        pending: [.[] | select(.bucket == "pending")] | length,
        state: (
            if length == 0 then "NO_CHECKS"
            elif ([.[] | select(.bucket == "fail")] | length) > 0 then "FAILURE"
            elif ([.[] | select(.bucket == "pending")] | length) > 0 then "PENDING"
            else "SUCCESS"
            end
        )
    }'
}

_gh_pr_diff() {
    local slug="$1" pr_num="$2"
    gh pr diff "$pr_num" --repo "$slug"
}

_gh_issue_list() {
    local slug="$1"
    gh issue list --repo "$slug" --json number,title,state,labels,author,createdAt,updatedAt,comments --limit 100
}

_gh_issue_comment() {
    local slug="$1" issue_num="$2" body="$3"
    gh issue comment "$issue_num" --repo "$slug" --body "$body"
}

_gh_issue_close() {
    local slug="$1" issue_num="$2"
    gh issue close "$issue_num" --repo "$slug"
}

_gh_issue_label() {
    local slug="$1" issue_num="$2" label="$3"
    gh issue edit "$issue_num" --repo "$slug" --add-label "$label"
}

_gh_release_get() {
    local slug="$1" tag="$2"
    gh release view "$tag" --repo "$slug" --json tagName,name,body,createdAt,isDraft,isPrerelease
}

_gh_release_edit() {
    local slug="$1" tag="$2" notes="$3"
    gh release edit "$tag" --repo "$slug" --notes "$notes"
}

_gh_release_list() {
    local slug="$1"
    gh release list --repo "$slug" --json tagName,name,createdAt --limit 10
}

_gh_user_info() {
    local username="$1"
    gh api "users/$username" --jq '{login: .login, name: .name, type: .type}'
}

_gh_discussion_create() {
    local slug="$1" category="$2" title="$3" body="$4"
    gh api "repos/$slug/discussions" -f category_name="$category" -f title="$title" -f body="$body"
}

_gh_milestone_list() {
    local slug="$1"
    gh api "repos/$slug/milestones" --jq '.[] | {number, title, open_issues, closed_issues, due_on, state}'
}

_gh_compare() {
    local slug="$1" base="$2" head="$3"
    gh api "repos/$slug/compare/${base}...${head}" --jq '.commits[] | {sha: .sha[0:7], message: .commit.message}'
}

# ── GitLab (glab) ────────────────────────────────────────────

_glab_pr_list() {
    local slug="$1"
    glab mr list --repo "$slug" --output json 2>/dev/null || echo "[]"
}

_glab_pr_comment() {
    local slug="$1" pr_num="$2" body="$3"
    glab mr note "$pr_num" --repo "$slug" -m "$body"
}

_glab_pr_merge() {
    local slug="$1" pr_num="$2"
    glab mr merge "$pr_num" --repo "$slug" --yes
}

_glab_issue_list() {
    local slug="$1"
    glab issue list --repo "$slug" --output json 2>/dev/null || echo "[]"
}

_glab_issue_comment() {
    local slug="$1" issue_num="$2" body="$3"
    glab issue note "$issue_num" --repo "$slug" -m "$body"
}

_glab_issue_close() {
    local slug="$1" issue_num="$2"
    glab issue close "$issue_num" --repo "$slug"
}

_glab_issue_label() {
    local slug="$1" issue_num="$2" label="$3"
    glab issue update "$issue_num" --repo "$slug" --label "$label"
}

_glab_release_get() {
    local slug="$1" tag="$2"
    glab release view "$tag" --repo "$slug" --output json 2>/dev/null || echo "{}"
}

_glab_release_edit() {
    local slug="$1" tag="$2" notes="$3"
    glab release edit "$tag" --repo "$slug" --notes "$notes"
}

# ── Repo Operations (provider-agnostic) ─────────────────────

# Clone a repo to a temporary working directory
# Returns: path to the cloned directory on stdout
_gh_repo_clone() {
    local slug="$1" branch="${2:-}"
    local work_dir="$KODO_HOME/.workdir/${slug//\//-}-$$"
    mkdir -p "$work_dir"

    local clone_args=(--depth 50 --single-branch)
    if [[ -n "$branch" ]]; then
        clone_args+=(--branch "$branch")
    fi

    if gh repo clone "$slug" "$work_dir" -- "${clone_args[@]}" >/dev/null 2>&1; then
        echo "$work_dir"
        return 0
    else
        rm -rf "$work_dir"
        return 1
    fi
}

# Create a branch in a local clone and push it
_gh_branch_create() {
    local work_dir="$1" branch_name="$2"
    cd "$work_dir" || return 1
    git checkout -b "$branch_name" 2>/dev/null
    cd - >/dev/null
}

# Create a PR from a branch
_gh_pr_create() {
    local slug="$1" branch="$2" title="$3" body="$4"
    gh pr create --repo "$slug" --head "$branch" --title "$title" --body "$body"
}

# Push a branch from a working directory
_gh_branch_push() {
    local work_dir="$1" branch_name="$2"
    cd "$work_dir" || return 1
    # --force-with-lease: safe force push — allows retry when branch exists from prior run
    git push --force-with-lease origin "$branch_name" 2>/dev/null
    cd - >/dev/null
}

# Clean up a working directory
_cleanup_workdir() {
    local work_dir="$1"
    if [[ -d "$work_dir" && "$work_dir" == *"/.workdir/"* ]]; then
        rm -rf "$work_dir"
    fi
}

# Get issue body (full content for context)
_gh_issue_get() {
    local slug="$1" issue_num="$2"
    gh issue view "$issue_num" --repo "$slug" --json number,title,body,labels,comments --jq '{
        number: .number,
        title: .title,
        body: .body,
        labels: [.labels[].name],
        comment_count: (.comments | length),
        last_comments: [.comments[-3:][] | {author: .author.login, body: .body[:500]}]
    }'
}

# ── Gitea / Bitbucket stubs ──────────────────────────────────

_stub_not_supported() {
    local provider="$1" action="$2"
    kodo_log "ERROR: provider '$provider' not yet supported for action '$action'"
    return 2
}

# ── Main Dispatcher ──────────────────────────────────────────

main() {
    local action="${1:-}"

    if [[ -z "$action" ]]; then
        echo "Usage: kodo-git.sh <action> <repo-toml|path> [args...]" >&2
        exit 1
    fi

    # Local operations that don't need a repo TOML — handle before provider dispatch
    case "$action" in
        branch-create)  shift; _gh_branch_create "$@"; return $? ;;
        branch-push)    shift; _gh_branch_push "$@"; return $? ;;
        cleanup-workdir) shift; _cleanup_workdir "$@"; return $? ;;
    esac

    local toml="${2:-}"

    if [[ -z "$toml" ]]; then
        echo "Usage: kodo-git.sh <action> <repo-toml> [args...]" >&2
        exit 1
    fi

    if [[ ! -f "$toml" ]]; then
        # Try resolving from repos/ dir
        if [[ -f "$KODO_HOME/repos/${toml}.toml" ]]; then
            toml="$KODO_HOME/repos/${toml}.toml"
        else
            kodo_log "ERROR: repo config not found: $toml"
            exit 1
        fi
    fi

    local provider slug
    provider="$(_resolve_provider "$toml")"
    slug="$(_resolve_slug "$toml")"

    shift 2

    # Write actions require shadow mode check
    local write_actions="pr-comment pr-merge pr-create branch-push issue-comment issue-close issue-label release-edit discussion-create"
    if [[ " $write_actions " == *" $action "* ]]; then
        if ! _guard_write "$toml" "$action"; then
            return 0
        fi
    fi

    case "$provider" in
        github)
            case "$action" in
                pr-list)            _gh_pr_list "$slug" ;;
                pr-comment)         _gh_pr_comment "$slug" "$@" ;;
                pr-merge)           _gh_pr_merge "$slug" "$@" ;;
                pr-checks)          _gh_pr_checks "$slug" "$@" ;;
                pr-diff)            _gh_pr_diff "$slug" "$@" ;;
                issue-list)         _gh_issue_list "$slug" ;;
                issue-comment)      _gh_issue_comment "$slug" "$@" ;;
                issue-close)        _gh_issue_close "$slug" "$@" ;;
                issue-label)        _gh_issue_label "$slug" "$@" ;;
                release-get)        _gh_release_get "$slug" "$@" ;;
                release-edit)       _gh_release_edit "$slug" "$@" ;;
                release-list)       _gh_release_list "$slug" ;;
                user-info)          _gh_user_info "$@" ;;
                discussion-create)  _gh_discussion_create "$slug" "$@" ;;
                milestone-list)     _gh_milestone_list "$slug" ;;
                compare)            _gh_compare "$slug" "$@" ;;
                repo-clone)         _gh_repo_clone "$slug" "$@" ;;
                pr-create)          _gh_pr_create "$slug" "$@" ;;
                issue-get)          _gh_issue_get "$slug" "$@" ;;
                *) kodo_log "ERROR: unknown action '$action'"; exit 1 ;;
            esac
            ;;
        gitlab)
            case "$action" in
                pr-list)            _glab_pr_list "$slug" ;;
                pr-comment)         _glab_pr_comment "$slug" "$@" ;;
                pr-merge)           _glab_pr_merge "$slug" "$@" ;;
                issue-list)         _glab_issue_list "$slug" ;;
                issue-comment)      _glab_issue_comment "$slug" "$@" ;;
                issue-close)        _glab_issue_close "$slug" "$@" ;;
                issue-label)        _glab_issue_label "$slug" "$@" ;;
                release-get)        _glab_release_get "$slug" "$@" ;;
                release-edit)       _glab_release_edit "$slug" "$@" ;;
                *) _stub_not_supported "$provider" "$action" ;;
            esac
            ;;
        gitea|bitbucket)
            _stub_not_supported "$provider" "$action"
            ;;
        *)
            kodo_log "ERROR: unknown provider '$provider'"
            exit 1
            ;;
    esac
}

main "$@"
