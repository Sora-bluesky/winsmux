import fs from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { physicalPath } from './distribution-prelaunch.mjs';
import { parseStrictJson } from './assert-license-inputs.mjs';
import { windowsDistributionBuildPlan, assertWindowsBuildEnvironment } from './windows-distribution-build.mjs';
import { checkedWindowsLicenseBuildInputs } from './windows-license-build-inputs.mjs';
import { buildDistributionLicenses } from './stage-distribution-licenses.mjs';
import { stageCoreGeneration } from './stage-core-generation.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const coreTargets = new Map([['x86_64-pc-windows-msvc', 'winsmux-x64.exe'],
  ['aarch64-pc-windows-msvc', 'winsmux-arm64.exe']]);
export const coreTargetMeasurementIdentity = 'dcf73ee4dda34898ca3e4445fcb6c333287bc896e20a6bf0d5ca43469810ac7f';
export const bytesHash = raw => createHash('sha256').update(raw).digest('hex');
export function requireCore(value, reason) { if (!value) throw new Error(reason); }
export function readCorePlain(file) {
  const resolved = physicalPath(file), info = fs.lstatSync(resolved);
  requireCore(info.isFile() && info.nlink === 1, 'Core candidate input must be a plain single-link file.');
  return fs.readFileSync(resolved);
}
export function exactCoreObject(value, keys) {
  return value && Object.getPrototypeOf(value) === Object.prototype
    && JSON.stringify(Object.keys(value).sort()) === JSON.stringify(keys.slice().sort());
}

function compilerFileState(file) {
  const stat = fs.lstatSync(physicalPath(file), { bigint: true });
  requireCore(stat.isFile() && stat.dev >= 0n && stat.ino > 0n, 'Plain compiler file identity required.');
  return stat;
}
function unchangedCompilerState(a, b) {
  return ['dev', 'ino', 'nlink', 'size', 'mtimeNs', 'ctimeNs'].every(key => a[key] === b[key]);
}

/** Cargo may hardlink its final image to its own intermediate image. Both links
 * must belong to this exact fresh producer run; external inputs stay single-link.
 * The workspace is exclusively owned, not adversarially replaced concurrently.
 */
export function detachCoreCompilerArtifact(work, target) {
  const ownedRoot = physicalPath(path.join(repo, '.winsmux/build/core-ci'));
  requireCore(coreTargets.has(target) && typeof work === 'string' && path.isAbsolute(work)
    && physicalPath(work) === work && path.dirname(work) === ownedRoot
    && /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/u.test(path.basename(work)),
    'Compiler artifact must belong to a fresh producer namespace.');
  const source = path.join(work, 'target', target, 'release/winsmux.exe');
  const peer = path.join(work, 'intermediate', target, 'release/deps/winsmux.exe');
  const destination = path.join(work, 'producer-executable.exe');
  const before = compilerFileState(source);
  requireCore(before.nlink === 1n || before.nlink === 2n, 'Compiler artifact link inventory differs.');
  const peerBefore = before.nlink === 2n ? compilerFileState(peer) : null;
  requireCore(!peerBefore || (peerBefore.nlink === 2n && peerBefore.dev === before.dev && peerBefore.ino === before.ino
    && peerBefore.size === before.size), 'Compiler artifact peer is not its fixed owned link.');
  const original = fs.readFileSync(physicalPath(source));
  fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL);
  const detached = compilerFileState(destination), bytes = readCorePlain(destination);
  requireCore(detached.nlink === 1n && !(detached.dev === before.dev && detached.ino === before.ino)
    && bytes.equals(original), 'Detached compiler artifact differs.');
  requireCore(unchangedCompilerState(before, compilerFileState(source))
    && original.equals(fs.readFileSync(physicalPath(source)))
    && (!peerBefore || unchangedCompilerState(peerBefore, compilerFileState(peer))), 'Compiler artifact changed during copying.');
  return bytes;
}

/** Host is the compiler process architecture, not the output architecture. */
export function observeCoreCompiler(text) {
  const fields = new Map();
  for (const line of text.trimEnd().split(/\r?\n/u).slice(1)) {
    const match = /^(binary|commit-hash|commit-date|host|release|LLVM version): (.+)$/u.exec(line);
    requireCore(match && !fields.has(match[1]), 'Ambiguous Rust compiler observation.');
    fields.set(match[1], match[2]);
  }
  requireCore(/^rustc 1\.96\.0 \([^\r\n]+\)$/u.test(text.split(/\r?\n/u)[0])
    && fields.size === 6 && fields.get('binary') === 'rustc'
    && fields.get('release') === '1.96.0'
    && /^[a-f0-9]{40}$/u.test(fields.get('commit-hash') ?? '')
    && fields.get('host') === 'x86_64-pc-windows-msvc', 'Unmeasured Core compiler host or version.');
  return { host: fields.get('host'), commit: fields.get('commit-hash'), release: fields.get('release') };
}

