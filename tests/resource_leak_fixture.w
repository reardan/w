# Expected leak verdicts, owned by resource_leak_test.w. These deliberately
# demonstrate documented manual ownership / defer semantics, not proposed
# automatic cleanup behavior. Each must fail under W_TEST_LEAKS=1.
import lib.testing
import lib.generator
import lib.event_loop


generator int fixture_counter():
	yield 1
	yield 2


void test_abandoned_generator():
	generator* g = fixture_counter()
	assert_equal(1, gen_next(g))
	assert1(g.stack_base != 0)


void test_drained_generator_without_free():
	generator* g = fixture_counter()
	while (gen_next(g)): assert1(gen_value(g) > 0)
	assert_equal(0, g.stack_base)


void test_defer_inside_loop():
	char* p = 0
	for i in range(4):
		p = cast(char*, malloc(16))
		defer free(p)


void fixture_early_return(int early):
	char* p = cast(char*, malloc(16))
	if (early): return
	defer free(p)


void test_return_before_defer():
	fixture_early_return(1)


event_loop* fixture_loop


void fixture_timer_callback(int id, void* context):
	asserts(c"cancelled timer fired", 0)


void test_cancelled_timer_retention():
	fixture_loop = event_loop_new()
	for i in range(100):
		int id = event_loop_add_timer(fixture_loop, 3600000, fixture_timer_callback, 0)
		assert_equal(1, event_loop_cancel_timer(fixture_loop, id))
	assert_equal(0, event_loop_timer_count(fixture_loop))
	# Cancelled timers stay allocated until the heap is drained or the
	# loop is freed. This test intentionally leaves the loop alive.
	assert_equal(100, fixture_loop.timer_heap.length)


void test_cleanup_after_leaks_still_runs():
	event_loop_free(fixture_loop)
	fixture_loop = 0
