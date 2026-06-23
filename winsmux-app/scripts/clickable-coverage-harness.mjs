import { spawn } from "node:child_process";
import { once } from "node:events";
import fs from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import process from "node:process";
import { chromium } from "playwright";

const OUTPUT_DIR = path.join(process.cwd(), "output", "playwright", "clickable-coverage");
const HARNESS_QUERY = "?viewport-harness=1";
const PROJECT_DIR = path.resolve(process.cwd(), "..").replace(/\\/g, "/");
const DEFAULT_RUNTIME_ROLE_PREFERENCES = [
  {
    roleId: "operator",
    provider: "claude",
    model: "provider-default",
    modelSource: "provider-default",
    reasoningEffort: "provider-default",
  },
  {
    roleId: "worker",
    provider: "codex",
    model: "provider-default",
    modelSource: "provider-default",
    reasoningEffort: "provider-default",
  },
  {
    roleId: "reviewer",
    provider: "codex",
    model: "gpt-5.3-codex-spark",
    modelSource: "cli-discovery",
    reasoningEffort: "high",
  },
];
const VIEWPORTS = [
  { name: "narrow", width: 1280, height: 720 },
  { name: "wide", width: 1600, height: 900 },
];

const clicked = [];
const skipped = [];
const observed = [];
const consoleErrors = [];
const pageErrors = [];
let currentViewportName = "default";

function scopedLabel(label) {
  return `${currentViewportName}: ${label}`;
}

function recordClick(label) {
  clicked.push(scopedLabel(label));
}

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
        reject(new Error("Failed to resolve a preview port"));
        return;
      }
      server.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve(address.port);
      });
    });
    server.on("error", reject);
  });
}

function startPreviewServer(previewPort) {
  const child = spawn(
    process.platform === "win32" ? "cmd.exe" : "npm",
    process.platform === "win32"
      ? ["/c", "npm", "run", "preview", "--", "--host", "127.0.0.1", "--port", `${previewPort}`, "--strictPort"]
      : ["run", "preview", "--", "--host", "127.0.0.1", "--port", `${previewPort}`, "--strictPort"],
    { cwd: process.cwd(), stdio: ["ignore", "pipe", "pipe"] },
  );
  child.stdout.on("data", (chunk) => process.stdout.write(chunk));
  child.stderr.on("data", (chunk) => process.stderr.write(chunk));
  return child;
}