/** Conservative non-dev dependency inventory; never a claim about native LIBs. */
export function assertCoreDependencyCoverage(metadata, catalog) {
  requireCore(Array.isArray(metadata?.packages) && Array.isArray(metadata?.resolve?.nodes)
    && Array.isArray(catalog?.components), 'Resolved Core dependency inventory required.');
  const packages = new Map(metadata.packages.map(p => [p.id, p]));
  const nodes = new Map(metadata.resolve.nodes.map(n => [n.id, n]));
  requireCore(packages.size === metadata.packages.length && nodes.size === metadata.resolve.nodes.length,
    'Duplicate dependency identity.');
  const roots = metadata.packages.filter(p => p.name === 'winsmux' && p.source === null);
  requireCore(roots.length === 1 && nodes.has(roots[0].id), 'Exact Core workspace root required.');
  const components = new Map();
  for (const item of catalog.components) {
    const key = `${item.id}\0${item.version}`;
    requireCore(!components.has(key), 'Duplicate license component identity.'); components.set(key, item);
  }
  const reached = new Set(), todo = [roots[0].id];
  while (todo.length) {
    const id = todo.pop(); if (reached.has(id)) continue;
    const p = packages.get(id), node = nodes.get(id);
    requireCore(p && node && Array.isArray(node.deps) && Array.isArray(node.features), 'Incomplete resolved dependency.');
    const license = components.get(`rust/${p.name}\0${p.version}`);
    requireCore(license && license.declared_license === p.license, 'Core dependency license is not covered.');
    reached.add(id);
    for (const dependency of node.deps) {
      requireCore(Array.isArray(dependency.dep_kinds) && dependency.dep_kinds.length > 0
        && dependency.dep_kinds.every(k => k && [null, 'build', 'dev'].includes(k.kind)
          && (k.target === null || typeof k.target === 'string')), 'Incomplete dependency kind.');
      if (dependency.dep_kinds.some(kind => kind.kind !== 'dev')) todo.push(dependency.pkg);
    }
  }
  const rows = [...reached].map(id => {
    const p = packages.get(id), node = nodes.get(id);
    return { name: p.name, version: p.version, source: p.source, license: p.license,
      features: [...node.features].sort(), dependencies: node.deps
        .filter(d => d.dep_kinds.some(k => k.kind !== 'dev')).map(d => ({ name: d.name,
          package: [packages.get(d.pkg)?.name, packages.get(d.pkg)?.version, packages.get(d.pkg)?.source],
          kinds: d.dep_kinds.filter(k => k.kind !== 'dev').map(k => ({ kind: k.kind, target: k.target })) })) };
  }).sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b), 'en'));
  return { packages: rows.length, sha256: bytesHash(Buffer.from(JSON.stringify(rows))) };
}

export function observeCoreArtifact(stdout, expectedExecutable) {
  const messages = stdout.trimEnd().split(/\r?\n/u).map(line => parseStrictJson(Buffer.from(line)));
  const completed = messages.filter(m => m.reason === 'build-finished');
  requireCore(completed.length === 1 && completed[0].success === true
    && messages.at(-1) === completed[0], 'Core Cargo build did not finish successfully.');
  const artifacts = messages.filter(m => m.reason === 'compiler-artifact' && m.target?.name === 'winsmux'
    && m.target.kind?.includes('bin'));
  requireCore(artifacts.length === 1 && artifacts[0].executable === expectedExecutable,
    'Core compiler artifact path differs.');
  requireCore(artifacts[0].profile?.test === false && artifacts[0].profile?.opt_level === '3',
    'Core compiler artifact is not the release binary.');
  return artifacts[0];
}

export function assertCoreTargetMeasurement({ target, version, compiler, bindingSha256, dependency }, raw) {
  requireCore(bytesHash(raw) === coreTargetMeasurementIdentity, 'Core target measurement identity differs.');
  const measured = parseStrictJson(raw);
  requireCore(measured.schema === 'core-target-license-projections/v1' && coreTargets.has(target)
    && measured.version === version && measured.compiler_host === compiler.host
    && measured.rustc_commit === compiler.commit && measured.binding_sha256 === bindingSha256
    && exactCoreObject(measured.targets, [...coreTargets.keys()])
    && JSON.stringify(measured.targets[target]) === JSON.stringify(dependency), 'Core target measurement does not cover this build.');
}

