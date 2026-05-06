import { defineConfig } from "vite";
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

// @ts-expect-error process is a nodejs global
const host = process.env.TAURI_DEV_HOST;
// @ts-expect-error process is a nodejs global
const projectRoot = process.env.WINSMUX_PROJECT_ROOT || path.resolve(process.cwd(), "..");

const explorerMaxEntries = 1200;

function hasExplorerChildren(dir: string) {
  try {
    return fs.readdirSync(dir, { withFileTypes: true })
      .some((child) => child.isDirectory() || child.isFile());
  } catch {
    return false;
  }
}

function resolveProjectRelativePath(requestedPath: string) {
  const normalizedPath = requestedPath.replace(/\\/g, "/").replace(/^\/+/, "").replace(/\/+$/, "");
  const resolvedPath = path.resolve(projectRoot, normalizedPath);
  const relativePath = path.relative(projectRoot, resolvedPath);
  if (relativePath.startsWith("..") || path.isAbsolute(relativePath)) {
    throw new Error("Invalid project path");
  }

  return {
    normalizedPath: relativePath.replaceAll(path.sep, "/"),
    resolvedPath,
  };
}

function collectGitIgnoredPaths(relativePaths: string[]) {
  if (relativePaths.length === 0) {
    return new Set<string>();
  }

  try {
    const result = spawnSync("git", ["-C", projectRoot, "check-ignore", "-z", "--stdin"], {
      input: `${relativePaths.join("\0")}\0`,
      encoding: "utf8",
      stdio: ["pipe", "pipe", "ignore"],
    });
    if (result.status !== 0 && result.status !== 1) {
      return new Set<string>();
    }
    return new Set(
      result.stdout
        .split("\0")
        .map((item) => item.replace(/\\/g, "/").replace(/\/+$/, ""))
        .filter(Boolean),
    );
  } catch {
    return new Set<string>();
  }
}

function collectExplorerEntries(root: string, basePath = "") {
  const entries: Array<{ path: string; kind: "directory" | "file"; has_children?: boolean; ignored?: boolean }> = [];
  const baseDir = path.resolve(root, basePath);
  const children = fs.readdirSync(baseDir, { withFileTypes: true })
    .sort((left, right) => left.name.localeCompare(right.name, undefined, { sensitivity: "base" }));

  for (const child of children) {
    if (entries.length >= explorerMaxEntries) {
      break;
    }
    const fullPath = path.join(baseDir, child.name);
    const relativePath = path.relative(root, fullPath).replaceAll(path.sep, "/");
    if (!relativePath) {
      continue;
    }
    if (child.isDirectory()) {
      entries.push({ path: relativePath, kind: "directory", has_children: hasExplorerChildren(fullPath) });
    } else if (child.isFile()) {
      entries.push({ path: relativePath, kind: "file" });
    }
  }

  const ignoredPaths = collectGitIgnoredPaths(entries.map((entry) => entry.path));
  return entries.map((entry) => ({
    ...entry,
    ignored: ignoredPaths.has(entry.path) || ignoredPaths.has(`${entry.path}/`),
  }));
}

function serveProjectExplorer(request: { url?: string }, response: { statusCode: number; setHeader: (name: string, value: string) => void; end: (body: string) => void }) {
  try {
    const url = new URL(request.url ?? "", "http://127.0.0.1");
    const requestedPath = url.searchParams.get("path") ?? "";
    const { normalizedPath, resolvedPath } = resolveProjectRelativePath(requestedPath);
    const stat = fs.statSync(resolvedPath);
    if (!stat.isDirectory()) {
      response.statusCode = 404;
      response.end(JSON.stringify({ error: "Project explorer path is not a directory" }));
      return;
    }

    const entries = collectExplorerEntries(projectRoot, normalizedPath);
    response.setHeader("Content-Type", "application/json; charset=utf-8");
    response.end(JSON.stringify({ project_dir: projectRoot, worktree: ".", path: normalizedPath, entries }));
  } catch (error) {
    response.statusCode = 500;
    response.end(JSON.stringify({ error: error instanceof Error ? error.message : String(error) }));
  }
}

function serveProjectFile(request: { url?: string }, response: { statusCode: number; setHeader: (name: string, value: string) => void; end: (body: string) => void }) {
  try {
    const url = new URL(request.url ?? "", "http://127.0.0.1");
    const requestedPath = url.searchParams.get("path") ?? "";
    const { resolvedPath } = resolveProjectRelativePath(requestedPath);
    const relativePath = path.relative(projectRoot, resolvedPath);
    if (!relativePath) {
      response.statusCode = 400;
      response.end(JSON.stringify({ error: "Invalid project file path" }));
      return;
    }

    const stat = fs.statSync(resolvedPath);
    if (!stat.isFile()) {
      response.statusCode = 404;
      response.end(JSON.stringify({ error: "Project file not found" }));
      return;
    }

    const maxBytes = 256 * 1024;
    const buffer = fs.readFileSync(resolvedPath);
    const truncated = buffer.length > maxBytes;
    const content = buffer.subarray(0, maxBytes).toString("utf8");
    response.setHeader("Content-Type", "application/json; charset=utf-8");
    response.end(JSON.stringify({
      path: relativePath.replaceAll(path.sep, "/"),
      content,
      line_count: content.split(/\r?\n/).length,
      truncated,
    }));
  } catch (error) {
    response.statusCode = 500;
    response.end(JSON.stringify({ error: error instanceof Error ? error.message : String(error) }));
  }
}

