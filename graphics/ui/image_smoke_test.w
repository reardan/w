# Native RGBA painting, alpha, clipping, updates and texture lifetime.
# wbuild: name=graphics_ui_image_smoke_test arch_only=x64 expect_stdout="graphics ui image"
import lib.lib
import graphics.ui.render
import lib.ci_skip


int image_smoke_failures


void image_smoke_pixel(int x, int y, int r, int g, int b):
	char[4] pixel
	glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, &pixel[0])
	int[3] wanted
	wanted[0] = r
	wanted[1] = g
	wanted[2] = b
	for i in range(3):
		int difference = (pixel[i] & 255) - wanted[i]
		if (difference < 0): difference = -difference
		if (difference > 8): image_smoke_failures = image_smoke_failures + 1


int main():
	gfx_window* window = gfx_window_open(c"W UI image probe", 160, 120)
	if (window == 0):
		test_skip(c"graphics ui image SKIP (no display)")
		return 0
	ui_renderer renderer
	if (ui_render_init(&renderer) == 0): return 1
	char[4] pixel
	pixel[0] = 255
	pixel[1] = 0
	pixel[2] = 0
	pixel[3] = 128
	ui_image* image = ui_image_create(&renderer, 1, 1, &pixel[0], 4)
	if (image == 0): return 1
	ui_render_begin(&renderer, 160, 120)
	glViewport(0, 0, 160, 120)
	glClearColor(0.0, 0.0, 0.0, 1.0)
	glClear(GL_COLOR_BUFFER_BIT)
	ui_render_rect(&renderer, ui_rect_new(0.0, 0.0, 160.0, 120.0), ui_gray(1.0))
	ui_clip_push(&renderer, ui_rect_new(40.0, 30.0, 80.0, 60.0))
	ui_draw_image(&renderer, image, ui_rect_new(0.0, 0.0, 160.0, 120.0), 1.0)
	ui_clip_pop(&renderer)
	# Atlas after image proves the sampler/mode switch and painting order.
	ui_render_rect(&renderer, ui_rect_new(70.0, 50.0, 20.0, 20.0), ui_gray(0.0))
	ui_render_end(&renderer)
	glFinish()
	image_smoke_pixel(20, 60, 255, 255, 255)
	image_smoke_pixel(50, 60, 255, 127, 127)
	image_smoke_pixel(80, 60, 0, 0, 0)
	pixel[0] = 0
	pixel[1] = 255
	pixel[3] = 255
	if (ui_image_update(image, &pixel[0], 4) == 0): return 1
	ui_render_begin(&renderer, 160, 120)
	ui_draw_image(&renderer, image, ui_rect_new(0.0, 0.0, 160.0, 120.0), 1.0)
	ui_image_release(image)
	ui_render_end(&renderer)
	glFinish()
	image_smoke_pixel(80, 60, 0, 255, 0)
	ui_render_destroy(&renderer)
	gfx_window_destroy(window)
	if (image_smoke_failures != 0):
		println(c"graphics ui image FAILED")
		return 1
	println(c"graphics ui image OK")
	return 0
