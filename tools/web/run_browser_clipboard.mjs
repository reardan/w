// Real-browser check of the W clipboard on the web (issue #910,
// docs/projects/ui_clipboard.md §6): the copy/cut/paste DOM events, the
// navigator.clipboard fallback with and without permission, rich copies
// (text/html, image/png) and the double/triple-click and middle-click
// selection paths, all through the compiled W page
// graphics/ui/clipboard_demo_web.w in tools/web/index.html.
// Usage:
//   ./wbuild graphics_ui_clipboard_web
//   node tools/web/run_browser_clipboard.mjs bin/graphics_ui_clipboard.wasm [browser...]
//
// Browsers are Playwright's ("chromium", "firefox", "webkit"; default
// chromium), resolved from the preinstalled Playwright package. A browser
// Playwright has not installed is reported as SKIP for that browser (exit 0
// unless W_REQUIRE_BROWSER=1); any failed check exits 1.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { join, resolve, extname, sep } from 'node:path';

const wasmPath = process.argv[2] ?? 'bin/graphics_ui_clipboard.wasm';
const wanted = process.argv.slice(3).length ? process.argv.slice(3) : ['chromium'];
const require_ = process.env.W_REQUIRE_BROWSER === '1';
const root = resolve('.');

const loadPlaywright = () => {
  const bases = [join(process.cwd(), 'x.js'), import.meta.url];
  try { bases.push(join(execFileSync('npm', ['root', '-g']).toString().trim(), 'x.js')); } catch { /* no npm */ }
  for (const base of bases) {
    try { return createRequire(base)('playwright'); } catch { /* not there */ }
  }
  return null;
};
const playwright = loadPlaywright();
if (!playwright) {
  console.log('run_browser_clipboard SKIP (no Playwright package)');
  process.exit(require_ ? 1 : 0);
}

const types = { '.html': 'text/html', '.mjs': 'text/javascript', '.js': 'text/javascript',
  '.wasm': 'application/wasm', '.json': 'application/json' };
const server = createServer(async (req, res) => {
  const pathname = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  const path = resolve(root, '.' + pathname);
  const file = pathname.endsWith('/') ? join(path, 'index.html') : path;
  if (!file.startsWith(root + sep)) { res.writeHead(403); res.end(); return; }
  try {
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream' });
    res.end(body);
  } catch { res.writeHead(404); res.end(); }
});
await new Promise(ok => server.listen(0, '127.0.0.1', ok));
// localhost, not 127.0.0.1: a secure context, which navigator.clipboard needs.
const origin = `http://localhost:${server.address().port}`;
const url = `${origin}/tools/web/?module=/${wasmPath}`;

// One page of the W program with its console lines collected.
async function openDemo(context) {
  const page = await context.newPage();
  const lines = [];
  // One console message per W write; W prints whole lines, with a line
  // feed inside a field's text escaped as \n.
  page.on('console', m => lines.push(m.text().replace(/\n$/, '').replace(/\\n/g, '\n')));
  page.on('pageerror', e => lines.push(`pageerror: ${e}`));
  await page.goto(url);
  const until = async (test, what, ms = 5000) => {
    const deadline = Date.now() + ms;
    while (Date.now() < deadline) {
      const hit = lines.find((l, i) => test(l, i));
      if (hit !== undefined) return hit;
      await page.waitForTimeout(20);
    }
    throw new Error(`timed out waiting for ${what}; console:\n${lines.join('\n')}`);
  };
  await until(l => l === 'ready', 'the W program to start');
  const field = k => Number(/\S+/.exec(lines.find(l => l.startsWith('geometry')).split(`${k}=`)[1])[0]);
  const width = k => Number(/\S+/.exec(lines.find(l => l.startsWith('widths')).split(`${k}=`)[1])[0]);
  const box = await page.locator('#canvas').boundingBox();
  const at = (x, y) => [box.x + x, box.y + y];
  const g = {
    beta: at(field('box_x') + width('beta'), field('box_y')),
    boxEnd: at(field('box_x') + 360, field('box_y')),
    two: at(field('area_x') + width('two'), field('area_y') + field('line_h') / 2),
    areaStart: at(field('area_x') - 2, field('area_y') + field('line_h') / 2),
    copy: at(32, 232), paste: at(172, 232), rich: at(312, 232), empty: at(200, 300),
  };
  // The latest report of a field ("box" or "area").
  const last = name => {
    const hit = lines.filter(l => l.startsWith(`${name}:`)).at(-1);
    return hit === undefined ? undefined : hit.slice(name.length + 1);
  };
  const waitFor = async (name, text, what) => {
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline) {
      if (last(name) === text) return;
      await page.waitForTimeout(20);
    }
    throw new Error(`${what}: ${name} is ${JSON.stringify(last(name))}, wanted ${JSON.stringify(text)}`);
  };
  const frames = n => page.evaluate(n => new Promise(ok => {
    const step = k => (k === 0 ? ok() : requestAnimationFrame(() => step(k - 1)));
    step(n);
  }), n);
  return { page, lines, g, last, waitFor, until, frames };
}

