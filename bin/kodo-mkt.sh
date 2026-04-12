#!/usr/bin/env bash
set -euo pipefail

# Marketing / Community Ops Engine
# Handles: contributor welcome, changelogs, announcements, good-first-issues, spotlights
# Usage: kodo-mkt.sh <event_id> <repo_toml> <domain>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kodo-lib.sh
source "$SCRIPT_DIR/kodo-lib.sh"

kodo_init_db

readonly EVENT_ID="${1:-}"
readonly REPO_TOML="${2:-}"
# Domain is always "mkt" for this engine (passed as $3 but unused)

if [[ -z "$EVENT_ID" || -z "$REPO_TOML" ]]; then
    echo "Usage: kodo-mkt.sh <event_id> <repo_toml> [domain]" >&2
    exit 1
fi

REPO_ID="$(kodo_repo_id "$REPO_TOML")"
readonly REPO_ID
REPO_SLUG="$(kodo_repo_slug "$REPO_TOML")"
readonly REPO_SLUG
export KODO_TRANSITION_REPO="$REPO_ID"

# Concurrent processing guard
if ! kodo_claim_event "$EVENT_ID" "mkt"; then
    exit 0
fi
trap 'kodo_release_event "$EVENT_ID" "mkt"' EXIT

# ── Helpers ──────────────────────────────────────────────────

get_state() {
    kodo_sql "SELECT state FROM pipeline_state
        WHERE event_id = '$(kodo_sql_escape "$EVENT_ID")' AND domain = 'mkt';"
}

get_payload() {
    kodo_sql "SELECT payload_json FROM pipeline_state
        WHERE event_id = '$(kodo_sql_escape "$EVENT_ID")' AND domain = 'mkt';"
}

transition() {
    KODO_TRANSITION_OWNER_PID=$$ "$SCRIPT_DIR/kodo-transition.sh" "$EVENT_ID" "$1" "$2" "mkt"
}

# Check if action already performed (dedup)
_already_done() {
    local author="$1" action="$2"
    local count
    count=$(kodo_sql "SELECT COUNT(*) FROM community_log
        WHERE repo = '$(kodo_sql_escape "$REPO_ID")'
        AND author = '$(kodo_sql_escape "$author")'
        AND action = '$(kodo_sql_escape "$action")';")
    [[ "$count" -gt 0 ]]
}

_record_action() {
    local author="$1" action="$2"
    kodo_sql "INSERT OR IGNORE INTO community_log (repo, author, action)
        VALUES ('$(kodo_sql_escape "$REPO_ID")', '$(kodo_sql_escape "$author")', '$(kodo_sql_escape "$action")');"
}

_mkt_enabled() {
    kodo_toml_bool "$REPO_TOML" "mkt" "enabled" 2>/dev/null
}

_mkt_feature_enabled() {
    local feature="$1"
    kodo_toml_bool "$REPO_TOML" "mkt" "$feature" 2>/dev/null
}

_publish_without_action() {
    local state="$1" reason="$2"
    kodo_log "MKT: $reason — skipping $EVENT_ID"
    case "$state" in
        pending)
            transition "pending" "drafting"
            transition "drafting" "published"
            ;;
        drafting)
            transition "drafting" "published"
            ;;
        reviewing)
            transition "reviewing" "published"
            ;;
        *) ;;
    esac
}

_event_type() {
    local payload="$1" event_type
    event_type=$(echo "$payload" | jq -r '.event_type // .eventType // .type // empty' 2>/dev/null) || event_type=""
    if [[ -n "$event_type" ]]; then
        echo "$event_type"
        return
    fi

    if echo "$payload" | jq -e 'has("tagName") or has("tag_name")' >/dev/null 2>&1; then
        echo "ReleaseEvent"
    elif echo "$payload" | jq -e 'has("headRefName") or has("source_branch") or has("target_branch")' >/dev/null 2>&1; then
        echo "PullRequestEvent"
    elif echo "$payload" | jq -e 'has("dueOn") or has("due_on") or has("openIssues") or has("open_issues")' >/dev/null 2>&1; then
        echo "MilestoneEvent"
    elif [[ "$EVENT_ID" == *"ReleaseEvent"* ]]; then
        echo "ReleaseEvent"
    elif [[ "$EVENT_ID" == *"IssuesEvent"* ]]; then
        echo "IssuesEvent"
    elif [[ "$EVENT_ID" == *"IssueCommentEvent"* ]]; then
        echo "IssueCommentEvent"
    elif [[ "$EVENT_ID" == *"ForkEvent"* ]]; then
        echo "ForkEvent"
    elif [[ "$EVENT_ID" == *"WatchEvent"* ]]; then
        echo "WatchEvent"
    elif [[ "$EVENT_ID" == *"DiscussionEvent"* ]]; then
        echo "DiscussionEvent"
    else
        echo "PullRequestEvent"
    fi
}

