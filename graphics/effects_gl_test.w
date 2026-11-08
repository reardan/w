/*
GPU effects vs the CPU reference: every graphics.effects_core kind, run
through graphics.effects' ping-pong FBO chain on a 97x61 image (odd
sizes, larger than the 32x32 window, so the passes must run at the
image's resolution) and compared channel by channel against
graphics.effects_cpu with a small tolerance. Also chains several
effects and checks GL state is restored for the window afterwards.

Prints "graphics effects gl OK" on success, or a SKIP line (exit 0)
with no display; the build greps for the "graphics effects gl" prefix
(the graphics_gl_texture_test convention).
*/
# wbuild: name=graphics_effects_gl_test arch_only=x64 expect_stdout="graphics effects gl"
# The same two pixel-checking programs as wasm in real headless Chromium
# WebGL2 (tools/web/index.html + webgl_env.mjs): FBOs, glGetIntegerv and
# the GLSL ES 3.00 spelling of every effect shader. SKIPs without Chromium.
# wbuild: target=graphics_effects_webgl_test tag=tests_wasm dep=wv2 dep=wrun input=tools/web/run_browser_webgl.mjs input=tools/web/headless_chromium.mjs input=tools/web/index.html input=tools/web/webgl_env.mjs input=tools/web/wasi_lite.mjs
# wbuild: step="bin/wv2 wasm graphics/gl_fbo_test.w -o bin/graphics_gl_fbo_test.wasm"
# wbuild: step="bin/wrun node tools/web/run_browser_webgl.mjs bin/graphics_gl_fbo_test.wasm" expect_stdout="graphics gl fbo"
# wbuild: step="bin/wv2 wasm graphics/effects_gl_test.w -o bin/graphics_effects_gl_test.wasm"
# wbuild: step="bin/wrun node tools/web/run_browser_webgl.mjs bin/graphics_effects_gl_test.wasm" expect_stdout="graphics effects gl"
import lib.lib
import graphics.gl
import graphics.window
import graphics.effects_core
import graphics.effects_cpu
import graphics.effects
import lib.ci_skip


int effects_failures


char* effects_pattern(int width, int height):
	char* pixels = cast(char*, malloc(width * height * 4))
	for y in range(height):
		for x in range(width):
			char* p = &pixels[(y * width + x) * 4]
			p[0] = (x * 255) / (width - 1)
			p[1] = (y * 255) / (height - 1)
			int check = ((x / 3) + (y / 3)) % 2
			p[2] = 30 + check * 180
			p[3] = 255 - (x % 7) * 20
	return pixels


# Compare GL and CPU for one chain; frees the chain's effects.
void effects_compare(char* label, fx_gl* g, list[fx_effect*] chain, char* src, int width, int height, int tolerance):
	char* want = fx_cpu_run(chain, src, width, height)
	char* got = fx_gl_run_pixels(g, chain, src, width, height)
	# Every run, the first one (which creates the targets) included,
	# leaves the window's framebuffer bound.
	if (gl_current_framebuffer() != 0):
		print_error(label)
		print_error(c": the default framebuffer was not rebound\n")
		effects_failures = effects_failures + 1
		glBindFramebuffer(GL_FRAMEBUFFER, 0)
	if (got == 0):
		print_error(label)
		print_error(c": GPU run failed\n")
		effects_failures = effects_failures + 1
		free(want)
		return
	int worst = 0
	int worst_at = 0
	for i in range(width * height * 4):
		int diff = (want[i] & 255) - (got[i] & 255)
		if (diff < 0): diff = 0 - diff
		if (diff > worst):
			worst = diff
			worst_at = i
	print(label)
	print(c": max diff ")
	println(itoa(worst))
	if (worst > tolerance):
		print_error(label)
		print_error(c": GL differs from CPU by ")
		print_error(itoa(worst))
		print_error(c" at byte ")
		print_error(itoa(worst_at))
		print_error(c" (cpu ")
		print_error(itoa(want[worst_at] & 255))
		print_error(c" gl ")
		print_error(itoa(got[worst_at] & 255))
		print_error(c")\n")
		effects_failures = effects_failures + 1
	for i in range(chain.length):
		fx_gl_release_effect(chain[i])
		fx_effect_free(chain[i])
	free(want)
	free(got)


