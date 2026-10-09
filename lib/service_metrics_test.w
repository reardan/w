# wbuild: x64
import lib.testing
import lib.service_metrics


generator int metrics_test_task():
	task_finish(0)


void test_service_metrics_scheduler_and_allocation_snapshots():
	metrics* m = metrics_new(METRICS_STANDARD_COUNT)
	task_scheduler* s = task_scheduler_new()
	task_spawn(s, metrics_test_task())
	task_spawn(s, metrics_test_task())
	metrics_sample_scheduler(m, s)
	assert_equal(2, metrics_get(m, METRIC_TASKS_PENDING))
	assert_equal(0, task_run(s))
	metrics_sample_scheduler(m, s)
	assert_equal(0, metrics_get(m, METRIC_TASKS_PENDING))
	task_scheduler_free(s)
	arena a
	arena_init(&a, 32, 32)
	char* p = 0
	assert_equal(ARENA_ERR_BUDGET, arena_alloc(&a, 100, 1, &p))
	metrics_sample_arena(m, &a)
	metrics_sample_arena(m, &a)
	assert_equal(1, metrics_get(m, METRIC_ALLOC_FAILURES))
	arena_release(&a)
	mem_budget b
	mem_budget_init(&b, 10)
	assert_equal(ARENA_ERR_BUDGET, mem_budget_reserve(&b, 11))
	assert_equal(ARENA_ERR_BUDGET, mem_budget_reserve(&b, 12))
	metrics_sample_budget(m, &b)
	metrics_sample_budget(m, &b)
	assert_equal(2, metrics_get(m, METRIC_ALLOC_FAILURES))
	assert_equal(METRICS_STANDARD_COUNT, m.count)
	metrics_free(m)


struct metrics_test_gate:
	int open
	int started


int metrics_test_job(void* p):
	metrics_test_gate* g = cast(metrics_test_gate*, p)
	atomic_add(&g.started, 1)
	sys_futex(cast(int, &g.started), thread_futex_wake_op, 0x7fffffff, 0)
	thread_wait_word(&g.open)
	return 7


void test_service_metrics_executor_reads_locked_snapshot():
	metrics* m = metrics_new(METRICS_STANDARD_COUNT)
	executor* ex = executor_new(c"metrics", 1, 1, 100)
	metrics_test_gate g
	g.open = 0
	g.started = 0
	executor_job* first = 0
	executor_job* second = 0
	assert_equal(IO_OK, executor_try_submit(ex, metrics_test_job, &g, 20, &first))
	thread_wait_word(&g.started)
	assert_equal(IO_OK, executor_try_submit(ex, metrics_test_job, &g, 30, &second))
	metrics_sample_executor(m, ex)
	assert_equal(1, metrics_get(m, METRIC_JOBS_QUEUED))
	assert_equal(30, metrics_get(m, METRIC_BYTES_QUEUED))
	assert_equal(1, metrics_get(m, METRIC_WORKERS_RUNNING))
	assert_equal(0, metrics_get(m, METRIC_WORKERS_BLOCKED))
	g.open = 1
	sys_futex(cast(int, &g.open), thread_futex_wake_op, 0x7fffffff, 0)
	executor_result r
	assert_equal(IO_OK, executor_wait(first, &r))
	assert_equal(IO_OK, executor_wait(second, &r))
	executor_shutdown(ex, EXEC_DRAIN)
	metrics_sample_executor(m, ex)
	assert_equal(0, metrics_get(m, METRIC_JOBS_QUEUED))
	assert_equal(0, metrics_get(m, METRIC_BYTES_QUEUED))
	assert_equal(0, metrics_get(m, METRIC_WORKERS_RUNNING))
	executor_free(ex)
	metrics_free(m)


void test_service_metrics_shared_budget_snapshot():
	metrics* m = metrics_new(METRICS_STANDARD_COUNT)
	mem_shared_budget b
	assert_equal(ARENA_OK, mem_shared_budget_init(&b, 1))
	assert_equal(ARENA_ERR_BUDGET, mem_shared_budget_reserve(&b, 2))
	assert_equal(ARENA_OK, metrics_sample_shared_budget(m, &b))
	assert_equal(ARENA_OK, metrics_sample_shared_budget(m, &b))
	assert_equal(1, metrics_get(m, METRIC_ALLOC_FAILURES))
	assert_equal(ARENA_OK, mem_shared_budget_destroy(&b))
	metrics_free(m)
