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
 * marker line before the eventual idle footer line appears. Within a single
 * fresh-launch sequence (echo -> "Starting..." -> spinner frames -> footer)
 * that marker always lands within a few lines of the footer, so only the
 * near-footer window needs to be inspected for it.
 *
 * #1115 (P3 follow-up): this must NOT scan the entire recent-lines window.
 * `recentLines` mixes buffered scrollback history with the current capture
 * (see inspectWorkerPaneReadiness in main.ts), so a launch echo/marker from
 * a much earlier launch can still be sitting many lines above an otherwise
 * genuinely idle footer. Scanning the full window would keep treating that
 * pane as not-ready forever. Limiting the scan to the trailing lines next
 * to the footer keeps the fresh-launch suppression intact while letting
 * stale history age out once enough lines have scrolled past it.
 */
const PENDING_LAUNCH_MARKER_WINDOW = 6;

function hasPendingWorkerLaunchMarker(lines: readonly string[]): boolean {
  return lines
    .slice(-PENDING_LAUNCH_MARKER_WINDOW)
    .some((line) => isWorkerLaunchCommandEcho(line)
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

/**
 * #1115 (root cause confirmed against a real capture, comment 4872058128):
 * inspectWorkerPaneReadiness in main.ts builds its readiness text by joining
 * three capture sources -- entry.outputBuffer, the live xterm DOM snapshot
 * from getWorkerPaneVisibleText, and the freshest capturePtyPane(...).output
 * -- with "\n" and then handing the whole blob to hasWorkerReadyPrompt, which
 * only inspects the trailing 10 non-empty lines of that combined text.
 *
 * capturePtyPane(...).output is always the LAST of the three sources in the
 * join, i.e. always closest to the tail. When the pane's own launch command
 * is long (absolute -C/--add-dir paths make it so) and the terminal keeps
 * re-drawing that command line in place, that freshest capture can by itself
 * span many more than 10 physical terminal rows: once ANSI control
 * sequences are stripped, one repaint glues directly onto the next with no
 * separating whitespace (e.g. "...--add-dir DIRcodex -c model=gpt-5.5..."),
 * but the repaint is still wrapped across several real rows, so it still
 * contains real "\n" boundaries internally. Once that alone exceeds 10
 * lines, the trailing-10 window is 100% redraw noise and can never see the
 * idle banner that getWorkerPaneVisibleText correctly holds in the *middle*
 * source, so the pane is stuck reporting "not ready" forever even though it
 * plainly is (worker-2/Codex in the reported capture).
 *
 * The fix: evaluate hasWorkerReadyPrompt against each source on its own
 * (each source gets its own trailing-10-lines window) instead of only
 * against the naive full join. This strictly generalizes the prior
 * behavior: whatever the joined-text window could ever see was, at most,
 * the tail of whichever source happens to dominate it, and per-source
 * evaluation of that same source covers that with an equal-or-larger
 * window, while also independently covering the other two sources -- so a
 * genuinely idle banner sitting in one source is never hidden by unrelated
 * redraw noise dominating a different source.
 *
 * This intentionally leaves the launch-pending/blocked guards in main.ts
 * (detectWorkerReadinessBlocker, detectWorkerReadinessPendingReason,
 * detectWorkerLaunchPendingReason) evaluating the combined text exactly as
 * before, and does not weaken the launch-marker guards already inside
 * hasWorkerReadyPrompt itself (isWorkerLaunchCommandEcho,
 * hasPendingWorkerLaunchMarker) -- every source is still run through the
 * exact same hasWorkerReadyPrompt check, marker guards included.
 *
 * #1115 (P2 follow-up, Codex review): per-source evaluation alone is not a
 * strict superset of the old joined-text check for multi-line signals whose
 * parts can legitimately land in *different* capture sources. The Grok
 * ghost-input-box signal (hasGrokInputBox in hasWorkerReadyPrompt) needs both
 * a "Grok Build" banner line and a "│ > │" input-box line inside the same
 * trailing-10-lines window; if one part is captured by
 * getWorkerPaneVisibleText and the other by capturePtyPane's freshest
 * output, neither source alone contains both lines, so per-source
 * evaluation alone would report not-ready for a pane the old join-then-check
 * behavior would have correctly reported ready.
 *
 * The fix: also evaluate hasWorkerReadyPrompt against the sources joined
 * with "\n" (the exact old behavior) and OR it with the per-source result.
 * This makes the combined check a guaranteed superset of both the prior
 * joined-only behavior and the per-source behavior above -- it can only
 * additionally resolve to ready in cases neither one alone would catch, and
 * never resolves to not-ready in a case either one alone would call ready.
 */
export function hasWorkerReadyPromptInAnySource(sources: readonly string[]): boolean {
  if (hasWorkerReadyPrompt(sources.filter(Boolean).join("\n"))) {
    return true;
  }
  return sources.some((source) => Boolean(source) && hasWorkerReadyPrompt(source));
}
