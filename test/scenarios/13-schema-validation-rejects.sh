#!/usr/bin/env bash
set -euo pipefail

# Scenario 13: Schema-backed LLM calls reject extracted JSON that does not match schema.

SCENARIO_NAME="13-schema-validation-rejects"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TEST_DIR/lib-fixture.sh"

fixture_setup "$SCENARIO_NAME"
# shellcheck disable=SC1091
source "$KODO_FIXTURE_HOME/bin/kodo-lib.sh"

if kodo_invoke_llm qwen "Return a malformed confidence review." \
    --schema "$KODO_HOME/schemas/confidence.schema.json" \
    --repo "fixture-org-test-repo" \
    --domain "dev" >/dev/null 2>&1; then
    echo "  DIFF (expected vs actual):"
    echo "    invalid schema output was accepted"
    fixture_teardown
    exit 1
fi

fixture_teardown
