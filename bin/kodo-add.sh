#!/usr/bin/env bash
set -euo pipefail

# Repo onboarding: clone → discover → generate config + docs → validate
# Usage: kodo-add.sh <owner/repo> [--provider github|gitlab] [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kodo-lib.sh
source "$SCRIPT_DIR/kodo-lib.sh"

# Script-level vars for trap access (local vars vanish after main returns)
_WORK_DIR=""
_TMP_TOML=""

# ── Argument Parsing ────────────────────────────────────────

_parse_args() {
    DRY_RUN=false
    PROVIDER="github"
    INPUT=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)   DRY_RUN=true; shift ;;
            --provider)  PROVIDER="${2:-github}"; shift 2 ;;
            -*)          echo "Unknown option: $1" >&2; exit 1 ;;
            *)           INPUT="$1"; shift ;;
        esac
    done

    if [[ -z "$INPUT" || "$INPUT" != *"/"* ]]; then
        echo "Usage: kodo-add.sh <owner/repo> [--provider github] [--dry-run]" >&2
        echo "  Example: kodo-add.sh acme/api" >&2
        echo "  Example: kodo-add.sh acme/api --dry-run" >&2
        exit 1
    fi

    OWNER="${INPUT%%/*}"
    REPO="${INPUT#*/}"
    REPO_ID="${OWNER}-${REPO}"
}

# ── Cleanup ─────────────────────────────────────────────────

_cleanup() {
    local work_dir="${1:-}" tmp_toml="${2:-}"
    if [[ -n "$work_dir" && -d "$work_dir" ]]; then
        "$SCRIPT_DIR/kodo-git.sh" cleanup-workdir "$work_dir" 2>/dev/null || rm -rf "$work_dir"
    fi
    [[ -n "$tmp_toml" && -f "$tmp_toml" ]] && rm -f "$tmp_toml"
}

# ── Discovery Functions (deterministic, no LLM) ────────────

_detect_package_manager() {
    local dir="$1"
    if [[ -f "$dir/pnpm-lock.yaml" ]]; then
        echo "pnpm"
    elif [[ -f "$dir/yarn.lock" ]]; then
        echo "yarn"
    elif [[ -f "$dir/package-lock.json" ]]; then
        echo "npm"
    elif [[ -f "$dir/bun.lockb" ]]; then
        echo "bun"
    elif [[ -f "$dir/Cargo.toml" ]]; then
        echo "cargo"
    elif [[ -f "$dir/go.mod" ]]; then
        echo "go"
    elif [[ -f "$dir/Gemfile" ]]; then
        echo "bundler"
    elif [[ -f "$dir/composer.json" ]]; then
        echo "composer"
    elif [[ -f "$dir/mix.exs" ]]; then
        echo "mix"
    elif [[ -f "$dir/pyproject.toml" ]]; then
        # Disambiguate pip vs poetry vs uv
        if grep -q '\[tool\.poetry\]' "$dir/pyproject.toml" 2>/dev/null; then
            echo "poetry"
        elif [[ -f "$dir/uv.lock" ]]; then
            echo "uv"
        else
            echo "pip"
        fi
    elif [[ -f "$dir/requirements.txt" ]]; then
        echo "pip"
    else
        echo "unknown"
    fi
}

