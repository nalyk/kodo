#!/usr/bin/env bash
set -euo pipefail

# Self-healing trial loop for KODO.
# Cron: */5 * * * * (flock protected)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kodo-lib.sh
source "$SCRIPT_DIR/kodo-lib.sh"

kodo_init_db

readonly HEARTBEAT_DIR="/tmp/heartbeat"
readonly PAUSE_FILE="/tmp/heartbeat/pause"
readonly LOCK_FILE="/tmp/heartbeat.lock"
readonly TSV_FILE="${KODO_HOME}/heartbeat_trials.tsv"
readonly HYPOTHESIS_SCHEMA="$SCRIPT_DIR/../schemas/hypothesis.schema.json"
readonly HEARTBEAT_BUDGET_USD="5.00"

TRIAL_ID=""
TRIAL_DIR=""
INTERVENTION_ID=""
INTERVENTION_KIND=""
INTERVENTION_TARGET="{}"
BASELINE_BEFORE=""
BASELINE_AFTER=""
SCORE_BEFORE="0"
SCORE_AFTER="0"
DELTA="0"
TRIAL_STATUS=""
TRIAL_REASON=""
TRIAL_FINALIZED=0
TERM_REQUESTED=0
ALERT_SENT=0

hb_log() {
    kodo_log "HEARTBEAT: $*"
}

sql_escape() {
    kodo_sql_escape "$1"
}

