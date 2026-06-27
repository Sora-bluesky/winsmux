import { spawn, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import fs from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import process from "node:process";
import { chromium } from "playwright";

const LAUNCH_PROJECT_ONLY = process.argv.includes("--launch-project-only")
  || process.env.WINSMUX_DESKTOP_E2E_LAUNCH_PROJECT_ONLY === "1";
const RELEASE_POPOUT_ONLY = process.argv.includes("--release-popout-only")
  || process.env.WINSMUX_DESKTOP_E2E_RELEASE_POPOUT_ONLY === "1";
const WORKER_START_ONLY = process.argv.includes("--worker-start-only")
  || process.env.WINSMUX_DESKTOP_E2E_WORKER_START_ONLY === "1";
const COMPOSER_ONLY = process.argv.includes("--composer-only")
  || process.env.WINSMUX_DESKTOP_E2E_COMPOSER_ONLY === "1";
const OUTPUT_DIR = path.join(
  process.cwd(),
  "output",
  "playwright",
  WORKER_START_ONLY
    ? "desktop-worker-start-e2e"
    : COMPOSER_ONLY
    ? "desktop-composer-e2e"
    : RELEASE_POPOUT_ONLY
    ? "desktop-release-popout-e2e"
    : LAUNCH_PROJECT_ONLY
      ? "desktop-launch-arg-e2e"
      : "desktop-pane-e2e",
);
const APP_URL_PATTERN = /localhost:1420|127\.0\.0\.1:1420/;
const CONTROL_PIPE_NAME = "winsmux-control";
const CONTROL_PIPE_TOKEN = process.env.WINSMUX_DESKTOP_E2E_CONTROL_PIPE_TOKEN
  || `winsmux-desktop-e2e-${randomUUID()}`;
const CDP_TIMEOUT_MS = Number.parseInt(process.env.WINSMUX_DESKTOP_E2E_CDP_TIMEOUT_MS || "300000", 10);
const WORKER_UI_MARKER = "WORKER_1_UI_E2E_READY";
const WORKER_ARROW_MARKER = "RAW_ABC";
const WORKER_PASTE_MARKER = "WORKER_PASTE_E2E_READY";
const OPERATOR_MARKER = "OP_E2E_READY";
const OPERATOR_SHELL_READY_MARKER = "OPERATOR_SHELL_E2E_READY";
const COMPOSER_TO_OPERATOR_MARKER = "BTN_E2E_READY";
const COMPOSER_MULTILINE_MARKER = "BTN_MULTI_E2E_READY";
const COMPOSER_ENTER_MARKER = "ENT_E2E_READY";
const COMPOSER_ATTACHMENT_MARKER = "ATT_E2E_READY";
const OPERATOR_TO_WORKER_MARKER = "W2_E2E_READY";
const STOP_AFTER_WORKER_STATUS = process.argv.includes("--stop-after-worker-status")
  || process.env.WINSMUX_DESKTOP_E2E_STOP_AFTER_WORKER_STATUS === "1";

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

function startTauriDev(debugPort, userDataDir, appArgs = []) {
  const args = process.platform === "win32"
    ? ["/c", "npm", "run", "tauri", "--", "dev"]
    : ["run", "tauri", "--", "dev"];
  if (appArgs.length > 0) {
    args.push("--", "--", ...appArgs);
  }
  const child = spawn(process.platform === "win32" ? "cmd.exe" : "npm", args, {
    cwd: process.cwd(),
    env: {
      ...process.env,
      WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${debugPort} --remote-allow-origins=*`,
      WEBVIEW2_USER_DATA_FOLDER: userDataDir,
      WINSMUX_CONTROL_PIPE_TOKEN: CONTROL_PIPE_TOKEN,
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

function startPackagedDesktopApp(debugPort, userDataDir, appArgs = []) {
  const appExe = process.env.WINSMUX_DESKTOP_E2E_APP_EXE
    || path.resolve(process.cwd(), "..", "target", "release", "winsmux-app.exe");
  const child = spawn(appExe, appArgs, {
    cwd: path.resolve(process.cwd(), ".."),
    env: {
      ...process.env,
      WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${debugPort} --remote-allow-origins=*`,
      WEBVIEW2_USER_DATA_FOLDER: userDataDir,
      WINSMUX_CONTROL_PIPE_TOKEN: CONTROL_PIPE_TOKEN,
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

function runWinsmuxCore(args, env = {}) {
  const coreScript = path.resolve(process.cwd(), "..", "scripts", "winsmux-core.ps1");
  const result = spawnSync("pwsh", ["-NoProfile", "-File", coreScript, ...args], {
    cwd: path.resolve(process.cwd(), ".."),
    env: {
      ...process.env,
      ...env,
      NO_COLOR: "1",
    },
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw new Error(`winsmux-core.ps1 ${args.join(" ")} failed (${result.status}): ${result.stdout}\n${result.stderr}`);
  }
  return result.stdout.trim();
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
        const hasAppShell = await page.evaluate(() => Boolean(document.querySelector("#app-shell"))).catch(() => false);
        if (hasAppShell) {
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
  await reloadAppPage(page);
}

async function setActiveProjectDirForUi(page, projectDir) {
  await page.evaluate((value) => {
    localStorage.setItem("winsmux.active-project.v1", value.replace(/\\/g, "/"));
  }, projectDir);
  await reloadAppPage(page);
}

async function reloadAppPage(page) {
  await page.reload({ waitUntil: "domcontentloaded", timeout: 60_000 }).catch(() => {});
  await waitForAppReady(page);
}

async function enableViewportHarness(page) {
  const harnessUrl = new URL(page.url());
  harnessUrl.search = "?viewport-harness=1";
  if (page.url() !== harnessUrl.toString()) {
    await page.goto(harnessUrl.toString(), { waitUntil: "domcontentloaded" });
    await waitForAppReady(page);
  }
  await page.waitForFunction(() => Boolean(window.__winsmuxViewportHarness?.setOperatorStartupInputForTest), undefined, {
    timeout: 30_000,
  });
}

async function configureOperatorShellForTest(page) {
  const startupInput = `pwsh -NoLogo -NoProfile -NoExit -Command "Write-Output '${OPERATOR_SHELL_READY_MARKER}'"\r`;
  await page.evaluate((value) => {
    window.__winsmuxViewportHarness?.setOperatorStartupInputForTest(value);
  }, startupInput);
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

async function readViewportFillMetrics(page) {
  return await page.evaluate(() => ({
    innerWidth: window.innerWidth,
    innerHeight: window.innerHeight,
    screenWidth: window.screen.width,
    screenHeight: window.screen.height,
    bodyWidth: Math.round(document.body.getBoundingClientRect().width),
    bodyHeight: Math.round(document.body.getBoundingClientRect().height),
  }));
}

function assertNoFixedViewportBlank(metrics) {
  if (
    metrics.innerWidth === 1600
    && metrics.innerHeight === 900
    && metrics.screenWidth >= 1800
    && metrics.screenHeight >= 1000
  ) {
    throw new Error(`WebView is stuck at the old test viewport: ${JSON.stringify(metrics)}`);
  }
  if (metrics.bodyWidth < metrics.innerWidth - 48 || metrics.bodyHeight < metrics.innerHeight - 2) {
    throw new Error(`document body should cover the WebView viewport: ${JSON.stringify(metrics)}`);
  }
}

async function readStartupWindowMetrics(page) {
  return await page.evaluate(async () => {
    const tauri = window.__TAURI__;
    const currentWindow = tauri?.window?.getCurrentWindow?.()
      ?? tauri?.webviewWindow?.getCurrentWebviewWindow?.();
    const outerSize = currentWindow && typeof currentWindow.outerSize === "function"
      ? await currentWindow.outerSize().catch((error) => ({ error: error instanceof Error ? error.message : String(error) }))
      : null;
    return {
      title: document.title,
      innerWidth: window.innerWidth,
      innerHeight: window.innerHeight,
      outerWidth: typeof outerSize?.width === "number" ? outerSize.width : null,
      outerHeight: typeof outerSize?.height === "number" ? outerSize.height : null,
      outerSizeError: typeof outerSize?.error === "string" ? outerSize.error : null,
      bodyWidth: Math.round(document.body.getBoundingClientRect().width),
      bodyHeight: Math.round(document.body.getBoundingClientRect().height),
    };
  });
}

function assertVisibleStartupGeometry(metrics) {
  if (metrics.title !== "winsmux") {
    throw new Error(`desktop window title should be stable for UI automation: ${JSON.stringify(metrics)}`);
  }
  if (metrics.innerWidth < 640 || metrics.innerHeight < 480) {
    throw new Error(`desktop window should start at a visible size: ${JSON.stringify(metrics)}`);
  }
  if (
    metrics.outerWidth !== null
    && metrics.outerHeight !== null
    && (metrics.outerWidth < 640 || metrics.outerHeight < 480)
  ) {
    throw new Error(`native desktop window should not restore as a tiny window: ${JSON.stringify(metrics)}`);
  }
  if (metrics.bodyWidth < metrics.innerWidth - 48 || metrics.bodyHeight < metrics.innerHeight - 2) {
    throw new Error(`document body should cover the startup viewport: ${JSON.stringify(metrics)}`);
  }
}

async function waitForNativeWindowResize(page, beforeMetrics, timeoutMs = 12_000) {
  await page.waitForFunction((before) => {
    const body = document.body;
    if (!body) {
      return false;
    }
    const bodyRect = body.getBoundingClientRect();
    const fillsViewport = bodyRect.width >= window.innerWidth - 48
      && bodyRect.height >= window.innerHeight - 2;
    const sizeChanged = Math.abs(window.innerWidth - before.innerWidth) > 2
      || Math.abs(window.innerHeight - before.innerHeight) > 2;
    const alreadyAtScreenLimit = window.screen.width <= before.innerWidth + 2
      || window.screen.height <= before.innerHeight + 80;
    return fillsViewport && (sizeChanged || alreadyAtScreenLimit);
  }, beforeMetrics, {
    timeout: timeoutMs,
  });
}

async function resizeNativeWindowAndReadMetrics(page) {
  const beforeMetrics = await readViewportFillMetrics(page);
  const maximizeAttempt = await page.evaluate(async () => {
    const tauri = window.__TAURI__;
    const currentWindow = tauri.window?.getCurrentWindow?.()
      ?? tauri.webviewWindow?.getCurrentWebviewWindow?.();
    if (!currentWindow) {
      throw new Error("Tauri current window API is unavailable");
    }
    const diagnostics = {
      api: tauri.window?.getCurrentWindow ? "window" : "webviewWindow",
      maximizable: null,
      maximizedBefore: null,
      innerSizeBefore: null,
    };
    diagnostics.maximizable = typeof currentWindow.isMaximizable === "function"
      ? await currentWindow.isMaximizable().catch((error) => `error:${error instanceof Error ? error.message : String(error)}`)
      : "missing";
    diagnostics.maximizedBefore = typeof currentWindow.isMaximized === "function"
      ? await currentWindow.isMaximized().catch((error) => `error:${error instanceof Error ? error.message : String(error)}`)
      : "missing";
    diagnostics.innerSizeBefore = typeof currentWindow.innerSize === "function"
      ? await currentWindow.innerSize().catch((error) => `error:${error instanceof Error ? error.message : String(error)}`)
      : "missing";
    if (typeof currentWindow.setFocus === "function") {
      await currentWindow.setFocus().catch(() => {});
    }
    await currentWindow.maximize();
    return diagnostics;
  });
  try {
    await waitForNativeWindowResize(page, beforeMetrics);
    return {
      ...(await readViewportFillMetrics(page)),
      nativeResizeMode: "maximize",
      nativeResizeDiagnostics: maximizeAttempt,
    };
  } catch (error) {
    const fallback = await page.evaluate(async () => {
      const tauri = window.__TAURI__;
      const currentWindow = tauri.window?.getCurrentWindow?.()
        ?? tauri.webviewWindow?.getCurrentWebviewWindow?.();
      const LogicalSize = tauri.dpi?.LogicalSize ?? tauri.window?.LogicalSize;
      if (!currentWindow || typeof currentWindow.setSize !== "function" || typeof LogicalSize !== "function") {
        throw new Error("Tauri setSize fallback is unavailable");
      }
      if (typeof currentWindow.unmaximize === "function") {
        await currentWindow.unmaximize().catch(() => {});
      }
      const targetWidth = Math.min(1600, Math.max(1280, Math.floor(window.screen.availWidth * 0.72)));
      const targetHeight = Math.min(1000, Math.max(820, Math.floor(window.screen.availHeight * 0.72)));
      await currentWindow.setSize(new LogicalSize(targetWidth, targetHeight));
      return {
        mode: "setSize",
        targetWidth,
        targetHeight,
        maximizeError: error instanceof Error ? error.message : String(error),
      };
    });
    await waitForNativeWindowResize(page, beforeMetrics);
    return {
      ...(await readViewportFillMetrics(page)),
      nativeResizeMode: fallback.mode,
      nativeResizeDiagnostics: {
        ...maximizeAttempt,
        fallback,
      },
    };
  }
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

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function removePtyCommandEchoes(value, marker) {
  const escapedMarker = escapeRegExp(marker);
  return value
    .replace(new RegExp(`Write-Output\\s+['"]${escapedMarker}['"]`, "g"), "")
    .replace(new RegExp(`echo\\s+['"]?${escapedMarker}['"]?`, "g"), "");
}

async function waitForPtyOutputLine(page, paneId, line, timeoutMs = 45_000) {
  const startedAt = Date.now();
  let lastOutput = "";
  while (Date.now() - startedAt < timeoutMs) {
    lastOutput = await capturePty(page, paneId).catch((error) => `capture failed: ${error.message}`);
    const stripped = removePtyCommandEchoes(stripAnsi(lastOutput), line);
    const strippedLines = stripped
      .split(/\r?\n/)
      .map((item) => item.trim());
    if (strippedLines.includes(line) || stripped.includes(line)) {
      return lastOutput;
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`Timed out waiting for output line ${line} in ${paneId}. Last output:\n${lastOutput}`);
}

async function waitForVisibleTerminalText(page, selector, marker, timeoutMs = 15_000) {
  const startedAt = Date.now();
  let lastText = "";
  const compactMarker = marker.replace(/\s+/g, "");
  while (Date.now() - startedAt < timeoutMs) {
    lastText = await page.locator(selector).innerText().catch((error) => `terminal text failed: ${error.message}`);
    if (lastText.includes(marker) || lastText.replace(/\s+/g, "").includes(compactMarker)) {
      return lastText;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`Timed out waiting for visible text ${marker} in ${selector}. Last text:\n${lastText}`);
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
    /トークン予算超過|確認待ち|どう進めますか|running \d+ shell command|listing \d+ director|wrangling|choreographing|spelunking|reticulating|fermenting|caramelizing|unfurling|schlepping|frolicking|cooking|hatching|frosting|tempering|thinking with|still thinking|running stop hooks?|running hooks?|tip:|pasted text|paste again to expand/i
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
  let lastVisibleText = "";
  let readySince = 0;
  while (Date.now() - startedAt < timeoutMs) {
    lastOutput = await capturePty(page, "operator").catch((error) => `capture failed: ${error.message}`);
    lastVisibleText = await page.locator("#operator-terminal").innerText().catch((error) => `terminal text failed: ${error.message}`);
    if (isClaudeOperatorReadyText(lastVisibleText) || isClaudeOperatorReadyText(lastOutput)) {
      readySince = readySince || Date.now();
      if (Date.now() - readySince >= 1_000) {
        return lastOutput;
      }
    } else {
      readySince = 0;
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`Timed out waiting for Claude Code readiness in operator. Last visible text:\n${lastVisibleText}\nLast output:\n${lastOutput}`);
}

async function clickTerminalPanel(page, selector) {
  const panel = page.locator(selector);
  await panel.waitFor({ state: "visible", timeout: 10_000 });
  await panel.scrollIntoViewIfNeeded();
  await panel.click({ timeout: 10_000, force: true });
}

async function startOperatorFromUiAndWaitForClaude(page) {
  await clickTerminalPanel(page, "#operator-terminal-panel");
  return await waitForClaudeOperatorReady(page);
}

async function startOperatorShellFromUiAndWaitForPrompt(page) {
  await clickTerminalPanel(page, "#operator-terminal-panel");
  await waitForPtyOutputLine(page, "operator", OPERATOR_SHELL_READY_MARKER, 30_000);
  return await waitForPtyPrompt(page, "operator", 30_000);
}

async function typeIntoTerminal(page, selector, text) {
  await clickTerminalPanel(page, selector);
  await page.keyboard.type(text, { delay: 8 });
  await page.keyboard.press("Enter");
}

async function typeTerminalDraft(page, selector, text) {
  await clickTerminalPanel(page, selector);
  await page.keyboard.type(text, { delay: 2 });
}

async function pasteIntoTerminal(page, selector, text) {
  await clickTerminalPanel(page, selector);
  let mode;
  if (process.platform === "win32") {
    try {
      mode = await pasteViaTerminalClipboardEvent(page, selector, text);
      await waitForVisibleTerminalText(page, selector, text.includes(WORKER_PASTE_MARKER) ? WORKER_PASTE_MARKER : text, 10_000);
      return `${mode}:windows-webview2`;
    } catch (error) {
      mode = setWindowsClipboardText(text);
      console.warn(`xterm clipboard event paste failed, falling back to ${mode}:`, error);
    }
    await page.keyboard.press("Control+V");
    await waitForVisibleTerminalText(page, selector, text.includes(WORKER_PASTE_MARKER) ? WORKER_PASTE_MARKER : text, 10_000);
    return `${mode}:windows-fallback`;
  } else {
    mode = await setBrowserClipboardText(page, text);
  }
  await page.keyboard.press(process.platform === "darwin" ? "Meta+V" : "Control+V");
  await waitForVisibleTerminalText(page, selector, text.includes(WORKER_PASTE_MARKER) ? WORKER_PASTE_MARKER : text, 10_000);
  return mode;
}

function setWindowsClipboardText(text) {
  const errors = [];
  for (let attempt = 1; attempt <= 12; attempt += 1) {
    const powershellResult = spawnSync("powershell.exe", [
      "-NoLogo",
      "-NoProfile",
      "-Command",
      "Set-Clipboard -Value $env:WINSMUX_E2E_CLIPBOARD",
    ], {
      env: {
        ...process.env,
        WINSMUX_E2E_CLIPBOARD: text,
      },
      encoding: "utf8",
    });
    if (powershellResult.status === 0) {
      return `windows-system-clipboard:set-clipboard:${attempt}`;
    }
    errors.push(`Set-Clipboard(${attempt}): ${powershellResult.stderr || powershellResult.stdout}`);

    const staResult = spawnSync("powershell.exe", [
      "-STA",
      "-NoLogo",
      "-NoProfile",
      "-Command",
      "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Clipboard]::SetText($env:WINSMUX_E2E_CLIPBOARD)",
    ], {
      env: {
        ...process.env,
        WINSMUX_E2E_CLIPBOARD: text,
      },
      encoding: "utf8",
    });
    if (staResult.status === 0) {
      return `windows-system-clipboard:forms:${attempt}`;
    }
    errors.push(`FormsClipboard(${attempt}): ${staResult.stderr || staResult.stdout}`);

    const clipResult = spawnSync("cmd.exe", ["/c", "clip"], {
      input: text,
      encoding: "utf8",
    });
    if (clipResult.status === 0) {
      return `windows-system-clipboard:clip:${attempt}`;
    }
    errors.push(`clip.exe(${attempt}): ${clipResult.stderr || clipResult.stdout}`);

    sleepSync(250);
  }
  throw new Error(`failed to set Windows clipboard after retries: ${errors.slice(-6).join("; ")}`);
}

function sleepSync(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

async function setBrowserClipboardText(page, text) {
  await page.evaluate((value) => navigator.clipboard.writeText(value), text);
  return "browser-clipboard";
}

async function pasteViaTerminalClipboardEvent(page, selector, text) {
  await page.evaluate(
    ({ targetSelector, value }) => {
      const root = document.querySelector(targetSelector);
      const textarea = root?.querySelector("textarea.xterm-helper-textarea");
      if (!(textarea instanceof HTMLTextAreaElement)) {
        throw new Error("xterm helper textarea was not available for paste");
      }
      const data = new DataTransfer();
      data.setData("text/plain", value);
      textarea.dispatchEvent(new ClipboardEvent("paste", {
        bubbles: true,
        cancelable: true,
        clipboardData: data,
      }));
    },
    { targetSelector: selector, value: text },
  );
  return "xterm-clipboard-event";
}

async function clearOperatorInputFromUi(page) {
  await clickTerminalPanel(page, "#operator-terminal-panel");
  await page.keyboard.press("Control+C");
  await page.waitForTimeout(750);
  await waitForClaudeOperatorReady(page);
}

async function startPaneFromUiAndWaitForPrompt(page, paneId, selector) {
  await clickTerminalPanel(page, selector);
  await page.keyboard.press("Enter");
  await waitForPtyPrompt(page, paneId);
}

function escapePwshSingleQuoted(value) {
  return value.replace(/'/g, "''");
}

async function writeOperatorPipeScript(scriptPath) {
  const contractPayload = {
    jsonrpc: "2.0",
    id: "operator-contract",
    method: "desktop.control_plane.contract",
  };
  const payload = {
    jsonrpc: "2.0",
    id: "operator-to-worker",
    method: "pty.write",
    auth: {
      token: CONTROL_PIPE_TOKEN,
    },
    params: {
      paneId: "worker-2",
      data: `Write-Output '${OPERATOR_TO_WORKER_MARKER}'\r`,
    },
  };

  const body = [
    "$ErrorActionPreference = 'Stop'",
    "function Invoke-WinsmuxPipe {",
    "  param([Parameter(Mandatory = $true)][string]$Payload)",
    `  $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', '${CONTROL_PIPE_NAME}', [System.IO.Pipes.PipeDirection]::InOut)`,
    "  $pipe.Connect(5000)",
    "  $encoding = [System.Text.UTF8Encoding]::new($false)",
    "  $writer = [System.IO.StreamWriter]::new($pipe, $encoding)",
    "  $reader = [System.IO.StreamReader]::new($pipe, $encoding)",
    "  $writer.AutoFlush = $true",
    "  try {",
    "    $writer.Write($Payload)",
    "    return $reader.ReadToEnd()",
    "  } finally {",
    "    try { $reader.Dispose() } catch {}",
    "    try { $writer.Dispose() } catch {}",
    "    try { $pipe.Dispose() } catch {}",
    "  }",
    "}",
    `$contractPayload = '${escapePwshSingleQuoted(JSON.stringify(contractPayload))}'`,
    "$contractResponse = Invoke-WinsmuxPipe -Payload $contractPayload",
    "$contract = $contractResponse | ConvertFrom-Json",
    "if ($contract.result.scope -ne 'external_control_pipe') { throw \"unexpected contract scope: $($contract.result.scope)\" }",
    "if ($contract.result.methods -contains 'desktop.editor.read') { throw 'external contract must not advertise desktop.editor.read' }",
    "if (-not ($contract.result.methods -contains 'pty.write')) { throw 'external contract must advertise pty.write' }",
    'Write-Output "PIPE_CONTRACT_OK"',
    `$payload = '${escapePwshSingleQuoted(JSON.stringify(payload))}'`,
    "$response = Invoke-WinsmuxPipe -Payload $payload",
    `Write-Output '${OPERATOR_MARKER}'`,
    'Write-Output "PIPE_RESPONSE:$response"',
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

async function submitWinsmuxComposerCommandWithButton(page, command) {
  await page.fill("#composer-input", command);
  await page.click("#send-btn");
  await page.waitForFunction(() => {
    const input = document.querySelector("#composer-input");
    return input instanceof HTMLTextAreaElement && input.value === "";
  });
  const conversationContainsMessage = await page.locator("#conversation-panel", { hasText: command }).count();
  if (conversationContainsMessage < 1) {
    throw new Error("submitted winsmux command was not rendered in the conversation panel");
  }
}

async function submitComposerShellWithButton(page, command, expectedMarker) {
  await startOperatorShellFromUiAndWaitForPrompt(page);
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
  const output = await waitForPtyOutputLine(page, "operator", expectedMarker, 30_000);
  await waitForPtyPrompt(page, "operator", 30_000);
  return output;
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

async function clickViewMenuItem(page, label, description) {
  let lastMenuText = "";
  for (let attempt = 0; attempt < 2; attempt += 1) {
    await page.click("#menu-view-btn");
    const popover = page.locator("#top-menu-popover");
    await popover.waitFor({ state: "visible", timeout: 10_000 });
    const item = page.locator("#top-menu-popover .top-menu-popover-item", { hasText: label }).first();
    lastMenuText = (await page.locator("#top-menu-popover .top-menu-popover-item").allTextContents().catch(() => []))
      .map((text) => text.replace(/\s+/g, " ").trim())
      .join(" | ");
    await item.waitFor({ state: "visible", timeout: 10_000 });
    await item.click({ force: attempt > 0 });
    if (await popover.isHidden({ timeout: 2_000 }).catch(() => false)) {
      return;
    }
    await page.keyboard.press("Escape").catch(() => {});
  }
  throw new Error(`View menu item did not activate for ${description}: ${lastMenuText}`);
}

async function setWorkerStatusStripFromViewMenu(page, visible) {
  if ((await page.locator("#worker-status-pill-bar").isVisible().catch(() => false)) === visible) {
    return;
  }
  const label = visible
    ? /Show Worker Details|Show worker status|ワーカー詳細情報を表示|ワーカー状態を表示/
    : /Hide Worker Details|Hide worker status|ワーカー詳細情報を隠す|ワーカー状態を隠す/;
  let lastError;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    await clickViewMenuItem(page, label, visible ? "show worker status" : "hide worker status");
    try {
      await page.locator("#worker-status-pill-bar").waitFor({ state: visible ? "visible" : "hidden", timeout: 10_000 });
      return;
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError;
}

async function setAgentVaultPanelFromViewMenu(page, visible) {
  const contextVisible = await page.locator("#context-panel").isVisible().catch(() => false);
  const vaultVisible = contextVisible && (await page.locator("#agent-vault-panel").isVisible().catch(() => false));
  if (vaultVisible === visible) {
    return;
  }
  const label = visible ? /Show Agent Vault|Agent Vault を表示/ : /Hide Agent Vault|Agent Vault を隠す/;
  await clickViewMenuItem(page, label, visible ? "show Agent Vault" : "hide Agent Vault");
  await page.locator("#context-panel").waitFor({ state: visible ? "visible" : "hidden", timeout: 10_000 });
  if (visible) {
    await page.locator("#agent-vault-panel").waitFor({ state: "visible", timeout: 10_000 });
  }
}

async function ensureAgentVaultOpen(page) {
  await setAgentVaultPanelFromViewMenu(page, true);
  await page.locator("#agent-vault-panel").waitFor({ state: "visible", timeout: 10_000 });
}

async function ensureAgentVaultHasCards(page) {
  if ((await page.locator(".agent-vault-card").count()) > 0) {
    return;
  }
  const projectFilter = page.locator("#agent-vault-project-filter");
  if ((await projectFilter.getAttribute("aria-pressed").catch(() => "false")) === "true") {
    await projectFilter.click();
  }
  await page.waitForFunction(
    () => document.querySelectorAll(".agent-vault-card").length > 0,
    undefined,
    { timeout: 20_000 },
  );
}

async function exerciseAgentVault(page) {
  await ensureAgentVaultOpen(page);
  await page.locator("#agent-vault-ring").waitFor({ state: "visible", timeout: 10_000 });
  await page.locator("#agent-vault-search").waitFor({ state: "visible", timeout: 10_000 });
  await page.locator("#agent-vault-provider-filters").waitFor({ state: "visible", timeout: 10_000 });
  await page.locator("#agent-vault-feed").waitFor({ state: "visible", timeout: 10_000 });

  const initialProviderFilterLabels = await page.locator("#agent-vault-provider-filters button").evaluateAll((buttons) =>
    buttons.map((button) => button.textContent?.trim() ?? ""),
  );
  for (const expectedLabel of ["Claude Code", "Codex", "OpenCode"]) {
    if (!initialProviderFilterLabels.some((label) => label.includes(expectedLabel))) {
      throw new Error(`Agent Vault provider filter missing ${expectedLabel}: ${JSON.stringify(initialProviderFilterLabels)}`);
    }
  }
  const workspaceOptions = await page.locator("#agent-vault-workspace-filter option").evaluateAll((options) =>
    options.map((option) => ({ value: option.value, text: option.textContent?.trim() ?? "" })),
  );
  if (!workspaceOptions.some((option) => option.value === "all" && /All folders|すべてのフォルダー/.test(option.text))) {
    throw new Error(`Agent Vault workspace folder filter is missing the all-folders option: ${JSON.stringify(workspaceOptions)}`);
  }
  await page.evaluate(() => {
    const select = document.querySelector("#agent-vault-workspace-filter");
    if (!(select instanceof HTMLSelectElement)) {
      throw new Error("Agent Vault workspace filter is unavailable");
    }
    select.value = "all";
    select.dispatchEvent(new Event("change", { bubbles: true }));
  });
  await page.locator("#agent-vault-project-filter[aria-pressed='false']").waitFor({ timeout: 10_000 });
  const allWorkspacePreference = await page.evaluate(() => {
    const rawValue = localStorage.getItem("winsmux.agent-vault.preferences.v1");
    return rawValue ? JSON.parse(rawValue).projectOnly : null;
  });
  if (allWorkspacePreference !== false) {
    throw new Error(`Selecting all Agent Vault workspaces should clear the project-only preference: ${JSON.stringify(allWorkspacePreference)}`);
  }
  if (workspaceOptions.length > 1) {
    await page.selectOption("#agent-vault-workspace-filter", workspaceOptions[1].value);
    await page.waitForFunction(
      () => document.querySelectorAll(".agent-vault-card").length > 0,
      undefined,
      { timeout: 10_000 },
    );
    await page.selectOption("#agent-vault-workspace-filter", "all");
  }

  await ensureAgentVaultHasCards(page);
  await page.evaluate(() => {
    const select = document.querySelector("#agent-vault-workspace-filter");
    if (!(select instanceof HTMLSelectElement)) {
      throw new Error("Agent Vault workspace filter is unavailable");
    }
    const staleOption = document.createElement("option");
    staleOption.value = "__winsmux_stale_workspace__";
    staleOption.textContent = "Stale workspace";
    select.appendChild(staleOption);
    select.value = staleOption.value;
    select.dispatchEvent(new Event("change", { bubbles: true }));
  });
  await page.waitForFunction(
    () => {
      const select = document.querySelector("#agent-vault-workspace-filter");
      return select instanceof HTMLSelectElement
        && select.value === "all"
        && document.querySelectorAll(".agent-vault-card").length > 0
        && !document.querySelector(".agent-vault-empty");
    },
    undefined,
    { timeout: 10_000 },
  );
  const providerFilterLabels = await page.locator("#agent-vault-provider-filters button").evaluateAll((buttons) =>
    buttons.map((button) => button.textContent?.trim() ?? ""),
  );
  const visibleCardCount = await page.locator(".agent-vault-card").count();
  const allProviderCount = Number((providerFilterLabels[0]?.match(/(\d+)\s*$/) ?? [])[1] ?? "0");
  if (allProviderCount < visibleCardCount) {
    throw new Error(`Agent Vault provider counts should include visible cards: ${JSON.stringify({ providerFilterLabels, visibleCardCount })}`);
  }
  const firstTitle = (await page.locator(".agent-vault-card-title").first().innerText()).trim();
  const searchTerm = firstTitle.split(/\s+/)[0] || firstTitle;
  await page.fill("#agent-vault-search", "__winsmux_no_agent_vault_match__");
  await page.locator(".agent-vault-empty", { hasText: /No sessions match|一致するセッション/ }).waitFor({ state: "visible", timeout: 10_000 });
  await page.fill("#agent-vault-search", searchTerm);
  await page.waitForFunction(
    () => document.querySelectorAll(".agent-vault-card").length > 0,
    undefined,
    { timeout: 10_000 },
  );
  await page.fill("#agent-vault-search", "");
  await ensureAgentVaultHasCards(page);

  const projectFilter = page.locator("#agent-vault-project-filter");
  const pressedBefore = await projectFilter.getAttribute("aria-pressed");
  await projectFilter.click();
  const pressedAfter = await projectFilter.getAttribute("aria-pressed");
  if (pressedBefore === pressedAfter) {
    throw new Error("Agent Vault project filter did not toggle aria-pressed");
  }
  const projectOnlyPreference = await page.evaluate(() => {
    const rawValue = localStorage.getItem("winsmux.agent-vault.preferences.v1");
    return rawValue ? JSON.parse(rawValue).projectOnly : null;
  });
  if (projectOnlyPreference !== (pressedAfter === "true")) {
    throw new Error(`Agent Vault project filter preference was not persisted: ${projectOnlyPreference}`);
  }
  await projectFilter.click();

  const allFilter = page.locator("#agent-vault-provider-filters button").first();
  await allFilter.click();
  const allPressed = await allFilter.getAttribute("aria-pressed");
  if (allPressed !== "true") {
    throw new Error("Agent Vault all-provider filter did not become active");
  }
  await ensureAgentVaultHasCards(page);

  const firstProviderHeading = page.locator(".agent-vault-provider-heading").first();
  await firstProviderHeading.click();
  const collapsedExpandedState = await page.locator(".agent-vault-provider-heading").first().getAttribute("aria-expanded");
  const collapsedPreference = await page.evaluate(() => {
    const rawValue = localStorage.getItem("winsmux.agent-vault.preferences.v1");
    return rawValue ? JSON.parse(rawValue).collapsedProviderIds : null;
  });
  if (collapsedExpandedState !== "false" || !Array.isArray(collapsedPreference) || collapsedPreference.length < 1) {
    throw new Error(`Agent Vault provider collapse state was not persisted: ${JSON.stringify({ collapsedExpandedState, collapsedPreference })}`);
  }
  await page.locator(".agent-vault-provider-heading").first().click();
  await ensureAgentVaultHasCards(page);

  const layoutMetrics = await page.locator("#agent-vault-panel").evaluate((panel) => {
    const rect = panel.getBoundingClientRect();
    const context = document.querySelector("#context-panel")?.getBoundingClientRect();
    const search = document.querySelector("#agent-vault-search");
    const workspaceFilter = document.querySelector("#agent-vault-workspace-filter");
    const list = document.querySelector("#agent-vault-session-list");
    return {
      panelWidth: Math.round(rect.width),
      panelHeight: Math.round(rect.height),
      panelLeft: Math.round(rect.left),
      panelRight: Math.round(rect.right),
      contextLeft: context ? Math.round(context.left) : 0,
      contextRight: context ? Math.round(context.right) : 0,
      viewportWidth: window.innerWidth,
      containedByContext: context
        ? rect.left >= context.left - 1 && rect.right <= context.right + 1
        : false,
      searchFits: search instanceof HTMLElement ? search.scrollWidth <= search.clientWidth + 1 : false,
      workspaceFilterFits: workspaceFilter instanceof HTMLElement ? workspaceFilter.scrollWidth <= workspaceFilter.clientWidth + 1 : false,
      listWidth: list instanceof HTMLElement ? Math.round(list.getBoundingClientRect().width) : 0,
    };
  });
  if (layoutMetrics.panelWidth < 240 || layoutMetrics.panelHeight < 160 || !layoutMetrics.searchFits || !layoutMetrics.workspaceFilterFits) {
    throw new Error(`Agent Vault right sidebar layout is clipped: ${JSON.stringify(layoutMetrics)}`);
  }
  if (!layoutMetrics.containedByContext) {
    throw new Error(`Agent Vault should stay in the right context sidebar: ${JSON.stringify(layoutMetrics)}`);
  }

  const ringText = (await page.locator("#agent-vault-ring").innerText()).trim();
  const feedText = (await page.locator("#agent-vault-feed").innerText()).trim();
  if (!ringText || !feedText) {
    throw new Error(`Agent Vault notification ring or feed is empty: ring=${ringText} feed=${feedText}`);
  }

  const duplicateRestoreTargetId = "pane-worker-5";
  await closePtyIfExists(page, "worker-5");
  await page.waitForFunction(
    () => /not started|未起動/i.test(document.querySelector("#pane-worker-5 .pane-meta")?.textContent ?? ""),
    undefined,
    { timeout: 10_000 },
  );
  await page.evaluate((targetId) => {
    const cardElement = document.querySelector(".agent-vault-card");
    const targetElement = document.getElementById(targetId);
    if (!(cardElement instanceof HTMLElement) || !(targetElement instanceof HTMLElement)) {
      throw new Error("Agent Vault duplicate restore source or target pane was not found");
    }
    const sessionId = cardElement.dataset.sessionId;
    if (!sessionId) {
      throw new Error("Agent Vault duplicate restore source has no session id");
    }
    const dispatchDrop = () => {
      const dataTransfer = new DataTransfer();
      dataTransfer.setData("application/x-winsmux-agent-vault-session", sessionId);
      cardElement.dispatchEvent(new DragEvent("dragstart", { bubbles: true, cancelable: true, dataTransfer }));
      targetElement.dispatchEvent(new DragEvent("dragover", { bubbles: true, cancelable: true, dataTransfer }));
      targetElement.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer }));
    };
    dispatchDrop();
    dispatchDrop();
  }, duplicateRestoreTargetId);
  await page.waitForFunction(
    () => /already starting|復元を開始中/.test(document.querySelector("#agent-vault-drop-status")?.textContent ?? ""),
    undefined,
    { timeout: 15_000 },
  );
  const duplicateRestoreGuardStatus = (await page.locator("#agent-vault-drop-status").innerText()).trim();
  await page.waitForFunction(
    () => {
      const status = document.querySelector("#agent-vault-drop-status")?.textContent ?? "";
      return /Restoring|復元/.test(status) && /worker-5/.test(status);
    },
    undefined,
    { timeout: 30_000 },
  );

  await page.waitForFunction(
    () => Boolean(document.querySelector(".agent-vault-card") && document.querySelector("#pane-worker-6")),
    undefined,
    { timeout: 10_000 },
  );
  await page.evaluate(() => {
    const cardElement = document.querySelector(".agent-vault-card");
    const targetElement = document.querySelector("#pane-worker-6");
    if (!(cardElement instanceof HTMLElement) || !(targetElement instanceof HTMLElement)) {
      throw new Error("Agent Vault drag source or target pane was not found");
    }
    const dataTransfer = new DataTransfer();
    const sessionId = cardElement.dataset.sessionId;
    if (sessionId) {
      dataTransfer.setData("application/x-winsmux-agent-vault-session", sessionId);
    }
    cardElement.dispatchEvent(new DragEvent("dragstart", { bubbles: true, cancelable: true, dataTransfer }));
    targetElement.dispatchEvent(new DragEvent("dragover", { bubbles: true, cancelable: true, dataTransfer }));
    targetElement.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer }));
  });
  await page.waitForFunction(
    () => {
      const status = document.querySelector("#agent-vault-drop-status")?.textContent ?? "";
      return /Restoring|復元/.test(status) && /worker-6/.test(status);
    },
    undefined,
    { timeout: 15_000 },
  );
  await page.locator("#conversation-panel", { hasText: "Session restore started" }).waitFor({ state: "visible", timeout: 15_000 });
  const restoreStatus = (await page.locator("#agent-vault-drop-status").innerText()).trim();

  return {
    providerFilterLabels,
    workspaceOptions,
    firstTitle,
    projectOnlyPreference,
    collapsedPreference,
    ringText,
    feedText,
    duplicateRestoreGuardStatus,
    restoreStatus,
    layoutMetrics,
  };
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
  if (contract?.scope !== "internal_desktop_json_rpc" || contract?.transport !== "tauri_invoke_desktop_json_rpc") {
    throw new Error(`desktop internal contract should identify the Tauri invoke surface: ${JSON.stringify(contract)}`);
  }
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
  const popoutVisualState = await popout.evaluate(() => {
    const htmlBackground = getComputedStyle(document.documentElement).backgroundColor;
    const bodyBackground = getComputedStyle(document.body).backgroundColor;
    const shell = document.querySelector("#app-shell");
    const editor = document.querySelector("#editor-surface");
    return {
      htmlBackground,
      bodyBackground,
      shellVisible: shell instanceof HTMLElement && !shell.hidden,
      editorVisible: editor instanceof HTMLElement && !editor.hidden,
      title: document.title,
    };
  });
  if (
    !popoutVisualState.shellVisible
    || !popoutVisualState.editorVisible
    || popoutVisualState.htmlBackground === "rgb(255, 255, 255)"
    || popoutVisualState.bodyBackground === "rgb(255, 255, 255)"
  ) {
    throw new Error(`popout editor should render on a dark initialized surface: ${JSON.stringify(popoutVisualState)}`);
  }
  await popout.screenshot({ path: path.join(OUTPUT_DIR, "popout-editor-ready.png"), fullPage: true });
  const popoutLabel = await popout.evaluate(() => window.__TAURI__.webviewWindow.getCurrentWebviewWindow().label);
  await popout.close({ runBeforeUnload: false }).catch(() => {});
  await page.locator("#workspace").waitFor({ state: "visible", timeout: 10_000 });

  return {
    apiSurface,
    contractMethods: contract.methods.length,
    editorLineCount: editorFile.line_count,
    explorerEntryCount: explorer.entries.length,
    popoutLabel,
    popoutVisualState,
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
  await ensureOutputDir();
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

async function exerciseWorkerStartButton(page) {
  const tempProjectDir = path.join(OUTPUT_DIR, "worker-start-project");
  await fs.rm(tempProjectDir, { recursive: true, force: true });
  await fs.mkdir(tempProjectDir, { recursive: true });
  const tempWinsmuxDir = path.join(tempProjectDir, ".winsmux");
  await fs.mkdir(tempWinsmuxDir, { recursive: true });
  const markerScriptPath = path.join(tempProjectDir, "desktop-worker-launch-marker.ps1");
  await fs.writeFile(
    markerScriptPath,
    [
      "Write-Output 'DESKTOP_WORKER_START_OK worker-1'",
      "Write-Output ($args -join ' ')",
      "",
    ].join("\n"),
    "utf8",
  );
  await fs.writeFile(
    path.join(tempWinsmuxDir, "provider-capabilities.json"),
    JSON.stringify({
      version: 1,
      providers: {
        codex: {
          adapter: "codex",
          command: markerScriptPath,
          prompt_transports: ["argv"],
          auth_modes: ["default"],
          model_sources: ["provider-default", "operator-override"],
          reasoning_efforts: ["provider-default", "high"],
          credential_requirements: "none",
          execution_backend: "local-cli",
          analysis_posture: "write",
        },
      },
    }, null, 2),
    "utf8",
  );
  await fs.writeFile(
    path.join(tempProjectDir, ".winsmux.yaml"),
    [
      "agent: codex",
      "model: gpt-5.4",
      "agent-slots:",
      "  - slot-id: worker-1",
      "    runtime-role: worker",
      "    worker-backend: local",
      "    agent: codex",
      "    model: gpt-5.4",
      "    model-source: operator-override",
      "    reasoning-effort: high",
      "    worktree-mode: managed",
      "",
    ].join("\n"),
    "utf8",
  );
  runWinsmuxCore(
    [
      "workers",
      "heartbeat",
      "mark",
      "worker-1",
      "--run-id",
      "desktop-heartbeat-e2e",
      "--state",
      "approval_waiting",
      "--message",
      "desktop e2e approval wait",
      "--json",
      "--project-dir",
      tempProjectDir,
    ],
    { WINSMUX_TEST_NOW_UTC: "2026-05-16T00:00:00Z" },
  );
  const workerStatus = JSON.parse(runWinsmuxCore([
    "workers",
    "status",
    "worker-1",
    "--json",
    "--project-dir",
    tempProjectDir,
  ]));
  const workerRow = Array.isArray(workerStatus?.workers)
    ? workerStatus.workers.find((row) => row.slot_id === "worker-1" || row.slot === "worker-1" || row.pane_id === "worker-1")
    : null;
  const launchCommand = String(workerRow?.launch_command ?? "");
  if (workerRow?.launch_command_status !== "available") {
    throw new Error(`worker-1 launch command was not available:\n${JSON.stringify(workerRow, null, 2)}`);
  }
  if (!launchCommand.includes("model=gpt-5.4") || !launchCommand.includes("model_reasoning_effort=high")) {
    throw new Error(`worker-1 launch command did not include the selected model and effort:\n${launchCommand}`);
  }

  await setActiveProjectDirForUi(page, tempProjectDir);
  await closePtyIfExists(page, "worker-1");
  await setWorkbenchLayout(page, "focus");
  await page.selectOption("#focused-pane-select", "worker-1");
  await setWorkbenchLayout(page, "3x2");
  await setWorkerStatusStripFromViewMenu(page, true);
  await page.locator('.worker-status-detail-strip[data-worker-status-detail="worker-1"] .worker-status-pill-chip[data-status-field="launch"]', { hasText: "launch:not_launched" }).waitFor({ state: "visible", timeout: 60_000 });
  await page.locator('.worker-status-detail-strip[data-worker-status-detail="worker-1"] .worker-status-pill-chip[data-status-field="heartbeat"]', { hasText: "hb:none" }).waitFor({ state: "visible", timeout: 60_000 });
  await page.click("#start-worker-btn");
  await page.locator("#conversation-panel", { hasText: "Worker launch approval" }).waitFor({ state: "visible", timeout: 60_000 });
  await page.locator("#conversation-panel", { hasText: "Worker start accepted" }).waitFor({ state: "visible", timeout: 60_000 });
  const workerOutput = await waitForPtyOutput(page, "worker-1", "DESKTOP_WORKER_START_OK", 60_000);
  const compactWorkerOutput = stripAnsi(workerOutput).replace(/\s+/g, "");
  if (!compactWorkerOutput.includes("DESKTOP_WORKER_START_OK")) {
    throw new Error(`worker pane did not run the launch command:\n${workerOutput.slice(-1_200)}`);
  }
  const text = await page.locator("#conversation-panel").innerText().catch(() => "");
  return {
    conversationTail: text.slice(-1_200),
    launchCommand,
    workerOutput: workerOutput.slice(-1_200),
  };
}

async function closeAllWorkerPtys(page) {
  for (let index = 1; index <= 6; index += 1) {
    await closePtyIfExists(page, `worker-${index}`);
  }
}

async function writeMinimalHarnessBenchmarkPack(projectDir) {
  const packDir = path.join(projectDir, "tasks", "cli-bakeoff", "v1");
  await fs.mkdir(packDir, { recursive: true });
  await fs.writeFile(
    path.join(packDir, "WB-001-desktop-worker-pane-launch-diagnosis.md"),
    [
      "# WB-001: Desktop worker-pane launch diagnosis",
      "",
      "Return BAKEOFF_ROUND_A_BEGIN, a concise diagnosis, and BAKEOFF_ROUND_A_END.",
      "",
    ].join("\n"),
    "utf8",
  );
  await fs.writeFile(
    path.join(packDir, "benchmark-pack.json"),
    JSON.stringify({
      version: 1,
      pack_id: "winsmux-cli-bakeoff-v1",
      title: "desktop pane e2e benchmark pack",
      default_timeout_seconds: 3600,
      tasks: [
        {
          task_id: "WB-001",
          title: "Desktop worker-pane launch diagnosis",
          packet_path: "WB-001-desktop-worker-pane-launch-diagnosis.md",
          timeout_seconds: 3600,
        },
      ],
    }, null, 2),
    "utf8",
  );
}

async function exerciseOperatorCommandStartsAllWorkerPanes(page, options = {}) {
  const tempProjectDir = path.join(OUTPUT_DIR, options.projectName ?? "operator-start-all-workers-project");
  await fs.rm(tempProjectDir, { recursive: true, force: true });
  await fs.mkdir(tempProjectDir, { recursive: true });
  const tempWinsmuxDir = path.join(tempProjectDir, ".winsmux");
  await fs.mkdir(tempWinsmuxDir, { recursive: true });
  await writeMinimalHarnessBenchmarkPack(tempProjectDir);
  const markerScriptPath = path.join(tempProjectDir, options.scriptName ?? "operator-start-all-worker-marker.ps1");
  const startMarker = options.startMarker ?? "DESKTOP_ALL_WORKERS_START_OK";
  await fs.writeFile(
    markerScriptPath,
    (options.scriptLines ?? [
      `Write-Output '${startMarker}'`,
      "Write-Output ($args -join ' ')",
      "",
    ]).join("\n"),
    "utf8",
  );
  await fs.writeFile(
    path.join(tempWinsmuxDir, "provider-capabilities.json"),
    JSON.stringify({
      version: 1,
      providers: {
        codex: {
          adapter: "codex",
          command: markerScriptPath,
          prompt_transports: ["argv"],
          auth_modes: ["default"],
          model_sources: ["provider-default", "operator-override"],
          reasoning_efforts: ["provider-default", "high"],
          credential_requirements: "none",
          execution_backend: "local-cli",
          analysis_posture: "write",
        },
      },
    }, null, 2),
    "utf8",
  );
  const slotLines = [];
  for (let index = 1; index <= 6; index += 1) {
    slotLines.push(
      `  - slot-id: worker-${index}`,
      "    runtime-role: worker",
      "    worker-backend: local",
      "    agent: codex",
      `    model: gpt-5.4-worker-${index}`,
      "    model-source: operator-override",
      "    reasoning-effort: high",
      "    worktree-mode: managed",
    );
  }
  await fs.writeFile(
    path.join(tempProjectDir, ".winsmux.yaml"),
    [
      "agent: codex",
      "model: gpt-5.4",
      "agent-slots:",
      ...slotLines,
      "",
    ].join("\n"),
    "utf8",
  );

  await setActiveProjectDirForUi(page, tempProjectDir);
  await setWorkbenchLayout(page, "3x2");
  await closeAllWorkerPtys(page);
  await submitWinsmuxComposerCommandWithButton(page, "winsmux workers start all");
  await page.locator("#conversation-panel", { hasText: "All worker panes were started" }).waitFor({ state: "visible", timeout: 60_000 });
  const outputs = {};
  for (let index = 1; index <= 6; index += 1) {
    const paneId = `worker-${index}`;
    const output = await waitForPtyOutput(page, paneId, startMarker, 60_000);
    outputs[paneId] = output.slice(-800);
  }
  return outputs;
}

async function exerciseOperatorBenchmarkReadyCheckBlocksOnMcpWarning(page) {
  await exerciseOperatorCommandStartsAllWorkerPanes(page, {
    projectName: "operator-ready-check-mcp-warning-project",
    scriptName: "operator-start-all-worker-mcp-warning.ps1",
    scriptLines: [
      "Write-Output 'DESKTOP_ALL_WORKERS_START_OK'",
      "Write-Output 'MCP startup incomplete (failed: figma)'",
      "Write-Output '3 MCP servers need authentication - run /mcp'",
      "Write-Output ($args -join ' ')",
      "",
    ],
  });
  await submitWinsmuxComposerCommandWithButton(page, "winsmux benchmark ready-check");
  await page.locator("#conversation-panel", { hasText: "Benchmark start readiness blocked" }).waitFor({ state: "visible", timeout: 60_000 });
  const text = await page.locator("#conversation-panel").textContent();
  const metaState = await page.evaluate(() => {
    return Array.from(document.querySelectorAll(".pane")).map((pane) => {
      const title = pane.querySelector(".pane-label")?.textContent?.trim() ?? "";
      const meta = pane.querySelector(".pane-meta")?.textContent?.trim() ?? "";
      const metaTitle = pane.querySelector(".pane-meta")?.getAttribute("title") ?? "";
      return { title, meta, metaTitle };
    });
  });
  const combined = `${text ?? ""}\n${JSON.stringify(metaState)}`;
  if (!combined.includes("MCP authentication required")) {
    throw new Error(`ready-check did not report the MCP blocker:\n${combined.slice(-1_800)}`);
  }
  return {
    conversationTail: (text ?? "").slice(-1_200),
    metaState,
  };
}

async function exerciseOperatorBenchmarkDispatchBlocksOnMcpWarning(page) {
  await exerciseOperatorCommandStartsAllWorkerPanes(page, {
    projectName: "operator-dispatch-mcp-warning-project",
    scriptName: "operator-dispatch-mcp-warning.ps1",
    scriptLines: [
      "Write-Output 'DESKTOP_ALL_WORKERS_START_OK'",
      "Write-Output 'MCP startup incomplete (failed: figma)'",
      "Write-Output '3 MCP servers need authentication - run /mcp'",
      "Write-Output ($args -join ' ')",
      "",
    ],
  });
  await submitWinsmuxComposerCommandWithButton(page, "winsmux benchmark dispatch WB-001");
  await page.locator("#conversation-panel", { hasText: "Benchmark dispatch blocked" }).waitFor({ state: "visible", timeout: 60_000 });
  const text = await page.locator("#conversation-panel").textContent();
  const outputs = {};
  for (let index = 1; index <= 6; index += 1) {
    const paneId = `worker-${index}`;
    outputs[paneId] = (await capturePty(page, paneId).catch(() => "")).slice(-1_200);
  }
  const combined = `${text ?? ""}\n${JSON.stringify(outputs)}`;
  if (!combined.includes("MCP authentication required")) {
    throw new Error(`benchmark dispatch did not report the MCP blocker:\n${combined.slice(-1_800)}`);
  }
  if (combined.includes("WINSMUX_BENCH_TASK_PACKET")) {
    throw new Error(`benchmark dispatch sent a task packet despite MCP warnings:\n${combined.slice(-1_800)}`);
  }
  return {
    conversationTail: (text ?? "").slice(-1_200),
    outputs,
  };
}

async function exerciseOperatorBenchmarkReadyCheck(page) {
  await submitWinsmuxComposerCommandWithButton(page, "winsmux benchmark ready-check");
  await page.locator("#conversation-panel", { hasText: "Benchmark start readiness confirmed" }).waitFor({ state: "visible", timeout: 60_000 });
  const outputs = {};
  for (let index = 1; index <= 6; index += 1) {
    const paneId = `worker-${index}`;
    const output = await waitForPtyOutputLine(page, paneId, `WINSMUX_BENCH_READY_CHECK ${paneId}`, 60_000);
    outputs[paneId] = output.slice(-800);
  }
  return outputs;
}

async function exerciseOperatorBenchmarkDispatch(page) {
  await submitWinsmuxComposerCommandWithButton(page, "winsmux benchmark dispatch WB-001");
  await page.locator("#conversation-panel", { hasText: "Benchmark task packet dispatched" }).waitFor({ state: "visible", timeout: 60_000 });
  const outputs = {};
  for (let index = 1; index <= 6; index += 1) {
    const paneId = `worker-${index}`;
    const output = await waitForPtyOutputLine(page, paneId, `WINSMUX_BENCH_TASK_PACKET WB-001 ${paneId}`, 60_000);
    outputs[paneId] = output.slice(-800);
  }
  const text = await page.locator("#conversation-panel").textContent();
  if (!(text ?? "").includes("sha256")) {
    throw new Error(`benchmark dispatch did not record the packet hash:\n${(text ?? "").slice(-1_200)}`);
  }
  return {
    conversationTail: (text ?? "").slice(-1_200),
    outputs,
  };
}

async function main() {
  await ensureOutputDir();
  const debugPort = await getAvailablePort();
  const userDataDir = path.join(OUTPUT_DIR, `webview2-user-data-${Date.now()}`);
  const launchProjectDir = path.join(OUTPUT_DIR, "launch-project");
  const scriptPath = path.join(OUTPUT_DIR, "operator-to-worker.ps1");
  const attachmentPath = path.join(OUTPUT_DIR, "composer-attachment.txt");
  if (LAUNCH_PROJECT_ONLY) {
    await fs.mkdir(launchProjectDir, { recursive: true });
  }
  await writeOperatorPipeScript(scriptPath);
  await fs.writeFile(attachmentPath, "desktop composer attachment e2e\n", "utf8");

  let browser;
  let page;
  const tauri = RELEASE_POPOUT_ONLY
    ? startPackagedDesktopApp(debugPort, userDataDir)
    : startTauriDev(
      debugPort,
      userDataDir,
      LAUNCH_PROJECT_ONLY ? ["--project-dir", launchProjectDir] : [],
    );

  try {
    await runStep("wait for WebView2 remote debugging", async () => {
      await waitForCdp(debugPort, tauri, Number.isFinite(CDP_TIMEOUT_MS) ? CDP_TIMEOUT_MS : 300000);
      return { debugPort };
    });

    browser = await chromium.connectOverCDP(`http://127.0.0.1:${debugPort}`);
    page = await resolveAppPage(browser);
    attachPageErrorCapture(page);

    await runStep("wait for desktop app chrome", async () => {
      await waitForAppReady(page);
      return { url: page.url() };
    });

    if (COMPOSER_ONLY) {
      await runStep("composer-only surface is visible", async () => {
        await page.locator("#operator-terminal-panel").waitFor({ state: "visible" });
        await page.locator("#composer").waitFor({ state: "visible" });
        await page.locator("#composer-input").waitFor({ state: "visible" });
        await page.locator("#send-btn").waitFor({ state: "visible" });
        return await readViewportFillMetrics(page);
      });
    } else {
      await runStep("desktop main window starts at a visible size", async () => {
        const metrics = await readStartupWindowMetrics(page);
        assertVisibleStartupGeometry(metrics);
        return metrics;
      });
    }

    if (WORKER_START_ONLY) {
      await resetAppState(page);
      await enableViewportHarness(page);
      await runStep("worker start button launches the selected Tauri worker pane", async () => {
        return await exerciseWorkerStartButton(page);
      });
      await runStep("operator benchmark ready-check stops on worker MCP warnings", async () => {
        return await exerciseOperatorBenchmarkReadyCheckBlocksOnMcpWarning(page);
      });
      await runStep("operator benchmark dispatch stops on worker MCP warnings", async () => {
        return await exerciseOperatorBenchmarkDispatchBlocksOnMcpWarning(page);
      });
      await runStep("operator composer command starts all worker panes", async () => {
        return await exerciseOperatorCommandStartsAllWorkerPanes(page);
      });
      await runStep("operator benchmark ready-check verifies all worker write paths", async () => {
        return await exerciseOperatorBenchmarkReadyCheck(page);
      });
      await runStep("operator benchmark dispatch writes the same task packet to all workers", async () => {
        return await exerciseOperatorBenchmarkDispatch(page);
      });
      await ensureOutputDir();
      await page.screenshot({ path: path.join(OUTPUT_DIR, "desktop-worker-start-e2e-success.png"), fullPage: true });
      await writeEvidence(true, { debugPort, mode: "worker-start-only" });
      process.stdout.write(`[desktop-pane-e2e] PASS worker-start-only evidence=${path.join(OUTPUT_DIR, "desktop-pane-e2e.json")}\n`);
      return;
    }

    if (RELEASE_POPOUT_ONLY) {
      await resetAppState(page);
      await runStep("release exe opens editor popout without a white screen", async () => {
        return await exerciseTauriNativeSurface(page, browser);
      });
      await ensureOutputDir();
      await page.screenshot({ path: path.join(OUTPUT_DIR, "desktop-release-popout-e2e-success.png"), fullPage: true });
      await writeEvidence(true, { debugPort, mode: "release-popout-only" });
      process.stdout.write(`[desktop-pane-e2e] PASS release-popout-only evidence=${path.join(OUTPUT_DIR, "desktop-pane-e2e.json")}\n`);
      return;
    }

    if (LAUNCH_PROJECT_ONLY) {
      await runStep("launch project argument selects the active project", async () => {
        const expectedProjectDir = launchProjectDir.replace(/\\/g, "/").replace(/\/+$/, "");
        const nativeInitialProjectDir = await page.evaluate(async () => {
          try {
            return await window.__TAURI__?.core?.invoke?.("desktop_initial_project_dir");
          } catch (error) {
            return { error: error instanceof Error ? error.message : String(error) };
          }
        });
        try {
          await page.waitForFunction((expected) => {
            const activeProjectDir = localStorage.getItem("winsmux.active-project.v1");
            const sessions = JSON.parse(localStorage.getItem("winsmux.project-sessions.v1") || "[]");
            return activeProjectDir === expected
              && Array.isArray(sessions)
              && sessions.some((entry) => entry?.path === expected);
          }, expectedProjectDir, { timeout: 15_000 });
        } catch (error) {
          const state = await page.evaluate(() => ({
            activeProjectDir: localStorage.getItem("winsmux.active-project.v1"),
            sessions: JSON.parse(localStorage.getItem("winsmux.project-sessions.v1") || "[]"),
          }));
          throw new Error(`launch project state did not settle: ${JSON.stringify({ expectedProjectDir, nativeInitialProjectDir, ...state })}`);
        }
        const state = await page.evaluate(() => {
          const activeProjectDir = localStorage.getItem("winsmux.active-project.v1");
          const sessions = JSON.parse(localStorage.getItem("winsmux.project-sessions.v1") || "[]");
          return {
            activeProjectDir,
            sessions,
          };
        });
        const recorded = Array.isArray(state.sessions)
          && state.sessions.some((entry) => entry?.path === expectedProjectDir);
        if (state.activeProjectDir !== expectedProjectDir || !recorded) {
          throw new Error(`launch project state mismatch: ${JSON.stringify({ expectedProjectDir, nativeInitialProjectDir, ...state })}`);
        }
        return { activeProjectDir: state.activeProjectDir, nativeInitialProjectDir, recorded };
      });
      await ensureOutputDir();
      await page.screenshot({ path: path.join(OUTPUT_DIR, "desktop-launch-arg-e2e-success.png"), fullPage: true });
      await writeEvidence(true, { debugPort });
      process.stdout.write(`[desktop-pane-e2e] PASS evidence=${path.join(OUTPUT_DIR, "desktop-pane-e2e.json")}\n`);
      return;
    }

    await resetAppState(page);

    if (COMPOSER_ONLY) {
      await runStep("configure deterministic operator shell", async () => {
        await enableViewportHarness(page);
        await configureOperatorShellForTest(page);
        return await page.evaluate(() => window.__winsmuxViewportHarness?.getOperatorStartupInput());
      });

      await runStep("operator pane starts local shell and accepts input", async () => {
        const readyOutput = await startOperatorShellFromUiAndWaitForPrompt(page);
        const visibleText = await waitForVisibleTerminalText(page, "#operator-terminal", OPERATOR_SHELL_READY_MARKER);
        const output = await capturePty(page, "operator");
        return { readyTail: readyOutput.slice(-800), visibleTextTail: visibleText.slice(-400), outputTail: output.slice(-800) };
      });

      await runStep("composer send button writes user message to operator pane", async () => {
        const command = `Write-Output '${COMPOSER_TO_OPERATOR_MARKER}'`;
        const output = await submitComposerShellWithButton(page, command, COMPOSER_TO_OPERATOR_MARKER);
        return { outputTail: output.slice(-800) };
      });

      await runStep("composer send button writes multi-line run-control message to operator pane", async () => {
        const command = [
          "Write-Output 'TASK-575 operator-managed benchmark start'",
          `Write-Output '${COMPOSER_MULTILINE_MARKER}'`,
          "Write-Output 'Dispatch the same task packet to every worker pane.'",
          "Write-Output 'Stop and report a blocker if operator-to-worker dispatch is unavailable.'",
        ].join("\n");
        const output = await submitComposerShellWithButton(page, command, COMPOSER_MULTILINE_MARKER);
        return { outputTail: output.slice(-1_000) };
      });

      await runStep("close spawned PTYs", async () => {
        await closePtyIfExists(page, "operator");
      });

      await ensureOutputDir();
      await page.screenshot({ path: path.join(OUTPUT_DIR, "desktop-composer-e2e-success.png"), fullPage: true });
      await writeEvidence(true, { debugPort, mode: "composer-only" });
      process.stdout.write(`[desktop-pane-e2e] PASS composer-only evidence=${path.join(OUTPUT_DIR, "desktop-pane-e2e.json")}\n`);
      return;
    }

    await runStep("desktop app fills the native WebView without fixed viewport emulation", async () => {
      const metrics = await readViewportFillMetrics(page);
      assertNoFixedViewportBlank(metrics);
      return metrics;
    });

    await runStep("native desktop window resize still fills the WebView", async () => {
      const metrics = await resizeNativeWindowAndReadMetrics(page);
      assertNoFixedViewportBlank(metrics);
      return metrics;
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

    await runStep("Agent Vault is hidden by default so worker panes keep primary space", async () => {
      const state = await page.locator("#workspace-body").evaluate((body) => {
        const contextPanel = document.querySelector("#context-panel");
        const agentVaultPanel = document.querySelector("#agent-vault-panel");
        const toggle = document.querySelector("#toggle-agent-vault-btn");
        return {
          contextHidden: contextPanel?.hasAttribute("hidden") ?? false,
          agentVaultHidden: agentVaultPanel?.hasAttribute("hidden") ?? false,
          contextCollapsed: body.classList.contains("context-collapsed"),
          toggleExpanded: toggle?.getAttribute("aria-expanded"),
        };
      });
      if (!state.contextHidden || !state.agentVaultHidden || !state.contextCollapsed || state.toggleExpanded !== "false") {
        throw new Error(`Agent Vault should start hidden by default: ${JSON.stringify(state)}`);
      }
      return state;
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
      const threeColumnMetrics = await page.locator("#panes-container .pane").evaluateAll((panes) => {
        const rects = panes.map((pane) => pane.getBoundingClientRect());
        const widths = rects.map((rect) => Math.round(rect.width));
        const columns = new Set(rects.map((rect) => Math.round(rect.left))).size;
        const rows = new Set(rects.map((rect) => Math.round(rect.top))).size;
        const labelHeights = panes.map((pane) => Math.round(pane.querySelector(".pane-label")?.getBoundingClientRect().height ?? 0));
        return {
          minWidth: Math.min(...widths),
          widths,
          columns,
          rows,
          labelHeights,
        };
      });
      if (threeColumnMetrics.columns !== 3 || threeColumnMetrics.rows !== 2) {
        throw new Error(`3x2 worker panes should stay fixed at 3 columns by 2 rows: ${JSON.stringify(threeColumnMetrics)}`);
      }
      if (threeColumnMetrics.minWidth < 300) {
        throw new Error(`3x2 worker panes are too narrow: ${JSON.stringify(threeColumnMetrics)}`);
      }
      if (threeColumnMetrics.labelHeights.some((height) => height > 26)) {
        throw new Error(`worker pane labels should stay on one row: ${JSON.stringify(threeColumnMetrics)}`);
      }
      await setWorkbenchLayout(page, "focus");
      await page.locator("#focused-pane-select").waitFor({ state: "visible" });
      await page.selectOption("#focused-pane-select", "worker-2");
      const ids = await visiblePaneIds(page);
      if (ids.length !== 1 || ids[0] !== "worker-2") {
        throw new Error(`focus layout should show only worker-2, saw ${ids.join(",")}`);
      }
      await setWorkbenchLayout(page, "3x2");
      return threeColumnMetrics;
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

    await runStep("worker status pills mirror native state and focus panes", async () => {
      await ensureDrawerOpen(page);
      await setWorkerStatusStripFromViewMenu(page, true);
      await page.locator("#worker-status-pill-bar").waitFor({ state: "visible", timeout: 10_000 });
      const workerOnePill = page.locator('.worker-status-pill[data-worker-status-target="worker-1"]');
      await workerOnePill.waitFor({ state: "visible", timeout: 10_000 });
      await workerOnePill.click();
      await page.waitForFunction(() => {
        const detail = document.querySelector(".worker-status-detail-strip");
        return detail?.getAttribute("data-worker-status-detail") === "worker-1";
      }, undefined, { timeout: 10_000 });
      const requiredFields = ["role", "backend", "profile", "workspace", "auth", "secrets", "policy", "model-source", "launch", "heartbeat", "blocked", "recovery", "remote", "elapsed", "focus"];
      for (const field of requiredFields) {
        const count = await page.locator(`.worker-status-detail-strip[data-worker-status-detail="worker-1"] .worker-status-pill-chip[data-status-field="${field}"]`).count();
        if (count !== 1) {
          throw new Error(`worker-1 status pill should expose ${field}, saw ${count}`);
        }
      }
      const detailMetrics = await page.locator('.worker-status-detail-strip[data-worker-status-detail="worker-1"]').evaluate((detail) => {
        const detailRect = detail.getBoundingClientRect();
        const visibleFields = Array.from(detail.querySelectorAll(".worker-status-pill-chip"))
          .filter((chip) => {
            const chipRect = chip.getBoundingClientRect();
            return chipRect.width > 0
              && chipRect.height > 0
              && chipRect.left >= detailRect.left
              && chipRect.right <= detailRect.right
              && chipRect.top >= detailRect.top
              && chipRect.bottom <= detailRect.bottom;
          })
          .map((chip) => chip.getAttribute("data-status-field"));
        return {
          width: detailRect.width,
          height: detailRect.height,
          visibleFields,
        };
      });
      const missingFields = requiredFields.filter((field) => !detailMetrics.visibleFields.includes(field));
      if (detailMetrics.width < 220 || missingFields.length > 0) {
        throw new Error(`worker status details should stay visible: ${JSON.stringify(detailMetrics)}`);
      }
      const workerTwoPill = page.locator('.worker-status-pill[data-worker-status-target="worker-2"]');
      await workerTwoPill.waitFor({ state: "visible", timeout: 10_000 });
      await workerTwoPill.click();
      await page.waitForFunction(() => {
        const drawer = document.querySelector("#terminal-drawer");
        const pill = document.querySelector('.worker-status-pill[data-worker-status-target="worker-2"]');
        const detail = document.querySelector(".worker-status-detail-strip");
        return drawer?.getAttribute("data-focused-pane") === "worker-2"
          && pill?.getAttribute("data-focused") === "true"
          && detail?.getAttribute("data-worker-status-detail") === "worker-2";
      }, undefined, { timeout: 10_000 });
      const workerPaneVisible = await page.locator("#pane-worker-2").isVisible();
      if (!workerPaneVisible) {
        throw new Error("worker-2 pane should remain visible after status pill focus");
      }
      const statusBarMetrics = await page.locator("#worker-status-pill-bar").evaluate((bar) => ({
        clientWidth: bar.clientWidth,
        scrollWidth: bar.scrollWidth,
        clientHeight: bar.clientHeight,
        scrollHeight: bar.scrollHeight,
      }));
      if (statusBarMetrics.scrollWidth > statusBarMetrics.clientWidth + 2) {
        throw new Error(`worker status surface should not require horizontal scrolling: ${JSON.stringify(statusBarMetrics)}`);
      }
    });

    if (STOP_AFTER_WORKER_STATUS) {
      await ensureOutputDir();
      await page.screenshot({ path: path.join(OUTPUT_DIR, "desktop-pane-e2e-worker-status.png"), fullPage: true });
      await writeEvidence(true, { debugPort, mode: "worker-status-only" });
      process.stdout.write(`[desktop-pane-e2e] PASS worker-status-only evidence=${path.join(OUTPUT_DIR, "desktop-pane-e2e.json")}\n`);
      return;
    }

    await runStep("View menu hides worker status so worker panes keep primary space", async () => {
      const before = await page.locator("#panes-container").evaluate((container) => ({
        top: Math.round(container.getBoundingClientRect().top),
        height: Math.round(container.getBoundingClientRect().height),
        statusVisible: !document.querySelector("#worker-status-pill-bar")?.hasAttribute("hidden"),
      }));
      await setWorkerStatusStripFromViewMenu(page, false);
      const after = await page.locator("#panes-container").evaluate((container) => ({
        top: Math.round(container.getBoundingClientRect().top),
        height: Math.round(container.getBoundingClientRect().height),
        statusVisible: !document.querySelector("#worker-status-pill-bar")?.hasAttribute("hidden"),
      }));
      if (after.statusVisible) {
        throw new Error(`worker status strip should be hidden from the View menu: ${JSON.stringify({ before, after })}`);
      }
      if (after.top >= before.top - 8 || after.height < before.height - 8) {
        throw new Error(`worker panes should move up and keep primary space after hiding status: ${JSON.stringify({ before, after })}`);
      }
      const fillMetrics = await page.locator("#panes-container").evaluate((container) => {
        const containerRect = container.getBoundingClientRect();
        const drawerRect = document.querySelector("#terminal-drawer")?.getBoundingClientRect();
        const paneRects = Array.from(container.querySelectorAll(".pane:not([hidden])")).map((pane) => {
          const rect = pane.getBoundingClientRect();
          return {
            top: Math.round(rect.top),
            bottom: Math.round(rect.bottom),
            height: Math.round(rect.height),
          };
        });
        const maxBottom = Math.max(...paneRects.map((rect) => rect.bottom));
        const minHeight = Math.min(...paneRects.map((rect) => rect.height));
        const maxHeight = Math.max(...paneRects.map((rect) => rect.height));
        return {
          containerTop: Math.round(containerRect.top),
          containerBottom: Math.round(containerRect.bottom),
          containerHeight: Math.round(containerRect.height),
          bottomGap: Math.round(containerRect.bottom - maxBottom),
          drawerBottomGap: drawerRect ? Math.round(drawerRect.bottom - maxBottom) : 0,
          minHeight,
          maxHeight,
          paneCount: paneRects.length,
        };
      });
      if (fillMetrics.paneCount !== 6 || fillMetrics.bottomGap > 10 || fillMetrics.drawerBottomGap > 10 || fillMetrics.minHeight < 120 || Math.abs(fillMetrics.maxHeight - fillMetrics.minHeight) > 24) {
        throw new Error(`worker panes should fill the available workbench area: ${JSON.stringify(fillMetrics)}`);
      }
      return { before, after, fillMetrics };
    });

    await runStep("View menu hides Agent Vault and frees the right sidebar", async () => {
      await ensureAgentVaultOpen(page);
      const before = await page.locator("#workspace-body").evaluate((body) => ({
        contextHidden: document.querySelector("#context-panel")?.hasAttribute("hidden") ?? true,
        vaultHidden: document.querySelector("#agent-vault-panel")?.hasAttribute("hidden") ?? true,
        contextCollapsed: body.classList.contains("context-collapsed"),
      }));
      await setAgentVaultPanelFromViewMenu(page, false);
      const hidden = await page.locator("#workspace-body").evaluate((body) => ({
        contextHidden: document.querySelector("#context-panel")?.hasAttribute("hidden") ?? false,
        vaultHidden: document.querySelector("#agent-vault-panel")?.hasAttribute("hidden") ?? false,
        contextCollapsed: body.classList.contains("context-collapsed"),
      }));
      if (!hidden.contextHidden || !hidden.contextCollapsed) {
        throw new Error(`Agent Vault View menu action should collapse the right sidebar: ${JSON.stringify({ before, hidden })}`);
      }
      await setAgentVaultPanelFromViewMenu(page, true);
      const restored = await page.locator("#workspace-body").evaluate((body) => ({
        contextHidden: document.querySelector("#context-panel")?.hasAttribute("hidden") ?? true,
        vaultHidden: document.querySelector("#agent-vault-panel")?.hasAttribute("hidden") ?? true,
        contextCollapsed: body.classList.contains("context-collapsed"),
      }));
      if (restored.contextHidden || restored.vaultHidden || restored.contextCollapsed) {
        throw new Error(`Agent Vault View menu action should restore the right sidebar: ${JSON.stringify({ before, hidden, restored })}`);
      }
      return { before, hidden, restored };
    });

    await runStep("Agent Vault indexes, searches, filters, feeds, and restores sessions from the right sidebar", async () => {
      return await exerciseAgentVault(page);
    });

    await runStep("worker terminal keeps shortcuts, arrows, and paste in the PTY", async () => {
      const terminalSelector = "#pane-worker-1 .pane-terminal";
      await page.click(terminalSelector, { timeout: 10_000 });
      await page.keyboard.press("Control+K");
      const commandPaletteVisible = await page.locator("#command-bar-shell").isVisible().catch(() => false);
      if (commandPaletteVisible) {
        throw new Error("Ctrl+K opened the command palette while the worker terminal was focused");
      }
      await page.keyboard.press(process.platform === "darwin" ? "Meta+," : "Control+,");
      const settingsVisible = await page.locator("#settings-sheet").isVisible().catch(() => false);
      if (settingsVisible) {
        throw new Error("settings opened while the worker terminal was focused");
      }
      await page.keyboard.press("Control+C");
      await waitForPtyPrompt(page, "worker-1");

      await page.waitForTimeout(250);
      await page.keyboard.type("Write-Output 'RAW_AB'", { delay: 10 });
      await page.keyboard.press("ArrowLeft");
      await page.keyboard.type("C", { delay: 10 });
      await page.keyboard.press("End");
      await page.keyboard.press("Enter");
      const arrowOutput = await waitForPtyOutputLine(page, "worker-1", WORKER_ARROW_MARKER);

      const pasteMode = await pasteIntoTerminal(page, terminalSelector, `Write-Output '${WORKER_PASTE_MARKER}'`);
      await page.keyboard.press("Enter");
      const pasteOutput = await waitForPtyOutputLine(page, "worker-1", WORKER_PASTE_MARKER);
      return {
        arrowOutputTail: arrowOutput.slice(-800),
        pasteOutputTail: pasteOutput.slice(-800),
        pasteMode,
      };
    });

    await runStep("operator pane starts Claude Code and accepts real user input", async () => {
      const readyOutput = await startOperatorFromUiAndWaitForClaude(page);
      await ensureOutputDir();
      await page.screenshot({ path: path.join(OUTPUT_DIR, "desktop-pane-e2e-operator-claude.png"), fullPage: true });
      await typeTerminalDraft(page, "#operator-terminal-panel", OPERATOR_MARKER);
      const visibleText = await waitForVisibleTerminalText(page, "#operator-terminal", OPERATOR_MARKER);
      const output = await capturePty(page, "operator");
      await clearOperatorInputFromUi(page);
      const timelineText = await page.locator("#conversation-timeline").innerText().catch(() => "");
      if (/Claude Code v\d|--permission-mode/.test(timelineText)) {
        throw new Error("operator startup log should stay in the operator pane and not mirror into the chat timeline");
      }
      return { readyTail: readyOutput.slice(-800), visibleTextTail: visibleText.slice(-400), outputTail: output.slice(-800) };
    });

    await runStep("operator command writes to worker through desktop control pipe", async () => {
      await spawnPtyIfNeeded(page, "worker-2");
      await waitForPtyPrompt(page, "worker-2");
      await startOperatorFromUiAndWaitForClaude(page);
      // Claude Code uses `!` as its shell-command prefix; this is typed into the operator, not PowerShell.
      const claudeShellCommand = `!pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File '${scriptPath.replace(/'/g, "''")}'`;
      const pasteMode = await pasteIntoTerminal(page, "#operator-terminal-panel", claudeShellCommand);
      await page.keyboard.press("Enter");
      await waitForPtyOutput(page, "operator", "PIPE_CONTRACT_OK");
      const operatorOutput = await waitForPtyOutput(page, "operator", "PIPE_RESPONSE:");
      const workerOutput = await waitForPtyOutputLine(page, "worker-2", OPERATOR_TO_WORKER_MARKER);
      return {
        operatorTail: operatorOutput.slice(-1_200),
        workerTail: workerOutput.slice(-800),
        pasteMode,
      };
    });

    await runStep("composer send button writes user message to operator pane", async () => {
      const command = COMPOSER_TO_OPERATOR_MARKER;
      const output = await submitComposerWithButton(page, command, COMPOSER_TO_OPERATOR_MARKER);
      await clearOperatorInputFromUi(page);
      return { outputTail: output.slice(-800) };
    });

    await runStep("composer send button writes multi-line run-control message to operator pane", async () => {
      const command = [
        "TASK-575 operator-managed benchmark start",
        COMPOSER_MULTILINE_MARKER,
        "Dispatch the same task packet to every worker pane.",
        "Stop and report a blocker if operator-to-worker dispatch is unavailable.",
      ].join("\n");
      const output = await submitComposerWithButton(page, command, COMPOSER_MULTILINE_MARKER);
      await clearOperatorInputFromUi(page);
      return { outputTail: output.slice(-1_000) };
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
      await clearOperatorInputFromUi(page);
      await page.fill("#composer-input", message);
      await page.click("#send-btn");
      await page.waitForFunction(() => {
        const input = document.querySelector("#composer-input");
        return input instanceof HTMLTextAreaElement && input.value === "";
      });
      const output = await waitForPtyOutput(page, "operator", COMPOSER_ATTACHMENT_MARKER, 90_000);
      const attachmentOutput = stripAnsi(output).includes("composer-attachment.txt")
        ? output
        : await waitForPtyOutput(page, "operator", "composer-attachment.txt", 30_000);
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
      return { outputTail: attachmentOutput.slice(-800) };
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

    await runStep("worker start button launches the selected Tauri worker pane", async () => {
      return await exerciseWorkerStartButton(page);
    });

    await runStep("operator composer command starts all worker panes", async () => {
      return await exerciseOperatorCommandStartsAllWorkerPanes(page);
    });

    await runStep("close spawned PTYs", async () => {
    await closePtyIfExists(page, "worker-1");
    await closePtyIfExists(page, "worker-2");
    await closePtyIfExists(page, "worker-5");
    await closePtyIfExists(page, "worker-6");
    await closePtyIfExists(page, "operator");
  });

    await ensureOutputDir();
    await page.screenshot({ path: path.join(OUTPUT_DIR, "desktop-pane-e2e-success.png"), fullPage: true });
    await writeEvidence(true, { debugPort });
    process.stdout.write(`[desktop-pane-e2e] PASS evidence=${path.join(OUTPUT_DIR, "desktop-pane-e2e.json")}\n`);
  } catch (error) {
    if (page) {
      await ensureOutputDir();
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