async function stopPreviewServer(child) {
  if (child.exitCode !== null || child.killed) {
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

async function waitForPreviewServer(url, timeoutMs = 30_000) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    try {
      const response = await fetch(url);
      if (response.ok) {
        return;
      }
    } catch {
      // Retry until the preview server is ready.
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`Preview server did not start within ${timeoutMs}ms`);
}

function attachErrorCapture(page) {
  page.on("popup", async (popup) => {
    await popup.close().catch(() => {});
  });
  page.on("console", (message) => {
    if (message.type() === "error") {
      consoleErrors.push(message.text());
    }
  });
  page.on("pageerror", (error) => {
    pageErrors.push(error.message);
  });
  page.on("dialog", async (dialog) => {
    if (dialog.type() === "prompt") {
      await dialog.accept(PROJECT_DIR);
      return;
    }
    await dialog.accept();
  });
}

async function installBrowserStubs(page) {
  await page.addInitScript(({ projectDir, runtimePreferences }) => {
    if (!window.localStorage.getItem("winsmux.runtime-role.preferences.v1")) {
      window.localStorage.setItem("winsmux.runtime-role.preferences.v1", JSON.stringify(runtimePreferences));
    }
    if (!window.localStorage.getItem("winsmux.runtime-model.assignment-mode.v1")) {
      window.localStorage.setItem("winsmux.runtime-model.assignment-mode.v1", "shared");
    }
    window.prompt = () => projectDir;
    window.alert = (message) => {
      window.__winsmuxClickableAlerts = [
        ...(window.__winsmuxClickableAlerts ?? []),
        String(message ?? ""),
      ];
    };
    const speechRecognitionState = {
      instances: [],
      starts: 0,
      stops: 0,
      get active() {
        return this.instances[this.instances.length - 1] ?? null;
      },
      emitResult(transcript, isFinal = true) {
        const result = [{ transcript, confidence: 1 }];
        result.isFinal = isFinal;
        this.active?.onresult?.({ resultIndex: 0, results: [result] });
      },
      emitError(error, message = error) {
        this.active?.onerror?.({ error, message });
      },
    };
    class MockSpeechRecognition {
      constructor() {
        this.continuous = false;
        this.interimResults = false;
        this.lang = "en-US";
        this.onerror = null;
        this.onend = null;
        this.onresult = null;
        this.onstart = null;
        speechRecognitionState.instances.push(this);
      }
      start() {
        speechRecognitionState.starts += 1;
        this.onstart?.();
      }
      stop() {
        speechRecognitionState.stops += 1;
        this.onend?.();
      }
      abort() {
        this.onend?.();
      }
    }
    window.__winsmuxSpeechRecognition = speechRecognitionState;
    window.SpeechRecognition = MockSpeechRecognition;
    window.webkitSpeechRecognition = MockSpeechRecognition;
  }, { projectDir: PROJECT_DIR, runtimePreferences: DEFAULT_RUNTIME_ROLE_PREFERENCES });
}

async function runStep(name, action) {
  const consoleStart = consoleErrors.length;
  const pageStart = pageErrors.length;
  process.stdout.write(`[clickable] ${name}\n`);
  try {
    await action();
  } catch (error) {
    if (error instanceof Error) {
      error.message = `${name}: ${error.message}`;
    }
    throw error;
  }
  if (pageErrors.length > pageStart) {
    throw new Error(`${name}: page error: ${pageErrors.slice(pageStart).join(" | ")}`);
  }
  if (consoleErrors.length > consoleStart) {
    throw new Error(`${name}: console error: ${consoleErrors.slice(consoleStart).join(" | ")}`);
  }
}

async function waitForAppReady(page) {
  await page.locator("#workspace").waitFor({ state: "visible" });
  await page.locator("#composer-input").waitFor({ state: "visible" });
  await page.waitForFunction(() => Boolean(window.__winsmuxViewportHarness));
}

async function recoverShell(page) {
  await page.keyboard.press("Escape").catch(() => {});
  if (await page.locator("#settings-sheet").isVisible().catch(() => false)) {
    await page.click("#close-settings-btn").catch(() => {});
  }
  if (await page.locator("#command-bar-shell").isVisible().catch(() => false)) {
    await page.keyboard.press("Escape").catch(() => {});
  }
  if (await page.locator("#sidebar-overlay").isVisible().catch(() => false)) {
    await page.click("#sidebar-overlay").catch(() => {});
  }
  await page.evaluate(() => {
    window.__winsmuxViewportHarness?.setTerminalDrawer(true);
    window.__winsmuxViewportHarness?.setContextPanel(true);
  });
  await page.locator("#terminal-drawer").waitFor({ state: "visible" });
}

async function recordVisibleInteractives(page, state) {
  const scopedState = `${currentViewportName}:${state}`;
  const items = await page.evaluate((label) => {
    const selector = [
      "button",
      "select",
      "input:not([type='hidden'])",
      "textarea",
      "[role='button']",
      "[tabindex]:not([tabindex='-1'])",
      ".footer-pill",
      ".sidebar-row",
      ".timeline-item",
    ].join(",");
    return Array.from(document.querySelectorAll(selector))
      .filter((element) => {
        if (!(element instanceof HTMLElement)) {
          return false;
        }
        if (element.hidden || element.closest("[hidden]")) {
          return false;
        }
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.visibility !== "hidden" &&
          style.display !== "none" &&
          rect.width > 0 &&
          rect.height > 0;
      })
      .map((element) => ({
        state: label,
        id: element.id || "",
        tag: element.tagName.toLowerCase(),
        role: element.getAttribute("role") || "",
        className: element.className || "",
        text: (element.textContent || element.getAttribute("aria-label") || element.getAttribute("title") || "")
          .replace(/\s+/g, " ")
          .trim()
          .slice(0, 120),
      }));
  }, scopedState);
  observed.push(...items);
}

async function isDisabled(locator) {
  return await locator.evaluate((element) => {
    if (!(element instanceof HTMLElement)) {
      return true;
    }
    return Boolean(element.getAttribute("aria-disabled") === "true" || element.hasAttribute("disabled") || element.disabled);
  }, undefined, { timeout: 2_000 });
}

async function clickLocator(page, locator, label, options = {}) {
  process.stdout.write(`[clickable] prepare ${label}\n`);
  await locator.scrollIntoViewIfNeeded({ timeout: 2_000 }).catch(() => {});
  if (!(await locator.isVisible({ timeout: 2_000 }).catch(() => false))) {
    skipped.push({ viewport: currentViewportName, label, reason: "not visible" });
    return false;
  }
  if (await isDisabled(locator).catch(() => false)) {
    skipped.push({ viewport: currentViewportName, label, reason: "disabled" });
    return false;
  }

  const chooserPromise = options.fileChooser
    ? page.waitForEvent("filechooser", { timeout: 1_000 }).catch(() => null)
    : Promise.resolve(null);
  process.stdout.write(`[clickable] click ${label}\n`);
  await locator.click({ timeout: 5_000, force: options.force ?? false, noWaitAfter: true });
  const chooser = await chooserPromise;
  if (chooser) {
    await chooser.setFiles(options.filePath);
  }
  recordClick(label);
  await page.waitForTimeout(options.settleMs ?? 100);
  return true;
}

async function clickSelector(page, selector, label, options = {}) {
  await clickLocator(page, page.locator(selector).first(), label, options);
}

async function waitForElementVisibility(page, selector, expected, label) {
  await page.waitForFunction(({ selector: targetSelector, expected: expectedVisibility }) => {
    const element = document.querySelector(targetSelector);
    if (!(element instanceof HTMLElement)) {
      return expectedVisibility === false;
    }
    const style = getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    const visible = !element.hidden &&
      !element.closest("[hidden]") &&
      style.display !== "none" &&
      style.visibility !== "hidden" &&
      rect.width > 0 &&
      rect.height > 0;
    return visible === expectedVisibility;
  }, { selector, expected }, { timeout: 5_000 }).catch((error) => {
    throw new Error(`${label}: expected ${selector} visible=${expected}: ${error.message}`);
  });
}

async function isSidebarModeOpen(page, mode) {
  return await page.evaluate((targetMode) => {
    const shell = document.getElementById("app-shell");
    const viewByMode = {
      explorer: document.getElementById("files-sidebar-section"),
      source: document.getElementById("source-control-view"),
      evidence: document.getElementById("evidence-view"),
      workspace: document.getElementById("session-sidebar-section"),
    };
    const view = viewByMode[targetMode];
    if (!shell || !(view instanceof HTMLElement)) {
      return false;
    }
    if (!shell.classList.contains("sidebar-open") || view.hidden || view.closest("[hidden]")) {
      return false;
    }
    const rect = view.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  }, mode);
}

async function waitForSidebarModeState(page, mode, expected, label) {
  await page.waitForFunction(({ targetMode, expectedOpen }) => {
    const shell = document.getElementById("app-shell");
    const rail = document.getElementById("left-rail");
    const viewByMode = {
      explorer: document.getElementById("files-sidebar-section"),
      source: document.getElementById("source-control-view"),
      evidence: document.getElementById("evidence-view"),
      workspace: document.getElementById("session-sidebar-section"),
    };
    const view = viewByMode[targetMode];
    if (!shell || !(rail instanceof HTMLElement) || !(view instanceof HTMLElement)) {
      return false;
    }
    const railStyle = getComputedStyle(rail);
    const railRect = rail.getBoundingClientRect();
    const railVisible = !rail.hidden &&
      !rail.closest("[hidden]") &&
      railStyle.display !== "none" &&
      railStyle.visibility !== "hidden" &&
      railRect.width > 0 &&
      railRect.height > 0;
    const modeOpen = shell.classList.contains("sidebar-open") &&
      railVisible &&
      !view.hidden &&
      !view.closest("[hidden]") &&
      view.getBoundingClientRect().height > 0;
    return modeOpen === expectedOpen;
  }, { targetMode: mode, expectedOpen: expected }, { timeout: 5_000 }).catch((error) => {
    throw new Error(`${label}: expected sidebar mode ${mode} open=${expected}: ${error.message}`);
  });
}

async function ensureSidebarMode(page, mode, triggerSelector, label) {
  if (!(await isSidebarModeOpen(page, mode))) {
    await clickSelector(page, triggerSelector, label);
  }
  await page.waitForFunction((targetMode) => {
    const shell = document.getElementById("app-shell");
    const viewByMode = {
      explorer: document.getElementById("files-sidebar-section"),
      source: document.getElementById("source-control-view"),
      evidence: document.getElementById("evidence-view"),
      workspace: document.getElementById("session-sidebar-section"),
    };
    const view = viewByMode[targetMode];
    if (!shell || !(view instanceof HTMLElement)) {
      return false;
    }
    if (!shell.classList.contains("sidebar-open") || view.hidden || view.closest("[hidden]")) {
      return false;
    }
    const rect = view.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  }, mode, { timeout: 5_000 });
}

async function clickAll(page, selector, label, options = {}) {
  const locator = page.locator(selector);
  const count = await locator.count();
  for (let index = 0; index < count; index += 1) {
    const didClick = await clickLocator(page, locator.nth(index), `${label} #${index + 1}`, options);
    if (didClick && options.afterClick) {
      await options.afterClick(index);
    }
  }
}

async function openTopMenu(page, menuId) {
  await clickSelector(page, `#${menuId}`, `top menu ${menuId}`);
  await page.locator("#top-menu-popover").waitFor({ state: "visible" });
}

async function clickTopMenuItemMatching(page, menuId, pattern, label) {
  await openTopMenu(page, menuId);
  const item = page.locator("#top-menu-popover .top-menu-popover-item").filter({ hasText: pattern }).first();
  if (!(await item.isVisible({ timeout: 2_000 }).catch(() => false))) {
    const menuText = (await page.locator("#top-menu-popover .top-menu-popover-item").allTextContents().catch(() => []))
      .map((text) => text.replace(/\s+/g, " ").trim())
      .join(" | ");
    await page.keyboard.press("Escape").catch(() => {});
    throw new Error(`${label}: menu item not found. Available: ${menuText}`);
  }
  await clickLocator(page, item, label, { settleMs: 200 });
}

async function clickTopMenuItems(page, menuId) {
  await openTopMenu(page, menuId);
  const count = await page.locator("#top-menu-popover .top-menu-popover-item").count();
  await page.keyboard.press("Escape");
  for (let index = 0; index < count; index += 1) {
    await openTopMenu(page, menuId);
    const item = page.locator("#top-menu-popover .top-menu-popover-item").nth(index);
    const text = ((await item.textContent()) ?? "").replace(/\s+/g, " ").trim();
    const fileChooser = text.includes("Attach file") || text.includes("ファイルを添付");
    await clickLocator(page, item, `top menu ${menuId}: ${text}`, {
      fileChooser,
      filePath: path.join(OUTPUT_DIR, "sample-attachment.txt"),
    });
    await recoverShell(page);
  }
}

async function testInitialDefaultChrome(page) {
  await waitForElementVisibility(page, "#conversation-timeline", false, "default event feed hidden");
  await waitForElementVisibility(page, "#worker-status-pill-bar", false, "default worker details hidden");
}

async function ensureWorkerStatusStripVisible(page) {
  const statusPill = page.locator('.worker-status-pill[data-worker-status-target="worker-2"]').first();
  if (await statusPill.isVisible({ timeout: 1_000 }).catch(() => false)) {
    return statusPill;
  }

  await openTopMenu(page, "menu-view-btn");
  const showWorkerStatus = page
    .locator("#top-menu-popover .top-menu-popover-item")
    .filter({ hasText: /Show Worker Details|Show worker status|ワーカー詳細情報を表示|ワーカー状態を表示/ })
    .first();
  if (!(await showWorkerStatus.isVisible({ timeout: 2_000 }).catch(() => false))) {
    const menuText = (await page.locator("#top-menu-popover .top-menu-popover-item").allTextContents().catch(() => []))
      .map((text) => text.replace(/\s+/g, " ").trim())
      .join(" | ");
    await page.keyboard.press("Escape").catch(() => {});
    throw new Error(`Worker status strip is hidden and View menu did not expose the restore action: ${menuText}`);
  }

  await clickLocator(page, showWorkerStatus, "workbench show worker status", { settleMs: 200 });
  await statusPill.waitFor({ state: "visible", timeout: 5_000 });
  return statusPill;
}

async function testViewMenuStateful(page) {
  await recoverShell(page);
  await ensureSidebarMode(page, "explorer", "#activity-explorer-btn", "view state explorer open");

  await clickTopMenuItemMatching(page, "menu-view-btn", /Hide Explorer|エクスプローラーを隠す/, "view hide explorer");
  await waitForSidebarModeState(page, "explorer", false, "view hide explorer");
  await clickTopMenuItemMatching(page, "menu-view-btn", /Show Explorer|エクスプローラーを表示/, "view show explorer");
  await waitForSidebarModeState(page, "explorer", true, "view show explorer");

  await clickTopMenuItemMatching(page, "menu-view-btn", /Show Workspace Overview|作業領域の概要を表示/, "view show workspace overview");
  await waitForSidebarModeState(page, "workspace", true, "view show workspace overview");
  await clickTopMenuItemMatching(page, "menu-view-btn", /Hide Workspace Overview|作業領域の概要を隠す/, "view hide workspace overview");
  await waitForSidebarModeState(page, "workspace", false, "view hide workspace overview");

  await clickTopMenuItemMatching(page, "menu-view-btn", /Show Source Control|ソース管理を表示/, "view show source control");
  await waitForSidebarModeState(page, "source", true, "view show source control");
  await clickTopMenuItemMatching(page, "menu-view-btn", /Hide Source Control|ソース管理を隠す/, "view hide source control");
  await waitForSidebarModeState(page, "source", false, "view hide source control");

  await clickTopMenuItemMatching(page, "menu-view-btn", /Show Evidence|証跡を表示/, "view show evidence");
  await waitForSidebarModeState(page, "evidence", true, "view show evidence");
  await clickTopMenuItemMatching(page, "menu-view-btn", /Hide Evidence|証跡を隠す/, "view hide evidence");
  await waitForSidebarModeState(page, "evidence", false, "view hide evidence");

  await clickTopMenuItemMatching(page, "menu-view-btn", /Hide Details|詳細を隠す/, "view hide details");
  await waitForElementVisibility(page, "#context-panel", false, "view hide details");
  await clickTopMenuItemMatching(page, "menu-view-btn", /Show Details|詳細を表示/, "view show details");
  await waitForElementVisibility(page, "#context-panel", true, "view show details");

  await clickTopMenuItemMatching(page, "menu-view-btn", /Show Agent Vault|Agent Vault を表示/, "view show agent vault");
  await waitForElementVisibility(page, "#agent-vault-panel", true, "view show agent vault");
  await clickTopMenuItemMatching(page, "menu-view-btn", /Hide Agent Vault|Agent Vault を隠す/, "view hide agent vault");
  await waitForElementVisibility(page, "#agent-vault-panel", false, "view hide agent vault");

  await clickTopMenuItemMatching(page, "menu-view-btn", /Show Worker Details|ワーカー詳細情報を表示/, "view show worker details");
  await waitForElementVisibility(page, "#worker-status-pill-bar", true, "view show worker details");
  await clickTopMenuItemMatching(page, "menu-view-btn", /Hide Worker Details|ワーカー詳細情報を隠す/, "view hide worker details");
  await waitForElementVisibility(page, "#worker-status-pill-bar", false, "view hide worker details");

  await clickTopMenuItemMatching(page, "menu-view-btn", /Show Event Feed|イベント欄を表示/, "view show event feed");
  await waitForElementVisibility(page, "#conversation-timeline", true, "view show event feed");
  await clickTopMenuItemMatching(page, "menu-view-btn", /Hide Event Feed|イベント欄を隠す/, "view hide event feed");
  await waitForElementVisibility(page, "#conversation-timeline", false, "view hide event feed");

  await clickTopMenuItemMatching(page, "menu-view-btn", /Hide Worker Panes|ワーカーペインを隠す/, "view hide worker panes");
  await waitForElementVisibility(page, "#terminal-drawer", false, "view hide worker panes");
  await clickTopMenuItemMatching(page, "menu-view-btn", /Show Worker Panes|ワーカーペインを表示/, "view show worker panes");
  await waitForElementVisibility(page, "#terminal-drawer", true, "view show worker panes");
}

async function testTopMenus(page) {
  for (const menuId of [
    "menu-file-btn",
    "menu-edit-btn",
    "menu-selection-btn",
    "menu-view-btn",
    "menu-go-btn",
    "menu-run-btn",
    "menu-terminal-btn",
    "menu-help-btn",
  ]) {
    await clickTopMenuItems(page, menuId);
  }
}

async function testNavigationAndFooter(page) {
  await clickSelector(page, "#activity-source-btn", "activity source");
  await clickSelector(page, "#activity-evidence-btn", "activity evidence");
  await clickSelector(page, "#activity-explorer-btn", "activity explorer");
  await clickSelector(page, "#activity-context-btn", "activity details");
  await clickSelector(page, "#activity-context-btn", "activity details restore");
  await clickSelector(page, "#activity-search-btn", "activity command palette");
  await page.locator("#command-bar-shell").waitFor({ state: "visible" });
  await page.keyboard.press("Escape");
  await clickSelector(page, "#activity-settings-btn", "activity settings");
  await page.locator("#settings-sheet").waitFor({ state: "visible" });
  await clickSelector(page, "#close-settings-btn", "settings close from activity");

  await clickSelector(page, "#open-command-bar-btn", "header actions");
  await page.keyboard.press("Escape");
  await clickSelector(page, "#toggle-sidebar-btn", "header workspace");
  await clickSelector(page, "#toggle-sidebar-btn", "header workspace restore");
  await clickSelector(page, "#toggle-context-btn", "header details");
  await clickSelector(page, "#toggle-context-btn", "header details restore");
  await clickSelector(page, "#toggle-terminal-btn", "header worker panes");
  await clickSelector(page, "#toggle-terminal-btn", "header worker panes restore");

  await clickAll(page, "#footer-left .footer-pill, #footer-right .footer-pill", "footer pill", {
    afterClick: async () => {
      await recoverShell(page);
    },
  });
  await recoverShell(page);
}

async function testCommandBar(page) {
  await clickSelector(page, "#activity-search-btn", "command bar open");
  await page.locator("#command-bar-shell").waitFor({ state: "visible" });
  const count = await page.locator("#command-bar-results .command-bar-item").count();
  await page.keyboard.press("Escape");
  for (let index = 0; index < count; index += 1) {
    await clickSelector(page, "#activity-search-btn", `command bar reopen ${index + 1}`);
    const item = page.locator("#command-bar-results .command-bar-item").nth(index);
    const text = ((await item.textContent()) ?? "").replace(/\s+/g, " ").trim();
    await clickLocator(page, item, `command bar item ${text}`);
    await recoverShell(page);
  }
}

async function testPaneModelSettings(page) {
  await clickSelector(page, "#settings-tab-user", "settings user scope for pane model settings");
  await clickSelector(page, "#settings-nav-common", "settings common nav for pane model settings");
  await page.locator(".runtime-model-assignment-panel").scrollIntoViewIfNeeded();

  const perPaneMode = page
    .locator(".runtime-model-mode-option")
    .filter({ hasText: /Set each pane individually|ペインごと/ })
    .first();
  await clickLocator(page, perPaneMode, "settings pane model per-pane mode", { settleMs: 200 });
  await page.waitForFunction(() => {
    const provider = document.querySelector("#runtime-worker-default-provider");
    const model = document.querySelector("#runtime-worker-default-model");
    const effort = document.querySelector("#runtime-worker-default-effort");
    return provider instanceof HTMLSelectElement && provider.disabled
      && model instanceof HTMLSelectElement && model.disabled
      && effort instanceof HTMLSelectElement && effort.disabled;
  });
  await page.waitForFunction(() => {
    return document.querySelector(".runtime-model-slot-row")
      || document.querySelector(".runtime-model-empty")?.textContent?.includes("worker slot")
      || document.querySelector(".runtime-model-empty")?.textContent?.includes("worker");
  });
  await clickSelector(page, "#apply-settings-btn", "settings pane model per-pane apply", { settleMs: 200 });
  await page.waitForFunction(() => window.localStorage.getItem("winsmux.runtime-model.assignment-mode.v1") === "per-pane");

  await page.reload({ waitUntil: "networkidle" });
  await waitForAppReady(page);
  await clickSelector(page, "#activity-settings-btn", "settings pane model reopen after reload");
  await page.locator("#settings-sheet").waitFor({ state: "visible" });
  await clickSelector(page, "#settings-tab-user", "settings user scope after pane mode reload");
  await clickSelector(page, "#settings-nav-common", "settings common nav after pane mode reload");
  await page.locator(".runtime-model-assignment-panel").scrollIntoViewIfNeeded();
  await page.waitForFunction(() => {
    const modeButtons = Array.from(document.querySelectorAll(".runtime-model-mode-option"));
    const perPane = modeButtons.find((button) => /Set each pane individually|ペインごと/.test(button.textContent ?? ""));
    const provider = document.querySelector("#runtime-worker-default-provider");
    const model = document.querySelector("#runtime-worker-default-model");
    const effort = document.querySelector("#runtime-worker-default-effort");
    return perPane instanceof HTMLElement
      && perPane.getAttribute("aria-pressed") === "true"
      && provider instanceof HTMLSelectElement && provider.disabled
      && model instanceof HTMLSelectElement && model.disabled
      && effort instanceof HTMLSelectElement && effort.disabled;
  });

  const sharedMode = page
    .locator(".runtime-model-mode-option")
    .filter({ hasText: /All panes use the default|全ペイン共通/ })
    .first();
  await clickLocator(page, sharedMode, "settings pane model shared mode", { settleMs: 200 });
  await page.waitForFunction(() => {
    const provider = document.querySelector("#runtime-worker-default-provider");
    const model = document.querySelector("#runtime-worker-default-model");
    const effort = document.querySelector("#runtime-worker-default-effort");
    return provider instanceof HTMLSelectElement && !provider.disabled
      && model instanceof HTMLSelectElement && !model.disabled
      && effort instanceof HTMLSelectElement && !effort.disabled
      && document.querySelectorAll(".runtime-model-slot-row").length === 0;
  });
}

async function testSettings(page) {
  await clickSelector(page, "#activity-settings-btn", "settings open");
  await page.locator("#settings-sheet").waitFor({ state: "visible" });
  await testPaneModelSettings(page);
  await clickAll(page, "#settings-tab-user, #settings-tab-workspace", "settings scope tab");
  await clickAll(page, "#settings-nav .settings-nav-item", "settings nav");
  await clickAll(page, ".settings-option-chip", "settings option chip");
  await clickSelector(page, "#settings-tab-user", "settings user scope restore");
  await clickSelector(page, "#settings-nav-common", "settings common nav restore");
  await page.locator("#editor-font-size-input").scrollIntoViewIfNeeded();
  await page.locator("#editor-font-size-input").fill("15");
  recordClick("settings editor font size input");
  await clickSelector(page, "#editor-font-size-reset-btn", "settings font size reset");
  await page.locator("#settings-font-family-input").fill("Consolas, 'Courier New', monospace");
  recordClick("settings font family input");
  await clickSelector(page, "#settings-font-family-menu-btn", "settings font family menu");
  await clickAll(page, "#settings-font-family-menu .settings-popover-item", "settings font family item");
  await page.locator("#voice-shortcut-input").scrollIntoViewIfNeeded();
  await page.click("#voice-shortcut-input");
  await page.keyboard.press("Control+Shift+Y");
  recordClick("settings voice shortcut input");
  await clickSelector(page, "#voice-shortcut-reset-btn", "settings voice shortcut reset");
  await page.locator("#voice-draft-storage-input").scrollIntoViewIfNeeded();
  await page.locator("#voice-draft-storage-input").check();
  recordClick("settings voice draft checkbox on");
  await page.locator("#voice-draft-storage-input").uncheck();
  recordClick("settings voice draft checkbox off");
  await clickSelector(page, "#apply-settings-btn", "settings apply");
  await clickSelector(page, "#close-settings-btn", "settings close");
}

async function testSourceAndExplorer(page) {
  await ensureSidebarMode(page, "source", "#activity-source-btn", "source open");
  await page.locator("#source-control-view").waitFor({ state: "visible" });
  await page.locator("#source-control-message").fill("clickable coverage harness");
  recordClick("source control message input");
  await clickSelector(page, "#source-control-commit-btn", "source commit");
  await page.locator("#source-control-message").fill("clickable coverage title commit");
  recordClick("source control title message input");
  await clickSelector(page, "#source-control-title-commit-btn", "source title commit");
  await clickSelector(page, "#source-control-refresh-btn", "source refresh");
  await clickSelector(page, "#source-control-graph-refresh-btn", "source graph refresh");
  await clickSelector(page, "#source-control-graph-fetch-btn", "source graph fetch");

  for (const menuId of ["#source-control-more-btn", "#source-control-graph-more-btn"]) {
    await clickSelector(page, menuId, `${menuId} open`);
    const count = await page.locator(".source-control-actions-menu .explorer-context-menu-item").count();
    await page.keyboard.press("Escape");
    for (let index = 0; index < count; index += 1) {
      await clickSelector(page, menuId, `${menuId} reopen ${index + 1}`);
      const item = page.locator(".source-control-actions-menu .explorer-context-menu-item").nth(index);
      await clickLocator(page, item, `${menuId} menu item ${index + 1}`);
      await recoverShell(page);
      await ensureSidebarMode(page, "source", "#activity-source-btn", "source restore after menu item");
    }
  }

  await clickAll(page, "#source-summary-list .source-entry-row", "source summary row");
  await clickAll(page, "#source-entry-list .source-entry-row", "source entry row");
  await clickAll(page, "#source-control-changes-list .source-control-file-row", "source change row");
  await clickAll(page, "#source-control-graph-list .source-control-graph-row", "source graph row");

  await ensureSidebarMode(page, "evidence", "#activity-evidence-btn", "evidence open");
  await clickAll(page, "#evidence-list .evidence-row", "evidence row");

  await ensureSidebarMode(page, "explorer", "#activity-explorer-btn", "explorer open");
  const folder = page.locator("#explorer-list .sidebar-tree-row.is-folder").first();
  await clickLocator(page, folder, "explorer folder row");
  const file = page.locator("#explorer-list .sidebar-tree-row.is-file").first();
  await clickLocator(page, file, "explorer file row", { force: true });
  await recoverShell(page);
}

async function openHarnessEditor(page) {
  await page.evaluate(() => {
    window.__winsmuxViewportHarness?.openEditorPreview(
      "winsmux-app/src/main.ts",
      "export const clickableCoverage = true;\n",
    );
  });
  await page.locator("#editor-surface").waitFor({ state: "visible" });
}

async function openHarnessPreview(page, previewUrl) {
  await page.evaluate((url) => {
    window.__winsmuxViewportHarness?.registerPreviewTarget("clickable-coverage", url);
    window.__winsmuxViewportHarness?.openPreviewTarget(url);
  }, `${previewUrl}${HARNESS_QUERY}`);
  await page.locator("#browser-surface").waitFor({ state: "visible" });
}

async function testEditorAndBrowser(page, previewUrl) {
  await recoverShell(page);
  await openHarnessEditor(page);
  await clickAll(page, "#editor-tabs .editor-tab", "editor tab");
  await openHarnessEditor(page);
  await clickSelector(page, "#popout-editor-btn", "editor popout");
  await openHarnessEditor(page);
  await clickSelector(page, "#close-editor-btn", "editor close");

  await openHarnessPreview(page, previewUrl);
  await clickSelector(page, "#browser-copy-btn", "browser copy");
  await clickSelector(page, "#browser-reload-btn", "browser reload");
  await clickAll(page, "#browser-target-list .editor-tab", "browser target tab");
  await clickSelector(page, "#browser-open-btn", "browser open external");
  await clickSelector(page, "#popout-editor-btn", "browser popout");
  await openHarnessPreview(page, previewUrl);
  await clickSelector(page, "#browser-back-btn", "browser back to code");
}

async function testWorkbench(page) {
  await recoverShell(page);
  await clickWorkbenchLayoutUntil(page, "3x2");
  await clickWorkbenchLayoutUntil(page, "focus");
  await page.locator("#focused-pane-select").waitFor({ state: "visible" });
  const options = await page.locator("#focused-pane-select option").count();
  if (options > 1) {
    const value = await page.locator("#focused-pane-select option").nth(options - 1).getAttribute("value");
    await page.selectOption("#focused-pane-select", value ?? "worker-1");
    recordClick("workbench focused pane select");
  }
  const statusPill = await ensureWorkerStatusStripVisible(page);
  await clickLocator(page, statusPill, "workbench worker status pill");
  await page.waitForFunction(() => {
    const drawer = document.querySelector("#terminal-drawer");
    const detail = document.querySelector(".worker-status-detail-strip");
    return drawer?.getAttribute("data-focused-pane") === "worker-2"
      && detail?.getAttribute("data-worker-status-detail") === "worker-2";
  });
  await clickWorkbenchLayoutUntil(page, "2x2");
  await clickSelector(page, "#add-pane-btn", "workbench add pane");
  await clickLocator(page, page.locator("#panes-container .pane-close").last(), "workbench pane close");
  await clickSelector(page, "#close-terminal-drawer-btn", "workbench close drawer");
  await page.locator("#terminal-drawer").waitFor({ state: "hidden" });
  await clickSelector(page, "#toggle-terminal-btn", "workbench reopen drawer");
}

async function clickWorkbenchLayoutUntil(page, expectedLayout) {
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const currentLayout = await page.locator("#terminal-drawer").getAttribute("data-layout");
    if (currentLayout === expectedLayout) {
      return;
    }
    await clickSelector(page, "#workbench-layout-btn", `workbench layout ${expectedLayout}`);
  }
  const actualLayout = await page.locator("#terminal-drawer").getAttribute("data-layout");
  throw new Error(`Expected workbench layout ${expectedLayout}, got ${actualLayout}`);
}

