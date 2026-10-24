import { invoke } from '@tauri-apps/api/core';
import { getCurrentWebviewWindow } from '@tauri-apps/api/webviewWindow';

import type { PopoutPayload, SecondaryCapture } from './startup-location';

function record(value: unknown): value is Record<string, unknown> { return !!value && typeof value === 'object' && !Array.isArray(value) && Object.getPrototypeOf(value) === Object.prototype; }
function keys(value: Record<string, unknown>, required: string[], optional: string[] = []) {
  return required.every(key => Object.prototype.hasOwnProperty.call(value, key)) && Object.keys(value).every(key => required.includes(key) || optional.includes(key));
}
function capturedReadIntent(storage: Pick<Storage, 'getItem'>): Readonly<{ root: string; active: string; sessions: string }> | null {
  try {
    const active = storage.getItem('winsmux.active-project.v1');
    const sessions = storage.getItem('winsmux.project-sessions.v1');
    const entries = JSON.parse(sessions ?? 'null');
    if (!active?.trim() || !Array.isArray(entries) || !entries.every(entry => record(entry) && keys(entry, ['path', 'name', 'lastSeenAt']) && typeof entry.path === 'string' && entry.path.trim().length > 0 && typeof entry.name === 'string' && typeof entry.lastSeenAt === 'number' && Number.isFinite(entry.lastSeenAt))) return null;
    return sessions !== null && entries.some(entry => entry.path === active) ? Object.freeze({ root: active, active, sessions }) : null;
  } catch { return null; }
}
export function capturedReadRoot(storage: Pick<Storage, 'getItem'>): string | null { return capturedReadIntent(storage)?.root ?? null; }

export function relativeReadPath(raw: string): string | null {
  const path = raw.replace(/\\/g, '/');
  return path.split('/').some(part => !part || part === '.' || part === '..' || /[\x00-\x1f\x7f:]/.test(part) || /[. ]$/.test(part)
    || /^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)/i.test(part)) ? null : path;
}
type ReadFileReply = { path: string; content: string; line_count: number; truncated: boolean };
export function validateReadReply(value: unknown, projectDir: string, worktree: string | null, path: string): ReadFileReply | null {
  if (!record(value) || !keys(value, ['project_dir', 'worktree', 'file']) || value.project_dir !== projectDir || value.worktree !== worktree) return null;
  const file = value.file;
  if (!record(file) || !keys(file, ['path', 'content', 'line_count', 'truncated']) || file.path !== path || typeof file.content !== 'string'
    || file.content.length > 32 * 1024 || typeof file.truncated !== 'boolean' || !Number.isSafeInteger(file.line_count)) return null;
  const lines = Math.max(1, file.content.split('\n').length - (file.content.endsWith('\n') ? 1 : 0));
  return file.line_count === lines ? file as ReadFileReply : null;
}

