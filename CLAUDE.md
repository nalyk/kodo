# KŌDŌ — Agent Instructions

> KŌDŌ (鼓動, "heartbeat") — Autonomous Repo Ops via Headless CLIs.
> Bash scripts + markdown specs + cron jobs orchestrating headless AI CLIs
> to autonomously maintain git repositories.

- **Runtime**: bash 5+, SQLite 3, WSL2/Linux
- **Deployment**: `git clone ~/.kodo && crontab ~/.kodo/crontab.txt && kodo-add owner/repo`
- **Scale target**: 3–5 moderately active repos per installation
- **Three domains**: Development Ops · Marketing/Community Ops · Project Management Ops
- **Four CLIs**: `claude -p` · `codex exec` · `gemini -p` · `qwen -p`
- **Budget ceiling**: $220/month total ($200 Claude Max + $20 Codex Pro)
- **Docs root**: `docs/kodo-v4-complete-architecture.html` is the authoritative architecture reference

---

## Safety Constraints

These rules are non-negotiable. Violating any NEVER rule is a critical failure.

### NEVER

1. NEVER merge code without ALL Layer 1 hard gates passing (tests, semgrep, diff limits, scope check)
2. NEVER bypass the state machine — all transitions go through `kodo-transition.sh`
3. NEVER push directly to protected branches (`main`, `master`, `production`)
4. NEVER spend Claude budget on tasks the free-tier CLIs (Gemini, Qwen) can handle
5. NEVER fabricate metrics, confidence scores, or commit metadata
6. NEVER take write actions (merge, comment, close, label) during shadow mode — log only
7. NEVER parse free-text LLM output — ALL structured data MUST use `--json-schema`
8. NEVER call `gh` / `glab` directly — ALL git-provider operations go through `kodo-git.sh`
9. NEVER create cron entries beyond the 4 defined in `crontab.txt`
10. NEVER auto-merge with confidence score below 90
11. NEVER act on events from repos not registered in `repos/*.toml`

### ALWAYS

1. ALWAYS log every CLI invocation to `budget_ledger` with model, tokens, cost, repo, domain
2. ALWAYS use `--json-schema <path>` when invoking any LLM for structured output
3. ALWAYS check `pipeline_state` before acting on an event — another engine may own it
4. ALWAYS route git operations through `kodo-git.sh <action> <repo>` for provider abstraction
5. ALWAYS include `event_id` in branch names, commit messages, and state transitions
6. ALWAYS verify `repo_mode` (shadow | live) before taking write actions
7. ALWAYS use `set -euo pipefail` in all bash scripts

---

## Architecture

### System Flow

```
cron (4 entries)
  │
  ├─ */2 * * * * ──► kodo-scout.sh ──► kodo.db (pending_events)
  │
  ├─ * * * * * ────► kodo-brain.sh ──► classify event ──┬── dev ──► kodo-dev.sh
  │                   (flock protected)                  ├── mkt ──► kodo-mkt.sh
  │                                                      └── pm  ──► kodo-pm.sh
  │
  ├─ 0 10 * * * ──► kodo-pm.sh --daily-triage
  │
  └─ 0 9 * * 1 ──► kodo-weekly.sh (PM weekly + self-health)
```

All domain engines write state via `kodo-transition.sh` → `kodo.db`.

### Component Table

| Component | File | Role | Frequency |
|-----------|------|------|-----------|
| Scout | `bin/kodo-scout.sh` | Detect GitHub events across all repos, INSERT into pending_events | Every 2 min |
| Brain | `bin/kodo-brain.sh` | Read event queue, classify (dev\|mkt\|pm), route to engine | Every 1 min (flock) |
| Dev Engine | `bin/kodo-dev.sh` | PR review, code gen, CI watch, merge, release, revert | Event-driven |
| Marketing Engine | `bin/kodo-mkt.sh` | Contributor response, docs, changelog, announcements | Event-driven |
| PM Engine | `bin/kodo-pm.sh` | Roadmap, backlog, priorities, velocity, digest | Event + daily + weekly |
| State Machine | `bin/kodo-transition.sh` | Enforce deterministic state transitions per domain | Called by engines |
| Weekly | `bin/kodo-weekly.sh` | Self-health check + PM weekly report + Telegram digest | Monday 09:00 |
| Status | `bin/kodo-status.sh` | Terminal dashboard for system state | On demand |
| Onboard | `bin/kodo-add.sh` | Add new repo (discover → validate → shadow → live) | On demand |
| Git Adapter | `bin/kodo-git.sh` | Provider abstraction (GitHub/GitLab/Gitea/Bitbucket) | Called by all engines |

