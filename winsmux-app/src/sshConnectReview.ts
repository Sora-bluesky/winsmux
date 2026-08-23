import "./sshConnectReview.css";

import { invoke } from "@tauri-apps/api/core";
import { SSH_CONNECT_REVIEW_SECTION_ID } from "./settingsNavigation.ts";

export { SSH_CONNECT_REVIEW_SECTION_ID };

type ReviewAction = "inspect" | "confirm" | "runtime" | "stop";
type HostState = "not_found" | "pending" | "registered" | "blocked";
type RuntimeState = "unavailable" | "handshake_confirmed" | "stopped";

interface ReviewResponse {
  ok: boolean;
  action: ReviewAction;
  hostState?: HostState;
  confirmedFingerprint?: string;
  presentedFingerprint?: string;
  runtimeState?: RuntimeState;
  errorCode?: string;
}

interface ReviewLabels {
  nav: string;
  title: string;
  intro: string;
  host: string;
  hostDescription: string;
  alias: string;
  aliasPlaceholder: string;
  inspect: string;
  identity: string;
  identityDescription: string;
  confirmedFingerprint: string;
  presentedFingerprint: string;
  unavailable: string;
  runtime: string;
  runtimeDescription: string;
  verifyHandshake: string;
  stopRuntime: string;
  scope: string;
  scopeDescription: string;
  workspaceRoot: string;
  workspacePlaceholder: string;
  permission: string;
  permissionReadOnly: string;
  permissionReadWrite: string;
  proposalOnly: string;
  review: string;
  reviewDescription: string;
  exactPreview: string;
  registerCondition: string;
  confirm: string;
  retry: string;
  safeStop: string;
  notInspected: string;
  hostNotFound: string;
  hostPending: string;
  hostRegistered: string;
  hostBlocked: string;
  aliasRequired: string;
  runtimeUnavailable: string;
  runtimeRunning: string;
  runtimeConfirmed: string;
  runtimeStopped: string;
  noWrites: string;
  confirmComplete: string;
  confirmBlocked: string;
  confirmPartiallyApplied: string;
  actionFailed: string;
}

