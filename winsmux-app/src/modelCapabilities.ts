export const providerCapabilityIds = [
  "provider-default",
  "codex",
  "claude",
  "antigravity",
  "grok-build",
  "openrouter",
] as const;
export type ProviderCapabilityId = typeof providerCapabilityIds[number];

export const modelSourceIds = [
  "provider-default",
  "cli-discovery",
  "provider-api",
  "official-doc",
  "operator-override",
] as const;
export type ModelSource = typeof modelSourceIds[number];

export const effortCapabilityIds = [
  "provider-default",
  "low",
  "medium",
  "high",
  "max",
  "xhigh",
] as const;
export type EffortCapabilityId = typeof effortCapabilityIds[number];

export const backendCapabilityIds = [
  "any",
  "agent-cli",
  "antigravity",
  "api_llm",
  "colab_cli",
] as const;
export type BackendCapabilityId = typeof backendCapabilityIds[number];

export const transportCapabilityIds = ["argv", "file", "stdin"] as const;
export type TransportCapabilityId = typeof transportCapabilityIds[number];

export const modelReadinessStates = [
  "selectable",
  "candidate",
  "setup-required",
  "runnable",
  "blocked",
  "reference-only",
  "unavailable",
] as const;
export type ReadinessState = typeof modelReadinessStates[number];

export const runtimeWorkerReadinessStates = ["runnable", "setup-required", "blocked"] as const;
export type RuntimeWorkerReadinessState = typeof runtimeWorkerReadinessStates[number];

export const workerPaneReadinessStates = ["ready", "blocked", "pending"] as const;
export type WorkerPaneReadinessState = typeof workerPaneReadinessStates[number];

export const agentVaultCommandProviderIds = ["claude", "codex", "opencode"] as const;
export type AgentVaultCommandProviderId = typeof agentVaultCommandProviderIds[number];

export const benchmarkFamilies = ["agent-arena", "code-arena", "winsmux-local"] as const;
export type BenchmarkFamily = typeof benchmarkFamilies[number];

export const commonContractSurfaceIds = [
  "provider",
  "readiness",
  "manifest",
  "route",
  "capsule",
  "mailbox",
  "settings",
] as const;
export type CommonContractSurfaceId = typeof commonContractSurfaceIds[number];

export interface Readiness {
  state: ReadinessState;
  assignable: boolean;
  availability: string;
  availabilityJa?: string;
  requiredEnv?: string;
}

export interface EvidenceRecord {
  id: string;
  kind: ModelSource | "provider-registry" | "desktop-model-picker";
  label: string;
  sourceLabel?: string;
  captureDate?: string;
  localRunId?: string;
  confidenceNote?: string;
  confidenceNoteJa?: string;
}

export interface EffortCapability {
  id: EffortCapabilityId;
  label: string;
  labelJa: string;
  providerLabels?: Partial<Record<ProviderCapabilityId, string>>;
  providerLabelsJa?: Partial<Record<ProviderCapabilityId, string>>;
  description?: string;
  descriptionJa?: string;
}

export interface BackendCapability {
  id: BackendCapabilityId;
  label: string;
  labelJa: string;
  assignableBackends: readonly string[];
}

export interface TransportCapability {
  id: TransportCapabilityId;
  label: string;
  labelJa: string;
}

export interface ProviderCapability {
  id: ProviderCapabilityId;
  label: string;
  labelJa: string;
  commandName?: string;
  defaultModelId: string;
  defaultEffortId: EffortCapabilityId;
  supportedEffortIds: readonly EffortCapabilityId[];
  supportedModelSources: readonly ModelSource[];
  supportedTransportIds: readonly TransportCapabilityId[];
  requiredBackend: BackendCapabilityId;
  authMode: string;
  dynamicModelLoading?: {
    source: ModelSource;
    url?: string;
    seedModelIds: readonly string[];
  };
  readiness: Readiness;
}

export interface ModelCapability {
  id: string;
  providerId: ProviderCapabilityId;
  label: string;
  labelJa: string;
  model: string;
  modelSource: ModelSource;
  defaultEffortId: EffortCapabilityId;
  supportedEffortIds?: readonly EffortCapabilityId[];
  promptTransport: TransportCapabilityId;
  authMode: string;
  requiredEnv?: string;
  requiredBackend: BackendCapabilityId;
  readiness: Readiness;
  family: BenchmarkFamily;
  speed: string;
  intelligence: string;
  cost: string;
  risk: string;
  benchmark: string;
  evidenceIds: readonly string[];
  note: string;
  noteJa: string;
  group?: "primary" | "other" | "seed" | "dynamic" | "reference";
}

export interface NormalizedRuntimeCatalogEntry {
  id: string;
  label: string;
  labelJa: string;
  agent: ProviderCapabilityId;
  providerId: ProviderCapabilityId;
  model: string;
  modelSource: ModelSource;
  reasoningEffort: EffortCapabilityId;
  supportedReasoningEfforts?: readonly EffortCapabilityId[];
  promptTransport: TransportCapabilityId;
  authMode: string;
  requiredEnv?: string;
  requiredBackend: BackendCapabilityId;
  status: ReadinessState;
  family: BenchmarkFamily;
  speed: string;
  intelligence: string;
  cost: string;
  risk: string;
  availability: string;
  benchmark: string;
  evidence: string;
  sourceLabel?: string;
  captureDate?: string;
  localRunId?: string;
  confidenceNote?: string;
  confidenceNoteJa?: string;
  note: string;
  noteJa: string;
}

export interface CapabilityRegistry {
  providers: readonly ProviderCapability[];
  models: readonly ModelCapability[];
  efforts: readonly EffortCapability[];
  backends: readonly BackendCapability[];
  transports: readonly TransportCapability[];
  evidence: readonly EvidenceRecord[];
}

