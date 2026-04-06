# kodo-roadmap — Weekly PM Analysis Skill

Generate a comprehensive weekly project management report.

## Input

- Open issues with labels, dates, comment counts
- Milestones with progress
- Merged PRs from last 7 days
- Repo metrics (merge_count, avg_confidence, avg_time_to_merge)
- Domain knowledge (from repos/{name}.kodo.md)
- External signals (competitor repos, npm downloads, if configured)

## Process

1. Calculate velocity metrics (PRs merged, issues closed/opened, trend)
2. Assess milestone progress and flag at-risk milestones
3. Prioritize open issues (P0-P3 with reasoning)
4. Identify technical debt candidates
5. Include competitive landscape if signals configured
6. Generate actionable recommendations

## Output

Structured JSON via `schemas/pm-report.schema.json`.

## Guidelines

- Velocity trend should compare to previous 4-week average, not just last week
- "At risk" means milestone is >70% of time elapsed but <50% of issues closed
- Technical debt candidates: issues older than 90 days with bug/debt labels
- Recommendations should be specific and actionable, not generic advice
