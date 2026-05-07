import { spawn } from "node:child_process";
import { once } from "node:events";
import fs from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import process from "node:process";
import { chromium } from "playwright";

const OUTPUT_DIR = path.join(process.cwd(), "output", "playwright", "viewport-harness");
const HARNESS_QUERY = "?viewport-harness=1";
const APP_DIR = process.cwd();

async function assertOperatorChatContractSource() {
  const source = await fs.readFile(path.join(APP_DIR, "src", "main.ts"), "utf8");
  const forbiddenSnippets = [
    "Sent to operator",
    "オペレーターへ送信",
    "The request was sent to the operator session.",
    "依頼内容をオペレーターセッションへ送信しました。",
  ];
  const matched = forbiddenSnippets.filter((snippet) => source.includes(snippet));
  if (matched.length > 0) {
    throw new Error(
      `Operator chat must mirror Claude Code output without internal sent acknowledgements: ${matched.join(", ")}`,
    );
  }
}

async function ensureOutputDir() {
  await fs.mkdir(OUTPUT_DIR, { recursive: true });
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
      // Ignore connection errors until the timeout expires.
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  throw new Error(`Preview server did not start within ${timeoutMs}ms`);
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

function startPreviewServer(previewPort) {
  const child = spawn(
    process.platform === "win32" ? "cmd.exe" : "npm",
    process.platform === "win32"
      ? ["/c", "npm", "run", "preview", "--", "--host", "127.0.0.1", "--port", `${previewPort}`, "--strictPort"]
      : ["run", "preview", "--", "--host", "127.0.0.1", "--port", `${previewPort}`, "--strictPort"],
    {
      cwd: process.cwd(),
      stdio: ["ignore", "pipe", "pipe"],
    },
  );

  child.stdout.on("data", (chunk) => {
    process.stdout.write(chunk);
  });
  child.stderr.on("data", (chunk) => {
    process.stderr.write(chunk);
  });

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
    return;
  }

  child.kill("SIGTERM");
  await once(child, "exit").catch(() => {});
}

async function getBox(page, selector) {
  const locator = page.locator(selector);
  await locator.waitFor({ state: "visible" });
  const box = await locator.boundingBox();
  if (!box) {
    throw new Error(`${selector} does not have a visible bounding box`);
  }
  return box;
}

function boxesOverlap(a, b) {
  return !(
    a.x + a.width <= b.x ||
    b.x + b.width <= a.x ||
    a.y + a.height <= b.y ||
    b.y + b.height <= a.y
  );
}

async function runStep(name, action) {
  try {
    await action();
  } catch (error) {
    if (error instanceof Error) {
      error.message = `${name}: ${error.message}`;
    }
    throw error;
  }
}

async function assertFullyVisible(page, selector) {
  await page.locator(selector).scrollIntoViewIfNeeded().catch(() => {});
  const box = await getBox(page, selector);
  const viewport = page.viewportSize();
  if (!viewport) {
    throw new Error("Viewport size is unavailable");
  }
  if (
    box.x < 0 ||
    box.y < 0 ||
    box.x + box.width > viewport.width ||
    box.y + box.height > viewport.height
  ) {
    throw new Error(`${selector} is clipped by the viewport`);
  }
}

async function assertHorizontallyVisible(page, selector) {
  await page.locator(selector).scrollIntoViewIfNeeded().catch(() => {});
  const box = await getBox(page, selector);
  const viewport = page.viewportSize();
  if (!viewport) {
    throw new Error("Viewport size is unavailable");
  }
  if (box.x < 0 || box.x + box.width > viewport.width) {
    throw new Error(`${selector} is clipped horizontally`);
  }
}

async function assertNoOverlap(page, firstSelector, secondSelector) {
  const first = await getBox(page, firstSelector);
  const second = await getBox(page, secondSelector);
  if (boxesOverlap(first, second)) {
    throw new Error(`${firstSelector} overlaps ${secondSelector}`);
  }
}

async function assertButtonVisible(page, selector) {
  await assertFullyVisible(page, selector);
  const disabled = await page.locator(selector).isDisabled();
  if (disabled) {
    throw new Error(`${selector} is disabled`);
  }
}

async function assertToolbarActionStates(page) {
  const summary = page.locator("#browser-toolbar-summary");
  await summary.waitFor({ state: "visible" });

  await assertButtonVisible(page, "#browser-copy-btn");
  await page.click("#browser-copy-btn");
  await page.waitForFunction(() => {
    const target = document.querySelector("#browser-toolbar-summary");
    if (!(target instanceof HTMLElement)) {
      return false;
    }
    return target.textContent?.includes("copied") || target.textContent?.includes("copy failed");
  });

  await assertButtonVisible(page, "#browser-open-btn");
  const popupPromise = page.context().waitForEvent("page", { timeout: 2_000 }).catch(() => null);
  await page.click("#browser-open-btn");
  await page.waitForFunction(() => {
    const target = document.querySelector("#browser-toolbar-summary");
    if (!(target instanceof HTMLElement)) {
      return false;
    }
    return target.textContent?.includes("external open") || target.textContent?.includes("external blocked");
  });
  const popup = await popupPromise;
  if (popup) {
    await popup.close().catch(() => {});
  }
}

async function assertReachableFrame(page, selector) {
  const locator = page.locator(selector);
  await locator.scrollIntoViewIfNeeded();
  await assertHorizontallyVisible(page, selector);
  const box = await getBox(page, selector);
  if (box.height < 120) {
    throw new Error(`${selector} is too small to use`);
  }
}

async function waitForHorizontalVisibility(page, selector) {
  await page.waitForFunction((targetSelector) => {
    const target = document.querySelector(targetSelector);
    if (!(target instanceof HTMLElement)) {
      return false;
    }
    const rect = target.getBoundingClientRect();
    return rect.x >= 0 && rect.right <= window.innerWidth;
  }, selector);
}

async function registerHarnessPreviewTarget(page, previewUrl) {
  await page.waitForFunction(() => Boolean(window.__winsmuxViewportHarness));
  await page.evaluate((url) => {
    window.__winsmuxViewportHarness?.registerPreviewTarget("viewport-harness", url);
  }, previewUrl);
}

async function openHarnessPreviewTarget(page, previewUrl) {
  await page.waitForFunction(() => Boolean(window.__winsmuxViewportHarness));
  await page.evaluate((url) => {
    window.__winsmuxViewportHarness?.openPreviewTarget(url);
  }, previewUrl);
}

async function openFirstSourceContextEntry(page) {
  await page.waitForFunction(() => Boolean(window.__winsmuxViewportHarness));
  await page.evaluate(() => {
    window.__winsmuxViewportHarness?.openEditorPreview(
      "winsmux-app/src/main.ts",
      [
        "const viewportHarnessPreview = true;",
        "function sampleViewportState() {",
        "  return 'context + editor';",
        "}",
      ].join("\n"),
    );
  });
  await page.locator("#editor-surface").waitFor({ state: "visible" });
  await page.locator("#editor-tabs .editor-tab").first().waitFor({ state: "visible" });
  await assertHorizontallyVisible(page, "#editor-surface");
  await assertHorizontallyVisible(page, "#editor-file-path");
}

async function assertBackToCode(page) {
  await page.click("#browser-back-btn");
  await page.locator("#browser-surface").waitFor({ state: "hidden" });
  await page.locator("#editor-code").waitFor({ state: "visible" });
  await page.locator("#editor-tabs .editor-tab").first().waitFor({ state: "visible" });
  await assertHorizontallyVisible(page, "#editor-surface");
  await assertHorizontallyVisible(page, "#editor-code");
}

