import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { readRustcIdentity, verifyWindowsDistributionCompiler } from '../../scripts/assert-windows-distribution-toolchain.mjs';
import { assertWindowsRuntime } from '../../scripts/assert-windows-runtime.mjs';
import { windowsDistributionBuildPlan } from '../../scripts/windows-distribution-build.mjs';
import { fixturePe } from './fixture-pe.mjs';

const target = 'x86_64-pc-windows-msvc';
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const request = { repoRoot, target, targetRoot: path.join(repoRoot, 'target'),
  intermediateRoot: path.join(repoRoot, 'intermediate') };
const measuredCommit = 'ac68faa20c58cbccd01ee7208bf3b6e93a7d7f96';
const compilerResult = text => ({ status: 0, signal: null,
  stdout: Buffer.from(text ?? `host: ${target}\ncommit-hash: ${measuredCommit}\n`) });

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
  for (const relative of ['VERSION', 'distribution/windows-licenses/binding.json',
    'distribution/windows-licenses/input.json', ...binding.sources.map(row => row.path)]) {
    const destination = path.join(root, relative);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(path.join(repoRoot, relative), destination);
  }
  const verify = result => verifyWindowsDistributionCompiler({ repoRoot: root, rustcResult: result });
  assert.deepEqual(verify(compilerResult()), { schema: 'windows-distribution-toolchain-proof/v1',
    accepted: true, version: '0.38.0', host: target, rustc_commit: measuredCommit });
  for (const text of [`host: aarch64-pc-windows-msvc\ncommit-hash: ${measuredCommit}\n`,
    `host: ${target}\ncommit-hash: ${'0'.repeat(40)}\n`]) assert.throws(() => verify(compilerResult(text)));
  for (const relative of ['VERSION', 'distribution/windows-licenses/binding.json',
    'distribution/windows-licenses/input.json', ...binding.sources.map(row => row.path)]) {
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
    'api-ms-win-crt-runtime-l1-1-0.dll', 'unknown.dll', '../kernel32.dll',
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
