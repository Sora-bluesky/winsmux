import { Terminal } from "xterm";
import { FitAddon } from "@xterm/addon-fit";
import "xterm/css/xterm.css";
import { isTauri } from "@tauri-apps/api/core";
import { WebviewWindow, getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import {
  applyDesktopRuntimeRolePreferences,
  compareDesktopRuns,
  getDesktopEditorFile,
  getDesktopRunExplain,
  getDesktopExplorerEntries,
  getDesktopSummarySnapshot,
  getDesktopVoiceCaptureStatus,
  pickDesktopRunWinner,
  promoteDesktopRunTactic,
  recordDesktopDogfoodEvent,
  startDesktopVoiceCapture,
  stopDesktopVoiceCapture,
  subscribeToDesktopSummaryRefresh,
  type DesktopCompareRunsResult,
  type DesktopBoardPane,
  type DesktopDogfoodEventInput,
  type DesktopEditorFilePayload,
  type DesktopExplorerEntry,
  type DesktopExplainPayload,
  type DesktopRunProjection,
  type DesktopSummarySnapshot,
  type DesktopRuntimeRolePreference,
  type DesktopVoiceCaptureStatus,
} from "./desktopClient";
import { getEditorFileKey, getSourceChangeKey, pickEditorPathCandidate, pickSourceChangeKeyCandidate } from "./editorTargets";
import {
  closePtyPane,
  resizePtyPane,
  spawnPtyPane,
  subscribeToPtyOutput,
  writePtyData,
} from "./ptyClient";

interface PaneEntry {
  terminal: Terminal;
  fitAddon: FitAddon;
  container: HTMLElement;
  labelElement: HTMLElement;
  metaElement: HTMLElement;
  lastOutputAt: number | null;
  ptyStarted: boolean;
  ptyStarting: Promise<void> | null;
}

type ChipAction =
  | "open-explain"
  | "open-editor"
  | "open-source-context"
  | "toggle-context"
  | "open-terminal";

interface ConversationChip {
  label: string;
  action: ChipAction;
}

type TimelineFilter = "all" | "attention" | "review" | "activity";
type ConversationCategory = "user" | "attention" | "review" | "activity";

interface ConversationDetail {
  label: string;
  value: string;
}

interface ConversationItem {
  type: "user" | "operator" | "system";
  category: ConversationCategory;
  timestamp: string;
  actor: string;
  title?: string;
  body: string;
  details?: ConversationDetail[];
  chips?: ConversationChip[];
  attachments?: Array<{ name: string; kind: "image" | "file"; sizeLabel: string }>;
  tone?: SurfaceTone;
  runId?: string;
  statusLabel?: string;
}

interface SessionItem {
  name: string;
  meta: string;
  active?: boolean;
  projectDir?: string | null;
  action?: "add-project";
}

interface DetachedSurfaceSessionState {
  name: string;
  meta: string;
}

interface ProjectSessionEntry {
  path: string;
  name: string;
  lastSeenAt: number;
}

interface ExplorerItem {
  label: string;
  meta?: string;
  depth: number;
  kind: "folder" | "file";
  folderKey?: string;
  path?: string;
  worktree?: string;
  open?: boolean;
  hasChildren?: boolean;
  active?: boolean;
  sourceStatus?: ChangeStatus;
  hasSourceChanges?: boolean;
  iconKind?: ExplorerIconKind;
  ignored?: boolean;
}

type ExplorerIconKind =
  | "config"
  | "image"
  | "javascript"
  | "json"
  | "license"
  | "lock"
  | "markdown"
  | "powershell"
  | "rust"
  | "text"
  | "toml"
  | "typescript"
  | "xml"
  | "yaml";

interface EditorCodeLine {
  number: number;
  text: string;
}

interface EditorFile {
  key: string;
  path: string;
  summary: string;
  content: string;
  language: string;
  lineCount: number;
  modified?: boolean;
  origin: "explorer" | "context";
  active?: boolean;
}

interface ProjectExplorerTreeNode {
  label: string;
  path: string;
  kind: "directory" | "file";
  hasChildren?: boolean;
  ignored?: boolean;
  children: Map<string, ProjectExplorerTreeNode>;
}

interface EditorTarget {
  key: string;
  path: string;
  summary: string;
  worktree: string;
  origin: "explorer" | "context";
  modified: boolean;
  sourceChange?: SourceChange;
}

interface PreviewTarget {
  url: string;
  portLabel: string;
  sourceLabel: string;
  lastSeenAt: number;
}

type PopoutSurfaceState =
  | {
      mode: "preview";
      url: string;
      portLabel: string;
      sourceLabel: string;
      lastSeenAt: number;
      runId?: string;
      runLabel?: string;
    }
  | {
      mode: "editor";
      path: string;
      worktree: string;
      summary: string;
      origin: "explorer" | "context";
      modified: boolean;
      sourceChange?: SourceChange | null;
      content?: string;
      runId?: string;
      runLabel?: string;
    };

declare global {
  interface Window {
    __winsmuxViewportHarness?: {
      registerPreviewTarget: (sourceLabel: string, url: string) => void;
      openPreviewTarget: (url: string) => void;
      openEditorPreview: (path: string, content: string, worktree?: string) => void;
      setContextPanel: (open: boolean) => void;
      setTerminalDrawer: (open: boolean) => void;
      getOperatorStartupInput: () => string;
    };
  }
}

type SourceFilter = "all" | "candidates" | "attention" | `pane:${string}`;

type ChangeStatus = "modified" | "added" | "deleted" | "renamed";
type ChangeRisk = "low" | "medium" | "high";

interface SourceChange {
  path: string;
  summary: string;
  paneLabel: string;
  worktree: string;
  status: ChangeStatus;
  risk: ChangeRisk;
  branch: string;
  lines: string;
  commitCandidate: boolean;
  needsAttention: boolean;
  run: string;
  review: string;
  staged?: boolean;
}

interface BrowserSourceGraphItem {
  run_id: string;
  short_sha?: string;
  parents?: string[];
  task: string;
  branch: string;
  refs?: string[];
  author?: string;
  relative_time?: string;
  committed_at?: string;
  changed_files: string[];
}

interface FooterStatusItem {
  label: string;
  value?: string;
  tone?: SurfaceTone;
}

interface HandoffDecisionItem {
  label: string;
  value: string;
  detail: string;
  status: "ready" | "waiting" | "blocked" | "missing";
}

interface EvidenceItem {
  category: string;
  title: string;
  body: string;
  meta: string;
  source: string;
  anchor: string;
  tone: SurfaceTone;
  runId?: string;
  primaryPath?: string;
  primaryWorktree?: string;
}

interface ExperimentDetailLine {
  label: string;
  value: string;
  path?: string;
  worktree?: string;
  title?: string;
}

type SurfaceTone = "default" | "accent" | "success" | "warning" | "danger" | "info" | "focus";
type CompareRiskLevel = "low" | "medium" | "high";
type ThemeMode = "codex-dark" | "graphite-dark";
type DensityMode = "comfortable" | "compact";
type WrapMode = "balanced" | "compact";
type CodeFontMode = "system" | "google-sans-code" | "jetbrains-mono";
type FocusMode = "standard" | "focused";
type LanguageMode = "en" | "ja";
type WorkbenchLayoutMode = "2x2" | "3x2" | "focus";
type RuntimeRoleId = "operator" | "worker" | "reviewer";
type RuntimeProviderId = "provider-default" | "codex" | "claude" | "gemini";
type RuntimeModelSource = "provider-default" | "cli-discovery" | "official-doc" | "operator-override";
type RuntimeReasoningEffort = "provider-default" | "low" | "medium" | "high" | "xhigh" | "max";
type ComposerPermissionMode = "auto" | "default" | "acceptEdits" | "plan";
type ComposerEffortLevel = "auto" | "low" | "medium" | "high" | "xhigh" | "max";
type ComposerModelId = "opus-4.7" | "opus-4.7-1m" | "opus-4.6" | "sonnet-4.6" | "haiku-4.5";
type VoiceDraftMode = "raw" | "cleaned" | "operator_request";

interface ThemeState {
  theme: ThemeMode;
  density: DensityMode;
  wrapMode: WrapMode;
  codeFont: CodeFontMode;
  codeFontFamily: string;
  editorFontSize: number;
  voiceShortcut: string;
  focusMode: FocusMode;
  language: LanguageMode;
}

interface ShellPreferenceState extends ThemeState {
  sidebarWidth: number;
  workbenchWidth: number | null;
  wideSidebarOpen: boolean;
  wideContextOpen: boolean;
  workbenchOpen: boolean;
  workbenchLayout: WorkbenchLayoutMode;
  focusedWorkbenchPaneId: string | null;
}

interface RuntimeRolePreference {
  roleId: RuntimeRoleId;
  provider: RuntimeProviderId;
  model: string;
  modelSource: RuntimeModelSource;
  reasoningEffort: RuntimeReasoningEffort;
}

interface ComposerAttachment {
  id: string;
  name: string;
  kind: "image" | "file";
  sizeLabel: string;
  file: File;
  previewUrl?: string;
}

interface ComposerRemoteReference {
  id: string;
  label: string;
  meta: string;
}

interface ComposerAttachmentSnapshot {
  name: string;
  kind: "image" | "file";
  sizeLabel: string;
  file: File;
}

interface ComposerHistoryEntry {
  value: string;
  remoteReferenceIds: string[];
  attachments: ComposerAttachmentSnapshot[];
}

interface ComposerSessionControlState {
  permissionMode: ComposerPermissionMode;
  model: ComposerModelId;
  effort: ComposerEffortLevel;
  voiceDraftMode: VoiceDraftMode;
  fastModeEnabled: boolean;
  fastModeTogglePending: boolean;
}

interface SpeechRecognitionAlternativeLike {
  transcript?: string;
}

interface SpeechRecognitionResultLike {
  isFinal?: boolean;
  [index: number]: SpeechRecognitionAlternativeLike;
}

interface SpeechRecognitionResultListLike {
  length: number;
  [index: number]: SpeechRecognitionResultLike;
}

interface SpeechRecognitionEventLike {
  resultIndex: number;
  results: SpeechRecognitionResultListLike;
}

interface SpeechRecognitionErrorEventLike {
  error?: string;
  message?: string;
}

interface SpeechRecognitionLike {
  continuous: boolean;
  interimResults: boolean;
  lang: string;
  onstart: (() => void) | null;
  onend: (() => void) | null;
  onerror: ((event: SpeechRecognitionErrorEventLike) => void) | null;
  onresult: ((event: SpeechRecognitionEventLike) => void) | null;
  start: () => void;
  stop: () => void;
  abort: () => void;
}

type SpeechRecognitionConstructor = new () => SpeechRecognitionLike;

type ComposerMode = "ask" | "dispatch" | "review";
type DogfoodInputSource = DesktopDogfoodEventInput["inputSource"];
type DogfoodActionType = DesktopDogfoodEventInput["actionType"];
type SidebarMode = "explorer" | "source" | "evidence" | "workspace";

interface ComposerSlashCommand {
  command: string;
  label: string;
  labelJa: string;
  description: string;
  descriptionJa: string;
  kind: "mode" | "claude" | "winsmux";
  mode?: ComposerMode;
}

interface CommandAction {
  id: string;
  label: string;
  description: string;
  keywords: string[];
  shortcut?: string;
  tone?: SurfaceTone;
  run: () => void;
}

const panes = new Map<string, PaneEntry>();
let terminalDrawerOpen = true;
let contextPanelOpen = false;
let editorSurfaceOpen = false;
let editorSurfaceMode: "code" | "preview" = "code";
let settingsSheetOpen = false;
let sidebarOpen = true;
let sidebarMode: SidebarMode = "explorer";
let workbenchLayout: WorkbenchLayoutMode = "2x2";
let focusedWorkbenchPaneId: string | null = null;
let composerImeActive = false;
let sidebarWidth = 292;
let workbenchWidth: number | null = null;
let selectedEditorKey = "";
let selectedPreviewUrl = "";
let lastPreviewExternalState: { url: string; at: number; ok: boolean } | null = null;
let lastPreviewClipboardState: { url: string; at: number; ok: boolean } | null = null;
let selectedRunId: string | null = null;
let detachedSurfaceRunLabel = "";
let detachedSurfaceSession: DetachedSurfaceSessionState | null = null;
let detachedSurfacePollTimer: number | null = null;
let activeComposerMode: ComposerMode = "dispatch";
let activeComposerPermissionMode: ComposerPermissionMode = "acceptEdits";
let activeComposerModel: ComposerModelId = "opus-4.7-1m";
let activeComposerEffort: ComposerEffortLevel = "xhigh";
let activeVoiceDraftMode: VoiceDraftMode = "raw";
let activeComposerFastModeEnabled = false;
let activeComposerFastModeTogglePending = false;
let openComposerSessionMenu: "permission" | "model" | "voice" | null = null;
let composerSlashOpen = false;
let composerSlashQuery = "";
let composerWinsmuxCommandOpen = false;
let composerWinsmuxCommandQuery = "";
let selectedComposerSlashIndex = 0;
let composerHistory: ComposerHistoryEntry[] = [];
let composerHistoryIndex = -1;
let composerDraftState: ComposerHistoryEntry = { value: "", remoteReferenceIds: [], attachments: [] };
let selectedComposerRemoteReferenceIds = new Set<string>();
let composerInputSource: DogfoodInputSource = "keyboard";
let composerDraftStartedAt = 0;
let composerDogfoodTaskRef = "";
let composerVoiceStartedAt = 0;
let composerKeyboardAfterVoiceAt = 0;
const dogfoodSessionId = `desktop-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
let dogfoodRunCounter = 0;
let activeSourceFilter: SourceFilter = "all";
let activeTimelineFilter: TimelineFilter = "all";
let commandBarOpen = false;
let commandBarQuery = "";
let selectedCommandIndex = 0;
let commandBarImeActive = false;
let lastCommandBarFocus: HTMLElement | null = null;
let openTopMenuId: string | null = null;
let pendingAttachments: ComposerAttachment[] = [];
let sourceControlCommitMessage = "";
let operatorPtyStarted = false;
let operatorPtyStarting: Promise<void> | null = null;
let operatorRequestActive = false;
let operatorRequestGeneration = 0;
let operatorRequestStartedAt = 0;
let operatorRequestStatusTimer: number | null = null;
let operatorInterruptInFlight = false;
let operatorOutputBuffer = "";
let operatorOutputFlushTimer: number | null = null;
let voiceRecognition: SpeechRecognitionLike | null = null;
let voiceListening = false;
let voiceInputMode: "browser" | "native" | null = null;
let voiceTranscriptBase = "";
let voiceCaptureStatus: DesktopVoiceCaptureStatus | null = null;
let voiceCaptureStatusError = "";
let voiceCaptureStatusRefreshStarted = false;
let voiceCapturePollTimer: number | null = null;
const detectedPreviewTargets = new Map<string, PreviewTarget>();
const PREVIEW_FRESHNESS_WINDOW_MS = 30_000;
const PANE_META_REFRESH_INTERVAL_MS = 30_000;
let desktopSummarySnapshot: DesktopSummarySnapshot | null = null;
let desktopSummaryRefreshInFlight: Promise<void> | null = null;
let desktopSummaryRefreshInFlightProjectKey = "";
let desktopSummaryRefreshTimeout: number | null = null;
let desktopSummaryQueuedRunId: string | null = null;
let desktopSummaryRefreshRequestedVersion = 0;
let desktopSummaryRefreshRunningVersion = 0;
let desktopSummaryRefreshSequence = 0;
let desktopSummaryFallbackRefreshRegistered = false;
let desktopSummaryLiveRefreshAvailable = false;
let desktopSummaryLastSuccessfulRefreshAt = 0;
let desktopSummaryLastStreamSignalAt = 0;
let desktopSummaryRefreshSerial = 0;
const desktopExplainCache = new Map<string, DesktopExplainPayload>();
const desktopRunCompareCache = new Map<string, DesktopCompareRunsResult>();
const promotedRunCandidates = new Map<string, {
  fingerprint: string;
  candidateRef: string;
  collapseAfterRefreshSerial: number;
}>();
const desktopEditorFileCache = new Map<string, EditorFile>();
const desktopEditorLoadingPaths = new Set<string>();
const desktopEditorLoadErrors = new Map<string, string>();
const desktopStandaloneEditorTargets = new Map<string, EditorTarget>();
const collapsedExplorerFolders = new Set<string>();
const expandedExplorerFolders = new Set<string>();
let projectExplorerEntries: DesktopExplorerEntry[] = [];
let projectExplorerLoaded = false;
let projectExplorerRefreshInFlight: Promise<void> | null = null;
const projectExplorerLoadedFolderPaths = new Set<string>();
const projectExplorerFolderLoads = new Map<string, Promise<void>>();
let explorerContextMenu: HTMLDivElement | null = null;
let browserSourceChanges: SourceChange[] = [];
let browserSourceGraphItems: BrowserSourceGraphItem[] = [];
let browserSourceRefreshInFlight: Promise<void> | null = null;
let sourceControlChangesHeight = 320;
const promotingRunIds = new Set<string>();
const pickingWinnerRunIds = new Set<string>();
const pendingPromotedRunRefreshIds = new Set<string>();
const comparingRunPairKeys = new Set<string>();
const backendConversation: ConversationItem[] = [];
const runtimeConversation: ConversationItem[] = [];
const DESKTOP_SUMMARY_REFRESH_FALLBACK_INTERVAL_MS = 15_000;
const DESKTOP_SUMMARY_STREAM_STALE_MS = 60_000;
const MAX_RUNTIME_CONVERSATION_ITEMS = 80;
const OPERATOR_PTY_ID = "operator";
const OPERATOR_PTY_COLS = 120;
const OPERATOR_PTY_ROWS = 32;
const DEFAULT_EDITOR_FONT_SIZE = 14;
const MIN_EDITOR_FONT_SIZE = 8;
const MAX_EDITOR_FONT_SIZE = 32;
const DEFAULT_CODE_FONT_FAMILY = "Consolas, 'Courier New', monospace";
const DEFAULT_VOICE_SHORTCUT = "Ctrl+Alt+M";
const RESERVED_VOICE_SHORTCUTS = new Set(["Win+H", "Ctrl+Space", "Ctrl+Shift+Space"]);
const themeState: ThemeState = {
  theme: "codex-dark",
  density: "comfortable",
  wrapMode: "balanced",
  codeFont: "system",
  codeFontFamily: DEFAULT_CODE_FONT_FAMILY,
  editorFontSize: DEFAULT_EDITOR_FONT_SIZE,
  voiceShortcut: DEFAULT_VOICE_SHORTCUT,
  focusMode: "standard",
  language: "en",
};
let settingsDraftState: ThemeState | null = null;
let settingsFontFamilyMenuOpen = false;
let runtimeRolePreferences: RuntimeRolePreference[] = [];
let runtimeRoleDraftState: RuntimeRolePreference[] | null = null;
let preferredWideSidebarOpen = true;
let preferredWideContextOpen = false;
const SHELL_PREFERENCES_STORAGE_KEY = "winsmux.shell.preferences.v1";
const RUNTIME_ROLE_PREFERENCES_STORAGE_KEY = "winsmux.runtime-role.preferences.v1";
const COMPOSER_SESSION_STORAGE_KEY = "winsmux.composer-session.v1";
const POPOUT_SURFACE_STORAGE_KEY_PREFIX = "winsmux.popout-surface.";
const PROJECT_SESSIONS_STORAGE_KEY = "winsmux.project-sessions.v1";
const ACTIVE_PROJECT_STORAGE_KEY = "winsmux.active-project.v1";
const MAX_PROJECT_SESSIONS = 8;
let projectSessionEntries: ProjectSessionEntry[] = readStoredProjectSessions();
let activeProjectDir: string | null = readStoredActiveProjectDir();

const composerModes: Array<{ mode: ComposerMode; label: string; placeholder: string }> = [
  { mode: "ask", label: "Ask", placeholder: "Ask a question or request guidance" },
  { mode: "dispatch", label: "Dispatch", placeholder: "Describe a task or ask a question" },
  { mode: "review", label: "Review", placeholder: "Describe what needs review or approval" },
];

const composerPermissionModeOptions: Array<{
  value: ComposerPermissionMode;
  label: string;
  labelJa: string;
  description: string;
  descriptionJa: string;
  shortcut: string;
}> = [
  {
    value: "default",
    label: "Ask before edits",
    labelJa: "編集前に確認",
    description: "Ask before file edits while keeping normal conversation flow.",
    descriptionJa: "通常の会話を保ちながら、ファイル編集前に確認します。",
    shortcut: "0",
  },
  {
    value: "acceptEdits",
    label: "Approve edits",
    labelJa: "編集を承認",
    description: "Allow Claude to edit without prompting for each change.",
    descriptionJa: "変更ごとの確認を省き、編集を承認します。",
    shortcut: "1",
  },
  {
    value: "plan",
    label: "Plan mode",
    labelJa: "プランモード",
    description: "Explore and prepare a plan before editing.",
    descriptionJa: "編集前に調査し、計画を作ります。",
    shortcut: "2",
  },
];

const composerModelOptions: Array<{
  value: ComposerModelId;
  label: string;
  labelJa: string;
  cliModel: string;
  shortcut: string;
  fastModeCompatible?: boolean;
}> = [
  { value: "opus-4.7", label: "Opus 4.7", labelJa: "Opus 4.7", cliModel: "opus", shortcut: "1" },
  { value: "opus-4.7-1m", label: "Opus 4.7 1M", labelJa: "Opus 4.7 1M", cliModel: "opus[1m]", shortcut: "2" },
  { value: "opus-4.6", label: "Opus 4.6", labelJa: "Opus 4.6", cliModel: "claude-opus-4-6", shortcut: "3", fastModeCompatible: true },
  { value: "sonnet-4.6", label: "Sonnet 4.6", labelJa: "Sonnet 4.6", cliModel: "sonnet", shortcut: "4" },
  { value: "haiku-4.5", label: "Haiku 4.5", labelJa: "Haiku 4.5", cliModel: "haiku", shortcut: "5" },
];

const composerEffortOptions: Array<{
  value: ComposerEffortLevel;
  label: string;
  labelJa: string;
  description: string;
  descriptionJa: string;
  shortcut: string;
}> = [
  {
    value: "low",
    label: "Low",
    labelJa: "低",
    description: "Prefer faster responses with lighter reasoning.",
    descriptionJa: "軽めの推論で応答を速くします。",
    shortcut: "L",
  },
  {
    value: "medium",
    label: "Medium",
    labelJa: "中",
    description: "Balance speed and reasoning depth.",
    descriptionJa: "速度と思考の深さを両立します。",
    shortcut: "M",
  },
  {
    value: "high",
    label: "High",
    labelJa: "高",
    description: "Use deeper reasoning for complex work.",
    descriptionJa: "複雑な作業に向けて深く考えます。",
    shortcut: "H",
  },
  {
    value: "xhigh",
    label: "Ultra",
    labelJa: "超高",
    description: "Use extra reasoning depth for difficult work.",
    descriptionJa: "難しい作業に向けてさらに深く考えます。",
    shortcut: "U",
  },
  {
    value: "max",
    label: "Max",
    labelJa: "Max",
    description: "Use the maximum available effort.",
    descriptionJa: "利用可能な最大の思考量を使います。",
    shortcut: "X",
  },
];

const localComposerSlashCommands: ComposerSlashCommand[] = [
  {
    command: "ask",
    label: "Ask",
    labelJa: "質問",
    description: "Switch the composer to ask mode.",
    descriptionJa: "質問モードに切り替えます。",
    kind: "mode",
    mode: "ask",
  },
  {
    command: "dispatch",
    label: "Dispatch",
    labelJa: "依頼",
    description: "Switch the composer to dispatch mode.",
    descriptionJa: "依頼モードに切り替えます。",
    kind: "mode",
    mode: "dispatch",
  },
];

const officialClaudeSlashCommandEntries: Array<Omit<ComposerSlashCommand, "kind">> = [
  { command: "add-dir", label: "Add directory", labelJa: "ディレクトリ追加", description: "Add a working directory.", descriptionJa: "作業ディレクトリを追加します。" },
  { command: "agents", label: "Agents", labelJa: "エージェント", description: "Manage agent configurations.", descriptionJa: "エージェント設定を管理します。" },
  { command: "autofix-pr", label: "Autofix PR", labelJa: "PR 自動修正", description: "Watch a PR and push fixes.", descriptionJa: "PR を監視し、修正を反映します。" },
  { command: "batch", label: "Batch", labelJa: "一括作業", description: "Plan and run large changes in parallel.", descriptionJa: "大きな変更を分割して並列実行します。" },
  { command: "branch", label: "Branch", labelJa: "会話ブランチ", description: "Branch the current conversation.", descriptionJa: "現在の会話から分岐します。" },
  { command: "fork", label: "Fork", labelJa: "分岐", description: "Alias for conversation branch.", descriptionJa: "会話ブランチの別名です。" },
  { command: "btw", label: "Side question", labelJa: "横質問", description: "Ask without adding to the conversation.", descriptionJa: "会話に混ぜずに短い質問をします。" },
  { command: "chrome", label: "Chrome", labelJa: "Chrome", description: "Configure Claude in Chrome.", descriptionJa: "Chrome 連携を設定します。" },
  { command: "claude-api", label: "Claude API", labelJa: "Claude API", description: "Load Claude API guidance.", descriptionJa: "Claude API の手順を読み込みます。" },
  { command: "clear", label: "Clear", labelJa: "履歴消去", description: "Start a new conversation.", descriptionJa: "新しい会話を開始します。" },
  { command: "reset", label: "Reset", labelJa: "リセット", description: "Alias for clear.", descriptionJa: "履歴消去の別名です。" },
  { command: "new", label: "New", labelJa: "新規", description: "Alias for clear.", descriptionJa: "履歴消去の別名です。" },
  { command: "color", label: "Color", labelJa: "色", description: "Change the prompt bar color.", descriptionJa: "入力バーの色を変更します。" },
  { command: "compact", label: "Compact", labelJa: "圧縮", description: "Summarize context with optional instructions.", descriptionJa: "指示を付けて文脈を圧縮します。" },
  { command: "config", label: "Config", labelJa: "設定", description: "Open Claude Code settings.", descriptionJa: "Claude Code の設定を開きます。" },
  { command: "settings", label: "Settings", labelJa: "設定", description: "Alias for config.", descriptionJa: "設定を開く別名です。" },
  { command: "context", label: "Context", labelJa: "文脈", description: "Show current context usage.", descriptionJa: "現在の文脈使用量を表示します。" },
  { command: "copy", label: "Copy", labelJa: "コピー", description: "Copy a recent assistant response.", descriptionJa: "直近の応答をコピーします。" },
  { command: "cost", label: "Cost", labelJa: "費用", description: "Alias for usage.", descriptionJa: "使用状況を開く別名です。" },
  { command: "usage", label: "Usage", labelJa: "使用状況", description: "Show usage limits and activity.", descriptionJa: "使用量と制限を表示します。" },
  { command: "stats", label: "Stats", labelJa: "統計", description: "Alias for usage.", descriptionJa: "使用状況を開く別名です。" },
  { command: "debug", label: "Debug", labelJa: "デバッグ", description: "Enable logs and diagnose an issue.", descriptionJa: "ログを有効にして問題を調べます。" },
  { command: "desktop", label: "Desktop", labelJa: "デスクトップ", description: "Continue in Claude Code Desktop.", descriptionJa: "デスクトップアプリで続けます。" },
  { command: "app", label: "App", labelJa: "アプリ", description: "Alias for desktop.", descriptionJa: "デスクトップ表示の別名です。" },
  { command: "diff", label: "Diff", labelJa: "差分", description: "Open the interactive diff viewer.", descriptionJa: "対話型の差分表示を開きます。" },
  { command: "doctor", label: "Doctor", labelJa: "診断", description: "Diagnose installation and settings.", descriptionJa: "インストールと設定を診断します。" },
  { command: "effort", label: "Effort", labelJa: "思考量", description: "Change model effort level.", descriptionJa: "モデルの思考量を変更します。" },
  { command: "exit", label: "Exit", labelJa: "終了", description: "Exit the CLI.", descriptionJa: "CLI を終了します。" },
  { command: "quit", label: "Quit", labelJa: "終了", description: "Alias for exit.", descriptionJa: "終了の別名です。" },
  { command: "export", label: "Export", labelJa: "書き出し", description: "Export the conversation.", descriptionJa: "会話を書き出します。" },
  { command: "goal", label: "Goal", labelJa: "ゴール", description: "Create or update a session goal.", descriptionJa: "セッションの目標を作成または更新します。" },
  { command: "extra-usage", label: "Extra usage", labelJa: "追加利用", description: "Configure extra usage.", descriptionJa: "追加利用を設定します。" },
  { command: "fast", label: "Fast", labelJa: "高速", description: "Toggle fast mode.", descriptionJa: "高速モードを切り替えます。" },
  { command: "feedback", label: "Feedback", labelJa: "フィードバック", description: "Submit feedback.", descriptionJa: "フィードバックを送信します。" },
  { command: "bug", label: "Bug report", labelJa: "不具合報告", description: "Alias for feedback.", descriptionJa: "フィードバック送信の別名です。" },
  { command: "fewer-permission-prompts", label: "Fewer prompts", labelJa: "確認を減らす", description: "Suggest permission allow rules.", descriptionJa: "権限確認を減らす設定を提案します。" },
  { command: "focus", label: "Focus", labelJa: "集中表示", description: "Toggle focus view.", descriptionJa: "集中表示を切り替えます。" },
  { command: "heapdump", label: "Heap dump", labelJa: "ヒープ保存", description: "Write a memory diagnostic file.", descriptionJa: "メモリ診断ファイルを出力します。" },
  { command: "help", label: "Help", labelJa: "ヘルプ", description: "Show help and available commands.", descriptionJa: "ヘルプと利用可能なコマンドを表示します。" },
  { command: "hooks", label: "Hooks", labelJa: "フック", description: "View hook configuration.", descriptionJa: "フック設定を表示します。" },
  { command: "ide", label: "IDE", labelJa: "IDE", description: "Manage IDE integrations.", descriptionJa: "IDE 連携を管理します。" },
  { command: "init", label: "Init", labelJa: "初期化", description: "Create or update CLAUDE.md.", descriptionJa: "CLAUDE.md を作成または更新します。" },
  { command: "insights", label: "Insights", labelJa: "分析", description: "Analyze recent Claude Code sessions.", descriptionJa: "最近のセッションを分析します。" },
  { command: "install-github-app", label: "GitHub app", labelJa: "GitHub アプリ", description: "Set up the GitHub Actions app.", descriptionJa: "GitHub Actions アプリを設定します。" },
  { command: "install-slack-app", label: "Slack app", labelJa: "Slack アプリ", description: "Install the Slack app.", descriptionJa: "Slack アプリをインストールします。" },
  { command: "keybindings", label: "Keybindings", labelJa: "キー設定", description: "Open keybindings configuration.", descriptionJa: "キー設定ファイルを開きます。" },
  { command: "login", label: "Login", labelJa: "ログイン", description: "Sign in to Anthropic.", descriptionJa: "Anthropic にログインします。" },
  { command: "logout", label: "Logout", labelJa: "ログアウト", description: "Sign out from Anthropic.", descriptionJa: "Anthropic からログアウトします。" },
  { command: "loop", label: "Loop", labelJa: "定期実行", description: "Run a prompt repeatedly.", descriptionJa: "プロンプトを繰り返し実行します。" },
  { command: "proactive", label: "Proactive", labelJa: "定期実行", description: "Alias for loop.", descriptionJa: "定期実行の別名です。" },
  { command: "mcp", label: "MCP", labelJa: "MCP", description: "Manage MCP connections and OAuth.", descriptionJa: "MCP 接続と OAuth 認証を管理します。" },
  { command: "memory", label: "Memory", labelJa: "メモリ", description: "Edit Claude memory files.", descriptionJa: "Claude のメモリファイルを編集します。" },
  { command: "mobile", label: "Mobile", labelJa: "モバイル", description: "Show the mobile app QR code.", descriptionJa: "モバイルアプリの QR コードを表示します。" },
  { command: "ios", label: "iOS", labelJa: "iOS", description: "Alias for mobile.", descriptionJa: "モバイル表示の別名です。" },
  { command: "android", label: "Android", labelJa: "Android", description: "Alias for mobile.", descriptionJa: "モバイル表示の別名です。" },
  { command: "model", label: "Model", labelJa: "モデル", description: "Select or change the model.", descriptionJa: "使用するモデルを変更します。" },
  { command: "passes", label: "Passes", labelJa: "招待", description: "Share a free Claude Code week.", descriptionJa: "無料利用パスを共有します。" },
  { command: "permissions", label: "Permissions", labelJa: "権限", description: "Manage tool permissions.", descriptionJa: "ツール権限を管理します。" },
  { command: "allowed-tools", label: "Allowed tools", labelJa: "許可ツール", description: "Alias for permissions.", descriptionJa: "権限管理の別名です。" },
  { command: "plan", label: "Plan", labelJa: "計画", description: "Enter plan mode.", descriptionJa: "計画モードに入ります。" },
  { command: "plugin", label: "Plugin", labelJa: "プラグイン", description: "Manage Claude Code plugins.", descriptionJa: "Claude Code プラグインを管理します。" },
  { command: "powerup", label: "Powerup", labelJa: "機能紹介", description: "Discover Claude Code features.", descriptionJa: "Claude Code の機能紹介を開きます。" },
  { command: "pr-comments", label: "PR comments", labelJa: "PR コメント", description: "Legacy PR comment viewer.", descriptionJa: "旧版の PR コメント表示です。" },
  { command: "privacy-settings", label: "Privacy", labelJa: "プライバシー", description: "View privacy settings.", descriptionJa: "プライバシー設定を表示します。" },
  { command: "recap", label: "Recap", labelJa: "要約", description: "Generate a session summary.", descriptionJa: "セッション要約を作成します。" },
  { command: "release-notes", label: "Release notes", labelJa: "リリースノート", description: "Open release notes.", descriptionJa: "リリースノートを開きます。" },
  { command: "reload-plugins", label: "Reload plugins", labelJa: "プラグイン再読込", description: "Reload active plugins.", descriptionJa: "有効なプラグインを再読み込みします。" },
  { command: "remote-control", label: "Remote control", labelJa: "リモート操作", description: "Enable remote control.", descriptionJa: "リモート操作を有効にします。" },
  { command: "rc", label: "Remote control", labelJa: "リモート操作", description: "Alias for remote-control.", descriptionJa: "リモート操作の別名です。" },
  { command: "remote-env", label: "Remote env", labelJa: "リモート環境", description: "Configure remote environment.", descriptionJa: "リモート環境を設定します。" },
  { command: "rename", label: "Rename", labelJa: "名前変更", description: "Rename the current session.", descriptionJa: "現在のセッション名を変更します。" },
  { command: "resume", label: "Resume", labelJa: "再開", description: "Resume a conversation.", descriptionJa: "会話を再開します。" },
  { command: "continue", label: "Continue", labelJa: "再開", description: "Alias for resume.", descriptionJa: "再開の別名です。" },
  { command: "review", label: "Review", labelJa: "レビュー", description: "Review a pull request locally.", descriptionJa: "PR をローカルでレビューします。" },
  { command: "rewind", label: "Rewind", labelJa: "巻き戻し", description: "Return to a previous point.", descriptionJa: "以前の時点へ戻します。" },
  { command: "checkpoint", label: "Checkpoint", labelJa: "チェックポイント", description: "Alias for rewind.", descriptionJa: "巻き戻しの別名です。" },
  { command: "undo", label: "Undo", labelJa: "元に戻す", description: "Alias for rewind.", descriptionJa: "巻き戻しの別名です。" },
  { command: "sandbox", label: "Sandbox", labelJa: "サンドボックス", description: "Toggle sandbox mode.", descriptionJa: "サンドボックスモードを切り替えます。" },
  { command: "schedule", label: "Schedule", labelJa: "定期予定", description: "Create or manage routines.", descriptionJa: "定期実行の予定を管理します。" },
  { command: "routines", label: "Routines", labelJa: "定期予定", description: "Alias for schedule.", descriptionJa: "定期予定の別名です。" },
  { command: "security-review", label: "Security review", labelJa: "セキュリティレビュー", description: "Review changes for security risks.", descriptionJa: "変更のセキュリティリスクを確認します。" },
  { command: "setup-bedrock", label: "Bedrock setup", labelJa: "Bedrock 設定", description: "Configure Amazon Bedrock.", descriptionJa: "Amazon Bedrock を設定します。" },
  { command: "setup-vertex", label: "Vertex setup", labelJa: "Vertex 設定", description: "Configure Google Vertex AI.", descriptionJa: "Google Vertex AI を設定します。" },
  { command: "simplify", label: "Simplify", labelJa: "簡素化", description: "Find and fix code quality issues.", descriptionJa: "コード品質の問題を探して修正します。" },
  { command: "skills", label: "Skills", labelJa: "スキル", description: "List available skills.", descriptionJa: "利用可能なスキルを一覧表示します。" },
  { command: "status", label: "Status", labelJa: "状態", description: "Show account and system status.", descriptionJa: "アカウントとシステムの状態を表示します。" },
  { command: "statusline", label: "Status line", labelJa: "状態行", description: "Configure the status line.", descriptionJa: "状態行を設定します。" },
  { command: "stickers", label: "Stickers", labelJa: "ステッカー", description: "Order Claude Code stickers.", descriptionJa: "Claude Code ステッカーを注文します。" },
  { command: "tasks", label: "Tasks", labelJa: "タスク", description: "List background tasks.", descriptionJa: "バックグラウンドタスクを一覧表示します。" },
  { command: "bashes", label: "Bashes", labelJa: "タスク", description: "Alias for tasks.", descriptionJa: "タスク一覧の別名です。" },
  { command: "team-onboarding", label: "Team onboarding", labelJa: "チーム導入", description: "Generate an onboarding guide.", descriptionJa: "チーム向け導入ガイドを作成します。" },
  { command: "teleport", label: "Teleport", labelJa: "取り込み", description: "Pull a web session into the terminal.", descriptionJa: "Web セッションを端末に取り込みます。" },
  { command: "tp", label: "Teleport", labelJa: "取り込み", description: "Alias for teleport.", descriptionJa: "取り込みの別名です。" },
  { command: "terminal-setup", label: "Terminal setup", labelJa: "端末設定", description: "Configure terminal keybindings.", descriptionJa: "端末のキー設定を行います。" },
  { command: "theme", label: "Theme", labelJa: "テーマ", description: "Change the color theme.", descriptionJa: "配色テーマを変更します。" },
  { command: "tui", label: "TUI", labelJa: "TUI", description: "Set the terminal renderer.", descriptionJa: "端末表示方式を変更します。" },
  { command: "ultraplan", label: "Ultraplan", labelJa: "高度な計画", description: "Draft a plan in a web session.", descriptionJa: "Web セッションで計画を作成します。" },
  { command: "ultrareview", label: "Ultrareview", labelJa: "高度なレビュー", description: "Run a cloud-based review.", descriptionJa: "クラウド上で詳細レビューを実行します。" },
  { command: "upgrade", label: "Upgrade", labelJa: "アップグレード", description: "Open the upgrade page.", descriptionJa: "アップグレード画面を開きます。" },
  { command: "vim", label: "Vim", labelJa: "Vim", description: "Legacy editor mode command.", descriptionJa: "旧版の編集モードコマンドです。" },
  { command: "voice", label: "Voice", labelJa: "音声入力", description: "Toggle voice dictation.", descriptionJa: "音声入力を切り替えます。" },
  { command: "web-setup", label: "Web setup", labelJa: "Web 設定", description: "Connect GitHub for web sessions.", descriptionJa: "Web セッション用に GitHub を接続します。" },
];

const winsmuxComposerCommandEntries: ComposerSlashCommand[] = [
  {
    command: "winsmux list",
    label: "List panes",
    labelJa: "ペイン一覧",
    description: "Show the current managed panes.",
    descriptionJa: "現在の管理ペインを一覧表示します。",
    kind: "winsmux",
  },
  {
    command: "winsmux read worker-1 30",
    label: "Read worker output",
    labelJa: "ワーカー出力を読む",
    description: "Read the latest lines from a worker pane.",
    descriptionJa: "ワーカーペインの直近行を読みます。",
    kind: "winsmux",
  },
  {
    command: "winsmux send worker-2 \"最新の認証変更をレビューしてください。\"",
    label: "Send a review request",
    labelJa: "レビュー依頼を送る",
    description: "Send an instruction to a worker pane.",
    descriptionJa: "ワーカーペインへ指示を送ります。",
    kind: "winsmux",
  },
  {
    command: "winsmux health-check",
    label: "Check pane health",
    labelJa: "ペイン状態を確認",
    description: "Check whether the managed panes are responsive.",
    descriptionJa: "管理ペインが応答しているか確認します。",
    kind: "winsmux",
  },
  {
    command: "winsmux compare runs <left_run_id> <right_run_id>",
    label: "Compare recorded runs",
    labelJa: "実行結果を比較",
    description: "Compare two recorded runs before choosing one.",
    descriptionJa: "採用前に 2 つの実行結果を比較します。",
    kind: "winsmux",
  },
  {
    command: "winsmux compare preflight <left_ref> <right_ref>",
    label: "Compare refs before merge",
    labelJa: "マージ前に比較",
    description: "Check two refs before merge or review.",
    descriptionJa: "マージやレビューの前に 2 つの参照を確認します。",
    kind: "winsmux",
  },
  {
    command: "winsmux compare promote <run_id>",
    label: "Promote a run",
    labelJa: "実行結果を次へ使う",
    description: "Export a successful run as input for a later run.",
    descriptionJa: "成功した実行結果を次の入力として書き出します。",
    kind: "winsmux",
  },
  {
    command: "winsmux meta-plan --task \"この変更を計画して\" --json",
    label: "Draft a meta-plan",
    labelJa: "メタ計画を作る",
    description: "Create a read-only planning packet.",
    descriptionJa: "読み取り専用の計画パケットを作成します。",
    kind: "winsmux",
  },
  {
    command: "winsmux meta-plan --task \"この変更を計画して\" --roles .winsmux/meta-plan-roles.yaml --review-rounds 2 --json",
    label: "Draft a reviewed meta-plan",
    labelJa: "レビュー付きメタ計画",
    description: "Create a multi-role plan with cross-review rounds.",
    descriptionJa: "複数ロールと相互レビュー付きの計画を作成します。",
    kind: "winsmux",
  },
  {
    command: "winsmux skills --json",
    label: "List winsmux skills",
    labelJa: "スキル一覧",
    description: "List available winsmux skill packs as JSON.",
    descriptionJa: "利用可能な winsmux スキルを JSON で表示します。",
    kind: "winsmux",
  },
];

const composerSlashCommands: ComposerSlashCommand[] = [
  ...localComposerSlashCommands,
  ...officialClaudeSlashCommandEntries.map((item) => ({
    ...item,
    kind: "claude" as const,
  })),
];

const timelineFilters: Array<{ filter: TimelineFilter; label: string }> = [
  { filter: "all", label: "All" },
  { filter: "attention", label: "Attention" },
  { filter: "review", label: "Review" },
  { filter: "activity", label: "Activity" },
];

const timelineFilterLabelsJa: Record<TimelineFilter, string> = {
  all: "すべて",
  attention: "要確認",
  review: "レビュー",
  activity: "活動",
};

const themeOptions: Array<{ value: ThemeMode; label: string; description: string; labelJa?: string; descriptionJa?: string }> = [
  { value: "codex-dark", label: "Codex TUI Dark", labelJa: "Codex TUI Dark", description: "Adaptation of public openai/codex TUI typography and contrast.", descriptionJa: "公開されている openai/codex TUI の文字設計とコントラストを参考にした表示。" },
  { value: "graphite-dark", label: "Graphite", labelJa: "Graphite", description: "Softer shell contrast for long operator sessions.", descriptionJa: "長時間のオペレーター作業向けにコントラストを抑えた表示。" },
];

const densityOptions: Array<{ value: DensityMode; label: string; description: string; labelJa?: string; descriptionJa?: string }> = [
  { value: "comfortable", label: "Comfortable", labelJa: "標準", description: "Default shell spacing for conversation and context.", descriptionJa: "会話と文脈パネルを読みやすくする標準の余白。" },
  { value: "compact", label: "Compact", labelJa: "コンパクト", description: "Tighter panel spacing and smaller composer height.", descriptionJa: "パネル間隔と入力欄を詰めた表示。" },
];

const wrapOptions: Array<{ value: WrapMode; label: string; description: string; labelJa?: string; descriptionJa?: string }> = [
  { value: "balanced", label: "Balanced", labelJa: "読みやすさ優先", description: "Preferred readability for timeline, code, and footer lanes.", descriptionJa: "タイムライン、コード、下部ステータスを読みやすく折り返します。" },
  { value: "compact", label: "Compact", labelJa: "密度優先", description: "Denser wrapping for narrow windows and long traces.", descriptionJa: "狭い画面や長いログで情報量を優先します。" },
];

const codeFontOptions: Array<{ value: CodeFontMode; label: string; description: string; labelJa?: string; descriptionJa?: string }> = [
  { value: "system", label: "Consolas / Courier New", labelJa: "Consolas / Courier New", description: "Windows developer default: Consolas, 'Courier New', monospace.", descriptionJa: "Windows 開発環境の既定値: Consolas, 'Courier New', monospace。" },
  { value: "google-sans-code", label: "Google Sans Code", labelJa: "Google Sans Code", description: "Use Google Sans Code when it is installed.", descriptionJa: "インストール済みの時に Google Sans Code を使います。" },
  { value: "jetbrains-mono", label: "JetBrains Mono", labelJa: "JetBrains Mono", description: "Use JetBrains Mono when it is installed.", descriptionJa: "インストール済みの時に JetBrains Mono を使います。" },
];

const focusModeOptions: Array<{ value: FocusMode; label: string; description: string; labelJa?: string; descriptionJa?: string }> = [
  { value: "standard", label: "Standard", labelJa: "標準", description: "Show timeline detail chips on every event.", descriptionJa: "すべての出来事に詳細チップを表示します。" },
  { value: "focused", label: "Focus", labelJa: "集中", description: "Keep details for selected, review, and attention events.", descriptionJa: "選択中、レビュー、注意が必要な出来事だけ詳細を残します。" },
];

const languageOptions: Array<{ value: LanguageMode; label: string; description: string; labelJa?: string; descriptionJa?: string }> = [
  { value: "en", label: "English", labelJa: "English", description: "Use English for the workspace chrome and controls.", descriptionJa: "作業領域と操作部品を英語で表示します。" },
  { value: "ja", label: "Japanese", labelJa: "日本語", description: "Use Japanese for the main workspace chrome and settings.", descriptionJa: "主要な操作部品と設定を日本語で表示します。" },
];

const voiceDraftModeOptions: Array<{ value: VoiceDraftMode; label: string; labelJa: string; description: string; descriptionJa: string }> = [
  { value: "raw", label: "Raw", labelJa: "そのまま", description: "Insert the recognized transcript without cleanup.", descriptionJa: "認識結果を整形せず下書きへ入れます。" },
  { value: "cleaned", label: "Clean draft", labelJa: "整える", description: "Remove fillers and repeated phrases conservatively.", descriptionJa: "不要な言いよどみや繰り返しだけを控えめに整えます。" },
  { value: "operator_request", label: "Operator request", labelJa: "依頼文", description: "Shape spoken intent into an editable operator request.", descriptionJa: "話した意図を編集可能な依頼文として整えます。" },
];

const runtimeRoleOptions: Array<{ value: RuntimeRoleId; label: string; labelJa: string; description: string; descriptionJa: string }> = [
  { value: "operator", label: "Operator", labelJa: "オペレーター", description: "Owns approvals and session control.", descriptionJa: "承認とセッション制御を担当します。" },
  { value: "worker", label: "Worker", labelJa: "ワーカー", description: "Handles implementation and verification work.", descriptionJa: "実装と検証を担当します。" },
  { value: "reviewer", label: "Reviewer", labelJa: "レビュアー", description: "Checks diffs, risks, and tests.", descriptionJa: "差分、リスク、テストを確認します。" },
];

const runtimeProviderOptions: Array<{ value: RuntimeProviderId; label: string; labelJa: string }> = [
  { value: "provider-default", label: "Provider default", labelJa: "既定値" },
  { value: "codex", label: "Codex CLI", labelJa: "Codex CLI" },
  { value: "claude", label: "Claude Code", labelJa: "Claude Code" },
  { value: "gemini", label: "Gemini CLI", labelJa: "Gemini CLI" },
];
const lockedOperatorRuntimePreference: RuntimeRolePreference = {
  roleId: "operator",
  provider: "claude",
  model: "provider-default",
  modelSource: "provider-default",
  reasoningEffort: "provider-default",
};

const runtimeModelSourceOptions: Array<{ value: RuntimeModelSource; label: string; labelJa: string }> = [
  { value: "provider-default", label: "Provider default", labelJa: "既定値" },
  { value: "cli-discovery", label: "Local CLI catalog", labelJa: "ローカル CLI" },
  { value: "official-doc", label: "Official docs", labelJa: "公式ドキュメント" },
  { value: "operator-override", label: "Operator override", labelJa: "明示指定" },
];

const runtimeReasoningOptions: Array<{ value: RuntimeReasoningEffort; label: string; labelJa: string }> = [
  { value: "provider-default", label: "Auto", labelJa: "自動" },
  { value: "low", label: "Low", labelJa: "低" },
  { value: "medium", label: "Medium", labelJa: "中" },
  { value: "high", label: "High", labelJa: "高" },
  { value: "xhigh", label: "X High", labelJa: "特高" },
  { value: "max", label: "Max", labelJa: "最大" },
];

const runtimeModelSuggestions = [
  "provider-default",
  "gpt-5.3-codex-spark",
  "gpt-5.5",
  "default",
  "sonnet",
  "opus",
  "opusplan",
];

runtimeRolePreferences = readStoredRuntimeRolePreferences();
{
  const storedComposerControls = readStoredComposerSessionControls();
  activeComposerPermissionMode = storedComposerControls.permissionMode;
  activeComposerModel = storedComposerControls.model;
  activeComposerEffort = storedComposerControls.effort;
  activeVoiceDraftMode = storedComposerControls.voiceDraftMode;
  activeComposerFastModeEnabled = storedComposerControls.fastModeEnabled;
  activeComposerFastModeTogglePending = storedComposerControls.fastModeTogglePending;
}

const fallbackExplorerPaths = [
  ".agents/README.md",
  ".github/workflows/ci.yml",
  "core/Cargo.toml",
  "docs/quickstart.md",
  "docs/quickstart.ja.md",
  "docs/installation.md",
  "docs/installation.ja.md",
  "docs/operator-model.md",
  "winsmux-app/index.html",
  "winsmux-app/src/main.ts",
  "winsmux-app/src/styles.css",
  "winsmux-core/scripts/doctor.ps1",
  "README.md",
  "README.ja.md",
  "Cargo.toml",
  "Cargo.lock",
];

function normalizeCodeFontFamily(value: unknown, fallback = DEFAULT_CODE_FONT_FAMILY) {
  if (typeof value !== "string") {
    return fallback;
  }
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > 200) {
    return fallback;
  }
  return trimmed;
}

function getCodeFontFamily(mode: CodeFontMode = themeState.codeFont, fontFamily: string = themeState.codeFontFamily) {
  const normalizedFamily = normalizeCodeFontFamily(fontFamily, "");
  if (normalizedFamily) {
    return normalizedFamily;
  }
  switch (mode) {
    case "google-sans-code":
      return "Google Sans Code, Consolas, 'Courier New', monospace";
    case "jetbrains-mono":
      return "JetBrains Mono, Consolas, 'Courier New', monospace";
    case "system":
    default:
      return DEFAULT_CODE_FONT_FAMILY;
  }
}

interface VoiceShortcutParts {
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
  meta: boolean;
  key: string;
}

function isModifierShortcutKey(key: string) {
  const normalized = key.toLowerCase();
  return normalized === "control"
    || normalized === "ctrl"
    || normalized === "alt"
    || normalized === "shift"
    || normalized === "meta"
    || normalized === "win"
    || normalized === "windows"
    || normalized === "cmd"
    || normalized === "command";
}

function normalizeShortcutKey(value: string) {
  if (value === " ") {
    return "Space";
  }
  const trimmed = value.trim();
  if (!trimmed) {
    return "";
  }

  const lower = trimmed.toLowerCase();
  if (lower === " " || lower === "space" || lower === "spacebar") {
    return "Space";
  }
  if (lower === "esc") {
    return "Escape";
  }
  if (lower === "up") {
    return "ArrowUp";
  }
  if (lower === "down") {
    return "ArrowDown";
  }
  if (lower === "left") {
    return "ArrowLeft";
  }
  if (lower === "right") {
    return "ArrowRight";
  }
  if (trimmed.length === 1) {
    return trimmed.toUpperCase();
  }
  return `${trimmed[0]?.toUpperCase() ?? ""}${trimmed.slice(1)}`;
}

function formatVoiceShortcut(parts: VoiceShortcutParts) {
  const keys: string[] = [];
  if (parts.ctrl) {
    keys.push("Ctrl");
  }
  if (parts.alt) {
    keys.push("Alt");
  }
  if (parts.shift) {
    keys.push("Shift");
  }
  if (parts.meta) {
    keys.push("Win");
  }
  keys.push(parts.key);
  return keys.join("+");
}

function parseVoiceShortcut(value: unknown): VoiceShortcutParts | null {
  if (typeof value !== "string") {
    return null;
  }

  const tokens = value
    .split("+")
    .map((item) => item.trim())
    .filter(Boolean);
  if (tokens.length === 0) {
    return null;
  }

  const parts: VoiceShortcutParts = {
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
    key: "",
  };

  for (const token of tokens) {
    const lower = token.toLowerCase();
    if (lower === "control" || lower === "ctrl") {
      parts.ctrl = true;
      continue;
    }
    if (lower === "alt" || lower === "option") {
      parts.alt = true;
      continue;
    }
    if (lower === "shift") {
      parts.shift = true;
      continue;
    }
    if (lower === "meta" || lower === "win" || lower === "windows" || lower === "cmd" || lower === "command") {
      parts.meta = true;
      continue;
    }
    if (parts.key) {
      return null;
    }
    parts.key = normalizeShortcutKey(token);
  }

  return parts.key ? parts : null;
}

function normalizeVoiceShortcut(value: unknown, fallback = DEFAULT_VOICE_SHORTCUT) {
  const parsed = parseVoiceShortcut(value);
  if (!parsed || (!parsed.ctrl && !parsed.alt && !parsed.shift && !parsed.meta)) {
    return fallback;
  }
  const formatted = formatVoiceShortcut(parsed);
  return RESERVED_VOICE_SHORTCUTS.has(formatted) ? fallback : formatted;
}

function getVoiceShortcutValidation(value: unknown, japanese: boolean) {
  const parsed = parseVoiceShortcut(value);
  if (!parsed) {
    return {
      valid: false,
      normalized: "",
      message: japanese ? "ショートカットを入力してください。" : "Enter a keyboard shortcut.",
    };
  }

  const hasModifier = parsed.ctrl || parsed.alt || parsed.shift || parsed.meta;
  if (!hasModifier) {
    return {
      valid: false,
      normalized: formatVoiceShortcut(parsed),
      message: japanese ? "少なくとも 1 つの修飾キーを含めてください。" : "Include at least one modifier key.",
    };
  }

  const normalized = formatVoiceShortcut(parsed);
  if (RESERVED_VOICE_SHORTCUTS.has(normalized)) {
    return {
      valid: false,
      normalized,
      message: japanese
        ? "Windows 音声入力、IME、エディター補完と競合するため、この組み合わせは使えません。"
        : "This shortcut conflicts with Windows voice typing, IME, or editor completion.",
    };
  }

  return { valid: true, normalized, message: "" };
}

function getVoiceShortcutFromKeyboardEvent(event: KeyboardEvent) {
  if (isModifierShortcutKey(event.key)) {
    return "";
  }
  const key = normalizeShortcutKey(event.key);
  if (!key) {
    return "";
  }
  return formatVoiceShortcut({
    ctrl: event.ctrlKey,
    alt: event.altKey,
    shift: event.shiftKey,
    meta: event.metaKey,
    key,
  });
}

function isVoiceShortcutEvent(event: KeyboardEvent) {
  const shortcut = parseVoiceShortcut(themeState.voiceShortcut);
  if (!shortcut) {
    return false;
  }
  const key = normalizeShortcutKey(event.key);
  return Boolean(key)
    && shortcut.key === key
    && shortcut.ctrl === event.ctrlKey
    && shortcut.alt === event.altKey
    && shortcut.shift === event.shiftKey
    && shortcut.meta === event.metaKey;
}

function getNextWorkerPaneId() {
  let index = 1;
  while (panes.has(`worker-${index}`)) {
    index += 1;
  }
  return `worker-${index}`;
}

function getPaneDisplayLabel(paneId: string, backendLabel?: string) {
  const label = backendLabel || paneId;
  const workerPane = /^worker-(\d+)$/.exec(paneId) || /^worker-(\d+)$/.exec(label);
  if (workerPane) {
    return `worker-${Number(workerPane[1])}`;
  }
  const generatedPane = /^pane-(\d+)$/.exec(paneId);
  if (generatedPane) {
    return `worker-${Number(generatedPane[1]) + 1}`;
  }
  return paneId.startsWith("worker-") ? paneId : label;
}

function getWorkbenchPaneOrdinal(paneId: string | null | undefined) {
  if (!paneId) {
    return null;
  }
  const workerPane = /^worker-(\d+)$/.exec(paneId);
  if (workerPane) {
    const ordinal = Number(workerPane[1]);
    return ordinal >= 1 && ordinal <= 6 ? ordinal : null;
  }
  return null;
}

function createPane(paneId?: string): string {
  const id = paneId || getNextWorkerPaneId();
  const container = document.getElementById("panes-container");
  if (!container) {
    return id;
  }

  if (!paneId && panes.size >= 6) {
    const paneIds = Array.from(panes.keys());
    return paneIds[paneIds.length - 1] ?? id;
  }

  const paneDiv = document.createElement("div");
  paneDiv.className = "pane";
  paneDiv.id = `pane-${id}`;

  const header = document.createElement("div");
  header.className = "pane-header";

  const labelGroup = document.createElement("div");
  labelGroup.className = "pane-heading";

  const label = document.createElement("span");
  label.className = "pane-label";
  label.textContent = getPaneDisplayLabel(id);

  const meta = document.createElement("span");
  meta.className = "pane-meta";
  meta.textContent = getLanguageText("No branch · waiting for summary", "ブランチなし・要約待ち");

  const closeBtn = document.createElement("button");
  closeBtn.className = "pane-close";
  closeBtn.textContent = "×";
  closeBtn.onclick = () => closePane(id);

  labelGroup.appendChild(label);
  labelGroup.appendChild(meta);
  header.appendChild(labelGroup);
  header.appendChild(closeBtn);

  const termDiv = document.createElement("div");
  termDiv.className = "pane-terminal";

  paneDiv.appendChild(header);
  paneDiv.appendChild(termDiv);

  container.appendChild(paneDiv);

  const terminal = new Terminal({
    cursorBlink: true,
    fontSize: themeState.editorFontSize,
    fontFamily: getCodeFontFamily(),
    theme: {
      background: "#131722",
      foreground: "#c7d2e6",
      cursor: "#c7d2e6",
    },
  });

  const fitAddon = new FitAddon();
  terminal.loadAddon(fitAddon);
  terminal.open(termDiv);
  fitAddon.fit();

  terminal.onData((data: string) => {
    void ensurePanePtyStarted(id).then(() => writePtyData(id, data)).catch((error) => {
      console.warn("Failed to write PTY data", error);
    });
  });

  terminal.onResize(({ cols, rows }) => {
    const entry = panes.get(id);
    if (entry?.ptyStarted) {
      void resizePtyPane(id, cols, rows);
    }
  });

  panes.set(id, {
    terminal,
    fitAddon,
    container: paneDiv,
    labelElement: label,
    metaElement: meta,
    lastOutputAt: null,
    ptyStarted: false,
    ptyStarting: null,
  });
  const hasKnownFocusedPane = focusedWorkbenchPaneId && (panes.has(focusedWorkbenchPaneId) || getWorkbenchPaneOrdinal(focusedWorkbenchPaneId) !== null);
  if (!hasKnownFocusedPane || (!paneId && workbenchLayout === "focus")) {
    focusedWorkbenchPaneId = id;
  }
  if (!paneId && workbenchLayout === "2x2" && panes.size > 4) {
    workbenchLayout = "3x2";
  }
  updateWorkbenchControls();

  if (shouldAutoStartPane(id)) {
    void ensurePanePtyStarted(id);
  }

  return id;
}

function shouldAutoStartPane(_paneId: string) {
  return false;
}

function getPaneStartupInput(_paneId: string) {
  return undefined;
}

function getOperatorStartupInput() {
  const args = ["claude", "--permission-mode", activeComposerPermissionMode];
  const modelOption = getComposerModelOption();
  if (modelOption.cliModel) {
    args.push("--model", modelOption.cliModel);
  }
  if (activeComposerEffort !== "auto") {
    args.push("--effort", activeComposerEffort);
  }
  const startupInput = `${args.join(" ")}\r`;
  const shouldToggleFastMode = activeComposerFastModeTogglePending;
  if (!shouldToggleFastMode) {
    return startupInput;
  }
  activeComposerFastModeTogglePending = false;
  persistComposerSessionControls();
  return `${startupInput}/fast\r`;
}

function ensureOperatorPtyStarted() {
  if (operatorPtyStarted) {
    return Promise.resolve();
  }
  if (operatorPtyStarting) {
    return operatorPtyStarting;
  }

  operatorPtyStarting = spawnPtyPane(OPERATOR_PTY_ID, OPERATOR_PTY_COLS, OPERATOR_PTY_ROWS, getOperatorStartupInput())
    .then(() => {
      operatorPtyStarted = true;
    })
    .catch((error) => {
      const message = error instanceof Error ? error.message : String(error);
      if (message.includes(`Pane ${OPERATOR_PTY_ID} already exists`)) {
        operatorPtyStarted = true;
        return;
      }
      operatorPtyStarted = false;
      throw error;
    })
    .finally(() => {
      operatorPtyStarting = null;
    });

  return operatorPtyStarting;
}

function ensurePanePtyStarted(paneId: string) {
  const entry = panes.get(paneId);
  if (!entry) {
    return Promise.reject(new Error(`Pane ${paneId} not found`));
  }
  if (entry.ptyStarted) {
    return Promise.resolve();
  }
  if (entry.ptyStarting) {
    return entry.ptyStarting;
  }

  const { cols, rows } = { cols: entry.terminal.cols, rows: entry.terminal.rows };
  entry.metaElement.textContent = getLanguageText("starting shell", "シェル起動中");
  entry.ptyStarting = spawnPtyPane(paneId, cols, rows, getPaneStartupInput(paneId))
    .then(() => {
      entry.ptyStarted = true;
      entry.metaElement.textContent = getLanguageText("waiting for summary", "要約待ち");
      requestDesktopSummaryRefresh(undefined, 500);
    })
    .catch((error) => {
      entry.ptyStarted = false;
      entry.metaElement.textContent = getLanguageText("shell start failed", "シェル起動失敗");
      entry.metaElement.title = error instanceof Error ? error.message : String(error);
      throw error;
    })
    .finally(() => {
      entry.ptyStarting = null;
    });

  return entry.ptyStarting;
}

function closePane(id: string) {
  const entry = panes.get(id);
  if (!entry) {
    return;
  }

  if (panes.size <= 1) {
    return;
  }

  entry.terminal.dispose();

  entry.container.remove();
  panes.delete(id);
  if (focusedWorkbenchPaneId === id) {
    focusedWorkbenchPaneId = null;
  }
  updateWorkbenchControls();
  void persistThemeState();
  if (entry.ptyStarted || entry.ptyStarting) {
    void closePtyPane(id)
      .catch((error) => {
        console.warn("Failed to close PTY pane", error);
      })
      .finally(() => {
        requestDesktopSummaryRefresh(undefined, 500);
      });
  }

  fitVisibleWorkbenchPanes();
}

function ensureDefaultWorkbenchPanes() {
  const defaultPaneIds = ["worker-1", "worker-2", "worker-3", "worker-4"];
  for (const id of defaultPaneIds) {
    if (panes.size >= 4) {
      break;
    }
    if (!panes.has(id)) {
      createPane(id);
    }
  }
}

function ensureWorkbenchPaneCount(targetCount: number) {
  ensureDefaultWorkbenchPanes();
  while (panes.size < targetCount && panes.size < 6) {
    createPane();
  }
}

function getWorkbenchPaneIds() {
  return Array.from(panes.keys());
}

function getFocusedWorkbenchPaneId() {
  if (focusedWorkbenchPaneId && panes.has(focusedWorkbenchPaneId)) {
    return focusedWorkbenchPaneId;
  }
  const firstPaneId = getWorkbenchPaneIds()[0] ?? null;
  const pendingOrdinal = getWorkbenchPaneOrdinal(focusedWorkbenchPaneId);
  if (pendingOrdinal !== null && panes.size < pendingOrdinal) {
    return firstPaneId;
  }
  if (!focusedWorkbenchPaneId || !panes.has(focusedWorkbenchPaneId)) {
    focusedWorkbenchPaneId = firstPaneId;
  }
  return firstPaneId;
}

function getWorkbenchPaneCountForLayout() {
  if (workbenchLayout === "3x2") {
    return 6;
  }
  if (workbenchLayout === "focus") {
    return Math.max(4, getWorkbenchPaneOrdinal(focusedWorkbenchPaneId) ?? 1);
  }
  return 4;
}

function getVisibleWorkbenchPaneIds() {
  const paneIds = getWorkbenchPaneIds();
  if (workbenchLayout === "focus") {
    const focusedPaneId = getFocusedWorkbenchPaneId();
    return focusedPaneId ? [focusedPaneId] : [];
  }
  return paneIds.slice(0, workbenchLayout === "3x2" ? 6 : 4);
}

function syncFocusedPaneSelect() {
  const select = document.getElementById("focused-pane-select") as HTMLSelectElement | null;
  if (!select) {
    return;
  }

  const focusedPaneId = getFocusedWorkbenchPaneId();
  select.replaceChildren(...getWorkbenchPaneIds().map((paneId) => {
    const option = document.createElement("option");
    option.value = paneId;
    option.textContent = getPaneDisplayLabel(paneId);
    return option;
  }));
  if (focusedPaneId) {
    select.value = focusedPaneId;
  }
  select.hidden = workbenchLayout !== "focus";
  select.disabled = workbenchLayout !== "focus" || panes.size <= 1;
}

function syncWorkbenchPaneVisibility() {
  const visibleIds = new Set(getVisibleWorkbenchPaneIds());
  panes.forEach((pane, paneId) => {
    const visible = visibleIds.has(paneId);
    pane.container.hidden = !visible;
    pane.container.toggleAttribute("data-focused-pane", workbenchLayout === "focus" && visible);
  });
}

function fitVisibleWorkbenchPanes() {
  panes.forEach((pane) => {
    if (!pane.container.hidden) {
      pane.fitAddon.fit();
    }
  });
}

function updateWorkbenchControls() {
  const drawer = document.getElementById("terminal-drawer");
  const addButton = document.getElementById("add-pane-btn") as HTMLButtonElement | null;
  const layoutButton = document.getElementById("workbench-layout-btn");
  const menuLayoutStatus = document.getElementById("menu-layout-status");

  drawer?.setAttribute("data-layout", workbenchLayout);
  syncWorkbenchPaneVisibility();
  syncFocusedPaneSelect();
  if (addButton) {
    addButton.disabled = panes.size >= 6;
    addButton.textContent = panes.size >= 6 ? getLanguageText("6 panes", "6 ペイン") : getLanguageText("+ Pane", "+ ペイン");
    addButton.setAttribute(
      "aria-label",
      panes.size >= 6 ? getLanguageText("Maximum pane count reached", "ペイン数が上限です") : getLanguageText("Add worker pane", "ワーカーペインを追加"),
    );
  }
  if (layoutButton) {
    layoutButton.textContent = workbenchLayout;
  }
  if (menuLayoutStatus) {
    const paneCount = terminalDrawerOpen ? getVisibleWorkbenchPaneIds().length : panes.size;
    const paneLabel = paneCount === 1 ? "pane" : "panes";
    menuLayoutStatus.textContent = getLanguageText(`${workbenchLayout} · ${paneCount} ${paneLabel}`, `${workbenchLayout}・${paneCount} ペイン`);
  }
}

function normalizeProjectDirInput(value: string | null | undefined) {
  return (value ?? "").trim().replace(/\\/g, "/").replace(/\/+$/, "");
}

function getProjectDisplayName(projectDir: string) {
  const normalized = normalizeProjectDirInput(projectDir);
  const segments = normalized.split("/").filter(Boolean);
  return segments[segments.length - 1] || normalized || "winsmux";
}

function readStoredProjectSessions() {
  try {
    const rawValue = window.localStorage.getItem(PROJECT_SESSIONS_STORAGE_KEY);
    if (!rawValue) {
      return [];
    }

    const parsed = JSON.parse(rawValue) as Array<Partial<ProjectSessionEntry>>;
    return parsed
      .map((entry) => {
        const path = normalizeProjectDirInput(entry.path);
        if (!path) {
          return null;
        }
        return {
          path,
          name: entry.name || getProjectDisplayName(path),
          lastSeenAt: typeof entry.lastSeenAt === "number" ? entry.lastSeenAt : 0,
        } satisfies ProjectSessionEntry;
      })
      .filter((entry): entry is ProjectSessionEntry => Boolean(entry))
      .slice(0, MAX_PROJECT_SESSIONS);
  } catch {
    return [];
  }
}

function persistProjectSessions() {
  try {
    window.localStorage.setItem(PROJECT_SESSIONS_STORAGE_KEY, JSON.stringify(projectSessionEntries));
  } catch (error) {
    console.warn("Failed to persist project sessions", error);
  }
}

function readStoredActiveProjectDir() {
  try {
    return normalizeProjectDirInput(window.localStorage.getItem(ACTIVE_PROJECT_STORAGE_KEY)) || null;
  } catch {
    return null;
  }
}

function persistActiveProjectDir() {
  try {
    if (activeProjectDir) {
      window.localStorage.setItem(ACTIVE_PROJECT_STORAGE_KEY, activeProjectDir);
    } else {
      window.localStorage.removeItem(ACTIVE_PROJECT_STORAGE_KEY);
    }
  } catch (error) {
    console.warn("Failed to persist active project", error);
  }
}

function getActiveProjectDirPayload() {
  return activeProjectDir ? normalizeProjectDirInput(activeProjectDir) : undefined;
}

function captureProjectRequestKey() {
  return normalizeProjectDirInput(getActiveProjectDirPayload()) || "";
}

function isProjectRequestCurrent(projectKey: string) {
  return (normalizeProjectDirInput(getActiveProjectDirPayload()) || "") === projectKey;
}

function rememberProjectSession(projectDir: string) {
  const path = normalizeProjectDirInput(projectDir);
  if (!path) {
    return;
  }

  projectSessionEntries = [
    { path, name: getProjectDisplayName(path), lastSeenAt: Date.now() },
    ...projectSessionEntries.filter((entry) => normalizeProjectDirInput(entry.path) !== path),
  ].slice(0, MAX_PROJECT_SESSIONS);
  persistProjectSessions();
}

function resetDesktopProjectState() {
  desktopSummarySnapshot = null;
  selectedRunId = null;
  selectedEditorKey = "";
  selectedPreviewUrl = "";
  activeSourceFilter = "all";
  activeTimelineFilter = "all";
  desktopExplainCache.clear();
  desktopRunCompareCache.clear();
  promotedRunCandidates.clear();
  desktopEditorFileCache.clear();
  desktopEditorLoadingPaths.clear();
  desktopEditorLoadErrors.clear();
  desktopStandaloneEditorTargets.clear();
  collapsedExplorerFolders.clear();
  expandedExplorerFolders.clear();
  projectExplorerEntries = [];
  projectExplorerLoaded = false;
  projectExplorerRefreshInFlight = null;
  projectExplorerLoadedFolderPaths.clear();
  projectExplorerFolderLoads.clear();
  browserSourceChanges = [];
  browserSourceGraphItems = [];
  browserSourceRefreshInFlight = null;
  promotingRunIds.clear();
  pickingWinnerRunIds.clear();
  pendingPromotedRunRefreshIds.clear();
  comparingRunPairKeys.clear();
  backendConversation.splice(0, backendConversation.length);
}

function setActiveProjectDir(projectDir: string | null) {
  const nextProjectDir = normalizeProjectDirInput(projectDir) || null;
  if (normalizeProjectDirInput(activeProjectDir) === normalizeProjectDirInput(nextProjectDir)) {
    return;
  }

  activeProjectDir = nextProjectDir;
  if (activeProjectDir) {
    rememberProjectSession(activeProjectDir);
  }
  persistActiveProjectDir();
  resetDesktopProjectState();
  renderDesktopSurfaces();
  void refreshProjectExplorerEntries();
  void refreshBrowserSourceControl();
  requestDesktopSummaryRefresh(undefined, 0);
}

function promptAndAddProjectSession() {
  const value = window.prompt(getLanguageText("Project path", "プロジェクトのパス"));
  const projectDir = normalizeProjectDirInput(value);
  if (!projectDir) {
    return;
  }

  setActiveProjectDir(projectDir);
}

function renderSessions() {
  const root = document.getElementById("session-list");
  if (!root) {
    return;
  }

  const activeSessions = getSessionItems();
  root.innerHTML = "";
  for (const session of activeSessions) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `sidebar-row ${session.active ? "is-active" : ""}`;
    if (session.projectDir) {
      button.title = session.projectDir;
    }
    button.innerHTML = `<span class="sidebar-row-title">${session.name}</span><span class="sidebar-row-meta">${session.meta}</span>`;
    if (session.action === "add-project") {
      button.addEventListener("click", () => {
        promptAndAddProjectSession();
      });
    } else if (session.projectDir !== undefined && !session.active) {
      button.addEventListener("click", () => {
        setActiveProjectDir(session.projectDir ?? null);
      });
    }
    root.appendChild(button);
  }
}

function getSessionItems() {
  const activePath = activeProjectDir ?? desktopSummarySnapshot?.project_dir ?? null;
  const activeName = activePath ? getProjectDisplayName(activePath) : "winsmux";
  if (!desktopSummarySnapshot) {
    const items: SessionItem[] = [{
      name: activeName,
      meta: getLanguageText("Connecting to desktop summary", "デスクトップ要約へ接続中"),
      active: true,
      projectDir: activePath,
    }];
    if (detachedSurfaceSession) {
      items.push({
        name: detachedSurfaceSession.name,
        meta: detachedSurfaceSession.meta,
      });
    }
    items.push({
      name: getLanguageText("Add project", "プロジェクトを追加"),
      meta: getLanguageText("Paste a local project path", "ローカルプロジェクトのパスを貼り付け"),
      action: "add-project",
    });
    return items;
  }

  const board = desktopSummarySnapshot.board.summary;
  const inbox = desktopSummarySnapshot.inbox.summary;

  const items: SessionItem[] = [
    {
      name: activeName,
      meta: `${board.pane_count} panes · ${inbox.item_count} notifications · ${board.tasks_blocked} blocked`,
      active: true,
      projectDir: activePath,
    },
  ];

  for (const entry of projectSessionEntries) {
    if (activePath && normalizeProjectDirInput(entry.path) === normalizeProjectDirInput(activePath)) {
      continue;
    }
    items.push({
      name: entry.name,
      meta: entry.path,
      projectDir: entry.path,
    });
  }

  if (detachedSurfaceSession) {
    items.push({
      name: detachedSurfaceSession.name,
      meta: detachedSurfaceSession.meta,
    });
  }

  items.push({
    name: getLanguageText("Add project", "プロジェクトを追加"),
    meta: getLanguageText("Paste a local project path", "ローカルプロジェクトのパスを貼り付け"),
    action: "add-project",
  });

  return items;
}

function getRunProjections() {
  return desktopSummarySnapshot?.run_projections ?? [];
}

function getAvailableRunIds(snapshot: DesktopSummarySnapshot | null = desktopSummarySnapshot) {
  if (!snapshot) {
    return [] as string[];
  }

  return snapshot.run_projections.map((projection) => projection.run_id);
}

function resolveSelectedRunId(snapshot: DesktopSummarySnapshot | null = desktopSummarySnapshot, preferredRunId?: string | null) {
  const availableRunIds = getAvailableRunIds(snapshot);
  if (availableRunIds.length === 0) {
    return null;
  }

  if (preferredRunId && availableRunIds.includes(preferredRunId)) {
    return preferredRunId;
  }

  if (selectedRunId && availableRunIds.includes(selectedRunId)) {
    return selectedRunId;
  }

  return availableRunIds[0] ?? null;
}

function getRunProjectionByRunId(runId: string | null) {
  if (!runId) {
    return null;
  }
  return getRunProjections().find((projection) => projection.run_id === runId) ?? null;
}

function getPrimaryRunProjection() {
  const resolvedRunId = resolveSelectedRunId();
  return getRunProjectionByRunId(resolvedRunId) ?? getRunProjections()[0] ?? null;
}

function getComparePairKey(leftRunId: string, rightRunId: string) {
  return `${leftRunId}::${rightRunId}`;
}

function mirrorCompareRunsResult(result: DesktopCompareRunsResult): DesktopCompareRunsResult {
  return {
    ...result,
    left: result.right,
    right: result.left,
    left_only_changed_files: [...result.right_only_changed_files],
    right_only_changed_files: [...result.left_only_changed_files],
    confidence_delta: result.confidence_delta !== null ? -result.confidence_delta : null,
    differences: result.differences.map((difference) => ({
      ...difference,
      left: difference.right,
      right: difference.left,
    })),
  };
}

function getComparePeerProjection(
  selectedProjection: DesktopRunProjection,
  preferredRunId?: string | null,
) {
  const otherRuns = getRunProjections().filter(
    (projection) => projection.run_id !== selectedProjection.run_id,
  );
  if (otherRuns.length === 0) {
    return null;
  }

  if (preferredRunId) {
    const preferredPeer = otherRuns.find(
      (projection) => projection.run_id === preferredRunId,
    );
    if (preferredPeer) {
      return preferredPeer;
    }
  }

  const sameTaskPeer = otherRuns.find(
    (projection) =>
      Boolean(selectedProjection.task) &&
      projection.task === selectedProjection.task,
  );
  if (sameTaskPeer) {
    return sameTaskPeer;
  }

  const sameBranchPeer = otherRuns.find(
    (projection) =>
      Boolean(selectedProjection.branch) &&
      projection.branch === selectedProjection.branch,
  );

  return sameBranchPeer ?? null;
}

function getCompareWinnerLabel(result: DesktopCompareRunsResult) {
  if (!result.recommend.winning_run_id) {
    return "";
  }
  if (result.recommend.winning_run_id === result.left.run_id) {
    return result.left.label || result.left.run_id;
  }
  if (result.recommend.winning_run_id === result.right.run_id) {
    return result.right.label || result.right.run_id;
  }
  return result.recommend.winning_run_id;
}

function summarizeCompareDifferenceFields(
  result: DesktopCompareRunsResult,
  limit = 3,
) {
  const fields = Array.from(
    new Set(
      result.differences
        .map((difference) => difference.field)
        .filter((field) => Boolean(field)),
    ),
  );
  if (fields.length === 0) {
    return "";
  }
  if (fields.length <= limit) {
    return fields.join(", ");
  }
  return `${fields.slice(0, limit).join(", ")} +${fields.length - limit}`;
}

function getCompareConflictRadar(result: DesktopCompareRunsResult): {
  level: CompareRiskLevel;
  label: string;
  tone: SurfaceTone;
  hotspots: string[];
  summary: string;
} {
  const hotspots = result.shared_changed_files.filter((path) => Boolean(path));
  const requiresConsult = result.recommend.reconcile_consult;
  const riskyFields = new Set([
    "branch",
    "worktree",
    "env_fingerprint",
    "command_hash",
    "result",
    "changed_files",
  ]);
  const riskyDifferenceCount = result.differences.filter((difference) =>
    riskyFields.has(difference.field),
  ).length;
  const hasMaterialDrift = riskyDifferenceCount > 0 || result.differences.length >= 3;
  const hasUnrecommendableRun = !result.left.recommendable || !result.right.recommendable;
  const level: CompareRiskLevel =
    hasUnrecommendableRun || (requiresConsult && hotspots.length > 0)
      ? "high"
      : (hotspots.length > 0 || hasMaterialDrift ? "medium" : "low");
  const label = level === "high"
    ? "High"
    : (level === "medium" ? "Medium" : "Low");
  const tone: SurfaceTone =
    level === "high" ? "danger" : (level === "medium" ? "warning" : "success");
  const reason = hasUnrecommendableRun
    ? "run not recommendable"
    : (
      hotspots.length > 0
        ? `${hotspots.length} hotspot${hotspots.length === 1 ? "" : "s"}`
        : (hasMaterialDrift ? `${riskyDifferenceCount || result.differences.length} risk fields` : "no shared files")
    );

  return {
    level,
    label,
    tone,
    hotspots,
    summary: `${label} risk · ${reason}`,
  };
}

function setSelectedRun(runId: string | null) {
  selectedRunId = resolveSelectedRunId(desktopSummarySnapshot, runId);
}

function getProjectionSourceEntries(): SourceChange[] {
  const projections = getRunProjections();
  if (projections.length === 0) {
    return browserSourceChanges;
  }

  const entries: SourceChange[] = [];
  for (const projection of projections) {
    const changedFiles = projection.changed_files;
    const reviewState = projection.review_state || "unknown";
    const verification = projection.verification_outcome || "";
    const security = projection.security_blocked || "";
    const commitCandidate =
      reviewState === "PASS" &&
      (verification === "" || verification === "PASS") &&
      (security === "" || security === "ALLOW" || security === "PASS");
    const needsAttention =
      reviewState === "PENDING" ||
      reviewState === "FAIL" ||
      reviewState === "FAILED" ||
      security === "BLOCK" ||
      projection.next_action === "blocked";
    const risk: ChangeRisk = needsAttention ? "high" : commitCandidate ? "low" : "medium";

    for (const path of changedFiles) {
      const recentReason = projection.reasons?.[0];
      entries.push({
        path,
        summary: recentReason || projection.summary || projection.task || `Projected from ${projection.run_id}`,
        paneLabel: projection.label || projection.pane_id || "summary-stream",
        worktree: projection.worktree || "",
        status: "modified",
        risk,
        branch: projection.branch || "no branch",
        lines: `${changedFiles.length} changed in run`,
        commitCandidate,
        needsAttention,
        run: projection.run_id,
        review: reviewState,
      });
    }
  }

  return entries;
}

function findSourceChangeByKey(key: string) {
  return pickSourceChangeKeyCandidate([getVisibleSourceChanges(), getProjectionSourceEntries()], key);
}

function findSourceChangeByPath(path: string, worktree = "") {
  return (
    pickEditorPathCandidate(getVisibleSourceChanges(), path, worktree, selectedEditorKey) ??
    pickEditorPathCandidate(getProjectionSourceEntries(), path, worktree, selectedEditorKey)
  );
}

function createStandaloneEditorTarget(path: string, worktree = ""): EditorTarget {
  const key = getEditorFileKey(path, worktree);
  return {
    key,
    path,
    summary: `Project file preview · ${path.split("/").pop() ?? path}`,
    worktree,
    origin: "explorer",
    modified: false,
  };
}

function getFallbackExplorerTargets() {
  return fallbackExplorerPaths.map((path) => createStandaloneEditorTarget(path));
}

function normalizeExplorerEntries(entries: DesktopExplorerEntry[]) {
  return entries
    .map((entry) => ({
      path: entry.path.replace(/\\/g, "/").replace(/^\/+/, "").replace(/\/+$/, ""),
      kind: entry.kind === "directory" ? "directory" as const : "file" as const,
      has_children: entry.has_children ?? entry.hasChildren,
      ignored: Boolean(entry.ignored),
    }))
    .filter((entry) => entry.path.length > 0);
}

async function loadBrowserProjectExplorerEntries(path?: string) {
  const params = new URLSearchParams();
  if (path) {
    params.set("path", path);
  }
  const query = params.toString();
  const response = await fetch(`/__winsmux_project_files${query ? `?${query}` : ""}`, {
    headers: { Accept: "application/json" },
  });
  if (!response.ok) {
    throw new Error(`Project explorer endpoint returned ${response.status}`);
  }
  const payload = await response.json() as { entries?: DesktopExplorerEntry[] };
  return normalizeExplorerEntries(payload.entries ?? []);
}

function mergeProjectExplorerEntries(entries: DesktopExplorerEntry[]) {
  const byPath = new Map(projectExplorerEntries.map((entry) => [entry.path, entry]));
  for (const entry of entries) {
    const existing = byPath.get(entry.path);
    byPath.set(entry.path, {
      ...existing,
      ...entry,
      has_children: existing?.has_children || entry.has_children,
      hasChildren: existing?.hasChildren || entry.hasChildren,
      ignored: existing?.ignored || entry.ignored,
    });
  }
  projectExplorerEntries = Array.from(byPath.values());
}

async function refreshProjectExplorerEntries() {
  if (projectExplorerRefreshInFlight) {
    return projectExplorerRefreshInFlight;
  }

  projectExplorerRefreshInFlight = (async () => {
    try {
      const entries = isTauri()
        ? normalizeExplorerEntries((await getDesktopExplorerEntries(undefined, getActiveProjectDirPayload())).entries)
        : await loadBrowserProjectExplorerEntries();
      projectExplorerEntries = entries;
      projectExplorerLoaded = true;
      projectExplorerLoadedFolderPaths.clear();
      projectExplorerLoadedFolderPaths.add("");
      projectExplorerFolderLoads.clear();
      expandedExplorerFolders.clear();
      renderExplorer();
    } catch (error) {
      projectExplorerLoaded = true;
      console.warn("Failed to load project explorer entries", error);
      renderExplorer();
    } finally {
      projectExplorerRefreshInFlight = null;
    }
  })();

  return projectExplorerRefreshInFlight;
}

async function loadBrowserProjectExplorerFolder(path: string) {
  const normalizedPath = normalizeSourcePath(path);
  if (isTauri() || !normalizedPath || projectExplorerLoadedFolderPaths.has(normalizedPath)) {
    return;
  }
  const existingLoad = projectExplorerFolderLoads.get(normalizedPath);
  if (existingLoad) {
    return existingLoad;
  }

  const load = (async () => {
    try {
      const entries = await loadBrowserProjectExplorerEntries(normalizedPath);
      mergeProjectExplorerEntries(entries);
      projectExplorerLoadedFolderPaths.add(normalizedPath);
      renderExplorer();
    } catch (error) {
      console.warn("Failed to load project explorer folder", normalizedPath, error);
    } finally {
      projectExplorerFolderLoads.delete(normalizedPath);
    }
  })();

  projectExplorerFolderLoads.set(normalizedPath, load);
  return load;
}

function normalizeBrowserSourceChange(change: Partial<SourceChange>): SourceChange | null {
  const path = normalizeSourcePath(change.path);
  if (!path) {
    return null;
  }
  const status = change.status === "added" || change.status === "deleted" || change.status === "renamed"
    ? change.status
    : "modified";
  return {
    path,
    summary: change.summary || `${status} ${path}`,
    paneLabel: change.paneLabel || "working tree",
    worktree: change.worktree || ".",
    status,
    risk: change.risk === "medium" || change.risk === "high" ? change.risk : "low",
    branch: change.branch || "",
    lines: change.lines || getSourceStatusLabel(status),
    commitCandidate: change.commitCandidate ?? true,
    needsAttention: change.needsAttention ?? false,
    run: change.run || "working-tree",
    review: change.review || "local",
    staged: Boolean(change.staged),
  };
}

function normalizeBrowserSourceGraphItem(item: Partial<BrowserSourceGraphItem>): BrowserSourceGraphItem | null {
  const runId = `${item.run_id || ""}`.trim();
  if (!runId) {
    return null;
  }
  return {
    run_id: runId,
    short_sha: `${item.short_sha || runId.slice(0, 7)}`.trim(),
    parents: Array.isArray(item.parents)
      ? item.parents.map((parent) => `${parent || ""}`.trim()).filter((parent) => parent)
      : [],
    task: `${item.task || runId}`.trim(),
    branch: `${item.branch || ""}`.trim(),
    refs: Array.isArray(item.refs) ? item.refs.map((ref) => `${ref}`.trim()).filter((ref) => ref) : [],
    author: `${item.author || ""}`.trim(),
    relative_time: `${item.relative_time || ""}`.trim(),
    committed_at: `${item.committed_at || ""}`.trim(),
    changed_files: Array.isArray(item.changed_files) ? item.changed_files.map((path) => `${path}`.trim()).filter((path) => path) : [],
  };
}

async function refreshBrowserSourceControl() {
  if (isTauri()) {
    return;
  }
  if (browserSourceRefreshInFlight) {
    return browserSourceRefreshInFlight;
  }

  browserSourceRefreshInFlight = (async () => {
    try {
      const response = await fetch("/__winsmux_source_control", {
        headers: { Accept: "application/json" },
      });
      if (!response.ok) {
        throw new Error(`Source control endpoint returned ${response.status}`);
      }
      const payload = await response.json() as {
        changes?: Array<Partial<SourceChange>>;
        graph?: BrowserSourceGraphItem[];
      };
      browserSourceChanges = (payload.changes ?? [])
        .map(normalizeBrowserSourceChange)
        .filter((change): change is SourceChange => Boolean(change));
      browserSourceGraphItems = (payload.graph ?? [])
        .map(normalizeBrowserSourceGraphItem)
        .filter((item): item is BrowserSourceGraphItem => Boolean(item));
      renderExplorer();
      renderSourceSummary();
      renderSourceEntries();
      renderSourceControlView();
      renderContextPanel();
      syncActivityButtons();
    } catch (error) {
      console.warn("Failed to load browser source control snapshot", error);
    } finally {
      browserSourceRefreshInFlight = null;
    }
  })();

  return browserSourceRefreshInFlight;
}

async function loadBrowserEditorFile(path: string): Promise<DesktopEditorFilePayload> {
  const response = await fetch(`/__winsmux_project_file?path=${encodeURIComponent(path)}`, {
    headers: { Accept: "application/json" },
  });
  if (!response.ok) {
    throw new Error(`Project file endpoint returned ${response.status}`);
  }
  return await response.json() as DesktopEditorFilePayload;
}

function getExplorerRootLabel(worktreeKey: string) {
  if (worktreeKey && worktreeKey !== ".") {
    return getWorktreeLabel(worktreeKey).toUpperCase();
  }
  const activeProject = getActiveProjectDirPayload();
  const normalized = activeProject?.replace(/\\/g, "/").replace(/\/+$/, "");
  const name = normalized?.split("/").filter(Boolean).pop();
  return (name || "winsmux").toUpperCase();
}

function compareProjectExplorerNodes(left: ProjectExplorerTreeNode, right: ProjectExplorerTreeNode) {
  const leftIsFile = left.kind === "file";
  const rightIsFile = right.kind === "file";
  if (leftIsFile !== rightIsFile) {
    return leftIsFile ? 1 : -1;
  }
  return left.label.localeCompare(right.label, undefined, { sensitivity: "base" });
}

function getProjectExplorerChildKey(label: string) {
  return label.toLocaleLowerCase();
}

function createProjectExplorerTreeNode(
  label: string,
  path: string,
  kind: "directory" | "file",
  hasChildren?: boolean,
  ignored?: boolean,
): ProjectExplorerTreeNode {
  return {
    label,
    path,
    kind,
    hasChildren,
    ignored,
    children: new Map<string, ProjectExplorerTreeNode>(),
  };
}

function buildProjectExplorerTree(entries: DesktopExplorerEntry[]) {
  const rootChildren = new Map<string, ProjectExplorerTreeNode>();

  for (const entry of entries) {
    const segments = entry.path.split("/").filter(Boolean);
    let currentChildren = rootChildren;
    let currentPath = "";

    segments.forEach((segment, index) => {
      currentPath = currentPath ? `${currentPath}/${segment}` : segment;
      const isFinalSegment = index === segments.length - 1;
      const nodeKind = isFinalSegment ? entry.kind : "directory";
      const childKey = getProjectExplorerChildKey(segment);
      let node = currentChildren.get(childKey);

      if (!node) {
        node = createProjectExplorerTreeNode(segment, currentPath, nodeKind, isFinalSegment ? entry.has_children : true, isFinalSegment ? entry.ignored : false);
        currentChildren.set(childKey, node);
      } else if (nodeKind === "directory") {
        node.kind = "directory";
      }
      if (node.kind === "directory") {
        node.hasChildren = node.hasChildren || !isFinalSegment || entry.has_children;
      }
      if (isFinalSegment && entry.ignored) {
        node.ignored = true;
      }

      currentChildren = node.children;
    });
  }

  return rootChildren;
}

function appendProjectExplorerTreeItems(
  items: ExplorerItem[],
  nodes: Iterable<ProjectExplorerTreeNode>,
  worktreeKey: string,
  depth: number,
  sourceChangesByPath: Map<string, SourceChange>,
  changedFolderKeys: Set<string>,
) {
  for (const node of Array.from(nodes).sort(compareProjectExplorerNodes)) {
    if (node.kind === "directory") {
      const folderKey = getExplorerFolderKey(worktreeKey, node.path);
      const hasChildren = node.children.size > 0 || node.hasChildren === true;
      const open = hasChildren && isExplorerFolderOpen(folderKey, depth);
      items.push({
        label: node.label,
        depth,
        kind: "folder",
        folderKey,
        path: node.path,
        open,
        hasChildren,
        worktree: worktreeKey,
        hasSourceChanges: changedFolderKeys.has(folderKey),
        ignored: node.ignored,
      });
      if (open) {
        appendProjectExplorerTreeItems(
          items,
          node.children.values(),
          worktreeKey,
          depth + 1,
          sourceChangesByPath,
          changedFolderKeys,
        );
      }
      continue;
    }

    const target = createStandaloneEditorTarget(node.path);
    const sourceChange = sourceChangesByPath.get(normalizeSourcePath(node.path));
    items.push({
      label: node.label,
      meta: sourceChange?.summary ?? target.summary,
      depth,
      kind: "file",
      path: node.path,
      worktree: target.worktree,
      active: (sourceChange ? getSourceChangeKey(sourceChange) : target.key) === selectedEditorKey,
      sourceStatus: sourceChange?.status,
      hasSourceChanges: Boolean(sourceChange),
      iconKind: getExplorerFileIconKind(node.path, node.label),
      ignored: node.ignored,
    });
  }
}

function getFilesystemExplorerItems() {
  const worktreeKey = ".";
  const worktreeFolderKey = getExplorerFolderKey(worktreeKey, "");
  const worktreeOpen = isExplorerFolderOpen(worktreeFolderKey, 0);
  const sourceChangesByPath = getSourceChangesByNormalizedPath();
  const changedFolderKeys = getChangedExplorerFolderKeys(worktreeKey);
  const items: ExplorerItem[] = [{
    label: getExplorerRootLabel(worktreeKey),
    depth: 0,
    kind: "folder",
    folderKey: worktreeFolderKey,
    open: worktreeOpen,
    worktree: worktreeKey,
    hasSourceChanges: changedFolderKeys.has(worktreeFolderKey),
  }];

  if (!worktreeOpen) {
    return items;
  }

  const tree = buildProjectExplorerTree(projectExplorerEntries);
  appendProjectExplorerTreeItems(
    items,
    tree.values(),
    worktreeKey,
    1,
    sourceChangesByPath,
    changedFolderKeys,
  );

  return items;
}

function getExplorerItems() {
  if (projectExplorerEntries.length > 0) {
    return getFilesystemExplorerItems();
  }

  const changedFolderKeys = getChangedExplorerFolderKeys(".");
  const targets = new Map<string, EditorTarget>();
  for (const entry of getProjectionSourceEntries()) {
    const target = getEditorTargetForSourceChange(entry);
    if (target) {
      targets.set(target.key, target);
    }
  }
  for (const [key, target] of desktopStandaloneEditorTargets) {
    if (!targets.has(key)) {
      targets.set(key, target);
    }
  }
  if (targets.size === 0) {
    for (const target of getFallbackExplorerTargets()) {
      targets.set(target.key, target);
    }
  }

  const items: ExplorerItem[] = [];
  const seenFolders = new Set<string>();

  const worktreeGroups = new Map<string, EditorTarget[]>();
  for (const target of Array.from(targets.values()).sort((left, right) => left.path.localeCompare(right.path))) {
    const worktreeKey = target.worktree || ".";
    const group = worktreeGroups.get(worktreeKey) ?? [];
    group.push(target);
    worktreeGroups.set(worktreeKey, group);
  }

  for (const [worktreeKey, group] of Array.from(worktreeGroups.entries()).sort((left, right) =>
    getWorktreeLabel(left[0]).localeCompare(getWorktreeLabel(right[0])),
  )) {
    const worktreeFolderKey = getExplorerFolderKey(worktreeKey, "");
    const worktreeOpen = isExplorerFolderOpen(worktreeFolderKey, 0);
    items.push({
      label: getExplorerRootLabel(worktreeKey),
      depth: 0,
      kind: "folder",
      folderKey: worktreeFolderKey,
      open: worktreeOpen,
      worktree: worktreeKey,
      hasSourceChanges: changedFolderKeys.has(worktreeFolderKey),
    });

    if (!worktreeOpen) {
      continue;
    }

    for (const target of group) {
      const normalizedPath = target.path.replace(/\\/g, "/");
      const segments = normalizedPath.split("/").filter(Boolean);
      let currentPath = "";
      let parentCollapsed = false;
      segments.forEach((segment, index) => {
        if (parentCollapsed) {
          return;
        }
        currentPath = currentPath ? `${currentPath}/${segment}` : segment;
        const folderKey = `${worktreeKey}::${currentPath}`;
        const depth = index + 1;
        const isFile = index === segments.length - 1;
        if (isFile) {
          const sourceChange = target.sourceChange;
          items.push({
            label: segment,
            meta: target.summary,
            depth,
            kind: "file",
            path: target.path,
            worktree: target.worktree,
            active: target.key === selectedEditorKey,
            sourceStatus: sourceChange?.status,
            hasSourceChanges: Boolean(sourceChange),
            iconKind: getExplorerFileIconKind(target.path, segment),
          });
          return;
        }

        if (!isExplorerFolderOpen(folderKey, depth)) {
          parentCollapsed = true;
        }
        if (seenFolders.has(folderKey)) {
          return;
        }

        seenFolders.add(folderKey);
        items.push({
          label: segment,
          depth,
          kind: "folder",
          folderKey,
          open: isExplorerFolderOpen(folderKey, depth),
          worktree: target.worktree,
          hasSourceChanges: changedFolderKeys.has(folderKey),
        });
      });
    }
  }

  return items;
}

function getEditorTargetForSourceChange(sourceChange: SourceChange | undefined): EditorTarget | null {
  if (!sourceChange) {
    return null;
  }

  return {
    key: getSourceChangeKey(sourceChange),
    path: sourceChange.path,
    summary: sourceChange.summary,
    worktree: sourceChange.worktree,
    origin: "context",
    modified: sourceChange.status !== "deleted",
    sourceChange,
  };
}

function getPreferredEditorTargetForSelectedRun(): EditorTarget | null {
  const runId = getSelectedRunId();
  if (!runId) {
    return null;
  }

  const runChanges = [
    ...getVisibleSourceChanges().filter((entry) => entry.run === runId),
    ...getProjectionSourceEntries().filter((entry) => entry.run === runId),
  ];
  const dedupedRunChanges = Array.from(
    new Map(runChanges.map((entry) => [getSourceChangeKey(entry), entry])).values(),
  );

  const selectedChange = dedupedRunChanges.find((entry) => getSourceChangeKey(entry) === selectedEditorKey);
  if (selectedChange) {
    return getEditorTargetForSourceChange(selectedChange);
  }

  if (dedupedRunChanges.length > 0) {
    return getEditorTargetForSourceChange(dedupedRunChanges[0]);
  }

  const projection = getRunProjectionByRunId(runId);
  const explainPayload = desktopExplainCache.get(runId) ?? null;
  const candidatePaths = [
    ...(explainPayload?.evidence_digest.changed_files ?? []),
    ...(projection?.changed_files ?? []),
    ...(explainPayload?.run.changed_files ?? []),
  ];
  const worktree = projection?.worktree || explainPayload?.run.worktree || "";

  for (const path of candidatePaths) {
    const existingChange = findSourceChangeByPath(path, worktree);
    if (existingChange) {
      return getEditorTargetForSourceChange(existingChange);
    }

    if (path) {
      const target = createStandaloneEditorTarget(path, worktree);
      desktopStandaloneEditorTargets.set(target.key, target);
      return target;
    }
  }

  return null;
}

function getEditorTargetByKey(key: string): EditorTarget | null {
  const standaloneTarget = desktopStandaloneEditorTargets.get(key);
  if (standaloneTarget) {
    return standaloneTarget;
  }

  const sourceChange = findSourceChangeByKey(key);
  if (sourceChange) {
    return getEditorTargetForSourceChange(sourceChange);
  }

  return null;
}

function getPaneSourceFilter(label: string): SourceFilter {
  return `pane:${label}`;
}

function getPaneLabelFromSourceFilter(filter: SourceFilter) {
  if (!filter.startsWith("pane:")) {
    return null;
  }

  return filter.slice("pane:".length);
}

function getWorktreeLabel(worktree: string | undefined) {
  if (!worktree || worktree === "." || worktree === "./") {
    return getLanguageText("Project root", "プロジェクトルート");
  }

  const normalized = worktree.replace(/\\/g, "/").replace(/\/+$/, "");
  const segments = normalized.split("/").filter(Boolean);
  return segments[segments.length - 1] || normalized;
}

function getExplorerFolderKey(worktree: string | undefined, path: string) {
  return `${worktree || "."}::${path}`;
}

function normalizeSourcePath(path: string | undefined) {
  return (path ?? "").replace(/\\/g, "/").replace(/^\.\//, "").replace(/^\/+/, "").replace(/\/+$/, "");
}

function getSourceChangesByNormalizedPath() {
  const changes = new Map<string, SourceChange>();
  for (const change of getProjectionSourceEntries()) {
    const key = normalizeSourcePath(change.path);
    if (key) {
      changes.set(key, change);
    }
  }
  return changes;
}

function getChangedExplorerFolderKeys(worktree = ".") {
  const keys = new Set<string>();
  for (const change of getProjectionSourceEntries()) {
    const segments = normalizeSourcePath(change.path).split("/").filter(Boolean);
    keys.add(getExplorerFolderKey(worktree, ""));
    for (let index = 1; index < segments.length; index += 1) {
      keys.add(getExplorerFolderKey(worktree, segments.slice(0, index).join("/")));
    }
  }
  return keys;
}

function getExplorerFileIconKind(path: string | undefined, label: string): ExplorerIconKind {
  const normalized = normalizeSourcePath(path || label).toLowerCase();
  const fileName = normalized.split("/").pop() || label.toLowerCase();
  if (fileName === "license") {
    return "license";
  }
  if (fileName === "cargo.lock" || fileName.endsWith(".lock")) {
    return "lock";
  }
  if (fileName === "cargo.toml" || fileName.endsWith(".toml")) {
    return "toml";
  }
  if (fileName.endsWith(".md") || fileName.endsWith(".markdown")) {
    return "markdown";
  }
  if (fileName.endsWith(".ts") || fileName.endsWith(".tsx")) {
    return "typescript";
  }
  if (fileName.endsWith(".js") || fileName.endsWith(".mjs") || fileName.endsWith(".cjs")) {
    return "javascript";
  }
  if (fileName.endsWith(".json")) {
    return "json";
  }
  if (fileName.endsWith(".rs")) {
    return "rust";
  }
  if (fileName.endsWith(".ps1") || fileName.endsWith(".psm1") || fileName.endsWith(".psd1")) {
    return "powershell";
  }
  if (fileName.endsWith(".yaml") || fileName.endsWith(".yml")) {
    return "yaml";
  }
  if (fileName.endsWith(".xml")) {
    return "xml";
  }
  if (fileName.endsWith(".png") || fileName.endsWith(".jpg") || fileName.endsWith(".jpeg") || fileName.endsWith(".webp") || fileName.endsWith(".gif") || fileName.endsWith(".svg")) {
    return "image";
  }
  if (fileName.startsWith(".") || fileName.endsWith(".conf") || fileName.endsWith(".config")) {
    return "config";
  }
  return "text";
}

function getExplorerFileIconLabel(iconKind: ExplorerIconKind) {
  switch (iconKind) {
    case "config":
      return "⚙";
    case "image":
      return "▧";
    case "javascript":
      return "JS";
    case "json":
      return "{}";
    case "license":
      return "§";
    case "lock":
      return "●";
    case "markdown":
      return "↓";
    case "powershell":
      return ">";
    case "rust":
      return "RS";
    case "toml":
      return "⚙";
    case "typescript":
      return "TS";
    case "xml":
      return "<>";
    case "yaml":
      return "!";
    case "text":
    default:
      return "";
  }
}

function isExplorerFolderOpen(folderKey: string, depth: number) {
  if (depth === 0) {
    return !collapsedExplorerFolders.has(folderKey);
  }
  return expandedExplorerFolders.has(folderKey);
}

function toggleExplorerFolder(folderKey: string, depth: number, path?: string, worktree?: string) {
  if (depth === 0) {
    if (collapsedExplorerFolders.has(folderKey)) {
      collapsedExplorerFolders.delete(folderKey);
    } else {
      collapsedExplorerFolders.add(folderKey);
    }
    renderExplorer();
    return;
  }

  if (expandedExplorerFolders.has(folderKey)) {
    expandedExplorerFolders.delete(folderKey);
  } else {
    expandedExplorerFolders.add(folderKey);
    if (worktree === "." && path) {
      void loadBrowserProjectExplorerFolder(path);
    }
  }
  renderExplorer();
}

function closeExplorerContextMenu() {
  explorerContextMenu?.remove();
  explorerContextMenu = null;
}

function getExplorerAbsolutePath(item: ExplorerItem) {
  const projectDir = getActiveProjectDirPayload()?.replace(/[\\/]+$/, "") ?? "";
  const relativePath = item.path?.replace(/\//g, "\\") ?? "";
  if (!projectDir) {
    return relativePath || item.label;
  }
  if (!relativePath) {
    return projectDir;
  }
  return `${projectDir}\\${relativePath}`;
}

function getExplorerRelativePath(item: ExplorerItem) {
  return item.path || ".";
}

function addExplorerContextMenuItem(
  menu: HTMLElement,
  label: string,
  action: () => void | Promise<void>,
  options?: { shortcut?: string; disabled?: boolean },
) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "explorer-context-menu-item";
  button.disabled = Boolean(options?.disabled);
  const labelElement = document.createElement("span");
  labelElement.textContent = label;
  button.appendChild(labelElement);
  if (options?.shortcut) {
    const shortcut = document.createElement("span");
    shortcut.className = "explorer-context-menu-shortcut";
    shortcut.textContent = options.shortcut;
    button.appendChild(shortcut);
  }
  button.addEventListener("click", async () => {
    if (button.disabled) {
      return;
    }
    closeExplorerContextMenu();
    await action();
  });
  menu.appendChild(button);
}

function addExplorerContextMenuSeparator(menu: HTMLElement) {
  const separator = document.createElement("div");
  separator.className = "explorer-context-menu-separator";
  menu.appendChild(separator);
}

function showExplorerContextMenu(event: MouseEvent, item: ExplorerItem) {
  event.preventDefault();
  event.stopPropagation();
  closeExplorerContextMenu();

  const menu = document.createElement("div");
  menu.className = "explorer-context-menu";
  menu.setAttribute("role", "menu");
  menu.addEventListener("pointerdown", (pointerEvent) => {
    pointerEvent.stopPropagation();
  });

  addExplorerContextMenuItem(
    menu,
    getLanguageText("Open", "開く"),
    () => {
      if (item.kind === "folder" && item.folderKey) {
        toggleExplorerFolder(item.folderKey, item.depth, item.path, item.worktree);
        return;
      }
      return openEditorPath(item.path, item.worktree ?? "");
    },
    { disabled: item.kind === "folder" && item.hasChildren === false },
  );
  addExplorerContextMenuItem(
    menu,
    getLanguageText("Open to Side", "横に開く"),
    async () => {
      await openEditorPath(item.path, item.worktree ?? "");
      await openEditorSurfacePopout();
    },
    { disabled: item.kind !== "file" || !item.path },
  );
  addExplorerContextMenuSeparator(menu);
  addExplorerContextMenuItem(menu, getLanguageText("Copy Path", "パスのコピー"), () => copyTextToClipboard(getExplorerAbsolutePath(item)), { shortcut: "Shift+Alt+C" });
  addExplorerContextMenuItem(menu, getLanguageText("Copy Relative Path", "相対パスをコピー"), () => copyTextToClipboard(getExplorerRelativePath(item)), { shortcut: "Ctrl+K Ctrl+Shift+C" });
  addExplorerContextMenuSeparator(menu);
  addExplorerContextMenuItem(menu, getLanguageText("Rename...", "名前の変更..."), () => undefined, { shortcut: "F2", disabled: true });
  addExplorerContextMenuItem(menu, getLanguageText("Delete", "削除"), () => undefined, { shortcut: "Del", disabled: true });

  document.body.appendChild(menu);
  const menuRect = menu.getBoundingClientRect();
  const left = Math.min(event.clientX, window.innerWidth - menuRect.width - 8);
  const top = Math.min(event.clientY, window.innerHeight - menuRect.height - 8);
  menu.style.left = `${Math.max(8, left)}px`;
  menu.style.top = `${Math.max(8, top)}px`;
  explorerContextMenu = menu;

  window.setTimeout(() => {
    document.addEventListener("pointerdown", closeExplorerContextMenu, { once: true });
  }, 0);
}

function showSourceControlActionsMenu(event: MouseEvent, scope: "changes" | "graph") {
  event.preventDefault();
  event.stopPropagation();
  closeExplorerContextMenu();

  const menu = document.createElement("div");
  menu.className = "explorer-context-menu source-control-actions-menu";
  menu.setAttribute("role", "menu");
  menu.addEventListener("pointerdown", (pointerEvent) => {
    pointerEvent.stopPropagation();
  });

  addExplorerContextMenuItem(
    menu,
    getLanguageText("Refresh", "更新"),
    () => {
      void refreshBrowserSourceControl();
      requestDesktopSummaryRefresh(undefined, 0);
    },
  );
  if (scope === "changes") {
    addExplorerContextMenuItem(
      menu,
      getLanguageText("Commit all", "すべてコミット"),
      () => submitSourceControlCommitRequest(),
      { disabled: sourceControlCommitMessage.trim().length === 0 || getVisibleSourceChanges().length === 0 },
    );
    addExplorerContextMenuItem(
      menu,
      getLanguageText("Open selected file", "選択中のファイルを開く"),
      () => openEditorSourceChange(getPrimarySourceChange(getVisibleSourceChanges())),
      { disabled: getVisibleSourceChanges().length === 0 },
    );
  } else {
    addExplorerContextMenuItem(
      menu,
      getLanguageText("Refresh graph", "グラフを更新"),
      () => {
        void refreshBrowserSourceControl();
        requestDesktopSummaryRefresh(undefined, 0);
      },
    );
    addExplorerContextMenuItem(
      menu,
      getLanguageText("Show selected run details", "選択中の実行詳細を表示"),
      () => setContextPanel(true),
      { disabled: !getSelectedRunId() },
    );
  }
  addExplorerContextMenuSeparator(menu);
  addExplorerContextMenuItem(menu, getLanguageText("Command palette...", "操作パレット..."), () => openCommandBar(), { shortcut: "Ctrl+K" });

  document.body.appendChild(menu);
  const trigger = event.currentTarget instanceof HTMLElement ? event.currentTarget.getBoundingClientRect() : null;
  const menuRect = menu.getBoundingClientRect();
  const left = trigger ? trigger.right - menuRect.width : event.clientX;
  const top = trigger ? trigger.bottom + 4 : event.clientY;
  menu.style.left = `${Math.max(8, Math.min(left, window.innerWidth - menuRect.width - 8))}px`;
  menu.style.top = `${Math.max(8, Math.min(top, window.innerHeight - menuRect.height - 8))}px`;
  explorerContextMenu = menu;

  window.setTimeout(() => {
    document.addEventListener("pointerdown", closeExplorerContextMenu, { once: true });
  }, 0);
}

function renderExplorer() {
  const root = document.getElementById("explorer-list");
  if (!root) {
    return;
  }

  const explorerItems = getExplorerItems();
  root.innerHTML = "";
  if (explorerItems.length === 0) {
    const empty = document.createElement("div");
    empty.className = "sidebar-row";
    const title = document.createElement("span");
    title.className = "sidebar-row-title";
    title.textContent = projectExplorerLoaded
      ? getLanguageText("No files", "ファイルはありません")
      : getLanguageText("Loading files", "ファイルを読み込み中");
    empty.append(title);
    root.appendChild(empty);
    return;
  }

  for (const item of explorerItems) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `sidebar-row sidebar-tree-row is-${item.kind} depth-${item.depth} ${item.active ? "is-active" : ""}`;
    button.classList.toggle("has-source-changes", Boolean(item.hasSourceChanges));
    button.classList.toggle("is-ignored", Boolean(item.ignored));
    if (item.sourceStatus) {
      button.dataset.sourceStatus = item.sourceStatus;
    }
    if (item.iconKind) {
      button.dataset.iconKind = item.iconKind;
    }
    button.style.setProperty("--tree-indent", `${item.depth * 12}px`);
    const canToggleFolder = item.kind === "folder" && Boolean(item.folderKey) && item.hasChildren !== false;
    button.classList.toggle("is-empty-folder", item.kind === "folder" && !canToggleFolder);
    const marker = item.kind === "folder" && canToggleFolder ? (item.open ? "⌄" : "›") : "";
    const markerElement = document.createElement("span");
    markerElement.className = "sidebar-tree-marker";
    markerElement.textContent = marker;
    const iconElement = document.createElement("span");
    iconElement.className = "sidebar-file-icon";
    if (item.kind === "file") {
      const iconKind = item.iconKind ?? getExplorerFileIconKind(item.path, item.label);
      iconElement.dataset.iconKind = iconKind;
      iconElement.textContent = getExplorerFileIconLabel(iconKind);
    }
    const title = document.createElement("span");
    title.className = "sidebar-row-title";
    title.textContent = item.label;
    const sourceStatus = document.createElement("span");
    sourceStatus.className = "sidebar-source-status";
    sourceStatus.textContent = item.sourceStatus ? getSourceStatusLabel(item.sourceStatus) : (item.kind === "folder" && item.hasSourceChanges ? "•" : "");
    if (item.sourceStatus) {
      sourceStatus.title = getLanguageText(`Git status: ${getSourceStatusLabel(item.sourceStatus)}`, `Git 状態: ${getSourceStatusLabel(item.sourceStatus)}`);
    }
    button.append(markerElement, iconElement, title, sourceStatus);
    button.title = [
      item.path,
      item.meta,
      item.ignored ? getLanguageText("Ignored by Git", "Git の無視対象") : "",
    ].filter(Boolean).join("\n");
    button.addEventListener("contextmenu", (event) => {
      showExplorerContextMenu(event, item);
    });
    if (item.kind === "folder" && item.folderKey && canToggleFolder) {
      const folderKey = item.folderKey;
      button.setAttribute("aria-expanded", item.open ? "true" : "false");
      button.addEventListener("click", () => {
        toggleExplorerFolder(folderKey, item.depth, item.path, item.worktree);
      });
    }
    if (item.kind === "file" && item.path) {
      const itemPath = item.path;
      const itemWorktree = item.worktree ?? "";
      button.addEventListener("click", () => {
        void openEditorPath(itemPath, itemWorktree);
      });
    }
    root.appendChild(button);
  }
}

function renderOpenEditors() {
  const root = document.getElementById("open-editors-list");
  if (!root) {
    return;
  }

  root.innerHTML = "";
  const editors = getEditorFiles();
  if (editors.length === 0) {
    const empty = document.createElement("div");
    empty.className = "sidebar-row";
    empty.innerHTML =
      `<span class="sidebar-row-title">${getLanguageText("No open editors", "開いているエディタはありません")}</span>` +
      `<span class="sidebar-row-meta">${getLanguageText("Open a file from Explorer or Source Control.", "エクスプローラーかソース管理からファイルを開いてください。")}</span>`;
    root.appendChild(empty);
    return;
  }

  for (const editor of editors) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `sidebar-row ${editor.key === selectedEditorKey && editorSurfaceOpen ? "is-active" : ""}`;
    const target = getEditorTargetByKey(editor.key);
    const worktreeLabel = getWorktreeLabel(target?.worktree);
    button.innerHTML =
      `<span class="sidebar-row-title">${editor.path.split("/").pop() ?? editor.path}</span>` +
      `<span class="sidebar-row-meta">${worktreeLabel} · ${editor.summary}</span>`;
    button.addEventListener("click", () => {
      void openEditorTarget(getEditorTargetByKey(editor.key));
    });
    root.appendChild(button);
  }
}

function renderSourceSummary() {
  const root = document.getElementById("source-summary-list");
  if (!root) {
    return;
  }

  const activeEntries = getProjectionSourceEntries();
  const visibleChanges = getVisibleSourceChanges();
  const entryCount = visibleChanges.length;
  const attentionCount = visibleChanges.filter((item) => item.needsAttention).length;
  const commitCandidates = visibleChanges.filter((item) => item.commitCandidate).length;
  const summaryItems = [
    { label: getLanguageText("Selected scope", "選択範囲"), value: getSourceFilterLabel(activeSourceFilter) },
    { label: getLanguageText("Projected", "投影"), value: getLanguageText(`${activeEntries.length} files`, `${activeEntries.length} ファイル`) },
    { label: getLanguageText("Changed", "変更"), value: getLanguageText(`${entryCount} files`, `${entryCount} ファイル`) },
    { label: getLanguageText("Ready", "準備済み"), value: getLanguageText(`${commitCandidates} candidate${commitCandidates === 1 ? "" : "s"}`, `${commitCandidates} 件`) },
    { label: getLanguageText("Risk", "リスク"), value: getLanguageText(`${attentionCount} attention`, `${attentionCount} 要確認`) },
  ];

  root.innerHTML = "";
  for (const item of summaryItems) {
    const row = document.createElement("div");
    row.className = "sidebar-summary-row";
    row.innerHTML = `<span class="sidebar-summary-label">${item.label}</span><span class="sidebar-summary-value">${item.value}</span>`;
    root.appendChild(row);
  }
}

function renderSourceEntries() {
  const root = document.getElementById("source-entry-list");
  if (!root) {
    return;
  }

  const activeEntries = getProjectionSourceEntries();
  root.innerHTML = "";
  const entryItems: Array<{ label: string; value: string; filter: SourceFilter; tone?: SurfaceTone }> = [
    { label: getLanguageText("Commit candidates", "コミット候補"), value: getLanguageText(`${activeEntries.filter((item) => item.commitCandidate).length} ready`, `${activeEntries.filter((item) => item.commitCandidate).length} 件`), tone: "success", filter: "candidates" },
    { label: getLanguageText("Needs attention", "要確認"), value: getLanguageText(`${activeEntries.filter((item) => item.needsAttention).length} blocker`, `${activeEntries.filter((item) => item.needsAttention).length} 件`), tone: "danger", filter: "attention" },
  ];
  const paneLabels = [...new Set(activeEntries.map((item) => item.paneLabel).filter((item) => item))].sort((left, right) =>
    left.localeCompare(right),
  );
  for (const paneLabel of paneLabels) {
    const count = activeEntries.filter((item) => item.paneLabel === paneLabel).length;
    entryItems.push({
      label: paneLabel,
      value: getLanguageText(`${count} files`, `${count} ファイル`),
      filter: getPaneSourceFilter(paneLabel),
    });
  }

  for (const item of entryItems) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `sidebar-row source-entry-row ${activeSourceFilter === item.filter ? "is-active" : ""}`;
    button.dataset.tone = item.tone ?? "default";
    button.innerHTML = `<span class="sidebar-row-title">${item.label}</span><span class="sidebar-row-meta">${item.value}</span>`;
    button.addEventListener("click", () => {
      activeSourceFilter = item.filter;
      setContextPanel(true);
      const primaryChange = getPrimarySourceChange(getVisibleSourceChanges());
      setSelectedRun(primaryChange?.run ?? null);
      if (editorSurfaceOpen && primaryChange) {
        selectedEditorKey = getSourceChangeKey(primaryChange);
        renderEditorSurface();
        renderOpenEditors();
      }
      renderSourceSummary();
      renderSourceEntries();
      renderContextPanel();
      renderRunSummary();
    });
    root.appendChild(button);
  }
}

function getSourceStatusLabel(status: ChangeStatus) {
  switch (status) {
    case "added":
      return "A";
    case "deleted":
      return "D";
    case "renamed":
      return "R";
    case "modified":
    default:
      return "M";
  }
}

function updateSourceControlCommitButton() {
  const input = document.getElementById("source-control-message") as HTMLTextAreaElement | null;
  const button = document.getElementById("source-control-commit-btn") as HTMLButtonElement | null;
  const titleButton = document.getElementById("source-control-title-commit-btn") as HTMLButtonElement | null;
  if (!input || !button) {
    return;
  }

  sourceControlCommitMessage = input.value;
  const disabled = input.value.trim().length === 0 || getVisibleSourceChanges().length === 0;
  button.disabled = disabled;
  if (titleButton) {
    titleButton.disabled = disabled;
  }
}

type SourceControlGraphItem = DesktopRunProjection | BrowserSourceGraphItem;

function getSourceGraphCommit(item: SourceControlGraphItem) {
  const browserItem = item as BrowserSourceGraphItem;
  const projectionShortSha = "head_short" in item ? item.head_short : "";
  const shortSha = (browserItem.short_sha || projectionShortSha || item.run_id.slice(0, 7)).trim();
  let subject = (item.task || item.run_id).trim();
  let refs = Array.isArray(browserItem.refs) ? browserItem.refs.filter((ref) => ref) : [];
  const decoration = /^\(([^)]+)\)\s*(.*)$/.exec(subject);
  if (decoration) {
    if (refs.length === 0) {
      refs = decoration[1].split(",").map((ref) => ref.trim()).filter((ref) => ref);
    }
    subject = decoration[2].trim() || subject;
  }
  const branchRef = refs.find((ref) => ref.startsWith("HEAD -> "))
    || refs.find((ref) => !ref.startsWith("origin/") && ref !== "HEAD")
    || "";
  const isBrowserGitLogItem = "short_sha" in item || "refs" in item;
  const branch = branchRef.replace(/^HEAD ->\s*/, "") || (isBrowserGitLogItem ? "" : item.branch || "");
  return {
    shortSha,
    subject,
    refs,
    branch,
    author: browserItem.author || "",
    relativeTime: browserItem.relative_time || "",
    committedAt: browserItem.committed_at || "",
  };
}

function getSourceGraphMeta(item: SourceControlGraphItem) {
  const commit = getSourceGraphCommit(item);
  const parts = [
    commit.shortSha,
    commit.author,
    commit.relativeTime || commit.committedAt,
    item.changed_files.length > 0 ? getLanguageText(`${item.changed_files.length} changed`, `${item.changed_files.length} 変更`) : "",
  ].filter((value) => value);
  return parts.join("  ");
}

function getSourceGraphParents(item: SourceControlGraphItem) {
  const browserItem = item as BrowserSourceGraphItem;
  return Array.isArray(browserItem.parents)
    ? browserItem.parents.map((parent) => `${parent || ""}`.trim()).filter((parent) => parent)
    : [];
}

interface SourceGraphLane {
  branchId: number;
  expecting: string;
}

interface SourceGraphRow {
  item: SourceControlGraphItem;
  commitLane: number;
  lanesIn: SourceGraphLane[];
  lanesOut: SourceGraphLane[];
}

interface SourceGraphLaneSpan {
  branchId: number;
  col: number;
  startRow: number;
  endRow: number;
}

interface SourceGraphMergeMarker {
  row: number;
  fromCol: number;
  toCol: number;
  colorLane: number;
}

interface SourceGraphLayout {
  rows: SourceGraphRow[];
  laneSpans: SourceGraphLaneSpan[];
  mergeMarkers: SourceGraphMergeMarker[];
}

const sourceGraphLaneColors = [
  "#58a6ff",
  "#d29922",
  "#db61a2",
  "#56d4a8",
  "#a371f7",
  "#f0883e",
];
const sourceGraphSvgNamespace = "http://www.w3.org/2000/svg";
const sourceGraphLaneStep = 10;
const sourceGraphLaneOffset = 10.5;
const sourceGraphRowHeight = 46;
const sourceGraphCurveZone = 5;
const sourceGraphNormalNodeRadius = 2.5;
const sourceGraphHeadNodeRadius = 3.5;
const sourceGraphMergeNodeRadius = 2;

function getSourceGraphLaneX(laneIndex: number) {
  return sourceGraphLaneOffset + laneIndex * sourceGraphLaneStep;
}

function getSourceGraphRowY(rowIndex: number) {
  return sourceGraphRowHeight / 2 + rowIndex * sourceGraphRowHeight;
}

function getSourceGraphColor(colorLane: number) {
  return sourceGraphLaneColors[colorLane % sourceGraphLaneColors.length];
}

function cloneSourceGraphLanes(lanes: SourceGraphLane[]) {
  return lanes.map((lane) => ({ ...lane }));
}

function assignSourceGraphRows(items: SourceControlGraphItem[]) {
  const rows: SourceGraphRow[] = [];
  const active: SourceGraphLane[] = [];
  let nextBranchId = 0;

  for (const item of items) {
    const commitId = item.run_id;
    let commitLane = active.findIndex((lane) => lane.expecting === commitId);
    if (commitLane < 0) {
      active.push({
        branchId: nextBranchId,
        expecting: commitId,
      });
      nextBranchId += 1;
      commitLane = active.length - 1;
    }

    const lanesIn = cloneSourceGraphLanes(active);
    const parents = getSourceGraphParents(item);
    const firstParent = parents[0] ?? "";
    if (firstParent) {
      const existingParentLane = active.findIndex((lane) => lane.expecting === firstParent && lane.branchId !== active[commitLane].branchId);
      if (existingParentLane >= 0) {
        active.splice(commitLane, 1);
      } else {
        active[commitLane].expecting = firstParent;
      }
    } else {
      active.splice(commitLane, 1);
    }

    for (const parent of parents.slice(1)) {
      if (!active.some((lane) => lane.expecting === parent)) {
        active.push({
          branchId: nextBranchId,
          expecting: parent,
        });
        nextBranchId += 1;
      }
    }

    rows.push({
      item,
      commitLane,
      lanesIn,
      lanesOut: cloneSourceGraphLanes(active),
    });
  }

  return rows;
}

function pushSourceGraphLaneSpan(spans: SourceGraphLaneSpan[], branchId: number, col: number, startRow: number, endRow: number) {
  if (startRow === endRow) {
    return;
  }
  spans.push({ branchId, col, startRow, endRow });
}

function buildSourceGraphLaneSpans(rows: SourceGraphRow[]) {
  const spans: SourceGraphLaneSpan[] = [];
  const active = new Map<number, { startRow: number; col: number }>();

  rows.forEach((row, rowIndex) => {
    row.lanesIn.forEach((lane, col) => {
      if (!active.has(lane.branchId)) {
        active.set(lane.branchId, { startRow: rowIndex, col });
      }
    });

    const outIds = new Set(row.lanesOut.map((lane) => lane.branchId));
    row.lanesOut.forEach((lane, col) => {
      const current = active.get(lane.branchId);
      if (!current) {
        active.set(lane.branchId, { startRow: rowIndex + 1, col });
        return;
      }
      if (current.col !== col) {
        pushSourceGraphLaneSpan(spans, lane.branchId, current.col, current.startRow, rowIndex);
        active.set(lane.branchId, { startRow: rowIndex + 1, col });
      }
    });

    for (const [branchId, current] of Array.from(active.entries())) {
      if (!outIds.has(branchId)) {
        active.delete(branchId);
        pushSourceGraphLaneSpan(spans, branchId, current.col, current.startRow, rowIndex);
      }
    }
  });

  active.forEach((current, branchId) => {
    pushSourceGraphLaneSpan(spans, branchId, current.col, current.startRow, rows.length);
  });

  return spans.sort((a, b) =>
    a.startRow - b.startRow ||
    a.col - b.col ||
    a.branchId - b.branchId ||
    a.endRow - b.endRow
  );
}

function buildSourceGraphMergeMarkers(rows: SourceGraphRow[]) {
  const markers: SourceGraphMergeMarker[] = [];

  rows.forEach((row, rowIndex) => {
    const parents = getSourceGraphParents(row.item);
    parents.slice(1).forEach((parent) => {
      const fromCol = row.lanesOut.findIndex((lane) => lane.expecting === parent);
      if (fromCol < 0 || fromCol === row.commitLane) {
        return;
      }
      markers.push({
        row: rowIndex,
        fromCol,
        toCol: row.commitLane,
        colorLane: row.lanesOut[fromCol].branchId,
      });
    });
  });

  return markers;
}

function buildSourceGraphLayout(rows: SourceGraphRow[]): SourceGraphLayout {
  return {
    rows,
    laneSpans: buildSourceGraphLaneSpans(rows),
    mergeMarkers: buildSourceGraphMergeMarkers(rows),
  };
}

function getSourceGraphRowLaneCount(row: SourceGraphRow) {
  return Math.max(1, row.commitLane + 1, row.lanesIn.length, row.lanesOut.length);
}

function getSourceGraphSvgWidth(laneCount: number) {
  const rightEdge = getSourceGraphLaneX(Math.max(0, laneCount - 1)) + sourceGraphHeadNodeRadius;
  return Math.max(64, Math.ceil(rightEdge));
}

function sourceGraphLaneShiftPath(x1: number, y1: number, x2: number, y2: number) {
  if (Math.abs(x1 - x2) < 0.01) {
    return `M ${x1} ${y1} L ${x2} ${y2}`;
  }
  const middle = (y1 + y2) / 2;
  const curveTop = Math.max(y1, middle - sourceGraphCurveZone);
  const curveBottom = Math.min(y2, middle + sourceGraphCurveZone);
  const cy1 = curveTop + (curveBottom - curveTop) * 0.4;
  const cy2 = curveTop + (curveBottom - curveTop) * 0.6;
  return `M ${x1} ${y1} L ${x1} ${curveTop} C ${x1} ${cy1} ${x2} ${cy2} ${x2} ${curveBottom} L ${x2} ${y2}`;
}

function appendSourceGraphPath(svg: SVGElement, d: string, branchId: number, className: string) {
  const path = document.createElementNS(sourceGraphSvgNamespace, "path");
  path.setAttribute("class", `source-control-graph-lane-path ${className}`);
  path.setAttribute("d", d);
  path.setAttribute("stroke", getSourceGraphColor(branchId));
  svg.appendChild(path);
}

function appendSourceGraphSegment(svg: SVGElement, fromLane: number, fromY: number, toLane: number, toY: number, branchId: number, className = "is-segment") {
  const fromX = getSourceGraphLaneX(fromLane);
  const toX = getSourceGraphLaneX(toLane);
  appendSourceGraphPath(svg, sourceGraphLaneShiftPath(fromX, fromY, toX, toY), branchId, className);
}

function appendSourceGraphNode(svg: SVGElement, laneIndex: number, y: number, branchId: number, rowIndex: number) {
  const color = getSourceGraphColor(branchId);
  const outer = document.createElementNS(sourceGraphSvgNamespace, "circle");
  outer.setAttribute("class", rowIndex === 0 ? "source-control-graph-lane-node is-head" : "source-control-graph-lane-node");
  outer.setAttribute("cx", String(getSourceGraphLaneX(laneIndex)));
  outer.setAttribute("cy", String(y));
  outer.setAttribute("r", String(rowIndex === 0 ? sourceGraphHeadNodeRadius : sourceGraphNormalNodeRadius));
  outer.setAttribute("stroke", color);
  svg.appendChild(outer);

  if (rowIndex === 0) {
    const core = document.createElementNS(sourceGraphSvgNamespace, "circle");
    core.setAttribute("class", "source-control-graph-lane-node-core");
    core.setAttribute("cx", String(getSourceGraphLaneX(laneIndex)));
    core.setAttribute("cy", String(y));
    core.setAttribute("r", "1.2");
    core.setAttribute("fill", color);
    svg.appendChild(core);
  }
}

function appendSourceGraphMergeMarker(svg: SVGElement, marker: SourceGraphMergeMarker) {
  const color = getSourceGraphColor(marker.colorLane);
  const dot = document.createElementNS(sourceGraphSvgNamespace, "circle");
  dot.setAttribute("class", "source-control-graph-merge-marker");
  dot.setAttribute("cx", String(getSourceGraphLaneX(marker.fromCol)));
  dot.setAttribute("cy", String(getSourceGraphRowY(marker.row)));
  dot.setAttribute("r", String(sourceGraphMergeNodeRadius));
  dot.setAttribute("stroke", color);
  svg.appendChild(dot);
}

function renderSourceGraphOverlay(layout: SourceGraphLayout) {
  const maxLanes = Math.max(
    1,
    ...layout.rows.map(getSourceGraphRowLaneCount),
    ...layout.laneSpans.map((span) => span.col + 1),
    ...layout.mergeMarkers.map((marker) => Math.max(marker.fromCol, marker.toCol) + 1),
  );
  const svgWidth = getSourceGraphSvgWidth(maxLanes);
  const svgHeight = Math.max(sourceGraphRowHeight, layout.rows.length * sourceGraphRowHeight);
  const svg = document.createElementNS(sourceGraphSvgNamespace, "svg");
  svg.setAttribute("class", "source-control-graph-svg source-control-graph-overlay");
  svg.setAttribute("viewBox", `0 0 ${svgWidth} ${svgHeight}`);
  svg.setAttribute("width", String(svgWidth));
  svg.setAttribute("height", String(svgHeight));
  svg.style.width = `${svgWidth}px`;
  svg.style.height = `${svgHeight}px`;
  svg.setAttribute("aria-hidden", "true");

  layout.laneSpans.forEach((span) => {
    appendSourceGraphPath(
      svg,
      `M ${getSourceGraphLaneX(span.col)} ${getSourceGraphRowY(span.startRow)} L ${getSourceGraphLaneX(span.col)} ${getSourceGraphRowY(span.endRow)}`,
      span.branchId,
      "is-pillar",
    );
  });

  layout.rows.forEach((row, rowIndex) => {
    const currentLane = row.lanesIn[row.commitLane];
    if (!currentLane) {
      return;
    }

    const y1 = getSourceGraphRowY(rowIndex);
    const y2 = getSourceGraphRowY(rowIndex + 1);
    row.lanesIn.forEach((lane, laneIndex) => {
      if (lane.branchId === currentLane.branchId) {
        return;
      }
      const nextLaneIndex = row.lanesOut.findIndex((nextLane) => nextLane.branchId === lane.branchId);
      if (nextLaneIndex >= 0 && nextLaneIndex !== laneIndex) {
        appendSourceGraphSegment(svg, laneIndex, y1, nextLaneIndex, y2, lane.branchId);
      }
    });

    for (const [parentIndex, parent] of getSourceGraphParents(row.item).entries()) {
      const nextLaneIndex = row.lanesOut.findIndex((lane) => lane.expecting === parent);
      if (nextLaneIndex < 0 || nextLaneIndex === row.commitLane) {
        continue;
      }
      const branchId = parentIndex === 0
        ? currentLane.branchId
        : row.lanesOut[nextLaneIndex].branchId;
      appendSourceGraphSegment(svg, row.commitLane, y1, nextLaneIndex, y2, branchId);
    }
  });

  layout.rows.forEach((row, rowIndex) => {
    const currentLane = row.lanesIn[row.commitLane];
    if (currentLane) {
      appendSourceGraphNode(svg, row.commitLane, getSourceGraphRowY(rowIndex), currentLane.branchId, rowIndex);
    }
  });
  layout.mergeMarkers.forEach((marker) => appendSourceGraphMergeMarker(svg, marker));
  return svg;
}

function renderSourceGraphLanes(root: HTMLElement, row: SourceGraphRow) {
  root.replaceChildren();
  root.style.width = `${getSourceGraphSvgWidth(getSourceGraphRowLaneCount(row))}px`;
  root.style.height = `${sourceGraphRowHeight}px`;
}

function applySourceControlSplitHeight() {
  const view = document.getElementById("source-control-view");
  if (!view) {
    return;
  }
  view.style.setProperty("--source-control-changes-height", `${sourceControlChangesHeight}px`);
  const splitter = document.getElementById("source-control-splitter");
  if (splitter) {
    splitter.setAttribute("aria-valuenow", `${Math.round(sourceControlChangesHeight)}`);
  }
}

function clampSourceControlChangesHeight(value: number) {
  const view = document.getElementById("source-control-view");
  const viewHeight = view?.getBoundingClientRect().height ?? window.innerHeight;
  const maxHeight = Math.max(140, viewHeight - 220);
  return Math.min(Math.max(96, value), maxHeight);
}

function renderSourceControlView() {
  const changesRoot = document.getElementById("source-control-changes-list");
  const graphRoot = document.getElementById("source-control-graph-list");
  const count = document.getElementById("source-control-count");
  const changesCount = document.getElementById("source-control-changes-count");
  const messageInput = document.getElementById("source-control-message") as HTMLTextAreaElement | null;
  if (!changesRoot || !graphRoot || !count) {
    return;
  }
  sourceControlChangesHeight = clampSourceControlChangesHeight(sourceControlChangesHeight);
  applySourceControlSplitHeight();

  const changes = getVisibleSourceChanges();
  const stagedChanges = changes.filter((change) => change.staged);
  const unstagedChanges = changes.filter((change) => !change.staged);
  const stagedSectionVisible = stagedChanges.length > 0;
  const primaryChangeCount = stagedSectionVisible ? stagedChanges.length : changes.length;
  count.textContent = `${changes.length}`;
  const changesTitle = document.getElementById("source-control-changes-title");
  if (changesTitle) {
    changesTitle.textContent = stagedSectionVisible
      ? getLanguageText("Staged Changes", "ステージされている変更")
      : getLanguageText("Changes", "変更");
  }
  if (changesCount) {
    changesCount.textContent = `${primaryChangeCount}`;
  }
  if (messageInput && messageInput.value !== sourceControlCommitMessage) {
    messageInput.value = sourceControlCommitMessage;
  }

  const appendChangeRow = (change: SourceChange) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `sidebar-row source-control-file-row ${getSourceChangeKey(change) === selectedEditorKey && editorSurfaceOpen ? "is-active" : ""}`;
    button.dataset.tone = getSourceEntryTone(change);
    button.classList.toggle("is-staged", Boolean(change.staged));
    const fileName = change.path.split("/").pop() ?? change.path;
    const fileDir = change.path.split("/").slice(0, -1).join("\\");
    const icon = document.createElement("span");
    icon.className = "sidebar-file-icon";
    const iconKind = getExplorerFileIconKind(change.path, fileName);
    icon.dataset.iconKind = iconKind;
    icon.textContent = getExplorerFileIconLabel(iconKind);

    const fileMain = document.createElement("span");
    fileMain.className = "source-control-file-main";
    const filePath = document.createElement("span");
    filePath.className = "sidebar-row-title source-control-file-path";
    filePath.textContent = fileName;
    const fileDirectory = document.createElement("span");
    fileDirectory.className = "source-control-file-dir";
    fileDirectory.textContent = fileDir;
    fileMain.append(filePath, fileDirectory);

    const status = document.createElement("span");
    status.className = "source-control-status";
    status.textContent = getSourceStatusLabel(change.status);
    status.title = [
      change.staged ? getLanguageText("staged", "ステージ済み") : getLanguageText("changes", "未ステージ"),
      change.status,
      change.lines,
    ].filter((value) => value).join(" · ");

    button.append(icon, fileMain, status);
    button.addEventListener("click", () => {
      setSelectedRun(change.run);
      void openEditorSourceChange(change);
      renderExplorer();
    });
    changesRoot.appendChild(button);
  };

  const appendInlineChangeHeader = (titleText: string, value: number) => {
    const header = document.createElement("div");
    header.className = "source-control-inline-group-title";
    const label = document.createElement("span");
    label.className = "source-control-group-label";
    label.textContent = `⌄ ${titleText}`;
    const badge = document.createElement("span");
    badge.className = "source-control-count";
    badge.textContent = `${value}`;
    header.append(label, badge);
    changesRoot.appendChild(header);
  };

  changesRoot.innerHTML = "";
  if (changes.length === 0) {
    const empty = document.createElement("div");
    empty.className = "sidebar-row";
    empty.innerHTML =
      `<span class="sidebar-row-title">${getLanguageText("No changed files", "変更ファイルはありません")}</span>` +
      `<span class="sidebar-row-meta">${getLanguageText("Desktop summary has not reported source changes.", "デスクトップ要約には変更がありません。")}</span>`;
    changesRoot.appendChild(empty);
  } else {
    for (const change of stagedSectionVisible ? stagedChanges : changes) {
      appendChangeRow(change);
    }
    if (stagedSectionVisible) {
      appendInlineChangeHeader(getLanguageText("Changes", "変更"), unstagedChanges.length);
      if (unstagedChanges.length === 0) {
        const empty = document.createElement("div");
        empty.className = "source-control-empty-group";
        empty.textContent = getLanguageText("No unstaged changes", "未ステージの変更はありません");
        changesRoot.appendChild(empty);
      } else {
        for (const change of unstagedChanges) {
          appendChangeRow(change);
        }
      }
    }
  }

  graphRoot.innerHTML = "";
  const graphItems = (browserSourceGraphItems.length > 0
    ? browserSourceGraphItems
    : getRunProjections()
  ).slice(0, 30);
  const graphRows = assignSourceGraphRows(graphItems);
  if (graphItems.length === 0) {
    const empty = document.createElement("div");
    empty.className = "sidebar-row";
    empty.innerHTML =
      `<span class="sidebar-row-title">${getLanguageText("No graph data", "グラフデータはありません")}</span>` +
      `<span class="sidebar-row-meta">${getLanguageText("Connect the desktop summary to show recent runs.", "最近の実行を表示するにはデスクトップ要約を接続してください。")}</span>`;
    graphRoot.appendChild(empty);
  } else {
    const graphLayout = buildSourceGraphLayout(graphRows);
    graphRoot.appendChild(renderSourceGraphOverlay(graphLayout));
    graphRows.forEach((row, index) => {
      const item = row.item;
      const commit = getSourceGraphCommit(item);
      const button = document.createElement("button");
      button.type = "button";
      button.className = `sidebar-row source-control-graph-row ${item.run_id === getSelectedRunId() ? "is-active" : ""}`;
      button.dataset.graphIndex = `${index % 6}`;
      button.title = [
        commit.subject,
        commit.branch ? getLanguageText(`branch: ${commit.branch}`, `ブランチ: ${commit.branch}`) : "",
        commit.refs.length > 0 ? getLanguageText(`refs: ${commit.refs.join(", ")}`, `参照: ${commit.refs.join(", ")}`) : "",
        getSourceGraphMeta(item),
      ].filter((value) => value).join("\n");

      const lane = document.createElement("span");
      lane.className = "source-control-graph-lanes";
      lane.title = getLanguageText(
        "Commit graph. Dot = commit; lines show lane, branch, and merge flow.",
        "コミットグラフ。点はコミット、線はレーン、分岐、合流の流れを示します。",
      );
      lane.setAttribute("aria-label", lane.title);
      lane.dataset.graphParents = getSourceGraphParents(item).join(" ");
      lane.dataset.graphLaneCount = `${getSourceGraphRowLaneCount(row)}`;
      renderSourceGraphLanes(lane, row);

      const content = document.createElement("span");
      content.className = "source-control-graph-content";

      const titleRow = document.createElement("span");
      titleRow.className = "source-control-graph-title-row";
      const title = document.createElement("span");
      title.className = "sidebar-row-title source-control-graph-subject";
      title.textContent = commit.subject;
      titleRow.appendChild(title);
      if (commit.branch) {
        const branch = document.createElement("span");
        branch.className = "source-control-graph-branch";
        branch.textContent = commit.branch;
        titleRow.appendChild(branch);
      }

      const meta = document.createElement("span");
      meta.className = "sidebar-row-meta source-control-graph-meta";
      meta.textContent = getSourceGraphMeta(item);

      content.append(titleRow, meta);
      button.append(lane, content);
      button.addEventListener("click", () => {
        setSelectedRun(item.run_id);
        renderDesktopSurfaces();
      });
      graphRoot.appendChild(button);
    });
  }

  updateSourceControlCommitButton();
}

function getEvidenceTone(value: string | null | undefined): SurfaceTone {
  const normalized = normalizeDecisionText(value).toUpperCase();
  if (normalized === "PASS" || normalized === "ALLOW" || normalized === "FALSE") {
    return "success";
  }
  if (normalized === "FAIL" || normalized === "FAILED" || normalized === "BLOCK" || normalized === "BLOCKED" || normalized === "TRUE") {
    return "danger";
  }
  if (normalized === "PENDING" || normalized === "PARTIAL" || normalized === "WARN" || normalized === "WARNING") {
    return "warning";
  }
  return "info";
}

function formatEvidenceTimestamp(value: string | null | undefined) {
  if (!value) {
    return "";
  }
  const parsed = Date.parse(value);
  if (Number.isNaN(parsed)) {
    return value;
  }
  return new Date(parsed).toLocaleString([], {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function getEvidenceItems(): EvidenceItem[] {
  const snapshot = desktopSummarySnapshot;
  if (!snapshot) {
    return [];
  }

  const items: EvidenceItem[] = [];
  const projections = getRunProjections();
  const verifiedCount = projections.filter((item) => item.verification_outcome).length;
  const reviewCount = projections.filter((item) => item.review_state).length;
  const securityCount = projections.filter((item) => item.security_blocked).length;
  const changedCount = projections.reduce((total, item) => total + item.changed_files.length, 0);
  const digestBodyParts = [
    getLanguageText(`${verifiedCount} verification records`, `検証 ${verifiedCount} 件`),
    getLanguageText(`${reviewCount} review records`, `レビュー ${reviewCount} 件`),
    getLanguageText(`${securityCount} security records`, `セキュリティ ${securityCount} 件`),
    getLanguageText(`${changedCount} changed files`, `${changedCount} 件の変更`),
  ].filter((item) => item);
  items.push({
    category: getLanguageText("Digest", "要約"),
    title: getLanguageText("Evidence digest", "証跡の要約"),
    body: digestBodyParts.join(" · ") || getLanguageText("No evidence outcome is visible yet.", "証跡の結果はまだ表示されていません。"),
    meta: getLanguageText(`generated ${formatEvidenceTimestamp(snapshot.generated_at)}`, `${formatEvidenceTimestamp(snapshot.generated_at)} 生成`),
    source: getLanguageText("source: desktop summary", "出典: デスクトップ要約"),
    anchor: getLanguageText("all visible run projections", "表示中の実行一覧"),
    tone: verifiedCount > 0 || reviewCount > 0 || securityCount > 0 ? "info" : "default",
  });

  for (const payload of Array.from(desktopExplainCache.values())) {
    const digest = payload.evidence_digest;
    if (digest.verification_outcome || digest.security_blocked || digest.changed_file_count > 0) {
      items.push({
        category: getLanguageText("Run", "実行"),
        title: payload.run.task || payload.run.run_id,
        body: [
          digest.verification_outcome ? getLanguageText(`verification ${digest.verification_outcome}`, `検証 ${digest.verification_outcome}`) : "",
          digest.security_blocked ? getLanguageText(`security ${digest.security_blocked}`, `セキュリティ ${digest.security_blocked}`) : "",
          getLanguageText(`${digest.changed_file_count} changed`, `${digest.changed_file_count} 件の変更`),
        ].filter((item) => item).join(" · "),
        meta: [payload.run.branch || getLanguageText("no branch", "ブランチなし"), formatEvidenceTimestamp(payload.generated_at)].filter((item) => item).join(" · "),
        source: getLanguageText("source: explain evidence digest", "出典: 実行説明"),
        anchor: [payload.run.run_id, payload.run.experiment_packet?.observation_pack_ref].filter((item) => item).join(" · "),
        tone: getEvidenceTone(digest.verification_outcome || digest.security_blocked),
        runId: payload.run.run_id,
        primaryPath: digest.changed_files[0] || payload.run.changed_files[0],
        primaryWorktree: payload.run.worktree || "",
      });
    }

    const reviewEvidence = payload.review_state?.evidence ?? null;
    if (reviewEvidence?.approved_at || reviewEvidence?.failed_at) {
      const failed = Boolean(reviewEvidence.failed_at);
      items.push({
        category: getLanguageText("Review", "レビュー"),
        title: getLanguageText("Review evidence", "レビュー証跡"),
        body: failed
          ? getLanguageText(`Failed via ${reviewEvidence.failed_via || "reviewer"}`, `${reviewEvidence.failed_via || "reviewer"} で失敗`)
          : getLanguageText(`Approved via ${reviewEvidence.approved_via || "reviewer"}`, `${reviewEvidence.approved_via || "reviewer"} で承認`),
        meta: [payload.run.run_id, formatEvidenceTimestamp(failed ? reviewEvidence.failed_at : reviewEvidence.approved_at)].filter((item) => item).join(" · "),
        source: getLanguageText("source: review state", "出典: レビュー状態"),
        anchor: reviewEvidence.review_contract_snapshot?.source_task || payload.run.task_id || payload.run.run_id,
        tone: failed ? "danger" : "success",
        runId: payload.run.run_id,
      });
    }

    for (const event of payload.recent_events.slice(0, 5)) {
      items.push({
        category: getLanguageText("Event", "イベント"),
        title: event.event || getLanguageText("Recent event", "最近のイベント"),
        body: event.message || event.label || getLanguageText("Event recorded.", "イベントが記録されました。"),
        meta: [payload.run.run_id, formatEvidenceTimestamp(event.timestamp), event.label].filter((item) => item).join(" · "),
        source: getLanguageText("source: recent event log", "出典: 最近のイベント"),
        anchor: [event.timestamp, event.event].filter((item) => item).join(" · "),
        tone: "default",
        runId: payload.run.run_id,
      });
    }
  }

  for (const projection of projections.slice(0, 12)) {
    const outcome = projection.verification_outcome || projection.review_state || projection.security_blocked;
    if (!outcome && projection.changed_files.length === 0 && !projection.observation_pack_ref && !projection.consultation_ref) {
      continue;
    }
    const evidenceRefs = [
      projection.observation_pack_ref ? getLanguageText("observation", "観測") : "",
      projection.consultation_ref ? getLanguageText("consultation", "相談") : "",
    ].filter((item) => item);
    items.push({
      category: getLanguageText("Run", "実行"),
      title: projection.task || projection.run_id,
      body: [
        projection.verification_outcome ? getLanguageText(`verification ${projection.verification_outcome}`, `検証 ${projection.verification_outcome}`) : "",
        projection.review_state ? getLanguageText(`review ${projection.review_state}`, `レビュー ${projection.review_state}`) : "",
        projection.security_blocked ? getLanguageText(`security ${projection.security_blocked}`, `セキュリティ ${projection.security_blocked}`) : "",
        projection.changed_files.length > 0 ? getLanguageText(`${projection.changed_files.length} changed`, `${projection.changed_files.length} 件の変更`) : "",
      ].filter((item) => item).join(" · ") || getLanguageText("Run evidence is available.", "実行の証跡があります。"),
      meta: [
        projection.branch || getLanguageText("no branch", "ブランチなし"),
        projection.head_short,
        evidenceRefs.join("/"),
      ].filter((item) => item).join(" · "),
      source: getLanguageText("source: run projection", "出典: 実行一覧"),
      anchor: [
        projection.run_id,
        projection.observation_pack_ref || projection.consultation_ref,
      ].filter((item) => item).join(" · "),
      tone: getEvidenceTone(outcome),
      runId: projection.run_id,
      primaryPath: projection.changed_files[0],
      primaryWorktree: projection.worktree || "",
    });
  }

  return items;
}

function renderEvidenceView() {
  const root = document.getElementById("evidence-list");
  const count = document.getElementById("evidence-count");
  const badge = document.getElementById("activity-evidence-count");
  if (!root || !count) {
    return;
  }

  const items = getEvidenceItems();
  count.textContent = `${items.length}`;
  if (badge) {
    badge.hidden = items.length === 0;
    badge.textContent = `${items.length}`;
  }

  root.innerHTML = "";
  if (items.length === 0) {
    const empty = document.createElement("div");
    empty.className = "sidebar-row";
    const title = document.createElement("span");
    title.className = "sidebar-row-title";
    title.textContent = getLanguageText("No evidence", "証跡はありません");
    const meta = document.createElement("span");
    meta.className = "sidebar-row-meta";
    meta.textContent = getLanguageText(
      "Run verification or open an explain payload. Evidence rows link back to the source run when available.",
      "検証を実行するか、実行説明を開くと証跡が表示されます。証跡行は、利用できる場合は元の実行へ戻れます。",
    );
    empty.append(title, meta);
    root.appendChild(empty);
    return;
  }

  for (const item of items) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `sidebar-row evidence-row ${item.runId && item.runId === getSelectedRunId() ? "is-active" : ""}`;
    button.dataset.tone = item.tone;
    button.title = [item.source, item.anchor, item.body].filter((value) => value).join("\n");

    const kicker = document.createElement("span");
    kicker.className = "evidence-row-kicker";
    const category = document.createElement("span");
    category.className = "evidence-row-category";
    category.textContent = item.category;
    const source = document.createElement("span");
    source.className = "evidence-row-source";
    source.textContent = item.source;
    kicker.append(category, source);

    const title = document.createElement("span");
    title.className = "sidebar-row-title";
    title.textContent = item.title;
    const body = document.createElement("span");
    body.className = "sidebar-row-meta";
    body.textContent = item.body;
    const meta = document.createElement("span");
    meta.className = "evidence-row-meta";
    meta.textContent = [item.meta, item.anchor].filter((value) => value).join(" · ");
    button.append(kicker, title, body, meta);

    button.addEventListener("click", () => {
      if (item.runId) {
        setSelectedRun(item.runId);
        setContextPanel(true);
        renderDesktopSurfaces();
      }
    });
    button.addEventListener("dblclick", () => {
      if (item.primaryPath) {
        void openEditorPath(item.primaryPath, item.primaryWorktree ?? "");
      }
    });
    root.appendChild(button);
  }
}

function submitSourceControlCommitRequest() {
  const message = sourceControlCommitMessage.trim();
  const changes = getVisibleSourceChanges();
  if (!message || changes.length === 0) {
    return;
  }

  appendRuntimeConversation({
    type: "user",
    category: "activity",
    timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
    actor: getLanguageText("User", "ユーザー"),
    title: getLanguageText("Commit requested", "コミットを依頼"),
    body: getLanguageText(
      `Commit message: ${message}. Files: ${summarizeChangedFiles(changes.map((item) => item.path), 4)}.`,
      `コミットメッセージ: ${message}。対象: ${summarizeChangedFiles(changes.map((item) => item.path), 4)}。`,
    ),
    details: [
      { label: getLanguageText("files", "ファイル"), value: `${changes.length}` },
      { label: getLanguageText("scope", "範囲"), value: getSourceFilterLabel(activeSourceFilter) },
    ],
    tone: "focus",
  });
  sourceControlCommitMessage = "";
  const messageInput = document.getElementById("source-control-message") as HTMLTextAreaElement | null;
  if (messageInput) {
    messageInput.value = "";
  }
  setComposerMode("dispatch");
  renderConversation(getConversationItems());
  renderSourceControlView();
}

function getVisibleSourceChanges() {
  const activeEntries = getProjectionSourceEntries();
  switch (activeSourceFilter) {
    case "candidates":
      return activeEntries.filter((item) => item.commitCandidate);
    case "attention":
      return activeEntries.filter((item) => item.needsAttention);
    default:
      if (activeSourceFilter.startsWith("pane:")) {
        const paneLabel = getPaneLabelFromSourceFilter(activeSourceFilter);
        return activeEntries.filter((item) => item.paneLabel === paneLabel);
      }
      return activeEntries;
  }
}

function getPrimarySourceChange(changes: SourceChange[]) {
  return (
    changes.find((item) => item.run === selectedRunId) ??
    changes.find((item) => getSourceChangeKey(item) === selectedEditorKey) ??
    changes[0] ??
    getProjectionSourceEntries()[0]
  );
}

function stripAnsi(input: string) {
  return input.replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, "");
}

function extractPreviewUrls(data: string) {
  const matches = stripAnsi(data).match(/https?:\/\/(?:localhost|127\.0\.0\.1):\d+(?:\/[^\s"'<>)]*)?/gi);
  return matches ?? [];
}

function getPreviewPortLabel(url: string) {
  try {
    const parsed = new URL(url);
    return parsed.port ? `:${parsed.port}` : parsed.host;
  } catch {
    return url;
  }
}

function formatPreviewSeenAt(timestamp: number) {
  return new Date(timestamp).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
  });
}

function registerPreviewTargets(paneId: string, data: string) {
  let changed = false;
  const now = Date.now();
  for (const url of extractPreviewUrls(data)) {
    const existing = detectedPreviewTargets.get(url);
    if (existing) {
      if (existing.sourceLabel !== (paneId || "terminal") || now - existing.lastSeenAt >= PREVIEW_FRESHNESS_WINDOW_MS) {
        detectedPreviewTargets.set(url, {
          ...existing,
          sourceLabel: paneId || "terminal",
          lastSeenAt: now,
        });
        changed = true;
      }
      continue;
    }
    detectedPreviewTargets.set(url, {
      url,
      portLabel: getPreviewPortLabel(url),
      sourceLabel: paneId || "terminal",
      lastSeenAt: now,
    });
    changed = true;
  }

  if (changed) {
    renderContextPanel();
    renderEditorSurface();
  }
}

function registerPreviewTargetForHarness(sourceLabel: string, url: string) {
  detectedPreviewTargets.set(url, {
    url,
    portLabel: getPreviewPortLabel(url),
    sourceLabel: sourceLabel || "viewport-harness",
    lastSeenAt: Date.now(),
  });
  renderContextPanel();
  renderEditorSurface();
}

function openEditorPreviewForHarness(path: string, content: string, worktree = "") {
  restoreStandaloneEditorFromSnapshot({
    mode: "editor",
    path,
    worktree,
    summary: `Project file preview · ${path.split("/").pop() ?? path}`,
    origin: "explorer",
    modified: false,
    sourceChange: null,
    content,
  });
}

function restoreStandaloneEditorFromSnapshot(state: Extract<PopoutSurfaceState, { mode: "editor" }> & { content: string }) {
  const target: EditorTarget = {
    key: getEditorFileKey(state.path, state.worktree),
    path: state.path,
    summary: state.summary,
    worktree: state.worktree,
    origin: state.origin,
    modified: state.modified,
    sourceChange: state.sourceChange ?? undefined,
  };
  desktopStandaloneEditorTargets.set(target.key, target);
  desktopEditorFileCache.set(target.key, {
    key: target.key,
    path: state.path,
    summary: state.summary,
    content: state.content,
    language: inferLanguageFromPath(state.path),
    lineCount: countEditorLines(state.content),
    modified: state.modified,
    origin: state.origin,
  });
  desktopEditorLoadErrors.delete(target.key);
  desktopEditorLoadingPaths.delete(target.key);
  editorSurfaceMode = "code";
  selectedPreviewUrl = "";
  lastPreviewExternalState = null;
  lastPreviewClipboardState = null;
  selectedEditorKey = target.key;
  setSelectedRun(target.sourceChange?.run ?? selectedRunId);
  setEditorSurface(true);
  renderOpenEditors();
  renderSourceSummary();
  renderRunSummary();
}

function getCurrentEditorSurfaceState(): PopoutSurfaceState | null {
  const selectedProjection = getPrimaryRunProjection();
  const runId = selectedProjection?.run_id || undefined;
  const runLabel = selectedProjection?.label || selectedProjection?.run_id || undefined;
  const previewTarget = selectedPreviewUrl ? detectedPreviewTargets.get(selectedPreviewUrl) ?? null : null;
  if (editorSurfaceMode === "preview" && previewTarget) {
    return {
      mode: "preview",
      url: previewTarget.url,
      portLabel: previewTarget.portLabel,
      sourceLabel: previewTarget.sourceLabel,
      lastSeenAt: previewTarget.lastSeenAt,
      runId,
      runLabel,
    };
  }

  const editors = getEditorFiles();
  const selected = editors.find((editor) => editor.key === selectedEditorKey) || editors[0];
  if (!selected) {
    return null;
  }

  const selectedTarget = getEditorTargetByKey(selected.key);
  return {
    mode: "editor",
    path: selected.path,
    worktree: selectedTarget?.worktree ?? "",
    summary: selected.summary,
    origin: selected.origin,
    modified: Boolean(selected.modified),
    sourceChange: selectedTarget?.sourceChange ?? null,
    content: isTauri() ? undefined : selected.content,
    runId,
    runLabel,
  };
}

function readPopoutSurfaceState() {
  const searchParams = new URLSearchParams(window.location.search);
  if (searchParams.get("popout") !== "1") {
    return null;
  }

  const key = searchParams.get("popout-key");
  if (!key) {
    return null;
  }

  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) {
      return null;
    }
    window.localStorage.removeItem(key);
    return JSON.parse(raw) as PopoutSurfaceState;
  } catch {
    return null;
  }
}

function describeDetachedSurfaceSession(state: PopoutSurfaceState): DetachedSurfaceSessionState {
  if (state.mode === "preview") {
    return {
      name: "detached-preview",
      meta: `${state.portLabel} · ${state.sourceLabel}${state.runLabel ? ` · ${state.runLabel}` : ""}`,
    };
  }

  const fileLabel = state.path.split("/").pop() ?? state.path;
  const worktreeLabel = state.worktree ? getWorktreeLabel(state.worktree) : "Project root";
  return {
    name: "detached-editor",
    meta: `${fileLabel} · ${worktreeLabel}${state.runLabel ? ` · ${state.runLabel}` : ""}`,
  };
}

function clearDetachedSurfaceSession() {
  detachedSurfaceSession = null;
  if (detachedSurfacePollTimer !== null) {
    window.clearInterval(detachedSurfacePollTimer);
    detachedSurfacePollTimer = null;
  }
  renderSessions();
}

function setDetachedSurfaceSession(state: PopoutSurfaceState) {
  detachedSurfaceSession = describeDetachedSurfaceSession(state);
  renderSessions();
}

function applyPopoutSurfaceState(state: PopoutSurfaceState | null) {
  if (!state) {
    return;
  }

  document.body.dataset.popoutSurface = "1";
  detachedSurfaceRunLabel = state.runLabel ?? state.runId ?? "";
  const title = document.getElementById("workspace-title");
  const subtitle = document.getElementById("workspace-subtitle");
  const editorLabel = state.mode === "editor" ? state.path.split("/").pop() ?? state.path : "";
  const editorWorktreeLabel = state.mode === "editor" && state.worktree ? getWorktreeLabel(state.worktree) : "Project root";
  if (title) {
    title.textContent =
      state.mode === "preview"
        ? `${state.portLabel} preview`
        : `${editorLabel} editor`;
  }
  if (subtitle) {
    subtitle.textContent =
      state.mode === "preview"
        ? `Detached secondary surface from ${state.sourceLabel}${detachedSurfaceRunLabel ? ` · ${detachedSurfaceRunLabel}` : ""}.`
        : `Detached secondary surface for ${editorWorktreeLabel}${detachedSurfaceRunLabel ? ` · ${detachedSurfaceRunLabel}` : ""}.`;
  }

  setSidebarOpen(false, { preserveWidePreference: false });
  setContextPanel(false, { preserveWidePreference: false });
  setTerminalDrawer(terminalDrawerOpen);
  setSettingsSheet(false);
  closeCommandBar();

  if (state.mode === "preview") {
    setSelectedRun(state.runId ?? null);
    registerPreviewTargetForHarness(state.sourceLabel, state.url);
    const target = detectedPreviewTargets.get(state.url);
    if (target) {
      target.portLabel = state.portLabel || target.portLabel;
      target.lastSeenAt = state.lastSeenAt || target.lastSeenAt;
    }
    openPreviewTarget(state.url);
    return;
  }

  if (typeof state.content === "string") {
    setSelectedRun(state.runId ?? null);
    restoreStandaloneEditorFromSnapshot({ ...state, content: state.content });
    return;
  }

  setSelectedRun(state.runId ?? null);
  void openEditorPath(state.path, state.worktree);
}

function getPreviewTargets(activeUrl = selectedPreviewUrl) {
  return Array.from(detectedPreviewTargets.values()).sort((left, right) => {
    if (activeUrl) {
      if (left.url === activeUrl && right.url !== activeUrl) {
        return -1;
      }
      if (right.url === activeUrl && left.url !== activeUrl) {
        return 1;
      }
    }
    if (left.lastSeenAt !== right.lastSeenAt) {
      return right.lastSeenAt - left.lastSeenAt;
    }
    return left.url.localeCompare(right.url);
  });
}

function openPreviewTarget(url: string) {
  selectedPreviewUrl = url;
  editorSurfaceMode = "preview";
  if (lastPreviewExternalState?.url !== url) {
    lastPreviewExternalState = null;
  }
  if (lastPreviewClipboardState?.url !== url) {
    lastPreviewClipboardState = null;
  }
  setEditorSurface(true);
}

function closePreviewTarget() {
  editorSurfaceMode = "code";
  selectedPreviewUrl = "";
  lastPreviewExternalState = null;
  lastPreviewClipboardState = null;
  if (!selectedEditorKey) {
    setEditorSurface(false);
    return;
  }
  setEditorSurface(true);
}

function reloadPreviewTarget() {
  if (!selectedPreviewUrl) {
    return;
  }
  const browserFrame = document.getElementById("browser-frame") as HTMLIFrameElement | null;
  if (!browserFrame) {
    return;
  }
  browserFrame.src = selectedPreviewUrl;
}

function openPreviewTargetExternally() {
  if (!selectedPreviewUrl) {
    return;
  }
  const previewUrl = selectedPreviewUrl;
  const opened = window.open(previewUrl, "_blank", "noopener");
  lastPreviewExternalState = {
    url: previewUrl,
    at: Date.now(),
    ok: Boolean(opened),
  };
  renderEditorSurface();
  if (!opened) {
    return;
  }
}

async function copyPreviewTargetUrl() {
  if (!selectedPreviewUrl) {
    return;
  }
  const previewUrl = selectedPreviewUrl;
  try {
    await copyTextToClipboard(previewUrl);
    lastPreviewClipboardState = {
      url: previewUrl,
      at: Date.now(),
      ok: true,
    };
  } catch {
    lastPreviewClipboardState = {
      url: previewUrl,
      at: Date.now(),
      ok: false,
    };
  }
  renderEditorSurface();
}

async function copyTextToClipboard(value: string) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(value);
    return;
  }

  const textArea = document.createElement("textarea");
  textArea.value = value;
  textArea.setAttribute("readonly", "true");
  textArea.style.position = "fixed";
  textArea.style.left = "-9999px";
  document.body.appendChild(textArea);
  textArea.select();
  const copied = document.execCommand("copy");
  textArea.remove();
  if (!copied) {
    throw new Error("Clipboard copy failed");
  }
}

async function openEditorSurfacePopout() {
  const state = getCurrentEditorSurfaceState();
  if (!state) {
    return;
  }

  const key = `${POPOUT_SURFACE_STORAGE_KEY_PREFIX}${Date.now()}`;
  try {
    window.localStorage.setItem(key, JSON.stringify(state));
  } catch {
    return;
  }

  const popoutUrl = `/?popout=1&popout-key=${encodeURIComponent(key)}`;
  if (isTauri()) {
    const label = `secondary-surface-${Date.now()}`;
    const detachedWindow = new WebviewWindow(label, {
      url: popoutUrl,
      title: state.mode === "preview" ? "winsmux Preview" : "winsmux Editor",
      width: state.mode === "preview" ? 1180 : 1040,
      height: 760,
      minWidth: 720,
      minHeight: 480,
      focus: true,
    });
    setDetachedSurfaceSession(state);
    void detachedWindow.once("tauri://destroyed", () => {
      clearDetachedSurfaceSession();
    });
    return;
  }

  const popup = window.open(popoutUrl, "_blank");
  if (!popup) {
    return;
  }
  setDetachedSurfaceSession(state);
  if (detachedSurfacePollTimer !== null) {
    window.clearInterval(detachedSurfacePollTimer);
  }
  detachedSurfacePollTimer = window.setInterval(() => {
    if (popup.closed) {
      clearDetachedSurfaceSession();
    }
  }, 500);
}

function getSourceFilterLabel(filter: SourceFilter) {
  switch (filter) {
    case "all":
      return getLanguageText("All changes", "すべての変更");
    case "candidates":
      return getLanguageText("Commit candidates", "コミット候補");
    case "attention":
      return getLanguageText("Needs attention", "要確認");
    default:
      return getPaneLabelFromSourceFilter(filter) ?? filter;
  }
}

function getSelectedRunId() {
  return resolveSelectedRunId();
}

function normalizeDecisionText(value: string | null | undefined) {
  return (value || "").trim();
}

function getDecisionStatusTone(status: HandoffDecisionItem["status"]): SurfaceTone {
  switch (status) {
    case "ready":
      return "success";
    case "waiting":
      return "warning";
    case "blocked":
      return "danger";
    case "missing":
    default:
      return "info";
  }
}

function getReviewDecisionItem(
  projection: DesktopRunProjection,
  payload: DesktopExplainPayload | null,
): HandoffDecisionItem {
  const reviewState = normalizeDecisionText(projection.review_state || payload?.run.review_state).toUpperCase();
  const reviewer = payload?.review_state?.reviewer?.label || payload?.review_state?.request?.target_review_label || "";
  if (reviewState === "PASS") {
    return {
      label: getLanguageText("Review", "レビュー"),
      value: getLanguageText("Passed", "通過"),
      detail: reviewer ? getLanguageText(`Approved by ${reviewer}`, `${reviewer} が承認しました。`) : getLanguageText("Review evidence is present.", "レビュー証跡があります。"),
      status: "ready",
    };
  }
  if (reviewState === "FAIL" || reviewState === "FAILED") {
    return {
      label: getLanguageText("Review", "レビュー"),
      value: getLanguageText("Failed", "失敗"),
      detail: reviewer ? getLanguageText(`Reviewer ${reviewer} returned a blocking result.`, `${reviewer} がブロック結果を返しました。`) : getLanguageText("Review is blocking this run.", "レビューがこの実行を止めています。"),
      status: "blocked",
    };
  }
  if (reviewState === "PENDING") {
    return {
      label: getLanguageText("Review", "レビュー"),
      value: getLanguageText("Pending", "待機中"),
      detail: reviewer ? getLanguageText(`Waiting on ${reviewer}.`, `${reviewer} の確認待ちです。`) : getLanguageText("Review has been requested.", "レビューを依頼済みです。"),
      status: "waiting",
    };
  }
  return {
    label: getLanguageText("Review", "レビュー"),
    value: getLanguageText("Not requested", "未依頼"),
    detail: projection.review_state || getLanguageText("No review state has been recorded.", "レビュー状態はまだ記録されていません。"),
    status: "missing",
  };
}

function getVerificationDecisionItem(
  projection: DesktopRunProjection,
  payload: DesktopExplainPayload | null,
): HandoffDecisionItem {
  const outcome = normalizeDecisionText(projection.verification_outcome || payload?.evidence_digest.verification_outcome).toUpperCase();
  if (outcome === "PASS") {
    return {
      label: getLanguageText("Verification", "検証"),
      value: getLanguageText("Passed", "通過"),
      detail: getLanguageText("Latest evidence reports a passing verification outcome.", "最新の証跡では検証が通っています。"),
      status: "ready",
    };
  }
  if (outcome === "FAIL" || outcome === "FAILED" || outcome === "BLOCK") {
    return {
      label: getLanguageText("Verification", "検証"),
      value: outcome,
      detail: getLanguageText("Verification must be resolved before release or merge.", "リリースまたはマージ前に検証失敗を解消してください。"),
      status: "blocked",
    };
  }
  if (outcome === "PARTIAL" || outcome === "WARN" || outcome === "WARNING") {
    return {
      label: getLanguageText("Verification", "検証"),
      value: outcome,
      detail: getLanguageText("Partial evidence needs an operator decision.", "部分的な証跡にはオペレーター判断が必要です。"),
      status: "waiting",
    };
  }
  return {
    label: getLanguageText("Verification", "検証"),
    value: getLanguageText("Missing", "未検出"),
    detail: getLanguageText("Open Explain or wait for the run to emit verification evidence.", "説明を開くか、実行が検証証跡を出すまで待ってください。"),
    status: "missing",
  };
}

function getSecurityDecisionItem(
  projection: DesktopRunProjection,
  payload: DesktopExplainPayload | null,
): HandoffDecisionItem {
  const securityText = normalizeDecisionText(projection.security_blocked || payload?.evidence_digest.security_blocked).toUpperCase();
  if (securityText === "BLOCK" || securityText === "BLOCKED" || securityText === "TRUE") {
    return {
      label: getLanguageText("Security", "セキュリティ"),
      value: getLanguageText("Blocked", "ブロック中"),
      detail: getLanguageText("Security policy is blocking this run.", "セキュリティ方針がこの実行を止めています。"),
      status: "blocked",
    };
  }
  if (securityText === "ALLOW" || securityText === "PASS" || securityText === "FALSE") {
    return {
      label: getLanguageText("Security", "セキュリティ"),
      value: getLanguageText("Clear", "問題なし"),
      detail: getLanguageText("No security block is reported for the selected run.", "選択中の実行にセキュリティブロックはありません。"),
      status: "ready",
    };
  }
  return {
    label: getLanguageText("Security", "セキュリティ"),
    value: getLanguageText("Unknown", "不明"),
    detail: getLanguageText("No security verdict is visible yet.", "セキュリティ判定はまだ表示されていません。"),
    status: "missing",
  };
}

function getOperatorDecisionItem(
  projection: DesktopRunProjection,
  payload: DesktopExplainPayload | null,
): HandoffDecisionItem {
  const nextAction = normalizeDecisionText(projection.next_action || payload?.explanation.next_action);
  const lowerNextAction = nextAction.toLowerCase();
  const reviewState = normalizeDecisionText(projection.review_state || payload?.run.review_state).toUpperCase();
  if (
    lowerNextAction.includes("needs_user_decision") ||
    lowerNextAction.includes("human") ||
    lowerNextAction.includes("draft_pr") ||
    lowerNextAction.includes("approve")
  ) {
    return {
      label: getLanguageText("Operator", "オペレーター"),
      value: getLanguageText("Decision needed", "判断が必要"),
      detail: nextAction,
      status: "waiting",
    };
  }
  if (projection.activity === "blocked" || lowerNextAction === "blocked") {
    return {
      label: getLanguageText("Operator", "オペレーター"),
      value: getLanguageText("Blocked", "ブロック中"),
      detail: projection.detail || nextAction || getLanguageText("Run is blocked.", "実行が止まっています。"),
      status: "blocked",
    };
  }
  if (reviewState === "PASS" && !nextAction) {
    return {
      label: getLanguageText("Operator", "オペレーター"),
      value: getLanguageText("Ready to package", "パッケージ化可能"),
      detail: getLanguageText("Review has passed and no extra decision is visible.", "レビューは通過済みで、追加判断は見えていません。"),
      status: "ready",
    };
  }
  return {
    label: getLanguageText("Operator", "オペレーター"),
    value: nextAction || getLanguageText("Monitoring", "監視中"),
    detail: projection.detail || projection.summary || getLanguageText("No operator decision is visible yet.", "オペレーター判断はまだ表示されていません。"),
    status: nextAction ? "waiting" : "missing",
  };
}

function renderHandoffCockpit(root: HTMLElement, projection: DesktopRunProjection | null) {
  root.innerHTML = "";
  if (!projection) {
    const empty = document.createElement("div");
    empty.className = "context-empty-state";
    empty.innerHTML =
      `<div class="context-label">${getLanguageText("No selected run", "実行が選択されていません")}</div>` +
      `<div class="context-value">${getLanguageText("A run must be selected before decision gates can be shown.", "判断項目を表示するには実行を選択してください。")}</div>`;
    root.appendChild(empty);
    return;
  }

  const payload = desktopExplainCache.get(projection.run_id) ?? null;
  const items = [
    getReviewDecisionItem(projection, payload),
    getVerificationDecisionItem(projection, payload),
    getSecurityDecisionItem(projection, payload),
    getOperatorDecisionItem(projection, payload),
  ];

  for (const item of items) {
    const row = document.createElement("div");
    row.className = "handoff-cockpit-row";
    row.dataset.tone = getDecisionStatusTone(item.status);

    const title = document.createElement("div");
    title.className = "handoff-cockpit-title";
    title.textContent = item.label;

    const value = document.createElement("div");
    value.className = "handoff-cockpit-value";
    value.textContent = item.value;

    const detail = document.createElement("div");
    detail.className = "handoff-cockpit-detail";
    detail.textContent = item.detail;

    row.appendChild(title);
    row.appendChild(value);
    row.appendChild(detail);
    root.appendChild(row);
  }
}

function renderExperimentContext() {
  const overviewRoot = document.getElementById("experiment-overview-cards");
  const detailRoot = document.getElementById("experiment-detail-list");
  if (!overviewRoot || !detailRoot) {
    return;
  }

  overviewRoot.innerHTML = "";
  detailRoot.innerHTML = "";

  const selectedProjection = getPrimaryRunProjection();
  if (!selectedProjection) {
    const empty = document.createElement("div");
    empty.className = "experiment-detail-card";
    empty.dataset.tone = "info";
    empty.innerHTML =
      `<div class="experiment-detail-title">${getLanguageText("No experiment run", "実験用の実行はありません")}</div>` +
      `<div class="experiment-detail-body">${getLanguageText("Select a run to inspect observation, compare, and playbook context.", "観測、比較、手順の文脈を確認するには実行を選択してください。")}</div>`;
    detailRoot.appendChild(empty);
    return;
  }

  const payload = desktopExplainCache.get(selectedProjection.run_id) ?? null;
  if (!payload) {
    const empty = document.createElement("div");
    empty.className = "experiment-detail-card";
    empty.dataset.tone = "info";
    empty.innerHTML =
      `<div class="experiment-detail-title">${getLanguageText("Explain not loaded", "説明は未読込です")}</div>` +
      `<div class="experiment-detail-body">${getLanguageText("Open Explain to load experiment context for the selected run.", "選択中の実行について実験文脈を読み込むには、説明を開いてください。")}</div>`;
    detailRoot.appendChild(empty);
    return;
  }

  const observationPack = getObservationPack(payload);
  const consultationPacket = getConsultationPacket(payload);
  const consultationSummary = getConsultationSummary(payload);
  const experimentPacket = payload.run.experiment_packet;
  const explainFingerprint = getExplainPayloadFingerprint(payload);
  const promotedCandidate = promotedRunCandidates.get(selectedProjection.run_id) ?? null;
  const hasPromotedCandidate =
    promotedCandidate !== null &&
    promotedCandidate.fingerprint === explainFingerprint;
  const isPromotedCandidate = hasPromotedCandidate &&
    promotedCandidate !== null &&
    desktopSummaryRefreshSerial <= promotedCandidate.collapseAfterRefreshSerial;
  const showLastExport = hasPromotedCandidate && !isPromotedCandidate;
  const promotedCandidateRef = hasPromotedCandidate && promotedCandidate
    ? summarizeArtifactRef(promotedCandidate.candidateRef)
    : "";
  const comparePeer = getComparePeerProjection(
    selectedProjection,
    payload.run.parent_run_id || null,
  );
  const comparePairKey = comparePeer
    ? getComparePairKey(selectedProjection.run_id, comparePeer.run_id)
    : "";
  const compareResult = comparePairKey
    ? desktopRunCompareCache.get(comparePairKey) ?? null
    : null;
  const compareInFlight = comparePairKey
    ? comparingRunPairKeys.has(comparePairKey)
    : false;
  const compareWinnerRunId = compareResult?.recommend.winning_run_id || null;
  const compareWinnerProjection = compareWinnerRunId
    ? getRunProjectionByRunId(compareWinnerRunId)
    : null;
  const compareLeftProjection = compareResult
    ? (getRunProjectionByRunId(compareResult.left.run_id) ?? selectedProjection)
    : selectedProjection;
  const compareRightProjection = compareResult
    ? (getRunProjectionByRunId(compareResult.right.run_id) ?? comparePeer)
    : comparePeer;
  const compareWinnerConfidence = compareResult
    ? (
      compareResult.left.run_id === compareWinnerRunId
        ? (compareResult.left.confidence ?? null)
        : (
          compareResult.right.run_id === compareWinnerRunId
            ? (compareResult.right.confidence ?? null)
            : null
        )
    )
    : null;
  const compareLoserSlot = compareResult
    ? (
      compareResult.left.run_id === compareWinnerRunId
        ? (compareRightProjection?.label || compareResult.right.label || compareResult.right.run_id)
        : (compareLeftProjection?.label || compareResult.left.label || compareResult.left.run_id)
    )
    : "";
  const canPickCompareWinner = Boolean(
    compareResult &&
    !compareResult.recommend.reconcile_consult &&
    compareWinnerProjection,
  );
  const persistedCompareTargetMatchesPeer = Boolean(
    comparePeer &&
    consultationPacket.target_slot &&
    consultationPacket.target_slot === (comparePeer.label || comparePeer.run_id),
  );
  const hasPersistedCompareWinner =
    !compareResult &&
    consultationPacket.kind === "consult_result" &&
    consultationPacket.mode === "final" &&
    persistedCompareTargetMatchesPeer;
  const compareWinnerLabel = compareResult
    ? getCompareWinnerLabel(compareResult)
    : "";
  const compareDifferenceSummary = compareResult
    ? summarizeCompareDifferenceFields(compareResult)
    : "";
  const compareConflictRadar = compareResult
    ? getCompareConflictRadar(compareResult)
    : null;
  const compareFileSummary = compareResult
    ? [
        compareResult.shared_changed_files.length > 0
          ? `shared ${summarizeChangedFiles(compareResult.shared_changed_files, 2)}`
          : "",
        compareResult.left_only_changed_files.length > 0
          ? `${compareResult.left.label || "left"} ${summarizeChangedFiles(compareResult.left_only_changed_files, 2)}`
          : "",
        compareResult.right_only_changed_files.length > 0
          ? `${compareResult.right.label || "right"} ${summarizeChangedFiles(compareResult.right_only_changed_files, 2)}`
          : "",
      ]
        .filter((value) => Boolean(value))
        .join(" · ")
    : "";
  const compareTone: SurfaceTone = compareResult
    ? (
      compareConflictRadar?.level === "high"
        ? "danger"
        : (
          compareConflictRadar?.level === "medium"
            ? "warning"
            : (compareWinnerLabel ? "success" : "info")
        )
    )
    : hasPersistedCompareWinner
      ? "success"
    : "info";
  const compareBody = compareResult
    ? [
        compareResult.recommend.reconcile_consult
          ? "Reconcile consult"
          : `Winner ${compareWinnerLabel || "not decided"}`,
        compareResult.recommend.next_action || "reconcile_consult",
        [
          compareConflictRadar?.summary || "",
          compareDifferenceSummary,
          compareFileSummary,
        ]
          .filter((value) => Boolean(value))
          .join(" · ") || "No material diff",
      ]
        .filter((value) => Boolean(value))
        .join(" · ")
      : comparePeer
      ? (
        hasPersistedCompareWinner
          ? [
              "Winner selected",
              consultationPacket.recommendation || selectedProjection.label || selectedProjection.run_id,
              consultationPacket.target_slot ? `vs ${consultationPacket.target_slot}` : "",
              consultationPacket.next_test || "winner persisted",
            ]
              .filter((value) => Boolean(value))
              .join(" · ")
          : [
          `vs ${comparePeer.label || comparePeer.run_id}`,
          comparePeer.branch || "no branch",
          comparePeer.review_state || "pending",
        ]
              .filter((value) => Boolean(value))
              .join(" · ")
      )
      : "Compare needs another surfaced run.";
  const compareOverviewValue = compareInFlight
    ? "Refreshing compare"
    : (
      compareResult
        ? (
          compareResult.recommend.reconcile_consult
            ? "Consult before pick"
            : `Winner ${compareWinnerLabel || "not decided"}`
        )
        : (
          hasPersistedCompareWinner
            ? "Winner selected"
        : (comparePeer ? `vs ${comparePeer.label || comparePeer.run_id}` : "Need peer")
        )
    );
  const compareDisplayBody = compareInFlight
    ? `Refreshing compare result${compareResult ? "..." : " from current runs..." }`
    : compareBody;
  const compareCandidateSummary = compareResult
    ? [
        compareWinnerLabel ? `winner ${compareWinnerLabel}` : "",
        compareConflictRadar?.summary || "",
        `diffs ${compareResult.differences.length}`,
      ]
        .filter((value) => Boolean(value))
        .join(" · ")
    : "";
  const canPromoteCandidate =
    isDesktopRunPromotable(payload.run) &&
    !promotingRunIds.has(selectedProjection.run_id) &&
    !pendingPromotedRunRefreshIds.has(selectedProjection.run_id) &&
    !isPromotedCandidate;

  const overviewCards = [
    {
      label: "Hypothesis",
      value: experimentPacket.hypothesis || selectedProjection.hypothesis || "No hypothesis",
    },
    {
      label: "Observe",
      value: observationPack.changed_files.length > 0
        ? `${observationPack.changed_files.length} files`
        : (observationPack.working_tree_summary || "No observation pack"),
    },
    {
      label: "Consult",
      value: consultationSummary.next_test || consultationPacket.recommendation || "No consult",
    },
    {
      label: "Compare",
      value: compareOverviewValue,
    },
    {
      label: "Candidate",
      value: isPromotedCandidate
        ? "Exported"
        : (experimentPacket.next_action || payload.explanation.next_action || "No candidate"),
    },
  ];

  for (const item of overviewCards) {
    const card = document.createElement("div");
    card.className = "source-overview-card";
    card.innerHTML = `<div class="context-label">${item.label}</div><div class="source-overview-value">${item.value}</div>`;
    overviewRoot.appendChild(card);
  }

  const experimentCards = [
    {
      title: "Observation Pack",
      body:
        observationPack.working_tree_summary ||
        observationPack.failing_command ||
        "Observation details will appear after the selected run emits an observation pack.",
      tone: "focus" as SurfaceTone,
      details: [
        { label: "files", value: `${observationPack.changed_files.length}` },
        { label: "test", value: observationPack.test_plan[0] || "n/a" },
        { label: "slot", value: observationPack.slot || "n/a" },
      ],
    },
    {
      title: "Compare",
      body: compareDisplayBody,
      tone: compareTone,
      actionLabel: comparePeer ? "Compare" : undefined,
      actionPendingLabel: "Comparing...",
      actionDisabled: compareInFlight,
      actionType: "compare" as const,
      actionRunId: selectedProjection.run_id,
      actionPeerRunId: comparePeer?.run_id,
      secondaryActionLabel: canPickCompareWinner ? "Pick winner" : undefined,
      secondaryActionType: "pick_winner" as const,
      secondaryActionRunId: compareWinnerProjection?.run_id,
      secondaryActionPeerSlot: compareLoserSlot || undefined,
      secondaryActionPeerRunId: compareResult
        ? (
          compareResult.left.run_id === compareWinnerRunId
            ? compareResult.right.run_id
            : compareResult.left.run_id
        )
        : undefined,
      secondaryActionRecommendation: compareResult
        ? `Pick ${compareWinnerLabel || compareWinnerProjection?.label || compareWinnerProjection?.run_id || "winner"}`
        : undefined,
      secondaryActionConfidence: compareWinnerConfidence,
      secondaryActionNextTest: compareResult?.recommend.next_action || undefined,
      secondaryActionDisabled: compareWinnerRunId ? pickingWinnerRunIds.has(compareWinnerRunId) : false,
      secondaryActionPendingLabel: "Picking...",
      details: compareResult
        ? [
            {
              label: "peer",
              value: comparePeer?.label || compareResult.right.label || compareResult.right.run_id,
            },
            { label: "winner", value: compareWinnerLabel || "none" },
            {
              label: "risk",
              value: compareConflictRadar?.label || "n/a",
              tone: compareConflictRadar?.tone,
            },
            {
              label: "hotspots",
              value: `${compareConflictRadar?.hotspots.length ?? 0}`,
              tone: compareConflictRadar?.tone,
            },
            { label: "diffs", value: `${compareResult.differences.length}` },
            {
              label: "delta",
              value: compareResult.confidence_delta !== null
                ? formatConfidencePercent(Math.abs(compareResult.confidence_delta))
                : "n/a",
            },
            { label: "shared", value: `${compareResult.shared_changed_files.length}` },
            { label: "left", value: `${compareResult.left_only_changed_files.length}` },
            { label: "right", value: `${compareResult.right_only_changed_files.length}` },
          ]
        : hasPersistedCompareWinner
          ? [
              { label: "winner", value: selectedProjection.label || selectedProjection.run_id },
              { label: "target", value: consultationPacket.target_slot || "n/a" },
              { label: "next", value: consultationPacket.next_test || "n/a" },
            ]
        : [
            { label: "peer", value: comparePeer?.label || "n/a" },
            { label: "changed", value: `${payload.evidence_digest.changed_file_count}` },
            { label: "verify", value: payload.evidence_digest.verification_outcome || "n/a" },
          ],
      lines: compareResult
        ? [
            {
              label: "Selected run",
              value: [
                compareResult.left.branch || compareLeftProjection?.branch || "no branch",
                compareLeftProjection?.head_short || "",
                compareResult.left.review_state || compareResult.left.state,
                compareResult.left.next_action || "idle",
              ]
                .filter((value) => Boolean(value))
                .join(" · "),
            },
            {
              label: "Peer run",
              value: [
                compareResult.right.branch || compareRightProjection?.branch || "no branch",
                compareRightProjection?.head_short || "",
                compareResult.right.review_state || compareResult.right.state,
                compareResult.right.next_action || "idle",
              ]
                .filter((value) => Boolean(value))
                .join(" · "),
            },
            {
              label: "Decision",
              value: compareResult.recommend.reconcile_consult
                ? "consult before pick"
                : [
                  compareWinnerLabel || "no winner",
                  compareResult.confidence_delta !== null
                    ? formatConfidencePercent(Math.abs(compareResult.confidence_delta))
                    : "",
                ]
                  .filter((value) => Boolean(value))
                  .join(" · "),
            },
            {
              label: "Decision basis",
              value: [
                compareDifferenceSummary,
                compareFileSummary,
              ]
                .filter((value) => Boolean(value))
                .join(" · ") || "none",
            },
            {
              label: "Recommendation",
              value: compareResult.recommend.next_action || "reconcile_consult",
            },
            {
              label: "Difference fields",
              value: compareDifferenceSummary || "none",
            },
            {
              label: "Conflict radar",
              value: compareConflictRadar?.summary || "low risk · no shared files",
            },
            buildExperimentFileLine(
              "Hotspot files",
              compareResult.shared_changed_files,
              compareLeftProjection?.worktree || selectedProjection.worktree || "",
            ),
            buildExperimentFileLine(
              `${selectedProjection.label || "Selected"} only`,
              compareResult.left_only_changed_files,
              compareLeftProjection?.worktree || selectedProjection.worktree || "",
            ),
            buildExperimentFileLine(
              `${comparePeer?.label || compareResult.right.label || "Peer"} only`,
              compareResult.right_only_changed_files,
              compareRightProjection?.worktree || comparePeer?.worktree || "",
            ),
          ]
        : [],
    },
    {
      title: "Playbook Candidate",
      body: isPromotedCandidate
        ? `Exported as ${promotedCandidateRef}.`
        : [
          consultationPacket.recommendation ||
            experimentPacket.result ||
            experimentPacket.next_action ||
            "No playbook candidate is ready yet.",
          compareCandidateSummary,
        ]
          .filter((value) => Boolean(value))
          .join(" · "),
      tone: "success" as SurfaceTone,
      actionLabel: canPromoteCandidate ? "Promote" : undefined,
      actionPendingLabel: "Promoting...",
      actionDisabled:
        promotingRunIds.has(selectedProjection.run_id) ||
        pendingPromotedRunRefreshIds.has(selectedProjection.run_id),
      actionType: "promote" as const,
      actionRunId: selectedProjection.run_id,
      details: [
        ...(isPromotedCandidate
          ? [{ label: "exported", value: promotedCandidateRef }]
          : (showLastExport
            ? [{ label: "last export", value: promotedCandidateRef }]
            : [])),
        { label: "next", value: experimentPacket.next_action || "n/a" },
        { label: "consult", value: consultationSummary.next_test || "n/a" },
        { label: "confidence", value: formatConfidencePercent(experimentPacket.confidence || 0) },
      ],
    },
  ];

  for (const item of experimentCards) {
    const card = document.createElement("div");
    card.className = "experiment-detail-card";
    card.dataset.tone = item.tone;
    card.innerHTML =
      `<div class="experiment-detail-title">${item.title}</div>` +
      `<div class="experiment-detail-body">${item.body}</div>`;

    const meta = document.createElement("div");
    meta.className = "experiment-detail-meta";
    for (const detail of item.details) {
      const pill = document.createElement("span");
      pill.className = "experiment-detail-pill";
      if ("tone" in detail && detail.tone) {
        pill.dataset.tone = detail.tone;
      }
      pill.innerHTML = `<span class="experiment-detail-pill-label">${detail.label}</span><span>${detail.value}</span>`;
      meta.appendChild(pill);
    }
    card.appendChild(meta);

    if (item.lines && item.lines.length > 0) {
      const lineList = document.createElement("div");
      lineList.className = "experiment-detail-lines";
      for (const line of item.lines as ExperimentDetailLine[]) {
        const row = document.createElement("div");
        row.className = "experiment-detail-line";
        row.innerHTML =
          `<span class="experiment-detail-line-label">${line.label}</span>` +
          `<span class="experiment-detail-line-value">${line.value}</span>`;
        if (line.path) {
          row.classList.add("is-actionable");
          row.tabIndex = 0;
          row.setAttribute("role", "button");
          if (line.title) {
            row.title = line.title;
          }
          row.addEventListener("click", () => {
            void openEditorPath(line.path, line.worktree || "");
          });
          row.addEventListener("keydown", (event) => {
            if (event.key === "Enter" || event.key === " ") {
              event.preventDefault();
              void openEditorPath(line.path, line.worktree || "");
            }
          });
        }
        lineList.appendChild(row);
      }
      card.appendChild(lineList);
    }

    if ((item.actionLabel || item.secondaryActionLabel) && selectedProjection.run_id) {
      const chipRow = document.createElement("div");
      chipRow.className = "timeline-chip-row";
      const appendActionButton = (
        label: string,
        type: "compare" | "promote" | "focus" | "pick_winner",
        runId: string,
        disabled?: boolean,
        pendingLabel?: string,
        peerRunId?: string,
        peerSlot?: string,
        recommendation?: string,
        confidence?: number | null,
        nextTest?: string,
      ) => {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "timeline-chip";
        button.textContent = disabled && pendingLabel ? pendingLabel : label;
        button.disabled = disabled ?? false;
        button.addEventListener("click", async () => {
          void recordOperatorDogfoodEvent({
            actionType: type === "compare" ? "retry" : type === "focus" ? "command" : "approval",
            inputSource: "shortcut",
            runId,
            taskRef: runId,
            taskClass: `details-${type}`,
            payload: { type, runId, peerRunId, peerSlot, recommendation, confidence, nextTest },
          });
          if (type === "compare" && peerRunId) {
            await compareSelectedRunWithPeer(runId, peerRunId);
            return;
          }
          if (type === "focus") {
            await focusRunInContext(runId);
            return;
          }
          if (type === "pick_winner") {
            await pickCompareWinner(
              runId,
              peerRunId || "",
              peerSlot || "",
              recommendation || "",
              confidence ?? null,
              nextTest || "",
            );
            return;
          }
          await promoteSelectedRunTactic(runId);
        });
        chipRow.appendChild(button);
      };

      if (item.actionLabel) {
        appendActionButton(
          item.actionLabel,
          item.actionType,
          item.actionRunId ?? selectedProjection.run_id,
          item.actionDisabled,
          item.actionPendingLabel,
          item.actionPeerRunId,
        );
      }
      if (item.secondaryActionLabel && item.secondaryActionType && item.secondaryActionRunId) {
        appendActionButton(
          item.secondaryActionLabel,
          item.secondaryActionType,
          item.secondaryActionRunId,
          item.secondaryActionDisabled,
          item.secondaryActionPendingLabel,
          item.secondaryActionPeerRunId,
          item.secondaryActionPeerSlot,
          item.secondaryActionRecommendation,
          item.secondaryActionConfidence,
          item.secondaryActionNextTest,
        );
      }
      card.appendChild(chipRow);
    }
    detailRoot.appendChild(card);
  }
}

function renderContextPanel() {
  const sectionRoot = document.getElementById("context-sections");
  const handoffRoot = document.getElementById("handoff-cockpit-list");
  if (!sectionRoot || !handoffRoot) {
    return;
  }

  const visibleChanges = getVisibleSourceChanges();
  const primaryChange = getPrimarySourceChange(visibleChanges);
  const selectedProjection = getPrimaryRunProjection();

  sectionRoot.innerHTML = "";
  const resolvedContextSections = [
    { label: getLanguageText("next", "次"), value: selectedProjection?.next_action || getLanguageText("Open Explain", "説明を開く") },
    { label: getLanguageText("run", "実行"), value: selectedProjection?.run_id || primaryChange?.run || getLanguageText("No active run", "実行はありません") },
    { label: getLanguageText("pane", "ペイン"), value: primaryChange?.paneLabel ?? getLanguageText("No pane label", "ペイン名はありません") },
    { label: getLanguageText("branch", "ブランチ"), value: selectedProjection?.branch || primaryChange?.branch || getLanguageText("No branch", "ブランチはありません") },
    { label: getLanguageText("worktree", "ワークツリー"), value: selectedProjection?.worktree || primaryChange?.worktree || getLanguageText("Project root", "プロジェクトルート") },
    { label: getLanguageText("review", "レビュー"), value: selectedProjection?.review_state || primaryChange?.review || getLanguageText("No review state", "レビュー状態はありません") },
  ];
  for (const item of resolvedContextSections) {
    const row = document.createElement("div");
    row.className = "context-section";
    row.innerHTML = `<div class="context-label">${item.label}</div><div class="context-value">${item.value}</div>`;
    sectionRoot.appendChild(row);
  }

  renderHandoffCockpit(handoffRoot, selectedProjection ?? null);
  renderExperimentContext();
  hideDetailsPanelExtraSections();

  renderComposerRemoteReferences();
}

function hideDetailsPanelExtraSections() {
  const hiddenIds = [
    "context-experiments-title",
    "experiment-overview-cards",
    "experiment-detail-list",
    "context-ports-title",
    "preview-target-list",
    "context-source-title",
    "source-overview-cards",
    "context-files-title",
    "context-file-list",
  ];

  for (const id of hiddenIds) {
    const element = document.getElementById(id);
    if (!element) {
      continue;
    }
    element.innerHTML = "";
    element.hidden = true;
  }
}

function getSourceEntryTone(entry: SourceChange): SurfaceTone {
  if (entry.needsAttention || entry.risk === "high") {
    return "danger";
  }
  if (entry.commitCandidate) {
    return "success";
  }
  if (entry.risk === "medium") {
    return "warning";
  }
  return "info";
}

function getFooterReviewTone(reviewState: string | undefined): SurfaceTone {
  switch ((reviewState || "").toUpperCase()) {
    case "PASS":
      return "success";
    case "PENDING":
      return "warning";
    case "FAIL":
    case "FAILED":
      return "danger";
    default:
      return "info";
  }
}

function getFooterNextTone(nextAction: string | undefined): SurfaceTone {
  switch ((nextAction || "").toLowerCase()) {
    case "blocked":
    case "reconcile_consult":
      return "warning";
    case "review":
    case "dispatch":
      return "focus";
    default:
      return "info";
  }
}

function getFooterSurfaceStatus() {
  if (commandBarOpen) {
    return "Actions";
  }
  if (settingsSheetOpen) {
    return "Settings";
  }
  if (selectedPreviewUrl) {
    return "Preview";
  }
  if (editorSurfaceOpen) {
    return "Code";
  }
  if (terminalDrawerOpen) {
    return "Terminal";
  }
  return "Shell";
}

function getFooterOperatorStatus(projection: DesktopRunProjection | undefined) {
  if (!projection) {
    return {
      label: desktopSummarySnapshot ? "Monitoring" : "Ready",
      tone: desktopSummarySnapshot ? "info" as SurfaceTone : "success" as SurfaceTone,
    };
  }

  if (projection.activity === "blocked") {
    return { label: projection.detail || "Blocked", tone: "danger" as SurfaceTone };
  }
  if (projection.activity === "completed") {
    return { label: projection.detail || "Completed", tone: "success" as SurfaceTone };
  }
  if (projection.activity === "waiting_for_input") {
    return { label: projection.detail || projection.phase || "Waiting", tone: "warning" as SurfaceTone };
  }

  const taskState = (projection.task_state || "").toLowerCase();
  if (taskState === "blocked") {
    return { label: "Blocked", tone: "danger" as SurfaceTone };
  }
  if (taskState === "commit_ready") {
    return { label: "Commit ready", tone: "success" as SurfaceTone };
  }
  if (taskState === "completed" || taskState === "task_completed" || taskState === "done") {
    return { label: "Completed", tone: "success" as SurfaceTone };
  }
  if (projection.verification_outcome) {
    return {
      label: `Verify ${projection.verification_outcome}`,
      tone: projection.verification_outcome.toUpperCase() === "PASS" ? "success" as SurfaceTone : "warning" as SurfaceTone,
    };
  }
  if (projection.next_action) {
    return {
      label: projection.next_action,
      tone: getFooterNextTone(projection.next_action),
    };
  }
  return {
    label: projection.detail || projection.activity || projection.task_state || "Tracking",
    tone: "info" as SurfaceTone,
  };
}

function getFooterSettingsTone(status: string): SurfaceTone {
  switch (status) {
    case "Draft":
      return "warning";
    case "Editing":
      return "info";
    case "Ready":
      return "focus";
    case "Saved":
      return "success";
    default:
      return "accent";
  }
}

function getFooterNotificationTone(count: number): SurfaceTone {
  if (count > 0) {
    return "warning";
  }
  return "success";
}

function getFooterContextItem(settingsStatus: string): FooterStatusItem {
  if (commandBarOpen) {
    const actions = getFilteredCommandActions();
    const activeAction = actions[Math.min(selectedCommandIndex, Math.max(0, actions.length - 1))];
    const query = commandBarQuery.trim();
    return {
      label: "Details",
      value: query ? `Search ${query}` : (activeAction?.label || "Search actions"),
      tone: "focus",
    };
  }

  if (settingsSheetOpen) {
    return {
      label: "Details",
      value: `Settings ${settingsStatus}`,
      tone: getFooterSettingsTone(settingsStatus),
    };
  }

  if (selectedPreviewUrl) {
    const previewTarget = detectedPreviewTargets.get(selectedPreviewUrl);
    if (previewTarget) {
      return {
        label: "Details",
        value: `${previewTarget.portLabel} · ${previewTarget.sourceLabel}`,
        tone: "accent",
      };
    }
  }

  if (editorSurfaceOpen) {
    const editors = getEditorFiles();
    const selected = editors.find((editor) => editor.key === selectedEditorKey) || editors[0];
    if (selected) {
      return {
        label: "Details",
        value: selected.path.split("/").pop() ?? selected.path,
        tone: selected.origin === "context" ? "focus" : "info",
      };
    }
  }

  if (terminalDrawerOpen) {
    return {
      label: "Details",
      value: "Utility drawer",
      tone: "info",
    };
  }

  return {
    label: "Details",
    value: "Ctrl+K",
    tone: "accent",
  };
}

function getFooterItems(): { left: FooterStatusItem[]; right: FooterStatusItem[] } {
  const selectedProjection = getPrimaryRunProjection();
  const modeLabel = getComposerModeLabel(activeComposerMode);
  const inboxCount = desktopSummarySnapshot?.inbox.summary.item_count ?? 0;
  const notificationStatus = desktopSummarySnapshot
    ? (inboxCount > 0 ? getLanguageText(`${inboxCount} items`, `${inboxCount}件`) : getLanguageText("none", "なし"))
    : getLanguageText("none", "なし");
  const runStatus = selectedProjection?.label || selectedProjection?.run_id || "No run selected";
  const reviewStatus = selectedProjection?.review_state || "No review";
  const nextStatus = selectedProjection?.next_action || "idle";
  const operatorStatus = getFooterOperatorStatus(selectedProjection ?? undefined);
  const hasThemeDraft = Boolean(settingsDraftState && !themeStatesEqual(settingsDraftState, themeState));
  const hasRuntimeDraft = Boolean(runtimeRoleDraftState && !runtimeRolePreferencesEqual(runtimeRoleDraftState, runtimeRolePreferences));
  const settingsStatus = hasThemeDraft || hasRuntimeDraft
    ? "Draft"
    : (settingsSheetOpen ? "Editing" : "Saved");
  const surfaceStatus = getFooterSurfaceStatus();
  const contextItem = getFooterContextItem(settingsStatus);

  return {
    left: [
      { label: "Mode", value: modeLabel, tone: "focus" },
      { label: "Surface", value: surfaceStatus },
      contextItem,
      { label: "Settings", value: settingsStatus, tone: getFooterSettingsTone(settingsStatus) },
    ],
    right: [
      { label: "Run", value: runStatus },
      { label: "Operator", value: operatorStatus.label, tone: operatorStatus.tone },
      { label: "Review", value: reviewStatus, tone: getFooterReviewTone(selectedProjection?.review_state) },
      { label: "Next", value: nextStatus, tone: getFooterNextTone(selectedProjection?.next_action) },
      { label: getLanguageText("Notifications", "通知"), value: notificationStatus, tone: getFooterNotificationTone(inboxCount) },
    ],
  };
}

function cloneThemeState(state: ThemeState): ThemeState {
  return {
    theme: state.theme,
    density: state.density,
    wrapMode: state.wrapMode,
    codeFont: state.codeFont,
    codeFontFamily: state.codeFontFamily,
    editorFontSize: state.editorFontSize,
    voiceShortcut: state.voiceShortcut,
    focusMode: state.focusMode,
    language: state.language,
  };
}

function themeStatesEqual(left: ThemeState, right: ThemeState) {
  return left.theme === right.theme
    && left.density === right.density
    && left.wrapMode === right.wrapMode
    && left.codeFont === right.codeFont
    && left.codeFontFamily === right.codeFontFamily
    && left.editorFontSize === right.editorFontSize
    && left.voiceShortcut === right.voiceShortcut
    && left.focusMode === right.focusMode
    && left.language === right.language;
}

function defaultRuntimeRolePreferences(): RuntimeRolePreference[] {
  return [
    { ...lockedOperatorRuntimePreference },
    {
      roleId: "worker",
      provider: "codex",
      model: "provider-default",
      modelSource: "provider-default",
      reasoningEffort: "provider-default",
    },
    {
      roleId: "reviewer",
      provider: "codex",
      model: "gpt-5.3-codex-spark",
      modelSource: "cli-discovery",
      reasoningEffort: "high",
    },
  ];
}

function cloneRuntimeRolePreferences(state: RuntimeRolePreference[]) {
  return state.map((item) => ({ ...item }));
}

function normalizeRuntimeRolePreference(value: Partial<RuntimeRolePreference>, fallback: RuntimeRolePreference): RuntimeRolePreference {
  if (fallback.roleId === "operator") {
    return { ...lockedOperatorRuntimePreference };
  }
  const provider = runtimeProviderOptions.find((item) => item.value === value.provider)?.value ?? fallback.provider;
  const modelSource = runtimeModelSourceOptions.find((item) => item.value === value.modelSource)?.value ?? fallback.modelSource;
  const reasoningEffort = runtimeReasoningOptions.find((item) => item.value === value.reasoningEffort)?.value ?? fallback.reasoningEffort;
  const model = typeof value.model === "string" && value.model.trim() ? value.model.trim() : fallback.model;
  return {
    roleId: fallback.roleId,
    provider,
    model,
    modelSource,
    reasoningEffort,
  };
}

function readStoredRuntimeRolePreferences(): RuntimeRolePreference[] {
  const defaults = defaultRuntimeRolePreferences();
  try {
    const rawValue = window.localStorage.getItem(RUNTIME_ROLE_PREFERENCES_STORAGE_KEY);
    if (!rawValue) {
      return defaults;
    }

    const parsed = JSON.parse(rawValue) as Partial<RuntimeRolePreference>[] | { roles?: Partial<RuntimeRolePreference>[] };
    const entries = Array.isArray(parsed) ? parsed : (Array.isArray(parsed.roles) ? parsed.roles : []);
    return defaults.map((fallback) => {
      const stored = entries.find((item) => item.roleId === fallback.roleId) ?? {};
      return normalizeRuntimeRolePreference(stored, fallback);
    });
  } catch {
    return defaults;
  }
}

function persistRuntimeRolePreferences() {
  try {
    window.localStorage.setItem(RUNTIME_ROLE_PREFERENCES_STORAGE_KEY, JSON.stringify(runtimeRolePreferences));
    return true;
  } catch (error) {
    console.warn("Failed to persist runtime role preferences", error);
    return false;
  }
}

function defaultComposerSessionControls(): ComposerSessionControlState {
  return {
    permissionMode: "acceptEdits",
    model: "opus-4.7-1m",
    effort: "xhigh",
    voiceDraftMode: "raw",
    fastModeEnabled: false,
    fastModeTogglePending: false,
  };
}

function normalizeComposerSessionControls(value: Partial<ComposerSessionControlState> | null | undefined) {
  const fallback = defaultComposerSessionControls();
  const model = composerModelOptions.find((item) => item.value === value?.model)?.value ?? fallback.model;
  const fastModeCompatible = isComposerFastModeCompatible(model);
  const storedFastModeEnabled =
    typeof value?.fastModeEnabled === "boolean" ? value.fastModeEnabled : fallback.fastModeEnabled;
  const fastModeEnabled = fastModeCompatible ? storedFastModeEnabled : fallback.fastModeEnabled;
  const preservesPendingDisable =
    !fastModeCompatible && storedFastModeEnabled === false && value?.fastModeTogglePending === true;
  const fastModeTogglePending =
    typeof value?.fastModeTogglePending === "boolean" && (fastModeCompatible || preservesPendingDisable)
      ? value.fastModeTogglePending
      : fallback.fastModeTogglePending;
  return {
    permissionMode: normalizeComposerPermissionMode(value?.permissionMode, fallback.permissionMode),
    model,
    effort: composerEffortOptions.find((item) => item.value === value?.effort)?.value ?? fallback.effort,
    voiceDraftMode: voiceDraftModeOptions.find((item) => item.value === value?.voiceDraftMode)?.value ?? fallback.voiceDraftMode,
    fastModeEnabled,
    fastModeTogglePending,
  };
}

function normalizeComposerPermissionMode(value: string | null | undefined, fallback: ComposerPermissionMode) {
  if (value === "auto" || value === "default") {
    return "default";
  }
  return composerPermissionModeOptions.find((item) => item.value === value)?.value ?? fallback;
}

function readStoredComposerSessionControls() {
  try {
    const rawValue = window.localStorage.getItem(COMPOSER_SESSION_STORAGE_KEY);
    if (!rawValue) {
      return defaultComposerSessionControls();
    }

    return normalizeComposerSessionControls(JSON.parse(rawValue) as Partial<ComposerSessionControlState>);
  } catch {
    return defaultComposerSessionControls();
  }
}

function persistComposerSessionControls() {
  try {
    window.localStorage.setItem(
      COMPOSER_SESSION_STORAGE_KEY,
      JSON.stringify({
        permissionMode: activeComposerPermissionMode,
        model: activeComposerModel,
        effort: activeComposerEffort,
        voiceDraftMode: activeVoiceDraftMode,
        fastModeEnabled: activeComposerFastModeEnabled,
        fastModeTogglePending: activeComposerFastModeTogglePending,
      }),
    );
    return true;
  } catch (error) {
    console.warn("Failed to persist composer session controls", error);
    return false;
  }
}

function runtimeRolePreferencesEqual(left: RuntimeRolePreference[], right: RuntimeRolePreference[]) {
  if (left.length !== right.length) {
    return false;
  }

  return left.every((item, index) => {
    const other = right[index];
    return Boolean(other)
      && item.roleId === other.roleId
      && item.provider === other.provider
      && item.model === other.model
      && item.modelSource === other.modelSource
      && item.reasoningEffort === other.reasoningEffort;
  });
}

function toDesktopRuntimeRolePreferences(state: RuntimeRolePreference[]): DesktopRuntimeRolePreference[] {
  return state.map((item) => ({
    role_id: item.roleId,
    provider: item.provider,
    model: item.model,
    model_source: item.modelSource,
    reasoning_effort: item.reasoningEffort,
  }));
}

async function applyRuntimeRolePreferencesToDesktop(state: RuntimeRolePreference[]) {
  if (!isTauri()) {
    console.warn("Runtime role preferences were saved locally; desktop runtime apply is unavailable outside Tauri.");
    return;
  }

  await applyDesktopRuntimeRolePreferences(
    toDesktopRuntimeRolePreferences(state),
    activeProjectDir,
  );
}

function clampEditorFontSize(value: unknown) {
  const numericValue = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(numericValue)) {
    return DEFAULT_EDITOR_FONT_SIZE;
  }
  return Math.max(MIN_EDITOR_FONT_SIZE, Math.min(MAX_EDITOR_FONT_SIZE, Math.round(numericValue)));
}

function readStoredShellPreferences(): ShellPreferenceState | null {
  try {
    const rawValue = window.localStorage.getItem(SHELL_PREFERENCES_STORAGE_KEY);
    if (!rawValue) {
      return null;
    }

    const parsed = JSON.parse(rawValue) as Partial<ShellPreferenceState>;
    const theme = themeOptions.find((item) => item.value === parsed.theme)?.value;
    const density = densityOptions.find((item) => item.value === parsed.density)?.value;
    const wrapMode = wrapOptions.find((item) => item.value === parsed.wrapMode)?.value;
    const codeFont = codeFontOptions.find((item) => item.value === parsed.codeFont)?.value ?? "system";
    const codeFontFamily = normalizeCodeFontFamily(parsed.codeFontFamily, getCodeFontFamily(codeFont, ""));
    const editorFontSize = clampEditorFontSize(parsed.editorFontSize);
    const voiceShortcut = normalizeVoiceShortcut(parsed.voiceShortcut);
    const focusMode = focusModeOptions.find((item) => item.value === parsed.focusMode)?.value ?? "standard";
    const language = languageOptions.find((item) => item.value === parsed.language)?.value ?? "en";
    if (!theme || !density || !wrapMode) {
      return null;
    }

    const sidebarWidthValue = typeof parsed.sidebarWidth === "number" ? parsed.sidebarWidth : 292;
    const workbenchWidthValue = typeof parsed.workbenchWidth === "number" ? parsed.workbenchWidth : null;
    const wideSidebarOpen = typeof parsed.wideSidebarOpen === "boolean" ? parsed.wideSidebarOpen : true;
    const wideContextOpen = typeof parsed.wideContextOpen === "boolean" ? parsed.wideContextOpen : false;
    const workbenchOpen = typeof parsed.workbenchOpen === "boolean" ? parsed.workbenchOpen : true;
    const workbenchLayout = parsed.workbenchLayout === "3x2" || parsed.workbenchLayout === "focus" ? parsed.workbenchLayout : "2x2";
    const storedFocusedWorkbenchPaneId = typeof parsed.focusedWorkbenchPaneId === "string" && getWorkbenchPaneOrdinal(parsed.focusedWorkbenchPaneId) !== null
      ? parsed.focusedWorkbenchPaneId
      : null;

    return {
      theme,
      density,
      wrapMode,
      codeFont,
      codeFontFamily,
      editorFontSize,
      voiceShortcut,
      focusMode,
      language,
      sidebarWidth: Math.max(240, Math.min(380, Math.round(sidebarWidthValue))),
      workbenchWidth: workbenchWidthValue === null ? null : Math.max(360, Math.min(1400, Math.round(workbenchWidthValue))),
      wideSidebarOpen,
      wideContextOpen,
      workbenchOpen,
      workbenchLayout,
      focusedWorkbenchPaneId: storedFocusedWorkbenchPaneId,
    };
  } catch {
    return null;
  }
}

function persistThemeState() {
  try {
    const nextState: ShellPreferenceState = {
      theme: themeState.theme,
      density: themeState.density,
      wrapMode: themeState.wrapMode,
      codeFont: themeState.codeFont,
      codeFontFamily: themeState.codeFontFamily,
      editorFontSize: themeState.editorFontSize,
      voiceShortcut: normalizeVoiceShortcut(themeState.voiceShortcut),
      focusMode: themeState.focusMode,
      language: themeState.language,
      sidebarWidth,
      workbenchWidth,
      wideSidebarOpen: preferredWideSidebarOpen,
      wideContextOpen: preferredWideContextOpen,
      workbenchOpen: terminalDrawerOpen,
      workbenchLayout,
      focusedWorkbenchPaneId: focusedWorkbenchPaneId && panes.has(focusedWorkbenchPaneId) ? focusedWorkbenchPaneId : null,
    };
    window.localStorage.setItem(SHELL_PREFERENCES_STORAGE_KEY, JSON.stringify(nextState));
    return true;
  } catch (error) {
    console.warn("Failed to persist shell preferences", error);
    return false;
  }
}

function applyShellPreferences() {
  const shell = document.getElementById("app-shell");
  if (!shell) {
    return;
  }

  shell.dataset.theme = themeState.theme;
  shell.dataset.density = themeState.density;
  shell.dataset.wrapMode = themeState.wrapMode;
  shell.dataset.codeFont = themeState.codeFont;
  shell.dataset.focusMode = themeState.focusMode;
  shell.style.setProperty("--font-code", themeState.codeFontFamily);
  shell.style.setProperty("--editor-font-size", `${themeState.editorFontSize}px`);
  document.documentElement.lang = themeState.language;
  if (workbenchWidth !== null) {
    shell.style.setProperty("--workbench-width", `${workbenchWidth}px`);
  }
}

function clampWorkbenchWidth(width: number) {
  const body = document.getElementById("workspace-body");
  const availableWidth = body?.clientWidth ?? window.innerWidth;
  const reservedWidth =
    360 +
    (contextPanelOpen && !isNarrowLayout() ? 292 : 0) +
    (editorSurfaceOpen && !isNarrowLayout() ? 320 : 0) +
    32;
  const maxWidth = Math.max(320, Math.min(availableWidth - reservedWidth, 1600));
  return Math.max(320, Math.min(maxWidth, Math.round(width)));
}

function applyWorkbenchWidth(width: number) {
  const shell = document.getElementById("app-shell");
  if (!shell) {
    return;
  }
  workbenchWidth = clampWorkbenchWidth(width);
  shell.style.setProperty("--workbench-width", `${workbenchWidth}px`);
  const handle = document.getElementById("workbench-resizer");
  handle?.setAttribute("aria-valuenow", `${workbenchWidth}`);
  requestAnimationFrame(() => {
    fitVisibleWorkbenchPanes();
  });
}

function getLanguageText(en: string, ja: string) {
  return themeState.language === "ja" ? ja : en;
}

function setElementText(id: string, text: string) {
  const element = document.getElementById(id);
  if (element) {
    element.textContent = text;
  }
}

function setSelectorText(selector: string, text: string) {
  const element = document.querySelector(selector);
  if (element) {
    element.textContent = text;
  }
}

function setButtonLabel(id: string, text: string, ariaLabel?: string) {
  const button = document.getElementById(id);
  if (!button) {
    return;
  }

  const label = button.querySelector(".btn-label");
  if (label) {
    label.textContent = text;
  } else {
    button.textContent = text;
  }
  if (ariaLabel) {
    button.setAttribute("aria-label", ariaLabel);
  }
}

function setButtonChrome(id: string, text: string, ariaLabel?: string) {
  const button = document.getElementById(id);
  if (!button) {
    return;
  }
  button.textContent = text;
  if (ariaLabel) {
    button.setAttribute("aria-label", ariaLabel);
    button.setAttribute("title", ariaLabel);
  }
}

function setIconButtonChrome(id: string, ariaLabel: string) {
  const button = document.getElementById(id);
  if (!button) {
    return;
  }
  button.setAttribute("aria-label", ariaLabel);
  button.setAttribute("title", ariaLabel);
}

function getSidebarModeTitle(mode: SidebarMode = sidebarMode) {
  switch (mode) {
    case "source":
      return getLanguageText("Source Control", "ソース管理");
    case "evidence":
      return getLanguageText("Evidence", "証跡");
    case "workspace":
      return getLanguageText("Workspace", "作業領域");
    case "explorer":
    default:
      return getLanguageText("Explorer", "エクスプローラー");
  }
}

function updateSidebarModeTitle() {
  setElementText("sidebar-mode-title", getSidebarModeTitle());
}

function applyLanguageChrome() {
  const japanese = themeState.language === "ja";
  document.documentElement.lang = japanese ? "ja" : "en";
  setElementText("menu-project-name", "winsmux");
  setButtonChrome("menu-file-btn", japanese ? "ファイル" : "File");
  setButtonChrome("menu-edit-btn", japanese ? "編集" : "Edit");
  setButtonChrome("menu-selection-btn", japanese ? "選択" : "Selection");
  setButtonChrome("menu-view-btn", japanese ? "表示" : "View");
  setButtonChrome("menu-go-btn", japanese ? "移動" : "Go");
  setButtonChrome("menu-run-btn", japanese ? "実行" : "Run");
  setButtonChrome("menu-terminal-btn", japanese ? "端末" : "Terminal");
  setButtonChrome("menu-help-btn", japanese ? "ヘルプ" : "Help");
  setIconButtonChrome("activity-explorer-btn", japanese ? "エクスプローラー" : "Explorer");
  setIconButtonChrome("activity-search-btn", japanese ? "操作検索" : "Search actions");
  setIconButtonChrome("activity-source-btn", japanese ? "ソース管理" : "Source control");
  setIconButtonChrome("activity-evidence-btn", japanese ? "証跡" : "Evidence");
  setIconButtonChrome("activity-context-btn", japanese ? "詳細" : "Details");
  setIconButtonChrome("activity-settings-btn", japanese ? "設定" : "Settings");
  updateSidebarModeTitle();
  setElementText("workspace-title", japanese ? "オペレーター" : "Operator");
  setElementText(
    "workspace-subtitle",
    japanese
      ? "会話、実行、判断をここで扱います。"
      : "Conversation, runs, and operator decisions.",
  );
  setButtonLabel("open-command-bar-btn", japanese ? "操作" : "Actions", japanese ? "操作パレットを開く" : "Open action palette");
  setButtonLabel("toggle-sidebar-btn", japanese ? "作業領域" : "Workspace", japanese ? "作業領域サイドバーを切り替える" : "Toggle workspace sidebar");
  setButtonLabel(
    "toggle-context-btn",
    contextPanelOpen ? (japanese ? "隠す" : "Hide") : (japanese ? "詳細" : "Details"),
    contextPanelOpen ? (japanese ? "詳細パネルを隠す" : "Hide details panel") : (japanese ? "詳細パネルを表示" : "Show details panel"),
  );
  setButtonLabel(
    "toggle-terminal-btn",
    terminalDrawerOpen ? (japanese ? "ペインを隠す" : "Hide panes") : (japanese ? "ペイン" : "Panes"),
    terminalDrawerOpen ? (japanese ? "ワーカーペインを隠す" : "Hide worker panes") : (japanese ? "ワーカーペインを表示" : "Show worker panes"),
  );
  setElementText("settings-sheet-title", japanese ? "設定" : "Settings");
  setElementText("apply-settings-btn", japanese ? "適用" : "Apply");
  document.getElementById("close-settings-btn")?.setAttribute("aria-label", japanese ? "設定を閉じる" : "Close settings");
  document.getElementById("close-settings-btn")?.setAttribute("title", japanese ? "設定を閉じる" : "Close settings");
  setElementText("settings-search-label", japanese ? "設定を検索" : "Search settings");
  const settingsSearchInput = document.getElementById("settings-search-input") as HTMLInputElement | null;
  if (settingsSearchInput) {
    settingsSearchInput.placeholder = japanese ? "設定の検索" : "Search settings";
  }
  setElementText("settings-tab-user", japanese ? "ユーザー" : "User");
  setElementText("settings-tab-workspace", japanese ? "ワークスペース" : "Workspace");
  setElementText("settings-nav-common", japanese ? "よく使用するもの" : "Commonly Used");
  setElementText("settings-nav-editor", japanese ? "テキスト エディター" : "Text Editor");
  setElementText("settings-nav-workbench", japanese ? "ワークベンチ" : "Workbench");
  setElementText("settings-nav-window", japanese ? "ウィンドウ" : "Window");
  setElementText("settings-nav-chat", japanese ? "チャット" : "Chat");
  setElementText("settings-nav-features", japanese ? "機能" : "Features");
  setElementText("settings-nav-application", japanese ? "アプリケーション" : "Application");
  setElementText("settings-nav-security", japanese ? "入力" : "Input");
  setElementText("settings-nav-extensions", japanese ? "拡張機能" : "Extensions");
  setElementText("settings-common-label", japanese ? "よく使用するもの" : "Commonly Used");
  setElementText("settings-common-value", japanese ? "エディターや端末で使うフォント設定です。" : "Editor font size and font family for code-oriented surfaces.");
  setElementText("editor-font-size-label", japanese ? "エディター: フォント サイズ" : "Editor: Font Size");
  setElementText(
    "editor-font-size-description",
    japanese
      ? "エディター表示と端末ペインで使うフォントサイズです。既定値は 14 です。"
      : "Controls the font size used in editor previews and terminal panes. The default is 14.",
  );
  setElementText("editor-font-size-reset-btn", japanese ? "既定値 14" : "Default 14");
  setElementText("settings-profile-label", japanese ? "実行環境" : "Runtime");
  setElementText(
    "settings-profile-value",
    japanese
      ? "ロールごとにローカル CLI、モデル入手元、思考量を選べます。既定値ではモデル指定を渡しません。"
      : "Choose local CLI, model source, and effort per role. Provider default passes no model override.",
  );
  setElementText("settings-language-label", japanese ? "言語" : "Language");
  setElementText("settings-language-value", japanese ? "作業領域の表示言語を日本語と英語で切り替えます。" : "Switch the workspace chrome between English and Japanese.");
  setElementText("settings-theme-label", japanese ? "テーマ" : "Theme");
  setElementText("settings-theme-value", japanese ? "文字、配色、シェルのコントラストを切り替えます。" : "Public openai/codex TUI-derived typography, semantic color tokens, and shell contrast.");
  setElementText("settings-density-label", japanese ? "密度" : "Density");
  setElementText("settings-density-value", japanese ? "作業領域、入力欄、パネルの余白を調整します。" : "Workspace spacing, composer height, and panel padding.");
  setElementText("settings-wrap-label", japanese ? "折り返し" : "Wrap");
  setElementText("settings-wrap-value", japanese ? "会話、エディター、下部ステータスの折り返しを調整します。" : "Conversation, editor, and footer wrapping behavior.");
  setElementText("settings-code-font-label", japanese ? "エディター: フォント ファミリ" : "Editor: Font Family");
  setElementText("settings-code-font-value", japanese ? "コード表示、端末ペイン、差分詳細に使います。" : "Used in code preview, terminal panes, and diff details.");
  document
    .getElementById("settings-font-family-menu-btn")
    ?.setAttribute("aria-label", japanese ? "フォント ファミリを選ぶ" : "Choose font family");
  document
    .getElementById("settings-font-family-menu-btn")
    ?.setAttribute("title", japanese ? "フォント ファミリを選ぶ" : "Choose font family");
  setElementText("settings-display-label", japanese ? "表示" : "Display");
  setElementText("settings-display-value", japanese ? "タイムラインの詳細を常時どこまで表示するかを選びます。" : "Choose how much timeline detail stays visible by default.");
  setElementText("settings-workspace-label", japanese ? "作業領域" : "Workspace");
  setElementText("settings-workspace-value", japanese ? "サイドバー幅、詳細パネル、ワークベンチの挙動を扱います。" : "Sidebar width, details panel, workbench behavior");
  setElementText("settings-input-label", japanese ? "入力" : "Input");
  setElementText("settings-input-value", japanese ? "Enter で送信、Shift+Enter で改行、IME 変換中の Enter は保護します。" : "Enter sends, Shift+Enter inserts newline, IME composition is protected");
  setElementText("voice-shortcut-label", japanese ? "音声入力: ショートカット" : "Voice Input: Shortcut");
  setElementText(
    "voice-shortcut-description",
    japanese
      ? "音声入力の開始と停止に使います。認識した文字は送信せず、オペレーター入力欄の下書きに入れます。"
      : "Starts or stops voice capture and writes recognized text into the operator composer as an editable draft.",
  );
  setElementText("voice-shortcut-reset-btn", japanese ? `既定値 ${DEFAULT_VOICE_SHORTCUT}` : `Default ${DEFAULT_VOICE_SHORTCUT}`);
  setSelectorText(".brand-block .sidebar-caption", japanese ? "オペレーターシェル" : "Operator shell");
  setSelectorText('[data-i18n="sessions-title"]', japanese ? "セッション" : "Sessions");
  setSelectorText('[data-i18n="files-title"]', japanese ? "ファイル" : "Files");
  setSelectorText('[data-i18n="editors-title"]', japanese ? "エディター" : "Editors");
  setSelectorText('[data-i18n="source-title"]', japanese ? "ソース" : "Source");
  setElementText("source-control-title", japanese ? "ソース管理" : "Source control");
  setElementText("source-control-commit-label", japanese ? "コミット依頼" : "Commit request");
  setElementText("source-control-changes-title", japanese ? "変更" : "Changes");
  setElementText("source-control-graph-title", japanese ? "グラフ" : "Graph");
  setElementText("evidence-title", japanese ? "証跡" : "Evidence");
  setElementText("workbench-title", japanese ? "ワーカーペイン" : "Worker panes");
  document.getElementById("terminal-drawer")?.setAttribute("aria-label", japanese ? "ワーカーペイン" : "Worker panes");
  document.getElementById("workbench-layout-btn")?.setAttribute("aria-label", japanese ? "ワーカーペインの配置を切り替える" : "Switch worker pane layout");
  updateWorkbenchControls();
  setSelectorText("#thread-meta span:first-child", japanese ? "winsmux セッション" : "winsmux session");
  setSelectorText("#thread-meta span:first-child", "Claude Code");
  setSelectorText("#thread-meta span:last-child", japanese ? "operator CLI" : "operator CLI");
  setElementText("timeline-feed-hint", japanese ? "CLI の会話として表示します。" : "Rendered as an operator CLI conversation.");
  setElementText("context-panel-title", japanese ? "詳細" : "Details");
  setElementText("context-decision-title", japanese ? "判断" : "Decision");
  setElementText("context-experiments-title", japanese ? "実験" : "Experiments");
  setElementText("context-ports-title", japanese ? "ポート" : "Ports");
  setElementText("context-source-title", japanese ? "ソース管理" : "Source control");
  setElementText("context-files-title", japanese ? "変更ファイル" : "Changed files");
  setElementText("command-bar-eyebrow", japanese ? "キーボード中心の操作" : "Keyboard-first control");
  setElementText("command-bar-title", japanese ? "操作パレット" : "Action palette");
  setElementText(
    "command-bar-hint",
    japanese ? "Ctrl+K で開く · ↑↓ で移動 · Enter で実行 · Esc で閉じる" : "Ctrl+K to open · ↑↓ navigate · Enter execute · Esc close",
  );
  setElementText("command-bar-search-label", japanese ? "コマンドを検索" : "Search commands");
  setElementText(
    "command-bar-description",
    japanese
      ? "依頼、レビュー、説明、ソース管理、設定、端末操作をここから実行できます。"
      : "Action palette for dispatch, review, explain, source control, settings, and terminal control.",
  );
  document
    .getElementById("command-bar-results")
    ?.setAttribute("aria-label", japanese ? "操作候補" : "Action results");

  const composerInput = document.getElementById("composer-input") as HTMLTextAreaElement | null;
  if (composerInput) {
    const selected = composerModes.find((item) => item.mode === activeComposerMode) ?? composerModes[0];
    composerInput.placeholder = getComposerModePlaceholder(selected.mode);
  }

  const commandBarInput = document.getElementById("command-bar-input") as HTMLInputElement | null;
  if (commandBarInput) {
    commandBarInput.placeholder = japanese ? "操作、実行、ペイン、オペレーター操作を検索" : "Search actions, runs, panels, and operator controls";
  }

  const attachButton = document.getElementById("attach-btn");
  if (attachButton) {
    attachButton.setAttribute("aria-label", japanese ? "ファイルを添付" : "Attach files");
    attachButton.setAttribute("title", japanese ? "ファイルを添付" : "Attach files");
  }
  updateVoiceInputButton();
  updateOperatorInterruptButton();
  updateOperatorStatusIndicator();
  renderComposerSessionControls();
  const sendButton = document.getElementById("send-btn");
  if (sendButton) {
    sendButton.setAttribute("aria-label", japanese ? "Enter で送信" : "Send with Enter");
    sendButton.setAttribute("title", japanese ? "Enter で送信" : "Send with Enter");
  }

  const sourceControlMessage = document.getElementById("source-control-message") as HTMLTextAreaElement | null;
  if (sourceControlMessage) {
    sourceControlMessage.placeholder = japanese ? "コミットメッセージ" : "Commit message";
  }
}

function applyThemeState(nextState: ThemeState) {
  themeState.theme = nextState.theme;
  themeState.density = nextState.density;
  themeState.wrapMode = nextState.wrapMode;
  themeState.codeFont = nextState.codeFont;
  themeState.codeFontFamily = normalizeCodeFontFamily(nextState.codeFontFamily);
  themeState.editorFontSize = clampEditorFontSize(nextState.editorFontSize);
  themeState.voiceShortcut = normalizeVoiceShortcut(nextState.voiceShortcut);
  themeState.focusMode = nextState.focusMode;
  themeState.language = nextState.language;
  applyShellPreferences();
  applyLanguageChrome();
  updateTimelineFeedHint();
  applyCodeFontToPanes();
  updateWorkbenchControls();
  renderSessions();
  renderExplorer();
  void refreshProjectExplorerEntries();
  void refreshBrowserSourceControl();
  renderOpenEditors();
  renderSourceSummary();
  renderSourceEntries();
  renderSourceControlView();
  renderEvidenceView();
  renderContextPanel();
  renderTimelineFilters();
  renderRunSummary();
  renderConversation(getConversationItems());
  renderComposerModes();
  renderAttachmentTray();
  renderCommandBar();
  renderSettingsControls();
  renderFooterLane();
}

function applyCodeFontToPanes() {
  const fontFamily = getCodeFontFamily();
  const fontSize = themeState.editorFontSize;
  panes.forEach((pane) => {
    pane.terminal.options.fontFamily = fontFamily;
    pane.terminal.options.fontSize = fontSize;
  });
  fitVisibleWorkbenchPanes();
}

function renderPreferenceOptions<T extends string>(
  rootId: string,
  options: Array<{ value: T; label: string; description: string; labelJa?: string; descriptionJa?: string }>,
  selected: T,
  onSelect: (value: T) => void,
) {
  const root = document.getElementById(rootId);
  if (!root) {
    return;
  }

  root.innerHTML = "";
  const japanese = (settingsDraftState?.language ?? themeState.language) === "ja";
  for (const option of options) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `settings-option-chip ${option.value === selected ? "is-active" : ""}`;
    button.setAttribute("aria-pressed", option.value === selected ? "true" : "false");
    button.innerHTML = `<span class="settings-option-label">${japanese ? (option.labelJa ?? option.label) : option.label}</span><span class="settings-option-description">${japanese ? (option.descriptionJa ?? option.description) : option.description}</span>`;
    button.addEventListener("click", () => onSelect(option.value));
    root.appendChild(button);
  }
}

function getSettingsDraftState() {
  if (!settingsDraftState) {
    settingsDraftState = cloneThemeState(themeState);
  }
  return settingsDraftState;
}

function updateSettingsApplyButton() {
  const applyButton = document.getElementById("apply-settings-btn") as HTMLButtonElement | null;
  if (!applyButton) {
    return;
  }
  const activeState = settingsDraftState ?? themeState;
  const voiceShortcutValid = getVoiceShortcutValidation(activeState.voiceShortcut, activeState.language === "ja").valid;
  const hasThemeChanges = Boolean(settingsDraftState && !themeStatesEqual(settingsDraftState, themeState));
  const hasRuntimeChanges = Boolean(runtimeRoleDraftState && !runtimeRolePreferencesEqual(runtimeRoleDraftState, runtimeRolePreferences));
  const hasChanges = hasThemeChanges || hasRuntimeChanges;
  applyButton.disabled = !hasChanges || !voiceShortcutValid;
  applyButton.setAttribute("aria-disabled", applyButton.disabled ? "true" : "false");
}

function updateEditorFontSizeControl(activeState: ThemeState) {
  const input = document.getElementById("editor-font-size-input") as HTMLInputElement | null;
  const resetButton = document.getElementById("editor-font-size-reset-btn") as HTMLButtonElement | null;
  if (input) {
    input.min = `${MIN_EDITOR_FONT_SIZE}`;
    input.max = `${MAX_EDITOR_FONT_SIZE}`;
    input.step = "1";
    const activeValue = `${activeState.editorFontSize}`;
    if (input.value !== activeValue) {
      input.value = activeValue;
    }
    input.setAttribute("aria-valuemin", `${MIN_EDITOR_FONT_SIZE}`);
    input.setAttribute("aria-valuemax", `${MAX_EDITOR_FONT_SIZE}`);
    input.setAttribute("aria-valuenow", activeValue);
    input.oninput = () => {
      const draft = getSettingsDraftState();
      draft.editorFontSize = clampEditorFontSize(input.value);
      input.setAttribute("aria-valuenow", `${draft.editorFontSize}`);
      updateSettingsApplyButton();
      renderFooterLane();
    };
    input.onchange = () => {
      const draft = getSettingsDraftState();
      draft.editorFontSize = clampEditorFontSize(input.value);
      input.value = `${draft.editorFontSize}`;
      renderSettingsControls();
    };
  }
  if (resetButton) {
    resetButton.disabled = activeState.editorFontSize === DEFAULT_EDITOR_FONT_SIZE;
    resetButton.setAttribute("aria-disabled", resetButton.disabled ? "true" : "false");
    resetButton.onclick = () => {
      const draft = getSettingsDraftState();
      draft.editorFontSize = DEFAULT_EDITOR_FONT_SIZE;
      renderSettingsControls();
    };
  }
}

function updateFontFamilyControl(activeState: ThemeState) {
  const input = document.getElementById("settings-font-family-input") as HTMLInputElement | null;
  if (!input) {
    return;
  }
  if (input.value !== activeState.codeFontFamily) {
    input.value = activeState.codeFontFamily;
  }
  input.oninput = () => {
    const draft = getSettingsDraftState();
    draft.codeFontFamily = normalizeCodeFontFamily(input.value);
    settingsFontFamilyMenuOpen = false;
    updateSettingsApplyButton();
    renderFooterLane();
  };
  input.onchange = () => {
    const draft = getSettingsDraftState();
    draft.codeFontFamily = normalizeCodeFontFamily(input.value);
    input.value = draft.codeFontFamily;
    renderSettingsControls();
  };
}

function updateVoiceShortcutWarning(activeState: ThemeState) {
  const input = document.getElementById("voice-shortcut-input") as HTMLInputElement | null;
  const resetButton = document.getElementById("voice-shortcut-reset-btn") as HTMLButtonElement | null;
  const warning = document.getElementById("voice-shortcut-warning");
  const validation = getVoiceShortcutValidation(activeState.voiceShortcut, activeState.language === "ja");
  if (input) {
    input.setAttribute("aria-invalid", validation.valid ? "false" : "true");
  }
  if (resetButton) {
    resetButton.disabled = validation.valid && validation.normalized === DEFAULT_VOICE_SHORTCUT;
    resetButton.setAttribute("aria-disabled", resetButton.disabled ? "true" : "false");
  }
  if (warning) {
    warning.hidden = validation.valid;
    warning.textContent = validation.message;
  }
  updateSettingsApplyButton();
}

function updateVoiceShortcutControl(activeState: ThemeState) {
  const input = document.getElementById("voice-shortcut-input") as HTMLInputElement | null;
  const resetButton = document.getElementById("voice-shortcut-reset-btn") as HTMLButtonElement | null;
  if (input) {
    const shortcutValue = typeof activeState.voiceShortcut === "string" ? activeState.voiceShortcut : DEFAULT_VOICE_SHORTCUT;
    if (document.activeElement !== input && input.value !== shortcutValue) {
      input.value = shortcutValue;
    }
    input.oninput = () => {
      const draft = getSettingsDraftState();
      draft.voiceShortcut = input.value;
      updateVoiceShortcutWarning(draft);
      renderFooterLane();
    };
    input.onkeydown = (event) => {
      if (event.key === "Tab" && !event.ctrlKey && !event.altKey && !event.shiftKey && !event.metaKey) {
        return;
      }
      if ((event.key === "Backspace" || event.key === "Delete") && !event.ctrlKey && !event.altKey && !event.shiftKey && !event.metaKey) {
        event.preventDefault();
        const draft = getSettingsDraftState();
        draft.voiceShortcut = "";
        input.value = "";
        updateVoiceShortcutWarning(draft);
        renderFooterLane();
        return;
      }
      const captured = getVoiceShortcutFromKeyboardEvent(event);
      if (!captured || (!event.ctrlKey && !event.altKey && !event.shiftKey && !event.metaKey)) {
        return;
      }
      event.preventDefault();
      event.stopPropagation();
      const draft = getSettingsDraftState();
      draft.voiceShortcut = captured;
      input.value = captured;
      updateVoiceShortcutWarning(draft);
      renderFooterLane();
    };
    input.onchange = () => {
      const draft = getSettingsDraftState();
      const validation = getVoiceShortcutValidation(input.value, draft.language === "ja");
      draft.voiceShortcut = validation.valid ? validation.normalized : input.value;
      input.value = draft.voiceShortcut;
      renderSettingsControls();
    };
  }
  if (resetButton) {
    const validation = getVoiceShortcutValidation(activeState.voiceShortcut, activeState.language === "ja");
    resetButton.disabled = validation.valid && validation.normalized === DEFAULT_VOICE_SHORTCUT;
    resetButton.setAttribute("aria-disabled", resetButton.disabled ? "true" : "false");
    resetButton.onclick = () => {
      const draft = getSettingsDraftState();
      draft.voiceShortcut = DEFAULT_VOICE_SHORTCUT;
      renderSettingsControls();
    };
  }
  updateVoiceShortcutWarning(activeState);
}

function renderSettingsFontFamilyMenu(activeState: ThemeState) {
  const button = document.getElementById("settings-font-family-menu-btn") as HTMLButtonElement | null;
  const menu = document.getElementById("settings-font-family-menu");
  if (!button || !menu) {
    return;
  }

  const japanese = activeState.language === "ja";
  button.setAttribute("aria-expanded", settingsFontFamilyMenuOpen ? "true" : "false");
  button.onclick = (event) => {
    event.stopPropagation();
    settingsFontFamilyMenuOpen = !settingsFontFamilyMenuOpen;
    renderSettingsControls();
  };

  menu.hidden = !settingsFontFamilyMenuOpen;
  menu.innerHTML = "";
  for (const option of codeFontOptions) {
    const presetValue = getCodeFontFamily(option.value, "");
    const isSelected = normalizeCodeFontFamily(activeState.codeFontFamily, "") === presetValue;
    const item = document.createElement("button");
    item.type = "button";
    item.className = `settings-popover-item ${isSelected ? "is-active" : ""}`;
    item.setAttribute("role", "menuitemradio");
    item.setAttribute("aria-checked", isSelected ? "true" : "false");

    const check = document.createElement("span");
    check.className = "settings-popover-check";
    check.textContent = isSelected ? "✓" : "";
    item.appendChild(check);

    const body = document.createElement("span");
    body.className = "settings-popover-item-body";

    const label = document.createElement("span");
    label.className = "settings-popover-item-label";
    label.textContent = japanese ? (option.labelJa ?? option.label) : option.label;
    body.appendChild(label);

    const description = document.createElement("span");
    description.className = "settings-popover-item-description";
    description.textContent = presetValue;
    body.appendChild(description);

    item.appendChild(body);
    item.addEventListener("click", (event) => {
      event.stopPropagation();
      const draft = getSettingsDraftState();
      draft.codeFont = option.value;
      draft.codeFontFamily = presetValue;
      settingsFontFamilyMenuOpen = false;
      renderSettingsControls();
    });
    menu.appendChild(item);
  }
}

function getRuntimeRoleDraft() {
  if (!runtimeRoleDraftState) {
    runtimeRoleDraftState = cloneRuntimeRolePreferences(runtimeRolePreferences);
  }
  return runtimeRoleDraftState;
}

function updateRuntimeRoleDraft(roleId: RuntimeRoleId, patch: Partial<RuntimeRolePreference>) {
  const draft = getRuntimeRoleDraft();
  const index = draft.findIndex((item) => item.roleId === roleId);
  if (index === -1) {
    return;
  }
  draft[index] = roleId === "operator"
    ? { ...lockedOperatorRuntimePreference }
    : { ...draft[index], ...patch };
  renderSettingsControls();
}

function runtimeAccessNote(preference: RuntimeRolePreference, japanese: boolean) {
  if (preference.roleId === "operator") {
    return japanese
      ? "デスクトップのオペレーターペインは現在 Claude Code 固定です。プロバイダー変更は今後のリリースで対応予定です。モデルと工数は入力欄のメニューで選びます。"
      : "The desktop operator pane is currently fixed to Claude Code. Provider switching is planned for a later release. Choose model and effort from the composer menu.";
  }
  if (preference.provider === "codex") {
    return japanese
      ? "ローカルの Codex CLI のモデル一覧と ChatGPT アカウント権限を使います。API の一覧だけでは判断しません。"
      : "Uses the local Codex CLI catalog and ChatGPT account access, not API-only availability.";
  }
  if (preference.provider === "claude") {
    return japanese
      ? "ローカルの Claude Code 設定を使います。`default`、`sonnet`、`opus`、`opusplan` を指定できます。"
      : "Uses local Claude Code settings. Aliases such as default, sonnet, opus, and opusplan are accepted.";
  }
  if (preference.provider === "gemini") {
    return japanese
      ? "ローカルの Gemini CLI 設定を使います。計画時は `--approval-mode plan` を使えます。"
      : "Uses local Gemini CLI settings. Plan runs can use --approval-mode plan.";
  }
  return japanese
    ? "winsmux はモデル指定を渡さず、プロバイダー側の既定値を使います。"
    : "winsmux passes no model override and lets the provider choose its default.";
}

function createRuntimeSelect<T extends string>(
  id: string,
  label: string,
  value: T,
  options: Array<{ value: T; label: string; labelJa: string }>,
  japanese: boolean,
  onChange: (value: T) => void,
  controlOptions: { disabled?: boolean; title?: string } = {},
) {
  const group = document.createElement("label");
  group.className = `runtime-control-group ${controlOptions.disabled ? "is-disabled" : ""}`;
  group.setAttribute("for", id);
  if (controlOptions.title) {
    group.setAttribute("title", controlOptions.title);
  }

  const caption = document.createElement("span");
  caption.className = "runtime-control-caption";
  caption.textContent = label;
  group.appendChild(caption);

  const select = document.createElement("select");
  select.id = id;
  select.className = "runtime-control-select";
  select.disabled = Boolean(controlOptions.disabled);
  select.setAttribute("aria-disabled", controlOptions.disabled ? "true" : "false");
  for (const option of options) {
    const element = document.createElement("option");
    element.value = option.value;
    element.textContent = japanese ? option.labelJa : option.label;
    element.selected = option.value === value;
    select.appendChild(element);
  }
  select.addEventListener("change", () => onChange(select.value as T));
  group.appendChild(select);
  return group;
}

function renderRuntimeRoleControls() {
  const root = document.getElementById("runtime-role-options");
  if (!root) {
    return;
  }

  const activeRuntimeState = runtimeRoleDraftState ?? runtimeRolePreferences;
  const japanese = (settingsDraftState?.language ?? themeState.language) === "ja";
  root.innerHTML = "";

  const datalist = document.createElement("datalist");
  datalist.id = "runtime-model-suggestions";
  for (const model of runtimeModelSuggestions) {
    const option = document.createElement("option");
    option.value = model;
    datalist.appendChild(option);
  }
  root.appendChild(datalist);

  for (const role of runtimeRoleOptions) {
    const operatorLocked = role.value === "operator";
    const preference = activeRuntimeState.find((item) => item.roleId === role.value)
      ?? defaultRuntimeRolePreferences().find((item) => item.roleId === role.value)!;
    const panel = document.createElement("section");
    panel.className = `runtime-role-panel ${operatorLocked ? "is-locked" : ""}`;

    const header = document.createElement("div");
    header.className = "runtime-role-header";
    const title = document.createElement("div");
    title.className = "runtime-role-title";
    title.textContent = japanese ? role.labelJa : role.label;
    const description = document.createElement("div");
    description.className = "runtime-role-description";
    description.textContent = japanese ? role.descriptionJa : role.description;
    header.append(title, description);
    panel.appendChild(header);

    const controls = document.createElement("div");
    controls.className = "runtime-role-controls";
    controls.appendChild(createRuntimeSelect(
      `runtime-provider-${role.value}`,
      japanese ? "プロバイダー" : "Provider",
      operatorLocked ? lockedOperatorRuntimePreference.provider : preference.provider,
      runtimeProviderOptions,
      japanese,
      (provider) => updateRuntimeRoleDraft(role.value, { provider }),
      operatorLocked
        ? {
            disabled: true,
            title: japanese
              ? "オペレーターペインは現在 Claude Code 固定です。"
              : "The operator pane is currently fixed to Claude Code.",
          }
        : {},
    ));

    const modelGroup = document.createElement("label");
    modelGroup.className = "runtime-control-group runtime-control-group-wide";
    modelGroup.setAttribute("for", `runtime-model-${role.value}`);
    const modelCaption = document.createElement("span");
    modelCaption.className = "runtime-control-caption";
    modelCaption.textContent = japanese ? "モデル" : "Model";
    const modelInput = document.createElement("input");
    modelInput.id = `runtime-model-${role.value}`;
    modelInput.className = "runtime-control-input";
    modelInput.value = operatorLocked ? lockedOperatorRuntimePreference.model : preference.model;
    modelInput.disabled = operatorLocked;
    modelInput.setAttribute("aria-disabled", operatorLocked ? "true" : "false");
    modelInput.setAttribute("list", "runtime-model-suggestions");
    modelInput.placeholder = "provider-default";
    modelInput.addEventListener("change", () => {
      const value = modelInput.value.trim() || "provider-default";
      const nextSource = value === "provider-default" ? "provider-default" : preference.modelSource;
      updateRuntimeRoleDraft(role.value, { model: value, modelSource: nextSource });
    });
    modelGroup.append(modelCaption, modelInput);
    controls.appendChild(modelGroup);

    controls.appendChild(createRuntimeSelect(
      `runtime-model-source-${role.value}`,
      japanese ? "入手元" : "Source",
      preference.modelSource,
      runtimeModelSourceOptions,
      japanese,
      (modelSource) => updateRuntimeRoleDraft(role.value, { modelSource }),
      operatorLocked ? { disabled: true } : {},
    ));
    controls.appendChild(createRuntimeSelect(
      `runtime-reasoning-${role.value}`,
      japanese ? "思考量" : "Effort",
      preference.reasoningEffort,
      runtimeReasoningOptions,
      japanese,
      (reasoningEffort) => updateRuntimeRoleDraft(role.value, { reasoningEffort }),
      operatorLocked ? { disabled: true } : {},
    ));
    panel.appendChild(controls);

    const note = document.createElement("div");
    note.className = "runtime-access-note";
    note.textContent = runtimeAccessNote(operatorLocked ? lockedOperatorRuntimePreference : preference, japanese);
    panel.appendChild(note);

    root.appendChild(panel);
  }
}

function renderSettingsControls() {
  const activeState = settingsDraftState ?? themeState;

  updateEditorFontSizeControl(activeState);
  updateFontFamilyControl(activeState);
  updateVoiceShortcutControl(activeState);
  renderSettingsFontFamilyMenu(activeState);

  renderPreferenceOptions("theme-options", themeOptions, activeState.theme, (value) => {
    getSettingsDraftState().theme = value;
    renderSettingsControls();
  });

  renderPreferenceOptions("density-options", densityOptions, activeState.density, (value) => {
    getSettingsDraftState().density = value;
    renderSettingsControls();
  });

  renderPreferenceOptions("wrap-options", wrapOptions, activeState.wrapMode, (value) => {
    getSettingsDraftState().wrapMode = value;
    renderSettingsControls();
  });

  renderPreferenceOptions("focus-mode-options", focusModeOptions, activeState.focusMode, (value) => {
    getSettingsDraftState().focusMode = value;
    renderSettingsControls();
  });

  renderPreferenceOptions("language-options", languageOptions, activeState.language, (value) => {
    getSettingsDraftState().language = value;
    renderSettingsControls();
  });

  renderRuntimeRoleControls();
  updateSettingsApplyButton();

  renderFooterLane();
}

function renderFooterLane() {
  const left = document.getElementById("footer-left");
  const right = document.getElementById("footer-right");
  if (!left || !right) {
    return;
  }

  const footerItems = getFooterItems();

  const buildPill = (item: FooterStatusItem) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "footer-pill";
    button.dataset.tone = item.tone ?? "default";
    button.innerHTML = item.value
      ? `<span class="footer-pill-label">${item.label}</span><span class="footer-pill-value">${item.value}</span>`
      : `<span class="footer-pill-value">${item.label}</span>`;
    if (item.label === "Actions" || item.value === "Actions") {
      button.addEventListener("click", () => openCommandBar());
    }
    if (item.label === "Settings" || item.value === "Settings") {
      button.addEventListener("click", () => setSettingsSheet(true));
    }
    return button;
  };

  left.innerHTML = "";
  right.innerHTML = "";

  for (const item of footerItems.left) {
    left.appendChild(buildPill(item));
  }

  for (const item of footerItems.right) {
    right.appendChild(buildPill(item));
  }
}

function setComposerMode(mode: ComposerMode) {
  activeComposerMode = mode;
  renderComposerModes();
}

function focusComposer() {
  const composerInput = document.getElementById("composer-input") as HTMLTextAreaElement | null;
  if (!composerInput) {
    return;
  }

  composerInput.focus();
  const length = composerInput.value.length;
  composerInput.setSelectionRange(length, length);
}

function getFilteredComposerSlashCommands() {
  if (composerWinsmuxCommandOpen) {
    const query = composerWinsmuxCommandQuery.toLowerCase();
    return winsmuxComposerCommandEntries.filter((item) => item.command.toLowerCase().startsWith(query));
  }
  if (!composerSlashOpen) {
    return [];
  }
  const query = composerSlashQuery.toLowerCase();
  if (!query) {
    return [
      ...localComposerSlashCommands,
      ...winsmuxComposerCommandEntries,
      ...composerSlashCommands.filter((item) => item.kind !== "mode"),
    ];
  }
  if ("winsmux".startsWith(query) || query.startsWith("winsmux")) {
    const winsmuxMatches = winsmuxComposerCommandEntries.filter((item) => item.command.toLowerCase().startsWith(query));
    const slashMatches = composerSlashCommands.filter((item) => item.command.toLowerCase().startsWith(query));
    return [...winsmuxMatches, ...slashMatches];
  }
  return composerSlashCommands.filter((item) => item.command.toLowerCase().startsWith(query));
}

function getComposerSlashFallbackCommand(): ComposerSlashCommand | null {
  if (!composerSlashOpen) {
    return null;
  }
  const command = composerSlashQuery.trim();
  if (!command) {
    return null;
  }
  const isMcpPrompt = command.startsWith("mcp__");
  return {
    command,
    label: `/${command}`,
    labelJa: `/${command}`,
    description: isMcpPrompt ? "Run an MCP prompt command." : "Run a custom slash command or skill.",
    descriptionJa: isMcpPrompt ? "MCP プロンプトコマンドを実行します。" : "カスタムコマンドまたはスキルを実行します。",
    kind: "claude",
  };
}

function getVisibleComposerSlashCommands() {
  const commands = getFilteredComposerSlashCommands();
  if (commands.length > 0) {
    return commands;
  }
  const fallback = getComposerSlashFallbackCommand();
  return fallback ? [fallback] : [];
}

function renderComposerSlashCommands() {
  const root = document.getElementById("composer-slash-row");
  if (!root) {
    return;
  }

  const visibleCommands = getVisibleComposerSlashCommands();
  root.innerHTML = "";
  const suggestionOpen = composerSlashOpen || composerWinsmuxCommandOpen;
  root.hidden = !suggestionOpen || visibleCommands.length === 0;
  if (!suggestionOpen || visibleCommands.length === 0) {
    return;
  }

  visibleCommands.forEach((item, index) => {
    const button = document.createElement("button");
    const commandLabel = document.createElement("span");
    const descriptionLabel = document.createElement("span");
    button.type = "button";
    button.className = `slash-chip ${index === selectedComposerSlashIndex ? "is-active" : ""}`;
    const label = themeState.language === "ja" ? item.labelJa : item.label;
    const description = themeState.language === "ja" ? item.descriptionJa : item.description;
    commandLabel.className = "slash-chip-command";
    commandLabel.textContent = item.kind === "winsmux" ? item.command : `/${item.command}`;
    descriptionLabel.className = "slash-chip-description";
    descriptionLabel.textContent = label === commandLabel.textContent ? description : label;
    button.appendChild(commandLabel);
    button.appendChild(descriptionLabel);
    button.addEventListener("click", () => {
      applyComposerSlashCommand(item);
    });
    root.appendChild(button);
    if (index === selectedComposerSlashIndex) {
      button.scrollIntoView({ block: "nearest", inline: "nearest" });
    }
  });
}

function syncComposerSlashState(value: string) {
  const match = value.match(/^\/([^\s]*)$/);
  const winsmuxMatch = value.match(/^(winsmux(?:\s.*)?)$/i);
  composerSlashOpen = Boolean(match);
  composerSlashQuery = match ? match[1] : "";
  composerWinsmuxCommandOpen = !composerSlashOpen && Boolean(winsmuxMatch);
  composerWinsmuxCommandQuery = winsmuxMatch ? winsmuxMatch[1].replace(/\s+/g, " ").trim() : "";
  const commands = getVisibleComposerSlashCommands();
  selectedComposerSlashIndex = commands.length === 0 ? 0 : Math.min(selectedComposerSlashIndex, commands.length - 1);
  renderComposerSlashCommands();
}

function getComposerModeSlashCommand(value: string) {
  const commandName = value.trim().match(/^\/([^\s]+)$/)?.[1]?.toLowerCase();
  if (!commandName) {
    return null;
  }
  return composerSlashCommands.find((item) => item.kind === "mode" && item.command.toLowerCase() === commandName) ?? null;
}

function applyComposerSlashCommand(command: ComposerSlashCommand) {
  const composerInput = document.getElementById("composer-input") as HTMLTextAreaElement | null;
  if (!composerInput) {
    return;
  }

  if (command.kind === "mode" && command.mode) {
    setComposerMode(command.mode);
    composerInput.value = composerInput.value.replace(/^\/[^\s]+/, "").replace(/^\s+/, "");
  } else if (command.kind === "winsmux") {
    composerInput.value = command.command;
  } else {
    composerInput.value = `/${command.command}${command.command ? " " : ""}`;
  }
  syncComposerInputHeight(composerInput);
  syncComposerSlashState(composerInput.value);
  exitComposerHistoryToDraft(composerInput.value);
  composerInput.focus();
  const length = composerInput.value.length;
  composerInput.setSelectionRange(length, length);
}

function getSpeechRecognitionConstructor(): SpeechRecognitionConstructor | null {
  const speechWindow = window as unknown as {
    SpeechRecognition?: SpeechRecognitionConstructor;
    webkitSpeechRecognition?: SpeechRecognitionConstructor;
  };
  return speechWindow.SpeechRecognition ?? speechWindow.webkitSpeechRecognition ?? null;
}

function isBrowserVoiceInputSupported() {
  return Boolean(getSpeechRecognitionConstructor());
}

function isNativeVoiceCaptureAvailable() {
  return isTauri() && voiceCaptureStatus?.native.available === true;
}

function isNativeVoiceCaptureTerminalState(state: string | undefined) {
  return state === "stopped" || state === "cancelled" || state === "permission_denied" || state === "no_microphone";
}

function getVoiceCaptureMeterPercent() {
  return Math.round(Math.max(0, Math.min(1, voiceCaptureStatus?.native.meter_level ?? 0)) * 100);
}

function getVoiceCaptureStatusMessage() {
  if (!isTauri()) {
    return "";
  }

  if (voiceCaptureStatusError) {
    return getLanguageText(
      `Native microphone status failed: ${voiceCaptureStatusError}`,
      `ネイティブのマイク状態を取得できません: ${voiceCaptureStatusError}`,
    );
  }

  if (!voiceCaptureStatus) {
    return getLanguageText(
      "Checking native microphone status...",
      "ネイティブのマイク状態を確認中...",
    );
  }

  if (voiceCaptureStatus.native.state === "recording") {
    const meter = getVoiceCaptureMeterPercent();
    return getLanguageText(
      `Native microphone capture is recording. Meter ${meter}%.`,
      `ネイティブのマイク入力で録音中です。メーターは ${meter}% です。`,
    );
  }

  if (voiceCaptureStatus.native.state === "silence") {
    const meter = getVoiceCaptureMeterPercent();
    return getLanguageText(
      `Native microphone capture is running, but speech is not detected. Meter ${meter}%.`,
      `ネイティブのマイク入力は動作中ですが、発話を検出していません。メーターは ${meter}% です。`,
    );
  }

  if (voiceCaptureStatus.native.state === "restarting") {
    return getLanguageText(
      "Restarting native microphone capture...",
      "ネイティブのマイク入力を再起動しています...",
    );
  }

  if (voiceCaptureStatus.native.state === "cancelled") {
    return getLanguageText(
      "Native microphone capture was cancelled.",
      "ネイティブのマイク入力をキャンセルしました。",
    );
  }

  if (voiceCaptureStatus.native.state === "stopped") {
    return getLanguageText(
      "Native microphone capture is ready.",
      "ネイティブのマイク入力を開始できます。",
    );
  }

  if (voiceCaptureStatus.native.state === "permission_denied") {
    return getLanguageText(
      "Native microphone capture could not access the microphone.",
      "ネイティブのマイク入力がマイクにアクセスできませんでした。",
    );
  }

  if (voiceCaptureStatus.native.available) {
    return getLanguageText(
      "Native microphone capture is available.",
      "ネイティブのマイク入力を利用できます。",
    );
  }

  if (voiceCaptureStatus.native.state === "no_microphone") {
    return getLanguageText(
      "No microphone was found for native capture.",
      "ネイティブのマイク入力に使えるマイクが見つかりません。",
    );
  }

  if (isBrowserVoiceInputSupported()) {
    return getLanguageText(
      "Native microphone capture is not ready; browser voice input is active.",
      "ネイティブのマイク入力は準備中です。ブラウザーの音声入力を使います。",
    );
  }

  return getLanguageText(
    "Native microphone capture is not ready, and browser voice input is unavailable.",
    "ネイティブのマイク入力は準備中です。この環境ではブラウザーの音声入力も使えません。",
  );
}

function renderVoiceCaptureStatus() {
  const status = document.getElementById("voice-input-status") as HTMLElement | null;
  if (!status) {
    return;
  }

  const message = getVoiceCaptureStatusMessage();
  status.hidden = !message;
  status.textContent = message;
  status.dataset.state = voiceCaptureStatus?.native.state ?? (voiceCaptureStatusError ? "error" : "unknown");
  status.style.setProperty("--voice-meter", `${getVoiceCaptureMeterPercent()}%`);
}

async function refreshVoiceCaptureStatus() {
  if (!isTauri()) {
    renderVoiceCaptureStatus();
    return;
  }

  try {
    voiceCaptureStatus = await getDesktopVoiceCaptureStatus();
    voiceCaptureStatusError = "";
  } catch (error) {
    voiceCaptureStatus = null;
    voiceCaptureStatusError = error instanceof Error ? error.message : String(error);
  }
  updateVoiceInputButton();
  renderVoiceCaptureStatus();
  if (voiceInputMode === "native" && isNativeVoiceCaptureTerminalState(voiceCaptureStatus?.native.state)) {
    voiceListening = false;
    voiceInputMode = null;
    stopVoiceCapturePolling();
    updateVoiceInputButton();
  }
}

function ensureVoiceCaptureStatusRefresh() {
  if (voiceCaptureStatusRefreshStarted) {
    return;
  }
  voiceCaptureStatusRefreshStarted = true;
  void refreshVoiceCaptureStatus();
}

function startVoiceCapturePolling() {
  if (voiceCapturePollTimer !== null) {
    return;
  }
  voiceCapturePollTimer = window.setInterval(() => {
    void refreshVoiceCaptureStatus();
  }, 250);
}

function stopVoiceCapturePolling() {
  if (voiceCapturePollTimer === null) {
    return;
  }
  window.clearInterval(voiceCapturePollTimer);
  voiceCapturePollTimer = null;
}

function updateVoiceInputButton() {
  const button = document.getElementById("voice-input-btn") as HTMLButtonElement | null;
  if (!button) {
    return;
  }

  const browserSupported = isBrowserVoiceInputSupported();
  const supported = browserSupported || isNativeVoiceCaptureAvailable();
  button.disabled = !supported;
  button.classList.toggle("is-recording", voiceListening);
  button.setAttribute("aria-pressed", voiceListening ? "true" : "false");
  const label = !supported
    ? isTauri()
      ? getLanguageText(
        "Voice input is unavailable until native microphone capture is ready",
        "ネイティブのマイク入力が準備できるまで音声入力は使えません",
      )
      : getLanguageText("Voice input is not available in this browser", "このブラウザーでは音声入力を利用できません")
    : voiceListening
      ? getLanguageText("Stop voice input", "音声入力を停止")
      : getLanguageText("Start voice input", "音声入力を開始");
  const labelWithShortcut = supported ? `${label} (${normalizeVoiceShortcut(themeState.voiceShortcut)})` : label;
  button.setAttribute("aria-label", labelWithShortcut);
  button.setAttribute("title", labelWithShortcut);
  renderVoiceCaptureStatus();
}

function stopVoiceInput() {
  if (voiceInputMode === "native") {
    void stopNativeVoiceInput(true);
    return;
  }

  if (!voiceRecognition) {
    return;
  }
  try {
    voiceRecognition.stop();
  } catch {
    voiceRecognition.abort();
  }
}

async function startNativeVoiceInput(composerInput: HTMLTextAreaElement) {
  try {
    voiceCaptureStatus = await startDesktopVoiceCapture();
    voiceCaptureStatusError = "";
    voiceInputMode = "native";
    voiceListening = true;
    markComposerInputSource("voice");
    startVoiceCapturePolling();
    updateVoiceInputButton();
    renderVoiceCaptureStatus();
    composerInput.focus();
  } catch (error) {
    voiceCaptureStatus = null;
    voiceCaptureStatusError = error instanceof Error ? error.message : String(error);
    voiceInputMode = null;
    voiceListening = false;
    stopVoiceCapturePolling();
    updateVoiceInputButton();
    renderVoiceCaptureStatus();
  }
}

async function stopNativeVoiceInput(cancelled: boolean) {
  try {
    voiceCaptureStatus = await stopDesktopVoiceCapture(cancelled);
    voiceCaptureStatusError = "";
  } catch (error) {
    voiceCaptureStatusError = error instanceof Error ? error.message : String(error);
  }
  voiceInputMode = null;
  voiceListening = false;
  stopVoiceCapturePolling();
  updateVoiceInputButton();
  renderVoiceCaptureStatus();
}

function escapeRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function normalizeVoiceDraftWhitespace(value: string) {
  return value
    .replace(/[ \t\r\n]+/g, " ")
    .replace(/\s+([、。,.!?])/g, "$1")
    .trim();
}

function removeVoiceFillers(value: string) {
  let text = value;
  for (const filler of ["えー", "えっと", "あの", "あのー", "その", "そのー", "まあ", "なんか"]) {
    text = text.replace(new RegExp(`(^|[\\s、。,.!?])${escapeRegExp(filler)}(?=$|[\\s、。,.!?])`, "g"), "$1");
  }
  text = text.replace(/\b(?:um|uh|erm|like)\b[,\s]*/gi, "");
  return normalizeVoiceDraftWhitespace(text);
}

function removeRepeatedVoicePhrases(value: string) {
  return normalizeVoiceDraftWhitespace(value
    .replace(/\b([A-Za-z0-9][\w'-]{1,})(?:\s+\1\b)+/gi, "$1")
    .replace(/([^\s、。,.!?]{2,12})(?:[、,]\s*\1)+/g, "$1"));
}

function removeVoiceSelfCorrectionMarkers(value: string) {
  return normalizeVoiceDraftWhitespace(value
    .replace(/(^|[、。,.!?]\s*)(?:いや|違う|訂正)[、,\s]*/g, "$1")
    .replace(/\b(?:sorry|correction|rather)\b[:,]?\s*/gi, ""));
}

function cleanVoiceTranscript(transcript: string) {
  return removeVoiceSelfCorrectionMarkers(removeRepeatedVoicePhrases(removeVoiceFillers(transcript)));
}

function shapeVoiceOperatorRequest(transcript: string) {
  return normalizeVoiceDraftWhitespace(cleanVoiceTranscript(transcript)
    .replace(/^(?:依頼です|お願い(?:したい(?:のですが|ですけど)?|です)?|やってほしいのは)[、,\s]*/u, "")
    .replace(/(?:お願いします|お願い)[。.!?\s]*$/u, "")
    .replace(/^(?:please|can you|could you)\s+/i, ""));
}

type VoiceSlashCommand = "ask" | "dispatch" | "review" | "goal";

const voiceSlashCommandAliases: Record<string, VoiceSlashCommand> = {
  ask: "ask",
  question: "ask",
  "質問": "ask",
  dispatch: "dispatch",
  request: "dispatch",
  task: "dispatch",
  "依頼": "dispatch",
  "タスク": "dispatch",
  review: "review",
  audit: "review",
  "レビュー": "review",
  "確認": "review",
  goal: "goal",
  objective: "goal",
  "ゴール": "goal",
  "目標": "goal",
};

function normalizeVoiceSlashCommandName(value: string): VoiceSlashCommand | null {
  const normalized = value
    .replace(/^\/+/, "")
    .trim()
    .toLowerCase();
  if (!normalized) {
    return null;
  }
  return voiceSlashCommandAliases[normalized] ?? null;
}

function getVoiceSlashBaseCommand(value: string): VoiceSlashCommand | null {
  const command = value.trim().match(/^\/([^\s]+)(?:\s+.*)?$/)?.[1] ?? "";
  return normalizeVoiceSlashCommandName(command);
}

function parseVoiceSlashCommand(transcript: string): { command: VoiceSlashCommand; body: string } | null {
  const cleaned = normalizeVoiceDraftWhitespace(cleanVoiceTranscript(transcript));
  const explicit = cleaned.match(/^(?:\/|slash|スラッシュ)\s*([^\s、。,.!?]+)(?:[\s、。,.!?]+(.*))?$/i);
  if (explicit) {
    const command = normalizeVoiceSlashCommandName(explicit[1]);
    if (command) {
      return { command, body: normalizeVoiceDraftWhitespace(explicit[2] ?? "") };
    }
  }

  const leading = cleaned.match(/^([^\s、。,.!?]+)(?:[\s、。,.!?]+(.*))?$/i);
  if (!leading) {
    return null;
  }
  const command = normalizeVoiceSlashCommandName(leading[1]);
  if (!command) {
    return null;
  }
  return { command, body: normalizeVoiceDraftWhitespace(leading[2] ?? "") };
}

function shapeVoiceTranscript(transcript: string) {
  switch (activeVoiceDraftMode) {
    case "cleaned":
      return cleanVoiceTranscript(transcript);
    case "operator_request":
      return shapeVoiceOperatorRequest(transcript);
    case "raw":
    default:
      return transcript;
  }
}

function shapeVoiceComposerDraft(base: string, transcript: string) {
  const trimmedBase = base.trim();
  const slashBaseCommand = getVoiceSlashBaseCommand(base);
  if (slashBaseCommand) {
    const shapedTranscript = shapeVoiceTranscript(transcript);
    const separator = shapedTranscript ? " " : "";
    return `${base.trimEnd()}${separator}${shapedTranscript}`.trimStart();
  }

  if (!trimmedBase || /^\/[^\s]*$/.test(trimmedBase)) {
    const slashDraft = parseVoiceSlashCommand(transcript);
    if (slashDraft) {
      return `/${slashDraft.command}${slashDraft.body ? ` ${slashDraft.body}` : ""}`;
    }
  }

  const shapedTranscript = shapeVoiceTranscript(transcript);
  const separator = base && shapedTranscript ? " " : "";
  return `${base}${separator}${shapedTranscript}`.trimStart();
}

function startVoiceInput(composerInput: HTMLTextAreaElement) {
  const SpeechRecognition = getSpeechRecognitionConstructor();
  if (!SpeechRecognition) {
    ensureVoiceCaptureStatusRefresh();
    if (isNativeVoiceCaptureAvailable()) {
      void startNativeVoiceInput(composerInput);
    }
    updateVoiceInputButton();
    return;
  }

  if (voiceRecognition) {
    stopVoiceInput();
  }

  voiceTranscriptBase = composerInput.value.trimEnd();
  const recognition = new SpeechRecognition();
  recognition.continuous = true;
  recognition.interimResults = true;
  recognition.lang = themeState.language === "ja" ? "ja-JP" : "en-US";
  recognition.onstart = () => {
    voiceListening = true;
    voiceInputMode = "browser";
    updateVoiceInputButton();
  };
  recognition.onend = () => {
    voiceListening = false;
    voiceRecognition = null;
    voiceInputMode = null;
    voiceTranscriptBase = "";
    updateVoiceInputButton();
    exitComposerHistoryToDraft(composerInput.value);
    syncComposerSlashState(composerInput.value);
  };
  recognition.onerror = (event) => {
    voiceListening = false;
    voiceInputMode = null;
    updateVoiceInputButton();
    if (event.error && event.error !== "no-speech" && event.error !== "aborted") {
      appendRuntimeConversation({
        type: "system",
        category: "attention",
        timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }),
        actor: "winsmux",
        title: getLanguageText("Voice input stopped", "音声入力を停止"),
        body: event.message || event.error,
        tone: "warning",
      });
      renderConversation(getConversationItems());
    }
  };
  recognition.onresult = (event) => {
    markComposerInputSource("voice");
    let transcript = "";
    for (let index = event.resultIndex; index < event.results.length; index += 1) {
      transcript += event.results[index]?.[0]?.transcript ?? "";
    }
    composerInput.value = shapeVoiceComposerDraft(voiceTranscriptBase, transcript);
    syncComposerInputHeight(composerInput);
    composerInput.focus();
    const length = composerInput.value.length;
    composerInput.setSelectionRange(length, length);
    syncComposerDraftState(composerInput.value);
    syncComposerSlashState(composerInput.value);
  };

  voiceRecognition = recognition;
  recognition.start();
}

function toggleVoiceInput(composerInput: HTMLTextAreaElement) {
  if (voiceListening) {
    stopVoiceInput();
    return;
  }
  startVoiceInput(composerInput);
}

function markComposerInputSource(source: DogfoodInputSource) {
  const now = Date.now();
  composerInputSource = source;
  if (!composerDraftStartedAt) {
    composerDraftStartedAt = now;
  }
  ensureComposerDogfoodTaskRef(now);
  if (source === "voice" && !composerVoiceStartedAt) {
    composerVoiceStartedAt = now;
  }
  if (source === "keyboard" && composerVoiceStartedAt && !composerKeyboardAfterVoiceAt) {
    composerKeyboardAfterVoiceAt = now;
  }
}

function resetComposerDogfoodDraft() {
  composerInputSource = "keyboard";
  composerDraftStartedAt = 0;
  composerDogfoodTaskRef = "";
  composerVoiceStartedAt = 0;
  composerKeyboardAfterVoiceAt = 0;
}

function ensureComposerDogfoodTaskRef(timestamp = Date.now()) {
  if (!composerDogfoodTaskRef) {
    composerDogfoodTaskRef = `desktop-command-${++dogfoodRunCounter}-${timestamp}`;
  }
  return composerDogfoodTaskRef;
}

function isComposerTypingKey(event: KeyboardEvent) {
  return (
    event.key.length === 1 ||
    event.key === "Backspace" ||
    event.key === "Delete"
  ) && !event.ctrlKey && !event.metaKey && !event.altKey;
}

async function sha256Hex(value: string) {
  if (!window.crypto?.subtle) {
    return "";
  }
  const digest = await window.crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function recordComposerDogfoodEvent(
  message: string,
  attachments: ComposerAttachment[],
  inputSource: DogfoodInputSource,
  startedAt: number,
  draft: { taskRef: string; voiceStartedAt: number; keyboardAfterVoiceAt: number },
) {
  if (draft.voiceStartedAt) {
    await recordOperatorDogfoodEvent({
      actionType: "input",
      inputSource: "voice",
      timestamp: draft.voiceStartedAt,
      startedAt: draft.voiceStartedAt,
      taskRef: draft.taskRef,
      taskClass: activeComposerMode,
      payload: { phase: "draft-input", source: "voice" },
    });
  }
  if (draft.keyboardAfterVoiceAt) {
    await recordOperatorDogfoodEvent({
      actionType: "input",
      inputSource: "keyboard",
      timestamp: draft.keyboardAfterVoiceAt,
      startedAt: draft.keyboardAfterVoiceAt,
      taskRef: draft.taskRef,
      taskClass: activeComposerMode,
      payload: { phase: "draft-input", source: "keyboard" },
    });
  }
  await recordOperatorDogfoodEvent({
    actionType: "command",
    inputSource,
    startedAt,
    taskRef: draft.taskRef,
    taskClass: activeComposerMode,
    payload: {
      message,
      attachments: attachments.map((attachment) => ({
        name: attachment.name,
        kind: attachment.kind,
        sizeLabel: attachment.sizeLabel,
      })),
    },
  });
}

async function recordOperatorDogfoodEvent(input: {
  actionType: DogfoodActionType;
  inputSource: DogfoodInputSource;
  timestamp?: number;
  startedAt?: number;
  runId?: string;
  taskRef?: string;
  taskClass?: string;
  payload: unknown;
}) {
  if (!isTauri()) {
    return;
  }
  const timestamp = input.timestamp || Date.now();
  const startedAt = input.startedAt || timestamp;
  const fallbackRunId = input.actionType === "command" || input.actionType === "input" ? "" : `desktop-${input.actionType}-${++dogfoodRunCounter}-${timestamp}`;
  const runId = input.runId || fallbackRunId;
  const fallbackTaskRef = input.actionType === "command" || input.actionType === "input"
    ? `desktop-command-${++dogfoodRunCounter}-${timestamp}`
    : input.runId ? input.runId : "";
  const taskRef = input.taskRef ?? fallbackTaskRef;
  const payloadHash = await sha256Hex(JSON.stringify(input.payload));
  try {
    await recordDesktopDogfoodEvent(
      {
        timestamp,
        runId,
        sessionId: dogfoodSessionId,
        paneId: OPERATOR_PTY_ID,
        inputSource: input.inputSource,
        actionType: input.actionType,
        taskRef,
        durationMs: Math.max(0, timestamp - startedAt),
        payloadHash,
        mode: "winsmux_desktop",
        taskClass: input.taskClass || "operator",
        model: getComposerModelOption().label,
        reasoningEffort: activeComposerEffort,
      },
      getActiveProjectDirPayload(),
    );
  } catch (error) {
    console.warn("Failed to record dogfood event", error);
  }
}

function insertComposerTab(composerInput: HTMLTextAreaElement) {
  const start = composerInput.selectionStart;
  const end = composerInput.selectionEnd;
  composerInput.setRangeText("\t", start, end, "end");
}

function isComposerSelectionCollapsed(composerInput: HTMLTextAreaElement) {
  return composerInput.selectionStart === composerInput.selectionEnd;
}

function isCaretOnFirstLine(composerInput: HTMLTextAreaElement) {
  return !composerInput.value.slice(0, composerInput.selectionStart).includes("\n");
}

function isCaretOnLastLine(composerInput: HTMLTextAreaElement) {
  return !composerInput.value.slice(composerInput.selectionEnd).includes("\n");
}

function syncComposerInputHeight(composerInput?: HTMLTextAreaElement | null) {
  const input = composerInput ?? (document.getElementById("composer-input") as HTMLTextAreaElement | null);
  if (!input) {
    return;
  }

  input.style.height = "auto";
  const computed = window.getComputedStyle(input);
  const minHeight = Number.parseFloat(computed.minHeight) || 0;
  const maxHeight = Number.parseFloat(computed.maxHeight) || input.scrollHeight;
  const targetHeight = Math.min(Math.max(input.scrollHeight, minHeight), maxHeight);
  input.style.height = `${Math.ceil(targetHeight)}px`;
  input.style.overflowY = input.scrollHeight > maxHeight + 1 ? "auto" : "hidden";
}

function setComposerValue(value: string) {
  const composerInput = document.getElementById("composer-input") as HTMLTextAreaElement | null;
  if (!composerInput) {
    return;
  }

  composerInput.value = value;
  syncComposerInputHeight(composerInput);
  syncComposerSlashState(value);
  const length = value.length;
  composerInput.setSelectionRange(length, length);
}

function syncComposerDraftState(value?: string) {
  const composerInput = document.getElementById("composer-input") as HTMLTextAreaElement | null;
  composerDraftState = captureComposerHistoryEntry(value ?? composerInput?.value ?? "");
}

function exitComposerHistoryToDraft(value?: string) {
  composerHistoryIndex = -1;
  syncComposerDraftState(value);
}

function snapshotComposerAttachments(attachments: ComposerAttachment[]): ComposerAttachmentSnapshot[] {
  return attachments.map((item) => ({
    name: item.name,
    kind: item.kind,
    sizeLabel: item.sizeLabel,
    file: item.file,
  }));
}

function restoreComposerAttachments(snapshots: ComposerAttachmentSnapshot[]) {
  return snapshots.map((item) => ({
    id: `${item.name}-${item.file.size}-${item.file.lastModified}-${Math.random().toString(36).slice(2, 8)}`,
    name: item.name,
    kind: item.kind,
    sizeLabel: item.sizeLabel,
    file: item.file,
    previewUrl: item.kind === "image" ? URL.createObjectURL(item.file) : undefined,
  }));
}

function captureComposerHistoryEntry(value: string): ComposerHistoryEntry {
  return {
    value,
    remoteReferenceIds: Array.from(selectedComposerRemoteReferenceIds),
    attachments: snapshotComposerAttachments(pendingAttachments),
  };
}

function applyComposerHistoryEntry(entry: ComposerHistoryEntry) {
  setComposerValue(entry.value);
  clearPendingAttachments();
  pendingAttachments = restoreComposerAttachments(entry.attachments);
  selectedComposerRemoteReferenceIds = new Set(entry.remoteReferenceIds);
  renderAttachmentTray();
  renderComposerRemoteReferences();
}

function stepComposerHistory(direction: -1 | 1) {
  if (composerHistory.length === 0) {
    return;
  }

  if (direction === -1) {
    if (composerHistoryIndex === -1) {
      const composerInput = document.getElementById("composer-input") as HTMLTextAreaElement | null;
      composerDraftState = captureComposerHistoryEntry(composerInput?.value ?? "");
      composerHistoryIndex = composerHistory.length - 1;
    } else if (composerHistoryIndex > 0) {
      composerHistoryIndex -= 1;
    }
    applyComposerHistoryEntry(composerHistory[composerHistoryIndex] ?? composerDraftState);
    return;
  }

  if (composerHistoryIndex === -1) {
    return;
  }

  if (composerHistoryIndex < composerHistory.length - 1) {
    composerHistoryIndex += 1;
    applyComposerHistoryEntry(composerHistory[composerHistoryIndex] ?? composerDraftState);
    return;
  }

  composerHistoryIndex = -1;
  applyComposerHistoryEntry(composerDraftState);
}

function pushComposerHistoryEntry(entry: ComposerHistoryEntry) {
  if (!entry.value && entry.remoteReferenceIds.length === 0 && entry.attachments.length === 0) {
    return;
  }

  composerHistory = [entry, ...composerHistory].slice(0, 20);
  composerHistoryIndex = -1;
  composerDraftState = { value: "", remoteReferenceIds: [], attachments: [] };
}

function getComposerRemoteReferences() {
  const selectedProjection = getPrimaryRunProjection();
  const references: ComposerRemoteReference[] = [];

  if (selectedProjection) {
    references.push({
      id: `run:${selectedProjection.run_id}`,
      label: selectedProjection.run_id,
      meta: `${selectedProjection.next_action || "idle"} · ${selectedProjection.branch || "no branch"}`,
    });
  }

  for (const change of getVisibleSourceChanges().slice(0, 3)) {
    references.push({
      id: `change:${getSourceChangeKey(change)}`,
      label: change.path.split("/").pop() ?? change.path,
      meta: `${change.status} · ${change.branch}`,
    });
  }

  return references;
}

function renderComposerRemoteReferences() {
  const root = document.getElementById("composer-remote-row");
  if (!root) {
    return;
  }

  root.innerHTML = "";
  root.hidden = true;
  selectedComposerRemoteReferenceIds.clear();
}

function getComposerPermissionModeOption(mode: ComposerPermissionMode = activeComposerPermissionMode) {
  return composerPermissionModeOptions.find((item) => item.value === mode) ?? composerPermissionModeOptions[0];
}

function getComposerModelOption(model: ComposerModelId = activeComposerModel) {
  return composerModelOptions.find((item) => item.value === model) ?? composerModelOptions[0];
}

function isComposerFastModeCompatible(model: ComposerModelId = activeComposerModel) {
  return Boolean(getComposerModelOption(model).fastModeCompatible);
}

function getComposerFastModeAppliedState() {
  return activeComposerFastModeTogglePending
    ? !activeComposerFastModeEnabled
    : activeComposerFastModeEnabled;
}

function getComposerEffortOption(effort: ComposerEffortLevel = activeComposerEffort) {
  return composerEffortOptions.find((item) => item.value === effort) ?? composerEffortOptions[0];
}

function getVoiceDraftModeOption(mode: VoiceDraftMode = activeVoiceDraftMode) {
  return voiceDraftModeOptions.find((item) => item.value === mode) ?? voiceDraftModeOptions[0];
}

function setComposerPermissionMode(mode: ComposerPermissionMode) {
  activeComposerPermissionMode = mode;
  persistComposerSessionControls();
  openComposerSessionMenu = null;
  renderComposerSessionControls();
}

function setComposerEffort(effort: ComposerEffortLevel) {
  activeComposerEffort = effort;
  persistComposerSessionControls();
  renderComposerSessionControls();
}

function setComposerModel(model: ComposerModelId) {
  const previousAppliedState = getComposerFastModeAppliedState();
  activeComposerModel = model;
  if (!isComposerFastModeCompatible(model)) {
    activeComposerFastModeEnabled = false;
    activeComposerFastModeTogglePending = previousAppliedState;
  }
  persistComposerSessionControls();
  renderComposerSessionControls();
}

function setComposerFastMode(enabled: boolean) {
  const previousAppliedState = getComposerFastModeAppliedState();
  const nextEnabled = enabled && isComposerFastModeCompatible();
  activeComposerFastModeEnabled = nextEnabled;
  activeComposerFastModeTogglePending = nextEnabled !== previousAppliedState;
  persistComposerSessionControls();
  renderComposerSessionControls();
}

function setVoiceDraftMode(mode: VoiceDraftMode) {
  activeVoiceDraftMode = mode;
  persistComposerSessionControls();
  openComposerSessionMenu = null;
  renderComposerSessionControls();
}

function stepComposerPermissionMode(delta: 1 | -1) {
  const currentIndex = composerPermissionModeOptions.findIndex((item) => item.value === activeComposerPermissionMode);
  const index = currentIndex === -1 ? 0 : currentIndex;
  const next = composerPermissionModeOptions[(index + delta + composerPermissionModeOptions.length) % composerPermissionModeOptions.length];
  setComposerPermissionMode(next.value);
}

function createComposerShortcut(label: string) {
  const shortcut = document.createElement("span");
  shortcut.className = "composer-session-shortcut";
  shortcut.textContent = label;
  return shortcut;
}

function createComposerSessionControl(kind: "permission" | "model" | "voice", selectedLabel: string) {
  const group = document.createElement("div");
  group.className = `composer-session-control composer-session-control-${kind}`;

  const button = document.createElement("button");
  button.type = "button";
  button.className = `composer-session-trigger composer-session-trigger-${kind}`;
  button.setAttribute("aria-expanded", openComposerSessionMenu === kind ? "true" : "false");
  button.setAttribute("aria-haspopup", "menu");
  button.setAttribute("aria-controls", `composer-${kind}-menu`);
  button.innerHTML = `<span class="composer-session-value">${selectedLabel}</span>`;
  button.addEventListener("click", (event) => {
    event.stopPropagation();
    openComposerSessionMenu = openComposerSessionMenu === kind ? null : kind;
    renderComposerSessionControls();
  });
  group.appendChild(button);
  return group;
}

function createComposerMenu(id: string, className = "") {
  const menu = document.createElement("div");
  menu.id = id;
  menu.className = `composer-session-menu ${className}`.trim();
  menu.setAttribute("role", "menu");
  return menu;
}

function appendComposerMenuHeading(menu: HTMLElement, label: string) {
  const heading = document.createElement("div");
  heading.className = "composer-session-heading";
  heading.textContent = label;
  menu.appendChild(heading);
}

function appendComposerMenuSeparator(menu: HTMLElement) {
  const separator = document.createElement("div");
  separator.className = "composer-session-separator";
  menu.appendChild(separator);
}

function appendComposerOptionButton<T extends string>(
  menu: HTMLElement,
  option: { value: T; label: string; labelJa: string; description?: string; descriptionJa?: string; shortcut?: string },
  selectedValue: T,
  onSelect: (value: T) => void,
) {
  const japanese = themeState.language === "ja";
  const optionButton = document.createElement("button");
  optionButton.type = "button";
  optionButton.className = `composer-session-option ${option.value === selectedValue ? "is-active" : ""}`;
  optionButton.setAttribute("role", "menuitemradio");
  optionButton.setAttribute("aria-checked", option.value === selectedValue ? "true" : "false");

  const labelRow = document.createElement("span");
  labelRow.className = "composer-session-option-label-row";

  const label = document.createElement("span");
  label.className = "composer-session-option-label";
  label.textContent = japanese ? option.labelJa : option.label;
  labelRow.appendChild(label);
  if (option.shortcut) {
    labelRow.appendChild(createComposerShortcut(option.shortcut));
  }
  optionButton.appendChild(labelRow);

  const descriptionText = japanese ? option.descriptionJa : option.description;
  if (descriptionText) {
    const description = document.createElement("span");
    description.className = "composer-session-option-description";
    description.textContent = descriptionText;
    optionButton.appendChild(description);
  }

  optionButton.addEventListener("click", (event) => {
    event.stopPropagation();
    onSelect(option.value);
  });
  menu.appendChild(optionButton);
}

function createComposerPermissionMenu() {
  const group = createComposerSessionControl("permission", themeState.language === "ja" ? getComposerPermissionModeOption().labelJa : getComposerPermissionModeOption().label);
  if (openComposerSessionMenu !== "permission") {
    return group;
  }

  const menu = createComposerMenu("composer-permission-menu", "composer-session-menu-permission");
  appendComposerMenuHeading(menu, themeState.language === "ja" ? "モード" : "Mode");
  for (const option of composerPermissionModeOptions) {
    appendComposerOptionButton(menu, option, activeComposerPermissionMode, setComposerPermissionMode);
  }
  group.appendChild(menu);
  return group;
}

function createComposerVoiceDraftMenu() {
  const selected = getVoiceDraftModeOption();
  const group = createComposerSessionControl("voice", themeState.language === "ja" ? selected.labelJa : selected.label);
  if (openComposerSessionMenu !== "voice") {
    return group;
  }

  const menu = createComposerMenu("composer-voice-menu", "composer-session-menu-voice");
  appendComposerMenuHeading(menu, themeState.language === "ja" ? "音声下書き" : "Voice draft");
  for (const option of voiceDraftModeOptions) {
    appendComposerOptionButton(menu, option, activeVoiceDraftMode, setVoiceDraftMode);
  }
  group.appendChild(menu);
  return group;
}

function createComposerModelMenu() {
  const modelOption = getComposerModelOption();
  const effortOption = getComposerEffortOption();
  const selectedLabel = `${themeState.language === "ja" ? modelOption.labelJa : modelOption.label}・${themeState.language === "ja" ? effortOption.labelJa : effortOption.label}`;
  const group = createComposerSessionControl("model", selectedLabel);
  if (openComposerSessionMenu !== "model") {
    return group;
  }

  const japanese = themeState.language === "ja";
  const menu = createComposerMenu("composer-model-menu", "composer-session-menu-model");
  appendComposerMenuHeading(menu, japanese ? "モデル" : "Model");
  for (const option of composerModelOptions) {
    appendComposerOptionButton(menu, option, activeComposerModel, setComposerModel);
  }
  appendComposerMenuSeparator(menu);
  appendComposerMenuHeading(menu, japanese ? "工数" : "Effort");
  for (const option of composerEffortOptions) {
    appendComposerOptionButton(menu, option, activeComposerEffort, setComposerEffort);
  }
  appendComposerMenuSeparator(menu);
  appendComposerMenuHeading(menu, japanese ? "高速モード" : "Fast mode");
  const fastModeCompatible = isComposerFastModeCompatible();
  if (!fastModeCompatible && activeComposerFastModeEnabled) {
    activeComposerFastModeEnabled = false;
    activeComposerFastModeTogglePending = false;
    persistComposerSessionControls();
  }
  const fastToggle = document.createElement("button");
  fastToggle.type = "button";
  fastToggle.className = `composer-fast-toggle ${activeComposerFastModeEnabled ? "is-active" : ""}`;
  fastToggle.disabled = !fastModeCompatible;
  fastToggle.setAttribute("role", "switch");
  fastToggle.setAttribute("aria-checked", activeComposerFastModeEnabled ? "true" : "false");
  fastToggle.setAttribute("aria-disabled", fastModeCompatible ? "false" : "true");
  fastToggle.innerHTML = `
    <span>${fastModeCompatible ? (japanese ? "高速モードを有効にする" : "Enable fast mode") : (japanese ? "高速モードは Opus 4.6 でのみ利用できます" : "Fast mode is only available on Opus 4.6")}</span>
    <span class="composer-fast-toggle-track" aria-hidden="true"><span class="composer-fast-toggle-thumb"></span></span>
  `;
  fastToggle.addEventListener("click", (event) => {
    event.stopPropagation();
    if (!fastModeCompatible) {
      return;
    }
    setComposerFastMode(!activeComposerFastModeEnabled);
  });
  menu.appendChild(fastToggle);
  group.appendChild(menu);

  return group;
}

function renderComposerSessionControls() {
  const root = document.getElementById("composer-session-row");
  const modelRoot = document.getElementById("composer-model-row");
  if (!root) {
    return;
  }

  root.innerHTML = "";
  if (modelRoot) {
    modelRoot.innerHTML = "";
  }
  root.appendChild(createComposerPermissionMenu());
  root.appendChild(createComposerVoiceDraftMenu());
  (modelRoot ?? root).appendChild(createComposerModelMenu());
}

function renderComposerModeChrome() {
  const composerInput = document.getElementById("composer-input") as HTMLTextAreaElement | null;
  const selected = composerModes.find((item) => item.mode === activeComposerMode);
  if (composerInput && selected) {
    composerInput.placeholder = getComposerModePlaceholder(selected.mode);
  }

  renderComposerSlashCommands();
  renderComposerRemoteReferences();
  renderComposerSessionControls();
  renderFooterLane();
}

function renderComposerModes() {
  const root = document.getElementById("composer-mode-row");
  if (root) {
    root.innerHTML = "";
    root.hidden = true;
  }

  renderComposerModeChrome();
}

function getComposerModeLabel(mode: ComposerMode) {
  if (themeState.language !== "ja") {
    return composerModes.find((item) => item.mode === mode)?.label ?? mode;
  }
  switch (mode) {
    case "ask":
      return "質問";
    case "dispatch":
      return "依頼";
    case "review":
      return "レビュー";
  }
}

function getComposerModePlaceholder(mode: ComposerMode) {
  if (themeState.language !== "ja") {
    return composerModes.find((item) => item.mode === mode)?.placeholder ?? "";
  }
  switch (mode) {
    case "ask":
      return "質問や相談内容を入力してください";
    case "dispatch":
      return "タスクを説明するか、質問を入力してください";
    case "review":
      return "レビューしてほしい内容を入力してください";
  }
}

function formatAttachmentSize(size: number) {
  if (size >= 1024 * 1024) {
    return `${(size / (1024 * 1024)).toFixed(1)} MB`;
  }
  if (size >= 1024) {
    return `${Math.max(1, Math.round(size / 1024))} KB`;
  }
  return `${size} B`;
}

function synthesizeScreenshotName() {
  const now = new Date();
  const date = `${now.getFullYear()}-${`${now.getMonth() + 1}`.padStart(2, "0")}-${`${now.getDate()}`.padStart(2, "0")}`;
  const time = `${`${now.getHours()}`.padStart(2, "0")}.${`${now.getMinutes()}`.padStart(2, "0")}.${`${now.getSeconds()}`.padStart(2, "0")}`;
  return `Screenshot ${date} ${time}.png`;
}

function createComposerAttachment(file: File) {
  const name = file.name?.trim() ? file.name : file.type.startsWith("image/") ? synthesizeScreenshotName() : "Attachment";
  const kind: "image" | "file" = file.type.startsWith("image/") ? "image" : "file";
  return {
    id: `${name}-${file.size}-${file.lastModified}-${Math.random().toString(36).slice(2, 8)}`,
    name,
    kind,
    sizeLabel: formatAttachmentSize(file.size),
    file,
    previewUrl: kind === "image" ? URL.createObjectURL(file) : undefined,
  } satisfies ComposerAttachment;
}

function releaseAttachmentPreview(attachment: ComposerAttachment) {
  if (attachment.previewUrl) {
    URL.revokeObjectURL(attachment.previewUrl);
  }
}

function clearPendingAttachments() {
  for (const attachment of pendingAttachments) {
    releaseAttachmentPreview(attachment);
  }
  pendingAttachments = [];
}

function renderAttachmentTray() {
  const tray = document.getElementById("attachment-tray");
  if (!tray) {
    return;
  }

  tray.innerHTML = "";
  tray.classList.toggle("is-empty", pendingAttachments.length === 0);
  tray.hidden = pendingAttachments.length === 0;

  if (pendingAttachments.length === 0) {
    return;
  }

  for (const attachment of pendingAttachments) {
    const item = document.createElement("div");
    item.className = "attachment-item";

    if (attachment.previewUrl) {
      const thumb = document.createElement("img");
      thumb.className = "attachment-thumb";
      thumb.src = attachment.previewUrl;
      thumb.alt = attachment.name;
      item.appendChild(thumb);
    } else {
      const icon = document.createElement("div");
      icon.className = "attachment-thumb attachment-thumb-file";
      icon.textContent = attachment.kind === "image" ? "IMG" : "FILE";
      item.appendChild(icon);
    }

    const meta = document.createElement("div");
    meta.className = "attachment-meta";
    meta.innerHTML = `<span class="attachment-name">${attachment.name}</span><span class="attachment-size">${attachment.sizeLabel}</span>`;
    item.appendChild(meta);

    const removeButton = document.createElement("button");
    removeButton.type = "button";
    removeButton.className = "attachment-remove";
    removeButton.setAttribute("aria-label", getLanguageText(`Remove ${attachment.name}`, `${attachment.name} を削除`));
    removeButton.textContent = getLanguageText("Remove", "削除");
    removeButton.addEventListener("click", () => {
      releaseAttachmentPreview(attachment);
      pendingAttachments = pendingAttachments.filter((item) => item.id !== attachment.id);
      exitComposerHistoryToDraft();
      renderAttachmentTray();
    });
    item.appendChild(removeButton);

    tray.appendChild(item);
  }
}

function appendAttachments(files: File[]) {
  if (files.length === 0) {
    return;
  }

  const remaining = Math.max(0, 5 - pendingAttachments.length);
  if (remaining <= 0) {
    return;
  }

  const next = files.slice(0, remaining).map((file) => createComposerAttachment(file));
  pendingAttachments = [...pendingAttachments, ...next];
  exitComposerHistoryToDraft();
  renderAttachmentTray();
}

function getClipboardAttachmentFiles(data: DataTransfer | null) {
  if (!data) {
    return [];
  }

  const files = [
    ...Array.from(data.files ?? []),
    ...Array.from(data.items ?? [])
      .filter((item) => item.kind === "file")
      .map((item) => item.getAsFile())
      .filter((file): file is File => Boolean(file)),
  ];
  const seen = new Set<string>();
  return files.filter((file) => {
    const key = `${file.name}:${file.type}:${file.size}:${file.lastModified}`;
    if (seen.has(key)) {
      return false;
    }
    seen.add(key);
    return true;
  });
}

async function readClipboardImageFiles() {
  if (!navigator.clipboard?.read) {
    return [];
  }

  try {
    const clipboardItems = await navigator.clipboard.read();
    const files: File[] = [];
    for (const item of clipboardItems) {
      const imageType = item.types.find((type) => type.startsWith("image/"));
      if (!imageType) {
        continue;
      }
      const blob = await item.getType(imageType);
      const extension = imageType.split("/")[1] || "png";
      const timestamp = Date.now();
      files.push(new File([blob], `clipboard-image-${timestamp}-${files.length + 1}.${extension}`, { type: imageType, lastModified: timestamp }));
    }
    return files;
  } catch {
    return [];
  }
}

function getVisibleConversationItems(items: ConversationItem[]) {
  switch (activeTimelineFilter) {
    case "attention":
      return items.filter((item) => item.category === "attention");
    case "review":
      return items.filter((item) => item.category === "review");
    case "activity":
      return items.filter((item) => item.category === "activity" || item.type === "operator");
    default:
      return items;
  }
}

function shouldShowTimelineDetails(item: ConversationItem) {
  if (themeState.focusMode !== "focused") {
    return true;
  }

  if (item.category === "attention" || item.category === "review") {
    return true;
  }

  return Boolean(item.runId && item.runId === getSelectedRunId());
}

function updateTimelineFeedHint() {
  const hint = document.getElementById("timeline-feed-hint");
  if (!hint) {
    return;
  }

  hint.textContent = themeState.focusMode === "focused"
    ? getLanguageText("Focus mode hides routine details. Select a run to expand it.", "集中表示では通常の詳細を隠します。実行を選ぶと展開します。")
    : getLanguageText("Key events only. Details open when needed.", "重要な出来事だけを表示します。必要な時に詳細を開きます。");
}

function renderTimelineFilters() {
  const root = document.getElementById("timeline-filter-row");
  if (!root) {
    return;
  }

  root.innerHTML = "";
  for (const item of timelineFilters) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `timeline-filter-chip ${item.filter === activeTimelineFilter ? "is-active" : ""}`;
    button.textContent = themeState.language === "ja" ? timelineFilterLabelsJa[item.filter] : item.label;
    button.setAttribute("aria-pressed", item.filter === activeTimelineFilter ? "true" : "false");
    button.addEventListener("click", () => {
      activeTimelineFilter = item.filter;
      renderTimelineFilters();
      renderConversation(getConversationItems());
      renderRunSummary();
    });
    root.appendChild(button);
  }
  syncActivityButtons();
}

function renderRunSummary() {
  const root = document.getElementById("selected-run-summary");
  if (!root) {
    return;
  }

  const projection = getPrimaryRunProjection();
  if (projection) {
    root.hidden = false;
    const statusTone =
      projection.review_state === "PASS"
        ? "success"
        : projection.review_state === "PENDING"
          ? "warning"
          : projection.review_state === "FAIL" || projection.review_state === "FAILED"
            ? "danger"
            : "info";
    const verification = projection.verification_outcome
      ? getLanguageText(`verify ${projection.verification_outcome}`, `検証 ${projection.verification_outcome}`)
      : getLanguageText("verify n/a", "検証なし");
    const security = projection.security_blocked
      ? getLanguageText(`security ${projection.security_blocked}`, `セキュリティ ${projection.security_blocked}`)
      : getLanguageText("security n/a", "セキュリティなし");

    root.innerHTML = `
      <div class="run-summary-card">
        <div class="run-summary-header">
          <div>
            <div class="timeline-eyebrow">${getLanguageText("Selected run", "選択中の実行")}</div>
            <div class="run-summary-title">${projection.run_id}</div>
          </div>
          <div class="run-summary-status" data-tone="${statusTone}">
            ${projection.detail || projection.activity || projection.review_state || getLanguageText("ready", "準備済み")}
          </div>
        </div>
        <div class="run-summary-meta-row">
          <span class="run-summary-pill">${projection.label || projection.pane_id || "summary-stream"}</span>
          <span class="run-summary-pill">${projection.branch || getLanguageText("no branch", "ブランチなし")}</span>
          <span class="run-summary-pill">${projection.phase || getLanguageText("no phase", "フェーズなし")}</span>
          <span class="run-summary-pill">${getLanguageText(`${projection.changed_files.length} changed`, `${projection.changed_files.length} 件の変更`)}</span>
          <span class="run-summary-pill">${projection.next_action || getLanguageText("no next action", "次の操作なし")}</span>
          <span class="run-summary-pill">${verification}</span>
          <span class="run-summary-pill">${security}</span>
        </div>
        <div class="run-summary-body">${projection.summary || projection.task || getLanguageText("Projected run surfaced by the backend adapter.", "バックエンドから投影された実行です。")}</div>
        <div class="timeline-chip-row">
          <button type="button" class="timeline-chip" data-action="open-explain">${getLanguageText("Open Explain", "説明を開く")}</button>
          <button type="button" class="timeline-chip" data-action="open-source-context">${getLanguageText("Source Control", "ソース管理")}</button>
          <button type="button" class="timeline-chip" data-action="open-terminal">${getLanguageText("Terminal", "端末")}</button>
        </div>
      </div>
    `;

    for (const button of root.querySelectorAll<HTMLButtonElement>(".timeline-chip")) {
      const action = button.dataset.action as ChipAction | undefined;
      if (!action) {
        continue;
      }
      button.addEventListener("click", () => handleChipAction(action));
    }
    return;
  }

  root.hidden = true;
  root.innerHTML = "";
}

function renderConversation(items: ConversationItem[]) {
  const timeline = document.getElementById("conversation-timeline");
  if (!timeline) {
    return;
  }

  timeline.innerHTML = "";
  const visibleItems = getVisibleConversationItems(items);

  if (visibleItems.length === 0) {
    const empty = document.createElement("div");
    empty.className = "attachment-empty-state";
    empty.textContent = getLanguageText("No events in this filter yet.", "この条件に一致するイベントはまだありません。");
    timeline.appendChild(empty);
    return;
  }

  for (const item of visibleItems) {
    const article = document.createElement("article");
    article.className = `timeline-item timeline-${item.type}`;
    article.dataset.tone = item.tone ?? (item.type === "operator" ? "info" : item.type === "system" ? "focus" : "default");
    if (item.runId) {
      article.classList.toggle("is-selected-run", item.runId === getSelectedRunId());
      article.addEventListener("click", () => {
        setSelectedRun(item.runId ?? null);
        renderDesktopSurfaces();
      });
    }

    const meta = document.createElement("div");
    meta.className = "timeline-meta-row";
    meta.innerHTML =
      `<span class="timeline-actor">${item.actor}</span>` +
      `<span class="timeline-meta-separator">·</span>` +
      `<span>${item.timestamp}</span>` +
      (item.runId ? `<span class="timeline-meta-separator">·</span><span>${item.runId}</span>` : "") +
      (item.statusLabel ? `<span class="timeline-status-pill">${item.statusLabel}</span>` : "");
    article.appendChild(meta);

    if (item.title) {
      const title = document.createElement("div");
      title.className = "timeline-title";
      title.textContent = item.title;
      article.appendChild(title);
    }

    const body = document.createElement("div");
    body.className = "timeline-body";
    body.textContent = item.body;
    article.appendChild(body);

    if (item.details?.length && shouldShowTimelineDetails(item)) {
      const detailRow = document.createElement("div");
      detailRow.className = "timeline-detail-row";
      for (const detail of item.details) {
        const pill = document.createElement("span");
        pill.className = "timeline-detail-pill";
        pill.innerHTML = `<span class="timeline-detail-label">${detail.label}</span><span>${detail.value}</span>`;
        detailRow.appendChild(pill);
      }
      article.appendChild(detailRow);
    }

    if (item.attachments?.length) {
      const attachmentRow = document.createElement("div");
      attachmentRow.className = "timeline-attachment-row";
      for (const attachment of item.attachments) {
        const pill = document.createElement("span");
        pill.className = "timeline-attachment-pill";
        pill.innerHTML = `<span>${attachment.kind === "image" ? "Image" : "File"}</span><span>${attachment.name}</span><span>${attachment.sizeLabel}</span>`;
        attachmentRow.appendChild(pill);
      }
      article.appendChild(attachmentRow);
    }

    if (item.chips?.length) {
      const chipRow = document.createElement("div");
      chipRow.className = "timeline-chip-row";
      for (const chipInfo of item.chips) {
        const chip = document.createElement("button");
        chip.type = "button";
        chip.className = "timeline-chip";
        chip.textContent = chipInfo.label;
        chip.addEventListener("click", () => handleChipAction(chipInfo.action));
        chipRow.appendChild(chip);
      }
      article.appendChild(chipRow);
    }

    timeline.appendChild(article);
  }
}

async function openExplainForSelectedRun() {
  const selectedRunId = getSelectedRunId();
  if (!selectedRunId) {
    appendRuntimeConversation({
      type: "operator",
      category: "activity",
      timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: "Operator",
      title: "Select a run first",
      body: "Explain requires a selected run from the desktop summary.",
      details: [{ label: "runs", value: `${getRunProjections().length}` }],
      tone: "info",
    });
    renderConversation(getConversationItems());
    return;
  }

  try {
    const previousPayload = desktopExplainCache.get(selectedRunId) ?? null;
    const projectDir = getActiveProjectDirPayload();
    const projectKey = captureProjectRequestKey();
    const payload = await getDesktopRunExplain(selectedRunId, projectDir);
    if (!isProjectRequestCurrent(projectKey)) {
      return;
    }
    const observationPack = getObservationPack(payload);
    const consultationSummary = getConsultationSummary(payload);
    desktopExplainCache.set(selectedRunId, payload);

    const detailItems: ConversationDetail[] = [
      { label: "run", value: payload.run.run_id },
      { label: "next", value: payload.explanation.next_action || payload.evidence_digest.next_action || "no next action" },
    ];
    if (payload.run.provider_target) {
      detailItems.push({ label: "model", value: payload.run.provider_target });
    }
    if (payload.run.priority) {
      detailItems.push({ label: "priority", value: payload.run.priority });
    }
    if (payload.run.pane_count > 0) {
      detailItems.push({ label: "panes", value: `${payload.run.pane_count}` });
    }
    if (payload.run.tokens_remaining) {
      detailItems.push({ label: "context", value: payload.run.tokens_remaining });
    }
    if (payload.run.experiment_packet.next_action) {
      detailItems.push({ label: "experiment", value: payload.run.experiment_packet.next_action });
    }
    if (observationPack.hypothesis) {
      detailItems.push({ label: "observe", value: observationPack.hypothesis });
    }
    if (consultationSummary.next_test) {
      detailItems.push({ label: "consult", value: consultationSummary.next_test });
    }
    if (payload.run.primary_label) {
      detailItems.push({ label: "pane", value: payload.run.primary_label });
    }
    if (payload.run.branch) {
      detailItems.push({ label: "branch", value: payload.run.branch });
    }
    if (payload.run.worktree) {
      detailItems.push({ label: "worktree", value: payload.run.worktree });
    }
    if (payload.run.head_sha) {
      detailItems.push({ label: "head", value: payload.run.head_sha.slice(0, 8) });
    }
    if (payload.run.last_event) {
      detailItems.push({ label: "event", value: payload.run.last_event });
    }
    if (
      payload.explanation.current_state.state ||
      payload.explanation.current_state.task_state ||
      payload.explanation.current_state.review_state ||
      payload.explanation.current_state.phase ||
      payload.explanation.current_state.activity ||
      payload.explanation.current_state.detail
    ) {
      const currentStateParts = [
        payload.explanation.current_state.phase,
        payload.explanation.current_state.activity,
        payload.explanation.current_state.detail,
        payload.explanation.current_state.state,
        payload.explanation.current_state.task_state,
        payload.explanation.current_state.review_state,
      ].filter((value) => Boolean(value));
      detailItems.push({ label: "state", value: currentStateParts.join(" / ") });
    }
    if (payload.run.review_state) {
      detailItems.push({ label: "review", value: payload.run.review_state });
    }
    if (payload.review_state?.reviewer?.label) {
      detailItems.push({ label: "reviewer", value: payload.review_state.reviewer.label });
    }
    if (payload.evidence_digest.verification_outcome) {
      detailItems.push({ label: "verify", value: payload.evidence_digest.verification_outcome });
    }
    if (payload.evidence_digest.security_blocked) {
      detailItems.push({ label: "security", value: payload.evidence_digest.security_blocked });
    }
    const changedFiles = payload.run.changed_files.length > 0
      ? payload.run.changed_files
      : payload.evidence_digest.changed_files;
    if (changedFiles.length > 0) {
      detailItems.push({ label: "changed", value: `${changedFiles.length}` });
    }

    const bodyParts = [payload.explanation.summary];
    if (payload.run.goal) {
      bodyParts.push(`Goal: ${payload.run.goal}`);
    }
    const workspaceContext = summarizeWorkspaceContext(payload.run.branch, payload.run.worktree);
    if (workspaceContext) {
      bodyParts.push(`Workspace: ${workspaceContext}`);
    }
    const reviewVerdict = summarizeReviewVerdict(payload);
    if (reviewVerdict) {
      bodyParts.push(`Review: ${reviewVerdict}`);
    }
    if (payload.explanation.reasons.length > 0) {
      bodyParts.push(`Reasons: ${payload.explanation.reasons.join(" | ")}`);
    }
    if (payload.explanation.current_state.last_event) {
      bodyParts.push(`State: ${payload.explanation.current_state.last_event}`);
    }
    if (payload.run.action_items.length > 0) {
      const actions = payload.run.action_items
        .slice(0, 2)
        .map((item) => `${item.kind}: ${item.message}`)
        .join(" | ");
      bodyParts.push(`Actions: ${actions}`);
    }
    if (observationPack.working_tree_summary || observationPack.failing_command) {
      const observationParts = [
        observationPack.working_tree_summary,
        observationPack.failing_command,
      ].filter((value) => Boolean(value));
      bodyParts.push(`Observe: ${observationParts.join(" | ")}`);
    }
    if (changedFiles.length > 0) {
      bodyParts.push(`Files: ${summarizeChangedFiles(changedFiles)}`);
    }
    if (payload.recent_events.length > 0) {
      const recent = payload.recent_events
        .slice(0, 2)
        .map((item) => `${item.event}: ${item.message}`)
        .join(" | ");
      bodyParts.push(`Recent: ${recent}`);
    }

    const previousFingerprint = getExplainPayloadFingerprint(previousPayload);
    const nextFingerprint = getExplainPayloadFingerprint(payload);
    if (previousFingerprint !== nextFingerprint) {
      appendRuntimeConversation({
        type: "operator",
        category: "activity",
        timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
        actor: "Operator",
        title: "Explain opened",
        body: bodyParts.join(" "),
        details: detailItems,
        tone: "info",
        runId: payload.run.run_id,
      });
    }
    renderRunSummary();
    renderContextPanel();
    renderConversation(getConversationItems());
  } catch (error) {
    console.warn("Failed to load desktop explain payload", error);
    appendFallbackExplain();
    return;
  }
}

async function promoteSelectedRunTactic(runId: string) {
  if (promotingRunIds.has(runId) || pendingPromotedRunRefreshIds.has(runId)) {
    return;
  }

  promotingRunIds.add(runId);
  renderContextPanel();

  try {
    const projectDir = getActiveProjectDirPayload();
    const projectKey = captureProjectRequestKey();
    const result = await promoteDesktopRunTactic(runId, projectDir);
    if (!isProjectRequestCurrent(projectKey)) {
      return;
    }
    pendingPromotedRunRefreshIds.add(runId);
    renderContextPanel();
    appendRuntimeConversation({
      type: "operator",
      category: "activity",
      timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: "Operator",
      title: "Playbook candidate exported",
      body: result.candidate.summary || result.candidate.title,
      details: [
        { label: "run", value: result.run_id },
        { label: "kind", value: result.candidate.kind },
        { label: "candidate", value: result.candidate_ref },
      ],
      tone: "success",
      runId,
    });
    renderConversation(getConversationItems());
    requestDesktopSummaryRefresh(undefined, 0);
    try {
      const explainPayload = await getDesktopRunExplain(runId, projectDir);
      if (!isProjectRequestCurrent(projectKey)) {
        return;
      }
      desktopExplainCache.set(runId, explainPayload);
      promotedRunCandidates.set(runId, {
        fingerprint: getExplainPayloadFingerprint(explainPayload),
        candidateRef: result.candidate_ref,
        collapseAfterRefreshSerial: desktopSummaryRefreshSerial + 1,
      });
    } catch (refreshError) {
      console.warn("Failed to refresh promoted run explain payload", refreshError);
      promotedRunCandidates.delete(runId);
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    appendRuntimeConversation({
      type: "operator",
      category: "attention",
      timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: "Operator",
      title: "Promote failed",
      body: message,
      details: [{ label: "run", value: runId }],
      tone: "warning",
      runId,
    });
    renderConversation(getConversationItems());
  } finally {
    promotingRunIds.delete(runId);
    pendingPromotedRunRefreshIds.delete(runId);
    renderContextPanel();
    renderRunSummary();
  }
}

async function focusRunInContext(runId: string) {
  setSelectedRun(runId);
  const focusedSourceChange = getProjectionSourceEntries().find((change) => change.run === runId);
  if (focusedSourceChange) {
    selectedEditorKey = getSourceChangeKey(focusedSourceChange);
  }
  renderDesktopSurfaces();

  try {
    const projectDir = getActiveProjectDirPayload();
    const projectKey = captureProjectRequestKey();
    const explainPayload = await getDesktopRunExplain(runId, projectDir);
    if (!isProjectRequestCurrent(projectKey)) {
      return;
    }
    desktopExplainCache.set(runId, explainPayload);
  } catch (error) {
    console.warn("Failed to preload explain payload for focused run", error);
  } finally {
    renderDesktopSurfaces();
  }
}

async function pickCompareWinner(
  runId: string,
  peerRunId: string,
  peerSlot: string,
  recommendation: string,
  confidence: number | null,
  nextTest: string,
) {
  if (pickingWinnerRunIds.has(runId)) {
    return;
  }

  pickingWinnerRunIds.add(runId);
  renderContextPanel();

  try {
    const projectDir = getActiveProjectDirPayload();
    const projectKey = captureProjectRequestKey();
    const result = await pickDesktopRunWinner(
      runId,
      peerSlot,
      recommendation,
      confidence,
      nextTest,
      projectDir,
    );
    if (!isProjectRequestCurrent(projectKey)) {
      return;
    }
    appendRuntimeConversation({
      type: "operator",
      category: "activity",
      timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: "Operator",
      title: "Winner picked",
      body: result.recommendation || runId,
      details: [
        { label: "run", value: result.run_id },
        { label: "target", value: result.target_slot || "n/a" },
        { label: "next", value: result.next_test || "n/a" },
      ],
      tone: "success",
      runId,
    });
    renderConversation(getConversationItems());
    if (peerRunId) {
      desktopRunCompareCache.delete(getComparePairKey(runId, peerRunId));
      desktopRunCompareCache.delete(getComparePairKey(peerRunId, runId));
    }
    requestDesktopSummaryRefresh(runId, 0);
    await focusRunInContext(runId);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    appendRuntimeConversation({
      type: "operator",
      category: "attention",
      timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: "Operator",
      title: "Pick winner failed",
      body: message,
      details: [{ label: "run", value: runId }],
      tone: "warning",
      runId,
    });
    renderConversation(getConversationItems());
  } finally {
    pickingWinnerRunIds.delete(runId);
    renderContextPanel();
  }
}

async function compareSelectedRunWithPeer(leftRunId: string, rightRunId: string) {
  const pairKey = getComparePairKey(leftRunId, rightRunId);
  if (comparingRunPairKeys.has(pairKey)) {
    return;
  }

  const leftFingerprint = getRunProjectionFingerprint(getRunProjectionByRunId(leftRunId));
  const rightFingerprint = getRunProjectionFingerprint(getRunProjectionByRunId(rightRunId));
  comparingRunPairKeys.add(pairKey);
  renderContextPanel();

  try {
    const projectDir = getActiveProjectDirPayload();
    const projectKey = captureProjectRequestKey();
    const result = await compareDesktopRuns(leftRunId, rightRunId, projectDir);
    if (!isProjectRequestCurrent(projectKey)) {
      return;
    }
    const latestLeftFingerprint = getRunProjectionFingerprint(getRunProjectionByRunId(leftRunId));
    const latestRightFingerprint = getRunProjectionFingerprint(getRunProjectionByRunId(rightRunId));
    if (
      leftFingerprint !== latestLeftFingerprint ||
      rightFingerprint !== latestRightFingerprint
    ) {
      appendRuntimeConversation({
        type: "operator",
        category: "activity",
        timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
        actor: "Operator",
        title: "Compare needs rerun",
        body: "The selected runs changed while compare was running.",
        details: [
          { label: "left", value: leftRunId },
          { label: "right", value: rightRunId },
        ],
        tone: "warning",
        runId: leftRunId,
      });
      renderConversation(getConversationItems());
      return;
    }

    desktopRunCompareCache.set(pairKey, result);
    desktopRunCompareCache.set(
      getComparePairKey(rightRunId, leftRunId),
      mirrorCompareRunsResult(result),
    );
    appendRuntimeConversation({
      type: "operator",
      category: "activity",
      timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: "Operator",
      title: "Compare completed",
      body: [
        `${result.left.label || result.left.run_id} vs ${result.right.label || result.right.run_id}`,
        result.recommend.next_action || "reconcile_consult",
      ].join(" · "),
      details: [
        { label: "winner", value: result.recommend.winning_run_id || "none" },
        { label: "diffs", value: `${result.differences.length}` },
        {
          label: "delta",
          value: result.confidence_delta !== null
            ? formatConfidencePercent(Math.abs(result.confidence_delta))
            : "n/a",
        },
      ],
      tone: result.recommend.reconcile_consult ? "warning" : "info",
      runId: leftRunId,
    });
    renderConversation(getConversationItems());
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    appendRuntimeConversation({
      type: "operator",
      category: "attention",
      timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: "Operator",
      title: "Compare failed",
      body: message,
      details: [
        { label: "left", value: leftRunId },
        { label: "right", value: rightRunId },
      ],
      tone: "warning",
      runId: leftRunId,
    });
    renderConversation(getConversationItems());
  } finally {
    comparingRunPairKeys.delete(pairKey);
    renderContextPanel();
  }
}

function appendFallbackExplain() {
  const timestamp = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false });
  const selectedRunId = getSelectedRunId();
  const projection = getPrimaryRunProjection();
  if (!selectedRunId || projection?.run_id !== selectedRunId) {
    return;
  }
  const workspaceContext = summarizeWorkspaceContext(projection.branch, projection.worktree);

  appendRuntimeConversation({
    type: "operator",
    category: "activity",
    timestamp,
    actor: "Operator",
    title: "Explain unavailable",
    body: workspaceContext
      ? `Explain unavailable for ${selectedRunId}. Workspace: ${workspaceContext}.`
      : `Explain unavailable for ${selectedRunId}.`,
    details: [
      { label: "run", value: selectedRunId },
      { label: "next", value: projection.next_action || "idle" },
      { label: "branch", value: projection.branch || "no branch" },
      { label: "worktree", value: projection.worktree || "project root" },
      { label: "changed", value: `${projection.changed_files.length}` },
    ],
    tone: "info",
    runId: selectedRunId,
  });
  renderRunSummary();
  renderContextPanel();
  renderConversation(getConversationItems());
}

function handleChipAction(action: ChipAction) {
  switch (action) {
    case "open-editor":
      void openEditorTarget(
        getPreferredEditorTargetForSelectedRun() ??
          getEditorTargetForSourceChange(getPrimarySourceChange(getVisibleSourceChanges())) ??
          getEditorTargetByKey(selectedEditorKey),
      );
      break;
    case "open-source-context":
    case "toggle-context":
      setContextPanel(true);
      break;
    case "open-terminal":
      setTerminalDrawer(true);
      break;
    case "open-explain":
      void openExplainForSelectedRun();
      break;
  }
}

function getCommandActions(): CommandAction[] {
  return [
    {
      id: "dispatch",
      label: getLanguageText("Dispatch next task", "次のタスクを依頼"),
      description: getLanguageText(
        "Switch the composer to dispatch mode and focus the operator input.",
        "入力欄を依頼モードに切り替え、オペレーター入力へ移動します。",
      ),
      keywords: getLanguageText("dispatch task composer", "依頼 タスク 入力").split(" "),
      shortcut: "Ctrl+K",
      tone: "focus",
      run: () => {
        setComposerMode("dispatch");
        focusComposer();
      },
    },
    {
      id: "ask",
      label: getLanguageText("Ask the operator", "オペレーターに質問"),
      description: getLanguageText(
        "Switch to ask mode for status questions, clarifications, and routing checks.",
        "状況確認、追加質問、振り分け確認のために質問モードへ切り替えます。",
      ),
      keywords: getLanguageText("ask status clarify", "質問 状況確認 確認").split(" "),
      tone: "info",
      run: () => {
        setComposerMode("ask");
        focusComposer();
      },
    },
    {
      id: "review",
      label: getLanguageText("Request review", "レビューを依頼"),
      description: getLanguageText(
        "Switch to review mode to request approval, audit, or verification.",
        "承認、監査、検証を依頼するためにレビューモードへ切り替えます。",
      ),
      keywords: getLanguageText("review approve audit verify", "レビュー 承認 監査 検証").split(" "),
      tone: "warning",
      run: () => {
        setComposerMode("review");
        focusComposer();
      },
    },
    {
      id: "explain",
      label: getLanguageText("Explain selected run", "選択中の実行を説明"),
      description: getLanguageText(
        "Open the explain flow for the currently selected run and add operator context to the timeline.",
        "選択中の実行について、説明用の流れを開いて会話に詳細を追加します。",
      ),
      keywords: getLanguageText("explain run blocked why", "説明 実行 停止 理由").split(" "),
      tone: "info",
      run: () => handleChipAction("open-explain"),
    },
    {
      id: "editor",
      label: getLanguageText("Open secondary editor", "補助エディターを開く"),
      description: getLanguageText(
        "Open the secondary work surface for the currently selected file or run context.",
        "選択中のファイルや実行の詳細を扱う補助作業面を開きます。",
      ),
      keywords: getLanguageText("editor file changed secondary", "エディター ファイル 変更 補助").split(" "),
      tone: "default",
      run: () => handleChipAction("open-editor"),
    },
    {
      id: "source-context",
      label: getLanguageText("Open source control", "ソース管理を開く"),
      description: getLanguageText(
        "Reveal the source-control context sheet and changed-file drill-down.",
        "ソース管理と変更ファイルの詳細を表示します。",
      ),
      keywords: getLanguageText("source control changed worktree branch", "ソース 管理 変更 ブランチ").split(" "),
      tone: "default",
      run: () => handleChipAction("open-source-context"),
    },
    {
      id: "evidence",
      label: getLanguageText("Open evidence", "証跡を開く"),
      description: getLanguageText(
        "Show verification, review, security, and recent event evidence.",
        "検証、レビュー、セキュリティ、最近のイベントの証跡を表示します。",
      ),
      keywords: getLanguageText("evidence audit trace review verification security", "証跡 監査 記録 レビュー 検証 セキュリティ").split(" "),
      tone: "info",
      run: () => showSidebarMode("evidence"),
    },
    {
      id: "terminal",
      label: getLanguageText("Open workbench panes", "ワークベンチペインを開く"),
      description: getLanguageText(
        "Show workbench panes for raw PTY output, diagnostics, and pane control.",
        "端末出力、診断、ペイン操作のためにワークベンチペインを表示します。",
      ),
      keywords: getLanguageText("terminal pane diagnostics pty", "端末 ペイン 診断").split(" "),
      tone: "default",
      run: () => handleChipAction("open-terminal"),
    },
    {
      id: "settings",
      label: getLanguageText("Open settings", "設定を開く"),
      description: getLanguageText(
        "Open theme, density, wrap, font, and display preferences.",
        "テーマ、密度、折り返し、フォント、表示設定を開きます。",
      ),
      keywords: getLanguageText("settings theme density wrap font display", "設定 テーマ 密度 折り返し フォント 表示").split(" "),
      tone: "accent",
      run: () => setSettingsSheet(true),
    },
    {
      id: "attention-filter",
      label: getLanguageText("Filter timeline: attention", "タイムラインを要確認で絞る"),
      description: getLanguageText(
        "Show only blocked and urgent attention events in the conversation feed.",
        "会話フィードで停止中または緊急の要確認イベントだけを表示します。",
      ),
      keywords: getLanguageText("filter attention blocked timeline", "絞り込み 要確認 停止 タイムライン").split(" "),
      tone: "danger",
      run: () => {
        activeTimelineFilter = "attention";
        renderTimelineFilters();
        renderRunSummary();
        renderConversation(getConversationItems());
      },
    },
    {
      id: "review-filter",
      label: getLanguageText("Filter timeline: review", "タイムラインをレビューで絞る"),
      description: getLanguageText(
        "Show review requests, approvals, and review-capable slot activity.",
        "レビュー依頼、承認、レビュー担当の動きだけを表示します。",
      ),
      keywords: getLanguageText("filter review timeline approve", "絞り込み レビュー タイムライン 承認").split(" "),
      tone: "warning",
      run: () => {
        activeTimelineFilter = "review";
        renderTimelineFilters();
        renderRunSummary();
        renderConversation(getConversationItems());
      },
    },
  ];
}

function getFilteredCommandActions() {
  const query = commandBarQuery.trim().toLowerCase();
  const actions = getCommandActions();
  if (!query) {
    return actions;
  }

  return actions.filter((action) => {
    const haystack = [action.label, action.description, action.shortcut ?? "", ...action.keywords]
      .join(" ")
      .toLowerCase();
    return haystack.includes(query);
  });
}

function openCommandBar() {
  if (settingsSheetOpen) {
    (document.getElementById("settings-search-input") as HTMLInputElement | null)?.focus();
    return;
  }
  commandBarOpen = true;
  commandBarQuery = "";
  selectedCommandIndex = 0;
  lastCommandBarFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  renderCommandBar();

  const shell = document.getElementById("command-bar-shell");
  const button = document.getElementById("open-command-bar-btn");
  const input = document.getElementById("command-bar-input") as HTMLInputElement | null;
  if (shell) {
    shell.hidden = false;
  }
  if (button) {
    button.setAttribute("aria-expanded", "true");
  }

  requestAnimationFrame(() => input?.focus());
}

function closeCommandBar(restoreFocus = true) {
  commandBarOpen = false;
  commandBarQuery = "";
  selectedCommandIndex = 0;
  commandBarImeActive = false;

  const shell = document.getElementById("command-bar-shell");
  const button = document.getElementById("open-command-bar-btn");
  const input = document.getElementById("command-bar-input") as HTMLInputElement | null;
  if (shell) {
    shell.hidden = true;
  }
  if (button) {
    button.setAttribute("aria-expanded", "false");
  }
  if (input) {
    input.value = "";
  }

  if (restoreFocus) {
    requestAnimationFrame(() => lastCommandBarFocus?.focus());
  }
}

interface TopMenuItem {
  label: string;
  shortcut?: string;
  action?: () => void;
  separator?: boolean;
}

function closeTopMenu() {
  const popover = document.getElementById("top-menu-popover");
  if (popover) {
    popover.hidden = true;
    popover.innerHTML = "";
  }
  if (openTopMenuId) {
    document.getElementById(openTopMenuId)?.classList.remove("is-open");
    document.getElementById(openTopMenuId)?.setAttribute("aria-expanded", "false");
  }
  openTopMenuId = null;
}

function getTopMenuItems(menuId: string): TopMenuItem[] {
  switch (menuId) {
    case "menu-file-btn":
      return [
        { label: getLanguageText("Add project", "プロジェクトを追加"), action: promptAndAddProjectSession },
        { label: getLanguageText("Settings", "設定"), action: () => setSettingsSheet(true) },
      ];
    case "menu-edit-btn":
      return [
        { label: getLanguageText("Focus input", "入力欄へ移動"), shortcut: "Esc", action: focusComposer },
        { label: getLanguageText("Attach file", "ファイルを添付"), action: () => document.getElementById("composer-file-input")?.click() },
      ];
    case "menu-selection-btn":
      return [
        { label: getLanguageText("All events", "すべてのイベント"), action: () => setTimelineFilter("all") },
        { label: getLanguageText("Needs attention", "要確認"), action: () => setTimelineFilter("attention") },
        { label: getLanguageText("Reviews", "レビュー"), action: () => setTimelineFilter("review") },
      ];
    case "menu-view-btn":
      return [
        { label: getLanguageText("Toggle explorer", "エクスプローラーを切り替え"), action: () => toggleSidebarMode("explorer") },
        { label: getLanguageText("Toggle workspace overview", "作業領域の概要を切り替え"), action: () => toggleSidebarMode("workspace") },
        { label: getLanguageText("Toggle source control", "ソース管理を切り替え"), action: () => toggleSidebarMode("source") },
        { label: getLanguageText("Toggle evidence", "証跡を切り替え"), action: () => toggleSidebarMode("evidence") },
        { label: getLanguageText("Toggle details", "詳細を切り替え"), action: () => setContextPanel(!contextPanelOpen) },
        { label: getLanguageText("Toggle panes", "ペインを切り替え"), action: () => setTerminalDrawer(!terminalDrawerOpen) },
      ];
    case "menu-go-btn":
      return [
        { label: getLanguageText("Explorer", "エクスプローラー"), action: () => showSidebarMode("explorer") },
        { label: getLanguageText("Workspace overview", "作業領域の概要"), action: () => showSidebarMode("workspace") },
        { label: getLanguageText("Source control", "ソース管理"), action: () => showSidebarMode("source") },
        { label: getLanguageText("Evidence", "証跡"), action: () => showSidebarMode("evidence") },
        { label: getLanguageText("Command palette", "操作パレット"), shortcut: "Ctrl+K", action: openCommandBar },
      ];
    case "menu-run-btn":
      return [
        { label: getLanguageText("Ask", "質問"), action: () => setComposerModeAndFocus("ask") },
        { label: getLanguageText("Dispatch", "依頼"), action: () => setComposerModeAndFocus("dispatch") },
        { label: getLanguageText("Review", "レビュー"), action: () => setComposerModeAndFocus("review") },
      ];
    case "menu-terminal-btn":
      return [
        { label: terminalDrawerOpen ? getLanguageText("Hide panes", "ペインを隠す") : getLanguageText("Show panes", "ペインを表示"), action: () => setTerminalDrawer(!terminalDrawerOpen) },
        { label: getLanguageText("Add pane", "ペインを追加"), action: () => createPane() },
        { label: getLanguageText("Switch layout", "配置を切り替え"), action: cycleWorkbenchLayout },
      ];
    case "menu-help-btn":
      return [
        { label: getLanguageText("Open command palette", "操作パレットを開く"), shortcut: "Ctrl+K", action: openCommandBar },
      ];
    default:
      return [];
  }
}

function setTimelineFilter(filter: TimelineFilter) {
  activeTimelineFilter = filter;
  renderTimelineFilters();
  renderRunSummary();
  renderConversation(getConversationItems());
}

function setComposerModeAndFocus(mode: ComposerMode) {
  setComposerMode(mode);
  focusComposer();
}

function showSidebarMode(mode: SidebarMode) {
  setSidebarMode(mode);
  setSidebarOpen(true);
}

function toggleSidebarMode(mode: SidebarMode) {
  if (sidebarOpen && sidebarMode === mode) {
    setSidebarOpen(false);
    return;
  }
  showSidebarMode(mode);
}

function openTopMenu(menuId: string) {
  const button = document.getElementById(menuId);
  const popover = document.getElementById("top-menu-popover");
  if (!button || !popover) {
    return;
  }

  if (openTopMenuId === menuId && !popover.hidden) {
    closeTopMenu();
    return;
  }

  closeTopMenu();
  openTopMenuId = menuId;
  button.classList.add("is-open");
  button.setAttribute("aria-expanded", "true");

  const rect = button.getBoundingClientRect();
  popover.style.left = `${Math.max(4, Math.min(rect.left, window.innerWidth - 332))}px`;
  popover.innerHTML = "";
  for (const item of getTopMenuItems(menuId)) {
    if (item.separator) {
      const separator = document.createElement("div");
      separator.className = "top-menu-popover-separator";
      popover.appendChild(separator);
      continue;
    }
    const itemButton = document.createElement("button");
    itemButton.type = "button";
    itemButton.className = "top-menu-popover-item";
    itemButton.setAttribute("role", "menuitem");
    itemButton.innerHTML =
      `<span>${item.label}</span>` +
      (item.shortcut ? `<span class="top-menu-popover-shortcut">${item.shortcut}</span>` : "");
    itemButton.addEventListener("click", () => {
      closeTopMenu();
      item.action?.();
    });
    popover.appendChild(itemButton);
  }
  popover.hidden = false;
}

function executeSelectedCommand() {
  const actions = getFilteredCommandActions();
  if (actions.length === 0) {
    return;
  }

  const action = actions[Math.min(selectedCommandIndex, actions.length - 1)];
  closeCommandBar(false);
  action.run();
}

function setCommandBarActiveIndex(index: number) {
  selectedCommandIndex = index;
  const results = document.getElementById("command-bar-results");
  if (!results) {
    return;
  }
  for (const item of results.querySelectorAll<HTMLButtonElement>(".command-bar-item")) {
    const active = item.id === `command-option-${getFilteredCommandActions()[index]?.id ?? ""}`;
    item.classList.toggle("is-active", active);
    item.setAttribute("aria-selected", active ? "true" : "false");
  }
  const activeAction = getFilteredCommandActions()[index];
  const input = document.getElementById("command-bar-input");
  if (activeAction) {
    input?.setAttribute("aria-activedescendant", `command-option-${activeAction.id}`);
  }
}

function renderCommandBar() {
  const input = document.getElementById("command-bar-input") as HTMLInputElement | null;
  const results = document.getElementById("command-bar-results");
  if (!input || !results) {
    return;
  }

  input.value = commandBarQuery;
  const actions = getFilteredCommandActions();
  if (selectedCommandIndex >= actions.length) {
    selectedCommandIndex = Math.max(0, actions.length - 1);
  }

  results.innerHTML = "";
  if (actions.length === 0) {
    input.removeAttribute("aria-activedescendant");
    const empty = document.createElement("div");
    empty.className = "command-bar-empty";
    empty.textContent = getLanguageText(
      "No matching command. Try run, review, terminal, source, or settings.",
      "一致する操作はありません。実行、レビュー、端末、ソース、設定で探してください。",
    );
    results.appendChild(empty);
    return;
  }

  actions.forEach((action, index) => {
    const optionId = `command-option-${action.id}`;
    const button = document.createElement("button");
    button.type = "button";
    button.id = optionId;
    button.className = `command-bar-item ${index === selectedCommandIndex ? "is-active" : ""}`;
    button.dataset.tone = action.tone ?? "default";
    button.setAttribute("role", "option");
    button.setAttribute("aria-selected", index === selectedCommandIndex ? "true" : "false");
    button.innerHTML =
      `<div class="command-bar-item-main">` +
      `<span class="command-bar-item-label">${action.label}</span>` +
      `<span class="command-bar-item-description">${action.description}</span>` +
      `</div>` +
      `<div class="command-bar-item-meta">` +
      (action.shortcut ? `<span class="command-bar-item-shortcut">${action.shortcut}</span>` : "") +
      `<span class="command-bar-item-keywords">${action.keywords.slice(0, 3).join(" · ")}</span>` +
      `</div>`;
    button.addEventListener("pointerenter", () => {
      setCommandBarActiveIndex(index);
    });
    button.addEventListener("pointerdown", (event) => {
      event.preventDefault();
      setCommandBarActiveIndex(index);
      executeSelectedCommand();
    });
    button.addEventListener("click", () => {
      selectedCommandIndex = index;
      executeSelectedCommand();
    });
    results.appendChild(button);
  });

  const activeAction = actions[Math.min(selectedCommandIndex, actions.length - 1)];
  if (activeAction) {
    input.setAttribute("aria-activedescendant", `command-option-${activeAction.id}`);
  } else {
    input.removeAttribute("aria-activedescendant");
  }
}

function trapCommandBarTab(event: KeyboardEvent) {
  const root = document.getElementById("command-bar");
  if (!root || event.key !== "Tab") {
    return;
  }

  const focusables = Array.from(
    root.querySelectorAll<HTMLElement>('input, button, [href], [tabindex]:not([tabindex="-1"])'),
  ).filter((element) => !element.hasAttribute("disabled") && !element.getAttribute("aria-hidden"));

  if (focusables.length === 0) {
    return;
  }

  const first = focusables[0];
  const last = focusables[focusables.length - 1];
  const active = document.activeElement;

  if (!event.shiftKey && active === last) {
    event.preventDefault();
    first.focus();
    return;
  }

  if (event.shiftKey && active === first) {
    event.preventDefault();
    last.focus();
  }
}

function renderEditorSurface() {
  const title = document.getElementById("editor-surface-title");
  const summary = document.getElementById("editor-surface-summary");
  const path = document.getElementById("editor-file-path");
  const meta = document.getElementById("editor-meta-row");
  const diffPreview = document.getElementById("editor-diff-preview");
  const browserSurface = document.getElementById("browser-surface");
  const browserFrame = document.getElementById("browser-frame") as HTMLIFrameElement | null;
  const browserMeta = document.getElementById("browser-meta-row");
  const browserTargetList = document.getElementById("browser-target-list");
  const browserToolbarSummary = document.getElementById("browser-toolbar-summary");
  const browserBackButton = document.getElementById("browser-back-btn") as HTMLButtonElement | null;
  const browserCopyButton = document.getElementById("browser-copy-btn") as HTMLButtonElement | null;
  const browserReloadButton = document.getElementById("browser-reload-btn") as HTMLButtonElement | null;
  const browserOpenButton = document.getElementById("browser-open-btn") as HTMLButtonElement | null;
  const popoutButton = document.getElementById("popout-editor-btn") as HTMLButtonElement | null;
  const tabs = document.getElementById("editor-tabs");
  const code = document.getElementById("editor-code");
  const statusbar = document.getElementById("editor-statusbar");
  if (!title || !summary || !path || !meta || !diffPreview || !browserSurface || !browserFrame || !browserMeta || !browserTargetList || !browserToolbarSummary || !browserBackButton || !browserCopyButton || !browserReloadButton || !browserOpenButton || !popoutButton || !tabs || !code || !statusbar) {
    return;
  }

  const editors = getEditorFiles();
  const selected = editors.find((editor) => editor.key === selectedEditorKey) || editors[0];
  const previewTarget = selectedPreviewUrl ? detectedPreviewTargets.get(selectedPreviewUrl) ?? null : null;
  const previewTargets = getPreviewTargets();
  const previewModeActive = editorSurfaceMode === "preview" && Boolean(previewTarget);
  const detachedSurface = document.body.dataset.popoutSurface === "1";
  if (!selected && !previewModeActive) {
    title.textContent = "Editor";
    path.textContent = "Editor idle";
    summary.innerHTML = "";
    summary.hidden = true;
    meta.innerHTML = "";
    meta.hidden = true;
    diffPreview.innerHTML = "";
    diffPreview.hidden = true;
    browserMeta.innerHTML = "";
    browserMeta.hidden = true;
    browserTargetList.innerHTML = "";
    browserTargetList.hidden = true;
    browserFrame.src = "about:blank";
    browserSurface.hidden = true;
    tabs.innerHTML = "";
    renderEditorCode(code, "No backend preview cached.", "Text");
    code.hidden = false;
    renderEditorStatusbar(statusbar, [
      { label: "", value: "Idle" },
      { label: "", value: "0 projected" },
    ]);
    popoutButton.disabled = true;
    return;
  }
  if (selected && !previewModeActive) {
    selectedEditorKey = selected.key;
  }
  const selectedTarget = selected ? getEditorTargetByKey(selected.key) : null;
  if (selected && selectedTarget && !desktopEditorFileCache.has(selected.key) && !desktopEditorLoadingPaths.has(selected.key)) {
    void ensureEditorFileLoaded(selectedTarget);
  }
  const selectedWorktreeLabel = selectedTarget?.worktree
    ? getWorktreeLabel(selectedTarget.worktree)
    : "";

  meta.innerHTML = "";
  meta.hidden = true;
  summary.innerHTML = "";
  summary.hidden = true;
  diffPreview.innerHTML = "";
  diffPreview.hidden = true;
  browserMeta.innerHTML = "";
  browserMeta.hidden = true;
  browserTargetList.innerHTML = "";
  browserToolbarSummary.textContent = "";
  browserTargetList.hidden = true;
  browserSurface.hidden = true;
  browserBackButton.disabled = true;
  browserCopyButton.disabled = true;
  browserReloadButton.disabled = true;
  browserOpenButton.disabled = true;
  code.hidden = false;

  if (previewModeActive && previewTarget) {
    title.textContent = "Preview";
    path.textContent = previewTarget.url;
    for (const item of [
      "Preview",
      detachedSurface ? "Detached" : "",
      detachedSurfaceRunLabel,
      previewTarget.portLabel,
      previewTarget.sourceLabel,
    ]) {
      if (!item) {
        continue;
      }
      const chip = document.createElement("span");
      chip.className = "editor-meta-chip";
      chip.dataset.tone = item === "Preview" ? "focus" : "default";
      chip.textContent = item;
      summary.appendChild(chip);
    }
    summary.hidden = summary.childElementCount === 0;
    if (lastPreviewExternalState?.url === previewTarget.url) {
      const openedAt = new Date(lastPreviewExternalState.at).toLocaleTimeString([], {
        hour: "2-digit",
        minute: "2-digit",
      });
      const handoffTitle = document.createElement("div");
      handoffTitle.className = "editor-diff-preview-title";
      handoffTitle.textContent = "External browser";
      const handoffBody = document.createElement("div");
      handoffBody.className = "editor-diff-preview-body";
      handoffBody.textContent = lastPreviewExternalState.ok ? `Opened at ${openedAt}` : `Blocked at ${openedAt}`;
      browserMeta.appendChild(handoffTitle);
      browserMeta.appendChild(handoffBody);
      browserMeta.hidden = false;
    }
    if (previewTargets.length > 0) {
      for (const target of previewTargets) {
        const targetButton = document.createElement("button");
        targetButton.type = "button";
        targetButton.className = `editor-tab ${target.url === previewTarget.url ? "is-active" : ""}`;
        targetButton.textContent = target.portLabel;
        targetButton.title = `${target.url} (${target.sourceLabel}, ${formatPreviewSeenAt(target.lastSeenAt)})`;
        targetButton.addEventListener("click", () => {
          openPreviewTarget(target.url);
        });
        browserTargetList.appendChild(targetButton);
      }
      browserTargetList.hidden = false;
    }
    browserToolbarSummary.textContent =
      `${previewTargets.length} targets · active ${previewTarget.portLabel}` +
      ` · from ${previewTarget.sourceLabel}` +
      ` · seen ${formatPreviewSeenAt(previewTarget.lastSeenAt)}` +
      `${lastPreviewExternalState?.url === previewTarget.url ? (lastPreviewExternalState.ok ? " · external open" : " · external blocked") : ""}`;
    if (lastPreviewClipboardState?.url === previewTarget.url) {
      browserToolbarSummary.textContent += lastPreviewClipboardState.ok ? " · copied" : " · copy failed";
    }
    if (browserFrame.dataset.previewUrl !== previewTarget.url) {
      browserFrame.src = previewTarget.url;
      browserFrame.dataset.previewUrl = previewTarget.url;
    }
    browserSurface.hidden = false;
    browserBackButton.disabled = false;
    browserCopyButton.disabled = false;
    browserReloadButton.disabled = false;
    browserOpenButton.disabled = false;
    code.replaceChildren();
    code.hidden = true;
    renderEditorStatusbar(statusbar, [
      { label: "", value: "Preview" },
      ...(detachedSurface ? [{ label: "", value: "Detached" }] : []),
      ...(detachedSurface && detachedSurfaceRunLabel ? [{ label: "", value: detachedSurfaceRunLabel }] : []),
      { label: "", value: previewTarget.portLabel },
      { label: "", value: previewTarget.sourceLabel },
      { label: "", value: formatPreviewSeenAt(previewTarget.lastSeenAt) },
      ...(lastPreviewExternalState?.url === previewTarget.url
        ? [{ label: "", value: lastPreviewExternalState.ok ? "Opened" : "Blocked" }]
        : []),
    ]);
    popoutButton.disabled = false;
  } else if (selected) {
    title.textContent = selectedTarget?.sourceChange ? "Diff review" : "Editor";
    path.textContent = selected.path;
    for (const item of [
      "Code",
      detachedSurface ? "Detached" : "",
      detachedSurfaceRunLabel,
      selected.origin === "context" ? "Run context" : "Explorer",
      selectedWorktreeLabel,
    ]) {
      if (!item) {
        continue;
      }
      const chip = document.createElement("span");
      chip.className = "editor-meta-chip";
      chip.dataset.tone = item === "Code" ? "focus" : "default";
      chip.textContent = item;
      summary.appendChild(chip);
    }
    if (selectedTarget?.sourceChange) {
      const diffChip = document.createElement("span");
      diffChip.className = "editor-meta-chip";
      diffChip.dataset.tone = "focus";
      diffChip.textContent = "Diff review";
      summary.appendChild(diffChip);
    }
    summary.hidden = summary.childElementCount === 0;
    for (const item of [
      selected.language,
      `${selected.lineCount} lines`,
      selected.modified ? "Modified" : "Saved",
    ]) {
      if (!item) {
        continue;
      }
      const chip = document.createElement("span");
      chip.className = `editor-meta-chip ${item === "Modified" ? "is-modified" : ""}`;
      chip.dataset.tone = item === "Modified" ? "focus" : "default";
      chip.textContent = item;
      meta.appendChild(chip);
    }
    meta.hidden = meta.childElementCount === 0;
    if (selectedTarget?.sourceChange) {
      const previewTitle = document.createElement("div");
      previewTitle.className = "editor-diff-preview-title";
      previewTitle.textContent = "Diff preview";
    const previewBody = document.createElement("div");
    previewBody.className = "editor-diff-preview-body";
    previewBody.textContent = selectedTarget.sourceChange.summary;
    const previewMeta = document.createElement("div");
    previewMeta.className = "editor-diff-preview-meta";
    for (const item of [
      selectedTarget.sourceChange.status,
      selectedTarget.sourceChange.lines,
      selectedTarget.sourceChange.branch,
      selectedTarget.sourceChange.review,
      selectedTarget.sourceChange.paneLabel,
    ]) {
      if (!item) {
        continue;
      }
      const chip = document.createElement("span");
      chip.className = "editor-meta-chip";
      chip.textContent = item;
      previewMeta.appendChild(chip);
    }
      diffPreview.appendChild(previewTitle);
      diffPreview.appendChild(previewBody);
      diffPreview.appendChild(previewMeta);
      diffPreview.hidden = false;
    }
    if (isEditorSvgPreview(selected)) {
      renderEditorSvgPreview(code, selected.content, selected.path);
    } else {
      renderEditorCode(code, selected.content, selected.language);
    }
    renderEditorStatusbar(statusbar, [
      ...(detachedSurface ? [{ label: "", value: "Detached" }] : []),
      ...(detachedSurface && detachedSurfaceRunLabel ? [{ label: "", value: detachedSurfaceRunLabel }] : []),
      { label: "", value: "Ln 1, Col 1" },
      { label: "", value: `Lines ${selected.lineCount}` },
      { label: "", value: getEditorIndentSizeLabel(selected.content) },
      { label: "", value: "UTF-8" },
      { label: "", value: getEditorLineEndingLabel(selected.content) },
      { label: "", value: selected.language },
    ]);
    popoutButton.disabled = false;
  }
  tabs.innerHTML = "";

  for (const editor of editors) {
    const tab = document.createElement("button");
    tab.type = "button";
    tab.className = `editor-tab ${selected && editor.key === selected.key ? "is-active" : ""}`;
    tab.title = editor.path;

    const tabLabel = document.createElement("span");
    tabLabel.className = "editor-tab-label";
    tabLabel.textContent = editor.path.split("/").pop() ?? editor.path;
    tab.appendChild(tabLabel);

    const closeButton = document.createElement("span");
    closeButton.className = "editor-tab-close";
    closeButton.setAttribute("role", "button");
    closeButton.setAttribute("aria-label", getLanguageText(`Close ${editor.path}`, `${editor.path} を閉じる`));
    closeButton.textContent = "×";
    tab.appendChild(closeButton);

    tab.addEventListener("click", (event) => {
      if ((event.target as HTMLElement | null)?.closest(".editor-tab-close")) {
        event.stopPropagation();
        closeEditorTab(editor.key);
        return;
      }
      void openEditorTarget(getEditorTargetByKey(editor.key));
    });
    tabs.appendChild(tab);
  }
}

function splitEditorCodeLines(content: string): EditorCodeLine[] {
  const lines = content.split(/\r\n|\r|\n/);
  return (lines.length > 0 ? lines : [""]).map((text, index) => ({
    number: index + 1,
    text,
  }));
}

type EditorSyntaxTokenKind =
  | "comment"
  | "function"
  | "heading"
  | "keyword"
  | "link"
  | "number"
  | "operator"
  | "property"
  | "punctuation"
  | "string"
  | "tag";

interface EditorSyntaxToken {
  start: number;
  end: number;
  kind: EditorSyntaxTokenKind;
}

function appendEditorSyntaxText(root: HTMLElement, text: string, kind?: EditorSyntaxTokenKind) {
  if (!text) {
    return;
  }
  const span = document.createElement("span");
  if (kind) {
    span.className = `editor-token editor-token-${kind}`;
  }
  span.textContent = text;
  root.appendChild(span);
}

function addEditorSyntaxMatches(tokens: EditorSyntaxToken[], text: string, pattern: RegExp, kind: EditorSyntaxTokenKind) {
  for (const match of text.matchAll(pattern)) {
    const start = match.index ?? -1;
    const value = match[0] ?? "";
    if (start < 0 || !value) {
      continue;
    }
    const end = start + value.length;
    if (tokens.some((token) => start < token.end && end > token.start)) {
      continue;
    }
    tokens.push({ start, end, kind });
  }
}

function appendTokenizedEditorLine(root: HTMLElement, text: string, tokens: EditorSyntaxToken[]) {
  let cursor = 0;
  const orderedTokens = [...tokens].sort((left, right) => left.start - right.start || right.end - left.end);
  for (const token of orderedTokens) {
    if (token.start < cursor || token.end <= token.start) {
      continue;
    }
    appendEditorSyntaxText(root, text.slice(cursor, token.start));
    appendEditorSyntaxText(root, text.slice(token.start, token.end), token.kind);
    cursor = token.end;
  }
  appendEditorSyntaxText(root, text.slice(cursor));
}

function appendMarkdownEditorLine(root: HTMLElement, text: string) {
  const heading = /^(#{1,6})(\s+)(.*)$/.exec(text);
  if (heading) {
    appendEditorSyntaxText(root, heading[1], "punctuation");
    appendEditorSyntaxText(root, heading[2]);
    appendEditorSyntaxText(root, heading[3], "heading");
    return;
  }

  const list = /^(\s*)([-*+]|\d+[.)])(\s+)(.*)$/.exec(text);
  if (list) {
    appendEditorSyntaxText(root, list[1]);
    appendEditorSyntaxText(root, list[2], "punctuation");
    appendEditorSyntaxText(root, list[3]);
    appendMarkdownInlineSyntax(root, list[4]);
    return;
  }

  const quote = /^(\s*>+\s?)(.*)$/.exec(text);
  if (quote) {
    appendEditorSyntaxText(root, quote[1], "punctuation");
    appendMarkdownInlineSyntax(root, quote[2]);
    return;
  }

  appendMarkdownInlineSyntax(root, text);
}

function appendMarkdownInlineSyntax(root: HTMLElement, text: string) {
  const tokens: EditorSyntaxToken[] = [];
  addEditorSyntaxMatches(tokens, text, /`[^`]*`/g, "string");
  addEditorSyntaxMatches(tokens, text, /\[[^\]]+\]\([^)]+\)/g, "link");
  addEditorSyntaxMatches(tokens, text, /<\/?[A-Za-z][^>]*>/g, "tag");
  addEditorSyntaxMatches(tokens, text, /(\*\*|__)[^\n]+?\1/g, "keyword");
  appendTokenizedEditorLine(root, text, tokens);
}

function appendCodeEditorLine(root: HTMLElement, text: string, language: string) {
  const normalized = language.toLowerCase();
  const tokens: EditorSyntaxToken[] = [];
  if (normalized === "markdown") {
    appendMarkdownEditorLine(root, text);
    return;
  }
  if (normalized === "html") {
    addEditorSyntaxMatches(tokens, text, /<!--.*?-->/g, "comment");
    addEditorSyntaxMatches(tokens, text, /<\/?[A-Za-z][A-Za-z0-9:-]*/g, "tag");
    addEditorSyntaxMatches(tokens, text, /\b[A-Za-z_:][-A-Za-z0-9_:.]*(?==)/g, "property");
  } else if (normalized === "css") {
    addEditorSyntaxMatches(tokens, text, /\/\*.*?\*\//g, "comment");
    addEditorSyntaxMatches(tokens, text, /(?:--)?[-A-Za-z]+(?=\s*:)/g, "property");
    addEditorSyntaxMatches(tokens, text, /#[0-9A-Fa-f]{3,8}\b/g, "number");
  } else if (normalized === "powershell" || normalized === "yaml" || normalized === "toml") {
    addEditorSyntaxMatches(tokens, text, /#.*/g, "comment");
  } else {
    addEditorSyntaxMatches(tokens, text, /\/\/.*/g, "comment");
  }

  addEditorSyntaxMatches(tokens, text, /(["'`])(?:\\.|(?!\1).)*\1/g, "string");
  addEditorSyntaxMatches(tokens, text, /\b\d+(?:\.\d+)?\b/g, "number");
  addEditorSyntaxMatches(tokens, text, /\b(?:async|await|break|case|const|continue|crate|else|enum|export|fn|for|from|function|if|impl|import|interface|let|match|mod|pub|return|self|struct|type|use|where|while)\b/g, "keyword");
  if (normalized === "powershell") {
    addEditorSyntaxMatches(tokens, text, /(?:^|\s)-[A-Za-z][A-Za-z0-9-]*/g, "operator");
  }
  addEditorSyntaxMatches(tokens, text, /\b[A-Za-z_$][\w$]*(?=\s*\()/g, "function");
  appendTokenizedEditorLine(root, text, tokens);
}

function renderEditorCode(root: HTMLElement, content: string, language = "Text") {
  root.innerHTML = "";
  root.classList.remove("is-image-preview");
  const lines = splitEditorCodeLines(content);
  root.style.setProperty("--editor-line-number-digits", `${Math.max(2, String(lines.length).length)}`);
  for (const line of lines) {
    const row = document.createElement("div");
    row.className = "editor-code-line";
    row.dataset.line = `${line.number}`;

    const lineNumber = document.createElement("span");
    lineNumber.className = "editor-line-number";
    lineNumber.textContent = `${line.number}`;

    const lineContent = document.createElement("span");
    lineContent.className = "editor-line-content";
    if (line.text) {
      appendCodeEditorLine(lineContent, line.text, language);
    } else {
      lineContent.textContent = " ";
    }

    row.append(lineNumber, lineContent);
    root.appendChild(row);
  }
}

function renderEditorSvgPreview(root: HTMLElement, content: string, path: string) {
  root.innerHTML = "";
  root.classList.add("is-image-preview");

  const preview = document.createElement("div");
  preview.className = "editor-svg-preview";

  const image = document.createElement("img");
  image.className = "editor-svg-preview-image";
  image.alt = path;
  image.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(content)}`;

  preview.appendChild(image);
  root.appendChild(preview);
}

function isEditorSvgPreview(selected: EditorFile) {
  return selected.path.toLowerCase().endsWith(".svg");
}

function getEditorLineEndingLabel(content: string) {
  return content.includes("\r\n") ? "CRLF" : "LF";
}

function getEditorIndentSizeLabel(content: string) {
  const indents = content.match(/^( +)\S/gm) ?? [];
  if (indents.length === 0) {
    return content.match(/^\t+\S/gm) ? "Tabs" : "Spaces: 2";
  }
  const sizes = indents
    .map((indent) => indent.search(/\S/))
    .filter((size) => size > 0);
  const smallest = sizes.length > 0 ? Math.min(...sizes) : 2;
  return `Spaces: ${Math.min(Math.max(smallest, 1), 8)}`;
}

function renderEditorStatusbar(
  root: HTMLElement,
  items: Array<{ label: string; value: string }>,
) {
  root.innerHTML = "";
  for (const item of items) {
    const entry = document.createElement("span");
    entry.className = "editor-status-item";

    const value = document.createElement("span");
    value.className = "editor-status-value";
    value.textContent = item.value;

    if (item.label) {
      const label = document.createElement("span");
      label.className = "editor-status-label";
      label.textContent = item.label;
      entry.appendChild(label);
    }
    entry.appendChild(value);
    root.appendChild(entry);
  }
}

function getConversationItems() {
  return [...backendConversation, ...runtimeConversation];
}

function appendRuntimeConversation(item: ConversationItem) {
  const lastItem = runtimeConversation[runtimeConversation.length - 1];
  if (
    lastItem &&
    lastItem.type === item.type &&
    lastItem.title === item.title &&
    lastItem.body === item.body &&
    lastItem.runId === item.runId
  ) {
    return;
  }

  runtimeConversation.push(item);
  if (runtimeConversation.length > MAX_RUNTIME_CONVERSATION_ITEMS) {
    runtimeConversation.splice(0, runtimeConversation.length - MAX_RUNTIME_CONVERSATION_ITEMS);
  }
}

function stripTerminalControlSequences(value: string) {
  return value
    .replace(/\x1b\][^\x07]*(?:\x07|\x1b\\)/g, "")
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/\x1b[@-Z\\-_]/g, "")
    .replace(/\r/g, "\n")
    .replace(/[^\S\n]+$/gm, "")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function getRecentNonEmptyLines(text: string, maxCount: number) {
  const lines = text.split(/\r?\n/).filter((line) => line.trim().length > 0);
  return lines.slice(Math.max(0, lines.length - maxCount));
}

function isClaudeOperatorReadyText(text: string) {
  const recentLines = getRecentNonEmptyLines(text, 8);
  if (recentLines.length === 0) {
    return false;
  }

  const tailText = recentLines.join("\n");
  if (/\b(missing api key|run \/login|unable to connect|failed to connect)\b/i.test(tailText)) {
    return false;
  }

  const finalLine = recentLines[recentLines.length - 1]?.trim() ?? "";
  return /^[>›▌❯]$/.test(finalLine);
}

function appendOperatorPtyOutput(data: string) {
  operatorOutputBuffer += data;
  if (operatorOutputBuffer.length > 8000) {
    operatorOutputBuffer = operatorOutputBuffer.slice(-8000);
  }

  if (operatorOutputFlushTimer !== null) {
    return;
  }

  operatorOutputFlushTimer = window.setTimeout(() => {
    operatorOutputFlushTimer = null;
    const body = stripTerminalControlSequences(operatorOutputBuffer).slice(-3000);
    operatorOutputBuffer = "";
    if (!body) {
      return;
    }
    if (operatorRequestActive && isClaudeOperatorReadyText(body)) {
      setOperatorRequestActive(false);
    }
    appendRuntimeConversation({
      type: "operator",
      category: "activity",
      timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }),
      actor: "Claude Code",
      body,
      tone: "info",
    });
    renderConversation(getConversationItems());
  }, 350);
}

function getExplainPayloadFingerprint(payload: DesktopExplainPayload | null | undefined) {
  if (!payload) {
    return "";
  }

  const observationPack = getObservationPack(payload);
  const consultationPacket = getConsultationPacket(payload);
  const consultationSummary = getConsultationSummary(payload);

  return JSON.stringify([
    payload.run.run_id,
    payload.run.task_id,
    payload.run.parent_run_id,
    payload.run.goal,
    payload.run.task_type,
    payload.run.priority,
    payload.run.blocking,
    payload.run.state,
    payload.run.task_state,
    payload.run.review_state,
    payload.run.provider_target,
    payload.run.agent_role,
    payload.run.branch,
    payload.run.head_sha,
    payload.run.worktree,
    payload.run.primary_label,
    payload.run.primary_pane_id,
    payload.run.primary_role,
    payload.run.last_event,
    payload.run.last_event_at,
    payload.run.tokens_remaining,
    payload.run.pane_count,
    payload.run.changed_file_count,
    payload.run.labels.join("|"),
    payload.run.pane_ids.join("|"),
    payload.run.roles.join("|"),
    payload.run.write_scope.join("|"),
    payload.run.read_scope.join("|"),
    payload.run.constraints.join("|"),
    payload.run.expected_output,
    payload.run.verification_plan.join("|"),
    payload.run.review_required,
    payload.run.timeout_policy,
    payload.run.handoff_refs.join("|"),
    payload.run.experiment_packet.hypothesis,
    payload.run.experiment_packet.test_plan.join("|"),
    payload.run.experiment_packet.result,
    payload.run.experiment_packet.confidence,
    payload.run.experiment_packet.next_action,
    payload.run.experiment_packet.observation_pack_ref,
    payload.run.experiment_packet.consultation_ref,
    payload.run.experiment_packet.run_id,
    payload.run.experiment_packet.slot,
    payload.run.experiment_packet.branch,
    payload.run.experiment_packet.worktree,
    payload.run.experiment_packet.env_fingerprint,
    payload.run.experiment_packet.command_hash,
    JSON.stringify(payload.run.security_policy),
    JSON.stringify(payload.run.security_verdict),
    JSON.stringify(payload.run.verification_contract),
    JSON.stringify(payload.run.verification_result),
    payload.run.changed_files.join("|"),
    payload.run.action_items.map((item) => `${item.kind}:${item.event}:${item.source}`).join("|"),
    payload.explanation.summary,
    payload.explanation.next_action,
    payload.explanation.reasons.join("|"),
    payload.explanation.current_state.state,
    payload.explanation.current_state.task_state,
    payload.explanation.current_state.review_state,
    payload.explanation.current_state.last_event,
    observationPack.run_id,
    observationPack.task_id,
    observationPack.pane_id,
    observationPack.slot,
    observationPack.hypothesis,
    observationPack.test_plan.join("|"),
    observationPack.changed_files.join("|"),
    observationPack.working_tree_summary,
    observationPack.failing_command,
    observationPack.env_fingerprint,
    observationPack.command_hash,
    observationPack.generated_at,
    consultationPacket.run_id,
    consultationPacket.task_id,
    consultationPacket.pane_id,
    consultationPacket.slot,
    consultationPacket.kind,
    consultationPacket.mode,
    consultationPacket.target_slot,
    consultationPacket.confidence,
    consultationPacket.recommendation,
    consultationPacket.next_test,
    consultationPacket.risks.join("|"),
    consultationPacket.generated_at,
    consultationSummary.kind,
    consultationSummary.mode,
    consultationSummary.target_slot,
    consultationSummary.confidence,
    consultationSummary.next_test,
    consultationSummary.risks.join("|"),
    payload.evidence_digest.next_action,
    payload.evidence_digest.verification_outcome,
    payload.evidence_digest.security_blocked,
    payload.evidence_digest.changed_files.join("|"),
    payload.recent_events.map((item) => `${item.event}:${item.message}`).join("|"),
  ]);
}

function getObservationPack(payload: DesktopExplainPayload): DesktopExplainPayload["observation_pack"] {
  const pack = (
    payload as DesktopExplainPayload & {
      observation_pack?: DesktopExplainPayload["observation_pack"];
    }
  ).observation_pack;
  return (
    pack ?? {
      run_id: "",
      task_id: "",
      pane_id: "",
      slot: "",
      hypothesis: "",
      test_plan: [],
      changed_files: [],
      working_tree_summary: "",
      failing_command: "",
      env_fingerprint: "",
      command_hash: "",
      generated_at: "",
    }
  );
}

function getConsultationPacket(payload: DesktopExplainPayload): DesktopExplainPayload["consultation_packet"] {
  const packet = (
    payload as DesktopExplainPayload & {
      consultation_packet?: DesktopExplainPayload["consultation_packet"];
    }
  ).consultation_packet;
  return (
    packet ?? {
      run_id: "",
      task_id: "",
      pane_id: "",
      slot: "",
      kind: "",
      mode: "",
      target_slot: "",
      confidence: 0,
      recommendation: "",
      next_test: "",
      risks: [],
      generated_at: "",
    }
  );
}

function getConsultationSummary(payload: DesktopExplainPayload): {
  kind: string;
  mode: string;
  target_slot: string;
  confidence: number;
  next_test: string;
  risks: string[];
} {
  const packet = getConsultationPacket(payload);
  return {
    kind: packet.kind,
    mode: packet.mode,
    target_slot: packet.target_slot,
    confidence: packet.confidence,
    next_test: packet.next_test,
    risks: packet.risks,
  };
}

function summarizeChangedFiles(paths: string[], limit = 3) {
  const visible = paths.filter((value) => Boolean(value)).slice(0, limit);
  if (visible.length === 0) {
    return "";
  }

  const remaining = paths.length - visible.length;
  return remaining > 0 ? `${visible.join(", ")} +${remaining} more` : visible.join(", ");
}

function buildExperimentFileLine(
  label: string,
  paths: string[],
  worktree: string,
): ExperimentDetailLine {
  const path = paths.find((value) => Boolean(value));
  return {
    label,
    value: paths.length > 0 ? summarizeChangedFiles(paths, 4) : "none",
    path: path || undefined,
    worktree: path ? worktree : undefined,
    title: path ? `Open ${path} in the read-only editor.` : undefined,
  };
}

function summarizeWorkspaceContext(branch: string, worktree: string) {
  const parts = [branch, worktree].filter((value) => Boolean(value));
  return parts.join(" @ ");
}

function summarizeReviewVerdict(payload: DesktopExplainPayload) {
  const status = payload.review_state?.status || payload.run.review_state;
  if (!status) {
    return "";
  }

  const parts = [status];
  if (payload.review_state?.reviewer?.label) {
    parts.push(`by ${payload.review_state.reviewer.label}`);
  }

  const evidence = payload.review_state?.evidence;
  const evidenceSource =
    (status === "PASS" ? evidence?.approved_via : undefined) ||
    ((status === "FAIL" || status === "FAILED") ? evidence?.failed_via : undefined);
  if (evidenceSource) {
    parts.push(`via ${evidenceSource}`);
  }

  return parts.join(" ");
}

function summarizeProjectionExperiment(projection: DesktopRunProjection) {
  if (!projection.hypothesis) {
    return "";
  }

  const parts = [`Hypothesis ${projection.hypothesis}`];
  if (projection.confidence !== null) {
    parts.push(`confidence ${formatConfidencePercent(projection.confidence)}`);
  }

  return parts.join(" · ");
}

function summarizeProjectionConsultation(projection: DesktopRunProjection) {
  if (!projection.consultation_ref) {
    return "";
  }

  const parts = [summarizeProjectionExperiment(projection) || "Consultation linked"];
  parts.push(`Next ${projection.next_action || "idle"}`);
  const reasons = projection.reasons.filter((value) => Boolean(value)).slice(0, 2);
  if (reasons.length > 0) {
    parts.push(`Reasons ${reasons.join(" | ")}`);
  }

  return parts.join(" · ");
}

function formatConfidencePercent(value: number) {
  return `${Math.round(value * 100)}%`;
}

function summarizeArtifactRef(path: string) {
  if (!path) {
    return "";
  }

  const parts = path.split(/[\\/]/).filter((value) => Boolean(value));
  return parts[parts.length - 1] || path;
}

function getRunProjectionFingerprint(projection: DesktopRunProjection | null | undefined) {
  if (!projection) {
    return "";
  }

  return JSON.stringify([
    projection.label,
    projection.head_sha,
    projection.head_short,
    projection.worktree,
    projection.review_state,
    projection.next_action,
    projection.verification_outcome,
    projection.security_blocked,
    projection.branch,
    projection.provider_target,
    projection.changed_files.join("|"),
    projection.hypothesis,
    projection.confidence,
  ]);
}

function getBoardPaneFingerprint(pane: DesktopBoardPane) {
  return JSON.stringify([
    pane.label,
    pane.role,
    pane.state,
    pane.task_state,
    pane.review_state,
    pane.branch,
    pane.worktree,
    pane.head_sha,
    pane.changed_file_count,
    pane.last_event_at,
  ]);
}

function diffDesktopSummarySnapshots(
  previousSnapshot: DesktopSummarySnapshot | null,
  nextSnapshot: DesktopSummarySnapshot,
) {
  if (!previousSnapshot) {
    return {
      hasMeaningfulChange: true,
      changedRunIds: [] as string[],
      inboxCountChanged: false,
      addedRunIds: [] as string[],
      removedRunIds: [] as string[],
    };
  }

  const previousProjectionMap = new Map(
    previousSnapshot.run_projections.map((projection) => [projection.run_id, projection]),
  );
  const nextProjectionMap = new Map(
    nextSnapshot.run_projections.map((projection) => [projection.run_id, projection]),
  );
  const previousBoardPaneMap = new Map(
    previousSnapshot.board.panes.map((pane) => [pane.pane_id, pane]),
  );
  const nextBoardPaneMap = new Map(
    nextSnapshot.board.panes.map((pane) => [pane.pane_id, pane]),
  );

  const changedRunIds: string[] = [];
  const addedRunIds: string[] = [];
  const removedRunIds: string[] = [];
  let boardPaneChanged = previousSnapshot.board.panes.length !== nextSnapshot.board.panes.length;

  for (const [runId, nextProjection] of nextProjectionMap) {
    const previousProjection = previousProjectionMap.get(runId);
    if (!previousProjection) {
      addedRunIds.push(runId);
      continue;
    }

    if (getRunProjectionFingerprint(previousProjection) !== getRunProjectionFingerprint(nextProjection)) {
      changedRunIds.push(runId);
    }
  }

  for (const runId of previousProjectionMap.keys()) {
    if (!nextProjectionMap.has(runId)) {
      removedRunIds.push(runId);
    }
  }

  if (!boardPaneChanged) {
    for (const [paneId, nextPane] of nextBoardPaneMap) {
      const previousPane = previousBoardPaneMap.get(paneId);
      if (!previousPane) {
        boardPaneChanged = true;
        break;
      }

      if (getBoardPaneFingerprint(previousPane) !== getBoardPaneFingerprint(nextPane)) {
        boardPaneChanged = true;
        break;
      }
    }
  }

  const inboxCountChanged =
    previousSnapshot.inbox.summary.item_count !== nextSnapshot.inbox.summary.item_count;

  return {
    hasMeaningfulChange:
      boardPaneChanged ||
      inboxCountChanged ||
      addedRunIds.length > 0 ||
      removedRunIds.length > 0 ||
      changedRunIds.length > 0,
    boardPaneChanged,
    changedRunIds,
    inboxCountChanged,
    addedRunIds,
    removedRunIds,
  };
}

function buildDesktopFollowConversation(
  previousSnapshot: DesktopSummarySnapshot | null,
  nextSnapshot: DesktopSummarySnapshot,
) {
  const diff = diffDesktopSummarySnapshots(previousSnapshot, nextSnapshot);
  if (!previousSnapshot || !diff.hasMeaningfulChange) {
    return [];
  }

  const timestamp = new Date(nextSnapshot.generated_at).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
  const previousProjectionMap = new Map(
    previousSnapshot.run_projections.map((projection) => [projection.run_id, projection]),
  );
  const nextProjectionMap = new Map(
    nextSnapshot.run_projections.map((projection) => [projection.run_id, projection]),
  );
  const selected = resolveSelectedRunId(nextSnapshot);
  const prioritizedChangedRunIds = [
    ...diff.changedRunIds.filter((runId) => runId === selected),
    ...diff.addedRunIds.filter((runId) => runId === selected),
    ...diff.changedRunIds.filter((runId) => runId !== selected),
    ...diff.addedRunIds.filter((runId) => runId !== selected),
  ]
    .map((runId, index) => {
      const projection = nextProjectionMap.get(runId);
      const selectedRank = runId === selected ? 0 : 1;
      const signalRank = projection?.consultation_ref ? 0 : projection?.hypothesis ? 1 : 2;
      const sourceRank = diff.changedRunIds.includes(runId) ? 0 : 1;
      return { runId, index, selectedRank, signalRank, sourceRank };
    })
    .sort((left, right) => {
      if (left.selectedRank !== right.selectedRank) {
        return left.selectedRank - right.selectedRank;
      }
      if (left.signalRank !== right.signalRank) {
        return left.signalRank - right.signalRank;
      }
      if (left.sourceRank !== right.sourceRank) {
        return left.sourceRank - right.sourceRank;
      }
      return left.index - right.index;
    })
    .map((item) => item.runId)
    .slice(0, 3);

  const items: ConversationItem[] = [];
  for (const runId of prioritizedChangedRunIds) {
    const projection = nextProjectionMap.get(runId);
    if (!projection) {
      continue;
    }
    const experimentSummary = summarizeProjectionExperiment(projection);
    const consultationSummary = summarizeProjectionConsultation(projection);
    const tone: SurfaceTone = consultationSummary
      ? "focus"
      : experimentSummary
        ? "accent"
        : projection.review_state === "PASS"
          ? "success"
          : projection.review_state === "PENDING"
            ? "warning"
            : "info";
    const statusLabel = consultationSummary
      ? "consultation"
      : experimentSummary
        ? "hypothesis"
        : projection.next_action || undefined;
    const title = consultationSummary
      ? (diff.addedRunIds.includes(runId) ? "Consultation surfaced" : "Consultation updated")
      : experimentSummary
      ? (diff.addedRunIds.includes(runId) ? "Hypothesis surfaced" : "Hypothesis updated")
      : (diff.addedRunIds.includes(runId) ? "Run surfaced" : "Run updated");

    items.push({
      type: "system",
      category:
        projection.review_state === "PENDING" ||
        projection.review_state === "FAIL" ||
        projection.review_state === "FAILED"
          ? "review"
          : "activity",
      timestamp,
      actor: projection.label || projection.pane_id || "System",
      title,
      body: consultationSummary
        ? `Consultation: ${consultationSummary}`
        : experimentSummary
        ? `Hypothesis: ${experimentSummary}`
        : `Run: ${projection.next_action || "idle"}`,
      details: [
        ...((consultationSummary || experimentSummary) && projection.changed_files.length > 0
          ? [
              {
                label: "files",
                value: `${projection.changed_files.length}: ${summarizeChangedFiles(projection.changed_files)}`,
              },
            ]
          : []),
        ...(projection.review_state
          ? [{ label: "review", value: projection.review_state }]
          : []),
        ...((consultationSummary || experimentSummary) && projection.head_short
          ? [{ label: "head", value: projection.head_short }]
          : []),
        ...((consultationSummary || experimentSummary)
          ? [{ label: "branch", value: projection.branch || "no branch" }]
          : []),
        ...(!(consultationSummary || experimentSummary) && projection.changed_files.length > 0
          ? [{ label: "changed", value: `${projection.changed_files.length}` }]
          : []),
        ...(projection.verification_outcome
          ? [{ label: "verify", value: projection.verification_outcome }]
          : []),
        ...((consultationSummary || experimentSummary)
          ? [{ label: "next", value: projection.next_action || "idle" }]
          : []),
        ...(!(consultationSummary || experimentSummary) && projection.head_short
          ? [{ label: "head", value: projection.head_short }]
          : []),
        ...(!(consultationSummary || experimentSummary)
          ? [{ label: "branch", value: projection.branch || "no branch" }]
          : []),
        ...(projection.consultation_ref
          ? [{ label: "consultation", value: summarizeArtifactRef(projection.consultation_ref) }]
          : []),
        ...(projection.hypothesis
          ? [{ label: "hypothesis", value: projection.hypothesis }]
          : []),
      ],
      tone,
      runId,
      statusLabel,
    });
  }

  for (const runId of diff.removedRunIds.slice(0, 2)) {
    const previousProjection = previousProjectionMap.get(runId);
    if (!previousProjection) {
      continue;
    }

    items.push({
      type: "system",
      category: "attention",
      timestamp,
      actor: previousProjection.label || previousProjection.pane_id || "System",
      title: "Run removed",
      body: `Run ${runId} dropped out of the desktop summary snapshot.`,
      details: [
        { label: "branch", value: previousProjection.branch || "no branch" },
        ...(previousProjection.head_short ? [{ label: "head", value: previousProjection.head_short }] : []),
      ],
      tone: "warning",
      runId,
      statusLabel: previousProjection.review_state || undefined,
    });
  }

  if (diff.inboxCountChanged) {
    items.push({
      type: "system",
      category: "attention",
      timestamp,
      actor: "System",
      title: "Notifications changed",
      body: `Notification count changed from ${previousSnapshot.inbox.summary.item_count} to ${nextSnapshot.inbox.summary.item_count}.`,
      details: [{ label: "notifications", value: `${nextSnapshot.inbox.summary.item_count}` }],
      tone: "warning",
    });
  }

  return items.slice(0, 4);
}

function setTerminalDrawer(open: boolean) {
  terminalDrawerOpen = open;
  const drawer = document.getElementById("terminal-drawer");
  const button = document.getElementById("toggle-terminal-btn");
  const body = document.getElementById("workspace-body");
  if (!drawer || !button) {
    return;
  }

  drawer.hidden = !open;
  body?.classList.toggle("workbench-collapsed", !open);
  drawer.setAttribute("data-layout", workbenchLayout);
  setCompactButtonLabel(button, open ? getLanguageText("Hide panes", "ペインを隠す") : getLanguageText("Worker panes", "ワーカーペイン"));
  button.setAttribute("aria-expanded", open ? "true" : "false");
  button.setAttribute("aria-label", open ? getLanguageText("Hide worker panes", "ワーカーペインを隠す") : getLanguageText("Show worker panes", "ワーカーペインを表示"));

  if (open) {
    ensureWorkbenchPaneCount(getWorkbenchPaneCountForLayout());
  }

  updateWorkbenchControls();
  void persistThemeState();
  requestAnimationFrame(() => {
    fitVisibleWorkbenchPanes();
  });
}

function setContextPanel(open: boolean, options?: { preserveWidePreference?: boolean }) {
  contextPanelOpen = open;
  const panel = document.getElementById("context-panel");
  const button = document.getElementById("toggle-context-btn");
  const body = document.getElementById("workspace-body");
  if (!panel || !button || !body) {
    return;
  }

  if ((options?.preserveWidePreference ?? true) && !isNarrowLayout()) {
    preferredWideContextOpen = open;
    void persistThemeState();
  }

  panel.toggleAttribute("hidden", !open);
  body.classList.toggle("context-collapsed", !open);
  setCompactButtonLabel(button, open ? getLanguageText("Hide", "隠す") : getLanguageText("Details", "詳細"));
  button.setAttribute("aria-expanded", open ? "true" : "false");
  button.setAttribute("aria-label", open ? getLanguageText("Hide details panel", "詳細パネルを隠す") : getLanguageText("Show details panel", "詳細パネルを表示"));
  syncActivityButtons();
}

function setSidebarMode(mode: SidebarMode) {
  sidebarMode = mode;
  const brandBlock = document.getElementById("sidebar-brand-block");
  const filesSection = document.getElementById("files-sidebar-section");
  const sessionSection = document.getElementById("session-sidebar-section");
  const editorsSection = document.getElementById("editors-sidebar-section");
  const sourceSummarySection = document.getElementById("source-sidebar-section");
  const sourceControlView = document.getElementById("source-control-view");
  const evidenceView = document.getElementById("evidence-view");
  const workspaceSectionsOpen = mode === "workspace";

  if (brandBlock) {
    brandBlock.hidden = !workspaceSectionsOpen;
  }
  if (filesSection) {
    filesSection.hidden = mode !== "explorer";
  }
  if (sessionSection) {
    sessionSection.hidden = !workspaceSectionsOpen;
  }
  if (editorsSection) {
    editorsSection.hidden = !workspaceSectionsOpen;
  }
  if (sourceSummarySection) {
    sourceSummarySection.hidden = !workspaceSectionsOpen;
  }
  if (sourceControlView) {
    sourceControlView.hidden = mode !== "source";
  }
  if (evidenceView) {
    evidenceView.hidden = mode !== "evidence";
  }
  if (mode === "source") {
    renderSourceControlView();
  } else if (mode === "evidence") {
    renderEvidenceView();
  } else if (mode === "workspace") {
    renderSessions();
    renderOpenEditors();
    renderSourceSummary();
    renderSourceEntries();
  }
  updateSidebarModeTitle();
  syncActivityButtons();
}

function cycleWorkbenchLayout() {
  workbenchLayout = workbenchLayout === "2x2" ? "3x2" : workbenchLayout === "3x2" ? "focus" : "2x2";
  if (terminalDrawerOpen && workbenchLayout === "3x2") {
    ensureWorkbenchPaneCount(6);
  }
  updateWorkbenchControls();
  void persistThemeState();
  requestAnimationFrame(() => {
    fitVisibleWorkbenchPanes();
  });
}

function setCompactButtonLabel(button: Element, label: string) {
  const labelNode = button.querySelector(".btn-label");
  if (labelNode) {
    labelNode.textContent = label;
    return;
  }

  button.textContent = label;
}

function setEditorSurface(open: boolean) {
  editorSurfaceOpen = open;
  const panel = document.getElementById("editor-surface");
  const body = document.getElementById("workspace-body");
  if (!panel || !body) {
    return;
  }

  panel.toggleAttribute("hidden", !open);
  body.classList.toggle("editor-open", open);
  renderEditorSurface();
  renderOpenEditors();
  renderContextPanel();
}

function isNarrowLayout() {
  return window.matchMedia("(max-width: 1366px)").matches;
}

function setSidebarOpen(open: boolean, options?: { preserveWidePreference?: boolean }) {
  sidebarOpen = open;
  const shell = document.getElementById("app-shell");
  const overlay = document.getElementById("sidebar-overlay");
  const button = document.getElementById("toggle-sidebar-btn");
  const activityButton = document.getElementById("activity-explorer-btn");
  if (!shell || !overlay || !button) {
    return;
  }

  if ((options?.preserveWidePreference ?? true) && !isNarrowLayout()) {
    preferredWideSidebarOpen = open;
    void persistThemeState();
  }

  shell.classList.toggle("sidebar-open", open);
  overlay.hidden = !(open && isNarrowLayout());
  button.setAttribute("aria-expanded", open ? "true" : "false");
  activityButton?.setAttribute("aria-expanded", open ? "true" : "false");
  syncActivityButtons();
}

function syncActivityButtons() {
  const explorerButton = document.getElementById("activity-explorer-btn");
  const sourceButton = document.getElementById("activity-source-btn");
  const evidenceButton = document.getElementById("activity-evidence-btn");
  const contextButton = document.getElementById("activity-context-btn");
  const sourceBadge = document.getElementById("activity-source-count");
  const evidenceBadge = document.getElementById("activity-evidence-count");
  const changeCount = getVisibleSourceChanges().length;
  const evidenceCount = getEvidenceItems().length;

  explorerButton?.classList.toggle("is-active", sidebarOpen && sidebarMode === "explorer");
  sourceButton?.classList.toggle("is-active", sidebarOpen && sidebarMode === "source");
  evidenceButton?.classList.toggle("is-active", sidebarOpen && sidebarMode === "evidence");
  contextButton?.classList.toggle("is-active", contextPanelOpen);
  explorerButton?.setAttribute("aria-expanded", sidebarOpen && sidebarMode === "explorer" ? "true" : "false");
  sourceButton?.setAttribute("aria-expanded", sidebarOpen && sidebarMode === "source" ? "true" : "false");
  evidenceButton?.setAttribute("aria-expanded", sidebarOpen && sidebarMode === "evidence" ? "true" : "false");
  contextButton?.setAttribute("aria-expanded", contextPanelOpen ? "true" : "false");
  if (sourceBadge) {
    sourceBadge.hidden = changeCount === 0;
    sourceBadge.textContent = `${changeCount}`;
  }
  if (evidenceBadge) {
    evidenceBadge.hidden = evidenceCount === 0;
    evidenceBadge.textContent = `${evidenceCount}`;
  }
}

function getSettingsSections() {
  return Array.from(document.querySelectorAll<HTMLElement>("#settings-content .settings-section"));
}

function setActiveSettingsNav(targetId: string) {
  document.querySelectorAll<HTMLButtonElement>(".settings-nav-item").forEach((button) => {
    button.classList.toggle("is-active", button.dataset.settingsTarget === targetId);
  });
}

function updateSettingsSearchFilter() {
  const input = document.getElementById("settings-search-input") as HTMLInputElement | null;
  const query = input?.value.trim().toLowerCase() ?? "";
  const sections = getSettingsSections();
  let firstVisibleId = "";
  for (const section of sections) {
    const text = section.textContent?.toLowerCase() ?? "";
    const visible = !query || text.includes(query);
    section.hidden = !visible;
    if (visible && !firstVisibleId) {
      firstVisibleId = section.id;
    }
  }

  document.querySelectorAll<HTMLButtonElement>(".settings-nav-item").forEach((button) => {
    const targetId = button.dataset.settingsTarget ?? "";
    const target = document.getElementById(targetId);
    const disabled = Boolean(query && target instanceof HTMLElement && target.hidden);
    button.disabled = disabled;
    button.setAttribute("aria-disabled", disabled ? "true" : "false");
  });

  if (firstVisibleId) {
    setActiveSettingsNav(firstVisibleId);
  }
}

function scrollToSettingsSection(targetId: string) {
  const target = document.getElementById(targetId);
  if (!(target instanceof HTMLElement) || target.hidden) {
    return;
  }
  setActiveSettingsNav(targetId);
  target.scrollIntoView({ block: "start", behavior: "smooth" });
}

function resetSettingsView() {
  settingsFontFamilyMenuOpen = false;
  const searchInput = document.getElementById("settings-search-input") as HTMLInputElement | null;
  if (searchInput) {
    searchInput.value = "";
  }
  getSettingsSections().forEach((section) => {
    section.hidden = false;
  });
  document.querySelectorAll<HTMLButtonElement>(".settings-nav-item").forEach((button) => {
    button.disabled = false;
    button.setAttribute("aria-disabled", "false");
  });
  setActiveSettingsNav("settings-section-common");
  const content = document.getElementById("settings-content");
  if (content) {
    content.scrollTop = 0;
  }
}

function initializeSettingsDialogControls() {
  document.querySelectorAll<HTMLButtonElement>(".settings-nav-item").forEach((button) => {
    button.addEventListener("click", () => {
      const targetId = button.dataset.settingsTarget;
      if (targetId) {
        scrollToSettingsSection(targetId);
      }
    });
  });

  document.getElementById("settings-search-input")?.addEventListener("input", updateSettingsSearchFilter);

  document.addEventListener("click", (event) => {
    if (!settingsFontFamilyMenuOpen) {
      return;
    }
    const target = event.target;
    if (!(target instanceof Node)) {
      return;
    }
    const control = document.querySelector(".settings-font-family-control");
    if (control?.contains(target)) {
      return;
    }
    settingsFontFamilyMenuOpen = false;
    renderSettingsControls();
  });

  document.querySelectorAll<HTMLButtonElement>(".settings-tab").forEach((button) => {
    button.addEventListener("click", () => {
      document.querySelectorAll<HTMLButtonElement>(".settings-tab").forEach((candidate) => {
        candidate.classList.toggle("is-active", candidate === button);
      });
    });
  });
}

function setSettingsSheet(open: boolean) {
  const sheet = document.getElementById("settings-sheet");
  if (!sheet) {
    return;
  }

  if (open && commandBarOpen) {
    closeCommandBar();
  }

  settingsSheetOpen = open;
  if (!open) {
    settingsFontFamilyMenuOpen = false;
  }
  if (open) {
    if (!settingsDraftState) {
      settingsDraftState = cloneThemeState(themeState);
    }
    if (!runtimeRoleDraftState) {
      runtimeRoleDraftState = cloneRuntimeRolePreferences(runtimeRolePreferences);
    }
    resetSettingsView();
    renderSettingsControls();
    requestAnimationFrame(() => {
      (document.getElementById("settings-search-input") as HTMLInputElement | null)?.focus();
    });
  }
  sheet.hidden = !open;
  renderFooterLane();
}

async function applySettingsDraft() {
  if (settingsDraftState) {
    const validation = getVoiceShortcutValidation(settingsDraftState.voiceShortcut, settingsDraftState.language === "ja");
    if (!validation.valid) {
      updateVoiceShortcutWarning(settingsDraftState);
      return;
    }
    settingsDraftState.voiceShortcut = validation.normalized;
    applyThemeState(settingsDraftState);
    persistThemeState();
  }
  if (runtimeRoleDraftState) {
    runtimeRolePreferences = cloneRuntimeRolePreferences(runtimeRoleDraftState);
    persistRuntimeRolePreferences();
    try {
      await applyRuntimeRolePreferencesToDesktop(runtimeRolePreferences);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      appendRuntimeConversation({
        type: "system",
        category: "attention",
        timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }),
        actor: "winsmux",
        title: getLanguageText("Runtime settings were saved locally", "実行環境設定はローカルに保存しました"),
        body: message,
        tone: "warning",
      });
      console.warn("Failed to apply runtime role preferences to desktop runtime", error);
    }
  }
  settingsDraftState = null;
  runtimeRoleDraftState = null;
  if (settingsSheetOpen) {
    renderSettingsControls();
    renderFooterLane();
  }
  renderConversation(getConversationItems());
}

function cancelSettingsDraft() {
  settingsDraftState = null;
  runtimeRoleDraftState = null;
  setSettingsSheet(false);
}

function syncResponsiveShell() {
  if (isNarrowLayout()) {
    setSidebarOpen(false, { preserveWidePreference: false });
    setContextPanel(false, { preserveWidePreference: false });
  } else {
    setSidebarOpen(preferredWideSidebarOpen, { preserveWidePreference: false });
    setContextPanel(preferredWideContextOpen, { preserveWidePreference: false });
  }
}

function installViewportHarnessHooks() {
  const searchParams = new URLSearchParams(window.location.search);
  if (searchParams.get("viewport-harness") !== "1") {
    return;
  }

  window.__winsmuxViewportHarness = {
    registerPreviewTarget: (sourceLabel: string, url: string) => {
      registerPreviewTargetForHarness(sourceLabel, url);
    },
    openPreviewTarget: (url: string) => {
      openPreviewTarget(url);
    },
    openEditorPreview: (path: string, content: string, worktree?: string) => {
      openEditorPreviewForHarness(path, content, worktree);
    },
    setContextPanel: (open: boolean) => {
      setContextPanel(open);
    },
    setTerminalDrawer: (open: boolean) => {
      setTerminalDrawer(open);
    },
    getOperatorStartupInput: () => getOperatorStartupInput(),
  };
}

function appendUserMessage(message: string, attachments: ComposerAttachment[]) {
  const dogfoodInputSource = composerInputSource;
  const dogfoodStartedAt = composerDraftStartedAt || Date.now();
  const dogfoodDraft = {
    taskRef: ensureComposerDogfoodTaskRef(dogfoodStartedAt),
    voiceStartedAt: composerVoiceStartedAt,
    keyboardAfterVoiceAt: composerKeyboardAfterVoiceAt,
  };
  const now = new Date();
  const timestamp = `${`${now.getHours()}`.padStart(2, "0")}:${`${now.getMinutes()}`.padStart(2, "0")}`;
  appendRuntimeConversation({
    type: "user",
    category: "user",
    timestamp,
    actor: "User",
    body: message || "Attached files for dispatch.",
    attachments: attachments.map((attachment) => ({
      name: attachment.name,
      kind: attachment.kind,
      sizeLabel: attachment.sizeLabel,
    })),
  });
  void forwardComposerMessageToOperatorPane(message, attachments, timestamp);
  void recordComposerDogfoodEvent(message, attachments, dogfoodInputSource, dogfoodStartedAt, dogfoodDraft);
  resetComposerDogfoodDraft();
  renderRunSummary();
  renderConversation(getConversationItems());
}

function updateOperatorInterruptButton() {
  const button = document.getElementById("interrupt-operator-btn") as HTMLButtonElement | null;
  if (!button) {
    return;
  }

  const label = operatorInterruptInFlight
    ? getLanguageText("Stopping operator request", "中断中")
    : getLanguageText("Stop operator request", "依頼を中断");
  button.hidden = !operatorRequestActive;
  button.disabled = operatorInterruptInFlight;
  button.classList.toggle("is-busy", operatorInterruptInFlight);
  button.setAttribute("aria-label", label);
  button.setAttribute("title", label);
}

function formatOperatorWorkingElapsed(startedAt: number) {
  const elapsedSeconds = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
  const minutes = Math.floor(elapsedSeconds / 60);
  const seconds = elapsedSeconds % 60;
  return `${minutes}m ${`${seconds}`.padStart(2, "0")}s`;
}

function updateOperatorStatusIndicator() {
  const status = document.getElementById("composer-operator-status");
  if (!status) {
    return;
  }

  status.hidden = !operatorRequestActive;
  if (!operatorRequestActive) {
    return;
  }

  const label = document.getElementById("operator-working-label");
  const elapsed = document.getElementById("operator-working-elapsed");
  const hint = document.getElementById("operator-working-hint");
  if (label) {
    label.textContent = getLanguageText("working", "処理中");
  }
  if (elapsed) {
    elapsed.textContent = formatOperatorWorkingElapsed(operatorRequestStartedAt || Date.now());
  }
  if (hint) {
    hint.textContent = getLanguageText("Esc to interrupt", "Esc で中断");
  }
}

function startOperatorStatusTimer() {
  if (operatorRequestStatusTimer !== null) {
    return;
  }

  operatorRequestStatusTimer = window.setInterval(() => {
    updateOperatorStatusIndicator();
  }, 1000);
}

function stopOperatorStatusTimer() {
  if (operatorRequestStatusTimer === null) {
    return;
  }

  window.clearInterval(operatorRequestStatusTimer);
  operatorRequestStatusTimer = null;
}

function setOperatorRequestActive(active: boolean) {
  const wasActive = operatorRequestActive;
  operatorRequestActive = active;
  if (active && !wasActive) {
    operatorRequestStartedAt = Date.now();
    startOperatorStatusTimer();
  }
  if (!active) {
    operatorRequestStartedAt = 0;
    stopOperatorStatusTimer();
  }
  updateOperatorInterruptButton();
  updateOperatorStatusIndicator();
}

function beginOperatorRequest() {
  operatorRequestGeneration += 1;
  setOperatorRequestActive(true);
  return operatorRequestGeneration;
}

function invalidateOperatorRequest() {
  operatorRequestGeneration += 1;
}

function isCurrentOperatorRequest(generation: number) {
  return operatorRequestActive && operatorRequestGeneration === generation;
}

async function interruptOperatorRequest() {
  if (!operatorRequestActive || operatorInterruptInFlight) {
    return;
  }

  const timestamp = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  operatorInterruptInFlight = true;
  invalidateOperatorRequest();
  const canceledGeneration = operatorRequestGeneration;
  setOperatorRequestActive(false);
  updateOperatorInterruptButton();
  try {
    await ensureOperatorPtyStarted();
    if (operatorRequestGeneration !== canceledGeneration || operatorRequestActive) {
      return;
    }
    await writePtyData(OPERATOR_PTY_ID, "\x03");
    appendRuntimeConversation({
      type: "system",
      category: "attention",
      timestamp,
      actor: "winsmux",
      title: getLanguageText("Operator request interrupted", "オペレーターへの依頼を中断"),
      body: getLanguageText(
        "winsmux sent Ctrl+C to the operator pane.",
        "winsmux はオペレーターペインへ Ctrl+C を送信しました。",
      ),
      tone: "warning",
    });
  } catch (error) {
    appendRuntimeConversation({
      type: "system",
      category: "attention",
      timestamp,
      actor: "winsmux",
      title: getLanguageText("Operator interrupt failed", "オペレーターを中断できませんでした"),
      body: error instanceof Error ? error.message : String(error),
      tone: "warning",
    });
  } finally {
    operatorInterruptInFlight = false;
    updateOperatorInterruptButton();
  }

  renderConversation(getConversationItems());
  requestDesktopSummaryRefresh(undefined, 500);
}

function formatComposerMessageForPty(message: string, attachments: ComposerAttachment[]) {
  const trimmedMessage = message.trim();
  const attachmentLines = attachments.map((attachment) => `- ${attachment.name}${attachment.sizeLabel ? ` (${attachment.sizeLabel})` : ""}`);
  if (attachmentLines.length === 0) {
    return trimmedMessage;
  }
  const attachmentHeader = getLanguageText("Attachments:", "添付:");
  const attachmentBlock = `${attachmentHeader}\n${attachmentLines.join("\n")}`;
  return trimmedMessage ? `${trimmedMessage}\n\n${attachmentBlock}` : attachmentBlock;
}

function encodePtySubmission(message: string) {
  if (message.includes("\n")) {
    return `\x1b[200~${message}\x1b[201~\r`;
  }
  return `${message}\r`;
}

async function forwardComposerMessageToOperatorPane(
  message: string,
  attachments: ComposerAttachment[],
  timestamp: string,
) {
  const payload = formatComposerMessageForPty(message, attachments);
  if (!payload.trim()) {
    setOperatorRequestActive(false);
    return;
  }

  const requestGeneration = beginOperatorRequest();
  try {
    await ensureOperatorPtyStarted();
    if (!isCurrentOperatorRequest(requestGeneration)) {
      return;
    }
    await writePtyData(OPERATOR_PTY_ID, encodePtySubmission(payload));
    if (!isCurrentOperatorRequest(requestGeneration)) {
      return;
    }
  } catch (error) {
    if (!isCurrentOperatorRequest(requestGeneration)) {
      return;
    }
    setOperatorRequestActive(false);
    const errorMessage = error instanceof Error ? error.message : String(error);
    const desktopRuntimeError = errorMessage.includes("outside the Tauri runtime");
    appendRuntimeConversation({
      type: "system",
      category: "attention",
      timestamp,
      actor: "winsmux",
      title: getLanguageText("Claude Code send failed", "Claude Code 送信に失敗"),
      body: desktopRuntimeError
        ? getLanguageText(
          "Open winsmux in the desktop runtime. The browser preview cannot launch or write to the operator CLI.",
          "winsmux デスクトップで開いてください。ブラウザー表示ではオペレーター CLI を起動・送信できません。",
        )
        : errorMessage,
      tone: "warning",
    });
    renderConversation(getConversationItems());
  }
}

function findEditorFile(target: EditorTarget | null) {
  if (!target) {
    return null;
  }

  const existing = desktopEditorFileCache.get(target.key);
  if (existing) {
    return existing;
  }

  const loading = desktopEditorLoadingPaths.has(target.key);
  const loadError = desktopEditorLoadErrors.get(target.key);
  const previewBody = loadError
    ? `Backend preview failed to load.\n\n${loadError}`
    : loading
      ? "Backend preview request in flight."
      : "No backend preview cached.";

  return {
    key: target.key,
    path: target.path,
    summary: target.summary,
    content: `${previewBody}\n`,
    language: inferLanguageFromPath(target.path),
    lineCount: countEditorLines(previewBody),
    modified: target.modified,
    origin: target.origin,
  };
}

function countEditorLines(content: string) {
  return content.split(/\r?\n/).length;
}

function getUpperRecordField(record: Record<string, unknown> | null | undefined, key: string) {
  const value = record?.[key];
  return typeof value === "string" ? value.toUpperCase() : "";
}

function isDesktopRunPromotable(run: DesktopExplainPayload["run"]) {
  const taskState = (run.task_state || "").toLowerCase();
  const reviewState = (run.review_state || "").toUpperCase();
  const verificationOutcome = getUpperRecordField(run.verification_result, "outcome");
  const securityVerdict = getUpperRecordField(run.security_verdict, "verdict");

  if (!["completed", "task_completed", "commit_ready", "done"].includes(taskState)) {
    return false;
  }
  if (reviewState && reviewState !== "PASS") {
    return false;
  }
  if (verificationOutcome !== "PASS") {
    return false;
  }
  if (!["ALLOW", "PASS"].includes(securityVerdict)) {
    return false;
  }

  return true;
}

function buildCachedEditorFile(
  target: EditorTarget,
  payload: DesktopEditorFilePayload,
): EditorFile {
  const summary = payload.truncated
    ? `${target.summary} · preview truncated`
    : target.summary;
  return {
    key: target.key,
    path: payload.path,
    summary,
    content: payload.content,
    language: inferLanguageFromPath(payload.path),
    lineCount: payload.line_count || countEditorLines(payload.content),
    modified: target.modified,
    origin: target.origin,
  };
}

function getEditorFiles() {
  return Array.from(desktopStandaloneEditorTargets.values())
    .map((target) => findEditorFile(target))
    .filter((item): item is EditorFile => Boolean(item));
}

function closeEditorTab(key: string) {
  const openKeys = Array.from(desktopStandaloneEditorTargets.keys());
  const closedIndex = openKeys.indexOf(key);
  const wasSelected = selectedEditorKey === key;

  desktopStandaloneEditorTargets.delete(key);
  desktopEditorFileCache.delete(key);
  desktopEditorLoadErrors.delete(key);
  desktopEditorLoadingPaths.delete(key);

  if (wasSelected) {
    const remainingKeys = Array.from(desktopStandaloneEditorTargets.keys());
    const nextKey = remainingKeys[Math.min(Math.max(closedIndex, 0), remainingKeys.length - 1)] ?? "";
    selectedEditorKey = nextKey;

    if (!nextKey && editorSurfaceMode !== "preview") {
      setEditorSurface(false);
      return;
    }

    const nextTarget = nextKey ? getEditorTargetByKey(nextKey) : null;
    if (nextTarget && !desktopEditorFileCache.has(nextTarget.key) && !desktopEditorLoadingPaths.has(nextTarget.key)) {
      void ensureEditorFileLoaded(nextTarget);
    }
  }

  renderEditorSurface();
  renderOpenEditors();
  renderContextPanel();
  renderSourceEntries();
}

async function ensureEditorFileLoaded(target: EditorTarget | null) {
  if (!target) {
    return;
  }

  if (!target.path || desktopEditorFileCache.has(target.key) || desktopEditorLoadingPaths.has(target.key)) {
    return;
  }

  desktopEditorLoadingPaths.add(target.key);
  desktopEditorLoadErrors.delete(target.key);
  renderEditorSurface();
  renderOpenEditors();

  try {
    const projectDir = getActiveProjectDirPayload();
    const projectKey = captureProjectRequestKey();
    const payload = isTauri()
      ? await getDesktopEditorFile(target.path, target.worktree || undefined, projectDir)
      : await loadBrowserEditorFile(target.path);
    if (!isProjectRequestCurrent(projectKey)) {
      return;
    }
    desktopEditorFileCache.set(target.key, buildCachedEditorFile(target, payload));
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    desktopEditorLoadErrors.set(target.key, message);
  } finally {
    desktopEditorLoadingPaths.delete(target.key);
    renderEditorSurface();
    renderOpenEditors();
    renderSourceSummary();
    renderContextPanel();
    renderSourceEntries();
    renderRunSummary();
  }
}

async function openEditorTarget(target: EditorTarget | null) {
  if (!target) {
    setEditorSurface(true);
    return;
  }

  editorSurfaceMode = "code";
  selectedPreviewUrl = "";
  lastPreviewExternalState = null;
  desktopStandaloneEditorTargets.set(target.key, target);
  selectedEditorKey = target.key;
  setSelectedRun(target.sourceChange?.run ?? selectedRunId);
  setEditorSurface(true);
  renderSourceSummary();
  renderRunSummary();
  await ensureEditorFileLoaded(target);
}

async function openEditorSourceChange(sourceChange: SourceChange | undefined) {
  await openEditorTarget(getEditorTargetForSourceChange(sourceChange));
}

async function openEditorPath(path: string | undefined, worktree = "") {
  if (!path) {
    await openEditorSourceChange(getPrimarySourceChange(getVisibleSourceChanges()));
    return;
  }

  const sourceChange = findSourceChangeByPath(path, worktree);
  if (sourceChange) {
    setSelectedRun(sourceChange.run);
    await openEditorSourceChange(sourceChange);
    return;
  }

  const target = createStandaloneEditorTarget(path, worktree);
  desktopStandaloneEditorTargets.set(target.key, target);
  editorSurfaceMode = "code";
  selectedPreviewUrl = "";
  lastPreviewExternalState = null;
  selectedEditorKey = target.key;
  setEditorSurface(true);
  renderOpenEditors();
  renderEditorSurface();
  await ensureEditorFileLoaded(target);
}

function inferLanguageFromPath(path: string) {
  if (path.endsWith(".ts")) {
    return "TypeScript";
  }
  if (path.endsWith(".rs")) {
    return "Rust";
  }
  if (path.endsWith(".md")) {
    return "Markdown";
  }
  if (path.endsWith(".css")) {
    return "CSS";
  }
  if (path.endsWith(".html")) {
    return "HTML";
  }
  if (path.endsWith(".svg")) {
    return "SVG";
  }
  if (path.endsWith(".ps1")) {
    return "PowerShell";
  }
  if (path.endsWith(".json")) {
    return "JSON";
  }
  if (path.endsWith(".toml")) {
    return "TOML";
  }
  if (path.endsWith(".yml") || path.endsWith(".yaml")) {
    return "YAML";
  }
  return "Text";
}

function buildDesktopSummaryConversation(snapshot: DesktopSummarySnapshot): ConversationItem[] {
  const board = snapshot.board.summary;
  const digest = snapshot.digest.summary;
  const inbox = snapshot.inbox.summary;
  const topInboxItems = snapshot.inbox.items.slice(0, 2);
  const topDigestItems = snapshot.run_projections.slice(0, 3);

  const items: ConversationItem[] = [
    {
      type: "operator",
      category: "activity",
      timestamp: new Date(snapshot.generated_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: "Operator",
      title: "Summary stream connected",
      body: "Tauri is reading board, notifications, and digest surfaces from the backend adapter instead of treating raw PTY output as the primary UI source.",
      details: [
        { label: "panes", value: `${board.pane_count}` },
        { label: "notifications", value: `${inbox.item_count}` },
        { label: "runs", value: `${digest.item_count}` },
      ],
      tone: "info",
    },
  ];

  for (const topInboxItem of topInboxItems) {
    items.push({
      type: "system",
      category: "attention",
      timestamp: new Date(snapshot.generated_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: topInboxItem.label || topInboxItem.pane_id || "System",
      title: `Notification: ${topInboxItem.kind}`,
      body: topInboxItem.message,
      details: [
        { label: "branch", value: topInboxItem.branch || "no branch" },
        { label: "review", value: topInboxItem.review_state || "n/a" },
        { label: "task", value: topInboxItem.task_state || "n/a" },
      ],
      tone: "warning",
      statusLabel: topInboxItem.kind,
    });
  }

  for (const digestItem of topDigestItems) {
    items.push({
      type: "operator",
      category: digestItem.review_state === "PENDING" || digestItem.review_state === "FAIL" || digestItem.review_state === "FAILED" ? "review" : "activity",
      timestamp: new Date(snapshot.generated_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: digestItem.label || digestItem.pane_id || "Operator",
      title: digestItem.task || "Projected run",
      body: `Next ${digestItem.next_action || "idle"} · ${digestItem.changed_files.length} changed files · review ${digestItem.review_state || "n/a"}.`,
      details: [
        { label: "run", value: digestItem.run_id },
        { label: "branch", value: digestItem.branch || "no branch" },
        { label: "verify", value: digestItem.verification_outcome || "n/a" },
      ],
      tone: digestItem.review_state === "PASS" ? "success" : digestItem.review_state === "PENDING" ? "warning" : "info",
      runId: digestItem.run_id,
      statusLabel: digestItem.review_state || digestItem.next_action || undefined,
      chips: [
        { label: "Open Explain", action: "open-explain" },
        { label: "Source Context", action: "open-source-context" },
      ],
    });
  }

  return items;
}

function pruneExplainCache(snapshot: DesktopSummarySnapshot, preservedRunId?: string | null) {
  const activeRunIds = new Set(snapshot.run_projections.map((projection) => projection.run_id));
  if (preservedRunId) {
    activeRunIds.add(preservedRunId);
  }

  for (const runId of Array.from(desktopExplainCache.keys())) {
    if (!activeRunIds.has(runId)) {
      desktopExplainCache.delete(runId);
    }
  }

  for (const pairKey of Array.from(desktopRunCompareCache.keys())) {
    const [leftRunId, rightRunId] = pairKey.split("::");
    if (!activeRunIds.has(leftRunId) || !activeRunIds.has(rightRunId)) {
      desktopRunCompareCache.delete(pairKey);
    }
  }

  for (const runId of Array.from(promotedRunCandidates.keys())) {
    if (!activeRunIds.has(runId)) {
      promotedRunCandidates.delete(runId);
    }
  }
}

function renderDesktopSurfaces() {
  renderPaneMetadata();
  renderSessions();
  renderFooterLane();
  renderRunSummary();
  renderSourceSummary();
  renderSourceEntries();
  renderSourceControlView();
  renderEvidenceView();
  renderContextPanel();
  renderOpenEditors();
  renderEditorSurface();
  renderConversation(getConversationItems());
}

function formatPaneMetaTime(timestamp: string) {
  const parsed = Date.parse(timestamp);
  if (Number.isNaN(parsed)) {
    return "";
  }

  return new Date(parsed).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
  });
}

function formatPaneWaitDuration(timestamp: string, now = Date.now()) {
  const parsed = Date.parse(timestamp);
  if (Number.isNaN(parsed)) {
    return "";
  }

  const elapsedMs = Math.max(0, now - parsed);
  const elapsedMinutes = Math.floor(elapsedMs / 60000);
  if (elapsedMinutes < 1) {
    return getLanguageText("<1m wait", "1分未満待機");
  }
  if (elapsedMinutes < 60) {
    return getLanguageText(`${elapsedMinutes}m wait`, `${elapsedMinutes}分待機`);
  }

  const hours = Math.floor(elapsedMinutes / 60);
  const minutes = elapsedMinutes % 60;
  if (minutes === 0) {
    return getLanguageText(`${hours}h wait`, `${hours}時間待機`);
  }

  return getLanguageText(`${hours}h ${minutes}m wait`, `${hours}時間${minutes}分待機`);
}

function summarizeBoardPaneStatus(pane: DesktopBoardPane | null) {
  if (!pane) {
    return "";
  }

  const role = pane.role || "pane";
  const taskState = (pane.task_state || "").toLowerCase();
  const reviewState = (pane.review_state || "").toUpperCase();

  if (taskState === "blocked") {
    return getLanguageText(`${role} · blocked`, `${role}・ブロック中`);
  }
  if (reviewState === "FAIL" || reviewState === "FAILED") {
    return getLanguageText(`${role} · review failed`, `${role}・レビュー失敗`);
  }
  if (reviewState === "PENDING") {
    return getLanguageText(`${role} · review pending`, `${role}・レビュー待ち`);
  }
  if (reviewState === "PASS") {
    return getLanguageText(`${role} · review pass`, `${role}・レビュー通過`);
  }
  if (taskState === "commit_ready") {
    return getLanguageText(`${role} · commit ready`, `${role}・コミット可能`);
  }
  if (taskState === "completed" || taskState === "task_completed" || taskState === "done") {
    return getLanguageText(`${role} · completed`, `${role}・完了`);
  }
  if (pane.task_state) {
    return `${role} · ${pane.task_state}`;
  }

  return role;
}

function renderPaneMetadata() {
  const boardPanes = desktopSummarySnapshot?.board.panes ?? [];
  const now = Date.now();

  panes.forEach((pane, paneId) => {
    const paneRecord = boardPanes.find((item) => item.pane_id === paneId) ?? null;
    const paneLabel = getPaneDisplayLabel(paneId, paneRecord?.label);
    pane.labelElement.textContent = paneLabel;

    if (!paneRecord && !pane.ptyStarted) {
      const metaText = pane.ptyStarting
        ? getLanguageText("starting shell", "シェル起動中")
        : getLanguageText("not started", "未起動");
      pane.metaElement.textContent = metaText;
      pane.metaElement.title = metaText;
      pane.labelElement.title = paneId === paneLabel ? paneLabel : `${paneLabel} (${paneId})`;
      return;
    }

    const status = summarizeBoardPaneStatus(paneRecord);
    const branch = paneRecord?.branch || "";
    const eventTime = paneRecord?.last_event_at ? formatPaneMetaTime(paneRecord.last_event_at) : "";
    const waitDuration = paneRecord?.last_event_at
      ? formatPaneWaitDuration(paneRecord.last_event_at, now)
      : pane.lastOutputAt
        ? getLanguageText(`${formatPreviewSeenAt(pane.lastOutputAt)} · live output`, `${formatPreviewSeenAt(pane.lastOutputAt)}・出力あり`)
        : getLanguageText("waiting for summary", "要約待ち");

    const parts = [status];
    if (branch) {
      parts.push(branch);
    }
    if (eventTime) {
      parts.push(eventTime);
    }
    parts.push(waitDuration);
    const metaText = parts.filter((value) => Boolean(value)).join(" · ");
    pane.metaElement.textContent = metaText;
    pane.metaElement.title = metaText;
    pane.labelElement.title = paneId === paneLabel ? paneLabel : `${paneLabel} (${paneId})`;
  });
}

async function refreshDesktopSummary(forceExplainRunId?: string | null) {
  const requestProjectDir = getActiveProjectDirPayload();
  const requestProjectKey = normalizeProjectDirInput(requestProjectDir) || "";
  if (desktopSummaryRefreshInFlight && desktopSummaryRefreshInFlightProjectKey === requestProjectKey) {
    return desktopSummaryRefreshInFlight;
  }

  const requestSequence = ++desktopSummaryRefreshSequence;
  desktopSummaryRefreshInFlightProjectKey = requestProjectKey;
  desktopSummaryRefreshInFlight = (async () => {
  try {
    const previousSnapshot = desktopSummarySnapshot;
    const previousSelectedRunId = selectedRunId;
    const snapshot = await getDesktopSummarySnapshot(requestProjectDir);
    const currentProjectKey = normalizeProjectDirInput(getActiveProjectDirPayload()) || "";
    if (requestSequence !== desktopSummaryRefreshSequence || currentProjectKey !== requestProjectKey) {
      return;
    }
    const snapshotProjectKey = normalizeProjectDirInput(snapshot.project_dir) || "";
    if (requestProjectKey && snapshotProjectKey && snapshotProjectKey !== requestProjectKey) {
      console.warn("Ignoring desktop summary for a different project", {
        requestedProjectDir: requestProjectKey,
        snapshotProjectDir: snapshotProjectKey,
      });
      return;
    }
    if (!activeProjectDir) {
      activeProjectDir = normalizeProjectDirInput(snapshot.project_dir) || null;
      persistActiveProjectDir();
    }
    rememberProjectSession(activeProjectDir ?? snapshot.project_dir);
    const diff = diffDesktopSummarySnapshots(previousSnapshot, snapshot);
    const invalidatedRunIds = new Set([
      ...diff.changedRunIds,
      ...diff.addedRunIds,
      ...diff.removedRunIds,
    ]);
    for (const pairKey of Array.from(desktopRunCompareCache.keys())) {
      const [leftRunId, rightRunId] = pairKey.split("::");
      if (
        invalidatedRunIds.has(leftRunId) ||
        invalidatedRunIds.has(rightRunId)
      ) {
        desktopRunCompareCache.delete(pairKey);
      }
    }
    for (const runId of invalidatedRunIds) {
      promotedRunCandidates.delete(runId);
    }
    desktopSummaryRefreshSerial += 1;
    desktopSummarySnapshot = snapshot;
    desktopSummaryLastSuccessfulRefreshAt = Date.now();
    selectedRunId = resolveSelectedRunId(snapshot, forceExplainRunId);
    pruneExplainCache(snapshot, forceExplainRunId);
    const selectedRunHasMaterialChange = Boolean(
      selectedRunId &&
        (diff.changedRunIds.includes(selectedRunId) || diff.addedRunIds.includes(selectedRunId)),
    );
    const shouldPrefetchExplain =
      Boolean(selectedRunId) &&
      (
        forceExplainRunId === selectedRunId ||
        !previousSnapshot ||
        selectedRunId !== previousSelectedRunId ||
        !desktopExplainCache.has(selectedRunId ?? "") ||
        selectedRunHasMaterialChange
      );
    if (selectedRunId && shouldPrefetchExplain) {
      try {
        const explainPayload = await getDesktopRunExplain(selectedRunId, getActiveProjectDirPayload());
        desktopExplainCache.set(selectedRunId, explainPayload);
      } catch (error) {
        console.warn("Failed to prefetch desktop explain payload", error);
      }
    }

    if (previousSnapshot && !diff.hasMeaningfulChange && !forceExplainRunId && !shouldPrefetchExplain) {
      return;
    }

    backendConversation.splice(0, backendConversation.length, ...buildDesktopSummaryConversation(snapshot));
    for (const item of buildDesktopFollowConversation(previousSnapshot, snapshot)) {
      appendRuntimeConversation(item);
    }
    renderDesktopSurfaces();
    } catch (error) {
      console.warn("Failed to load desktop summary snapshot", error);
    } finally {
      if (requestSequence !== desktopSummaryRefreshSequence) {
        return;
      }
      desktopSummaryRefreshInFlight = null;
      desktopSummaryRefreshInFlightProjectKey = "";
      if (desktopSummaryRefreshRunningVersion < desktopSummaryRefreshRequestedVersion) {
        flushDesktopSummaryRefreshQueue();
      }
    }
  })();

  return desktopSummaryRefreshInFlight;
}

function flushDesktopSummaryRefreshQueue() {
  if (desktopSummaryRefreshInFlight) {
    return;
  }

  if (desktopSummaryRefreshRunningVersion >= desktopSummaryRefreshRequestedVersion) {
    return;
  }

  const queuedRunId = desktopSummaryQueuedRunId;
  desktopSummaryQueuedRunId = null;
  desktopSummaryRefreshRunningVersion = desktopSummaryRefreshRequestedVersion;
  void refreshDesktopSummary(queuedRunId);
}

function requestDesktopSummaryRefresh(forceExplainRunId?: string | null, delayMs = 150) {
  desktopSummaryRefreshRequestedVersion += 1;
  if (forceExplainRunId) {
    desktopSummaryQueuedRunId = forceExplainRunId;
  }
  if (desktopSummaryRefreshTimeout !== null) {
    window.clearTimeout(desktopSummaryRefreshTimeout);
  }

  desktopSummaryRefreshTimeout = window.setTimeout(() => {
    desktopSummaryRefreshTimeout = null;
    if (desktopSummaryRefreshInFlight) {
      return;
    }
    flushDesktopSummaryRefreshQueue();
  }, delayMs);
}

function shouldRunDesktopSummaryFallbackRefresh(now = Date.now()) {
  if (!desktopSummaryLiveRefreshAvailable) {
    return true;
  }

  const lastLiveActivityAt = Math.max(
    desktopSummaryLastSuccessfulRefreshAt,
    desktopSummaryLastStreamSignalAt,
  );
  return now - lastLiveActivityAt >= DESKTOP_SUMMARY_STREAM_STALE_MS;
}

function registerDesktopSummaryFallbackRefresh() {
  if (desktopSummaryFallbackRefreshRegistered) {
    return;
  }

  desktopSummaryFallbackRefreshRegistered = true;

  window.setInterval(() => {
    if (document.visibilityState !== "visible") {
      return;
    }
    if (!shouldRunDesktopSummaryFallbackRefresh()) {
      return;
    }
    requestDesktopSummaryRefresh(undefined, 0);
  }, DESKTOP_SUMMARY_REFRESH_FALLBACK_INTERVAL_MS);

  window.addEventListener("focus", () => {
    if (!shouldRunDesktopSummaryFallbackRefresh()) {
      return;
    }
    requestDesktopSummaryRefresh(undefined, 0);
  });

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") {
      return;
    }
    if (!shouldRunDesktopSummaryFallbackRefresh()) {
      return;
    }
    requestDesktopSummaryRefresh(undefined, 0);
  });
}

function registerDesktopSummaryLiveRefresh() {
  registerDesktopSummaryFallbackRefresh();

  void subscribeToDesktopSummaryRefresh((event) => {
    if (event.source !== "pty") {
      desktopSummaryLastStreamSignalAt = Date.now();
    }
    requestDesktopSummaryRefresh(event.run_id, 0);
  }).then(() => {
    desktopSummaryLiveRefreshAvailable = true;
  }).catch((error) => {
    console.warn("Failed to subscribe to desktop summary refresh events", error);
    desktopSummaryLiveRefreshAvailable = false;
  });
}

function initializeSidebarResize() {
  const appShell = document.getElementById("app-shell");
  const handle = document.getElementById("sidebar-resizer");
  if (!appShell || !handle) {
    return;
  }

  appShell.style.setProperty("--sidebar-width", `${sidebarWidth}px`);

  handle.addEventListener("pointerdown", (event) => {
    const startX = event.clientX;
    const startWidth = sidebarWidth;
    const onMove = (moveEvent: PointerEvent) => {
      sidebarWidth = Math.max(240, Math.min(380, startWidth + (moveEvent.clientX - startX)));
      appShell.style.setProperty("--sidebar-width", `${sidebarWidth}px`);
    };
    const onUp = () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
      void persistThemeState();
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  });
}

function initializeWorkbenchResize() {
  const handle = document.getElementById("workbench-resizer");
  const drawer = document.getElementById("terminal-drawer");
  if (!handle || !drawer) {
    return;
  }

  const setWidthFromKeyboard = (delta: number) => {
    const currentWidth = workbenchWidth ?? drawer.getBoundingClientRect().width;
    applyWorkbenchWidth(currentWidth + delta);
    void persistThemeState();
  };

  handle.setAttribute("aria-valuemin", "320");
  handle.setAttribute("aria-valuemax", "1600");
  if (workbenchWidth !== null) {
    handle.setAttribute("aria-valuenow", `${workbenchWidth}`);
  }

  handle.addEventListener("keydown", (event) => {
    if (event.key === "ArrowLeft") {
      event.preventDefault();
      setWidthFromKeyboard(32);
      return;
    }
    if (event.key === "ArrowRight") {
      event.preventDefault();
      setWidthFromKeyboard(-32);
      return;
    }
    if (event.key === "Home") {
      event.preventDefault();
      applyWorkbenchWidth(320);
      void persistThemeState();
      return;
    }
  });

  handle.addEventListener("pointerdown", (event) => {
    if (!terminalDrawerOpen || isNarrowLayout()) {
      return;
    }
    event.preventDefault();
    handle.setPointerCapture?.(event.pointerId);
    document.body.classList.add("is-resizing-workbench");
    const startX = event.clientX;
    const startWidth = drawer.getBoundingClientRect().width;
    const onMove = (moveEvent: PointerEvent) => {
      applyWorkbenchWidth(startWidth + (startX - moveEvent.clientX));
    };
    const onUp = () => {
      document.body.classList.remove("is-resizing-workbench");
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
      window.removeEventListener("pointercancel", onUp);
      void persistThemeState();
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
    window.addEventListener("pointercancel", onUp);
  });
}

function initializeSourceControlSplitResize() {
  const handle = document.getElementById("source-control-splitter");
  if (!handle) {
    return;
  }

  handle.setAttribute("aria-valuemin", "96");
  handle.setAttribute("aria-valuemax", "900");
  applySourceControlSplitHeight();

  const setHeightFromKeyboard = (delta: number) => {
    sourceControlChangesHeight = clampSourceControlChangesHeight(sourceControlChangesHeight + delta);
    applySourceControlSplitHeight();
  };

  handle.addEventListener("keydown", (event) => {
    if (event.key === "ArrowUp") {
      event.preventDefault();
      setHeightFromKeyboard(-24);
      return;
    }
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setHeightFromKeyboard(24);
      return;
    }
    if (event.key === "Home") {
      event.preventDefault();
      sourceControlChangesHeight = 96;
      applySourceControlSplitHeight();
      return;
    }
    if (event.key === "End") {
      event.preventDefault();
      sourceControlChangesHeight = clampSourceControlChangesHeight(900);
      applySourceControlSplitHeight();
    }
  });

  handle.addEventListener("pointerdown", (event) => {
    event.preventDefault();
    handle.setPointerCapture?.(event.pointerId);
    const startY = event.clientY;
    const startHeight = sourceControlChangesHeight;
    const onMove = (moveEvent: PointerEvent) => {
      sourceControlChangesHeight = clampSourceControlChangesHeight(startHeight + (moveEvent.clientY - startY));
      applySourceControlSplitHeight();
    };
    const onUp = () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
      window.removeEventListener("pointercancel", onUp);
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
    window.addEventListener("pointercancel", onUp);
  });
}

window.addEventListener("DOMContentLoaded", async () => {
  installViewportHarnessHooks();
  const popoutSurfaceState = readPopoutSurfaceState();

  const storedShellPreferences = readStoredShellPreferences();
  if (storedShellPreferences) {
    applyThemeState(storedShellPreferences);
    sidebarWidth = storedShellPreferences.sidebarWidth;
    workbenchWidth = storedShellPreferences.workbenchWidth;
    preferredWideSidebarOpen = storedShellPreferences.wideSidebarOpen;
    preferredWideContextOpen = storedShellPreferences.wideContextOpen;
    terminalDrawerOpen = true;
    workbenchLayout = storedShellPreferences.workbenchLayout;
    focusedWorkbenchPaneId = storedShellPreferences.focusedWorkbenchPaneId;
  }

  void subscribeToPtyOutput((payload) => {
    if (payload.pane_id === OPERATOR_PTY_ID) {
      appendOperatorPtyOutput(payload.data);
      return;
    }
    registerPreviewTargets(payload.pane_id, payload.data);
    const entry = payload.pane_id ? panes.get(payload.pane_id) : undefined;
    if (entry) {
      entry.lastOutputAt = Date.now();
      entry.terminal.write(payload.data);
      renderPaneMetadata();
      return;
    }

    if (payload.pane_id) {
      return;
    }

    const first = panes.values().next().value as PaneEntry | undefined;
    if (first) {
      first.lastOutputAt = Date.now();
      first.terminal.write(payload.data);
      renderPaneMetadata();
    }
  }).catch((error) => {
    console.warn("Failed to subscribe to PTY output events", error);
  });

  renderSessions();
  renderExplorer();
  void refreshProjectExplorerEntries();
  void refreshBrowserSourceControl();
  renderOpenEditors();
  renderSourceSummary();
  renderSourceEntries();
  renderEvidenceView();
  renderContextPanel();
  applyShellPreferences();
  applyLanguageChrome();
  renderSettingsControls();
  renderFooterLane();
  renderTimelineFilters();
  renderRunSummary();
  renderConversation(getConversationItems());
  renderComposerModes();
  renderComposerSlashCommands();
  renderComposerRemoteReferences();
  renderAttachmentTray();
  renderCommandBar();
  renderEditorSurface();
  syncResponsiveShell();
  setEditorSurface(false);
  setTerminalDrawer(true);
  applyPopoutSurfaceState(popoutSurfaceState);
  registerDesktopSummaryLiveRefresh();
  void refreshDesktopSummary();
  initializeSidebarResize();
  initializeWorkbenchResize();
  initializeSourceControlSplitResize();
  window.setInterval(() => {
    renderPaneMetadata();
  }, PANE_META_REFRESH_INTERVAL_MS);

  for (const menuButton of document.querySelectorAll<HTMLButtonElement>(".menu-bar-item")) {
    menuButton.setAttribute("aria-haspopup", "menu");
    menuButton.setAttribute("aria-expanded", "false");
    menuButton.addEventListener("click", (event) => {
      event.stopPropagation();
      openTopMenu(menuButton.id);
    });
  }

  document.getElementById("toggle-sidebar-btn")?.addEventListener("click", () => {
    setSidebarOpen(!sidebarOpen);
  });

  document.getElementById("activity-explorer-btn")?.addEventListener("click", () => {
    if (sidebarOpen && sidebarMode === "explorer") {
      setSidebarOpen(false);
      return;
    }
    setSidebarMode("explorer");
    setSidebarOpen(true);
  });

  document.getElementById("activity-search-btn")?.addEventListener("click", () => {
    openCommandBar();
  });

  document.getElementById("activity-source-btn")?.addEventListener("click", () => {
    if (sidebarOpen && sidebarMode === "source") {
      setSidebarOpen(false);
      return;
    }
    setSidebarMode("source");
    setSidebarOpen(true);
  });

  document.getElementById("activity-evidence-btn")?.addEventListener("click", () => {
    if (sidebarOpen && sidebarMode === "evidence") {
      setSidebarOpen(false);
      return;
    }
    setSidebarMode("evidence");
    setSidebarOpen(true);
  });

  document.getElementById("activity-context-btn")?.addEventListener("click", () => {
    setContextPanel(!contextPanelOpen);
  });

  document.getElementById("open-command-bar-btn")?.addEventListener("click", () => {
    if (commandBarOpen) {
      closeCommandBar();
      return;
    }
    openCommandBar();
  });

  document.getElementById("toggle-terminal-btn")?.addEventListener("click", () => {
    setTerminalDrawer(!terminalDrawerOpen);
  });

  document.getElementById("browser-reload-btn")?.addEventListener("click", () => {
    reloadPreviewTarget();
  });

  document.getElementById("browser-back-btn")?.addEventListener("click", () => {
    closePreviewTarget();
  });

  document.getElementById("browser-copy-btn")?.addEventListener("click", async () => {
    await copyPreviewTargetUrl();
  });

  document.getElementById("browser-open-btn")?.addEventListener("click", () => {
    openPreviewTargetExternally();
  });

  document.getElementById("toggle-context-btn")?.addEventListener("click", () => {
    setContextPanel(!contextPanelOpen);
  });

  document.getElementById("close-editor-btn")?.addEventListener("click", async () => {
    if (document.body.dataset.popoutSurface === "1") {
      if (isTauri()) {
        await getCurrentWebviewWindow().close();
        return;
      }
      window.close();
      return;
    }
    setEditorSurface(false);
  });

  document.getElementById("popout-editor-btn")?.addEventListener("click", async () => {
    await openEditorSurfacePopout();
  });

  document.getElementById("activity-settings-btn")?.addEventListener("click", () => {
    setSettingsSheet(true);
  });

  const sourceControlMessageInput = document.getElementById("source-control-message") as HTMLTextAreaElement | null;
  sourceControlMessageInput?.addEventListener("input", () => {
    updateSourceControlCommitButton();
  });

  document.getElementById("source-control-commit-btn")?.addEventListener("click", () => {
    submitSourceControlCommitRequest();
  });

  document.getElementById("source-control-title-commit-btn")?.addEventListener("click", () => {
    submitSourceControlCommitRequest();
  });

  for (const refreshButtonId of ["source-control-refresh-btn", "source-control-graph-refresh-btn", "source-control-graph-fetch-btn"]) {
    document.getElementById(refreshButtonId)?.addEventListener("click", () => {
      void refreshBrowserSourceControl();
      requestDesktopSummaryRefresh(undefined, 0);
    });
  }

  document.getElementById("source-control-more-btn")?.addEventListener("click", (event) => {
    showSourceControlActionsMenu(event, "changes");
  });
  document.getElementById("source-control-graph-more-btn")?.addEventListener("click", (event) => {
    showSourceControlActionsMenu(event, "graph");
  });

  document.getElementById("apply-settings-btn")?.addEventListener("click", () => {
    void applySettingsDraft();
  });

  document.getElementById("close-settings-btn")?.addEventListener("click", () => {
    cancelSettingsDraft();
  });

  initializeSettingsDialogControls();

  document.getElementById("sidebar-overlay")?.addEventListener("click", () => {
    setSidebarOpen(false);
  });

  document.getElementById("command-bar-backdrop")?.addEventListener("click", () => {
    closeCommandBar();
  });

  document.addEventListener("click", (event) => {
    if (!openTopMenuId) {
      return;
    }
    const target = event.target;
    if (!(target instanceof Node)) {
      return;
    }
    const popover = document.getElementById("top-menu-popover");
    const button = document.getElementById(openTopMenuId);
    if (popover?.contains(target) || button?.contains(target)) {
      return;
    }
    closeTopMenu();
  });

  document.getElementById("command-bar")?.addEventListener("keydown", (event) => {
    trapCommandBarTab(event);
  });

  const commandBarInput = document.getElementById("command-bar-input") as HTMLInputElement | null;
  commandBarInput?.addEventListener("compositionstart", () => {
    commandBarImeActive = true;
  });

  commandBarInput?.addEventListener("compositionend", () => {
    commandBarImeActive = false;
  });

  commandBarInput?.addEventListener("input", () => {
    commandBarQuery = commandBarInput.value;
    selectedCommandIndex = 0;
    renderCommandBar();
  });

  commandBarInput?.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      const actions = getFilteredCommandActions();
      if (actions.length === 0) {
        return;
      }
      selectedCommandIndex = (selectedCommandIndex + 1) % actions.length;
      renderCommandBar();
      return;
    }

    if (event.key === "ArrowUp") {
      event.preventDefault();
      const actions = getFilteredCommandActions();
      if (actions.length === 0) {
        return;
      }
      selectedCommandIndex = (selectedCommandIndex - 1 + actions.length) % actions.length;
      renderCommandBar();
      return;
    }

    if (event.key === "Enter") {
      if (commandBarImeActive || event.isComposing) {
        return;
      }
      event.preventDefault();
      executeSelectedCommand();
      return;
    }

    if (event.key === "Escape") {
      event.preventDefault();
      closeCommandBar();
    }
  });

  document.getElementById("add-pane-btn")?.addEventListener("click", () => {
    if (!terminalDrawerOpen) {
      setTerminalDrawer(true);
    }
    createPane();
  });

  document.getElementById("workbench-layout-btn")?.addEventListener("click", () => {
    cycleWorkbenchLayout();
  });

  document.getElementById("focused-pane-select")?.addEventListener("change", (event) => {
    const value = (event.currentTarget as HTMLSelectElement).value;
    if (!panes.has(value)) {
      return;
    }
    focusedWorkbenchPaneId = value;
    updateWorkbenchControls();
    void persistThemeState();
    requestAnimationFrame(() => {
      fitVisibleWorkbenchPanes();
    });
  });

  const composer = document.getElementById("composer") as HTMLFormElement | null;
  const composerInput = document.getElementById("composer-input") as HTMLTextAreaElement | null;
  const composerFileInput = document.getElementById("composer-file-input") as HTMLInputElement | null;
  const attachButton = document.getElementById("attach-btn") as HTMLButtonElement | null;
  const voiceInputButton = document.getElementById("voice-input-btn") as HTMLButtonElement | null;
  const interruptOperatorButton = document.getElementById("interrupt-operator-btn") as HTMLButtonElement | null;
  if (composer && composerInput) {
    ensureVoiceCaptureStatusRefresh();

    voiceInputButton?.addEventListener("click", () => {
      toggleVoiceInput(composerInput);
    });

    composerInput.addEventListener("compositionstart", () => {
      composerImeActive = true;
    });

    composerInput.addEventListener("compositionend", () => {
      composerImeActive = false;
    });

    composerInput.addEventListener("keydown", (event) => {
      const slashCommands = getVisibleComposerSlashCommands();
      const composerImeBlocking = composerImeActive || event.isComposing;
      const composerSuggestionOpen = composerSlashOpen || composerWinsmuxCommandOpen;
      if (!composerImeBlocking && isComposerTypingKey(event)) {
        markComposerInputSource("keyboard");
      }
      if (event.key === "ArrowUp" && !composerImeBlocking && !event.shiftKey && !event.ctrlKey && !event.metaKey && !event.altKey && !composerSuggestionOpen && composerHistory.length > 0 && isComposerSelectionCollapsed(composerInput) && isCaretOnFirstLine(composerInput)) {
        event.preventDefault();
        stepComposerHistory(-1);
        return;
      }

      if (event.key === "ArrowDown" && !composerImeBlocking && !event.shiftKey && !event.ctrlKey && !event.metaKey && !event.altKey && !composerSuggestionOpen && composerHistoryIndex !== -1 && isComposerSelectionCollapsed(composerInput) && isCaretOnLastLine(composerInput)) {
        event.preventDefault();
        stepComposerHistory(1);
        return;
      }

      if (event.key === "ArrowDown" && !composerImeBlocking && slashCommands.length > 0) {
        event.preventDefault();
        selectedComposerSlashIndex = (selectedComposerSlashIndex + 1) % slashCommands.length;
        renderComposerSlashCommands();
        return;
      }

      if (event.key === "ArrowUp" && !composerImeBlocking && slashCommands.length > 0) {
        event.preventDefault();
        selectedComposerSlashIndex = (selectedComposerSlashIndex - 1 + slashCommands.length) % slashCommands.length;
        renderComposerSlashCommands();
        return;
      }

      if (event.key === "Tab" && !composerImeBlocking && event.shiftKey && !event.ctrlKey && !event.metaKey && !event.altKey) {
        event.preventDefault();
        stepComposerPermissionMode(-1);
        return;
      }

      if (event.key === "Tab" && !composerImeBlocking && !event.shiftKey && !event.ctrlKey && !event.metaKey && !event.altKey) {
        event.preventDefault();
        if (slashCommands.length > 0) {
          markComposerInputSource("shortcut");
          applyComposerSlashCommand(slashCommands[selectedComposerSlashIndex] ?? slashCommands[0]);
          return;
        }
        insertComposerTab(composerInput);
        syncComposerSlashState(composerInput.value);
        exitComposerHistoryToDraft(composerInput.value);
        return;
      }

      if (event.key !== "Enter") {
        return;
      }

      if (event.shiftKey || composerImeActive || event.isComposing) {
        return;
      }

      event.preventDefault();
      composer.requestSubmit();
    });

    composerInput.addEventListener("input", () => {
      if (composerHistoryIndex !== -1) {
        composerHistoryIndex = -1;
      }
      syncComposerInputHeight(composerInput);
      syncComposerDraftState(composerInput.value);
      syncComposerSlashState(composerInput.value);
    });

    composerInput.addEventListener("paste", (event) => {
      markComposerInputSource("paste");
      const attachmentFiles = getClipboardAttachmentFiles(event.clipboardData);

      if (attachmentFiles.length > 0) {
        event.preventDefault();
        appendAttachments(attachmentFiles);
        return;
      }

      if (event.clipboardData?.types.includes("text/plain")) {
        return;
      }

      event.preventDefault();
      void readClipboardImageFiles().then((files) => {
        appendAttachments(files);
      });
    });

    composerInput.addEventListener("dragover", (event) => {
      if (event.dataTransfer?.files?.length) {
        event.preventDefault();
      }
    });

    composerInput.addEventListener("drop", (event) => {
      const files = Array.from(event.dataTransfer?.files ?? []);
      if (files.length === 0) {
        return;
      }

      event.preventDefault();
      appendAttachments(files);
    });

    composer.addEventListener("submit", (event) => {
      event.preventDefault();
      const slashModeCommand = getComposerModeSlashCommand(composerInput.value);
      if (slashModeCommand) {
        applyComposerSlashCommand(slashModeCommand);
        return;
      }
      if (voiceListening) {
        stopVoiceInput();
      }
      const rawValue = composerInput.value;
      const value = rawValue.trim();
      const selectedRemoteReferences = getComposerRemoteReferences().filter((item) => selectedComposerRemoteReferenceIds.has(item.id));
      if (!value && pendingAttachments.length === 0 && selectedRemoteReferences.length === 0) {
        return;
      }
      const historyEntry = captureComposerHistoryEntry(rawValue);
      const submittedAttachments = [
        ...pendingAttachments,
        ...selectedRemoteReferences.map((item) => ({
          id: item.id,
          name: item.label,
          kind: "file" as const,
          sizeLabel: item.meta,
          file: new File([], item.label),
        })),
      ];
      appendUserMessage(rawValue, submittedAttachments);
      pushComposerHistoryEntry(historyEntry);
      composerInput.value = "";
      syncComposerInputHeight(composerInput);
      syncComposerSlashState(composerInput.value);
      clearPendingAttachments();
      selectedComposerRemoteReferenceIds.clear();
      renderComposerRemoteReferences();
      renderAttachmentTray();
      requestDesktopSummaryRefresh(undefined, 750);
    });

    syncComposerInputHeight(composerInput);
  }

  attachButton?.addEventListener("click", () => {
    composerFileInput?.click();
  });

  interruptOperatorButton?.addEventListener("click", () => {
    void interruptOperatorRequest();
  });

  document.addEventListener("click", (event) => {
    if (!openComposerSessionMenu) {
      return;
    }
    const root = document.getElementById("composer-session-row");
    if (root && event.target instanceof Node && root.contains(event.target)) {
      return;
    }
    openComposerSessionMenu = null;
    renderComposerSessionControls();
  });

  composerFileInput?.addEventListener("change", () => {
    const files = Array.from(composerFileInput.files ?? []);
    appendAttachments(files);
    composerFileInput.value = "";
  });

  window.addEventListener("keydown", (event) => {
    const keyTarget = event.target;
    const settingsSheet = document.getElementById("settings-sheet");
    const keyInsideSettings = keyTarget instanceof Node && Boolean(settingsSheet?.contains(keyTarget));
    if (composerInput && !keyInsideSettings && !commandBarOpen && !event.isComposing && !composerImeActive && isVoiceShortcutEvent(event)) {
      event.preventDefault();
      toggleVoiceInput(composerInput);
      return;
    }

    if (event.ctrlKey && event.key.toLowerCase() === "k") {
      event.preventDefault();
      if (commandBarOpen) {
        closeCommandBar();
      } else {
        openCommandBar();
      }
      return;
    }

    if (event.key === "Escape" && commandBarOpen) {
      event.preventDefault();
      closeCommandBar();
      return;
    }

    if (event.key === "Escape" && openTopMenuId) {
      event.preventDefault();
      closeTopMenu();
      return;
    }

    if (event.key === "Escape" && explorerContextMenu) {
      event.preventDefault();
      closeExplorerContextMenu();
      return;
    }

    if (event.key === "Escape" && openComposerSessionMenu) {
      event.preventDefault();
      openComposerSessionMenu = null;
      renderComposerSessionControls();
      return;
    }

    if (event.key === "Escape" && operatorRequestActive && !operatorInterruptInFlight && !keyInsideSettings) {
      event.preventDefault();
      void interruptOperatorRequest();
      return;
    }

    if ((event.ctrlKey || event.metaKey) && event.key === ",") {
      event.preventDefault();
      setSettingsSheet(true);
    }
  });

  window.addEventListener("resize", () => {
    syncResponsiveShell();
    syncComposerInputHeight();
    fitVisibleWorkbenchPanes();
  });

  window.addEventListener("beforeunload", () => {
    stopVoiceInput();
  });
});