list[fx_effect*] effects_one(fx_effect* e):
	list[fx_effect*] chain = new list[fx_effect*]
	chain.push(e)
	return chain


int main(int argc, int argv):
	gfx_window* win = gfx_window_open(c"w graphics effects", 32, 32)
	if (win == 0):
		test_skip(c"graphics effects gl SKIP (no display)")
		return 0
	fx_gl g
	fx_gl_init(&g)
	int width = 97
	int height = 61
	char* src = effects_pattern(width, height)

	effects_compare(c"bcs", &g, effects_one(fx_bcs(0.08, 1.3, 1.4)), src, width, height, 2)
	effects_compare(c"bcs grayscale", &g, effects_one(fx_bcs(0.0 - 0.1, 0.8, 0.0)), src, width, height, 2)
	effects_compare(c"levels", &g, effects_one(fx_levels(0.1, 0.9, 1.8, 0.05, 0.95)), src, width, height, 2)
	effects_compare(c"sharpen", &g, effects_one(fx_sharpen(0.8)), src, width, height, 2)
	effects_compare(c"edge detect", &g, effects_one(fx_edge_detect()), src, width, height, 2)
	effects_compare(c"emboss", &g, effects_one(fx_emboss()), src, width, height, 2)
	effects_compare(c"blur h", &g, effects_one(fx_blur_pass(5, 0)), src, width, height, 2)
	effects_compare(c"blur v", &g, effects_one(fx_blur_pass(5, 1)), src, width, height, 2)
	effects_compare(c"vignette", &g, effects_one(fx_vignette(0.8, 0.2, 0.7)), src, width, height, 2)
	effects_compare(c"lut sepia", &g, effects_one(fx_lut(fx_lut_generate(FX_LUT_SEPIA, 16), 16, 1.0)), src, width, height, 3)
	effects_compare(c"lut warm half", &g, effects_one(fx_lut(fx_lut_generate(FX_LUT_WARM, 8), 8, 0.5)), src, width, height, 3)

	list[fx_effect*] chain = new list[fx_effect*]
	chain.push(fx_bcs(0.05, 1.1, 1.2))
	chain.push(fx_blur_pass(3, 0))
	chain.push(fx_blur_pass(3, 1))
	chain.push(fx_sharpen(0.5))
	chain.push(fx_gamma(1.2))
	chain.push(fx_vignette(0.5, 0.4, 0.5))
	effects_compare(c"chain of 6", &g, chain, src, width, height, 3)

	# The runner restored the default framebuffer and window viewport:
	# a clear lands in the window.
	glClearColor(0.0, 1.0, 0.0, 1.0)
	glClear(GL_COLOR_BUFFER_BIT)
	glFinish()
	char* pixel = cast(char*, malloc(4))
	glReadPixels(16, 16, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel)
	if ((pixel[1] & 255) != 255):
		print_error(c"window clear after the chain did not land\n")
		effects_failures = effects_failures + 1
	int32[4] viewport
	glGetIntegerv(GL_VIEWPORT, &viewport[0])
	if ((viewport[2] != win.width) || (viewport[3] != win.height)):
		print_error(c"viewport not restored\n")
		effects_failures = effects_failures + 1

	int gl_error = glGetError()
	if (gl_error != 0):
		print_error(c"glGetError: ")
		print_error(itoa(gl_error))
		print_error(c"\n")
		effects_failures = effects_failures + 1
	gfx_window_swap(win)
	gfx_window_poll(win)
	free(pixel)
	free(src)
	fx_gl_destroy(&g)
	if (effects_failures > 0):
		println(c"graphics effects gl FAILED")
		return 1
	println(c"graphics effects gl OK")
	gfx_window_destroy(win)
	return 0
