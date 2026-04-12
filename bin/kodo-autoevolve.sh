#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kodo-lib.sh
source "$SCRIPT_DIR/kodo-lib.sh"
kodo_init_db
readonly AUTOEVOLVE_DIR="$KODO_HOME/autoevolve"
readonly PAUSE_FILE="/tmp/autoevolve/pause"
readonly LOCK_FILE="/tmp/autoevolve.lock"
readonly TSV_FILE="$KODO_HOME/autoevolve_trials.tsv"
readonly PLAN_SCHEMA="$SCRIPT_DIR/../schemas/autoevolve-hypothesis.schema.json"
readonly AUTO_TOML="$SCRIPT_DIR/../repos/_autoevolve.toml"
readonly REJECTED_DIR="$AUTOEVOLVE_DIR/rejected"
readonly SIMULATED_FILE="$AUTOEVOLVE_DIR/simulated-current.json"
readonly MONTHLY_BUDGET_USD="10.00"
TRIAL_ID=""
BRANCH_NAME=""
PLAN_JSON=""
PRIOR_CAPABILITY="{}"
SIMULATED_CAPABILITY="{}"
PRIOR_SCORE="0"
SIMULATED_SCORE="0"
FAST_DELTA="0"
IMPROVEMENT="0"
STATUS=""
REASON=""
RISK_LEVEL=""
HYPOTHESIS_SOURCE=""
DIFF_LINES="0"
LINES_ADDED="0"
LINES_DELETED="0"
PR_URL=""
TRIAL_FINALIZED=0
BRANCH_CREATED=0
ALERT_SENT=0
ae_log() {
    kodo_log "AUTOEVOLVE: $*"
}
sql_escape() {
    kodo_sql_escape "$1"
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
autoevolve_enabled() {
    [[ -f "$AUTO_TOML" ]] || return 1
    kodo_toml_bool "$AUTO_TOML" "autoevolve" "enabled" 2>/dev/null
}
heartbeat_enabled() {
    local cfg
    for cfg in "$KODO_HOME/config.toml" "$KODO_HOME/kodo.toml"; do
        [[ -f "$cfg" ]] || continue
        if [[ "$(kodo_toml_get "$cfg" "heartbeat" "enabled" 2>/dev/null || true)" == "true" ]]; then
            return 0
        fi
        if [[ "$(kodo_toml_get "$cfg" "heartbeat" "enabled" 2>/dev/null || true)" == "false" ]]; then
            return 1
        fi
    done
    return 1
}
paused_until_clear() {
    local raw epoch now
    raw="$(kodo_toml_get "$AUTO_TOML" "autoevolve" "paused_until" 2>/dev/null || true)"
    [[ -z "$raw" ]] && return 0
    epoch="$(date -d "$raw" +%s 2>/dev/null || echo 0)"
    [[ "$epoch" -eq 0 ]] && return 0
    now="$(date +%s)"
    [[ "$epoch" -le "$now" ]]
}
monthly_budget_ok() {
    local limit spent
    limit="$(kodo_toml_get "$AUTO_TOML" "autoevolve" "monthly_budget_usd" 2>/dev/null || true)"
    [[ "$limit" =~ ^[0-9]+(\.[0-9]+)?$ ]] || limit="$MONTHLY_BUDGET_USD"
    spent="$(kodo_sql "SELECT COALESCE(SUM(cost_usd), 0.0)
        FROM budget_ledger
        WHERE domain='autoevolve'
          AND invoked_at > date('now', 'start of month');" 2>/dev/null || echo "$limit")"
    awk -v s="${spent:-0}" -v l="$limit" 'BEGIN { exit (s < l) ? 0 : 1 }'
}
heartbeat_stable_24h() {
    local table_exists count
    table_exists="$(kodo_sql "SELECT COUNT(*) FROM sqlite_master
        WHERE type='table' AND name='heartbeat_baseline';" 2>/dev/null || echo 0)"
    [[ "${table_exists:-0}" -gt 0 ]] || return 1
    count="$(kodo_sql "SELECT COUNT(*) FROM heartbeat_baseline
        WHERE health_score >= 0.85
          AND created_at > datetime('now', '-24 hours');" 2>/dev/null || echo 0)"
    [[ "${count:-0}" -ge 3 ]]
}
capability_observed_ok() {
    local out mode crash baseline_at baseline_epoch now
    out="$("$SCRIPT_DIR/kodo-capability.sh" --mode observed 2>/tmp/autoevolve-capability.err)" || return 1
    jq -e 'type == "object"' >/dev/null 2>&1 <<< "$out" || return 1
    crash="$(jq -r '._crash // empty' <<< "$out")"
    [[ -z "$crash" ]] || return 1
    mode="$(jq -r '.mode // empty' <<< "$out")"
    [[ "$mode" == "observed" ]] || return 1
    baseline_at="$(jq -r '.baseline.captured_at // empty' <<< "$out")"
    baseline_epoch="$(date -d "$baseline_at" +%s 2>/dev/null || echo 0)"
    now="$(date +%s)"
    [[ "$baseline_epoch" -gt 0 && $((now - baseline_epoch)) -gt 604800 ]] || return 1
    PRIOR_CAPABILITY="$out"
    PRIOR_SCORE="$(jq -r '.capability_score // 0' <<< "$out")"
}
no_open_autoevolve_pr() {
    local prs
    [[ -f "$AUTO_TOML" ]] || return 1
    prs="$("$SCRIPT_DIR/kodo-git.sh" pr-list "$AUTO_TOML" 2>/dev/null)" || return 1
    ! jq -e '
        .[] |
        select((.state // "OPEN" | ascii_downcase) == "open") |
        select(
            (.headRefName // "" | startswith("autoevolve/")) or
            ([.labels[]? | if type == "object" then .name else . end] | map(ascii_downcase) | index("kodo-autoevolve"))
        )
    ' >/dev/null 2>&1 <<< "$prs"
}
fixtures_pass_current() {
    [[ -f "$SCRIPT_DIR/../test/run-fixtures.sh" ]] || return 1
    (cd "$SCRIPT_DIR/.." && bash test/run-fixtures.sh >/tmp/autoevolve-fixtures-main.log 2>&1)
}
hard_gate() {
    [[ ! -f "$PAUSE_FILE" ]] || return 1
    autoevolve_enabled || return 1
    heartbeat_enabled || return 1
    heartbeat_stable_24h || return 1
    capability_observed_ok || return 1
    monthly_budget_ok || return 1
    no_open_autoevolve_pr || return 1
    fixtures_pass_current || return 1
    paused_until_clear || return 1
}
ensure_tables() {
    sqlite3 -cmd ".timeout 5000" "$KODO_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS autoevolve_trials (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    trial_id TEXT NOT NULL UNIQUE,
    hypothesis_source TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL CHECK (status IN ('keep','discard','crash','empty','rejected')),
    risk_level TEXT NOT NULL DEFAULT '',
    prior_score REAL NOT NULL DEFAULT 0.0,
    simulated_score REAL NOT NULL DEFAULT 0.0,
    fast_delta REAL NOT NULL DEFAULT 0.0,
    improvement REAL NOT NULL DEFAULT 0.0,
    diff_lines INTEGER NOT NULL DEFAULT 0,
    lines_added INTEGER NOT NULL DEFAULT 0,
    lines_deleted INTEGER NOT NULL DEFAULT 0,
    reason TEXT NOT NULL DEFAULT '',
    plan_json TEXT NOT NULL DEFAULT '{}',
    pr_url TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS autoevolve_calibration (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    trial_id TEXT NOT NULL,
    simulated_delta REAL NOT NULL DEFAULT 0.0,
    observed_delta REAL NOT NULL DEFAULT 0.0,
    status TEXT NOT NULL DEFAULT 'pending',
    checked_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_autoevolve_trials_created
    ON autoevolve_trials(created_at);
CREATE INDEX IF NOT EXISTS idx_autoevolve_trials_status
    ON autoevolve_trials(status);
CREATE INDEX IF NOT EXISTS idx_autoevolve_calibration_trial
    ON autoevolve_calibration(trial_id);
SQL
}
next_trial_id() {
    local n
    n="$(kodo_sql "SELECT COALESCE(MAX(id), 0) + 1 FROM autoevolve_trials;" 2>/dev/null || echo 1)"
    printf 'autoevolve-%06d' "${n:-1}"
}
append_tsv() {
    mkdir -p "$(dirname "$TSV_FILE")"
    if [[ ! -f "$TSV_FILE" ]]; then
        printf 'created_at\ttrial_id\tsource\tstatus\trisk\tprior_score\tsimulated_score\tfast_delta\timprovement\tdiff_lines\tlines_added\tlines_deleted\treason\tpr_url\n' >> "$TSV_FILE"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$TRIAL_ID" \
        "$HYPOTHESIS_SOURCE" \
        "$STATUS" \
        "$RISK_LEVEL" \
        "$PRIOR_SCORE" \
        "$SIMULATED_SCORE" \
        "$FAST_DELTA" \
        "$IMPROVEMENT" \
        "$DIFF_LINES" \
        "$LINES_ADDED" \
        "$LINES_DELETED" \
        "$(printf '%s' "$REASON" | tr '\t\n' '  ')" \
        "$PR_URL" >> "$TSV_FILE"
}
record_trial() {
    kodo_sql "INSERT OR IGNORE INTO autoevolve_trials
        (trial_id, hypothesis_source, status, risk_level, prior_score,
         simulated_score, fast_delta, improvement, diff_lines, lines_added,
         lines_deleted, reason, plan_json, pr_url)
        VALUES ('$(sql_escape "$TRIAL_ID")',
        '$(sql_escape "$HYPOTHESIS_SOURCE")',
        '$(sql_escape "$STATUS")',
        '$(sql_escape "$RISK_LEVEL")',
        $PRIOR_SCORE, $SIMULATED_SCORE, $FAST_DELTA, $IMPROVEMENT,
        $DIFF_LINES, $LINES_ADDED, $LINES_DELETED,
        '$(sql_escape "$REASON")',
        '$(sql_escape "${PLAN_JSON:-{}}")',
        '$(sql_escape "$PR_URL")');"
    append_tsv
    TRIAL_FINALIZED=1
}
consecutive_crashes() {
    kodo_sql "SELECT COUNT(*) FROM (
        SELECT status FROM autoevolve_trials
        ORDER BY id DESC LIMIT 3
    ) WHERE status='crash';" 2>/dev/null || echo 0
}
maybe_pause_after_crashes() {
    local crashes
    crashes="$(consecutive_crashes)"
    if [[ "${crashes:-0}" -ge 3 ]]; then
        mkdir -p /tmp/autoevolve
        touch "$PAUSE_FILE"
        send_alert "HIGH: KODO autoevolve paused after 3 consecutive crashes. Last trial: ${TRIAL_ID}"
    fi
}
delete_trial_branch() {
    [[ "$BRANCH_CREATED" -eq 1 && -n "$BRANCH_NAME" ]] || return 0
    git checkout main >/dev/null 2>&1 || true
    git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
    BRANCH_CREATED=0
}
finish_crash() {
    local reason="$1"
    STATUS="crash"
    REASON="$reason"
    FAST_DELTA="0"
    IMPROVEMENT="0"
    delete_trial_branch
    record_trial
    maybe_pause_after_crashes
}
on_exit() {
    local rc=$?
    if [[ "$TRIAL_FINALIZED" -eq 0 && -n "$TRIAL_ID" && -n "$STATUS" ]]; then
        finish_crash "unexpected exit rc=$rc"
    fi
}
trap on_exit EXIT
mutable_functions() {
    awk -v root="$SCRIPT_DIR/../" -v bindir="$SCRIPT_DIR/" '
        FNR == 1 { marker=0 }
        /# autoevolve:mutable/ { marker=1; next }
        marker && /^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(\)[[:space:]]*\{/ {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]]*\(\).*/, "", line)
            file=FILENAME
            sub("^" root, "", file)
            sub("^" bindir, "bin/", file)
            print file "|" line
            marker=0
            next
        }
        marker && /^function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
            line=$0
            sub(/^function[[:space:]]+/, "", line)
            sub(/[[:space:]].*/, "", line)
            file=FILENAME
            sub("^" root, "", file)
            sub("^" bindir, "bin/", file)
            print file "|" line
            marker=0
            next
        }
        /^[^#[:space:]]/ { marker=0 }
    ' "$SCRIPT_DIR"/*.sh 2>/dev/null
}
split_field() {
    local n="$1" text="$2"
    awk -F'|' -v n="$n" '{print $n; exit}' <<< "$text"
}
first_matching_function() {
    local pattern="$1"
    mutable_functions | awk -F'|' -v pat="$pattern" '$0 ~ pat {print; exit}'
}
log_files() {
    local f
    for f in "$KODO_LOG_DIR"/*.log "$SCRIPT_DIR/../logs"/*.log; do
        [[ -f "$f" ]] && printf '%s\n' "$f"
    done
}
function_has_marker() {
    local file="$1" fn="$2"
    awk -v fn="$fn" '
        /# autoevolve:mutable/ { marker=NR; next }
        $0 ~ "^[[:space:]]*" fn "[[:space:]]*\\(\\)[[:space:]]*\\{" {
            if (marker && NR-marker <= 3) found=1
        }
        $0 ~ "^function[[:space:]]+" fn "([[:space:]]|\\()" {
            if (marker && NR-marker <= 3) found=1
        }
        END { exit found ? 0 : 1 }
    ' "$file"
}
plan_base() {
    local source="$1" rationale="$2" file="$3" fn="$4" predicted="$5" desc="$6" risk="$7"
    jq -nc \
        --arg trial_id "$TRIAL_ID" \
        --arg source "$source" \
        --arg rationale "$rationale" \
        --arg file "$file" \
        --arg fn "$fn" \
        --argjson predicted "$predicted" \
        --arg desc "$desc" \
        --arg risk "$risk" \
        '{
            trial_id: $trial_id,
            hypothesis_source: $source,
            rationale: $rationale,
            target_files: [$file],
            target_functions: (if $fn == "" then [] else [$fn] end),
            expected_factor_delta: {
                f_automation: 0.0,
                f_quality: 0.0,
                f_autonomy: 0.0,
                f_cost: $predicted,
                f_speed: 0.0
            },
            predicted_capability_delta: $predicted,
            diff_description: $desc,
            rollback_plan: "git revert the PR",
            risk_level: $risk
        }'
}
miner_1_dead_code() {
    local logs funcs file fn hits rel
    logs="$(log_files)"
    funcs="$(mutable_functions)"
    [[ -n "$funcs" ]] || return 1
    while IFS='|' read -r file fn; do
        [[ -n "$file" && -n "$fn" ]] || continue
        rel="${file#$SCRIPT_DIR/../}"
        rel="${rel#$SCRIPT_DIR/}"
        hits="0"
        if [[ -n "$logs" ]]; then
            while IFS= read -r log; do
                hits=$((hits + $(grep -c "$fn" "$log" 2>/dev/null || echo 0)))
            done <<< "$logs"
        fi
        if [[ "${hits:-0}" -eq 0 ]]; then
            plan_base "miner_1_dead_code" \
                "The mutable function ${fn} has no log-visible invocations in the last operational logs, so removing it is the safest simplification candidate." \
                "$rel" "$fn" "0.01" \
                "remove apparently dead mutable function ${fn} and any dead callers" \
                "low"
            return 0
        fi
    done <<< "$funcs"
    return 1
}
miner_2_bottleneck() {
    local row state avg count target file fn
    row="$(kodo_sql "
        SELECT state,
               ROUND(AVG((julianday('now') - julianday(updated_at)) * 86400.0), 2) AS avg_s,
               COUNT(*) AS n
        FROM pipeline_state
        WHERE state NOT IN ('resolved','closed','published','reported')
        GROUP BY state
        HAVING n > 0
        ORDER BY avg_s DESC
        LIMIT 1;" 2>/dev/null || true)"
    [[ -n "$row" ]] || return 1
    state="$(split_field 1 "$row")"
    avg="$(split_field 2 "$row")"
    count="$(split_field 3 "$row")"
    target="$(first_matching_function "\\|(_do_${state}|do_${state}|.*${state}.*)" || true)"
    [[ -n "$target" ]] || return 1
    file="$(split_field 1 "$target")"
    fn="$(split_field 2 "$target")"
    file="${file#$SCRIPT_DIR/../}"
    plan_base "miner_2_bottleneck" \
        "Pipeline state ${state} has the highest average time-in-state (${avg}s across ${count} rows), and ${fn} is the mutable handler candidate." \
        "$file" "$fn" "0.02" \
        "reduce time spent in ${state} by tightening ${fn}" \
        "medium"
}
miner_3_failure_class() {
    local logs reason target file fn
    logs="$(log_files)"
    [[ -n "$logs" ]] || return 1
    reason="$(awk '
        /deferred.*-- / {
            sub(/^.*deferred[[:space:]]*--[[:space:]]*/, "")
            reasons[$0]++
        }
        END {
            for (r in reasons) if (reasons[r] > max) { max=reasons[r]; best=r }
            if (best != "") print best
        }' $logs 2>/dev/null || true)"
    [[ -n "$reason" ]] || return 1
    target="$(first_matching_function '\|(defer|fallback|prompt|generation|build|codex|qwen|gemini)' || true)"
    [[ -n "$target" ]] || return 1
    file="$(split_field 1 "$target")"
    fn="$(split_field 2 "$target")"
    file="${file#$SCRIPT_DIR/../}"
    plan_base "miner_3_failure_class" \
        "The most frequent deferred failure class is '${reason}', so the relevant mutable retry or prompt function should be narrowed to reduce repeats." \
        "$file" "$fn" "0.02" \
        "address repeated deferred reason: ${reason}" \
        "medium"
}
miner_4_cost() {
    local row model domain avg target file fn
    row="$(kodo_sql "
        SELECT model, domain, ROUND(AVG(cost_usd), 4) AS avg_cost
        FROM budget_ledger
        WHERE invoked_at > datetime('now', '-30 days')
          AND cost_usd > 0
        GROUP BY model, domain
        ORDER BY avg_cost DESC
        LIMIT 1;" 2>/dev/null || true)"
    [[ -n "$row" ]] || return 1
    model="$(split_field 1 "$row")"
    domain="$(split_field 2 "$row")"
    avg="$(split_field 3 "$row")"
    target="$(first_matching_function "\\|(${model}|${domain}|prompt|invoke|llm)" || true)"
    [[ -n "$target" ]] || return 1
    file="$(split_field 1 "$target")"
    fn="$(split_field 2 "$target")"
    file="${file#$SCRIPT_DIR/../}"
    plan_base "miner_4_cost" \
        "The highest average LLM cost is ${model}/${domain} at ${avg} USD per call, so a mutable prompt or routing function should reduce spend." \
        "$file" "$fn" "0.03" \
        "reduce ${model}/${domain} cost with a smaller prompt or cheaper routing" \
        "medium"
}
miner_5_ablation() {
    local funcs total index target file fn next_index
    funcs="$(mutable_functions)"
    [[ -n "$funcs" ]] || return 1
    total="$(awk 'END {print NR}' <<< "$funcs")"
    [[ "$total" -gt 0 ]] || return 1
    index="$(kodo_sql "SELECT COALESCE(MAX(id), 0) % $total FROM autoevolve_trials;" 2>/dev/null || echo 0)"
    next_index=$((index + 1))
    target="$(printf '%s\n' "$funcs" | awk -v n="$next_index" 'NR==n {print}')"
    [[ -n "$target" ]] || return 1
    file="$(split_field 1 "$target")"
    fn="$(split_field 2 "$target")"
    file="${file#$SCRIPT_DIR/../}"
    plan_base "miner_5_ablation" \
        "Ablation rotation selected ${fn}; remove the last conditional branch and keep only if fixtures and simulated capability stay flat." \
        "$file" "$fn" "0.00" \
        "remove the last conditional branch in ${fn} as an ablation probe" \
        "low"
}
empty_days_count() {
    kodo_sql "SELECT COUNT(*) FROM (
        SELECT status FROM autoevolve_trials
        ORDER BY id DESC LIMIT 3
    ) WHERE status='empty';" 2>/dev/null || echo 0
}
autoevolve_budget_ok() {
    monthly_budget_ok
}
build_claude_prompt() {
    local trials capability miners whitelist autoevolve_doc mutable_dump
    trials="$(tail -n 5 "$TSV_FILE" 2>/dev/null || true)"
    capability="$PRIOR_CAPABILITY"
    miners="Miners 1-5 returned empty for this trial after priority-ordered execution."
    whitelist="Mutable whitelist: bin/*.sh only inside functions marked # autoevolve:mutable, context/runtime-rules.md, repos/_template.toml, repos/_template.kodo.md, repos/_template.voice.md, test/fixtures/*, test/scenarios/*. Forbidden: schemas, sql/schema.sql, kodo-health.sh, kodo-capability.sh, kodo-autoevolve.sh, kodo-heartbeat.sh, crontab, operator docs."
    mutable_dump="$(mutable_functions | while IFS='|' read -r file fn; do
        [[ -n "$file" ]] || continue
        printf '\n--- %s :: %s ---\n' "$file" "$fn"
        awk -v fn="$fn" '
            $0 ~ fn "[[:space:]]*\\(\\)" { in_fn=1 }
            in_fn && n < 120 { print; n++ }
            in_fn && /^}/ { exit }
        ' "$SCRIPT_DIR/../$file" 2>/dev/null
    done)"
    autoevolve_doc="$(cat "$SCRIPT_DIR/../AUTOEVOLVE.md")"
    cat <<EOF