export interface CapabilityValidationIssue {
  code: "duplicate-id" | "unsupported-default-effort" | "invalid-required-backend";
  scope: "provider" | "model" | "effort" | "backend" | "transport" | "evidence";
  id: string;
  message: string;
}

export const openRouterModelsApiUrl = "https://openrouter.ai/api/v1/models";

export const commonContractPackageVersion = "0.36.26";

export const commonContractPackage = {
  version: commonContractPackageVersion,
  surfaces: commonContractSurfaceIds,
  vocabularies: {
    runtimeProviderIds: {
      owner: "winsmux-app/src/modelCapabilities.ts",
      values: providerCapabilityIds,
    },
    modelSources: {
      owner: "winsmux-app/src/modelCapabilities.ts",
      values: modelSourceIds,
    },
    reasoningEfforts: {
      owner: "winsmux-app/src/modelCapabilities.ts",
      values: effortCapabilityIds,
    },
    backendCapabilities: {
      owner: "winsmux-app/src/modelCapabilities.ts",
      values: backendCapabilityIds,
      note: "Capability categories, not concrete worker_backend values.",
    },
    promptTransports: {
      owner: "winsmux-app/src/modelCapabilities.ts",
      values: transportCapabilityIds,
    },
    modelReadiness: {
      owner: "winsmux-app/src/modelCapabilities.ts",
      values: modelReadinessStates,
      note: "Model availability vocabulary. Do not merge with worker pane readiness.",
    },
    runtimeWorkerReadiness: {
      owner: "winsmux-app/src/main.ts",
      values: runtimeWorkerReadinessStates,
      note: "Startability summary derived from model availability plus credential/backend state.",
    },
    workerPaneReadiness: {
      owner: "winsmux-app/src/main.ts",
      values: workerPaneReadinessStates,
      note: "Pane idle-state vocabulary. Do not merge with model availability.",
    },
    agentVaultCommandProviders: {
      owner: "winsmux-app/src/main.ts",
      values: agentVaultCommandProviderIds,
      note: "Command-provider vocabulary kept separate from runtime provider IDs.",
    },
    benchmarkFamilies: {
      owner: "winsmux-app/src/modelCapabilities.ts",
      values: benchmarkFamilies,
    },
  },
} as const;

export const effortCapabilities: readonly EffortCapability[] = [
  { id: "provider-default", label: "Auto", labelJa: "自動" },
  { id: "low", label: "Low", labelJa: "低" },
  { id: "medium", label: "Medium", labelJa: "中" },
  { id: "high", label: "High", labelJa: "高" },
  { id: "max", label: "Max", labelJa: "最大", providerLabels: { claude: "Max" } },
  {
    id: "xhigh",
    label: "X High",
    labelJa: "非常に高い",
    providerLabels: { claude: "Ultra" },
    providerLabelsJa: { claude: "Ultra" },
  },
];

export const backendCapabilities: readonly BackendCapability[] = [
  { id: "any", label: "Any", labelJa: "任意", assignableBackends: ["*"] },
  { id: "agent-cli", label: "Agent CLI", labelJa: "エージェント CLI", assignableBackends: ["", "local", "codex", "claude"] },
  { id: "antigravity", label: "Antigravity", labelJa: "Antigravity", assignableBackends: ["antigravity"] },
  { id: "api_llm", label: "OpenAI-compatible API", labelJa: "OpenAI 互換 API", assignableBackends: ["api_llm"] },
  { id: "colab_cli", label: "Colab CLI", labelJa: "Colab CLI", assignableBackends: ["colab_cli"] },
];

export const transportCapabilities: readonly TransportCapability[] = [
  { id: "argv", label: "argv", labelJa: "argv" },
  { id: "file", label: "File", labelJa: "ファイル" },
  { id: "stdin", label: "stdin", labelJa: "stdin" },
];

export const evidenceRecords: readonly EvidenceRecord[] = [
  { id: "provider-registry", kind: "provider-registry", label: "Provider registry" },
  { id: "cli-discovery", kind: "cli-discovery", label: "Local CLI discovery" },
  { id: "official-doc", kind: "official-doc", label: "Official docs" },
  { id: "operator-override", kind: "operator-override", label: "Operator override" },
  { id: "provider-api", kind: "provider-api", label: "Provider API" },
  { id: "desktop-model-picker", kind: "desktop-model-picker", label: "Desktop model picker" },
  { id: "openrouter-model-page-kimi", kind: "official-doc", label: "OpenRouter model page + official model weights", captureDate: "2026-06-20" },
];