export async function mountSecondarySurface(payload: PopoutPayload, capture: SecondaryCapture | null = null) {
  let disposed = false; let succeeded = true; const current = () => !disposed && (capture === null || capture.current());
  let surfaceCurrent = current;
  if (!current()) throw Error('secondary_stale');
  const callbacks: Array<() => void> = [];
  const shell = document.getElementById('app-shell'); const editor = document.getElementById('editor-surface');
  if (!shell || !editor) throw new Error('secondary_surface_missing');
  const body = document.getElementById('workspace-body');
  if (!body) throw new Error('secondary_surface_missing');
  // Keep only the readonly surface, before revealing or registering anything.
  editor.remove(); body.replaceChildren(editor); shell.replaceChildren(body);
  shell.hidden = false; shell.inert = false; editor.hidden = false; document.body.dataset.popoutSurface = '1';
  applyVisualPreferences(shell);
  const element = <T extends HTMLElement>(id: string) => {
    const found = document.getElementById(id); if (!found) throw new Error('secondary_surface_missing'); return found as T;
  };
  const code = element('editor-code'); code.setAttribute('aria-readonly', 'true');
  const frame = element<HTMLIFrameElement>('browser-frame'); const browser = element('browser-surface');
  const status = element('editor-statusbar'); const title = element('editor-surface-title');
  const path = element('editor-file-path'); const summary = element('editor-surface-summary');
  const diff = element('editor-diff-preview'); const meta = element('editor-meta-row');
  element('popout-editor-btn').remove(); element('editor-tabs').replaceChildren();
  const clearFrame = () => { frame.src = 'about:blank'; browser.hidden = true; };
  const dispose = () => { if (disposed) return; capture?.report('closed'); disposed = true; capture?.dispose(); callbacks.forEach(remove => remove()); clearFrame(); window.removeEventListener('unload', dispose); };
  window.addEventListener('unload', dispose, { once: true });
  const bind = (id: string, fn: () => void | Promise<void>) => { const button = element<HTMLButtonElement>(id); const callback = () => { if (!disposed) void fn(); }; button.addEventListener('click', callback); callbacks.push(() => button.removeEventListener('click', callback)); };
  bind('close-editor-btn', async () => { if (!disposed) await getCurrentWebviewWindow().close(); });
  function chips(root: HTMLElement, values: string[]) { root.replaceChildren(); for (const value of values.filter(Boolean)) { const chip = document.createElement('span'); chip.className = 'editor-meta-chip'; chip.textContent = value; root.append(chip); } root.hidden = root.childElementCount === 0; }
  if (payload.mode === 'preview') {
    title.textContent = 'Preview'; path.textContent = payload.url;
    chips(summary, ['Preview', 'Detached', payload.runLabel ?? payload.runId ?? '', payload.portLabel, payload.sourceLabel]);
    meta.hidden = true; diff.hidden = true; code.hidden = true; frame.src = payload.url; browser.hidden = false;
    element('browser-target-list').replaceChildren(); element('browser-meta-row').replaceChildren();
    element('browser-toolbar-summary').textContent = `${payload.portLabel} · ${payload.sourceLabel}`;
    status.textContent = `Preview · ${payload.portLabel} · ${payload.sourceLabel}`;
    bind('browser-reload-btn', () => { frame.src = payload.url; });
    bind('browser-back-btn', () => { clearFrame(); code.hidden = false; code.textContent = 'No backend preview cached.'; status.textContent = 'Idle'; });
    bind('browser-copy-btn', async () => { try { await navigator.clipboard.writeText(payload.url); if (!disposed) status.textContent = 'Copied'; } catch { if (!disposed) status.textContent = 'Copy failed'; } });
    bind('browser-open-btn', () => { const opened = window.open(payload.url, '_blank', 'noopener'); status.textContent = opened ? 'Opened' : 'Blocked'; });
  } else {
    clearFrame(); code.hidden = false; title.textContent = payload.sourceChange ? 'Diff review' : 'Editor'; path.textContent = payload.path;
    chips(summary, ['Code', 'Detached', payload.runLabel ?? payload.runId ?? '', payload.origin === 'context' ? 'Run context' : 'Explorer', payload.worktree]);
    if (payload.sourceChange) chips(diff, ['Diff preview', payload.sourceChange.summary, payload.sourceChange.status, payload.sourceChange.lines, payload.sourceChange.branch, payload.sourceChange.review, payload.sourceChange.paneLabel]); else diff.hidden = true;
    let readCurrent = current;
    const render = (content: string, truncated: boolean, lineCount: number) => {
      if (!readCurrent()) return;
      const language = inferLanguageFromPath(payload.path);
      if (payload.path.toLowerCase().endsWith('.svg')) renderEditorSvgPreview(code, content, payload.path); else renderEditorCode(code, content, language);
      chips(meta, [language, `${lineCount} lines`, payload.modified ? 'Modified' : 'Saved', truncated ? 'Preview truncated' : '']);
      status.textContent = ['Detached', payload.runLabel ?? payload.runId ?? '', 'Ln 1, Col 1', `Lines ${lineCount}`, getEditorIndentSizeLabel(content), 'UTF-8', getEditorLineEndingLabel(content), language].filter(Boolean).join(' · ');
    };
    if (payload.content !== undefined) render(payload.content, false, payload.content.split(/\r\n|\r|\n/).length);
    else {
      let epoch = 0;
      const invalidate = (event: StorageEvent) => { if ((event.storageArea === null || event.storageArea === localStorage) && (event.key === null || !capture?.metadata && ['winsmux.active-project.v1', 'winsmux.project-sessions.v1'].includes(event.key))) epoch++; };
      window.addEventListener('storage', invalidate); callbacks.push(() => window.removeEventListener('storage', invalidate));
      const legacyIntent = capture?.metadata ? null : capturedReadIntent(localStorage);
      const intent = capture?.intent ? { root: capture.intent.project_dir } : legacyIntent; const capturedEpoch = epoch;
      readCurrent = () => {
        if (!current() || epoch !== capturedEpoch || intent === null) return false;
        if (capture?.metadata) return capture.intent !== null;
        try { return localStorage.getItem('winsmux.active-project.v1') === legacyIntent?.active && localStorage.getItem('winsmux.project-sessions.v1') === legacyIntent?.sessions; }
        catch { return false; }
      };
      surfaceCurrent = readCurrent;
      const path = relativeReadPath(payload.path); const worktree = payload.worktree || null;
      if (intent === null || path === null || !readCurrent()) { succeeded = false; code.textContent = '明示的な作業場所と相対ファイルを確認できないためファイルを読みません。'; }
      else {
      code.textContent = 'Backend preview request in flight.';
      try {
        const reply = await invoke<unknown>('startup_secondary_request', { requestJson: JSON.stringify({ kind: 'editor-read', project_dir: intent.root, worktree, path }) });
        const data = validateReadReply(reply, intent.root, worktree, path);
        if (data === null) throw new Error('protocol_failed');
        render(data.content, data.truncated, data.line_count);
      } catch { succeeded = false; capture?.report('failed'); if (readCurrent()) code.textContent = 'Backend preview failed to load.'; }
      }
    }
  }
  await new Promise<void>(resolve => requestAnimationFrame(() => resolve()));
  if (!disposed && (capture?.metadata ? surfaceCurrent() && succeeded : true)) {
    const reply = await invoke<unknown>('startup_secondary_request', { requestJson: JSON.stringify({ kind: 'show' }) });
    if (!record(reply) || !keys(reply, ['shown']) || reply.shown !== true) throw new Error('secondary_show_failed');
    if (surfaceCurrent()) capture?.report('ready'); else capture?.report('failed');
  } else capture?.report('failed');
  return { dispose };
}