_detect_test_command() {
    local dir="$1" pkg_mgr="$2"

    case "$pkg_mgr" in
        npm|yarn|pnpm|bun)
            if [[ -f "$dir/package.json" ]]; then
                local test_script
                test_script=$(jq -r '.scripts.test // empty' "$dir/package.json" 2>/dev/null)
                if [[ -n "$test_script" && "$test_script" != "echo \"Error: no test specified\" && exit 1" ]]; then
                    echo "${pkg_mgr} test"
                    return
                fi
            fi
            ;;
        pip|poetry|uv)
            if [[ -f "$dir/pytest.ini" ]] \
                || [[ -f "$dir/pyproject.toml" ]] && grep -q '\[tool\.pytest' "$dir/pyproject.toml" 2>/dev/null \
                || [[ -f "$dir/setup.cfg" ]] && grep -q '\[tool:pytest\]' "$dir/setup.cfg" 2>/dev/null \
                || [[ -f "$dir/tox.ini" ]]; then
                echo "python -m pytest"
                return
            fi
            # Check for tests/ directory as a hint
            if [[ -d "$dir/tests" || -d "$dir/test" ]]; then
                echo "python -m pytest"
                return
            fi
            ;;
        cargo)
            echo "cargo test"
            return
            ;;
        go)
            echo "go test ./..."
            return
            ;;
        bundler)
            if [[ -f "$dir/Rakefile" ]] && grep -q 'RSpec\|Minitest\|test' "$dir/Rakefile" 2>/dev/null; then
                echo "bundle exec rake test"
                return
            fi
            ;;
        mix)
            echo "mix test"
            return
            ;;
        composer)
            if [[ -f "$dir/composer.json" ]]; then
                local test_script
                test_script=$(jq -r '.scripts.test // empty' "$dir/composer.json" 2>/dev/null)
                if [[ -n "$test_script" ]]; then
                    echo "composer test"
                    return
                fi
            fi
            if [[ -f "$dir/phpunit.xml" || -f "$dir/phpunit.xml.dist" ]]; then
                echo "vendor/bin/phpunit"
                return
            fi
            ;;
    esac
    # No test command detected
    echo ""
}

_detect_lint_command() {
    local dir="$1" pkg_mgr="$2"

    case "$pkg_mgr" in
        npm|yarn|pnpm|bun)
            if [[ -f "$dir/package.json" ]]; then
                local lint_script
                lint_script=$(jq -r '.scripts.lint // empty' "$dir/package.json" 2>/dev/null)
                if [[ -n "$lint_script" ]]; then
                    echo "${pkg_mgr} run lint"
                    return
                fi
            fi
            # Check for eslint config
            local has_eslint=false
            for f in .eslintrc .eslintrc.js .eslintrc.json .eslintrc.yml .eslintrc.yaml eslint.config.js eslint.config.mjs eslint.config.ts; do
                if [[ -f "$dir/$f" ]]; then
                    has_eslint=true
                    break
                fi
            done
            if [[ "$has_eslint" == "true" ]]; then
                echo "npx eslint ."
                return
            fi
            ;;
        pip|poetry|uv)
            if [[ -f "$dir/ruff.toml" ]] \
                || [[ -f "$dir/pyproject.toml" ]] && grep -q '\[tool\.ruff\]' "$dir/pyproject.toml" 2>/dev/null; then
                echo "ruff check ."
                return
            fi
            if [[ -f "$dir/.flake8" ]] \
                || [[ -f "$dir/setup.cfg" ]] && grep -q '\[flake8\]' "$dir/setup.cfg" 2>/dev/null; then
                echo "flake8"
                return
            fi
            if [[ -f "$dir/pyproject.toml" ]] && grep -q '\[tool\.pylint\]' "$dir/pyproject.toml" 2>/dev/null; then
                echo "pylint"
                return
            fi
            ;;
        cargo)
            echo "cargo clippy"
            return
            ;;
        go)
            echo "go vet ./..."
            return
            ;;
        mix)
            echo "mix credo"
            return
            ;;
    esac
    # No lint command detected
    echo ""
}

_detect_ci_workflows() {
    local dir="$1"
    local workflows=()

    # GitHub Actions
    if [[ -d "$dir/.github/workflows" ]]; then
        while IFS= read -r -d '' f; do
            workflows+=("$(basename "$f")")
        done < <(find "$dir/.github/workflows" -maxdepth 1 -name '*.yml' -o -name '*.yaml' 2>/dev/null | tr '\n' '\0')
    fi

    # GitLab CI
    if [[ -f "$dir/.gitlab-ci.yml" ]]; then
        workflows+=(".gitlab-ci.yml")
    fi

    # CircleCI
    if [[ -f "$dir/.circleci/config.yml" ]]; then
        workflows+=(".circleci/config.yml")
    fi

    # Travis
    if [[ -f "$dir/.travis.yml" ]]; then
        workflows+=(".travis.yml")
    fi

    local IFS=','
    echo "${workflows[*]:-}"
}

# ── Claude-Powered Generation (budget-gated) ───────────────