ensure_tables() {
    sqlite3 -cmd ".timeout 5000" "$KODO_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS heartbeat_trials (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    trial_id TEXT NOT NULL UNIQUE,
    intervention_kind TEXT NOT NULL DEFAULT '',
    target_json TEXT NOT NULL DEFAULT '{}',
    health_score_before REAL NOT NULL DEFAULT 0.0,
    health_score_after REAL NOT NULL DEFAULT 0.0,
    delta REAL NOT NULL DEFAULT 0.0,
    status TEXT NOT NULL CHECK (status IN ('keep','discard','crash','skipped')),
    reason TEXT NOT NULL DEFAULT '',
    health_json_before TEXT NOT NULL DEFAULT '{}',
    health_json_after TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS heartbeat_interventions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    trial_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    target_json TEXT NOT NULL DEFAULT '{}',
    before_json TEXT NOT NULL DEFAULT '{}',
    applied_at TEXT,
    reverted_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS heartbeat_baseline (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    captured_at TEXT NOT NULL,
    health_score REAL NOT NULL,
    health_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_heartbeat_baseline_created
    ON heartbeat_baseline(created_at);
CREATE INDEX IF NOT EXISTS idx_heartbeat_trials_created
    ON heartbeat_trials(created_at);
CREATE INDEX IF NOT EXISTS idx_heartbeat_interventions_trial
    ON heartbeat_interventions(trial_id);
SQL
}

heartbeat_enabled() {
    local cfg
    for cfg in "$KODO_HOME/config.toml" "$KODO_HOME/kodo.toml"; do
        [[ -f "$cfg" ]] || continue
        if [[ "$(kodo_toml_get "$cfg" "heartbeat" "enabled" 2>/dev/null || true)" == "false" ]]; then
            return 1
        fi
    done
    return 0
}

check_stop_signals() {
    if [[ -f "$PAUSE_FILE" ]]; then
        hb_log "pause file present — exiting"
        exit 0
    fi
    if ! heartbeat_enabled; then
        hb_log "heartbeat.enabled=false — exiting"
        exit 0
    fi
    if [[ "$TERM_REQUESTED" -eq 1 ]]; then
        hb_log "SIGTERM received — exiting"
        exit 0
    fi
}

send_alert() {
    local msg="$1"
    [[ "$ALERT_SENT" -eq 1 ]] && return 0
    ALERT_SENT=1
    if declare -F kodo_telegram >/dev/null 2>&1; then
        kodo_telegram "$msg" || true
    elif declare -F kodo_send_telegram >/dev/null 2>&1; then
        kodo_send_telegram "$msg" || true
    else
        local token chat_id
        token="$(kodo_toml_get "$KODO_HOME/telegram.conf" "bot_token" 2>/dev/null || true)"
        chat_id="$(kodo_toml_get "$KODO_HOME/telegram.conf" "chat_id" 2>/dev/null || true)"
        if [[ -n "$token" && -n "$chat_id" ]]; then
            curl -s -o /dev/null -X POST \
                "https://api.telegram.org/bot${token}/sendMessage" \
                -d chat_id="$chat_id" \
                -d text="$msg" \
                -d parse_mode="Markdown" 2>/dev/null || true
        fi
    fi
}

trial_budget_s() {
    local cfg val
    for cfg in "$KODO_HOME/config.toml" "$KODO_HOME/kodo.toml"; do
        [[ -f "$cfg" ]] || continue
        val="$(kodo_toml_get "$cfg" "heartbeat" "trial_budget_s" 2>/dev/null || true)"
        if [[ "$val" =~ ^[0-9]+$ && "$val" -gt 0 ]]; then
            echo "$val"
            return 0
        fi
    done
    echo "300"
}

begin_trial() {
    TRIAL_ID="trial-$(date +%Y%m%d%H%M%S)-$$"
    TRIAL_DIR="$HEARTBEAT_DIR/$TRIAL_ID"
    mkdir -p "$TRIAL_DIR"
    : > "$TRIAL_DIR/run.log"
}

record_baseline() {
    local health="$1"
    local captured score
    captured="$(jq -r '.captured_at // ""' <<< "$health")"
    score="$(jq -r '.health_score // 0' <<< "$health")"
    kodo_sql "INSERT INTO heartbeat_baseline (captured_at, health_score, health_json)
        VALUES ('$(sql_escape "$captured")', $score, '$(sql_escape "$health")');"
}

health_stale() {
    local health="$1"
    local captured epoch now
    captured="$(jq -r '.captured_at // empty' <<< "$health")"
    [[ -n "$captured" ]] || return 0
    epoch="$(date -d "$captured" +%s 2>/dev/null || echo 0)"
    now="$(date +%s)"
    [[ "$epoch" -gt 0 && $((now - epoch)) -le 120 ]]
}

run_health_once() {
    local out
    if ! out="$("$SCRIPT_DIR/kodo-health.sh" 2>"$HEARTBEAT_DIR/health.err")"; then
        return 1
    fi
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$out"; then
        return 1
    fi
    if jq -e 'has("_crash")' >/dev/null 2>&1 <<< "$out"; then
        return 1
    fi
    if ! health_stale "$out"; then
        return 1
    fi
    printf '%s\n' "$out"
}

capture_stable_baseline() {
    local h1 h2 h3 s1 s2 s3 spread
    h1="$(run_health_once)" || return 1
    sleep 1
    h2="$(run_health_once)" || return 1
    sleep 1
    h3="$(run_health_once)" || return 1

    s1="$(jq -r '.health_score' <<< "$h1")"
    s2="$(jq -r '.health_score' <<< "$h2")"
    s3="$(jq -r '.health_score' <<< "$h3")"
    spread="$(awk -v a="$s1" -v b="$s2" -v c="$s3" '
        BEGIN {
            min=a; max=a
            if (b<min) min=b; if (c<min) min=c
            if (b>max) max=b; if (c>max) max=c
            printf "%.4f", max-min
        }')"
    if awk -v s="$spread" 'BEGIN { exit (s > 0.02) ? 0 : 1 }'; then
        hb_log "unstable baseline spread=$spread — skipping tick"
        return 1
    fi
    record_baseline "$h3"
    printf '%s\n' "$h3"
}

next_intervention_id() {
    kodo_sql "SELECT COALESCE(MAX(id), 0) + 1 FROM heartbeat_interventions;"
}

write_before_snapshot() {
    local before="$1"
    printf '%s\n' "$before" > "$TRIAL_DIR/before.json"
    INTERVENTION_ID="$(next_intervention_id)"
    kodo_sql "INSERT INTO heartbeat_interventions
        (id, trial_id, kind, target_json, before_json, applied_at)
        VALUES ($INTERVENTION_ID, '$(sql_escape "$TRIAL_ID")',
        '$(sql_escape "$INTERVENTION_KIND")',
        '$(sql_escape "$INTERVENTION_TARGET")',
        '$(sql_escape "$before")', datetime('now'));"
}

append_tsv() {
    mkdir -p "$(dirname "$TSV_FILE")"
    if [[ ! -f "$TSV_FILE" ]]; then
        printf 'created_at\ttrial_id\tkind\tstatus\tscore_before\tscore_after\tdelta\treason\ttarget_json\n' >> "$TSV_FILE"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$TRIAL_ID" \
        "$INTERVENTION_KIND" \
        "$TRIAL_STATUS" \
        "$SCORE_BEFORE" \
        "$SCORE_AFTER" \
        "$DELTA" \
        "$(printf '%s' "$TRIAL_REASON" | tr '\t\n' '  ')" \
        "$(printf '%s' "$INTERVENTION_TARGET" | tr '\t\n' '  ')" >> "$TSV_FILE"
}

record_trial() {
    local before="${BASELINE_BEFORE:-{}}"
    local after="${BASELINE_AFTER:-{}}"
    kodo_sql "INSERT OR IGNORE INTO heartbeat_trials
        (trial_id, intervention_kind, target_json, health_score_before,
         health_score_after, delta, status, reason, health_json_before,
         health_json_after)
        VALUES ('$(sql_escape "$TRIAL_ID")',
        '$(sql_escape "$INTERVENTION_KIND")',
        '$(sql_escape "$INTERVENTION_TARGET")',
        $SCORE_BEFORE, $SCORE_AFTER, $DELTA,
        '$(sql_escape "$TRIAL_STATUS")',
        '$(sql_escape "$TRIAL_REASON")',
        '$(sql_escape "$before")',
        '$(sql_escape "$after")');"
    append_tsv
    TRIAL_FINALIZED=1
}

count_consecutive_crashes() {
    kodo_sql "SELECT COUNT(*) FROM (
        SELECT status FROM heartbeat_trials
        ORDER BY id DESC LIMIT 3
    ) WHERE status='crash';"
}