function applyVisualPreferences(shell: HTMLElement) {
  let data: Record<string, unknown> = {};
  try { const parsed: unknown = JSON.parse(localStorage.getItem('winsmux.shell.preferences.v1') ?? '{}'); if (record(parsed)) data = parsed; } catch { /* display defaults */ }
  const theme = ['codex-dark', 'graphite-dark'].includes(data.theme as string) ? 'dark' : data.theme;
  shell.dataset.theme = ['system', 'dark', 'light'].includes(theme as string) ? theme as string : 'system';
  shell.dataset.density = data.density === 'compact' ? 'compact' : 'comfortable';
  shell.dataset.wrapMode = data.wrapMode === 'compact' ? 'compact' : 'balanced';
  shell.dataset.codeFont = ['system', 'google-sans-code', 'jetbrains-mono'].includes(data.codeFont as string) ? data.codeFont as string : 'system';
  const font = typeof data.codeFontFamily === 'string' && data.codeFontFamily.trim().length > 0 && data.codeFontFamily.trim().length <= 200 ? data.codeFontFamily.trim() : "Consolas, 'Courier New', monospace";
  const size = typeof data.editorFontSize === 'number' && Number.isFinite(data.editorFontSize) ? Math.max(8, Math.min(32, data.editorFontSize)) : 13;
  shell.style.setProperty('--font-code', font); shell.style.setProperty('--editor-font-size', `${size}px`); document.documentElement.lang = data.language === 'ja' ? 'ja' : 'en';
}

interface EditorCodeLine { number: number; text: string }
function splitEditorCodeLines(content: string): EditorCodeLine[] {
  const lines = content.split(/\r\n|\r|\n/);
  return (lines.length > 0 ? lines : [""]).map((text, index) => ({
    number: index + 1,
    text,
  }));
}

type EditorSyntaxTokenKind =
  | "comment"
  | "function"
  | "heading"
  | "keyword"
  | "link"
  | "number"
  | "operator"
  | "property"
  | "punctuation"
  | "string"
  | "tag";

