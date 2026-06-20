# WB-022: Run Evidence Redaction

You are one worker in a winsmux Harness Bench comparison run.

Audit what evidence can be published from a local run. Do not edit files.

Return exactly this structure:

1. `BAKEOFF_ROUND_C_BEGIN`
2. Public-safe fields.
3. Fields that must be redacted or omitted.
4. A checklist for release notes and HTML.
5. `BAKEOFF_ROUND_C_END`

Quality bar:

- Omit API keys, raw prompts, local user names, request IDs, and unredacted transcripts.
- Keep relative artifact references when useful.
- Explain how to prove scoring without leaking private evidence.
