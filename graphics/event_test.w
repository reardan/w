# Unit tests for graphics.event's ring helpers: FIFO order, wraparound
# past the 64-slot capacity, drop-on-full, and field fidelity. Pure
# code (no GL or windowing), so it runs on the default 32-bit target,
# x64, and wasm alike.
# wbuild: name=graphics_event_test x64 group=wasm_smoke_test@wasm
import lib.testing
import graphics.event


void test_empty_ring_returns_nothing():
	int32[320] ring
	int32 head = 0
	int32 tail = 0
	gfx_event out
	assert_equal(0, gfx_event_ring_next(&ring[0], &head, &tail, &out))


void test_fifo_order_and_fields():
	int32[320] ring
	int32 head = 0
	int32 tail = 0
	gfx_event_ring_push(&ring[0], &head, &tail, GFX_EVENT_MOUSE_DOWN, 1, 10, 20, 0)
	gfx_event_ring_push(&ring[0], &head, &tail, GFX_EVENT_MOUSE_UP, 1, 11, 21, 0)
	gfx_event_ring_push(&ring[0], &head, &tail, GFX_EVENT_CHAR, 97, 0, 0, 0)

	gfx_event out
	assert_equal(1, gfx_event_ring_next(&ring[0], &head, &tail, &out))
	assert_equal(GFX_EVENT_MOUSE_DOWN, out.kind)
	assert_equal(1, out.code)
	assert_equal(10, out.x)
	assert_equal(20, out.y)

	assert_equal(1, gfx_event_ring_next(&ring[0], &head, &tail, &out))
	assert_equal(GFX_EVENT_MOUSE_UP, out.kind)
	assert_equal(11, out.x)
	assert_equal(21, out.y)

	assert_equal(1, gfx_event_ring_next(&ring[0], &head, &tail, &out))
	assert_equal(GFX_EVENT_CHAR, out.kind)
	assert_equal(97, out.code)

	assert_equal(0, gfx_event_ring_next(&ring[0], &head, &tail, &out))


void test_wraparound_past_capacity():
	int32[320] ring
	int32 head = 0
	int32 tail = 0
	gfx_event out
	# Three laps of push-one/pop-one walk the indices through the mask
	# boundary twice.
	int i = 0
	while (i < 200):
		gfx_event_ring_push(&ring[0], &head, &tail, GFX_EVENT_KEY_DOWN, i, i + 1, i + 2, i & 15)
		assert_equal(1, gfx_event_ring_next(&ring[0], &head, &tail, &out))
		assert_equal(GFX_EVENT_KEY_DOWN, out.kind)
		assert_equal(i, out.code)
		assert_equal(i + 1, out.x)
		assert_equal(i + 2, out.y)
		assert_equal(i & 15, out.mods)
		i = i + 1
	assert_equal(0, gfx_event_ring_next(&ring[0], &head, &tail, &out))


void test_scroll_event_fields():
	int32[320] ring
	int32 head = 0
	int32 tail = 0
	# The kind value is part of the JS-host contract
	# (tools/web/index.html mirrors these numbers).
	assert_equal(6, GFX_EVENT_SCROLL)
	gfx_event_ring_push(&ring[0], &head, &tail, GFX_EVENT_SCROLL, 1, 30, 40, 0)
	gfx_event_ring_push(&ring[0], &head, &tail, GFX_EVENT_SCROLL, 0 - 1, 31, 41, 0)

	gfx_event out
	assert_equal(1, gfx_event_ring_next(&ring[0], &head, &tail, &out))
	assert_equal(GFX_EVENT_SCROLL, out.kind)
	assert_equal(1, out.code)
	assert_equal(30, out.x)
	assert_equal(40, out.y)
	assert_equal(1, gfx_event_ring_next(&ring[0], &head, &tail, &out))
	assert_equal(0 - 1, out.code)
	assert_equal(0, gfx_event_ring_next(&ring[0], &head, &tail, &out))


