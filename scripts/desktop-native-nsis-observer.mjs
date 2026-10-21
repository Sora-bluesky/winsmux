import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const diagnosticBranch = 'refs/heads/codex/task880-native-lifecycle';
export const retainedOutputLimit = 1023;
const reasons = new Set(['usage', 'context_refused', 'plan_refused', 'actor_refused', 'path_refused',
  'member_unconfirmed', 'registration_conflict', 'legacy_inventory_incomplete', 'legacy_receipt_missing',
  'legacy_profile_incomplete', 'legacy_root_mismatch', 'work_running_or_locked',
  'pending_unconfirmed', 'io_unconfirmed', 'startup_unconfirmed', 'nsis_startup_usage', 'nsis_startup_plan',
  'nsis_startup_path', 'nsis_startup_member', 'nsis_startup_actor', 'nsis_startup_isolation',
  'nsis_startup_launch', 'nsis_startup_receipt', 'nsis_startup_timeout', 'nsis_startup_cleanup']);
export const events = ['install-return', 'uninstall-return', 'install-workspace-failure',
  'uninstall-workspace-failure', 'install-context-failure', 'uninstall-context-failure'];
const registers = [...Array.from({ length: 10 }, (_, n) => '$' + n),
  ...Array.from({ length: 10 }, (_, n) => '$R' + n)];
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const need = (condition, reason) => { if (!condition) throw new Error(reason); };
const exact = (object, keys) => object && typeof object === 'object' && !Array.isArray(object)
  && Object.keys(object).sort().join('\0') === keys.slice().sort().join('\0');
const uint = value => Number.isSafeInteger(value) && value >= 0 && value <= 0xffffffff;
const sha = value => typeof value === 'string' && /^[a-f0-9]{64}$/u.test(value);

export function admitDiagnostic(env, source, format) {
  need(env.GITHUB_ACTIONS === 'true' && env.RUNNER_OS === 'Windows'
    && env.GITHUB_REPOSITORY === 'Sora-bluesky/winsmux' && env.GITHUB_REF === diagnosticBranch
    && /^[a-f0-9]{40}$/u.test(source) && env.GITHUB_SHA === source && format === 'NSIS'
    && /^[1-9][0-9]*$/u.test(env.GITHUB_RUN_ID ?? '') && /^[1-9][0-9]*$/u.test(env.GITHUB_RUN_ATTEMPT ?? ''),
  'nsis_observer_caller_refused');
}

/** This projects held nsExec combined output; it never claims separate stream capture. */
export function projectReturn(rawExit, combined) {
  need(typeof rawExit === 'string' && typeof combined === 'string', 'nsis_observer_return_type_refused');
  let kind = 'unobserved', code = null;
  if (rawExit === 'error' || rawExit === 'timeout') kind = rawExit;
  else if (/^(?:0|[1-9][0-9]{0,9})$/u.test(rawExit) && uint(Number(rawExit))) {
    kind = 'number'; code = Number(rawExit);
  }
  let output = 'rejected', reason = 'unobserved';
  const atLimit = combined.length >= retainedOutputLimit;
  if (!atLimit && combined === '') output = 'empty';
  else if (!atLimit) {
    const match = /^winsmux installer: ([a-z_]+)(?:\r?\n)?$/u.exec(combined);
    if (match && reasons.has(match[1])) { output = 'allowed_reason'; reason = match[1]; }
  }
  return { kind, code, output, reason, held_utf16_units: Math.min(combined.length, retainedOutputLimit),
    held_limit_utf16_units: retainedOutputLimit, truncation: atLimit ? 'possible_at_limit' : 'not_at_limit',
    separate_streams_observed: false };
}

function literal(value) {
  need(typeof value === 'string' && value.length > 0 && !/[\x00-\x1f\x7f]/u.test(value),
    'nsis_observer_literal_refused');
  return value.replaceAll('$', () => '$$').replaceAll('"', () => '$\\"');
}

function saver(name, event, captureRoot) {
  const directory = literal(captureRoot + '\\' + event);
  const write = (file, value) => [
    '  ClearErrors', '  FileOpen $R0 "' + directory + '\\' + file + '" w',
    '  IfErrors +3 0', '  FileWriteUTF16LE $R0 "' + value + '"', '  FileClose $R0'];
  const lines = ['Function ' + name, ...registers.map(register => '  Push ' + register),
    '  GetErrorLevel $R9', '  IfErrors 0 +3', '  StrCpy $R8 1', '  Goto +2', '  StrCpy $R8 0',
    '  ClearErrors', '  CreateDirectory "' + directory + '"'];
  for (const [file, value] of [['exit.utf16', '$0'], ['combined.utf16', '$1'], ['instdir.utf16', '$INSTDIR'],
    ['workspace.utf16', '$WinsmuxWorkspace'], ['source.utf16', '$WinsmuxSource'],
    ['context-path.utf16', '$WinsmuxContext'], ['command.utf16', '$WinsmuxCommand'],
    ['exepath.utf16', '$EXEPATH'], ['errorlevel.utf16', '$R9'], ['errorflag.utf16', '$R8']]) {
    lines.push(...write(file, value));
  }
  lines.push("  System::Call 'kernel32::GetCurrentDirectoryW(i " + '${NSIS_MAX_STRLEN}' + ", w .r2) i.r3'",
    ...write('cwd.utf16', '$2'), ...write('cwd-length.utf16', '$3'),
    "  System::Call 'kernel32::GetCurrentProcessId() i.r3'", ...write('pid.utf16', '$3'));
  for (const [from, to] of [['$WinsmuxContext', 'context.bin'],
    ['$WinsmuxSource\\winsmux.install-plan.json', 'source-plan.bin'],
    ['$WinsmuxHelper', 'helper.exe'], ['$EXEPATH', 'executable.exe']]) {
    lines.push('  ClearErrors', '  CopyFiles /SILENT "' + from + '" "' + directory + '\\' + to + '"');
  }
  // The decision and both NSIS flags are restored after every best-effort write/copy.
  lines.push('  SetErrorLevel $R9', '  ClearErrors', '  StrCmp $R8 0 +2 0', '  SetErrors',
    ...registers.slice().reverse().map(register => '  Pop ' + register), 'FunctionEnd');
  return lines.join('\n');
}

