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

**Dev** — Reviews every PR with structured confidence scoring. Score ≥90: auto-merge. Score 50-89: three AI models vote in parallel, 2/3 consensus required. Score <50: deferred, you deal with it. Hard gates (tests, lint, semgrep, diff size) run *before* any AI touches it. Bot feedback loop: waits for reviews from Gemini Code Assist / CodeRabbit, auto-applies code suggestions, adjusts confidence. Auto-rebase when branch falls behind base. CI status verified before every merge. 48h post-merge monitoring window — polls main-branch CI for the merge commit on a 15-minute cadence, CI failure triggers automatic revert PR, failed reverts page the operator via Telegram. Dependency updates from Dependabot/Renovate take a zero-LLM fast path through hard gates — detected, tested, merged in seconds.

**Marketing** — Welcomes first-time contributors within minutes. Generates changelogs from commit history. Curates good-first-issues. Runs contributor spotlights. All with the repo's own voice, not generic AI slop.

**PM** — Daily backlog triage. Weekly velocity reports. Feature request evaluation. Stale issue cleanup. Roadmap tracking against milestones. Competitive landscape if you feed it signals.

Classification is bash `case` statements. No LLM decides what goes where.

---

### The economics

| Model | What it does | What it costs |
|-------|-------------|---------------|
| Claude | Analyzes codebase, creates implementation plans, reviews code, scores confidence, PM reports | $200/mo |
| Codex | Executes implementation plans (primary code builder) | $20/mo |
| Qwen | Executes plans (fallback builder), triages issues, classifies PR feedback | $0 |
| Gemini | Executes plans (fallback builder), writes content (changelogs, welcomes) | $0 |

The expensive model thinks. The free models work. Total: **$220/mo** for 3-5 active repos.

Budget enforcement is baked into the LLM abstraction layer. Every CLI call checks monthly spend before invoking. Telegram alert at 80%. Hard block at 100%. Free-tier CLIs bypass the check. Surprise bills are structurally impossible.

When Claude goes down, the system doesn't make bad decisions. It queues events, degrades gracefully for 30 minutes, then hibernates. No merge happens without the confidence it deserves.

---

### The safety model

Every merge goes through this gauntlet:

```
hard gates (tests, lint, semgrep, diff ≤ 500 lines)
    ↓ all pass
bot feedback (wait for Gemini Code Assist / CodeRabbit reviews)
    ↓ suggestions? → auto-apply → re-run hard gates
    ↓ blocking concerns? → defer
    ↓ clean or window expired
confidence review (Claude scores 0-100, structured JSON, with feedback delta)
    ↓ score ≥ 90
mergeability check → BEHIND? → server-side rebase → re-verify
    ↓ clean
CI status check (green required)
    ↓ CI green
auto-merge → 48h post-merge monitoring → resolved
    ↓ CI red on main within monitoring window
    automatic revert PR → Telegram alert → operator review
    ↓ revert fails
    deferred → Telegram HIGH alert → manual intervention

    ↓ score 50-89
ballot (Claude + Gemini + Qwen vote in parallel, 2/3 required)

    ↓ CI pending
engine yields, Brain re-dispatches when CI completes

    ��� score < 50 or CI red or any gate fails
deferred (retry twice, then close with explanation)
```

Shadow mode runs the entire pipeline but takes zero write actions. Flip one TOML value when you trust it.

Concurrent processing is PID-locked — two Brain cycles can't dispatch the same event to the same engine. Stale PIDs from crashed processes are detected and reclaimed automatically.

All state transitions go through one file (`kodo-transition.sh`). Invalid transitions are rejected. The state machine has 40+ transitions across three domains and every single one is explicitly enumerated.

---

### What's in the box

```
~/.kodo/
├── bin/                      11 scripts, ~4500 lines
├── context/runtime-rules.md  shared rules injected into every LLM prompt
├── schemas/                  6 JSON schemas — all LLM output is structured
├── repos/                    per-repo TOML configs (auto-generated on onboard)
├── crontab.txt               4 lines. the whole schedule
└── kodo.db                   SQLite. 10 tables. the brain's memory
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

Confidence bands self-calibrate weekly. After ≥20 merges per band, KŌDŌ compares observed incident rates against targets (≤2% for auto-merge, ≤10% for ballot) and adjusts thresholds within bounded ranges ([85,95] and [40,60]). Threshold changes alert the operator via Telegram. Start conservative. Let the data tell you when to trust it.

---

<sub>KŌDŌ — because your repos shouldn't need you to breathe.</sub>
