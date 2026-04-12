-- Additive heartbeat/autoevolve schema.
-- Safe to replay: only CREATE TABLE IF NOT EXISTS and CREATE INDEX IF NOT EXISTS.

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
    status TEXT NOT NULL CHECK (status IN ('pending','confirmed','revert','proxy_drift')),
    checked_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    calibrated_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_heartbeat_trials_created
    ON heartbeat_trials(created_at);
CREATE INDEX IF NOT EXISTS idx_heartbeat_trials_status
    ON heartbeat_trials(status);
CREATE INDEX IF NOT EXISTS idx_heartbeat_interventions_trial
    ON heartbeat_interventions(trial_id);
CREATE INDEX IF NOT EXISTS idx_heartbeat_baseline_created
    ON heartbeat_baseline(created_at);
CREATE INDEX IF NOT EXISTS idx_autoevolve_trials_created
    ON autoevolve_trials(created_at);
CREATE INDEX IF NOT EXISTS idx_autoevolve_trials_status
    ON autoevolve_trials(status);
CREATE INDEX IF NOT EXISTS idx_autoevolve_calibration_trial
    ON autoevolve_calibration(trial_id);
CREATE INDEX IF NOT EXISTS idx_autoevolve_calibration_status
    ON autoevolve_calibration(status);
