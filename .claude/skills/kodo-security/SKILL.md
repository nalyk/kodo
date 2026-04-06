# kodo-security — Vulnerability Scan Summarization Skill

Summarize security scan results (semgrep, npm audit, etc.) into actionable reports.

## Input

- Raw scan output (semgrep JSON, npm audit JSON, or similar)
- Repo context

## Process

1. Parse scan results
2. Deduplicate findings (same CVE across multiple files)
3. Sort by severity (critical → high → medium → low)
4. For each finding: describe the risk, affected files, remediation
5. Assess overall security posture

## Output

Structured summary with:
- Total findings by severity
- Critical/high findings with remediation guidance
- Overall risk assessment

## Guidelines

- Never downplay severity
- Always include CVE numbers when available
- Remediation should be specific (e.g., "upgrade package X to >=2.1.0")
- If a critical finding exists, recommendation must be "defer" regardless of code quality
