#!/usr/bin/env bash
set -euo pipefail

# KODO Fixture-Based Regression Harness
# Usage: bash test/run-fixtures.sh
# Exits 0 if all scenarios pass, 1 if any fail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Pre-flight checks ──────────────────────────────────────

for dep in sqlite3 jq git; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "FATAL: $dep not found on PATH" >&2
        exit 2
    fi
done

# ── Run scenarios ──────────────────────────────────────────

pass_count=0
fail_count=0
skip_count=0
results=()

echo ""
echo "KODO Fixture Regression Harness"
echo "================================"
echo ""

for scenario_file in "$TEST_DIR"/scenarios/*.sh; do
    [[ ! -f "$scenario_file" ]] && continue

    scenario_name=$(basename "$scenario_file" .sh)
    printf "  %-45s " "$scenario_name"

    # Save and restore PATH around each scenario (mocks prepend to it)
    ORIG_PATH="$PATH"

    # Run in a subshell to isolate env and catch failures
    FIXTURE_RESULT="UNKNOWN"
    output=""
    if output=$(bash "$scenario_file" 2>&1); then
        # Check if the scenario set FIXTURE_RESULT (it's in a subshell, so we parse output)
        if echo "$output" | grep -q "DIFF (expected vs actual)"; then
            FIXTURE_RESULT="FAIL"
        elif echo "$output" | grep -q "MISSING expected file"; then
            FIXTURE_RESULT="FAIL"
        else
            FIXTURE_RESULT="PASS"
        fi
    else
        FIXTURE_RESULT="FAIL"
    fi

    PATH="$ORIG_PATH"

    case "$FIXTURE_RESULT" in
        PASS)
            echo "PASS"
            pass_count=$((pass_count + 1))
            ;;
        FAIL)
            echo "FAIL"
            fail_count=$((fail_count + 1))
            if [[ -n "$output" ]]; then
                echo "$output" | head -20 | sed 's/^/      /'
            fi
            ;;
        *)
            echo "SKIP"
            skip_count=$((skip_count + 1))
            ;;
    esac
    results+=("$FIXTURE_RESULT $scenario_name")
done

# ── Summary ────────────────────────────────────────────────

echo ""
echo "================================"
echo "Results: $pass_count passed, $fail_count failed, $skip_count skipped"
echo "================================"
echo ""

# Clean up any leftover fixture dirs (belt and suspenders)
rm -rf /tmp/kodo-fixtures-*-* 2>/dev/null || true

if [[ "$fail_count" -gt 0 ]]; then
    exit 1
fi
exit 0
