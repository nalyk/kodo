#!/usr/bin/env bash
set -euo pipefail

# Hook: reject diffs exceeding max_diff_lines
# Called by Claude hooks system before merge actions

KODO_HOME="${KODO_HOME:-$HOME/.kodo}"

# Read max_diff_lines from the active repo TOML
# Expects KODO_REPO_TOML env var set by the engine
REPO_TOML="${KODO_REPO_TOML:-}"

if [[ -z "$REPO_TOML" || ! -f "$REPO_TOML" ]]; then
    exit 0
fi

MAX_DIFF=$(grep -m1 "^max_diff_lines" "$REPO_TOML" 2>/dev/null \
    | sed 's/^[^=]*=[[:space:]]*//' | tr -d '"' || echo "500")
MAX_DIFF="${MAX_DIFF:-500}"

# Count diff lines from stdin or from the last git diff
DIFF_LINES="${KODO_DIFF_LINES:-0}"

if [[ "$DIFF_LINES" -gt "$MAX_DIFF" ]]; then
    echo "DIFF GATE: $DIFF_LINES lines exceeds limit of $MAX_DIFF" >&2
    exit 1
fi

exit 0