const mod = browser => (browser === 'webkit' ? 'Meta' : 'Control');
const clipText = page => page.evaluate(() => navigator.clipboard.readText());

async function runBrowser(name) {
  const type = playwright[name];
  if (!type) return `${name}: SKIP (Playwright has no ${name})`;
  const exe = type.executablePath();
  if (!exe || !existsSync(exe)) return `${name}: SKIP (Playwright has not installed ${name})`;
  const launch = name === 'firefox'
    ? { firefoxUserPrefs: { 'dom.events.asyncClipboard.readText': true, 'dom.events.testing.asyncClipboard': true } }
    : {};
  const browser = await type.launch({ headless: true, ...launch });
  const results = [];
  const ok = what => results.push(what);
  const C = mod(name);
  try {
    // ---- with clipboard permissions: every path, read back through the API.
    const granted = await browser.newContext({ viewport: { width: 640, height: 480 } });
    if (name === 'chromium') await granted.grantPermissions(['clipboard-read', 'clipboard-write'], { origin });
    let d = await openDemo(granted);
    const { page, g } = d;
    // Double-click selects the word; Ctrl+C runs W's copy inside the copy
    // event, so the text lands on clipboardData.
    await page.mouse.dblclick(...g.beta);
    await d.frames(2);
    await page.keyboard.press(`${C}+c`);
    assert.equal(await clipText(page), 'beta', 'double-click + Ctrl+C copies the word');
    ok('copy event (double-click word)');
    await page.waitForTimeout(600);
    await page.mouse.click(...g.beta, { clickCount: 3 });
    await d.frames(2);
    await page.keyboard.press(`${C}+c`);
    assert.equal(await clipText(page), 'alpha beta gamma', 'triple-click + Ctrl+C copies the line');
    ok('copy event (triple-click line)');
    // Cut: the word goes to the clipboard and out of the field. (Wait out
    // the click interval first, or this would be clicks four and five.)
    await page.waitForTimeout(600);
    await page.mouse.dblclick(...g.beta);
    await d.frames(2);
    await page.keyboard.press(`${C}+x`);
    await d.waitFor('box', 'alpha  gamma', 'Ctrl+X removes the selection');
    assert.equal(await clipText(page), 'beta');
    ok('cut event');
    // Paste: the paste event's clipboardData answers W's read.
    await page.evaluate(() => navigator.clipboard.writeText('pasted ✓'));
    await page.mouse.click(...g.boxEnd);
    await d.frames(2);
    await page.keyboard.press(`${C}+v`);
    await d.waitFor('box', 'alpha  gammapasted ✓', 'Ctrl+V pastes from the paste event');
    ok('paste event');
    // navigator.clipboard outside the events: a button copies and pastes.
    await page.mouse.click(...g.copy);
    await d.frames(3);
    assert.equal(await clipText(page), 'alpha  gammapasted ✓', 'the Copy button writes through navigator.clipboard');
    ok('navigator.clipboard.writeText fallback');
    await page.evaluate(() => navigator.clipboard.writeText('|api|'));
    await page.mouse.click(...g.paste);
    await d.waitFor('box', 'alpha  gammapasted ✓|api|', 'the Paste button reads through navigator.clipboard');
    ok('navigator.clipboard.readText fallback (permission granted)');
    // Rich copies: inside the copy event (nothing focused, Ctrl+C) and from
    // a button; both offer text/plain, text/html and image/png.
    const flavors = () => page.evaluate(async () => {
      const items = await navigator.clipboard.read();
      const out = {};
      for (const item of items) {
        for (const type of item.types) {
          const blob = await item.getType(type);
          out[type] = type.startsWith('text/') ? await blob.text() : Array.from(new Uint8Array(await blob.arrayBuffer()).slice(0, 4));
        }
      }
      return out;
    });
    await page.evaluate(() => navigator.clipboard.writeText('stale'));
    await page.mouse.click(...g.empty);
    await d.frames(2);
    await page.keyboard.press(`${C}+c`);
    await page.waitForTimeout(300);
    let got = await flavors();
    assert.equal(got['text/plain'], 'rich text');
    assert.match(got['text/html'] ?? '', /<b>rich<\/b> html/);
    assert.deepEqual(got['image/png'], [137, 80, 78, 71], 'the image flavor is a PNG');
    ok('rich copy inside the copy event (text/plain + text/html + image/png)');
    await page.evaluate(() => navigator.clipboard.writeText('stale'));
    await page.mouse.click(...g.rich);
    await page.waitForTimeout(300);
    got = await flavors();
    assert.equal(got['text/plain'], 'rich text');
    assert.deepEqual(got['image/png'], [137, 80, 78, 71]);
    ok('rich copy outside an event (ClipboardItem)');
    // Middle-click pastes the page's own PRIMARY (the last selection).
    await page.waitForTimeout(600);
    await page.mouse.dblclick(...g.two);
    await d.frames(2);
    await page.mouse.click(...g.areaStart, { button: 'middle' });
    await d.waitFor('area', 'twoone two\nthree', 'middle-click pastes the last selection');
    ok('double-click in the textarea + middle-click PRIMARY paste');
    await granted.close();

    // ---- without clipboard-read permission: the events still work, the
    // API read is refused and W stops waiting instead of hanging.
    const bare = await browser.newContext({ viewport: { width: 640, height: 480 } });
    d = await openDemo(bare);
    const p2 = d.page;
    // Put text on the system clipboard with a native copy (no API).
    await p2.evaluate(() => {
      const t = document.createElement('textarea');
      t.id = 'native';
      t.value = 'native text';
      document.body.append(t);
    });
    await p2.locator('#native').selectText();
    await p2.keyboard.press(`${C}+c`);
    await p2.mouse.click(...d.g.boxEnd);
    await d.frames(2);
    await p2.keyboard.press(`${C}+v`);
    await d.waitFor('box', 'alpha beta gammanative text', 'Ctrl+V needs no permission');
    ok('paste event without permission');
    // The Copy button copies outside a copy event; Ctrl+V into the field
    // (an event, so no permission) shows what reached the clipboard.
    const beforeWrite = d.lines.length;
    await p2.mouse.click(...d.g.copy);
    await d.frames(3);
    await p2.waitForTimeout(200);
    const writeRefusal = d.lines.slice(beforeWrite).find(l => l.includes('clipboard write refused'));
    await p2.mouse.click(...d.g.boxEnd);
    await d.frames(2);
    await p2.keyboard.press(`${C}+v`);
    await p2.waitForTimeout(300);
    const doubled = d.last('box') === 'alpha beta gammanative textalpha beta gammanative text';
    results.push(`copy from a click without permission: ${doubled ? 'written (execCommand in the gesture)' : `not written (${writeRefusal ?? d.last('box')})`}`);
    assert.ok(doubled, 'a click copies without the clipboard-write permission');
    ok('copy outside an event without permission');
    const before = d.lines.length;
    await p2.mouse.click(...d.g.paste);
    await d.until(l => l === 'pending:1', 'the Paste button to start a read');
    await d.until((l, i) => l === 'pending:0' && d.lines.lastIndexOf('pending:1') < d.lines.lastIndexOf('pending:0'), 'the refused read to settle', 8000);
    let refusal = null;
    try { refusal = await d.until((l, i) => i >= before && l.includes('clipboard read refused'), 'the refusal', 2000); } catch { refusal = null; }
    results.push(`readText without permission: ${refusal ? `refused (${refusal.replace(/^.*refused: /, '')})` : 'allowed'}`);
    assert.equal(d.last('box'), 'alpha beta gammanative textalpha beta gammanative text', 'a refused read inserts nothing');
    ok('refused navigator.clipboard read settles as empty');
    await bare.close();
  } finally {
    await browser.close();
  }
  return `${name}: ${results.length} checks\n  - ${results.join('\n  - ')}`;
}

let failed = 0;
let ran = 0;
for (const name of wanted) {
  try {
    const report = await runBrowser(name);
    if (!report.includes('SKIP')) ran++;
    console.log(report);
  } catch (err) {
    failed++;
    console.log(`${name}: FAIL ${err.stack ?? err}`);
  }
}
server.close();
if (failed) process.exit(1);
if (ran === 0) {
  console.log('run_browser_clipboard SKIP (no browser ran)');
  process.exit(require_ ? 1 : 0);
}
console.log(`run_browser_clipboard OK (${ran} browser${ran === 1 ? '' : 's'})`);