async function testComposer(page) {
  await recoverShell(page);
  if (await page.locator("#editor-surface").isVisible().catch(() => false)) {
    await clickSelector(page, "#close-editor-btn", "composer restore conversation surface");
  }
  await page.locator("#composer-input").waitFor({ state: "visible" });
  await page.locator("#composer-input").fill("clickable coverage message");
  recordClick("composer textarea");
  await clickSelector(page, "#send-btn", "composer send");
  await page.locator("#composer-input").fill("");
  await clickSelector(page, "#voice-input-btn", "composer voice start");
  await page.waitForFunction(() => document.querySelector("#voice-input-btn")?.getAttribute("aria-pressed") === "true");
  await clickSelector(page, "#voice-input-btn", "composer voice stop");
  await clickAll(page, ".composer-session-trigger-permission", "composer permission trigger");
  if (await page.locator("#composer-permission-menu").isVisible().catch(() => false)) {
    await clickAll(page, "#composer-permission-menu .composer-session-option", "composer permission option");
  }
  await clickAll(page, ".composer-session-trigger-model", "composer model trigger");
  if (await page.locator("#composer-model-menu").isVisible().catch(() => false)) {
    await clickAll(page, "#composer-model-menu .composer-session-option", "composer model option");
    await clickAll(page, "#composer-model-menu .composer-fast-toggle", "composer fast toggle");
  }
  await clickSelector(page, "#attach-btn", "composer attach", {
    fileChooser: true,
    filePath: path.join(OUTPUT_DIR, "sample-attachment.txt"),
  });
  await clickAll(page, "#attachment-tray button", "attachment tray button");
}

