<p align="center">
  <strong>KŌDŌ</strong><br>
  <sub>鼓動 — heartbeat</sub>
</p>

<p align="center">
  <em>Your repos have a pulse now.</em>
</p>

---

Bash scripts and cron jobs that wire up headless AI CLIs to autonomously maintain git repositories. Reviews PRs, generates fixes, welcomes contributors, triages issues, writes changelogs, tracks velocity — all while you're not looking.

No framework. No containers. No YAML pipelines. No "infrastructure."
Eleven shell scripts, four cron entries, one SQLite file.

```
git clone <this> ~/.kodo && crontab ~/.kodo/crontab.txt && ~/.kodo/bin/kodo-add.sh you/repo
```

That's the whole deploy.

---

### The idea

You have repos. Things happen in them — PRs open, issues pile up, releases ship, contributors show up. Right now, you handle all of that. Or you don't, and it rots.

KŌDŌ handles it. Three engines run in parallel:

**Dev** — Reviews every PR with structured confidence scoring. Score ≥90: auto-merge. Score 50-89: three AI models vote in parallel, 2/3 consensus required. Score <50: deferred, you deal with it. Hard gates (tests, semgrep, diff size) run *before* any AI touches it. CI status verified before every merge. 48h post-merge rollback window. Dependency updates from Dependabot/Renovate take a zero-LLM fast path — detected, merged, released in under a second.

**Marketing** — Welcomes first-time contributors within minutes. Generates changelogs from commit history. Curates good-first-issues. Runs contributor spotlights. All with the repo's own voice, not generic AI slop.

**PM** — Daily backlog triage. Weekly velocity reports. Feature request evaluation. Stale issue cleanup. Roadmap tracking against milestones. Competitive landscape if you feed it signals.

Classification is bash `case` statements. No LLM decides what goes where.

---

### The economics

| Model | What it does | What it costs |
|-------|-------------|---------------|
| Claude | Reviews code, scores confidence, writes PM reports | $200/mo |
| Codex | Generates fixes, writes regression tests | $20/mo |
| Gemini | Writes all the content (changelogs, welcomes, docs) | $0 |
| Qwen | Triages every issue, grooms the backlog daily | $0 |

The expensive model thinks. The free models work. Total: **$220/mo** for 3-5 active repos.

Budget enforcement is baked into the LLM abstraction layer. Every CLI call checks monthly spend before invoking. Telegram alert at 80%. Hard block at 100%. Free-tier CLIs bypass the check. Surprise bills are structurally impossible.

When Claude goes down, the system doesn't make bad decisions. It queues events, degrades gracefully for 30 minutes, then hibernates. No merge happens without the confidence it deserves.

---

### The safety model

Every merge goes through this gauntlet:

```
hard gates (tests, semgrep, diff ≤ 500 lines, scope check)
    ↓ all pass
auto-generated regression tests (Codex writes tests for the diff)
    ↓ no surprises
confidence review (Claude scores 0-100, structured JSON)
    ↓ score ≥ 90
CI status check (gh pr checks — green required)
    ↓ CI green
auto-merge → 48h rollback window → resolved

    ↓ score 50-89
ballot (Claude + Gemini + Qwen vote in parallel, 2/3 required)

    ↓ CI pending
engine yields, Brain re-dispatches when CI completes

    ��� score < 50 or CI red or any gate fails
deferred (retry twice, then close with explanation)
```

Shadow mode runs the entire pipeline but takes zero write actions. Flip one TOML value when you trust it.

Concurrent processing is PID-locked — two Brain cycles can't dispatch the same event to the same engine. Stale PIDs from crashed processes are detected and reclaimed automatically.

All state transitions go through one file (`kodo-transition.sh`). Invalid transitions are rejected. The state machine has 30+ transitions across three domains and every single one is explicitly enumerated.

---

### What's in the box

```
~/.kodo/
├── bin/                      11 scripts, ~3200 lines
├── context/runtime-rules.md  shared rules injected into every LLM prompt
├── schemas/                  5 JSON schemas — all LLM output is structured
├── repos/                    per-repo TOML configs (auto-generated on onboard)
├── crontab.txt               4 lines. the whole schedule
└── kodo.db                   SQLite. 9 tables. the brain's memory
```

GitHub day-one. GitLab day-one. Gitea/Bitbucket: adapter ready, endpoints stubbed.

---

### Requirements

`bash 5+` · `sqlite3` · `jq` · `flock` · `git` · `curl`

Plus the AI CLIs you want: `claude` · `codex` · `gemini` · `qwen`
Plus your git provider CLI: `gh` or `glab`

---

### Status

Working implementation. Full-cycle tested against `yoda-digital/iris-gateway` — Scout through resolved, all three engines, all state paths. Shadow mode verified. Dependabot auto-merge path: pending to resolved in under 1 second.

The confidence bands self-calibrate over time. Start conservative. Let the data tell you when to trust it.

---

<sub>KŌDŌ — because your repos shouldn't need you to breathe.</sub>
