#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# KODO v4.2 Configuration Compatibility Audit
# Verifies that iris-gateway config is ready for the patched codebase.
#
# Run from the OPERATOR terminal (not from Claude Code):
#   bash /home/ubuntu/gits/kodo-dev/scripts/verify-iris-config.sh
#
# This script is READ-ONLY. It does NOT modify any file.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

KODO_LIVE="${KODO_HOME:-/home/ubuntu/.kodo}"
TOML="$KODO_LIVE/repos/yoda-digital-iris-gateway.toml"

RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
BLD='\033[1m'
RST='\033[0m'

CRITICAL=0
WARNING=0
OK=0

pass()     { OK=$((OK + 1));       printf "${GRN}  ✓ PASS${RST}  %s\n" "$1"; }
warn()     { WARNING=$((WARNING + 1));  printf "${YEL}  ⚠ WARN${RST}  %s\n" "$1"; }
critical() { CRITICAL=$((CRITICAL + 1)); printf "${RED}  ✗ CRIT${RST}  %s\n" "$1"; }
info()     { printf "  ℹ INFO  %s\n" "$1"; }
header()   { printf "\n${BLD}━━ %s ━━${RST}\n" "$1"; }

# Minimal TOML reader (matches kodo_toml_get logic)
toml_get() {
    local file="$1"
    if [[ $# -ge 3 ]]; then
        local section="$2" key="$3"
        awk -v section="$section" -v key="$key" '
            /^\[/ { in_section = ($0 ~ "^\\[" section "\\]") }
            in_section && $0 ~ "^" key "[[:space:]]*=" {
                sub(/^[^=]*=[[:space:]]*/, "")
                if (/^"/) { sub(/"[[:space:]]*#.*$/, "\"") }
                else if (/^'\''/) { sub(/'\''[[:space:]]*#.*$/, "'\''") }
                else { sub(/[[:space:]]*#.*$/, "") }
                gsub(/^["'\''"]|["'\''"][[:space:]]*$/, "")
                print; exit
            }
        ' "$file" 2>/dev/null
    else
        local key="$2"
        grep -m1 "^${key}[[:space:]]*=" "$file" 2>/dev/null \
            | sed 's/^[^=]*=[[:space:]]*//' \
            | sed 's/^"\([^"]*\)".*/\1/' \
            | sed "s/^'\([^']*\)'.*/\1/" \
            | sed 's/[[:space:]]*#.*$//'
    fi
}

toml_bool() {
    local val
    val="$(toml_get "$@")"
    [[ "$val" == "true" ]]
}

is_placeholder() {
    local cmd="$1"
    [[ -z "$cmd" ]] && return 0
    [[ "$cmd" =~ ^echo[[:space:]]+(no-tests?|no-lint|skip|placeholder)$ ]] && return 0
    return 1
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
printf "${BLD}KODO v4.2 Configuration Compatibility Audit${RST}\n"
printf "Target: %s\n" "$TOML"
printf "Date:   %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── 0. File existence ──────────────────────────────────────────
header "FILE EXISTENCE"

if [[ ! -f "$TOML" ]]; then
    critical "TOML not found: $TOML"
    echo ""
    echo "Cannot continue. The iris-gateway TOML does not exist."
    exit 1
fi
pass "TOML exists: $TOML"

REPO_ID="yoda-digital-iris-gateway"
KODO_MD="$KODO_LIVE/repos/${REPO_ID}.kodo.md"
VOICE_MD="$KODO_LIVE/repos/${REPO_ID}.voice.md"

if [[ -f "$KODO_MD" ]]; then
    local_lines=$(wc -l < "$KODO_MD")
    if [[ "$local_lines" -lt 5 ]]; then
        warn ".kodo.md exists but only $local_lines lines — might be placeholder"
    elif grep -q "Not yet documented" "$KODO_MD" 2>/dev/null; then
        warn ".kodo.md has unfilled placeholder sections"
    else
        pass ".kodo.md exists ($local_lines lines)"
    fi
else
    warn ".kodo.md NOT found: $KODO_MD — kodo-pm.sh weekly report will have no domain knowledge"
fi

if [[ -f "$VOICE_MD" ]]; then
    local_lines=$(wc -l < "$VOICE_MD")
    if [[ "$local_lines" -lt 5 ]]; then
        warn ".voice.md exists but only $local_lines lines — might be placeholder"
    elif grep -q "Not yet documented" "$VOICE_MD" 2>/dev/null; then
        warn ".voice.md has unfilled placeholder sections"
    else
        pass ".voice.md exists ($local_lines lines)"
    fi
else
    warn ".voice.md NOT found: $VOICE_MD — kodo-mkt.sh will fall back to TOML [voice] or defaults"
fi

# ── 1. [repo] section — REQUIRED fields ───────────────────────
header "[repo] SECTION — Core Identity"

for field in owner name provider mode; do
    val=$(toml_get "$TOML" "$field")
    if [[ -z "$val" ]]; then
        critical "[repo] $field is MISSING — engine will fail to start"
    else
        pass "[repo] $field = \"$val\""
    fi
done

# branch_default — default "main" in code, but should be explicit
val=$(toml_get "$TOML" "branch_default")
if [[ -z "$val" ]]; then
    warn "[repo] branch_default not set — code defaults to 'main', verify this is correct"
else
    pass "[repo] branch_default = \"$val\""
fi

# enabled
if toml_bool "$TOML" "repo" "enabled" 2>/dev/null || toml_bool "$TOML" "enabled" 2>/dev/null; then
    pass "[repo] enabled = true"
else
    val=$(toml_get "$TOML" "enabled")
    if [[ -z "$val" ]]; then
        warn "[repo] enabled not set — kodo-scout.sh checks this, missing = skipped"
    else
        critical "[repo] enabled = \"$val\" — repo will be SKIPPED by scout"
    fi
fi

# ── 2. [dev] section — PATCH 1 CRITICAL fields ────────────────
header "[dev] SECTION — Patch 1: Fake Gate Kill"

# test_command
test_cmd=$(toml_get "$TOML" "dev" "test_command")
if is_placeholder "$test_cmd"; then
    # This is the danger zone — check for tests_optional
    tests_opt=$(toml_get "$TOML" "dev" "tests_optional")
    if [[ "$tests_opt" == "true" ]]; then
        pass "test_command is placeholder/empty BUT tests_optional=true → gate skipped (intentional)"
    elif [[ -z "$tests_opt" ]]; then
        critical "test_command='$test_cmd' (placeholder) AND tests_optional NOT SET → EVERY PR WILL DEFER"
        info "Fix: set [dev] test_command to a real command, OR set [dev] tests_optional = true"
    else
        critical "test_command='$test_cmd' (placeholder) AND tests_optional=$tests_opt → EVERY PR WILL DEFER"
        info "Fix: set [dev] test_command to a real command, OR set [dev] tests_optional = true"
    fi
else
    pass "test_command = \"$test_cmd\" (real command)"
    # Verify tests_optional is set even if not needed (belt and suspenders)
    tests_opt=$(toml_get "$TOML" "dev" "tests_optional")
    if [[ -z "$tests_opt" ]]; then
        info "tests_optional not set (defaults to false — fine since test_command is real)"
    fi
fi

# lint_command
lint_cmd=$(toml_get "$TOML" "dev" "lint_command")
if is_placeholder "$lint_cmd"; then
    lint_opt=$(toml_get "$TOML" "dev" "lint_optional")
    if [[ "$lint_opt" == "true" ]]; then
        pass "lint_command is placeholder/empty BUT lint_optional=true → gate skipped (intentional)"
    elif [[ -z "$lint_opt" ]]; then
        critical "lint_command='$lint_cmd' (placeholder) AND lint_optional NOT SET → EVERY PR WILL DEFER"
        info "Fix: set [dev] lint_command to a real command, OR set [dev] lint_optional = true"
    else
        critical "lint_command='$lint_cmd' (placeholder) AND lint_optional=$lint_opt → EVERY PR WILL DEFER"
        info "Fix: set [dev] lint_command to a real command, OR set [dev] lint_optional = true"
    fi
else
    pass "lint_command = \"$lint_cmd\" (real command)"
    lint_opt=$(toml_get "$TOML" "dev" "lint_optional")
    if [[ -z "$lint_opt" ]]; then
        info "lint_optional not set (defaults to false — fine since lint_command is real)"
    fi
fi

# allow_no_ci
allow_no_ci=$(toml_get "$TOML" "dev" "allow_no_ci")
if [[ -z "$allow_no_ci" ]]; then
    warn "allow_no_ci NOT SET — defaults to false. If iris-gateway has CI, this is fine. If NOT, merges will be REFUSED."
    info "Fix: set [dev] allow_no_ci = false (explicit) if CI exists, or true if no CI"
else
    pass "allow_no_ci = \"$allow_no_ci\" (explicitly set)"
fi

# ── 3. [dev] section — PATCH 2 fields ─────────────────────────
header "[dev] SECTION — Patch 2: Post-Merge Monitoring"

mon_window=$(toml_get "$TOML" "dev" "monitoring_window_hours")
if [[ -z "$mon_window" ]]; then
    info "monitoring_window_hours not set — defaults to 48h (safe)"
else
    pass "monitoring_window_hours = $mon_window"
    if [[ "$mon_window" -lt 1 ]]; then
        warn "monitoring_window_hours=$mon_window is very short — monitoring will auto-resolve almost immediately"
    fi
fi

# ── 4. [dev] section — PATCH 3 fields ─────────────────────────
header "[dev] SECTION — Patch 3: Anti-Self-Grading"
info "Patch 3 uses pipeline metadata (architect_cli, gen_cli), not TOML fields — no config needed"
pass "No TOML changes required for Patch 3"

# ── 5. [dev] section — PATCH 5 fields ─────────────────────────
header "[dev] SECTION — Patch 5: Issue Intent Gate"

intent_gate=$(toml_get "$TOML" "dev" "issue_intent_gate")
if [[ -z "$intent_gate" ]]; then
    info "issue_intent_gate NOT SET — kodo_toml_bool returns false for missing → gate DISABLED (old behavior preserved)"
    warn "Recommend: set [dev] issue_intent_gate = false explicitly to document the decision"
else
    pass "issue_intent_gate = \"$intent_gate\" (explicitly set)"
    if [[ "$intent_gate" == "true" ]]; then
        # Check intent_window_hours
        intent_window=$(toml_get "$TOML" "dev" "intent_window_hours")
        if [[ -z "$intent_window" ]]; then
            info "intent_window_hours not set — defaults to 24h"
        else
            pass "intent_window_hours = $intent_window"
        fi
    fi
fi

# ── 6. [dev] section — Bot feedback loop fields ───────────────
header "[dev] SECTION — Bot Feedback Loop (pre-patch, still relevant)"

for field_name in await_bot_feedback feedback_window_minutes max_feedback_rounds apply_bot_suggestions; do
    val=$(toml_get "$TOML" "dev" "$field_name")
    if [[ -z "$val" ]]; then
        info "$field_name not set — code has safe defaults"
    else
        pass "$field_name = \"$val\""
    fi
done

# trusted_review_bots (array — special handling)
trusted_bots=$(toml_get "$TOML" "dev" "trusted_review_bots")
if [[ -z "$trusted_bots" ]]; then
    info "trusted_review_bots not set — bot suggestion apply won't match any bots"
else
    pass "trusted_review_bots = $trusted_bots"
fi

# ── 7. [dev] section — Other operational fields ───────────────
header "[dev] SECTION — Operational Fields"

for field_name in max_diff_lines auto_merge_deps semver_release max_rebase_attempts; do
    val=$(toml_get "$TOML" "dev" "$field_name")
    if [[ -z "$val" ]]; then
        info "$field_name not set — code has safe defaults"
    else
        pass "$field_name = \"$val\""
    fi
done

# ── 8. [dev] enabled ──────────────────────────────────────────
val=$(toml_get "$TOML" "dev" "enabled")
if [[ -z "$val" ]]; then
    warn "[dev] enabled not set — verify engine dispatch logic handles this"
elif [[ "$val" == "true" ]]; then
    pass "[dev] enabled = true"
else
    warn "[dev] enabled = $val — dev engine will be SKIPPED"
fi

# ── 9. [mkt] section ─────────────────────────────────────────
header "[mkt] SECTION"

for field_name in enabled welcome_new_contributors generate_changelogs; do
    val=$(toml_get "$TOML" "mkt" "$field_name")
    if [[ -z "$val" ]]; then
        info "[mkt] $field_name not set"
    else
        pass "[mkt] $field_name = \"$val\""
    fi
done

# ── 10. [pm] section ──────────────────────────────────────────
header "[pm] SECTION"

for field_name in enabled weekly_report daily_triage telegram_digest; do
    val=$(toml_get "$TOML" "pm" "$field_name")
    if [[ -z "$val" ]]; then
        info "[pm] $field_name not set"
    else
        pass "[pm] $field_name = \"$val\""
    fi
done

# ── 11. Residual old-code check ───────────────────────────────
header "CODE CONSISTENCY CHECK"

if grep -q 'echo no-tests' /home/ubuntu/gits/kodo-dev/bin/kodo-dev.sh 2>/dev/null | grep -v '^#' | grep -v '_is_placeholder_cmd' | grep -qv 'Match common'; then
    warn "Residual hardcoded 'echo no-tests' check found in kodo-dev.sh — should use _is_placeholder_cmd"
else
    pass "No residual hardcoded placeholder checks — all use _is_placeholder_cmd"
fi

# ── 12. Database schema compatibility ─────────────────────────
header "DATABASE SCHEMA"

DB="$KODO_LIVE/kodo.db"
if [[ ! -f "$DB" ]]; then
    critical "Database not found: $DB"
else
    pass "Database exists: $DB"

    # Check for new index from Patch 2
    idx=$(sqlite3 "$DB" ".indices pipeline_state" 2>/dev/null || true)
    if echo "$idx" | grep -q "idx_pipeline_monitoring"; then
        pass "idx_pipeline_monitoring index exists (Patch 2)"
    else
        warn "idx_pipeline_monitoring index MISSING — run: sqlite3 $DB < sql/schema.sql"
    fi

    # Check for merge_outcomes outcome CHECK constraint
    outcomes_schema=$(sqlite3 "$DB" ".schema merge_outcomes" 2>/dev/null || true)
    if echo "$outcomes_schema" | grep -q "reverted"; then
        pass "merge_outcomes has 'reverted' in CHECK constraint"
    else
        warn "merge_outcomes CHECK constraint may not include 'reverted' — verify schema"
    fi

    # Check for calibration_history table (Patch 6)
    tables=$(sqlite3 "$DB" ".tables" 2>/dev/null || true)
    if echo "$tables" | grep -q "calibration_history"; then
        pass "calibration_history table exists (Patch 6)"
    else
        warn "calibration_history table MISSING — run: sqlite3 $DB < sql/schema.sql"
    fi

    # Check for merge_outcome_stats_30d view (Patch 6 — optional, calibration may use inline query)
    if sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='view' AND name='merge_outcome_stats_30d';" 2>/dev/null | grep -q "merge_outcome_stats_30d"; then
        pass "merge_outcome_stats_30d view exists (Patch 6)"
    else
        info "merge_outcome_stats_30d view not present — calibration uses inline query (OK)"
    fi

    # Check for pr_feedback table (bot feedback loop)
    if echo "$tables" | grep -q "pr_feedback"; then
        pass "pr_feedback table exists"
    else
        warn "pr_feedback table MISSING — run: sqlite3 $DB < sql/schema.sql"
    fi

    # Check for stuck events
    # Terminal states: resolved, closed, deferred, pending (all domains)
    #                  published (MKT terminal), reported (PM terminal)
    stuck=$(sqlite3 "$DB" "SELECT event_id, state, updated_at FROM pipeline_state WHERE state NOT IN ('resolved', 'closed', 'deferred', 'pending', 'published', 'reported') AND updated_at < datetime('now', '-1 hour');" 2>/dev/null || true)
    if [[ -n "$stuck" ]]; then
        warn "Possibly stuck pipeline events (>1h in non-terminal state):"
        echo "$stuck" | while IFS= read -r line; do
            info "  $line"
        done
    else
        pass "No stuck pipeline events"
    fi
fi

# ── 13. .gitignore protection ─────────────────────────────────
header "DEPLOY SAFETY (.gitignore)"

GITIGNORE="$KODO_LIVE/.gitignore"
if [[ ! -f "$GITIGNORE" ]]; then
    critical ".gitignore NOT FOUND in $KODO_LIVE — git reset --hard will DESTROY local state"
else
    pass ".gitignore exists"
    for pattern in "kodo.db" "logs/" "telegram.conf"; do
        if grep -q "$pattern" "$GITIGNORE" 2>/dev/null; then
            pass ".gitignore protects: $pattern"
        else
            critical ".gitignore MISSING: $pattern — deploy will overwrite live state"
        fi
    done
    # repos/*.toml protection
    if grep -qE 'repos/\*\.toml|repos/' "$GITIGNORE" 2>/dev/null; then
        pass ".gitignore protects: repos/*.toml"
    else
        critical ".gitignore does NOT protect repos/*.toml — deploy will OVERWRITE iris-gateway config"
    fi
    # repos/*.kodo.md and *.voice.md
    if grep -qE 'repos/\*\.kodo\.md|repos/\*\.(kodo|voice)\.md|repos/' "$GITIGNORE" 2>/dev/null; then
        pass ".gitignore protects: repos/*.kodo.md and *.voice.md"
    else
        warn ".gitignore may not protect repos/*.kodo.md and *.voice.md — verify manually"
    fi
fi

# ── 14. Codebase deployed version check ───────────────────────
header "DEPLOYED CODE VERSION"

if [[ -d "$KODO_LIVE/.git" ]]; then
    deployed_sha=$(cd "$KODO_LIVE" && git rev-parse HEAD 2>/dev/null || echo "unknown")
    dev_sha=$(cd /home/ubuntu/gits/kodo-dev && git rev-parse HEAD 2>/dev/null || echo "unknown")
    pass "Deployed SHA: $deployed_sha"
    pass "Dev HEAD SHA: $dev_sha"
    if [[ "$deployed_sha" == "$dev_sha" ]]; then
        pass "Deployed code matches dev HEAD"
    else
        warn "Deployed code DIFFERS from dev HEAD — may need git pull"
    fi
else
    warn "$KODO_LIVE is not a git repository — cannot verify deployed version"
fi

# ── 15. Cron sanity ──────────────────────────────────────────
header "CRON SANITY"

cron_lines=$(crontab -l 2>/dev/null | grep -c "kodo-" || true)
if [[ "$cron_lines" -eq 4 ]]; then
    pass "Exactly 4 kodo cron entries found"
elif [[ "$cron_lines" -eq 0 ]]; then
    critical "No kodo cron entries — system is not running"
else
    warn "$cron_lines kodo cron entries found (expected 4)"
fi

# ── SUMMARY ──────────────────────────────────────────────────
header "SUMMARY"

echo ""
printf "  ${GRN}PASS:     %d${RST}\n" "$OK"
printf "  ${YEL}WARNINGS: %d${RST}\n" "$WARNING"
printf "  ${RED}CRITICAL: %d${RST}\n" "$CRITICAL"
echo ""

if [[ "$CRITICAL" -gt 0 ]]; then
    printf "${RED}${BLD}RESULT: NOT READY — fix all CRITICAL items before running KODO v4.2${RST}\n"
    echo ""
    echo "Quick-fix template for iris-gateway TOML — add any MISSING [dev] fields:"
    echo ""
    echo '  [dev]'
    echo '  tests_optional = false     # OR true if no test suite'
    echo '  lint_optional = false      # OR true if no linter'
    echo '  allow_no_ci = false        # OR true if no CI workflows'
    echo '  monitoring_window_hours = 48'
    echo '  issue_intent_gate = false  # preserve old behavior'
    echo '  intent_window_hours = 24'
    echo ""
    echo "Database schema update (idempotent, safe on live db):"
    echo "  sqlite3 $DB < /home/ubuntu/gits/kodo-dev/sql/schema.sql"
    echo ""
    exit 1
elif [[ "$WARNING" -gt 0 ]]; then
    printf "${YEL}${BLD}RESULT: READY WITH WARNINGS — review items above${RST}\n"
    exit 0
else
    printf "${GRN}${BLD}RESULT: FULLY READY${RST}\n"
    exit 0
fi