handle_crash_backoff() {
    local budget crashes
    budget="$(trial_budget_s)"
    crashes="$(count_consecutive_crashes)"
    if [[ "${crashes:-0}" -ge 3 ]]; then
        mkdir -p "$HEARTBEAT_DIR"
        touch "$PAUSE_FILE"
        send_alert "HIGH: KODO heartbeat paused after 3 consecutive crashes. Last trial: ${TRIAL_ID}"
        exit 0
    fi
    sleep "$((budget * 2))"
}

sql_rows_to_json() {
    local query="$1"
    sqlite3 -json -cmd ".timeout 5000" "$KODO_DB" "$query"
}

json_num() {
    jq -r "$1 // 0" <<< "$BASELINE_BEFORE"
}

json_str() {
    jq -r "$1 // empty" <<< "$BASELINE_BEFORE"
}

engine_busy_for_rows() {
    local where_sql="$1"
    local rows
    rows="$(kodo_sql "SELECT processing_pid FROM pipeline_state
        WHERE $where_sql
          AND processing_pid IS NOT NULL
          AND processing_pid > 0
        LIMIT 10;" 2>/dev/null || true)"
    [[ -z "$rows" ]] && return 1
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    done <<< "$rows"
    return 1
}

choose_deterministic_intervention() {
    local loop_rate stuck_ratio schema_errors lock_errors pm_rate pm_cohort deferred_growth success_1h total_rows dev_cohort
    loop_rate="$(json_num '.signals.loop_rate_per_min')"
    stuck_ratio="$(json_num '.signals.stuck_events_ratio')"
    schema_errors="$(json_num '.signals.schema_drift_errors_1h')"
    lock_errors="$(json_num '.signals.db_lock_errors_1h')"
    pm_rate="$(json_num '.signals.pm_schema_violation_rate')"
    pm_cohort="$(json_num '.cohorts.pm')"
    dev_cohort="$(json_num '.cohorts.dev')"
    deferred_growth="$(json_num '.signals.deferred_growth_1h')"
    success_1h="$(json_num '.signals.successful_resolutions_1h')"
    total_rows="$(json_num '.counts.pipeline_rows_total')"

    if awk -v v="$loop_rate" 'BEGIN { exit (v > 0.5) ? 0 : 1 }'; then
        local count
        count="$(kodo_sql "SELECT COUNT(*) FROM pipeline_state
            WHERE state='monitoring'
              AND COALESCE(json_extract(metadata_json, '$.redispatch_count'), 0) >= 10;")"
        if [[ "${count:-0}" -gt 0 ]]; then
            INTERVENTION_KIND="clear_redispatch_count"
            INTERVENTION_TARGET="$(jq -nc --argjson rows "$count" '{kind:"pipeline_state", rows:$rows}')"
            return 0
        fi
    fi

    if awk -v v="$stuck_ratio" 'BEGIN { exit (v > 0.15) ? 0 : 1 }'; then
        local count
        count="$(kodo_sql "SELECT COUNT(*) FROM pipeline_state
            WHERE state='triaging'
              AND updated_at < datetime('now', '-15 minutes');")"
        if [[ "${count:-0}" -gt 0 ]]; then
            INTERVENTION_KIND="reset_triaging_to_pending"
            INTERVENTION_TARGET="$(jq -nc --argjson rows "$count" '{kind:"pipeline_state", rows:$rows, limit:3}')"
            return 0
        fi
    fi

    if [[ "$schema_errors" -gt 0 ]]; then
        INTERVENTION_KIND="replay_schema_migration"
        INTERVENTION_TARGET='{"kind":"kodo_db"}'
        return 0
    fi

    if [[ "$lock_errors" -gt 0 ]]; then
        local mode
        mode="$(sqlite3 -cmd ".timeout 5000" "$KODO_DB" "PRAGMA journal_mode;" 2>/dev/null || true)"
        if [[ "$mode" != "wal" ]]; then
            INTERVENTION_KIND="enable_wal_mode"
            INTERVENTION_TARGET="$(jq -nc --arg mode "$mode" '{kind:"kodo_db", current_mode:$mode}')"
            return 0
        fi
    fi

    if awk -v p="$pm_rate" -v c="$pm_cohort" 'BEGIN { exit (p > 0.2 && c < 0.6) ? 0 : 1 }'; then
        INTERVENTION_KIND="pm_force_json_schema"
        INTERVENTION_TARGET='{"kind":"repos_toml","section":"pm","key":"output_validation"}'
        return 0
    fi

    if awk -v g="$deferred_growth" -v c="$dev_cohort" 'BEGIN { exit (g > 10 && c < 0.6) ? 0 : 1 }'; then
        local count
        count="$(kodo_sql "SELECT COUNT(*) FROM pipeline_state
            WHERE state='deferred' AND retry_count < 2;")"
        if [[ "${count:-0}" -gt 0 ]]; then
            INTERVENTION_KIND="drain_deferred_safe"
            INTERVENTION_TARGET="$(jq -nc --argjson rows "$count" '{kind:"pipeline_state", rows:$rows, limit:3}')"
            return 0
        fi
    fi

    if [[ "$success_1h" -eq 0 && "$total_rows" -gt 5 ]]; then
        local zeros
        zeros="$(kodo_sql "SELECT COUNT(*) FROM (
            SELECT health_json FROM heartbeat_baseline
            ORDER BY id DESC LIMIT 6
        ) WHERE COALESCE(json_extract(health_json, '$.signals.successful_resolutions_1h'), -1) = 0;")"
        if [[ "${zeros:-0}" -ge 6 ]]; then
            INTERVENTION_KIND="operator_alert_stall"
            INTERVENTION_TARGET='{"kind":"telegram","signal":"stall"}'
            return 0
        fi
    fi

    return 1
}

