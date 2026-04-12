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
        return 3  # distinct code: 3 = shadow blocked (not error)
    fi
    return 0
}

# ── GitHub (gh) ──────────────────────────────────────────────

_gh_pr_list() {
    local slug="$1"
    gh pr list --repo "$slug" --json number,title,state,headRefName,author,authorAssociation,labels,createdAt,updatedAt --limit 50
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
    local raw
    raw=$(gh pr checks "$pr_num" --repo "$slug" --json name,state,bucket 2>&1) || {
        kodo_log "ERROR: gh pr checks failed for $slug #$pr_num: ${raw:0:200}"
        return 1
    }
    echo "$raw" | jq -c '{
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

# Check if PR is mergeable (MERGEABLE, CONFLICTING, UNKNOWN) and branch status (CLEAN, BEHIND, DIRTY)
_gh_pr_mergeable() {
    local slug="$1" pr_num="$2"
    gh pr view "$pr_num" --repo "$slug" \
        --json mergeable,mergeStateStatus,headRefName,baseRefName \
        2>/dev/null || echo '{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN"}'
}

# Server-side branch update (rebase from base branch)
# Returns: 0 = rebased cleanly, 1 = conflict, 2 = API error
_gh_pr_rebase() {
    local slug="$1" pr_num="$2"
    local response
    if response=$(gh api "repos/${slug}/pulls/${pr_num}/update-branch" \
            -X PUT -f update_method=rebase 2>&1); then
        return 0
    fi
    # 422 = merge conflict
    if echo "$response" | grep -qiE "merge conflict|cannot be updated|unprocessable"; then
        return 1
    fi
    return 2
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

_gh_event_list() {
    local slug="$1"
    gh api "repos/$slug/events?per_page=50" --jq '[.[] | {
        id,
        type,
        created_at,
        actor: {login: .actor.login, type: "User"},
        payload: .payload
    }]'
}

_gh_issue_comments() {
    local slug="$1" issue_num="$2"
    gh api "repos/${slug}/issues/${issue_num}/comments?per_page=50" --jq \
        '[.[] | {id: (.id | tostring), body, author: {login: .user.login, type: .user.type}, createdAt: .created_at, updatedAt: .updated_at}]'
}

_gh_compare() {
    local slug="$1" base="$2" head="$3"
    gh api "repos/$slug/compare/${base}...${head}" --jq '.commits[] | {sha: .sha[0:7], message: .commit.message}'
}

# Get labels on an issue (read-only)
_gh_issue_labels_get() {
    local slug="$1" issue_num="$2"
    gh api "repos/${slug}/issues/${issue_num}/labels" --jq '[.[].name]' 2>/dev/null || echo '[]'
}

# Get reaction counts on an issue comment (read-only)
_gh_comment_reactions() {
    local slug="$1" comment_id="$2"
    gh api "repos/${slug}/issues/comments/${comment_id}/reactions" --jq '{
        thumbs_up: [.[] | select(.content == "+1")] | length,
        thumbs_down: [.[] | select(.content == "-1")] | length
    }' 2>/dev/null || echo '{"thumbs_up":0,"thumbs_down":0}'
}

# ── GitLab (glab) ────────────────────────────────────────────

_glab_pr_list() {
    local slug="$1"
    glab mr list --repo "$slug" --output json 2>/dev/null || { kodo_log "ERROR: glab mr list failed for $slug"; return 1; }
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
    glab issue list --repo "$slug" --output json 2>/dev/null || { kodo_log "ERROR: glab issue list failed for $slug"; return 1; }
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
    glab release view "$tag" --repo "$slug" --output json 2>/dev/null || { kodo_log "ERROR: glab release view failed for $slug $tag"; return 1; }
}

_glab_release_edit() {
    local slug="$1" tag="$2" notes="$3"
    glab release edit "$tag" --repo "$slug" --notes "$notes"
}

_glab_release_list() {
    local slug="$1"
    glab release list -R "$slug" --output json 2>/dev/null | jq -c '[.[:10][] | {tagName: .tag_name, name: .name, createdAt: .released_at}]' \
        || { kodo_log "ERROR: glab release list failed for $slug"; return 1; }
}

