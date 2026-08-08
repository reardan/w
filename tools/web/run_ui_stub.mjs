// Headless host runner for the wasm UI demo: the run_webgl_stub.mjs
// skeleton (shared env glue over a recording fake WebGL2 context, the
// rAF-style table-callback loop) extended with textures and a scripted
// input queue — before frame 2 it delivers a MOUSE_DOWN and before
// frame 3 a MOUSE_UP at the demo button's documented click point
// (graphics/ui/demo_shared.w), so the module itself prints
// "ui demo clicks: 1" (asserted by wasm_ui_test's expect_stdout, not
// here). This is the wasm_ui_test gate: it proves the widget chain —
// atlas upload, per-frame batched draws, the event-queue import —
// without a GPU or browser.
//
// Usage: node tools/web/run_ui_stub.mjs bin/graphics_ui_demo.wasm --frames 4
import { readFile } from 'node:fs/promises';
import { WASI } from 'node:wasi';
import { argv, exit } from 'node:process';
import { makeEnv } from './webgl_env.mjs';

const fail = (msg) => { console.error(`run_ui_stub: FAIL: ${msg}`); exit(1); };
const assertEq = (want, got, what) => {
  if (want !== got) fail(`${what}: want ${want}, got ${got}`);
};

const framesArg = argv.indexOf('--frames');
const maxFrames = framesArg >= 0 ? parseInt(argv[framesArg + 1], 10) : 4;

// ---------------------------- recording fake GL ----------------------------
const calls = {
  shaderSources: [],
  linkCount: 0,
  texImages: [],
  texParameters: 0,
  bufferDataBytes: [],
  drawArrays: [],
  clearCount: 0,
};
let attribCounter = 0;
const fakeGl = {
  viewport: () => {},
  clearColor: () => {},
  clear: () => calls.clearCount++,
  enable: () => {},
  disable: () => {},
  blendFunc: () => {},
  getError: () => 0,
  finish: () => {},
  pixelStorei: () => {},
  getParameter: (name) => `fake-webgl(${name})`,
  readPixels: (x, y, w, h, format, type, out) => out.fill(7),
  createBuffer: () => ({}),
  deleteBuffer: () => {},
  bindBuffer: () => {},
  bufferData: (target, data, usage) =>
    calls.bufferDataBytes.push(typeof data === 'number' ? data : data.byteLength),
  bufferSubData: () => {},
  createVertexArray: () => ({}),
  bindVertexArray: () => {},
  enableVertexAttribArray: () => {},
  disableVertexAttribArray: () => {},
  vertexAttribPointer: () => {},
  drawArrays: (mode, first, count) => calls.drawArrays.push([mode, first, count]),
  drawElements: () => {},
  scissor: () => {},
  createTexture: () => ({}),
  deleteTexture: () => {},
  bindTexture: () => {},
  activeTexture: () => {},
  texParameteri: () => calls.texParameters++,
  texImage2D: (target, level, internalFormat, w, h, border, format, type, data) =>
    calls.texImages.push([internalFormat, w, h, data ? data.byteLength : 0]),
  texSubImage2D: () => {},
  createShader: (type) => ({ type }),
  shaderSource: (shader, source) => calls.shaderSources.push(source),
  compileShader: () => {},
  getShaderParameter: (shader, pname) => (pname === 0x8b81 ? true : 0),
  getShaderInfoLog: () => '',
  deleteShader: () => {},
  createProgram: () => ({}),
  attachShader: () => {},
  linkProgram: () => calls.linkCount++,
  getProgramParameter: (program, pname) => (pname === 0x8b82 ? true : 0),
  getProgramInfoLog: () => '',
  useProgram: () => {},
  deleteProgram: () => {},
  getAttribLocation: () => attribCounter++,
  getUniformLocation: () => ({}),
  uniform1i: () => {},
  uniform1f: () => {},
  uniform2f: () => {},
  uniform3f: () => {},
  uniform4f: () => {},
  uniformMatrix4fv: (loc, transpose, data) => {
    if (data.length % 16 !== 0) fail(`uniformMatrix4fv: ${data.length} floats`);
  },
};

