#!/usr/bin/env bash
set -euo pipefail

# Hook: reject CLI calls exceeding monthly budget
# Checks budget_ledger before allowing expensive CLI invocations

KODO_HOME="${KODO_HOME:-$HOME/.kodo}"
KODO_DB="${KODO_DB:-$KODO_HOME/kodo.db}"

# Budget limits
CLAUDE_LIMIT=200
CODEX_LIMIT=20

# Expects KODO_CLI_MODEL env var
CLI_MODEL="${KODO_CLI_MODEL:-}"

if [[ -z "$CLI_MODEL" ]]; then
    exit 0
fi

if [[ ! -f "$KODO_DB" ]]; then
    exit 0
fi

case "$CLI_MODEL" in
    claude)
        spent=$(sqlite3 "$KODO_DB" "SELECT COALESCE(SUM(cost_usd), 0.0) FROM budget_ledger
            WHERE model = 'claude' AND invoked_at > date('now', 'start of month');")
        if awk "BEGIN { exit ($spent >= $CLAUDE_LIMIT) ? 0 : 1 }"; then
            echo "BUDGET GATE: Claude budget exhausted (\$${spent}/\$${CLAUDE_LIMIT})" >&2
            exit 1
        fi
        ;;
    codex)
        spent=$(sqlite3 "$KODO_DB" "SELECT COALESCE(SUM(cost_usd), 0.0) FROM budget_ledger
            WHERE model = 'codex' AND invoked_at > date('now', 'start of month');")
        if awk "BEGIN { exit ($spent >= $CODEX_LIMIT) ? 0 : 1 }"; then
            echo "BUDGET GATE: Codex budget exhausted (\$${spent}/\$${CODEX_LIMIT})" >&2
            exit 1
        fi
        ;;
    gemini|qwen)
        # Free tier — always pass
        exit 0
        ;;
esac

exit 0
