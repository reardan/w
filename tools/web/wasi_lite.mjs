// Minimal browser-side WASI preview1 shim — just enough of the fixed
// import set W wasm modules declare (code_generator/wasm_module.w) to
// run a graphics program in a page: stdout/stderr to the console (and
// an optional sink), a real clock, no filesystem, no args.
//
// makeWasi({ onWrite }) returns { imports, exitCode() }: pass imports
// as the "wasi_snapshot_preview1" module, call _start inside
// runStart(instance) which absorbs the proc_exit unwind.

const ERRNO_BADF = 8;
const ERRNO_NOENT = 44;

class WasiExit extends Error {
  constructor(code) { super(`proc_exit(${code})`); this.code = code; }
}

export function makeWasi({ memory, onWrite = null } = {}) {
  const decoder = new TextDecoder();
  let exitCode = null;
  const lineBuf = ['', '', '']; // per fd 0..2, line-buffered console output

  const emit = (fd, text) => {
    if (onWrite) { onWrite(fd, text); return; }
    const slot = fd === 2 ? 2 : 1;
    lineBuf[slot] += text;
    let nl;
    while ((nl = lineBuf[slot].indexOf('\n')) >= 0) {
      (fd === 2 ? console.error : console.log)(lineBuf[slot].slice(0, nl));
      lineBuf[slot] = lineBuf[slot].slice(nl + 1);
    }
  };

  const imports = {
    proc_exit: (code) => { exitCode = code; throw new WasiExit(code); },
    fd_write: (fd, iovsPtr, iovsLen, nwrittenPtr) => {
      const dv = new DataView(memory().buffer);
      const b = new Uint8Array(memory().buffer);
      let written = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = dv.getUint32(iovsPtr + 8 * i, true);
        const len = dv.getUint32(iovsPtr + 8 * i + 4, true);
        emit(fd, decoder.decode(b.subarray(ptr, ptr + len)));
        written += len;
      }
      dv.setUint32(nwrittenPtr, written, true);
      return 0;
    },
    fd_read: () => ERRNO_BADF,
    fd_close: () => ERRNO_BADF,
    fd_seek: () => ERRNO_BADF,
    path_open: () => ERRNO_NOENT,
    path_unlink_file: () => ERRNO_NOENT,
    args_sizes_get: (argcPtr, buflenPtr) => {
      const dv = new DataView(memory().buffer);
      dv.setUint32(argcPtr, 0, true);
      dv.setUint32(buflenPtr, 0, true);
      return 0;
    },
    args_get: () => 0,
    clock_time_get: (clock, precision, outPtr) => {
      new DataView(memory().buffer)
        .setBigUint64(outPtr, BigInt(Math.round(Date.now())) * 1000000n, true);
      return 0;
    },
  };

  // Run the module's _start, absorbing the proc_exit unwind; returns the
  // exit code (0 when main returned without an explicit exit).
  const runStart = (instance) => {
    try {
      instance.exports._start();
      return exitCode ?? 0;
    } catch (e) {
      if (e instanceof WasiExit) return e.code;
      throw e;
    }
  };

  return { imports, runStart, exitCode: () => exitCode };
}
