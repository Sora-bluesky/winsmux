import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { physicalPath } from './distribution-prelaunch.mjs';
import { parseStrictJson } from './assert-license-inputs.mjs';
import { assertWindowsBuildEnvironment } from './windows-distribution-build.mjs';
import { buildDistributionLicenses } from './stage-distribution-licenses.mjs';

export const desktopCurrentLicenseSourcePath = 'core/crates/winsmux-workspace/src/desktop_current_licenses_v0380.json';

export const windowsLicenseBindingIdentity = '657393576db1a503d75de3ba90480ea804b2d7c6dceb42c7f0a40a31ed5d1110';
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
function checkedBuildInputs({ repoRoot, host, version, rustcCommit }) {
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

/** Generate the fixed Desktop x64 source from the same complete canonical renderer.
 * Core targets are deliberately absent: the verified binding names the compiler host. */
export function renderDesktopCurrentLicenseAuthority(request) {
  const checked = checkedBuildInputs(request);
  const { files } = buildDistributionLicenses(checked.licenseOptions);
  const rows = [...files].map(([relative, bytes]) => ({ path: 'licenses/' + relative,
    bytes: bytes.length, sha256: hash(bytes) })).sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
  const { binding } = checked;
  const authority = { schema: 'winsmux-desktop-current-licenses/v1', version: binding.version, host: binding.host,
    binding_sha256: bindingIdentity, policy_sha256: binding.policy_sha256, input_sha256: binding.input_sha256,
    catalog_sha256: binding.catalog_sha256, files: rows };
  return { ...checked, sourceBytes: Buffer.from(JSON.stringify(authority, null, 2) + '\n') };
}

/** Read-only build admission; the embedded source must be exactly the canonical generation. */
export function checkedWindowsLicenseBuildInputs(request) {
  const { sourceBytes, ...checked } = renderDesktopCurrentLicenseAuthority(request);
  requireValue(plain(path.join(checked.repo, desktopCurrentLicenseSourcePath)).equals(sourceBytes),
    'Embedded Desktop current license source differs from the complete frozen input.');
  return checked;
}
