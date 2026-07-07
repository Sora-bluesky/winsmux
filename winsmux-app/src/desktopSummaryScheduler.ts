export interface DesktopSummaryRefreshEventLike {
  source?: string;
  reason?: string;
  pane_id?: string;
  run_id?: string;
}

export interface DesktopSummaryRefreshTarget {
  projectDir: string | null;
  projectKey: string;
}

export interface DesktopSummaryRefreshContext {
  forceExplainRunId: string | null;
  requestProjectDir: string | null;
  requestProjectKey: string;
  isCurrent: (currentProjectKey?: string) => boolean;
  markSuccessfulRefresh: () => void;
}

export interface DesktopSummarySchedulerWindow {
  setTimeout(callback: () => void, delayMs: number): number;
  clearTimeout(timerId: number): void;
  setInterval(callback: () => void, delayMs: number): number;
  addEventListener(type: "focus", listener: () => void): void;
}

export interface DesktopSummarySchedulerDocument {
  readonly visibilityState: DocumentVisibilityState;
  addEventListener(type: "visibilitychange", listener: () => void): void;
}

export interface DesktopSummaryRefreshSchedulerOptions<
  TEvent extends DesktopSummaryRefreshEventLike = DesktopSummaryRefreshEventLike,
> {
  window: DesktopSummarySchedulerWindow;
  document: DesktopSummarySchedulerDocument;
  fallbackIntervalMs: number;
  streamStaleMs: number;
  getRefreshTarget: () => DesktopSummaryRefreshTarget;
  refresh: (context: DesktopSummaryRefreshContext) => Promise<void>;
  subscribe: (onRefresh: (event: TEvent) => void) => Promise<unknown>;
  handleLiveEvent?: (event: TEvent) => void;
  now?: () => number;
  logger?: Pick<Console, "warn">;
}

export class DesktopSummaryRefreshScheduler<
  TEvent extends DesktopSummaryRefreshEventLike = DesktopSummaryRefreshEventLike,
> {
  private readonly options: DesktopSummaryRefreshSchedulerOptions<TEvent>;
  private refreshInFlight: Promise<void> | null = null;
  private refreshInFlightProjectKey = "";
  private refreshTimeout: number | null = null;
  private queuedRunId: string | null = null;
  private requestedVersion = 0;
  private runningVersion = 0;
  private refreshSequence = 0;
  private fallbackRefreshRegistered = false;
  private liveRefreshAvailable = false;
  private lastSuccessfulRefreshAt = 0;
  private lastStreamSignalAt = 0;

  constructor(options: DesktopSummaryRefreshSchedulerOptions<TEvent>) {
    this.options = options;
  }

  refresh(forceExplainRunId?: string | null) {
    const target = this.options.getRefreshTarget();
    if (this.refreshInFlight && this.refreshInFlightProjectKey === target.projectKey) {
      return this.refreshInFlight;
    }

    const requestSequence = ++this.refreshSequence;
    this.refreshInFlightProjectKey = target.projectKey;
    this.refreshInFlight = (async () => {
      try {
        await this.options.refresh({
          forceExplainRunId: forceExplainRunId ?? null,
          requestProjectDir: target.projectDir,
          requestProjectKey: target.projectKey,
          isCurrent: (currentProjectKey?: string) =>
            requestSequence === this.refreshSequence &&
            (currentProjectKey === undefined || currentProjectKey === target.projectKey),
          markSuccessfulRefresh: () => {
            this.markSuccessfulRefresh();
          },
        });
      } finally {
        if (requestSequence !== this.refreshSequence) {
          return;
        }
        this.refreshInFlight = null;
        this.refreshInFlightProjectKey = "";
        if (this.runningVersion < this.requestedVersion) {
          this.flushQueue();
        }
      }
    })();

    return this.refreshInFlight;
  }

  request(forceExplainRunId?: string | null, delayMs = 150) {
    this.requestedVersion += 1;
    if (forceExplainRunId) {
      this.queuedRunId = forceExplainRunId;
    }
    if (this.refreshTimeout !== null) {
      this.options.window.clearTimeout(this.refreshTimeout);
    }

    this.refreshTimeout = this.options.window.setTimeout(() => {
      this.refreshTimeout = null;
      if (this.refreshInFlight) {
        return;
      }
      this.flushQueue();
    }, delayMs);
  }

  shouldRunFallbackRefresh(now = this.now()) {
    if (!this.liveRefreshAvailable) {
      return true;
    }

    const lastLiveActivityAt = Math.max(
      this.lastSuccessfulRefreshAt,
      this.lastStreamSignalAt,
    );
    return now - lastLiveActivityAt >= this.options.streamStaleMs;
  }

  registerFallbackRefresh() {
    if (this.fallbackRefreshRegistered) {
      return;
    }

    this.fallbackRefreshRegistered = true;

    this.options.window.setInterval(() => {
      if (this.options.document.visibilityState !== "visible") {
        return;
      }
      if (!this.shouldRunFallbackRefresh()) {
        return;
      }
      this.request(undefined, 0);
    }, this.options.fallbackIntervalMs);

    this.options.window.addEventListener("focus", () => {
      if (!this.shouldRunFallbackRefresh()) {
        return;
      }
      this.request(undefined, 0);
    });

    this.options.document.addEventListener("visibilitychange", () => {
      if (this.options.document.visibilityState !== "visible") {
        return;
      }
      if (!this.shouldRunFallbackRefresh()) {
        return;
      }
      this.request(undefined, 0);
    });
  }

  registerLiveRefresh() {
    this.registerFallbackRefresh();

    void this.options.subscribe((event) => {
      this.options.handleLiveEvent?.(event);
      if (event.source !== "pty") {
        this.lastStreamSignalAt = this.now();
      }
      this.request(event.run_id, 0);
    }).then(() => {
      this.liveRefreshAvailable = true;
    }).catch((error) => {
      this.options.logger?.warn("Failed to subscribe to desktop summary refresh events", error);
      this.liveRefreshAvailable = false;
    });
  }

  private flushQueue() {
    if (this.refreshInFlight) {
      return;
    }

    if (this.runningVersion >= this.requestedVersion) {
      return;
    }

    const queuedRunId = this.queuedRunId;
    this.queuedRunId = null;
    this.runningVersion = this.requestedVersion;
    void this.refresh(queuedRunId);
  }

  private markSuccessfulRefresh() {
    this.lastSuccessfulRefreshAt = this.now();
  }

  private now() {
    return this.options.now?.() ?? Date.now();
  }
}