interface EditorSyntaxToken {
  start: number;
  end: number;
  kind: EditorSyntaxTokenKind;
}

function appendEditorSyntaxText(root: HTMLElement, text: string, kind?: EditorSyntaxTokenKind) {
  if (!text) {
    return;
  }
  const span = document.createElement("span");
  if (kind) {
    span.className = `editor-token editor-token-${kind}`;
  }
  span.textContent = text;
  root.appendChild(span);
}

function addEditorSyntaxMatches(tokens: EditorSyntaxToken[], text: string, pattern: RegExp, kind: EditorSyntaxTokenKind) {
  for (const match of text.matchAll(pattern)) {
    const start = match.index ?? -1;
    const value = match[0] ?? "";
    if (start < 0 || !value) {
      continue;
    }
    const end = start + value.length;
    if (tokens.some((token) => start < token.end && end > token.start)) {
      continue;
    }
    tokens.push({ start, end, kind });
  }
}

function appendTokenizedEditorLine(root: HTMLElement, text: string, tokens: EditorSyntaxToken[]) {
  let cursor = 0;
  const orderedTokens = [...tokens].sort((left, right) => left.start - right.start || right.end - left.end);
  for (const token of orderedTokens) {
    if (token.start < cursor || token.end <= token.start) {
      continue;
    }
    appendEditorSyntaxText(root, text.slice(cursor, token.start));
    appendEditorSyntaxText(root, text.slice(token.start, token.end), token.kind);
    cursor = token.end;
  }
  appendEditorSyntaxText(root, text.slice(cursor));
}

function appendMarkdownEditorLine(root: HTMLElement, text: string) {
  const heading = /^(#{1,6})(\s+)(.*)$/.exec(text);
  if (heading) {
    appendEditorSyntaxText(root, heading[1], "punctuation");
    appendEditorSyntaxText(root, heading[2]);
    appendEditorSyntaxText(root, heading[3], "heading");
    return;
  }

  const list = /^(\s*)([-*+]|\d+[.)])(\s+)(.*)$/.exec(text);
  if (list) {
    appendEditorSyntaxText(root, list[1]);
    appendEditorSyntaxText(root, list[2], "punctuation");
    appendEditorSyntaxText(root, list[3]);
    appendMarkdownInlineSyntax(root, list[4]);
    return;
  }

  const quote = /^(\s*>+\s?)(.*)$/.exec(text);
  if (quote) {
    appendEditorSyntaxText(root, quote[1], "punctuation");
    appendMarkdownInlineSyntax(root, quote[2]);
    return;
  }

  appendMarkdownInlineSyntax(root, text);
}

function appendMarkdownInlineSyntax(root: HTMLElement, text: string) {
  const tokens: EditorSyntaxToken[] = [];
  addEditorSyntaxMatches(tokens, text, /`[^`]*`/g, "string");
  addEditorSyntaxMatches(tokens, text, /\[[^\]]+\]\([^)]+\)/g, "link");
  addEditorSyntaxMatches(tokens, text, /<\/?[A-Za-z][^>]*>/g, "tag");
  addEditorSyntaxMatches(tokens, text, /(\*\*|__)[^\n]+?\1/g, "keyword");
  appendTokenizedEditorLine(root, text, tokens);
}

function appendCodeEditorLine(root: HTMLElement, text: string, language: string) {
  const normalized = language.toLowerCase();
  const tokens: EditorSyntaxToken[] = [];
  if (normalized === "markdown") {
    appendMarkdownEditorLine(root, text);
    return;
  }
  if (normalized === "html") {
    addEditorSyntaxMatches(tokens, text, /<!--.*?-->/g, "comment");
    addEditorSyntaxMatches(tokens, text, /<\/?[A-Za-z][A-Za-z0-9:-]*/g, "tag");
    addEditorSyntaxMatches(tokens, text, /\b[A-Za-z_:][-A-Za-z0-9_:.]*(?==)/g, "property");
  } else if (normalized === "css") {
    addEditorSyntaxMatches(tokens, text, /\/\*.*?\*\//g, "comment");
    addEditorSyntaxMatches(tokens, text, /(?:--)?[-A-Za-z]+(?=\s*:)/g, "property");
    addEditorSyntaxMatches(tokens, text, /#[0-9A-Fa-f]{3,8}\b/g, "number");
  } else if (normalized === "powershell" || normalized === "yaml" || normalized === "toml") {
    addEditorSyntaxMatches(tokens, text, /#.*/g, "comment");
  } else {
    addEditorSyntaxMatches(tokens, text, /\/\/.*/g, "comment");
  }

  addEditorSyntaxMatches(tokens, text, /(["'`])(?:\\.|(?!\1).)*\1/g, "string");
  addEditorSyntaxMatches(tokens, text, /\b\d+(?:\.\d+)?\b/g, "number");
  addEditorSyntaxMatches(tokens, text, /\b(?:async|await|break|case|const|continue|crate|else|enum|export|fn|for|from|function|if|impl|import|interface|let|match|mod|pub|return|self|struct|type|use|where|while)\b/g, "keyword");
  if (normalized === "powershell") {
    addEditorSyntaxMatches(tokens, text, /(?:^|\s)-[A-Za-z][A-Za-z0-9-]*/g, "operator");
  }
  addEditorSyntaxMatches(tokens, text, /\b[A-Za-z_$][\w$]*(?=\s*\()/g, "function");
  appendTokenizedEditorLine(root, text, tokens);
}

