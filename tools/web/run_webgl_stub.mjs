// Headless host runner for W wasm graphics programs: instantiates the
// module with the shared env glue (tools/web/webgl_env.mjs) over a
// recording fake WebGL2 context and a static canvas host, drives the
// registered frame callback the way a browser would (rAF -> table call,
// stop when $ax reads 0), then asserts the GL call trace a working
// program must produce. This is the wasm_webgl_test gate: it proves the
// whole chain — extern imports, string/buffer marshalling through linear
// memory, handle tables, the frame-callback contract — without a GPU.
//
// Usage: node tools/web/run_webgl_stub.mjs bin/graphics_demo.wasm --frames 3
import { readFile } from 'node:fs/promises';
import { WASI } from 'node:wasi';
import { argv, exit } from 'node:process';
import { makeEnv } from './webgl_env.mjs';

const fail = (msg) => { console.error(`run_webgl_stub: FAIL: ${msg}`); exit(1); };
const assertEq = (want, got, what) => {
  if (want !== got) fail(`${what}: want ${want}, got ${got}`);
};

const framesArg = argv.indexOf('--frames');
const maxFrames = framesArg >= 0 ? parseInt(argv[framesArg + 1], 10) : 3;

// ---------------------------- recording fake GL ----------------------------
const calls = {
  shaderSources: [],
  linkCount: 0,
  bufferDataBytes: [],
  drawArrays: [],
  uniformMatrix: 0,
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
  createVertexArray: () => ({}),
  bindVertexArray: () => {},
  enableVertexAttribArray: () => {},
  disableVertexAttribArray: () => {},
  vertexAttribPointer: () => {},
  drawArrays: (mode, first, count) => calls.drawArrays.push([mode, first, count]),
  drawElements: () => {},
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
    calls.uniformMatrix++;
  },
};

// ------------------------------- canvas host --------------------------------
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
    mouseX: 0,
    mouseY: 0,
    mouseButtons: 0,
    lastKeycode: 0,
  }),
  setFrameCallback: (tableIndex) => { frameCallback = tableIndex; },
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

// The rAF loop: call the frame function until it returns 0 (read from
// the exported $ax global), bounded well past the expected frame count.
let frames = 0;
for (; frames < maxFrames + 10; frames++) {
  instance.exports.table.get(frameCallback)();
  if (instance.exports.ax.value === 0) { frames++; break; }
}

assertEq(maxFrames, frames, 'frames until the callback returned 0');
assertEq(2, calls.shaderSources.length, 'shaders compiled');
if (!calls.shaderSources[0].startsWith('#version 300 es'))
  fail(`vertex shader missing the GLSL ES header: ${calls.shaderSources[0].slice(0, 40)}`);
assertEq(1, calls.linkCount, 'programs linked');
assertEq('60', calls.bufferDataBytes.join(','), 'vertex buffer upload bytes');
assertEq(maxFrames, calls.drawArrays.length, 'drawArrays calls');
assertEq('4,0,3', calls.drawArrays[0].join(','), 'drawArrays(mode, first, count)');
assertEq(maxFrames, calls.uniformMatrix, 'uniformMatrix4fv calls');
assertEq(maxFrames, calls.clearCount, 'clear calls');

console.log(`run_webgl_stub OK (${frames} frames, canvas "${canvas.title}" ${canvas.width}x${canvas.height})`);
