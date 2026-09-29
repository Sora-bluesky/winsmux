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

export async function closeWorkspaceSession(): Promise<Response> {
  const response = await invoke<Response>("workspace_session_close");
  if (response.accepted) currentInstance = null;
  return response;
}

export async function forceExitUncertainWorkspace(): Promise<void> {
  await invoke("workspace_force_exit");
}