async function assertPopoutShell(popup, visibleSelector) {
  await popup.locator(visibleSelector).waitFor({ state: "visible" });
  const isPopout = await popup.evaluate(() => document.body.dataset.popoutSurface === "1");
  if (!isPopout) {
    throw new Error("Pop-out window did not enter detached surface mode");
  }
  await popup.locator("#workspace-header").waitFor({ state: "visible" });
  await popup.waitForFunction(() => {
    const title = document.querySelector("#workspace-title");
    const subtitle = document.querySelector("#workspace-subtitle");
    return (
      title instanceof HTMLElement &&
      subtitle instanceof HTMLElement &&
      Boolean(title.textContent?.trim()) &&
      subtitle.textContent?.includes("Detached secondary surface")
    );
  });
  await popup.locator("#conversation-panel").waitFor({ state: "hidden" });
  await popup.locator("#context-panel").waitFor({ state: "hidden" });
  await popup.locator("#workspace-footer").waitFor({ state: "hidden" });
  await popup.locator("#header-actions").waitFor({ state: "hidden" });
  await assertHorizontallyVisible(popup, "#editor-surface");
}

async function closePopoutByEditorButton(popup) {
  const closePromise = popup.waitForEvent("close");
  await popup.click("#close-editor-btn").catch((error) => {
    if (!String(error).includes("Target page, context or browser has been closed")) {
      throw error;
    }
  });
  await closePromise;
}

async function assertDetachedSessionEntry(page, expectedName) {
  await page.waitForFunction((name) => {
    const rows = Array.from(document.querySelectorAll("#session-list .sidebar-row"));
    return rows.some((row) => {
      const title = row.querySelector(".sidebar-row-title");
      return title instanceof HTMLElement && title.textContent?.trim() === name;
    });
  }, expectedName);
}

async function assertDetachedSessionEntryCleared(page, expectedName) {
  await page.waitForFunction((name) => {
    const rows = Array.from(document.querySelectorAll("#session-list .sidebar-row"));
    return rows.every((row) => {
      const title = row.querySelector(".sidebar-row-title");
      return !(title instanceof HTMLElement) || title.textContent?.trim() !== name;
    });
  }, expectedName);
}

async function assertPreviewPopout(page) {
  const popupPromise = page.waitForEvent("popup");
  await page.click("#popout-editor-btn");
  const popup = await popupPromise;
  await assertDetachedSessionEntry(page, "detached-preview");
  await assertPopoutShell(popup, "#browser-surface");
  await popup.locator("#browser-frame").waitFor({ state: "visible" });
  await popup.locator("#browser-toolbar").waitFor({ state: "visible" });
  await closePopoutByEditorButton(popup);
  await assertDetachedSessionEntryCleared(page, "detached-preview");
  await page.locator("#browser-surface").waitFor({ state: "visible" });
  await page.locator("#browser-toolbar").waitFor({ state: "visible" });
  await assertHorizontallyVisible(page, "#editor-surface");
}

async function assertEditorPopout(page) {
  const popupPromise = page.waitForEvent("popup");
  await page.click("#popout-editor-btn");
  const popup = await popupPromise;
  await assertDetachedSessionEntry(page, "detached-editor");
  await assertPopoutShell(popup, "#editor-code");
  await popup.locator("#editor-file-path").waitFor({ state: "visible" });
  await popup.locator("#editor-statusbar").waitFor({ state: "visible" });
  await popup.waitForFunction(() => {
    const target = document.querySelector("#editor-code");
    return target instanceof HTMLElement && target.textContent?.includes("context + editor");
  });
  await closePopoutByEditorButton(popup);
  await assertDetachedSessionEntryCleared(page, "detached-editor");
  await page.locator("#editor-code").waitFor({ state: "visible" });
  await page.waitForFunction(() => {
    const target = document.querySelector("#editor-code");
    return target instanceof HTMLElement && target.textContent?.includes("context + editor");
  });
  await assertHorizontallyVisible(page, "#editor-surface");
}

async function assertPreviewClosed(page) {
  await page.click("#browser-back-btn");
  await page.locator("#browser-surface").waitFor({ state: "hidden" });
  if (await page.locator("#editor-surface").isVisible().catch(() => false)) {
    await page.locator("#editor-code").waitFor({ state: "visible" });
  }
}

async function installSpeechRecognitionStub(page) {
  await page.addInitScript(() => {
    class MockSpeechRecognition {
      constructor() {
        this.continuous = false;
        this.interimResults = false;
        this.lang = "en-US";
        this.onerror = null;
        this.onend = null;
        this.onresult = null;
        this.onstart = null;
      }

      start() {
        this.onstart?.();
      }

      stop() {
        this.onend?.();
      }

      abort() {
        this.onend?.();
      }
    }

    window.SpeechRecognition = MockSpeechRecognition;
    window.webkitSpeechRecognition = MockSpeechRecognition;
  });
}

async function assertCommandBarRoundtrip(page, returnSelector) {
  await page.click("#activity-search-btn");
  await page.locator("#command-bar-shell").waitFor({ state: "visible" });
  await assertFullyVisible(page, "#command-bar");
  await assertButtonVisible(page, "#command-bar-input");
  await page.keyboard.press("Escape");
  await page.locator("#command-bar-shell").waitFor({ state: "hidden" });
  await page.locator(returnSelector).waitFor({ state: "visible" });
}

async function assertSettingsRoundtrip(page, returnSelector) {
  await page.click("#activity-settings-btn");
  await page.locator("#settings-sheet").waitFor({ state: "visible" });
  await assertFullyVisible(page, "#settings-sheet");
  await assertButtonVisible(page, "#close-settings-btn");
  await page.locator("#theme-options", { hasText: "Codex TUI Dark" }).waitFor();
  await page.locator("#theme-options", { hasText: "Graphite" }).waitFor();
  await page.locator("#density-options", { hasText: "Comfortable" }).waitFor();
  await page.locator("#wrap-options", { hasText: "Balanced" }).waitFor();
  await page.locator("#editor-font-size-input").waitFor();
  await page.locator("#settings-font-family-input").waitFor();
  await assertButtonVisible(page, "#settings-font-family-menu-btn");
  await page.locator("#focus-mode-options", { hasText: "Focus" }).waitFor();
  await page.waitForFunction(() => {
    const input = document.querySelector("#editor-font-size-input");
    return input instanceof HTMLInputElement && input.value === "14";
  });
  await page.waitForFunction(() => {
    const input = document.querySelector("#settings-font-family-input");
    return input instanceof HTMLInputElement &&
      input.value === "Consolas, 'Courier New', monospace";
  });
  await page.click("#settings-font-family-menu-btn");
  await page.locator("#settings-font-family-menu").waitFor({ state: "visible" });
  await page.locator("#settings-font-family-menu", { hasText: "JetBrains Mono" }).waitFor();
  await page.locator("#settings-font-family-menu .settings-popover-item", { hasText: "JetBrains Mono" }).click();
  await page.waitForFunction(() => {
    const input = document.querySelector("#settings-font-family-input");
    return input instanceof HTMLInputElement && input.value.startsWith("JetBrains Mono");
  });
  await page.waitForFunction(() => {
    const provider = document.querySelector("#runtime-provider-operator");
    const model = document.querySelector("#runtime-model-operator");
    const source = document.querySelector("#runtime-model-source-operator");
    const effort = document.querySelector("#runtime-reasoning-operator");
    return provider instanceof HTMLSelectElement &&
      provider.value === "claude" &&
      provider.disabled &&
      model instanceof HTMLInputElement &&
      model.disabled &&
      source instanceof HTMLSelectElement &&
      source.disabled &&
      effort instanceof HTMLSelectElement &&
      effort.disabled;
  });
  await page.locator("#voice-shortcut-input").waitFor();
  await page.locator("#voice-shortcut-input").scrollIntoViewIfNeeded();
  await page.waitForFunction(() => {
    const input = document.querySelector("#voice-shortcut-input");
    return input instanceof HTMLInputElement && input.value === "Ctrl+Alt+M";
  });
  await page.click("#voice-shortcut-input");
  await page.keyboard.press("Control+Space");
  await page.locator("#voice-shortcut-warning", { hasText: "conflicts" }).waitFor({ state: "visible" });
  await page.waitForFunction(() => {
    const apply = document.querySelector("#apply-settings-btn");
    return apply instanceof HTMLButtonElement && apply.disabled;
  });
  await page.click("#voice-shortcut-reset-btn");
  await page.waitForFunction(() => {
    const input = document.querySelector("#voice-shortcut-input");
    const warning = document.querySelector("#voice-shortcut-warning");
    return input instanceof HTMLInputElement &&
      input.value === "Ctrl+Alt+M" &&
      warning instanceof HTMLElement &&
      warning.hidden;
  });
  await page.keyboard.press("Escape");
  await page.locator("#settings-sheet").waitFor({ state: "visible" });
  await page.click("#close-settings-btn");
  await page.locator("#settings-sheet").waitFor({ state: "hidden" });
  await page.locator(returnSelector).waitFor({ state: "visible" });
}

