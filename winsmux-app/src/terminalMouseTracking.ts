const MOUSE_TRACKING_RESET_SEQUENCE = "\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l";
const ALTERNATE_SCREEN_MODES = new Set([47, 1047, 1049]);

type CsiParameter = number | number[];

interface TerminalMouseTrackingTerminal {
  parser: {
    registerCsiHandler(
      identifier: { prefix?: string; final: string },
      callback: (params: CsiParameter[]) => boolean,
    ): { dispose(): void };
  };
  write(data: string): void;
}

export function resetTerminalMouseTracking(terminal: TerminalMouseTrackingTerminal) {
  terminal.write(MOUSE_TRACKING_RESET_SEQUENCE);
}

export function installTerminalMouseTrackingReset(terminal: TerminalMouseTrackingTerminal) {
  let resetScheduled = false;
  return terminal.parser.registerCsiHandler({ prefix: "?", final: "l" }, (params) => {
    const exitsAlternateScreen = params.some((param) => typeof param === "number" && ALTERNATE_SCREEN_MODES.has(param));
    if (!exitsAlternateScreen || resetScheduled) {
      return false;
    }

    resetScheduled = true;
    queueMicrotask(() => {
      resetScheduled = false;
      // Let xterm process the TUI's DECRST first, then clear every supported
      // tracking mode in the frontend. xterm does not expose SGR encoding
      // state separately, so an active-protocol check would miss a leaked 1006.
      resetTerminalMouseTracking(terminal);
    });
    return false;
  });
}