const labels: Record<"en" | "ja", ReviewLabels> = {
  en: {
    nav: "SSH connection review",
    title: "SSH connection review",
    intro: "Review HostProfile trust and a handshake before any future session launch.",
    host: "Host",
    hostDescription: "Inspect the existing HostProfile record without changing it.",
    alias: "OpenSSH alias",
    aliasPlaceholder: "Configured Host alias",
    inspect: "Inspect status",
    identity: "Identity",
    identityDescription: "Only HostProfile fingerprints are shown. Agent keys are deferred.",
    confirmedFingerprint: "Confirmed fingerprint",
    presentedFingerprint: "Presented fingerprint",
    unavailable: "Unavailable until a confirmed check returns it",
    runtime: "Runtime",
    runtimeDescription: "Verify only the Hello/Welcome handshake. No PTY or session is started.",
    verifyHandshake: "Verify handshake",
    stopRuntime: "Stop runtime check",
    scope: "Scope",
    scopeDescription: "Draft the intended workspace and permission for review.",
    workspaceRoot: "Workspace root proposal",
    workspacePlaceholder: "Proposal only; not sent or saved",
    permission: "Permission proposal",
    permissionReadOnly: "Read-only proposal",
    permissionReadWrite: "Read/write proposal",
    proposalOnly: "Proposal only — not saved, enforced, or sent to the backend.",
    review: "Review",
    reviewDescription: "Confirm the only possible HostProfile changes. Nothing else is written.",
    exactPreview: "Exact argv preview",
    registerCondition: "only if check returns pending",
    confirm: "Confirm check, then register if pending",
    retry: "Retry status inspect",
    safeStop: "Safe stop",
    notInspected: "Not inspected. No subprocess has run.",
    hostNotFound: "No local HostProfile record.",
    hostPending: "HostProfile is pending explicit confirmation.",
    hostRegistered: "HostProfile is registered.",
    hostBlocked: "HostProfile is blocked. Register will not run.",
    aliasRequired: "Enter a configured OpenSSH alias.",
    runtimeUnavailable: "Handshake is unavailable until HostProfile is registered.",
    runtimeRunning: "Handshake check is running. Safe stop remains available.",
    runtimeConfirmed: "Hello/Welcome handshake confirmed; the request child was reaped.",
    runtimeStopped: "The request child was stopped and reaped.",
    noWrites: "No HostProfile writes have run.",
    confirmComplete: "Review confirmation completed using the displayed argv sequence.",
    confirmBlocked: "Check returned blocked; register was not run.",
    confirmPartiallyApplied: "Check recorded a pending HostProfile state; register did not complete.",
    actionFailed: "Action failed without exposing subprocess output.",
  },
  ja: {
    nav: "SSH 接続レビュー",
    title: "SSH 接続レビュー",
    intro: "将来のセッション起動より前に、HostProfile の信頼状態とhandshakeを確認します。",
    host: "ホスト",
    hostDescription: "既存の HostProfile レコードを変更せずに確認します。",
    alias: "OpenSSH エイリアス",
    aliasPlaceholder: "設定済みの Host エイリアス",
    inspect: "状態を確認",
    identity: "識別情報",
    identityDescription: "HostProfile のfingerprintだけを表示します。agent keyは後続カットです。",
    confirmedFingerprint: "確認済みfingerprint",
    presentedFingerprint: "提示されたfingerprint",
    unavailable: "明示確認したcheckが返すまでは利用不可",
    runtime: "実行環境",
    runtimeDescription: "Hello/Welcome handshakeだけを確認します。PTYやセッションは起動しません。",
    verifyHandshake: "Handshake を確認",
    stopRuntime: "実行確認を停止",
    scope: "範囲",
    scopeDescription: "確認用にworkspaceとpermissionの案を作ります。",
    workspaceRoot: "Workspace root の案",
    workspacePlaceholder: "案のみ。送信・保存しません",
    permission: "Permission の案",
    permissionReadOnly: "読み取り専用案",
    permissionReadWrite: "読み書き案",
    proposalOnly: "案のみです。保存・強制・backend送信は行いません。",
    review: "最終確認",
    reviewDescription: "起こり得る HostProfile 変更だけを確認します。それ以外は書き込みません。",
    exactPreview: "正確なargvプレビュー",
    registerCondition: "check が pending を返した場合のみ",
    confirm: "Checkを確認し、pendingの場合だけregister",
    retry: "状態確認を再試行",
    safeStop: "安全に停止",
    notInspected: "未確認です。subprocessはまだ実行していません。",
    hostNotFound: "ローカル HostProfile レコードはありません。",
    hostPending: "HostProfile は明示確認待ちです。",
    hostRegistered: "HostProfile は登録済みです。",
    hostBlocked: "HostProfile はblockedです。registerは実行しません。",
    aliasRequired: "設定済みの OpenSSH エイリアスを入力してください。",
    runtimeUnavailable: "HostProfile登録後にhandshakeを確認できます。",
    runtimeRunning: "Handshake確認中です。安全停止は利用できます。",
    runtimeConfirmed: "Hello/Welcomeを確認し、request childをreapしました。",
    runtimeStopped: "Request childを停止してreapしました。",
    noWrites: "HostProfileへの書き込みはまだ実行していません。",
    confirmComplete: "表示したargv順序で確認処理が完了しました。",
    confirmBlocked: "Checkがblockedを返したため、registerは実行していません。",
    confirmPartiallyApplied: "checkによりHostProfileをpendingとして記録しましたが、registerは完了しませんでした。",
    actionFailed: "Subprocess出力を表示せず、安全に失敗しました。",
  },
};

interface MountedReview {
  requestId: string;
  hostState: HostState | null;
  confirmedFingerprint: string | null;
  presentedFingerprint: string | null;
  runtimeState: RuntimeState | null;
  runtimeBusy: boolean;
  confirmBusy: boolean;
  confirmGeneration: number;
}

let mountedReview: MountedReview | null = null;
let languageObserver: MutationObserver | null = null;

function currentLabels() {
  const language = document.documentElement.getAttribute("lang")?.toLowerCase();
  return labels[language?.startsWith("ja") ? "ja" : "en"];
}

function createElement<K extends keyof HTMLElementTagNameMap>(
  tagName: K,
  className = "",
  id = "",
): HTMLElementTagNameMap[K] {
  const element = document.createElement(tagName);
  element.className = className;
  element.id = id;
  return element;
}

function createText<K extends keyof HTMLElementTagNameMap>(
  tagName: K,
  className: string,
  id: string,
): HTMLElementTagNameMap[K] {
  return createElement(tagName, className, id);
}