# URL-encode project path for GitLab REST API (owner/repo → owner%2Frepo)
_glab_project_id() {
    local slug="$1"
    echo "${slug/\//%2F}"
}

# Pipeline status for an MR — matches _gh_pr_checks output shape
_glab_pr_checks() {
    local slug="$1" mr_iid="$2"
    local proj_id pipeline_id raw jobs
    proj_id=$(_glab_project_id "$slug")

    # Get latest pipeline for the MR
    raw=$(glab api "projects/${proj_id}/merge_requests/${mr_iid}/pipelines" --per-page 1 2>&1) || {
        kodo_log "ERROR: glab pr-checks failed for $slug !$mr_iid: ${raw:0:200}"
        return 1
    }

    pipeline_id=$(echo "$raw" | jq -r '.[0].id // empty')
    if [[ -z "$pipeline_id" ]]; then
        echo '{"state":"NO_CHECKS","pass":0,"fail":0,"pending":0,"total":0}'
        return 0
    fi

    # Get jobs for granular counts
    jobs=$(glab api "projects/${proj_id}/pipelines/${pipeline_id}/jobs" 2>/dev/null) || {
        # Fallback: use pipeline-level status
        echo "$raw" | jq -c '.[0] | {
            total: 1,
            pass: (if .status == "success" then 1 else 0 end),
            fail: (if (.status == "failed" or .status == "canceled") then 1 else 0 end),
            pending: (if (.status == "running" or .status == "pending" or .status == "created") then 1 else 0 end),
            state: (
                if (.status == "failed" or .status == "canceled") then "FAILURE"
                elif (.status == "running" or .status == "pending" or .status == "created") then "PENDING"
                elif .status == "success" then "SUCCESS"
                else "NEUTRAL"
                end
            )
        }'
        return 0
    }

    echo "$jobs" | jq -c '{
        total: length,
        pass: [.[] | select(.status == "success")] | length,
        fail: [.[] | select(.status == "failed" or .status == "canceled")] | length,
        pending: [.[] | select(.status == "running" or .status == "pending" or .status == "created")] | length,
        state: (
            if length == 0 then "NO_CHECKS"
            elif ([.[] | select(.status == "failed" or .status == "canceled")] | length) > 0 then "FAILURE"
            elif ([.[] | select(.status == "running" or .status == "pending" or .status == "created")] | length) > 0 then "PENDING"
            else "SUCCESS"
            end
        )
    }'
}

# CI status for a specific commit — matches _gh_commit_checks output shape
_glab_commit_checks() {
    local slug="$1" sha="$2"
    local proj_id raw
    proj_id=$(_glab_project_id "$slug")
    raw=$(glab api "projects/${proj_id}/repository/commits/${sha}/statuses" 2>&1) || {
        kodo_log "ERROR: glab commit-checks failed for $slug $sha: ${raw:0:200}"
        return 1
    }
    echo "$raw" | jq -c '{
        total: length,
        pass: [.[] | select(.status == "success")] | length,
        fail: [.[] | select(.status == "failed" or .status == "canceled")] | length,
        pending: [.[] | select(.status == "running" or .status == "pending" or .status == "created")] | length,
        state: (
            if length == 0 then "NO_CHECKS"
            elif ([.[] | select(.status == "failed" or .status == "canceled")] | length) > 0 then "FAILURE"
            elif ([.[] | select(.status == "running" or .status == "pending" or .status == "created")] | length) > 0 then "PENDING"
            else "SUCCESS"
            end
        )
    }'
}

_glab_pr_diff() {
    local slug="$1" mr_iid="$2"
    glab mr diff "$mr_iid" -R "$slug"
}

# MR mergeability — matches _gh_pr_mergeable output shape
_glab_pr_mergeable() {
    local slug="$1" mr_iid="$2"
    local proj_id raw
    proj_id=$(_glab_project_id "$slug")
    raw=$(glab api "projects/${proj_id}/merge_requests/${mr_iid}" 2>/dev/null) || {
        echo '{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN"}'
        return 0
    }
    echo "$raw" | jq -c '{
        mergeable: (
            if .merge_status == "can_be_merged" then "MERGEABLE"
            elif .merge_status == "cannot_be_merged" then "CONFLICTING"
            elif .merge_status == "cannot_be_merged_recheck" then "UNKNOWN"
            else "UNKNOWN"
            end
        ),
        mergeStateStatus: (
            if .has_conflicts == true then "DIRTY"
            elif .merge_status == "can_be_merged" then "CLEAN"
            elif .merge_status == "unchecked" then "UNKNOWN"
            else "UNKNOWN"
            end
        ),
        headRefName: .source_branch,
        baseRefName: .target_branch
    }'
}

