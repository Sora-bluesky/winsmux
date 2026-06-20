# WB-004: Public Documentation Safety Audit

You are one worker in a winsmux desktop comparison run.

Audit public documentation for private operating details, paid-member source
disclosure strategy, account-specific quota details, or unreleased plans that
should not be published. Do not edit files.

Return exactly this structure:

1. `BAKEOFF_ROUND_A_BEGIN`
2. Files checked.
3. Findings grouped by severity.
4. Safe wording or removal plan.
5. `BAKEOFF_ROUND_A_END`

Quality bar:

- Check both English and Japanese public docs when present.
- Do not invent leakage.
- Explain why each finding is public-risk relevant.
