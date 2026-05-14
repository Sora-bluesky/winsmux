import { spawn } from "node:child_process";
import { once } from "node:events";
import fs from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import process from "node:process";
import { chromium } from "playwright";

const OUTPUT_DIR = path.join(process.cwd(), "output", "playwright", "desktop-pane-e2e");
const APP_URL_PATTERN = /localhost:1420|127\.0\.0\.1:1420/;
const CONTROL_PIPE_NAME = "winsmux-control";
const WORKER_UI_MARKER = "WORKER_1_UI_E2E_READY";
const OPERATOR_MARKER = "OP_E2E_READY";
const COMPOSER_TO_OPERATOR_MARKER = "BTN_E2E_READY";
const COMPOSER_ENTER_MARKER = "ENT_E2E_READY";
const COMPOSER_ATTACHMENT_MARKER = "ATT_E2E_READY";
const OPERATOR_TO_WORKER_MARKER = "W2_E2E_READY";

const steps = [];
const consoleErrors = [];
const pageErrors = [];
const tauriOutput = [];
const tauriErrors = [];

async function ensureOutputDir() {
  await fs.mkdir(OUTPUT_DIR, { recursive: true });
}

async function getAvailablePort() {
  return await new Promise((resolve, reject) => {
    const server = net.createServer();
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close();
        reject(new Error("Failed to resolve an available port"));
        return;
      }
      const { port } = address;
      server.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve(port);
      });
    });
    server.on("error", reject);
  });
}

function appendBounded(lines, chunk) {
  const text = chunk.toString();
  lines.push(text);
  while (lines.join("").length > 200_000) {
    lines.shift();
  }
}

