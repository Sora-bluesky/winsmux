import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const app = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(resolve(app, 'package.json'));
const { build } = require('esbuild');
const { chromium } = require('playwright');
const evidence = resolve(app, '../verification-evidence/t6-input');
mkdirSync(evidence, { recursive: true });
// Load every product module from the frozen base without stashing or altering the worktree.
const baseline = process.argv.includes('--baseline');
const sourceIndex = process.argv.indexOf('--source-ref');
const sourceRef = sourceIndex >= 0 ? process.argv[sourceIndex + 1] : baseline ? 'fa510131c2a0347e9f2e0e9b016b92ee99dc5b60' : null;
const source = path => sourceRef ? execFileSync('git', ['show', `${sourceRef}:winsmux-app/${relative(app, path).replaceAll('\\', '/')}`], { cwd: app, encoding: 'utf8' }) : readFileSync(path, 'utf8');
const probePath = resolve(app, 'scripts/fixtures/ime-probe-win11-edge.txt');
const probe = readFileSync(probePath, 'utf8');
const probeEvents = probe.trimEnd().split('\n').map((line, index) => {
  const match = /^(\d+\.\d+) ms (\S+) (.*)$/.exec(line);
  if (!match) throw Error(`Invalid probe line ${index + 1}`);
  const event = { time: Number(match[1]), type: match[2], line: index + 1 };
  for (const field of match[3].matchAll(/(\w+)=("(?:\\.|[^"\\])*"|true|false|null|\d+)/g)) event[field[1]] = JSON.parse(field[2]);
  if (typeof event.value !== 'string') throw Error(`Missing probe value at line ${index + 1}`);
  return event;
});
// Exact captured windows, including extra operations in S4-S6. No native event
// inside a window is removed to make the capture agree with the intended task.
// S1 excludes setup/corrections and an additional Enter between S1 and S2.
const replayWindows = [
  ['S1', 48804.6, 57937.6, '日本語\r'],
  ['S2', 65031.3, 74800.7, '日本語\r'],
  ['S3', 78443.1, 90302.5, '😊\r'],
  ['S4', 96649.5, 118035.5, '👇👇\r'],
  ['S5', 120005.4, 132937.5, '👇\r'],
  ['S6', 138794.2, 181797.1, '日本語\rx\r'],
  ['S7', 186066.0, 196640.4, '\r'],
].map(([name, first, last, expected]) => {
  const events = probeEvents.filter(event => event.time >= first && event.time <= last);
  if (!events.length || events[0].time !== first || events.at(-1).time !== last) throw Error(`Invalid replay window ${name}`);
  return { name, events, expected };
});
const plugins = sourceRef ? [{ name: 'frozen-product-source', setup(builder) {
  builder.onLoad({ filter: /[\\/]src[\\/].*\.ts$/ }, args => ({ contents: source(args.path), loader: 'ts', resolveDir: dirname(args.path) }));
} }] : [];
const bundle = await build({ stdin: { contents: "export * from './src/workspace-ui/terminal-input-codec'; export * from './src/workspace-ui/focus'; export * from './src/workspace-ui/project-pane';", resolveDir: app }, bundle: true, write: false, format: 'esm', platform: 'browser', metafile: true, plugins });
const sources = [...Object.keys(bundle.metafile.inputs).filter(path => path !== '<stdin>' && !path.includes('node_modules')).map(path => resolve(path)), resolve(app, 'src/workspace-ui/project-pane.css')]
  .map(path => ({ path: relative(app, path).replaceAll('\\', '/'), sha256: createHash('sha256').update(source(path)).digest('hex') }));
const browser = await chromium.launch({ headless: true, channel: process.env.WINSMUX_TEST_BROWSER_CHANNEL || 'msedge' });
const results = [];
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  await page.route('**/*', route => route.request().url() === 'https://tauri.localhost/'
    ? route.fulfill({ contentType: 'text/html; charset=utf-8', body: '<!doctype html><html lang="ja"><body><div id="view"></div></body></html>' }) : route.abort());
  await page.goto('https://tauri.localhost/');
  await page.addStyleTag({ content: source(resolve(app, 'src/workspace-ui/project-pane.css')) });
  await page.addStyleTag({ content: readFileSync(resolve(app, 'node_modules/xterm/css/xterm.css'), 'utf8') });
  await page.addScriptTag({ content: readFileSync(resolve(app, 'node_modules/xterm/lib/xterm.js'), 'utf8') });
  await page.evaluate(async text => { globalThis.product = await import(URL.createObjectURL(new Blob([text], { type: 'text/javascript' }))); }, bundle.outputFiles[0].text);
  results.push(...await page.evaluate(async replayWindows => {
    const { installTerminalInputCodec, createProjectPaneView } = product;
    const results = [];
    // Native text and its physical Process/229 press have independent lifetimes.
    // End notifications, native input, and key release may cross DOM task boundaries.
    const check = (name, actual, expected) => results.push({ name, passed: JSON.stringify(actual) === JSON.stringify(expected), actual: structuredClone(actual), expected });
    const tick = () => new Promise(resolve => setTimeout(resolve, 5));
    const key = (f, type, options) => f.ta.dispatchEvent(new KeyboardEvent(type, { bubbles: true, cancelable: true, ...options }));
    const enter = (f, type, extra = {}) => key(f, type, { key: 'Enter', code: 'Enter', keyCode: 13, charCode: type === 'keypress' ? 13 : 0, ...extra });
    const separateEnter = f => {
      // Ordinary browser keypress is omitted when xterm cancels keydown. Native
      // confirming presses below are deliberately tested even across all phases.
      if (enter(f, 'keydown')) enter(f, 'keypress');
      enter(f, 'keyup');
    };
    const ordinaryKey = (f, name) => {
      const options = {
        Enter: { key: 'Enter', code: 'Enter', keyCode: 13 },
        Tab: { key: 'Tab', code: 'Tab', keyCode: 9 },
        Backspace: { key: 'Backspace', code: 'Backspace', keyCode: 8 },
        Escape: { key: 'Escape', code: 'Escape', keyCode: 27 },
        'Ctrl+C': { key: 'c', code: 'KeyC', keyCode: 67, ctrlKey: true },
        x: { key: 'x', code: 'KeyX', keyCode: 88 },
      }[name];
      if (key(f, 'keydown', options)) key(f, 'keypress', { ...options, charCode: name === 'x' ? 120 : 0 });
      key(f, 'keyup', options);
    };
    const nativeInput = (name, options) => {
      const event = new InputEvent(name, options);
      // Chromium's constructor drops insertFromComposition; retain the exact
      // native type under test rather than silently testing an empty inputType.
      if (event.inputType !== options.inputType) Object.defineProperty(event, 'inputType', { value: options.inputType });
      return event;
    };
    const input = (f, text, type = 'insertText', composing = false) => {
      f.ta.dispatchEvent(nativeInput('beforeinput', { bubbles: true, cancelable: true, inputType: type, data: text, isComposing: composing }));
      f.ta.value += text;
      f.ta.dispatchEvent(nativeInput('input', { bubbles: true, inputType: type, data: text, isComposing: composing }));
    };
    const fixture = () => {
      const slot = document.createElement('div'); slot.className = 'workspace-terminal'; slot.style.cssText = 'width:800px;height:300px'; document.body.append(slot);
      const terminal = new Terminal(); terminal.open(slot); terminal.focus();
      const out = [], notes = [], f = { slot, terminal, ta: terminal.textarea, out, notes, enabled: true };
      const codec = installTerminalInputCodec(slot, terminal, { target: { paneId: 'test' }, offer: text => { out.push(text); return true; }, focus() {}, pending: () => true, canAccept: () => f.enabled, retire() {} }, text => notes.push(text));
      f.dispose = () => { codec.retire(); terminal.dispose(); slot.remove(); };
      return f;
    };
    globalThis.makeDesktopInputFixture = fixture;
    const vt = { Enter: '\r', Tab: '\t', Backspace: '\x7f', 'Ctrl+C': '\x03', x: 'x' };
    // Rebase only native textarea mutations: the probe's ordinary textarea kept
    // earlier text, whereas xterm cancels VT defaults and the codec clears commits.
    for (const { name, events, expected } of replayWindows) {
      const f = fixture();
      let compositionBase = null, nativeEdit = null, canceled = false;
      for (const event of events) {
        if (event.type === '---tick---') { await tick(); continue; }
        if (event.type === 'focus') { f.ta.focus(); continue; }
        if (event.type === 'blur') { f.ta.blur(); continue; }
        if (event.type.startsWith('key')) {
          if (event.type === 'keydown') canceled = false;
          if (event.type === 'keypress' && canceled) continue;
          const domEvent = new KeyboardEvent(event.type, { bubbles: true, cancelable: true, ...event,
            charCode: event.type === 'keypress' ? event.keyCode : 0 });
          f.ta.dispatchEvent(domEvent);
          if (event.type !== 'keyup') canceled ||= domEvent.defaultPrevented;
          continue;
        }
        if (event.type.startsWith('composition')) {
          if (event.type === 'compositionstart') compositionBase = { recorded: event.value, local: f.ta.value };
          f.ta.dispatchEvent(new CompositionEvent(event.type, { bubbles: true, data: event.data }));
          if (event.type === 'compositionend') compositionBase = null;
          continue;
        }
        if (canceled) continue; // A canceled key has no native default edit in xterm.
        if (event.type === 'beforeinput') nativeEdit = { recorded: event.value, local: f.ta.value };
        if (event.type === 'input') {
          const base = compositionBase ?? nativeEdit;
          if (!base || !event.value.startsWith(base.recorded)) {
            // Conversion replaces the preedit; compositionBase is the original
            // insertion boundary and must remain a prefix throughout that edit.
            throw Error(`Unmapped native mutation ${name}:${event.line}`);
          }
          f.ta.value = base.local + event.value.slice(base.recorded.length);
        }
        f.ta.dispatchEvent(nativeInput(event.type, { bubbles: true, cancelable: event.type === 'beforeinput', ...event }));
      }
      await tick();
      check('recorded replay ' + name, f.out.join(''), expected);
      f.dispose();
    }
    // The requested seven journeys, including the canceled/immediate-x actions
    // absent from the capture, remain explicit synthetic acceptance cases.
    for (const scenario of ['S1', 'S2', 'S3', 'S4', 'S5', 'S6', 'S7']) {
      const f = fixture();
      const canceled = scenario === 'S5' || scenario === 'S7';
      const emoji = scenario === 'S3' || scenario === 'S4';
      const text = emoji ? '😊' : '日本語';
      if (emoji || canceled) key(f, 'keydown', { key: '.', code: 'Period', keyCode: 190, metaKey: true });
      if (!canceled) {
        if (scenario === 'S4') enter(f, 'keydown', { key: 'Process', keyCode: 229 });
        f.ta.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
        input(f, text, 'insertCompositionText', true);
        if (scenario === 'S1' || scenario === 'S6') enter(f, 'keydown', { key: 'Process', keyCode: 229, isComposing: true });
        f.ta.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: text }));
        await tick();
        if (['S1', 'S4', 'S6'].includes(scenario)) enter(f, 'keyup', { key: 'Process', keyCode: 229 });
        check('requested journey commit ' + scenario, f.out.join(''), text);
      } else if (scenario === 'S5') ordinaryKey(f, 'Escape');
      else { f.ta.blur(); f.ta.focus(); }
      ordinaryKey(f, scenario === 'S6' ? 'x' : 'Enter');
      check('requested journey ' + scenario, f.out.join(''), (canceled ? '' : text) + (scenario === 'S6' ? 'x' : '\r'));
      f.dispose();
    }
    {
      const f = fixture();
      f.ta.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      input(f, '日本語', 'insertCompositionText', true);
      f.ta.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '日本語' }));
      await tick(); ordinaryKey(f, 'Enter');
      check('R1 no final input never reserves the next Enter', f.out.join(''), '日本語\r');
      f.dispose();
    }
    for (const next of ['x', 'Tab', 'Backspace', 'Ctrl+C']) {
      const f = fixture();
      f.ta.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      enter(f, 'keydown', { keyCode: 229 });
      f.ta.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '日本語' }));
      ordinaryKey(f, next);
      enter(f, 'keyup'); input(f, '日本語', 'insertFromComposition'); await tick();
      check('R2 key before confirm release is retained ' + next, f.out.join(''), '日本語' + vt[next]);
      f.dispose();
    }
    {
      const f = fixture();
      key(f, 'keydown', { key: '.', code: 'Period', keyCode: 190, metaKey: true });
      f.ta.blur(); f.ta.focus(); ordinaryKey(f, 'Enter');
      check('R3 unopened selection never blocks ordinary Enter', f.out.join(''), '\r');
      f.dispose();
    }
    for (const type of ['insertText', 'insertFromComposition']) {
      const f = fixture();
      f.ta.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      input(f, '日本語', 'insertCompositionText', true);
      enter(f, 'keydown', { keyCode: 229 });
      f.ta.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '日本語' }));
      await tick(); enter(f, 'keyup'); ordinaryKey(f, 'x'); input(f, '日本語', type); await tick();
      check('R4 ordinary key preserves late final receipt ' + type, f.out.join(''), '日本語x');
      f.dispose();
    }
    // A final DOM insertion without an observed confirming press completes the
    // native transaction. The next ordinary key belongs to the shell.
    for (const source of ['ime-end-first', 'ime-input-first', 'ime-text-end-first', 'ime-text-input-first', 'panel', 'panel-end']) {
      for (const next of ['Enter', 'Tab', 'Ctrl+C', 'x', 'Backspace']) {
        const f = fixture();
        const text = source.startsWith('ime') ? '日本語' : '😀';
        const end = () => f.ta.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: text }));
        if (source.startsWith('ime')) {
          f.ta.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
          input(f, text, 'insertCompositionText', true);
          const inputType = source.includes('text') ? 'insertText' : 'insertFromComposition';
          if (source.endsWith('end-first')) end();
          f.ta.dispatchEvent(nativeInput('beforeinput', { bubbles: true, cancelable: true, inputType, data: text }));
          f.ta.value = text;
          f.ta.dispatchEvent(nativeInput('input', { bubbles: true, inputType, data: text }));
          if (source.endsWith('input-first')) end();
        } else {
          key(f, 'keydown', { key: '.', code: 'Period', keyCode: 190, metaKey: true });
          key(f, 'keyup', { key: '.', code: 'Period', keyCode: 190, metaKey: true });
          input(f, text);
          if (source === 'panel-end') end();
        }
        await tick();
        check('B1 mouse commit completes ' + source + '/' + next, f.out.join(''), text);
        ordinaryKey(f, next);
        check('B1 mouse commit releases ' + source + '/' + next, f.out.join(''), text + vt[next]);
        f.dispose();
      }
    }
    // xterm remains the VT encoder while final native text is pending. Every
    // later key, including control keys, follows that text once.
    for (const source of ['composition', 'composition-final-first', 'panel', 'implicit']) {
      for (const endBeforeRelease of [false, true]) {
        for (const sequence of [['x'], ['Tab'], ['Backspace'], ['Ctrl+C'], ['x', 'Tab', 'Backspace', 'Ctrl+C', 'Enter', 'x']]) {
          const f = fixture();
          if (source.startsWith('composition')) f.ta.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
          if (source === 'panel') key(f, 'keydown', { key: '.', code: 'Period', metaKey: true });
          const end = () => f.ta.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '日本語' }));
          enter(f, 'keydown', { keyCode: 229 });
          if (source === 'composition' && endBeforeRelease) end();
          if (source === 'composition-final-first' && endBeforeRelease) input(f, '日本語', 'insertFromComposition');
          enter(f, 'keyup');
          if (source === 'composition-final-first' && !endBeforeRelease) input(f, '日本語', 'insertFromComposition');
          for (const next of sequence) ordinaryKey(f, next);
          check('B2 keys wait for native text ' + source + '/' + endBeforeRelease + '/' + sequence.join(','), f.out, []);
          if (source === 'composition' && !endBeforeRelease) end();
          if (source === 'composition-final-first') { f.ta.blur(); f.ta.focus(); end(); }
          else input(f, '日本語', source === 'composition' ? 'insertFromComposition' : 'insertText');
          await tick();
          check('B2 keys follow native text once ' + source + '/' + endBeforeRelease + '/' + sequence.join(','), f.out.join(''), '日本語' + sequence.map(next => vt[next]).join(''));
          f.dispose();
        }
      }
    }
    // Class-wide ordering table: the physical down/press/up stay ordered; final
    // DOM insertion and compositionend may occur on either side of every phase.
    // A second press after keyup may precede either final notification.
    const interleavings = (keys, native) => !keys.length ? [native] : !native.length ? [keys]
      : [...interleavings(keys.slice(1), native).map(rest => [keys[0], ...rest]), ...interleavings(keys, native.slice(1)).map(rest => [native[0], ...rest])];
    for (const nativeOrder of [['end', 'final'], ['final', 'end']]) {
      for (const order of interleavings(['down', 'press', 'up'], nativeOrder)) {
        for (const earlyNextEnter of [false, true]) {
          const f = fixture(); input(f, 'echo ');
          f.ta.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
          input(f, 'にほんご', 'insertCompositionText', true);
          let confirmLeaked = false;
          for (const step of order) {
            // The capture marks the confirming key itself as Process/229. An
            // unmarked Enter after end is an ordinary shell key (R1/S2/S3).
            if (step === 'down') enter(f, 'keydown', { key: 'Process', keyCode: 229 });
            if (step === 'press') enter(f, 'keypress');
            if (step === 'up') enter(f, 'keyup');
            if (step === 'end') f.ta.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '日本語' }));
            if (step === 'final') {
              f.ta.dispatchEvent(nativeInput('beforeinput', { bubbles: true, cancelable: true, inputType: 'insertFromComposition', data: '日本語' }));
              f.ta.value = '日本語';
              f.ta.dispatchEvent(nativeInput('input', { bubbles: true, inputType: 'insertFromComposition', data: '日本語' }));
            }
            await tick();
            if (!earlyNextEnter || order.indexOf(step) <= order.indexOf('up')) confirmLeaked ||= f.out.join('').includes('\r');
            if (step === 'up' && earlyNextEnter) separateEnter(f);
          }
          check('C1 ordering ' + order.join('/') + ' next=' + earlyNextEnter, { text: f.out.join(''), confirmLeaked }, { text: 'echo 日本語' + (earlyNextEnter ? '\r' : ''), confirmLeaked: false });
          if (!earlyNextEnter) {
            enter(f, 'keydown'); enter(f, 'keyup');
            check('C1 ordering separate Enter ' + order.join('/'), f.out.join(''), 'echo 日本語\r');
          }
          f.dispose();
        }
      }
    }
    for (const order of ['end-before-down', 'end-task-before-down', 'end-between-down-press', 'end-before-keyup', 'end-after-keyup', 'late-dom']) {
      const f = fixture();
      input(f, 'echo ');
      f.ta.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      if (order !== 'late-dom') input(f, '日本語', 'insertCompositionText', true);
      const end = () => f.ta.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '日本語' }));
      if (order === 'end-before-down' || order === 'end-task-before-down') end();
      if (order === 'end-task-before-down') await tick();
      enter(f, 'keydown', { key: 'Process', keyCode: 229 });
      if (order === 'end-between-down-press' || order === 'late-dom') end();
      await tick();
      enter(f, 'keypress');
      if (order === 'end-before-keyup') end();
      enter(f, 'keyup');
      if (order === 'end-after-keyup') end();
      if (order === 'late-dom') input(f, '日本語', 'insertFromComposition');
      await tick();
      check('C1 confirm cycle ' + order, f.out, ['echo ', '日本語']);
      enter(f, 'keydown'); enter(f, 'keyup');
      check('C1 separate Enter ' + order, f.out, ['echo ', '日本語', '\r']);
      f.dispose();
    }
    for (const order of ['text-before-confirm', 'text-after-keydown', 'text-after-keyup']) {
      const f = fixture(); input(f, 'echo ');
      key(f, 'keydown', { key: '.', code: 'Period', keyCode: 190, metaKey: true });
      key(f, 'keyup', { key: '.', code: 'Period', keyCode: 190, metaKey: true });
      if (order === 'text-before-confirm') input(f, '😀');
      enter(f, 'keydown', { key: 'Process', keyCode: 229 });
      if (order === 'text-after-keydown') input(f, '😀');
      key(f, 'keypress', { key: 'あ', code: 'Enter', keyCode: 12354, charCode: 12354 });
      enter(f, 'keyup');
      if (order === 'text-after-keyup') input(f, '😀');
      await tick();
      check('C2 emoji panel ' + order, f.out, ['echo ', '😀']);
      enter(f, 'keydown'); enter(f, 'keyup');
      check('C2 separate Enter ' + order, f.out, ['echo ', '😀', '\r']);
      f.dispose();
    }
    for (const panel of [false, true]) {
      const f = fixture(); input(f, 'echo ');
      if (panel) key(f, 'keydown', { key: '.', code: 'Period', keyCode: 190, metaKey: true });
      else f.ta.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      enter(f, 'keydown', { keyCode: 229 });
      if (!panel) f.ta.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '日本語' }));
      enter(f, 'keyup'); await tick();
      enter(f, 'keydown'); enter(f, 'keyup');
      check('C1/C2 later Enter waits for final DOM ' + panel, f.out, ['echo ']);
      input(f, panel ? '😀' : '日本語', panel ? 'insertText' : 'insertFromComposition');
      await tick();
      check('C1/C2 final text precedes queued CR ' + panel, f.out, ['echo ', (panel ? '😀' : '日本語') + '\r']);
      f.dispose();
    }
    {
      const f = fixture();
      f.ta.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      enter(f, 'keydown', { keyCode: 229 });
      f.ta.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '日本語' }));
      enter(f, 'keyup');
      f.enabled = false; separateEnter(f);
      input(f, '日本語', 'insertFromComposition'); await tick();
      check('C1 frozen producer retains native text without CR', f.out, []);
      f.enabled = true; separateEnter(f);
      check('C1 Enter while frozen is never replayed after resume', f.out.join(''), '日本語\r');
      f.dispose();
    }
    for (const type of ['insertFromComposition', 'insertText']) {
      const f = fixture();
      f.ta.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      input(f, '日本語', 'insertCompositionText', true);
      enter(f, 'keydown');
      f.ta.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '日本語' }));
      await tick(); enter(f, 'keyup');
      input(f, '日本語', type); await tick();
      check('C1 late final DOM is a receipt, not another insertion ' + type, f.out, ['日本語']);
      enter(f, 'keydown'); enter(f, 'keyup');
      check('C1 late final DOM releases next Enter ' + type, f.out, ['日本語', '\r']);
      f.dispose();
    }
    for (const code of ['Enter', 'NumpadEnter']) {
      const f = fixture(); input(f, 'echo ');
      // TSF can report Process/229 and insertText without any composition events or Win+. shortcut.
      key(f, 'keydown', { key: 'Process', code, keyCode: 229 });
      await tick();
      key(f, 'keypress', { key: 'あ', code, keyCode: 12354, charCode: 12354 });
      key(f, 'keyup', { key: 'Enter', code, keyCode: 13 });
      enter(f, 'keydown'); enter(f, 'keyup');
      check('C2 229 without composition waits for text ' + code, f.out, ['echo ']);
      input(f, '😀'); await tick();
      check('C2 229 without composition orders text before CR ' + code, f.out, ['echo ', '😀\r']);
      f.dispose();
    }
    for (const source of ['panel', 'implicit', 'implicit-preedit']) {
      for (const endFirst of [false, true]) {
        const f = fixture();
        if (source === 'panel') key(f, 'keydown', { key: '.', code: 'Period', metaKey: true });
        else key(f, 'keydown', { key: 'Process', code: 'KeyA', keyCode: 229 });
        if (source === 'implicit-preedit') input(f, 'にほんご', 'insertCompositionText', true);
        enter(f, 'keydown', { keyCode: 229 });
        const final = () => {
          f.ta.dispatchEvent(nativeInput('beforeinput', { bubbles: true, cancelable: true, inputType: 'insertText', data: '日本語' }));
          f.ta.value = '日本語';
          f.ta.dispatchEvent(nativeInput('input', { bubbles: true, inputType: 'insertText', data: '日本語' }));
        };
        const end = () => f.ta.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '日本語' }));
        if (endFirst) { end(); await tick(); final(); } else { final(); await tick(); end(); }
        await tick(); enter(f, 'keyup'); separateEnter(f);
        check('C1/C2 missing start final/end order ' + source + '/' + endFirst, f.out.join(''), '日本語\r');
        f.dispose();
      }
    }
    {
      const f = fixture();
      key(f, 'keydown', { key: '.', code: 'Period', metaKey: true });
      input(f, '😀'); input(f, '😀'); enter(f, 'keydown', { keyCode: 229 }); enter(f, 'keyup'); separateEnter(f);
      check('C2 separate same emoji insertions are never deduplicated', f.out.join(''), '😀😀\r');
      f.dispose();
    }
    {
      const f = fixture();
      key(f, 'keydown', { key: '.', code: 'Period', metaKey: true });
      for (let i = 0; i < 2; i++) {
        input(f, '😀');
        f.ta.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '😀' }));
        await tick();
      }
      enter(f, 'keydown', { keyCode: 229 }); enter(f, 'keyup'); separateEnter(f);
      check('C2 committed native input with optional end stays independent', f.out.join(''), '😀😀\r');
      f.dispose();
    }
    for (const flags of [{ isComposing: true }, { keyCode: 229 }]) {
      const f = fixture();
      f.ta.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      input(f, '日本語', 'insertCompositionText', true);
      enter(f, 'keydown', flags);
      f.ta.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '日本語' }));
      await tick();
      enter(f, 'keydown', { repeat: true }); enter(f, 'keypress'); enter(f, 'keyup');
      check('C1 held confirm never repeats CR ' + JSON.stringify(flags), f.out, ['日本語']);
      enter(f, 'keydown'); enter(f, 'keyup');
      check('C1 released confirm permits next press ' + JSON.stringify(flags), f.out, ['日本語', '\r']);
      f.dispose();
    }
    for (const panel of [false, true]) {
      const f = fixture();
      if (panel) key(f, 'keydown', { key: ';', code: 'Semicolon', metaKey: true });
      else { f.ta.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true })); input(f, '日本語', 'insertCompositionText', true); }
      key(f, 'keydown', { key: 'Escape', code: 'Escape', keyCode: 27 });
      if (!panel) {
        f.ta.value = '';
        f.ta.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '' }));
      }
      key(f, 'keyup', { key: 'Escape', code: 'Escape', keyCode: 27 }); await tick();
      enter(f, 'keydown'); enter(f, 'keyup');
      check('C1/C2 canceled native input releases normal Enter ' + panel, f.out, ['\r']);
      f.dispose();
    }
    const f = fixture();
    const ctrlV = new KeyboardEvent('keydown', { bubbles: true, cancelable: true, key: 'v', code: 'KeyV', keyCode: 86, ctrlKey: true });
    f.ta.dispatchEvent(ctrlV);
    check('C3 Ctrl+V is left available for browser paste', { out: f.out, canceled: ctrlV.defaultPrevented }, { out: [], canceled: false });
    const paste = text => { const data = new DataTransfer(); data.setData('text/plain', text); f.ta.dispatchEvent(new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: data })); };
    paste('一\n二');
    check('C3 key then multiline paste uses SDK once', f.out, ['一\r二']);
    await new Promise(resolve => f.terminal.write('\x1b[?2004h', resolve));
    f.out.length = 0;
    key(f, 'keydown', { key: 'v', code: 'KeyV', keyCode: 86, ctrlKey: true }); paste('😀\n二');
    check('C3 Ctrl+V preserves bracketed paste', f.out, ['\x1b[200~😀\r二\x1b[201~']);
    f.dispose();

    const snapshot = { instanceId: 'instance', generation: 'generation', topologyRevision: 1, availability: 'available', busy: false,
      projects: { selected_project_id: 'project', projects: [{ project_id: 'project', display_name: 'test', path: 'C:/synthetic', root_state: 'verified' }] },
      panes: { project_id: 'project', selected_pane_id: 'pane', root: { kind: 'leaf', pane_id: 'pane' }, panes: [{ pane_id: 'pane', project_id: 'project', display_name: 'test', path: 'C:/synthetic', current_run_id: 'run', observation: null }] } };
    let mounted;
    const view = createProjectPaneView(document.querySelector('#view'), snapshot, { control: () => ({ disposition: 'refused' }), inspect() {}, mountTerminal(slot) {
      const terminal = new Terminal(); terminal.open(slot); slot.tabIndex = -1;
      const out = [];
      const codec = installTerminalInputCodec(slot, terminal, { target: { paneId: 'pane' }, offer: text => { out.push(text); return true; }, focus() {}, pending: () => true, canAccept: () => true, retire() {} }, () => {});
      mounted = { terminal, ta: terminal.textarea, out }; return () => { codec.retire(); terminal.dispose(); };
    } });
    mounted.terminal.focus();
    key(mounted, 'keydown', { key: 'Tab', code: 'Tab', keyCode: 9 });
    check('C4 Tab still completes in shell', mounted.out, ['\t']);
    mounted.out.length = 0;
    key(mounted, 'keydown', { key: 'F6', code: 'F6', keyCode: 117 });
    check('C4 F6 leaves real xterm for toolbar', !!document.activeElement.closest('.workspace-toolbar'), true);
    check('C4 F6 does not reach PTY', mounted.out, []);
    document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: 'F6', shiftKey: true, bubbles: true, cancelable: true }));
    check('C4 Shift+F6 returns to real xterm', document.activeElement === mounted.ta, true);
    check('C4 keyboard route is discoverable', document.querySelector('.workspace-project-pane').textContent.includes('F6'), true);
    document.querySelector('[data-action=close-pane]').click();
    const dialogFocus = document.activeElement;
    dialogFocus.dispatchEvent(new KeyboardEvent('keydown', { key: 'F6', bubbles: true, cancelable: true }));
    check('C4 F6 preserves dialog focus ownership', document.activeElement === dialogFocus && !!dialogFocus.closest('dialog[open]'), true);
    document.querySelector('[data-action=modal-return]').click();
    check('C4 dialog returns focus to close invoker', document.activeElement === document.querySelector('[data-action=close-pane]'), true);
    // The preexisting dialog return contract remains covered by the full view check.
    view.dispose();

    const zoomRoot = document.createElement('section'); document.body.append(zoomRoot);
    {
      const zooms = [], notes = [];
      const installZoom = product.installWorkspaceZoom ?? (() => () => {});
      const remove = installZoom(zoomRoot, async value => { zooms.push(value); }, message => notes.push(message));
      for (let i = 0; i < 10; i++) zoomRoot.dispatchEvent(new KeyboardEvent('keydown', { key: '+', ctrlKey: true, bubbles: true, cancelable: true }));
      await tick(); check('C5 keys reach 200%', zooms.at(-1), 2);
      const reset = new KeyboardEvent('keydown', { key: '0', ctrlKey: true, bubbles: true, cancelable: true }); zoomRoot.dispatchEvent(reset);
      await tick(); check('C5 Ctrl+0 resets and is canceled', [zooms.at(-1), reset.defaultPrevented], [1, true]);
      const minus = new KeyboardEvent('keydown', { key: '-', ctrlKey: true, bubbles: true, cancelable: true }); zoomRoot.dispatchEvent(minus);
      await tick(); check('C5 minus zooms out', zooms.at(-1) < 1 && minus.defaultPrevented, true);
      zoomRoot.dispatchEvent(new KeyboardEvent('keydown', { key: '0', ctrlKey: true, bubbles: true, cancelable: true }));
      for (let i = 0; i < 10; i++) zoomRoot.dispatchEvent(new WheelEvent('wheel', { deltaY: -100, ctrlKey: true, bubbles: true, cancelable: true }));
      await tick(); check('C5 wheel reaches 200%', zooms.at(-1), 2);
      for (let i = 0; i < 10; i++) zoomRoot.dispatchEvent(new WheelEvent('wheel', { deltaY: 100, ctrlKey: true, bubbles: true, cancelable: true }));
      await tick(); check('C5 wheel returns to 100%', zooms.at(-1), 1);
      const before = zooms.length; zoomRoot.dispatchEvent(new WheelEvent('wheel', { deltaY: -100, bubbles: true, cancelable: true }));
      zoomRoot.dispatchEvent(new KeyboardEvent('keydown', { key: 'r', ctrlKey: true, bubbles: true, cancelable: true }));
      await tick(); check('C5 ordinary scrolling and other accelerators are untouched', zooms.length, before);
      remove();
    }
    zoomRoot.remove();
    return results;
  }, replayWindows));
  await page.evaluate(() => {
    const f = globalThis.browserPasteFixture = makeDesktopInputFixture();
    f.nativePastes = 0;
    f.intercept = event => {
      if (!event.isTrusted || event.target !== f.ta) return;
      // Keep the system clipboard unchanged and never inspect its contents.
      event.preventDefault(); event.stopImmediatePropagation(); f.nativePastes++;
      const data = new DataTransfer(); data.setData('text/plain', 'browser\npaste');
      f.ta.dispatchEvent(new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: data }));
    };
    document.addEventListener('paste', f.intercept, true);
  });
  await page.keyboard.press('Control+v');
  await page.waitForTimeout(30);
  results.push(await page.evaluate(() => {
    const f = browserPasteFixture;
    const result = { name: 'C3 actual Ctrl+V reaches native paste once', passed: f.nativePastes === 1 && JSON.stringify(f.out) === JSON.stringify(['browser\rpaste']), nativePastes: f.nativePastes, out: [...f.out] };
    document.removeEventListener('paste', f.intercept, true); f.dispose(); return result;
  }));
  await page.evaluate(() => {
    const f = globalThis.browserZoomFixture = makeDesktopInputFixture(); f.zooms = [];
    f.removeZoom = product.installWorkspaceZoom?.(f.slot, async factor => { f.zooms.push(factor); }, () => {});
  });
  for (const chord of ['Control+Equal', 'Control+Shift+Equal', 'Control+Minus', 'Control+0']) await page.keyboard.press(chord);
  await page.waitForTimeout(30);
  results.push(await page.evaluate(() => {
    const f = browserZoomFixture;
    const result = { name: 'C5 actual zoom keys never reach real xterm PTY data', passed: f.out.length === 0 && JSON.stringify(f.zooms) === JSON.stringify([1.1, 1.2, 1.1, 1]), out: [...f.out], zooms: [...f.zooms] };
    f.removeZoom?.(); f.dispose(); return result;
  }));
  for (const forcedColors of ['none', 'active']) {
    await page.emulateMedia({ forcedColors });
    results.push(...await page.evaluate(forcedColors => {
      const root = document.createElement('section'); root.className = 'workspace-project-pane';
      const terminal = document.createElement('div'); terminal.className = 'workspace-terminal';
      const button = document.createElement('button'); button.textContent = 'control'; root.append(terminal, button); document.body.append(root);
      const xterm = new Terminal(); xterm.open(terminal); const textarea = xterm.textarea;
      const visible = style => style.outlineStyle !== 'none' && parseFloat(style.outlineWidth) >= 2 && style.outlineColor !== 'rgba(0, 0, 0, 0)';
      textarea.focus(); const terminalVisible = visible(getComputedStyle(terminal));
      button.focus(); const buttonVisible = visible(getComputedStyle(button));
      const values = [{ name: 'C4 terminal focus ring ' + forcedColors, passed: terminalVisible }, { name: 'C4 button focus ring ' + forcedColors, passed: buttonVisible }];
      xterm.dispose(); root.remove(); return values;
    }, forcedColors));
  }
} finally { await browser.close(); }
writeFileSync(resolve(evidence, baseline ? 'desktop-input-before.json' : sourceRef ? 'desktop-input-reference.json' : 'desktop-input.json'), JSON.stringify({ sourceRef, sources,
  probe: { path: relative(app, probePath).replaceAll('\\', '/'), sha256: createHash('sha256').update(probe).digest('hex'),
    windows: replayWindows.map(({ name, events, expected }) => ({ name, firstLine: events[0].line, lastLine: events.at(-1).line, expected })) },
  scope: 'installed xterm in headless Edge; recorded Win11 native event replay and synthetic IME DOM events; stub PTY producer and native zoom setter; trusted Ctrl+V paste event with synthetic clipboard text', results }, null, 2) + '\n', 'utf8');
for (const result of results) console.log(`${result.passed ? 'PASS' : 'FAIL'} ${result.name}${result.passed ? '' : ' ' + JSON.stringify(result)}`);
console.log(`desktop input: ${results.filter(result => result.passed).length}/${results.length} passed`);
if (results.some(result => !result.passed)) process.exitCode = 1;
