import { invoke } from "@tauri-apps/api/core";

type DesktopCommandName = "desktop_summary_snapshot" | "desktop_run_explain";
type DesktopJsonRpcMethod = "desktop.summary.snapshot" | "desktop.run.explain";

interface DesktopJsonRpcRequest {
  jsonrpc: "2.0";
  id: string;
  method: DesktopJsonRpcMethod;
  params?: Record<string, unknown>;
}

interface DesktopJsonRpcError {
  code: number;
  message: string;
}

type DesktopJsonRpcResponse<TResponse> =
  | {
      jsonrpc: "2.0";
      id: string;
      result: TResponse;
    }
  | {
      jsonrpc: "2.0";
      id: string;
      error: DesktopJsonRpcError;
    };

export interface DesktopCommandTransport {
  request<TResponse>(
    command: DesktopCommandName,
    payload?: Record<string, unknown>,
  ): Promise<TResponse>;
}

export interface DesktopBoardSummary {
  pane_count: number;
  dirty_panes: number;
  review_pending: number;
  review_failed: number;
  review_passed: number;
  tasks_in_progress: number;
  tasks_blocked: number;
}

export interface DesktopBoardPane {
  label: string;
  pane_id: string;
  role: string;
  task: string;
  task_state: string;
  review_state: string;
  branch: string;
  changed_file_count: number;
}

export interface DesktopInboxSummary {
  item_count: number;
}

export interface DesktopInboxItem {
  kind: string;
  message: string;
  label: string;
  pane_id: string;
  task_state: string;
  review_state: string;
  branch: string;
  changed_file_count: number;
}

export interface DesktopDigestSummary {
  item_count: number;
  actionable_items: number;
  review_pending: number;
  review_failed: number;
}

export interface DesktopDigestItem {
  run_id: string;
  task: string;
  label: string;
  pane_id: string;
  role: string;
  task_state: string;
  review_state: string;
  next_action: string;
  branch: string;
  head_short: string;
  changed_file_count: number;
  changed_files: string[];
  verification_outcome?: string;
  security_blocked?: string;
}

export interface DesktopRunProjection {
  run_id: string;
  pane_id: string;
  label: string;
  branch: string;
  task: string;
  task_state: string;
  review_state: string;
  verification_outcome: string;
  security_blocked: string;
  changed_files: string[];
  next_action: string;
  summary: string;
  reasons: string[];
}

export interface DesktopSummarySnapshot {
  generated_at: string;
  project_dir: string;
  board: {
    summary: DesktopBoardSummary;
    panes: DesktopBoardPane[];
  };
  inbox: {
    summary: DesktopInboxSummary;
    items: DesktopInboxItem[];
  };
  digest: {
    summary: DesktopDigestSummary;
    items: DesktopDigestItem[];
  };
  run_projections: DesktopRunProjection[];
}

export interface DesktopExplainPayload {
  run: {
    run_id: string;
    task: string;
    state: string;
    task_state: string;
    review_state: string;
    branch: string;
    head_sha: string;
    changed_files: string[];
  };
  explanation: {
    summary: string;
    reasons: string[];
    next_action: string;
  };
  evidence_digest: {
    next_action: string;
    changed_file_count: number;
    changed_files: string[];
    verification_outcome?: string;
    security_blocked?: string;
  };
  recent_events: Array<{
    timestamp: string;
    event: string;
    label: string;
    message: string;
  }>;
}

let nextDesktopJsonRpcId = 0;

function normalizeDesktopError(action: string, error: unknown) {
  if (error instanceof Error) {
    return new Error(`${action} failed: ${error.message}`);
  }

  return new Error(`${action} failed: ${String(error)}`);
}

function getDesktopJsonRpcMethod(command: DesktopCommandName): DesktopJsonRpcMethod {
  switch (command) {
    case "desktop_summary_snapshot":
      return "desktop.summary.snapshot";
    case "desktop_run_explain":
      return "desktop.run.explain";
  }
}

function normalizeDesktopJsonRpcError(
  method: DesktopJsonRpcMethod,
  error: DesktopJsonRpcError,
) {
  return new Error(`${method} returned JSON-RPC error ${error.code}: ${error.message}`);
}

export function createJsonRpcDesktopCommandTransport(
  invokeCommand: typeof invoke = invoke,
): DesktopCommandTransport {
  return {
    async request<TResponse>(
      command: DesktopCommandName,
      payload?: Record<string, unknown>,
    ) {
      const method = getDesktopJsonRpcMethod(command);
      const request: DesktopJsonRpcRequest = {
        jsonrpc: "2.0",
        id: `desktop-${++nextDesktopJsonRpcId}`,
        method,
      };
      if (payload && Object.keys(payload).length > 0) {
        request.params = payload;
      }

      const response = await invokeCommand<DesktopJsonRpcResponse<TResponse>>(
        "desktop_json_rpc",
        { request },
      );
      if (response.jsonrpc !== "2.0") {
        throw new Error(`${method} returned an invalid JSON-RPC version`);
      }
      if (response.id !== request.id) {
        throw new Error(`${method} returned an unexpected JSON-RPC id`);
      }
      if ("error" in response) {
        throw normalizeDesktopJsonRpcError(method, response.error);
      }

      return response.result;
    },
  };
}

let desktopCommandTransport: DesktopCommandTransport =
  createJsonRpcDesktopCommandTransport();

export function createTauriDesktopCommandTransport(
  invokeCommand: typeof invoke = invoke,
): DesktopCommandTransport {
  return createJsonRpcDesktopCommandTransport(invokeCommand);
}

export function configureDesktopCommandTransport(
  transport: DesktopCommandTransport,
) {
  desktopCommandTransport = transport;
}

export async function getDesktopSummarySnapshot() {
  try {
    return await desktopCommandTransport.request<DesktopSummarySnapshot>(
      "desktop_summary_snapshot",
    );
  } catch (error) {
    throw normalizeDesktopError("desktop_summary_snapshot", error);
  }
}

export async function getDesktopRunExplain(runId: string) {
  try {
    return await desktopCommandTransport.request<DesktopExplainPayload>(
      "desktop_run_explain",
      { runId },
    );
  } catch (error) {
    throw normalizeDesktopError(`desktop_run_explain(${runId})`, error);
  }
}
