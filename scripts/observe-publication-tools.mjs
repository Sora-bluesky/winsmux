import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { physicalPath } from './distribution-prelaunch.mjs';
import { revalidateObservedPublicationPlan } from './plan-integrated-publication.mjs';

// Actual local byte observation only. No PATH search, shell/batch fallback,
// process execution, authorization or custody claim. The native owner must
// separately hold these inputs and the fixed bundle before any dispatch.
const issued = new WeakMap();
const demand = (value, reason) => { if (!value) throw new Error(reason); };
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const keys = ['githubCli', 'nodeExecutable', 'npmCli'];
const identityKeys = ['dev', 'ino', 'nlink', 'size', 'mtimeNs', 'ctimeNs'];
const freeze = value => { if (value && typeof value === 'object') { Object.values(value).forEach(freeze); Object.freeze(value); } return value; };

function observe(file, name) {
  demand(typeof file === 'string' && path.isAbsolute(file) && !file.startsWith('\\\\') && !file.includes('\0'),
    'Exact local absolute tool path required.');
  const target = physicalPath(file);
  demand(path.basename(target).toLowerCase() === name, 'Fixed native tool filename required; no wrapper fallback.');
  const descriptor = fs.openSync(target, 'r');
  try {
    const before = fs.fstatSync(descriptor, { bigint: true });
    demand(before.isFile() && before.nlink === 1n, 'Plain single-link tool source required.');
    const bytes = fs.readFileSync(descriptor);
    const after = fs.fstatSync(descriptor, { bigint: true }), named = fs.lstatSync(target, { bigint: true });
    demand(identityKeys.every(key => before[key] === after[key] && after[key] === named[key]), 'Tool changed during observation.');
    demand(bytes.length > 0 && (!name.endsWith('.exe') || (bytes[0] === 0x4d && bytes[1] === 0x5a)),
      'Native Windows image or nonempty npm source required.');
    return { path: target, bytes: bytes.length, sha256: sha(bytes),
      identity: Object.fromEntries(identityKeys.map(key => [key, String(after[key])])) };
  } finally { fs.closeSync(descriptor); }
}

export function observePublicationTools(paths) {
  demand(paths && JSON.stringify(Object.keys(paths).sort()) === JSON.stringify([...keys].sort()), 'Exact tool path inventory required.');
  const result = freeze({ githubCli: observe(paths.githubCli, 'gh.exe'),
    nodeExecutable: observe(paths.nodeExecutable, 'node.exe'), npmCli: observe(paths.npmCli, 'npm-cli.js'),
    native_custody_verified: false, publication_admitted: false });
  issued.set(result, { ...paths });
  return result;
}

export function revalidatePublicationTools(tools) {
  const paths = issued.get(tools);
  demand(paths, 'Actual process-local tool observation required.');
  for (const [key, name] of [['githubCli', 'gh.exe'], ['nodeExecutable', 'node.exe'], ['npmCli', 'npm-cli.js']])
    demand(JSON.stringify(observe(paths[key], name)) === JSON.stringify(tools[key]), 'Observed tool bytes or native identity changed.');
  return freeze({ local_tool_integrity_verified: true, native_custody_verified: false, publication_admitted: false });
}

export function observedPublicationInvocations(contract, bundle, plan, tools) {
  revalidateObservedPublicationPlan(contract, bundle, plan);
  revalidatePublicationTools(tools);
  return freeze(plan.operations.map(operation => {
    demand(operation.program === 'gh' || operation.program === 'npm', 'Unsupported publication program.');
    const image = operation.program === 'gh' ? tools.githubCli : tools.nodeExecutable;
    return { operation_id: operation.id, kind: operation.kind, executable: image.path,
      executable_sha256: image.sha256,
      arguments: operation.program === 'gh' ? [...operation.arguments] : [tools.npmCli.path, ...operation.arguments],
      additional_read_inputs: operation.program === 'gh' ? [] : [tools.npmCli],
      working_directory: bundle.root, publication_admitted: false };
  }));
}