// ------------------------------- canvas host --------------------------------
// The click script: queues delivered before each frame, indexed by the
// frame number about to run (frame 0 = the first callback invocation).
// (20, 60) is inside the "Click me" button per demo_shared.w's layout.
const CLICK_X = 20;
const CLICK_Y = 60;
const script = {
  1: [{ kind: 4, code: 1, x: CLICK_X, y: CLICK_Y }],
  2: [{ kind: 5, code: 1, x: CLICK_X, y: CLICK_Y }],
};
let pending = [];

let canvas = null;
let frameCallback = 0;
const host = {
  canvasInit: (title, width, height) => {
    canvas = { title, width, height };
    return 1;
  },
  pollState: () => ({
    width: canvas.width,
    height: canvas.height,
    shouldClose: 0,
    mouseX: CLICK_X,
    mouseY: CLICK_Y,
    mouseButtons: 0,
    lastKeycode: 0,
  }),
  setFrameCallback: (tableIndex) => { frameCallback = tableIndex; },
  nextEvent: () => pending.shift() ?? null,
};

// -------------------------------- run ---------------------------------------
const wasi = new WASI({
  version: 'preview1',
  args: [argv[2], '--frames', String(maxFrames)],
  env: {},
  preopens: { '.': process.cwd() },
  returnOnExit: true,
});

let instance = null;
const env = makeEnv({ memory: () => instance.exports.memory, gl: fakeGl, host });
const wasm = await WebAssembly.compile(await readFile(argv[2]));
instance = await WebAssembly.instantiate(wasm, { ...wasi.getImportObject(), env });

const code = wasi.start(instance);
assertEq(0, code, 'module exit code');
if (!canvas) fail('module never called gfx_host_canvas_init');
if (frameCallback === 0) fail('module never registered a frame callback');

// The rAF loop with the click script feeding the event queue.
let frames = 0;
for (; frames < maxFrames + 10; frames++) {
  pending = pending.concat(script[frames] ?? []);
  instance.exports.table.get(frameCallback)();
  if (instance.exports.ax.value === 0) { frames++; break; }
}

assertEq(maxFrames, frames, 'frames until the callback returned 0');
assertEq(2, calls.shaderSources.length, 'shaders compiled');
if (!calls.shaderSources[0].startsWith('#version 300 es'))
  fail(`vertex shader missing the GLSL ES header: ${calls.shaderSources[0].slice(0, 40)}`);
assertEq(1, calls.linkCount, 'programs linked');
assertEq(1, calls.texImages.length, 'glyph-atlas uploads');
// GL_R8 = 0x8229; a single-channel atlas whose byte length matches its
// dimensions (the exact height is font-bake-derived — see
// tools/generate_ui_atlas.w — so only the shape is pinned).
const [atlasFormat, atlasW, atlasH, atlasBytes] = calls.texImages[0];
assertEq(33321, atlasFormat, 'atlas internalformat');
if (atlasW < 128 || atlasH < 64 || atlasBytes !== atlasW * atlasH)
  fail(`implausible atlas upload: ${atlasW}x${atlasH}, ${atlasBytes} bytes`);
if (calls.texParameters < 4) fail(`expected 4 texture parameters, got ${calls.texParameters}`);
assertEq(maxFrames, calls.drawArrays.length, 'drawArrays calls (one batch per frame)');
for (const [mode, first, count] of calls.drawArrays) {
  if (mode !== 4 || first !== 0) fail(`unexpected drawArrays args: ${mode},${first},${count}`);
  if (count <= 0 || count % 3 !== 0) fail(`vertex count not triangles: ${count}`);
}
assertEq(maxFrames, calls.clearCount, 'background clears');
if (calls.bufferDataBytes.length !== maxFrames)
  fail(`expected one vertex upload per frame, got ${calls.bufferDataBytes.length}`);

console.log(`run_ui_stub OK (${frames} frames, canvas "${canvas.title}" ${canvas.width}x${canvas.height})`);