/** The only runtime insertions are after Pop $1 and inside already-taken refusal branches. */
export function instrumentNsis(source, { outputFile, captureRoot }) {
  need(typeof source === 'string' && !source.includes('WINSMUX_ACTUAL_CALLEE_OBSERVER'),
    'nsis_observer_source_already_instrumented');
  const eol = source.includes('\r\n') ? '\r\n' : '\n';
  need(!source.replaceAll('\r\n', '').includes('\r'), 'nsis_observer_mixed_eol_refused');
  let text = source.replaceAll('\r\n', '\n');
  const changes = [];
  const replace = (before, after, reason) => {
    need(text.split(before).length === 2, 'nsis_observer_anchor_' + reason);
    text = text.replace(before, () => after); changes.push({ reason, before, after });
  };
  replace('OutFile "${OUTFILE}"', 'OutFile "' + literal(outputFile) + '"', 'output');
  for (const [prefix, name] of [['', 'WinsmuxObserveInstallReturn'], ['un.', 'un.WinsmuxObserveUninstallReturn']]) {
    const action = prefix ? 'uninstall' : 'install';
    const anchor = '  Call ' + prefix + 'WinsmuxWrite' + (prefix ? 'Uninstall' : 'Install')
      + 'Context\n  nsExec::ExecToStack $WinsmuxCommand\n  Pop $0\n  Pop $1';
    replace(anchor, anchor + '\n  Call ' + name, action + '_return');
  }
  const workspace = '    SetErrorLevel 2\n    Abort "$(WINSMUX_TRANSACTION_FAILED)"\n  ${EndIf}\nFunctionEnd\n!macroend\n!insertmacro WINSMUX_WORKSPACE_FUNCTION';
  replace(workspace, workspace.replace('    Abort ', () => '    Call ${NAME}ObserverFailure\n    Abort '), 'workspace_failure');
  const context = '    SetErrorLevel $2\n    Abort "$(WINSMUX_TRANSACTION_FAILED)"\n  ${EndIf}\nFunctionEnd\n!macroend\n!insertmacro WINSMUX_CONTEXT_FUNCTION';
  replace(context, context.replace('    Abort ', () => '    Call ${NAME}ObserverFailure\n    Abort '), 'context_failure');
  const functions = [
    ['WinsmuxObserveInstallReturn', 'install-return'], ['un.WinsmuxObserveUninstallReturn', 'uninstall-return'],
    ['WinsmuxInitWorkspaceObserverFailure', 'install-workspace-failure'],
    ['un.WinsmuxInitWorkspaceObserverFailure', 'uninstall-workspace-failure'],
    ['WinsmuxWriteInstallContextObserverFailure', 'install-context-failure'],
    ['un.WinsmuxWriteUninstallContextObserverFailure', 'uninstall-context-failure']];
  const addition = '\n; WINSMUX_ACTUAL_CALLEE_OBSERVER: private diagnostic only.\n'
    + functions.map(([name, event]) => saver(name, event, captureRoot)).join('\n\n') + '\n';
  text += addition;
  const result = text.replaceAll('\n', eol);
  // Reverse every declared edit, including exact appended bytes, before accepting D.
  let inverse = result.replaceAll('\r\n', '\n');
  need(inverse.endsWith(addition), 'nsis_observer_function_suffix_refused');
  inverse = inverse.slice(0, -addition.length);
  for (const change of changes.slice().reverse()) {
    need(inverse.split(change.after).length === 2, 'nsis_observer_inverse_ambiguous');
    inverse = inverse.replace(change.after, () => change.before);
  }
  need(inverse.replaceAll('\n', eol) === source, 'nsis_observer_undeclared_difference');
  return { source: result, changes, addition, original_sha256: hash(Buffer.from(source)),
    diagnostic_sha256: hash(Buffer.from(result)), release_admissible: false };
}

export function projectWitness(witness, allowedPaths) {
  need(exact(witness, ['root', 'root_identity', 'files', 'registration', 'shortcuts', 'user_sentinel'])
    && Array.isArray(witness.files) && Array.isArray(witness.registration)
    && Array.isArray(witness.shortcuts) && allowedPaths instanceof Set
    && [...allowedPaths].every(value => typeof value === 'string'
      && /^[A-Za-z0-9._/-]+$/u.test(value) && !value.startsWith('/')
      && !value.split('/').some(part => !part || part === '.' || part === '..')),
    'nsis_observer_witness_shape_refused');
  const id = value => value === null || (typeof value === 'string' && /^[0-9]+:[0-9]+:[0-9]+$/u.test(value));
  const fact = value => {
    need(exact(value, ['bytes', 'sha256', 'identity']) && uint(value.bytes) && sha(value.sha256)
      && id(value.identity), 'nsis_observer_file_fact_refused');
    return { bytes: value.bytes, sha256: value.sha256, identity: value.identity };
  };
  need(id(witness.root_identity), 'nsis_observer_root_identity_refused');
  const selected = [], seen = new Set();
  for (const row of witness.files) {
    need(exact(row, ['path', 'bytes', 'sha256', 'identity']) && typeof row.path === 'string'
      && !seen.has(row.path), 'nsis_observer_witness_row_refused');
    seen.add(row.path);
    if (allowedPaths.has(row.path)) selected.push({ path: row.path, ...fact({ bytes: row.bytes, sha256: row.sha256, identity: row.identity }) });
  }
  return { schema: 'winsmux-nsis-observer-witness/v1', root_identity: witness.root_identity,
    total_files: witness.files.length, unlisted_files: witness.files.length - selected.length, files: selected,
    registration_present_slots: witness.registration.filter(value => value !== null).length,
    shortcut_present_slots: witness.shortcuts.filter(value => value !== null).length,
    user_sentinel: fact(witness.user_sentinel) };
}

export function projectProcess(value) {
  need(value && ['nsis-update', 'nsis-uninstall'].includes(value.purpose) && uint(value.exit_code)
    && value.process && uint(value.process.pid) && uint(value.process.active_members)
    && typeof value.process.terminal === 'boolean' && sha(value.process.image_sha256),
  'nsis_observer_process_refused');
  return { purpose: value.purpose, root_exit_code: value.exit_code, pid: value.process.pid,
    active_members: value.process.active_members, terminal: value.process.terminal,
    image_sha256: value.process.image_sha256, exit_code_scope: 'retained_root_process', helper_exit_observed: false };
}

