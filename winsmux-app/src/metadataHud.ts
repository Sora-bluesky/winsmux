export interface MetadataHudSources {
  cost?: string;
  heartbeat?: string;
  tokensRemaining?: string;
  branch?: string;
  headSha?: string;
  worktree?: string;
  previewUrl?: string;
  cpuPercent?: number;
  memoryMb?: number;
}

export interface MetadataHudChip {
  id: "cost" | "heartbeat" | "context" | "branch" | "head" | "worktree" | "preview" | "cpu" | "memory";
  label: string;
  value: string;
}

function presentText(value: string | undefined | null): string | null {
  if (typeof value !== "string") {
    return null;
  }
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

function presentFiniteNumber(value: number | undefined): string | null {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return null;
  }
  return String(value);
}

export function truncateSha(sha: string | undefined | null): string | null {
  const trimmed = presentText(sha);
  if (!trimmed || trimmed.length < 8) {
    return null;
  }
  return trimmed.slice(0, 8);
}

export function hudChipsFromSources(input: MetadataHudSources = {}): MetadataHudChip[] {
  const chips: MetadataHudChip[] = [];
  const cost = presentText(input.cost);
  if (cost) {
    chips.push({ id: "cost", label: "cost", value: cost });
  }
  const heartbeat = presentText(input.heartbeat);
  if (heartbeat) {
    chips.push({ id: "heartbeat", label: "heartbeat", value: heartbeat });
  }
  const tokensRemaining = presentText(input.tokensRemaining);
  if (tokensRemaining) {
    chips.push({ id: "context", label: "context", value: tokensRemaining });
  }
  const branch = presentText(input.branch);
  if (branch) {
    chips.push({ id: "branch", label: "branch", value: branch });
  }
  const head = truncateSha(input.headSha);
  if (head) {
    chips.push({ id: "head", label: "head", value: head });
  }
  const worktree = presentText(input.worktree);
  if (worktree) {
    chips.push({ id: "worktree", label: "worktree", value: worktree });
  }
  const previewUrl = presentText(input.previewUrl);
  if (previewUrl) {
    chips.push({ id: "preview", label: "preview", value: previewUrl });
  }
  const cpu = presentFiniteNumber(input.cpuPercent);
  if (cpu !== null) {
    chips.push({ id: "cpu", label: "cpu", value: cpu });
  }
  const memory = presentFiniteNumber(input.memoryMb);
  if (memory !== null) {
    chips.push({ id: "memory", label: "memory", value: memory });
  }
  return chips;
}
