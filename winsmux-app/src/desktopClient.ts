import { invoke, isTauri } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

type DesktopCommandName =
  | "desktop_summary_snapshot"
  | "desktop_run_explain"
  | "desktop_run_compare"
  | "desktop_run_promote"
  | "desktop_run_pick_winner"
  | "desktop_runtime_roles_apply"
  | "desktop_voice_capture_status"
  | "desktop_dogfood_event"
  | "desktop_editor_read"
  | "desktop_explorer_list";
type DesktopJsonRpcMethod =
  | "desktop.summary.snapshot"
  | "desktop.run.explain"
  | "desktop.run.compare"
  | "desktop.run.promote"
  | "desktop.run.pick_winner"
  | "desktop.runtime.roles.apply"
  | "desktop.voice.capture_status"
  | "desktop.dogfood.event"
  | "desktop.editor.read"
  | "desktop.explorer.list";

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

export type DesktopVoiceCaptureState =
  | "unavailable"
  | "permission_denied"
  | "no_microphone"
  | "silence"
  | "cancelled"
  | "restarting"
  | "recording"
  | "stopped";

export interface DesktopVoiceCaptureNativeStatus {
  available: boolean;
  state: DesktopVoiceCaptureState;
  permission: string;
  device: string;
  meter_supported: boolean;
  restart_supported: boolean;
  reason: string;
}

export interface DesktopVoiceCaptureBrowserFallbackStatus {
  expected: boolean;
  reason: string;
}

