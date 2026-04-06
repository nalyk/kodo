# KŌDŌ

Autonomous repo ops. Bash scripts + cron + headless AI CLIs maintaining your git repositories while you sleep.

KŌDŌ (鼓動) means "heartbeat" in Japanese.

## What it does

Four cron jobs detect events across your repos, classify them, and route to three domain engines:

- **Dev** — PR review, code generation, confidence scoring, merge/revert, semver releases
- **Marketing** — contributor welcomes, changelogs, announcements, good-first-issue curation
- **PM** — backlog triage, velocity reports, roadmap tracking, feature evaluation

No framework. No build step. No runtime dependencies beyond bash, sqlite3, jq, and the AI CLIs.

## How it works

```
*/2 * * * *  kodo-scout.sh     # detect events across all repos
*   * * * *  kodo-brain.sh     # classify + route (flock protected)
0  10 * * *  kodo-pm.sh        # daily backlog triage
0   9 * * 1  kodo-weekly.sh    # weekly health + PM report
```

Scout polls. Brain classifies (bash logic, no LLM). Engines process. State machine enforces transitions. Everything logs to SQLite.

```
GitHub event → scout → brain → engine → [hard gates → LLM review → merge/defer]
                                              ↓
                                         kodo-transition.sh (state machine)
                                              ↓
                                          kodo.db
```

## The four CLIs

| CLI | Role | Cost |
|-----|------|------|
| `claude -p` | Strategy, code review, PM analysis | $200/mo |
| `codex exec` | Code generation, bug fixes | $20/mo |
| `gemini -p` | Bulk content, changelogs, welcomes | Free |
| `qwen -p` | Issue triage, stale detection, labels | Free |

The expensive model does strategy. The free models do volume.

## Install

```bash
git clone <this-repo> ~/.kodo
crontab ~/.kodo/crontab.txt
~/.kodo/bin/kodo-add.sh owner/repo
```

That's it. `kodo-add` auto-discovers your repo (language, CI, tests, branch protection) and starts in shadow mode. Shadow mode runs everything but takes no write actions. When accuracy looks good, flip `mode = "live"` in the TOML.

## Confidence-gated merging

Every PR gets a confidence score 0-100:

- **90+** → auto-merge (no human needed)
- **50-89** → ballot (2/3 CLI consensus required)
- **0-49** → defer (flag for attention)

Bands are adaptive. 30-day rolling window of merge outcomes adjusts thresholds automatically. If your auto-merges start getting reverted, the threshold tightens on its own.

After every merge: 48h rollback window. CI regression → auto-revert.

## Safety

- All state transitions enforced by one script (`kodo-transition.sh`)
- All git operations go through one adapter (`kodo-git.sh`) — shadow mode enforced there
- All LLM output is structured JSON via `--json-schema` — no free-text parsing
- Hard gates (tests, semgrep, diff size, scope) must pass before any LLM even looks at the code
- Budget tracked per-model per-month in SQLite

When Claude goes down: Codex reviews (capped confidence) → queue events → hibernate after 4h. Recovery drains the queue chronologically.

## Files

```
~/.kodo/
├── bin/                    # 11 bash scripts (~2500 lines total)
│   ├── kodo-lib.sh         # shared functions
│   ├── kodo-scout.sh       # event detection
│   ├── kodo-brain.sh       # classification + routing
│   ├── kodo-dev.sh         # dev ops engine
│   ├── kodo-mkt.sh         # marketing engine
│   ├── kodo-pm.sh          # PM engine
│   ├── kodo-transition.sh  # state machine
│   ├── kodo-git.sh         # git provider abstraction
│   ├── kodo-add.sh         # repo onboarding
│   ├── kodo-weekly.sh      # weekly health + reports
│   └── kodo-status.sh      # terminal dashboard
├── context/
│   └── runtime-rules.md    # shared rules injected into all LLM prompts
├── schemas/                # JSON schemas for structured LLM output
├── repos/                  # per-repo TOML configs (auto-generated)
├── crontab.txt             # 4 entries, the entire schedule
└── kodo.db                 # SQLite (runtime, gitignored)
```

GitHub and GitLab supported. Gitea/Bitbucket stubbed (API adapter ready, needs implementation).

## Status

```bash
~/.kodo/bin/kodo-status.sh
```

Shows repos, pipeline state, budget usage, CLI availability, recent deferrals. Read-only.

## Requirements

bash 5+, sqlite3, jq, flock, git, curl. Plus whichever AI CLIs you want to use (claude, codex, gemini, qwen). `gh` for GitHub repos, `glab` for GitLab.

## License

Do what you want with it.
