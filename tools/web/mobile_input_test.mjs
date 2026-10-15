import assert from 'node:assert/strict';
import { createInput, viewportSize, createEventQueue, EVENT } from './mobile_input.mjs';
import { makeEnv } from './webgl_env.mjs';

class Target {
  listeners = new Map();
  style = {};
  value = '';
  attrs = {};
  clientHeight = 400;
  addEventListener(name, fn) {
    const handlers = this.listeners.get(name) ?? [];
    handlers.push(fn); this.listeners.set(name, handlers);
  }
  fire(name, options = {}) {
    const event = { target: this, pointerId: 1, isPrimary: true, button: 0,
      pointerType: 'touch', clientX: 30, clientY: 60,
      preventDefault() { this.prevented = true; }, ...options };
    for (const handler of this.listeners.get(name) ?? []) handler(event);
    return event;
  }
  getBoundingClientRect() { return { left: 10, top: 20, width: 300, height: 400 }; }
  setPointerCapture(id) { this.capture = id; }
  releasePointerCapture(id) { this.capture = null; }
  setSelectionRange(a, b) { this.selection = [a, b]; }
  setAttribute(key, value) { this.attrs[key] = value; }
  focus() { this.doc.activeElement = this; }
  blur() { this.doc.activeElement = null; }
}
function setup() {
  const canvas = new Target(), editor = new Target(), doc = new Target(), win = new Target();
  canvas.doc = editor.doc = doc;
  const state = { mouseX: 0, mouseY: 0, mouseButtons: 0, lastKeycode: 0 };
  const events = [];
  let onFrame = () => {};
  const input = createInput({ canvas, editor, state, document: doc, window: win,
    pushEvent: (kind, code, x, y, mods) => events.push({ kind, code, x, y, mods }),
    flushFrame: () => onFrame() });
  return { canvas, editor, doc, win, state, events, input,
    frame(fn) { onFrame = fn; }, chars() { return events.filter(e => e.kind === EVENT.CHAR).map(e => e.code); } };
}