### Event Classification (Deterministic — No LLM)

Routing is bash logic, not LLM-based. Classification uses event type + author + labels.

| Event Type | Condition | Routes To |
|------------|-----------|-----------|
| PullRequestEvent | any | DEV |
| PushEvent | any | DEV |
| IssuesEvent | label: bug, feature, enhancement | DEV |
| IssuesEvent | label: question, help-wanted | MKT |
| IssuesEvent | label: priority, roadmap, planning | PM |
| IssueCommentEvent | from external contributor | MKT |
| IssueCommentEvent | review or technical content | DEV |
| ReleaseEvent | any | MKT |
| ForkEvent / WatchEvent | any | MKT |
| DiscussionEvent | any | MKT |
| MilestoneEvent | any | PM |

Note: an event MAY route to multiple domains (e.g., a bug from an external contributor → DEV + MKT).

---

## File System Layout

```
~/.kodo/
├── CLAUDE.md                          # This file — agent instructions for claude -p
├── AGENTS.md                          # Code generator rules for codex exec
├── .gemini/
│   └── GEMINI.md                      # Content + scanner rules for gemini -p
├── .qwen/
│   └── QWEN.md                        # Triage + gardening rules for qwen -p
├── bin/
│   ├── kodo-scout.sh                  # Event detection across all repos
│   ├── kodo-brain.sh                  # Event classification + routing
│   ├── kodo-dev.sh                    # Development ops engine
│   ├── kodo-mkt.sh                    # Marketing/community ops engine
│   ├── kodo-pm.sh                     # Project management ops engine
│   ├── kodo-transition.sh             # State machine enforcement
│   ├── kodo-weekly.sh                 # Self-health + PM weekly
│   ├── kodo-status.sh                 # Terminal dashboard
│   ├── kodo-add.sh                    # Repo onboarding
│   └── kodo-git.sh                    # Git provider abstraction layer
├── repos/
│   ├── _template.toml                 # Template for new repo configs
│   ├── {owner}-{repo}.toml            # Per-repo configuration
│   ├── {owner}-{repo}.voice.md        # Optional: voice profile + golden examples
│   └── {owner}-{repo}.kodo.md         # Optional: domain knowledge for PM
├── schemas/
│   ├── confidence.schema.json         # Structured confidence output from reviews
│   ├── triage.schema.json             # Structured triage output for PM
│   ├── discovery.schema.json          # Structured repo auto-discovery output
│   └── pm-report.schema.json          # Structured PM analysis output
├── .claude/
│   └── skills/
│       ├── kodo-audit/SKILL.md        # Code review skill
│       ├── kodo-discover/SKILL.md     # Repo auto-configuration skill
│       ├── kodo-changelog/SKILL.md    # Release notes generation skill
│       ├── kodo-welcome/SKILL.md      # Contributor onboarding skill
│       ├── kodo-roadmap/SKILL.md      # Weekly PM analysis skill
│       ├── kodo-triage/SKILL.md       # Issue classification skill
│       └── kodo-security/SKILL.md     # Vulnerability scan summarization
├── .claude/
│   └── hooks/
│       ├── diff-gate.sh               # Reject diffs exceeding max_diff_lines
│       ├── scope-gate.sh              # Reject changes outside related files
│       └── budget-gate.sh             # Reject CLI calls exceeding budget
├── .gemini/skills/                    # Gemini-specific skills (same structure)
├── .qwen/skills/                      # Qwen-specific skills (same structure)
├── docs/
│   └── kodo-v4-complete-architecture.html  # Full architecture reference
├── kodo.db                            # SQLite database (runtime, .gitignored)
├── crontab.txt                        # 4 cron entries — the complete schedule
└── logs/                              # Runtime logs (.gitignored)
```