function startTauriDev(debugPort, userDataDir) {
  const args = process.platform === "win32"
    ? ["/c", "npm", "run", "tauri", "--", "dev"]
    : ["run", "tauri", "--", "dev"];
  const child = spawn(process.platform === "win32" ? "cmd.exe" : "npm", args, {
    cwd: process.cwd(),
    env: {
      ...process.env,
      WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${debugPort} --remote-allow-origins=*`,
      WEBVIEW2_USER_DATA_FOLDER: userDataDir,
      NO_COLOR: "1",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  child.stdout.on("data", (chunk) => {
    appendBounded(tauriOutput, chunk);
    process.stdout.write(chunk);
  });
  child.stderr.on("data", (chunk) => {
    appendBounded(tauriErrors, chunk);
    process.stderr.write(chunk);
  });

  return child;
}

async function stopProcessTree(child) {
  if (!child || child.exitCode !== null || child.killed) {
    return;
  }

  if (process.platform === "win32") {
    const killer = spawn("taskkill", ["/pid", `${child.pid}`, "/t", "/f"], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    await once(killer, "exit").catch(() => {});
    child.stdout?.destroy();
    child.stderr?.destroy();
    child.unref();
    return;
  }

  child.kill("SIGTERM");
  await once(child, "exit").catch(() => {});
}

async function waitForCdp(debugPort, child, timeoutMs = 180_000) {
  const endpoint = `http://127.0.0.1:${debugPort}/json/version`;
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if (child.exitCode !== null) {
      throw new Error(`tauri dev exited before WebView2 remote debugging became available (${child.exitCode})`);
    }
    try {
      const response = await fetch(endpoint);
      if (response.ok) {
        return;
      }
    } catch {
      // Retry until the WebView2 debug endpoint opens.
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`WebView2 remote debugging did not start within ${timeoutMs}ms on port ${debugPort}`);
}

async function resolveAppPage(browser, timeoutMs = 60_000) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    for (const context of browser.contexts()) {
      for (const page of context.pages()) {
        if (APP_URL_PATTERN.test(page.url())) {
          return page;
        }
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  const pages = browser.contexts().flatMap((context) => context.pages()).map((page) => page.url());
  throw new Error(`Could not find the Tauri app page. Seen pages: ${pages.join(", ")}`);
}

function attachPageErrorCapture(page) {
  page.on("console", (message) => {
    if (message.type() === "error") {
      consoleErrors.push(message.text());
    }
  });
  page.on("pageerror", (error) => {
    pageErrors.push(error.message);
  });
  page.on("dialog", async (dialog) => {
    await dialog.accept().catch(() => {});
  });
}

async function runStep(name, action) {
  process.stdout.write(`[desktop-pane-e2e] ${name}\n`);
  const consoleStart = consoleErrors.length;
  const pageStart = pageErrors.length;
  const startedAt = Date.now();
  try {
    const value = await action();
    steps.push({ name, ok: true, durationMs: Date.now() - startedAt, value });
    if (pageErrors.length > pageStart) {
      throw new Error(`${name}: page error: ${pageErrors.slice(pageStart).join(" | ")}`);
    }
    if (consoleErrors.length > consoleStart) {
      throw new Error(`${name}: console error: ${consoleErrors.slice(consoleStart).join(" | ")}`);
    }
    return value;
  } catch (error) {
    steps.push({
      name,
      ok: false,
      durationMs: Date.now() - startedAt,
      error: error instanceof Error ? error.message : String(error),
    });
    if (error instanceof Error) {
      error.message = `${name}: ${error.message}`;
    }
    throw error;
  }
}

async function waitForAppReady(page) {
  await page.locator("#workspace").waitFor({ state: "visible", timeout: 60_000 });
  await page.locator("#terminal-drawer").waitFor({ state: "visible", timeout: 60_000 });
  await page.locator("#operator-terminal-panel").waitFor({ state: "visible", timeout: 60_000 });
  await page.waitForFunction(() => Boolean(window.__TAURI__?.core?.invoke), undefined, {
    timeout: 30_000,
  });
}

async function resetAppState(page) {
  await page.evaluate(() => {
    localStorage.clear();
    sessionStorage.clear();
  });
  await page.reload({ waitUntil: "domcontentloaded" });
  await waitForAppReady(page);
}

async function assertDrawerVisible(page, expected) {
  await page.waitForFunction((visible) => {
    const drawer = document.querySelector("#terminal-drawer");
    const toggle = document.querySelector("#toggle-terminal-btn");
    if (!(drawer instanceof HTMLElement) || !(toggle instanceof HTMLElement)) {
      return false;
    }
    return drawer.hidden === !visible && toggle.getAttribute("aria-expanded") === String(visible);
  }, expected);
}

async function ensureDrawerOpen(page) {
  if (await page.locator("#terminal-drawer").evaluate((drawer) => drawer.hidden).catch(() => false)) {
    await clickWorkerPanesFooterToggle(page);
    await assertDrawerVisible(page, true);
  }
}

async function clickWorkerPanesFooterToggle(page) {
  await page.locator(".footer-pill", { hasText: "Worker panes" }).first().click({ timeout: 10_000 });
}

async function getWorkbenchLayout(page) {
  return await page.locator("#terminal-drawer").getAttribute("data-layout");
}

async function setWorkbenchLayout(page, target) {
  await ensureDrawerOpen(page);
  for (let index = 0; index < 4; index += 1) {
    if ((await getWorkbenchLayout(page)) === target) {
      return;
    }
    await page.click("#workbench-layout-btn");
    await page.waitForTimeout(250);
  }
  throw new Error(`Could not switch workbench layout to ${target}; current=${await getWorkbenchLayout(page)}`);
}

async function paneCount(page) {
  return await page.locator("#panes-container .pane").count();
}

async function visiblePaneIds(page) {
  return await page.locator("#panes-container .pane:visible").evaluateAll((panes) =>
    panes.map((pane) => pane.id.replace(/^pane-/, "")),
  );
}

async function invokePty(page, method, params) {
  const response = await page.evaluate(
    async ({ methodName, methodParams }) => {
      return await window.__TAURI__.core.invoke("pty_json_rpc", {
        request: {
          jsonrpc: "2.0",
          id: `desktop-e2e-${Date.now()}-${Math.random().toString(16).slice(2)}`,
          method: methodName,
          params: methodParams,
        },
      });
    },
    { methodName: method, methodParams: params },
  );

  if (response?.error) {
    throw new Error(response.error.message);
  }
  return response?.result;
}

async function invokeDesktop(page, method, params = {}) {
  const response = await page.evaluate(
    async ({ methodName, methodParams }) => {
      return await window.__TAURI__.core.invoke("desktop_json_rpc", {
        request: {
          jsonrpc: "2.0",
          id: `desktop-native-e2e-${Date.now()}-${Math.random().toString(16).slice(2)}`,
          method: methodName,
          params: methodParams,
        },
      });
    },
    { methodName: method, methodParams: params },
  );

  if (response?.error) {
    throw new Error(response.error.message);
  }
  return response?.result;
}

async function invokeTauriCommand(page, command, args = {}) {
  return await page.evaluate(
    async ({ commandName, commandArgs }) => {
      return await window.__TAURI__.core.invoke(commandName, commandArgs);
    },
    { commandName: command, commandArgs: args },
  );
}

async function capturePty(page, paneId, lines = 120) {
  const result = await invokePty(page, "pty.capture", { paneId, lines });
  return String(result?.output ?? "");
}

async function closePtyIfExists(page, paneId) {
  try {
    await invokePty(page, "pty.close", { paneId });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (!message.includes(`Pane ${paneId} not found`)) {
      throw error;
    }
  }
}

async function spawnPtyIfNeeded(page, paneId) {
  try {
    await invokePty(page, "pty.spawn", { paneId, cols: 100, rows: 24 });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (!message.includes(`Pane ${paneId} already exists`)) {
      throw error;
    }
  }
}

async function waitForPtyOutput(page, paneId, marker, timeoutMs = 45_000) {
  const startedAt = Date.now();
  let lastOutput = "";
  const compactMarker = marker.replace(/\s+/g, "");
  while (Date.now() - startedAt < timeoutMs) {
    lastOutput = await capturePty(page, paneId).catch((error) => `capture failed: ${error.message}`);
    const stripped = stripAnsi(lastOutput);
    if (
      lastOutput.includes(marker) ||
      stripped.includes(marker) ||
      stripped.replace(/\s+/g, "").includes(compactMarker)
    ) {
      return lastOutput;
    }
    if (
      paneId === "operator" &&
      /トークン予算超過|確認待ち|どう進めますか|token budget|continue\?/i.test(stripped)
    ) {
      throw new Error(`Operator is waiting for a user decision before ${marker}. Last output:\n${lastOutput}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`Timed out waiting for ${marker} in ${paneId}. Last output:\n${lastOutput}`);
}

function stripAnsi(value) {
  return value.replace(/\u001B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~]|\][^\u0007]*(?:\u0007|\u001B\\))/g, "");
}

async function waitForPtyOutputLine(page, paneId, line, timeoutMs = 45_000) {
  const startedAt = Date.now();
  let lastOutput = "";
  while (Date.now() - startedAt < timeoutMs) {
    lastOutput = await capturePty(page, paneId).catch((error) => `capture failed: ${error.message}`);
    const strippedLines = stripAnsi(lastOutput)
      .split(/\r?\n/)
      .map((item) => item.trim());
    if (strippedLines.includes(line)) {
      return lastOutput;
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`Timed out waiting for output line ${line} in ${paneId}. Last output:\n${lastOutput}`);
}

async function waitForPtyPrompt(page, paneId, timeoutMs = 45_000) {
  const startedAt = Date.now();
  let lastOutput = "";
  while (Date.now() - startedAt < timeoutMs) {
    lastOutput = await capturePty(page, paneId).catch((error) => `capture failed: ${error.message}`);
    if (/PS [^\r\n>]*> ?$/m.test(stripAnsi(lastOutput).trimEnd())) {
      return lastOutput;
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`Timed out waiting for a PowerShell prompt in ${paneId}. Last output:\n${lastOutput}`);
}

function isClaudeOperatorReadyText(output) {
  const stripped = stripAnsi(output)
    .replace(/\r/g, "\n")
    .replace(/\u00a0/g, " ");
  const compact = stripped.replace(/\s+/g, "");
  if (!compact.includes("ClaudeCode")) {
    return false;
  }
  const tail = stripped.slice(-4000);
  if (/\b(missing api key|run \/login|unable to connect|failed to connect)\b/i.test(tail)) {
    return false;
  }
  if (
    /トークン予算超過|確認待ち|どう進めますか|running \d+ shell command|listing \d+ director|wrangling|choreographing|spelunking|thinking with|still thinking|running stop hook|pasted text|paste again to expand/i
      .test(tail)
  ) {
    return false;
  }
  return /(?:^|\n)[^\n]*[>›▌❯][^\n]*(?:Try "create|create a util|$)/.test(tail)
    || /accepteditson/i.test(tail.replace(/\s+/g, ""));
}

async function waitForClaudeOperatorReady(page, timeoutMs = 90_000) {
  const startedAt = Date.now();
  let lastOutput = "";
  while (Date.now() - startedAt < timeoutMs) {
    lastOutput = await capturePty(page, "operator").catch((error) => `capture failed: ${error.message}`);
    if (isClaudeOperatorReadyText(lastOutput)) {
      return lastOutput;
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`Timed out waiting for Claude Code readiness in operator. Last output:\n${lastOutput}`);
}

async function startOperatorFromUiAndWaitForClaude(page) {
  await page.click("#operator-terminal-panel", { timeout: 10_000 });
  return await waitForClaudeOperatorReady(page);
}

async function typeIntoTerminal(page, selector, text) {
  await page.click(selector, { timeout: 10_000 });
  await page.keyboard.type(text, { delay: 2 });
  await page.keyboard.press("Enter");
}

async function typeTerminalDraft(page, selector, text) {
  await page.click(selector, { timeout: 10_000 });
  await page.keyboard.type(text, { delay: 2 });
}

async function clearOperatorInputFromUi(page) {
  await page.click("#operator-terminal-panel", { timeout: 10_000 });
  await page.keyboard.press("Control+C");
  await page.waitForTimeout(750);
}

async function startPaneFromUiAndWaitForPrompt(page, paneId, selector) {
  await page.click(selector, { timeout: 10_000 });
  await page.keyboard.press("Enter");
  await waitForPtyPrompt(page, paneId);
}

function escapePwshSingleQuoted(value) {
  return value.replace(/'/g, "''");
}

async function writeOperatorPipeScript(scriptPath) {
  const payload = {
    jsonrpc: "2.0",
    id: "operator-to-worker",
    method: "pty.write",
    params: {
      paneId: "worker-2",
      data: `Write-Output '${OPERATOR_TO_WORKER_MARKER}'\r`,
    },
  };

  const body = [
    "$ErrorActionPreference = 'Stop'",
    `$payload = '${escapePwshSingleQuoted(JSON.stringify(payload))}'`,
    `$pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', '${CONTROL_PIPE_NAME}', [System.IO.Pipes.PipeDirection]::InOut)`,
    "$pipe.Connect(5000)",
    "$encoding = [System.Text.UTF8Encoding]::new($false)",
    "$writer = [System.IO.StreamWriter]::new($pipe, $encoding)",
    "$reader = [System.IO.StreamReader]::new($pipe, $encoding)",
    "$writer.AutoFlush = $true",
    "try {",
    "  $writer.Write($payload)",
    "  $response = $reader.ReadToEnd()",
    `  Write-Output '${OPERATOR_MARKER}'`,
    '  Write-Output "PIPE_RESPONSE:$response"',
    "} finally {",
    "  try { $reader.Dispose() } catch {}",
    "  try { $writer.Dispose() } catch {}",
    "  try { $pipe.Dispose() } catch {}",
    "}",
    "",
  ].join("\r\n");

  await fs.writeFile(scriptPath, body, "utf8");
}

async function submitComposerWithButton(page, command, expectedMarker) {
  await startOperatorFromUiAndWaitForClaude(page);
  await page.fill("#composer-input", command);
  await page.click("#send-btn");
  await page.waitForFunction(() => {
    const input = document.querySelector("#composer-input");
    return input instanceof HTMLTextAreaElement && input.value === "";
  });
  const conversationContainsMessage = await page.locator("#conversation-panel", { hasText: command }).count();
  if (conversationContainsMessage < 1) {
    throw new Error("submitted composer message was not rendered in the conversation panel");
  }
  return await waitForPtyOutput(page, "operator", expectedMarker);
}

async function submitComposerWithEnter(page, command, expectedMarker) {
  await startOperatorFromUiAndWaitForClaude(page);
  await page.fill("#composer-input", command);
  await page.focus("#composer-input");
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => {
    const input = document.querySelector("#composer-input");
    return input instanceof HTMLTextAreaElement && input.value === "";
  });
  return await waitForPtyOutput(page, "operator", expectedMarker);
}

async function openCommandPaletteAction(page, query, expected) {
  if (await page.locator("#open-command-bar-btn").isVisible().catch(() => false)) {
    await page.click("#open-command-bar-btn");
  } else {
    await page.focus("#composer-input");
    await page.keyboard.press("Control+K");
  }
  await page.locator("#command-bar-shell").waitFor({ state: "visible" });
  await page.fill("#command-bar-input", query);
  await page.keyboard.press("Enter");
  await expected();
}

async function waitForTauriPage(browser, predicate, timeoutMs = 20_000) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    for (const context of browser.contexts()) {
      for (const candidate of context.pages()) {
        if (await predicate(candidate)) {
          return candidate;
        }
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  const pages = browser.contexts().flatMap((context) => context.pages()).map((candidate) => candidate.url());
  throw new Error(`Timed out waiting for a Tauri page. Seen pages: ${pages.join(", ")}`);
}

async function exerciseTauriNativeSurface(page, browser) {
  const apiSurface = await page.evaluate(() => {
    const tauri = window.__TAURI__;
    return {
      keys: tauri ? Object.keys(tauri).sort() : [],
      hasCoreInvoke: typeof tauri?.core?.invoke === "function",
      hasWebviewWindow: Boolean(tauri?.webviewWindow),
      hasDialog: Boolean(tauri?.dialog),
      hasTray: Boolean(tauri?.tray),
    };
  });
  if (!apiSurface.hasCoreInvoke || !apiSurface.hasWebviewWindow) {
    throw new Error(`Tauri API surface is incomplete: ${JSON.stringify(apiSurface)}`);
  }

  const contract = await invokeDesktop(page, "desktop.control_plane.contract");
  if (!Array.isArray(contract?.methods) || !contract.methods.includes("desktop.editor.read")) {
    throw new Error(`desktop control-plane contract missing editor read: ${JSON.stringify(contract)}`);
  }

  const editorFile = await invokeDesktop(page, "desktop.editor.read", { path: "winsmux-app/src/main.ts" });
  if (!String(editorFile?.content ?? "").includes("@tauri-apps/plugin-dialog")) {
    throw new Error("desktop.editor.read did not return the expected source content");
  }

  const explorer = await invokeDesktop(page, "desktop.explorer.list");
  if (!Array.isArray(explorer?.entries) || explorer.entries.length === 0) {
    throw new Error("desktop.explorer.list returned no project entries");
  }

  const voiceInitial = await invokeTauriCommand(page, "desktop_voice_capture_status");
  const voiceStart = await invokeTauriCommand(page, "desktop_voice_capture_start");
  await page.waitForTimeout(500);
  const voiceDuring = await invokeTauriCommand(page, "desktop_voice_capture_status");
  const voiceStop = await invokeTauriCommand(page, "desktop_voice_capture_stop", { cancelled: true });

  const harnessUrl = new URL(page.url());
  harnessUrl.search = "?viewport-harness=1";
  await page.goto(harnessUrl.toString(), { waitUntil: "domcontentloaded" });
  await waitForAppReady(page);
  await page.waitForFunction(() => Boolean(window.__winsmuxViewportHarness?.openEditorPreview));
  await page.evaluate(() => {
    window.__winsmuxViewportHarness.openEditorPreview(
      "winsmux-app/src/main.ts",
      "export const tauriNativeE2e = true;\n",
    );
  });
  await page.locator("#editor-surface").waitFor({ state: "visible" });
  await page.locator("#popout-editor-btn").waitFor({ state: "visible" });

  await page.click("#popout-editor-btn");
  const popout = await waitForTauriPage(
    browser,
    async (candidate) => candidate !== page && candidate.url().includes("popout=1"),
  );
  attachPageErrorCapture(popout);
  await popout.locator("#editor-surface").waitFor({ state: "visible" });
  await popout.locator("#editor-code", { hasText: "@tauri-apps/plugin-dialog" }).waitFor({ state: "visible" });
  const popoutLabel = await popout.evaluate(() => window.__TAURI__.webviewWindow.getCurrentWebviewWindow().label);
  await popout.click("#close-editor-btn");
  await page.waitForFunction(
    async (label) => {
      const windows = await window.__TAURI__.webviewWindow.getAllWebviewWindows();
      return !windows.some((item) => item.label === label);
    },
    popoutLabel,
    { timeout: 20_000 },
  );

  return {
    apiSurface,
    contractMethods: contract.methods.length,
    editorLineCount: editorFile.line_count,
    explorerEntryCount: explorer.entries.length,
    voiceStates: {
      initial: voiceInitial?.native?.state,
      start: voiceStart?.native?.state,
      during: voiceDuring?.native?.state,
      stop: voiceStop?.native?.state,
    },
    webviewWindow: `created-and-closed:${popoutLabel}`,
  };
}

async function writeEvidence(ok, extra = {}) {
  const evidence = {
    ok,
    timestamp: new Date().toISOString(),
    steps,
    consoleErrors,
    pageErrors,
    tauriOutputTail: tauriOutput.join("").slice(-20_000),
    tauriErrorTail: tauriErrors.join("").slice(-20_000),
    ...extra,
  };
  await fs.writeFile(path.join(OUTPUT_DIR, "desktop-pane-e2e.json"), JSON.stringify(evidence, null, 2));
}

async function main() {
  await ensureOutputDir();
  const debugPort = await getAvailablePort();
  const userDataDir = path.join(OUTPUT_DIR, `webview2-user-data-${Date.now()}`);
  const scriptPath = path.join(OUTPUT_DIR, "operator-to-worker.ps1");
  const attachmentPath = path.join(OUTPUT_DIR, "composer-attachment.txt");
  await writeOperatorPipeScript(scriptPath);
  await fs.writeFile(attachmentPath, "desktop composer attachment e2e\n", "utf8");

  let browser;
  let page;
  const tauri = startTauriDev(debugPort, userDataDir);

  try {
    await runStep("wait for WebView2 remote debugging", async () => {
      await waitForCdp(debugPort, tauri);
      return { debugPort };
    });

    browser = await chromium.connectOverCDP(`http://127.0.0.1:${debugPort}`);
    page = await resolveAppPage(browser);
    attachPageErrorCapture(page);
    await page.setViewportSize({ width: 1600, height: 900 }).catch(() => {});

    await runStep("wait for desktop app chrome", async () => {
      await waitForAppReady(page);
      await resetAppState(page);
      return { url: page.url() };
    });

    await runStep("default center keeps operator and composer unobstructed", async () => {
      await page.waitForTimeout(2_000);
      await page.locator("#operator-terminal-panel").waitFor({ state: "visible" });
      await page.locator("#composer").waitFor({ state: "visible" });
      const runSummaryVisible = await page.locator("#selected-run-summary").isVisible().catch(() => false);
      const dashboardVisible = await page.locator("#agent-work-dashboard").isVisible().catch(() => false);
      if (runSummaryVisible || dashboardVisible) {
        throw new Error(`default center should not show run summary or dashboard; summary=${runSummaryVisible}, dashboard=${dashboardVisible}`);
      }
    });

    await runStep("drawer close and reopen controls", async () => {
      await ensureDrawerOpen(page);
      await page.click("#close-terminal-drawer-btn");
      await assertDrawerVisible(page, false);
      await clickWorkerPanesFooterToggle(page);
      await assertDrawerVisible(page, true);
    });

    await runStep("workbench layout cycling and focus selector", async () => {
      await setWorkbenchLayout(page, "3x2");
      if ((await paneCount(page)) < 6) {
        throw new Error(`3x2 layout should create 6 panes, found ${await paneCount(page)}`);
      }
      await setWorkbenchLayout(page, "focus");
      await page.locator("#focused-pane-select").waitFor({ state: "visible" });
      await page.selectOption("#focused-pane-select", "worker-2");
      const ids = await visiblePaneIds(page);
      if (ids.length !== 1 || ids[0] !== "worker-2") {
        throw new Error(`focus layout should show only worker-2, saw ${ids.join(",")}`);
      }
      await setWorkbenchLayout(page, "3x2");
    });

    await runStep("add and close worker pane controls", async () => {
      await setWorkbenchLayout(page, "3x2");
      const before = await paneCount(page);
      if (before >= 6) {
        if (!(await page.locator("#add-pane-btn").isDisabled())) {
          throw new Error("add pane button should be disabled at the 6 pane limit");
        }
        const lastPaneId = await page.locator("#panes-container .pane").last().getAttribute("id");
        await page.click(`#${lastPaneId} .pane-close`);
        await page.waitForFunction((expected) => document.querySelectorAll("#panes-container .pane").length === expected, before - 1);
        await page.click("#add-pane-btn");
        await page.waitForFunction((expected) => document.querySelectorAll("#panes-container .pane").length === expected, before);
        return {
          limitVerified: true,
          restoredCount: await paneCount(page),
        };
      }
      await page.click("#add-pane-btn");
      const after = await paneCount(page);
      if (before < 6 && after !== before + 1) {
        throw new Error(`add pane should increase count from ${before} to ${before + 1}, saw ${after}`);
      }
      const countAfterAdd = await paneCount(page);
      if (countAfterAdd > 4) {
        const lastPaneId = await page.locator("#panes-container .pane").last().getAttribute("id");
        await page.click(`#${lastPaneId} .pane-close`);
        await page.waitForFunction((expected) => document.querySelectorAll("#panes-container .pane").length === expected, countAfterAdd - 1);
      }
    });

    await runStep("worker pane starts from real UI typing", async () => {
      await setWorkbenchLayout(page, "3x2");
      await startPaneFromUiAndWaitForPrompt(page, "worker-1", "#pane-worker-1 .pane-terminal");
      await typeIntoTerminal(page, "#pane-worker-1 .pane-terminal", `Write-Output '${WORKER_UI_MARKER}'`);
      const output = await waitForPtyOutputLine(page, "worker-1", WORKER_UI_MARKER);
      return { outputTail: output.slice(-800) };
    });

    await runStep("operator pane starts Claude Code and accepts real user input", async () => {
      const readyOutput = await startOperatorFromUiAndWaitForClaude(page);
      await typeTerminalDraft(page, "#operator-terminal-panel", OPERATOR_MARKER);
      const output = await waitForPtyOutput(page, "operator", OPERATOR_MARKER);
      await clearOperatorInputFromUi(page);
      const timelineText = await page.locator("#conversation-timeline").innerText().catch(() => "");
      if (/Claude Code v\d|--permission-mode/.test(timelineText)) {
        throw new Error("operator startup log should stay in the operator pane and not mirror into the chat timeline");
      }
      return { readyTail: readyOutput.slice(-800), outputTail: output.slice(-800) };
    });

    await runStep("operator command writes to worker through desktop control pipe", async () => {
      await spawnPtyIfNeeded(page, "worker-2");
      await waitForPtyPrompt(page, "worker-2");
      await startOperatorFromUiAndWaitForClaude(page);
      // Claude Code uses `!` as its shell-command prefix; this is typed into the operator, not PowerShell.
      const claudeShellCommand = `!pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File '${scriptPath.replace(/'/g, "''")}'`;
      await typeIntoTerminal(page, "#operator-terminal-panel", claudeShellCommand);
      const operatorOutput = await waitForPtyOutput(page, "operator", "PIPE_RESPONSE:");
      const workerOutput = await waitForPtyOutputLine(page, "worker-2", OPERATOR_TO_WORKER_MARKER);
      return {
        operatorTail: operatorOutput.slice(-1_200),
        workerTail: workerOutput.slice(-800),
      };
    });

    await runStep("composer send button writes user message to operator pane", async () => {
      const command = COMPOSER_TO_OPERATOR_MARKER;
      const output = await submitComposerWithButton(page, command, COMPOSER_TO_OPERATOR_MARKER);
      await clearOperatorInputFromUi(page);
      return { outputTail: output.slice(-800) };
    });

    await runStep("composer keyboard behavior preserves newline and Enter sends", async () => {
      await page.fill("#composer-input", "first line");
      await page.focus("#composer-input");
      await page.keyboard.press("Shift+Enter");
      await page.keyboard.type("second line");
      const draft = await page.locator("#composer-input").inputValue();
      if (!draft.includes("\n") || !draft.includes("second line")) {
        throw new Error(`Shift+Enter should insert a newline, got ${JSON.stringify(draft)}`);
      }
      const command = COMPOSER_ENTER_MARKER;
      const output = await submitComposerWithEnter(page, command, COMPOSER_ENTER_MARKER);
      await clearOperatorInputFromUi(page);
      return { outputTail: output.slice(-800) };
    });

    await runStep("composer slash command changes mode without sending", async () => {
      await page.fill("#composer-input", "/ask");
      await page.focus("#composer-input");
      await page.keyboard.press("Enter");
      await page.waitForFunction(() => {
        const input = document.querySelector("#composer-input");
        return input instanceof HTMLTextAreaElement && input.value === "";
      });
      await page.waitForFunction(() => {
        return Array.from(document.querySelectorAll(".footer-pill")).some((item) =>
          item.textContent?.includes("Mode") && item.textContent?.includes("Ask"),
        );
      });
      const value = await page.locator("#composer-input").inputValue();
      return { mode: "ask", inputValue: value };
    });

    await runStep("composer attachment is included in user send flow", async () => {
      await page.locator("#composer-file-input").setInputFiles(attachmentPath);
      await page.locator("#attachment-tray", { hasText: "composer-attachment.txt" }).waitFor({ state: "visible" });
      const message = COMPOSER_ATTACHMENT_MARKER;
      await startOperatorFromUiAndWaitForClaude(page);
      await page.fill("#composer-input", message);
      await page.click("#send-btn");
      await page.waitForFunction(() => {
        const input = document.querySelector("#composer-input");
        return input instanceof HTMLTextAreaElement && input.value === "";
      });
      const output = await waitForPtyOutput(page, "operator", "Pasted text");
      const attachmentStillVisible = await page.locator("#attachment-tray", { hasText: "composer-attachment.txt" }).isVisible().catch(() => false);
      if (attachmentStillVisible) {
        throw new Error("attachment tray should clear after composer submit");
      }
      const conversationHasMessage = await page.locator("#conversation-panel", { hasText: COMPOSER_ATTACHMENT_MARKER }).count();
      if (conversationHasMessage < 1) {
        throw new Error("submitted attachment message was not rendered in the conversation panel");
      }
      const conversationHasAttachment = await page.locator("#conversation-panel", { hasText: "composer-attachment.txt" }).count();
      if (conversationHasAttachment < 1) {
        throw new Error("submitted attachment was not rendered in the conversation panel");
      }
      return { outputTail: output.slice(-800) };
    });

    await runStep("command palette drives settings and worker pane navigation", async () => {
      await openCommandPaletteAction(page, "settings", async () => {
        await page.locator("#settings-sheet").waitFor({ state: "visible" });
      });
      await page.click("#close-settings-btn");
      await page.waitForFunction(() => {
        const sheet = document.querySelector("#settings-sheet");
        return sheet instanceof HTMLElement && sheet.hidden;
      });

      await page.click("#close-terminal-drawer-btn");
      await assertDrawerVisible(page, false);
      await openCommandPaletteAction(page, "workbench", async () => {
        await assertDrawerVisible(page, true);
      });
    });

    await runStep("settings density change applies and persists to shell", async () => {
      await page.click("#activity-settings-btn");
      await page.locator("#settings-sheet").waitFor({ state: "visible" });
      await page.locator("#density-options .settings-option-chip", { hasText: "Compact" }).click();
      await page.click("#apply-settings-btn");
      await page.waitForFunction(() => {
        const shell = document.querySelector("#app-shell");
        return shell instanceof HTMLElement && shell.dataset.density === "compact";
      });
      await page.click("#close-settings-btn");
    });

    await runStep("Tauri native APIs exercise Rust, filesystem, voice, and webview windows", async () => {
      return await exerciseTauriNativeSurface(page, browser);
    });

    await runStep("close spawned PTYs", async () => {
      await closePtyIfExists(page, "worker-1");
      await closePtyIfExists(page, "worker-2");
      await closePtyIfExists(page, "operator");
    });

    await writeEvidence(true, { debugPort });
    process.stdout.write(`[desktop-pane-e2e] PASS evidence=${path.join(OUTPUT_DIR, "desktop-pane-e2e.json")}\n`);
  } catch (error) {
    if (page) {
      await page.screenshot({ path: path.join(OUTPUT_DIR, "desktop-pane-e2e-failure.png"), fullPage: true }).catch(() => {});
    }
    await writeEvidence(false, {
      debugPort,
      error: error instanceof Error ? error.message : String(error),
    });
    throw error;
  } finally {
    if (browser) {
      await browser.close().catch(() => {});
    }
    await stopProcessTree(tauri);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
