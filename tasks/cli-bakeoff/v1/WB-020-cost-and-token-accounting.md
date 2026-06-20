# WB-020: Cost and Token Accounting

You are one worker in a winsmux Harness Bench comparison run.

Define how the benchmark report should account for tokens and cost. Do not edit
files.

Return exactly this structure:

1. `BAKEOFF_ROUND_C_BEGIN`
2. Required token fields.
3. Required cost fields.
4. Public-redaction rules.
5. `BAKEOFF_ROUND_C_END`

Quality bar:

- Tokens and cost must come from run metadata or be marked unavailable.
- Provider request IDs are not public evidence.
- Excluded runs still need cost accounting when available.
