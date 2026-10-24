import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { physicalPath } from './distribution-prelaunch.mjs';

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const roles = new Set(['declaration', 'attribution', 'full_terms', 'notice', 'exception', 'source_availability']);
const exact = (value, fields) => value && typeof value === 'object' && !Array.isArray(value)
  && Object.keys(value).sort().join('\0') === fields.slice().sort().join('\0');
const text = value => typeof value === 'string' && value.length > 0 && value === value.trim();
const hash = value => typeof value === 'string' && /^[a-f0-9]{64}$/u.test(value);
const key = value => `${value.id}\0${value.version}`;
function requireValue(condition, reason) {
  if (!condition) throw new Error(reason);
}
function readPlain(file) {
  const resolved = physicalPath(file);
  const stat = fs.lstatSync(resolved);
  requireValue(stat.isFile() && stat.nlink === 1, 'Input must be a plain single-link file.');
  return fs.readFileSync(resolved);
}
export function parseStrictJson(bytes) {
  const decoded = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes);
  requireValue(!decoded.startsWith('\uFEFF'), 'Input must be BOM-free UTF-8.');
  // Check the grammar before JSON.parse can discard duplicate, escaped-equivalent keys.
  let offset = 0;
  const whitespace = () => { while (/[ \t\r\n]/u.test(decoded[offset] ?? '\0')) offset += 1; };
  function string() {
    requireValue(decoded[offset] === '"', 'Expected a JSON string.');
    const start = offset++;
    while (offset < decoded.length) {
      const character = decoded[offset++];
      if (character === '\\') offset += 1;
      else if (character === '"') return JSON.parse(decoded.slice(start, offset));
    }
    throw new Error('Unterminated JSON string.');
  }
  function value() {
    whitespace();
    if (decoded[offset] === '{') {
      offset += 1;
      whitespace();
      const names = new Set();
      if (decoded[offset] === '}') { offset += 1; return; }
      while (true) {
        whitespace();
        const name = string();
        requireValue(!names.has(name), 'Duplicate JSON property.');
        names.add(name);
        whitespace();
        requireValue(decoded[offset++] === ':', 'Expected a JSON property value.');
        value();
        whitespace();
        const delimiter = decoded[offset++];
        if (delimiter === '}') return;
        requireValue(delimiter === ',', 'Invalid JSON object delimiter.');
      }
    } else if (decoded[offset] === '[') {
      offset += 1;
      whitespace();
      if (decoded[offset] === ']') { offset += 1; return; }
      while (true) {
        value();
        whitespace();
        const delimiter = decoded[offset++];
        if (delimiter === ']') return;
        requireValue(delimiter === ',', 'Invalid JSON array delimiter.');
      }
    } else if (decoded[offset] === '"') string();
    else {
      const start = offset;
      while (offset < decoded.length && !/[ \t\r\n,\]}]/u.test(decoded[offset])) offset += 1;
      requireValue(offset > start, 'Missing JSON value.');
      JSON.parse(decoded.slice(start, offset));
    }
  }
  value();
  whitespace();
  requireValue(offset === decoded.length, 'Unexpected JSON input suffix.');
  return JSON.parse(decoded);
}

