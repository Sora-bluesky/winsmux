import assert from "node:assert/strict";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { chromium } from "playwright";

const chrome = process.env.WINSMUX_PLAYWRIGHT_CHROMIUM_EXECUTABLE
  || "C:/Program Files/Google/Chrome/Application/chrome.exe";
const browser = await chromium.launch({
  headless: true,
  executablePath: chrome,
  args: ["--allow-file-access-from-files"],
});

try {
  const context = await browser.newContext({ colorScheme: "dark" });
  const page = await context.newPage();
  await page.route(/^https?:/, (route) => route.abort());
  const pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  await page.goto(pathToFileURL(path.resolve("dist/index.html")).href, { waitUntil: "domcontentloaded" });
  await page.locator("#operator-terminal .xterm-viewport").waitFor();
  // The onboarding dialog needs a desktop project chooser, which is absent in file mode.
  await page.addStyleTag({ content: "#first-run-wizard { pointer-events: none !important; }" });

  const snapshot = () => page.evaluate(() => ({
    shell: document.querySelector("#app-shell")?.getAttribute("data-theme"),
    storage: localStorage.getItem("winsmux.shell.preferences.v1"),
    terminals: [...document.querySelectorAll("#operator-terminal .xterm, .pane-terminal .xterm")].map((element) => ({
      background: element.querySelector(".xterm-viewport")?.style.backgroundColor,
      screen: element.querySelector(".xterm-screen")?.getAttribute("style"),
      font: element.querySelector(".xterm-char-measure-element")?.getAttribute("style"),
    })),
  }));
  const colors = (state) => [...new Set(state.terminals.map((terminal) => terminal.background))];
  const metrics = (state) => state.terminals.map((terminal) => [terminal.screen, terminal.font]);
  const switchOs = async (colorScheme) => {
    await page.emulateMedia({ colorScheme });
    await page.waitForTimeout(150);
  };
  const selectTheme = (index) => page.locator("#theme-options button").nth(index).click();

  let before = await snapshot();
  assert.equal(before.terminals.length, 7, "operator and six existing worker panes");
  assert.deepEqual(colors(before), ["rgb(11, 13, 16)"]);
  const originalStorage = before.storage;

  await switchOs("light");
  let after = await snapshot();
  assert.deepEqual(colors(after), ["rgb(255, 255, 255)"]);
  assert.deepEqual(metrics(after), metrics(before));
  assert.equal(after.storage, originalStorage);
  await switchOs("dark");
  after = await snapshot();
  assert.deepEqual(colors(after), ["rgb(11, 13, 16)"]);
  assert.equal(after.storage, originalStorage);

  await page.locator("#activity-settings-btn").click();
  await selectTheme(1);
  before = await snapshot();
  assert.equal(before.shell, "light");
  assert.deepEqual(colors(before), ["rgb(255, 255, 255)"]);
  await switchOs("light");
  await switchOs("dark");
  after = await snapshot();
  assert.deepEqual(colors(after), ["rgb(255, 255, 255)"]);
  assert.deepEqual(metrics(after), metrics(before));
  assert.equal(after.storage, before.storage);

  await selectTheme(2);
  before = await snapshot();
  assert.deepEqual(colors(before), ["rgb(11, 13, 16)"]);
  await switchOs("light");
  after = await snapshot();
  assert.deepEqual(colors(after), ["rgb(11, 13, 16)"]);
  assert.equal(after.storage, before.storage);

  await selectTheme(0);
  await switchOs("dark");
  await page.locator("#editor-font-size-input").fill("18");
  await page.locator("#editor-font-size-input").dispatchEvent("change");
  before = await snapshot();
  assert.equal(before.shell, "system");
  assert.deepEqual(colors(before), ["rgb(11, 13, 16)"]);
  assert.equal(await page.locator("#editor-font-size-input").inputValue(), "18");
  assert.ok(before.terminals.every((terminal) => terminal.font?.includes("13px")));
  await switchOs("light");
  after = await snapshot();
  assert.deepEqual(colors(after), ["rgb(255, 255, 255)"]);
  assert.deepEqual(metrics(after), metrics(before));
  assert.equal(after.storage, before.storage);

  await page.locator("#close-settings-btn").click();
  after = await snapshot();
  assert.equal(after.shell, "system");
  assert.deepEqual(colors(after), ["rgb(255, 255, 255)"]);
  assert.equal(after.storage, originalStorage);

  await page.locator("#activity-settings-btn").click();
  await selectTheme(2);
  await page.locator("#apply-settings-btn").click();
  before = await snapshot();
  assert.equal(JSON.parse(before.storage).theme, "dark");
  assert.deepEqual(colors(before), ["rgb(11, 13, 16)"]);
  await switchOs("dark");
  await switchOs("light");
  after = await snapshot();
  assert.deepEqual(colors(after), ["rgb(11, 13, 16)"]);
  assert.equal(after.storage, before.storage);

  await selectTheme(0);
  await page.locator("#editor-font-size-input").fill("18");
  await page.locator("#editor-font-size-input").dispatchEvent("change");
  before = await snapshot();
  assert.deepEqual(colors(before), ["rgb(255, 255, 255)"]);
  await switchOs("dark");
  after = await snapshot();
  assert.deepEqual(colors(after), ["rgb(11, 13, 16)"]);
  assert.deepEqual(metrics(after), metrics(before));
  assert.equal(after.storage, before.storage);
  await switchOs("light");
  await page.locator("#close-settings-btn").click();
  after = await snapshot();
  assert.deepEqual(colors(after), ["rgb(11, 13, 16)"]);
  assert.equal(after.storage, before.storage);

  await page.locator("#activity-settings-btn").click();
  await selectTheme(1);
  await page.locator("#apply-settings-btn").click();
  before = await snapshot();
  assert.equal(JSON.parse(before.storage).theme, "light");
  await switchOs("dark");
  after = await snapshot();
  assert.deepEqual(colors(after), ["rgb(255, 255, 255)"]);
  assert.equal(after.storage, before.storage);

  assert.deepEqual(pageErrors, []);
  await selectTheme(0);
  await page.locator("#apply-settings-btn").click();
  await page.evaluate(() => {
    window.isTauri = true;
    window.__ptyCalls = [];
    window.__TAURI_INTERNALS__ = {
      invoke: async (command, args) => {
        if (command === "pty_json_rpc") {
          window.__ptyCalls.push(args.request.method);
          return { jsonrpc: "2.0", id: args.request.id, result: null };
        }
        return null;
      },
    };
    document.querySelector("#operator-terminal .xterm-helper-textarea").focus();
  });
  await page.keyboard.type("x");
  await page.waitForTimeout(400);
  assert.ok((await page.evaluate(() => window.__ptyCalls)).includes("pty.spawn"));
  await page.evaluate(() => { window.__ptyCalls = []; });
  before = await snapshot();
  await switchOs("light");
  after = await snapshot();
  assert.deepEqual(colors(after), ["rgb(255, 255, 255)"]);
  assert.deepEqual(metrics(after), metrics(before));
  assert.equal(after.storage, before.storage);
  assert.deepEqual(await page.evaluate(() => window.__ptyCalls), [], "OS appearance change must not dispatch PTY requests");

  console.log(JSON.stringify({
    result: "PASS",
    existingTerminals: before.terminals.length,
    systemPalette: ["dark", "light", "dark"],
    explicitDraft: ["light", "dark"],
    draftSystemFontSize: 18,
    fontAndScreenMetricsStableOnOsChange: true,
    storageStableOnOsChange: true,
    cancelRestoredSavedSystem: true,
    savedExplicitDarkStable: true,
    draftSystemOverridesSavedDarkAndCancelRestoresIt: true,
    savedExplicitLightStable: true,
    startedPtyRequestsOnOsChange: 0,
  }));
} finally {
  await browser.close();
}