export function canonicalCoreSourceInventory(rows) {
  requireCore(Array.isArray(rows), 'Core source inventory required.');
  const files = new Map();
  for (const row of rows) {
    requireCore(exactCoreObject(row, ['path', 'sha256']) && typeof row.path === 'string'
      && /^[a-f0-9]{64}$/u.test(row.sha256), 'Exact Core source identity required.');
    const name = row.path.replaceAll('\\', '/');
    requireCore(!name.startsWith('/') && !name.includes(':')
      && name.split('/').every(part => part && part !== '.' && part !== '..') && !files.has(name),
    'Core source path or canonical alias differs.');
    files.set(name, row.sha256);
  }
  return [...files].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
    .map(([name, sha256]) => ({ path: name, sha256 }));
}
export function coreSourceInventoryIdentity(rows) {
  return bytesHash(Buffer.from(JSON.stringify(canonicalCoreSourceInventory(rows))));
}
export function coreSourceInventory() {
  const files = new Set(['.gitattributes', 'VERSION', 'Cargo.toml', 'Cargo.lock', 'LICENSE', 'install.ps1', '.github/workflows/release-core.yml']);
  for (const relative of ['core', 'git-graph', 'scripts', 'distribution/windows-licenses']) {
    const walk = directory => {
      for (const item of fs.readdirSync(physicalPath(directory), { withFileTypes: true })) {
        requireCore(!item.isSymbolicLink(), 'Linked Core build source is unsupported.');
        if (['target', '.git', '.evidence', 'node_modules'].includes(item.name)) continue;
        const next = path.join(directory, item.name);
        if (item.isDirectory()) walk(next); else files.add(path.relative(repo, next).replaceAll('\\', '/'));
      }
    }; walk(path.join(repo, relative));
  }
  for (const name of ['winsmux-app/package.json', 'winsmux-app/package-lock.json', 'winsmux-app/src-tauri/Cargo.toml']) files.add(name);
  return canonicalCoreSourceInventory([...files].map(name => ({ path: name, sha256: bytesHash(readCorePlain(path.join(repo, name))) })));
}

