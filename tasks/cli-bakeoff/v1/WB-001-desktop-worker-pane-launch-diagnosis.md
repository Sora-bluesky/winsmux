# WB-001: Desktop Worker-Pane Launch Diagnosis

You are one worker in a winsmux desktop comparison run.

Use the repository evidence to diagnose why worker panes can appear started but
produce no scoreable work. Do not edit files.

Return exactly this structure:

1. `BAKEOFF_ROUND_A_BEGIN`
2. A concise diagnosis with file references.
3. A mitigation plan that can be rerun during a recorded desktop test.
4. A scoring note with risks, missing evidence, and follow-up tests.
5. `BAKEOFF_ROUND_A_END`

Quality bar:

- Distinguish CLI failure, runner failure, and desktop pane display failure.
- Mention the evidence that would prove each failure mode.
- Do not claim a model failed unless the launch path was valid.
