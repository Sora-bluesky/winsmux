#!/usr/bin/env node
// sh-pipeline.js — STG gate-driven pipeline (Node.js port)
// Spec: DETAILED_DESIGN.md §8.1
// Event: TaskCompleted
// Execution order: after sh-task-gate.js
// Target response time: < 30000ms
"use strict";

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const {
  readHookInput,
  allow,
  deny,
  readSession,
  writeSession,
  readYaml,
  appendEvidence,
  commandExists,
  SH_DIR,
} = require("./lib/sh-utils");

const HOOK_NAME = "sh-pipeline";
const PIPELINE_CONFIG = path.join(SH_DIR, "config", "pipeline-config.json");
const BACKLOG_FILE = path.join("tasks", "backlog.yaml");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Load pipeline configuration.
 * @returns {Object|null}
 */
function loadPipelineConfig() {
  try {
    if (!fs.existsSync(PIPELINE_CONFIG)) return null;
    return JSON.parse(fs.readFileSync(PIPELINE_CONFIG, "utf8"));
  } catch {
    return null;
  }
}

/**
 * Get task data from backlog.yaml.
 * @param {string} taskId
 * @returns {{ stage_status: string, intent: string, branch: string, pr_url: string }|null}
 */
function getTaskData(taskId) {
  try {
    const backlog = readYaml(BACKLOG_FILE);
    const tasks = backlog.tasks || [];
    const task = tasks.find((t) => t.id === taskId);
    if (!task) return null;
    return {
      stage_status: task.stage_status || null,
      intent: task.intent || "",
      branch: task.branch || "",
      pr_url: task.pr_url || "",
    };
  } catch {
    return null;
  }
}

/**
 * Execute a trusted git operation in a child process.
 * Uses SH_PIPELINE=1 env to identify trusted operations.
 * @param {string} taskId
 * @param {string} command
 * @returns {string} stdout
 */