# Load voice profile if exists
_load_voice() {
    local voice_file="$KODO_HOME/repos/${REPO_ID}.voice.md"
    if [[ -f "$voice_file" ]]; then
        cat "$voice_file"
    else
        local tone personality
        tone="$(kodo_toml_get "$REPO_TOML" "tone" 2>/dev/null)" || tone="professional and welcoming"
        personality="$(kodo_toml_get "$REPO_TOML" "personality" 2>/dev/null)" || personality=""
        echo "Tone: $tone"
        [[ -n "$personality" ]] && echo "Personality: $personality"
    fi
}

# ── Content Generators ───────────────────────────────────────

generate_welcome() {
    local payload="$1"
    local author pr_num
    author=$(echo "$payload" | jq -r '.author.login // .author // "contributor"' 2>/dev/null)
    pr_num=$(echo "$payload" | jq -r '.number // empty' 2>/dev/null)

    if ! _mkt_feature_enabled "welcome_new_contributors"; then
        kodo_log "MKT: welcome_new_contributors disabled for $REPO_ID"
        transition "drafting" "published"
        return
    fi

    # Dedup check
    if _already_done "$author" "welcomed"; then
        kodo_log "MKT: $author already welcomed on $REPO_ID — skipping"
        transition "drafting" "published"
        return
    fi

    if ! kodo_cli_available gemini; then
        kodo_log "MKT: gemini unavailable for welcome generation"
        transition "drafting" "deferred"
        return
    fi

    local voice
    voice="$(_load_voice)"

    local prompt
    prompt="$(kodo_prompt "Write a brief, warm welcome message for a first-time contributor to the $REPO_SLUG open source project.
Their username is @$author.

Voice profile:
$voice

Guidelines:
- Keep it under 100 words
- Be genuine, not corporate
- Mention that their contribution matters
- Do NOT use exclamation marks excessively
- Do NOT use the word 'excited'")"

    local message
    message=$(timeout 60 gemini -p "$prompt" </dev/null 2>/dev/null) || {
        transition "drafting" "deferred"
        return
    }
    kodo_log_budget "gemini" "$REPO_ID" "mkt" 0 0 0.0

    # Post welcome comment on the correct API surface (PR vs Issue)
    if [[ -z "$pr_num" ]]; then
        kodo_log "MKT: no issue/PR number in payload for welcome"
        transition "drafting" "published"
        return
    fi

    local posted=false
    if [[ "$EVENT_ID" == *"IssuesEvent"* || "$EVENT_ID" == *"IssueCommentEvent"* ]]; then
        "$SCRIPT_DIR/kodo-git.sh" issue-comment "$REPO_TOML" "$pr_num" "$message" 2>/dev/null && posted=true
    else
        "$SCRIPT_DIR/kodo-git.sh" pr-comment "$REPO_TOML" "$pr_num" "$message" 2>/dev/null && posted=true
    fi

    if [[ "$posted" == "true" || "$(kodo_toml_get "$REPO_TOML" "repo" "mode" 2>/dev/null)" == "shadow" ]]; then
        _record_action "$author" "welcomed"
    fi
    transition "drafting" "published"
    kodo_log "MKT: welcomed $author on $REPO_ID"
}