function createReviewStep(key: string) {
  const step = createElement("div", "ssh-connect-review-step");
  step.dataset.step = key;
  const heading = createText("h3", "ssh-connect-review-heading", `ssh-connect-review-${key}-heading`);
  heading.dataset.sshConnectReviewHeading = key;
  step.append(heading);
  return step;
}

function createButton(id: string, className = "ghost-btn ghost-btn-small") {
  const button = createElement("button", className, id);
  button.type = "button";
  return button;
}

function setText(id: string, value: string) {
  const element = document.getElementById(id);
  if (element) {
    element.textContent = value;
  }
}

function createReviewSection() {
  const section = createElement("section", "settings-section ssh-connect-review", SSH_CONNECT_REVIEW_SECTION_ID);
  const title = createText("div", "context-label", "ssh-connect-review-title");
  const intro = createText("div", "context-value", "ssh-connect-review-intro");
  const grid = createElement("div", "ssh-connect-review-grid");

  const host = createReviewStep("host");
  const hostDescription = createText("p", "ssh-connect-review-description", "ssh-connect-review-host-description");
  const aliasLabel = createText("label", "settings-field-label", "ssh-connect-review-alias-label");
  aliasLabel.setAttribute("for", "ssh-connect-review-alias");
  const aliasInput = createElement("input", "settings-text-input", "ssh-connect-review-alias");
  aliasInput.type = "text";
  aliasInput.setAttribute("autocomplete", "off");
  aliasInput.setAttribute("spellcheck", "false");
  const hostActions = createElement("div", "ssh-connect-review-actions");
  const inspectButton = createButton("ssh-connect-review-inspect");
  const hostStatus = createText("p", "ssh-connect-review-status", "ssh-connect-review-host-status");
  hostStatus.setAttribute("aria-live", "polite");
  hostActions.append(inspectButton);
  host.append(hostDescription, aliasLabel, aliasInput, hostActions, hostStatus);

  const identity = createReviewStep("identity");
  const identityDescription = createText("p", "ssh-connect-review-description", "ssh-connect-review-identity-description");
  const fingerprintList = createElement("dl", "ssh-connect-review-fingerprints");
  const confirmedLabel = createText("dt", "ssh-connect-review-term", "ssh-connect-review-confirmed-label");
  const confirmedValue = createText("dd", "ssh-connect-review-fingerprint", "ssh-connect-review-confirmed-value");
  const presentedLabel = createText("dt", "ssh-connect-review-term", "ssh-connect-review-presented-label");
  const presentedValue = createText("dd", "ssh-connect-review-fingerprint", "ssh-connect-review-presented-value");
  fingerprintList.append(confirmedLabel, confirmedValue, presentedLabel, presentedValue);
  identity.append(identityDescription, fingerprintList);

  const runtime = createReviewStep("runtime");
  const runtimeDescription = createText("p", "ssh-connect-review-description", "ssh-connect-review-runtime-description");
  const runtimeActions = createElement("div", "ssh-connect-review-actions");
  const runtimeButton = createButton("ssh-connect-review-runtime");
  const runtimeStopButton = createButton("ssh-connect-review-runtime-stop");
  const runtimeStatus = createText("p", "ssh-connect-review-status", "ssh-connect-review-runtime-status");
  runtimeStatus.setAttribute("aria-live", "polite");
  runtimeActions.append(runtimeButton, runtimeStopButton);
  runtime.append(runtimeDescription, runtimeActions, runtimeStatus);

  const scope = createReviewStep("scope");
  const scopeDescription = createText("p", "ssh-connect-review-description", "ssh-connect-review-scope-description");
  const workspaceLabel = createText("label", "settings-field-label", "ssh-connect-review-workspace-label");
  workspaceLabel.setAttribute("for", "ssh-connect-review-workspace");
  const workspaceInput = createElement("input", "settings-text-input", "ssh-connect-review-workspace");
  workspaceInput.type = "text";
  workspaceInput.setAttribute("autocomplete", "off");
  const permissionLabel = createText("label", "settings-field-label", "ssh-connect-review-permission-label");
  permissionLabel.setAttribute("for", "ssh-connect-review-permission");
  const permissionSelect = createElement("select", "settings-text-input", "ssh-connect-review-permission");
  const readOnly = createElement("option", "", "ssh-connect-review-permission-read-only");
  readOnly.value = "read_only";
  const readWrite = createElement("option", "", "ssh-connect-review-permission-read-write");
  readWrite.value = "read_write";
  permissionSelect.append(readOnly, readWrite);
  const proposal = createText("p", "ssh-connect-review-proposal", "ssh-connect-review-proposal-only");
  scope.append(scopeDescription, workspaceLabel, workspaceInput, permissionLabel, permissionSelect, proposal);

  const review = createReviewStep("review");
  const reviewDescription = createText("p", "ssh-connect-review-description", "ssh-connect-review-review-description");
  const previewLabel = createText("div", "settings-field-label", "ssh-connect-review-preview-label");
  const preview = createElement("ol", "ssh-connect-review-preview");
  const checkPreview = createText("li", "", "ssh-connect-review-check-preview");
  const registerPreview = createText("li", "", "ssh-connect-review-register-preview");
  preview.append(checkPreview, registerPreview);
  const reviewActions = createElement("div", "ssh-connect-review-actions");
  const confirmButton = createButton("ssh-connect-review-confirm");
  const retryButton = createButton("ssh-connect-review-retry");
  const safeStopButton = createButton("ssh-connect-review-safe-stop");
  const reviewStatus = createText("p", "ssh-connect-review-status", "ssh-connect-review-review-status");
  reviewStatus.setAttribute("aria-live", "polite");
  reviewActions.append(confirmButton, retryButton, safeStopButton);
  review.append(reviewDescription, previewLabel, preview, reviewActions, reviewStatus);

  grid.append(host, identity, runtime, scope, review);
  section.append(title, intro, grid);
  return section;
}

