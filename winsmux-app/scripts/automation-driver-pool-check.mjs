import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  acquireAutomationDriverLease,
  getAutomationDriverKey,
  heartbeatAutomationDriverLease,
  releaseAutomationDriverLease,
  tryHeartbeatAutomationDriverLease,
} from "./automation-driver-pool.mjs";

function createPoolPath(name) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), `winsmux-driver-pool-${name}-`));
  return {
    root,
    poolPath: path.join(root, "automation-driver-pool.json"),
    cleanup: () => fs.rmSync(root, { recursive: true, force: true }),
  };
}

function readPool(poolPath) {
  return JSON.parse(fs.readFileSync(poolPath, "utf8"));
}

const scriptDir = path.dirname(fileURLToPath(import.meta.url));

{
  const { poolPath, cleanup } = createPoolPath("reuse");
  const livePids = new Set([100]);
  try {
    const first = acquireAutomationDriverLease({
      poolPath,
      target: "http://127.0.0.1:5173/",
      pid: 100,
      nowMs: Date.UTC(2026, 6, 8, 0, 0, 0),
      isProcessAlive: (pid) => livePids.has(pid),
    });
    assert.equal(first.acquired, true);

    const second = acquireAutomationDriverLease({
      poolPath,
      target: "http://127.0.0.1:5173/",
      pid: 200,
      nowMs: Date.UTC(2026, 6, 8, 0, 0, 1),
      isProcessAlive: (pid) => livePids.has(pid),
    });
    assert.equal(second.acquired, false);
    assert.equal(second.reason, "active_lease");
    assert.equal(second.lease.owner_pid, 100);
    assert.equal(readPool(poolPath).leases.length, 1);
  } finally {
    cleanup();
  }
}

{
  const { poolPath, cleanup } = createPoolPath("stale");
  const livePids = new Set([100]);
  try {
    acquireAutomationDriverLease({
      poolPath,
      target: "http://127.0.0.1:5173/",
      pid: 100,
      nowMs: Date.UTC(2026, 6, 8, 0, 0, 0),
      isProcessAlive: (pid) => livePids.has(pid),
    });
    livePids.delete(100);
    livePids.add(200);

    const replacement = acquireAutomationDriverLease({
      poolPath,
      target: "http://127.0.0.1:5173/",
      pid: 200,
      nowMs: Date.UTC(2026, 6, 8, 0, 0, 2),
      isProcessAlive: (pid) => livePids.has(pid),
    });
    assert.equal(replacement.acquired, true);
    assert.equal(readPool(poolPath).leases.length, 1);
    assert.equal(readPool(poolPath).leases[0].owner_pid, 200);
  } finally {
    cleanup();
  }
}

{
  const { poolPath, cleanup } = createPoolPath("limit");
  const livePids = new Set([100]);
  try {
    acquireAutomationDriverLease({
      poolPath,
      target: "http://127.0.0.1:5173/",
      pid: 100,
      nowMs: Date.UTC(2026, 6, 8, 0, 0, 0),
      maxActiveLeases: 1,
      isProcessAlive: (pid) => livePids.has(pid),
    });
    const blocked = acquireAutomationDriverLease({
      poolPath,
      target: "http://127.0.0.1:8766/",
      pid: 200,
      nowMs: Date.UTC(2026, 6, 8, 0, 0, 1),
      maxActiveLeases: 1,
      isProcessAlive: (pid) => livePids.has(pid),
    });
    assert.equal(blocked.acquired, false);
    assert.equal(blocked.reason, "pool_full");
    assert.equal(readPool(poolPath).leases.length, 1);
  } finally {
    cleanup();
  }
}

{
  const { poolPath, cleanup } = createPoolPath("heartbeat-release");
  const livePids = new Set([100]);
  try {
    const acquired = acquireAutomationDriverLease({
      poolPath,
      target: "http://127.0.0.1:5173/",
      pid: 100,
      idleTimeoutMs: 1_000,
      nowMs: Date.UTC(2026, 6, 8, 0, 0, 0),
      isProcessAlive: (pid) => livePids.has(pid),
    });
    assert.equal(acquired.acquired, true);
    assert.equal(heartbeatAutomationDriverLease({
      poolPath,
      leaseId: acquired.lease.lease_id,
      nowMs: Date.UTC(2026, 6, 8, 0, 0, 5),
      idleTimeoutMs: 2_000,
    }), true);
    const afterHeartbeat = readPool(poolPath).leases[0];
    assert.equal(afterHeartbeat.heartbeat_at, "2026-07-08T00:00:05.000Z");
    assert.equal(afterHeartbeat.expires_at, "2026-07-08T00:00:07.000Z");

    assert.equal(releaseAutomationDriverLease({ poolPath, leaseId: acquired.lease.lease_id }), true);
    assert.equal(readPool(poolPath).leases.length, 0);
  } finally {
    cleanup();
  }
}

{
  const { poolPath, cleanup } = createPoolPath("heartbeat-lock");
  const livePids = new Set([100]);
  try {
    const acquired = acquireAutomationDriverLease({
      poolPath,
      target: "http://127.0.0.1:5173/",
      pid: 100,
      idleTimeoutMs: 1_000,
      nowMs: Date.now(),
      isProcessAlive: (pid) => livePids.has(pid),
    });
    assert.equal(acquired.acquired, true);

    const lockPath = `${poolPath}.lock`;
    fs.writeFileSync(lockPath, JSON.stringify({ owner_pid: 999, acquired_at: new Date().toISOString() }), "utf8");
    let reportedError = null;
    const result = tryHeartbeatAutomationDriverLease({
      poolPath,
      leaseId: acquired.lease.lease_id,
      idleTimeoutMs: 2_000,
    }, {
      onError: (error) => {
        reportedError = error;
      },
    });

    assert.equal(result.heartbeat, false);
    assert.match(reportedError.message, /automation driver pool lock/);
    fs.rmSync(lockPath, { force: true });
  } finally {
    cleanup();
  }
}

{
  const { poolPath, cleanup } = createPoolPath("probe-active");
  const target = "http://127.0.0.1:65535/";
  try {
    const nowMs = Date.now();
    fs.writeFileSync(poolPath, `${JSON.stringify({
      version: 1,
      leases: [{
        lease_id: "active-probe-lease",
        driver_key: getAutomationDriverKey({ target, headless: true }),
        owner: "test-owner",
        owner_pid: process.pid,
        target,
        headless: true,
        status: "leased",
        acquired_at: new Date(nowMs).toISOString(),
        heartbeat_at: new Date(nowMs).toISOString(),
        expires_at: new Date(nowMs + 60_000).toISOString(),
        idle_timeout_ms: 60_000,
        crash_recovery: "reclaim_when_owner_pid_exits",
      }],
    }, null, 2)}\n`, "utf8");

    assert.throws(() => execFileSync(process.execPath, [
      path.join(scriptDir, "open-dev-browser.mjs"),
      "--probe",
      "--no-server",
      "--headless",
      `--url=${target}`,
      `--driver-pool=${poolPath}`,
    ], {
      cwd: path.dirname(scriptDir),
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    }), (error) => {
      assert.equal(error.status, 1);
      const payload = JSON.parse(error.stdout);
      assert.equal(payload.reason, "active_lease_probe_requires_metrics");
      assert.equal(payload.reusedExistingDriver, false);
      assert.equal(payload.blocked, true);
      assert.equal(payload.metrics, undefined);
      return true;
    });
  } finally {
    cleanup();
  }
}

console.log("[automation-driver-pool-check] passed");