# Server-side rebase — matches _gh_pr_rebase return codes
# Returns: 0 = accepted, 1 = conflict, 2 = API error
_glab_pr_rebase() {
    local slug="$1" mr_iid="$2"
    local proj_id response
    proj_id=$(_glab_project_id "$slug")
    if response=$(glab api -X PUT "projects/${proj_id}/merge_requests/${mr_iid}/rebase" 2>&1); then
        # Check if rebase was accepted (rebase_in_progress == true)
        if echo "$response" | jq -e '.rebase_in_progress == true' >/dev/null 2>&1; then
            return 0
        fi
        # Might already be merged or no rebase needed
        return 0
    fi
    if echo "$response" | grep -qiE "conflict|cannot be rebased|rebase in progress"; then
        return 1
    fi
    return 2
}

# Review approvals — matches _gh_pr_reviews output shape
_glab_pr_reviews() {
    local slug="$1" mr_iid="$2"
    local proj_id
    proj_id=$(_glab_project_id "$slug")
    glab api "projects/${proj_id}/merge_requests/${mr_iid}/approvals" 2>/dev/null \
        | jq -c '[(.approved_by // [])[] | {
            id: (.user.id | tostring),
            author: .user.username,
            author_type: "User",
            state: "APPROVED",
            body: "",
            submitted_at: ""
        }]' 2>/dev/null || echo "[]"
}

# Inline diff notes — matches _gh_pr_review_comments output shape
_glab_pr_review_comments() {
    local slug="$1" mr_iid="$2"
    local proj_id
    proj_id=$(_glab_project_id "$slug")
    glab api "projects/${proj_id}/merge_requests/${mr_iid}/notes" --per-page 100 2>/dev/null \
        | jq -c '[.[] | select(.type == "DiffNote") | {
            id: (.id | tostring),
            author: .author.username,
            author_type: (if .author.bot then "Bot" else "User" end),
            body: .body,
            path: (.position.new_path // .position.old_path // ""),
            line: (.position.new_line // .position.old_line // 0),
            created_at: .created_at
        }]' 2>/dev/null || echo "[]"
}

# Apply a GitLab suggestion by ID
_glab_pr_apply_suggestion() {
    local work_dir="$1" file_path="$2" line_num="$3" suggestion_text="$4" commit_msg="$5"
    # Same manual file-edit + commit approach as GitHub
    (
        cd "$work_dir" || return 1
        if [[ ! -f "$file_path" ]]; then
            return 1
        fi
        local tmp_file
        tmp_file=$(mktemp)
        awk -v line="$line_num" -v replacement="$suggestion_text" '
            NR == line { print replacement; next }
            { print }
        ' "$file_path" > "$tmp_file" && mv "$tmp_file" "$file_path"
        git add "$file_path"
        git commit -m "$commit_msg" --no-verify
    )
}

# Merge commit SHA for a merged MR
_glab_pr_merge_sha() {
    local slug="$1" mr_iid="$2"
    local proj_id
    proj_id=$(_glab_project_id "$slug")
    glab api "projects/${proj_id}/merge_requests/${mr_iid}" 2>/dev/null \
        | jq -r '.merge_commit_sha // empty'
}

# ── Repo Operations (provider-agnostic) ─────────────────────

# Clone a repo to a temporary working directory
# Returns: path to the cloned directory on stdout
_gh_repo_clone() {
    local slug="$1" branch="${2:-}"
    mkdir -p "$KODO_HOME/.workdir"
    local work_dir
    work_dir=$(mktemp -d "$KODO_HOME/.workdir/${slug//\//-}-XXXXXX") || return 1

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
    ( cd "$work_dir" && git checkout -b "$branch_name" )
}

