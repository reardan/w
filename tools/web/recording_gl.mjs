// Recording WebGL2 context shared by the UI wasm integration runners.
export function createRecordingGl() {
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
    if (data.length % 16 !== 0) (() => { throw new Error(`uniformMatrix4fv: ${data.length} floats`); })();
  },
};

  return { calls, gl: fakeGl };
}