export const providerCapabilities: readonly ProviderCapability[] = [
  {
    id: "provider-default",
    label: "Provider default",
    labelJa: "プロバイダー既定",
    defaultModelId: "provider-default",
    defaultEffortId: "provider-default",
    supportedEffortIds: ["provider-default"],
    supportedModelSources: ["provider-default"],
    supportedTransportIds: ["file"],
    requiredBackend: "any",
    authMode: "provider-default",
    readiness: {
      state: "selectable",
      assignable: true,
      availability: "Uses the configured slot provider.",
    },
  },
  {
    id: "codex",
    label: "Codex",
    labelJa: "Codex",
    commandName: "codex",
    defaultModelId: "codex-gpt-5-5",
    defaultEffortId: "medium",
    supportedEffortIds: ["provider-default", "low", "medium", "high", "xhigh"],
    supportedModelSources: ["cli-discovery", "operator-override"],
    supportedTransportIds: ["file"],
    requiredBackend: "agent-cli",
    authMode: "codex-chatgpt-local",
    readiness: {
      state: "selectable",
      assignable: true,
      availability: "Requires local Codex CLI model access.",
    },
  },
  {
    id: "claude",
    label: "Claude Code",
    labelJa: "Claude Code",
    commandName: "claude",
    defaultModelId: "claude-opus-4-8",
    defaultEffortId: "high",
    supportedEffortIds: ["provider-default", "low", "medium", "high", "max", "xhigh"],
    supportedModelSources: ["official-doc", "operator-override"],
    supportedTransportIds: ["file"],
    requiredBackend: "agent-cli",
    authMode: "claude-pro-max-oauth",
    readiness: {
      state: "selectable",
      assignable: true,
      availability: "Requires local Claude Code access.",
    },
  },
  {
    id: "antigravity",
    label: "Antigravity",
    labelJa: "Antigravity",
    commandName: "agy",
    defaultModelId: "antigravity-gemini-3-5-flash-medium",
    defaultEffortId: "provider-default",
    supportedEffortIds: ["provider-default"],
    supportedModelSources: ["cli-discovery"],
    supportedTransportIds: ["file"],
    requiredBackend: "antigravity",
    authMode: "antigravity-official-cli",
    readiness: {
      state: "selectable",
      assignable: true,
      availability: "Shown by Antigravity CLI 1.0.10 model picker.",
    },
  },
  {
    id: "grok-build",
    label: "Grok Build",
    labelJa: "Grok Build",
    defaultModelId: "grok-build-grok-4-3",
    defaultEffortId: "provider-default",
    supportedEffortIds: ["provider-default"],
    supportedModelSources: ["cli-discovery"],
    supportedTransportIds: ["file"],
    requiredBackend: "agent-cli",
    authMode: "grok-build-local",
    readiness: {
      state: "selectable",
      assignable: true,
      availability: "Requires Grok Build headless access.",
    },
  },
  {
    id: "openrouter",
    label: "OpenRouter",
    labelJa: "OpenRouter",
    defaultModelId: "openrouter-glm-5-2",
    defaultEffortId: "provider-default",
    supportedEffortIds: ["provider-default"],
    supportedModelSources: ["operator-override", "provider-api"],
    supportedTransportIds: ["file"],
    requiredBackend: "api_llm",
    authMode: "api-key-env",
    dynamicModelLoading: {
      source: "provider-api",
      url: openRouterModelsApiUrl,
      seedModelIds: ["openrouter-sakana-fugu-ultra", "openrouter-glm-5-2", "openrouter-kimi-k2-7-code"],
    },
    readiness: {
      state: "setup-required",
      assignable: true,
      availability: "Requires OPENROUTER_API_KEY.",
      requiredEnv: "OPENROUTER_API_KEY",
    },
  },
];