# Create a PR from a branch
_gh_pr_create() {
    local slug="$1" branch="$2" title="$3" body="$4"
    gh pr create --repo "$slug" --head "$branch" --title "$title" --body "$body"
}

# Push a branch from a working directory
_gh_branch_push() {
    local work_dir="$1" branch_name="$2"
    ( cd "$work_dir" && git push --force-with-lease origin "$branch_name" )
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

# ── PR Feedback ──────────────────────────────────────────────

# Fetch all reviews on a PR (approval, changes_requested, commented)
_gh_pr_reviews() {
    local slug="$1" pr_num="$2"
    gh api "repos/${slug}/pulls/${pr_num}/reviews" --jq \
        '[.[] | {id: (.id | tostring), author: .user.login, author_type: .user.type, state: .state, body: .body, submitted_at: .submitted_at}]' \
        2>/dev/null || echo "[]"
}

# Fetch inline review comments (contains suggestion blocks)
_gh_pr_review_comments() {
    local slug="$1" pr_num="$2"
    gh api "repos/${slug}/pulls/${pr_num}/comments" --jq \
        '[.[] | {id: (.id | tostring), author: .user.login, author_type: .user.type, body: .body, path: .path, line: (.line // .original_line // 0), created_at: .created_at}]' \
        2>/dev/null || echo "[]"
}

# Apply a suggestion patch in a working directory and commit
# Usage: _gh_pr_apply_suggestion <work_dir> <file_path> <line_num> <suggestion_text> <commit_msg>
_gh_pr_apply_suggestion() {
    local work_dir="$1" file_path="$2" line_num="$3" suggestion_text="$4" commit_msg="$5"
    (
        cd "$work_dir" || return 1
        if [[ ! -f "$file_path" ]]; then
            return 1
        fi
        # Replace the target line(s) with the suggestion text
        # GitHub suggestions replace the line at the given position
        local tmp_file
        tmp_file=$(mktemp)
        awk -v line="$line_num" -v replacement="$suggestion_text" '
            NR == line { print replacement; next }
            { print }
        ' "$file_path" > "$tmp_file" && mv "$tmp_file" "$file_path"
        git add "$file_path"
        git commit -m "$commit_msg" --no-verify
    )
}

# ── Post-Merge Monitoring ───────────────────────────────────

# Get the merge commit SHA for a merged PR
_gh_pr_merge_sha() {
    local slug="$1" pr_num="$2"
    gh pr view "$pr_num" --repo "$slug" --json mergeCommit --jq '.mergeCommit.oid' 2>/dev/null
}

# Check CI status for a specific commit on the default branch
# Returns JSON: {state, pass, fail, pending, total}
_gh_commit_checks() {
    local slug="$1" sha="$2"
    local raw
    raw=$(gh api "repos/${slug}/commits/${sha}/check-runs" --jq '[.check_runs[] | {name, status, conclusion}]' 2>&1) || {
        kodo_log "ERROR: commit-checks failed for $slug $sha: ${raw:0:200}"
        return 1
    }
    echo "$raw" | jq -c '{
        total: length,
        pass: [.[] | select(.conclusion == "success")] | length,
        fail: [.[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out")] | length,
        pending: [.[] | select(.status != "completed")] | length,
        state: (
            if length == 0 then "NO_CHECKS"
            elif ([.[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out")] | length) > 0 then "FAILURE"
            elif ([.[] | select(.status != "completed")] | length) > 0 then "PENDING"
            else "SUCCESS"
            end
        )
    }'
}

# Create and merge a revert PR for a merge commit
# Uses manual git-revert flow (gh has no native pr-revert)
_gh_pr_revert() {
    local slug="$1" merge_sha="$2" event_id="${3:-}" pr_title="${4:-}"
    local branch_name="kodo/dev/revert-${event_id:-${merge_sha:0:12}}"
    local work_dir

    work_dir=$(_gh_repo_clone "$slug") || {
        kodo_log "ERROR: failed to clone $slug for revert"
        return 1
    }

    (
        cd "$work_dir" || return 1
        git revert "$merge_sha" --no-edit 2>/dev/null || {
            kodo_log "ERROR: git revert $merge_sha failed — likely conflict"
            return 1
        }
        git checkout -b "$branch_name"
    ) || {
        rm -rf "$work_dir"
        return 1
    }

    _gh_branch_push "$work_dir" "$branch_name" 2>/dev/null || {
        rm -rf "$work_dir"
        return 1
    }

    local revert_title="[kodo-dev] Revert: ${pr_title:-merge $merge_sha}"
    local revert_body
    revert_body="Automated revert by KŌDŌ post-merge monitoring.

**Reason:** CI regression detected after merge.
**Original merge SHA:** \`${merge_sha}\`
**Event ID:** \`${event_id}\`

This revert was triggered because main-branch CI checks failed within the monitoring window."

    local pr_url
    pr_url=$(_gh_pr_create "$slug" "$branch_name" "$revert_title" "$revert_body" 2>/dev/null) || {
        rm -rf "$work_dir"
        return 1
    }

    # Extract PR number from URL
    local revert_pr_num
    revert_pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$')

    # Wait for CI to start before merging the revert
    sleep 60

    local revert_checks revert_state
    revert_checks=$(_gh_pr_checks "$slug" "$revert_pr_num" 2>/dev/null) || {
        kodo_log "ERROR: failed to check revert PR #$revert_pr_num CI"
        rm -rf "$work_dir"
        return 1
    }
    revert_state=$(echo "$revert_checks" | jq -r '.state // "UNKNOWN"' 2>/dev/null)
    if [[ "$revert_state" != "SUCCESS" && "$revert_state" != "NO_CHECKS" ]]; then
        kodo_log "ERROR: revert PR #$revert_pr_num CI not green ($revert_state)"
        rm -rf "$work_dir"
        return 1
    fi

    _gh_pr_merge "$slug" "$revert_pr_num" 2>/dev/null || {
        kodo_log "ERROR: failed to merge revert PR #$revert_pr_num"
        rm -rf "$work_dir"
        return 1
    }

    rm -rf "$work_dir"
    kodo_log "REVERT: merged revert PR #$revert_pr_num for $slug ($merge_sha)"
    return 0
}

# ── GitLab Repo / Issue / Misc ──────────────────────────────

# Create a branch in a local clone (provider-agnostic, mirrors _gh_branch_create)
_glab_branch_create() {
    local work_dir="$1" branch_name="$2"
    ( cd "$work_dir" && git checkout -b "$branch_name" )
}

_glab_repo_clone() {
    local slug="$1" branch="${2:-}"
    mkdir -p "$KODO_HOME/.workdir"
    local work_dir
    work_dir=$(mktemp -d "$KODO_HOME/.workdir/${slug//\//-}-XXXXXX") || return 1

    local clone_args=(--depth 50 --single-branch)
    if [[ -n "$branch" ]]; then
        clone_args+=(--branch "$branch")
    fi

    if glab repo clone "$slug" "$work_dir" -- "${clone_args[@]}" >/dev/null 2>&1; then
        echo "$work_dir"
        return 0
    else
        rm -rf "$work_dir"
        return 1
    fi
}

_glab_pr_create() {
    local slug="$1" branch="$2" title="$3" body="$4"
    glab mr create -R "$slug" -s "$branch" -t "$title" -d "$body" --yes
}

_glab_branch_push() {
    local work_dir="$1" branch_name="$2"
    ( cd "$work_dir" && git push --force-with-lease origin "$branch_name" )
}

# Full issue details — matches _gh_issue_get output shape
_glab_issue_get() {
    local slug="$1" issue_iid="$2"
    local proj_id issue_data notes_data
    proj_id=$(_glab_project_id "$slug")
    issue_data=$(glab api "projects/${proj_id}/issues/${issue_iid}" 2>/dev/null) || {
        kodo_log "ERROR: glab issue-get failed for $slug #$issue_iid"
        return 1
    }
    notes_data=$(glab api "projects/${proj_id}/issues/${issue_iid}/notes" --per-page 100 2>/dev/null) || notes_data="[]"

    # Combine into the expected shape
    jq -nc --argjson issue "$issue_data" --argjson notes "$notes_data" '{
        number: $issue.iid,
        title: $issue.title,
        body: ($issue.description // ""),
        labels: ($issue.labels // []),
        comment_count: ($notes | length),
        last_comments: [$notes | sort_by(.created_at) | .[-3:][] | {author: .author.username, body: .body[:500]}]
    }'
}

# Issue labels — upgrade from stub
_glab_issue_labels_get() {
    local slug="$1" issue_iid="$2"
    local proj_id
    proj_id=$(_glab_project_id "$slug")
    glab api "projects/${proj_id}/issues/${issue_iid}" 2>/dev/null \
        | jq -c '.labels // []' 2>/dev/null || echo '[]'
}

# Comment reactions via award emoji — upgrade from stub
_glab_comment_reactions() {
    local slug="$1" note_id="$2"
    # GitLab award_emoji on issue notes requires issue_iid + note_id;
    # since we only get note_id from callers, use global note lookup
    local proj_id
    proj_id=$(_glab_project_id "$slug")
    # Try merge request notes first, then issue notes
    local emojis
    emojis=$(glab api "projects/${proj_id}/merge_requests/notes/${note_id}/award_emoji" 2>/dev/null) \
        || emojis="[]"
    echo "$emojis" | jq -c '{
        thumbs_up: [.[] | select(.name == "thumbsup")] | length,
        thumbs_down: [.[] | select(.name == "thumbsdown")] | length
    }' 2>/dev/null || echo '{"thumbs_up":0,"thumbs_down":0}'
}

_glab_user_info() {
    local username="$1"
    glab api "users?username=${username}" 2>/dev/null \
        | jq -c '.[0] // {} | {login: .username, name: .name, type: (if .bot then "Bot" else "User" end)}' \
        2>/dev/null || echo '{}'
}

_glab_discussion_create() {
    local slug="$1" category="$2" title="$3" body="$4"
    local proj_id
    proj_id=$(_glab_project_id "$slug")
    # GitLab discussions are on issues/MRs, not repo-level like GitHub Discussions.
    # Create as an issue with the discussion label for closest equivalent.
    glab api -X POST "projects/${proj_id}/issues" -f "title=${title}" -f "description=${body}" -f "labels=discussion" 2>/dev/null
}

_glab_milestone_list() {
    local slug="$1"
    local proj_id
    proj_id=$(_glab_project_id "$slug")
    glab api "projects/${proj_id}/milestones?state=active" 2>/dev/null \
        | jq -c '[.[] | {number: .id, title: .title, open_issues: (.issues_count // 0), closed_issues: (.closed_issues_count // 0), due_on: .due_date, state: .state}]' \
        2>/dev/null || echo '[]'
}

_glab_event_list() {
    local slug="$1"
    local proj_id
    proj_id=$(_glab_project_id "$slug")
    glab api "projects/${proj_id}/events?per_page=50" 2>/dev/null \
        | jq -c '[.[] | {
            id: (.id | tostring),
            type: (if .action_name == "pushed to" then "PushEvent" else "GitLabEvent" end),
            created_at: .created_at,
            actor: {login: .author.username, type: (if .author.bot then "Bot" else "User" end)},
            payload: .
        }]' 2>/dev/null || echo '[]'
}

_glab_issue_comments() {
    local slug="$1" issue_iid="$2"
    local proj_id
    proj_id=$(_glab_project_id "$slug")
    glab api "projects/${proj_id}/issues/${issue_iid}/notes?per_page=50" 2>/dev/null \
        | jq -c '[.[] | {id: (.id | tostring), body, author: {login: .author.username, type: (if .author.bot then "Bot" else "User" end)}, createdAt: .created_at, updatedAt: .updated_at}]' \
        2>/dev/null || echo '[]'
}

_glab_compare() {
    local slug="$1" base="$2" head="$3"
    local proj_id
    proj_id=$(_glab_project_id "$slug")
    glab api "projects/${proj_id}/repository/compare?from=${base}&to=${head}" 2>/dev/null \
        | jq -c '[.commits[] | {sha: .short_id, message: .message}]' \
        2>/dev/null || echo '[]'
}

# Create and merge a revert MR — same manual flow as GitHub
_glab_pr_revert() {
    local slug="$1" merge_sha="$2" event_id="${3:-}" pr_title="${4:-}"
    local branch_name="kodo/dev/revert-${event_id:-${merge_sha:0:12}}"
    local work_dir

    work_dir=$(_glab_repo_clone "$slug") || {
        kodo_log "ERROR: failed to clone $slug for revert"
        return 1
    }

    (
        cd "$work_dir" || return 1
        git revert "$merge_sha" --no-edit 2>/dev/null || {
            kodo_log "ERROR: git revert $merge_sha failed — likely conflict"
            return 1
        }
        git checkout -b "$branch_name"
    ) || {
        rm -rf "$work_dir"
        return 1
    }

    _glab_branch_push "$work_dir" "$branch_name" 2>/dev/null || {
        rm -rf "$work_dir"
        return 1
    }

    local revert_title="[kodo-dev] Revert: ${pr_title:-merge $merge_sha}"
    local revert_body
    revert_body="Automated revert by KŌDŌ post-merge monitoring.

**Reason:** CI regression detected after merge.
**Original merge SHA:** \`${merge_sha}\`
**Event ID:** \`${event_id}\`

This revert was triggered because main-branch CI checks failed within the monitoring window."

    local mr_url
    mr_url=$(_glab_pr_create "$slug" "$branch_name" "$revert_title" "$revert_body" 2>/dev/null) || {
        rm -rf "$work_dir"
        return 1
    }

    # Extract MR number from URL (GitLab MR URLs end with merge_requests/<iid>)
    local revert_mr_iid
    revert_mr_iid=$(echo "$mr_url" | grep -oE '[0-9]+$')

    # Wait for CI to start before merging the revert
    sleep 60

    local revert_checks revert_state
    revert_checks=$(_glab_pr_checks "$slug" "$revert_mr_iid" 2>/dev/null) || {
        kodo_log "ERROR: failed to check revert MR !$revert_mr_iid CI"
        rm -rf "$work_dir"
        return 1
    }
    revert_state=$(echo "$revert_checks" | jq -r '.state // "UNKNOWN"' 2>/dev/null)
    if [[ "$revert_state" != "SUCCESS" && "$revert_state" != "NO_CHECKS" ]]; then
        kodo_log "ERROR: revert MR !$revert_mr_iid CI not green ($revert_state)"
        rm -rf "$work_dir"
        return 1
    fi

    _glab_pr_merge "$slug" "$revert_mr_iid" 2>/dev/null || {
        kodo_log "ERROR: failed to merge revert MR !$revert_mr_iid"
        rm -rf "$work_dir"
        return 1
    }

    rm -rf "$work_dir"
    kodo_log "REVERT: merged revert MR !$revert_mr_iid for $slug ($merge_sha)"
    return 0
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
    local write_actions="pr-comment pr-merge pr-create branch-push issue-comment issue-close issue-label issue-create release-edit discussion-create pr-apply-suggestion pr-rebase pr-revert"
    if [[ " $write_actions " == *" $action "* ]]; then
        _guard_write "$toml" "$action" || return $?
    fi

    # Provider capabilities query — returns JSON list of supported actions
    if [[ "$action" == "provider-capabilities" ]]; then
        case "$provider" in
            github)
                echo '["pr-list","pr-comment","pr-merge","pr-checks","pr-diff","issue-list","issue-comment","issue-close","issue-label","release-get","release-edit","release-list","user-info","discussion-create","milestone-list","event-list","issue-comments","compare","repo-info","issue-create","repo-clone","pr-create","issue-get","branch-push","pr-mergeable","pr-rebase","pr-reviews","pr-review-comments","pr-apply-suggestion","pr-merge-sha","commit-checks","pr-revert","issue-labels-get","comment-reactions"]'
                ;;
            gitlab)
                echo '["pr-list","pr-comment","pr-merge","pr-checks","pr-diff","issue-list","issue-comment","issue-close","issue-label","release-get","release-edit","release-list","user-info","discussion-create","milestone-list","event-list","issue-comments","compare","repo-info","issue-create","repo-clone","pr-create","issue-get","branch-push","pr-mergeable","pr-rebase","pr-reviews","pr-review-comments","pr-apply-suggestion","pr-merge-sha","commit-checks","pr-revert","issue-labels-get","comment-reactions"]'
                ;;
            *)
                echo '[]'
                ;;
        esac
        return 0
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
                event-list)         _gh_event_list "$slug" ;;
                issue-comments)     _gh_issue_comments "$slug" "$@" ;;
                compare)            _gh_compare "$slug" "$@" ;;
                repo-info)          gh api "repos/$slug" 2>/dev/null || echo "{}" ;;
                issue-create)       gh issue create --repo "$slug" --title "$1" --body "$2" 2>/dev/null ;;
                repo-clone)         _gh_repo_clone "$slug" "$@" ;;
                pr-create)          _gh_pr_create "$slug" "$@" ;;
                issue-get)          _gh_issue_get "$slug" "$@" ;;
                branch-push)        _gh_branch_push "$@" ;;
                pr-mergeable)       _gh_pr_mergeable "$slug" "$@" ;;
                pr-rebase)          _gh_pr_rebase "$slug" "$@" ;;
                pr-reviews)         _gh_pr_reviews "$slug" "$@" ;;
                pr-review-comments) _gh_pr_review_comments "$slug" "$@" ;;
                pr-apply-suggestion) _gh_pr_apply_suggestion "$@" ;;
                pr-merge-sha)       _gh_pr_merge_sha "$slug" "$@" ;;
                commit-checks)      _gh_commit_checks "$slug" "$@" ;;
                pr-revert)          _gh_pr_revert "$slug" "$@" ;;
                issue-labels-get)   _gh_issue_labels_get "$slug" "$@" ;;
                comment-reactions)  _gh_comment_reactions "$slug" "$@" ;;
                *) kodo_log "ERROR: unknown action '$action'"; exit 1 ;;
            esac
            ;;
        gitlab)
            case "$action" in
                pr-list)             _glab_pr_list "$slug" ;;
                pr-comment)          _glab_pr_comment "$slug" "$@" ;;
                pr-merge)            _glab_pr_merge "$slug" "$@" ;;
                pr-checks)           _glab_pr_checks "$slug" "$@" ;;
                pr-diff)             _glab_pr_diff "$slug" "$@" ;;
                issue-list)          _glab_issue_list "$slug" ;;
                issue-comment)       _glab_issue_comment "$slug" "$@" ;;
                issue-close)         _glab_issue_close "$slug" "$@" ;;
                issue-label)         _glab_issue_label "$slug" "$@" ;;
                release-get)         _glab_release_get "$slug" "$@" ;;
                release-edit)        _glab_release_edit "$slug" "$@" ;;
                release-list)        _glab_release_list "$slug" ;;
                user-info)           _glab_user_info "$@" ;;
                discussion-create)   _glab_discussion_create "$slug" "$@" ;;
                milestone-list)      _glab_milestone_list "$slug" ;;
                event-list)          _glab_event_list "$slug" ;;
                issue-comments)      _glab_issue_comments "$slug" "$@" ;;
                compare)             _glab_compare "$slug" "$@" ;;
                repo-info)           glab api "projects/$(_glab_project_id "$slug")" 2>/dev/null || echo "{}" ;;
                issue-create)        glab issue create -R "$slug" -t "$1" -d "$2" 2>/dev/null ;;
                repo-clone)          _glab_repo_clone "$slug" "$@" ;;
                pr-create)           _glab_pr_create "$slug" "$@" ;;
                issue-get)           _glab_issue_get "$slug" "$@" ;;
                branch-push)         _glab_branch_push "$@" ;;
                pr-mergeable)        _glab_pr_mergeable "$slug" "$@" ;;
                pr-rebase)           _glab_pr_rebase "$slug" "$@" ;;
                pr-reviews)          _glab_pr_reviews "$slug" "$@" ;;
                pr-review-comments)  _glab_pr_review_comments "$slug" "$@" ;;
                pr-apply-suggestion) _glab_pr_apply_suggestion "$@" ;;
                pr-merge-sha)        _glab_pr_merge_sha "$slug" "$@" ;;
                commit-checks)       _glab_commit_checks "$slug" "$@" ;;
                pr-revert)           _glab_pr_revert "$slug" "$@" ;;
                issue-labels-get)    _glab_issue_labels_get "$slug" "$@" ;;
                comment-reactions)   _glab_comment_reactions "$slug" "$@" ;;
                *) kodo_log "ERROR: unknown action '$action'"; exit 1 ;;
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
