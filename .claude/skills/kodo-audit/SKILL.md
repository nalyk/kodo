# kodo-audit — Code Review Skill

Review a pull request or code change with structured confidence scoring.

## Input

- PR diff (from `kodo-git.sh pr-diff`)
- Repo context (language, test coverage, CI status)

## Process

1. Analyze the diff for correctness, security, and style
2. Identify behavioral changes ("function X now returns Y instead of Z")
3. Check each behavioral assertion against test coverage
4. Score confidence 0-100
5. List risks by severity

## Output

Structured JSON via `schemas/confidence.schema.json`:
- `score`: 0-100 confidence for merge safety
- `recommendation`: auto_merge | ballot | defer
- `risks[]`: severity + description + file + line
- `behavioral_assertions[]`: assertion + covered_by_tests
- `summary`: brief review finding

## Guidelines

- Score >= 90 only if: all tests pass, no security risks, small diff, clear intent
- Score 50-89: concern exists but manageable with consensus
- Score < 50: real danger signals — defer immediately
- Never inflate scores. A wrong auto-merge is worse than a false defer.