function renderEditorCode(root: HTMLElement, content: string, language = "Text") {
  root.innerHTML = "";
  root.classList.remove("is-image-preview");
  const lines = splitEditorCodeLines(content);
  root.style.setProperty("--editor-line-number-digits", `${Math.max(2, String(lines.length).length)}`);
  for (const line of lines) {
    const row = document.createElement("div");
    row.className = "editor-code-line";
    row.dataset.line = `${line.number}`;

    const lineNumber = document.createElement("span");
    lineNumber.className = "editor-line-number";
    lineNumber.textContent = `${line.number}`;

    const lineContent = document.createElement("span");
    lineContent.className = "editor-line-content";
    if (line.text) {
      appendCodeEditorLine(lineContent, line.text, language);
    } else {
      lineContent.textContent = " ";
    }

    row.append(lineNumber, lineContent);
    root.appendChild(row);
  }
}

function renderEditorSvgPreview(root: HTMLElement, content: string, path: string) {
  root.innerHTML = "";
  root.classList.add("is-image-preview");

  const preview = document.createElement("div");
  preview.className = "editor-svg-preview";

  const image = document.createElement("img");
  image.className = "editor-svg-preview-image";
  image.alt = path;
  image.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(content)}`;

  preview.appendChild(image);
  root.appendChild(preview);
}

function getEditorLineEndingLabel(content: string) {
  return content.includes("\r\n") ? "CRLF" : "LF";
}

function getEditorIndentSizeLabel(content: string) {
  const indents = content.match(/^( +)\S/gm) ?? [];
  if (indents.length === 0) {
    return content.match(/^\t+\S/gm) ? "Tabs" : "Spaces: 2";
  }
  const sizes = indents
    .map((indent) => indent.search(/\S/))
    .filter((size) => size > 0);
  const smallest = sizes.length > 0 ? Math.min(...sizes) : 2;
  return `Spaces: ${Math.min(Math.max(smallest, 1), 8)}`;
}

function inferLanguageFromPath(path: string) {
  if (path.endsWith(".ts")) {
    return "TypeScript";
  }
  if (path.endsWith(".rs")) {
    return "Rust";
  }
  if (path.endsWith(".md")) {
    return "Markdown";
  }
  if (path.endsWith(".css")) {
    return "CSS";
  }
  if (path.endsWith(".html")) {
    return "HTML";
  }
  if (path.endsWith(".svg")) {
    return "SVG";
  }
  if (path.endsWith(".ps1")) {
    return "PowerShell";
  }
  if (path.endsWith(".json")) {
    return "JSON";
  }
  if (path.endsWith(".toml")) {
    return "TOML";
  }
  if (path.endsWith(".yml") || path.endsWith(".yaml")) {
    return "YAML";
  }
  return "Text";
}
