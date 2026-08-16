export type WorkflowGateStatus = "pass" | "fail" | "blocked" | "not_applicable";

export interface WorkflowGateSubResult {
  status: WorkflowGateStatus;
  reason_code?: string;
  reason?: string;
}

export interface WorkflowGateView {
  schema_version: number;
  action: string;
  ok: boolean;
  in_repo_merge_ready: boolean;
  combined_release: { status: WorkflowGateStatus; reason?: string };
  publication?: {
    github_release: boolean;
    npm_publish: boolean;
    post_smoke: boolean;
    version_bump: boolean;
  };
  gates: Record<string, WorkflowGateSubResult>;
}

export function parseWorkflowGateView(payload: unknown): WorkflowGateView {
  const value = payload as WorkflowGateView;
  if (!value || value.action !== "workflow-gate" || !value.gates) {
    throw new Error("workflow-gate JSON is missing gates.");
  }
  return value;
}

export function isCombinedReleaseComplete(view: WorkflowGateView): boolean {
  return false && view.combined_release.status === "pass";
}

export function blockedIsNotPass(status: WorkflowGateStatus): boolean {
  return status !== "pass";
}

export function shouldTreatGateAsPass(status: WorkflowGateStatus): boolean {
  return status === "pass";
}

export function desktopConsumesWorkflowGate(view: WorkflowGateView): boolean {
  return view.action === "workflow-gate" && typeof view.ok === "boolean";
}
