import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { readRustcIdentity, verifyWindowsDistributionCompiler } from '../../scripts/assert-windows-distribution-toolchain.mjs';
import { assertWindowsRuntime } from '../../scripts/assert-windows-runtime.mjs';
import { windowsDistributionBuildPlan } from '../../scripts/windows-distribution-build.mjs';
import { desktopCurrentLicenseSourcePath } from '../../scripts/windows-license-build-inputs.mjs';
import { fixturePe } from './fixture-pe.mjs';

const target = 'x86_64-pc-windows-msvc';
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const request = { repoRoot, target, targetRoot: path.join(repoRoot, 'target'),
  intermediateRoot: path.join(repoRoot, 'intermediate') };
const measuredCommit = 'ac68faa20c58cbccd01ee7208bf3b6e93a7d7f96';
const compilerResult = text => ({ status: 0, signal: null,
  stdout: Buffer.from(text ?? `host: ${target}\ncommit-hash: ${measuredCommit}\n`) });

test('Git checkout preserves the pinned NSIS input bytes even with autocrlf enabled', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'winsmux-nsis-checkout-'));
  t.after(() => fs.rmSync(root, { recursive: true }));
  const files = new Map([
    ['winsmux-app/src-tauri/nsis/installer.nsi', 'a74f6be49dbc25cdd0af7816e0440d19392438d89d4f4c730761cb702cb0833d'],
    ['winsmux-app/src-tauri/nsis/winsmux-utils.nsh', '923281c0324b9c1650df9ab0859803adfaaa489a0eb08aa826d2bfdb55c6c8ad'],
    ['distribution/windows-licenses/MICROSOFT-COMPONENT-TERMS.ja.txt', 'bbc1e106fce5d78e2f7d8823f98e7b13a3c56b0307154a26c0fddb798f1a235c'],
  ]);
  const attributes = spawnSync('git', ['check-attr', 'text', '--', ...files.keys()], { cwd: repoRoot, encoding: 'utf8', windowsHide: true });
  assert.equal(attributes.status, 0, attributes.stderr);
  assert.deepEqual(attributes.stdout.trim().split(/\r?\n/u), [...files.keys()].map(file => `${file}: text: unset`));
  const checkout = spawnSync('git', ['-c', 'core.autocrlf=true', 'checkout-index',
    '--prefix=' + root.replaceAll('\\', '/') + '/', '--', ...files.keys()], { cwd: repoRoot, encoding: 'utf8', windowsHide: true });
  assert.equal(checkout.status, 0, checkout.stderr);
  for (const [file, expected] of files) {
    const bytes = fs.readFileSync(path.join(root, file));
    const blob = spawnSync('git', ['cat-file', 'blob', `HEAD:${file}`], { cwd: repoRoot, windowsHide: true });
    assert.equal(blob.status, 0, blob.stderr.toString());
    assert.deepEqual(bytes, blob.stdout, file);
    assert.equal(createHash('sha256').update(bytes).digest('hex'), expected, file);
  }
});

test('Japanese installer license is a marked reference translation followed by the English original byte for byte', () => {
  const licenses = path.join(repoRoot, 'distribution/windows-licenses');
  const english = fs.readFileSync(path.join(licenses, 'MICROSOFT-COMPONENT-TERMS.txt'));
  const japanese = fs.readFileSync(path.join(licenses, 'MICROSOFT-COMPONENT-TERMS.ja.txt'));
  assert.deepEqual([...japanese.subarray(0, 3)], [0xef, 0xbb, 0xbf]);
  assert.equal(japanese.toString('utf8', 3).split('\n')[0],
    'この日本語は参考訳です。英語の原文と内容が異なる場合は、英語の原文が優先します。英語の原文は、この訳文のあとにそのまま掲載しています。');
  assert.deepEqual(japanese.subarray(japanese.length - english.length), english);
  assert.equal(japanese.toString('utf8', 3, japanese.length - english.length).endsWith('\n英語の原文（English original）\n\n'), true);
});

const makensis = [process.env.WINSMUX_MAKENSIS, process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'tauri/NSIS/makensis.exe'),
  'C:\\Program Files (x86)\\NSIS\\makensis.exe'].find(file => file && fs.existsSync(file));
test('the Desktop and Start menu links the installer writes start in the install folder, not in its temporary source folder', {
  skip: process.platform !== 'win32' || !makensis ? 'needs Windows and makensis' : false,
}, t => {
  const nsis = path.join(repoRoot, 'winsmux-app/src-tauri/nsis');
  const template = fs.readFileSync(path.join(nsis, 'installer.nsi'), 'utf8').replaceAll('\r\n', '\n');
  const section = template.match(/^Section Install\n([\s\S]*?)^SectionEnd$/mu)[1].split('\n');
  const uninstaller = section.indexOf('  WriteUninstaller "$WinsmuxSource\\uninstall.exe"');
  const dispatch = section.indexOf('  Call WinsmuxWriteInstallContext');
  assert.ok(uninstaller > 0 && dispatch > uninstaller, 'the links are written between the uninstaller and the helper dispatch');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'winsmux-nsis-links-'));
  t.after(() => fs.rmSync(root, { recursive: true }));
  const [workspace, source, install] = ['workspace', 'source', 'install'].map(name => path.join(root, name));
  const script = [
    'Unicode true', '!include LogicLib.nsh', '!include "' + path.join(nsis, 'winsmux-utils.nsh') + '"', '!include "Win\\COM.nsh"',
    '!include "Win\\Propkey.nsh"', '!define BUNDLEID "io.github.sora-bluesky.winsmux"', '!define MAINBINARYNAME "winsmux-app"',
    'Name "links"', 'OutFile "' + path.join(root, 'links.exe') + '"', 'RequestExecutionLevel user', 'SilentInstall silent',
    'Var WinsmuxWorkspace', 'Var WinsmuxSource', 'Var WinsmuxStartMenu', 'Var WinsmuxDesktop', 'Section',
    '  StrCpy $WinsmuxWorkspace "' + workspace + '"', '  StrCpy $WinsmuxSource "' + source + '"', '  StrCpy $INSTDIR "' + install + '"',
    '  StrCpy $WinsmuxStartMenu 1', '  StrCpy $WinsmuxDesktop 1',
    ...section.slice(0, uninstaller).filter(line => line.startsWith('  SetOutPath ')),
    ...section.slice(uninstaller + 1, dispatch),
    '  FileOpen $9 "' + path.join(root, 'outdir.txt') + '" w', '  FileWrite $9 "$OUTDIR"', '  FileClose $9', 'SectionEnd', '',
  ].join('\r\n');
  fs.writeFileSync(path.join(root, 'links.nsi'), '\ufeff' + script);
  const compiled = spawnSync(makensis, ['/V2', path.join(root, 'links.nsi')], { encoding: 'utf8', windowsHide: true });
  assert.equal(compiled.status, 0, compiled.stdout + compiled.stderr);
  const ran = spawnSync(path.join(root, 'links.exe'), [], { windowsHide: true });
  assert.equal(ran.status, 0, 'the link script ran');
  const read = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
    '$s = New-Object -ComObject WScript.Shell; @("start_menu", "desktop") | ForEach-Object { $l = $s.CreateShortcut((Join-Path $env:LINKS ($_ + ".lnk"))); [ordered]@{ kind = $_; target = $l.TargetPath; start_in = $l.WorkingDirectory } } | ConvertTo-Json -Compress'],
  { encoding: 'utf8', windowsHide: true, env: { ...process.env, LINKS: path.join(source, 'shortcuts') } });
  assert.equal(read.status, 0, read.stderr);
  assert.deepEqual(JSON.parse(read.stdout), ['start_menu', 'desktop'].map(kind => ({ kind, target: path.join(install, 'winsmux-app.exe'), start_in: install })));
  assert.equal(fs.readFileSync(path.join(root, 'outdir.txt'), 'utf8'), source, 'the helper dispatch keeps the output folder it had');
  assert.equal(fs.existsSync(install), false, 'the install folder is left for the helper to create');
});

