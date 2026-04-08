#!/usr/bin/env bash
set -euo pipefail

# Repo onboarding: discover → validate → shadow
# Usage: kodo-add.sh <owner/repo> [--provider github|gitlab|gitea|bitbucket]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kodo-lib.sh
source "$SCRIPT_DIR/kodo-lib.sh"

kodo_init_db

main() {
    local input="${1:-}"
    local provider="${3:-github}"

    if [[ -z "$input" || "$input" != *"/"* ]]; then
        echo "Usage: kodo-add.sh <owner/repo> [--provider github]" >&2
        echo "  Example: kodo-add.sh acme/api" >&2
        exit 1
    fi

    local owner="${input%%/*}"
    local repo="${input#*/}"
    local repo_id="${owner}-${repo}"
    local toml_path="$KODO_HOME/repos/${repo_id}.toml"

    if [[ -f "$toml_path" ]]; then
        echo "Repo already registered: $toml_path" >&2
        echo "Remove it first if you want to re-onboard." >&2
        exit 1
    fi

    # ── Phase 1: Discovering ────────────────────────────────────

    echo "=== Phase 1: Discovering $owner/$repo ==="

    # Create a temporary TOML to use kodo-git.sh for discovery
    local tmp_toml
    tmp_toml=$(mktemp)
    trap 'rm -f "$tmp_toml"' EXIT
    cat > "$tmp_toml" <<EOF
[repo]
owner = "$owner"
name = "$repo"
provider = "$provider"
mode = "shadow"
branch_default = "main"
enabled = true

[dev]
enabled = true

[mkt]
enabled = true

[pm]
enabled = true
EOF

    local lang="unknown" branch="main" test_cmd="" lint_cmd=""

    # Use Claude for auto-discovery if available
    if kodo_cli_available claude; then
        echo "Using Claude for intelligent discovery..."

        # Gather raw data from GitHub
        local pr_data
        pr_data=$("$SCRIPT_DIR/kodo-git.sh" pr-list "$tmp_toml" 2>/dev/null) || pr_data="[]"
        local issue_data
        issue_data=$("$SCRIPT_DIR/kodo-git.sh" issue-list "$tmp_toml" 2>/dev/null) || issue_data="[]"

        local repo_api_data
        repo_api_data=$("$SCRIPT_DIR/kodo-git.sh" repo-info "$tmp_toml" 2>/dev/null) || repo_api_data="{}"

        local prompt
        prompt="Analyze this repository: $owner/$repo

API data: $repo_api_data
Recent PRs count: $(echo "$pr_data" | jq 'length' 2>/dev/null || echo "0")
Open issues count: $(echo "$issue_data" | jq 'length' 2>/dev/null || echo "0")

Discover: language, CI system, test command, lint command, default branch, labels, conventions."

        local discovery
        discovery=$(kodo_invoke_llm claude "$prompt" \
            --schema "$KODO_HOME/schemas/discovery.schema.json" \
            --timeout 120 \
            --repo "$owner/$repo" \
            --domain "onboard") || discovery=""

        if [[ -n "$discovery" ]]; then
            lang=$(echo "$discovery" | jq -r '.language // "unknown"' 2>/dev/null)
            branch=$(echo "$discovery" | jq -r '.branch_default // "main"' 2>/dev/null)
            test_cmd=$(echo "$discovery" | jq -r '.test_command // ""' 2>/dev/null)
            lint_cmd=$(echo "$discovery" | jq -r '.lint_command // ""' 2>/dev/null)
        fi
    else
        echo "Claude unavailable — using basic discovery..."

        local repo_info
        repo_info=$("$SCRIPT_DIR/kodo-git.sh" repo-info "$tmp_toml" 2>/dev/null) || repo_info="{}"

        lang=$(echo "$repo_info" | jq -r '.language // "unknown"' 2>/dev/null)
        branch=$(echo "$repo_info" | jq -r '.default_branch // "main"' 2>/dev/null)
    fi

    echo "  Language: $lang"
    echo "  Branch: $branch"
    echo "  Tests: $test_cmd"
    echo "  Lint: $lint_cmd"

    # ── Phase 2: Generate TOML ──────────────────────────────────

    echo ""
    echo "=== Phase 2: Generating config ==="

    cat > "$toml_path" <<TOML
[repo]
owner = "$owner"
name = "$repo"
provider = "$provider"
mode = "shadow"
branch_default = "${branch:-main}"
enabled = true

[dev]
enabled = true
test_command = "$test_cmd"
lint_command = "$lint_cmd"
tests_optional = false
lint_optional = false
allow_no_ci = false
max_diff_lines = 500
auto_merge_deps = true
semver_release = true

[mkt]
enabled = true
welcome_new_contributors = true
generate_changelogs = true
good_first_issues = true
contributor_spotlights = true

[pm]
enabled = true
weekly_report = true
daily_triage = true
feature_evaluation = true
telegram_digest = false
TOML

    echo "  Config written: $toml_path"

    # Warn operator about missing gates so they take explicit action
    if [[ -z "$test_cmd" ]]; then
        echo "WARNING: no test command detected for $owner/$repo. Hard gates will defer all PRs until you set [dev] test_command in repos/${repo_id}.toml or explicitly opt out with [dev] tests_optional = true." >&2
    fi
    if [[ -z "$lint_cmd" ]]; then
        echo "WARNING: no lint command detected for $owner/$repo. Hard gates will defer all PRs until you set [dev] lint_command in repos/${repo_id}.toml or explicitly opt out with [dev] lint_optional = true." >&2
    fi
    echo "NOTE: allow_no_ci defaults to false. If this repo has no CI, auto-merge will refuse until you configure CI or set [dev] allow_no_ci = true." >&2

    # ── Phase 3: Validate ───────────────────────────────────────

    echo ""
    echo "=== Phase 3: Validating ==="

    local validation_ok=true

    # Check gh auth
    if ! gh auth status >/dev/null 2>&1; then
        echo "  FAIL: gh not authenticated"
        validation_ok=false
    fi

    # Check repo access
    if ! gh api "repos/$owner/$repo" >/dev/null 2>&1; then
        echo "  FAIL: cannot access $owner/$repo"
        validation_ok=false
    else
        echo "  OK: repo accessible"
    fi

    # Check branch exists
    if gh api "repos/$owner/$repo/branches/${branch:-main}" >/dev/null 2>&1; then
        echo "  OK: branch '${branch:-main}' exists"
    else
        echo "  WARN: branch '${branch:-main}' not found — may need adjustment"
    fi

    echo "  OK: mode = shadow (safe)"

    if [[ "$validation_ok" == "false" ]]; then
        echo ""
        echo "Validation failed. Fix issues and re-run."
        rm -f "$toml_path"
        exit 1
    fi

    # ── Phase 4: Initialize ─────────────────────────────────────

    echo ""
    echo "=== Phase 4: Initializing shadow mode ==="

    kodo_sql "INSERT OR IGNORE INTO repo_metrics (repo) VALUES ('$(kodo_sql_escape "$repo_id")');"

    echo "  Repo registered in shadow mode"
    echo "  Next scout cycle will start detecting events"
    echo "  Shadow mode: all engines run but take NO write actions"
    echo ""
    echo "Done: $owner/$repo onboarded as shadow"
    echo "  Config: $toml_path"
    echo "  Monitor: kodo-status.sh"
    echo "  Promote to live: edit mode = \"live\" in TOML"
}

main "$@"
