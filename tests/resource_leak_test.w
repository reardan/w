# wbuild: x64
# Ownership regressions run with both explicit debug allocation and the
# runner's leak verdict. Direct mmap stacks are not counted by this check.
# wbuild: step="bin/resource_leak_test" env="W_DEBUG_ALLOC=1" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
# wbuild: step="bin/wv2 x64 tests/resource_leak_test.w -o bin/resource_leak_check64"
# wbuild: step="bin/resource_leak_check64" env="W_DEBUG_ALLOC=1" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
# wbuild: step="bin/wv2 tests/resource_leak_fixture.w -o bin/resource_leak_fixture"
# wbuild: step="bin/resource_leak_fixture" env="W_DEBUG_ALLOC=1" env="W_TEST_LEAKS=1" expect_fail expect_stdout="LEAK: 'test_abandoned_generator()' returned with 1 heap block(s)" expect_stdout="LEAK: 'test_drained_generator_without_free()' returned with 1 heap block(s)" expect_stdout="LEAK: 'test_defer_inside_loop()' returned with 3 heap block(s), 48 byte(s)" expect_stdout="LEAK: 'test_return_before_defer()' returned with 1 heap block(s), 16 byte(s)" expect_stdout="LEAK: 'test_cancelled_timer_retention()'" expect_stdout="Summary: 1 passed, 5 failed, 0 skipped [leak check]" reject_stdout="All tests passed!"
# wbuild: step="bin/wv2 x64 tests/resource_leak_fixture.w -o bin/resource_leak_fixture64"
# wbuild: step="bin/resource_leak_fixture64" env="W_DEBUG_ALLOC=1" env="W_TEST_LEAKS=1" expect_fail expect_stdout="Summary: 1 passed, 5 failed, 0 skipped [leak check]" reject_stdout="All tests passed!"
import lib.testing
import lib.generator
import lib.result
import lib.event_loop
import lib.event_sim


generator int leak_counter(int n):
	for i in range(n): yield i


void test_manual_generator_free_before_start():
	generator* g = leak_counter(3)
	assert1(g.stack_base != 0)
	gen_free(g)


void test_manual_generator_free_after_yield():
	generator* g = leak_counter(3)
	assert_equal(1, gen_next(g))
	assert_equal(0, gen_value(g))
	gen_free(g)


void test_manual_generator_drain_and_free():
	generator* g = leak_counter(3)
	int count = 0
	while (gen_next(g)): count = count + 1
	assert_equal(3, count)
	assert_equal(0, g.stack_base)
	gen_free(g)


void test_generator_loop_exhaustion_and_continue():
	int sum = 0
	for int x in leak_counter(6):
		if ((x % 2) == 0): continue
		sum = sum + x
	assert_equal(9, sum)


void test_generator_loop_break():
	for int x in leak_counter(100):
		assert_equal(0, x)
		break


int leak_return_from_loop():
	for int x in leak_counter(100): return x + 1
	return 0


void test_generator_loop_return():
	assert_equal(1, leak_return_from_loop())


wresult[int]* leak_propagate_from_loop():
	for int x in leak_counter(100):
		int value = result_new_error[int](-3)?
		return result_new_ok[int](value + x)
	return result_new_ok[int](0)


void test_generator_loop_error_propagation():
	wresult[int]* r = leak_propagate_from_loop()
	assert_equal(-3, result_code[int](r))
	result_free[int](r)


int leak_defer_helper(int early):
	char* p = malloc(16)
	defer free(p)
	p[0] = 'x'
	if (early): return 7
	return 8


void test_defer_on_each_return():
	assert_equal(7, leak_defer_helper(1))
	assert_equal(8, leak_defer_helper(0))


void leak_defer_fallthrough():
	char* p = malloc(16)
	defer free(p)
	p[0] = 'x'


void test_defer_per_call_in_loop():
	for i in range(20): leak_defer_fallthrough()


wresult[int]* leak_defer_error():
	char* p = malloc(16)
	defer free(p)
	int value = result_new_error[int](-4)?
	return result_new_ok[int](value)


void test_defer_error_propagation():
	wresult[int]* r = leak_defer_error()
	assert_equal(-4, result_code[int](r))
	result_free[int](r)


void leak_timer_count(int id, void* context):
	int* count = cast(int*, context)
	count[0] = count[0] + 1


void test_fired_and_cancelled_timers_release_on_free():
	wclock* clock = wclock_virtual_new(0)
	event_sim* sim = event_sim_new(clock)
	event_loop* loop = event_loop_new_with(clock, event_sim_poller(sim))
	int fired = 0
	event_loop_add_timer(loop, 10, leak_timer_count, cast(void*, &fired))
	int cancelled = event_loop_add_timer(loop, 3600000, leak_timer_count, cast(void*, &fired))
	assert_equal(1, event_loop_cancel_timer(loop, cancelled))
	assert_equal(0, event_loop_run(loop))
	assert_equal(1, fired)
	assert_equal(0, loop.timer_heap.length)
	event_loop_free(loop)
	event_sim_free(sim)
	wclock_free(clock)


void test_pending_cancelled_timers_release_on_free():
	event_loop* loop = event_loop_new()
	int fired = 0
	for i in range(100):
		int id = event_loop_add_timer(loop, 3600000, leak_timer_count, cast(void*, &fired))
		assert_equal(1, event_loop_cancel_timer(loop, id))
	assert_equal(0, event_loop_timer_count(loop))
	event_loop_free(loop)
	assert_equal(0, fired)
