// The "env" import module for W wasm graphics programs: the JS half of
// the extern surface declared by graphics/gl_web.w and
// graphics/window_web.w (design: docs/projects/wasm_webgl.md).
//
// Environment-agnostic: the browser page (index.html) passes a real
// WebGL2 context and a canvas-backed host, the headless test runner
// (run_webgl_stub.mjs) passes a recording fake. Marshalling rules:
//
//   - GL object handles travel as positive i32s through a handle table
//     (WebGL objects are opaque; native GL hands out ints).
//   - Pointers are offsets into the module's exported linear memory.
//     Views are created fresh per call: memory.grow() detaches
//     ArrayBuffers, so cached views would go stale.
//   - glGetString copies its result into the reserved low-page scratch
//     window [3072, 4096) (the W side reserves [0, 4096); the WASI
//     wrappers use [256, 512)) and returns its address.
//
// makeEnv({ memory, gl, host, log }):
//   memory  () => WebAssembly.Memory (late-bound: imports are built
//           before instantiation)
//   gl      a WebGL2 context or a compatible fake
//   host    { canvasInit(title, w, h) -> 0|1,
//             pollState() -> { width, height, shouldClose, mouseX,
//                              mouseY, mouseButtons, lastKeycode },
//             setFrameCallback(tableIndex) }
//   log     optional diagnostic sink (defaults to console.error)

const GL_STR_SCRATCH = 3072;
const GL_STR_SCRATCH_END = 4096;

