import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// Synthetic bundle consumer. No external destination or publication operation.
const [mode, fixtureRoot, ...args] = process.argv.slice(2);
const fixture = JSON.parse(fs.readFileSync(path.join(fixtureRoot, 'custody-fixture.json'), 'utf8'));
if (!fixture.synthetic || fixture.publication_admitted !== false) throw new Error('Synthetic input required');
function verifyBundle() {
  for (let i = 0; i < fixture.names.length; i++) {
    const actual = crypto.createHash('sha256').update(fs.readFileSync(path.join(fixture.bundle_root, fixture.names[i]))).digest('hex');
    if (actual !== fixture.hashes[i]) throw new Error('Consumer observed changed bundle');
  }
}
const write = (name, value) => fs.writeFileSync(path.join(fixtureRoot, name), `${JSON.stringify(value)}\n`, { flag: 'wx' });
verifyBundle();
if (mode === 'root') {
  // Detached bypasses libuv's own kill-child-on-parent-exit Job. The native
  // publication Job still owns this descendant; that inheritance is tested.
  const child = spawn(process.execPath, [fileURLToPath(import.meta.url), 'descendant', fixtureRoot], { stdio: 'ignore', windowsHide: true, detached: true });
  child.once('error', error => { write('spawn-error.json', { message: error.message }); process.exit(23); });
  child.once('spawn', () => {
    write('root-result.json', { pid: process.pid, descendant: child.pid, arguments: args, files_read: fixture.names.length });
    child.unref();
    process.exit(0);
  });
} else if (mode === 'descendant') {
  write('descendant-ready.json', { pid: process.pid, files_read: fixture.names.length });
  const deadline = Date.now() + 20000; // Fixture watchdog only; no release policy deadline.
  const poll = setInterval(() => {
    if (fs.existsSync(path.join(fixtureRoot, 'finish-descendant'))) {
      clearInterval(poll); verifyBundle(); write('descendant-result.json', { pid: process.pid, files_read: fixture.names.length }); process.exit(0);
    } else if (Date.now() > deadline) { clearInterval(poll); write('descendant-timeout.json', { pid: process.pid }); process.exit(24); }
  }, 50);
} else if (mode === 'nonzero') {
  write('nonzero-result.json', { pid: process.pid, files_read: fixture.names.length }); process.exit(37);
} else throw new Error('Unknown synthetic child mode');
