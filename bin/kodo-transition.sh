#!/usr/bin/env bash
set -euo pipefail

# State machine enforcement
# ALL state transitions MUST go through this script
# Usage: kodo-transition.sh <event_id> <from_state> <to_state> <domain>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kodo-lib.sh
source "$SCRIPT_DIR/kodo-lib.sh"

kodo_init_db

# ── Valid Transitions ────────────────────────────────────────

# Dev domain transitions (from:to pairs)
declare -A DEV_TRANSITIONS=(
    ["*:pending"]=1
    ["pending:triaging"]=1
    ["triaging:generating"]=1
    ["triaging:auditing"]=1
    ["triaging:auto_merge"]=1
    ["triaging:hard_gates"]=1
    ["triaging:deferred"]=1
    ["triaging:closed"]=1
    ["triaging:awaiting_intent"]=1
    ["awaiting_intent:generating"]=1
    ["awaiting_intent:deferred"]=1
    ["generating:hard_gates"]=1
    ["generating:deferred"]=1
    ["hard_gates:auditing"]=1
    ["hard_gates:awaiting_feedback"]=1
    ["hard_gates:auto_merge"]=1
    ["hard_gates:deferred"]=1
    ["awaiting_feedback:auditing"]=1
    ["awaiting_feedback:applying_suggestions"]=1
    ["awaiting_feedback:deferred"]=1
    ["applying_suggestions:hard_gates"]=1
    ["applying_suggestions:auditing"]=1
    ["applying_suggestions:deferred"]=1
    ["auditing:scanning"]=1
    ["auditing:deferred"]=1
    ["scanning:auto_merge"]=1
    ["scanning:balloting"]=1
    ["scanning:deferred"]=1
    ["balloting:guarded_merge"]=1
    ["balloting:deferred"]=1
    ["auto_merge:releasing"]=1
    ["auto_merge:hard_gates"]=1
    ["auto_merge:deferred"]=1
    ["guarded_merge:releasing"]=1
    ["guarded_merge:hard_gates"]=1
    ["guarded_merge:deferred"]=1
    ["releasing:resolved"]=1
    ["releasing:monitoring"]=1
    ["releasing:reverting"]=1
    ["monitoring:resolved"]=1
    ["monitoring:reverting"]=1
    ["reverting:resolved"]=1
    ["reverting:deferred"]=1
    ["deferred:pending"]=1
    ["deferred:closed"]=1
)

# Marketing domain transitions
declare -A MKT_TRANSITIONS=(
    ["*:pending"]=1
    ["pending:drafting"]=1
    ["drafting:reviewing"]=1
    ["drafting:published"]=1
    ["drafting:deferred"]=1
    ["reviewing:published"]=1
    ["reviewing:deferred"]=1
    ["deferred:pending"]=1
    ["deferred:closed"]=1
)

# PM domain transitions
declare -A PM_TRANSITIONS=(
    ["*:pending"]=1
    ["pending:analyzing"]=1
    ["analyzing:reported"]=1
    ["analyzing:deferred"]=1
    ["deferred:pending"]=1
    ["deferred:closed"]=1
)

# ── Transition Logic ─────────────────────────────────────────

validate_transition() {
    local from="$1" to="$2" domain="$3"
    local key="${from}:${to}"

    case "$domain" in
        dev)
            [[ -v DEV_TRANSITIONS["$key"] ]] && return 0
            ;;
        mkt)
            [[ -v MKT_TRANSITIONS["$key"] ]] && return 0
            ;;
        pm)
            [[ -v PM_TRANSITIONS["$key"] ]] && return 0
            ;;
        *)
            kodo_log "ERROR: unknown domain '$domain'"
            return 1
            ;;
    esac

    kodo_log "INVALID TRANSITION: $from → $to (domain: $domain)"
    return 1
}

