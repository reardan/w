# graphics.effects — GPU photo effects with a CPU reference

Shader effects for photo apps: brightness/contrast/saturation, levels
and gamma, 3x3 convolutions (sharpen, edge detect, emboss), a separable
Gaussian blur, a vignette and 3D-LUT color grading, run as a chain of
fragment-shader passes over ping-pong framebuffer objects at the
image's own resolution, and read back to RGBA bytes. Every effect also
has a CPU implementation that is the test oracle and the fallback when
there is no GL.

**Status: implemented** on every GL backend (GLX, the Mac's core
profile, WGL, WebGL2). Real runs: Linux x64 under Xvfb/Mesa llvmpipe
and wasm in headless Chromium's WebGL2; arm64_darwin and win64 compile
in CI but have not been run on hardware yet.

## Modules

| Module | Role |
| --- | --- |
| `graphics/effects_core.w` | What an effect *is*: `fx_effect` (kind + 12 float params + an optional LUT strip), constructors, the Gaussian weights, the vignette falloff, LUT presets. No GL, no window. |
| `graphics/effects_cpu.w` | CPU reference: `fx_cpu_apply`, `fx_cpu_run`, `fx_cpu_run_image`. No GL, builds for every target (x86 included). |
| `graphics/effects.w` | GPU runner: the fullscreen-quad pass helper (`fx_pass_program`, `fx_draw_pass`), the per-kind shaders, `fx_gl_run` over ping-pong FBOs, `fx_gl_read`, `fx_gl_run_image`. Needs a current GL context. |
| `examples/photo/photo_lib.w` | The samples' shared code: PNG/JPEG/`pattern:WxH` loading, PNG writing, CLI flags → `photo_settings` → effect chain. |
| `examples/photo/photo_fx.w` | Headless CLI. |
| `examples/photo/photo_viewer.w` | Interactive viewer with graphics.ui sliders. |

