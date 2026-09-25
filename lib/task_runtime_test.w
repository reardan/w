# wbuild: x64
# Tests for the multi-threaded task runtime (lib/task_runtime.w):
# per-worker schedulers, runtime-wide completion, cross-thread
# channels and blocking work on helper threads.
import lib.testing
import lib.time
import lib.thread
import lib.task
import lib.task_runtime
import lib.container


/* Tasks spread over every worker and the run ends when all are done. */

struct rt_record:
	task_runtime* rt
	int* worker_of     # per task: the worker it ran on
	int done


generator int rt_note_worker(rt_record* rec, int i):
	task_sleep_ms(1)
	rec.worker_of[i] = task_runtime_worker_index(rec.rt)
	atomic_add(&rec.done, 1)


void test_runtime_spreads_tasks_over_workers():
	task_runtime* rt = task_runtime_new(4)
	rt_record* rec = new rt_record()
	rec.rt = rt
	rec.worker_of = cast(int*, malloc(40 * __word_size__))
	rec.done = 0
	int i = 0
	while (i < 40):
		rec.worker_of[i] = -1
		task_runtime_spawn(rt, rt_note_worker(rec, i))
		i = i + 1
	assert_equal(0, task_runtime_run(rt))
	assert_equal(40, rec.done)
	int* seen = cast(int*, malloc(4 * __word_size__))
	i = 0
	while (i < 4):
		seen[i] = 0
		i = i + 1
	i = 0
	while (i < 40):
		int w = rec.worker_of[i]
		asserts(c"task ran outside the runtime", (w >= 0) && (w < 4))
		seen[w] = seen[w] + 1
		i = i + 1
	i = 0
	while (i < 4):
		# Round-robin: every worker got exactly its share.
		assert_equal(10, seen[i])
		i = i + 1
	free(cast(void*, seen))
	free(cast(void*, rec.worker_of))
	free(cast(void*, rec))
	task_runtime_free(rt)


/* Tasks spawned by tasks, locally or on other workers, keep the
   runtime alive until they finish too. */

struct rt_tree:
	task_runtime* rt
	int leaves


generator int rt_leaf(rt_tree* tree):
	task_sleep_ms(2)
	atomic_add(&tree.leaves, 1)


generator int rt_branch(rt_tree* tree, int depth):
	if (depth == 0):
		atomic_add(&tree.leaves, 1)
		return
	# One child on this worker, one wherever round-robin puts it.
	task_go(rt_branch(tree, depth - 1))
	task_runtime_spawn(tree.rt, rt_branch(tree, depth - 1))
	task_group* g = task_group_here()
	task_group_spawn(g, rt_leaf(tree))
	task_group_wait(g)
	task_group_free(g)


void test_nested_spawns_are_awaited():
	task_runtime* rt = task_runtime_new(3)
	rt_tree* tree = new rt_tree()
	tree.rt = rt
	tree.leaves = 0
	task_runtime_spawn(rt, rt_branch(tree, 5))
	assert_equal(0, task_runtime_run(rt))
	# 2^5 depth-0 leaves plus one group leaf per inner branch (2^5 - 1).
	assert_equal(32 + 31, tree.leaves)
	free(cast(void*, tree))
	task_runtime_free(rt)


/* Cross-thread channel. */

struct rt_sum:
	int total
	int received


generator int rt_producer(task_xchan* ch, int start, int count):
	int i = 0
	while (i < count):
		assert_equal(0, task_xchan_send(ch, start + i))
		i = i + 1


generator int rt_consumer(task_xchan* ch, rt_sum* sum):
	int v = 0
	while (task_xchan_recv(ch, &v) > 0):
		atomic_add(&sum.total, v)
		atomic_add(&sum.received, 1)


generator int rt_close_when(task_xchan* ch, rt_sum* sum, int want):
	while (sum.received < want):
		task_sleep_ms(1)
	task_xchan_close(ch)


void test_xchan_moves_values_between_workers():
	task_runtime* rt = task_runtime_new(4)
	task_xchan* ch = task_xchan_new(8)
	rt_sum* sum = new rt_sum()
	sum.total = 0
	sum.received = 0
	task_runtime_spawn_on(rt, 0, rt_producer(ch, 1, 1000))
	task_runtime_spawn_on(rt, 1, rt_producer(ch, 1001, 1000))
	task_runtime_spawn_on(rt, 2, rt_consumer(ch, sum))
	task_runtime_spawn_on(rt, 3, rt_consumer(ch, sum))
	task_runtime_spawn_on(rt, 3, rt_close_when(ch, sum, 2000))
	assert_equal(0, task_runtime_run(rt))
	assert_equal(2000, sum.received)
	# 1 + 2 + ... + 2000
	assert_equal(2001000, sum.total)
	free(cast(void*, sum))
	task_xchan_free(ch)
	task_runtime_free(rt)


generator int rt_xrecv_timeout(task_xchan* ch):
	int v = 0
	task_finish(task_xchan_recv_timeout(ch, &v, 5))


void test_xchan_timeout_on_a_lone_scheduler():
	task_scheduler* s = task_scheduler_new()
	task_xchan* ch = task_xchan_new(0)
	task* t = task_spawn(s, rt_xrecv_timeout(ch))
	assert_equal(0, task_run(s))
	assert_equal(task_err_timed_out(), task_result(t))
	assert_equal(0, ch.receivers.length)
	# Same-scheduler rendezvous works without another thread.
	task* r = task_spawn(s, rt_consumer(ch, new rt_sum()))
	task_spawn(s, rt_producer(ch, 5, 3))
	task_run_once(s, 0)
	task_run_once(s, 0)
	task_xchan_close(ch)
	assert_equal(0, task_run(s))
	assert_equal(1, task_done(r))
	task_xchan_free(ch)
	task_scheduler_free(s)


/* Blocking work parks only the calling task. */

int rt_blocking_sleep(void* arg):
	sleep_ms(60)
	return 7


generator int rt_blocker():
	task_finish(task_spawn_blocking(rt_blocking_sleep, 0))


generator int rt_ticker(task* until, list[int] ticks):
	while (task_done(until) == 0):
		task_sleep_ms(5)
		ticks.push(1)


void test_spawn_blocking_keeps_the_loop_running():
	task_scheduler* s = task_scheduler_new()
	list[int] ticks = new list[int]
	task* b = task_spawn(s, rt_blocker())
	task_spawn(s, rt_ticker(b, ticks))
	assert_equal(0, task_run(s))
	assert_equal(7, task_result(b))
	asserts(c"the loop stalled while the helper thread slept", ticks.length >= 5)
	list_free[int](ticks)
	task_scheduler_free(s)


int rt_sum_range(void* arg):
	int n = cast(int, arg)
	int total = 0
	int i = 1
	while (i <= n):
		total = total + i
		i = i + 1
	return total


generator int rt_many_blocking(list[int] out):
	task_group* g = task_group_here()
	out.push(task_spawn_blocking(rt_sum_range, cast(void*, 100)))
	out.push(task_spawn_blocking(rt_sum_range, cast(void*, 10)))
	task_group_free(g)


void test_spawn_blocking_inside_the_runtime():
	task_runtime* rt = task_runtime_new(2)
	list[int] a = new list[int]
	list[int] b = new list[int]
	task_runtime_spawn(rt, rt_many_blocking(a))
	task_runtime_spawn(rt, rt_many_blocking(b))
	assert_equal(0, task_runtime_run(rt))
	assert_equal(2, a.length)
	assert_equal(5050, a[0])
	assert_equal(55, b[1])
	list_free[int](a)
	list_free[int](b)
	task_runtime_free(rt)
