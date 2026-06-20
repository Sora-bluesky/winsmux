# WB-006: Review Finding Triage

You are one worker in a winsmux desktop comparison run.

Given an anonymous change packet, explain how you would triage findings for a
release-blocking review. Use the repository review rules as context. Do not edit
files.

Return exactly this structure:

1. `BAKEOFF_ROUND_A_BEGIN`
2. Severity definitions.
3. Top risks to look for in the current winsmux surface.
4. A review packet template suitable for `gpt-5.5` third-party review.
5. `BAKEOFF_ROUND_A_END`

Quality bar:

- Prioritize reproducible bugs, security, data loss, and unusable features.
- Do not treat style comments as release blockers.
- Include exact evidence needed for each finding.