export const modelCapabilities: readonly ModelCapability[] = [
  {
    id: "provider-default",
    providerId: "provider-default",
    label: "Auto / provider default",
    labelJa: "自動 / プロバイダー既定",
    model: "provider-default",
    modelSource: "provider-default",
    defaultEffortId: "provider-default",
    supportedEffortIds: ["provider-default"],
    promptTransport: "file",
    authMode: "provider-default",
    requiredBackend: "any",
    readiness: {
      state: "selectable",
      assignable: true,
      availability: "Uses the configured slot provider.",
    },
    family: "winsmux-local",
    speed: "auto",
    intelligence: "auto",
    cost: "configured",
    risk: "low",
    benchmark: "Local evidence only",
    evidenceIds: ["provider-registry"],
    note: "Clears the slot override and lets the current provider choose its default.",
    noteJa: "スロット上書きを解除し、現在のプロバイダー既定値に戻します。",
  },
  {
    id: "codex-gpt-5-5",
    providerId: "codex",
    label: "GPT-5.5",
    labelJa: "GPT-5.5",
    model: "gpt-5.5",
    modelSource: "cli-discovery",
    defaultEffortId: "medium",
    supportedEffortIds: ["low", "medium", "high", "xhigh"],
    promptTransport: "file",
    authMode: "codex-chatgpt-local",
    requiredBackend: "agent-cli",
    readiness: { state: "selectable", assignable: true, availability: "Requires local Codex CLI model access." },
    family: "agent-arena",
    speed: "frontier",
    intelligence: "high",
    cost: "account",
    risk: "local-cli",
    benchmark: "Agent Arena reference plus winsmux run evidence",
    evidenceIds: ["cli-discovery"],
    note: "Use as a strong hosted coding worker when the local Codex CLI account exposes it.",
    noteJa: "ローカル Codex CLI アカウントで利用できる場合の強いコーディング用ワーカーです。",
  },
  {
    id: "codex-gpt-5-4",
    providerId: "codex",
    label: "GPT-5.4",
    labelJa: "GPT-5.4",
    model: "gpt-5.4",
    modelSource: "cli-discovery",
    defaultEffortId: "medium",
    supportedEffortIds: ["low", "medium", "high", "xhigh"],
    promptTransport: "file",
    authMode: "codex-chatgpt-local",
    requiredBackend: "agent-cli",
    readiness: { state: "selectable", assignable: true, availability: "Accepted by local Codex CLI headless execution." },
    family: "winsmux-local",
    speed: "frontier",
    intelligence: "high",
    cost: "account",
    risk: "local-cli",
    benchmark: "winsmux local model availability evidence",
    evidenceIds: ["cli-discovery"],
    note: "Use when the local Codex CLI account exposes GPT-5.4.",
    noteJa: "ローカル Codex CLI アカウントで GPT-5.4 が利用できる場合に使います。",
  },
  {
    id: "codex-gpt-5-4-mini",
    providerId: "codex",
    label: "GPT-5.4-Mini",
    labelJa: "GPT-5.4-Mini",
    model: "gpt-5.4-mini",
    modelSource: "cli-discovery",
    defaultEffortId: "medium",
    supportedEffortIds: ["low", "medium", "high", "xhigh"],
    promptTransport: "file",
    authMode: "codex-chatgpt-local",
    requiredBackend: "agent-cli",
    readiness: { state: "selectable", assignable: true, availability: "Accepted by local Codex CLI headless execution." },
    family: "winsmux-local",
    speed: "fast",
    intelligence: "medium-high",
    cost: "account",
    risk: "local-cli",
    benchmark: "winsmux local model availability evidence",
    evidenceIds: ["cli-discovery"],
    note: "Use for lower-latency Codex worker panes.",
    noteJa: "低遅延の Codex ワーカーペインに使います。",
  },
  {
    id: "codex-spark",
    providerId: "codex",
    label: "GPT-5.3 Codex Spark",
    labelJa: "GPT-5.3 Codex Spark",
    model: "gpt-5.3-codex-spark",
    modelSource: "cli-discovery",
    defaultEffortId: "high",
    supportedEffortIds: ["low", "medium", "high", "xhigh"],
    promptTransport: "file",
    authMode: "codex-chatgpt-local",
    requiredBackend: "agent-cli",
    readiness: { state: "selectable", assignable: true, availability: "Requires local Codex CLI model access." },
    family: "winsmux-local",
    speed: "fast",
    intelligence: "medium-high",
    cost: "account",
    risk: "local-cli",
    benchmark: "winsmux local review/e2e evidence",
    evidenceIds: ["cli-discovery"],
    note: "Use for quick review, verification, and low-latency worker panes.",
    noteJa: "高速なレビュー、検証、低遅延ワーカーに向きます。",
  },
  {
    id: "claude-fable-5",
    providerId: "claude",
    label: "Fable 5",
    labelJa: "Fable 5",
    model: "claude-fable-5",
    modelSource: "official-doc",
    defaultEffortId: "high",
    supportedEffortIds: ["low", "medium", "high", "max", "xhigh"],
    promptTransport: "file",
    authMode: "claude-pro-max-oauth",
    requiredBackend: "agent-cli",
    readiness: {
      state: "selectable",
      assignable: true,
      availability: "Anthropic restored Fable 5 access on 2026-07-01 for Claude Platform, Claude.ai, Claude Code, and Claude Cowork. Pro, Max, Team, and select Enterprise included usage applies through 2026-07-07; after that, usage credits are required.",
    },
    family: "agent-arena",
    speed: "frontier",
    intelligence: "high",
    cost: "account",
    risk: "usage-credits",
    benchmark: "Agent Arena reference plus official redeployment notice",
    evidenceIds: ["official-doc"],
    note: "Selectable through Claude Code when the account exposes Fable 5. Verify subscription allowance or usage credits before long runs.",
    noteJa: "Claude Code アカウントで Fable 5 が表示される場合に選択できます。長時間実行前にサブスク枠または usage credits を確認してください。",
  },
  {
    id: "claude-opus-4-8",
    providerId: "claude",
    label: "Opus 4.8",
    labelJa: "Opus 4.8",
    model: "claude-opus-4-8",
    modelSource: "official-doc",
    defaultEffortId: "high",
    supportedEffortIds: ["low", "medium", "high", "max", "xhigh"],
    promptTransport: "file",
    authMode: "claude-pro-max-oauth",
    requiredBackend: "agent-cli",
    readiness: { state: "selectable", assignable: true, availability: "Requires local Claude Code access." },
    family: "agent-arena",
    speed: "frontier",
    intelligence: "high",
    cost: "account",
    risk: "local-cli",
    benchmark: "Agent Arena reference plus winsmux run evidence",
    evidenceIds: ["official-doc"],
    note: "Use for high-complexity implementation or review when Claude Code access exposes Opus 4.8.",
    noteJa: "Claude Code で Opus 4.8 が利用できる場合の高難度実装・レビュー向けです。",
  },
  {
    id: "claude-sonnet-4-6",
    providerId: "claude",
    label: "Sonnet 4.6",
    labelJa: "Sonnet 4.6",
    model: "sonnet",
    modelSource: "official-doc",
    defaultEffortId: "high",
    supportedEffortIds: ["low", "medium", "high", "max"],
    promptTransport: "file",
    authMode: "claude-pro-max-oauth",
    requiredBackend: "agent-cli",
    readiness: { state: "selectable", assignable: true, availability: "Requires local Claude Code access." },
    family: "agent-arena",
    speed: "balanced",
    intelligence: "high",
    cost: "account",
    risk: "local-cli",
    benchmark: "Agent Arena reference plus winsmux run evidence",
    evidenceIds: ["official-doc"],
    note: "Use as the balanced Claude Code worker default.",
    noteJa: "Claude Code の標準的なバランス型ワーカーです。",
  },
  {
    id: "claude-haiku-4-5",
    providerId: "claude",
    label: "Haiku 4.5",
    labelJa: "Haiku 4.5",
    model: "haiku",
    modelSource: "official-doc",
    defaultEffortId: "provider-default",
    supportedEffortIds: ["provider-default"],
    promptTransport: "file",
    authMode: "claude-pro-max-oauth",
    requiredBackend: "agent-cli",
    readiness: { state: "selectable", assignable: true, availability: "Requires local Claude Code access." },
    family: "winsmux-local",
    speed: "fast",
    intelligence: "medium",
    cost: "account",
    risk: "local-cli",
    benchmark: "Local runtime selection",
    evidenceIds: ["official-doc", "desktop-model-picker"],
    note: "Selectable Claude Code model.",
    noteJa: "Claude Code の選択可能モデルです。",
  },
  {
    id: "claude-opus-4-7",
    providerId: "claude",
    label: "Opus 4.7",
    labelJa: "Opus 4.7",
    model: "claude-opus-4-7",
    modelSource: "official-doc",
    defaultEffortId: "xhigh",
    supportedEffortIds: ["low", "medium", "high", "max", "xhigh"],
    promptTransport: "file",
    authMode: "claude-pro-max-oauth",
    requiredBackend: "agent-cli",
    readiness: { state: "selectable", assignable: true, availability: "Requires local Claude Code access." },
    family: "winsmux-local",
    speed: "frontier",
    intelligence: "high",
    cost: "account",
    risk: "local-cli",
    benchmark: "Local runtime selection",
    evidenceIds: ["official-doc", "desktop-model-picker"],
    note: "Selectable Claude Code other model.",
    noteJa: "Claude Code のその他モデルとして選択できます。",
    group: "other",
  },
  {
    id: "claude-opus-4-6",
    providerId: "claude",
    label: "Opus 4.6",
    labelJa: "Opus 4.6",
    model: "claude-opus-4-6",
    modelSource: "official-doc",
    defaultEffortId: "high",
    supportedEffortIds: ["low", "medium", "high", "max"],
    promptTransport: "file",
    authMode: "claude-pro-max-oauth",
    requiredBackend: "agent-cli",
    readiness: { state: "selectable", assignable: true, availability: "Requires local Claude Code access." },
    family: "winsmux-local",
    speed: "frontier",
    intelligence: "high",
    cost: "account",
    risk: "local-cli",
    benchmark: "Local runtime selection",
    evidenceIds: ["official-doc", "desktop-model-picker"],
    note: "Selectable Claude Code other model.",
    noteJa: "Claude Code のその他モデルとして選択できます。",
    group: "other",
  },
  {
    id: "antigravity-gemini-3-5-flash-medium",
    providerId: "antigravity",
    label: "Gemini 3.5 Flash (Medium)",
    labelJa: "Gemini 3.5 Flash (Medium)",
    model: "Gemini 3.5 Flash (Medium)",
    modelSource: "cli-discovery",
    defaultEffortId: "provider-default",
    promptTransport: "file",
    authMode: "antigravity-official-cli",
    requiredBackend: "antigravity",
    readiness: { state: "selectable", assignable: true, availability: "Shown by Antigravity CLI 1.0.10 model picker." },
    family: "agent-arena",
    speed: "fast",
    intelligence: "medium",
    cost: "account",
    risk: "local-cli",
    benchmark: "Agent Arena reference plus Antigravity run evidence",
    evidenceIds: ["cli-discovery"],
    note: "Use for the Gemini replacement lane after the individual Gemini CLI sunset.",
    noteJa: "個人向け Gemini CLI 終了後の Gemini 系ワーカー候補です。",
  },
  {
    id: "antigravity-gemini-3-5-flash-high",
    providerId: "antigravity",
    label: "Gemini 3.5 Flash (High)",
    labelJa: "Gemini 3.5 Flash (High)",
    model: "Gemini 3.5 Flash (High)",
    modelSource: "cli-discovery",
    defaultEffortId: "provider-default",
    promptTransport: "file",
    authMode: "antigravity-official-cli",
    requiredBackend: "antigravity",
    readiness: { state: "selectable", assignable: true, availability: "Shown by Antigravity CLI 1.0.10 model picker." },
    family: "agent-arena",
    speed: "fast",
    intelligence: "medium-high",
    cost: "account",
    risk: "local-cli",
    benchmark: "Agent Arena reference plus Antigravity run evidence",
    evidenceIds: ["cli-discovery"],
    note: "Use when Antigravity should spend more reasoning on the Gemini Flash lane.",
    noteJa: "Gemini Flash 系でより深い推論を使う場合に選びます。",
  },
  {
    id: "antigravity-gemini-3-5-flash-low",
    providerId: "antigravity",
    label: "Gemini 3.5 Flash (Low)",
    labelJa: "Gemini 3.5 Flash (Low)",
    model: "Gemini 3.5 Flash (Low)",
    modelSource: "cli-discovery",
    defaultEffortId: "provider-default",
    promptTransport: "file",
    authMode: "antigravity-official-cli",
    requiredBackend: "antigravity",
    readiness: { state: "selectable", assignable: true, availability: "Shown by Antigravity CLI 1.0.10 model picker." },
    family: "winsmux-local",
    speed: "fast",
    intelligence: "medium",
    cost: "account",
    risk: "local-cli",
    benchmark: "Antigravity CLI local availability evidence",
    evidenceIds: ["cli-discovery"],
    note: "Use for lower-cost Antigravity smoke and parallel checks.",
    noteJa: "低コストの Antigravity スモーク確認や並列確認に使います。",
  },
  {
    id: "antigravity-gemini-3-1-pro-low",
    providerId: "antigravity",
    label: "Gemini 3.1 Pro (Low)",
    labelJa: "Gemini 3.1 Pro (Low)",
    model: "Gemini 3.1 Pro (Low)",
    modelSource: "cli-discovery",
    defaultEffortId: "provider-default",
    promptTransport: "file",
    authMode: "antigravity-official-cli",
    requiredBackend: "antigravity",
    readiness: { state: "selectable", assignable: true, availability: "Shown by Antigravity CLI 1.0.10 model picker." },
    family: "winsmux-local",
    speed: "balanced",
    intelligence: "high",
    cost: "account",
    risk: "local-cli",
    benchmark: "Antigravity CLI local availability evidence",
    evidenceIds: ["cli-discovery"],
    note: "Use for Pro-model checks through Antigravity CLI.",
    noteJa: "Antigravity CLI 経由の Pro 系確認に使います。",
  },
  {
    id: "antigravity-gemini-3-1-pro-high",
    providerId: "antigravity",
    label: "Gemini 3.1 Pro (High)",
    labelJa: "Gemini 3.1 Pro (High)",
    model: "Gemini 3.1 Pro (High)",
    modelSource: "cli-discovery",
    defaultEffortId: "provider-default",
    promptTransport: "file",
    authMode: "antigravity-official-cli",
    requiredBackend: "antigravity",
    readiness: { state: "selectable", assignable: true, availability: "Shown by Antigravity CLI 1.0.10 model picker." },
    family: "winsmux-local",
    speed: "balanced",
    intelligence: "high",
    cost: "account",
    risk: "local-cli",
    benchmark: "Antigravity CLI local availability evidence",
    evidenceIds: ["cli-discovery"],
    note: "Use for harder Pro-model checks through Antigravity CLI.",
    noteJa: "より難しい Antigravity CLI 経由の Pro 系確認に使います。",
  },
  {
    id: "antigravity-claude-sonnet-4-6-thinking",
    providerId: "antigravity",
    label: "Claude Sonnet 4.6 (Thinking)",
    labelJa: "Claude Sonnet 4.6 (Thinking)",
    model: "Claude Sonnet 4.6 (Thinking)",
    modelSource: "cli-discovery",
    defaultEffortId: "provider-default",
    promptTransport: "file",
    authMode: "antigravity-official-cli",
    requiredBackend: "antigravity",
    readiness: { state: "selectable", assignable: true, availability: "Shown by Antigravity CLI 1.0.10 model picker." },
    family: "winsmux-local",
    speed: "balanced",
    intelligence: "high",
    cost: "account",
    risk: "local-cli",
    benchmark: "Antigravity CLI local availability evidence",
    evidenceIds: ["cli-discovery"],
    note: "Use only as an Antigravity-hosted Claude lane.",
    noteJa: "Antigravity が提供する Claude 系レーンとして使います。",
  },
  {
    id: "antigravity-claude-opus-4-6-thinking",
    providerId: "antigravity",
    label: "Claude Opus 4.6 (Thinking)",
    labelJa: "Claude Opus 4.6 (Thinking)",
    model: "Claude Opus 4.6 (Thinking)",
    modelSource: "cli-discovery",
    defaultEffortId: "provider-default",
    promptTransport: "file",
    authMode: "antigravity-official-cli",
    requiredBackend: "antigravity",
    readiness: { state: "selectable", assignable: true, availability: "Shown by Antigravity CLI 1.0.10 model picker." },
    family: "winsmux-local",
    speed: "balanced",
    intelligence: "high",
    cost: "account",
    risk: "local-cli",
    benchmark: "Antigravity CLI local availability evidence",
    evidenceIds: ["cli-discovery"],
    note: "Use only as an Antigravity-hosted Claude lane.",
    noteJa: "Antigravity が提供する Claude 系レーンとして使います。",
  },
  {
    id: "antigravity-gpt-oss-120b-medium",
    providerId: "antigravity",
    label: "GPT-OSS 120B (Medium)",
    labelJa: "GPT-OSS 120B (Medium)",
    model: "GPT-OSS 120B (Medium)",
    modelSource: "cli-discovery",
    defaultEffortId: "provider-default",
    promptTransport: "file",
    authMode: "antigravity-official-cli",
    requiredBackend: "antigravity",
    readiness: { state: "selectable", assignable: true, availability: "Shown by Antigravity CLI 1.0.10 model picker." },
    family: "winsmux-local",
    speed: "balanced",
    intelligence: "medium-high",
    cost: "account",
    risk: "local-cli",
    benchmark: "Antigravity CLI local availability evidence",
    evidenceIds: ["cli-discovery"],
    note: "Use for GPT-OSS checks exposed by Antigravity CLI.",
    noteJa: "Antigravity CLI が提供する GPT-OSS 系確認に使います。",
  },
  {
    id: "grok-build-grok-4-3",
    providerId: "grok-build",
    label: "Grok 4.3",
    labelJa: "Grok 4.3",
    model: "grok-build",
    modelSource: "cli-discovery",
    defaultEffortId: "provider-default",
    supportedEffortIds: ["provider-default"],
    promptTransport: "file",
    authMode: "grok-build-local",
    requiredBackend: "agent-cli",
    readiness: { state: "selectable", assignable: true, availability: "Requires Grok Build headless access." },
    family: "winsmux-local",
    speed: "custom",
    intelligence: "custom",
    cost: "account",
    risk: "local-cli",
    benchmark: "Direct operator input; benchmark evidence is separate.",
    evidenceIds: ["cli-discovery"],
    note: "Use through the Grok Build worker lane.",
    noteJa: "Grok Build の worker 経由で使います。",
  },
  {
    id: "grok-build-composer-2-5-fast",
    providerId: "grok-build",
    label: "Composer 2.5 Fast",
    labelJa: "Composer 2.5 Fast",
    model: "grok-composer-2.5-fast",
    modelSource: "cli-discovery",
    defaultEffortId: "provider-default",
    supportedEffortIds: ["provider-default"],
    promptTransport: "file",
    authMode: "grok-build-local",
    requiredBackend: "agent-cli",
    readiness: { state: "selectable", assignable: true, availability: "Requires Grok Build headless access." },
    family: "winsmux-local",
    speed: "fast",
    intelligence: "custom",
    cost: "account",
    risk: "local-cli",
    benchmark: "Direct operator input; benchmark evidence is separate.",
    evidenceIds: ["cli-discovery"],
    note: "Use through the Grok Build worker lane.",
    noteJa: "Grok Build の worker 経由で使います。",
  },
  {
    id: "openrouter-sakana-fugu-ultra",
    providerId: "openrouter",
    label: "Sakana Fugu Ultra via OpenRouter",
    labelJa: "Sakana Fugu Ultra / OpenRouter",
    model: "sakana/fugu-ultra",
    modelSource: "operator-override",
    defaultEffortId: "provider-default",
    supportedEffortIds: ["provider-default"],
    promptTransport: "file",
    authMode: "api-key-env",
    requiredEnv: "OPENROUTER_API_KEY",
    requiredBackend: "api_llm",
    readiness: {
      state: "selectable",
      assignable: true,
      availability: "Requires OPENROUTER_API_KEY. The desktop worker pane launches through the OpenAI-compatible pane worker.",
      requiredEnv: "OPENROUTER_API_KEY",
    },
    family: "agent-arena",
    speed: "hosted",
    intelligence: "high",
    cost: "external-api",
    risk: "api-key-env",
    benchmark: "Provider Models API reference plus Harness Bench run evidence",
    evidenceIds: ["operator-override"],
    note: "Selectable for a desktop worker pane; OPENROUTER_API_KEY is validated when the worker starts.",
    noteJa: "デスクトップの worker pane で選択できます。OPENROUTER_API_KEY は worker 起動時に検証します。",
    group: "seed",
  },
  {
    id: "openrouter-glm-5-2",
    providerId: "openrouter",
    label: "GLM-5.2 via OpenRouter",
    labelJa: "GLM-5.2 / OpenRouter",
    model: "z-ai/glm-5.2",
    modelSource: "operator-override",
    defaultEffortId: "provider-default",
    supportedEffortIds: ["provider-default"],
    promptTransport: "file",
    authMode: "api-key-env",
    requiredEnv: "OPENROUTER_API_KEY",
    requiredBackend: "api_llm",
    readiness: {
      state: "selectable",
      assignable: true,
      availability: "Requires OPENROUTER_API_KEY. The desktop worker pane launches through the OpenAI-compatible pane worker.",
      requiredEnv: "OPENROUTER_API_KEY",
    },
    family: "code-arena",
    speed: "hosted",
    intelligence: "high",
    cost: "external-api",
    risk: "api-key-env",
    benchmark: "Code Arena / Agent Arena reference plus Harness Bench run evidence",
    evidenceIds: ["operator-override"],
    note: "Selectable for a desktop worker pane; OPENROUTER_API_KEY is validated when the worker starts.",
    noteJa: "デスクトップの worker pane で選択できます。OPENROUTER_API_KEY は worker 起動時に検証します。",
    group: "seed",
  },
  {
    id: "openrouter-kimi-k2-7-code",
    providerId: "openrouter",
    label: "Kimi K2.7 Code via OpenRouter",
    labelJa: "Kimi K2.7 Code / OpenRouter",
    model: "moonshotai/kimi-k2.7-code",
    modelSource: "operator-override",
    defaultEffortId: "provider-default",
    supportedEffortIds: ["provider-default"],
    promptTransport: "file",
    authMode: "api-key-env",
    requiredEnv: "OPENROUTER_API_KEY",
    requiredBackend: "api_llm",
    readiness: {
      state: "selectable",
      assignable: true,
      availability: "Requires OPENROUTER_API_KEY. The desktop worker pane launches through the OpenAI-compatible pane worker.",
      requiredEnv: "OPENROUTER_API_KEY",
    },
    family: "agent-arena",
    speed: "hosted",
    intelligence: "high",
    cost: "external-api",
    risk: "api-key-env",
    benchmark: "Agent Arena reference plus Harness Bench run evidence",
    evidenceIds: ["openrouter-model-page-kimi"],
    note: "Selectable for a desktop worker pane; OPENROUTER_API_KEY is validated when the worker starts.",
    noteJa: "デスクトップの worker pane で選択できます。OPENROUTER_API_KEY は worker 起動時に検証します。",
    group: "seed",
  },
];