test('every helper refusal the installer names gets an install and an uninstall message that says what that class guarantees', () => {
  const read = file => fs.readFileSync(path.join(repoRoot, file), 'utf8').replaceAll('\r\n', '\n');
  const hooks = read('winsmux-app/src-tauri/nsis-installer-hooks.nsh');
  const template = read('winsmux-app/src-tauri/nsis/installer.nsi');
  const helper = read('core/crates/winsmux-workspace/src/desktop_nsis.rs');
  const strings = new Map();
  for (const m of hooks.matchAll(/^LangString (WINSMUX_\w+) (1033|1041) "(.*)"$/gmu)) {
    if (!strings.has(m[1])) strings.set(m[1], {});
    assert.equal(strings.get(m[1])[m[2]], undefined, `${m[1]} ${m[2]} defined twice`);
    strings.get(m[1])[m[2]] = m[3];
  }
  const classificationBody = helper.slice(helper.indexOf('pub fn classification(self)'), helper.indexOf('#[derive', helper.indexOf('pub fn classification(self)')));
  const emitted = new Set([...classificationBody.matchAll(/=> "([a-z_]+)"/gu)].map(m => m[1]));
  assert.ok(emitted.has('member_unconfirmed') && emitted.has('destination_occupied') && emitted.has('shortcut_folder_moved')
    && !emitted.has('legacy_root_mismatch'));
  const macroStart = template.indexOf('!macro WINSMUX_REPORT_HELPER_FAILURE UN PREFIX\n');
  assert.ok(macroStart >= 0);
  const macro = template.slice(macroStart, template.indexOf('!macroend', macroStart));
  const branches = [...macro.matchAll(/\$\{(?:If|ElseIf|OrIf)\} \$3 S== "winsmux installer: ([a-z_]+)"\n(?:\s+\$\{OrIf\} \$3 S== "winsmux installer: ([a-z_]+)"\n)*\s+StrCpy \$4 "\$\(WINSMUX_\$\{PREFIX\}(\w+)\)"/gu)];
  const mapped = new Map();
  for (const branch of branches) {
    for (const cls of branch[0].matchAll(/winsmux installer: ([a-z_]+)/gu)) mapped.set(cls[1], branch[3]);
  }
  assert.deepEqual([...mapped.keys()].sort(), ['destination_occupied', 'legacy_inventory_incomplete', 'legacy_profile_incomplete',
    'legacy_receipt_missing', 'member_unconfirmed', 'pending_unconfirmed', 'registration_conflict', 'shortcut_folder_moved',
    'work_running_or_locked']);
  for (const cls of mapped.keys()) assert.ok(emitted.has(cls), `${cls} is not a classification the helper emits`);
  assert.ok(macro.includes('  DetailPrint $4\n  Abort $4\n'), 'the message is printed to the details view before the abort');
  // Every helper line reaches the details view and the last non-empty line is the classification. The
  // restore lines the helper prints choose the restore message and its notices (the next test runs the
  // macro on those lines).
  assert.ok(macro.includes('        DetailPrint "winsmux installer helper: $6"\n        StrCpy $4 $6 27\n        ${If} $4 S!= "winsmux installer: readback"\n          StrCpy $3 $6\n'),
    'each helper line is printed and the last one outside the readback lines is classified');
  for (const line of ['restore_incomplete {refusal} {} {} {}', 'restore_shortcut_parked {kind}', 'restore_shortcut_unconfirmed {kind}',
    'readback_refused {site} {}:{} {what}', 'readback_recovered {site} {}:{}', 'readback_more {more}']) {
    assert.ok(helper.includes(`"winsmux installer: ${line}"`), `the helper prints the ${line} line the installer looks for`);
  }
  assert.equal((macro.match(/\$\{PREFIX\}/gu) ?? []).length, new Set(mapped.values()).size + 4, 'every string selection, the default and the restore strings included, goes through the prefix');
  assert.ok(/Section Install\n[\s\S]*?!insertmacro WINSMUX_REPORT_HELPER_FAILURE "" ""\n[\s\S]*?SectionEnd/u.test(template));
  assert.ok(/Section Uninstall\n[\s\S]*?!insertmacro WINSMUX_REPORT_HELPER_FAILURE "un\." "UN_"\n[\s\S]*?SectionEnd/u.test(template));
  // What each class guarantees, in the words the helper's Error enum documents: a Member is unconfirmed
  // (never asserted to be a collision), Occupied is a collision the user moves away, FolderMoved is a
  // known folder the user moves back, and only an install run says "installer" or "nothing was changed".
  const expectations = {
    FAILED_MEMBER: { 1033: [/could not confirm/u, /^(?!.*already holds)/u], 1041: [/確認できない/u, /^(?!.*同名のファイルがあります)/u] },
    FAILED_OCCUPIED: { 1033: [/holds a file with a winsmux name/u, /Move that file away/u], 1041: [/同名のファイルがあります/u, /そのファイルを移/u] },
    FAILED_FOLDER_MOVED: { 1033: [/Desktop or Start menu folder .* has moved since winsmux was installed/u, /Move the folder back/u],
      1041: [/デスクトップかスタートメニューのフォルダーが.*移動している/u, /元の場所に戻して/u] },
    FAILED_LEGACY_CAPTURE: { 1033: [/record of the earlier winsmux install is incomplete/u], 1041: [/記録が不完全/u] },
    FAILED_REGISTRATION: { 1033: [/registry entries do not match/u], 1041: [/レジストリ項目が.*一致しない/u] },
    FAILED_RUNNING: { 1033: [/still running or its folder is locked/u], 1041: [/起動中か、フォルダーがロック/u] },
    FAILED_PENDING: { 1033: [/did not finish and its recovery data is kept/u, /preserved/u], 1041: [/完了しておらず、復旧データを残して/u, /保全/u] },
    TRANSACTION_FAILED: { 1033: [/could not be confirmed/u, /preserved/u], 1041: [/確認できませんでした/u, /保全/u] },
    RESTORE_INCOMPLETE: { 1033: [/could not be finished, and its recovery data is kept/u, /again to resume it/u],
      1041: [/最後まで終えられず、復旧データを残して/u, /再開します/u] },
  };
  // Notices follow a message and say only what the helper saw of the Desktop and Start menu links.
  const notices = {
    RESTORE_PARKED: { 1033: [/set aside are preserved in the winsmux folder/u], 1041: [/ショートカットは退避中/u, /保全/u] },
    RESTORE_SHORTCUT_UNCONFIRMED: { 1033: [/could not confirm that the Desktop or Start menu shortcuts were put back/u],
      1041: [/ショートカットの復旧を確認できません/u] },
  };
  const outcome = {
    '': { 1033: [/nothing was changed|preserved/iu, /^(?!.*uninstaller)/u], 1041: [/何も変更していません|保全/u, /^(?!.*アンインストールしてください)/u] },
    UN_: { 1033: [/nothing was removed|preserved/iu, /^(?!.*\binstaller\b)/u, /^(?!.*nothing was changed)/iu], 1041: [/何も削除していません|保全/u, /^(?!.*何も変更していません)/u] },
  };
  for (const prefix of ['', 'UN_']) {
    for (const [suffix, perLanguage] of Object.entries(expectations)) {
      const key = `WINSMUX_${prefix}${suffix}`;
      const text = strings.get(key);
      assert.ok(text, `${key} is not defined in the installer hook`);
      for (const language of ['1033', '1041']) {
        assert.ok(text[language], `${key} has no ${language} string`);
        for (const rule of [...perLanguage[language], ...outcome[prefix][language]]) assert.match(text[language], rule, `${key} ${language}`);
      }
    }
  }
  for (const prefix of ['', 'UN_']) {
    for (const [suffix, perLanguage] of Object.entries(notices)) {
      const key = `WINSMUX_${prefix}${suffix}`;
      for (const language of ['1033', '1041']) {
        const text = strings.get(key)?.[language];
        assert.ok(text, `${key} has no ${language} string`);
        for (const rule of perLanguage[language]) assert.match(text, rule, `${key} ${language}`);
      }
    }
  }
  for (const suffix of [...new Set(mapped.values()), 'RESTORE_INCOMPLETE']) assert.ok(Object.hasOwn(expectations, suffix), `${suffix} has no expectation row`);
  assert.ok(!hooks.includes('LEGACY_ROOT') && !template.includes('legacy_root_mismatch'));
});