### Naming Conventions

| Entity | Pattern | Example |
|--------|---------|---------|
| Script | `kodo-{function}.sh` | `kodo-scout.sh` |
| Repo config | `repos/{owner}-{repo}.toml` | `repos/acme-api.toml` |
| Voice profile | `repos/{owner}-{repo}.voice.md` | `repos/acme-api.voice.md` |
| Domain knowledge | `repos/{owner}-{repo}.kodo.md` | `repos/acme-api.kodo.md` |
| Skill | `.claude/skills/kodo-{capability}/SKILL.md` | `kodo-audit/SKILL.md` |
| Branch | `kodo/{domain}/{event-id}` | `kodo/dev/evt-4821` |
| Commit message | `kodo({domain}): {action} -- {detail}` | `kodo(dev): fix #42 -- null check in auth handler` |
| Commit metadata | Trailer lines: `Event-ID:`, `Confidence:`, `Model:` | `Event-ID: evt-4821` |

---

## CLI Role Assignment

### Primary Assignment

| CLI | Command | Domain(s) | Tasks | Budget |
|-----|---------|-----------|-------|--------|
| Claude | `claude -p` | DEV, MKT (selective), PM | Code review, confidence scoring, content quality review, strategic analysis, weekly reports, feature evaluation | $200/mo (Max plan) |
| Codex | `codex exec` | DEV | Code generation, bug fixes, implementation from issue specs, auto-regression tests | $20/mo (Pro plan) |
| Gemini | `gemini -p` | MKT, DEV (scan summaries) | Bulk content: changelogs, welcomes, announcements, docs refresh, good-first-issue curation, contributor spotlights, security scan summaries | Free (1K RPD) |
| Qwen | `qwen -p` | PM | Daily backlog triage, stale detection, duplicate flagging, label suggestions, routine maintenance | Free (1K RPD) |

**Budget optimization rule**: The expensive model does strategy. The free models do volume.

### Fallback Chain

| Primary Down | Substitute | Constraints |
|--------------|------------|-------------|
| Claude | Codex (for code review) | Confidence capped at 79, forces balloting |
| Claude | Gemini (emergency auditor) | Confidence capped at 69 |
| Codex | Qwen (emergency generator) | Output requires extra Layer 1 validation |
| Gemini | Qwen | No constraints — equivalent free tier |
| Qwen | Gemini | No constraints — equivalent free tier |

### Claude Outage Protocol

| Tier | Duration | Behavior |
|------|----------|----------|
| 1 | 0–30 min | Codex as emergency code reviewer. Confidence capped at 79. MKT/PM continue normally. |
| 2 | 30 min – 4 h | All Claude-requiring events queued to `deferred_queue`. Dev: deps-automerge only. MKT: Gemini continues. PM: Qwen-only triage. |
| 3 | 4+ h | **Hibernate.** All engines except scout go quiet. Scout keeps detecting and queueing. No merges, no content, no analysis. Telegram: "Kōdō hibernating." |
| Recovery | Claude returns | Detected via `claude -p "ping" --max-turns 1` with exponential backoff (1m, 2m, 4m, 8m, 16m, cap 30m). Drain `deferred_queue` chronologically. |

---

## State Machine

All state transitions are enforced by `kodo-transition.sh`. Direct database state updates are forbidden.

### Dev Domain States

```
[*] → pending → triaging → generating → hard_gates → auditing → scanning → auto_merge → releasing → resolved
                    │                        │            │           │                        │
                    ├─► auditing             ├─► deferred ├─► deferred├─► balloting            ├─► reverting
                    └─► auto_merge (deps)    │            │           │   └─► guarded_merge     │   └─► deferred
                                             │            │           │       └─► releasing     │
                                             └────────────┴───────────┴─► deferred ─► pending (retry, max 2)
                                                                                   └─► closed
```

### Dev Transition Rules

