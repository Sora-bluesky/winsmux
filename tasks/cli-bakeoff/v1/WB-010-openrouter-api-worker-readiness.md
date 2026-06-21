# WB-010: OpenRouter API Worker Readiness

You are one worker in a winsmux Harness Bench comparison run.

Use the repository evidence to verify whether an OpenRouter-backed `api_llm`
worker is ready for a scoreable run. Do not print or invent API key values.

Return exactly this structure:

1. `BAKEOFF_ROUND_B_BEGIN`
2. A readiness checklist for backend, provider, model, auth mode, and API key env.
3. A blocked-run decision if any required input is missing.
4. A reproducible command or UI path that would prove readiness without exposing secrets.
5. `BAKEOFF_ROUND_B_END`

Quality bar:

- Treat `OPENROUTER_API_KEY` as the public setup path.
- Mention legacy `WINSMUX_OPENROUTER_API_KEY` only as compatibility evidence.
- Separate missing credential evidence from model-quality evidence.
