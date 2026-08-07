/*
End-to-end UI smoke test: open a real window, run one frame of the
shared demo form (graphics/ui/demo_shared.w's documented layout), and
read pixels back — the button fill, the background, and at least one
glyph-ink sample across the label row (bitmap-exact positions are
deliberately avoided).

Prints "graphics ui smoke OK" on success; SKIPs with exit 0 when no
display is reachable (the graphics_gl_smoke_test convention — the
build greps the shared prefix, a real failure exits 1).
*/
# wbuild: name=graphics_ui_smoke_test arch_only=x64 expect_stdout="graphics ui smoke"
import lib.lib
import graphics.gl
import graphics.window
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets
import graphics.ui.demo_shared


int ui_smoke_failures


# Red channel at UI pixel x,y (grayscale theme: one channel is
# enough); flips y for glReadPixels' bottom-origin.
int ui_smoke_pixel(int x, int y):
	char* pixel = malloc(4)
	glReadPixels(x, 240 - 1 - y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel)
	int value = pixel[0] & 255
	free(pixel)
	return value


void ui_smoke_check(char* label, int x, int y, int want, int tolerance):
	int got = ui_smoke_pixel(x, y)
	int diff = got - want
	if (diff < 0):
		diff = 0 - diff
	if (diff > tolerance):
		print_error(c"pixel check failed: ")
		print_error(label)
		print_error(c" wanted ")
		print_error(itoa(want))
		print_error(c" got ")
		print_error(itoa(got))
		print_error(c"\n")
		ui_smoke_failures = ui_smoke_failures + 1


int main(int argc, int argv):
	gfx_window* win = gfx_window_open(c"w ui smoke", 320, 240)
	if (win == 0):
		println(c"graphics ui smoke SKIP (no display)")
		return 0
	ui_renderer rndr
	if (ui_render_init(&rndr) == 0):
		println(c"graphics ui smoke FAILED (renderer init)")
		return 1
	ui_demo_state state
	ui_demo_init(&state)
	ui_context ctx
	ui_context_init(&ctx, &rndr, &state.light_theme)

	ui_begin_window(&ctx, win)
	ui_demo_body(&ctx, &state)
	ui_end(&ctx)
	glFinish()

	# Light theme: the button is a filled accent pill (accent red
	# channel 0.404 -> 103); background 0.96 -> 245.
	ui_smoke_check(c"button fill", 20, 60, 103, 10)
	ui_smoke_check(c"background corner", 300, 220, 245, 8)

	# Title row: "W UI demo" (bold title strike) starts at x=8 in row
	# y 8..40 with glyph ink around y 16..32. Any dark sample counts
	# as ink (text 0.11 -> 28).
	int ink_found = 0
	int x = 8
	while (x < 152):
		if (ui_smoke_pixel(x, 20) < 90):
			ink_found = 1
		x = x + 2
	if (ink_found == 0):
		print_error(c"no glyph ink found across the label row\n")
		ui_smoke_failures = ui_smoke_failures + 1

	int gl_error = glGetError()
	if (gl_error != 0):
		print_error(c"glGetError: ")
		print_error(itoa(gl_error))
		print_error(c"\n")
		ui_smoke_failures = ui_smoke_failures + 1

	gfx_window_swap(win)
	gfx_window_poll(win)

	if (ui_smoke_failures > 0):
		println(c"graphics ui smoke FAILED")
		return 1
	println(c"graphics ui smoke OK")
	ui_render_destroy(&rndr)
	gfx_window_destroy(win)
	return 0
