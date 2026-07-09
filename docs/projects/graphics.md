# graphics/ — math, OpenGL and windowing for W

Status: stage 1 landed (math + GL/X11 bindings + smoke test).

## Goal

A graphics module for W programs, built in stages:

1. **Math** (done): a GLM-inspired vector/matrix/quaternion library.
2. **OpenGL + window integration** (done): X11/GLX window management and
   OpenGL bindings with string shaders.
3. **2D + UI features** (planned): sprites, text, immediate-mode UI.
4. **3D features** (planned): meshes, cameras, lighting helpers.

## Modules

### graphics.math

Pure W, no libm, so it links statically and runs on both x86 and x64.
API follows GLM's naming where it maps cleanly onto W (no operator
overloading, so `vec3_add(a, b)` instead of `a + b`):

- `vec2` / `vec3` / `vec4`: `float32` fields; `_new`, `_add`, `_sub`,
  `_scale`, `_mul` (component-wise), `_dot`, `_length`, `_normalize`,
  `_lerp`, plus `vec3_cross` and `vec3_reflect`.
- `mat4`: column-major `float32[16]` like GLM/OpenGL; `mat4_identity`,
  `mat4_mul`, `mat4_mul_vec4`, `mat4_mul_point`, `mat4_translate`,
  `mat4_scale`, `mat4_rotation` / `mat4_rotate` (axis + angle),
  `mat4_perspective`, `mat4_ortho`, `mat4_look_at`, `mat4_transpose`.
  Column-major means `glUniformMatrix4fv(loc, 1, 0, &m.m[0])` works
  without transposing.
- `quat`: `quat_from_axis_angle`, `quat_mul`, `quat_normalize`,
  `quat_rotate_vec3`, `quat_to_mat4`.
- Scalar helpers: `radians` / `degrees`, `gfx_sqrt`, `gfx_sin`,
  `gfx_cos`, `gfx_tan`, `gfx_lerp`, `gfx_clamp`, `gfx_floor`,
  `gfx_mod`. The transcendentals are polynomial approximations with
  range reduction — accurate to well under 1e-4, plenty for rendering
  math, and they keep the module free of libc/libm.

Tests: `graphics/math_test.w`, run as `graphics_math_test` (x86) and
`graphics_math_64_test` (x64).

### graphics.x11 / graphics.gl

FFI bindings through `c_lib` + `extern` (link-time dynamic linking, see
`grammar/extern_statement.w`):

- `graphics.x11` binds libX11.so.6: display/window/colormap management,
  atoms, and event handling. Struct layouts (`x_visual_info`,
  `x_set_window_attributes`, the `x_event` union) match the x86_64 ABI,
  so the windowing stack is **x64-only**; compile consumers with
  `wv2 x64`.
- `graphics.gl` binds libGL.so.1 (which also exports GLX): context
  creation, core GL state, buffers/vertex attributes, shader/program
  objects and uniforms. Shaders are compiled from GLSL source strings
  at runtime via `gl_compile_shader` / `gl_link_program` /
  `gl_create_program` (no shader file loader yet — string shaders by
  design for now).

### graphics.window

The high-level entry point:

	gfx_window* win = gfx_window_open(c"demo", 640, 480)
	while (gfx_window_poll(win)):
		# glClear / draw ...
		gfx_window_swap(win)
	gfx_window_destroy(win)

`gfx_window_open` picks a double-buffered RGBA GLX visual, creates the
window, registers WM_DELETE_WINDOW and makes a GL context current.
`gfx_window_poll` drains the X event queue and tracks close/resize,
last keycode, pointer position and button mask.

## Testing

`graphics_gl_smoke_test` (part of `tests_x64`) renders one
interpolated-color triangle through a `mat4` uniform from
graphics.math, reads pixels back with `glReadPixels` and checks both
the triangle center and the clear-color corner. When no X display is
reachable it prints "graphics gl smoke SKIP" and passes, like
`cuda_smoke` does for missing GPUs, so headless hosts stay green — a
real failure (bad pixels, shader errors) still fails the target.

## Compiler/runtime fixes the module surfaced

Building this module exposed several latent bugs, fixed alongside:

- `from_hex` ignored uppercase hex digits, so `0x1F01` silently parsed
  as `0x101` (GL enum constants were the first heavy user).
- Struct-by-value argument passing miscompiled single-word structs on
  x64, nested struct-returning calls leaked stack words into the
  parameter block, and struct reassignment from a call read a stale
  address (`grammar/postfix_expr.w`, `grammar/expression.w`).
- Local/argument stack slots were read as a signed byte in
  `compiler/symbol_table.w`, corrupting frames with slot offsets >= 128
  (big structs like `mat4` hit this immediately).
- Dynamically linked W programs shared the program break with glibc:
  glibc's sbrk caches the break and never rechecks it, so W's raw-brk
  malloc handed out memory glibc also handed out (crash inside
  glXSwapBuffers). The ELF writer now flips `malloc_mmap_mode` in the
  image whenever `c_lib`/`extern` is used, keeping W's allocator on
  mmap chunks, and `lib/memory.w` re-checks the live break before
  growing it.

## Next steps

- 2D layer: orthographic sprite batching, textures
  (`glGenTextures`/`glTexImage2D` bindings), text rendering.
- UI layer: immediate-mode widgets on top of the 2D layer and the
  existing input state on `gfx_window`.
- 3D layer: depth/culling state helpers, mesh + camera structs,
  `mat4_perspective`/`mat4_look_at` are already in place.
- Keyboard state beyond `last_keycode` (keymap, text input).
- GLX 1.3+ (`glXCreateContextAttribsARB`) for core-profile contexts.
