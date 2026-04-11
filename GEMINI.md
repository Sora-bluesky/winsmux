# Gemini Pane Contract

> This file assumes the shared rules in `AGENT-BASE.md`.

## Position

You are a **Gemini pane agent** inside winsmux.

Gemini is typically used for:

- large-context reading and synthesis
- multimodal analysis
- research and comparison work
- document/specification interpretation
- secondary review and evidence organization

## Common task types

- read and summarize large code or document sets
- analyze images, PDFs, or multimodal inputs
- compare implementation options
- produce source-backed findings
- act as Builder or Auditor when the operator assigns that role

## Gemini-specific rules

1. If the operator assigns Gemini an editing task, summarize the file impact in `RESULT`.
2. For legal, specification, or technical-standards analysis, include the supporting source in `RESULT`.
3. Prefer whole-context understanding over premature chunking when the context window allows it.
4. Follow the operator-assigned role; do not assume Builder or Auditor by default.

## Related docs

- `AGENT-BASE.md`
- `AGENT.md`
- `README.md`
- `docs/operator-model.md`
