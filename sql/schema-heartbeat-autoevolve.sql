-- Additive heartbeat/autoevolve schema.
-- Safe to replay: only CREATE TABLE IF NOT EXISTS and CREATE INDEX IF NOT EXISTS.

CREATE TABLE IF NOT EXISTS heartbeat_trials (
    trial_id TEXT PRIMARY KEY,
    trial_ts TEXT,
    intervention_kind TEXT,
    target TEXT,
    h_before REAL,
    h_after REAL,
    delta REAL,
    status TEXT CHECK (status IN ('keep','discard','crash')),
    rationale TEXT
);

CREATE TABLE IF NOT EXISTS heartbeat_interventions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    trial_id TEXT,
    surface TEXT,
    before_json TEXT,
    after_json TEXT,
    reverted INTEGER DEFAULT 0,
    applied_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS heartbeat_baseline (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    captured_at TEXT,
    health_score REAL,
    signals_json TEXT
);

CREATE TABLE IF NOT EXISTS autoevolve_trials (
    trial_id TEXT PRIMARY KEY,
    trial_ts TEXT,
    hypothesis_source TEXT,
    target_functions TEXT,
    capability_before REAL,
    capability_after REAL,
    delta REAL,
    status TEXT CHECK (status IN ('keep','discard','crash')),
    description TEXT
);

CREATE TABLE IF NOT EXISTS autoevolve_calibration (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    trial_id TEXT,
    simulated_delta REAL,
    observed_delta REAL,
    status TEXT CHECK (status IN ('confirmed','revert','proxy_drift')),
    calibrated_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_heartbeat_trials_ts
    ON heartbeat_trials(trial_ts);
CREATE INDEX IF NOT EXISTS idx_heartbeat_trials_status
    ON heartbeat_trials(status);
CREATE INDEX IF NOT EXISTS idx_heartbeat_interventions_trial
    ON heartbeat_interventions(trial_id);
CREATE INDEX IF NOT EXISTS idx_heartbeat_baseline_captured
    ON heartbeat_baseline(captured_at);
CREATE INDEX IF NOT EXISTS idx_autoevolve_trials_ts
    ON autoevolve_trials(trial_ts);
CREATE INDEX IF NOT EXISTS idx_autoevolve_trials_status
    ON autoevolve_trials(status);
CREATE INDEX IF NOT EXISTS idx_autoevolve_calibration_trial
    ON autoevolve_calibration(trial_id);
CREATE INDEX IF NOT EXISTS idx_autoevolve_calibration_status
    ON autoevolve_calibration(status);