async function assertNarrowSettingsRoundtrip(page, returnSelector) {
  await page.locator("#activity-explorer-btn[aria-expanded='false']").waitFor();
  await page.click("#activity-explorer-btn");
  await page.locator("#activity-explorer-btn[aria-expanded='true']").waitFor();
  await waitForHorizontalVisibility(page, "#left-rail");
  await assertHorizontallyVisible(page, "#left-rail");
  await assertFullyVisible(page, "#sidebar-overlay");
  await assertSettingsRoundtrip(page, returnSelector);
  const viewport = page.viewportSize();
  if (!viewport) {
    throw new Error("Viewport size is unavailable");
  }
  await page.mouse.click(viewport.width - 10, 24);
  await page.locator("#activity-explorer-btn[aria-expanded='false']").waitFor();
}

async function assertTerminalDrawerWithSourceContext(page, returnSelector, extraSelector) {
  await ensureWorkbenchOpen(page);
  await page.locator("#terminal-drawer").waitFor({ state: "visible" });
  await assertFullyVisible(page, "#add-pane-btn");
  await assertHorizontallyVisible(page, "#terminal-drawer");
  await page.locator("#panes-container .pane").first().waitFor({ state: "visible" });
  await page.locator(returnSelector).waitFor({ state: "visible" });
  if (extraSelector) {
    await page.locator(extraSelector).waitFor({ state: "visible" });
    await assertHorizontallyVisible(page, extraSelector);
  }
  await page.locator(returnSelector).waitFor({ state: "visible" });
}

async function ensureContextPanelOpen(page) {
  const contextPanel = page.locator("#context-panel");
  if (await contextPanel.isVisible().catch(() => false)) {
    return;
  }
  await page.click("#activity-context-btn");
  await contextPanel.waitFor({ state: "visible" });
}

async function ensureWorkbenchOpen(page) {
  const workbench = page.locator("#terminal-drawer");
  if (await workbench.isVisible().catch(() => false)) {
    return;
  }
  await page.waitForFunction(() => Boolean(window.__winsmuxViewportHarness));
  await page.evaluate(() => {
    window.__winsmuxViewportHarness?.setTerminalDrawer(true);
  });
  await workbench.waitFor({ state: "visible" });
}

async function assertWorkbenchPaneGrid(page, expectedMin = 4) {
  await ensureWorkbenchOpen(page);
  await assertHorizontallyVisible(page, "#terminal-drawer");
  await assertButtonVisible(page, "#workbench-layout-btn");
  await assertFullyVisible(page, "#add-pane-btn");
  await page.waitForFunction((minCount) => {
    return document.querySelectorAll("#panes-container .pane").length >= minCount;
  }, expectedMin);
}

async function setShellLanguage(page, language) {
  await page.evaluate((nextLanguage) => {
    const key = "winsmux.shell.preferences.v1";
    const current = JSON.parse(window.localStorage.getItem(key) ?? "{}");
    window.localStorage.setItem(
      key,
      JSON.stringify({
        theme: "codex-dark",
        density: "comfortable",
        wrapMode: "balanced",
        codeFont: "system",
        codeFontFamily: "Consolas, 'Courier New', monospace",
        editorFontSize: 14,
        focusMode: "standard",
        sidebarWidth: 292,
        workbenchWidth: null,
        wideSidebarOpen: true,
        wideContextOpen: false,
        workbenchOpen: true,
        workbenchLayout: "2x2",
        focusedWorkbenchPaneId: null,
        ...current,
        language: nextLanguage,
      }),
    );
  }, language);
}

