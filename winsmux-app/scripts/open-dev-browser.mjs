import { chromium } from "playwright";
import { spawn } from "node:child_process";

const DEFAULT_URL = "http://127.0.0.1:5173/";
const DEFAULT_WINDOW_WIDTH = 2048;
const DEFAULT_WINDOW_HEIGHT = 1244;
const SERVER_READY_TIMEOUT_MS = 30_000;

function parsePositiveInteger(value, fallback) {
  const parsed = Number.parseInt(`${value ?? ""}`, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function readOption(name) {
  const prefix = `--${name}=`;
  const match = process.argv.slice(2).find((arg) => arg.startsWith(prefix));
  return match ? match.slice(prefix.length) : "";
}

function hasFlag(name) {
  return process.argv.slice(2).includes(`--${name}`);
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function getProtocolDefaultPort(protocol) {
  if (protocol === "http:") {
    return "80";
  }
  if (protocol === "https:") {
    return "443";
  }
  return "";
}

function getRequestedPort(targetUrl) {
  return targetUrl.port || getProtocolDefaultPort(targetUrl.protocol);
}

const url = readOption("url") || process.env.WINSMUX_DEV_BROWSER_URL || DEFAULT_URL;
const width = parsePositiveInteger(
  readOption("width") || process.env.WINSMUX_DEV_BROWSER_WIDTH,
  DEFAULT_WINDOW_WIDTH,
);
const height = parsePositiveInteger(
  readOption("height") || process.env.WINSMUX_DEV_BROWSER_HEIGHT,
  DEFAULT_WINDOW_HEIGHT,
);
const headless = hasFlag("headless") || process.env.WINSMUX_DEV_BROWSER_HEADLESS === "1";
const closeAfterProbe = hasFlag("probe");
const skipServer = hasFlag("no-server") || process.env.WINSMUX_DEV_BROWSER_NO_SERVER === "1";

async function canReachDevServer(targetUrl) {
  try {
    const response = await fetch(targetUrl, { method: "GET" });
    return response.ok || response.status < 500;
  } catch {
    return false;
  }
}

function waitForChildExit(child) {
  if (!child) {
    return new Promise(() => {});
  }
  if (child.exitCode !== null) {
    return Promise.resolve();
  }
  return new Promise((resolve) => child.once("exit", resolve));
}

async function waitForDevServer(targetUrl, child = null) {
  const startedAt = Date.now();
  const childExit = waitForChildExit(child);
  while (Date.now() - startedAt < SERVER_READY_TIMEOUT_MS) {
    if (await canReachDevServer(targetUrl)) {
      return;
    }
    if (child?.exitCode !== null) {
      throw new Error(`Dev server exited before it became reachable at ${targetUrl}`);
    }
    const result = await Promise.race([delay(250).then(() => "retry"), childExit.then(() => "exit")]);
    if (result === "exit") {
      throw new Error(`Dev server exited before it became reachable at ${targetUrl}`);
    }
  }
  throw new Error(`Timed out waiting for dev server at ${targetUrl}`);
}

function startDevServerIfNeeded(targetUrl) {
  if (skipServer) {
    return null;
  }
  const target = new URL(targetUrl);
  if (target.hostname !== "127.0.0.1" && target.hostname !== "localhost") {
    return null;
  }
  const port = getRequestedPort(target);
  if (!port) {
    return null;
  }
  return spawn(
    process.execPath,
    ["node_modules/vite/bin/vite.js", "--host", target.hostname, "--port", port, "--strictPort"],
    {
      cwd: process.cwd(),
      env: process.env,
      stdio: "inherit",
    },
  );
}

async function stopDevServer(child) {
  if (!child || child.killed || child.exitCode !== null) {
    return;
  }
  if (process.platform === "win32" && child.pid) {
    spawn("taskkill", ["/pid", String(child.pid), "/T", "/F"], {
      stdio: "ignore",
      windowsHide: true,
    });
  } else {
    child.kill();
  }
  await Promise.race([
    new Promise((resolve) => child.once("exit", resolve)),
    new Promise((resolve) => setTimeout(resolve, 2_000)),
  ]);
}

let devServer = null;
if (!(await canReachDevServer(url))) {
  devServer = startDevServerIfNeeded(url);
  if (!devServer) {
    throw new Error(`Dev server is not reachable at ${url}`);
  }
  try {
    await waitForDevServer(url, devServer);
  } catch (err) {
    await stopDevServer(devServer);
    throw err;
  }
}

let browser = null;

try {
  browser = await chromium.launch({
    headless,
    args: headless ? [] : [`--window-size=${width},${height}`],
  });

  const context = await browser.newContext(headless ? { viewport: { width, height } } : { viewport: null });
  const page = await context.newPage();
  await page.goto(url, { waitUntil: "domcontentloaded" });
  await page.bringToFront().catch(() => {});

  const metrics = await page.evaluate(() => {
    const shell = document.getElementById("app-shell");
    const shellRect = shell?.getBoundingClientRect();
    return {
      innerWidth: window.innerWidth,
      innerHeight: window.innerHeight,
      outerWidth: window.outerWidth,
      outerHeight: window.outerHeight,
      appShellWidth: shellRect?.width ?? null,
      appShellHeight: shellRect?.height ?? null,
    };
  });

  console.log(JSON.stringify({ url, headless, startedServer: Boolean(devServer), width, height, metrics }, null, 2));

  if (closeAfterProbe) {
    await browser.close();
  } else {
    await new Promise((resolve) => browser.on("disconnected", resolve));
  }
} finally {
  if (browser) {
    await browser.close().catch(() => {});
  }
  await stopDevServer(devServer);
}