| From | To | Trigger |
|------|----|---------|
| `*` | `pending` | Scout detects PR/issue |
| `pending` | `triaging` | Brain classifies as dev |
| `triaging` | `generating` | Issue needs code fix |
| `triaging` | `auditing` | PR ready for review |
| `triaging` | `auto_merge` | Deps update + CI green (zero LLM) |
| `generating` | `hard_gates` | Codex produces diff |
| `generating` | `deferred` | Codex failed 3x |
| `hard_gates` | `auditing` | All Layer 1 gates pass |
| `hard_gates` | `deferred` | Any gate fails |
| `auditing` | `scanning` | Claude confidence >= 50 |
| `auditing` | `deferred` | Confidence < 50 |
| `scanning` | `auto_merge` | Confidence >= 90 AND scan clean |
| `scanning` | `balloting` | Confidence 50–89 |
| `scanning` | `deferred` | Vulnerability found |
| `balloting` | `guarded_merge` | 2/3 CLI consensus |
| `balloting` | `deferred` | No consensus |
| `auto_merge` | `releasing` | Merge success |
| `guarded_merge` | `releasing` | CI green within 48h window |
| `releasing` | `resolved` | Semver tag applied |
| `releasing` | `reverting` | CI regression within 48h |
| `reverting` | `deferred` | Revert merged |
| `deferred` | `pending` | New commits (max 2 retries) |
| `deferred` | `closed` | Auto-close with explanation |

### Confidence Bands

| Score | Action | Merge Path |
|-------|--------|------------|
| 90–100 | Auto-merge | Direct merge, no human/ballot needed |
| 50–89 | Ballot | 2/3 CLI consensus required |
| 0–49 | Defer | Route to deferred, flag for attention |

Bands are **adaptive**: 30-day rolling window of merge outcomes (clean, reverted, hotfixed) adjusts thresholds automatically. Bootstrap calibration runs against last 50 merged PRs during onboarding shadow mode.

### Marketing Domain States

```
[*] → pending → drafting → reviewing → published
                    │          │
                    └──────────┴─► deferred
```

- `drafting`: Gemini generates content (welcome, changelog, announcement)
- `reviewing`: Claude quality check (high-stakes content only — releases, spotlights)
- `published`: Content posted to GitHub

### PM Domain States

```
[*] → pending → analyzing → reported
                    │
                    └─► deferred
```

- `analyzing`: Claude (strategy) or Qwen (triage) processes the event
- `reported`: Analysis posted as GitHub issue/comment or sent via Telegram

---

## Database Schema

Database file: `kodo.db` (SQLite 3). Runtime artifact — .gitignored.

| Table | Purpose | Key Columns |
|-------|---------|-------------|
| `pipeline_state` | Current state of every tracked event | `event_id`, `repo`, `domain`, `state`, `updated_at`, `retry_count` |
| `pending_events` | Queue of unprocessed events from scout | `event_id`, `repo`, `event_type`, `payload_json`, `detected_at` |
| `community_log` | Dedup tracker for marketing actions | `repo`, `author`, `action` (welcomed, announced, etc.), `created_at` |
| `pm_artifacts` | PM analysis outputs (weekly reports, triage) | `repo`, `type` (weekly, triage, evaluation), `data_json`, `created_at` |
| `budget_ledger` | Every CLI invocation with cost | `model`, `repo`, `domain`, `tokens_in`, `tokens_out`, `cost_usd`, `invoked_at` |
| `repo_metrics` | Rolling performance metrics per repo | `repo`, `merge_count`, `avg_confidence`, `avg_time_to_merge`, `incident_rate_30d` |
| `merge_outcomes` | Post-merge tracking for calibration | `event_id`, `repo`, `confidence`, `outcome` (clean, reverted, hotfixed), `merged_at` |
| `deferred_queue` | Events queued during Claude outage | `event_id`, `repo`, `domain`, `queued_at`, `reason` |
| `confidence_bands` | Adaptive threshold configuration | `band`, `threshold`, `incident_rate_30d`, `updated_at` |

### Query Conventions