// A small interpreter for the LogicLib statements the installer's failure macros use, so a test judges
// what a macro does with the helper's output, not how its source is spelled.
function nsisStatements(body, params) {
  let text = body;
  for (const [name, value] of Object.entries(params)) text = text.replaceAll(name, value);
  return text.split('\n').map(s => s.trim()).filter(s => s && !s.startsWith(';'));
}
const nsisArgsSeen = new Map();
function nsisArgs(s) {
  if (!nsisArgsSeen.has(s)) {
    nsisArgsSeen.set(s, [...s.matchAll(/"((?:\$\\.|\$[^\\]|[^"$])*)"|(\S+)/gu)].map(m => (m[1] === undefined ? { bare: m[2] } : { quoted: m[1] })));
  }
  return nsisArgsSeen.get(s);
}
function nsisParse(statements) {
  let i = 0;
  const condition = s => s.replace(/^\$\{(?:If|ElseIf|OrIf|AndIf|LoopUntil)\} /u, '');
  const block = stops => {
    const out = [];
    while (i < statements.length && !stops.some(stop => statements[i].startsWith(stop))) {
      const s = statements[i++];
      if (s.startsWith('${If} ')) {
        const node = { kind: 'if', arms: [], otherwise: [] };
        for (let head = s; ;) {
          const conditions = [['', condition(head)]];
          while (/^\$\{(?:OrIf|AndIf)\} /u.test(statements[i] ?? '')) {
            const next = statements[i++];
            conditions.push([next.startsWith('${OrIf}') ? 'or' : 'and', condition(next)]);
          }
          node.arms.push({ conditions, body: block(['${ElseIf} ', '${Else}', '${EndIf}']) });
          const next = statements[i++];
          if (next?.startsWith('${ElseIf} ')) { head = next; continue; }
          if (next === '${Else}') { node.otherwise = block(['${EndIf}']); i++; }
          else assert.equal(next, '${EndIf}', 'every If is closed');
          break;
        }
        out.push(node);
      } else if (s === '${Do}') {
        const body = block(['${LoopUntil} ']);
        out.push({ kind: 'do', body, until: condition(statements[i++]) });
      } else out.push({ kind: 'statement', s });
    }
    return out;
  };
  const tree = block([]);
  assert.equal(i, statements.length, 'every statement is parsed');
  return tree;
}
function nsisRun(tree, reg, strings, details) {
  const value = token => {
    if (token.bare !== undefined) return token.bare.startsWith('$') ? reg[token.bare] : token.bare;
    return token.quoted.replace(/\$\\n|\$\\r|\$\(([A-Z_]+)\)|\$(\d|INSTDIR)/gu, (m, name, r) => {
      if (m === '$\\n') return '\n';
      if (m === '$\\r') return '\r';
      if (name) {
        assert.ok(strings.has(name), `${name} is not a hook string`);
        return strings.get(name);
      }
      return reg[`$${r}`];
    });
  };
  const test = text => {
    const [a, op, b] = nsisArgs(text);
    const x = value(a), y = value(b);
    if (op.bare === '==') return x.toLowerCase() === y.toLowerCase();
    if (op.bare === '!=') return x.toLowerCase() !== y.toLowerCase();
    if (op.bare === 'S==') return x === y;
    if (op.bare === 'S!=') return x !== y;
    if (op.bare === '=') return Number(x) === Number(y);
    if (op.bare === '<>') return Number(x) !== Number(y);
    return assert.fail(`this test does not model the condition: ${text}`);
  };
  const holds = conditions => conditions.reduce((acc, [join, c]) => (join === 'or' ? acc || test(c) : join === 'and' ? acc && test(c) : test(c)), false);
  for (const node of tree) {
    let result;
    if (node.kind === 'if') {
      const arm = node.arms.find(a => holds(a.conditions));
      result = nsisRun(arm ? arm.body : node.otherwise, reg, strings, details);
    } else if (node.kind === 'do') {
      for (let n = 0; result === undefined; n++) {
        assert.ok(n < 100000, 'the loop ends');
        result = nsisRun(node.body, reg, strings, details);
        if (test(node.until)) break;
      }
    } else {
      const [op, ...a] = nsisArgs(node.s);
      if (op.bare === 'DetailPrint') details.push(value(a[0]));
      else if (op.bare === 'Abort') result = value(a[0]);
      else if (op.bare === 'StrCpy') {
        const text = value(a[1]), from = a[3] ? Number(value(a[3])) : 0;
        reg[a[0].bare] = a[2] ? text.slice(from, from + Number(value(a[2]))) : text;
      } else if (op.bare === 'IntOp') {
        const x = Number(value(a[1])), y = Number(value(a[3])), ops = { '+': x + y, '|': x | y, '&': x & y };
        assert.ok(Object.hasOwn(ops, a[2].bare), `this test does not model IntOp ${a[2].bare}`);
        reg[a[0].bare] = String(ops[a[2].bare]);
      } else if (/^\$\{(?:un\.)?TrimNewLines\}$/u.test(op.bare)) reg[a[1].bare] = value(a[0]).replace(/[\r\n]+$/u, '');
      else assert.fail(`this test does not model the statement: ${node.s}`);
    }
    if (result !== undefined) return result;
  }
  return undefined;
}
function nsisMacroBody(template, header) {
  const start = template.indexOf(`${header}\n`);
  assert.ok(start >= 0, `${header} is in the template`);
  return template.slice(start + header.length + 1, template.indexOf('!macroend', start));
}
// The report macro run on one helper exit and output (its lines, or the raw text ExecToStack kept), with one
// prefix's strings in one language.
function helperFailureAbort(template, hooks, { prefix, language, lines, output = lines.map(line => `${line}\n`).join(''), exit = '2' }) {
  const body = nsisMacroBody(template, '!macro WINSMUX_REPORT_HELPER_FAILURE UN PREFIX');
  const strings = new Map([...hooks.matchAll(/^LangString (\w+) (1033|1041) "(.*)"$/gmu)].filter(m => m[2] === language).map(m => [m[1], m[3]]));
  const reg = Object.fromEntries(Array.from({ length: 10 }, (_, n) => [`$${n}`, '']));
  Object.assign(reg, { $0: exit, $1: output, $INSTDIR: 'C:\\Users\\u\\AppData\\Local\\winsmux' });
  const details = [];
  const abort = nsisRun(nsisParse(nsisStatements(body, { '${PREFIX}': prefix, '${${UN}': prefix ? '${un.' : '${' })), reg, strings, details);
  assert.equal(typeof abort, 'string', 'the report aborts');
  return { abort, details };
}

