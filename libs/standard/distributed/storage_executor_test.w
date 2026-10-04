# wbuild: x64 timeout=60000
import lib.testing
import lib.task
import libs.standard.distributed.storage_executor


struct storage_test_gate:
	int started
	int released


int storage_delayed_sync(void* self, int fd, io_result* result):
	storage_test_gate* gate = cast(storage_test_gate*, self)
	atomic_add(&gate.started, 1)
	thread_wait_word(&gate.released)
	return file_ops_real_sync(0, fd, result)


void storage_release(storage_test_gate* gate):
	gate.released = 1
	sys_futex(cast(int, &gate.released), thread_futex_wake_op, 2147483647, 0)


void test_stalled_maintenance_reserved_commit():
	char* suffix = itoa(__word_size__)
	char* prefix = strjoin(c"bin/storage_worker_", suffix)
	char* wal_path = strjoin(prefix, c"_raft")
	storage_unlink(cast(file_ops*, 0), wal_path)
	# Unique prefix per process/run; no previous manifest can interfere.
	char* pid = itoa(getpid())
	char* unique = strjoin(prefix, pid)
	free(pid)
	lsm* store = lsm_open(unique, 100000)
	assert1(lsm_put(store, c"key", c"value", 5))
	assert1(lsm_flush(store))
	storage_test_gate* gate = new storage_test_gate(0, 0)
	file_ops* ops = file_ops_real_new()
	ops.self = gate
	ops.sync = storage_delayed_sync
	store.ops = ops
	store.log.ops = ops
	store.manifest.ops = ops
	storage_executor* workers = storage_executor_new(100000, 100000)
	storage_compact_job* maintenance = new storage_compact_job(store, 100000)
	executor_job* stalled = 0
	assert_equal(IO_OK, executor_try_submit(workers.maintenance, storage_compact_work, maintenance, 50000, &stalled))
	while (gate.started == 0): sleep_ms(1)
	# Reserved commit capacity remains available while a real table sync
	# stalls on the other worker. No maintenance success is released yet.
	raft_wal* log = raft_wal_open(wal_path)
	list[int] peers = new list[int]
	raft* node = raft_new(1, peers, 100, 200, 20, 1)
	u64_set_int(node.current_term, 1)
	list[raft_msg*] staged = new list[raft_msg*]
	staged.push(raft_msg_new(raft_msg_vote_reply, 1, 2, node.current_term))
	list[raft_msg*] released = new list[raft_msg*]
	storage_persist_job* commit = new storage_persist_job(log, node, staged, released)
	executor_job* fast = 0
	assert_equal(IO_OK, executor_try_submit(workers.commit, storage_persist_work, commit, 1000, &fast))
	executor_result result
	assert_equal(IO_OK, executor_wait(fast, &result))
	assert_equal(IO_OK, result.value)
	assert_equal(1, released.length)
	assert_equal(0, gate.released)
	# Saturation is bounded; queued cancellation runs no storage code.
	executor_job* queued = 0
	assert_equal(IO_OK, executor_try_submit(workers.maintenance, storage_compact_work, maintenance, 50000, &queued))
	executor_job* refused = 0
	assert_equal(EXEC_OVERLOADED, executor_try_submit(workers.maintenance, storage_compact_work, maintenance, 1, &refused))
	storage_executor_close(workers)
	assert_equal(IO_CANCELLED, executor_wait(queued, &result))
	storage_release(gate)
	assert_equal(IO_OK, executor_wait(stalled, &result))
	assert_equal(IO_OK, result.value)
	storage_executor_free(workers)
	raft_msg_free(released[0])
	raft_wal_close(log)
	raft_free(node)
	lsm_close(store)
	free(gate)
	free(maintenance)
	free(commit)
	free(ops)
	free(unique)
	free(wal_path)
	free(prefix)
	free(suffix)


import libs.standard.distributed.raft_tcp


generator int storage_wait_task(executor_job* job, list[int] completed):
	executor_result result
	assert_equal(IO_OK, executor_wait(job, &result))
	assert_equal(IO_OK, result.value)
	completed.push(1)


generator int storage_socket_task(storage_test_gate* gate, list[int] completed):
	while (gate.started == 0): task_sleep_ms(1)
	int port = 26500 + __word_size__ * 100
	raft_tcp* a = raft_tcp_new(1, port)
	raft_tcp* b = raft_tcp_new(2, port + 1)
	assert1(cast(int, a) != 0 && cast(int, b) != 0)
	raft_tcp_add_peer(a, 2, port + 1)
	u64* term = u64_new_int(1)
	raft_msg* message = raft_msg_new(raft_msg_vote_req, 1, 2, term)
	assert1(raft_tcp_send(a, message))
	raft_msg_free(message)
	int deadline = mono_deadline(time_monotonic_ms(), 2000)
	while (raft_tcp_inbox_count(b) == 0):
		assert1(mono_expired(time_monotonic_ms(), deadline) == 0)
		raft_tcp_pump(a)
		raft_tcp_pump(b)
		task_sleep_ms(1)
	assert_equal(0, completed.length)
	assert_equal(0, gate.released)
	# Timer/deadline and socket work ran while persistence was stalled.
	task_sleep_ms(5)
	storage_release(gate)
	u64_free(term)
	raft_tcp_free(a)
	raft_tcp_free(b)


void test_socket_processing_during_delayed_sync():
	char* word = itoa(__word_size__)
	char* path = strjoin(c"bin/storage_delayed_sync_", word)
	unlink(path)
	storage_test_gate* gate = new storage_test_gate(0, 0)
	file_ops* ops = file_ops_real_new()
	ops.self = gate
	ops.sync = storage_delayed_sync
	wal_recovery report
	raft_wal* log = raft_wal_open_policy_with_ops(ops, path, WAL_RECOVER_STRICT_TRUNCATE, &report)
	list[int] peers = new list[int]
	raft* node = raft_new(1, peers, 100, 200, 20, 1)
	u64_set_int(node.current_term, 1)
	list[raft_msg*] staged = new list[raft_msg*]
	list[raft_msg*] released = new list[raft_msg*]
	storage_persist_job* request = new storage_persist_job(log, node, staged, released)
	storage_executor* workers = storage_executor_new(10000, 10000)
	executor_job* job = 0
	assert_equal(IO_OK, executor_try_submit(workers.commit, storage_persist_work, request, 1000, &job))
	task_scheduler* scheduler = task_scheduler_new()
	list[int] completed = new list[int]
	task_spawn(scheduler, storage_wait_task(job, completed))
	task_spawn(scheduler, storage_socket_task(gate, completed))
	assert_equal(0, task_run(scheduler))
	assert_equal(1, completed.length)
	task_scheduler_free(scheduler)
	storage_executor_free(workers)
	raft_wal_close(log)
	raft_free(node)
	free(request)
	free(ops)
	free(gate)
	unlink(path)
	free(path)
	free(word)