/** Execute one private build. A receipt is not a redistribution/publication grant. */
export function buildCoreCandidate(request) {
  requireCore(exactCoreObject(request, ['target', 'sourceCommit', 'releaseTag', 'runIdentity']), 'Exact Core build identity required.');
  const { target, sourceCommit, releaseTag, runIdentity } = request;
  requireCore(coreTargets.has(target) && process.platform === 'win32', 'Supported Windows Core target required.');
  requireCore(/^[a-f0-9]{40}$/u.test(sourceCommit) && /^[A-Za-z0-9._-]+$/u.test(runIdentity), 'Core source/run identity required.');
  assertWindowsBuildEnvironment();
  const before = coreSourceInventory();
  const version = readCorePlain(path.join(repo, 'VERSION')).toString('utf8').replace(/\r?\n$/u, '');
  requireCore(/^\d+\.\d+\.\d+$/u.test(version), 'Exact Core product version required.');
  const invoke = (args, logRoot, name = 'cargo') => {
    const result = spawnSync(args[0], args.slice(1), { cwd: repo, windowsHide: true, maxBuffer: 64 * 1024 * 1024 });
    if (logRoot) {
      fs.writeFileSync(path.join(logRoot, name + '.stdout'), result.stdout ?? Buffer.alloc(0), { flag: 'wx' });
      fs.writeFileSync(path.join(logRoot, name + '.stderr'), result.stderr ?? Buffer.alloc(0), { flag: 'wx' });
      fs.writeFileSync(path.join(logRoot, name + '-exit.json'), JSON.stringify({ status: result.status,
        signal: result.signal, error: result.error?.code ?? null }) + '\n', { flag: 'wx' });
    }
    requireCore(!result.error && result.signal === null && result.status === 0, 'Core build subprocess failed.');
    return { stdout: new TextDecoder('utf-8', { fatal: true }).decode(result.stdout), stderr: result.stderr };
  };
  const compiler = observeCoreCompiler(invoke(['rustc', '-vV']).stdout);
  const commit = invoke(['git', 'rev-parse', 'HEAD']).stdout.trim();
  requireCore(commit === sourceCommit && releaseTag === 'v' + version, 'Core checkout or release tag differs.');
  const { licenseOptions, binding } = checkedWindowsLicenseBuildInputs({ repoRoot: repo,
    host: compiler.host, version, rustcCommit: compiler.commit });
  const work = physicalPath(path.join(repo, '.winsmux/build/core-ci', randomUUID()));
  fs.mkdirSync(work, { recursive: true });
  const metadata = invoke(['cargo', 'metadata', '--manifest-path', path.join(repo, 'Cargo.toml'),
    '--format-version', '1', '--locked', '--filter-platform', target], work, 'metadata');
  const dependency = assertCoreDependencyCoverage(parseStrictJson(Buffer.from(metadata.stdout)),
    parseStrictJson(readCorePlain(licenseOptions.catalogPath)));
  const bindingSha256 = bytesHash(readCorePlain(path.join(repo, 'distribution/windows-licenses/binding.json')));
  assertCoreTargetMeasurement({ target, version, compiler, bindingSha256, dependency },
    readCorePlain(path.join(repo, 'distribution/windows-licenses/core-targets.json')));
  const plan = windowsDistributionBuildPlan({ repoRoot: repo, target,
    targetRoot: path.join(work, 'target'), intermediateRoot: path.join(work, 'intermediate') });
  const build = invoke(['cargo', ...plan.args], work);
  const executablePath = path.join(work, 'target', target, 'release/winsmux.exe');
  observeCoreArtifact(build.stdout, executablePath);
  const executable = detachCoreCompilerArtifact(work, target);
  const { files: licenses } = buildDistributionLicenses(licenseOptions);
  requireCore(JSON.stringify(coreSourceInventory()) === JSON.stringify(before), 'Core build source bytes changed.');
  const staged = stageCoreGeneration({ version, target, executable, licenses });
  requireCore(JSON.stringify(coreSourceInventory()) === JSON.stringify(before), 'Core generation source bytes changed.');
  requireCore(invoke(['git', 'rev-parse', 'HEAD']).stdout.trim() === sourceCommit, 'Core checkout changed during build.');
  const output = path.join(work, 'artifact'); fs.mkdirSync(output);
  for (const row of staged.files) {
    const raw = readCorePlain(path.join(staged.directory, row.path));
    requireCore(raw.length === row.bytes && bytesHash(raw) === row.sha256, 'Core staged artifact changed.');
    fs.writeFileSync(path.join(output, row.path), raw, { flag: 'wx' });
    requireCore(readCorePlain(path.join(output, row.path)).equals(raw), 'Core CI artifact readback differs.');
  }
  const receipt = { schema: 'core-ci-candidate/v1', version, release_tag: releaseTag, target, source_commit: commit, run_identity: runIdentity,
    source_inventory_sha256: coreSourceInventoryIdentity(before), compiler,
    binding_sha256: bindingSha256, target_measurement_sha256: coreTargetMeasurementIdentity,
    build_plan_sha256: bytesHash(readCorePlain(path.join(repo, 'scripts/windows-distribution-build.mjs'))),
    consumer_source_sha256: bytesHash(readCorePlain(path.join(repo, 'install.ps1'))),
    catalog_sha256: binding.catalog_sha256, dependency, license_files: licenses.size, executable_sha256: bytesHash(executable),
    files: staged.files, build_origin_verified: true, native_redistribution_verified: false, publication_admitted: false };
  const receiptBytes = Buffer.from(JSON.stringify(receipt, null, 2) + '\n');
  fs.writeFileSync(path.join(output, 'core-candidate.json'), receiptBytes, { flag: 'wx' });
  requireCore(readCorePlain(path.join(output, 'core-candidate.json')).equals(receiptBytes)
    && JSON.stringify(fs.readdirSync(output).sort()) === JSON.stringify([...staged.files.map(f => f.path), 'core-candidate.json'].sort()),
    'Core candidate receipt readback or inventory differs.');
  for (const row of staged.files) requireCore(bytesHash(readCorePlain(path.join(output, row.path))) === row.sha256,
    'Completed Core candidate bytes differ.');
  requireCore(JSON.stringify(coreSourceInventory()) === JSON.stringify(before)
    && invoke(['git', 'rev-parse', 'HEAD']).stdout.trim() === sourceCommit, 'Completed Core candidate source differs.');
  return { directory: output, receipt };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    requireCore(process.argv.length === 5, 'Usage: build-core-candidate.mjs <target> <source-commit> <release-tag>');
    const runIdentity = process.env.GITHUB_RUN_ID ? `${process.env.GITHUB_RUN_ID}.${process.env.GITHUB_RUN_ATTEMPT}` : 'local-' + randomUUID();
    const result = buildCoreCandidate({ target: process.argv[2], sourceCommit: process.argv[3], releaseTag: process.argv[4], runIdentity });
    if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT, `artifact_path=${result.directory}\n`);
    console.log(JSON.stringify(result));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