async function assertComposerSessionControls(page, previewUrl) {
  await page.locator("#composer-mode-row").waitFor({ state: "hidden" });
  await page.locator(".composer-session-trigger-permission", { hasText: "Approve edits" }).waitFor();
  await page.locator(".composer-session-trigger-model", { hasText: "Opus 4.7 1M・Ultra" }).waitFor();

  await page.evaluate(() => {
    localStorage.setItem("winsmux.composer-session.v1", JSON.stringify({
      permissionMode: "default",
      model: "opus-4.7-1m",
      effort: "xhigh",
      fastModeEnabled: false,
    }));
  });
  await page.reload({ waitUntil: "networkidle" });
  await page.locator(".composer-session-trigger-permission", { hasText: "Ask before edits" }).waitFor();

  await page.evaluate(() => {
    localStorage.setItem("winsmux.composer-session.v1", JSON.stringify({
      permissionMode: "auto",
      model: "opus-4.7-1m",
      effort: "xhigh",
      fastModeEnabled: false,
    }));
  });
  await page.reload({ waitUntil: "networkidle" });
  await page.locator(".composer-session-trigger-permission", { hasText: "Ask before edits" }).waitFor();

  await page.evaluate(() => {
    localStorage.setItem("winsmux.composer-session.v1", JSON.stringify({
      permissionMode: "acceptEdits",
      model: "opus-4.7-1m",
      effort: "xhigh",
      fastModeEnabled: false,
    }));
  });
  await page.reload({ waitUntil: "networkidle" });
  await page.locator(".composer-session-trigger-permission", { hasText: "Approve edits" }).waitFor();

  await page.click(".composer-session-trigger-permission");
  await page.locator("#composer-permission-menu", { hasText: "Mode" }).waitFor();
  await page.locator("#composer-permission-menu .composer-session-option", { hasText: "Plan mode" }).click();
  await page.locator(".composer-session-trigger-permission", { hasText: "Plan mode" }).waitFor();

  await page.click(".composer-session-trigger-model");
  await page.locator("#composer-model-menu", { hasText: "Model" }).waitFor();
  await page.locator("#composer-model-menu", { hasText: "Effort" }).waitFor();
  await page.locator("#composer-model-menu", { hasText: "Fast mode" }).waitFor();
  await page.locator("#composer-model-menu .composer-session-option", { hasText: "Max" }).click();
  await page.locator("#composer-model-menu .composer-session-option", { hasText: "Sonnet 4.6" }).click();
  await page.locator(".composer-session-trigger-model", { hasText: "Sonnet 4.6・Max" }).waitFor();
  await page.waitForFunction(() => {
    const toggle = document.querySelector("#composer-model-menu .composer-fast-toggle");
    return toggle instanceof HTMLButtonElement &&
      toggle.disabled &&
      toggle.getAttribute("aria-checked") === "false" &&
      toggle.textContent?.includes("Opus 4.6");
  });
  await page.locator("#composer-model-menu .composer-session-option", { hasText: "Opus 4.6" }).click();
  await page.locator(".composer-session-trigger-model", { hasText: "Opus 4.6・Max" }).waitFor();
  await page.locator("#composer-model-menu .composer-fast-toggle").click();
  await page.locator("#composer-model-menu .composer-fast-toggle[aria-checked='true']").waitFor();

  await page.reload({ waitUntil: "networkidle" });
  await page.locator(".composer-session-trigger-permission", { hasText: "Plan mode" }).waitFor();
  await page.locator(".composer-session-trigger-model", { hasText: "Opus 4.6・Max" }).waitFor();
  const startupInputs = await page.evaluate(() => [
    window.__winsmuxViewportHarness?.getOperatorStartupInput(),
    window.__winsmuxViewportHarness?.getOperatorStartupInput(),
    JSON.parse(localStorage.getItem("winsmux.composer-session.v1") || "{}"),
  ]);
  if (!String(startupInputs[0]).includes("/fast\r")) {
    throw new Error("Fast mode toggle was not sent once after enabling Opus 4.6 fast mode");
  }
  if (String(startupInputs[1]).includes("/fast\r")) {
    throw new Error("Fast mode toggle was sent more than once after enabling Opus 4.6 fast mode");
  }
  if (startupInputs[2]?.fastModeEnabled !== true || startupInputs[2]?.fastModeTogglePending !== false) {
    throw new Error("Fast mode persisted state did not keep enabled mode with the launch toggle consumed");
  }
  await page.click(".composer-session-trigger-model");
  await page.locator("#composer-model-menu .composer-session-option", { hasText: "Sonnet 4.6" }).click();
  await page.locator(".composer-session-trigger-model", { hasText: "Sonnet 4.6・Max" }).waitFor();
  await page.reload({ waitUntil: "networkidle" });
  await page.locator(".composer-session-trigger-model", { hasText: "Sonnet 4.6・Max" }).waitFor();
  const modelSwitchDisableStartupInputs = await page.evaluate(() => [
    window.__winsmuxViewportHarness?.getOperatorStartupInput(),
    window.__winsmuxViewportHarness?.getOperatorStartupInput(),
    JSON.parse(localStorage.getItem("winsmux.composer-session.v1") || "{}"),
  ]);
  if (!String(modelSwitchDisableStartupInputs[0]).includes("/fast\r")) {
    throw new Error("Fast mode toggle was not sent once after switching away from Opus 4.6 fast mode");
  }
  if (String(modelSwitchDisableStartupInputs[1]).includes("/fast\r")) {
    throw new Error("Fast mode model-switch disable toggle was sent more than once");
  }
  if (modelSwitchDisableStartupInputs[2]?.fastModeEnabled !== false || modelSwitchDisableStartupInputs[2]?.fastModeTogglePending !== false) {
    throw new Error("Fast mode model-switch disable did not persist with the launch toggle consumed");
  }
  await page.click(".composer-session-trigger-model");
  await page.locator("#composer-model-menu .composer-session-option", { hasText: "Opus 4.6" }).click();
  await page.locator(".composer-session-trigger-model", { hasText: "Opus 4.6・Max" }).waitFor();
  await page.locator("#composer-model-menu .composer-fast-toggle").click();
  await page.locator("#composer-model-menu .composer-fast-toggle[aria-checked='true']").waitFor();
  const modelSwitchReenableStartupInputs = await page.evaluate(() => [
    window.__winsmuxViewportHarness?.getOperatorStartupInput(),
    window.__winsmuxViewportHarness?.getOperatorStartupInput(),
    JSON.parse(localStorage.getItem("winsmux.composer-session.v1") || "{}"),
  ]);
  if (!String(modelSwitchReenableStartupInputs[0]).includes("/fast\r")) {
    throw new Error("Fast mode toggle was not sent once after re-enabling Opus 4.6 fast mode");
  }
  if (String(modelSwitchReenableStartupInputs[1]).includes("/fast\r")) {
    throw new Error("Fast mode re-enable toggle was sent more than once");
  }
  await page.locator("#composer-model-menu .composer-fast-toggle[aria-checked='true']").click();
  await page.locator("#composer-model-menu .composer-fast-toggle[aria-checked='false']").waitFor();
  const disableStartupInputs = await page.evaluate(() => [
    window.__winsmuxViewportHarness?.getOperatorStartupInput(),
    window.__winsmuxViewportHarness?.getOperatorStartupInput(),
    JSON.parse(localStorage.getItem("winsmux.composer-session.v1") || "{}"),
  ]);
  if (!String(disableStartupInputs[0]).includes("/fast\r")) {
    throw new Error("Fast mode toggle was not sent once after disabling Opus 4.6 fast mode");
  }
  if (String(disableStartupInputs[1]).includes("/fast\r")) {
    throw new Error("Fast mode disable toggle was sent more than once");
  }
  if (disableStartupInputs[2]?.fastModeEnabled !== false || disableStartupInputs[2]?.fastModeTogglePending !== false) {
    throw new Error("Fast mode persisted state did not keep disabled mode with the launch toggle consumed");
  }

  await setShellLanguage(page, "ja");
  await page.goto(`${previewUrl}${HARNESS_QUERY}`, { waitUntil: "networkidle" });
  await page.locator(".composer-session-trigger-permission", { hasText: "プランモード" }).waitFor();
  await page.locator(".composer-session-trigger-model", { hasText: "Opus 4.6・Max" }).waitFor();
  await page.click(".composer-session-trigger-model");
  await page.locator("#composer-model-menu", { hasText: "モデル" }).waitFor();
  await page.locator("#composer-model-menu", { hasText: "工数" }).waitFor();
  await page.locator("#composer-model-menu", { hasText: "高速モード" }).waitFor();
  await page.locator("#composer-model-menu", { hasText: "高速モードを有効にする" }).waitFor();
  await page.locator("#composer-model-menu .composer-fast-toggle[aria-checked='false']").waitFor();

  await setShellLanguage(page, "en");
  await page.goto(`${previewUrl}${HARNESS_QUERY}`, { waitUntil: "networkidle" });
  await assertComposerModeChromeUpdates(page);
}