function executeTrusted(taskId, command) {
  return execSync(command, {
    encoding: "utf8",
    timeout: 30000,
    env: {
      ...process.env,
      SH_PIPELINE: "1",
      SH_TASK_ID: taskId,
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
}

/**
 * Update backlog.yaml task fields via js-yaml.
 * @param {string} taskId
 * @param {Object} updates - key-value pairs to update
 */
function updateBacklog(taskId, updates) {
  let yaml;
  try {
    yaml = require("js-yaml");
  } catch {
    // js-yaml not available — skip backlog update
    return;
  }

  try {
    const content = fs.readFileSync(BACKLOG_FILE, "utf8");
    const backlog = yaml.load(content);
    const tasks = backlog.tasks || [];
    const task = tasks.find((t) => t.id === taskId);
    if (!task) return;

    // Apply updates
    for (const [key, value] of Object.entries(updates)) {
      if (key === "stg_history_push") {
        if (!Array.isArray(task.stg_history)) task.stg_history = [];
        task.stg_history.push(value);
      } else {
        task[key] = value;
      }
    }

    // Write back
    const output = yaml.dump(backlog, {
      lineWidth: -1,
      noRefs: true,
      quotingType: '"',
      forceQuotes: false,
    });
    fs.writeFileSync(BACKLOG_FILE, output);
  } catch {
    // Backlog update failure is non-critical for pipeline
  }
}

/**
 * Format commit message from template.
 * @param {string} template
 * @param {string} taskId
 * @param {string} gate
 * @param {string} intent
 * @returns {string}
 */
function formatCommitMsg(template, taskId, gate, intent) {
  return template
    .replace("{task_id}", taskId)
    .replace("{gate}", gate)
    .replace("{intent}", intent);
}

// Priority weight for sorting (lower = higher priority)
const PRIORITY_WEIGHT = { must: 0, should: 1, could: 2 };

// Maximum auto-pickups per session (infinite loop guard)
const MAX_AUTO_PICKUPS = 10;

/**
 * Find the next eligible task from backlog.yaml.
 * Filters: status === "backlog", all depends_on are "done".
 * Sorts: priority (must > should > could), then due_date ascending.
 * @returns {{ id: string, intent: string, priority: string }|null}
 */
function findNextTask() {
  try {
    const backlog = readYaml(BACKLOG_FILE);
    const tasks = backlog.tasks || [];

    // Build status lookup for dependency checking
    const statusMap = {};
    for (const t of tasks) {
      statusMap[t.id] = t.status;
    }

    // Filter candidates: backlog status + all deps done
    const candidates = tasks.filter((t) => {
      if (t.status !== "backlog") return false;
      const deps = t.depends_on || [];
      return deps.every((depId) => statusMap[depId] === "done");
    });

    if (candidates.length === 0) return null;

    // Sort: priority ascending, then due_date ascending (null last)
    candidates.sort((a, b) => {
      const pa = PRIORITY_WEIGHT[a.priority] ?? 99;
      const pb = PRIORITY_WEIGHT[b.priority] ?? 99;
      if (pa !== pb) return pa - pb;

      // due_date: null → Infinity for sorting
      const da = a.due_date ? new Date(a.due_date).getTime() : Infinity;
      const db = b.due_date ? new Date(b.due_date).getTime() : Infinity;
      return da - db;
    });

    const next = candidates[0];
    return { id: next.id, intent: next.intent, priority: next.priority };
  } catch {
    return null;
  }
}

/**
 * Bump version in package.json and return the new version string.
 * @param {string} bumpType - "patch" | "minor" | "major"
 * @returns {string|null} New version string, or null if package.json not found.
 */
function bumpVersion(bumpType) {
  const pkgPath = "package.json";
  if (!fs.existsSync(pkgPath)) return null;

  const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
  const parts = (pkg.version || "0.0.0").split(".").map(Number);

  switch (bumpType) {
    case "major":
      parts[0] += 1;
      parts[1] = 0;
      parts[2] = 0;
      break;
    case "minor":
      parts[1] += 1;
      parts[2] = 0;
      break;
    case "patch":
    default:
      parts[2] += 1;
      break;
  }

  const newVersion = parts.join(".");
  pkg.version = newVersion;
  fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + "\n", "utf8");
  return newVersion;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

try {
  const input = readHookInput();

  // Step 0: Load pipeline config
  const config = loadPipelineConfig();
  if (!config || config.auto_commit !== true) {
    allow();
    return;
  }

  const autoCommit = config.auto_commit === true;
  const autoPush = config.auto_push === true;
  const autoPR = config.auto_pr === true;
  const autoMerge = config.auto_merge === true;
  const autoTag = config.auto_tag === true;
  const versionBump = config.version_bump || "patch";
  const commitFmt =
    config.commit_message_format || "[{task_id}] STG{gate}: {intent}";

  // Step 1: Get active task
  const session = readSession();
  const taskId = session.active_task_id;
  if (!taskId) {
    allow();
    return;
  }

  // Step 2: Get stage status
  const taskData = getTaskData(taskId);
  if (!taskData) {
    allow();
    return;
  }

  const stageStatus = taskData.stage_status;
  if (!stageStatus) {
    allow();
    return;
  }

  // Step 3: STG gate progression
  let summary = "";
  const timestamp = new Date().toISOString();
  const today = timestamp.slice(0, 10);

  switch (stageStatus) {
    case null:
    case "stg0_passed":
    case "stg1_passed": {
      // STG2: Auto commit
      if (!autoCommit) break;

      const commitMsg = formatCommitMsg(
        commitFmt,
        taskId,
        "2",
        taskData.intent,
      );
      const branchName = `feature/${taskId}`;

      try {
        // Ensure feature branch
        try {
          executeTrusted(taskId, `git checkout -b "${branchName}"`);
        } catch {
          try {
            executeTrusted(taskId, `git checkout "${branchName}"`);
          } catch {
            // Already on the branch
          }
        }

        // Sync project views + README drift check (ADR-033, ADR-035)
        if (commandExists("pwsh")) {
          try {
            executeTrusted(taskId, "pwsh scripts/sync-project-views.ps1");
          } catch {
            // Non-critical
          }
          try {
            executeTrusted(taskId, "pwsh scripts/sync-readme.ps1");
          } catch {
            // Non-critical — drift is reported but does not block
          }
        }

        // Permissions alignment gate (permanent countermeasure — Requirement 1: Hard Gate)
        const PERM_SPEC_FILE = path.join(".claude", "permissions-spec.json");
        if (fs.existsSync(PERM_SPEC_FILE)) {
          try {
            const {
              validateAlignment,
            } = require("./lib/permissions-validator");
            const alignResult = validateAlignment(
              PERM_SPEC_FILE,
              path.join(".claude", "settings.json"),
            );
            if (!alignResult.aligned) {
              updateBacklog(taskId, {
                stage_status: "stg2_blocked",
                stg_history_push: {
                  gate: "stg2_blocked",
                  passed_at: timestamp,
                  reason: "permissions_divergence",
                },
              });
              appendEvidence({
                hook: HOOK_NAME,
                action: "stg2_blocked",
                reason: "permissions_divergence",
                diff_summary: alignResult.summary,
              });
              summary = `STG2 BLOCKED: permissions divergence — ${alignResult.summary}`;
              break;
            }
          } catch (err) {
            // fail-close: validation error also blocks STG2
            summary = `STG2 BLOCKED: permissions check error — ${err.message}`;
            break;
          }
        }

        // Update backlog
        updateBacklog(taskId, {
          stage_status: "stg2_passed",
          start_date: today,
          branch: branchName,
          stg_history_push: { gate: "stg2", passed_at: timestamp },
        });

        // Stage and commit
        executeTrusted(taskId, "git add -A");
        try {
          executeTrusted(taskId, `git commit -m "${commitMsg}"`);
        } catch {
          // No changes to commit
        }

        summary = `STG2 passed: auto-committed [${taskId}]`;
      } catch (err) {
        summary = `STG2 error: ${err.message}`;
      }
      break;
    }

    case "stg2_passed": {
      // STG3: Auto push
      if (!autoPush) break;

      const branchName = taskData.branch || `feature/${taskId}`;

      try {
        executeTrusted(taskId, `git push -u origin "${branchName}"`);

        updateBacklog(taskId, {
          stage_status: "stg3_passed",
          stg_history_push: { gate: "stg3", passed_at: timestamp },
        });

        // Commit backlog update
        executeTrusted(taskId, "git add tasks/backlog.yaml");
        try {
          executeTrusted(
            taskId,
            `git commit -m "[${taskId}] STG3: pushed to remote"`,
          );
        } catch {
          // No changes
        }

        summary = `STG3 passed: pushed to ${branchName}`;
      } catch (err) {
        summary = `STG3 error: ${err.message}`;
      }
      break;
    }

    case "stg3_passed":
    case "stg4_passed": {
      // STG5: Auto PR
      if (!autoPR) break;

      if (!commandExists("gh")) {
        summary = `gh CLI not found. Please create PR manually for feature/${taskId}`;
        break;
      }

      try {
        const prUrl = executeTrusted(
          taskId,
          `gh pr create --title "[${taskId}] ${taskData.intent}" --body "Auto-generated by shield-harness pipeline (ADR-031)"`,
        ).trim();

        if (prUrl) {
          updateBacklog(taskId, {
            stage_status: "stg5_passed",
            pr_url: prUrl,
            stg_history_push: { gate: "stg5", passed_at: timestamp },
          });

          executeTrusted(taskId, "git add tasks/backlog.yaml");
          try {
            executeTrusted(
              taskId,
              `git commit -m "[${taskId}] STG5: PR created"`,
            );
          } catch {
            // No changes
          }

          summary = `STG5 passed: PR created at ${prUrl}`;
        } else {
          summary = `STG5: PR creation failed for feature/${taskId}`;
        }
      } catch (err) {
        summary = `STG5 error: ${err.message}`;
      }
      break;
    }

    case "stg5_passed": {
      // STG6: Auto merge
      if (!autoMerge) break;

      if (!commandExists("gh")) {
        summary = "gh CLI not found. Please merge PR manually.";
        break;
      }

      try {
        const branchName = taskData.branch || `feature/${taskId}`;
        const prNumberStr = executeTrusted(
          taskId,
          `gh pr list --head "${branchName}" --json number -q ".[0].number"`,
        ).trim();

        if (!prNumberStr) {
          summary = `STG5: No PR found for ${branchName}`;
          break;
        }

        // Check CI status
        let failedCount;
        try {
          failedCount = executeTrusted(
            taskId,
            `gh pr checks ${prNumberStr} --json state -q '[.[] | select(.state != "SUCCESS")] | length'`,
          ).trim();
        } catch {
          failedCount = "unknown";
        }

        if (failedCount !== "0") {
          summary = `STG5: CI checks not passed yet (${failedCount} failing). Waiting...`;
          break;
        }

        // Merge
        executeTrusted(taskId, `gh pr merge ${prNumberStr} --squash`);
        executeTrusted(taskId, "git checkout main");
        executeTrusted(taskId, "git pull origin main");

        // Branch cleanup
        try {
          executeTrusted(taskId, `git branch -d "${branchName}"`);
        } catch {
          // Already deleted
        }
        try {
          executeTrusted(taskId, `git push origin --delete "${branchName}"`);
        } catch {
          // Already deleted remotely
        }

        // Update backlog to done
        updateBacklog(taskId, {
          status: "done",
          stage_status: "stg6_passed",
          completed_date: today,
          stg_history_push: { gate: "stg6", passed_at: timestamp },
        });

        // Sync views
        if (commandExists("pwsh")) {
          try {
            executeTrusted(taskId, "pwsh scripts/sync-project-views.ps1");
          } catch {
            // Non-critical
          }
        }

        // Final commit
        executeTrusted(taskId, "git add -A");
        try {
          executeTrusted(
            taskId,
            `git commit -m "[${taskId}] STG6: merged and completed"`,
          );
        } catch {
          // No changes
        }

        // Auto-tag release version (TASK-013)
        if (autoTag) {
          try {
            const newVersion = bumpVersion(versionBump);
            if (newVersion) {
              const tag = `v${newVersion}`;
              executeTrusted(taskId, `git tag "${tag}"`);
              executeTrusted(taskId, `git push origin "${tag}"`);
              summary = `STG6 passed: PR #${prNumberStr} merged, tagged ${tag} [${taskId}]`;
            } else {
              summary = `STG6 passed: PR #${prNumberStr} merged [${taskId}] (tag skipped: no package.json)`;
            }
          } catch (tagErr) {
            summary = `STG6 passed: PR #${prNumberStr} merged [${taskId}] (tag failed: ${tagErr.message})`;
          }
        } else {
          summary = `STG6 passed: PR #${prNumberStr} merged [${taskId}]`;
        }
      } catch (err) {
        summary = `STG6 error: ${err.message}`;
      }
      break;
    }

    case "stg6_passed": {
      // Auto-pickup next task (ADR-034)
      if (!config.auto_pickup_next_task) {
        summary = `Task ${taskId} already completed (stg6_passed)`;
        break;
      }

      // Infinite loop guard
      const session = readSession();
      const pickupCount = session.auto_pickup_count || 0;
      if (pickupCount >= MAX_AUTO_PICKUPS) {
        summary = `Auto-pickup limit reached (${MAX_AUTO_PICKUPS}). Stopping.`;
        break;
      }

      const nextTask = findNextTask();
      if (!nextTask) {
        summary = "All tasks completed or no eligible tasks found.";
        break;
      }

      try {
        // Update next task to in_progress
        const nextBranch = `feature/${nextTask.id}`;
        updateBacklog(nextTask.id, {
          status: "in_progress",
          stage_status: "stg0_passed",
          start_date: today,
          branch: nextBranch,
          stg_history_push: { gate: "stg0", passed_at: timestamp },
        });

        // Create branch
        try {
          executeTrusted(nextTask.id, `git checkout -b "${nextBranch}"`);
        } catch {
          try {
            executeTrusted(nextTask.id, `git checkout "${nextBranch}"`);
          } catch {
            // Already on branch
          }
        }

        // Update session
        writeSession({
          ...session,
          active_task_id: nextTask.id,
          auto_pickup_count: pickupCount + 1,
        });

        summary = `Auto-pickup: starting ${nextTask.id} (${nextTask.intent}) [${nextTask.priority}]`;
      } catch (err) {
        summary = `Auto-pickup error: ${err.message}`;
      }
      break;
    }

    default:
      summary = `Unknown stage: ${stageStatus}`;
      break;
  }

  // Step 4: Output
  if (summary) {
    try {
      appendEvidence({
        hook: HOOK_NAME,
        event: "TaskCompleted",
        decision: "allow",
        task_id: taskId,
        stage: stageStatus,
        summary,
        session_id: input.sessionId,
      });
    } catch {
      // Non-blocking
    }

    allow(`[${HOOK_NAME}] ${summary}`);
    return;
  }

  allow();
} catch (_err) {
  // Pipeline is operational — fail-open
  allow();
}

// ---------------------------------------------------------------------------
// Exports (for testing)
// ---------------------------------------------------------------------------

module.exports = {
  loadPipelineConfig,
  getTaskData,
  executeTrusted,
  updateBacklog,
  formatCommitMsg,
};