function createNavItem() {
  const button = createButton("settings-nav-ssh-connect-review", "settings-nav-item");
  button.dataset.settingsTarget = SSH_CONNECT_REVIEW_SECTION_ID;
  return button;
}

function requestId() {
  return globalThis.crypto?.randomUUID?.() ?? `ssh-review-${Date.now().toString(36)}`;
}

function aliasValue() {
  const input = document.getElementById("ssh-connect-review-alias") as HTMLInputElement | null;
  return input?.value.trim() ?? "";
}

function formatArgvPreview(args: string[]) {
  return `[${args.map((arg) => JSON.stringify(arg)).join(", ")}]`;
}

function renderPreviews() {
  const text = currentLabels();
  const alias = aliasValue();
  if (!alias) {
    setText("ssh-connect-review-check-preview", text.aliasRequired);
    setText("ssh-connect-review-register-preview", text.aliasRequired);
    return;
  }
  setText(
    "ssh-connect-review-check-preview",
    formatArgvPreview(["host-profile", "check", alias, "--json"]),
  );
  setText(
    "ssh-connect-review-register-preview",
    `${formatArgvPreview(["host-profile", "register", alias, "--json"])} — ${text.registerCondition}`,
  );
}

function renderState() {
  if (!mountedReview) {
    return;
  }
  const text = currentLabels();
  const hostMessages: Record<HostState, string> = {
    not_found: text.hostNotFound,
    pending: text.hostPending,
    registered: text.hostRegistered,
    blocked: text.hostBlocked,
  };
  setText(
    "ssh-connect-review-host-status",
    mountedReview.hostState ? hostMessages[mountedReview.hostState] : text.notInspected,
  );
  setText(
    "ssh-connect-review-confirmed-value",
    mountedReview.confirmedFingerprint ?? text.unavailable,
  );
  setText(
    "ssh-connect-review-presented-value",
    mountedReview.presentedFingerprint ?? text.unavailable,
  );
  const runtimeMessages: Record<RuntimeState, string> = {
    unavailable: text.runtimeUnavailable,
    handshake_confirmed: text.runtimeConfirmed,
    stopped: text.runtimeStopped,
  };
  setText(
    "ssh-connect-review-runtime-status",
    mountedReview.runtimeBusy
      ? text.runtimeRunning
      : mountedReview.runtimeState
        ? runtimeMessages[mountedReview.runtimeState]
        : text.runtimeUnavailable,
  );
  const runtimeButton = document.getElementById("ssh-connect-review-runtime") as HTMLButtonElement | null;
  if (runtimeButton) {
    runtimeButton.disabled = mountedReview.hostState !== "registered" || mountedReview.runtimeBusy;
  }
  const inspectButton = document.getElementById("ssh-connect-review-inspect") as HTMLButtonElement | null;
  if (inspectButton) {
    inspectButton.disabled = mountedReview.confirmBusy;
  }
  const confirmButton = document.getElementById("ssh-connect-review-confirm") as HTMLButtonElement | null;
  if (confirmButton) {
    confirmButton.disabled = mountedReview.confirmBusy;
  }
  const retryButton = document.getElementById("ssh-connect-review-retry") as HTMLButtonElement | null;
  if (retryButton) {
    retryButton.disabled = mountedReview.confirmBusy;
  }
}

