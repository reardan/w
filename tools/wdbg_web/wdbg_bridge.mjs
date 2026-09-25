// The "wdbg" import module for tools/wdbg_ui.w: HTTP requests to the
// wdbg_web server as polled handles, since wasm cannot block on fetch.
// Shared by the browser page (index.html) and the headless test
// (run_ui_test.mjs).
//
// makeWdbgBridge({ memory, base, code, fetch }) returns the imports:
//   wdbg_http_start(method, path, body) -> handle (never 0)
//   wdbg_http_status(h)  0 while pending, HTTP status when done, -1 on error
//   wdbg_http_length(h)  body length in bytes
//   wdbg_http_read(h, dst, max) -> bytes copied
//   wdbg_http_free(h)
export function makeWdbgBridge({ memory, base = '', code = '', fetch = globalThis.fetch }) {
  const handles = new Map();
  let next = 1;
  const readCStr = (ptr) => {
    const bytes = new Uint8Array(memory().buffer);
    let end = ptr;
    while (bytes[end] !== 0) end++;
    return new TextDecoder().decode(bytes.subarray(ptr, end));
  };
  return {
    wdbg_http_start: (methodPtr, pathPtr, bodyPtr) => {
      const id = next++;
      const h = { status: 0, bytes: null };
      handles.set(id, h);
      const method = readCStr(methodPtr);
      const init = { method, headers: {}, credentials: 'same-origin' };
      if (code) init.headers['X-Wdbg-Code'] = code;
      if (method !== 'GET' && bodyPtr) init.body = readCStr(bodyPtr);
      fetch(base + readCStr(pathPtr), init)
        .then(async (res) => {
          h.bytes = new Uint8Array(await res.arrayBuffer());
          h.status = res.status || -1;
        })
        .catch(() => { h.bytes = new Uint8Array(0); h.status = -1; });
      return id;
    },
    wdbg_http_status: (id) => handles.get(id)?.status ?? -1,
    wdbg_http_length: (id) => handles.get(id)?.bytes?.length ?? 0,
    wdbg_http_read: (id, dst, max) => {
      const bytes = handles.get(id)?.bytes;
      if (!bytes) return 0;
      const n = Math.min(max, bytes.length);
      new Uint8Array(memory().buffer, dst, n).set(bytes.subarray(0, n));
      return n;
    },
    wdbg_http_free: (id) => { handles.delete(id); },
  };
}
