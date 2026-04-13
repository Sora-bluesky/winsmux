import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

type PtyCommandName = "pty_spawn" | "pty_write" | "pty_resize" | "pty_close";

interface PtyOutputEvent {
  pane_id: string;
  data: string;
}

export interface PtyCommandTransport {
  request(command: PtyCommandName, payload: Record<string, unknown>): Promise<void>;
}

function normalizePtyError(action: string, error: unknown) {
  if (error instanceof Error) {
    return new Error(`${action} failed: ${error.message}`);
  }

  return new Error(`${action} failed: ${String(error)}`);
}

export function createTauriPtyCommandTransport(
  invokeCommand: typeof invoke = invoke,
): PtyCommandTransport {
  return {
    async request(command: PtyCommandName, payload: Record<string, unknown>) {
      await invokeCommand(command, payload);
    },
  };
}

let ptyCommandTransport: PtyCommandTransport = createTauriPtyCommandTransport();

export function configurePtyCommandTransport(transport: PtyCommandTransport) {
  ptyCommandTransport = transport;
}

export async function spawnPtyPane(
  paneId: string,
  cols: number,
  rows: number,
) {
  try {
    await ptyCommandTransport.request("pty_spawn", { paneId, cols, rows });
  } catch (error) {
    throw normalizePtyError(`pty_spawn(${paneId})`, error);
  }
}

export async function writePtyData(paneId: string, data: string) {
  try {
    await ptyCommandTransport.request("pty_write", { paneId, data });
  } catch (error) {
    throw normalizePtyError(`pty_write(${paneId})`, error);
  }
}

export async function resizePtyPane(
  paneId: string,
  cols: number,
  rows: number,
) {
  try {
    await ptyCommandTransport.request("pty_resize", { paneId, cols, rows });
  } catch (error) {
    throw normalizePtyError(`pty_resize(${paneId})`, error);
  }
}

export async function closePtyPane(paneId: string) {
  try {
    await ptyCommandTransport.request("pty_close", { paneId });
  } catch (error) {
    throw normalizePtyError(`pty_close(${paneId})`, error);
  }
}

export async function subscribeToPtyOutput(
  onOutput: (event: PtyOutputEvent) => void,
): Promise<UnlistenFn> {
  return listen<string>("pty-output", (event) => {
    try {
      onOutput(JSON.parse(event.payload) as PtyOutputEvent);
    } catch {
      onOutput({
        pane_id: "",
        data: event.payload,
      });
    }
  });
}