function renderLabels() {
  const text = currentLabels();
  const values: Record<string, string> = {
    "settings-nav-ssh-connect-review": text.nav,
    "ssh-connect-review-title": text.title,
    "ssh-connect-review-intro": text.intro,
    "ssh-connect-review-host-heading": text.host,
    "ssh-connect-review-host-description": text.hostDescription,
    "ssh-connect-review-alias-label": text.alias,
    "ssh-connect-review-inspect": text.inspect,
    "ssh-connect-review-identity-heading": text.identity,
    "ssh-connect-review-identity-description": text.identityDescription,
    "ssh-connect-review-confirmed-label": text.confirmedFingerprint,
    "ssh-connect-review-presented-label": text.presentedFingerprint,
    "ssh-connect-review-runtime-heading": text.runtime,
    "ssh-connect-review-runtime-description": text.runtimeDescription,
    "ssh-connect-review-runtime": text.verifyHandshake,
    "ssh-connect-review-runtime-stop": text.stopRuntime,
    "ssh-connect-review-scope-heading": text.scope,
    "ssh-connect-review-scope-description": text.scopeDescription,
    "ssh-connect-review-workspace-label": text.workspaceRoot,
    "ssh-connect-review-permission-label": text.permission,
    "ssh-connect-review-permission-read-only": text.permissionReadOnly,
    "ssh-connect-review-permission-read-write": text.permissionReadWrite,
    "ssh-connect-review-proposal-only": text.proposalOnly,
    "ssh-connect-review-review-heading": text.review,
    "ssh-connect-review-review-description": text.reviewDescription,
    "ssh-connect-review-preview-label": text.exactPreview,
    "ssh-connect-review-confirm": text.confirm,
    "ssh-connect-review-retry": text.retry,
    "ssh-connect-review-safe-stop": text.safeStop,
  };
  for (const [id, value] of Object.entries(values)) {
    setText(id, value);
  }
  const aliasInput = document.getElementById("ssh-connect-review-alias") as HTMLInputElement | null;
  if (aliasInput) {
    aliasInput.placeholder = text.aliasPlaceholder;
  }
  const workspaceInput = document.getElementById("ssh-connect-review-workspace") as HTMLInputElement | null;
  if (workspaceInput) {
    workspaceInput.placeholder = text.workspacePlaceholder;
  }
  renderPreviews();
  renderState();
}

function applyResponse(response: ReviewResponse) {
  if (!mountedReview) {
    return;
  }
  if (response.hostState) {
    mountedReview.hostState = response.hostState;
  }
  if (response.action === "inspect" || response.action === "confirm" || response.action === "runtime") {
    mountedReview.confirmedFingerprint = response.confirmedFingerprint ?? null;
  }
  if (response.action === "inspect" || response.action === "confirm") {
    mountedReview.presentedFingerprint = response.presentedFingerprint ?? null;
  }
  if (response.runtimeState) {
    mountedReview.runtimeState = response.runtimeState;
  }
  const text = currentLabels();
  if (response.action === "confirm") {
    if (!response.ok || response.errorCode) {
      setText("ssh-connect-review-review-status", text.confirmPartiallyApplied);
    } else {
      setText(
        "ssh-connect-review-review-status",
        response.hostState === "blocked" ? text.confirmBlocked : text.confirmComplete,
      );
    }
  } else if (!response.ok || response.errorCode) {
    setText("ssh-connect-review-review-status", text.actionFailed);
  }
  renderState();
}

