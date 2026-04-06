# KŌDŌ — Development Guide

> This file is for **agents developing KODO itself** — writing, modifying, and testing
> the bash scripts, schemas, skills, and context files that make up KODO.
>
> This is a LOCAL file (not committed to git). It lives only in the `kodo-dev` workspace.
> The committed `CLAUDE.md` in the repo root is the RUNTIME context for `claude -p`.

---

## Repository Layout

This is the development workspace for KODO. The code here is the same git repo
as the runtime deployment. Changes committed here get deployed to `~/.kodo/`.

**Two CLAUDE.md files, two purposes:**
- `CLAUDE.md` (committed, repo root) → Runtime constitution for `claude -p` operating autonomously
- `.claude/CLAUDE.md` (this file, local) → Development guide for agents building KODO

**Shared runtime rules**: `context/runtime-rules.md` — single source of truth for operational
rules. Injected into ALL LLM prompts via `kodo_prompt()`. If you change safety constraints,
confidence bands, or operational rules — change them there, not in individual CLI files.

**CLI context files** (committed, auto-discovered by each CLI at runtime):
- `AGENTS.md` → Codex role-specific rules
- `.gemini/GEMINI.md` → Gemini role-specific rules
- `.qwen/QWEN.md` → Qwen role-specific rules

These reference `context/runtime-rules.md` but don't duplicate it.

---

## Code Style Rules

All bash scripts MUST follow:

```bash
#!/usr/bin/env bash
set -euo pipefail

# One-line purpose comment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/kodo-lib.sh"
```

- Quote ALL variables: `"$var"`, never `$var`
- Use `local` for function variables
- Use `readonly` for constants
- Comments explain WHY, never WHAT
- Functions named `kodo_{verb}_{noun}`: `kodo_check_budget`, `kodo_route_event`
- Exit codes: 0 = success, 1 = expected failure, 2 = unexpected error
- ALWAYS use `set -euo pipefail` in every script

---

## Development Safety Constraints

### NEVER

1. NEVER call `gh`/`glab` directly in engine scripts — use `kodo-git.sh`
2. NEVER update `pipeline_state.state` directly — use `kodo-transition.sh` (metadata updates via `kodo_pipeline_set` are OK)
3. NEVER create cron entries beyond the 4 in `crontab.txt`
4. NEVER parse free-text LLM output — use `--json-schema`
5. NEVER hardcode repo names, owners, or provider-specific commands
6. NEVER skip shadow mode checks in write operations
7. NEVER duplicate runtime rules — change `context/runtime-rules.md` instead

### ALWAYS

1. ALWAYS source `kodo-lib.sh` and use its functions (don't reinvent)
2. ALWAYS use `kodo_invoke_llm()` for LLM calls (handles budget, schema, JSON extraction)
3. ALWAYS use `kodo_prompt()` when building prompt text (injects runtime context)
4. ALWAYS route git operations through `kodo-git.sh`
5. ALWAYS validate with `bash -n` and `shellcheck` before committing

---

## Architecture Quick Reference

```
cron (4 entries)
  ├─ */2 * * * * → kodo-scout.sh → kodo.db (pending_events)
  ├─ * * * * *   → kodo-brain.sh → classify → dev|mkt|pm engine
  ├─ 0 10 * * *  → kodo-pm.sh --daily-triage
  └─ 0 9 * * 1   → kodo-weekly.sh
```

### Components

| Script | Lines | Role |
|--------|-------|------|
| `bin/kodo-lib.sh` | ~350 | Shared functions: LLM abstraction, budget, metadata, JSON extraction, concurrency |
| `bin/kodo-git.sh` | ~270 | Git provider abstraction + CI status checks |
| `bin/kodo-transition.sh` | ~170 | State machine enforcement |
| `bin/kodo-scout.sh` | ~160 | Event detection |
| `bin/kodo-brain.sh` | ~230 | Event classification + routing + stalled event advancement |
| `bin/kodo-dev.sh` | ~640 | Dev ops engine: triaging, auditing, CI-aware merge, parallel ballot |
| `bin/kodo-mkt.sh` | ~280 | Marketing engine |
| `bin/kodo-pm.sh` | ~290 | PM engine |
| `bin/kodo-add.sh` | ~210 | Repo onboarding |
| `bin/kodo-weekly.sh` | ~230 | Self-health + weekly cycle |
| `bin/kodo-status.sh` | ~170 | Terminal dashboard |

### Key Design Decisions

1. **kodo-lib.sh** is sourced (not executed) — shared by all scripts
2. **kodo-git.sh** centralizes shadow mode enforcement + CI status checks for write operations
3. **kodo-brain.sh** uses flock for single-instance + Phase 2 stalled event advancement
4. **kodo-dev.sh** is state-driven: **loops through all states** in one invocation until terminal/deferred
5. **kodo_invoke_llm()** is the single entry point for all LLM calls (budget gate, schema, JSON extraction)
6. **kodo_claim_event/kodo_release_event** prevents concurrent processing of the same event
7. **kodo_pipeline_set/get** enables inter-state data flow (confidence, model, ballot, CI state)

---

## Testing & Verification

### Before Committing

```bash
# Syntax check all scripts
for f in bin/*.sh .claude/hooks/*.sh; do bash -n "$f"; done

# Schema validation
sqlite3 :memory: < sql/schema.sql
for f in schemas/*.json; do jq empty "$f"; done

# State machine test
KODO_HOME=. KODO_DB=/tmp/test.db sqlite3 /tmp/test.db < sql/schema.sql
KODO_HOME=. KODO_DB=/tmp/test.db KODO_TRANSITION_REPO=test \
  bash bin/kodo-transition.sh evt-test '*' pending dev
KODO_HOME=. KODO_DB=/tmp/test.db \
  bash bin/kodo-transition.sh evt-test pending triaging dev
# Invalid transition must fail:
KODO_HOME=. KODO_DB=/tmp/test.db \
  bash bin/kodo-transition.sh evt-test triaging resolved dev || echo "Correctly blocked"
rm /tmp/test.db
```

### Before Merging

- [ ] Shadow mode cycle completed for affected engine(s)
- [ ] Budget projection checked
- [ ] No orphan states or unreachable transitions
- [ ] Runtime rules updated in `context/runtime-rules.md` (not duplicated)
- [ ] CLI context files reference shared rules (not duplicate them)

---

## PR Checklist

- [ ] Scoped to single domain engine or shared component
- [ ] `bash -n` passes on all modified scripts
- [ ] No hardcoded repos/owners/providers
- [ ] State transitions documented if modified
- [ ] Schema updated if output format changed
- [ ] Uses `kodo_prompt()` for LLM invocations
- [ ] Shadow mode behavior verified
- [ ] Runtime rules in `context/runtime-rules.md` (single source of truth)

---

## Deployment

```bash
# From kodo-dev, push changes:
git push origin main

# On target machine:
git clone <repo> ~/.kodo
crontab ~/.kodo/crontab.txt
~/.kodo/bin/kodo-add.sh owner/repo
```

The deployed `~/.kodo/CLAUDE.md` is the runtime constitution.
The deployed `~/.kodo/context/runtime-rules.md` is injected into every LLM prompt.
This file (`.claude/CLAUDE.md`) does NOT deploy — it's local to `kodo-dev` only.