export function assertPublicSummary(value) {
  need(exact(value, ['schema', 'diagnostic', 'release_admissible', 'source_commit', 'stage', 'observations',
    'original_journey_passed', 'image_cause']) && value.schema === 'winsmux-nsis-actual-callee-observer/v1'
    && value.diagnostic === true && value.release_admissible === false
    && /^[a-f0-9]{40}$/u.test(value.source_commit) && value.stage === 'first_managed_uninstall'
    && value.original_journey_passed === false && value.image_cause === 'unobserved_time_comparison'
    && Array.isArray(value.observations) && value.observations.length === events.length,
  'nsis_observer_public_shape_refused');
  for (let index = 0; index < events.length; index++) {
    const row = value.observations[index];
    need(exact(row, ['event', 'status', 'returned', 'context', 'helper', 'source_plan', 'executable'])
      && row.event === events[index] && ['observed', 'unobserved', 'rejected'].includes(row.status),
    'nsis_observer_public_event_refused');
    if (row.returned !== null) {
      const r = row.returned;
      need(exact(r, ['kind', 'code', 'output', 'reason', 'held_utf16_units', 'held_limit_utf16_units', 'truncation', 'separate_streams_observed'])
        && ['number', 'error', 'timeout', 'unobserved'].includes(r.kind)
        && (r.kind === 'number' ? uint(r.code) : r.code === null)
        && ['empty', 'allowed_reason', 'rejected'].includes(r.output)
        && (r.output === 'allowed_reason' ? reasons.has(r.reason) : r.reason === 'unobserved')
        && Number.isSafeInteger(r.held_utf16_units) && r.held_utf16_units >= 0 && r.held_utf16_units <= retainedOutputLimit
        && r.held_limit_utf16_units === retainedOutputLimit && ['possible_at_limit', 'not_at_limit'].includes(r.truncation)
        && r.separate_streams_observed === false, 'nsis_observer_public_return_refused');
    }
    for (const name of ['context', 'helper', 'source_plan', 'executable']) {
      const f = row[name];
      need(f === null || (exact(f, ['bytes', 'sha256']) && uint(f.bytes) && sha(f.sha256)),
        'nsis_observer_public_identity_refused');
    }
  }
  return value;
}

function plain(file, limit = 67108864) {
  const stat = fs.lstatSync(file, { bigint: true });
  need(stat.isFile() && !stat.isSymbolicLink() && stat.nlink === 1n && stat.size <= BigInt(limit),
    'nsis_observer_plain_file_required');
  const bytes = fs.readFileSync(file), after = fs.lstatSync(file, { bigint: true });
  need(stat.dev === after.dev && stat.ino === after.ino && stat.size === after.size
    && stat.mtimeNs === after.mtimeNs && bytes.length === Number(stat.size), 'nsis_observer_read_changed');
  return bytes;
}

function utf16(file) {
  const bytes = plain(file, 32768);
  need(bytes.length % 2 === 0, 'nsis_observer_utf16_length_refused');
  const text = new TextDecoder('utf-16le', { fatal: true, ignoreBOM: true }).decode(bytes);
  need(!text.includes('\0') && !text.includes('\ufeff'), 'nsis_observer_utf16_content_refused');
  return text;
}

export function collectPrivate(captureRoot, sourceCommit) {
  const summary = { schema: 'winsmux-nsis-actual-callee-observer/v1', diagnostic: true, release_admissible: false,
    source_commit: sourceCommit, stage: 'first_managed_uninstall', observations: [],
    original_journey_passed: false, image_cause: 'unobserved_time_comparison' };
  for (const event of events) {
    const row = { event, status: 'unobserved', returned: null, context: null, helper: null, source_plan: null, executable: null };
    const directory = path.join(captureRoot, event);
    try {
      const stat = fs.lstatSync(directory); need(stat.isDirectory() && !stat.isSymbolicLink(), 'capture_not_directory');
      const rawExit = utf16(path.join(directory, 'exit.utf16'));
      const combined = utf16(path.join(directory, 'combined.utf16'));
      // Refusal branches have no callee return; the saved registers are private context only.
      if (event.endsWith('-return')) row.returned = projectReturn(rawExit, combined);
      for (const [key, name] of [['context', 'context.bin'], ['helper', 'helper.exe'],
        ['source_plan', 'source-plan.bin'], ['executable', 'executable.exe']]) {
        try { const bytes = plain(path.join(directory, name)); row[key] = { bytes: bytes.length, sha256: hash(bytes) }; }
        catch { /* A missing best-effort copy remains unobserved. */ }
      }
      row.status = 'observed';
    } catch (error) { if (error.code !== 'ENOENT') row.status = 'rejected'; }
    summary.observations.push(row);
  }
  return assertPublicSummary(summary);
}



function compilePath(value) {
  return typeof value === 'string' && /^[A-Za-z]:\\/u.test(value) && path.win32.normalize(value) === value
    && value.slice(3).split('\\').every(part => part.length > 0 && !/[<>:"|?*\x00-\x1f\x7f]/u.test(part)
      && !/[. ]$/u.test(part) && !/^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)/iu.test(part));
}
export function auditCompilerReferences(source, allowedAbsolute, sdkIncludes) {
  need(typeof source === 'string' && allowedAbsolute instanceof Set && sdkIncludes instanceof Set,
    'nsis_observer_reference_audit_refused');
  const macros = new Set(['${MAINBINARYSRCPATH}','${WINSMUX_NSIS_HELPER_PATH}','${WINSMUX_NSIS_PLAN_PATH}',
    '${WEBVIEW2BOOTSTRAPPERPATH}','${WEBVIEW2INSTALLERPATH}']);
  for (const line of source.split(/\r?\n/u)) {
    if (/^\s*;/u.test(line)) continue;
    const include = /^\s*!include\s+(?:"([^"]+)"|([^\s]+))\s*$/u.exec(line);
    if (include) {
      const value = include[1] ?? include[2];
      const relative = !value.includes('$') && !path.win32.isAbsolute(value)
        && !value.split(/[\\/]/u).some(part => !part || part === '.' || part === '..')
        && sdkIncludes.has(value.replaceAll('\\','/').toLowerCase());
      need(allowedAbsolute.has(value) || value === '${WINSMUX_NSIS_INPUTS}\\winsmux-utils.nsh' || relative,
        'nsis_observer_include_reference_refused');
    } else need(!/^\s*!include\b/u.test(line),'nsis_observer_include_syntax_refused');
    if (/^\s*File\s/u.test(line)) {
      const values = [...line.matchAll(/"(?:\$\\"|[^"\r\n])*"/gu)];
      const last = values.at(-1)?.[0]?.slice(1,-1);
      need(typeof last === 'string' && !/^\s*File\s+\/r\b/iu.test(line)
        && (allowedAbsolute.has(last.replaceAll('$$','$').replaceAll('$\\"','"')) || macros.has(last)),
        'nsis_observer_file_reference_refused');
    }
    need(!/^\s*ReserveFile\b/iu.test(line),'nsis_observer_reserve_reference_refused');
  }
  return true;
}


