/**
 * Pure text-shape heuristics for deciding whether a worker pane's captured
 * terminal output shows an idle prompt (ready for benchmark dispatch) or is
 * still mid-launch/mid-response. Extracted from main.ts so the exact banner
 * shapes reported against real agent CLIs can be covered by a fixture-based
 * regression test (see scripts/worker-readiness-prompt-check.mjs) without
 * needing to boot the full desktop webview.
 */

/**
 * A line that merely echoes a not-yet-submitted launch/command invocation
 * (e.g. the shell prompt showing `> codex --model ...` right after a pane
 * was spawned) must never be mistaken for an idle ghost-text input prompt.
 */
export function isWorkerLaunchCommandEcho(line: string): boolean {
  return /^[>›❯]\s*(?:claude|codex|agy|grok|pwsh|powershell)\b/i.test(line)
    || /^PS\s+.+>\s*(?:claude|codex|agy|grok|pwsh|powershell)\b/i.test(line);
}

/**
 * #1115: Codex/GPT-5.5 idle panes render a footer status line such as
 * "gpt-5.5 xhigh fast" below the ghost-text input prompt instead of the
 * "NN% context left" readout the generic marker heuristics in
 * hasWorkerReadyPrompt expect. When that status line is the most recent
 * non-empty line and it is not itself a pending launch/command echo, the
 * pane is idle at its prompt and ready, independent of whether the
 * ghost-prompt marker line above it survived buffer normalization intact.
 */
export function hasCodexIdleStatusLine(line: string): boolean {
  return /^(?:gpt|codex|gpt-oss|o[0-9])[A-Za-z0-9._/-]*\s+(?:provider-default|low|medium|high|xhigh|max)\s+(?:minimal|low|medium|high|fast|turbo|slow)\b/i.test(line);
}

/**
 * #1115 (P2 follow-up): a pane that is still mid-launch can print the launch
 * command echo (`> codex --model ...`) and/or a "Starting Codex..." style
 * marker *above* the eventual idle footer line within the same captured
 * window. If any recent line still shows that pending/mid-launch shape, the
 * footer line must not be trusted as idle evidence yet, even though the
 * footer text itself matches the idle-status shape.
 */
function hasPendingWorkerLaunchMarker(lines: readonly string[]): boolean {
  return lines.some((line) => isWorkerLaunchCommandEcho(line)
    || /\b(?:starting|launching|initializing)\b/i.test(line));
}

export function hasWorkerReadyPrompt(text: string): boolean {
  const recentLines = text
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(-10);
  const hasGrokInputBox = recentLines.some((line) => /^│\s*>\s*│?$/.test(line))
    && recentLines.some((line) => /Grok\s+Build/i.test(line));
  if (hasGrokInputBox) {
    return true;
  }
  if (
    recentLines.some((line) => !isWorkerLaunchCommandEcho(line)
      && (/^api_llm\[[a-z0-9._-]+\]>\s*$/i.test(line)
        || /^(?:[>›❯])\s*$/.test(line)
        || /^(?:[>›❯])\s*(?!(?:claude|codex|agy|grok|pwsh|powershell)\b)\S/i.test(line)))
  ) {
    return true;
  }
  const lastLine = recentLines[recentLines.length - 1];
  return Boolean(lastLine)
    && hasCodexIdleStatusLine(lastLine)
    && !hasPendingWorkerLaunchMarker(recentLines);
}