test('a restore the helper left unfinished reads as kept recovery data, and a shortcut as parked only when the helper saw it there', () => {
  const read = file => fs.readFileSync(path.join(repoRoot, file), 'utf8').replaceAll('\r\n', '\n');
  const template = read('winsmux-app/src-tauri/nsis/installer.nsi');
  const hooks = read('winsmux-app/src-tauri/nsis-installer-hooks.nsh');
  const hook = (name, language) => hooks.match(new RegExp(`^LangString ${name} ${language} "(.*)"$`, 'mu'))?.[1];
  const desktop = 'C:\\Users\\u\\Desktop\\winsmux.lnk';
  const programs = 'C:\\Users\\u\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\winsmux.lnk';
  // The helper output for these runs: the classification, then the restore lines desktop_nsis.rs pins, then
  // the readback lines. A slot the restore found holding an external value
  // (crash_reentry_and_external_registration_are_preserved), a foreign link back in its folder after its
  // readback refused (task881_rollback_readback_refusal_names_the_restore_move_and_returns_the_other_link), a
  // product link that could not leave the Desktop (task881_restore_never_calls_a_product_link_parked), a
  // foreign link left parked (task881_restore_reports_a_link_it_left_parked), and two rows left with a link the
  // files do not place (task881_restore_reports_all_rows_it_left_and_each_link_it_cannot_place).
  const cases = {
    slot_left_external: ['winsmux installer: registration_conflict', 'winsmux installer: restore_incomplete uncertain slot registration slot:0'],
    link_back_after_readback: ['winsmux installer: startup_unconfirmed',
      `winsmux installer: restore_incomplete path_refused:171 preserved desktop ${desktop}`,
      'winsmux installer: readback_refused 171 file:6 reopen:5'],
    product_link_stayed: ['winsmux installer: io_unconfirmed', 'winsmux installer: restore_shortcut_unconfirmed desktop',
      `winsmux installer: restore_incomplete io_unconfirmed new desktop ${desktop}`],
    link_left_parked: ['winsmux installer: startup_unconfirmed', 'winsmux installer: restore_shortcut_parked desktop',
      `winsmux installer: restore_incomplete io_unconfirmed preserved desktop ${desktop}`],
    link_not_placed: ['winsmux installer: io_unconfirmed', 'winsmux installer: restore_shortcut_unconfirmed start_menu',
      `winsmux installer: restore_incomplete path_refused:170 new desktop ${desktop}`,
      `winsmux installer: restore_incomplete uncertain preserved start_menu ${programs}`,
      'winsmux installer: readback_refused 170 file:6 reopen:5'],
  };
  for (const [prefix, language] of [['', '1041'], ['', '1033'], ['UN_', '1041'], ['UN_', '1033']]) {
    const said = name => hook(`WINSMUX_${prefix}${name}`, language);
    for (const [name, lines] of Object.entries(cases)) {
      const where = `${name} ${prefix}${language}`;
      const { abort, details } = helperFailureAbort(template, hooks, { prefix, language, lines });
      for (const line of lines) assert.ok(details.includes(`winsmux installer helper: ${line}`), `${where}: ${line} reaches the details view`);
      assert.doesNotMatch(abort, /何も変更していません|何も削除していません|nothing was (?:changed|removed)/iu, `${where}: the unfinished restore is not reported as no change`);
      const parked = lines.some(line => line.startsWith('winsmux installer: restore_shortcut_parked '));
      const unplaced = lines.some(line => line.startsWith('winsmux installer: restore_shortcut_unconfirmed '));
      if (!parked) assert.doesNotMatch(abort, /退避中|set aside/u, `${where}: no shortcut was seen parked`);
      assert.equal(abort, [said('RESTORE_INCOMPLETE'), ...(parked ? [said('RESTORE_PARKED')] : []),
        ...(unplaced ? [said('RESTORE_SHORTCUT_UNCONFIRMED')] : [])].join(' '), where);
    }
    assert.equal(helperFailureAbort(template, hooks, { prefix, language, lines: ['winsmux installer: member_unconfirmed'] }).abort,
      said('FAILED_MEMBER'), `${prefix}${language}: without a restore line the class message stands`);
    // A readback that still refused after the rename (task881_preserved_link_readback_refusal_names_the_publish_move)
    // prints its line after the class, and the message is the class message.
    const refused = ['winsmux installer: path_refused', 'winsmux installer: readback_refused 169 file:6 reopen:5'];
    const { abort, details } = helperFailureAbort(template, hooks, { prefix, language, lines: refused, exit: '169' });
    assert.equal(abort, said('TRANSACTION_FAILED'), `${prefix}${language}: a readback line keeps the class message`);
    assert.ok(details.includes(`winsmux installer helper: ${refused[1]}`), `${prefix}${language}: the readback line reaches the details view`);
  }
});

test('the readback lines the helper prints last reach the details view and never take the place of the classification', () => {
  const read = file => fs.readFileSync(path.join(repoRoot, file), 'utf8').replaceAll('\r\n', '\n');
  const template = read('winsmux-app/src-tauri/nsis/installer.nsi');
  const hooks = read('winsmux-app/src-tauri/nsis-installer-hooks.nsh');
  const hook = (name, language) => hooks.match(new RegExp(`^LangString ${name} ${language} "(.*)"$`, 'mu'))?.[1];
  // A move whose readback refused and was proved again by name, before a later refusal, and a move whose
  // second readback found another parent (task881_second_readback_mismatch_still_reports_the_first_refusal).
  const cases = [
    [['winsmux installer: registration_conflict', 'winsmux installer: readback_recovered 167 file:6'], 'FAILED_REGISTRATION'],
    [['winsmux installer: pending_unconfirmed', 'winsmux installer: readback_refused 167 file:6 mismatch',
      'winsmux installer: readback_recovered 166 file:6', 'winsmux installer: readback_more 1'], 'FAILED_PENDING'],
  ];
  for (const [prefix, language] of [['', '1041'], ['', '1033'], ['UN_', '1041'], ['UN_', '1033']]) {
    for (const [lines, message] of cases) {
      const { abort, details } = helperFailureAbort(template, hooks, { prefix, language, lines });
      assert.equal(abort, hook(`WINSMUX_${prefix}${message}`, language), `${prefix}${language}: ${lines[0]} keeps its message`);
      for (const line of lines) assert.ok(details.includes(`winsmux installer helper: ${line}`), `${prefix}${language}: ${line} reaches the details view`);
    }
  }
});

// The success branch run on one helper output; returns what it printed to the details view.
function helperSuccessDetails(template, un, output) {
  const body = nsisMacroBody(template, '!macro WINSMUX_PRINT_HELPER_READBACK UN');
  const reg = Object.fromEntries(Array.from({ length: 10 }, (_, n) => [`$${n}`, '']));
  Object.assign(reg, { $0: '0', $1: output });
  const details = [];
  assert.equal(nsisRun(nsisParse(nsisStatements(body, { '${${UN}': `\${${un}` })), reg, new Map(), details), undefined, 'a success never aborts');
  return details;
}

test('a helper run that succeeded prints its readback lines to the details view and nothing else', () => {
  const template = fs.readFileSync(path.join(repoRoot, 'winsmux-app/src-tauri/nsis/installer.nsi'), 'utf8').replaceAll('\r\n', '\n');
  // A run that installed after two readbacks refused and were proved again by name, past the two lines it
  // prints (task881_publish_shortcut_readback_refusal_after_the_rename_still_installs), then its receipt.
  const readback = ['winsmux installer: readback_recovered 167 file:6', 'winsmux installer: readback_recovered 167 file:6',
    'winsmux installer: readback_more 1'];
  const receipt = '{"schema":"winsmux-desktop-nsis-transaction-receipt/v1","durable_commit":true}';
  for (const un of ['', 'un.']) {
    for (const eol of ['\n', '\r\n']) {
      const output = [...readback, receipt].map(line => `${line}${eol}`).join('');
      assert.deepEqual(helperSuccessDetails(template, un, output), readback.map(line => `winsmux installer helper: ${line}`), `${un}${JSON.stringify(eol)}`);
      assert.deepEqual(helperSuccessDetails(template, un, `${receipt}${eol}`), [], `${un}${JSON.stringify(eol)}: a receipt alone prints nothing`);
    }
  }
  assert.ok(/Section Install\n[\s\S]*?!insertmacro WINSMUX_REPORT_HELPER_FAILURE "" ""\n  \$\{EndIf\}\n  !insertmacro WINSMUX_PRINT_HELPER_READBACK ""\n[\s\S]*?SectionEnd/u.test(template));
  assert.ok(/Section Uninstall\n[\s\S]*?!insertmacro WINSMUX_REPORT_HELPER_FAILURE "un\." "UN_"\n  \$\{EndIf\}\n  !insertmacro WINSMUX_PRINT_HELPER_READBACK "un\."\n[\s\S]*?SectionEnd/u.test(template));
});

