import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { checkedWindowsLicenseBuildInputs } from './windows-license-build-inputs.mjs';

function requireValue(value, message) { if (!value) throw new Error(message); }
function strictText(bytes) {
  requireValue(Buffer.isBuffer(bytes), 'Compiler output must be captured bytes.');
  const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes);
  requireValue(!text.startsWith('\ufeff') && !text.includes('\0'), 'Invalid compiler text.');
  return text;
}

export function readRustcIdentity(result) {
  requireValue(result && !result.error && result.status === 0 && !result.signal,
    'Compiler observation did not complete successfully.');
  const lines = strictText(result.stdout).split(/\r?\n/u);
  const hosts = lines.filter(line => line.startsWith('host:'));
  const commits = lines.filter(line => line.startsWith('commit-hash:'));
  requireValue(hosts.length === 1 && /^host: [A-Za-z0-9_-]+$/u.test(hosts[0]),
    'Compiler host identity must be unique and valid.');
  requireValue(commits.length === 1 && /^commit-hash: [a-f0-9]{40}$/u.test(commits[0]),
    'Compiler commit identity must be unique and valid.');
  return { host: hosts[0].slice(6), rustcCommit: commits[0].slice(13) };
}

/** Shared read-only admission for the actual compiler, not a redistribution grant. */
export function verifyWindowsDistributionCompiler({ repoRoot, rustcResult }) {
  const identity = readRustcIdentity(rustcResult);
  const versionPath = path.join(repoRoot, 'VERSION');
  const stat = fs.lstatSync(versionPath);
  requireValue(stat.isFile() && !stat.isSymbolicLink() && stat.nlink === 1,
    'Product version must be a plain single-link file.');
  const version = strictText(fs.readFileSync(versionPath)).trim();
  requireValue(/^\d+\.\d+\.\d+$/u.test(version), 'Invalid product version.');
  checkedWindowsLicenseBuildInputs({ repoRoot, version, ...identity });
  return { schema: 'windows-distribution-toolchain-proof/v1', accepted: true,
    version, host: identity.host, rustc_commit: identity.rustcCommit };
}

export function inspectCurrentWindowsDistributionCompiler(repoRoot) {
  const rustcResult = spawnSync('rustc', ['-vV'], { windowsHide: true, encoding: null });
  return verifyWindowsDistributionCompiler({ repoRoot, rustcResult });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
    console.log(JSON.stringify(inspectCurrentWindowsDistributionCompiler(repoRoot)));
  } catch {
    // Captured compiler output and local filesystem details are not public errors.
    console.log(JSON.stringify({ schema: 'windows-distribution-toolchain-proof/v1',
      accepted: false, status: 'refused' }));
    process.exitCode = 1;
  }
}