async function assertComposerModeChromeUpdates(page) {
  async function selectMode(label, placeholder) {
    await page.click("#menu-run-btn");
    await page.locator("#top-menu-popover .top-menu-popover-item", { hasText: label }).click();
    await page.waitForFunction(
      ({ expectedLabel, expectedPlaceholder }) => {
        const input = document.querySelector("#composer-input");
        const footerMode = Array.from(document.querySelectorAll("#footer-left .footer-pill")).find((item) => {
          const label = item.querySelector(".footer-pill-label")?.textContent?.trim() ?? "";
          const value = item.querySelector(".footer-pill-value")?.textContent?.trim() ?? "";
          return label === "Mode" && value === expectedLabel;
        });
        return input instanceof HTMLTextAreaElement && input.placeholder === expectedPlaceholder && Boolean(footerMode);
      },
      { expectedLabel: label, expectedPlaceholder: placeholder },
    );
  }

  await page.locator("#composer-mode-row").waitFor({ state: "hidden" });
  await selectMode("Ask", "Ask a question or request guidance");
  await selectMode("Review", "Describe what needs review or approval");
  await selectMode("Dispatch", "Describe a task or ask a question");
}

async function getVisibleWorkbenchPaneLabels(page) {
  return page.evaluate(() => {
    return Array.from(document.querySelectorAll("#panes-container .pane"))
      .filter((pane) => pane instanceof HTMLElement && !pane.hidden && getComputedStyle(pane).display !== "none")
      .map((pane) => pane.querySelector(".pane-label")?.textContent?.trim() ?? "");
  });
}

async function getWorkbenchPaneLabels(page) {
  return page.evaluate(() => {
    return Array.from(document.querySelectorAll("#panes-container .pane"))
      .map((pane) => pane.querySelector(".pane-label")?.textContent?.trim() ?? "");
  });
}

async function assertVisibleWorkbenchPaneCount(page, expectedCount, label) {
  try {
    await page.waitForFunction((count) => {
      return Array.from(document.querySelectorAll("#panes-container .pane"))
        .filter((pane) => pane instanceof HTMLElement && !pane.hidden && getComputedStyle(pane).display !== "none")
        .length === count;
    }, expectedCount);
  } catch (error) {
    const visibleLabels = await getVisibleWorkbenchPaneLabels(page).catch(() => []);
    const paneLabels = await getWorkbenchPaneLabels(page).catch(() => []);
    const reason = error instanceof Error ? error.message : String(error);
    throw new Error(
      `${label} expected ${expectedCount} visible panes, visible: ${visibleLabels.join(", ") || "(none)"}, all: ${paneLabels.join(", ") || "(none)"}. ${reason}`,
    );
  }
  const labels = await getVisibleWorkbenchPaneLabels(page);
  if (labels.length !== expectedCount) {
    throw new Error(`${label} expected ${expectedCount} visible panes, got ${labels.length}`);
  }
  return labels;
}

async function setWorkbenchLayout(page, layout) {
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const current = (await page.locator("#workbench-layout-btn").textContent())?.trim();
    if (current === layout) {
      return;
    }
    await page.click("#workbench-layout-btn");
  }
  throw new Error(`Unable to switch workbench layout to ${layout}`);
}

async function assertWorkbenchLayoutCycle(page) {
  let visibleLabels;

  await runStep("workbench focus cycle 2x2 initial", async () => {
    await ensureWorkbenchOpen(page);
    await setWorkbenchLayout(page, "2x2");
    await assertVisibleWorkbenchPaneCount(page, 4, "2x2 initial");
    await page.locator("#menu-layout-status", { hasText: "2x2 · 4 panes" }).waitFor();
  });

  await runStep("workbench focus cycle 3x2", async () => {
    await setWorkbenchLayout(page, "3x2");
    await assertVisibleWorkbenchPaneCount(page, 6, "3x2");
    await page.locator("#menu-layout-status", { hasText: "3x2 · 6 panes" }).waitFor();
  });

  await runStep("workbench focus cycle select worker-6", async () => {
    await setWorkbenchLayout(page, "focus");
    visibleLabels = await assertVisibleWorkbenchPaneCount(page, 1, "focus");
    await page.locator("#focused-pane-select").waitFor({ state: "visible" });
    await page.locator("#menu-layout-status", { hasText: "focus · 1 pane" }).waitFor();

    await page.selectOption("#focused-pane-select", "worker-6");
    visibleLabels = await assertVisibleWorkbenchPaneCount(page, 1, "focus worker-6");
    if (visibleLabels[0] !== "worker-6") {
      throw new Error(`focus layout selected ${visibleLabels[0]} instead of worker-6`);
    }
  });

  await runStep("workbench focus cycle reload worker-6", async () => {
    await page.reload({ waitUntil: "networkidle" });
    visibleLabels = await assertVisibleWorkbenchPaneCount(page, 1, "focus worker-6 after reload");
    if (visibleLabels[0] !== "worker-6") {
      throw new Error(`focus layout restored ${visibleLabels[0]} instead of worker-6`);
    }
    await page.locator("#focused-pane-select").waitFor({ state: "visible" });
    const restoredFocusedPane = await page.locator("#focused-pane-select").inputValue();
    if (restoredFocusedPane !== "worker-6") {
      throw new Error(`focus selector restored ${restoredFocusedPane} instead of worker-6`);
    }
  });

  await runStep("workbench focus cycle close worker-6", async () => {
    await page.locator("#panes-container .pane[data-focused-pane] .pane-close").click();
    await page.waitForFunction(() => {
      const labels = Array.from(document.querySelectorAll("#panes-container .pane"))
        .filter((pane) => pane instanceof HTMLElement && !pane.hidden && getComputedStyle(pane).display !== "none")
        .map((pane) => pane.querySelector(".pane-label")?.textContent?.trim() ?? "");
      return labels.length === 1 && labels[0] === "worker-1";
    });
    const persistedFocusAfterClose = await page.evaluate(() => {
      const rawValue = window.localStorage.getItem("winsmux.shell.preferences.v1");
      return rawValue ? JSON.parse(rawValue).focusedWorkbenchPaneId : null;
    });
    if (persistedFocusAfterClose === "worker-6") {
      throw new Error("focus layout kept closed worker-6 in persisted preferences");
    }

    await page.reload({ waitUntil: "networkidle" });
    visibleLabels = await assertVisibleWorkbenchPaneCount(page, 1, "focus after closing worker-6 and reloading");
    if (visibleLabels[0] !== "worker-1") {
      throw new Error(`focus layout restored ${visibleLabels[0]} after worker-6 was closed`);
    }
    const labelsAfterCloseReload = await getWorkbenchPaneLabels(page);
    if (labelsAfterCloseReload.includes("worker-6")) {
      throw new Error("focus layout recreated closed worker-6 after reload");
    }
  });

  await runStep("workbench focus cycle 2x2 restored", async () => {
    await setWorkbenchLayout(page, "2x2");
    visibleLabels = await assertVisibleWorkbenchPaneCount(page, 4, "2x2 restored");
    if (visibleLabels.includes("worker-5") || visibleLabels.includes("worker-6")) {
      throw new Error(`2x2 restored with extra panes visible: ${visibleLabels.join(", ")}`);
    }
    await page.locator("#focused-pane-select").waitFor({ state: "hidden" });
    await page.locator("#menu-layout-status", { hasText: "2x2 · 4 panes" }).waitFor();
  });

  await runStep("workbench focus cycle stale focus fallback", async () => {
    await page.evaluate(() => {
      const key = "winsmux.shell.preferences.v1";
      const current = JSON.parse(window.localStorage.getItem(key) ?? "{}");
      window.localStorage.setItem(
        key,
        JSON.stringify({
          ...current,
          workbenchOpen: true,
          workbenchLayout: "focus",
          focusedWorkbenchPaneId: "pane-5",
        }),
      );
    });
    await page.reload({ waitUntil: "networkidle" });
    visibleLabels = await assertVisibleWorkbenchPaneCount(page, 1, "focus stale pane id after reload");
    if (visibleLabels[0] !== "worker-1") {
      throw new Error(`focus layout restored stale pane id as ${visibleLabels[0]} instead of worker-1`);
    }
    const fallbackFocusedPane = await page.locator("#focused-pane-select").inputValue();
    if (fallbackFocusedPane !== "worker-1") {
      throw new Error(`focus selector fallback restored ${fallbackFocusedPane} instead of worker-1`);
    }

    await setWorkbenchLayout(page, "2x2");
    await assertVisibleWorkbenchPaneCount(page, 4, "2x2 after stale focus fallback");
  });
}

