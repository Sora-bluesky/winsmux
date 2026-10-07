import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { physicalPath } from './distribution-prelaunch.mjs';
import { parseStrictJson } from './assert-license-inputs.mjs';
import { assertWindowsBuildEnvironment } from './windows-distribution-build.mjs';

export const windowsLicenseBindingIdentity = '7f3aa38a96cb9e5c1b6a0f5e1bccecd275f7c4c6e8edbece4e98a77bf2c0c0fe';
const bindingIdentity = windowsLicenseBindingIdentity;
const hash = data => createHash('sha256').update(data).digest('hex');
function requireValue(condition, reason) { if (!condition) throw new Error(reason); }
function plain(file) {
  const resolved = physicalPath(file); const stat = fs.lstatSync(resolved);
  requireValue(stat.isFile() && stat.nlink === 1, 'Distribution input must be a plain single-link file.');
  return fs.readFileSync(resolved);
}

function licenseOptions(assets, binding, version) {
  return { policyPath: path.join(assets, 'policy.json'), policySha256: binding.policy_sha256,
    inputPath: path.join(assets, 'input.json'), catalogPath: path.join(assets, 'manifest.json'),
    catalogSha256: binding.catalog_sha256, textRoot: path.join(assets, 'texts'), sourceRoot: assets, version };
}

/** Existing measured declaration binding. It does not prove binary build origin
 * or native redistribution rights. Other targets require their own measurement.
 */
export function checkedWindowsLicenseBuildInputs({ repoRoot, host, version, rustcCommit }) {
  assertWindowsBuildEnvironment();
  const repo = physicalPath(repoRoot);
  const assets = path.join(repo, 'distribution/windows-licenses');
  const bindingBytes = plain(path.join(assets, 'binding.json'));
  requireValue(hash(bindingBytes) === bindingIdentity, 'Frozen license/build binding differs.');
  const binding = parseStrictJson(bindingBytes);
  requireValue(binding.schema === 'windows-license-build-binding/v1'
    && binding.source_normalization === 'utf8-crlf-to-lf'
    && version === binding.version && host === binding.host && rustcCommit === binding.rustc_commit,
  'This license generation does not cover the requested version, host or Rust toolchain.');
  // This catalog binds the measured Windows build. Other hosts need their own measured binding.
  for (const row of binding.sources) {
    requireValue(typeof row.path === 'string' && !path.isAbsolute(row.path)
      && !row.path.includes('\\') && !row.path.split('/').some(part => !part || part === '..' || part === '.')
      && !/[:\x00-\x1f]/u.test(row.path), 'Invalid bound source path.');
    const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(plain(path.join(repo, row.path)));
    const normalized = text.replaceAll('\r\n', '\n');
    requireValue(!text.startsWith('\ufeff') && !text.includes('\0') && !normalized.includes('\r')
      && hash(Buffer.from(normalized)) === row.sha256, 'Build declaration or dependency inventory changed.');
  }
  requireValue(hash(plain(path.join(assets, 'input.json'))) === binding.input_sha256,
    'Bound license input differs.');
  return { repo, assets, binding, licenseOptions: licenseOptions(assets, binding, version) };
}