- ALWAYS filter by `repo` — never query across all repos without explicit intent
- Use `datetime('now')` for timestamps, never application-level time
- Dedup check before marketing actions: `SELECT 1 FROM community_log WHERE repo=? AND author=? AND action=?`
- Budget check: `SELECT SUM(cost_usd) FROM budget_ledger WHERE model=? AND invoked_at > date('now', 'start of month')`

---

## Repo Configuration

### Required TOML Fields

```toml
[repo]
owner = "acme"                         # GitHub/GitLab owner or org
name = "api"                           # Repository name
provider = "github"                    # github | gitlab | gitea | bitbucket
mode = "shadow"                        # shadow | live
branch_default = "main"                # Default branch name

[dev]
enabled = true                         # Enable dev engine
test_command = "npm test"              # Command to run tests
lint_command = "npm run lint"          # Command to run linter
max_diff_lines = 500                   # Hard gate: max diff size
auto_merge_deps = true                 # Auto-merge dependency updates if CI green
semver_release = true                  # Auto-tag semver releases after merge

[mkt]
enabled = true                         # Enable marketing engine
welcome_new_contributors = true        # Auto-welcome first-time contributors
generate_changelogs = true             # Auto-generate release changelogs
good_first_issues = true               # Curate good-first-issue labels weekly
contributor_spotlights = true          # Monthly contributor recognition

[pm]
enabled = true                         # Enable PM engine
weekly_report = true                   # Generate weekly velocity/roadmap report
daily_triage = true                    # Daily backlog grooming via Qwen
feature_evaluation = true              # Evaluate new feature requests
telegram_digest = true                 # Send weekly digest to Telegram
```

### Optional Fields

```toml
[provider]
api_base = "https://gitlab.company.com"  # Self-hosted instance URL

[voice]
tone = "technical but approachable"
vocabulary = ["contributors", "community", "ship"]
anti_patterns = ["leverage", "synergy", "excited to announce"]
personality = "a senior engineer who writes clearly and hates fluff"

[signals]
competitor_repos = ["competitor/project"]
npm_package = "my-package"
stackoverflow_tag = "my-framework"
rss_feeds = ["https://blog.example.com/feed.xml"]
```

---

## Repo Onboarding Lifecycle

Onboarding is fully automated. Zero human review required.

| Phase | Entry | Actions | Exit |
|-------|-------|---------|------|
| **Discovering** | `kodo add owner/repo` | Claude reads README, package.json, CI config, branch protection, labels, milestones, contributor patterns, release history. Generates draft `repos/{owner}-{repo}.toml` | Draft TOML created |
| **Validating** | Draft TOML exists | Automated checks: CI system detected? Test command resolved? Branch protection parsed? Required secrets available? `gh auth` verified? | All checks pass |
| **Shadow** | Validation passes | Runs ALL three engines. Logs what it WOULD do. Does NOT merge/close/comment. Measures accuracy. Default: 24h for active repos, 7 days for quiet repos | Accuracy meets thresholds |
| **Live** | Shadow accuracy OK | Fully autonomous. All engines take write actions | Ongoing |

Shadow → Live promotion is automatic. If shadow accuracy falls below threshold, the repo stays in shadow with a Telegram alert.

---

## Quality Gates

Applied in sequence. Each layer must pass before proceeding to the next.

### Layer 1 — Hard Gates (deterministic, no LLM)

All MUST pass. Any failure → `deferred`.

- [ ] Test suite passes (`test_command` from TOML)
- [ ] Semgrep clean (no security findings)
- [ ] `npm audit` / equivalent clean (no critical/high vulns)
- [ ] Diff size <= `max_diff_lines` from TOML
- [ ] Changed files limited to related scope (no unrelated modifications)

### Layer 1.5 — Auto-Generated Regression Tests

Codex generates 3–5 targeted test cases for changed code paths:
```
codex exec "Write 3-5 test cases that exercise the behavioral changes in this diff. Focus on edge cases and boundary conditions the existing tests don't cover."
```

If generated tests reveal unexpected behavior changes → lower confidence by 20 points, route to balloting.

### Layer 2 — LLM Review (advisory)

