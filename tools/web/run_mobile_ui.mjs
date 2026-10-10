// Exercise the real W mobile form through its wasm host ABI without a GPU.
// Usage: node tools/web/run_mobile_ui.mjs bin/graphics_ui_mobile.wasm
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { WASI } from 'node:wasi';
import { makeEnv } from './webgl_env.mjs';
import { createRecordingGl } from './recording_gl.mjs';
import { createEventQueue, EVENT, viewportSize } from './mobile_input.mjs';

const { calls, gl } = createRecordingGl();
const events = createEventQueue();
let dimensions, callback, textField;
let mouse = { mouseX: 30, mouseY: 150, mouseButtons: 0 };
const bridges = [];
const host = {
  canvasInit(title, requestedWidth, requestedHeight) {
    dimensions = viewportSize({ width: 390, height: 720, requestedWidth, requestedHeight, dpr: 3 });
    return 1;
  },
  pollState: () => ({ ...dimensions, ...mouse, shouldClose: 0, lastKeycode: 0 }),
  setFrameCallback: index => { callback = index; },
  nextEvent: () => events.next(),
  textInput(...args) { textField = args; bridges.push(args); },
  pointerMode() {},
  pixelRatio: () => dimensions.ratio,
};
let instance;
const wasi = new WASI({ version: 'preview1', args: [process.argv[2]], env: {},
  preopens: { '.': process.cwd() }, returnOnExit: true });
const env = makeEnv({ memory: () => instance.exports.memory, gl, host });
instance = await WebAssembly.instantiate(await WebAssembly.compile(await readFile(process.argv[2])),
  { ...wasi.getImportObject(), env });
assert.equal(wasi.start(instance), 0);
assert.ok(callback, 'W registered the form frame');
let frames = 0;
function frame() {
  events.beginFrame();
  instance.exports.table.get(callback)();
  frames++;
  assert.equal(instance.exports.ax.value, 1);
}
function event(kind, code = 0, x = mouse.mouseX, y = mouse.mouseY) {
  mouse.mouseX = x; mouse.mouseY = y;
  if (kind === EVENT.DOWN) mouse.mouseButtons = 1;
  if (kind === EVENT.UP || kind === EVENT.CANCEL) mouse.mouseButtons = 0;
  events.push(kind, code, x, y, 0);
}
function containsText(text) {
  return Buffer.from(instance.exports.memory.buffer).includes(Buffer.from(`${text}\0`));
}
frame();
assert.equal(textField[0], 0, 'no keyboard before a field is focused');
event(EVENT.DOWN, 1); frame();
event(EVENT.UP, 1); frame();
assert.equal(textField[0], 1, 'name field publishes keyboard request');
assert.equal(textField[1], 0, 'name is single-line');
assert.ok(textField[2] <= 30 && textField[2] + textField[4] > 30);
assert.ok(textField[3] <= 150 && textField[3] + textField[5] > 150);
assert.ok(textField[6] > 0, 'stable focused ID crosses wasm ABI');
const nameId = textField[6];
for (const c of 'é🙂Ω') event(EVENT.CHAR, c.codePointAt(0));
frame();
assert.ok(containsText('é🙂Ω'), 'Unicode scalar events reached UTF-8 W textbox');
event(EVENT.CHAR, 8); frame();
assert.ok(containsText('é🙂'), 'backspace removes a complete Unicode scalar');
// Long paste spans frames without truncating W\'s 32-char input buffer.
const paste = 'a'.repeat(70);
for (const c of paste) event(EVENT.CHAR, c.codePointAt(0));
frame(); frame(); frame();
assert.ok(containsText(`é🙂${paste}`), '70-character paste survives host backpressure');
// Focus the email field, then simulate the software keyboard reducing height.
event(EVENT.DOWN, 1, 30, 270); frame();
event(EVENT.UP, 1); frame();
assert.equal(textField[0], 1);
assert.notEqual(textField[6], nameId);
const emailId = textField[6];
dimensions = viewportSize({ width: 320, height: 250, requestedWidth: 390, requestedHeight: 720, dpr: 3 });
frame(); frame();
assert.equal(dimensions.width, 320);
assert.equal(textField[0], 1, 'keyboard resize preserves focus');
assert.equal(textField[6], emailId);
assert.ok(textField[3] >= 0 && textField[3] + textField[5] <= 250, 'focused field revealed above keyboard');
const beforeScrollY = textField[3];
event(EVENT.CANCEL, 0, 30, 100);
event(EVENT.SCROLL_PIXELS, 17); frame(); frame();
assert.equal(textField[6], emailId, 'pan cancellation preserves text focus');
assert.equal(textField[3], beforeScrollY - 17, 'pixel scroll moves form exactly 17 pixels');
event(EVENT.SCROLL_PIXELS, -10000); frame(); frame();
const topY = textField[3];
event(EVENT.SCROLL_PIXELS, -10000); frame(); frame();
assert.equal(textField[3], topY, 'scroll clamps at top');
assert.ok(calls.drawArrays.length >= frames);
assert.ok(calls.texImages.length > 0);
assert.equal(bridges.length, frames, 'bridge reports exactly once per W frame');
console.log(`run_mobile_ui OK (${frames} frames: Unicode, paste, focus, keyboard resize, pan and clamp)`);
