#!/usr/bin/env bash
set -euo pipefail

# Scenario 15: kodo-add generated repo configs include new-repo intent gate defaults.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

dev_block=$(awk '
    /^\[dev\]/ { in_dev = 1; next }
    /^\[/ && in_dev { exit }
    in_dev { print }
' "$REPO_ROOT/bin/kodo-add.sh")

missing=()
echo "$dev_block" | grep -q 'issue_intent_gate = true' || missing+=("issue_intent_gate = true")
echo "$dev_block" | grep -q 'intent_window_hours = 24' || missing+=("intent_window_hours = 24")

if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "  DIFF (expected vs actual):"
    for item in "${missing[@]}"; do
        printf '    missing generated [dev] field: %s\n' "$item"
    done
    exit 1
fi