/** Check a caller-frozen policy only. This does not certify a binary or publish a distribution. */
export function assertLicenseInputs({ policyPath, policySha256, inputPath, textRoot }) {
  requireValue(hash(policySha256), 'An exact approved policy SHA-256 is required.');
  const policyBytes = readPlain(policyPath);
  requireValue(sha256(policyBytes) === policySha256, 'Approved policy identity differs.');
  const policy = parseStrictJson(policyBytes);
  requireValue(exact(policy, ['schema', 'scope', 'documents', 'components'])
    && policy.schema === 'distribution-license-policy/v1' && policy.scope === 'input-requirements-only'
    && Array.isArray(policy.documents) && policy.documents.length > 0
    && Array.isArray(policy.components) && policy.components.length > 0, 'Unsupported license policy.');
  const approved = new Map();
  for (const document of policy.documents) {
    requireValue(exact(document, ['sha256', 'bytes', 'grants']) && hash(document.sha256)
      && Number.isSafeInteger(document.bytes) && document.bytes > 0
      && Array.isArray(document.grants) && document.grants.length > 0
      && !approved.has(document.sha256), 'Invalid or duplicate approved document.');
    const grants = new Set();
    for (const grant of document.grants) {
      requireValue(exact(grant, ['role', 'license']) && roles.has(grant.role)
        && typeof grant.license === 'string'
        && ((grant.role === 'full_terms' || grant.role === 'exception') ? text(grant.license) : grant.license === ''), 'Invalid approved document role.');
      const grantKey = `${grant.role}\0${grant.license}`;
      requireValue(!grants.has(grantKey), 'Duplicate approved role.');
      grants.add(grantKey);
    }
    approved.set(document.sha256, { bytes: document.bytes, grants });
  }
  const components = new Map();
  for (const component of policy.components) {
    requireValue(exact(component, ['id', 'version', 'declared_license', 'choice', 'requirements'])
      && text(component.id) && !component.id.includes('\0') && text(component.version) && !component.version.includes('\0')
      && (component.declared_license === null || text(component.declared_license)) && text(component.choice)
      && Array.isArray(component.requirements) && component.requirements.length > 0
      && !components.has(key(component)), 'Invalid or duplicate component policy.');
    const required = new Set();
    for (const requirement of component.requirements) {
      requireValue(exact(requirement, ['role', 'license', 'any_of']) && roles.has(requirement.role)
        && typeof requirement.license === 'string'
        && ((requirement.role === 'full_terms' || requirement.role === 'exception') ? text(requirement.license) : requirement.license === '')
        && Array.isArray(requirement.any_of) && requirement.any_of.length > 0
        && new Set(requirement.any_of).size === requirement.any_of.length, 'Invalid required role.');
      const roleKey = `${requirement.role}\0${requirement.license}`;
      requireValue(!required.has(roleKey), 'Duplicate required role.');
      required.add(roleKey);
      for (const identity of requirement.any_of) {
        requireValue(hash(identity) && approved.get(identity)?.grants.has(roleKey), 'Required role lacks an approved original text.');
      }
    }
    requireValue([...required].some(role => role.startsWith('full_terms\0')),
      'A component policy must require approved full terms.');
    requireValue(component.declared_license !== null || required.has('declaration\0'),
      'An undeclared component requires explicit original licensing evidence.');
    components.set(key(component), component);
  }
  const inputBytes = readPlain(inputPath);
  const input = parseStrictJson(inputBytes);
  requireValue(exact(input, ['schema', 'policy_sha256', 'components'])
    && input.schema === 'distribution-license-inputs/v1' && input.policy_sha256 === policySha256
    && Array.isArray(input.components) && input.components.length === components.size, 'Input differs from the fixed component inventory.');
  const root = physicalPath(textRoot);
  requireValue(fs.statSync(root).isDirectory(), 'Text root must be an existing plain directory.');
  const observed = new Set();
  const documentHashes = new Set();
  for (const component of input.components) {
    requireValue(exact(component, ['id', 'version', 'declared_license', 'documents'])
      && text(component.id) && text(component.version) && Array.isArray(component.documents)
      && !observed.has(key(component)), 'Invalid or duplicate input component.');
    observed.add(key(component));
    const expected = components.get(key(component));
    requireValue(expected && component.declared_license === expected.declared_license,
      'Unregistered component, version, or uninterpreted license declaration.');
    const received = new Set();
    for (const document of component.documents) {
      requireValue(exact(document, ['path', 'sha256']) && hash(document.sha256) && text(document.path)
        && !document.path.includes('\\') && !document.path.includes(':')
        && document.path.split('/').every(part => /^[A-Za-z0-9_-][A-Za-z0-9_.-]*$/u.test(part) && !part.endsWith('.'))
        && !path.isAbsolute(document.path) && !received.has(document.sha256), 'Invalid, escaping, or duplicate text path.');
      const destination = physicalPath(path.join(root, ...document.path.split('/')));
      const relative = path.relative(root, destination);
      requireValue(relative && !relative.startsWith('..') && !path.isAbsolute(relative), 'Text path escapes the approved root.');
      const bytes = readPlain(destination);
      const approval = approved.get(document.sha256);
      requireValue(approval && bytes.length === approval.bytes && sha256(bytes) === document.sha256,
        'Text bytes differ from the approved original.');
      // A role is never inferred from a file name, size, or a declaration inside the text.
      received.add(document.sha256);
      documentHashes.add(document.sha256);
    }
    for (const requirement of expected.requirements) {
      requireValue(requirement.any_of.some(identity => received.has(identity)),
        `Required license input is missing: ${requirement.role}.`);
    }
  }
  return { schema: 'distribution-license-input-check/v1', status: 'input_requirements_satisfied',
    scope: 'input-requirements-only', policy_sha256: policySha256, input_sha256: sha256(inputBytes),
    components: observed.size, approved_texts: documentHashes.size, distribution_complete: false };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const argumentsMap = new Map();
    const args = process.argv.slice(2);
    requireValue(args.length === 8, 'Expected --policy, --policy-sha256, --input, and --text-root.');
    for (let index = 0; index < args.length; index += 2) {
      requireValue(['--policy', '--policy-sha256', '--input', '--text-root'].includes(args[index])
        && !argumentsMap.has(args[index]) && text(args[index + 1]), 'Invalid checker arguments.');
      argumentsMap.set(args[index], args[index + 1]);
    }
    console.log(JSON.stringify(assertLicenseInputs({ policyPath: argumentsMap.get('--policy'),
      policySha256: argumentsMap.get('--policy-sha256'), inputPath: argumentsMap.get('--input'), textRoot: argumentsMap.get('--text-root') })));
  } catch (error) {
    // Do not print document contents, local paths, or interpreter source in a public-facing error.
    console.error(JSON.stringify({ schema: 'distribution-license-input-check/v1', status: 'rejected', distribution_complete: false }));
    process.exitCode = 1;
  }
}
