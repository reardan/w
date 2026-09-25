/*
graphics.gl_web: the WebGL binding for the wasm target — the same core-GL
extern surface as graphics/gl_linux.w (minus GLX), imported from the
"env" module and implemented by the JS host glue (tools/web/webgl_env.mjs)
over a WebGL2 canvas context.

Selected by graphics/__arch__/wasm/gl_native.w; graphics.gl re-exports it
together with the enums and shader helpers, so consumers keep importing
graphics.gl only.

Handles (GLuint) travel as word-sized W ints: WebGL object handles are
JS objects, so the glue keeps a handle table mapping these ints to the
underlying WebGLBuffer/WebGLShader/... instances. Pointers are linear
memory offsets the glue resolves against the module's exported memory;
glGetString copies its result into the reserved low-page scratch region
(see tools/web/webgl_env.mjs) and returns its address.

Design notes: docs/projects/wasm_webgl.md
*/
import lib.lib


c_lib "env"

# The core-GL externs, bound to the "env" import module above.
import graphics.gl_core
