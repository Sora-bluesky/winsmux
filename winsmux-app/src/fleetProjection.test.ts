// @ts-nocheck

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { registerHooks } from "node:module";
import test from "node:test";

class FakeClassList {
  #values = new Set<string>();

  replaceFrom(value: string) {
    this.#values = new Set(value.split(/\s+/u).filter(Boolean));
  }

  contains(value: string) {
    return this.#values.has(value);
  }

  toString() {
    return [...this.#values].join(" ");
  }
}

class FakeElement {
  readonly attributes = new Map<string, string>();
  readonly children: FakeElement[] = [];
  readonly classList = new FakeClassList();
  id = "";
  parentElement: FakeElement | null = null;
  textContent = "";
  readonly tagName: string;

  constructor(tagName: string) {
    this.tagName = tagName;
  }

  get className() {
    return this.classList.toString();
  }

  set className(value: string) {
    this.classList.replaceFrom(value);
  }

  append(...elements: FakeElement[]) {
    for (const element of elements) {
      element.parentElement = this;
      this.children.push(element);
    }
  }

  insertBefore(element: FakeElement, reference: FakeElement | null) {
    element.parentElement = this;
    const index = reference === null ? -1 : this.children.indexOf(reference);
    if (index < 0) {
      this.children.push(element);
    } else {
      this.children.splice(index, 0, element);
    }
    return element;
  }

  replaceChildren(...elements: FakeElement[]) {
    for (const child of this.children) {
      child.parentElement = null;
    }
    this.children.splice(0, this.children.length);
    this.append(...elements);
  }

  setAttribute(name: string, value: string) {
    this.attributes.set(name, value);
  }

  getAttribute(name: string) {
    return this.attributes.get(name) ?? null;
  }

  matches(selector: string) {
    if (selector.startsWith("#")) {
      return this.id === selector.slice(1);
    }
    if (selector.startsWith(".")) {
      return this.classList.contains(selector.slice(1));
    }
    const attribute = selector.match(/^\[([a-z-]+)="([^"]+)"\]$/u);
    if (attribute) {
      return this.getAttribute(attribute[1]) === attribute[2];
    }
    return this.tagName.toLowerCase() === selector.toLowerCase();
  }

  querySelectorAll(selector: string): FakeElement[] {
    const matches: FakeElement[] = [];
    const visit = (element: FakeElement) => {
      for (const child of element.children) {
        if (child.matches(selector)) {
          matches.push(child);
        }
        visit(child);
      }
    };
    visit(this);
    return matches;
  }

  querySelector(selector: string) {
    return this.querySelectorAll(selector)[0] ?? null;
  }
}

class FakeDocument {
  readonly documentElement = new FakeElement("html");

  createElement(tagName: string) {
    return new FakeElement(tagName);
  }

  getElementById(id: string) {
    if (this.documentElement.id === id) {
      return this.documentElement;
    }
    return this.documentElement.querySelector(`#${id}`);
  }
}

const document = new FakeDocument();
const terminalDrawer = document.createElement("section");
const toolbar = document.createElement("div");
const workerStatus = document.createElement("div");
const panesContainer = document.createElement("div");
terminalDrawer.id = "terminal-drawer";
toolbar.id = "terminal-toolbar";
workerStatus.id = "worker-status-pill-bar";
panesContainer.id = "panes-container";
document.documentElement.append(terminalDrawer);
terminalDrawer.append(toolbar, workerStatus, panesContainer);

Object.assign(globalThis, {
  document,
  HTMLElement: FakeElement,
  Node: FakeElement,
});

const invokeCalls: Array<{ command: string; payload: unknown }> = [];
let nextInvoke = async (): Promise<unknown> => [];
globalThis.__fleetProjectionTestInvoke = async (command: string, payload: unknown) => {
  invokeCalls.push({ command, payload });
  return nextInvoke();
};

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === "@tauri-apps/api/core") {
      return { url: "fleet-projection-test:tauri", shortCircuit: true };
    }
    if (specifier.endsWith(".css")) {
      return { url: new URL(specifier, context.parentURL).href, shortCircuit: true };
    }
    return nextResolve(specifier, context);
  },
  load(url, context, nextLoad) {
    if (url === "fleet-projection-test:tauri") {
      return {
        format: "module",
        source: "export const invoke = (command, payload) => globalThis.__fleetProjectionTestInvoke(command, payload);",
        shortCircuit: true,
      };
    }
    if (url.endsWith(".css")) {
      return { format: "module", source: "", shortCircuit: true };
    }
    return nextLoad(url, context);
  },
});

