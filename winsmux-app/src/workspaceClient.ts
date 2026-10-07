import { invoke } from "@tauri-apps/api/core";
import type { InstanceId, Request, Response, Version } from "./generated/workspace-contract";

export interface WorkspaceSession {
  instance_id: InstanceId;
  schema_version: Version;
}
export interface WorkspaceDiscovery extends WorkspaceSession { pipe_name: string }
export interface WorkspaceHostStatus {
  instance_id: InstanceId | null;
  generation: string;
  revision: string;
  phase: 'Empty' | 'Opening' | 'Ready' | 'Busy' | 'Stopping' | 'Unknown' | 'ForcePrompt'
    | 'Finishing' | 'FailedClosed' | 'MainClosed' | 'ExitReleased';
}

export async function getWorkspaceHostStatus(): Promise<WorkspaceHostStatus> {
  return invoke<WorkspaceHostStatus>('workspace_host_status');
}

// This is only a view of the Rust host generation, never a second workspace state.
let currentInstance: InstanceId | null = null;

export async function openWorkspaceSession(): Promise<WorkspaceSession> {
  const session = await invoke<WorkspaceSession>("workspace_session_open");
  currentInstance = session.instance_id;
  return session;
}

export async function workspaceRequest(request: Request): Promise<Response> {
  if (!currentInstance || request.instance_id !== currentInstance) {
    throw new Error("protocol_failed");
  }
  const response = await invoke<Response>("workspace_request", {
    requestJson: JSON.stringify(request),
  });
  if (request.operation === "host.stop" && response.accepted) {
    currentInstance = null;
  }
  return response;
}
export async function getWorkspaceDiscovery(instanceId: InstanceId): Promise<WorkspaceDiscovery> {
  if (!currentInstance || currentInstance !== instanceId) throw new Error('protocol_failed');
  const discovery = await invoke<WorkspaceDiscovery>('workspace_discovery_get');
  if (discovery.instance_id !== currentInstance || discovery.schema_version !== 1 || typeof discovery.pipe_name !== 'string'
    || !discovery.pipe_name.startsWith('\\\\.\\pipe\\winsmux-workspace-v1-')) throw new Error('protocol_failed');
  return discovery;
}

function exactDiscovery(value: unknown, expected: WorkspaceDiscovery): value is WorkspaceDiscovery {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const actual = value as Record<string, unknown>;
  return Object.keys(actual).length === 3 && actual.instance_id === expected.instance_id
    && actual.pipe_name === expected.pipe_name && actual.schema_version === expected.schema_version;
}

// The native command validates the live owner and writes its own three-field projection.
// A successful receipt is tied to this mount's owner generation, not browser focus.
export async function copyWorkspaceDiscovery(ownerGeneration: string, discovery: WorkspaceDiscovery): Promise<WorkspaceDiscovery> {
  if (!currentInstance || discovery.instance_id !== currentInstance || !/^[1-9][0-9]*$/.test(ownerGeneration)) {
    throw new Error('世代が変わりました。');
  }
  let result: unknown;
  try {
    result = await invoke('workspace_discovery_copy', { requestJson: JSON.stringify({
      owner_generation: ownerGeneration,
      discovery: { instance_id: discovery.instance_id, pipe_name: discovery.pipe_name, schema_version: discovery.schema_version },
    }) });
  } catch (error) {
    if (error === 'clipboard_unavailable' || error === 'clipboard_write_failed') {
      throw new Error('クリップボードへコピーできませんでした。もう一度お試しください。');
    }
    throw new Error('現在の接続情報をコピーできませんでした。接続状態を確認してください。');
  }
  const receipt = result as { owner_generation?: unknown; discovery?: unknown } | null;
  if (!receipt || typeof receipt !== 'object' || Array.isArray(receipt) || Object.keys(receipt).length !== 2
    || receipt.owner_generation !== ownerGeneration || currentInstance !== discovery.instance_id
    || !exactDiscovery(receipt.discovery, discovery)) throw new Error('世代が変わりました。');
  return receipt.discovery;
}

export async function closeWorkspaceSession(): Promise<Response> {
  const response = await invoke<Response>("workspace_session_close");
  if (response.accepted) currentInstance = null;
  return response;
}

export async function forceExitUncertainWorkspace(): Promise<void> {
  await invoke("workspace_force_exit");
}
