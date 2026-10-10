# wbuild: name=graphics_ui_image_test arch_only=x64
import lib.testing
import graphics.ui.render


void test_image_copy_update_and_limits():
	ui_renderer renderer
	ui_render_init_headless(&renderer)
	char[4] pixel
	pixel[0] = 200
	pixel[1] = 100
	pixel[2] = 50
	pixel[3] = 128
	asserts(c"bad dimensions", ui_image_create(&renderer, 0, 1, &pixel[0], 4) == 0)
	asserts(c"bad length", ui_image_create(&renderer, 1, 1, &pixel[0], 3) == 0)
	asserts(c"overflow dimensions", ui_image_create(&renderer, 2147483647, 2147483647, &pixel[0], 4) == 0)
	ui_image* image = ui_image_create(&renderer, 1, 1, &pixel[0], 4)
	asserts(c"created", image != 0)
	pixel[0] = 20
	assert_equal(200, image.pixels[0] & 255)
	assert_equal(0, ui_image_update(image, &pixel[0], 3))
	assert_equal(1, ui_image_update(image, &pixel[0], 4))
	assert_equal(20, image.pixels[0] & 255)
	ui_image_release(image)
	ui_render_destroy(&renderer)


void test_image_order_scaling_clipping_and_release():
	ui_renderer renderer
	ui_render_init_headless(&renderer)
	ui_render_begin(&renderer, 200, 200)
	char[4] pixel
	pixel[0] = 255
	pixel[1] = 0
	pixel[2] = 0
	pixel[3] = 128
	ui_image* image = ui_image_create(&renderer, 1, 1, &pixel[0], 4)
	ui_render_rect(&renderer, ui_rect_new(0.0, 0.0, 100.0, 100.0), ui_gray(0.0))
	ui_clip_push(&renderer, ui_rect_new(25.0, 25.0, 50.0, 50.0))
	ui_draw_image(&renderer, image, ui_rect_new(0.0, 0.0, 100.0, 100.0), 0.5)
	ui_clip_pop(&renderer)
	ui_render_rect(&renderer, ui_rect_new(0.0, 0.0, 10.0, 10.0), ui_gray(1.0))
	assert_equal(3, renderer.commands.length)
	asserts(c"atlas first", renderer.commands[0].image == 0)
	asserts(c"image middle", renderer.commands[1].image == image)
	asserts(c"atlas last", renderer.commands[2].image == 0)
	assert_equal(6, renderer.commands[1].first)
	assert_equal(6, renderer.commands[1].count)
	assert_equal(2, image.references)
	float32* verts = renderer.layer_verts[UI_LAYER_BASE]
	asserts(c"clipped x", verts[48] == 25.0)
	asserts(c"clipped y", verts[49] == 25.0)
	asserts(c"clipped u", verts[50] == 0.25)
	asserts(c"clipped v", verts[51] == 0.25)
	asserts(c"opacity", verts[55] == 0.5)
	asserts(c"far u", verts[66] == 0.75)
	asserts(c"far v", verts[67] == 0.75)
	# Release caller ownership while queued: rendering retains it.
	ui_image_release(image)
	assert_equal(1, renderer.commands[1].image.references)
	ui_render_end(&renderer)
	ui_render_begin(&renderer, 200, 200)
	assert_equal(0, renderer.commands.length)
	assert_equal(0, renderer.layer_vert_count[UI_LAYER_BASE])
	ui_render_destroy(&renderer)


void test_image_layers_clipped_away_and_merge():
	ui_renderer renderer
	ui_render_init_headless(&renderer)
	ui_render_begin(&renderer, 100, 100)
	char[4] pixel
	for i in range(4): pixel[i] = 255
	ui_image* image = ui_image_create(&renderer, 1, 1, &pixel[0], 4)
	ui_render_layer(&renderer, UI_LAYER_POPUP)
	ui_clip_push(&renderer, ui_rect_new(50.0, 50.0, 10.0, 10.0))
	ui_draw_image(&renderer, image, ui_rect_new(0.0, 0.0, 10.0, 10.0), 1.0)
	assert_equal(0, renderer.commands.length)
	assert_equal(1, image.references)
	ui_clip_pop(&renderer)
	ui_draw_image(&renderer, image, ui_rect_new(0.0, 0.0, 10.0, 10.0), 1.0)
	ui_draw_image(&renderer, image, ui_rect_new(10.0, 0.0, 10.0, 10.0), 1.0)
	assert_equal(1, renderer.commands.length)
	assert_equal(12, renderer.commands[0].count)
	assert_equal(UI_LAYER_POPUP, renderer.commands[0].layer)
	assert_equal(2, image.references)
	ui_image_release(image)
	ui_render_destroy(&renderer)


void test_image_uvs_survive_font_atlas_growth():
	ui_renderer renderer
	ui_render_init_headless(&renderer)
	ui_render_begin(&renderer, 100, 100)
	char[4] pixel
	for i in range(4): pixel[i] = 255
	ui_image* image = ui_image_create(&renderer, 1, 1, &pixel[0], 4)
	ui_render_rect(&renderer, ui_rect_new(0.0, 0.0, 10.0, 10.0), ui_gray(1.0))
	ui_draw_image(&renderer, image, ui_rect_new(10.0, 0.0, 10.0, 10.0), 1.0)
	int old_rows = ui_font_uv_rows()
	float32 old_v = renderer.layer_verts[UI_LAYER_BASE][3]
	assert_equal(1, ui_font_rows_reserve(ui_font_st.cap_rows + 1))
	ui_render_sync_atlas(&renderer)
	float32 factor = cast(float32, old_rows) / cast(float32, ui_font_uv_rows())
	asserts(c"atlas rescaled", renderer.layer_verts[UI_LAYER_BASE][3] == old_v * factor)
	asserts(c"image unchanged", renderer.layer_verts[UI_LAYER_BASE][48 + 19] == 1.0)
	ui_image_release(image)
	ui_render_destroy(&renderer)