Claude reviews with structured output via `schemas/confidence.schema.json`:
- Confidence score (0–100)
- Risk assessment
- Behavioral diff assertions ("function X now returns null instead of throwing")
- Each assertion checked against existing test coverage

### Layer 3 — Balloting (medium-confidence)

For scores 50–89: invoke 2–3 CLIs independently. 2/3 consensus required for `guarded_merge`. No consensus → `deferred`.

### Post-Merge — 48h Rollback Window

Monitor CI for 48 hours after merge. Regression detected → auto-revert + move to `deferred`.

---

## Git Workflow

### Branch Naming

```
kodo/{domain}/{event-id}
```

Examples: `kodo/dev/evt-4821`, `kodo/mkt/evt-5033`, `kodo/pm/evt-5100`

### Commit Message Format

```
kodo({domain}): {action} -- {detail}

Event-ID: evt-{id}
Confidence: {score}
Model: {cli-name}
```

Example:
```
kodo(dev): fix #42 -- add null check in auth handler

Event-ID: evt-4821
Confidence: 92
Model: codex
```

### PR Conventions

- Title: `[kodo-{domain}] {action}: {brief description}`
- Body: structured sections — Summary, Changes, Test Results, Confidence, Risk Assessment
- Labels: `kodo-dev`, `kodo-mkt`, `kodo-pm`, `kodo-auto-merge`, `kodo-ballot`

### Provider Abstraction

ALL git provider operations MUST use `kodo-git.sh`:

```bash
kodo-git.sh pr-list <repo>
kodo-git.sh pr-comment <repo> <pr-number> <body>
kodo-git.sh pr-merge <repo> <pr-number>
kodo-git.sh issue-list <repo>
kodo-git.sh issue-comment <repo> <issue-number> <body>
kodo-git.sh issue-close <repo> <issue-number>
kodo-git.sh issue-label <repo> <issue-number> <label>
kodo-git.sh release-get <repo> <tag>
kodo-git.sh release-edit <repo> <tag> <notes>
kodo-git.sh user-info <repo> <username>
kodo-git.sh discussion-create <repo> <category> <title> <body>
```

The adapter reads `provider` from repo TOML and routes to: `gh` (GitHub), `glab` (GitLab), `curl+jq` (Gitea/Bitbucket).

---

## Crontab

Exactly 4 entries. Do NOT add more.

```crontab
*/2 * * * * ~/.kodo/bin/kodo-scout.sh        # Detect events across all repos
*   * * * * ~/.kodo/bin/kodo-brain.sh        # Process event queue (flock protected)
0  10 * * * ~/.kodo/bin/kodo-pm.sh --daily-triage  # PM daily grooming
0   9 * * 1 ~/.kodo/bin/kodo-weekly.sh       # PM weekly + self-health
```

Scout runs every 2 minutes. Brain runs every minute but is flock-protected (single instance). PM triage is daily at 10:00. Weekly report is Monday at 09:00.

---

## JSON Schema Contracts

ALL LLM outputs MUST use `--json-schema`. Free-text LLM output parsing is forbidden.

| Schema File | Consuming Engine | Purpose |
|-------------|-----------------|---------|
| `schemas/confidence.schema.json` | DEV | Structured code review: score, risks, behavioral assertions |
| `schemas/triage.schema.json` | PM | Structured issue triage: priority, labels, duplicates, stale flags |
| `schemas/discovery.schema.json` | Onboarding | Structured repo discovery: conventions, CI, branch rules, language |
| `schemas/pm-report.schema.json` | PM | Structured weekly report: velocity, priorities, roadmap, debt |

Usage pattern:
```bash
claude -p "Review this PR..." --json-schema schemas/confidence.schema.json --max-turns 3
codex exec "Write tests for..." --json-schema schemas/confidence.schema.json
gemini -p "Generate changelog..." --json-schema schemas/discovery.schema.json
qwen -p "Triage these issues..." --json-schema schemas/triage.schema.json
```

---

## Testing & Verification

### Before Committing