recent_degradation() {
    local base score count
    score="$(jq -r '.health_score' <<< "$BASELINE_BEFORE")"
    base="$(kodo_sql "SELECT AVG(health_score) FROM (
        SELECT health_score FROM heartbeat_baseline
        ORDER BY id DESC LIMIT 12
    );")"
    [[ -n "$base" ]] || return 1
    count="$(kodo_sql "SELECT COUNT(*) FROM (
        SELECT health_score FROM heartbeat_baseline
        ORDER BY id DESC LIMIT 3
    ) WHERE health_score < (($base) - 0.05);")"
    [[ "${count:-0}" -ge 3 ]] && awk -v s="$score" -v b="$base" 'BEGIN { exit (s < b - 0.05) ? 0 : 1 }'
}

heartbeat_budget_ok() {
    local spent
    spent="$(kodo_sql "SELECT COALESCE(SUM(cost_usd), 0.0)
        FROM budget_ledger
        WHERE model='claude'
          AND domain='heartbeat'
          AND invoked_at > date('now', 'start of month');")"
    awk -v spent="${spent:-0}" -v limit="$HEARTBEAT_BUDGET_USD" 'BEGIN { exit (spent < limit) ? 0 : 1 }'
}

tail_log_since_1h() {
    local file="$1"
    local cutoff
    cutoff="$(date -d "@$(( $(date +%s) - 3600 ))" '+%Y-%m-%d %H:%M:%S')"
    [[ -f "$file" ]] || return 0
    tail -n 50 "$file" | awk -v cutoff="[$cutoff" 'substr($0,1,20) >= cutoff { print }'
}

build_claude_prompt() {
    local recent trials logs whitelist
    recent="$(kodo_sql "SELECT health_json FROM heartbeat_baseline ORDER BY id DESC LIMIT 3;" | awk '{print}')"
    trials="$(tail -n 20 "$TSV_FILE" 2>/dev/null || true)"
    logs="$(
        for name in brain dev mkt pm; do
            printf '\n[%s.log]\n' "$name"
            tail_log_since_1h "$KODO_LOG_DIR/${name}.log"
        done
    )"
    whitelist='Mutable whitelist: repos/*.toml values only; pipeline_state.metadata_json keys redispatch_count, feedback_rounds, rebase_count, monitoring_polls reset to 0; confidence_bands.threshold auto_merge [85,95] ballot [40,60]; insert rows in heartbeat tables; /tmp/heartbeat file operations. kodo-health.sh, schemas, bin/*.sh, sql/schema.sql, context, CLAUDE.md and HEARTBEAT.md are read-only.'
    cat <<EOF
You are the KODO Heartbeat trial generator. Return one JSON object matching schemas/hypothesis.schema.json. No markdown.

Current health JSON:
$BASELINE_BEFORE

Last 3 health JSONs:
$recent

Recent logs:
$logs

Last 20 heartbeat trials:
$trials

$whitelist
EOF
}

