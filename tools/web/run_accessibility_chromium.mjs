// The ARIA mirror (tools/web/accessibility.mjs) in real headless Chromium:
// DOM identity across publications (focus, textarea selection and an IME
// composition driven through the DevTools Input domain survive a republish)
// and live regions as Chromium's accessibility tree exposes them
// (Accessibility.getFullAXTree). Prints a SKIP line without a browser, or
// fails when W_REQUIRE_BROWSER=1. Run by graphics_ui_accessibility_web_test.
import assert from 'node:assert/strict';
import { findChromium, openPage } from './headless_chromium.mjs';

const label = 'web accessibility Chromium';
const chromium = findChromium();
if (!chromium) {
  if (process.env.W_REQUIRE_BROWSER === '1') {
    console.error(`${label} FAIL: W_REQUIRE_BROWSER=1 but no Chromium (set CHROMIUM)`);
    process.exit(1);
  }
  console.log(`${label} SKIP (no Chromium; set CHROMIUM)`);
  process.exit(0);
}

const page = await openPage({ chromium });
try {
  // The page-side harness: one mirror, a publish helper and the action queue.
  await page.evaluate(`(async () => {
    const { createAccessibility } = await import('/tools/web/accessibility.mjs');
    const container = document.createElement('div');
    document.body.appendChild(container);
    const access = createAccessibility({ document, container });
    const publish = (value, status, extra = () => {}) => {
      access.begin(16, 1024, 1);
      access.add(1, 0, 1, 0, 0, 0);
      access.text(1, 1, 'Editor');
      access.add(2, 1, 8, 64, 6, 0); access.text(2, 1, 'Source'); access.text(2, 2, value);
      access.add(3, 1, 6, 64, 3, 0); access.text(3, 1, 'Save');
      access.add(4, 1, 3, 0, 0, 0, 1); access.text(4, 1, status);
      extra();
      return access.commit(2);
    };
    const drain = () => { const out = []; for (let e; (e = access.next(1, 1024));) out.push({ id: e.id, action: e.action, value: new TextDecoder().decode(e.data) }); return out; };
    window.w = { access, publish, drain, container, ta: () => container.querySelector('textarea') };
    return true;
  })()`);
  const run = expression => page.evaluate(`(() => { const { access, publish, drain, container, ta } = window.w; ${expression} })()`);

  assert.equal(await run(`return publish('graph TD', 'Ready.')`), 1);
  assert.equal(await run(`return document.activeElement === ta()`), true, 'snapshot focus reaches the textarea');
  assert.deepEqual(await run(`return drain()`), [], 'programmatic focus does not echo');
  // Selection survives an identical and an unrelated republish.
  await run(`window.w.first = ta(); ta().setSelectionRange(2, 5); return 0`);
  assert.equal(await run(`return publish('graph TD', 'Saved.')`), 1);
  assert.deepEqual(await run(`return [ta() === window.w.first, document.activeElement === ta(), ta().selectionStart, ta().selectionEnd]`),
    [true, true, 2, 5], 'same element, focus and selection after a republish');

  // An IME composition (DevTools Input.imeSetComposition) is not cancelled by
  // a republish, and its commit reaches the queue once.
  await run(`ta().setSelectionRange(8, 8); return 0`);
  await page.send('Input.imeSetComposition', { text: 'に', selectionStart: 1, selectionEnd: 1 });
  assert.equal(await run(`return ta().value`), 'graph TDに');
  assert.equal(await run(`return publish('graph TD', 'Saved.')`), 1);
  assert.equal(await run(`return ta().value`), 'graph TDに', 'composition text kept across a republish');
  assert.deepEqual(await run(`return drain()`), [], 'no value request mid-composition');
  await page.send('Input.insertText', { text: 'に' });
  const committed = await run(`return drain()`);
  assert.deepEqual(committed.filter(e => e.action === 4).at(-1), { id: 2, action: 4, value: 'graph TDに' }, 'committed composition queued');

  // Live regions in Chromium's accessibility tree.
  assert.equal(await run(`return publish('graph TDに', 'Saved.', () => {
    access.add(5, 1, 3, 0, 0, 0, 2); access.text(5, 1, 'Disk full');
    access.announce('Exported', 1);
  })`), 1);
  await page.send('Accessibility.enable');
  const { nodes } = await page.send('Accessibility.getFullAXTree');
  const prop = (n, name) => n.properties?.find(p => p.name === name)?.value?.value;
  const named = text => nodes.find(n => n.name?.value === text && !n.ignored);
  const status = nodes.find(n => !n.ignored && prop(n, 'live') === 'polite' && prop(n, 'atomic') === true &&
    nodes.some(c => n.childIds?.includes(c.nodeId) && c.name?.value === 'Saved.'));
  assert.ok(status, 'the status line is a polite atomic live region');
  const toast = nodes.find(n => !n.ignored && prop(n, 'live') === 'assertive' &&
    nodes.some(c => n.childIds?.includes(c.nodeId) && c.name?.value === 'Disk full'));
  assert.ok(toast, 'the toast is an assertive live region');
  const regions = nodes.filter(n => !n.ignored && ['polite', 'assertive'].includes(prop(n, 'live')) &&
    nodes.some(c => n.childIds?.includes(c.nodeId) && /^(Exported|Disk full) ?$/.test(c.name?.value ?? '')));
  assert.ok(regions.length >= 3, 'hidden announcement regions hold the announcement and the new toast');
  const textbox = named('Source');
  assert.equal(textbox?.role?.value, 'textbox');
  assert.equal(named('Save')?.role?.value, 'button');
  console.log(`${label} probe OK (${page.version})`);
} finally {
  await page.close();
}