_generate_kodo_md() {
    local work_dir="$1" owner="$2" repo="$3" output_path="$4"

    if ! kodo_cli_available claude; then
        kodo_log "ONBOARD: Claude CLI not available — using placeholder for .kodo.md"
        return 1
    fi
    if ! kodo_check_budget claude; then
        kodo_log "ONBOARD: Claude budget exhausted — using placeholder for .kodo.md"
        return 1
    fi

    echo "  Generating domain knowledge via Claude (read-only repo analysis)..."

    local prompt
    prompt="You are analyzing the repository ${owner}/${repo} to produce a domain knowledge document.

Your working directory is the root of the repository. Explore it to understand:
- What the project does (read README.md if it exists)
- Architecture (look for ARCHITECTURE.md, docs/, or infer from directory structure)
- Tech stack (languages, frameworks, key dependencies from config files)
- Current priorities (look at open issues via gh, recent activity, TODO comments)
- Known patterns (coding conventions, project structure, testing approach)
- Active pain points (recurring issues, complexity hotspots)

Produce a Markdown document with these exact sections:

# ${repo} — Domain Knowledge

## What it is
(2-3 sentences)

## Architecture
(Key components, data flow, deployment model)

## Tech stack
(Languages, frameworks, databases, infra — bullet list)

## Current priorities
(What the maintainers seem focused on, based on issues/PRs/README)

## Known patterns
(Coding conventions, naming, testing approach, CI/CD setup)

## Active pain points
(Problems visible from issues, stale branches, complexity)

Rules:
- Maximum 60 lines, 3000 characters
- Be factual — only state what you can verify from the repo
- If a section has no data, write \"Not determined from repository inspection.\"
- Output ONLY the Markdown document — no preamble, no explanation, no code fences"

    local raw_output result cost tokens_in tokens_out
    local llm_stderr
    llm_stderr=$(mktemp)

    raw_output=$(cd "$work_dir" && timeout 180 claude -p "$prompt" \
        --allowedTools 'Read' 'Glob' 'Grep' 'Bash(find:*)' 'Bash(ls:*)' 'Bash(head:*)' 'Bash(wc:*)' \
        --output-format json \
        --max-turns 20 </dev/null 2>"$llm_stderr") || {
        kodo_log "ONBOARD: Claude .kodo.md generation failed (exit=$?): $(head -c 200 "$llm_stderr" 2>/dev/null)"
        rm -f "$llm_stderr"
        return 1
    }
    rm -f "$llm_stderr"

    result=$(echo "$raw_output" | jq -r '.result // empty' 2>/dev/null)
    cost=$(echo "$raw_output" | jq -r '.total_cost_usd // 0' 2>/dev/null)
    tokens_in=$(echo "$raw_output" | jq -r '.usage.input_tokens // 0' 2>/dev/null)
    tokens_out=$(echo "$raw_output" | jq -r '.usage.output_tokens // 0' 2>/dev/null)

    # Log budget regardless of result quality
    kodo_log_budget "claude" "${owner}/${repo}" "onboard" "$tokens_in" "$tokens_out" "$cost"

    if [[ -z "$result" ]]; then
        kodo_log "ONBOARD: Claude returned empty result for .kodo.md"
        return 1
    fi

    # Strip preamble before the first markdown heading
    result=$(echo "$result" | sed -n '/^# /,$p')
    if [[ -z "$result" ]]; then
        kodo_log "ONBOARD: Claude .kodo.md had no markdown heading after stripping preamble"
        return 1
    fi

    # Truncate to 3000 chars at a clean line boundary
    echo "$result" | head -c 3000 | sed '$ { /^$/! { /\.$/! s/\n[^\n]*$// ; } }' > "$output_path"
    echo "  .kodo.md generated ($(wc -l < "$output_path") lines, $(wc -c < "$output_path") bytes)"
    return 0
}

