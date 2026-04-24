import { invoke, isTauri } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

const PTY_JSON_RPC_VERSION = "2.0";
type PtyCommandName =
  | "pty.spawn"
  | "pty.write"
  | "pty.resize"
  | "pty.capture"
  | "pty.respawn"
  | "pty.close";

interface PtyOutputEvent {
  pane_id: string;
  data: string;
}

interface PtyJsonRpcRequest {
  jsonrpc: typeof PTY_JSON_RPC_VERSION;
  id: string;
  method: PtyCommandName;
  params?: Record<string, unknown>;
}

interface PtyJsonRpcError {
  code: number;
  message: string;
}

type PtyJsonRpcResponse =
  | {
      jsonrpc: typeof PTY_JSON_RPC_VERSION;
      id: string;
      result: unknown;
    }
  | {
      jsonrpc: typeof PTY_JSON_RPC_VERSION;
      id: string;
      error: PtyJsonRpcError;
    };

export interface PtyCommandTransport {
  request<T = unknown>(
    command: PtyCommandName,
    payload: Record<string, unknown>,
  ): Promise<T>;
}

export interface PtyCaptureResult {
  paneId: string;
  output: string;
}

let ptyRequestSequence = 0;

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
    async request<T = unknown>(
      command: PtyCommandName,
      payload: Record<string, unknown>,
    ): Promise<T> {
      if (!isTauri()) {
        if (command === "pty.capture") {
          return {
            paneId: String(payload.paneId ?? payload.pane_id ?? ""),
            output: "",
          } as T;
        }

        return undefined as T;
      }

      const request: PtyJsonRpcRequest = {
        jsonrpc: PTY_JSON_RPC_VERSION,
        id: `pty-${++ptyRequestSequence}`,
        method: command,
        params: payload,
      };
      const response = await invokeCommand<PtyJsonRpcResponse>("pty_json_rpc", {
        request,
      });

      if ("error" in response) {
        throw new Error(response.error.message);
      }

      return response.result as T;
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
    await ptyCommandTransport.request("pty.spawn", { paneId, cols, rows });
  } catch (error) {
    throw normalizePtyError(`pty.spawn(${paneId})`, error);
  }
}

export async function writePtyData(paneId: string, data: string) {
  try {
    await ptyCommandTransport.request("pty.write", { paneId, data });
  } catch (error) {
    throw normalizePtyError(`pty.write(${paneId})`, error);
  }
}

export async function resizePtyPane(
  paneId: string,
  cols: number,
  rows: number,
) {
  try {
    await ptyCommandTransport.request("pty.resize", { paneId, cols, rows });
  } catch (error) {
    throw normalizePtyError(`pty.resize(${paneId})`, error);
  }
}

export async function capturePtyPane(
  paneId: string,
): Promise<PtyCaptureResult> {
  try {
    return await ptyCommandTransport.request<PtyCaptureResult>("pty.capture", {
      paneId,
    });
  } catch (error) {
    throw normalizePtyError(`pty.capture(${paneId})`, error);
  }
}

export async function respawnPtyPane(paneId: string) {
  try {
    await ptyCommandTransport.request("pty.respawn", { paneId });
  } catch (error) {
    throw normalizePtyError(`pty.respawn(${paneId})`, error);
  }
}

export async function closePtyPane(paneId: string) {
  try {
    await ptyCommandTransport.request("pty.close", { paneId });
  } catch (error) {
    throw normalizePtyError(`pty.close(${paneId})`, error);
  }
}

export async function subscribeToPtyOutput(
  onOutput: (event: PtyOutputEvent) => void,
): Promise<UnlistenFn> {
  if (!isTauri()) {
    return async () => {};
  }

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
