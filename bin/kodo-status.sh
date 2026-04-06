#!/usr/bin/env bash
set -euo pipefail

# Terminal dashboard for KODO system state
# Read-only, zero side effects
# Usage: kodo-status.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kodo-lib.sh
source "$SCRIPT_DIR/kodo-lib.sh"

kodo_init_db

# ── Colors ───────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
DIM='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# ── Header ───────────────────────────────────────────────────

echo -e "${BOLD}KODO${NC} ${DIM}(鼓動)${NC} — Autonomous Repo Ops"
echo -e "${DIM}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo ""

# ── Repos ────────────────────────────────────────────────────

echo -e "${BOLD}REPOS${NC}"
echo -e "${DIM}──────────────────────────────────────${NC}"

for toml in "$KODO_HOME/repos/"*.toml; do
    [[ "$(basename "$toml")" == "_template.toml" ]] && continue
    [[ ! -f "$toml" ]] && continue

    local_rid="$(kodo_repo_id "$toml")"
    local_mode="$(kodo_toml_get "$toml" "mode")"

    if [[ "$local_mode" == "live" ]]; then
        mode_color="${GREEN}LIVE${NC}"
    else
        mode_color="${YELLOW}SHADOW${NC}"
    fi

    local_pending=$(kodo_sql "SELECT COUNT(*) FROM pipeline_state
        WHERE repo = '$(kodo_sql_escape "$local_rid")' AND state = 'pending';")
    local_active=$(kodo_sql "SELECT COUNT(*) FROM pipeline_state
        WHERE repo = '$(kodo_sql_escape "$local_rid")'
        AND state NOT IN ('pending','resolved','closed','deferred');")
    local_deferred=$(kodo_sql "SELECT COUNT(*) FROM pipeline_state
        WHERE repo = '$(kodo_sql_escape "$local_rid")' AND state = 'deferred';")

    echo -e "  ${BOLD}$local_rid${NC} [$mode_color] pending:$local_pending active:$local_active deferred:$local_deferred"
done

# ── Pipeline State ───────────────────────────────────────────

echo ""
echo -e "${BOLD}PIPELINE${NC}"
echo -e "${DIM}──────────────────────────────────────${NC}"

local_total=$(kodo_sql "SELECT COUNT(*) FROM pipeline_state;")
local_by_state=$(kodo_sql "SELECT state, COUNT(*) FROM pipeline_state GROUP BY state ORDER BY COUNT(*) DESC;")

if [[ -z "$local_by_state" ]]; then
    echo -e "  ${DIM}(empty)${NC}"
else
    while IFS='|' read -r state count; do
        case "$state" in
            resolved|published|reported) color="$GREEN" ;;
            deferred|closed) color="$RED" ;;
            pending) color="$YELLOW" ;;
            *) color="$CYAN" ;;
        esac
        echo -e "  ${color}$state${NC}: $count"
    done <<< "$local_by_state"
fi

echo -e "  ${DIM}Total: $local_total${NC}"

# ── Active Events ────────────────────────────────────────────

echo ""
echo -e "${BOLD}ACTIVE EVENTS${NC}"
echo -e "${DIM}──────────────────────────────────────${NC}"

local_active_events=$(kodo_sql "SELECT event_id, repo, domain, state, updated_at
    FROM pipeline_state
    WHERE state NOT IN ('resolved', 'closed', 'published', 'reported')
    ORDER BY updated_at DESC LIMIT 10;")

if [[ -z "$local_active_events" ]]; then
    echo -e "  ${DIM}(none)${NC}"
else
    while IFS='|' read -r eid repo domain state updated; do
        case "$domain" in
            dev) dcolor="$RED" ;;
            mkt) dcolor="$CYAN" ;;
            pm)  dcolor="$PURPLE" ;;
            *)   dcolor="$NC" ;;
        esac
        echo -e "  ${dcolor}[$domain]${NC} $eid ${DIM}($repo)${NC} → ${BOLD}$state${NC} ${DIM}$updated${NC}"
    done <<< "$local_active_events"
fi

# ── Budget ───────────────────────────────────────────────────

echo ""
echo -e "${BOLD}BUDGET${NC} ${DIM}(this month)${NC}"
echo -e "${DIM}──────────────────────────────────────${NC}"

for model_info in "claude:200" "codex:20" "gemini:0" "qwen:0"; do
    local_model="${model_info%%:*}"
    local_limit="${model_info#*:}"

    local_spent=$(kodo_sql "SELECT COALESCE(SUM(cost_usd), 0.0)
        FROM budget_ledger
        WHERE model = '$local_model' AND invoked_at > date('now', 'start of month');")

    local_calls=$(kodo_sql "SELECT COUNT(*)
        FROM budget_ledger
        WHERE model = '$local_model' AND invoked_at > date('now', 'start of month');")

    if [[ "$local_limit" == "0" ]]; then
        echo -e "  $local_model: ${GREEN}\$${local_spent}${NC} (free) | $local_calls calls"
    else
        echo -e "  $local_model: ${BOLD}\$${local_spent}${NC}/\$${local_limit} | $local_calls calls"
    fi
done

# ── CLI Status ───────────────────────────────────────────────

echo ""
echo -e "${BOLD}CLI STATUS${NC}"
echo -e "${DIM}──────────────────────────────────────${NC}"

for cli in claude codex gemini qwen gh glab; do
    if command -v "$cli" >/dev/null 2>&1; then
        echo -e "  $cli: ${GREEN}available${NC}"
    else
        echo -e "  $cli: ${RED}missing${NC}"
    fi
done

# ── Recent Errors ────────────────────────────────────────────

echo ""
echo -e "${BOLD}RECENT DEFERRALS${NC} ${DIM}(last 24h)${NC}"
echo -e "${DIM}──────────────────────────────────────${NC}"

local_recent=$(kodo_sql "SELECT event_id, repo, domain, reason
    FROM deferred_queue
    WHERE queued_at > datetime('now', '-1 day')
    ORDER BY queued_at DESC LIMIT 5;")

if [[ -z "$local_recent" ]]; then
    echo -e "  ${GREEN}(none)${NC}"
else
    while IFS='|' read -r eid repo domain reason; do
        echo -e "  ${RED}$eid${NC} ${DIM}($repo/$domain)${NC}: $reason"
    done <<< "$local_recent"
fi

echo ""