export function makeEnv({ memory, gl, host, log = console.error }) {
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();

  const bytes = () => new Uint8Array(memory().buffer);
  const view = () => new DataView(memory().buffer);

  const readCStr = (ptr) => {
    if (ptr === 0) return '';
    const b = bytes();
    let end = ptr;
    while (b[end] !== 0) end++;
    return decoder.decode(b.subarray(ptr, end));
  };

  // Write str + NUL at ptr, truncated to max bytes total; returns the
  // number of content bytes written.
  const writeCStr = (ptr, str, max) => {
    const data = encoder.encode(str).subarray(0, Math.max(0, max - 1));
    bytes().set(data, ptr);
    bytes()[ptr + data.length] = 0;
    return data.length;
  };

  // One handle table for buffers/shaders/programs/VAOs (native GL uses
  // separate namespaces, but nothing in the W surface relies on ids
  // colliding across kinds), plus one for uniform locations.
  const objects = [null];
  const allocObject = (obj) => objects.push(obj) - 1;
  const uniforms = [null];

  const shaderLog = (shader) => gl.getShaderInfoLog(objects[shader]) || '';
  const programLog = (program) => gl.getProgramInfoLog(objects[program]) || '';

  const env = {
    // ------------------------------ core GL ------------------------------
    glViewport: (x, y, w, h) => gl.viewport(x, y, w, h),
    glClearColor: (r, g, b, a) => gl.clearColor(r, g, b, a),
    glClear: (mask) => gl.clear(mask),
    glEnable: (cap) => gl.enable(cap),
    glDisable: (cap) => gl.disable(cap),
    glBlendFunc: (src, dst) => gl.blendFunc(src, dst),
    glGetError: () => gl.getError(),
    glFinish: () => gl.finish(),
    glPixelStorei: (pname, param) => gl.pixelStorei(pname, param),

    glGetString: (name) => {
      // 0x1F00 VENDOR / 0x1F01 RENDERER / 0x1F02 VERSION
      let s = '';
      try { s = String(gl.getParameter(name) ?? ''); } catch { s = ''; }
      writeCStr(GL_STR_SCRATCH, s, GL_STR_SCRATCH_END - GL_STR_SCRATCH);
      return GL_STR_SCRATCH;
    },

    glReadPixels: (x, y, w, h, format, type, ptr) => {
      // RGBA + UNSIGNED_BYTE is the only layout the W surface uses.
      if (format !== 0x1908 || type !== 0x1401)
        throw new Error(`glReadPixels: unsupported format/type ${format}/${type}`);
      gl.readPixels(x, y, w, h, format, type, new Uint8Array(memory().buffer, ptr, w * h * 4));
    },

    // ------------------------- buffers and arrays -------------------------
    glGenBuffers: (count, outPtr) => {
      const dv = view();
      for (let i = 0; i < count; i++)
        dv.setInt32(outPtr + 4 * i, allocObject(gl.createBuffer()), true);
    },
    glDeleteBuffers: (count, idsPtr) => {
      const dv = view();
      for (let i = 0; i < count; i++) {
        const id = dv.getInt32(idsPtr + 4 * i, true);
        if (objects[id]) { gl.deleteBuffer(objects[id]); objects[id] = null; }
      }
    },
    glBindBuffer: (target, id) => gl.bindBuffer(target, id ? objects[id] : null),
    glBufferData: (target, size, ptr, usage) => {
      if (ptr === 0) gl.bufferData(target, size, usage);
      else gl.bufferData(target, new Uint8Array(memory().buffer, ptr, size), usage);
    },
    glGenVertexArrays: (count, outPtr) => {
      const dv = view();
      for (let i = 0; i < count; i++)
        dv.setInt32(outPtr + 4 * i, allocObject(gl.createVertexArray()), true);
    },
    glBindVertexArray: (id) => gl.bindVertexArray(id ? objects[id] : null),
    glEnableVertexAttribArray: (index) => gl.enableVertexAttribArray(index),
    glDisableVertexAttribArray: (index) => gl.disableVertexAttribArray(index),
    glVertexAttribPointer: (index, size, type, normalized, stride, offset) =>
      gl.vertexAttribPointer(index, size, type, !!normalized, stride, offset),
    glDrawArrays: (mode, first, count) => gl.drawArrays(mode, first, count),
    glDrawElements: (mode, count, type, offset) => gl.drawElements(mode, count, type, offset),

    // ------------------------ shaders and programs ------------------------
    glCreateShader: (type) => allocObject(gl.createShader(type)),
    glShaderSource: (shader, count, sourcesPtr, lengthsPtr) => {
      const dv = view();
      let source = '';
      for (let i = 0; i < count; i++) {
        const strPtr = dv.getUint32(sourcesPtr + 4 * i, true);
        const len = lengthsPtr ? dv.getInt32(lengthsPtr + 4 * i, true) : -1;
        source += len < 0 ? readCStr(strPtr)
                          : decoder.decode(bytes().subarray(strPtr, strPtr + len));
      }
      gl.shaderSource(objects[shader], source);
    },
    glCompileShader: (shader) => gl.compileShader(objects[shader]),
    glGetShaderiv: (shader, pname, outPtr) => {
      // 0x8B84 INFO_LOG_LENGTH has no WebGL parameter (the log comes
      // back as a string); 0x8B81 COMPILE_STATUS is a boolean.
      let v;
      if (pname === 0x8b84) v = shaderLog(shader).length + 1;
      else {
        const p = gl.getShaderParameter(objects[shader], pname);
        v = p === true ? 1 : p === false ? 0 : p | 0;
      }
      view().setInt32(outPtr, v, true);
    },
    glGetShaderInfoLog: (shader, maxLength, lengthPtr, logPtr) => {
      const n = writeCStr(logPtr, shaderLog(shader), maxLength);
      if (lengthPtr) view().setInt32(lengthPtr, n, true);
    },
    glDeleteShader: (shader) => { if (objects[shader]) { gl.deleteShader(objects[shader]); objects[shader] = null; } },
    glCreateProgram: () => allocObject(gl.createProgram()),
    glAttachShader: (program, shader) => gl.attachShader(objects[program], objects[shader]),
    glLinkProgram: (program) => gl.linkProgram(objects[program]),
    glGetProgramiv: (program, pname, outPtr) => {
      // 0x8B82 LINK_STATUS boolean, 0x8B84 INFO_LOG_LENGTH via string
      let v;
      if (pname === 0x8b84) v = programLog(program).length + 1;
      else {
        const p = gl.getProgramParameter(objects[program], pname);
        v = p === true ? 1 : p === false ? 0 : p | 0;
      }
      view().setInt32(outPtr, v, true);
    },
    glGetProgramInfoLog: (program, maxLength, lengthPtr, logPtr) => {
      const n = writeCStr(logPtr, programLog(program), maxLength);
      if (lengthPtr) view().setInt32(lengthPtr, n, true);
    },
    glUseProgram: (program) => gl.useProgram(program ? objects[program] : null),
    glDeleteProgram: (program) => { if (objects[program]) { gl.deleteProgram(objects[program]); objects[program] = null; } },
    glGetAttribLocation: (program, namePtr) => gl.getAttribLocation(objects[program], readCStr(namePtr)),
    glGetUniformLocation: (program, namePtr) => {
      const loc = gl.getUniformLocation(objects[program], readCStr(namePtr));
      return loc === null ? -1 : uniforms.push(loc) - 1;
    },
    glUniform1i: (loc, v) => gl.uniform1i(uniforms[loc], v),
    glUniform1f: (loc, x) => gl.uniform1f(uniforms[loc], x),
    glUniform2f: (loc, x, y) => gl.uniform2f(uniforms[loc], x, y),
    glUniform3f: (loc, x, y, z) => gl.uniform3f(uniforms[loc], x, y, z),
    glUniform4f: (loc, x, y, z, w) => gl.uniform4f(uniforms[loc], x, y, z, w),
    glUniformMatrix4fv: (loc, count, transpose, ptr) =>
      gl.uniformMatrix4fv(uniforms[loc], !!transpose, new Float32Array(memory().buffer, ptr, 16 * count)),

    // ----------------------- window / canvas host -----------------------
    gfx_host_canvas_init: (titlePtr, width, height) =>
      host.canvasInit(readCStr(titlePtr), width, height),
    gfx_host_poll_state: (ptr) => {
      const s = host.pollState();
      const dv = view();
      dv.setInt32(ptr, s.width, true);
      dv.setInt32(ptr + 4, s.height, true);
      dv.setInt32(ptr + 8, s.shouldClose, true);
      dv.setInt32(ptr + 12, s.mouseX, true);
      dv.setInt32(ptr + 16, s.mouseY, true);
      dv.setInt32(ptr + 20, s.mouseButtons, true);
      dv.setInt32(ptr + 24, s.lastKeycode, true);
    },
    gfx_host_set_frame_callback: (tableIndex) => host.setFrameCallback(tableIndex),
  };

  return env;
}
