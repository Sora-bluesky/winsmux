import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const app = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(resolve(app, 'package.json'));
const { build } = require('esbuild');
const compiled = await build({ entryPoints: [resolve(app, 'src/workspace-ui/workspace-copy-gate.ts')], bundle: true, write: false, format: 'esm', platform: 'node' });
const { createWorkspaceCopyGate } = await import('data:text/javascript;base64,' + Buffer.from(compiled.outputFiles[0].text).toString('base64'));
const checks = [];
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
{
  const gate = createWorkspaceCopyGate(), native = deferred(); let readers = 0, writes = 0;
  assert.equal(gate.canReserveControl(), true);
  const issued = gate.send(true, () => native.promise);
  const copy = gate.beginCopy(); assert(copy);
  assert.equal(gate.canReserveControl(), false); assert.equal(gate.canReserveControl(copy), true);
  const waiting = gate.send(true, async () => ++readers);
  const denied = gate.send(false, async () => ++writes);
  await assert.rejects(denied, /host_not_sent/); assert.equal(readers, 0); assert.equal(writes, 0);
  native.resolve('original'); assert.equal(await issued, 'original'); assert.equal(await copy.ready, true);
  assert.equal(readers, 0); assert.equal(gate.endCopy(copy), true); assert.equal(await waiting, 1);
  assert.equal(gate.canReserveControl(), true); assert.equal(gate.canReserveControl(copy), false);
  checks.push('issued native flight alone drains; reads wait; mutations are never queued or dispatched');
}
for (const mode of ['synchronous throw', 'Promise rejection']) {
  const gate = createWorkspaceCopyGate();
  const rejected = gate.send(true, () => { if (mode === 'synchronous throw') throw Error(mode); return Promise.reject(Error(mode)); });
  const handled = assert.rejects(rejected, new RegExp(mode));
  const copy = gate.beginCopy(); await handled; assert.equal(await copy.ready, true); gate.endCopy(copy);
  assert.equal(await gate.send(true, async () => 'later'), 'later'); checks.push(mode + ' settles native registration and permits later copy/read');
}
{
  const gate = createWorkspaceCopyGate(), native = deferred(); let delivered = 0;
  const old = gate.send(true, () => native.promise), copy = gate.beginCopy();
  const waiting = gate.send(true, async () => ++delivered); const rejected = assert.rejects(waiting, /session_closed/);
  gate.retire(); assert.equal(await copy.ready, false); await rejected; assert.equal(delivered, 0);
  assert.equal(gate.canReserveControl(), false); assert.equal(gate.canReserveControl(copy), false);
  assert.equal(gate.endCopy(copy), false); assert.equal(gate.beginCopy(), null);
  native.resolve('old terminal preserved'); assert.equal(await old, 'old terminal preserved');
  await assert.rejects(gate.send(true, async () => ++delivered), /session_closed/); assert.equal(delivered, 0);
  checks.push('retirement cancels copy/read waiters without discarding an already issued native terminal');
}
{
  const gate = createWorkspaceCopyGate(); const previous = gate.beginCopy(); await previous.ready; gate.endCopy(previous);
  const current = gate.beginCopy(); await current.ready; let reads = 0;
  const waiting = gate.send(true, async () => ++reads);
  assert.equal(gate.endCopy(previous), false); assert.equal(reads, 0);
  assert.equal(gate.canReserveControl(previous), false); assert.equal(gate.canReserveControl(current), true);
  assert.equal(gate.endCopy(current), true); assert.equal(await waiting, 1); assert.equal(gate.endCopy(current), false);
  const replacement = createWorkspaceCopyGate(); const fresh = replacement.beginCopy(); await fresh.ready;
  assert.equal(replacement.canReserveControl(previous), false); assert.equal(replacement.canReserveControl(fresh), true);
  assert.equal(replacement.endCopy(previous), false); assert.equal(replacement.endCopy(fresh), true);
  checks.push('old and duplicate releases cannot reopen a different copy or owner gate');
}
console.log(JSON.stringify({ success: true, checks }, null, 2));
