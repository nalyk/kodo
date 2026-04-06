#!/usr/bin/env bash
set -euo pipefail

# Repo onboarding: discover → validate → shadow
# Usage: kodo-add.sh <owner/repo> [--provider github|gitlab|gitea|bitbucket]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kodo-lib.sh
source "$SCRIPT_DIR/kodo-lib.sh"

kodo_init_db

readonly INPUT="${1:-}"
readonly PROVIDER="${3:-github}"

if [[ -z "$INPUT" || "$INPUT" != *"/"* ]]; then
    echo "Usage: kodo-add.sh <owner/repo> [--provider github]" >&2
    echo "  Example: kodo-add.sh acme/api" >&2
    exit 1
fi

readonly OWNER="${INPUT%%/*}"
readonly REPO="${INPUT#*/}"
readonly REPO_ID="${OWNER}-${REPO}"
readonly TOML_PATH="$KODO_HOME/repos/${REPO_ID}.toml"

if [[ -f "$TOML_PATH" ]]; then
    echo "Repo already registered: $TOML_PATH" >&2
    echo "Remove it first if you want to re-onboard." >&2
    exit 1
fi

# ── Phase 1: Discovering ────────────────────────────────────

echo "=== Phase 1: Discovering $OWNER/$REPO ==="

# Create a temporary TOML to use kodo-git.sh for discovery
local_tmp=$(mktemp)
cat > "$local_tmp" <<EOF
[repo]
owner = "$OWNER"
name = "$REPO"
provider = "$PROVIDER"
mode = "shadow"
branch_default = "main"

[dev]
enabled = true

[mkt]
enabled = true

[pm]
enabled = true
EOF

# Use Claude for auto-discovery if available
if kodo_cli_available claude; then
    echo "Using Claude for intelligent discovery..."

    # Gather raw data from GitHub
    local pr_data issue_data
    pr_data=$("$SCRIPT_DIR/kodo-git.sh" pr-list "$local_tmp" 2>/dev/null) || pr_data="[]"
    issue_data=$("$SCRIPT_DIR/kodo-git.sh" issue-list "$local_tmp" 2>/dev/null) || issue_data="[]"

    local repo_api_data
    repo_api_data=$(gh api "repos/$OWNER/$REPO" 2>/dev/null) || repo_api_data="{}"

    local prompt="Analyze this repository: $OWNER/$REPO

API data: $repo_api_data
Recent PRs count: $(echo "$pr_data" | jq 'length' 2>/dev/null || echo "0")
Open issues count: $(echo "$issue_data" | jq 'length' 2>/dev/null || echo "0")

Discover: language, CI system, test command, lint command, default branch, labels, conventions."

    local discovery
    discovery=$(timeout 120 claude -p "$prompt" \
        --json-schema "$KODO_HOME/schemas/discovery.schema.json" \
        --max-turns 3 2>/dev/null) || discovery=""

    kodo_log_budget "claude" "$REPO_ID" "onboard" 0 0 1.00

    if [[ -n "$discovery" ]]; then
        # Extract discovered values
        local lang branch test_cmd lint_cmd
        lang=$(echo "$discovery" | jq -r '.language // "unknown"' 2>/dev/null)
        branch=$(echo "$discovery" | jq -r '.branch_default // "main"' 2>/dev/null)
        test_cmd=$(echo "$discovery" | jq -r '.test_command // "echo no-tests"' 2>/dev/null)
        lint_cmd=$(echo "$discovery" | jq -r '.lint_command // "echo no-lint"' 2>/dev/null)

        echo "  Language: $lang"
        echo "  Branch: $branch"
        echo "  Tests: $test_cmd"
        echo "  Lint: $lint_cmd"
    fi
else
    echo "Claude unavailable — using basic discovery..."

    # Basic discovery via GitHub API
    local repo_info
    repo_info=$(gh api "repos/$OWNER/$REPO" 2>/dev/null) || repo_info="{}"

    local lang branch
    lang=$(echo "$repo_info" | jq -r '.language // "unknown"' 2>/dev/null)
    branch=$(echo "$repo_info" | jq -r '.default_branch // "main"' 2>/dev/null)
    test_cmd="echo no-tests"
    lint_cmd="echo no-lint"

    echo "  Language: $lang"
    echo "  Branch: $branch"
fi

# ── Phase 2: Generate TOML ──────────────────────────────────

echo ""
echo "=== Phase 2: Generating config ==="

cat > "$TOML_PATH" <<TOML
[repo]
owner = "$OWNER"
name = "$REPO"
provider = "$PROVIDER"
mode = "shadow"
branch_default = "${branch:-main}"

[dev]
enabled = true
test_command = "${test_cmd:-echo no-tests}"
lint_command = "${lint_cmd:-echo no-lint}"
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

echo "  Config written: $TOML_PATH"

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
if ! gh api "repos/$OWNER/$REPO" >/dev/null 2>&1; then
    echo "  FAIL: cannot access $OWNER/$REPO"
    validation_ok=false
else
    echo "  OK: repo accessible"
fi

# Check branch exists
if gh api "repos/$OWNER/$REPO/branches/${branch:-main}" >/dev/null 2>&1; then
    echo "  OK: branch '${branch:-main}' exists"
else
    echo "  WARN: branch '${branch:-main}' not found — may need adjustment"
fi

echo "  OK: mode = shadow (safe)"

if [[ "$validation_ok" == "false" ]]; then
    echo ""
    echo "Validation failed. Fix issues and re-run."
    rm "$TOML_PATH"
    rm "$local_tmp"
    exit 1
fi

# ── Phase 4: Initialize ─────────────────────────────────────

echo ""
echo "=== Phase 4: Initializing shadow mode ==="

# Initialize repo metrics
kodo_sql "INSERT OR IGNORE INTO repo_metrics (repo) VALUES ('$(kodo_sql_escape "$REPO_ID")');"

echo "  Repo registered in shadow mode"
echo "  Next scout cycle will start detecting events"
echo "  Shadow mode: all engines run but take NO write actions"
echo ""
echo "Done: $OWNER/$REPO onboarded as shadow"
echo "  Config: $TOML_PATH"
echo "  Monitor: kodo-status.sh"
echo "  Promote to live: edit mode = \"live\" in TOML"

rm -f "$local_tmp"
