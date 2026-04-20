import { spawn } from "node:child_process";
import { once } from "node:events";
import fs from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import process from "node:process";
import { chromium } from "playwright";

const OUTPUT_DIR = path.join(process.cwd(), "output", "playwright", "viewport-harness");
const HARNESS_QUERY = "?viewport-harness=1";

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

async function assertFullyVisible(page, selector) {
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

async function waitForPreviewTargetEntry(page) {
  await page.waitForFunction(() => {
    return document.querySelectorAll("#preview-target-list .context-file-row").length > 0;
  });
}

async function openFirstSourceContextEntry(page) {
  const firstSourceEntry = page.locator("#context-file-list .context-file-row").first();
  if (await firstSourceEntry.isVisible().catch(() => false)) {
    await firstSourceEntry.click();
  } else {
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
  }
  await page.locator("#editor-surface").waitFor({ state: "visible" });
  await page.locator("#editor-tabs .editor-tab").first().waitFor({ state: "visible" });
  await assertHorizontallyVisible(page, "#editor-surface");
  await assertHorizontallyVisible(page, "#editor-file-path");
  await assertHorizontallyVisible(page, "#editor-statusbar");
}

async function assertBackToCode(page) {
  await page.click("#browser-back-btn");
  await page.locator("#browser-surface").waitFor({ state: "hidden" });
  await page.locator("#editor-code").waitFor({ state: "visible" });
  await page.locator("#editor-tabs .editor-tab").first().waitFor({ state: "visible" });
  await assertHorizontallyVisible(page, "#editor-surface");
  await assertHorizontallyVisible(page, "#editor-code");
}

async function assertCommandBarRoundtrip(page, returnSelector) {
  await page.click("#open-command-bar-btn");
  await page.locator("#command-bar-shell").waitFor({ state: "visible" });
  await assertFullyVisible(page, "#command-bar");
  await assertButtonVisible(page, "#command-bar-input");
  await page.keyboard.press("Escape");
  await page.locator("#command-bar-shell").waitFor({ state: "hidden" });
  await page.locator(returnSelector).waitFor({ state: "visible" });
}

async function verifyDesktopViewport(page, previewUrl) {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto(`${previewUrl}${HARNESS_QUERY}`, { waitUntil: "networkidle" });

  await assertHorizontallyVisible(page, "#left-rail");
  await assertFullyVisible(page, "#conversation-panel");
  await assertHorizontallyVisible(page, "#context-panel");
  await assertButtonVisible(page, "#send-btn");
  await assertFullyVisible(page, "#workspace-footer");
  await assertNoOverlap(page, "#workspace-header", "#workspace-body");
  await assertNoOverlap(page, "#workspace-body", "#workspace-footer");

  await page.click("#open-command-bar-btn");
  await page.locator("#command-bar-shell").waitFor({ state: "visible" });
  await assertFullyVisible(page, "#command-bar");
  await assertButtonVisible(page, "#command-bar-input");
  await page.keyboard.press("Escape");
  await page.locator("#command-bar-shell").waitFor({ state: "hidden" });

  await page.click("#settings-btn");
  await page.locator("#settings-sheet").waitFor({ state: "visible" });
  await assertFullyVisible(page, "#settings-sheet");
  await assertButtonVisible(page, "#close-settings-btn");
  await page.click("#close-settings-btn");
  await page.locator("#settings-sheet").waitFor({ state: "hidden" });

  await openFirstSourceContextEntry(page);
  await assertCommandBarRoundtrip(page, "#editor-surface");

  await registerHarnessPreviewTarget(page, `${previewUrl}${HARNESS_QUERY}`);
  await waitForPreviewTargetEntry(page);
  await openHarnessPreviewTarget(page, `${previewUrl}${HARNESS_QUERY}`);
  await page.locator("#browser-reload-btn").waitFor({ state: "visible" });
  await assertButtonVisible(page, "#browser-back-btn");
  await assertButtonVisible(page, "#browser-reload-btn");
  await assertButtonVisible(page, "#browser-open-btn");
  await assertHorizontallyVisible(page, "#browser-toolbar");
  await assertFullyVisible(page, "#browser-frame");
  await assertCommandBarRoundtrip(page, "#browser-toolbar");

  await page.click("#toggle-terminal-btn");
  await page.locator("#terminal-drawer").waitFor({ state: "visible" });
  await assertButtonVisible(page, "#add-pane-btn");
  await assertFullyVisible(page, "#terminal-drawer");
  await assertHorizontallyVisible(page, "#browser-toolbar");
  await assertBackToCode(page);
  await assertHorizontallyVisible(page, "#editor-statusbar");
}

async function verifyNarrowViewport(page, previewUrl) {
  await page.setViewportSize({ width: 393, height: 852 });
  await page.goto(`${previewUrl}${HARNESS_QUERY}`, { waitUntil: "networkidle" });

  await assertButtonVisible(page, "#send-btn");
  await assertFullyVisible(page, "#workspace-footer");
  await page.locator("#toggle-sidebar-btn[aria-expanded='false']").waitFor();

  await page.click("#open-command-bar-btn");
  await page.locator("#command-bar-shell").waitFor({ state: "visible" });
  await assertFullyVisible(page, "#command-bar");
  await assertButtonVisible(page, "#command-bar-input");
  await page.keyboard.press("Escape");
  await page.locator("#command-bar-shell").waitFor({ state: "hidden" });

  await page.click("#toggle-sidebar-btn");
  await page.locator("#toggle-sidebar-btn[aria-expanded='true']").waitFor();
  await waitForHorizontalVisibility(page, "#left-rail");
  await assertHorizontallyVisible(page, "#left-rail");
  await assertFullyVisible(page, "#sidebar-overlay");
  await page.click("#settings-btn");
  await page.locator("#settings-sheet").waitFor({ state: "visible" });
  await assertFullyVisible(page, "#settings-sheet");
  await assertButtonVisible(page, "#close-settings-btn");
  await page.click("#close-settings-btn");
  await page.locator("#settings-sheet").waitFor({ state: "hidden" });
  const narrowViewport = page.viewportSize();
  if (!narrowViewport) {
    throw new Error("Viewport size is unavailable");
  }
  await page.mouse.click(narrowViewport.width - 10, 24);
  await page.locator("#toggle-sidebar-btn[aria-expanded='false']").waitFor();

  await page.click("#toggle-context-btn");
  await page.locator("#toggle-context-btn[aria-expanded='true']").waitFor();
  await waitForHorizontalVisibility(page, "#context-panel");
  await assertHorizontallyVisible(page, "#context-panel");
  await openFirstSourceContextEntry(page);
  await assertCommandBarRoundtrip(page, "#editor-surface");

  await page.click("#toggle-terminal-btn");
  await page.locator("#terminal-drawer").waitFor({ state: "visible" });
  await assertButtonVisible(page, "#add-pane-btn");
  await assertFullyVisible(page, "#terminal-drawer");
  await page.click("#toggle-terminal-btn");
  await page.locator("#terminal-drawer").waitFor({ state: "hidden" });

  await registerHarnessPreviewTarget(page, `${previewUrl}${HARNESS_QUERY}`);
  await waitForPreviewTargetEntry(page);
  await openHarnessPreviewTarget(page, `${previewUrl}${HARNESS_QUERY}`);
  await page.locator("#browser-reload-btn").waitFor({ state: "visible" });
  await assertButtonVisible(page, "#browser-back-btn");
  await assertButtonVisible(page, "#browser-reload-btn");
  await assertButtonVisible(page, "#browser-open-btn");
  await assertHorizontallyVisible(page, "#browser-toolbar");
  await assertReachableFrame(page, "#browser-frame");
  await page.locator("#browser-target-list .editor-tab").first().waitFor({ state: "visible" });
  await assertReachableFrame(page, "#browser-frame");
  await assertCommandBarRoundtrip(page, "#browser-toolbar");
  await assertBackToCode(page);
}

async function verifyShortNarrowViewport(page, previewUrl) {
  await page.setViewportSize({ width: 393, height: 720 });
  await page.goto(`${previewUrl}${HARNESS_QUERY}`, { waitUntil: "networkidle" });

  await assertButtonVisible(page, "#send-btn");
  await page.click("#open-command-bar-btn");
  await page.locator("#command-bar-shell").waitFor({ state: "visible" });
  await assertFullyVisible(page, "#command-bar");
  await assertButtonVisible(page, "#command-bar-input");
  await page.keyboard.press("Escape");
  await page.locator("#command-bar-shell").waitFor({ state: "hidden" });

  await page.locator("#toggle-sidebar-btn[aria-expanded='false']").waitFor();
  await page.click("#toggle-sidebar-btn");
  await page.locator("#toggle-sidebar-btn[aria-expanded='true']").waitFor();
  await waitForHorizontalVisibility(page, "#left-rail");
  await assertHorizontallyVisible(page, "#left-rail");

  await page.click("#settings-btn");
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
  await page.locator("#toggle-sidebar-btn[aria-expanded='false']").waitFor();

  await page.click("#toggle-terminal-btn");
  await page.locator("#terminal-drawer").waitFor({ state: "visible" });
  await assertButtonVisible(page, "#add-pane-btn");
  await assertHorizontallyVisible(page, "#terminal-drawer");
  await assertHorizontallyVisible(page, "#terminal-toolbar");
}

async function run() {
  await ensureOutputDir();

  const previewPort = await getAvailablePort();
  const previewUrl = `http://127.0.0.1:${previewPort}`;
  const previewServer = startPreviewServer(previewPort);
  let browser;

  try {
    await waitForPreviewServer(previewUrl);
    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage();

    await verifyDesktopViewport(page, previewUrl);
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
            "desktop-1440x900",
            "desktop-command-bar",
            "desktop-settings-sheet",
            "desktop-source-context",
            "desktop-command-bar-with-editor",
            "desktop-preview-browser",
            "desktop-command-bar-with-preview",
            "desktop-preview-back-to-code",
            "desktop-terminal-drawer",
            "narrow-393x852",
            "narrow-command-bar",
            "narrow-settings-sheet",
            "narrow-context-panel",
            "narrow-source-context",
            "narrow-command-bar-with-editor",
            "narrow-terminal-drawer",
            "narrow-preview-browser",
            "narrow-command-bar-with-preview",
            "narrow-preview-back-to-code",
            "short-narrow-command-bar",
            "short-narrow-settings-sheet",
            "short-narrow-terminal-drawer",
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
