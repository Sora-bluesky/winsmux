import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { scanCoreLocalPaths, assertCoreLocalPaths } from '../../scripts/assert-core-local-paths.mjs';
import * as buildPolicy from '../../scripts/windows-distribution-build.mjs';

const prefixes = ['D:/private/repository', 'E:/build/cargo', 'F:/rust/toolchains'];
// Core license archives use this exact stored ZIP32 representation.
function storedZip(name, raw) {
  const member = Buffer.from(name), local = Buffer.alloc(30), central = Buffer.alloc(46), end = Buffer.alloc(22);
  local.writeUInt32LE(0x04034b50); local.writeUInt32LE(raw.length, 18); local.writeUInt32LE(raw.length, 22);
  local.writeUInt16LE(member.length, 26);
  central.writeUInt32LE(0x02014b50); central.writeUInt32LE(raw.length, 20); central.writeUInt32LE(raw.length, 24);
  central.writeUInt16LE(member.length, 28);
  const records = Buffer.concat([local, member, raw]), directory = Buffer.concat([central, member]);
  end.writeUInt32LE(0x06054b50); end.writeUInt16LE(1, 8); end.writeUInt16LE(1, 10);
  end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(records.length, 16);
  return Buffer.concat([records, directory, end]);
}

test('host path scan detects profile, repository, Cargo and toolchain paths in both encodings and slash styles', () => {
  for (const prefix of ['C:/Users/fixture', ...prefixes]) {
    for (const spelling of [prefix.toUpperCase(), prefix.toLowerCase().replaceAll('/', '\\')]) {
      for (const encoding of ['utf8', 'utf16le']) {
        const raw = Buffer.from(`before\0${spelling}/src/main.rs\0after`, encoding);
        const files = new Map([['winsmux-x64.exe', raw]]);
        const report = scanCoreLocalPaths(files, prefixes);
        assert.equal(report.accepted, false);
        assert.equal(report.files[0].matches, 1);
        assert.equal(report.files[0].sha256, createHash('sha256').update(raw).digest('hex'));
        assert.throws(() => assertCoreLocalPaths(files, prefixes), /local build paths/u);
      }
    }
  }
});

test('archive members and names are scanned and their bytes are bound to the archive hash', () => {
  const raw = storedZip('licenses/component.txt', Buffer.from('E:\\BUILD\\CARGO\\registry\\src'));
  const report = scanCoreLocalPaths(new Map([['winsmux-x64.exe.licenses.zip', raw]]), prefixes);
  assert.equal(report.accepted, false);
  assert.equal(report.files[0].members[0].matches, 1);
  assert.equal(report.files[0].sha256, createHash('sha256').update(raw).digest('hex'));
  const named = storedZip('C:/Users/fixture/input.txt', Buffer.from('license'));
  assert.equal(scanCoreLocalPaths(new Map([['test.zip', named]]), prefixes).accepted, false);
});

test('only the supplied artifact bytes are scanned; clean binaries, checksums and license members pass', () => {
  const files = new Map([['winsmux-x64.exe', Buffer.from('MZ\0/rustc/fixed/library')],
    ['SHA256SUMS', Buffer.from('abc  winsmux-x64.exe\n')],
    ['licenses.zip', storedZip('licenses/component.txt', Buffer.from('legal text'))]]);
  const report = assertCoreLocalPaths(files, prefixes);
  assert.equal(report.accepted, true);
  assert.equal(report.files.length, 3);
  assert.equal(report.matches, 0);
});

test('unscannable input refuses: empty inventory, invalid bytes, truncated or unsupported ZIP', () => {
  assert.throws(() => assertCoreLocalPaths(new Map(), prefixes));
  assert.throws(() => assertCoreLocalPaths(new Map([['exe', null]]), prefixes));
  assert.throws(() => assertCoreLocalPaths(new Map([['exe', Buffer.from('clean')]]), ['/']), /Non-empty/u);
  const zip = storedZip('license.txt', Buffer.from('clean'));
  assert.throws(() => assertCoreLocalPaths(new Map([['bad.zip', zip.subarray(0, -1)]]), prefixes));
  zip.writeUInt16LE(8, 8);
  assert.throws(() => assertCoreLocalPaths(new Map([['compressed.zip', zip]]), prefixes));
});