// Canvas placement (including safe-area/CSS offsets) never changes W coordinates.
{
  const h = setup();
  h.canvas.fire('pointerdown');
  assert.deepEqual(h.events[0], { kind: EVENT.DOWN, code: 1, x: 20, y: 40, mods: 0 });
  assert.notEqual(h.doc.activeElement, h.editor, 'ordinary taps do not open keyboard');
  h.canvas.fire('pointerup', { clientX: 600 });
  assert.equal(h.state.mouseButtons, 0);
  assert.equal(h.events.at(-1).kind, EVENT.UP, 'capture releases outside canvas');
}
// Focus is resolved synchronously inside the trusted gesture frame.
{
  const h = setup();
  h.frame(() => h.input.setTextInput(1, 1, 15, 30, 200, 40));
  h.canvas.fire('pointerdown', { pointerType: 'mouse' });
  assert.equal(h.doc.activeElement, h.editor);
  assert.equal(h.editor.style.top, '50px');
  h.input.setTextInput(0, 0, 0, 0, 0, 0);
  assert.equal(h.doc.activeElement, h.canvas);
}
// Touch panning cancels the click; no synthetic up can activate a button.
{
  const h = setup();
  h.canvas.fire('pointerdown');
  h.canvas.fire('pointermove', { clientY: 40 });
  h.canvas.fire('pointerup', { clientY: 40 });
  assert.deepEqual(h.events.map(e => e.kind), [EVENT.DOWN, EVENT.CANCEL, EVENT.SCROLL_PIXELS]);
  assert.equal(h.events.at(-1).code, 20);
  assert.equal(h.state.mouseButtons, 0);
}
// Explicit W widget drag keeps touch capture; secondary fingers cannot release it.
{
  const h = setup();
  h.frame(() => h.input.setPointerMode(1));
  h.canvas.fire('pointerdown');
  h.canvas.fire('pointerdown', { pointerId: 2, isPrimary: false });
  h.canvas.fire('pointerup', { pointerId: 2 });
  assert.equal(h.state.mouseButtons, 1);
  h.canvas.fire('pointermove', { clientY: 10 });
  h.canvas.fire('pointerup');
  assert.deepEqual(h.events.map(e => e.kind), [EVENT.DOWN, EVENT.UP]);
}
for (const reason of ['pointercancel', 'lostpointercapture', 'blur', 'visibilitychange']) {
  const h = setup();
  h.canvas.fire('pointerdown');
  if (reason === 'blur') h.win.fire(reason);
  else if (reason === 'visibilitychange') { h.doc.hidden = true; h.doc.fire(reason); }
  else h.canvas.fire(reason);
  assert.equal(h.state.mouseButtons, 0, reason);
  assert.equal(h.events.at(-1).kind, EVENT.CANCEL, reason);
}
// Mouse drag works without the touch pan threshold, including outside movement.
{
  const h = setup();
  h.canvas.fire('pointerdown', { pointerType: 'mouse' });
  h.canvas.fire('pointermove', { pointerType: 'mouse', clientY: 900 });
  assert.equal(h.state.mouseButtons, 1);
  assert.equal(h.state.mouseY, 880);
  h.canvas.fire('pointerup', { pointerType: 'mouse' });
  assert.deepEqual(h.events.map(e => e.kind), [EVENT.DOWN, EVENT.UP]);
}
{
  const h = setup();
  h.canvas.fire('wheel', { deltaMode: 0, deltaY: 0.5 });
  h.canvas.fire('wheel', { deltaMode: 0, deltaY: 0.5 });
  h.canvas.fire('wheel', { deltaMode: 1, deltaY: -2 });
  h.canvas.fire('wheel', { deltaMode: 2, deltaY: 1 });
  assert.deepEqual(h.events.map(e => e.code), [1, -32, 400]);
}
// Unicode, surrogate pairs, paste and preedit commit once; no partial preedit.
{
  const h = setup();
  h.editor.value += 'é🙂';
  h.editor.fire('input', { inputType: 'insertText', data: 'é🙂' });
  h.editor.fire('compositionstart');
  h.editor.value += 'に';
  h.editor.fire('input', { isComposing: true });
  h.editor.value += '日本';
  h.editor.fire('compositionend', { data: '日本' });
  h.editor.fire('input', { inputType: 'insertCompositionText', data: '日本' });
  assert.deepEqual(h.chars(), [233, 0x1f642, 0x65e5, 0x672c]);
  await Promise.resolve();
  h.editor.value += 'paste\ntext';
  h.editor.fire('input', { inputType: 'insertFromPaste' });
  assert.deepEqual(h.chars().slice(4), [...'paste\rtext'].map(c => c.codePointAt(0)));
  h.editor.fire('beforeinput', { inputType: 'deleteContentBackward' });
  h.editor.fire('beforeinput', { inputType: 'insertLineBreak' });
  assert.deepEqual(h.chars().slice(-2), [8, 13]);
}
{
  const h = setup();
  const shortcut = h.canvas.fire('keydown', { key: 'r', keyCode: 82, metaKey: true });
  assert.equal(shortcut.prevented, undefined);
  assert.deepEqual(h.chars(), [114]);
  assert.equal(h.events.at(-1).mods, 8);
  h.events.length = 0;
  const arrow = h.editor.fire('keydown', { key: 'ArrowLeft', keyCode: 37 });
  assert.equal(arrow.prevented, true);
  assert.equal(h.events.at(-1).kind, EVENT.NAV);
  h.canvas.fire('keydown', { key: '🙂', keyCode: 0 });
  assert.deepEqual(h.chars(), [0x1f642]);
}
{
  const queue = createEventQueue();
  for (let i = 0; i < 80; i++) queue.push(EVENT.CHAR, i, 0, 0, 0);
  let count = 0;
  while (queue.next()) count++;
  assert.equal(count, 32);
  queue.beginFrame();
  while (queue.next()) count++;
  assert.equal(count, 64);
  queue.beginFrame();
  while (queue.next()) count++;
  assert.equal(count, 80);
}
assert.deepEqual(viewportSize({ width: 390, height: 300, requestedWidth: 640,
  requestedHeight: 480, insetLeft: 5, insetRight: 5, insetTop: 20, insetBottom: 10, dpr: 3 }),
{ width: 380, height: 270, bufferWidth: 1140, bufferHeight: 810, ratio: 3 });
// The GL host scales both viewport and clipping, while W sees logical pixels.
{
  const calls = [];
  const memory = new WebAssembly.Memory({ initial: 1 });
  const env = makeEnv({ memory: () => memory,
    gl: { viewport: (...v) => calls.push(v), scissor: (...v) => calls.push(v) },
    host: { pixelRatio: () => 2, textInput: (...v) => calls.push(v), pointerMode: v => calls.push(v) } });
  env.glViewport(0, 0, 390, 300);
  env.glScissor(5, 10, 20, 30);
  env.gfx_host_text_input(1, 0, 5, 10, 20, 30, 42);
  env.gfx_host_pointer_mode(1);
  assert.deepEqual(calls, [[0, 0, 780, 600], [10, 20, 40, 60], [1, 0, 5, 10, 20, 30, 42], 1]);
}
// Composition completion may be followed by its input in a later task.
{
  const h = setup();
  h.editor.fire('compositionstart');
  h.editor.fire('compositionend', { data: '文' });
  await new Promise(resolve => setTimeout(resolve, 0));
  h.editor.value += '文';
  h.editor.fire('input', { inputType: 'insertFromComposition', data: '文' });
  assert.deepEqual(h.chars(), [0x6587]);
  h.editor.fire('beforeinput', { inputType: 'insertText', data: '文' });
  h.editor.value += '文';
  h.editor.fire('input', { inputType: 'insertText', data: '文' });
  assert.deepEqual(h.chars(), [0x6587, 0x6587], 'subsequent identical typing is retained');
}
{
  const h = setup();
  h.input.setTextInput(1, 0, 0, 0, 100, 40, 1);
  h.editor.fire('compositionstart');
  h.editor.value += '旧';
  h.input.setTextInput(1, 0, 0, 60, 100, 40, 2);
  h.editor.fire('compositionend', { data: '旧' });
  h.editor.fire('input', { inputType: 'insertFromComposition', data: '旧' });
  assert.deepEqual(h.chars(), [], 'preedit cannot leak into another focused field');
}
{
  const h = setup();
  const nav = h.canvas.fire('keydown', { key: 'ArrowLeft', keyCode: 37, ctrlKey: true });
  assert.equal(nav.prevented, undefined);
  assert.equal(h.events.at(-1).mods, 2);
  h.editor.fire('keydown', { key: '@', keyCode: 81, ctrlKey: true, altKey: true });
  h.editor.value += '@';
  h.editor.fire('input', { inputType: 'insertText', data: '@' });
  assert.deepEqual(h.chars(), [64], 'AltGr emits printable text once');
}
{
  const q = createEventQueue();
  for (let i = 0; i < 12; i++) q.push(EVENT.NAV, 1, 0, 0, 0);
  let count = 0;
  while (q.next()) count++;
  assert.equal(count, 8);
  q.beginFrame();
  while (q.next()) count++;
  assert.equal(count, 12);
}
{
  const h = setup();
  h.canvas.fire('pointerdown', { pointerType: 'mouse' });
  h.canvas.fire('pointerdown', { pointerType: 'mouse', button: 2 });
  h.canvas.fire('pointerup', { pointerType: 'mouse', button: 2 });
  assert.equal(h.state.mouseButtons, 1, 'auxiliary release cannot end primary drag');
  h.canvas.fire('pointerup', { pointerType: 'mouse' });
  assert.equal(h.state.mouseButtons, 0);
}
{
  const queue = createEventQueue();
  for (let i = 0; i < 10000; i++) queue.push(EVENT.CHAR, i, 0, 0, 0);
  let count = 0;
  while (count < 10000) {
    queue.beginFrame();
    let event;
    while ((event = queue.next())) assert.equal(event.code, count++);
  }
  queue.push(EVENT.UP, 1, 0, 0, 0);
  assert.equal(queue.next(), null, 'later pointer edge waits for committed text');
  queue.beginFrame();
  assert.equal(queue.next().kind, EVENT.UP, 'queue can be reused after long paste');
}
{
  const h = setup();
  h.frame(() => h.input.setTextInput(1, 1, 15, 80, 250, 100, 12));
  h.canvas.fire('pointerdown');
  h.canvas.fire('pointerup');
  h.editor.fire('compositionstart');
  h.editor.value += '文';
  h.input.setTextInput(1, 1, 15, 20, 250, 100, 12);
  assert.equal(h.doc.activeElement, h.editor, 'scroll/keyboard resize retains editor focus');
  assert.equal(h.editor.value, '\u200b文', 'moving same field preserves composition');
  h.editor.fire('compositionend', { data: '文' });
  assert.deepEqual(h.chars(), [0x6587]);
}
{
  const h = setup();
  h.frame(() => h.input.setTextInput(1, 0, 15, 30, 200, 40, 5));
  h.canvas.fire('pointerdown');
  assert.notEqual(h.doc.activeElement, h.editor, 'touch down does not open keyboard');
  h.canvas.fire('pointermove', { clientY: 20 });
  h.canvas.fire('pointerup', { clientY: 20 });
  assert.notEqual(h.doc.activeElement, h.editor, 'swiping a text field never opens keyboard');
  h.canvas.fire('pointerdown');
  assert.notEqual(h.doc.activeElement, h.editor);
  h.canvas.fire('pointerup');
  assert.equal(h.doc.activeElement, h.editor, 'tap focuses editor within trusted release');
}
// Composition previews replace snapshots and remain distinct from commits.
{
  const h = setup();
  h.input.setTextInput(1, 0, 0, 0, 100, 20, 7);
  h.editor.fire('compositionstart');
  h.editor.fire('compositionupdate', { data: '日😀' });
  assert.deepEqual(h.chars(), []);
  const preview = h.events.filter(e => e.kind >= EVENT.PREEDIT_BEGIN);
  assert.deepEqual(preview.map(e => [e.kind, e.code, e.x]), [
    [EVENT.PREEDIT_BEGIN, 0, 7], [EVENT.PREEDIT_BEGIN, 0, 7],
    [EVENT.PREEDIT_TEXT, 0x65e5, 7], [EVENT.PREEDIT_TEXT, 0x1f600, 7],
  ]);
  h.editor.fire('compositionend', { data: '日' });
  assert.deepEqual(h.chars(), [0x65e5]);
  assert.equal(h.events.at(-2).kind, EVENT.PREEDIT_END);
}
// A blur clears preview before changing the owner and rejects a late commit.
{
  const h = setup();
  h.input.setTextInput(1, 0, 0, 0, 100, 20, 7);
  h.editor.fire('compositionstart');
  h.editor.fire('compositionupdate', { data: '旧' });
  h.input.setTextInput(1, 0, 0, 0, 100, 20, 8);
  assert.deepEqual(h.events.at(-1), { kind: EVENT.PREEDIT_END, code: 0, x: 7, y: 0, mods: 0 });
  h.editor.fire('compositionend', { data: '旧' });
  assert.deepEqual(h.chars(), []);
}
// Navigation must run in the old field/caret before later text or clicks.
for (const kind of [EVENT.CHAR, EVENT.DOWN, EVENT.UP]) {
  const queue = createEventQueue();
  queue.push(EVENT.NAV, 1, 0, 0, 0);
  queue.push(kind, 88, 5, 6, 0);
  assert.equal(queue.next().kind, EVENT.NAV);
  assert.equal(queue.next(), null, 'later input waits for navigation');
  queue.beginFrame();
  assert.equal(queue.next().kind, kind);
  assert.equal(queue.next(), null);
}
// Model the widget's CHAR-before-NAV frame processing to catch reordering.
{
  const queue = createEventQueue();
  queue.push(EVENT.NAV, 1, 0, 0, 0);
  queue.push(EVENT.CHAR, 88, 0, 0, 0);
  let text = 'ab', caret = 2;
  for (let frame = 0; frame < 2; frame++) {
    queue.beginFrame();
    const events = [];
    let event;
    while ((event = queue.next())) events.push(event);
    for (const e of events.filter(e => e.kind === EVENT.CHAR)) {
      text = text.slice(0, caret) + String.fromCodePoint(e.code) + text.slice(caret);
      caret++;
    }
    for (const e of events.filter(e => e.kind === EVENT.NAV)) caret--;
  }
  assert.equal(text, 'aXb');
  assert.equal(caret, 2);
}
console.log('mobile_input_test OK (30 scenarios)');