async function assertSourceControlChrome(page) {
  await page.click("#activity-source-btn");
  await page.locator("#source-control-view").waitFor({ state: "visible" });
  await assertFullyVisible(page, "#source-control-commit-btn");
  await assertHorizontallyVisible(page, "#source-control-message");
  await assertHorizontallyVisible(page, "#source-control-changes-list");
  await assertHorizontallyVisible(page, "#source-control-graph-list");
  await page.locator("#source-control-graph-list .source-control-graph-row").first().waitFor();
  await page.waitForFunction(() => {
    const lane = document.querySelector("#source-control-graph-list .source-control-graph-lanes");
    const title = lane?.getAttribute("title") ?? "";
    return title.includes("Commit graph") &&
      !title.includes("diagonal") &&
      !title.includes("斜線");
  });
  await page.waitForFunction(() => {
    const row = document.querySelector("#source-control-graph-list .source-control-graph-row");
    const svg = document.querySelector("#source-control-graph-list .source-control-graph-overlay");
    if (!(row instanceof HTMLElement) || !(svg instanceof SVGElement)) {
      return false;
    }
    return svg.getBoundingClientRect().height >= row.getBoundingClientRect().height;
  });
  await page.waitForFunction(() => {
    const lane = document.querySelector("#source-control-graph-list .source-control-graph-lanes");
    const svg = document.querySelector("#source-control-graph-list .source-control-graph-overlay");
    return lane instanceof HTMLElement &&
      svg instanceof SVGElement &&
      lane.getBoundingClientRect().width <= 80 &&
      svg.getBoundingClientRect().width <= 80;
  });
  await page.waitForFunction(() => {
    const path = Array.from(document.querySelectorAll("#source-control-graph-list .source-control-graph-lane-path"))
      .find((candidate) => (candidate.getAttribute("d") ?? "").includes(" C "));
    const pillar = Array.from(document.querySelectorAll("#source-control-graph-list .source-control-graph-lane-path.is-pillar"))
      .find((candidate) => !(candidate.getAttribute("d") ?? "").includes(" C "));
    const arcPath = Array.from(document.querySelectorAll("#source-control-graph-list .source-control-graph-lane-path"))
      .find((candidate) => (candidate.getAttribute("d") ?? "").includes(" A "));
    const parentLane = Array.from(document.querySelectorAll("#source-control-graph-list .source-control-graph-lanes"))
      .find((lane) => (lane instanceof HTMLElement) && (lane.dataset.graphParents ?? "").length > 0);
    return Boolean(path && pillar && parentLane && !arcPath);
  });
  await page.click("#activity-explorer-btn");
  await page.locator("#explorer-list").waitFor({ state: "visible" });
}

async function assertExplorerFolderExpandsInline(page) {
  const folderRow = page.locator("#explorer-list .sidebar-tree-row.is-folder", { hasText: ".agents" }).first();
  await folderRow.scrollIntoViewIfNeeded();
  await folderRow.click();
  await page.waitForFunction(() => {
    const rows = Array.from(document.querySelectorAll("#explorer-list .sidebar-tree-row"));
    const folderIndex = rows.findIndex((row) =>
      row.classList.contains("is-folder") &&
      row.textContent?.includes(".agents") &&
      row.getAttribute("aria-expanded") === "true"
    );
    if (folderIndex < 0) {
      return false;
    }
    const nextRow = rows[folderIndex + 1];
    return (
      nextRow instanceof HTMLElement &&
      nextRow.classList.contains("is-file") &&
      nextRow.classList.contains("depth-2") &&
      nextRow.textContent?.includes("README.md")
    );
  });
}

async function assertExplorerFileOpensMainEditor(page) {
  const readmeRow = page.locator("#explorer-list .sidebar-tree-row.is-file", { hasText: "README.md" }).first();
  await readmeRow.scrollIntoViewIfNeeded();
  await readmeRow.click({ force: true });
  await page.locator("#editor-surface").waitFor({ state: "visible" });
  await page.waitForFunction(() => {
    const conversation = document.querySelector("#conversation-panel");
    const editorPath = document.querySelector("#editor-file-path");
    const editorCode = document.querySelector("#editor-code");
    const firstLineNumber = document.querySelector("#editor-code .editor-line-number");
    const statusbar = document.querySelector("#editor-statusbar");
    return (
      conversation instanceof HTMLElement &&
      getComputedStyle(conversation).display === "none" &&
      editorPath instanceof HTMLElement &&
      editorPath.textContent?.includes("README.md") &&
      editorCode instanceof HTMLElement &&
      editorCode.textContent?.includes("winsmux") &&
      firstLineNumber instanceof HTMLElement &&
      firstLineNumber.textContent === "1" &&
      statusbar instanceof HTMLElement &&
      statusbar.textContent?.includes("Lines")
    );
  });
  await assertHorizontallyVisible(page, "#editor-surface");
  await assertHorizontallyVisible(page, "#editor-statusbar");
}