_generate_voice_md() {
    local work_dir="$1" owner="$2" repo="$3" output_path="$4"

    if ! kodo_cli_available claude; then
        kodo_log "ONBOARD: Claude CLI not available — using placeholder for .voice.md"
        return 1
    fi
    if ! kodo_check_budget claude; then
        kodo_log "ONBOARD: Claude budget exhausted — using placeholder for .voice.md"
        return 1
    fi

    echo "  Generating voice profile via Claude (commit + README analysis)..."

    local prompt
    prompt="You are analyzing the repository ${owner}/${repo} to extract the maintainer's writing voice.

Your working directory is the root of the repository. Analyze:
1. Git commit messages: run git log --oneline -30 to see recent commits
2. README tone and style (read README.md if it exists)
3. PR description templates (check .github/pull_request_template.md)
4. Issue templates (check .github/ISSUE_TEMPLATE/ directory)
5. CONTRIBUTING.md if present
6. Recent issue/PR titles: run gh issue list --limit 10 and gh pr list --limit 10

Produce a voice profile document with these exact sections:

# ${repo} — Voice Profile

## Tone
(2-3 sentences describing the writing style: formal/casual, technical depth, humor level)

## Golden examples

### PR comment
(Write an example code review comment in the maintainer's voice)

### Welcome message
(Write an example first-time contributor welcome in the maintainer's voice)

### Changelog entry
(Write an example changelog entry in the maintainer's voice)

## Anti-patterns
(Phrases and styles to AVOID — things that clash with this repo's voice)

Rules:
- Maximum 50 lines, 2500 characters
- Base voice analysis on ACTUAL text from the repo, not assumptions
- If insufficient text samples exist, say so honestly
- Output ONLY the Markdown document — no preamble, no explanation, no code fences"

    local raw_output result cost tokens_in tokens_out
    local llm_stderr
    llm_stderr=$(mktemp)

    raw_output=$(cd "$work_dir" && timeout 180 claude -p "$prompt" \
        --allowedTools 'Read' 'Glob' 'Grep' 'Bash(git log:*)' 'Bash(git show:*)' 'Bash(gh issue list:*)' 'Bash(gh pr list:*)' 'Bash(ls:*)' 'Bash(head:*)' \
        --output-format json \
        --max-turns 20 </dev/null 2>"$llm_stderr") || {
        kodo_log "ONBOARD: Claude .voice.md generation failed (exit=$?): $(head -c 200 "$llm_stderr" 2>/dev/null)"
        rm -f "$llm_stderr"
        return 1
    }
    rm -f "$llm_stderr"

    result=$(echo "$raw_output" | jq -r '.result // empty' 2>/dev/null)
    cost=$(echo "$raw_output" | jq -r '.total_cost_usd // 0' 2>/dev/null)
    tokens_in=$(echo "$raw_output" | jq -r '.usage.input_tokens // 0' 2>/dev/null)
    tokens_out=$(echo "$raw_output" | jq -r '.usage.output_tokens // 0' 2>/dev/null)

    kodo_log_budget "claude" "${owner}/${repo}" "onboard" "$tokens_in" "$tokens_out" "$cost"

    if [[ -z "$result" ]]; then
        kodo_log "ONBOARD: Claude returned empty result for .voice.md"
        return 1
    fi

    # Strip preamble before the first markdown heading
    result=$(echo "$result" | sed -n '/^# /,$p')
    if [[ -z "$result" ]]; then
        kodo_log "ONBOARD: Claude .voice.md had no markdown heading after stripping preamble"
        return 1
    fi

    # Truncate to 2500 chars at a clean line boundary
    echo "$result" | head -c 2500 | sed '$ { /^$/! { /\.$/! s/\n[^\n]*$// ; } }' > "$output_path"
    echo "  .voice.md generated ($(wc -l < "$output_path") lines, $(wc -c < "$output_path") bytes)"
    return 0
}

# ── Placeholder Fallbacks ───────────────────────────────────

_write_placeholder_kodo_md() {
    local output_path="$1" repo="$2"
    sed "s/{repo}/${repo}/g" "$SCRIPT_DIR/../repos/_template.kodo.md" > "$output_path"
    echo "  .kodo.md placeholder written (Claude unavailable — edit manually)"
}

_write_placeholder_voice_md() {
    local output_path="$1" repo="$2"
    sed "s/{repo}/${repo}/g" "$SCRIPT_DIR/../repos/_template.voice.md" > "$output_path"
    echo "  .voice.md placeholder written (Claude unavailable — edit manually)"
}

# ── Summary ─────────────────────────────────────────────────

_print_summary() {
    local owner="$1" repo="$2" repo_id="$3"
    local pkg_mgr="$4" test_cmd="$5" lint_cmd="$6"
    local branch="$7" ci_count="$8" output_dir="$9"

    local test_display="${test_cmd:-EMPTY — REQUIRES MANUAL CONFIG}"
    local lint_display="${lint_cmd:-EMPTY}"

    echo ""
    echo "KŌDŌ onboarding complete for ${owner}/${repo}"
    echo "Mode: shadow (recommended for first 3 days)"
    echo "Files created:"
    echo "  ${output_dir}/${repo_id}.toml"
    echo "  ${output_dir}/${repo_id}.kodo.md      (REVIEW THIS — generated by Claude)"
    echo "  ${output_dir}/${repo_id}.voice.md     (REVIEW THIS — generated by Claude)"
    echo ""
    echo "Configuration:"
    echo "  package_manager: ${pkg_mgr}"
    echo "  test_command:    ${test_display}"
    echo "  lint_command:    ${lint_display}"
    echo "  default_branch:  ${branch}"
    echo "  ci_workflows:    ${ci_count} detected"
    echo "  allow_no_ci:     false"
    echo "  tests_optional:  false"
    echo ""
    echo "Next steps:"
    echo "  1. Review and edit the .kodo.md and .voice.md files"
    echo "  2. Set [repo] mode = \"live\" in the TOML when ready"
    echo "  3. Watch ~/.kodo/logs/ for the first scan cycle"
}

# ── Main ────────────────────────────────────────────────────

main() {
    _parse_args "$@"

    local output_dir="$KODO_HOME/repos"

    # Bootstrap temp KODO_HOME for --dry-run
    if [[ "$DRY_RUN" == "true" ]]; then
        mkdir -p "$KODO_HOME/repos" "$KODO_HOME/sql" "$KODO_HOME/.workdir" "$KODO_HOME/logs"
        if [[ ! -f "$KODO_HOME/sql/schema.sql" ]]; then
            cp "$SCRIPT_DIR/../sql/schema.sql" "$KODO_HOME/sql/" 2>/dev/null || {
                echo "WARNING: cannot copy schema.sql to dry-run KODO_HOME — DB operations will be skipped" >&2
            }
        fi
    fi

    kodo_init_db

    local toml_path="${output_dir}/${REPO_ID}.toml"
    local kodo_md_path="${output_dir}/${REPO_ID}.kodo.md"
    local voice_md_path="${output_dir}/${REPO_ID}.voice.md"

    if [[ -f "$toml_path" ]]; then
        echo "Repo already registered: $toml_path" >&2
        echo "Remove it first if you want to re-onboard." >&2
        exit 1
    fi

    # ── Phase 1: Clone ──────────────────────────────────────
    echo "=== Phase 1: Cloning ${OWNER}/${REPO} ==="

    # Temp TOML for kodo-git.sh operations during discovery
    _TMP_TOML=$(mktemp)
    cat > "$_TMP_TOML" <<EOF
[repo]
owner = "$OWNER"
name = "$REPO"
provider = "$PROVIDER"
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

    _WORK_DIR=$("$SCRIPT_DIR/kodo-git.sh" repo-clone "$_TMP_TOML") || {
        echo "FAIL: could not clone ${OWNER}/${REPO}" >&2
        rm -f "$_TMP_TOML"
        exit 1
    }
    trap '_cleanup "$_WORK_DIR" "$_TMP_TOML"' EXIT

    echo "  Cloned to $_WORK_DIR"

    # ── Phase 2: Discover ───────────────────────────────────
    echo ""
    echo "=== Phase 2: Discovering ==="

    # Package manager
    local pkg_mgr
    pkg_mgr=$(_detect_package_manager "$_WORK_DIR")
    echo "  Package manager: $pkg_mgr"

    # Test command
    local test_cmd
    test_cmd=$(_detect_test_command "$_WORK_DIR" "$pkg_mgr")
    echo "  Test command: ${test_cmd:-<none detected>}"

    # Lint command
    local lint_cmd
    lint_cmd=$(_detect_lint_command "$_WORK_DIR" "$pkg_mgr")
    echo "  Lint command: ${lint_cmd:-<none detected>}"

    # Default branch from API
    local repo_info branch
    repo_info=$("$SCRIPT_DIR/kodo-git.sh" repo-info "$_TMP_TOML" 2>/dev/null) || repo_info="{}"
    branch=$(echo "$repo_info" | jq -r '.default_branch // "main"' 2>/dev/null) || branch="main"
    echo "  Default branch: $branch"

    # CI workflows
    local ci_csv ci_count
    ci_csv=$(_detect_ci_workflows "$_WORK_DIR")
    if [[ -n "$ci_csv" ]]; then
        # Count comma-separated entries
        ci_count=$(echo "$ci_csv" | tr ',' '\n' | wc -l)
    else
        ci_count=0
    fi
    echo "  CI workflows: $ci_count detected"

    # ── Phase 3: Generate TOML ──────────────────────────────
    echo ""
    echo "=== Phase 3: Generating config ==="

    mkdir -p "$output_dir"
    cat > "$toml_path" <<TOML
[repo]
owner = "$OWNER"
name = "$REPO"
provider = "$PROVIDER"
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
await_bot_feedback = true
feedback_window_minutes = 10
max_feedback_rounds = 2
apply_bot_suggestions = true
trusted_review_bots = ["gemini-code-assist[bot]", "coderabbit[bot]"]
max_rebase_attempts = 2
monitoring_window_hours = 48

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

    # Warn about missing gates
    if [[ -z "$test_cmd" ]]; then
        echo "WARNING: no test command detected for ${OWNER}/${REPO}. Hard gates will defer all PRs until you set [dev] test_command in repos/${REPO_ID}.toml or explicitly opt out with [dev] tests_optional = true." >&2
    fi
    if [[ -z "$lint_cmd" ]]; then
        echo "WARNING: no lint command detected for ${OWNER}/${REPO}. Hard gates will defer all PRs until you set [dev] lint_command in repos/${REPO_ID}.toml or explicitly opt out with [dev] lint_optional = true." >&2
    fi
    if [[ "$ci_count" -eq 0 ]]; then
        echo "WARNING: no CI workflows detected for ${OWNER}/${REPO}. allow_no_ci defaults to false — auto-merge will refuse until you configure CI or set [dev] allow_no_ci = true." >&2
    fi

    # ── Phase 4: Generate .kodo.md ──────────────────────────
    echo ""
    echo "=== Phase 4: Generating domain knowledge ==="

    if ! _generate_kodo_md "$_WORK_DIR" "$OWNER" "$REPO" "$kodo_md_path"; then
        _write_placeholder_kodo_md "$kodo_md_path" "$REPO"
    fi

    # ── Phase 5: Generate .voice.md ─────────────────────────
    echo ""
    echo "=== Phase 5: Generating voice profile ==="

    if ! _generate_voice_md "$_WORK_DIR" "$OWNER" "$REPO" "$voice_md_path"; then
        _write_placeholder_voice_md "$voice_md_path" "$REPO"
    fi

    # ── Phase 6: Validate ───────────────────────────────────
    echo ""
    echo "=== Phase 6: Validating ==="

    local validation_ok=true

    if ! gh auth status >/dev/null 2>&1; then
        echo "  FAIL: gh not authenticated"
        validation_ok=false
    fi

    if ! gh api "repos/${OWNER}/${REPO}" >/dev/null 2>&1; then
        echo "  FAIL: cannot access ${OWNER}/${REPO}"
        validation_ok=false
    else
        echo "  OK: repo accessible"
    fi

    if gh api "repos/${OWNER}/${REPO}/branches/${branch:-main}" >/dev/null 2>&1; then
        echo "  OK: branch '${branch:-main}' exists"
    else
        echo "  WARN: branch '${branch:-main}' not found — may need adjustment"
    fi

    echo "  OK: mode = shadow (safe)"

    if [[ "$validation_ok" == "false" ]]; then
        echo ""
        echo "Validation failed. Fix issues and re-run."
        rm -f "$toml_path" "$kodo_md_path" "$voice_md_path"
        exit 1
    fi

    # ── Phase 7: Initialize ─────────────────────────────────
    echo ""
    echo "=== Phase 7: Initializing shadow mode ==="

    if [[ "$DRY_RUN" != "true" ]]; then
        kodo_sql "INSERT OR IGNORE INTO repo_metrics (repo) VALUES ('$(kodo_sql_escape "$REPO_ID")');"
        echo "  Repo registered in shadow mode"
    else
        echo "  Dry run — skipped DB registration"
    fi

    _print_summary "$OWNER" "$REPO" "$REPO_ID" \
        "$pkg_mgr" "$test_cmd" "$lint_cmd" \
        "${branch:-main}" "$ci_count" "$output_dir"
}

main "$@"