choose_claude_intervention() {
    heartbeat_budget_ok || {
        hb_log "Claude heartbeat budget capped — skipping expensive path"
        return 1
    }
    [[ -f "$HYPOTHESIS_SCHEMA" ]] || {
        hb_log "missing $HYPOTHESIS_SCHEMA — skipping expensive path"
        return 1
    }
    command -v claude >/dev/null 2>&1 || {
        hb_log "claude CLI unavailable — skipping expensive path"
        return 1
    }

    local prompt raw kind target cost
    prompt="$(build_claude_prompt)"
    raw="$(claude -p "$prompt" --json-schema "$HYPOTHESIS_SCHEMA" </dev/null 2>"$TRIAL_DIR/claude.err")" || {
        kodo_log_budget "claude" "system" "heartbeat" 0 0 0.0 || true
        return 1
    }
    cost="$(jq -r '.total_cost_usd // .cost_usd // 0' <<< "$raw" 2>/dev/null || echo 0)"
    kodo_log_budget "claude" "system" "heartbeat" 0 0 "${cost:-0}" || true
    raw="$(jq -c '.structured_output // .' <<< "$raw" 2>/dev/null || printf '%s' "$raw")"
    jq -e 'type == "object"' >/dev/null 2>&1 <<< "$raw" || return 1
    kind="$(jq -r '.intervention // "null"' <<< "$raw")"
    if [[ "$kind" == "null" || -z "$kind" ]]; then
        target="$(jq -r '.target.kind // "unknown"' <<< "$raw")"
        send_alert "KODO heartbeat: Claude returned no intervention for ${target}."
        return 1
    fi
    INTERVENTION_KIND="$kind"
    INTERVENTION_TARGET="$(jq -c '.target // {}' <<< "$raw")"
    printf '%s\n' "$raw" > "$TRIAL_DIR/hypothesis.json"
    return 0
}

toml_set_existing() {
    local file="$1" section="$2" key="$3" value="$4"
    local tmp="${file}.heartbeat.$$"
    awk -v section="$section" -v key="$key" -v value="$value" '
        BEGIN { in_section=0; changed=0 }
        /^\[/ {
            if (in_section && !changed) exit 2
            in_section = ($0 == "[" section "]")
        }
        in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            prefix=$0
            sub(/=.*/, "= ", prefix)
            print prefix "\"" value "\""
            changed=1
            next
        }
        { print }
        END { if (!changed) exit 2 }
    ' "$file" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$file"
}

apply_clear_redispatch_count() {
    local before
    if engine_busy_for_rows "state='monitoring' AND COALESCE(json_extract(metadata_json, '$.redispatch_count'), 0) >= 10"; then
        hb_log "matching monitoring row is engine-owned — yielding"
        return 2
    fi
    before="$(sql_rows_to_json "SELECT event_id, domain, state, metadata_json FROM pipeline_state
        WHERE state='monitoring'
          AND COALESCE(json_extract(metadata_json, '$.redispatch_count'), 0) >= 10;")"
    [[ "$before" != "[]" ]] || return 1
    write_before_snapshot "$before"
    kodo_sql "UPDATE pipeline_state
        SET metadata_json = json_set(COALESCE(metadata_json, '{}'), '$.redispatch_count', 0),
            updated_at = datetime('now')
        WHERE state='monitoring'
          AND COALESCE(json_extract(metadata_json, '$.redispatch_count'), 0) >= 10;"
}

apply_reset_triaging_to_pending() {
    local before
    if engine_busy_for_rows "state='triaging' AND updated_at < datetime('now', '-15 minutes')"; then
        hb_log "matching triaging row is engine-owned — yielding"
        return 2
    fi
    before="$(sql_rows_to_json "SELECT event_id, domain, state, retry_count, updated_at FROM pipeline_state
        WHERE state='triaging'
          AND updated_at < datetime('now', '-15 minutes')
        ORDER BY updated_at ASC LIMIT 3;")"
    [[ "$before" != "[]" ]] || return 1
    write_before_snapshot "$before"
    jq -c '.[]' <<< "$before" | while IFS= read -r row; do
        local event_id domain
        event_id="$(jq -r '.event_id' <<< "$row")"
        domain="$(jq -r '.domain' <<< "$row")"
        kodo_sql "UPDATE pipeline_state
            SET state='pending',
                retry_count=retry_count + 1,
                updated_at=datetime('now')
            WHERE event_id='$(sql_escape "$event_id")'
              AND domain='$(sql_escape "$domain")';"
    done
}

apply_replay_schema_migration() {
    local schema
    schema="$KODO_HOME/sql/schema.sql"
    [[ -f "$schema" ]] || schema="$SCRIPT_DIR/../sql/schema.sql"
    [[ -f "$schema" ]] || return 1
    write_before_snapshot "$(jq -nc --arg schema "$schema" '{schema:$schema, rollback:"none"}')"
    sqlite3 -cmd ".timeout 5000" "$KODO_DB" < "$schema"
}

apply_enable_wal_mode() {
    local mode before
    mode="$(sqlite3 -cmd ".timeout 5000" "$KODO_DB" "PRAGMA journal_mode;" 2>/dev/null || true)"
    before="$(jq -nc --arg mode "$mode" '{journal_mode:$mode}')"
    write_before_snapshot "$before"
    sqlite3 -cmd ".timeout 5000" "$KODO_DB" "PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL;" >/dev/null
}

