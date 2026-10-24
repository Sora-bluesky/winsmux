import fs from "node:fs";
import os from "node:os";
import path from "node:path";

function assertOrdinary(absolute) {
  if (process.platform !== "win32") { return; }
  if (!/^[A-Za-z]:\\/u.test(absolute)) {
    throw new Error("Unsupported distribution path namespace: local drive paths are required.");
  }
  for (const component of absolute.slice(3).split(path.sep).filter(Boolean)) {
    if (/[<>:"|?*\x00-\x1f]/u.test(component) || /[. ]$/u.test(component) ||
        /^(?:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)/iu.test(component)) {
      throw new Error("Unsupported distribution path component.");
    }
  }
}

function assertRawComponents(input) {
  if (process.platform !== "win32") { return; }
  const spelling = input.replaceAll("/", "\\");
  if (spelling.startsWith("\\\\") || (/^[A-Za-z]:/u.test(spelling) && !/^[A-Za-z]:\\/u.test(spelling))) {
    throw new Error("Unsupported distribution path namespace: local drive paths are required.");
  }
  const relative = /^[A-Za-z]:\\/u.test(spelling) ? spelling.slice(3) : spelling;
  for (const component of relative.split("\\").filter(Boolean)) {
    if (component === "." || component === "..") { continue; }
    if (/[<>:"|?*\x00-\x1f]/u.test(component) || /[. ]$/u.test(component) ||
        /^(?:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)/iu.test(component)) {
      throw new Error("Unsupported distribution path component.");
    }
  }
}

// Read-only; links and unverifiable existing ancestors are refused.
// The supported operator filesystem is not concurrently replaced.
export function physicalPath(input) {
  assertRawComponents(input);
  const absolute = path.resolve(input);
  assertOrdinary(absolute);
  const { root } = path.parse(absolute);
  let current = root;
  let missing = false;
  for (const component of absolute.slice(root.length).split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    if (missing) { continue; }
    let stat;
    try { stat = fs.lstatSync(current); }
    catch (error) {
      if (error.code !== "ENOENT") { throw error; }
      missing = true;
      continue;
    }
    if (stat.isSymbolicLink()) { throw new Error(`Linked staging/source path is unsupported: ${current}`); }
    current = fs.realpathSync.native(current);
    assertOrdinary(current);
  }
  return current;
}

function identity(stat) {
  if (stat.ino <= 0n || stat.dev < 0n) { throw new Error("Distribution directory identity is unavailable."); }
  return `${stat.dev}:${stat.ino}`;
}

function ancestry(input) {
  const absolute = physicalPath(input);
  const ancestors = new Set();
  let current = absolute;
  let own = null;
  while (true) {
    try {
      const stat = fs.lstatSync(current, { bigint: true });
      if (stat.isSymbolicLink()) { throw new Error("Linked distribution ancestor is unsupported."); }
      const key = identity(stat);
      if (current === absolute) { own = { key, directory: stat.isDirectory() }; }
      if (stat.isDirectory()) { ancestors.add(key); }
      else if (current !== absolute) { throw new Error("Distribution ancestor must be a directory."); }
    } catch (error) {
      if (error.code !== "ENOENT") { throw error; }
    }
    const parent = path.dirname(current);
    if (parent === current) { break; }
    current = parent;
  }
  return { absolute, own, ancestors };
}

// This is the only product-owned PowerShell preparation launch boundary.
// Missing temporary directories are unsupported: no child may create one first.
export function checkedPowerShellEnvironment(repoRoot, protectedOutputs = [], env = process.env, effectiveTemp = os.tmpdir()) {
  const protectedPaths = [repoRoot, ...protectedOutputs].map(ancestry);
  if (!protectedPaths[0].own?.directory) { throw new Error("Preparation checkout must be an existing directory."); }
  const configured = new Map([["TEMP", []], ["TMP", []]]);
  for (const [key, value] of Object.entries(env)) {
    const group = configured.get(key.toUpperCase());
    if (!group || value === undefined || value === "") { continue; }
    if (typeof value !== "string" || !value.trim()) { throw new Error("Invalid preparation temporary environment value."); }
    group.push(value);
  }
  for (const values of configured.values()) {
    if (new Set(values).size > 1) { throw new Error("Conflicting case variants of preparation TEMP/TMP."); }
  }
  const values = [...new Set([effectiveTemp, ...configured.get("TEMP"), ...configured.get("TMP")])];
  const temporary = values.map(value => {
    if (typeof value !== "string" || !path.isAbsolute(value)) {
      throw new Error("Preparation temporary path must be absolute.");
    }
    if (process.platform === "win32" && !/^[A-Za-z]:[/\\]/u.test(value)) {
      throw new Error("Preparation temporary path must be drive-qualified.");
    }
    const temp = ancestry(value);
    if (!temp.own?.directory) { throw new Error("Preparation temporary path must be an existing plain directory."); }
    for (const protectedPath of protectedPaths) {
      if (protectedPath.ancestors.has(temp.own.key) ||
          (protectedPath.own && temp.ancestors.has(protectedPath.own.key))) {
        throw new Error("Preparation temporary directory and protected distribution paths overlap.");
      }
    }
    return temp.absolute;
  });
  const childEnv = {};
  for (const [key, value] of Object.entries(env)) {
    if (!configured.has(key.toUpperCase())) { childEnv[key] = value; }
  }
  childEnv.TEMP = temporary[0];
  childEnv.TMP = temporary[0];
  return childEnv;
}