apply_transition() {
    local event_id="$1" from="$2" to="$3" domain="$4"
    local eid dom
    eid="$(kodo_sql_escape "$event_id")"
    dom="$(kodo_sql_escape "$domain")"

    # Validate
    if ! validate_transition "$from" "$to" "$domain"; then
        return 1
    fi

    # Special: deferred→pending increments retry_count, max 2
    if [[ "$from" == "deferred" && "$to" == "pending" ]]; then
        local retry_count
        retry_count=$(kodo_sql "SELECT retry_count FROM pipeline_state
            WHERE event_id = '$(kodo_sql_escape "$event_id")' AND domain = '$(kodo_sql_escape "$domain")';")
        if [[ "$retry_count" -ge 2 ]]; then
            kodo_log "MAX RETRIES: $event_id ($domain) — forcing closed"
            to="closed"
        fi
    fi

    # Initial state creation (*→pending)
    if [[ "$from" == "*" && "$to" == "pending" ]]; then
        local payload
        payload="${KODO_TRANSITION_PAYLOAD:-}"
        [[ -z "$payload" ]] && payload='{}'
        local rows_changed
        rows_changed=$(sqlite3 -cmd ".timeout 5000" "$KODO_DB" "
            INSERT OR IGNORE INTO pipeline_state (event_id, repo, domain, state, payload_json)
            VALUES (
                '${eid}',
                '$(kodo_sql_escape "${KODO_TRANSITION_REPO:-unknown}")',
                '${dom}',
                'pending',
                '$(kodo_sql_escape "$payload")'
            );
            SELECT changes();")
        if [[ "${rows_changed:-0}" -gt 0 ]]; then
            kodo_log "STATE: $event_id [$domain] * → pending"
        else
            kodo_log "STATE: $event_id [$domain] * → pending (already exists)"
        fi
        return 0
    fi

    # Verify current state matches expected
    local current_state
    current_state=$(kodo_sql "SELECT state FROM pipeline_state
        WHERE event_id = '${eid}' AND domain = '${dom}';")

    if [[ "$current_state" != "$from" ]]; then
        kodo_log "STATE MISMATCH: $event_id ($domain) expected '$from' but found '$current_state'"
        return 1
    fi

    # Apply transition atomically. Engines pass KODO_TRANSITION_OWNER_PID so a
    # stale or unclaimed worker cannot advance state it no longer owns.
    local retry_increment=""
    if [[ "$from" == "deferred" && "$to" == "pending" ]]; then
        retry_increment=", retry_count = retry_count + 1"
    fi
    local owner_clause=""
    if [[ -n "${KODO_TRANSITION_OWNER_PID:-}" ]]; then
        if [[ ! "$KODO_TRANSITION_OWNER_PID" =~ ^[0-9]+$ ]]; then
            kodo_log "ERROR: invalid transition owner PID for $event_id ($domain)"
            return 1
        fi
        owner_clause="AND processing_pid = ${KODO_TRANSITION_OWNER_PID}"
    fi

    local rows_changed
    rows_changed=$(sqlite3 -cmd ".timeout 5000" "$KODO_DB" "
        UPDATE pipeline_state
        SET state = '$(kodo_sql_escape "$to")', updated_at = datetime('now') $retry_increment
        WHERE event_id = '${eid}' AND domain = '${dom}'
        AND state = '$(kodo_sql_escape "$from")'
        ${owner_clause};
        SELECT changes();")

    if [[ "${rows_changed:-0}" -le 0 ]]; then
        current_state=$(kodo_sql "SELECT state FROM pipeline_state
            WHERE event_id = '${eid}' AND domain = '${dom}';")
        kodo_log "STATE LOST RACE: $event_id ($domain) expected '$from' but found '$current_state'"
        return 1
    fi

    kodo_log "STATE: $event_id [$domain] $from → $to"
    return 0
}

# ── Main ─────────────────────────────────────────────────────

main() {
    local event_id="${1:-}"
    local from="${2:-}"
    local to="${3:-}"
    local domain="${4:-}"

    if [[ -z "$event_id" || -z "$from" || -z "$to" || -z "$domain" ]]; then
        echo "Usage: kodo-transition.sh <event_id> <from> <to> <domain>" >&2
        echo "  Domains: dev | mkt | pm" >&2
        exit 1
    fi

    apply_transition "$event_id" "$from" "$to" "$domain"
}

# Allow sourcing for testing
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
