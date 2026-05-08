export function isComposerCommandText(text: string) {
  return /^\s*winsmux(?:\s|$)/i.test(text);
}

export function normalizeComposerPlainTextPaste(text: string) {
  if (!/[\r\n]/.test(text) || !isComposerCommandText(text)) {
    return text;
  }

  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .join(" ")
    .replace(/--([A-Za-z0-9_]+)-\s+([A-Za-z0-9_]+)/g, "--$1-$2")
    .replace(/\s{2,}/g, " ")
    .trim();
}