async function run() {
  await ensureOutputDir();
  await fs.writeFile(path.join(OUTPUT_DIR, "sample-attachment.txt"), "clickable coverage attachment\n", "utf8");

  const previewPort = await getAvailablePort();
  const previewUrl = `http://127.0.0.1:${previewPort}`;
  const previewServer = startPreviewServer(previewPort);
  let browser;
  try {
    await waitForPreviewServer(previewUrl);
    browser = await chromium.launch({ headless: true });
    for (const viewport of VIEWPORTS) {
      currentViewportName = viewport.name;
      process.stdout.write(`[clickable] viewport ${viewport.name} ${viewport.width}x${viewport.height}\n`);
      const page = await browser.newPage({ viewport: { width: viewport.width, height: viewport.height } });
      attachErrorCapture(page);
      await installBrowserStubs(page);
      await page.goto(`${previewUrl}${HARNESS_QUERY}`, { waitUntil: "networkidle" });
      await waitForAppReady(page);
      await runStep(`${viewport.name}: initial default chrome`, () => testInitialDefaultChrome(page));
      await recordVisibleInteractives(page, "initial");

      await runStep(`${viewport.name}: view menu stateful toggles`, () => testViewMenuStateful(page));
      await runStep(`${viewport.name}: top menus`, () => testTopMenus(page));
      await recordVisibleInteractives(page, "after-top-menus");
      await runStep(`${viewport.name}: navigation and footer`, () => testNavigationAndFooter(page));
      await runStep(`${viewport.name}: command bar`, () => testCommandBar(page));
      await runStep(`${viewport.name}: settings`, () => testSettings(page));
      await runStep(`${viewport.name}: source, evidence, explorer`, () => testSourceAndExplorer(page));
      await runStep(`${viewport.name}: editor and browser`, () => testEditorAndBrowser(page, previewUrl));
      await runStep(`${viewport.name}: workbench`, () => testWorkbench(page));
      await runStep(`${viewport.name}: composer`, () => testComposer(page));
      await recordVisibleInteractives(page, "final");
      await page.close().catch(() => {});
    }

    await fs.writeFile(
      path.join(OUTPUT_DIR, "clickable-coverage.json"),
      JSON.stringify(
        {
          ok: true,
          generatedAt: new Date().toISOString(),
          previewUrl,
          viewports: VIEWPORTS,
          clicked,
          skipped,
          observed,
          consoleErrors,
          pageErrors,
        },
        null,
        2,
      ),
      "utf8",
    );
  } catch (error) {
    if (browser) {
      const page = browser.contexts()[0]?.pages()[0];
      if (page) {
        await page.screenshot({
          path: path.join(OUTPUT_DIR, "clickable-coverage-failure.png"),
          fullPage: true,
        }).catch(() => {});
      }
    }
    await fs.writeFile(
      path.join(OUTPUT_DIR, "clickable-coverage.json"),
      JSON.stringify(
        {
          ok: false,
          generatedAt: new Date().toISOString(),
          previewUrl,
          viewports: VIEWPORTS,
          error: error instanceof Error ? error.message : String(error),
          clicked,
          skipped,
          observed,
          consoleErrors,
          pageErrors,
        },
        null,
        2,
      ),
      "utf8",
    );
    throw error;
  } finally {
    if (browser) {
      await browser.close().catch(() => {});
    }
    await stopPreviewServer(previewServer);
  }
}

run()
  .then(() => {
    process.exit(0);
  })
  .catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  });