// The T-only observer's helper branch run on one helper exit and output; returns the exit code it sets.
function helperObservedExit(template, exit, output) {
  const body = nsisMacroBody(template, '!macro WINSMUX_OBSERVE_FAILURE STAGE');
  const branch = '  !else if "${STAGE}" == "helper"\n';
  assert.ok(body.startsWith('  StrCpy $2 59\n') && body.includes(branch) && body.includes('\n  !else\n'), 'the helper stage branch is found');
  const statements = ['StrCpy $2 59', ...nsisStatements(body.slice(body.indexOf(branch) + branch.length, body.indexOf('\n  !else\n')), {})];
  const reg = Object.fromEntries(Array.from({ length: 10 }, (_, n) => [`$${n}`, '']));
  Object.assign(reg, { $0: exit, $1: output });
  nsisRun(nsisParse(statements), reg, new Map(), []);
  return reg.$2;
}

test('the T-only exit code names the helper classification even with the restore lines the helper prints after it', () => {
  const template = fs.readFileSync(path.join(repoRoot, 'winsmux-app/src-tauri/nsis/installer.nsi'), 'utf8').replaceAll('\r\n', '\n');
  const observe = (exit, lines, eol) => helperObservedExit(template, exit, lines.map(line => `${line}${eol}`).join(''));
  // The lines desktop_nsis.rs pins after the classification: where a Desktop or Start menu link stands, the
  // rows left, then the readback lines.
  const restore = ['winsmux installer: restore_shortcut_parked desktop', 'winsmux installer: restore_shortcut_unconfirmed start_menu',
    'winsmux installer: restore_incomplete uncertain slot registration slot:0',
    'winsmux installer: restore_incomplete path_refused:171 preserved desktop C:\\Users\\u\\Desktop\\winsmux.lnk',
    'winsmux installer: readback_refused 171 file:6 reopen:5', 'winsmux installer: readback_recovered 170 file:6',
    'winsmux installer: readback_more 4'];
  for (const eol of ['\n', '\r\n']) {
    for (const [exit, cls, code] of [['2', 'registration_conflict', '66'], ['3', 'pending_unconfirmed', '69'], ['2', 'io_unconfirmed', '70'],
      ['2', 'startup_unconfirmed', '71'], ['2', 'member_unconfirmed', '65'], ['171', 'path_refused', '171']]) {
      assert.equal(observe(exit, [`winsmux installer: ${cls}`], eol), code, `${cls} alone`);
      assert.equal(observe(exit, [`winsmux installer: ${cls}`, ...restore], eol), code, `${cls} before the restore lines`);
    }
    const timeout = ['winsmux installer: startup_timeout_phase root_wait=timeout phase=awaiting_pipe_listening', 'winsmux installer: nsis_startup_timeout'];
    assert.equal(observe('2', timeout, eol), '390', 'the two-line startup timeout');
    assert.equal(observe('2', [...timeout, ...restore], eol), '390', 'the two-line startup timeout before the restore lines');
    assert.equal(observe('2', ['winsmux installer: registration_conflict', 'winsmux installer: rollback_incomplete x'], eol), '59', 'a line outside the restore prefix still leaves the output unmatched');
  }
});

test('the abort notices and the T-only exit code survive wherever ExecToStack cuts a long helper output', () => {
  const read = file => fs.readFileSync(path.join(repoRoot, file), 'utf8').replaceAll('\r\n', '\n');
  const template = read('winsmux-app/src-tauri/nsis/installer.nsi');
  const hooks = read('winsmux-app/src-tauri/nsis-installer-hooks.nsh');
  const hook = (name, language) => hooks.match(new RegExp(`^LangString ${name} ${language} "(.*)"$`, 'mu'))?.[1];
  // ExecToStack keeps only the first NSIS_MAX_STRLEN (1024 in the pinned NSIS 3.11) characters of the output.
  // The helper prints its classification, then where the links stand, then at most three row lines and a count
  // of the rest (task881_restore_says_where_the_links_stand_before_its_rows_and_counts_the_rows_past_three).
  const deep = `C:\\Users\\u\\AppData\\Local\\winsmux\\${'nested-folder\\'.repeat(20)}`;
  const lines = ['winsmux installer: io_unconfirmed',
    'winsmux installer: restore_shortcut_parked desktop', 'winsmux installer: restore_shortcut_unconfirmed desktop',
    'winsmux installer: restore_shortcut_parked start_menu', 'winsmux installer: restore_shortcut_unconfirmed start_menu',
    ...['uninstall.exe', 'winsmux.exe', 'winsmux-app.exe'].map(name => `winsmux installer: restore_incomplete io_unconfirmed new root ${deep}${name}`),
    'winsmux installer: restore_incomplete_more 7'];
  const output = lines.map(line => `${line}\n`).join('');
  assert.ok(output.length > 1024, 'the output is longer than ExecToStack carries');
  const firstRow = output.indexOf('winsmux installer: restore_incomplete ');
  for (let cut = lines[0].length + 1; cut <= output.length; cut++) {
    assert.equal(helperObservedExit(template, '2', output.slice(0, cut)), '70', `the class exit code with the output cut at ${cut}`);
  }
  for (const [prefix, language] of [['', '1041'], ['UN_', '1033']]) {
    const said = name => hook(`WINSMUX_${prefix}${name}`, language);
    for (let cut = firstRow + 'winsmux installer: restore_incomplete'.length; cut <= output.length; cut++) {
      const { abort, details } = helperFailureAbort(template, hooks, { prefix, language, output: output.slice(0, cut) });
      assert.equal(abort, [said('RESTORE_INCOMPLETE'), said('RESTORE_PARKED'), said('RESTORE_SHORTCUT_UNCONFIRMED')].join(' '), `${prefix}${language}: cut at ${cut}`);
      assert.ok(details.includes(`winsmux installer helper: ${lines[0]}`), `${prefix}${language}: the classification reaches the details view with the output cut at ${cut}`);
    }
  }
});