- [ ] `shellcheck` passes on all `.sh` files
- [ ] SQL queries tested against `kodo.db` schema
- [ ] State transitions verified: every `from → to` pair exists in transition rules
- [ ] JSON schemas validate with `jq --schema` or equivalent
- [ ] `set -euo pipefail` present in every script

### Before Merging

- [ ] Shadow mode cycle completed for affected engine(s)
- [ ] Budget projection checked: new code won't exceed monthly limits
- [ ] State machine violation check: no orphan states, no unreachable transitions
- [ ] Dedup logic verified: community_log prevents duplicate actions

### Integration Verification

| Component | Verify By |
|-----------|-----------|
| Scout | Run manually, confirm events inserted into `pending_events` |
| Brain | Run manually, confirm events classified correctly and routed |
| Dev Engine | Process a test PR through full pipeline in shadow mode |
| MKT Engine | Process a test release event, verify draft content logged |
| PM Engine | Run `--daily-triage`, verify triage output matches schema |
| State Machine | Attempt invalid transition, confirm rejection |
| Git Adapter | Test each provider command against a test repo |
| Budget Gate | Simulate budget limit, confirm CLI calls blocked |

---

## Dependencies

### Required System Tools

| Tool | Purpose | Install |
|------|---------|---------|
| `bash` (5+) | Script runtime | System package |
| `sqlite3` | Database | `apt install sqlite3` |
| `jq` | JSON processing | `apt install jq` |
| `flock` | Brain single-instance lock | `apt install util-linux` |
| `curl` | HTTP requests (Gitea/Bitbucket API, Telegram) | System package |
| `git` | Version control | System package |
| `shellcheck` | Bash linting | `apt install shellcheck` |
| `semgrep` | Security static analysis | `pip install semgrep` |

### Required CLI Tools (authenticated)

| CLI | Auth | Purpose |
|-----|------|---------|
| `claude` | Anthropic Max plan | Strategy, review, PM analysis |
| `codex` | OpenAI Pro plan | Code generation, implementation |
| `gemini` | Google account (free) | Bulk content, security summaries |
| `qwen` | Alibaba account (free) | Triage, gardening, maintenance |

### Git Provider CLIs

| Provider | CLI | Auth |
|----------|-----|------|
| GitHub | `gh` | `gh auth login` |
| GitLab | `glab` | `glab auth login` |
| Gitea/Forgejo | `curl + jq` | API token in repo TOML |
| Bitbucket | `curl + jq` | App password in repo TOML |

### Optional

| Tool | Purpose |
|------|---------|
| Telegram Bot API | Weekly digests, status alerts, hibernate notifications |
| `npm` / `pip` | Project-specific test/lint runners |

---

## Agent Contribution Protocol

### Before Making Any Change

1. Read this CLAUDE.md fully
2. Check `pipeline_state` for the target repo — is another engine processing?
3. Verify `repo_mode` — shadow repos get log-only actions
4. Check `budget_ledger` — is the monthly budget for this model exceeded?
5. Identify which domain (dev, mkt, pm) owns the change
6. Confirm the target files are within scope for the domain

### Code Style Rules

All bash scripts MUST follow:

```bash
#!/usr/bin/env bash
set -euo pipefail

# One-line purpose comment

readonly KODO_HOME="${KODO_HOME:-$HOME/.kodo}"
readonly DB="$KODO_HOME/kodo.db"
```

- Quote ALL variables: `"$var"`, never `$var`
- Use `local` for function variables
- Use `readonly` for constants
- Comments explain WHY, never WHAT
- Functions named `kodo_{verb}_{noun}`: `kodo_check_budget`, `kodo_route_event`
- Exit codes: 0 = success, 1 = expected failure, 2 = unexpected error

### PR Checklist (for agents submitting changes to this repo)

- [ ] Change is scoped to a single domain engine or shared component
- [ ] `shellcheck` passes
- [ ] No hardcoded repo names, owners, or provider-specific commands
- [ ] State transitions documented if modified
- [ ] Schema updated if structured output format changed
- [ ] Budget impact assessed in PR description
- [ ] Shadow mode behavior verified (no write actions leak through)
