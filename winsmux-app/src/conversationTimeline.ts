import type { DesktopSummarySnapshot } from "./desktopClient";

export type ChipAction =
  | "open-explain"
  | "open-editor"
  | "open-source-context"
  | "toggle-context"
  | "open-terminal";

export type TimelineFilter = "all" | "attention" | "review" | "activity";
export type ConversationCategory = "user" | "attention" | "review" | "activity";
export type SurfaceTone = "default" | "accent" | "success" | "warning" | "danger" | "info" | "focus";

export interface ConversationChip {
  label: string;
  action: ChipAction;
}

export interface ConversationDetail {
  label: string;
  value: string;
}

export interface ConversationItem {
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

export interface BuildDesktopSummaryConversationOptions {
  formatTimestamp?: (value: string) => string;
}

export function formatDesktopSummaryConversationTimestamp(value: string) {
  return new Date(value).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

function getDigestConversationCategory(reviewState: string): ConversationCategory {
  return reviewState === "PENDING" || reviewState === "FAIL" || reviewState === "FAILED"
    ? "review"
    : "activity";
}

function getDigestConversationTone(reviewState: string): SurfaceTone {
  return reviewState === "PASS" ? "success" : reviewState === "PENDING" ? "warning" : "info";
}

export function buildDesktopSummaryConversation(
  snapshot: DesktopSummarySnapshot,
  options: BuildDesktopSummaryConversationOptions = {},
): ConversationItem[] {
  const board = snapshot.board.summary;
  const digest = snapshot.digest.summary;
  const inbox = snapshot.inbox.summary;
  const topInboxItems = snapshot.inbox.items.slice(0, 2);
  const topDigestItems = snapshot.run_projections.slice(0, 3);
  const timestamp = (options.formatTimestamp ?? formatDesktopSummaryConversationTimestamp)(snapshot.generated_at);

  const items: ConversationItem[] = [
    {
      type: "operator",
      category: "activity",
      timestamp,
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
      timestamp,
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
      category: getDigestConversationCategory(digestItem.review_state),
      timestamp,
      actor: digestItem.label || digestItem.pane_id || "Operator",
      title: digestItem.task || "Projected run",
      body: `Next ${digestItem.next_action || "idle"} · ${digestItem.changed_files.length} changed files · review ${digestItem.review_state || "n/a"}.`,
      details: [
        { label: "run", value: digestItem.run_id },
        { label: "branch", value: digestItem.branch || "no branch" },
        { label: "verify", value: digestItem.verification_outcome || "n/a" },
      ],
      tone: getDigestConversationTone(digestItem.review_state),
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

export function getVisibleConversationItems(items: ConversationItem[], filter: TimelineFilter) {
  switch (filter) {
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

export function shouldShowTimelineDetails(
  item: ConversationItem,
  focusMode: string,
  selectedRunId?: string | null,
) {
  if (focusMode !== "focused") {
    return true;
  }

  if (item.category === "attention" || item.category === "review") {
    return true;
  }

  return Boolean(item.runId && item.runId === selectedRunId);
}