test('the restore notices survive what ExecToStack keeps however many readbacks refused', () => {
  const read = file => fs.readFileSync(path.join(repoRoot, file), 'utf8').replaceAll('\r\n', '\n');
  const template = read('winsmux-app/src-tauri/nsis/installer.nsi');
  const hooks = read('winsmux-app/src-tauri/nsis-installer-hooks.nsh');
  const hook = (name, language) => hooks.match(new RegExp(`^LangString ${name} ${language} "(.*)"$`, 'mu'))?.[1];
  // A restore after startup_unconfirmed where eighteen moves were renamed and both of their readbacks refused,
  // a link was left parked and a row left. The helper prints the restore lines before the readback lines, and
  // two of those with a count of the rest
  // (task881_restore_prints_its_notices_before_the_readback_lines_and_counts_those_past_two).
  const refused = 'winsmux installer: readback_refused 170 file:6 reopen:5';
  const restore = ['winsmux installer: restore_shortcut_parked start_menu',
    'winsmux installer: restore_incomplete path_refused:170 new root C:\\winsmux\\winsmux.exe'];
  const printed = ['winsmux installer: startup_unconfirmed', ...restore, refused, refused, 'winsmux installer: readback_more 16'];
  // The order 557251d0 printed: every readback line before the restore lines.
  const unbounded = ['winsmux installer: startup_unconfirmed', ...Array(18).fill(refused), ...restore];
  const kept = lines => lines.map(line => `${line}\n`).join('').slice(0, 1023);
  assert.ok(unbounded.map(line => `${line}\n`).join('').length > 1023, 'the unbounded output is longer than ExecToStack carries');
  assert.equal(helperObservedExit(template, '2', kept(printed)), '71', 'the class exit code');
  for (const [prefix, language] of [['', '1041'], ['', '1033'], ['UN_', '1041'], ['UN_', '1033']]) {
    const said = name => hook(`WINSMUX_${prefix}${name}`, language);
    const { abort, details } = helperFailureAbort(template, hooks, { prefix, language, output: kept(printed) });
    assert.equal(abort, [said('RESTORE_INCOMPLETE'), said('RESTORE_PARKED')].join(' '), `${prefix}${language}`);
    for (const line of printed) assert.ok(details.includes(`winsmux installer helper: ${line}`), `${prefix}${language}: ${line}`);
    // Printed first, the readback lines took both notices out of what ExecToStack kept.
    assert.equal(helperFailureAbort(template, hooks, { prefix, language, output: kept(unbounded) }).abort, said('TRANSACTION_FAILED'), `${prefix}${language}: unbounded`);
  }
});

test('compiler identity refuses unsuccessful observations and malformed captured bytes', () => {
  assert.deepEqual(readRustcIdentity(compilerResult()), { host: target, rustcCommit: measuredCommit });
  for (const change of [{ error: new Error('spawn failed') }, { status: 1 }, { status: null },
    { signal: 'SIGTERM' }, { stdout: 'not captured bytes' }, { stdout: Buffer.from([0xc0, 0xaf]) }]) {
    assert.throws(() => readRustcIdentity({ ...compilerResult(), ...change }));
  }
  for (const text of ['', `host: ${target}\n`, `commit-hash: ${measuredCommit}\n`,
    `host: ${target}\nhost: ${target}\ncommit-hash: ${measuredCommit}\n`,
    `host: ${target}\ncommit-hash: ${measuredCommit}\ncommit-hash: ${measuredCommit}\n`,
    `host: ../bad\ncommit-hash: ${measuredCommit}\n`, `host: ${target}\ncommit-hash: bad\n`,
    `\ufeffhost: ${target}\ncommit-hash: ${measuredCommit}\n`,
    `host: ${target}\ncommit-hash: ${measuredCommit}\n\0`]) {
    assert.throws(() => readRustcIdentity(compilerResult(text)));
  }
});

test('compiler verifier uses product VERSION and preserves the canonical measured input binding', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'winsmux-compiler-binding-'));
  t.after(() => fs.rmSync(root, { recursive: true }));
  const binding = JSON.parse(fs.readFileSync(path.join(repoRoot, 'distribution/windows-licenses/binding.json')));
  const inputs = ['VERSION', ...['binding.json', 'input.json', 'policy.json', 'manifest.json']
    .map(name => 'distribution/windows-licenses/' + name), desktopCurrentLicenseSourcePath,
  ...binding.sources.map(row => row.path)];
  fs.cpSync(path.join(repoRoot, 'distribution/windows-licenses'), path.join(root, 'distribution/windows-licenses'),
    { recursive: true });
  for (const relative of inputs) {
    const destination = path.join(root, relative);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(path.join(repoRoot, relative), destination);
  }
  const verify = result => verifyWindowsDistributionCompiler({ repoRoot: root, rustcResult: result });
  assert.deepEqual(verify(compilerResult()), { schema: 'windows-distribution-toolchain-proof/v1',
    accepted: true, version: '0.38.0', host: target, rustc_commit: measuredCommit });
  for (const text of [`host: aarch64-pc-windows-msvc\ncommit-hash: ${measuredCommit}\n`,
    `host: ${target}\ncommit-hash: ${'0'.repeat(40)}\n`]) assert.throws(() => verify(compilerResult(text)));
  for (const relative of inputs) {
    const file = path.join(root, relative), original = fs.readFileSync(file);
    fs.writeFileSync(file, relative === 'VERSION' ? '0.38.1\n' : Buffer.concat([original, Buffer.from('x')]));
    assert.throws(() => verify(compilerResult()), undefined, relative);
    fs.writeFileSync(file, original);
  }
  assert.equal(verify(compilerResult()).accepted, true);
});

