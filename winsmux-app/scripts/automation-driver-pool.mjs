import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

export const DEFAULT_DRIVER_IDLE_TIMEOUT_MS = 15 * 60 * 1000;
const POOL_FILENAME = "automation-driver-pool.json";
const LOCK_STALE_MS = 10_000;
const LOCK_WAIT_MS = 2_000;

export function getDefaultAutomationDriverPoolPath(cwd = process.cwd()) {
  return path.join(cwd, "output", POOL_FILENAME);
}

export function getAutomationDriverKey({ target, headless = false }) {
  return crypto.createHash("sha256").update(`${target}\0${headless ? "headless" : "headed"}`).digest("hex").slice(0, 16);
}

export function defaultIsProcessAlive(pid) {
  if (!Number.isInteger(pid) || pid < 1) {
    return false;
  }
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

function readPoolState(poolPath) {
  try {
    const raw = fs.readFileSync(poolPath, "utf8");
    const parsed = JSON.parse(raw);
    return {
      version: 1,
      leases: Array.isArray(parsed?.leases) ? parsed.leases : [],
    };
  } catch (error) {
    if (error?.code === "ENOENT") {
      return { version: 1, leases: [] };
    }
    throw error;
  }
}

function writePoolState(poolPath, state) {
  fs.mkdirSync(path.dirname(poolPath), { recursive: true });
  const tempPath = `${poolPath}.${process.pid}.tmp`;
  fs.writeFileSync(tempPath, `${JSON.stringify(state, null, 2)}\n`, "utf8");
  fs.renameSync(tempPath, poolPath);
}

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function withPoolLock(poolPath, callback, nowMs = Date.now()) {
  fs.mkdirSync(path.dirname(poolPath), { recursive: true });
  const lockPath = `${poolPath}.lock`;
  const deadline = Date.now() + LOCK_WAIT_MS;
  while (true) {
    let fd = null;
    try {
      fd = fs.openSync(lockPath, "wx");
      fs.writeFileSync(fd, JSON.stringify({ owner_pid: process.pid, acquired_at: new Date(nowMs).toISOString() }));
      return callback();
    } catch (error) {
      if (error?.code !== "EEXIST") {
        throw error;
      }
      try {
        const lockStat = fs.statSync(lockPath);
        if (Date.now() - lockStat.mtimeMs > LOCK_STALE_MS) {
          fs.unlinkSync(lockPath);
          continue;
        }
      } catch (statError) {
        if (statError?.code !== "ENOENT") {
          throw statError;
        }
        continue;
      }
      if (Date.now() >= deadline) {
        throw new Error(`Timed out waiting for automation driver pool lock: ${lockPath}`);
      }
      sleepSync(50);
    } finally {
      if (fd !== null) {
        fs.closeSync(fd);
        fs.rmSync(lockPath, { force: true });
      }
    }
  }
}

function normalizeIdleTimeoutMs(value) {
  const parsed = Number.parseInt(`${value ?? ""}`, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_DRIVER_IDLE_TIMEOUT_MS;
}

function pruneActiveLeases(leases, { nowMs, isProcessAlive }) {
  return leases.filter((lease) => {
    const expiresAt = Date.parse(`${lease.expires_at ?? ""}`);
    const ownerPid = Number.parseInt(`${lease.owner_pid ?? ""}`, 10);
    return Number.isFinite(expiresAt) && expiresAt > nowMs && isProcessAlive(ownerPid);
  });
}

export function acquireAutomationDriverLease({
  poolPath = getDefaultAutomationDriverPoolPath(),
  owner = "open-dev-browser",
  target,
  headless = false,
  pid = process.pid,
  idleTimeoutMs = DEFAULT_DRIVER_IDLE_TIMEOUT_MS,
  maxActiveLeases = 4,
  nowMs = Date.now(),
  isProcessAlive = defaultIsProcessAlive,
} = {}) {
  if (!target) {
    throw new Error("target is required to acquire an automation driver lease");
  }

  const normalizedIdleTimeoutMs = normalizeIdleTimeoutMs(idleTimeoutMs);
  const driverKey = getAutomationDriverKey({ target, headless });
  return withPoolLock(poolPath, () => {
    const state = readPoolState(poolPath);
    const activeLeases = pruneActiveLeases(state.leases, { nowMs, isProcessAlive });
    const existing = activeLeases.find((lease) => lease.driver_key === driverKey);
    if (existing) {
      const nextState = { version: 1, leases: activeLeases };
      writePoolState(poolPath, nextState);
      return { acquired: false, reason: "active_lease", lease: existing, state: nextState };
    }

    if (activeLeases.length >= maxActiveLeases) {
      const nextState = { version: 1, leases: activeLeases };
      writePoolState(poolPath, nextState);
      return { acquired: false, reason: "pool_full", lease: null, state: nextState };
    }

    const nowIso = new Date(nowMs).toISOString();
    const lease = {
      lease_id: `${driverKey}-${pid}-${nowMs}`,
      driver_key: driverKey,
      owner,
      owner_pid: pid,
      target,
      headless,
      status: "leased",
      acquired_at: nowIso,
      heartbeat_at: nowIso,
      expires_at: new Date(nowMs + normalizedIdleTimeoutMs).toISOString(),
      idle_timeout_ms: normalizedIdleTimeoutMs,
      crash_recovery: "reclaim_when_owner_pid_exits",
    };
    const nextState = { version: 1, leases: [...activeLeases, lease] };
    writePoolState(poolPath, nextState);
    return { acquired: true, reason: "acquired", lease, state: nextState };
  }, nowMs);
}

export function heartbeatAutomationDriverLease({
  poolPath = getDefaultAutomationDriverPoolPath(),
  leaseId,
  nowMs = Date.now(),
  idleTimeoutMs,
} = {}) {
  if (!leaseId) {
    return false;
  }
  return withPoolLock(poolPath, () => {
    const state = readPoolState(poolPath);
    let updated = false;
    const nextLeases = state.leases.map((lease) => {
      if (lease.lease_id !== leaseId) {
        return lease;
      }
      updated = true;
      const timeoutMs = normalizeIdleTimeoutMs(idleTimeoutMs ?? lease.idle_timeout_ms);
      return {
        ...lease,
        heartbeat_at: new Date(nowMs).toISOString(),
        expires_at: new Date(nowMs + timeoutMs).toISOString(),
        idle_timeout_ms: timeoutMs,
      };
    });
    if (updated) {
      writePoolState(poolPath, { version: 1, leases: nextLeases });
    }
    return updated;
  }, nowMs);
}

export function tryHeartbeatAutomationDriverLease(options = {}, { onError = null } = {}) {
  try {
    return {
      heartbeat: heartbeatAutomationDriverLease(options),
      error: null,
    };
  } catch (error) {
    if (typeof onError === "function") {
      onError(error);
    }
    return {
      heartbeat: false,
      error,
    };
  }
}

export function releaseAutomationDriverLease({ poolPath = getDefaultAutomationDriverPoolPath(), leaseId } = {}) {
  if (!leaseId) {
    return false;
  }
  return withPoolLock(poolPath, () => {
    const state = readPoolState(poolPath);
    const nextLeases = state.leases.filter((lease) => lease.lease_id !== leaseId);
    const released = nextLeases.length !== state.leases.length;
    if (released) {
      writePoolState(poolPath, { version: 1, leases: nextLeases });
    }
    return released;
  });
}
