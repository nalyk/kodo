# kodo-changelog — Release Notes Generation Skill

Generate structured, voice-consistent release notes from commit history.

## Input

- Release tag and previous tag
- Commit list between tags (from `kodo-git.sh compare`)
- Voice profile (from repos/{name}.voice.md or TOML [voice] section)

## Process

1. Group commits by type: Features, Bug Fixes, Internal/Maintenance
2. Extract user-facing changes (skip CI, docs-only, internal refactors for highlights)
3. Credit contributors by @username
4. Apply voice profile for tone and vocabulary
5. Format as markdown

## Output

Markdown release notes, structured as:
- Brief summary (1-2 sentences)
- Features section
- Bug Fixes section
- Internal section (collapsed or brief)
- Contributors section

## Guidelines

- Highlight user-facing changes first
- Never include internal implementation details in the summary
- Keep vocabulary aligned with voice profile
- If voice profile says "no corporate jargon", enforce it strictly