export const providerCapabilityRegistry: CapabilityRegistry = {
  providers: providerCapabilities,
  models: modelCapabilities,
  efforts: effortCapabilities,
  backends: backendCapabilities,
  transports: transportCapabilities,
  evidence: evidenceRecords,
};

export function getEffortLabel(effortId: EffortCapabilityId, providerId: ProviderCapabilityId, japanese = false) {
  const effort = effortCapabilities.find((item) => item.id === effortId);
  if (!effort) {
    return effortId;
  }
  const providerLabel = japanese ? effort.providerLabelsJa?.[providerId] : effort.providerLabels?.[providerId];
  return providerLabel ?? (japanese ? effort.labelJa : effort.label);
}

export function createOpenRouterApiModelCapability(modelId: string, displayName: string = modelId): ModelCapability {
  const label = displayName && displayName !== modelId ? `${displayName} (${modelId})` : modelId;
  return {
    id: `openrouter-api-${slugCapabilityId(modelId)}`,
    providerId: "openrouter",
    label,
    labelJa: label,
    model: modelId,
    modelSource: "provider-api",
    defaultEffortId: "provider-default",
    supportedEffortIds: ["provider-default"],
    promptTransport: "file",
    authMode: "api-key-env",
    requiredEnv: "OPENROUTER_API_KEY",
    requiredBackend: "api_llm",
    readiness: {
      state: "selectable",
      assignable: true,
      availability: "Loaded from the OpenRouter Models API.",
      requiredEnv: "OPENROUTER_API_KEY",
    },
    family: "winsmux-local",
    speed: "provider-api",
    intelligence: "provider-api",
    cost: "external-api",
    risk: "api-key-env",
    benchmark: "Provider catalog; benchmark evidence is separate.",
    evidenceIds: ["provider-api"],
    note: "Loaded from OpenRouter at Settings render time. OPENROUTER_API_KEY is validated when the worker starts.",
    noteJa: "Settings 表示時に OpenRouter から取得した候補です。OPENROUTER_API_KEY は worker 起動時に検証します。",
    group: "dynamic",
  };
}