test('real verifier subprocess refuses a missing rustc without accepting a synthetic observation', t => {
  const empty = fs.mkdtempSync(path.join(os.tmpdir(), 'winsmux-no-compiler-'));
  t.after(() => fs.rmSync(empty, { recursive: true }));
  const env = { ...process.env };
  for (const key of Object.keys(env)) if (key.toLowerCase() === 'path') delete env[key];
  env.PATH = empty;
  const result = spawnSync(process.execPath, [path.join(repoRoot, 'scripts/assert-windows-distribution-toolchain.mjs')],
    { cwd: empty, env, encoding: 'utf8', windowsHide: true });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 1);
  assert.deepEqual(JSON.parse(result.stdout), { schema: 'windows-distribution-toolchain-proof/v1',
    accepted: false, status: 'refused' });
});
test('CLI and companion plans explicitly load the target CRT policy from workspace root', () => {
  for (const companions of [false, true]) {
    const plan = windowsDistributionBuildPlan({ ...request, companions }, {});
    assert.equal(plan.cwd, repoRoot);
    assert.ok(plan.args.includes(path.join(repoRoot, 'core/.cargo/config.toml')));
    assert.equal(plan.args[plan.args.indexOf('--target') + 1], target);
    assert.deepEqual(plan.packages, companions ? ['winsmux', 'winsmux-workspace-mcp'] : ['winsmux']);
    assert.deepEqual(plan.args.flatMap((value, index) => value === '--bin' ? [plan.args[index + 1]] : []), plan.packages);
  }
});
test('unsupported targets and flag/wrapper overrides refuse before Cargo', () => {
  assert.throws(() => windowsDistributionBuildPlan({ ...request, target: 'x86_64-unknown-linux-gnu' }, {}));
  for (const key of ['RUSTFLAGS', 'cargo_encoded_rustflags', 'CARGO_BUILD_RUSTFLAGS',
    'CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS', 'RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER',
    'CARGO_BUILD_RUSTC_WRAPPER', 'CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER', 'RUSTC', 'CARGO_BUILD_RUSTC',
    'CC', 'HOST_CC', 'TARGET_CC', 'AR', 'CXX', 'CL', 'LINK', 'CFLAGS_x86_64_pc_windows_msvc']) {
    for (const value of ['', '-Ctarget-feature=-crt-static']) {
      assert.throws(() => windowsDistributionBuildPlan(request, { [key]: value }), /override/u, key);
    }
  }
});
test('all declared machines accept normal and delay OS imports with exact-byte identity', () => {
  for (const [triple, machine] of [['x86_64-pc-windows-msvc', 0x8664], ['i686-pc-windows-msvc', 0x14c], ['aarch64-pc-windows-msvc', 0xaa64]]) {
    const proof = assertWindowsRuntime(fixturePe({ machine, normal: ['KERNEL32.dll'], delayed: ['USER32.dll'] }), triple);
    assert.deepEqual(proof.imports, ['kernel32.dll']);
    assert.deepEqual(proof.delay_imports, ['user32.dll']);
    assert.match(proof.sha256, /^[a-f0-9]{64}$/u);
  }
});
test('known API-set, ordinal imports and ordinary OFT0 remain supported', () => {
  for (const api of ['api-ms-win-core-synch-l1-2-0.dll', 'api-ms-win-core-handle-l1-1-0.dll']) {
    for (const [triple, machine, width] of [['x86_64-pc-windows-msvc', 0x8664, 8],
      ['i686-pc-windows-msvc', 0x14c, 4], ['aarch64-pc-windows-msvc', 0xaa64, 8]]) {
      const proof = assertWindowsRuntime(fixturePe({ machine, normal: [api], delayed: [api] }), triple);
      assert.deepEqual(proof.imports, [api]); assert.deepEqual(proof.delay_imports, [api]);
      const oft0 = fixturePe({ machine, normal: [api] }); oft0.writeUInt32LE(0, 512);
      assert.deepEqual(assertWindowsRuntime(oft0, triple).imports, [api]);
      for (const delayed of [false, true]) {
        const bytes = fixturePe({ machine, [delayed ? 'delayed' : 'normal']: [api] });
        const row = delayed ? 900 : 512;
        const value = (1n << BigInt(width * 8 - 1)) | 1n;
        const put = field => {
          const offset = bytes.readUInt32LE(field) - 0x1000 + 512;
          if (width === 8) bytes.writeBigUInt64LE(value, offset); else bytes.writeUInt32LE(Number(value), offset);
        };
        put(row + (delayed ? 16 : 0)); if (!delayed) put(row + 16);
        assert.deepEqual(assertWindowsRuntime(bytes, triple)[delayed ? 'delay_imports' : 'imports'], [api]);
      }
    }
  }
  for (const [triple, machine, width] of [['x86_64-pc-windows-msvc', 0x8664, 8],
    ['i686-pc-windows-msvc', 0x14c, 4], ['aarch64-pc-windows-msvc', 0xaa64, 8]]) {
    const ordinary = fixturePe({ machine, normal: ['kernel32.dll'] });
    ordinary.writeUInt32LE(0, 512);
    assert.equal(assertWindowsRuntime(ordinary, triple).imports[0], 'kernel32.dll');
    for (const delayed of [false, true]) {
      const bytes = fixturePe({ machine, [delayed ? 'delayed' : 'normal']: ['kernel32.dll'] });
      const row = delayed ? 900 : 512;
      const value = (1n << BigInt(width * 8 - 1)) | 1n;
      const put = field => {
        const offset = bytes.readUInt32LE(field) - 0x1000 + 512;
        if (width === 8) bytes.writeBigUInt64LE(value, offset); else bytes.writeUInt32LE(Number(value), offset);
      };
      put(row + (delayed ? 16 : 0)); if (!delayed) put(row + 16);
      assert.equal(assertWindowsRuntime(bytes, triple)[delayed ? 'delay_imports' : 'imports'][0], 'kernel32.dll');
    }
  }
});
test('dynamic CRT, unknown DLLs and path spellings refuse in either import table', () => {
  for (const name of ['vcruntime140.dll', 'msvcp140.dll', 'concrt140.dll', 'ucrtbase.dll',
    'api-ms-win-crt-runtime-l1-2-0.dll', 'unknown.dll', '../kernel32.dll',
    'api-ms-win-core-review-unknown-l999-9-9.dll', 'api-ms-win-core-synch-l999-9-9.dll',
    'api-ms-win-core-handle-l999-9-9.dll', 'api-ms-win-core-handle-l1-1-1.dll']) {
    for (const field of ['normal', 'delayed']) {
      assert.throws(() => assertWindowsRuntime(fixturePe({ [field]: [name] }), target));
    }
  }
});
test('ordinary and delayed pointer graphs reject every malformed structure across targets', () => {
  for (const [triple, machine, width] of [['x86_64-pc-windows-msvc', 0x8664, 8],
    ['i686-pc-windows-msvc', 0x14c, 4], ['aarch64-pc-windows-msvc', 0xaa64, 8]]) {
    for (const delayed of [false, true]) {
      const row = delayed ? 900 : 512;
      const valid = fixturePe({ machine, [delayed ? 'delayed' : 'normal']: ['kernel32.dll'] });
      const lookupField = row + (delayed ? 16 : 0), addressField = row + (delayed ? 12 : 16);
      const offset = rva => rva - 0x1000 + 512;
      const lookup = offset(valid.readUInt32LE(lookupField)), address = offset(valid.readUInt32LE(addressField));
      const pointerFields = [lookupField, addressField, ...(delayed ? [row + 8] : [])];
      for (const field of pointerFields) {
        const broken = Buffer.from(valid); broken.writeUInt32LE(0xfffffff0, field);
        assert.throws(() => assertWindowsRuntime(broken, triple), undefined, 'unmapped pointer');
      }
      for (const destination of [0x1000 + row - 512, valid.readUInt32LE(row + (delayed ? 4 : 12))]) {
        const broken = Buffer.from(valid); broken.writeUInt32LE(destination, lookupField);
        assert.throws(() => assertWindowsRuntime(broken, triple), undefined, 'structure overlap');
      }
      const writePointer = (bytes, position, value) => width === 8 ? bytes.writeBigUInt64LE(value, position) : bytes.writeUInt32LE(Number(value), position);
      for (const value of [0x7ffffff0n, (1n << BigInt(width * 8 - 1)) | 0x10000n, 0n]) {
        const broken = Buffer.from(valid); writePointer(broken, lookup, value);
        assert.throws(() => assertWindowsRuntime(broken, triple), undefined, 'invalid lookup');
      }
      const shortAddress = Buffer.from(valid); writePointer(shortAddress, address, 0n);
      assert.throws(() => assertWindowsRuntime(shortAddress, triple), undefined, 'different IAT length');
      const trailingAddress = Buffer.from(valid); writePointer(trailingAddress, address + width, 1n);
      assert.throws(() => assertWindowsRuntime(trailingAddress, triple), undefined, 'unterminated IAT');
      const truncated = Buffer.from(valid); truncated.writeUInt32LE(0x1000 + 1536 - width, lookupField);
      writePointer(truncated, 2048 - width, BigInt(0x1000 + 1800 - 512));
      assert.throws(() => assertWindowsRuntime(truncated, triple), undefined, 'unterminated lookup boundary');
      const hint = Buffer.from(valid); hint.fill(0x41, 1802);
      assert.throws(() => assertWindowsRuntime(hint, triple), undefined, 'unterminated hint/name');
      const unsupportedBound = Buffer.from(valid); unsupportedBound.writeUInt32LE(1, row + (delayed ? 28 : 4));
      assert.throws(() => assertWindowsRuntime(unsupportedBound, triple), undefined, 'bound input unsupported');
    }
  }
});
test('wrong CPU, truncated headers/sections and malformed directory mappings refuse', () => {
  assert.throws(() => assertWindowsRuntime(fixturePe({ machine: 0xaa64 }), target), /machine/u);
  const valid = fixturePe({ normal: ['kernel32.dll'], delayed: ['user32.dll'] });
  for (const length of [0, 63, 128, 300, 511, 700, 2047]) {
    assert.throws(() => assertWindowsRuntime(valid.subarray(0, length), target));
  }
  for (const [offset, value] of [[0x80 + 24 + 112 + 8, 0x999999],
    [0x80 + 24 + 112 + 12, 20], [900, 0], [512 + 12, 0], [512 + 16, 0]]) {
    const broken = Buffer.from(valid); broken.writeUInt32LE(value, offset);
    assert.throws(() => assertWindowsRuntime(broken, target));
  }
});

