# wbuild: name=graphics_text_unicode_test x64
import lib.testing
import graphics.text_unicode
import graphics.input_queue


void test_surrogate_pairs_and_malformed_low():
	int32 pending = 0
	assert_equal(0 - 1, gfx_utf16_input(&pending, 0xd83d))
	assert_equal(0x1f600, gfx_utf16_input(&pending, 0xde00))
	assert_equal(0, pending)
	assert_equal(0x4e2d, gfx_utf16_input(&pending, 0x4e2d))
	assert_equal(65533, gfx_utf16_input(&pending, 0xde00))
	assert_equal(0 - 1, gfx_utf16_input(&pending, 0xd83d))
	assert_equal(65, gfx_utf16_input(&pending, 65))
	assert_equal(0, pending)


void test_utf8_window_titles():
	char* text = gfx_utf16_from_utf8(c"A\xe4\xb8\xad\xf0\x9f\x98\x80")
	assert_equal(65, load_int16(text) & 65535)
	assert_equal(0x4e2d, load_int16(text + 2) & 65535)
	assert_equal(0xd83d, load_int16(text + 4) & 65535)
	assert_equal(0xde00, load_int16(text + 6) & 65535)
	assert_equal(0, load_int16(text + 8))
	free(text)


void test_long_native_commits_preserve_order_across_frames():
	gfx_input_queue queue
	gfx_input_queue_init(&queue)
	for i in range(1000): gfx_input_queue_push(&queue, GFX_EVENT_CHAR, 1000 + i, 2, 3, 0)
	gfx_input_queue_push(&queue, GFX_EVENT_NAV, GFX_NAV_LEFT, 2, 3, GFX_MOD_SHIFT)
	gfx_event event
	int seen = 0
	while (seen < 1000):
		gfx_input_queue_begin(&queue)
		int frame = 0
		while (gfx_input_queue_next(&queue, &event)):
			if (event.kind == GFX_EVENT_CHAR):
				assert_equal(1000 + seen, event.code)
				seen = seen + 1
				frame = frame + 1
			else:
				assert_equal(1000, seen)
				assert_equal(GFX_MOD_SHIFT, event.mods)
		asserts(c"frame budget", frame <= 32)
	gfx_input_queue_begin(&queue)
	assert_equal(1, gfx_input_queue_next(&queue, &event))
	assert_equal(GFX_EVENT_NAV, event.kind)
	assert_equal(0, queue.count)
	gfx_input_queue_free(&queue)


void test_native_queue_compaction_and_nav_budget():
	gfx_input_queue queue
	gfx_input_queue_init(&queue)
	for i in range(64): gfx_input_queue_push(&queue, GFX_EVENT_NAV, i, 0, 0, 0)
	gfx_event event
	for i in range(8):
		assert_equal(1, gfx_input_queue_next(&queue, &event))
		assert_equal(i, event.code)
	assert_equal(0, gfx_input_queue_next(&queue, &event))
	for i in range(8): gfx_input_queue_push(&queue, GFX_EVENT_NAV, 64 + i, 0, 0, 0)
	for frame in range(8):
		gfx_input_queue_begin(&queue)
		for i in range(8):
			assert_equal(1, gfx_input_queue_next(&queue, &event))
			assert_equal(8 + frame * 8 + i, event.code)
	gfx_input_queue_free(&queue)


void test_commit_finishes_before_later_focus_change():
	gfx_input_queue queue
	gfx_input_queue_init(&queue)
	gfx_input_queue_push(&queue, GFX_EVENT_CHAR, 'a', 0, 0, 0)
	gfx_input_queue_push(&queue, GFX_EVENT_MOUSE_DOWN, 1, 100, 200, 0)
	gfx_event event
	assert_equal(1, gfx_input_queue_next(&queue, &event))
	assert_equal(GFX_EVENT_CHAR, event.kind)
	assert_equal(0, gfx_input_queue_next(&queue, &event))
	gfx_input_queue_begin(&queue)
	assert_equal(1, gfx_input_queue_next(&queue, &event))
	assert_equal(GFX_EVENT_MOUSE_DOWN, event.kind)
	gfx_input_queue_free(&queue)


void test_navigation_finishes_before_later_text_or_focus_change():
	gfx_input_queue queue
	gfx_input_queue_init(&queue)
	gfx_event event
	for kind in range(3):
		int next_kind = GFX_EVENT_CHAR
		if (kind == 1): next_kind = GFX_EVENT_MOUSE_DOWN
		if (kind == 2): next_kind = GFX_EVENT_MOUSE_UP
		gfx_input_queue_begin(&queue)
		gfx_input_queue_push(&queue, GFX_EVENT_NAV, GFX_NAV_LEFT, 0, 0, 0)
		gfx_input_queue_push(&queue, next_kind, 'X', 5, 6, 0)
		assert_equal(1, gfx_input_queue_next(&queue, &event))
		assert_equal(GFX_EVENT_NAV, event.kind)
		assert_equal(0, gfx_input_queue_next(&queue, &event))
		gfx_input_queue_begin(&queue)
		assert_equal(1, gfx_input_queue_next(&queue, &event))
		assert_equal(next_kind, event.kind)
		assert_equal('X', event.code)
		assert_equal(0, gfx_input_queue_next(&queue, &event))
	gfx_input_queue_free(&queue)