void test_nav_event_contract():
	# Kind and code values are part of the JS-host contract
	# (tools/web/index.html mirrors these numbers).
	assert_equal(7, GFX_EVENT_NAV)
	assert_equal(1, GFX_NAV_LEFT)
	assert_equal(2, GFX_NAV_RIGHT)
	assert_equal(3, GFX_NAV_HOME)
	assert_equal(4, GFX_NAV_END)
	# The editor codes, added with the modifier flags.
	assert_equal(5, GFX_NAV_UP)
	assert_equal(6, GFX_NAV_DOWN)
	assert_equal(7, GFX_NAV_PAGE_UP)
	assert_equal(8, GFX_NAV_PAGE_DOWN)
	assert_equal(9, GFX_NAV_DELETE)

	int32[320] ring
	int32 head = 0
	int32 tail = 0
	gfx_event out
	gfx_event_ring_push(&ring[0], &head, &tail, GFX_EVENT_NAV, GFX_NAV_END, 5, 6, 0)
	assert_equal(1, gfx_event_ring_next(&ring[0], &head, &tail, &out))
	assert_equal(GFX_EVENT_NAV, out.kind)
	assert_equal(GFX_NAV_END, out.code)

	# Every editor code round-trips as its own event.
	int code = GFX_NAV_UP
	while (code <= GFX_NAV_DELETE):
		gfx_event_ring_push(&ring[0], &head, &tail, GFX_EVENT_NAV, code, 0, 0, 0)
		assert_equal(1, gfx_event_ring_next(&ring[0], &head, &tail, &out))
		assert_equal(GFX_EVENT_NAV, out.kind)
		assert_equal(code, out.code)
		code = code + 1
	assert_equal(0, gfx_event_ring_next(&ring[0], &head, &tail, &out))


void test_ring_slot_count():
	# The ring is capacity events x 5 int32 fields; every backend sizes
	# its own array from this number.
	assert_equal(64, gfx_event_ring_capacity())
	assert_equal(320, gfx_event_ring_ints())


void test_modifier_bits_round_trip():
	# Bit values are part of the JS-host contract
	# (tools/web/index.html mirrors these numbers).
	assert_equal(1, GFX_MOD_SHIFT)
	assert_equal(2, GFX_MOD_CTRL)
	assert_equal(4, GFX_MOD_ALT)
	assert_equal(8, GFX_MOD_SUPER)

	int32[320] ring
	int32 head = 0
	int32 tail = 0
	gfx_event out
	# mods travels per event, not per ring: interleaved events keep
	# their own masks.
	gfx_event_ring_push(&ring[0], &head, &tail, GFX_EVENT_NAV, GFX_NAV_LEFT, 0, 0, GFX_MOD_SHIFT)
	gfx_event_ring_push(&ring[0], &head, &tail, GFX_EVENT_CHAR, 97, 0, 0, 0)
	gfx_event_ring_push(&ring[0], &head, &tail, GFX_EVENT_NAV, GFX_NAV_HOME, 1, 2, GFX_MOD_CTRL | GFX_MOD_SHIFT)

	assert_equal(1, gfx_event_ring_next(&ring[0], &head, &tail, &out))
	assert_equal(GFX_NAV_LEFT, out.code)
	assert_equal(GFX_MOD_SHIFT, out.mods)

	assert_equal(1, gfx_event_ring_next(&ring[0], &head, &tail, &out))
	assert_equal(GFX_EVENT_CHAR, out.kind)
	assert_equal(0, out.mods)

	assert_equal(1, gfx_event_ring_next(&ring[0], &head, &tail, &out))
	assert_equal(GFX_NAV_HOME, out.code)
	assert_equal(3, out.mods)
	assert_equal(GFX_MOD_CTRL, out.mods & GFX_MOD_CTRL)
	assert_equal(0, out.mods & GFX_MOD_ALT)
	assert_equal(1, out.x)
	assert_equal(2, out.y)

	assert_equal(0, gfx_event_ring_next(&ring[0], &head, &tail, &out))


void test_all_modifiers_set():
	int32[320] ring
	int32 head = 0
	int32 tail = 0
	gfx_event out
	int all = GFX_MOD_SHIFT | GFX_MOD_CTRL | GFX_MOD_ALT | GFX_MOD_SUPER
	assert_equal(15, all)
	gfx_event_ring_push(&ring[0], &head, &tail, GFX_EVENT_KEY_DOWN, 42, 0, 0, all)
	assert_equal(1, gfx_event_ring_next(&ring[0], &head, &tail, &out))
	assert_equal(all, out.mods)


void test_overflow_drops_newest():
	int32[320] ring
	int32 head = 0
	int32 tail = 0
	# Capacity is 64 slots; 63 events fit, the 64th and later are
	# dropped.
	int i = 0
	while (i < 80):
		gfx_event_ring_push(&ring[0], &head, &tail, GFX_EVENT_KEY_DOWN, i, 0, 0, 0)
		i = i + 1

	gfx_event out
	int drained = 0
	while (gfx_event_ring_next(&ring[0], &head, &tail, &out)):
		# Survivors are the oldest 63 in order.
		assert_equal(drained, out.code)
		drained = drained + 1
	assert_equal(63, drained)
