/**
 * winsmux SDK — TypeScript client for the winsmux MCP Server
 *
 * Communicates with mcp-server.js via child_process spawn + stdio JSON-RPC 2.0.
 * No external dependencies.
 */

import { spawn, ChildProcess } from "child_process";
import { resolve, dirname } from "path";
import { createInterface, Interface } from "readline";

interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: number;
  method: string;
  params?: Record<string, unknown>;
}

interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: number;
  result?: {
    content?: Array<{ type: string; text: string }>;
    isError?: boolean;
    [key: string]: unknown;
  };
  error?: { code: number; message: string };
}

type PendingRequest = {
  resolve: (value: JsonRpcResponse) => void;
  reject: (reason: Error) => void;
};

export class WinsmuxClient {
  private serverPath: string;
  private process: ChildProcess | null = null;
  private rl: Interface | null = null;
  private nextId = 1;
  private pending = new Map<number, PendingRequest>();
  private initialized = false;
  private initPromise: Promise<void> | null = null;

  constructor(serverPath?: string) {
    this.serverPath = serverPath ?? this.resolveDefaultServerPath();
  }

  // --- Public API ---

  /** List labeled panes in the current winsmux session. */
  async list(): Promise<string> {
    return this.callTool("winsmux_list", {});
  }

  /** Read recent output from a pane. */
  async read(target: string, lines?: number): Promise<string> {
    const args: Record<string, unknown> = { target };
    if (lines !== undefined) args.lines = lines;
    return this.callTool("winsmux_read", args);
  }

  /** Send text to a pane via winsmux-bridge send. */
  async send(target: string, text: string): Promise<string> {
    return this.callTool("winsmux_send", { target, text });
  }

  /** Route text to the appropriate pane by keyword. */
  async dispatch(text: string): Promise<string> {
    return this.callTool("winsmux_dispatch", { text });
  }

  /** Health check all panes. */
  async health(): Promise<string> {
    return this.callTool("winsmux_health", {});
  }

  /** Run plan-exec-verify-fix pipeline for a task. */
  async pipeline(task: string): Promise<string> {
    return this.callTool("winsmux_pipeline", { task });
  }

  /** Close the child process and clean up. */
  close(): void {
    if (this.rl) {
      this.rl.close();
      this.rl = null;
    }
    if (this.process) {
      this.process.stdin?.end();
      this.process.kill();
      this.process = null;
    }
    this.initialized = false;
    this.initPromise = null;
    // Reject any pending requests
    for (const [, pending] of this.pending) {
      pending.reject(new Error("Client closed"));
    }
    this.pending.clear();
  }

  // --- Internals ---

  private resolveDefaultServerPath(): string {
    // Relative to this file: ../../winsmux-core/mcp-server.js
    return resolve(dirname(__filename), "..", "..", "psmux-bridge", "mcp-server.js");
  }

  private ensureProcess(): void {
    if (this.process) return;

    this.process = spawn("node", [this.serverPath], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });

    this.rl = createInterface({ input: this.process.stdout! });

    this.rl.on("line", (line: string) => {
      const trimmed = line.trim();
      if (!trimmed) return;
      let msg: JsonRpcResponse;
      try {
        msg = JSON.parse(trimmed);
      } catch {
        return; // ignore unparseable lines
      }
      if (msg.id !== undefined && this.pending.has(msg.id)) {
        const p = this.pending.get(msg.id)!;
        this.pending.delete(msg.id);
        p.resolve(msg);
      }
    });

    this.process.on("error", (err: Error) => {
      for (const [, pending] of this.pending) {
        pending.reject(err);
      }
      this.pending.clear();
    });

    this.process.on("exit", () => {
      this.process = null;
      this.rl = null;
      this.initialized = false;
      this.initPromise = null;
    });
  }

  private sendRequest(method: string, params?: Record<string, unknown>): Promise<JsonRpcResponse> {
    this.ensureProcess();
    const id = this.nextId++;
    const req: JsonRpcRequest = { jsonrpc: "2.0", id, method };
    if (params !== undefined) req.params = params;

    return new Promise<JsonRpcResponse>((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      const line = JSON.stringify(req) + "\n";
      this.process!.stdin!.write(line, (err) => {
        if (err) {
          this.pending.delete(id);
          reject(err);
        }
      });
    });
  }

  private async ensureInitialized(): Promise<void> {
    if (this.initialized) return;

    // Prevent concurrent initialization
    if (this.initPromise) {
      await this.initPromise;
      return;
    }

    this.initPromise = (async () => {
      // Step 1: initialize
      const initResp = await this.sendRequest("initialize", {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "winsmux-sdk-ts", version: "1.0.0" },
      });

      if (initResp.error) {
        throw new Error(`Initialize failed: ${initResp.error.message}`);
      }

      // Step 2: notifications/initialized (no response expected, so fire-and-forget)
      this.ensureProcess();
      const notification = JSON.stringify({
        jsonrpc: "2.0",
        method: "notifications/initialized",
      }) + "\n";
      this.process!.stdin!.write(notification);

      this.initialized = true;
    })();

    await this.initPromise;
  }

  private async callTool(name: string, args: Record<string, unknown>): Promise<string> {
    await this.ensureInitialized();

    const resp = await this.sendRequest("tools/call", {
      name,
      arguments: args,
    });

    if (resp.error) {
      throw new Error(`Tool call failed: ${resp.error.message}`);
    }

    const content = resp.result?.content;
    if (Array.isArray(content) && content.length > 0) {
      const text = content[0].text;
      if (resp.result?.isError) {
        throw new Error(text);
      }
      return text;
    }

    return "";
  }
}