apply_pm_force_json_schema() {
    local before files file current entries
    entries="[]"
    files="$(find "$KODO_HOME/repos" "$SCRIPT_DIR/../repos" -maxdepth 1 -type f -name '*.toml' 2>/dev/null | sort -u || true)"
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        current="$(kodo_toml_get "$file" "pm" "output_validation" 2>/dev/null || true)"
        [[ -n "$current" && "$current" != "strict_json" ]] || continue
        entries="$(jq -c --arg file "$file" --arg value "$current" --rawfile content "$file" \
            '. + [{file:$file, value:$value, content:$content}]' <<< "$entries")"
    done <<< "$files"
    [[ "$entries" != "[]" ]] || return 1
    before="$entries"
    write_before_snapshot "$before"
    jq -r '.[].file' <<< "$before" | while IFS= read -r file; do
        toml_set_existing "$file" "pm" "output_validation" "strict_json"
    done
}

apply_drain_deferred_safe() {
    local before
    if engine_busy_for_rows "state='deferred' AND retry_count < 2"; then
        hb_log "matching deferred row is engine-owned — yielding"
        return 2
    fi
    before="$(sql_rows_to_json "SELECT event_id, domain, state, retry_count, updated_at FROM pipeline_state
        WHERE state='deferred' AND retry_count < 2
        ORDER BY updated_at ASC LIMIT 3;")"
    [[ "$before" != "[]" ]] || return 1
    write_before_snapshot "$before"
    jq -c '.[]' <<< "$before" | while IFS= read -r row; do
        local event_id domain
        event_id="$(jq -r '.event_id' <<< "$row")"
        domain="$(jq -r '.domain' <<< "$row")"
        kodo_sql "UPDATE pipeline_state
            SET state='pending',
                updated_at=datetime('now')
            WHERE event_id='$(sql_escape "$event_id")'
              AND domain='$(sql_escape "$domain")';"
    done
}

apply_operator_alert_stall() {
    write_before_snapshot '{"rollback":"none"}'
    send_alert "KODO heartbeat stall: zero successful resolutions for 6 ticks while pipeline has active rows."
}

apply_reset_metadata_key() {
    local hypothesis key identifier event_id domain before
    hypothesis="$(cat "$TRIAL_DIR/hypothesis.json")"
    key="$(jq -r '.parameters.key // empty' <<< "$hypothesis")"
    identifier="$(jq -r '.target.identifier // empty' <<< "$hypothesis")"
    [[ "$key" =~ ^(redispatch_count|feedback_rounds|rebase_count|monitoring_polls)$ ]] || return 1
    event_id="${identifier%%:*}"
    domain="${identifier##*:}"
    [[ -n "$event_id" && -n "$domain" && "$event_id" != "$domain" ]] || return 1
    before="$(sql_rows_to_json "SELECT event_id, domain, metadata_json FROM pipeline_state
        WHERE event_id='$(sql_escape "$event_id")' AND domain='$(sql_escape "$domain")';")"
    [[ "$before" != "[]" ]] || return 1
    write_before_snapshot "$before"
    kodo_sql "UPDATE pipeline_state
        SET metadata_json=json_set(COALESCE(metadata_json, '{}'), '$.$key', 0),
            updated_at=datetime('now')
        WHERE event_id='$(sql_escape "$event_id")' AND domain='$(sql_escape "$domain")';"
}