async function verifyDesktopViewport(page, previewUrl) {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto(`${previewUrl}${HARNESS_QUERY}`, { waitUntil: "networkidle" });

  await runStep("desktop initial chrome", async () => {
    await assertHorizontallyVisible(page, "#left-rail");
    await assertFullyVisible(page, "#conversation-panel");
    await assertWorkbenchPaneGrid(page);
    await assertButtonVisible(page, "#send-btn");
    await assertButtonVisible(page, "#voice-input-btn");
    await page.waitForFunction(() => {
      const voice = document.querySelector("#voice-input-btn");
      return voice instanceof HTMLButtonElement &&
        !voice.disabled &&
        voice.getAttribute("aria-label")?.includes("Ctrl+Alt+M");
    });
    await page.waitForFunction(() => {
      const status = document.querySelector("#voice-input-status");
      return status instanceof HTMLElement && status.hidden;
    });
    await page.keyboard.press("Control+Alt+M");
    await page.waitForFunction(() => {
      const voice = document.querySelector("#voice-input-btn");
      return voice instanceof HTMLElement && voice.getAttribute("aria-pressed") === "true";
    });
    await page.keyboard.press("Control+Alt+M");
    await page.waitForFunction(() => {
      const voice = document.querySelector("#voice-input-btn");
      return voice instanceof HTMLElement && voice.getAttribute("aria-pressed") === "false";
    });
    await page.waitForFunction(() => {
      const wrap = document.querySelector("#composer-input-wrap");
      const voice = document.querySelector("#voice-input-btn");
      const send = document.querySelector("#send-btn");
      if (!(wrap instanceof HTMLElement) || !(voice instanceof HTMLElement) || !(send instanceof HTMLElement)) {
        return false;
      }
      const wrapRect = wrap.getBoundingClientRect();
      const voiceRect = voice.getBoundingClientRect();
      const sendRect = send.getBoundingClientRect();
      return voiceRect.left >= wrapRect.left &&
        voiceRect.right <= wrapRect.right &&
        sendRect.left >= wrapRect.left &&
        sendRect.right <= wrapRect.right &&
        Math.abs(voiceRect.top - sendRect.top) <= 2;
    });
    await assertFullyVisible(page, "#workspace-footer");
    await assertNoOverlap(page, "#workspace-body", "#workspace-footer");
  });

  await runStep("desktop composer autosizes without resize grabber", async () => {
    const initialHeight = await page.locator("#composer-input").evaluate((input) => input.getBoundingClientRect().height);
    await page.locator("#composer-input").fill(Array.from({ length: 40 }, (_, index) => `line ${index + 1}`).join("\n"));
    await page.waitForFunction(
      (baselineHeight) => {
        const input = document.querySelector("#composer-input");
        if (!(input instanceof HTMLTextAreaElement)) {
          return false;
        }
        const styles = getComputedStyle(input);
        const rect = input.getBoundingClientRect();
        const maxHeight = Number.parseFloat(styles.maxHeight);
        return styles.resize === "none" &&
          rect.height > baselineHeight + 20 &&
          rect.height <= maxHeight + 1 &&
          input.scrollHeight > input.clientHeight &&
          styles.overflowY === "auto";
      },
      initialHeight,
    );
    await page.locator("#composer-input").fill("");
    await page.waitForFunction(
      (baselineHeight) => {
        const input = document.querySelector("#composer-input");
        if (!(input instanceof HTMLTextAreaElement)) {
          return false;
        }
        const rect = input.getBoundingClientRect();
        return rect.height <= baselineHeight + 1 && getComputedStyle(input).overflowY === "hidden";
      },
      initialHeight,
    );
  });

  await assertComposerSessionControls(page, previewUrl);

  await runStep("desktop command bar", async () => {
    await page.click("#activity-search-btn");
    await page.locator("#command-bar-shell").waitFor({ state: "visible" });
    await assertFullyVisible(page, "#command-bar");
    await assertButtonVisible(page, "#command-bar-input");
    await page.keyboard.press("Escape");
    await page.locator("#command-bar-shell").waitFor({ state: "hidden" });
  });

  await runStep("desktop settings sheet", async () => {
    await page.click("#activity-settings-btn");
    await page.locator("#settings-sheet").waitFor({ state: "visible" });
    await assertFullyVisible(page, "#settings-sheet");
    await assertButtonVisible(page, "#close-settings-btn");
    await page.click("#close-settings-btn");
    await page.locator("#settings-sheet").waitFor({ state: "hidden" });
  });

  await runStep("desktop editor surface", async () => {
    await assertSourceControlChrome(page);
    await assertExplorerFolderExpandsInline(page);
    await assertExplorerFileOpensMainEditor(page);
    await ensureContextPanelOpen(page);
    await openFirstSourceContextEntry(page);
    await assertEditorPopout(page);
    await assertCommandBarRoundtrip(page, "#editor-surface");
    await assertSettingsRoundtrip(page, "#editor-surface");
    await assertTerminalDrawerWithSourceContext(page, "#editor-surface", "#context-panel");
  });

  await runStep("desktop browser surface", async () => {
    await registerHarnessPreviewTarget(page, `${previewUrl}${HARNESS_QUERY}`);
    await openHarnessPreviewTarget(page, `${previewUrl}${HARNESS_QUERY}`);
    await page.locator("#browser-reload-btn").waitFor({ state: "visible" });
    await assertButtonVisible(page, "#browser-back-btn");
    await assertButtonVisible(page, "#browser-reload-btn");
    await assertButtonVisible(page, "#browser-open-btn");
    await assertHorizontallyVisible(page, "#browser-toolbar");
    await assertFullyVisible(page, "#browser-frame");
    await assertToolbarActionStates(page);
    await assertPreviewPopout(page);
    await assertCommandBarRoundtrip(page, "#browser-toolbar");
    await assertSettingsRoundtrip(page, "#browser-toolbar");
  });

  await runStep("desktop workbench layout", async () => {
    await runStep("desktop workbench grid after browser preview", async () => {
      await assertWorkbenchPaneGrid(page);
      await assertFullyVisible(page, "#terminal-drawer");
      await assertHorizontallyVisible(page, "#browser-toolbar");
    });
    await runStep("desktop browser back to code", async () => {
      await assertBackToCode(page);
      await assertHorizontallyVisible(page, "#editor-code");
    });
    await runStep("desktop workbench focus cycle", async () => {
      await assertWorkbenchLayoutCycle(page);
    });
  });
}

async function verifyNarrowViewport(page, previewUrl) {
  await page.setViewportSize({ width: 393, height: 852 });
  await page.goto(`${previewUrl}${HARNESS_QUERY}`, { waitUntil: "networkidle" });

  await assertButtonVisible(page, "#send-btn");
  await assertFullyVisible(page, "#workspace-footer");
  await page.locator("#activity-explorer-btn[aria-expanded='false']").waitFor();

  await page.click("#activity-search-btn");
  await page.locator("#command-bar-shell").waitFor({ state: "visible" });
  await assertFullyVisible(page, "#command-bar");
  await assertButtonVisible(page, "#command-bar-input");
  await page.keyboard.press("Escape");
  await page.locator("#command-bar-shell").waitFor({ state: "hidden" });

  await page.click("#activity-explorer-btn");
  await page.locator("#activity-explorer-btn[aria-expanded='true']").waitFor();
  await waitForHorizontalVisibility(page, "#left-rail");
  await assertHorizontallyVisible(page, "#left-rail");
  await assertFullyVisible(page, "#sidebar-overlay");
  await assertSettingsRoundtrip(page, "#left-rail");
  const narrowViewport = page.viewportSize();
  if (!narrowViewport) {
    throw new Error("Viewport size is unavailable");
  }
  await page.mouse.click(narrowViewport.width - 10, 24);
  await page.locator("#activity-explorer-btn[aria-expanded='false']").waitFor();

  await ensureContextPanelOpen(page);
  await page.locator("#activity-context-btn[aria-expanded='true']").waitFor();
  await waitForHorizontalVisibility(page, "#context-panel");
  await assertHorizontallyVisible(page, "#context-panel");
  await openFirstSourceContextEntry(page);
  await assertCommandBarRoundtrip(page, "#editor-surface");
  await assertNarrowSettingsRoundtrip(page, "#editor-surface");
  await assertTerminalDrawerWithSourceContext(page, "#editor-surface");

  await assertWorkbenchPaneGrid(page);
  await assertFullyVisible(page, "#terminal-drawer");

  await registerHarnessPreviewTarget(page, `${previewUrl}${HARNESS_QUERY}`);
  await openHarnessPreviewTarget(page, `${previewUrl}${HARNESS_QUERY}`);
  await page.locator("#browser-reload-btn").waitFor({ state: "visible" });
  await assertButtonVisible(page, "#browser-back-btn");
  await assertButtonVisible(page, "#browser-reload-btn");
  await assertButtonVisible(page, "#browser-open-btn");
  await assertHorizontallyVisible(page, "#browser-toolbar");
  await assertReachableFrame(page, "#browser-frame");
  await page.locator("#browser-target-list .editor-tab").first().waitFor({ state: "visible" });
  await assertReachableFrame(page, "#browser-frame");
  await assertToolbarActionStates(page);
  await assertCommandBarRoundtrip(page, "#browser-toolbar");
  await assertNarrowSettingsRoundtrip(page, "#browser-toolbar");
  await assertBackToCode(page);
}