export function toRuntimeCatalogEntry(model: ModelCapability, registry: CapabilityRegistry = providerCapabilityRegistry): NormalizedRuntimeCatalogEntry {
  const evidence = model.evidenceIds
    .map((evidenceId) => registry.evidence.find((item) => item.id === evidenceId))
    .filter((item): item is EvidenceRecord => Boolean(item));
  const primaryEvidence = evidence[0];
  return {
    id: model.id,
    label: model.label,
    labelJa: model.labelJa,
    agent: model.providerId,
    providerId: model.providerId,
    model: model.model,
    modelSource: model.modelSource,
    reasoningEffort: model.defaultEffortId,
    supportedReasoningEfforts: model.supportedEffortIds,
    promptTransport: model.promptTransport,
    authMode: model.authMode,
    requiredEnv: model.requiredEnv,
    requiredBackend: model.requiredBackend,
    status: model.readiness.state,
    family: model.family,
    speed: model.speed,
    intelligence: model.intelligence,
    cost: model.cost,
    risk: model.risk,
    availability: model.readiness.availability,
    benchmark: model.benchmark,
    evidence: primaryEvidence?.kind ?? model.evidenceIds[0] ?? "provider-registry",
    sourceLabel: primaryEvidence?.sourceLabel,
    captureDate: primaryEvidence?.captureDate,
    localRunId: primaryEvidence?.localRunId,
    confidenceNote: primaryEvidence?.confidenceNote,
    confidenceNoteJa: primaryEvidence?.confidenceNoteJa,
    note: model.note,
    noteJa: model.noteJa,
  };
}