test('all import-directory pairs have one mapped presence authority across every architecture', () => {
  for (const [triple, machine] of [['x86_64-pc-windows-msvc', 0x8664],
    ['i686-pc-windows-msvc', 0x14c], ['aarch64-pc-windows-msvc', 0xaa64]]) {
    const valid = fixturePe({ machine, normal: ['kernel32.dll'], delayed: ['user32.dll'] });
    const directory = 0x80 + 24 + (machine === 0x14c ? 96 : 112);
    for (const index of [1, 11, 12, 13]) {
      for (const [rva, size] of [[0, 16], [0x1000, 0], [0xfffffff0, 32],
        [0x2000, 8], [0x80, 8], [0x1000 + 1536 - 4, 8]]) {
        const broken = Buffer.from(valid), entry = directory + index * 8;
        broken.writeUInt32LE(rva, entry); broken.writeUInt32LE(size, entry + 4);
        assert.throws(() => assertWindowsRuntime(broken, triple), undefined, `directory ${index} ${rva}/${size}`);
      }
    }
    const bound = Buffer.from(valid);
    bound.writeUInt32LE(0x1000 + 1850 - 512, directory + 11 * 8);
    bound.writeUInt32LE(8, directory + 11 * 8 + 4);
    assert.throws(() => assertWindowsRuntime(bound, triple), /Bound imports/u);
    assertWindowsRuntime(fixturePe({ machine }), triple);
  }
});

test('IAT aggregate is exactly the contiguous ordinary IAT union, with explicit absent support', () => {
  for (const [triple, machine, width] of [['x86_64-pc-windows-msvc', 0x8664, 8],
    ['i686-pc-windows-msvc', 0x14c, 4], ['aarch64-pc-windows-msvc', 0xaa64, 8]]) {
    const options = { machine, normal: ['kernel32.dll', 'user32.dll'], delayed: ['shell32.dll'] };
    const valid = fixturePe(options), entry = 0x80 + 24 + (machine === 0x14c ? 96 : 112) + 12 * 8;
    const rva = valid.readUInt32LE(entry), size = valid.readUInt32LE(entry + 4);
    assert.deepEqual(assertWindowsRuntime(valid, triple).imports, ['kernel32.dll', 'user32.dll']);
    assertWindowsRuntime(fixturePe({ ...options, iatDirectory: false }), triple);
    for (const row of [512, 532]) {
      const oft0 = Buffer.from(valid); oft0.writeUInt32LE(0, row);
      assertWindowsRuntime(oft0, triple);
    }
    // Parallel aggregate pointers cannot redirect to another valid structure,
    // hide a table, truncate it, include delay IATs or include extra zero bytes.
    for (const [start, length] of [[rva - width, size + width], [rva, size + width],
      [rva, size - width], [rva, width], [rva + 2 * width, 2 * width],
      [rva + 1, size], [valid.readUInt32LE(512), size],
      [valid.readUInt32LE(524), size], [0x1000, size],
      [valid.readUInt32LE(912), 2 * width], [valid.readUInt32LE(908), width]]) {
      const broken = Buffer.from(valid); broken.writeUInt32LE(start, entry); broken.writeUInt32LE(length, entry + 4);
      assert.throws(() => assertWindowsRuntime(broken, triple), undefined, `aggregate ${start}/${length}`);
    }
    const noOrdinary = fixturePe({ machine, delayed: ['user32.dll'] });
    noOrdinary.writeUInt32LE(noOrdinary.readUInt32LE(912), entry);
    noOrdinary.writeUInt32LE(2 * width, entry + 4);
    assert.throws(() => assertWindowsRuntime(noOrdinary, triple), /ordinary table inventory/u);
    // Move the second ordinary IAT to a valid unused area: absent directory
    // supports disjoint IATs; present aggregate refuses gaps or hidden tables.
    const gap = Buffer.from(valid), second = gap.readUInt32LE(548) - 0x1000 + 512;
    gap.copy(gap, 1296, second, second + 2 * width);
    gap.fill(0, second, second + 2 * width); gap.writeUInt32LE(0x1000 + 1296 - 512, 548);
    for (const length of [size, 1296 + 2 * width - 1216]) {
      gap.writeUInt32LE(length, entry + 4);
      assert.throws(() => assertWindowsRuntime(gap, triple), /complete ordinary table inventory/u);
    }
    gap.writeUInt32LE(0, entry); gap.writeUInt32LE(0, entry + 4);
    assertWindowsRuntime(gap, triple);
    // Two descriptors may share exact names, but cannot alias IAT tables.
    const alias = Buffer.from(valid); alias.writeUInt32LE(alias.readUInt32LE(528), 548);
    assert.throws(() => assertWindowsRuntime(alias, triple), /Overlapping/u);
  }
});


test('Windows Installer runtime inventory accepts exact MSI ordinary and delayed imports', () => {
  for (const imports of [{ normal: ['msi.dll'] }, { delayed: ['msi.dll'] },
    { normal: ['MSI.DLL'], delayed: ['msi.dll'] }]) {
    const proof = assertWindowsRuntime(fixturePe(imports), target);
    assert.ok([...proof.imports, ...proof.delay_imports].every(name => name === 'msi.dll'));
  }
});

test('Windows Installer runtime inventory refuses near names in ordinary and delayed imports', () => {
  for (const name of ['msi2.dll', 'msi-custom.dll', 'msi.dll.evil', '../msi.dll']) {
    for (const kind of ['normal', 'delayed']) {
      assert.throws(() => assertWindowsRuntime(fixturePe({ [kind]: [name] }), target),
        /runtime dependency|PE DLL name/u, kind + ': ' + name);
    }
  }
});

test('Windows 10 inbox runtime inventory accepts exact GUI OS and UCRT ordinary and delayed imports', () => {
  const names = [
    'comctl32.dll', 'dwmapi.dll',
    'api-ms-win-crt-string-l1-1-0.dll', 'api-ms-win-crt-math-l1-1-0.dll',
    'api-ms-win-crt-runtime-l1-1-0.dll', 'api-ms-win-crt-filesystem-l1-1-0.dll',
    'api-ms-win-crt-stdio-l1-1-0.dll', 'api-ms-win-crt-time-l1-1-0.dll',
    'api-ms-win-crt-heap-l1-1-0.dll', 'api-ms-win-crt-convert-l1-1-0.dll',
    'api-ms-win-crt-locale-l1-1-0.dll',
  ];
  for (const name of names) {
    for (const imports of [{ normal: [name] }, { delayed: [name] },
      { normal: [name.toUpperCase()], delayed: [name] }]) {
      const proof = assertWindowsRuntime(fixturePe(imports), target);
      assert.deepEqual(proof.imports, (imports.normal ?? []).map(() => name));
      assert.deepEqual(proof.delay_imports, (imports.delayed ?? []).map(() => name));
    }
  }
});

test('Windows 10 inbox runtime inventory refuses redistributable unknown and near-name dependencies', () => {
  const observed = [
    'comctl32.dll', 'dwmapi.dll',
    'api-ms-win-crt-string-l1-1-0.dll', 'api-ms-win-crt-math-l1-1-0.dll',
    'api-ms-win-crt-runtime-l1-1-0.dll', 'api-ms-win-crt-filesystem-l1-1-0.dll',
    'api-ms-win-crt-stdio-l1-1-0.dll', 'api-ms-win-crt-time-l1-1-0.dll',
    'api-ms-win-crt-heap-l1-1-0.dll', 'api-ms-win-crt-convert-l1-1-0.dll',
    'api-ms-win-crt-locale-l1-1-0.dll',
  ];
  const refused = ['VCRUNTIME140.dll', 'VCRUNTIME140_1.dll', 'MSVCP140.dll', 'ucrtbased.dll',
    'unknown.dll', 'comctl33.dll', 'dwmapi-custom.dll',
    'api-ms-win-crt-unknown-l1-1-0.dll', 'api-ms-win-crt-string-l1-2-0.dll',
    ...observed.flatMap(name => [name + '.evil', '../' + name, name.replace('.dll', '-extra.dll')])];
  for (const name of refused) {
    for (const kind of ['normal', 'delayed']) {
      assert.throws(() => assertWindowsRuntime(fixturePe({ [kind]: [name] }), target),
        /runtime dependency|PE DLL name/u, kind + ': ' + name);
    }
  }
});
