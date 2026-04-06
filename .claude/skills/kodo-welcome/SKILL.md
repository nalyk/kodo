# kodo-welcome — Contributor Onboarding Skill

Generate a personalized welcome message for first-time contributors.

## Input

- Contributor username
- Contribution type (PR, issue, discussion)
- Repo context (name, description, language)
- Voice profile

## Process

1. Check community_log for dedup (never welcome twice)
2. Draft welcome message using voice profile
3. Keep under 100 words
4. Mention their specific contribution type

## Output

A markdown comment to post on the contributor's PR or issue.

## Guidelines

- Be genuine, not corporate
- Mention that their contribution matters
- Don't use excessive exclamation marks
- Don't use "excited to announce" or similar corporate phrases
- Reference the project by name, not "this project"
- If voice profile exists, match its tone exactly
