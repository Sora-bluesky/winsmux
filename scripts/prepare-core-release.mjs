import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { physicalPath } from './distribution-prelaunch.mjs';
import { parseStrictJson } from './assert-license-inputs.mjs';
import { checkedWindowsLicenseBuildInputs } from './windows-license-build-inputs.mjs';
import { buildDistributionLicenses } from './stage-distribution-licenses.mjs';
import { stageCoreGeneration } from './stage-core-generation.mjs';

const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
function requireValue(value, reason) { if (!value) throw new Error(reason); }
function plain(file) {
  const resolved=physicalPath(file), stat=fs.lstatSync(resolved);
  requireValue(stat.isFile() && stat.nlink===1, 'Core input must be a plain single-link file.');
  return fs.readFileSync(resolved);
}

/** Stage a private candidate from trusted local caller-frozen bytes. Declared
 * compiler/hash values are not proof of actual build origin or redistribution.
 */
export function prepareCoreRelease(request) {
  const keys=['executablePath','executableSha256','rustcCommit','target'];
  requireValue(request && Object.getPrototypeOf(request)===Object.prototype
    && JSON.stringify(Object.keys(request).sort())===JSON.stringify(keys)
    && keys.every(key=>typeof request[key]==='string'), 'Exact Core local preparation request required.');
  requireValue(path.isAbsolute(request.executablePath) && /^[a-f0-9]{64}$/u.test(request.executableSha256),
    'Absolute executable path and frozen SHA-256 required.');
  const versionBytes=plain(path.join(repo,'VERSION'));
  const version=new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(versionBytes);
  requireValue(/^\d+\.\d+\.\d+(?:\r?\n)?$/u.test(version), 'Exact repository version required.');
  const productVersion=version.replace(/\r?\n$/u,'');
  const {licenseOptions,binding}=checkedWindowsLicenseBuildInputs({repoRoot:repo,host:request.target,
    version:productVersion,rustcCommit:request.rustcCommit});
  const executable=plain(request.executablePath);
  requireValue(hash(executable)===request.executableSha256, 'Core executable identity differs.');
  const {files:licenses}=buildDistributionLicenses(licenseOptions);
  const receipt=stageCoreGeneration({version:productVersion,target:request.target,executable,licenses});
  return {...receipt,declared_rustc_commit:request.rustcCommit,license_catalog_sha256:binding.catalog_sha256,
    build_origin_verified:false,native_redistribution_verified:false};
}

if (process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {
    requireValue(process.argv.length===3, 'Usage: prepare-core-release.mjs <local-request.json>');
    const request=parseStrictJson(plain(path.resolve(process.argv[2])));
    console.log(JSON.stringify(prepareCoreRelease(request)));
  } catch (error) { console.error(error.message); process.exitCode=1; }
}
