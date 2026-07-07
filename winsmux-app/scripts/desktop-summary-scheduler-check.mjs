import assert from "node:assert/strict";
import { DesktopSummaryRefreshScheduler } from "../src/desktopSummaryScheduler.ts";

class FakeWindow {
  constructor() {
    this.nextTimerId = 1;
    this.timeouts = new Map();
    this.intervals = [];
    this.focusListeners = [];
  }

  setTimeout(callback, delayMs) {
    const timerId = this.nextTimerId;
    this.nextTimerId += 1;
    this.timeouts.set(timerId, { callback, delayMs });
    return timerId;
  }

  clearTimeout(timerId) {
    this.timeouts.delete(timerId);
  }

  setInterval(callback, delayMs) {
    const timerId = this.nextTimerId;
    this.nextTimerId += 1;
    this.intervals.push({ timerId, callback, delayMs });
    return timerId;
  }

  addEventListener(type, listener) {
    if (type === "focus") {
      this.focusListeners.push(listener);
    }
  }

  runNextTimeout() {
    const next = this.timeouts.entries().next();
    assert.equal(next.done, false, "expected a pending timeout");
    const [timerId, timeout] = next.value;
    this.timeouts.delete(timerId);
    timeout.callback();
  }

  fireInterval(index = 0) {
    assert.ok(this.intervals[index], "expected a registered interval");
    this.intervals[index].callback();
  }

  fireFocus() {
    for (const listener of this.focusListeners) {
      listener();
    }
  }
}

class FakeDocument {
  constructor() {
    this.visibilityState = "visible";
    this.visibilityListeners = [];
  }

  addEventListener(type, listener) {
    if (type === "visibilitychange") {
      this.visibilityListeners.push(listener);
    }
  }

  fireVisibilityChange() {
    for (const listener of this.visibilityListeners) {
      listener();
    }
  }
}

async function flushMicrotasks() {
  await Promise.resolve();
  await Promise.resolve();
}

function createScheduler(overrides = {}) {
  const fakeWindow = new FakeWindow();
  const fakeDocument = new FakeDocument();
  const refreshCalls = [];
  let now = 0;
  let emitLiveEvent = () => {
    throw new Error("live subscription was not registered");
  };
  const scheduler = new DesktopSummaryRefreshScheduler({
    window: fakeWindow,
    document: fakeDocument,
    fallbackIntervalMs: 15_000,
    streamStaleMs: 60_000,
    getRefreshTarget: () => ({ projectDir: null, projectKey: "" }),
    refresh: async (context) => {
      refreshCalls.push(context.forceExplainRunId);
      context.markSuccessfulRefresh();
    },
    subscribe: async (onRefresh) => {
      emitLiveEvent = onRefresh;
      return () => {};
    },
    now: () => now,
    logger: console,
    ...overrides,
  });
  return {
    scheduler,
    fakeWindow,
    fakeDocument,
    refreshCalls,
    setNow: (value) => {
      now = value;
    },
    emitLiveEvent: (event) => emitLiveEvent(event),
  };
}

{
  const { scheduler, fakeWindow, refreshCalls } = createScheduler();

  scheduler.request("run-a", 150);
  scheduler.request("run-b", 150);

  assert.equal(fakeWindow.timeouts.size, 1, "debounce should keep only the newest timeout");
  fakeWindow.runNextTimeout();
  await flushMicrotasks();

  assert.deepEqual(refreshCalls, ["run-b"], "debounce should keep the newest forced run id");
}

{
  let finishFirstRefresh = () => {};
  const refreshCalls = [];
  const fakeWindow = new FakeWindow();
  const fakeDocument = new FakeDocument();
  const scheduler = new DesktopSummaryRefreshScheduler({
    window: fakeWindow,
    document: fakeDocument,
    fallbackIntervalMs: 15_000,
    streamStaleMs: 60_000,
    getRefreshTarget: () => ({ projectDir: null, projectKey: "" }),
    refresh: async (context) => {
      refreshCalls.push(context.forceExplainRunId);
      if (refreshCalls.length === 1) {
        await new Promise((resolve) => {
          finishFirstRefresh = resolve;
        });
      }
      context.markSuccessfulRefresh();
    },
    subscribe: async () => () => {},
    logger: console,
  });

  scheduler.request("first", 0);
  fakeWindow.runNextTimeout();
  await flushMicrotasks();
  scheduler.request("second", 0);
  fakeWindow.runNextTimeout();
  await flushMicrotasks();

  assert.deepEqual(refreshCalls, ["first"], "in-flight refresh should defer the queued request");
  finishFirstRefresh();
  await flushMicrotasks();
  await flushMicrotasks();

  assert.deepEqual(refreshCalls, ["first", "second"], "queued request should run after the in-flight refresh finishes");
}

{
  const {
    scheduler,
    fakeWindow,
    fakeDocument,
    refreshCalls,
    setNow,
    emitLiveEvent,
  } = createScheduler();

  scheduler.registerLiveRefresh();
  await flushMicrotasks();

  assert.equal(fakeWindow.intervals.length, 1, "fallback interval should be registered once");
  assert.equal(fakeWindow.focusListeners.length, 1, "focus fallback listener should be registered once");
  assert.equal(fakeDocument.visibilityListeners.length, 1, "visibility fallback listener should be registered once");

  setNow(100);
  emitLiveEvent({ source: "desktop", run_id: "live-run" });
  fakeWindow.runNextTimeout();
  await flushMicrotasks();

  assert.deepEqual(refreshCalls, ["live-run"], "live refresh event should request an immediate refresh");
  assert.equal(scheduler.shouldRunFallbackRefresh(60_099), false, "fresh live activity should suppress fallback");
  assert.equal(scheduler.shouldRunFallbackRefresh(60_100), true, "stale live activity should allow fallback");

  fakeDocument.visibilityState = "hidden";
  fakeWindow.fireInterval();
  await flushMicrotasks();
  assert.deepEqual(refreshCalls, ["live-run"], "hidden document should not run fallback refresh");

  fakeDocument.visibilityState = "visible";
  setNow(60_100);
  fakeDocument.fireVisibilityChange();
  fakeWindow.runNextTimeout();
  await flushMicrotasks();
  assert.deepEqual(refreshCalls, ["live-run", null], "visible stale fallback should request a refresh");
}

console.log("desktop-summary-scheduler-check passed");
