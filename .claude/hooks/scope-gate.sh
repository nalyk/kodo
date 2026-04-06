#!/usr/bin/env bash
set -euo pipefail

# Hook: reject changes outside the related scope
# Ensures generated code only modifies files related to the issue/PR

KODO_HOME="${KODO_HOME:-$HOME/.kodo}"

# Expects KODO_ALLOWED_PATHS env var: newline-separated list of allowed file patterns
ALLOWED_PATHS="${KODO_ALLOWED_PATHS:-}"

if [[ -z "$ALLOWED_PATHS" ]]; then
    # No scope restriction defined — pass
    exit 0
fi

# Expects KODO_CHANGED_FILES env var: newline-separated list of changed files
CHANGED_FILES="${KODO_CHANGED_FILES:-}"

if [[ -z "$CHANGED_FILES" ]]; then
    exit 0
fi

# Check each changed file against allowed paths
while IFS= read -r changed_file; do
    [[ -z "$changed_file" ]] && continue

    local_match=false
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        # Simple glob matching
        if [[ "$changed_file" == $pattern ]]; then
            local_match=true
            break
        fi
    done <<< "$ALLOWED_PATHS"

    if [[ "$local_match" == "false" ]]; then
        echo "SCOPE GATE: $changed_file is outside allowed scope" >&2
        exit 1
    fi
done <<< "$CHANGED_FILES"

exit 0
