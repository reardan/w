import lib.testing
import structures.array_list
import libs.standard.concurrent.sched
import libs.standard.concurrent.queue
import libs.standard.concurrent.futures


struct sched_reentrant_ctx:
	scheduler* s
	array_list* log


struct future_test_callback_ctx:
	array_list* log
	int value


void sched_test_record_id(int event_id, void* ctx):
	array_list_push(cast(array_list*, ctx), event_id)


void sched_test_record_two(int event_id, void* ctx):
	array_list_push(cast(array_list*, ctx), 2)


void sched_test_record_one_and_enter_two(int event_id, void* ctx):
	sched_reentrant_ctx* state = cast(sched_reentrant_ctx*, ctx)
	array_list_push(state.log, 1)
	sched_enter_at(state.s, 0, 0, sched_test_record_two, cast(void*, state.log))


void future_test_log_callback(future* f, void* ctx):
	future_test_callback_ctx* state = cast(future_test_callback_ctx*, ctx)
	array_list_push(state.log, state.value)


void test_sched_orders_by_time_priority_and_insertion():
	scheduler* s = sched_new()
	array_list* log = array_list_new()

	int late = sched_enter_at(s, 20, 0, sched_test_record_id, cast(void*, log))
	int low_priority = sched_enter_at(s, 10, 5, sched_test_record_id, cast(void*, log))
	int high_priority = sched_enter_at(s, 10, 1, sched_test_record_id, cast(void*, log))
	int same_priority = sched_enter_at(s, 10, 1, sched_test_record_id, cast(void*, log))

	sched_run_pending_at(s, 9)
	assert_equal(0, log.length)

	sched_run_pending_at(s, 10)
	assert_equal(3, log.length)
	assert_equal(high_priority, array_list_get(log, 0))
	assert_equal(same_priority, array_list_get(log, 1))
	assert_equal(low_priority, array_list_get(log, 2))

	sched_run_pending_at(s, 20)
	assert_equal(4, log.length)
	assert_equal(late, array_list_get(log, 3))

	array_list_free(log)
	sched_free(s)


void test_sched_cancel_skips_event():
	scheduler* s = sched_new()
	array_list* log = array_list_new()

	int cancelled = sched_enter_at(s, 0, 0, sched_test_record_id, cast(void*, log))
	int keeper = sched_enter_at(s, 0, 0, sched_test_record_id, cast(void*, log))

	assert_equal(1, sched_cancel(s, cancelled))
	assert_equal(0, sched_cancel(s, cancelled))
	sched_run_pending_at(s, 0)

	assert_equal(1, log.length)
	assert_equal(keeper, array_list_get(log, 0))

	array_list_free(log)
	sched_free(s)


void test_sched_reentrant_schedule_runs_in_same_pending_pass():
	scheduler* s = sched_new()
	array_list* log = array_list_new()
	sched_reentrant_ctx state
	state.s = s
	state.log = log

	sched_enter_at(s, 0, 0, sched_test_record_one_and_enter_two, cast(void*, &state))
	sched_run_pending_at(s, 0)

	assert_equal(2, log.length)
	assert_equal(1, array_list_get(log, 0))
	assert_equal(2, array_list_get(log, 1))

	array_list_free(log)
	sched_free(s)


void test_queue_fifo_and_empty_get():
	queue* q = queue_new()
	int first = 11
	int second = 22
	int third = 33

	assert_equal(1, queue_empty(q))
	assert_equal(0, cast(int, queue_get(q)))

	queue_put(q, cast(void*, &first))
	queue_put(q, cast(void*, &second))
	queue_put(q, cast(void*, &third))

	assert_equal(0, queue_empty(q))
	assert_equal(3, queue_size(q))
	assert_equal(11, *cast(int*, queue_get(q)))
	assert_equal(22, *cast(int*, queue_get(q)))
	assert_equal(33, *cast(int*, queue_get(q)))
	assert_equal(1, queue_empty(q))

	queue_free(q)


void test_queue_maxsize_try_put():
	queue* q = queue_new_maxsize(2)
	int first = 1
	int second = 2
	int third = 3

	assert_equal(1, queue_try_put(q, cast(void*, &first)))
	assert_equal(1, queue_try_put(q, cast(void*, &second)))
	assert_equal(1, queue_full(q))
	assert_equal(0, queue_try_put(q, cast(void*, &third)))
	assert_equal(2, queue_size(q))
	assert_equal(1, *cast(int*, queue_get(q)))
	assert_equal(0, queue_full(q))
	assert_equal(1, queue_try_put(q, cast(void*, &third)))
	assert_equal(2, *cast(int*, queue_get(q)))
	assert_equal(3, *cast(int*, queue_get(q)))

	queue_free(q)


void test_future_result_and_callback_order():
	future* f = future_new()
	array_list* log = array_list_new()
	future_test_callback_ctx first
	future_test_callback_ctx second
	future_test_callback_ctx late
	int result = 42

	first.log = log
	first.value = 1
	second.log = log
	second.value = 2
	late.log = log
	late.value = 3

	assert_equal(future_pending(), future_state(f))
	assert_equal(0, future_done(f))
	future_add_done_callback(f, future_test_log_callback, cast(void*, &first))
	future_add_done_callback(f, future_test_log_callback, cast(void*, &second))

	assert_equal(1, future_set_result(f, cast(void*, &result)))
	assert_equal(1, future_done(f))
	assert_equal(future_finished(), future_state(f))
	assert_equal(42, *cast(int*, future_result(f)))
	assert_equal(2, log.length)
	assert_equal(1, array_list_get(log, 0))
	assert_equal(2, array_list_get(log, 1))

	future_add_done_callback(f, future_test_log_callback, cast(void*, &late))
	assert_equal(3, log.length)
	assert_equal(3, array_list_get(log, 2))

	array_list_free(log)
	future_free(f)


void test_future_cancel_blocks_late_completion():
	future* f = future_new()
	int result = 7

	assert_equal(1, future_cancel(f))
	assert_equal(1, future_done(f))
	assert_equal(future_cancelled(), future_state(f))
	assert_equal(0, future_set_result(f, cast(void*, &result)))
	assert_equal(0, future_set_error(f, c"late"))
	assert_equal(0, cast(int, future_result(f)))
	assert_equal(0, cast(int, future_error(f)))

	future_free(f)


void test_future_running_then_error():
	future* f = future_new()

	assert_equal(1, future_set_running(f))
	assert_equal(future_running(), future_state(f))
	assert_equal(0, future_done(f))
	assert_equal(1, future_set_error(f, c"boom"))
	assert_equal(1, future_done(f))
	assert_equal(future_failed(), future_state(f))
	assert_strings_equal(c"boom", future_error(f))

	future_free(f)


void test_future_set_once():
	future* f = future_new()
	int first = 1
	int second = 2

	assert_equal(1, future_set_result(f, cast(void*, &first)))
	assert_equal(0, future_set_result(f, cast(void*, &second)))
	assert_equal(0, future_cancel(f))
	assert_equal(1, *cast(int*, future_result(f)))

	future_free(f)
