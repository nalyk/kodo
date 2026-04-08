-- KODO v4 Database Schema
-- Runtime artifact: kodo.db (gitignored)
-- Init: sqlite3 kodo.db < sql/schema.sql

CREATE TABLE IF NOT EXISTS pending_events (
    event_id    TEXT PRIMARY KEY,
    repo        TEXT NOT NULL,
    event_type  TEXT NOT NULL,
    payload_json TEXT NOT NULL DEFAULT '{}',
    detected_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS pipeline_state (
    event_id       TEXT NOT NULL,
    repo           TEXT NOT NULL,
    domain         TEXT NOT NULL CHECK (domain IN ('dev', 'mkt', 'pm')),
    state          TEXT NOT NULL DEFAULT 'pending',
    payload_json   TEXT NOT NULL DEFAULT '{}',
    metadata_json  TEXT NOT NULL DEFAULT '{}',
    processing_pid INTEGER DEFAULT NULL,
    retry_count    INTEGER NOT NULL DEFAULT 0,
    created_at     TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at     TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (event_id, domain)
);

CREATE TABLE IF NOT EXISTS community_log (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    repo       TEXT NOT NULL,
    author     TEXT NOT NULL,
    action     TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_community_dedup
    ON community_log(repo, author, action);

CREATE TABLE IF NOT EXISTS pm_artifacts (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    repo       TEXT NOT NULL,
    type       TEXT NOT NULL CHECK (type IN ('weekly', 'triage', 'evaluation')),
    data_json  TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS budget_ledger (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    model      TEXT NOT NULL,
    repo       TEXT NOT NULL,
    domain     TEXT NOT NULL,
    tokens_in  INTEGER NOT NULL DEFAULT 0,
    tokens_out INTEGER NOT NULL DEFAULT 0,
    cost_usd   REAL NOT NULL DEFAULT 0.0,
    invoked_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS repo_metrics (
    repo              TEXT PRIMARY KEY,
    merge_count       INTEGER NOT NULL DEFAULT 0,
    avg_confidence    REAL NOT NULL DEFAULT 0.0,
    avg_time_to_merge REAL NOT NULL DEFAULT 0.0,
    incident_rate_30d REAL NOT NULL DEFAULT 0.0,
    updated_at        TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS merge_outcomes (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id   TEXT NOT NULL,
    repo       TEXT NOT NULL,
    confidence INTEGER NOT NULL,
    outcome    TEXT NOT NULL CHECK (outcome IN ('clean', 'reverted', 'hotfixed')),
    merged_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS deferred_queue (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id   TEXT NOT NULL,
    repo       TEXT NOT NULL,
    domain     TEXT NOT NULL,
    reason     TEXT NOT NULL DEFAULT '',
    queued_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS confidence_bands (
    band       TEXT PRIMARY KEY,
    threshold  INTEGER NOT NULL,
    incident_rate_30d REAL NOT NULL DEFAULT 0.0,
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Bootstrap default confidence bands
INSERT OR IGNORE INTO confidence_bands (band, threshold) VALUES
    ('auto_merge', 90),
    ('ballot', 50),
    ('defer', 0);

CREATE TABLE IF NOT EXISTS pr_feedback (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id          TEXT NOT NULL,
    repo              TEXT NOT NULL,
    review_id         TEXT NOT NULL,
    review_type       TEXT NOT NULL CHECK (review_type IN ('review', 'comment')),
    author            TEXT NOT NULL,
    author_is_bot     INTEGER NOT NULL DEFAULT 0,
    classification    TEXT NOT NULL DEFAULT 'pending'
                      CHECK (classification IN ('suggestion', 'concern', 'approval', 'changes_requested', 'informational', 'pending')),
    suggestion_applied INTEGER NOT NULL DEFAULT 0,
    raw_body          TEXT NOT NULL DEFAULT '',
    file_path         TEXT NOT NULL DEFAULT '',
    line_number       INTEGER NOT NULL DEFAULT 0,
    processed_at      TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (event_id, review_id)
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_pending_repo ON pending_events(repo);
CREATE INDEX IF NOT EXISTS idx_pipeline_repo ON pipeline_state(repo, domain);
CREATE INDEX IF NOT EXISTS idx_pipeline_state ON pipeline_state(state);
CREATE INDEX IF NOT EXISTS idx_budget_model_month ON budget_ledger(model, invoked_at);
CREATE INDEX IF NOT EXISTS idx_budget_repo ON budget_ledger(repo);
CREATE INDEX IF NOT EXISTS idx_merge_repo ON merge_outcomes(repo, merged_at);
CREATE INDEX IF NOT EXISTS idx_deferred_domain ON deferred_queue(domain);
CREATE INDEX IF NOT EXISTS idx_pr_feedback_event ON pr_feedback(event_id);
CREATE INDEX IF NOT EXISTS idx_pipeline_monitoring
    ON pipeline_state(state, updated_at)
    WHERE state = 'monitoring';