export function getRuntimeCatalogEntries(registry: CapabilityRegistry = providerCapabilityRegistry): NormalizedRuntimeCatalogEntry[] {
  const issues = validateCapabilityRegistry(registry);
  if (issues.length) {
    throw new Error(`Invalid model capability registry: ${issues.map((issue) => issue.message).join("; ")}`);
  }
  return registry.models.map((model) => toRuntimeCatalogEntry(model, registry));
}

export function getProviderEffortIds(providerId: ProviderCapabilityId, registry: CapabilityRegistry = providerCapabilityRegistry): readonly EffortCapabilityId[] {
  return registry.providers.find((provider) => provider.id === providerId)?.supportedEffortIds ?? ["provider-default"];
}

export function getModelEffortIds(model: ModelCapability, registry: CapabilityRegistry = providerCapabilityRegistry): readonly EffortCapabilityId[] {
  return model.supportedEffortIds?.length ? model.supportedEffortIds : getProviderEffortIds(model.providerId, registry);
}

export function findDuplicateCapabilityIds(registry: CapabilityRegistry = providerCapabilityRegistry): CapabilityValidationIssue[] {
  return [
    ...findDuplicateIds("provider", registry.providers),
    ...findDuplicateIds("model", registry.models),
    ...findDuplicateIds("effort", registry.efforts),
    ...findDuplicateIds("backend", registry.backends),
    ...findDuplicateIds("transport", registry.transports),
    ...findDuplicateIds("evidence", registry.evidence),
  ];
}

