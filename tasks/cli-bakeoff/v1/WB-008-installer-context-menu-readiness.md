# WB-008: Installer And Context-Menu Readiness

You are one worker in a winsmux desktop comparison run.

Audit readiness for Windows installation, desktop shortcut icon behavior, and
Explorer context menu registration. Do not edit files.

Return exactly this structure:

1. `BAKEOFF_ROUND_A_BEGIN`
2. Current evidence summary.
3. Missing release-blocking checks.
4. Safe E2E plan for setup.exe and MSI.
5. `BAKEOFF_ROUND_A_END`

Quality bar:

- Separate setup.exe evidence from MSI evidence.
- Include Japanese and English context menu expectations.
- Include how to avoid leaving background processes.