export function decodeCompilerText(bytes) {
  need(Buffer.isBuffer(bytes), 'nsis_observer_compiler_text_refused');
  const text=new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(bytes);
  need(Buffer.from(text,'utf8').equals(bytes),'nsis_observer_compiler_encoding_refused');
  return text;
}

/** A finite token transform. Every replacement is reversible; unknown absolute references fail closed. */
export function rebindCompilerText(source, mappings, { unsigned = false } = {}) {
  need(typeof source === 'string' && Array.isArray(mappings), 'nsis_observer_rebind_input_refused');
  const bySource = new Map(), used = new Set(), changes = [], destinations = new Set();
  for (const entry of mappings) {
    need(exact(entry, ['from', 'to']) && compilePath(entry.from) && compilePath(entry.to)
      && !bySource.has(entry.from.toLowerCase()) && !destinations.has(entry.to.toLowerCase()), 'nsis_observer_rebind_map_refused');
    destinations.add(entry.to.toLowerCase());
    bySource.set(entry.from.toLowerCase(), entry);
  }
  const directives = new Set(['if','else','endif','include','macro','error','macroend','ifndef','ifdef','define','undef','addplugindir','uninstfinalize','insertmacro']);
  for (const line of source.split(/\r?\n/u)) {
    const directive = /^\s*!(\w+)/u.exec(line);
    need(!directive || directives.has(directive[1]), 'nsis_observer_compile_directive_refused');
    const outside = line.replace(/"(?:\$\\"|[^"\r\n])*"/gu, '');
    need(/^\s*;/u.test(line) || !/[A-Za-z]:[\\/]/u.test(outside), 'nsis_observer_unquoted_reference_refused');
  }
  let result = source;
  if (unsigned) {
    const match = /^!define UNINSTALLERSIGNCOMMAND "[^\r\n]*"$/gmu;
    const values = [...result.matchAll(match)];
    need(values.length === 1 && values[0][0].includes('--sign-asset') && values[0][0].includes('--unsigned')
      && values[0][0].includes('%1'), 'nsis_observer_signer_shape_refused');
    const before = values[0][0], after = '!define UNINSTALLERSIGNCOMMAND ""';
    result = result.replace(before, () => after); changes.push({ before, after });
  }
  result = result.replace(/"(?:\$\\"|[^"\r\n])*"/gu, token => {
    const encoded = token.slice(1, -1);
    if (!/^[A-Za-z]:[\\/]/u.test(encoded)) return token;
    const decoded = encoded.replaceAll('$$', '$').replaceAll('$\\"', '"');
    need('"' + literal(decoded) + '"' === token, 'nsis_observer_literal_not_canonical');
    const entry = bySource.get(decoded.toLowerCase());
    need(entry && decoded === entry.from, 'nsis_observer_unknown_compile_reference');
    used.add(entry.from);
    const after = '"' + literal(entry.to) + '"'; changes.push({ before: token, after }); return after;
  });
  let inverse = result;
  for (const change of changes.slice().reverse()) {
    const at = inverse.lastIndexOf(change.after);
    need(at >= 0, 'nsis_observer_rebind_inverse_missing');
    inverse = inverse.slice(0, at) + change.before + inverse.slice(at + change.after.length);
  }
  need(inverse === source, 'nsis_observer_rebind_inverse_changed');
  need(!/^\s*!(?:system|execute|packhdr|finalize|appendfile|delfile|tempfile|cd|addincludedir)\b/imu.test(result),
    'nsis_observer_compile_directive_refused');
  const finalizers = result.split(/\r?\n/u).filter(line => /^\s*!uninstfinalize\b/iu.test(line));
  need(finalizers.length === (unsigned ? 1 : 0) && finalizers.every(line => line.trim() === "!uninstfinalize '${UNINSTALLERSIGNCOMMAND}'"),
    'nsis_observer_compile_callback_refused');
  return { source: result, changes, used: [...used] };
}

export function projectNssGui(original, inputSha, nsisSha, planGui) {
  need(Buffer.isBuffer(original) && sha(inputSha) && sha(nsisSha) && planGui && uint(planGui.bytes)
    && sha(planGui.sha256) && hash(original) === inputSha, 'nsis_observer_gui_origin_refused');
  const marker = Buffer.from('__TAURI_BUNDLE_TYPE_VAR_'), at = original.indexOf(marker);
  need(at >= 0 && original.indexOf(marker, at + 1) < 0 && original.toString('ascii', at + marker.length, at + marker.length + 3) === 'UNK',
    'nsis_observer_gui_marker_refused');
  const projected = Buffer.from(original); projected.write('NSS', at + marker.length, 3, 'ascii');
  need(projected.length === original.length && projected.length === planGui.bytes && hash(projected) === nsisSha
    && nsisSha === planGui.sha256, 'nsis_observer_gui_projection_refused');
  return projected;
}


/** Project only after assertCanonicalBundledDistribution has checked the complete frozen generation. */
export function selectTransportLicenseRows(manifest) {
  need(manifest && Array.isArray(manifest.files), 'nsis_observer_license_inventory_refused');
  const seen = new Set(), rows = [];
  for (const row of manifest.files) {
    if (typeof row?.path !== 'string' || !row.path.toLowerCase().startsWith('licenses/')) continue;
    need(exact(row, ['path','bytes','sha256']) && row.path.startsWith('licenses/') && uint(row.bytes) && row.bytes > 0
      && sha(row.sha256) && /^[A-Za-z0-9._/-]+$/u.test(row.path)
      && !row.path.split('/').some(part => !part || part === '.' || part === '..')
      && !seen.has(row.path.toLowerCase()), 'nsis_observer_license_inventory_refused');
    seen.add(row.path.toLowerCase()); rows.push({role:'license',path:row.path,bytes:row.bytes,sha256:row.sha256});
  }
  need(seen.has('licenses/manifest.json') && seen.has('licenses/third_party_notices.txt'),
    'nsis_observer_license_inventory_refused');
  return rows;
}

/** The UI name is an input; the installed identity is the canonical content-addressed text. */
export function bindUiLicense(sourceBytes, generation, plan, canonicalBytes, renderedUiBytes) {
  need(Buffer.isBuffer(sourceBytes) && sourceBytes.length > 0 && Buffer.isBuffer(canonicalBytes)
    && Buffer.isBuffer(renderedUiBytes) && plan && Array.isArray(plan.files), 'nsis_observer_license_identity_refused');
  const identity=hash(sourceBytes),relative='licenses/texts/'+identity;
  const generated=selectTransportLicenseRows(generation).filter(row=>row.path===relative);
  const planned=plan.files.filter(row=>row?.path===relative);
  need(generated.length===1 && planned.length===1 && exact(planned[0],['role','path','bytes','sha256'])
    && planned[0].role==='license' && generated[0].bytes===sourceBytes.length && generated[0].sha256===identity
    && planned[0].bytes===generated[0].bytes && planned[0].sha256===generated[0].sha256 && canonicalBytes.equals(sourceBytes)
    && renderedUiBytes.equals(Buffer.concat([Buffer.from([0xef,0xbb,0xbf]),sourceBytes])),
    'nsis_observer_license_identity_refused');
  return {path:relative,bytes:sourceBytes.length,sha256:identity};
}

function assertBuild(value, sourceCommit) {
  need(exact(value, ['schema','diagnostic','release_admissible','source_commit','original','diagnostic_setup','compiler',
    'closure_files','closure_sha256','original_unchanged']) && value.schema === 'winsmux-nsis-observer-build/v1'
    && value.diagnostic === true && value.release_admissible === false && value.source_commit === sourceCommit
    && value.original_unchanged === true && uint(value.closure_files) && value.closure_files > 0 && sha(value.closure_sha256),
    'nsis_observer_build_refused');
  for (const key of ['original','diagnostic_setup','compiler']) need(exact(value[key], ['bytes','sha256'])
    && uint(value[key].bytes) && sha(value[key].sha256), 'nsis_observer_build_identity_refused');
  return value;
}


export function extractTransportModule(source) {
  need(typeof source === 'string', 'nsis_observer_transport_source_refused');
  const matches = [...source.matchAll(/^function Get-DesktopNativeTransportModule \{\r?\n    return @'\r?\n([\s\S]*?)\r?\n'@\r?\n\}/gmu)];
  need(matches.length === 1, 'nsis_observer_transport_module_refused');
  return matches[0][1];
}


export async function assertCompilerSnapshot(snapshot) {
  need(snapshot && Array.isArray(snapshot.files) && Array.isArray(snapshot.directories), 'nsis_observer_snapshot_refused');
  const { pathToFileURL }=await import('node:url');
  const { physicalPath }=await import(pathToFileURL(path.join(snapshot.repo_root,'scripts/distribution-prelaunch.mjs')));
  const physical=file=>{need(physicalPath(file)===path.resolve(file),'nsis_observer_path_alias_refused');};
  for(const row of snapshot.files){physical(row.path);const stat=fs.lstatSync(row.path,{bigint:true});const bytes=plain(row.path);
    need(String(stat.dev)===row.dev&&String(stat.ino)===row.ino&&String(stat.mtimeNs)===row.mtime_ns
      && bytes.length===row.bytes&&hash(bytes)===row.sha256,'nsis_observer_origin_changed');}
  for(const row of snapshot.directories){physical(row.path);const stat=fs.lstatSync(row.path,{bigint:true});
    need(stat.isDirectory()&&!stat.isSymbolicLink()&&String(stat.dev)===row.dev&&String(stat.ino)===row.ino
      && JSON.stringify(fs.readdirSync(row.path).sort())===JSON.stringify(row.names),'nsis_observer_origin_directory_changed');}
}

/** Read-only whole preparation. The caller owns admission, transport, fresh writes and compilation. */
export async function prepareCompilerClosure({repoRoot,releaseDirectory,sdkRoot,diagnosticDirectory}) {
  const repo=path.resolve(repoRoot);
  const { pathToFileURL }=await import('node:url');
  const { physicalPath }=await import(pathToFileURL(path.join(repo,'scripts/distribution-prelaunch.mjs')));
  const { parseStrictJson }=await import(pathToFileURL(path.join(repo,'scripts/assert-license-inputs.mjs')));
  const { assertCanonicalBundledDistribution }=await import(pathToFileURL(path.join(repo,'scripts/stage-bundled-distribution.mjs')));
  const physical=file=>{const full=path.resolve(file);need(physicalPath(file)===full,'nsis_observer_path_alias_refused');return full;};
  physical(repo);const release=physical(releaseDirectory),sdk=physical(sdkRoot),diagnostic=physical(diagnosticDirectory),source=path.join(repo,'winsmux-app/src-tauri');
  need(![repo,release,sdk].some(root=>diagnostic===root||root.startsWith(diagnostic+path.sep)||diagnostic.startsWith(root+path.sep)), 'nsis_observer_destination_overlap');
  const originals=new Map(),directories=new Map(),copies=new Map();
  const trackDir=dir=>{physical(dir);const stat=fs.lstatSync(dir,{bigint:true});need(stat.isDirectory()&&!stat.isSymbolicLink(),'nsis_observer_directory_refused');
    const row={path:dir,dev:String(stat.dev),ino:String(stat.ino),names:fs.readdirSync(dir).sort()};
    if(directories.has(dir))need(JSON.stringify(directories.get(dir))===JSON.stringify(row),'nsis_observer_origin_directory_changed');directories.set(dir,row);};
  const track=(file,to=null)=>{const full=physical(file),bytes=plain(full),stat=fs.lstatSync(full,{bigint:true});
    const row={path:full,bytes:bytes.length,sha256:hash(bytes),dev:String(stat.dev),ino:String(stat.ino),mtime_ns:String(stat.mtimeNs)};
    if(originals.has(full))need(JSON.stringify(originals.get(full))===JSON.stringify(row),'nsis_observer_input_changed');originals.set(full,row);trackDir(path.dirname(full));
    if(to){const destination=physical(to);need(destination.startsWith(diagnostic+path.sep),'nsis_observer_destination_escape');const key=destination.toLowerCase();
      need(!copies.has(key)||copies.get(key).origin===full,'nsis_observer_destination_collision');copies.set(key,{path:destination,bytes,origin:full,origin_sha256:row.sha256,transform:'copy'});}
    return bytes;};
  const mapRows=[];const map=(from,to)=>{if(!mapRows.some(row=>row.from===from))mapRows.push({from,to});track(from,to);};
  const walk=(root,to)=>{trackDir(root);const names=fs.readdirSync(root).sort();need(new Set(names.map(x=>x.toLowerCase())).size===names.length,'nsis_observer_case_collision');
    for(const name of names){const file=path.join(root,name),stat=fs.lstatSync(file);need(!stat.isSymbolicLink(),'nsis_observer_link_refused');if(stat.isDirectory())walk(file,path.join(to,name));else track(file,path.join(to,name));}};
  const guiPath=path.join(release,'winsmux-app.exe'),phasePath=guiPath+'.winsmux-bundle-phase.json',planPath=guiPath+'.winsmux-nsis-plan.json',includePath=guiPath+'.winsmux-nsis-plan.nsh';
  const generationPath=path.join(source,'binaries/distribution-manifest.json'),renderedPath=path.join(release,'nsis/x64/installer.nsi');
  const phase=parseStrictJson(track(phasePath)),generationBytes=track(generationPath),generation=parseStrictJson(generationBytes),planBytes=track(planPath),plan=parseStrictJson(planBytes),includeBytes=track(includePath);
  need(phase.schema==='winsmux-desktop-bundle-phase/v1'&&phase.phase==='frozen'&&phase.signed===false&&Array.isArray(phase.records)
    && phase.records.filter(row=>row.flavor==='nsis').length===1&&hash(generationBytes)===phase.generation_manifest_sha256,'nsis_observer_phase_refused');
  const record=phase.records.find(row=>row.flavor==='nsis');
  need(record.compiler_inputs_ready===true&&hash(planBytes)===record.plan_sha256&&hash(includeBytes)===record.include_sha256,'nsis_observer_plan_phase_refused');
  const assets=path.join(repo,'distribution/windows-licenses'),binding=parseStrictJson(track(path.join(assets,'binding.json')));
  const within=(root,relative)=>{need(typeof relative==='string'&&!path.isAbsolute(relative)&&!relative.split(/[/\\]/u).some(x=>!x||x==='.'||x==='..'),'nsis_observer_source_path_refused');const full=path.resolve(root,relative);need(full.startsWith(root+path.sep),'nsis_observer_source_path_escape');return full;};
  for(const row of binding.sources)track(within(repo,row.path));
  const input=parseStrictJson(track(path.join(assets,'input.json'))),catalog=parseStrictJson(track(path.join(assets,'manifest.json')));track(path.join(assets,'policy.json'));
  for(const row of input.components)for(const document of row.documents)track(within(path.join(assets,'texts'),document.path));
  for(const row of catalog.source_obligations)if(row.source_path)track(within(assets,row.source_path));
  for(const file of ['nsis/winsmux_nsis_utils.dll','nsis/winsmux-utils.nsh'])track(path.join(source,file));
  const scriptQueue=['scripts/stage-bundled-distribution.mjs','scripts/distribution-prelaunch.mjs','scripts/assert-license-inputs.mjs','scripts/stage-desktop-msi-plan.mjs'],seenScripts=new Set();
  while(scriptQueue.length){const relative=scriptQueue.pop();if(seenScripts.has(relative))continue;seenScripts.add(relative);const body=decodeCompilerText(track(path.join(repo,relative)));
    for(const match of body.matchAll(/(?:from\s+|import\s*\()(['"])(\.\/[^'"\r\n]+)\1/gu)){const child=path.posix.normalize(path.posix.join(path.posix.dirname(relative),match[2]));need(child.startsWith('scripts/'),'nsis_observer_source_script_escape');scriptQueue.push(child);}}
  assertCanonicalBundledDistribution({repoRoot:repo,host:phase.host,version:phase.version,rustcCommit:binding.rustc_commit,projectOutput:release});
  // Snapshot the other published C assets too; no producer or callback is invoked.
  for(const file of [guiPath+'.winsmux-msi-plan.json',guiPath+'.winsmux-plan.wxi',path.join(release,'winsmux_app_lib.dll'),
    path.join(release,'bundle/msi/winsmux_0.38.0_x64_en-US.msi'),path.join(release,'bundle/msi/winsmux_0.38.0_x64_ja-JP.msi')])track(file);
  const setup=track(path.join(release,'bundle/nsis/winsmux_0.38.0_x64-setup.exe'));
  need(Array.isArray(record.artifacts)&&record.artifacts.length===1&&record.artifacts[0].output==='setup'
    &&record.artifacts[0].bytes===setup.length&&record.artifacts[0].sha256===hash(setup),'nsis_observer_original_setup_refused');
  const dSource=path.join(diagnostic,'source/winsmux-app/src-tauri'),dRelease=path.join(diagnostic,'build/release'),dSdk=path.join(diagnostic,'sdk');
  map(generationPath,path.join(dSource,'binaries/distribution-manifest.json'));
  const config=parseStrictJson(track(path.join(source,'tauri.conf.json')));track(path.join(source,'nsis/installer.nsi'));track(path.join(repo,'scripts/stage-desktop-msi-plan.mjs'));
  need(config.bundle?.windows?.signCommand?.cmd==='node'&&JSON.stringify(config.bundle.windows.signCommand.args)===JSON.stringify(['../../scripts/stage-desktop-msi-plan.mjs','--sign-asset','%1','--unsigned']),'nsis_observer_sign_config_refused');
  const licensePath=config.bundle.licenseFile?physical(path.resolve(source,config.bundle.licenseFile)):null,renderedLicensePath=path.join(release,'nsis/x64/license_file');
  if(licensePath){const bytes=track(licensePath),canonical=track(path.join(source,'binaries','licenses/texts',hash(bytes))),ui=track(renderedLicensePath);
    bindUiLicense(bytes,generation,plan,canonical,ui);map(licensePath,path.join(diagnostic,'source/distribution/windows-licenses/MICROSOFT-COMPONENT-TERMS.txt'));map(renderedLicensePath,path.join(dRelease,'nsis/x64/license_file'));
    // The hook reaches the Japanese page text relative to its own directory, so it keeps the source-tree offset.
    map(path.join(assets,'MICROSOFT-COMPONENT-TERMS.ja.txt'),path.join(diagnostic,'source/distribution/windows-licenses/MICROSOFT-COMPONENT-TERMS.ja.txt'));}
  for(const row of generation.files){need(typeof row.path==='string'&&/^[A-Za-z0-9._/-]+$/u.test(row.path)&&!row.path.split('/').some(x=>!x||x==='.'||x==='..'),'nsis_observer_generation_path_refused');
    const from=path.join(source,'binaries',row.path),to=path.join(dSource,'binaries',row.path),bytes=track(from,to);need(bytes.length===row.bytes&&hash(bytes)===row.sha256,'nsis_observer_generation_changed');map(from,to);}
  const expected=[...selectTransportLicenseRows(generation),{role:'gui',path:'winsmux-app.exe',bytes:track(guiPath).length,sha256:record.gui_sha256},
    ...[['cli','winsmux.exe','winsmux-'+phase.host+'.exe'],['mcp','winsmux-workspace-mcp.exe','winsmux-workspace-mcp-'+phase.host+'.exe']].map(([role,name,relative])=>{const bytes=track(path.join(source,'binaries',relative));return {role,path:name,bytes:bytes.length,sha256:hash(bytes)};})].sort((a,b)=>a.path<b.path?-1:a.path>b.path?1:0);
  need(plan.schema==='winsmux-desktop-install-plan/v1'&&plan.flavor==='nsis'&&plan.version===phase.version&&plan.host===phase.host
    &&JSON.stringify(plan.files)===JSON.stringify(expected),'nsis_observer_plan_inventory_refused');
  const hooks=path.join(source,'nsis-installer-hooks.nsh');map(hooks,path.join(dSource,'nsis-installer-hooks.nsh'));
  // assertCanonicalBundledDistribution/assertNsisGeneration owns hook content and its generation anchor.
  map(guiPath,path.join(dRelease,'winsmux-app.exe'));map(planPath,path.join(dRelease,'winsmux-app.exe.winsmux-nsis-plan.json'));map(includePath,path.join(dRelease,'winsmux-app.exe.winsmux-nsis-plan.nsh'));
  const languageDir=path.join(release,'nsis/x64');for(const language of ['English','Japanese'])map(path.join(languageDir,language+'.nsh'),path.join(dRelease,'nsis/x64',language+'.nsh'));
  const additional=path.join(languageDir,'Plugins/x86-unicode/additional');walk(additional,path.join(dRelease,'nsis/x64/Plugins/x86-unicode/additional'));mapRows.push({from:additional,to:path.join(dRelease,'nsis/x64/Plugins/x86-unicode/additional')});
  walk(sdk,dSdk);track(path.join(sdk,'makensis.exe'));track(path.join(sdk,'Bin/makensis.exe'));
  const rendered=decodeCompilerText(track(renderedPath)),include=decodeCompilerText(includeBytes),rebound=rebindCompilerText(rendered,mapRows,{unsigned:true}),reboundInclude=rebindCompilerText(include,mapRows);
  const allowedAbsolute=new Set(mapRows.map(row=>row.to)),sdkIncludes=new Set([...copies.values()].filter(item=>item.origin.startsWith(path.join(sdk,'Include')+path.sep)).map(item=>path.relative(path.join(sdk,'Include'),item.origin).replaceAll('\\','/').toLowerCase()));
  auditCompilerReferences(rebound.source,allowedAbsolute,sdkIncludes);
  const transforms=new Map([[includePath,{bytes:Buffer.from(reboundInclude.source),kind:'rebind',changes:reboundInclude.changes}]]);
  for(const item of copies.values())if(!item.origin.startsWith(sdk+path.sep)&&item.origin.endsWith('.nsh')&&item.origin!==includePath){const result=rebindCompilerText(decodeCompilerText(item.bytes),mapRows);auditCompilerReferences(result.source,allowedAbsolute,sdkIncludes);transforms.set(item.origin,{bytes:Buffer.from(result.source),kind:'rebind',changes:result.changes});}
  for(const name of ['INSTALLERICON','SIDEBARIMAGE','HEADERIMAGE','UNINSTALLERICON','UNINSTALLERHEADERIMAGE','WEBVIEW2BOOTSTRAPPERPATH','WEBVIEW2INSTALLERPATH'])need(rendered.split('!define '+name+' ""').length===2,'nsis_observer_resource_profile_refused');
  need(rebound.used.includes(hooks)&&rebound.used.includes(guiPath)&&rebound.used.includes(includePath)&&reboundInclude.used.includes(planPath),'nsis_observer_required_reference_missing');
  need(rendered.split('!define LICENSE "'+(licensePath?literal(renderedLicensePath):'')+'"').length===2,'nsis_observer_rendered_license_refused');
  const gui=projectNssGui(track(guiPath),phase.input_gui_sha256,record.gui_sha256,plan.files.find(row=>row.role==='gui'));
  const output=path.join(diagnostic,'output/nsis-output.exe'),captureRoot=path.join(diagnostic,'capture'),instrumented=instrumentNsis(rebound.source,{outputFile:output,captureRoot});
  const files=[...copies.values()].map(item=>({...item,bytes:item.origin===guiPath?gui:transforms.get(item.origin)?.bytes??item.bytes,transform:item.origin===guiPath?'NSS':transforms.get(item.origin)?.kind??'copy'}));
  const dRendered=path.join(dRelease,'nsis/x64/installer.nsi');files.push({path:dRendered,bytes:Buffer.from(instrumented.source),origin:renderedPath,origin_sha256:hash(Buffer.from(rendered)),transform:'rebind+observer'});
  need(new Set(files.map(row=>row.path.toLowerCase())).size===files.length,'nsis_observer_destination_collision');
  const snapshot={repo_root:repo,files:[...originals.values()],directories:[...directories.values()]};await assertCompilerSnapshot(snapshot);
  const inventory=files.map(row=>({origin:row.origin,destination:row.path,origin_sha256:row.origin_sha256,bytes:row.bytes.length,sha256:hash(row.bytes),transform:row.transform}));
  return {files,snapshot,inventory,release_admissible:false,original_setup:{bytes:setup.length,sha256:hash(setup)},
    changes:{rendered:rebound.changes,include:reboundInclude.changes,headers:[...transforms].map(([origin,value])=>({origin,changes:value.changes})),instrumentation:instrumented.changes},
    compiler:{image:path.join(dSdk,'makensis.exe'),cwd:path.join(diagnostic,'output'),nsisdir:dSdk,temp:path.join(diagnostic,'temp'),output,
      args:['/NOCONFIG','/NOCD','/V4','/INPUTCHARSET','UTF8','/OUTPUTCHARSET','UTF8',dRendered]},diagnostic};
}

async function runFixed(mode, sourceCommit, repoArgument) {
  need(['compile','collect'].includes(mode), 'nsis_observer_mode_refused');
  admitDiagnostic(process.env, sourceCommit, 'NSIS');
  need(process.platform === 'win32', 'nsis_observer_windows_required');
  const { physicalPath } = await import(new URL('./distribution-prelaunch.mjs', import.meta.url));
  const { parseStrictJson } = await import(new URL('./assert-license-inputs.mjs', import.meta.url));
  const { spawnSync } = await import('node:child_process');
  const physical = file => {
    const full = path.resolve(file); need(physicalPath(file) === full, 'nsis_observer_path_alias_refused'); return full;
  };
  const repo = physical(repoArgument);
  need(repo === physical(process.env.GITHUB_WORKSPACE), 'nsis_observer_repo_refused');
  const native = physical(path.join(process.env.RUNNER_TEMP, 'winsmux-native-input-' + process.env.GITHUB_RUN_ID + '.'
    + process.env.GITHUB_RUN_ATTEMPT + '.' + sourceCommit + '.NSIS'));
  const diagnostic = physical(path.join(native,'diagnostic-nsis')), evidence = physical(path.join(native,'evidence'));
  const read = file => plain(physical(file));
  const json = file => parseStrictJson(read(file));
  const write = (file, bytes) => {
    physical(file); fs.mkdirSync(path.dirname(file), { recursive: true }); physical(path.dirname(file));
    fs.writeFileSync(file, bytes, { flag: 'wx' }); need(read(file).equals(Buffer.from(bytes)), 'nsis_observer_write_readback_changed');
  };
  const writeJson = (file, value) => write(file, Buffer.from(JSON.stringify(value,null,2) + '\n'));
  const transfer = path.join(repo,'scripts/test-public-release.ps1');
  const transportModule = extractTransportModule(read(transfer).toString('utf8'));
  const transport = () => {
    const result = spawnSync(process.execPath, ['--input-type=module','--eval',transportModule,'verify',sourceCommit,'NSIS',repo],
      { cwd: repo, windowsHide: true, encoding: 'buffer', maxBuffer: 4194304 });
    need(result.status === 0 && !result.error && result.stderr?.length === 0, 'nsis_observer_transport_refused');
    const receipt = parseStrictJson(result.stdout);
    need(receipt.schema === 'winsmux-desktop-native-transport-check/v1' && receipt.mode === 'verify'
      && receipt.source_commit === sourceCommit && receipt.format === 'NSIS', 'nsis_observer_transport_result_refused');
  };
  transport();
  if (mode === 'collect') {
    const build = assertBuild(json(path.join(evidence,'nsis-observer-build.json')), sourceCommit);
    const setup = read(path.join(diagnostic,'output/nsis-output.exe'));
    need(setup.length === build.diagnostic_setup.bytes && hash(setup) === build.diagnostic_setup.sha256,
      'nsis_observer_collect_setup_changed');
    writeJson(path.join(evidence,'nsis-actual-callee-observer.json'), collectPrivate(path.join(diagnostic,'capture'),sourceCommit));
    const plan = json(path.join(native,'candidate/winsmux-nsis-plan.json'));
    const allowed = new Set([...plan.files.map(row => row.path), 'winsmux.install-plan.json','uninstall.exe',
      '.winsmux-desktop/installed.json','.winsmux-desktop/pending.json']);
    for (const [name, kind] of [['before','witness'],['after','witness'],['update-process','process'],['uninstall-process','process']]) {
      const file = path.join(diagnostic,name+'.json');
      if (!fs.existsSync(file)) continue;
      const raw = json(file), safe = kind === 'witness' ? projectWitness(raw,allowed) : projectProcess(raw);
      writeJson(path.join(evidence,'nsis-observer-'+name+'.json'),safe);
    }
    transport(); return;
  }
  need(!fs.existsSync(diagnostic), 'nsis_observer_diagnostic_reuse_refused');
  const closure=await prepareCompilerClosure({repoRoot:repo,releaseDirectory:path.join(native,'build/release'),sdkRoot:path.join(process.env.LOCALAPPDATA,'tauri/NSIS'),diagnosticDirectory:diagnostic});
  const diagnosticInputs=new Map();
  const unchanged=async()=>{await assertCompilerSnapshot(closure.snapshot);for(const [file,bytes]of diagnosticInputs)need(read(file).equals(bytes),'nsis_observer_diagnostic_input_changed');};
  fs.mkdirSync(diagnostic); for(const sub of ['capture','output','temp'])fs.mkdirSync(path.join(diagnostic,sub));
  let compilerResult=null;
  try {
    for(const item of closure.files){write(item.path,item.bytes);diagnosticInputs.set(item.path,item.bytes);}
    const inventory=closure.inventory;
    writeJson(path.join(diagnostic,'input-inventory.json'),{schema:'winsmux-nsis-observer-private-closure/v1',source_commit:sourceCommit,inventory,changes:closure.changes});
    await unchanged();transport();
    const compiler=closure.compiler.image,env={...process.env,NSISDIR:closure.compiler.nsisdir,TEMP:closure.compiler.temp,TMP:closure.compiler.temp};
    const version=spawnSync(compiler,['/VERSION'],{cwd:closure.compiler.cwd,env,windowsHide:true,encoding:'buffer',maxBuffer:4194304});
    write(path.join(diagnostic,'compiler-version.stdout.bin'),version.stdout??Buffer.alloc(0));write(path.join(diagnostic,'compiler-version.stderr.bin'),version.stderr??Buffer.alloc(0));
    need(version.status===0&&!version.error&&version.stdout?.toString('utf8').trim()==='v3.11','nsis_observer_compiler_version_refused');
    compilerResult=spawnSync(compiler,closure.compiler.args,{cwd:closure.compiler.cwd,env,windowsHide:true,encoding:'buffer',maxBuffer:4194304});
    write(path.join(diagnostic,'compiler.stdout.bin'),compilerResult.stdout??Buffer.alloc(0));write(path.join(diagnostic,'compiler.stderr.bin'),compilerResult.stderr??Buffer.alloc(0));
    need(compilerResult.status===0&&!compilerResult.error,'nsis_observer_compile_failed');
    const output=read(closure.compiler.output);need(output.length>0&&output[0]===0x4d&&output[1]===0x5a,'nsis_observer_output_refused');
    await unchanged();transport();
    const original=read(path.join(native,'candidate/winsmux_0.38.0_x64-setup.exe')),compilerBytes=read(compiler);
    const safe=assertBuild({schema:'winsmux-nsis-observer-build/v1',diagnostic:true,release_admissible:false,source_commit:sourceCommit,
      original:{bytes:original.length,sha256:hash(original)},diagnostic_setup:{bytes:output.length,sha256:hash(output)},
      compiler:{bytes:compilerBytes.length,sha256:hash(compilerBytes)},closure_files:inventory.length,closure_sha256:hash(Buffer.from(JSON.stringify(inventory))),original_unchanged:true},sourceCommit);
    writeJson(path.join(diagnostic,'build.json'),safe);writeJson(path.join(evidence,'nsis-observer-build.json'),safe);
  } finally {
    await unchanged();transport();
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [mode, sourceCommit, repoRoot, ...extra] = process.argv.slice(2);
  try {
    need(extra.length === 0 && typeof repoRoot === 'string', 'nsis_observer_cli_refused');
    await runFixed(mode, sourceCommit, repoRoot);
  } catch (error) {
    const message = typeof error?.message === 'string' && /^nsis_observer_[a-z_]+$/u.test(error.message)
      ? error.message : 'nsis_observer_operation_refused';
    console.error(message); process.exitCode = 1;
  }
}