The FBO bindings underneath are described in
[graphics.md](graphics.md#framebuffer-objects-render-to-texture).

## Design

**One effect description, two engines.** An effect list is plain data
(`list[fx_effect*]`), so the same chain runs on the GPU or the CPU:

	list[fx_effect*] chain = new list[fx_effect*]
	chain.push(fx_bcs(0.1, 1.2, 1.1))        # brightness, contrast, saturation
	chain.push(fx_blur_pass(3, 0))           # horizontal
	chain.push(fx_blur_pass(3, 1))           # vertical
	chain.push(fx_vignette(0.5, 0.35, 0.65))

	fx_gl g
	fx_gl_init(&g)                           # after gfx_window_open
	rgba_image* out = fx_gl_run_image(&g, chain, image)
	if (out == 0): out = fx_cpu_run_image(chain, image)

**Image resolution, not window resolution.** `fx_gl_run` allocates two
RGBA8 textures + framebuffers at the image size (reused while the size
holds), sets the viewport to it and alternates: pass *i* samples the
previous texture (the uploaded source for pass 0) and draws into the
other. The window is only a way to get a context — `photo_fx` opens a
64x64 one. Images up to `GL_MAX_TEXTURE_SIZE` run on the GPU;
`fx_gl_run_pixels` returns 0 beyond that so callers fall back.

**No flips.** `rgba_image` rows are top-down; they upload as texture
rows 0..h-1, fragment row *j* of each pass samples texel row *j*, and
`glReadPixels` with the FBO bound returns rows in the same order. Only
code that reads the *window* (the viewer's screenshot) flips.

**Exact texel sampling.** Ping-pong and source textures use `GL_NEAREST`
and `GL_CLAMP_TO_EDGE`; `v_uv` lands on texel centers, so a
convolution's `v_uv + offset * u_texel` hits neighbors exactly, and edge
taps clamp exactly as the CPU's coordinate clamp does. Only the LUT
texture is `GL_LINEAR` (its bilinear filtering is half of the trilinear
lookup; the CPU reproduces it).

**8-bit between passes.** Each pass writes an RGBA8 target, and the CPU
quantizes (`fx_to_byte`) after every pass too, so a chain agrees with
the reference to a level or two; one-pass effects typically match
exactly. Sharpening after other passes amplifies a one-level difference
by its center weight, which is why chain tolerances are a few levels.

**Shader convention.** A pass body is joined after
`gfx_shader_header()` (GLSL 130 on GLX/WGL, 150 on the Mac's core
profile, 300 es + `precision highp float` on WebGL2) and a prelude:

	in vec2 v_uv;                # this fragment's texel center, 0..1
	out vec4 frag_color;
	uniform sampler2D u_source;  # previous pass
	uniform vec2 u_texel;        # 1 / image size
	uniform float u_p[12];       # fx_effect.p, uploaded with glUniform1fv

Bodies use `texture()` and an explicit `out` (the dialect all three
headers accept) and declare any extra uniforms themselves (the blur's
`u_weights[33]`/`u_radius`/`u_step`, the LUT's `u_lut`/`u_lut_size`).

**GL state.** `fx_gl_run` saves and restores the framebuffer binding,
viewport, current program and the `GL_BLEND`/`GL_SCISSOR_TEST` enables
(both are off during passes), leaves texture unit 0 active and disables
its own vertex attribute, so it can run between UI frames. It binds no
VAO (the Mac backend binds one at window open; GLX and WGL contexts are
compatibility profile).

## Effects

| Constructor | Kind | Parameters (`p[i]`) | Formula (rgb in 0..1) |
| --- | --- | --- | --- |
| `fx_bcs(b, c, s)` | `FX_BCS` | brightness, contrast, saturation | `c' = (c + b - 0.5) * k + 0.5`; `l = Rec.709 luma`; `l + (c' - l) * s` |
| `fx_levels(ib, iw, g, ob, ow)`, `fx_gamma(g)` | `FX_LEVELS` | input black/white, gamma, output black/white | `ob + pow(clamp((c - ib)/(iw - ib)), 1/g) * (ow - ob)` |
| `fx_convolve(k9, bias)`, `fx_sharpen(a)`, `fx_edge_detect()`, `fx_emboss()` | `FX_CONVOLVE` | 9 weights (row-major from top-left), bias | `bias + Σ k[i] * neighbor[i]`; alpha from the center |
| `fx_blur_pass(radius, vertical)` | `FX_BLUR` | radius (≤ 32), sigma (= radius/2), direction | normalized Gaussian taps `exp(-x²/2σ²)`, all four channels; use one horizontal + one vertical pass |
| `fx_vignette(amount, radius, softness)` | `FX_VIGNETTE` | amount, radius, softness | `rgb * (1 - amount * smoothstep(radius, radius + softness, d))`, `d` = 0 at the center, 1 at a corner |
| `fx_lut(strip, n, amount)` | `FX_LUT` | amount (+ the strip) | trilinear lookup in an n³ LUT, mixed with the input by `amount` |

**LUT strips.** A 3D LUT of size *n* (2..64) is an `n*n` x `n` RGBA
image: slice *b* (blue) is the *n* x *n* tile at x = b·n, red runs
across the tile, green down it. `fx_lut_generate(preset, n)` builds the
identity, warm, cool, sepia and mono presets; `photo_fx --lut FILE.png`
loads any strip in that layout (the common "Unreal/strip" export of
grading tools; a 64-step strip is 4096x64). The lookup is bilinear in
red/green within the two nearest blue slices (with half-texel insets so
it never bleeds across tiles) and linear between them.

## Adding an effect

1. `graphics/effects_core.w`: a new `FX_*` kind below `FX_KIND_COUNT`
   (bump it; the GPU program cache has 8 slots), a constructor that
   fills `p[]`, its row in the parameter table comment, and a name in
   `fx_kind_name`.
2. `graphics/effects_cpu.w`: the per-pixel (or neighborhood) arithmetic
   in `fx_cpu_apply`. Write it first — it is the specification.
3. `graphics/effects.w`: a body in `fx_fragment_body` against the
   prelude; extra uniforms go in `fx_gl_effect_uniforms`.
4. Tests: invariants/known values in `graphics/effects_cpu_test.w`
   (always runs, x86 and x64) and a GPU-vs-CPU line in
   `graphics/effects_gl_test.w`.
5. If users should reach it, a flag in `examples/photo/photo_lib.w`
   (`photo_settings`, `photo_settings_from_args`, `photo_build_chain`)
   and a slider in `photo_viewer.w`.

## Samples

	./wbuild photo_fx photo_viewer
	bin/photo_fx IN.png OUT.png --brightness 0.1 --contrast 1.2 --blur 3 --sharpen --vignette 0.5
	bin/photo_fx IN.jpg OUT.png --gamma 1.2 --lut sepia --lut-amount 0.7
	bin/photo_fx pattern:640x400 OUT.png --edges          # synthetic input
	bin/photo_fx --compare A.png B.png --tolerance 3      # per-channel max difference
	bin/photo_viewer photo.jpg --out graded.png

`photo_fx` reads PNG or JPEG (by signature) and writes PNG
(`png_encode_rgba`). Flags apply in a fixed order: levels/gamma,
brightness/contrast/saturation, LUT, blur, sharpen/edges/emboss,
vignette; a neutral value adds no pass. `--cpu` forces the reference,
`--gl` fails instead of falling back; with neither, a missing display
prints `photo_fx: no GL display; using the CPU reference` and carries
on. Negative values need the `=` form (`--brightness=-0.2`), since
lib.args reads `-0.2` as a flag. Both samples are x64 builds (the GL
binding links libGL.so.1, so the binary needs it present even for
`--cpu`).

`photo_viewer` shows the image fitted right of a control panel; every
slider, radio or checkbox change re-runs the chain on the next frame
and re-uploads the readback into a `ui_image`. graphics.ui has no slider
widget yet, so the viewer carries a small one (`photo_slider`: layout
row, `ui_click_behavior`, drag while held, a `UI_ACCESS_SLIDER` node
with its range) — a candidate to promote into graphics/ui/widgets.

## Tests

| Target | Umbrella | What |
| --- | --- | --- |
| `graphics_effects_cpu_test` / `graphics_effects_cpu_64_test` | `tests` / `tests_x64` | known values and invariants of every kind on the CPU (identity params exact, saturation 0 = luma, blur keeps mass and symmetry, edge detect on a step, LUT identity and sepia vs. the matrix, chain order) |
| `graphics_effects_gl_test` | `tests_x64` | every kind plus a 6-pass chain on a 97x61 image (larger than the 32x32 window), GPU vs. CPU within 2–3 levels; the default framebuffer and viewport are restored after every run. SKIP without a display |
| `graphics_gl_fbo_test` | `tests_x64` | the raw FBO/renderbuffer bindings (docs/projects/graphics.md) |
| `graphics_effects_webgl_test` | `tests_wasm` | both of the above as wasm in headless Chromium WebGL2 |
| `photo_fx_test` | `tests_x64` | the CLI: a 7-pass chain on the CPU, the same on the GPU when a display exists, compared (≤ 8 levels); PNG round trip; a real PNG (`docs/images/ui_demo_light.png`) graded |
| `photo_viewer_test` | `tests_x64` | three real viewer frames with a GPU chain and a screenshot. SKIP without a display |

## Next steps

- Promote `photo_slider` into graphics/ui/widgets with keyboard
  stepping and accessibility set-value support.
- `.cube` LUT parsing (strip PNGs only today).
- A preview path that runs the chain at screen resolution and only the
  final export at full resolution, and draws the result texture
  directly instead of reading it back each change.
- Half-float targets (`GL_RGBA16F`) to drop the 8-bit quantization
  between passes for long chains.
- A hidden/offscreen window flag in graphics.window, so headless tools
  do not map a window just to get a context.