test('producer profile directories refuse while the product path-detection patterns stay clean', () => {
  for (const encoding of ['utf8', 'utf16le']) {
    for (const literal of ['C:\\Users\\C:\\\\Users\\\\/Users/.claude/local',
      'C:/Users/\0', 'C:/Users/a:b/file', 'C:/Users/a\nb/file']) {
      const patterns = Buffer.from(literal, encoding);
      assert.equal(assertCoreLocalPaths(new Map([['winsmux-x64.exe', patterns]]), prefixes).matches, 0);
    }
    for (const profile of ['another-builder', '別の利用者']) {
      const raw = Buffer.from(`d:/users/${profile}/cargo/src/lib.rs`, encoding);
      assert.equal(scanCoreLocalPaths(new Map([['winsmux-x64.exe', raw]]), prefixes).accepted, false);
      const odd = Buffer.concat([Buffer.from([0xff]), raw]);
      assert.equal(scanCoreLocalPaths(new Map([['winsmux-x64.exe', odd]]), prefixes).accepted, false);
    }
  }
});

test('distribution remaps both spellings of build roots and keeps the static CRT flag', () => {
  assert.equal(typeof buildPolicy.windowsDistributionRustflags, 'function', 'Internal remap policy is required.');
  const flags = buildPolicy.windowsDistributionRustflags({ repoRoot: 'D:/work/repo',
    cargoHome: 'D:/work/repo/cargo', rustupHome: 'F:/rust/toolchains' });
  assert.deepEqual(flags.slice(0, 2), ['-C', 'target-feature=+crt-static']);
  for (const [source, virtual] of [['D:/work/repo', '/winsmux/src'],
    ['D:/work/repo/cargo', '/winsmux/cargo'], ['F:/rust/toolchains', '/winsmux/rustup']]) {
    for (const spelling of [source, source.replaceAll('/', '\\')]) {
      assert.ok(flags.includes(`--remap-path-prefix=${spelling}=${virtual}`));
    }
  }
  assert.ok(flags.indexOf('--remap-path-prefix=D:/work/repo=/winsmux/src')
    < flags.indexOf('--remap-path-prefix=D:/work/repo/cargo=/winsmux/cargo'));
  assert.throws(() => buildPolicy.windowsDistributionRustflags({ repoRoot: 'relative',
    cargoHome: 'E:/cargo', rustupHome: 'F:/rust' }), /absolute/u);
});

test('one build policy owns Rust and target native path flags, including space-containing roots', () => {
  assert.equal(typeof buildPolicy.windowsDistributionPathConfig, 'function', 'Unified compiler path policy is required.');
  for (const target of ['x86_64-pc-windows-msvc', 'aarch64-pc-windows-msvc', 'i686-pc-windows-msvc']) {
    const configs = buildPolicy.windowsDistributionPathConfig({ repoRoot: 'D:/work/repo with spaces',
      cargoHome: 'E:/cargo home', rustupHome: 'F:/rust tools', target });
    const prefix = `target.${target}.rustflags=`;
    assert.ok(configs.some(value => value.startsWith(prefix)));
    for (const compiler of ['CFLAGS', 'CXXFLAGS']) {
      const key = `env.${compiler}_${target.replaceAll('-', '_')}`;
      const entry = configs.find(value => value.startsWith(key + '.value='));
      assert.ok(entry, key);
      assert.ok(configs.includes(key + '.force=true'));
      const flags = JSON.parse(entry.slice((key + '.value=').length));
      assert.ok(flags.includes(JSON.stringify('/d1trimfile:E:/cargo home/')));
      assert.ok(flags.includes(JSON.stringify('/d1trimfile:D:/work/repo with spaces/')));
    }
    assert.ok(configs.includes('env.CC_SHELL_ESCAPED_FLAGS.value="1"'));
    assert.ok(configs.includes('env.CC_SHELL_ESCAPED_FLAGS.force=true'));
  }
});