export function findUnsupportedDefaultEfforts(registry: CapabilityRegistry = providerCapabilityRegistry): CapabilityValidationIssue[] {
  const issues: CapabilityValidationIssue[] = [];
  for (const provider of registry.providers) {
    if (!provider.supportedEffortIds.includes(provider.defaultEffortId)) {
      issues.push({
        code: "unsupported-default-effort",
        scope: "provider",
        id: provider.id,
        message: `${provider.id} default effort ${provider.defaultEffortId} is not in its supported effort list.`,
      });
    }
  }
  for (const model of registry.models) {
    const supported = getModelEffortIds(model, registry);
    if (!supported.includes(model.defaultEffortId)) {
      issues.push({
        code: "unsupported-default-effort",
        scope: "model",
        id: model.id,
        message: `${model.id} default effort ${model.defaultEffortId} is not supported by the model or provider.`,
      });
    }
  }
  return issues;
}

export function findInvalidRequiredBackends(registry: CapabilityRegistry = providerCapabilityRegistry): CapabilityValidationIssue[] {
  const backendIds = new Set(registry.backends.map((backend) => backend.id));
  const issues: CapabilityValidationIssue[] = [];
  for (const provider of registry.providers) {
    if (!backendIds.has(provider.requiredBackend)) {
      issues.push({
        code: "invalid-required-backend",
        scope: "provider",
        id: provider.id,
        message: `${provider.id} requires unknown backend ${provider.requiredBackend}.`,
      });
    }
  }
  for (const model of registry.models) {
    if (!backendIds.has(model.requiredBackend)) {
      issues.push({
        code: "invalid-required-backend",
        scope: "model",
        id: model.id,
        message: `${model.id} requires unknown backend ${model.requiredBackend}.`,
      });
    }
  }
  return issues;
}

export function validateCapabilityRegistry(registry: CapabilityRegistry = providerCapabilityRegistry): CapabilityValidationIssue[] {
  return [
    ...findDuplicateCapabilityIds(registry),
    ...findUnsupportedDefaultEfforts(registry),
    ...findInvalidRequiredBackends(registry),
  ];
}

export function slugCapabilityId(value: string) {
  return value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._/-]+/g, "-")
    .replace(/^[^a-z0-9]+|[^a-z0-9]+$/g, "")
    || "model";
}

function findDuplicateIds(
  scope: CapabilityValidationIssue["scope"],
  entries: readonly { id: string }[],
): CapabilityValidationIssue[] {
  const seen = new Set<string>();
  const duplicates = new Set<string>();
  for (const entry of entries) {
    if (seen.has(entry.id)) {
      duplicates.add(entry.id);
    }
    seen.add(entry.id);
  }
  return Array.from(duplicates).map((id) => ({
    code: "duplicate-id",
    scope,
    id,
    message: `${scope} id ${id} is declared more than once.`,
  }));
}