function runGitRaw(args: string[]) {
  return execFileSync("git", ["-C", projectRoot, ...args], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
}

function runGit(args: string[]) {
  return runGitRaw(args).trim();
}

function mapGitStatus(code: string) {
  if (code.includes("A") || code.includes("?")) {
    return "added";
  }
  if (code.includes("D")) {
    return "deleted";
  }
  if (code.includes("R")) {
    return "renamed";
  }
  return "modified";
}

function mapGitStatusChar(statusChar: string, fallbackCode: string) {
  const normalized = statusChar && statusChar !== " " ? statusChar : fallbackCode;
  return mapGitStatus(normalized);
}

function parseGitStatusPath(rawPath: string) {
  const renameParts = rawPath.split(" -> ");
  return (renameParts[renameParts.length - 1] ?? rawPath).replace(/\\/g, "/");
}

function collectSourceControlChangeRows(line: string, branch: string) {
  const code = line.slice(0, 2);
  const indexStatus = code[0] ?? " ";
  const worktreeStatus = code[1] ?? " ";
  const filePath = parseGitStatusPath(line.slice(2).trim());
  const rows = [];
  const pushRow = (statusChar: string, staged: boolean) => {
    const status = mapGitStatusChar(statusChar, code);
    rows.push({
      path: filePath,
      summary: `${status} ${filePath}`,
      paneLabel: staged ? "index" : "working tree",
      worktree: ".",
      status,
      risk: "low",
      branch,
      lines: statusChar.trim() || "M",
      commitCandidate: true,
      needsAttention: false,
      run: staged ? "index" : "working-tree",
      review: staged ? "staged" : "local",
      staged,
    });
  };

  if (indexStatus !== " " && indexStatus !== "?") {
    pushRow(indexStatus, true);
  }
  if (code === "??" || worktreeStatus !== " ") {
    pushRow(code === "??" ? "?" : worktreeStatus, false);
  }
  if (rows.length === 0 && filePath) {
    pushRow(code.trim() || "M", false);
  }
  return rows;
}

function collectSourceControlSnapshot() {
  const branch = runGit(["rev-parse", "--abbrev-ref", "HEAD"]) || "HEAD";
  const statusText = runGitRaw(["status", "--short", "--untracked-files=all"]).trimEnd();
  const changes = statusText
    ? statusText.split(/\r?\n/).filter(Boolean).flatMap((line) => collectSourceControlChangeRows(line, branch))
    : [];

  const graphText = runGitRaw([
    "log",
    "--topo-order",
    "--pretty=format:%H%x1f%P%x1f%h%x1f%D%x1f%an%x1f%ar%x1f%ad%x1f%s",
    "--date=format:%Y-%m-%d %H:%M",
    "-30",
  ]).trimEnd();
  const graph = graphText
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => {
      const [
        sha = "",
        parentsText = "",
        shortSha = "",
        refsText = "",
        author = "",
        relativeTime = "",
        committedAt = "",
        subject = "",
      ] = line.split("\u001f");
      return {
        run_id: sha,
        short_sha: shortSha,
        parents: parentsText.split(/\s+/).map((parent) => parent.trim()).filter(Boolean),
        task: subject,
        branch,
        refs: refsText.split(",").map((ref) => ref.trim()).filter(Boolean),
        author,
        relative_time: relativeTime,
        committed_at: committedAt,
        changed_files: [],
      };
    });

  return { branch, changes, graph };
}

function serveProjectSourceControl(_request: unknown, response: { statusCode: number; setHeader: (name: string, value: string) => void; end: (body: string) => void }) {
  try {
    response.setHeader("Content-Type", "application/json; charset=utf-8");
    response.end(JSON.stringify(collectSourceControlSnapshot()));
  } catch (error) {
    response.statusCode = 500;
    response.end(JSON.stringify({ error: error instanceof Error ? error.message : String(error) }));
  }
}

// https://vite.dev/config/
export default defineConfig(async () => ({

  // Vite options tailored for Tauri development and only applied in `tauri dev` or `tauri build`
  //
  // 1. prevent Vite from obscuring rust errors
  clearScreen: false,
  // 2. tauri expects a fixed port, fail if that port is not available
  server: {
    port: 1420,
    strictPort: true,
    host: host || false,
    hmr: host
      ? {
          protocol: "ws",
          host,
          port: 1421,
        }
      : undefined,
    watch: {
      // 3. tell Vite to ignore watching `src-tauri`
      ignored: ["**/src-tauri/**"],
    },
  },
  plugins: [{
    name: "winsmux-project-explorer",
    configureServer(server) {
      server.middlewares.use("/__winsmux_project_files", serveProjectExplorer);
      server.middlewares.use("/__winsmux_project_file", serveProjectFile);
      server.middlewares.use("/__winsmux_source_control", serveProjectSourceControl);
    },
    configurePreviewServer(server) {
      server.middlewares.use("/__winsmux_project_files", serveProjectExplorer);
      server.middlewares.use("/__winsmux_project_file", serveProjectFile);
      server.middlewares.use("/__winsmux_source_control", serveProjectSourceControl);
    },
  }],
}));