const {
  mountFleetProjection,
  projectLocalFleet,
  refreshRemoteFleetProjection,
} = await import("./fleetProjection.ts");

function useInvokeValue(value: unknown) {
  nextInvoke = async () => value;
}

function useInvokeFailure(error: Error) {
  nextInvoke = async () => {
    throw error;
  };
}

function deferred() {
  let resolve: (value: unknown) => void = () => {};
  let reject: (reason?: unknown) => void = () => {};
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function renderedRows() {
  const root = document.getElementById("fleet-projection");
  assert.ok(root);
  return root.querySelectorAll(".fleet-projection-row").map((row) => ({
    location: row.querySelector(".fleet-projection-location")?.textContent,
    state: row.querySelector(".fleet-projection-state")?.textContent,
    latency: row.querySelector(".fleet-projection-latency")?.textContent,
    tagName: row.tagName,
    role: row.getAttribute("role"),
  }));
}

function renderedListItems() {
  const root = document.getElementById("fleet-projection");
  assert.ok(root);
  return root.querySelectorAll("li");
}

function createControlPipeHarness(panes: Map<string, { ptyStarted: boolean; ptyStarting: unknown }>) {
  let workerStatusRefreshInFlight: Promise<unknown> | null = null;
  let lastRemoteRefresh = Promise.resolve();
  const workersDeferred = deferred();

  function refreshWorkerStatusSurface() {
    projectLocalFleet(panes);
    if (workerStatusRefreshInFlight) {
      return workerStatusRefreshInFlight;
    }
    lastRemoteRefresh = refreshRemoteFleetProjection();
    void lastRemoteRefresh;
    workerStatusRefreshInFlight = workersDeferred.promise.finally(() => {
      workerStatusRefreshInFlight = null;
    });
    return workerStatusRefreshInFlight;
  }

  function markPanePtyStartedFromExternalEvent(paneId: string) {
    const entry = panes.get(paneId);
    if (!entry) {
      return;
    }
    const wasStarted = entry.ptyStarted;
    entry.ptyStarted = true;
    entry.ptyStarting = null;
    if (!wasStarted) {
      void refreshWorkerStatusSurface();
    }
  }

  function markPanePtyStoppedFromExternalEvent(paneId: string) {
    const entry = panes.get(paneId);
    if (!entry) {
      return;
    }
    const wasRunning = entry.ptyStarted || Boolean(entry.ptyStarting);
    entry.ptyStarted = false;
    entry.ptyStarting = null;
    if (wasRunning) {
      void refreshWorkerStatusSurface();
    }
  }

  function handleDesktopSummaryLiveRefreshEvent(event: { source: string; pane_id?: string; reason: string }) {
    if (event.source !== "pty" || !event.pane_id) {
      return;
    }
    if (event.reason === "pty.close") {
      markPanePtyStoppedFromExternalEvent(event.pane_id);
      return;
    }
    if (event.reason === "pty.spawn" || event.reason === "pty.respawn") {
      markPanePtyStartedFromExternalEvent(event.pane_id);
    }
  }

  return {
    refreshWorkerStatusSurface,
    handleDesktopSummaryLiveRefreshEvent,
    workersDeferred,
    get lastRemoteRefresh() {
      return lastRemoteRefresh;
    },
    getInFlight() {
      return workerStatusRefreshInFlight;
    },
  };
}

function renderedWarning() {
  return document
    .getElementById("fleet-projection")
    ?.querySelector(".fleet-projection-warning")
    ?.textContent ?? "";
}

function collectDomStrings(element: FakeElement): string[] {
  const values = [element.id, element.className, element.textContent, ...element.attributes.values()];
  for (const child of element.children) {
    values.push(...collectDomStrings(child));
  }
  return values;
}

test("mount inserts one noninteractive Fleet list immediately before worker status", () => {
  mountFleetProjection();
  mountFleetProjection();

  const root = document.getElementById("fleet-projection");
  assert.ok(root);
  assert.equal(terminalDrawer.children.indexOf(root), terminalDrawer.children.indexOf(workerStatus) - 1);
  assert.equal(terminalDrawer.querySelectorAll("#fleet-projection").length, 1);
  assert.equal(root.querySelectorAll("button").length, 0);
  assert.equal(root.querySelectorAll("input").length, 0);
  assert.equal(root.querySelectorAll("li").length, 0);
  assert.equal(root.querySelectorAll(".fleet-projection-empty").length, 0);
  assert.equal(invokeCalls.length, 0);
});

test("projects all six frozen mappings and excludes idle local panes", async () => {
  projectLocalFleet(new Map([
    ["local-live", { ptyStarted: true, ptyStarting: null }],
    ["local-starting", { ptyStarted: false, ptyStarting: Promise.resolve() }],
    ["local-idle", { ptyStarted: false, ptyStarting: null }],
  ]));
  useInvokeValue([
    { sessionId: "remote-attached", hostAlias: "alpha", controllerState: "attached", lastHelloWelcomeRttMs: 0 },
    { sessionId: "remote-detached", hostAlias: "beta", controllerState: "detached", lastHelloWelcomeRttMs: 8 },
    { sessionId: "remote-unreachable", hostAlias: "gamma", controllerState: "unreachable", lastHelloWelcomeRttMs: 15 },
  ]);
  await refreshRemoteFleetProjection();

  assert.deepEqual(renderedRows(), [
    { location: "LOCAL · This device", state: "live", latency: "local", tagName: "li", role: "listitem" },
    { location: "LOCAL · This device", state: "connecting", latency: "local", tagName: "li", role: "listitem" },
    { location: "REMOTE · alpha", state: "live", latency: "0 ms", tagName: "li", role: "listitem" },
    { location: "REMOTE · beta", state: "detached", latency: "8 ms", tagName: "li", role: "listitem" },
    { location: "REMOTE · gamma", state: "unreachable", latency: "15 ms", tagName: "li", role: "listitem" },
  ]);
  assert.deepEqual(invokeCalls.at(-1), { command: "remote_session_snapshots", payload: undefined });
});

test("local startup remains one row from connecting to live and all frozen removal paths are immediate", async () => {
  useInvokeValue([]);
  await refreshRemoteFleetProjection();
  const entry = { ptyStarted: false, ptyStarting: Promise.resolve() };
  const panes = new Map([["worker-private-id", entry]]);

  projectLocalFleet(panes);
  assert.equal(renderedRows()[0].state, "connecting");
  entry.ptyStarted = true;
  projectLocalFleet(panes);
  assert.equal(renderedRows()[0].state, "live");

  entry.ptyStarted = false;
  entry.ptyStarting = null;
  projectLocalFleet(panes);
  assert.equal(renderedRows().length, 0, "failed start removes the row");

  entry.ptyStarted = true;
  panes.set("worker-private-id", entry);
  projectLocalFleet(panes);
  panes.delete("worker-private-id");
  projectLocalFleet(panes);
  assert.equal(renderedRows().length, 0, "panes.delete removes the row");

  const resetAndClose = async (closePtyPane: () => Promise<void>) => {
    entry.ptyStarted = false;
    entry.ptyStarting = null;
    projectLocalFleet(panes);
    assert.equal(renderedRows().length, 0, "reset removes the row before awaiting closePtyPane");
    await closePtyPane();
  };
  panes.set("worker-private-id", entry);
  entry.ptyStarted = true;
  projectLocalFleet(panes);
  await resetAndClose(async () => {});

  entry.ptyStarted = true;
  projectLocalFleet(panes);
  await assert.rejects(resetAndClose(async () => {
    throw new Error("close rejected");
  }), /close rejected/u);
  assert.equal(renderedRows().length, 0);
});

test("empty sources stay an empty list and a first remote failure does not claim a last snapshot", async () => {
  mountFleetProjection();
  assert.equal(renderedListItems().length, 0);
  useInvokeFailure(new Error("private-host secret-token executable-path"));
  await refreshRemoteFleetProjection();
  assert.equal(renderedListItems().length, 0);
  assert.equal(renderedRows().length, 0);
  assert.equal(renderedWarning(), "Remote Fleet refresh unavailable.");
  assert.equal(renderedWarning().includes("last successful"), false);
  assert.equal(collectDomStrings(document.documentElement).join(" ").includes("private-host"), false);
});

test("spawn, respawn, and close re-project locally while worker status refresh is in flight", async () => {
  mountFleetProjection();
  const pendingRemote = deferred();
  nextInvoke = async () => pendingRemote.promise;
  const panes = new Map([["worker-1", { ptyStarted: false, ptyStarting: null }]]);
  const harness = createControlPipeHarness(panes);

  const remoteInvokesBeforeFlight = invokeCalls.filter((call) => call.command === "remote_session_snapshots").length;
  const inFlightRefresh = harness.refreshWorkerStatusSurface();
  assert.ok(harness.getInFlight(), "workerStatusRefreshInFlight must be set before control-pipe events");
  const remoteInvokesAtFlight = invokeCalls.filter((call) => call.command === "remote_session_snapshots").length;
  assert.equal(remoteInvokesAtFlight, remoteInvokesBeforeFlight + 1);

  harness.handleDesktopSummaryLiveRefreshEvent({ source: "pty", pane_id: "worker-1", reason: "pty.spawn" });
  assert.equal(renderedRows()[0]?.state, "live", "spawn is visible while refresh is in flight");
  harness.handleDesktopSummaryLiveRefreshEvent({ source: "pty", pane_id: "worker-1", reason: "pty.respawn" });
  assert.equal(renderedRows()[0]?.state, "live", "respawn keeps the live row while refresh is in flight");
  harness.handleDesktopSummaryLiveRefreshEvent({ source: "pty", pane_id: "worker-1", reason: "pty.close" });
  assert.equal(renderedRows().length, 0, "close removes the row while refresh is in flight");
  assert.equal(
    invokeCalls.filter((call) => call.command === "remote_session_snapshots").length,
    remoteInvokesAtFlight,
    "in-flight spawn/respawn/close must not start another remote refresh",
  );

  pendingRemote.resolve([
    { sessionId: "late-remote", hostAlias: "remote-a", controllerState: "attached", lastHelloWelcomeRttMs: 4 },
  ]);
  await harness.lastRemoteRefresh;
  assert.deepEqual(renderedRows().map((row) => row.location), ["REMOTE · remote-a"]);
  assert.equal(renderedRows().some((row) => row.location === "LOCAL · This device"), false);

  const resetRemote = deferred();
  nextInvoke = async () => resetRemote.promise;
  harness.workersDeferred.resolve(undefined);
  await inFlightRefresh;

  const resetHarness = createControlPipeHarness(panes);
  const resetInFlight = resetHarness.refreshWorkerStatusSurface();
  assert.ok(resetHarness.getInFlight());
  panes.set("worker-1", { ptyStarted: false, ptyStarting: null });
  resetHarness.handleDesktopSummaryLiveRefreshEvent({ source: "pty", pane_id: "worker-1", reason: "pty.spawn" });
  assert.equal(renderedRows().some((row) => row.location === "LOCAL · This device"), true);
  resetHarness.handleDesktopSummaryLiveRefreshEvent({ source: "pty", pane_id: "worker-1", reason: "pty.close" });
  assert.equal(renderedRows().some((row) => row.location === "LOCAL · This device"), false);
  resetRemote.resolve([
    { sessionId: "post-reset-remote", hostAlias: "remote-b", controllerState: "detached", lastHelloWelcomeRttMs: 5 },
  ]);
  await resetHarness.lastRemoteRefresh;
  resetHarness.workersDeferred.resolve(undefined);
  await resetInFlight;
  assert.deepEqual(renderedRows().map((row) => row.location), ["REMOTE · remote-b"]);
});

test("newer remote generations win and failures retain the last successful states", async () => {
  const older = deferred();
  nextInvoke = async () => older.promise;
  const olderRefresh = refreshRemoteFleetProjection();
  const newer = deferred();
  nextInvoke = async () => newer.promise;
  const newerRefresh = refreshRemoteFleetProjection();

  newer.resolve([
    { sessionId: "newer-id", hostAlias: "newer", controllerState: "detached", lastHelloWelcomeRttMs: 2 },
  ]);
  await newerRefresh;
  older.resolve([
    { sessionId: "older-id", hostAlias: "older", controllerState: "unreachable", lastHelloWelcomeRttMs: 99 },
  ]);
  await olderRefresh;
  assert.deepEqual(renderedRows(), [
    { location: "REMOTE · newer", state: "detached", latency: "2 ms", tagName: "li", role: "listitem" },
  ]);

  useInvokeFailure(new Error("private-host secret-token executable-path"));
  await refreshRemoteFleetProjection();
  assert.equal(renderedRows()[0].state, "detached");
  assert.equal(renderedWarning(), "Remote Fleet refresh unavailable.");
  assert.equal(collectDomStrings(document.documentElement).join(" ").includes("private-host"), false);
});

test("duplicate aliases stay distinct while pending, malformed, and duplicate records are atomic failures", async () => {
  useInvokeValue([
    { sessionId: "first-shared-alias", hostAlias: "shared", controllerState: "detached", lastHelloWelcomeRttMs: 1 },
    { sessionId: "second-shared-alias", hostAlias: "shared", controllerState: "unreachable", lastHelloWelcomeRttMs: 2 },
    { sessionId: "same-helper-id", hostAlias: "first", controllerState: "attached", lastHelloWelcomeRttMs: 0 },
    { sessionId: "same-helper-id", hostAlias: "second", controllerState: "attached", lastHelloWelcomeRttMs: 0 },
  ]);
  await refreshRemoteFleetProjection();
  const retainedLocations = ["REMOTE · shared", "REMOTE · shared", "REMOTE · first", "REMOTE · second"];
  assert.deepEqual(renderedRows().map((row) => row.location), retainedLocations);

  const invalidPayloads = [
    [{ sessionId: "pending-id", hostAlias: "pending", controllerState: "connecting", lastHelloWelcomeRttMs: 1 }],
    [{ sessionId: "missing-rtt", hostAlias: "malformed", controllerState: "attached" }],
    [
      { sessionId: "duplicate", hostAlias: "same", controllerState: "attached", lastHelloWelcomeRttMs: 1 },
      { sessionId: "duplicate", hostAlias: "same", controllerState: "detached", lastHelloWelcomeRttMs: 2 },
    ],
  ];
  for (const payload of invalidPayloads) {
    useInvokeValue(payload);
    await refreshRemoteFleetProjection();
    assert.deepEqual(renderedRows().map((row) => row.location), retainedLocations);
    assert.notEqual(renderedWarning(), "");
  }
});

test("session IDs and unexpected private fields never reach DOM, attributes, logs, storage, or lifecycle calls", async () => {
  const sessionId = "0123456789abcdef0123456789abcdef";
  const privateValues = [
    sessionId,
    "resolved.private.example",
    "C:\\private\\agent.exe",
    "credential-secret",
    "private terminal output",
    "helper-private-id",
  ];
  useInvokeValue([{
    sessionId,
    hostAlias: "safe-alias",
    controllerState: "attached",
    lastHelloWelcomeRttMs: 3,
    hostname: privateValues[1],
    executable: privateValues[2],
    credential: privateValues[3],
    output: privateValues[4],
    helperId: privateValues[5],
  }]);
  await refreshRemoteFleetProjection();

  const domValues = collectDomStrings(document.documentElement).join("\n");
  for (const value of privateValues) {
    assert.equal(domValues.includes(value), false, value);
  }
  assert.equal(renderedRows().some((row) => row.location === "REMOTE · safe-alias"), false);

  const source = await readFile(new URL("./fleetProjection.ts", import.meta.url), "utf8");
  assert.equal(/createPane|localStorage|sessionStorage|console\.|remote_session_(?:start|reattach|detach|stop)/u.test(source), false);
  assert.equal([...source.matchAll(/invoke(?:<[^>]+>)?\(\s*["']([^"']+)/gu)].map((match) => match[1]).join(","), "remote_session_snapshots");
});

test("CSS reserves four drawer rows without changing styles.css", async () => {
  const css = await readFile(new URL("./fleetProjection.css", import.meta.url), "utf8");
  assert.match(css, /#terminal-drawer\s*\{[^}]*grid-template-rows:\s*auto auto auto minmax\(0,\s*1fr\)/su);
  assert.match(css, /#fleet-projection\s*\{[^}]*grid-row:\s*2/su);
  assert.match(css, /#worker-status-pill-bar\s*\{[^}]*grid-row:\s*3/su);
  assert.match(css, /#panes-container\s*\{[^}]*grid-row:\s*4/su);
});

test("main.ts integrates every local transition and keeps the in-flight choke point synchronous", async () => {
  const main = await readFile(new URL("./main.ts", import.meta.url), "utf8");
  const importLine = main.split(/\r?\n/u).find((line) => line.includes("./sshConnectReview")) ?? "";
  assert.match(importLine, /\.\/fleetProjection/u);

  const refreshStart = main.indexOf("async function refreshWorkerStatusSurface()");
  const refreshEnd = main.indexOf("\n}\n\nfunction getAgentVaultProviderDefinition", refreshStart);
  const refresh = main.slice(refreshStart, refreshEnd);
  assert.ok(refresh.indexOf("projectLocalFleet(panes)") < refresh.indexOf("if (workerStatusRefreshInFlight)"));
  assert.ok(refresh.indexOf("if (workerStatusRefreshInFlight)") < refresh.indexOf("refreshRemoteFleetProjection()"));
  assert.match(refresh, /if \(workerStatusRefreshInFlight\) \{\s*return workerStatusRefreshInFlight;/u);
  assert.match(refresh, /refreshRemoteFleetProjection\(\)/u);

  const startIndex = main.indexOf("entry.ptyStarting = spawnPtyPane");
  const startEndMarker = "projectLocalFleet(panes); return entry.ptyStarting;";
  const start = main.slice(startIndex, main.indexOf(startEndMarker, startIndex) + startEndMarker.length);
  assert.match(start, /entry\.ptyStarting = spawnPtyPane[\s\S]*?\}\);\s*projectLocalFleet\(panes\)/u);
  assert.match(start, /entry\.ptyStarted = true;[\s\S]*?refreshWorkerStatusSurface\(\)/u);
  assert.match(start, /\.finally\(\(\) => \{\s*entry\.ptyStarting = null;\s*projectLocalFleet\(panes\)/u);

  assert.match(main, /panes\.delete\(id\);\s*projectLocalFleet\(panes\)/u);
  const reset = main.slice(main.indexOf("async function resetWorkerPaneForStartup"), main.indexOf("function getWorkerStatusRowForStart", main.indexOf("async function resetWorkerPaneForStartup")));
  assert.match(reset, /entry\.ptyStarted = false;\s*entry\.ptyStarting = null;\s*projectLocalFleet\(panes\);[\s\S]*?await closePtyPane\(target\)/u);

  for (const functionName of ["markPanePtyStartedFromExternalEvent", "markPanePtyStoppedFromExternalEvent"]) {
    const functionStart = main.indexOf(`function ${functionName}`);
    const functionEnd = main.indexOf("\n}\n", functionStart);
    assert.match(main.slice(functionStart, functionEnd), /refreshWorkerStatusSurface\(\)/u);
  }

  const liveRefreshStart = main.indexOf("function handleDesktopSummaryLiveRefreshEvent");
  const liveRefreshEnd = main.indexOf("function registerDesktopSummaryLiveRefresh", liveRefreshStart);
  const liveRefresh = main.slice(liveRefreshStart, liveRefreshEnd);
  assert.match(liveRefresh, /event\.reason === "pty\.close"/u);
  assert.match(liveRefresh, /event\.reason === "pty\.spawn" \|\| event\.reason === "pty\.respawn"/u);
  assert.match(liveRefresh, /markPanePtyStartedFromExternalEvent\(workbenchPaneId\)/u);
  assert.match(liveRefresh, /markPanePtyStoppedFromExternalEvent\(workbenchPaneId\)/u);
});