async function runAction(action: ReviewAction) {
  if (!mountedReview) {
    return;
  }
  if ((action === "confirm" || action === "inspect") && mountedReview.confirmBusy) {
    return;
  }
  const confirmGeneration = mountedReview.confirmGeneration;
  const alias = aliasValue();
  const aliasInput = document.getElementById("ssh-connect-review-alias") as HTMLInputElement | null;
  if (action !== "stop" && !alias) {
    setText("ssh-connect-review-host-status", currentLabels().aliasRequired);
    return;
  }
  if (action === "runtime") {
    mountedReview.runtimeBusy = true;
    renderState();
  }
  if (action === "confirm") {
    mountedReview.confirmBusy = true;
    mountedReview.confirmGeneration += 1;
    renderState();
  }
  if (action !== "stop" && aliasInput) {
    aliasInput.disabled = true;
  }
  try {
    const response = await invoke<ReviewResponse>("ssh_connect_review", {
      request: {
        action,
        requestId: mountedReview.requestId,
        ...(action === "stop" ? {} : { alias }),
      },
    });
    if (
      (action === "stop" || aliasValue() === alias)
      && (action !== "inspect" || mountedReview.confirmGeneration === confirmGeneration)
    ) {
      applyResponse(response);
      if (action === "stop" && response.ok && response.runtimeState === "stopped" && mountedReview) {
        mountedReview.requestId = requestId();
      }
    }
  } catch {
    if (action !== "inspect" || mountedReview?.confirmGeneration === confirmGeneration) {
      setText("ssh-connect-review-review-status", currentLabels().actionFailed);
    }
  } finally {
    if (mountedReview && action === "runtime") {
      mountedReview.runtimeBusy = false;
      renderState();
    }
    if (mountedReview && action === "confirm") {
      mountedReview.confirmBusy = false;
      renderState();
    }
    if (action !== "stop" && aliasInput) {
      aliasInput.disabled = false;
    }
  }
}

function bindNav(button: HTMLButtonElement, section: HTMLElement) {
  if (button.dataset.sshConnectReviewBound === "true") {
    return;
  }
  button.dataset.sshConnectReviewBound = "true";
  button.addEventListener("click", () => {
    document.querySelectorAll<HTMLButtonElement>(".settings-nav-item").forEach((item) => {
      item.classList.toggle("is-active", item === button);
    });
    if (section.hidden) {
      return;
    }
    const content = document.getElementById("settings-content");
    if (content instanceof HTMLElement) {
      const top = Math.max(0, section.offsetTop - content.offsetTop);
      content.scrollTo({ top, behavior: "auto" });
    }
  });
}

function bindActions() {
  document.getElementById("ssh-connect-review-alias")?.addEventListener("input", () => {
    if (!mountedReview) {
      return;
    }
    mountedReview.hostState = null;
    mountedReview.confirmedFingerprint = null;
    mountedReview.presentedFingerprint = null;
    mountedReview.runtimeState = null;
    renderPreviews();
    renderState();
  });
  document.getElementById("ssh-connect-review-inspect")?.addEventListener("click", () => void runAction("inspect"));
  document.getElementById("ssh-connect-review-retry")?.addEventListener("click", () => void runAction("inspect"));
  document.getElementById("ssh-connect-review-confirm")?.addEventListener("click", () => void runAction("confirm"));
  document.getElementById("ssh-connect-review-runtime")?.addEventListener("click", () => void runAction("runtime"));
  document.getElementById("ssh-connect-review-runtime-stop")?.addEventListener("click", () => void runAction("stop"));
  document.getElementById("ssh-connect-review-safe-stop")?.addEventListener("click", () => void runAction("stop"));
}

export function mountSshConnectReview(): void {
  const settingsNav = document.getElementById("settings-nav");
  const settingsContent = document.getElementById("settings-content");
  if (!(settingsNav instanceof HTMLElement) || !(settingsContent instanceof HTMLElement)) {
    return;
  }

  let navItem = document.getElementById("settings-nav-ssh-connect-review") as HTMLButtonElement | null;
  let section = document.getElementById(SSH_CONNECT_REVIEW_SECTION_ID);
  if (!navItem) {
    navItem = createNavItem();
    settingsNav.append(navItem);
  }
  if (!section) {
    section = createReviewSection();
    settingsContent.append(section);
  }
  bindNav(navItem, section);

  if (!mountedReview) {
    mountedReview = {
      requestId: requestId(),
      hostState: null,
      confirmedFingerprint: null,
      presentedFingerprint: null,
      runtimeState: null,
      runtimeBusy: false,
      confirmBusy: false,
      confirmGeneration: 0,
    };
    bindActions();
    setText("ssh-connect-review-review-status", currentLabels().noWrites);
  }
  renderLabels();

  if (!languageObserver && typeof MutationObserver !== "undefined") {
    languageObserver = new MutationObserver(renderLabels);
    languageObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["lang"],
    });
  }
}