generate_changelog() {
    local payload="$1"
    local tag
    tag=$(echo "$payload" | jq -r '.tagName // .tag_name // empty' 2>/dev/null)

    if ! _mkt_feature_enabled "generate_changelogs"; then
        kodo_log "MKT: generate_changelogs disabled for $REPO_ID"
        transition "drafting" "published"
        return
    fi

    if [[ -z "$tag" ]]; then
        transition "drafting" "deferred"
        return
    fi

    if _already_done "$tag" "changelog_generated"; then
        transition "drafting" "published"
        return
    fi

    if ! kodo_cli_available gemini; then
        transition "drafting" "deferred"
        return
    fi

    local voice
    voice="$(_load_voice)"

    # Get release info
    local release_info
    release_info=$("$SCRIPT_DIR/kodo-git.sh" release-get "$REPO_TOML" "$tag" 2>/dev/null) || release_info="{}"

    local prompt
    prompt="$(kodo_prompt "Generate release notes for $REPO_SLUG version $tag.

Release info: $release_info

Voice profile:
$voice

Guidelines:
- Group changes by type: Features, Fixes, Internal
- Highlight user-facing changes first
- Keep it concise but informative
- Use markdown formatting")"

    local changelog
    changelog=$(timeout 120 gemini -p "$prompt" </dev/null 2>/dev/null) || {
        transition "drafting" "deferred"
        return
    }
    kodo_log_budget "gemini" "$REPO_ID" "mkt" 0 0 0.0

    # Quality review for releases (Claude, if available and enabled)
    if kodo_cli_available claude && kodo_check_budget "claude"; then
        local reviewed
        reviewed=$(timeout 60 claude -p "Review and improve this changelog for accuracy and tone. Return only markdown, with no preamble.

$changelog" </dev/null 2>/dev/null) || reviewed=""
        if [[ -n "$reviewed" ]]; then
            changelog="$reviewed"
        fi
        kodo_log_budget "claude" "$REPO_ID" "mkt" 0 0 0.0
        transition "drafting" "reviewing"
    else
        # Skip review, go straight to publishing after release-edit
        transition "drafting" "reviewing"
    fi

    # Update release notes — only publish if edit succeeds
    if "$SCRIPT_DIR/kodo-git.sh" release-edit "$REPO_TOML" "$tag" "$changelog" 2>/dev/null; then
        transition "reviewing" "published"
    else
        kodo_log "MKT: release-edit failed for $tag — deferring"
        transition "reviewing" "deferred"
        return
    fi

    _record_action "$tag" "changelog_generated"
    kodo_log "MKT: changelog generated for $REPO_ID $tag"
}

generate_announcement() {
    local payload="$1"
    kodo_log "MKT: announcement generation for $EVENT_ID"
    # Announcements follow same pattern as changelog but for discussions
    transition "drafting" "published"
}

# ── Main State Machine ──────────────────────────────────────

main() {
    local state
    state="$(get_state)"

    if [[ -z "$state" ]]; then
        kodo_log "MKT: no state for $EVENT_ID — skipping"
        exit 0
    fi

    kodo_log "MKT: processing $EVENT_ID (state: $state)"

    if ! _mkt_enabled; then
        _publish_without_action "$state" "[mkt].enabled is false"
        return
    fi

    case "$state" in
        pending)
            transition "pending" "drafting"

            local payload
            payload="$(get_payload)"
            [[ -z "$payload" ]] && payload='{}'

            # Prefer provider payload shape; fall back to scout event id encoding.
            local event_type
            event_type="$(_event_type "$payload")"

            case "$event_type" in
                PullRequestEvent|IssueCommentEvent|IssuesEvent)
                    generate_welcome "$payload"
                    ;;
                ReleaseEvent)
                    generate_changelog "$payload"
                    ;;
                ForkEvent|WatchEvent|DiscussionEvent)
                    generate_announcement "$payload"
                    ;;
                *)
                    transition "drafting" "published"
                    ;;
            esac
            ;;
        drafting)
            # Re-execute content generation (engine may have died mid-drafting)
            local payload
            payload="$(get_payload)"
            [[ -z "$payload" ]] && payload='{}'

            local event_type
            event_type="$(_event_type "$payload")"

            kodo_log "MKT: resuming $EVENT_ID in drafting (re-generating content)"
            case "$event_type" in
                PullRequestEvent|IssueCommentEvent|IssuesEvent)
                    generate_welcome "$payload"
                    ;;
                ReleaseEvent)
                    generate_changelog "$payload"
                    ;;
                ForkEvent|WatchEvent|DiscussionEvent)
                    generate_announcement "$payload"
                    ;;
                *)
                    transition "drafting" "published"
                    ;;
            esac
            ;;
        reviewing)
            kodo_log "MKT: $EVENT_ID in review"
            ;;
        published)
            kodo_log "MKT: $EVENT_ID already published"
            ;;
        deferred)
            kodo_log "MKT: $EVENT_ID deferred"
            ;;
        *)
            kodo_log "MKT: unknown state '$state' for $EVENT_ID"
            ;;
    esac
}

main
