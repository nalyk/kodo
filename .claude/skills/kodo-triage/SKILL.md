# kodo-triage — Issue Classification Skill

Classify and triage open issues for backlog grooming.

## Input

- List of open issues with titles, labels, creation dates, comment counts
- Repo context (existing labels, milestones)

## Process

1. Assign priority P0-P3 based on title, labels, and activity
2. Suggest labels from the repo's existing label set
3. Detect duplicates (>80% confidence required)
4. Flag stale issues (>30 days, no activity, no assignee)
5. Suggest stale action: close (with explanation) or ping

## Output

Structured JSON via `schemas/triage.schema.json`.

## Guidelines

- P0: security vulnerabilities, data loss, complete feature broken
- P1: significant bugs, important features blocking users
- P2: improvements, non-critical bugs, nice-to-have features
- P3: cosmetic, low-impact, someday/maybe
- Never suggest closing issues with recent discussion
- Never suggest labels that don't exist in the repo
