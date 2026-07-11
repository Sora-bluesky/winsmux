import assert from "node:assert/strict";
import {
  installTerminalMouseTrackingReset,
  resetTerminalMouseTracking,
} from "../src/terminalMouseTracking.ts";

const MOUSE_TRACKING_RESET_SEQUENCE = "\x1b[?1015l\x1b[?1006l\x1b[?1005l\x1b[?1003l\x1b[?1002l\x1b[?1000l\x1b[?9l";

class FakeTerminal {
  writes = [];
  csiHandler = null;

  parser = {
    registerCsiHandler: (identifier, callback) => {
      assert.deepEqual(identifier, { prefix: "?", final: "l" });
      this.csiHandler = callback;
      return { dispose() {} };
    },
  };

  write(data) {
    this.writes.push(data);
  }
}

async function flushMicrotasks() {
  await Promise.resolve();
  await Promise.resolve();
}

for (const alternateScreenMode of [47, 1047, 1049]) {
  const terminal = new FakeTerminal();
  installTerminalMouseTrackingReset(terminal);
  assert.ok(terminal.csiHandler, "expected a DEC private-mode reset handler");
  assert.equal(terminal.csiHandler([alternateScreenMode]), false, "the xterm fallback handler must still process the TUI exit");
  await flushMicrotasks();
  assert.deepEqual(
    terminal.writes,
    [MOUSE_TRACKING_RESET_SEQUENCE],
    "leaving the alternate screen with active mouse tracking must clear every supported tracking mode",
  );
}

{
  const terminal = new FakeTerminal();
  installTerminalMouseTrackingReset(terminal);
  terminal.csiHandler([1049]);
  terminal.csiHandler([1047]);
  await flushMicrotasks();
  assert.deepEqual(
    terminal.writes,
    [MOUSE_TRACKING_RESET_SEQUENCE],
    "multiple alternate-screen exits in one parser turn must schedule only one frontend reset",
  );
}

{
  const terminal = new FakeTerminal();
  installTerminalMouseTrackingReset(terminal);
  terminal.csiHandler([25]);
  await flushMicrotasks();
  assert.deepEqual(terminal.writes, [], "unrelated DEC private-mode resets must not change mouse tracking");
}

{
  const terminal = new FakeTerminal();
  resetTerminalMouseTracking(terminal);
  assert.deepEqual(terminal.writes, [MOUSE_TRACKING_RESET_SEQUENCE], "lifecycle cleanup must use the same exact reset sequence");
}

process.stdout.write("[terminal-mouse-tracking] PASS\n");
