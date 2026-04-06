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
readonly DOMAIN="${3:-mkt}"

if [[ -z "$EVENT_ID" || -z "$REPO_TOML" ]]; then
    echo "Usage: kodo-mkt.sh <event_id> <repo_toml> [domain]" >&2
    exit 1
fi

readonly REPO_ID="$(kodo_repo_id "$REPO_TOML")"
readonly REPO_SLUG="$(kodo_repo_slug "$REPO_TOML")"
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
    "$SCRIPT_DIR/kodo-transition.sh" "$EVENT_ID" "$1" "$2" "mkt"
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
    message=$(timeout 60 gemini -p "$prompt" 2>/dev/null) || {
        transition "drafting" "deferred"
        return
    }
    kodo_log_budget "gemini" "$REPO_ID" "mkt" 0 0 0.0

    # Post welcome comment
    if [[ -n "$pr_num" ]]; then
        "$SCRIPT_DIR/kodo-git.sh" pr-comment "$REPO_TOML" "$pr_num" "$message" 2>/dev/null || true
    fi

    _record_action "$author" "welcomed"
    transition "drafting" "published"
    kodo_log "MKT: welcomed $author on $REPO_ID"
}

generate_changelog() {
    local payload="$1"
    local tag
    tag=$(echo "$payload" | jq -r '.tagName // .tag_name // empty' 2>/dev/null)

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

    # Get release info and recent commits
    local release_info commits
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
    changelog=$(timeout 120 gemini -p "$prompt" 2>/dev/null) || {
        transition "drafting" "deferred"
        return
    }
    kodo_log_budget "gemini" "$REPO_ID" "mkt" 0 0 0.0

    # Quality review for releases (Claude, if available and enabled)
    if kodo_toml_bool "$REPO_TOML" "generate_changelogs" && kodo_cli_available claude; then
        local reviewed
        reviewed=$(timeout 60 claude -p "Review and improve this changelog for accuracy and tone. Keep the same structure:

$changelog" --max-turns 1 2>/dev/null) || reviewed="$changelog"
        if [[ -n "$reviewed" ]]; then
            changelog="$reviewed"
            kodo_log_budget "claude" "$REPO_ID" "mkt" 0 0 0.50
        fi
        transition "drafting" "reviewing"
        transition "reviewing" "published"
    else
        transition "drafting" "published"
    fi

    # Update release notes
    "$SCRIPT_DIR/kodo-git.sh" release-edit "$REPO_TOML" "$tag" "$changelog" 2>/dev/null || true

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

    case "$state" in
        pending)
            transition "pending" "drafting"

            local payload
            payload="$(get_payload)"
            payload="${payload:-\{\}}"

            # Determine content type from event_id pattern
            local event_type="PullRequestEvent"
            if [[ "$EVENT_ID" == *"ReleaseEvent"* ]]; then
                event_type="ReleaseEvent"
            elif [[ "$EVENT_ID" == *"IssuesEvent"* ]]; then
                event_type="IssuesEvent"
            elif [[ "$EVENT_ID" == *"IssueCommentEvent"* ]]; then
                event_type="IssueCommentEvent"
            elif [[ "$EVENT_ID" == *"ForkEvent"* ]]; then
                event_type="ForkEvent"
            elif [[ "$EVENT_ID" == *"WatchEvent"* ]]; then
                event_type="WatchEvent"
            elif [[ "$EVENT_ID" == *"DiscussionEvent"* ]]; then
                event_type="DiscussionEvent"
            fi

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
            payload="${payload:-\{\}}"

            local event_type="PullRequestEvent"
            if [[ "$EVENT_ID" == *"ReleaseEvent"* ]]; then
                event_type="ReleaseEvent"
            elif [[ "$EVENT_ID" == *"IssuesEvent"* ]]; then
                event_type="IssuesEvent"
            elif [[ "$EVENT_ID" == *"IssueCommentEvent"* ]]; then
                event_type="IssueCommentEvent"
            elif [[ "$EVENT_ID" == *"ForkEvent"* ]]; then
                event_type="ForkEvent"
            elif [[ "$EVENT_ID" == *"WatchEvent"* ]]; then
                event_type="WatchEvent"
            elif [[ "$EVENT_ID" == *"DiscussionEvent"* ]]; then
                event_type="DiscussionEvent"
            fi

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
