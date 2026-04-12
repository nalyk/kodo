#!/usr/bin/env bash
set -euo pipefail

# Scenario 14: PM triage must iterate labels line-by-line, preserving spaces.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

if rg -n 'for label in \$labels' "$REPO_ROOT/bin/kodo-pm.sh" >/dev/null; then
    echo "  DIFF (expected vs actual):"
    echo "    PM triage still splits suggested labels on whitespace"
    exit 1
fi
