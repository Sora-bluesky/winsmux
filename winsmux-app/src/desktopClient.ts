import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

type DesktopCommandName =
  | "desktop_summary_snapshot"
  | "desktop_run_explain"
  | "desktop_editor_read";
type DesktopJsonRpcMethod =
  | "desktop.summary.snapshot"
  | "desktop.run.explain"
  | "desktop.editor.read";

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
  by_state: Record<string, number>;
  by_review: Record<string, number>;
  by_task_state: Record<string, number>;
}

export interface DesktopBoardPane {
  label: string;
  pane_id: string;
  role: string;
  state: string;
  task: string;
  task_state: string;
  review_state: string;
  branch: string;
  worktree: string;
  head_sha: string;
  changed_file_count: number;
  last_event_at: string;
}

export interface DesktopInboxSummary {
  item_count: number;
  by_kind: Record<string, number>;
}

export interface DesktopInboxItem {
  kind: string;
  priority: number;
  message: string;
  label: string;
  pane_id: string;
  role: string;
  task_id: string;
  task: string;
  task_state: string;
  review_state: string;
  branch: string;
  head_sha: string;
  changed_file_count: number;
  event: string;
  timestamp: string;
  source: string;
}

export interface DesktopDigestSummary {
  item_count: number;
  dirty_items: number;
  actionable_items: number;
  review_pending: number;
  review_failed: number;
}

export interface DesktopDigestItem {
  run_id: string;
  task_id: string;
  task: string;
  label: string;
  pane_id: string;
  role: string;
  provider_target: string;
  task_state: string;
  review_state: string;
  next_action: string;
  branch: string;
  worktree: string;
  head_sha: string;
  head_short: string;
  changed_file_count: number;
  changed_files: string[];
  action_item_count: number;
  last_event: string;
  verification_outcome: string;
  security_blocked: string;
  hypothesis: string;
  confidence: number | null;
  observation_pack_ref: string;
  consultation_ref: string;
  last_event_at: string;
}

export interface DesktopRunProjection {
  run_id: string;
  pane_id: string;
  label: string;
  branch: string;
  worktree: string;
  head_sha: string;
  head_short: string;
  provider_target: string;
  task: string;
  task_state: string;
  review_state: string;
  verification_outcome: string;
  security_blocked: string;
  changed_files: string[];
  next_action: string;
  summary: string;
  reasons: string[];
  hypothesis: string;
  confidence: number | null;
  observation_pack_ref: string;
  consultation_ref: string;
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
  generated_at: string;
  project_dir: string;
  run: {
    run_id: string;
    task: string;
    state: string;
    task_state: string;
    review_state: string;
    provider_target: string;
    agent_role: string;
    branch: string;
    head_sha: string;
    worktree: string;
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
    verification_outcome: string;
    security_blocked: string;
  };
  review_state?: DesktopReviewStateRecord | null;
  recent_events: Array<{
    timestamp: string;
    event: string;
    label: string;
    message: string;
  }>;
}

export interface DesktopReviewStateRecord {
  status: string;
  branch: string;
  head_sha: string;
  request: DesktopReviewStateRequest;
  reviewer: DesktopReviewStateReviewer;
  updatedAt: string;
  evidence?: DesktopReviewStateEvidence | null;
}

export interface DesktopReviewStateRequest {
  id?: string | null;
  branch: string;
  head_sha: string;
  target_review_pane_id: string;
  target_review_label: string;
  target_review_role: string;
  target_reviewer_pane_id?: string | null;
  target_reviewer_label?: string | null;
  target_reviewer_role?: string | null;
  review_contract: DesktopReviewContract;
  dispatched_at?: string | null;
}

export interface DesktopReviewStateReviewer {
  pane_id: string;
  label: string;
  role: string;
  agent_name?: string | null;
}

export interface DesktopReviewStateEvidence {
  approved_at?: string | null;
  approved_via?: string | null;
  failed_at?: string | null;
  failed_via?: string | null;
  review_contract_snapshot: DesktopReviewContract;
}

export interface DesktopReviewContract {
  version: number;
  source_task: string;
  issue_ref: string;
  style: string;
  required_scope: string[];
  checklist_labels: string[];
  rationale: string;
}

export interface DesktopEditorFilePayload {
  path: string;
  content: string;
  line_count: number;
  truncated: boolean;
}

export interface DesktopSummaryRefreshEvent {
  source?: string;
  reason?: string;
  pane_id?: string;
  run_id?: string;
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
    case "desktop_editor_read":
      return "desktop.editor.read";
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

export async function getDesktopEditorFile(path: string, worktree?: string) {
  try {
    return await desktopCommandTransport.request<DesktopEditorFilePayload>(
      "desktop_editor_read",
      worktree ? { path, worktree } : { path },
    );
  } catch (error) {
    const worktreeSuffix = worktree ? `, ${worktree}` : "";
    throw normalizeDesktopError(`desktop_editor_read(${path}${worktreeSuffix})`, error);
  }
}

export async function subscribeToDesktopSummaryRefresh(
  onRefresh: (event: DesktopSummaryRefreshEvent) => void,
): Promise<UnlistenFn> {
  return listen<DesktopSummaryRefreshEvent | string>(
    "desktop-summary-refresh",
    (event) => {
      if (typeof event.payload === "string") {
        try {
          onRefresh(JSON.parse(event.payload) as DesktopSummaryRefreshEvent);
          return;
        } catch {
          onRefresh({});
          return;
        }
      }

      onRefresh(event.payload ?? {});
    },
  );
}
