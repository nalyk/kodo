# kodo-discover — Repo Auto-Discovery Skill

Analyze a repository to auto-generate configuration for KODO.

## Input

- Repository URL or owner/repo slug
- Raw API data (README, package.json, CI config, labels, milestones)

## Process

1. Detect primary language and framework
2. Identify CI system (GitHub Actions, GitLab CI, CircleCI, etc.)
3. Resolve test command from package.json / Makefile / CI config
4. Resolve lint command
5. Check branch protection settings
6. Catalog existing labels and milestones
7. Analyze commit style conventions
8. Count contributors and activity level

## Output

Structured JSON via `schemas/discovery.schema.json`.

## Guidelines

- Prefer detecting test_command from CI config over package.json (CI is what actually runs)
- If no tests detected, set test_command to "echo no-tests"
- Always detect branch_default from API, don't assume "main"
- Report conventions honestly — don't invent patterns that aren't there