Return one JSON object matching schemas/autoevolve-hypothesis.schema.json, or {"hypothesis": null, "reason": "..."} if no safe plan exists.
Trial id: $TRIAL_ID
Last 5 trials:
$trials
Current capability JSON:
$capability
Miner summary:
$miners
$whitelist
Mutable function contents:
$mutable_dump
AUTOEVOLVE.md:
$autoevolve_doc
EOF
}
miner_6_claude() {
    local prompt raw cost
    [[ "$(empty_days_count)" -ge 3 ]] || return 1
    autoevolve_budget_ok || return 1
    [[ -f "$PLAN_SCHEMA" ]] || return 1
    command -v claude >/dev/null 2>&1 || return 1
    prompt="$(build_claude_prompt)"
    raw="$(claude -p "$prompt" --json-schema "$PLAN_SCHEMA" </dev/null 2>/tmp/autoevolve-claude.err)" || {
        kodo_log_budget "claude" "kodo-dev" "autoevolve" 0 0 0.0 || true
        return 1
    }
    cost="$(jq -r '.total_cost_usd // .cost_usd // 0' <<< "$raw" 2>/dev/null || echo 0)"
    kodo_log_budget "claude" "kodo-dev" "autoevolve" 0 0 "${cost:-0}" || true
    raw="$(jq -c '.structured_output // .' <<< "$raw" 2>/dev/null || printf '%s' "$raw")"
    if jq -e 'has("hypothesis") and .hypothesis == null' >/dev/null 2>&1 <<< "$raw"; then
        return 1
    fi
    jq -e 'type == "object"' >/dev/null 2>&1 <<< "$raw" || return 1
    printf '%s\n' "$raw"
}
run_miners() {
    local plan
    if plan="$(miner_1_dead_code)"; then printf '%s\n' "$plan"; return 0; fi
    if plan="$(miner_2_bottleneck)"; then printf '%s\n' "$plan"; return 0; fi
    if plan="$(miner_3_failure_class)"; then printf '%s\n' "$plan"; return 0; fi
    if plan="$(miner_4_cost)"; then printf '%s\n' "$plan"; return 0; fi
    if plan="$(miner_5_ablation)"; then printf '%s\n' "$plan"; return 0; fi
    if plan="$(miner_6_claude)"; then printf '%s\n' "$plan"; return 0; fi
    return 1
}
file_in_whitelist() {
    local file="$1"
    case "$file" in
        bin/kodo-health.sh|bin/kodo-capability.sh|bin/kodo-autoevolve.sh|bin/kodo-heartbeat.sh)
            return 1 ;;
        bin/*.sh)
            [[ -f "$SCRIPT_DIR/../$file" ]] ;;
        context/runtime-rules.md|repos/_template.toml|repos/_template.kodo.md|repos/_template.voice.md)
            [[ -f "$SCRIPT_DIR/../$file" ]] ;;
        test/fixtures/*|test/scenarios/*)
            return 0 ;;
        *)
            return 1 ;;
    esac
}
validate_plan_schema() {
    jq -e '
        type == "object" and
        (.trial_id | type == "string") and
        (.hypothesis_source | IN("miner_1_dead_code","miner_2_bottleneck","miner_3_failure_class","miner_4_cost","miner_5_ablation","claude")) and
        (.target_files | type == "array" and length >= 1) and
        (.target_functions | type == "array") and
        (.expected_factor_delta | type == "object") and
        (.predicted_capability_delta | type == "number") and
        (.risk_level | IN("low","medium","high"))
    ' >/dev/null 2>&1 <<< "$PLAN_JSON"
}
validate_plan_whitelist() {
    local file fn has_bin_target=0
    validate_plan_schema || return 1
    while IFS= read -r file; do
        file_in_whitelist "$file" || return 1
        [[ "$file" == bin/*.sh ]] && has_bin_target=1
    done < <(jq -r '.target_files[]' <<< "$PLAN_JSON")
    if [[ "$has_bin_target" -eq 1 ]]; then
        [[ "$(jq '.target_functions | length' <<< "$PLAN_JSON")" -gt 0 ]] || return 1
    fi
    while IFS= read -r fn; do
        [[ -n "$fn" ]] || continue
        local found=0
        while IFS= read -r file; do
            [[ "$file" == bin/*.sh ]] || continue
            if function_has_marker "$SCRIPT_DIR/../$file" "$fn"; then
                found=1
                break
            fi
        done < <(jq -r '.target_files[]' <<< "$PLAN_JSON")
        [[ "$found" -eq 1 ]] || return 1
    done < <(jq -r '.target_functions[]?' <<< "$PLAN_JSON")
}
write_rejected_plan() {
    mkdir -p "$REJECTED_DIR"
    printf '%s\n' "$PLAN_JSON" > "$REJECTED_DIR/${TRIAL_ID}.json"
}
create_trial_branch() {
    BRANCH_NAME="autoevolve/$TRIAL_ID"
    git checkout main >/dev/null 2>&1 || return 1
    git checkout -b "$BRANCH_NAME" >/dev/null 2>&1 || return 1
    BRANCH_CREATED=1
}
builder_prompt() {
    cat <<EOF
You are executing a KODO autoevolve implementation plan. The plan is trusted only after local whitelist validation and appears between BEGIN_PLAN and END_PLAN.
CRITICAL SAFETY INSTRUCTIONS:
- Modify only the listed target_files.
- For bin/*.sh files, modify only listed target_functions and preserve every # autoevolve:mutable marker.
- Do not edit schemas, sql/schema.sql, kodo-health.sh, kodo-capability.sh, kodo-autoevolve.sh, kodo-heartbeat.sh, crontab, docs, AGENTS.md, README.md, CLAUDE.md, HEARTBEAT.md, or AUTOEVOLVE.md.
- Keep the diff minimal and do not commit.
BEGIN_PLAN
$PLAN_JSON
END_PLAN
Apply the change described by diff_description. Match existing bash style.
EOF
}
run_builder_chain() {
    local prompt cli before after changes
    prompt="$(builder_prompt)"
    before="$(git status --short)"
    for cli in codex qwen gemini; do
        kodo_cli_available "$cli" || continue
        ae_log "Phase B — $cli executing $TRIAL_ID"
        case "$cli" in
            codex)
                codex exec --full-auto --cd "$SCRIPT_DIR/.." "$prompt" </dev/null >/tmp/autoevolve-builder.out 2>/tmp/autoevolve-builder.err || true
                kodo_log_budget "codex" "kodo-dev" "autoevolve" 0 0 0.50 || true
                ;;
            qwen)
                (cd "$SCRIPT_DIR/.." && qwen -p "$prompt" --approval-mode yolo -o json </dev/null >/tmp/autoevolve-builder.out 2>/tmp/autoevolve-builder.err) || true
                kodo_log_budget "qwen" "kodo-dev" "autoevolve" 0 0 0.0 || true
                ;;
            gemini)
                (cd "$SCRIPT_DIR/.." && gemini -p "$prompt" --yolo </dev/null >/tmp/autoevolve-builder.out 2>/tmp/autoevolve-builder.err) || true
                kodo_log_budget "gemini" "kodo-dev" "autoevolve" 0 0 0.0 || true
                ;;
        esac
        after="$(git status --short)"
        if [[ "$after" != "$before" ]]; then
            changes="$(git diff --name-only && git ls-files --others --exclude-standard)"
            [[ -n "$changes" ]] && return 0
        fi
    done
    return 1
}
validate_diff_surface() {
    local file planned fn marker_before marker_after
    planned="$(jq -r '.target_files[]' <<< "$PLAN_JSON")"
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        echo "$planned" | grep -Fx "$file" >/dev/null 2>&1 || return 1
        file_in_whitelist "$file" || return 1
        if [[ "$file" == bin/*.sh ]]; then
            while IFS= read -r fn; do
                [[ -n "$fn" ]] || continue
                function_has_marker "$SCRIPT_DIR/../$file" "$fn" || return 1
            done < <(jq -r '.target_functions[]?' <<< "$PLAN_JSON")
        fi
    done < <(git diff --name-only && git ls-files --others --exclude-standard)
    while IFS= read -r file; do
        [[ "$file" == bin/*.sh ]] || continue
        marker_before="$(git show "main:$file" 2>/dev/null | grep -c '# autoevolve:mutable' || true)"
        marker_after="$(grep -c '# autoevolve:mutable' "$SCRIPT_DIR/../$file" 2>/dev/null || true)"
        [[ "$marker_before" == "$marker_after" ]] || return 1
    done < <(jq -r '.target_files[]' <<< "$PLAN_JSON")
}
compute_diff_stats() {
    local stat
    stat="$(git diff --numstat)"
    LINES_ADDED="$(awk '{s+=$1} END {print s+0}' <<< "$stat")"
    LINES_DELETED="$(awk '{s+=$2} END {print s+0}' <<< "$stat")"
    DIFF_LINES="$((LINES_ADDED + LINES_DELETED))"
}
run_fixture_proxy() {
    (cd "$SCRIPT_DIR/.." && bash test/run-fixtures.sh >/tmp/autoevolve-fixtures-trial.log 2>&1)
}
write_simulated_metrics() {
    local current predicted deleted_bonus cost speed automation quality autonomy
    mkdir -p "$AUTOEVOLVE_DIR"
    current="$(jq -c '.current' <<< "$PRIOR_CAPABILITY")"
    predicted="$(jq -r '.predicted_capability_delta // 0' <<< "$PLAN_JSON")"
    deleted_bonus="0"
    if [[ "$LINES_DELETED" -gt "$LINES_ADDED" ]]; then
        deleted_bonus="0.01"
    fi
    automation="$(jq -r '.automation_rate' <<< "$current")"
    quality="$(jq -r '.incident_rate' <<< "$current")"
    autonomy="$(jq -r '.alerts_per_event' <<< "$current")"
    cost="$(jq -r '.cost_per_resolution_usd' <<< "$current")"
    speed="$(jq -r '.median_time_to_resolution_s' <<< "$current")"
    jq -nc \
        --argjson current "$current" \
        --argjson predicted "$predicted" \
        --argjson bonus "$deleted_bonus" \
        --argjson automation "$automation" \
        --argjson incident "$quality" \
        --argjson alerts "$autonomy" \
        --argjson cost "$cost" \
        --argjson speed "$speed" \
        '
        ($predicted + $bonus) as $lift |
        {
            window_seconds: ($current.window_seconds // 604800),
            events_total: ($current.events_total // 1),
            events_clean_resolution: ($current.events_clean_resolution // 1),
            events_deferred: ($current.events_deferred // 0),
            events_incidents: ($current.events_incidents // 0),
            operator_alerts: ($current.operator_alerts // 0),
            total_budget_usd: ($current.total_budget_usd // 0),
            automation_rate: ([1.0, ($automation + ($lift / 4.0))] | min),
            incident_rate: ([0.0, ($incident - ($lift / 8.0))] | max),
            alerts_per_event: ([0.0, ($alerts - ($lift / 8.0))] | max),
            cost_per_resolution_usd: ([0.01, ($cost * (1.0 - ([0.20, $lift] | min)))] | max),
            median_time_to_resolution_s: ([1.0, ($speed * (1.0 - ([0.20, $lift] | min)))] | max)
        }' > "$SIMULATED_FILE"
}
run_capability_simulated() {
    local out
    out="$("$SCRIPT_DIR/kodo-capability.sh" --mode simulated 2>/tmp/autoevolve-capability-sim.err)" || return 1
    jq -e 'type == "object" and (.mode == "simulated") and (has("_crash") | not)' >/dev/null 2>&1 <<< "$out" || return 1
    SIMULATED_CAPABILITY="$out"
    SIMULATED_SCORE="$(jq -r '.capability_score // 0' <<< "$out")"
    FAST_DELTA="$(awk -v s="$SIMULATED_SCORE" 'BEGIN { printf "%.4f", s - 1.0 }')"
    local prior_fast
    prior_fast="$(kodo_sql "SELECT COALESCE(MAX(simulated_score), 1.0)
        FROM autoevolve_trials
        WHERE status='keep';" 2>/dev/null || echo "1.0")"
    IMPROVEMENT="$(awk -v s="$SIMULATED_SCORE" -v p="${prior_fast:-1.0}" 'BEGIN { printf "%.4f", s - p }')"
}
diff_removes_lines() {
    [[ "$LINES_DELETED" -gt "$LINES_ADDED" ]]
}
plan_is_simplification() {
    case "$HYPOTHESIS_SOURCE" in
        miner_1_dead_code|miner_5_ablation) return 0 ;;
        *) jq -r '.diff_description' <<< "$PLAN_JSON" | grep -qiE 'remove|delete|simplif' ;;
    esac
}
decide_keep_discard() {
    RISK_LEVEL="$(jq -r '.risk_level // "high"' <<< "$PLAN_JSON")"
    HYPOTHESIS_SOURCE="$(jq -r '.hypothesis_source // ""' <<< "$PLAN_JSON")"
    if awk -v i="$IMPROVEMENT" 'BEGIN { exit (i < 0) ? 0 : 1 }'; then
        STATUS="discard"; REASON="improvement < 0"; return 0
    fi
    if awk -v i="$IMPROVEMENT" 'BEGIN { exit (i == 0) ? 0 : 1 }'; then
        if diff_removes_lines; then
            STATUS="keep"; REASON="zero improvement with line removal"; return 0
        fi
        STATUS="discard"; REASON="zero improvement with added or flat diff"; return 0
    fi
    if awk -v i="$IMPROVEMENT" 'BEGIN { exit (i > 0 && i < 0.01) ? 0 : 1 }'; then
        if plan_is_simplification; then
            STATUS="keep"; REASON="small improvement for simplification"; return 0
        fi
        STATUS="discard"; REASON="improvement below 0.01"; return 0
    fi
    if awk -v i="$IMPROVEMENT" 'BEGIN { exit (i >= 0.01 && i < 0.02) ? 0 : 1 }'; then
        if [[ "$RISK_LEVEL" == "low" ]]; then
            STATUS="keep"; REASON="low-risk improvement >= 0.01"; return 0
        fi
        STATUS="discard"; REASON="medium/high risk improvement below 0.02"; return 0
    fi
    if awk -v i="$IMPROVEMENT" 'BEGIN { exit (i >= 0.02) ? 0 : 1 }'; then
        STATUS="keep"
        REASON="improvement >= 0.02"
        if [[ "$RISK_LEVEL" == "high" ]]; then
            REASON="high-risk improvement requires draft/operator review"
        elif [[ "$RISK_LEVEL" == "medium" ]]; then
            REASON="medium-risk improvement needs human review label"
        fi
        if awk -v i="$IMPROVEMENT" -v d="$DIFF_LINES" 'BEGIN { exit (i >= 0.05 && d > 100) ? 0 : 1 }'; then
            REASON="large high-impact diff requires draft/operator review"
        fi
        return 0
    fi
    STATUS="discard"; REASON="no keep rule matched"
}
commit_changes() {
    git add $(git diff --name-only) $(git ls-files --others --exclude-standard) >/dev/null 2>&1 || return 1
    git commit -m "kodo(dev): evolve -- ${TRIAL_ID}" >/dev/null 2>&1 || return 1
}
pr_body() {
    cat <<EOF
## Autoevolve Trial ${TRIAL_ID}
**Hypothesis source:** ${HYPOTHESIS_SOURCE}
**Risk level:** ${RISK_LEVEL}
**Fast proxy score:** ${SIMULATED_SCORE}
**Fast delta from Day-0:** ${FAST_DELTA}
**Improvement over prior kept trial:** ${IMPROVEMENT}
### Plan
$(jq -r '.rationale' <<< "$PLAN_JSON")
### Diff
$(jq -r '.diff_description' <<< "$PLAN_JSON")
Lines added: ${LINES_ADDED}
Lines deleted: ${LINES_DELETED}
### Rollback
$(jq -r '.rollback_plan' <<< "$PLAN_JSON")
### Simulated Capability
\`\`\`json
$SIMULATED_CAPABILITY
\`\`\`
EOF
}
open_autoevolve_pr() {
    local title body pr_num
    local desc
    desc="$(jq -r '.diff_description' <<< "$PLAN_JSON")"
    title="[kodo-autoevolve] ${TRIAL_ID}: ${desc:0:80}"
    if [[ "$RISK_LEVEL" == "high" ]] || awk -v i="$IMPROVEMENT" -v d="$DIFF_LINES" 'BEGIN { exit (i >= 0.05 && d > 100) ? 0 : 1 }'; then
        title="[DRAFT] $title"
        send_alert "KODO autoevolve produced a high-impact draft candidate: ${TRIAL_ID}"
    fi
    body="$(pr_body)"
    "$SCRIPT_DIR/kodo-git.sh" branch-push "$AUTO_TOML" "$SCRIPT_DIR/.." "$BRANCH_NAME" >/tmp/autoevolve-push.out 2>/tmp/autoevolve-push.err || return 1
    PR_URL="$("$SCRIPT_DIR/kodo-git.sh" pr-create "$AUTO_TOML" "$BRANCH_NAME" "$title" "$body" 2>/tmp/autoevolve-pr.err)" || return 1
    pr_num="$(printf '%s' "$PR_URL" | grep -oE '[0-9]+$' || true)"
    if [[ -n "$pr_num" ]]; then
        "$SCRIPT_DIR/kodo-git.sh" issue-label "$AUTO_TOML" "$pr_num" "kodo-autoevolve" >/dev/null 2>&1 || true
        if [[ "$RISK_LEVEL" == "medium" ]]; then
            "$SCRIPT_DIR/kodo-git.sh" issue-label "$AUTO_TOML" "$pr_num" "needs-human-review" >/dev/null 2>&1 || true
        fi
    fi
    kodo_sql "INSERT INTO autoevolve_calibration
        (trial_id, simulated_delta, observed_delta, status)
        VALUES ('$(sql_escape "$TRIAL_ID")', $FAST_DELTA, 0.0, 'pending');"
}
mark_empty_day() {
    STATUS="empty"
    REASON="miners empty"
    HYPOTHESIS_SOURCE=""
    PLAN_JSON="{}"
    record_trial
}
main() {
    mkdir -p /tmp/autoevolve "$AUTOEVOLVE_DIR"
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        exit 0
    fi
    hard_gate || exit 0
    ensure_tables
    TRIAL_ID="$(next_trial_id)"
    ae_log "starting $TRIAL_ID"
    if ! PLAN_JSON="$(run_miners)"; then
        mark_empty_day
        exit 0
    fi
    HYPOTHESIS_SOURCE="$(jq -r '.hypothesis_source // ""' <<< "$PLAN_JSON")"
    RISK_LEVEL="$(jq -r '.risk_level // ""' <<< "$PLAN_JSON")"
    if ! validate_plan_whitelist; then
        STATUS="rejected"
        REASON="plan failed whitelist validation"
        write_rejected_plan
        record_trial
        exit 0
    fi
    create_trial_branch || finish_crash "failed to create trial branch"
    if [[ "$STATUS" == "crash" ]]; then exit 0; fi
    run_builder_chain || finish_crash "builder produced no diff"
    if [[ "$STATUS" == "crash" ]]; then exit 0; fi
    validate_diff_surface || finish_crash "diff touched non-mutable surface"
    if [[ "$STATUS" == "crash" ]]; then exit 0; fi
    compute_diff_stats
    [[ "$DIFF_LINES" -gt 0 ]] || finish_crash "builder produced empty diff"
    if [[ "$STATUS" == "crash" ]]; then exit 0; fi
    run_fixture_proxy || finish_crash "fixture harness failed"
    if [[ "$STATUS" == "crash" ]]; then exit 0; fi
    write_simulated_metrics
    run_capability_simulated || finish_crash "simulated capability failed"
    if [[ "$STATUS" == "crash" ]]; then exit 0; fi
    decide_keep_discard
    if [[ "$STATUS" == "keep" ]]; then
        commit_changes || finish_crash "commit failed"
        if [[ "$STATUS" == "crash" ]]; then exit 0; fi
        open_autoevolve_pr || finish_crash "PR creation failed"
        if [[ "$STATUS" == "crash" ]]; then exit 0; fi
        git checkout main >/dev/null 2>&1 || true
        BRANCH_CREATED=0
    else
        delete_trial_branch
    fi
    record_trial
    ae_log "$TRIAL_ID $STATUS improvement=$IMPROVEMENT source=$HYPOTHESIS_SOURCE"
}
main "$@"