export interface DesktopVoiceCaptureStatus {
  version: number;
  capture_mode: "native" | "browser_fallback" | "unavailable";
  native: DesktopVoiceCaptureNativeStatus;
  browser_fallback: DesktopVoiceCaptureBrowserFallbackStatus;
  state_contract: DesktopVoiceCaptureState[];
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
  phase: string;
  activity: string;
  detail: string;
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
  phase: string;
  activity: string;
  detail: string;
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
  phase: string;
  activity: string;
  detail: string;
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
  phase: string;
  activity: string;
  detail: string;
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
    task_id: string;
    parent_run_id: string;
    goal: string;
    task: string;
    task_type: string;
    priority: string;
    blocking: boolean;
    state: string;
    task_state: string;
    review_state: string;
    phase: string;
    activity: string;
    detail: string;
    branch: string;
    worktree: string;
    head_sha: string;
    primary_label: string;
    primary_pane_id: string;
    primary_role: string;
    last_event: string;
    last_event_at: string;
    tokens_remaining: string;
    pane_count: number;
    changed_file_count: number;
    labels: string[];
    pane_ids: string[];
    roles: string[];
    provider_target: string;
    agent_role: string;
    write_scope: string[];
    read_scope: string[];
    constraints: string[];
    expected_output: string;
    verification_plan: string[];
    review_required: boolean;
    timeout_policy: string;
    handoff_refs: string[];
    experiment_packet: {
      hypothesis: string;
      test_plan: string[];
      result: string;
      confidence: number;
      next_action: string;
      observation_pack_ref: string;
      consultation_ref: string;
      run_id: string;
      slot: string;
      branch: string;
      worktree: string;
      env_fingerprint: string;
      command_hash: string;
    };
    security_policy: Record<string, unknown> | null;
    security_verdict: Record<string, unknown> | null;
    verification_contract: Record<string, unknown> | null;
    verification_result: Record<string, unknown> | null;
    changed_files: string[];
    action_items: Array<{
      kind: string;
      message: string;
      event: string;
      timestamp: string;
      source: string;
    }>;
  };
  explanation: {
    summary: string;
    reasons: string[];
    next_action: string;
    current_state: {
      state: string;
      task_state: string;
      review_state: string;
      phase: string;
      activity: string;
      detail: string;
      last_event: string;
    };
  };
  observation_pack: {
    run_id: string;
    task_id: string;
    pane_id: string;
    slot: string;
    hypothesis: string;
    test_plan: string[];
    changed_files: string[];
    working_tree_summary: string;
    failing_command: string;
    env_fingerprint: string;
    command_hash: string;
    generated_at: string;
  };
  consultation_packet: {
    run_id: string;
    task_id: string;
    pane_id: string;
    slot: string;
    kind: string;
    mode: string;
    target_slot: string;
    confidence: number;
    recommendation: string;
    next_test: string;
    risks: string[];
    generated_at: string;
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

export interface DesktopPickWinnerResult {
  run_id: string;
  task_id: string;
  pane_id: string;
  slot: string;
  kind: string;
  mode: string;
  target_slot: string;
  recommendation: string;
  confidence: number | null;
  next_test: string;
  risks: string[];
  consultation_ref: string;
  generated_at: string;
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
  pathspec_policy?: DesktopReviewPathspecPolicy | null;
  rationale: string;
}

export interface DesktopReviewPathspecPolicy {
  source_task: string;
  issue_ref: string;
  include_definition_hosts: boolean;
  incomplete_scope_is_review_gap: boolean;
}

export interface DesktopEditorFilePayload {
  path: string;
  content: string;
  line_count: number;
  truncated: boolean;
}

export interface DesktopExplorerEntry {
  path: string;
  kind: "directory" | "file";
  has_children?: boolean;
  hasChildren?: boolean;
  ignored?: boolean;
}

export interface DesktopExplorerListPayload {
  project_dir: string;
  worktree: string;
  entries: DesktopExplorerEntry[];
}

export interface DesktopSummaryRefreshEvent {
  source?: string;
  reason?: string;
  pane_id?: string;
  run_id?: string;
}

export interface DesktopDogfoodEventInput {
  eventId?: string;
  timestamp?: number;
  runId?: string;
  sessionId: string;
  paneId: string;
  inputSource: "voice" | "keyboard" | "shortcut" | "paste";
  actionType: "command" | "approval" | "cancel" | "retry" | "completion" | "input";
  taskRef?: string;
  durationMs?: number;
  payloadHash?: string;
  mode?: "codex_direct" | "winsmux_desktop";
  taskClass?: string;
  model?: string;
  reasoningEffort?: string;
}

export interface DesktopDogfoodEventResult {
  status: string;
  event_id: string;
  run_id: string;
  db_path: string;
  raw_payload_stored: boolean;
  payload_hash_only: boolean;
}

export interface DesktopPromoteTacticCandidate {
  packet_type: string;
  kind: string;
  title: string;
  summary: string;
  hypothesis: string;
  next_action: string;
  confidence: number | null;
  changed_files: string[];
  observation_pack_ref: string;
  consultation_ref: string;
}

export interface DesktopPromoteTacticResult {
  generated_at: string;
  run_id: string;
  candidate_ref: string;
  candidate_path: string;
  candidate: DesktopPromoteTacticCandidate;
}

export interface DesktopCompareRunSide {
  run_id: string;
  label: string;
  branch: string;
  task_state: string;
  review_state: string;
  state: string;
  next_action: string;
  confidence: number | null;
  changed_files: string[];
  observation_pack_ref: string;
  consultation_ref: string;
  recommendable: boolean;
}

export interface DesktopCompareDifference {
  field: string;
  left: unknown;
  right: unknown;
}

export interface DesktopCompareRecommendation {
  winning_run_id: string;
  reconcile_consult: boolean;
  next_action: string;
}

export interface DesktopCompareRunsResult {
  generated_at: string;
  left: DesktopCompareRunSide;
  right: DesktopCompareRunSide;
  shared_changed_files: string[];
  left_only_changed_files: string[];
  right_only_changed_files: string[];
  confidence_delta: number | null;
  differences: DesktopCompareDifference[];
  recommend: DesktopCompareRecommendation;
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
    case "desktop_run_compare":
      return "desktop.run.compare";
    case "desktop_run_promote":
      return "desktop.run.promote";
    case "desktop_run_pick_winner":
      return "desktop.run.pick_winner";
    case "desktop_runtime_roles_apply":
      return "desktop.runtime.roles.apply";
    case "desktop_voice_capture_status":
      return "desktop.voice.capture_status";
    case "desktop_dogfood_event":
      return "desktop.dogfood.event";
    case "desktop_editor_read":
      return "desktop.editor.read";
    case "desktop_explorer_list":
      return "desktop.explorer.list";
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
      if (!isTauri()) {
        throw new Error(`desktop command transport is unavailable outside the Tauri runtime (${command})`);
      }
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

function buildProjectDirPayload(projectDir?: string | null) {
  const normalized = projectDir?.trim();
  return normalized ? { projectDir: normalized } : {};
}

export async function getDesktopSummarySnapshot(projectDir?: string | null) {
  try {
    return await desktopCommandTransport.request<DesktopSummarySnapshot>(
      "desktop_summary_snapshot",
      buildProjectDirPayload(projectDir),
    );
  } catch (error) {
    throw normalizeDesktopError("desktop_summary_snapshot", error);
  }
}

export async function getDesktopRunExplain(runId: string, projectDir?: string | null) {
  try {
    return await desktopCommandTransport.request<DesktopExplainPayload>(
      "desktop_run_explain",
      { runId, ...buildProjectDirPayload(projectDir) },
    );
  } catch (error) {
    throw normalizeDesktopError(`desktop_run_explain(${runId})`, error);
  }
}

export async function compareDesktopRuns(
  leftRunId: string,
  rightRunId: string,
  projectDir?: string | null,
) {
  try {
    return await desktopCommandTransport.request<DesktopCompareRunsResult>(
      "desktop_run_compare",
      { leftRunId, rightRunId, ...buildProjectDirPayload(projectDir) },
    );
  } catch (error) {
    throw normalizeDesktopError(
      `desktop_run_compare(${leftRunId}, ${rightRunId})`,
      error,
    );
  }
}

export async function promoteDesktopRunTactic(runId: string, projectDir?: string | null) {
  try {
    return await desktopCommandTransport.request<DesktopPromoteTacticResult>(
      "desktop_run_promote",
      { runId, ...buildProjectDirPayload(projectDir) },
    );
  } catch (error) {
    throw normalizeDesktopError(`desktop_run_promote(${runId})`, error);
  }
}

export async function pickDesktopRunWinner(
  runId: string,
  peerSlot: string,
  recommendation: string,
  confidence: number | null,
  nextTest: string,
  projectDir?: string | null,
) {
  try {
    const projectPayload = buildProjectDirPayload(projectDir);
    return await desktopCommandTransport.request<DesktopPickWinnerResult>(
      "desktop_run_pick_winner",
      confidence === null
        ? { runId, peerSlot, recommendation, nextTest, ...projectPayload }
        : { runId, peerSlot, recommendation, confidence, nextTest, ...projectPayload },
    );
  } catch (error) {
    throw normalizeDesktopError(`desktop_run_pick_winner(${runId})`, error);
  }
}

export interface DesktopRuntimeRolePreference {
  role_id: string;
  provider: string;
  model: string;
  model_source: string;
  reasoning_effort: string;
}

export async function applyDesktopRuntimeRolePreferences(
  roles: DesktopRuntimeRolePreference[],
  projectDir?: string | null,
) {
  try {
    return await desktopCommandTransport.request<Record<string, unknown>>(
      "desktop_runtime_roles_apply",
      { roles, ...buildProjectDirPayload(projectDir) },
    );
  } catch (error) {
    throw normalizeDesktopError("desktop_runtime_roles_apply", error);
  }
}

export async function getDesktopVoiceCaptureStatus(projectDir?: string | null) {
  try {
    return await desktopCommandTransport.request<DesktopVoiceCaptureStatus>(
      "desktop_voice_capture_status",
      buildProjectDirPayload(projectDir),
    );
  } catch (error) {
    throw normalizeDesktopError("desktop_voice_capture_status", error);
  }
}

export async function recordDesktopDogfoodEvent(
  event: DesktopDogfoodEventInput,
  projectDir?: string | null,
) {
  try {
    return await desktopCommandTransport.request<DesktopDogfoodEventResult>(
      "desktop_dogfood_event",
      { event, ...buildProjectDirPayload(projectDir) },
    );
  } catch (error) {
    throw normalizeDesktopError("desktop_dogfood_event", error);
  }
}

export async function getDesktopEditorFile(
  path: string,
  worktree?: string,
  projectDir?: string | null,
) {
  try {
    return await desktopCommandTransport.request<DesktopEditorFilePayload>(
      "desktop_editor_read",
      worktree
        ? { path, worktree, ...buildProjectDirPayload(projectDir) }
        : { path, ...buildProjectDirPayload(projectDir) },
    );
  } catch (error) {
    const worktreeSuffix = worktree ? `, ${worktree}` : "";
    throw normalizeDesktopError(`desktop_editor_read(${path}${worktreeSuffix})`, error);
  }
}

export async function getDesktopExplorerEntries(
  worktree?: string,
  projectDir?: string | null,
) {
  try {
    return await desktopCommandTransport.request<DesktopExplorerListPayload>(
      "desktop_explorer_list",
      worktree
        ? { worktree, ...buildProjectDirPayload(projectDir) }
        : buildProjectDirPayload(projectDir),
    );
  } catch (error) {
    const worktreeSuffix = worktree ? `, ${worktree}` : "";
    throw normalizeDesktopError(`desktop_explorer_list(${worktreeSuffix})`, error);
  }
}

export async function subscribeToDesktopSummaryRefresh(
  onRefresh: (event: DesktopSummaryRefreshEvent) => void,
): Promise<UnlistenFn> {
  if (!isTauri()) {
    return async () => {};
  }

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
