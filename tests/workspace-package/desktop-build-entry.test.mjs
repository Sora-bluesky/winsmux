import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { after, test } from 'node:test';
import { desktopBuildArguments } from '../../winsmux-app/scripts/tauri-cli.mjs';

const launcher = fileURLToPath(new URL('../../winsmux-app/scripts/tauri-cli.mjs', import.meta.url));
const buildCases = [
  ['default', ['build']],
  ['no-bundle', ['build', '--no-bundle']],
  ...['msi', 'nsis', 'all'].map(format => [format, ['build', '--bundles', format]]),
  ['signed-config', ['build', '--config', 'src-tauri/tauri.ci.conf.json']],
  ['config-json-values', ['build', '--config', '{"value":"build --lib --help"}']],
  ['config-equals-value', ['build', '--config=--lib']],
  ['profile-features-target', ['build', '--target', 'x86_64-pc-windows-msvc', '--features', 'one,two', '--', '--profile', 'release']],
  ['cargo-tail', ['build', '--', '--locked']],
  ['cargo-help', ['build', '--', '--help']],
  ['cargo-lookalike', ['build', '--', '--lib-extra']],
  ['verbose-short', ['-v', 'build']],
  ['verbose-count', ['-vv', 'build']],
  ['verbose-long', ['--verbose', 'build']],
  ['verbose-combined', ['-v', '--verbose', '-vvv', 'build']],
];
for (const [name, input] of buildCases) {
  test(`build requests the library: ${name}`, () => {
    const original = [...input];
    const expected = input.includes('--') ? [...input, '--lib'] : [...input, '--', '--lib'];
    const actual = desktopBuildArguments(input);
    assert.deepEqual(actual, expected);
    assert.deepEqual(input, original);
    assert.deepEqual(desktopBuildArguments(actual), actual);
  });
}

const unchangedCases = [
  ['existing-library', ['build', '--', '--lib']],
  ['existing-library-in-tail', ['-v', 'build', '--config', 'signed.json', '--', '--locked', '--lib', '--offline']],
  ['dev', ['dev', '--features', 'build']],
  ['bundle', ['bundle', '--bundles', 'msi']],
  ['mobile-build', ['android', 'build']],
  ['mobile-ios-build', ['ios', 'build']],
  ['help-command', ['help', 'build']],
  ['help-flag', ['--help']],
  ['version', ['--version']],
  ['build-help', ['build', '--help']],
  ['build-short-help', ['-v', 'build', '-h']],
  ['build-help-with-options', ['build', '--config', 'signed.json', '--help']],
  ['invalid-config-help', ['build', '--config', '--help']],
  ['unknown-command-value', ['info', 'build']],
  ['global-option-value', ['--config', 'build']],
  ['separator-first', ['--', 'build']],
  ['empty', []],
];
for (const [name, input] of unchangedCases) {
  test(`preserve SDK arguments: ${name}`, () => {
    const actual = desktopBuildArguments(input);
    assert.deepEqual(actual, input);
    assert.notEqual(actual, input);
  });
}

const tempParent = fs.realpathSync(os.tmpdir());
const owned = fs.mkdtempSync(path.join(tempParent, 'winsmux-desktop-build-entry-'));
after(() => {
  assert.equal(path.dirname(owned), tempParent);
  assert.match(path.basename(owned), /^winsmux-desktop-build-entry-[A-Za-z0-9]+$/u);
  fs.rmSync(owned, { recursive: true });
});
const fixture = path.join(owned, '日本語 & SDK input');
const fixtureLauncher = path.join(fixture, 'tauri-cli.mjs');
const sdk = path.join(fixture, 'node_modules', '@tauri-apps', 'cli');
fs.mkdirSync(sdk, { recursive: true });
fs.copyFileSync(launcher, fixtureLauncher);
fs.writeFileSync(path.join(sdk, 'package.json'), JSON.stringify({ name: '@tauri-apps/cli', version: '2.11.1', main: 'main.js' }));
fs.writeFileSync(path.join(sdk, 'main.js'), [
  "exports.run = (args, binName) => args.includes('__reject__')",
  "  ? Promise.reject(new Error('synthetic SDK rejection'))",
  "  : Promise.resolve().then(() => process.stdout.write(JSON.stringify({ args, binName }) + '\\n'));",
  "exports.logError = message => process.stderr.write('sdk-error: ' + message + '\\n');",
].join('\n'));

for (const [name, args, expected] of [
  ['build', ['--verbose', 'build', '--config', '日本語 & signed.json', '--', '--features', 'one two & three'],
    ['--verbose', 'build', '--config', '日本語 & signed.json', '--', '--features', 'one two & three', '--lib']],
  ['direct-bundle', ['bundle', '--config', '日本語 & unsigned.json', '--bundles', 'all'],
    ['bundle', '--config', '日本語 & unsigned.json', '--bundles', 'all']],
  ['SDK-help', ['build', '--config', '日本語 & signed.json', '--help'],
    ['build', '--config', '日本語 & signed.json', '--help']],
]) {
  test(`actual launcher forwards an argv array to SDK run: ${name}`, () => {
    const child = spawnSync(process.execPath, [fixtureLauncher, ...args], { cwd: fixture, shell: false, windowsHide: true });
    assert.ifError(child.error);
    assert.equal(child.signal, null);
    assert.equal(child.status, 0);
    assert.equal(child.stderr.length, 0);
    const output = new TextDecoder('utf-8', { fatal: true }).decode(child.stdout);
    assert.deepEqual(JSON.parse(output), { args: expected, binName: 'npm run tauri' });
  });
}

test('SDK Promise rejection uses the SDK logger and exit 1', () => {
  const child = spawnSync(process.execPath, [fixtureLauncher, 'info', '__reject__'], { cwd: fixture, shell: false, windowsHide: true });
  assert.ifError(child.error);
  assert.equal(child.signal, null);
  assert.equal(child.status, 1);
  assert.equal(child.stdout.length, 0);
  assert.equal(new TextDecoder('utf-8', { fatal: true }).decode(child.stderr), 'sdk-error: synthetic SDK rejection\n');
});