async function verifyShortNarrowViewport(page, previewUrl) {
  await page.setViewportSize({ width: 393, height: 720 });
  await page.goto(`${previewUrl}${HARNESS_QUERY}`, { waitUntil: "networkidle" });

  await assertButtonVisible(page, "#send-btn");
  await page.click("#activity-search-btn");
  await page.locator("#command-bar-shell").waitFor({ state: "visible" });
  await assertFullyVisible(page, "#command-bar");
  await assertButtonVisible(page, "#command-bar-input");
  await page.keyboard.press("Escape");
  await page.locator("#command-bar-shell").waitFor({ state: "hidden" });

  await page.locator("#activity-explorer-btn[aria-expanded='false']").waitFor();
  await page.click("#activity-explorer-btn");
  await page.locator("#activity-explorer-btn[aria-expanded='true']").waitFor();
  await waitForHorizontalVisibility(page, "#left-rail");
  await assertHorizontallyVisible(page, "#left-rail");

  await page.click("#activity-settings-btn");
  await page.locator("#settings-sheet").waitFor({ state: "visible" });
  await assertFullyVisible(page, "#settings-sheet");
  await assertButtonVisible(page, "#close-settings-btn");
  await page.click("#close-settings-btn");
  await page.locator("#settings-sheet").waitFor({ state: "hidden" });
  const shortNarrowViewport = page.viewportSize();
  if (!shortNarrowViewport) {
    throw new Error("Viewport size is unavailable");
  }
  await page.mouse.click(shortNarrowViewport.width - 10, 24);
  await page.locator("#activity-explorer-btn[aria-expanded='false']").waitFor();

  await assertWorkbenchPaneGrid(page);
  await assertHorizontallyVisible(page, "#terminal-drawer");
  await assertHorizontallyVisible(page, "#terminal-toolbar");

  await registerHarnessPreviewTarget(page, `${previewUrl}${HARNESS_QUERY}`);
  await openHarnessPreviewTarget(page, `${previewUrl}${HARNESS_QUERY}`);
  await page.locator("#browser-reload-btn").waitFor({ state: "visible" });
  await assertButtonVisible(page, "#browser-back-btn");
  await assertButtonVisible(page, "#browser-reload-btn");
  await assertButtonVisible(page, "#browser-open-btn");
  await assertHorizontallyVisible(page, "#browser-toolbar");
  await assertReachableFrame(page, "#browser-frame");
  await assertToolbarActionStates(page);
  await assertPreviewClosed(page);
}

async function verifyDeveloperWindowViewport(page, previewUrl, width, height, label) {
  await page.setViewportSize({ width, height });
  await page.goto(`${previewUrl}${HARNESS_QUERY}`, { waitUntil: "networkidle" });

  await assertButtonVisible(page, "#send-btn");
  await page.locator("#activity-explorer-btn[aria-expanded='false']").waitFor();

  await page.click("#activity-search-btn");
  await page.locator("#command-bar-shell").waitFor({ state: "visible" });
  await assertFullyVisible(page, "#command-bar");
  await assertButtonVisible(page, "#command-bar-input");
  await page.keyboard.press("Escape");
  await page.locator("#command-bar-shell").waitFor({ state: "hidden" });

  await page.click("#activity-explorer-btn");
  await page.locator("#activity-explorer-btn[aria-expanded='true']").waitFor();
  await waitForHorizontalVisibility(page, "#left-rail");
  await assertHorizontallyVisible(page, "#left-rail");
  await assertFullyVisible(page, "#sidebar-overlay");
  await assertSettingsRoundtrip(page, "#left-rail");
  const viewport = page.viewportSize();
  if (!viewport) {
    throw new Error(`Viewport size is unavailable for ${label}`);
  }
  await page.mouse.click(viewport.width - 10, 24);
  await page.locator("#activity-explorer-btn[aria-expanded='false']").waitFor();

  await assertWorkbenchPaneGrid(page);
  await assertFullyVisible(page, "#terminal-drawer");
  await assertHorizontallyVisible(page, "#terminal-toolbar");
}

async function run() {
  await runStep("desktop-operator-chat-contract", assertOperatorChatContractSource);
  await ensureOutputDir();

  const previewPort = await getAvailablePort();
  const previewUrl = `http://127.0.0.1:${previewPort}`;
  const previewServer = startPreviewServer(previewPort);
  let browser;

  try {
    await waitForPreviewServer(previewUrl);
    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage();
    await installSpeechRecognitionStub(page);

    await verifyDesktopViewport(page, previewUrl);
    await verifyDeveloperWindowViewport(page, previewUrl, 1366, 768, "developer-1366x768");
    await verifyDeveloperWindowViewport(page, previewUrl, 1280, 720, "developer-1280x720");
    await verifyDeveloperWindowViewport(page, previewUrl, 800, 600, "tauri-default-800x600");
    await verifyNarrowViewport(page, previewUrl);
    await verifyShortNarrowViewport(page, previewUrl);

    await fs.writeFile(
      path.join(OUTPUT_DIR, "viewport-harness.json"),
      JSON.stringify(
        {
          ok: true,
          generatedAt: new Date().toISOString(),
          previewUrl,
          checks: [
            "desktop-operator-chat-contract",
            "desktop-1440x900",
            "desktop-composer-autosize",
            "desktop-command-bar",
            "desktop-composer-model-controls",
            "desktop-composer-japanese-controls",
            "desktop-voice-shortcut",
            "desktop-settings-sheet",
            "desktop-settings-voice-shortcut",
            "desktop-source-context",
            "desktop-editor-popout",
            "desktop-command-bar-with-editor",
            "desktop-settings-with-editor",
            "desktop-source-context-with-terminal-drawer",
            "desktop-preview-browser",
            "desktop-preview-toolbar-actions",
            "desktop-preview-popout",
            "desktop-command-bar-with-preview",
            "desktop-settings-with-preview",
            "desktop-preview-back-to-code",
            "desktop-terminal-drawer",
            "desktop-workbench-layout-cycle",
            "desktop-workbench-focus-persistence",
            "desktop-workbench-focus-close-persistence",
            "desktop-workbench-focus-fallback",
            "developer-1366x768",
            "developer-1280x720",
            "tauri-default-800x600",
            "narrow-393x852",
            "narrow-command-bar",
            "narrow-settings-sheet",
            "narrow-context-panel",
            "narrow-source-context",
            "narrow-command-bar-with-editor",
            "narrow-settings-with-editor",
            "narrow-source-context-with-terminal-drawer",
            "narrow-terminal-drawer",
            "narrow-preview-browser",
            "narrow-preview-toolbar-actions",
            "narrow-command-bar-with-preview",
            "narrow-settings-with-preview",
            "narrow-preview-back-to-code",
            "short-narrow-command-bar",
            "short-narrow-settings-sheet",
            "short-narrow-terminal-drawer",
            "short-narrow-preview-browser",
            "short-narrow-preview-toolbar-actions",
          ],
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
          path: path.join(OUTPUT_DIR, "viewport-harness-failure.png"),
          fullPage: true,
        }).catch(() => {});
      }
    }

    await fs.writeFile(
      path.join(OUTPUT_DIR, "viewport-harness.json"),
      JSON.stringify(
        {
          ok: false,
          generatedAt: new Date().toISOString(),
          previewUrl,
          error: error instanceof Error ? error.message : String(error),
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

run().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
