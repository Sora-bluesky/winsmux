import "./fleetProjection.css";

import { invoke } from "@tauri-apps/api/core";

type FleetState = "connecting" | "live" | "detached" | "unreachable";
type RemoteControllerState = "attached" | "detached" | "unreachable";

interface LocalFleetPaneState {
  ptyStarted: boolean;
  ptyStarting: unknown;
}

interface RemoteSessionSnapshot {
  sessionId: string;
  hostAlias: string;
  controllerState: RemoteControllerState;
  lastHelloWelcomeRttMs: number;
}

interface FleetRow {
  location: string;
  state: FleetState;
  latency: string;
}

const REMOTE_SNAPSHOT_FIELDS = [
  "controllerState",
  "hostAlias",
  "lastHelloWelcomeRttMs",
  "sessionId",
] as const;
const REMOTE_STATES = new Set<RemoteControllerState>(["attached", "detached", "unreachable"]);
const REMOTE_REFRESH_WARNING = "Remote Fleet refresh unavailable.";

let localRows: FleetRow[] = [];
let remoteRows: FleetRow[] = [];
let remoteRefreshGeneration = 0;
let remoteRefreshWarning = false;

function createTextElement(tagName: string, className: string, text: string) {
  const element = document.createElement(tagName);
  element.className = className;
  element.textContent = text;
  return element;
}

function getFleetRoot() {
  return document.getElementById("fleet-projection");
}

function renderFleetProjection() {
  const root = getFleetRoot();
  if (!root) {
    return;
  }

  const title = createTextElement("div", "fleet-projection-title", "Fleet");
  title.id = "fleet-projection-title";
  const list = document.createElement("ul");
  list.className = "fleet-projection-list";
  list.setAttribute("role", "list");
  list.setAttribute("aria-labelledby", "fleet-projection-title");

  const rows = [...localRows, ...remoteRows];
  for (const row of rows) {
    const item = document.createElement("li");
    item.className = "fleet-projection-row";
    item.setAttribute("role", "listitem");
    item.append(
      createTextElement("span", "fleet-projection-location", row.location),
      createTextElement("span", "fleet-projection-state", row.state),
      createTextElement("span", "fleet-projection-latency", row.latency),
    );
    list.append(item);
  }

  const children = [title, list];
  if (remoteRefreshWarning) {
    const warning = createTextElement("div", "fleet-projection-warning", REMOTE_REFRESH_WARNING);
    warning.setAttribute("role", "status");
    children.push(warning);
  }
  root.replaceChildren(...children);
}

function mapRemoteState(state: RemoteControllerState): Exclude<FleetState, "connecting"> {
  return state === "attached" ? "live" : state;
}

function validateRemoteSnapshots(value: unknown): RemoteSessionSnapshot[] | null {
  if (!Array.isArray(value)) {
    return null;
  }

  const snapshots: RemoteSessionSnapshot[] = [];
  const keys = new Set<string>();
  for (const candidate of value) {
    if (typeof candidate !== "object" || candidate === null || Array.isArray(candidate)) {
      return null;
    }
    const record = candidate as Record<string, unknown>;
    const fields = Object.keys(record).sort();
    if (fields.length !== REMOTE_SNAPSHOT_FIELDS.length
      || fields.some((field, index) => field !== REMOTE_SNAPSHOT_FIELDS[index])) {
      return null;
    }
    if (typeof record.sessionId !== "string" || record.sessionId.length === 0
      || typeof record.hostAlias !== "string" || record.hostAlias.length === 0
      || typeof record.controllerState !== "string" || !REMOTE_STATES.has(record.controllerState as RemoteControllerState)
      || typeof record.lastHelloWelcomeRttMs !== "number"
      || !Number.isSafeInteger(record.lastHelloWelcomeRttMs)
      || record.lastHelloWelcomeRttMs < 0) {
      return null;
    }

    const snapshot = record as unknown as RemoteSessionSnapshot;
    const key = JSON.stringify([snapshot.hostAlias, snapshot.sessionId]);
    if (keys.has(key)) {
      return null;
    }
    keys.add(key);
    snapshots.push(snapshot);
  }
  return snapshots;
}

export function mountFleetProjection() {
  if (getFleetRoot()) {
    return;
  }
  const drawer = document.getElementById("terminal-drawer");
  const workerStatus = document.getElementById("worker-status-pill-bar");
  if (!drawer || !workerStatus || workerStatus.parentElement !== drawer) {
    return;
  }

  const root = document.createElement("section");
  root.id = "fleet-projection";
  root.setAttribute("aria-label", "Fleet");
  drawer.insertBefore(root, workerStatus);
  renderFleetProjection();
}

export function projectLocalFleet(panes: Iterable<readonly [unknown, LocalFleetPaneState]>) {
  const nextRows: FleetRow[] = [];
  for (const [, pane] of panes) {
    if (pane.ptyStarted) {
      nextRows.push({ location: "LOCAL · This device", state: "live", latency: "local" });
    } else if (pane.ptyStarting) {
      nextRows.push({ location: "LOCAL · This device", state: "connecting", latency: "local" });
    }
  }
  localRows = nextRows;
  renderFleetProjection();
}

export async function refreshRemoteFleetProjection() {
  const generation = ++remoteRefreshGeneration;
  try {
    const payload = await invoke<unknown>("remote_session_snapshots");
    if (generation !== remoteRefreshGeneration) {
      return;
    }
    const snapshots = validateRemoteSnapshots(payload);
    if (!snapshots) {
      remoteRefreshWarning = true;
      renderFleetProjection();
      return;
    }
    remoteRows = snapshots.map((snapshot) => ({
      location: `REMOTE · ${snapshot.hostAlias}`,
      state: mapRemoteState(snapshot.controllerState),
      latency: `${snapshot.lastHelloWelcomeRttMs} ms`,
    }));
    remoteRefreshWarning = false;
    renderFleetProjection();
  } catch {
    if (generation !== remoteRefreshGeneration) {
      return;
    }
    remoteRefreshWarning = true;
    renderFleetProjection();
  }
}
