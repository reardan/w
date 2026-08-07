# Unit tests for graphics.event's ring helpers: FIFO order, wraparound
# past the 64-slot capacity, drop-on-full, and field fidelity. Pure
# code (no GL or windowing), so it runs on the default 32-bit target,
# x64, and wasm alike.
# wbuild: name=graphics_event_test x64 group=wasm_smoke_test@wasm
import lib.testing
import graphics.event


void test_empty_ring_returns_nothing():
	int32[256] ring
	int32 head = 0
	int32 tail = 0
	gfx_event out
	assert_equal(0, gfx_event_ring_next(&ring[0], &head, &tail, &out))


void test_fifo_order_and_fields():
	int32[256] ring
	int32 head = 0
	int32 tail = 0
	gfx_event_ring_push(&ring[0], &head, &tail, GFX_EVENT_MOUSE_DOWN, 1, 10, 20)
	gfx_event_ring_push(&ring[0], &head, &tail, GFX_EVENT_MOUSE_UP, 1, 11, 21)
	gfx_event_ring_push(&ring[0], &head, &tail, GFX_EVENT_CHAR, 97, 0, 0)

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
	int32[256] ring
	int32 head = 0
	int32 tail = 0
	gfx_event out
	# Three laps of push-one/pop-one walk the indices through the mask
	# boundary twice.
	int i = 0
	while (i < 200):
		gfx_event_ring_push(&ring[0], &head, &tail, GFX_EVENT_KEY_DOWN, i, i + 1, i + 2)
		assert_equal(1, gfx_event_ring_next(&ring[0], &head, &tail, &out))
		assert_equal(GFX_EVENT_KEY_DOWN, out.kind)
		assert_equal(i, out.code)
		assert_equal(i + 1, out.x)
		assert_equal(i + 2, out.y)
		i = i + 1
	assert_equal(0, gfx_event_ring_next(&ring[0], &head, &tail, &out))


void test_overflow_drops_newest():
	int32[256] ring
	int32 head = 0
	int32 tail = 0
	# Capacity is 64 slots; 63 events fit, the 64th and later are
	# dropped.
	int i = 0
	while (i < 80):
		gfx_event_ring_push(&ring[0], &head, &tail, GFX_EVENT_KEY_DOWN, i, 0, 0)
		i = i + 1

	gfx_event out
	int drained = 0
	while (gfx_event_ring_next(&ring[0], &head, &tail, &out)):
		# Survivors are the oldest 63 in order.
		assert_equal(drained, out.code)
		drained = drained + 1
	assert_equal(63, drained)