apply_toml_set() {
    local hypothesis file section key value current before
    hypothesis="$(cat "$TRIAL_DIR/hypothesis.json")"
    file="$(jq -r '.target.identifier // .parameters.file // empty' <<< "$hypothesis")"
    section="$(jq -r '.parameters.section // empty' <<< "$hypothesis")"
    key="$(jq -r '.parameters.key // empty' <<< "$hypothesis")"
    value="$(jq -r '.parameters.value // empty' <<< "$hypothesis")"
    [[ "$file" == "$KODO_HOME"/repos/*.toml || "$file" == "$SCRIPT_DIR"/../repos/*.toml ]] || return 1
    [[ -f "$file" && -n "$section" && "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    current="$(kodo_toml_get "$file" "$section" "$key" 2>/dev/null || true)"
    [[ -n "$current" ]] || return 1
    before="$(jq -nc --arg file "$file" --arg section "$section" --arg key "$key" --arg value "$current" --rawfile content "$file" '[{file:$file, section:$section, key:$key, value:$value, content:$content}]')"
    write_before_snapshot "$before"
    toml_set_existing "$file" "$section" "$key" "$value"
}

apply_threshold_bump() {
    local hypothesis band new before min max
    hypothesis="$(cat "$TRIAL_DIR/hypothesis.json")"
    band="$(jq -r '.target.identifier // .parameters.band // empty' <<< "$hypothesis")"
    new="$(jq -r '.parameters.threshold // .parameters.new_threshold // empty' <<< "$hypothesis")"
    case "$band" in
        auto_merge) min=85; max=95 ;;
        ballot) min=40; max=60 ;;
        *) return 1 ;;
    esac
    [[ "$new" =~ ^[0-9]+$ && "$new" -ge "$min" && "$new" -le "$max" ]] || return 1
    before="$(sql_rows_to_json "SELECT band, threshold FROM confidence_bands
        WHERE band='$(sql_escape "$band")';")"
    [[ "$before" != "[]" ]] || return 1
    write_before_snapshot "$before"
    kodo_sql "UPDATE confidence_bands
        SET threshold=$new, updated_at=datetime('now')
        WHERE band='$(sql_escape "$band")';"
}

apply_open_pr() {
    local hypothesis title target
    hypothesis="$(cat "$TRIAL_DIR/hypothesis.json")"
    title="$(jq -r '.parameters.title // "Heartbeat operator PR required"' <<< "$hypothesis")"
    target="$(jq -c '.target // {}' <<< "$hypothesis")"
    write_before_snapshot "$(jq -nc --argjson target "$target" '{rollback:"none", target:$target}')"
    send_alert "KODO heartbeat needs operator PR: ${title}"
}

apply_intervention() {
    {
        case "$INTERVENTION_KIND" in
            clear_redispatch_count) apply_clear_redispatch_count ;;
            reset_triaging_to_pending) apply_reset_triaging_to_pending ;;
            replay_schema_migration) apply_replay_schema_migration ;;
            enable_wal_mode) apply_enable_wal_mode ;;
            pm_force_json_schema) apply_pm_force_json_schema ;;
            drain_deferred_safe) apply_drain_deferred_safe ;;
            operator_alert_stall) apply_operator_alert_stall ;;
            reset_metadata_key) apply_reset_metadata_key ;;
            toml_set) apply_toml_set ;;
            threshold_bump) apply_threshold_bump ;;
            open_pr) apply_open_pr ;;
            *) return 1 ;;
        esac
    } >> "$TRIAL_DIR/run.log" 2>&1
}

revert_from_before_json() {
    [[ -n "$INTERVENTION_ID" ]] || return 0
    local before
    before="$(kodo_sql "SELECT before_json FROM heartbeat_interventions WHERE id=$INTERVENTION_ID;" 2>/dev/null || true)"
    [[ -n "$before" ]] || return 1
    case "$INTERVENTION_KIND" in
        clear_redispatch_count|reset_metadata_key)
            jq -c '.[]' <<< "$before" | while IFS= read -r row; do
                local event_id domain metadata
                event_id="$(jq -r '.event_id' <<< "$row")"
                domain="$(jq -r '.domain' <<< "$row")"
                metadata="$(jq -r '.metadata_json' <<< "$row")"
                kodo_sql "UPDATE pipeline_state
                    SET metadata_json='$(sql_escape "$metadata")', updated_at=datetime('now')
                    WHERE event_id='$(sql_escape "$event_id")' AND domain='$(sql_escape "$domain")';"
            done
            ;;
        reset_triaging_to_pending|drain_deferred_safe)
            jq -c '.[]' <<< "$before" | while IFS= read -r row; do
                local event_id domain state retry updated
                event_id="$(jq -r '.event_id' <<< "$row")"
                domain="$(jq -r '.domain' <<< "$row")"
                state="$(jq -r '.state' <<< "$row")"
                retry="$(jq -r '.retry_count' <<< "$row")"
                updated="$(jq -r '.updated_at' <<< "$row")"
                kodo_sql "UPDATE pipeline_state
                    SET state='$(sql_escape "$state")',
                        retry_count=$retry,
                        updated_at='$(sql_escape "$updated")'
                    WHERE event_id='$(sql_escape "$event_id")' AND domain='$(sql_escape "$domain")';"
            done
            ;;
        enable_wal_mode)
            local mode
            mode="$(jq -r '.journal_mode // empty' <<< "$before")"
            if [[ -n "$mode" && "$mode" != "wal" ]]; then
                sqlite3 -cmd ".timeout 5000" "$KODO_DB" "PRAGMA journal_mode=$mode;" >/dev/null || return 1
            fi
            ;;
        pm_force_json_schema|toml_set)
            jq -c '.[]' <<< "$before" | while IFS= read -r row; do
                local file
                file="$(jq -r '.file' <<< "$row")"
                [[ "$file" == "$KODO_HOME"/repos/*.toml || "$file" == "$SCRIPT_DIR"/../repos/*.toml ]] || return 1
                jq -j '.content' <<< "$row" > "$file"
            done
            ;;
        threshold_bump)
            jq -c '.[]' <<< "$before" | while IFS= read -r row; do
                local band threshold
                band="$(jq -r '.band' <<< "$row")"
                threshold="$(jq -r '.threshold' <<< "$row")"
                kodo_sql "UPDATE confidence_bands
                    SET threshold=$threshold, updated_at=datetime('now')
                    WHERE band='$(sql_escape "$band")';"
            done
            ;;
        replay_schema_migration|operator_alert_stall|open_pr)
            ;;
        *)
            return 1
            ;;
    esac
    kodo_sql "UPDATE heartbeat_interventions
        SET reverted_at=datetime('now')
        WHERE id=$INTERVENTION_ID;" || true
}

kind_is_cheap() {
    case "$1" in
        clear_redispatch_count|reset_triaging_to_pending|replay_schema_migration|enable_wal_mode|drain_deferred_safe|operator_alert_stall|reset_metadata_key)
            return 0 ;;
        *) return 1 ;;
    esac
}

kind_is_simplified_config() {
    case "$1" in
        pm_force_json_schema|toml_set|threshold_bump) return 0 ;;
        *) return 1 ;;
    esac
}

decide_trial_status() {
    if awk -v d="$DELTA" 'BEGIN { exit (d >= 0.05) ? 0 : 1 }'; then
        TRIAL_STATUS="keep"
        TRIAL_REASON="delta >= 0.05"
    elif awk -v d="$DELTA" 'BEGIN { exit (d > 0 && d < 0.05) ? 0 : 1 }'; then
        if kind_is_cheap "$INTERVENTION_KIND"; then
            TRIAL_STATUS="keep"
            TRIAL_REASON="small positive delta for cheap intervention"
        else
            TRIAL_STATUS="discard"
            TRIAL_REASON="small positive delta for touchy intervention"
        fi
    elif awk -v d="$DELTA" 'BEGIN { exit (d == 0) ? 0 : 1 }' && kind_is_simplified_config "$INTERVENTION_KIND"; then
        TRIAL_STATUS="keep"
        TRIAL_REASON="zero delta config simplification"
    else
        TRIAL_STATUS="discard"
        TRIAL_REASON="delta < 0 or no improvement"
    fi
}

finish_crash() {
    local reason="$1"
    TRIAL_STATUS="crash"
    TRIAL_REASON="$reason"
    DELTA="0"
    SCORE_AFTER="${SCORE_AFTER:-0}"
    if [[ -n "$INTERVENTION_ID" ]]; then
        revert_from_before_json || TRIAL_REASON="$TRIAL_REASON; revert failed"
    fi
    record_trial
    send_alert "KODO heartbeat trial crashed: ${TRIAL_ID} (${TRIAL_REASON})"
    handle_crash_backoff
}

on_exit() {
    local rc=$?
    if [[ "$TRIAL_FINALIZED" -eq 0 && -n "$TRIAL_ID" && -n "$INTERVENTION_KIND" ]]; then
        finish_crash "unexpected exit rc=$rc"
    fi
}

on_term() {
    TERM_REQUESTED=1
    if [[ "$TRIAL_FINALIZED" -eq 0 && -n "$TRIAL_ID" && -n "$INTERVENTION_KIND" ]]; then
        finish_crash "SIGTERM"
    fi
    exit 0
}

trap on_exit EXIT
trap on_term TERM

main() {
    mkdir -p "$HEARTBEAT_DIR"
    check_stop_signals
    ensure_tables

    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        exit 0
    fi

    check_stop_signals
    begin_trial

    BASELINE_BEFORE="$(capture_stable_baseline)" || exit 0
    SCORE_BEFORE="$(jq -r '.health_score' <<< "$BASELINE_BEFORE")"

    if ! choose_deterministic_intervention; then
        if recent_degradation; then
            choose_claude_intervention || exit 0
        else
            exit 0
        fi
    fi

    hb_log "trial $TRIAL_ID applying $INTERVENTION_KIND"
    local apply_rc=0
    if apply_intervention; then
        apply_rc=0
    else
        apply_rc=$?
    fi
    if [[ "$apply_rc" -eq 2 ]]; then
        TRIAL_FINALIZED=1
        exit 0
    fi
    if [[ "$apply_rc" -ne 0 ]]; then
        finish_crash "intervention failed"
        exit 0
    fi

    check_stop_signals
    sleep "$(trial_budget_s)"
    check_stop_signals

    if ! BASELINE_AFTER="$(run_health_once)"; then
        finish_crash "post-trial health read failed"
        exit 0
    fi
    record_baseline "$BASELINE_AFTER"
    SCORE_AFTER="$(jq -r '.health_score' <<< "$BASELINE_AFTER")"
    DELTA="$(awk -v a="$SCORE_AFTER" -v b="$SCORE_BEFORE" 'BEGIN { printf "%.4f", a-b }')"

    decide_trial_status
    if [[ "$TRIAL_STATUS" == "discard" ]]; then
        revert_from_before_json || finish_crash "revert failed"
    fi

    hb_log "trial $TRIAL_ID $TRIAL_STATUS delta=$DELTA kind=$INTERVENTION_KIND"
    record_trial
}

main "$@"
