# wbuild: x64
import lib.testing
import lib.fake_fs_async
import lib.event_sim
import libs.standard.distributed.sim_env


struct delayed_test:
	fake_fs* fs
	wclock* clock
	fake_fs_async* queue
	int fd


delayed_test* delayed_test_new():
	delayed_test* t = new delayed_test()
	t.fs = fake_fs_new(17)
	t.clock = wclock_virtual_new(0)
	t.queue = fake_fs_async_new(t.fs, t.clock, 32, 65536)
	io_result r
	assert_equal(IO_OK, file_ops_open(fake_fs_ops(t.fs), c"data", FILE_OPS_WRITE | FILE_OPS_CREATE | FILE_OPS_APPEND, 420, &t.fd, &r))
	assert_equal(IO_OK, file_ops_sync_dir(fake_fs_ops(t.fs), c".", &r))
	return t


void delayed_test_free(delayed_test* t):
	fake_fs_async_free(t.queue)
	wclock_free(t.clock)
	fake_fs_free(t.fs)
	free(t)


fake_fs_request* delayed_submit(delayed_test* t, int kind, char* data, int length, int execute, int complete):
	fake_fs_request* req = 0
	assert_equal(IO_OK, fake_fs_async_submit(t.queue, kind, t.fd, data, length, execute, complete, &req))
	assert1(req != 0)
	return req


void delayed_step(delayed_test* t, int ms):
	wclock_virtual_advance_ms(t.clock, ms)
	assert_equal(IO_OK, fake_fs_async_poll(t.queue))


void test_write_visibility_and_sync_notification_are_separate():
	delayed_test* t = delayed_test_new()
	char* source = mem_dup(c"A\0B", 3)
	fake_fs_request* write_req = delayed_submit(t, FAKE_FS_OP_WRITE, source, 3, 10, 20)
	source[0] = 'X'
	free(source)
	io_result r
	delayed_step(t, 9)
	assert_equal(0, fake_fs_file_size(t.fs, c"data"))
	assert_equal(IO_WOULD_BLOCK, fake_fs_async_result(t.queue, write_req, &r))
	delayed_step(t, 1)
	assert1(fake_fs_file_equals(t.fs, c"data", c"A\0B", 3))
	assert_equal(IO_WOULD_BLOCK, fake_fs_async_result(t.queue, write_req, &r))
	assert_equal(1, fake_fs_pending_changes(t.fs, c"data"))
	delayed_step(t, 20)
	assert_equal(IO_OK, fake_fs_async_result(t.queue, write_req, &r))
	assert_equal(IO_OK, r.status)
	assert_equal(3, r.transferred)
	fake_fs_request* sync_req = delayed_submit(t, FAKE_FS_OP_SYNC, 0, 0, 5, 15)
	delayed_step(t, 5)
	assert_equal(0, fake_fs_pending_changes(t.fs, c"data"))
	assert_equal(IO_WOULD_BLOCK, fake_fs_async_result(t.queue, sync_req, &r))
	delayed_step(t, 15)
	assert_equal(IO_OK, fake_fs_async_result(t.queue, sync_req, &r))
	assert_equal(IO_OK, r.status)
	fake_fs_crash(t.fs, 0)
	assert1(fake_fs_file_equals(t.fs, c"data", c"A\0B", 3))
	assert_equal(IO_OK, fake_fs_async_release(t.queue, write_req))
	assert_equal(IO_OK, fake_fs_async_release(t.queue, sync_req))
	assert_equal(0, t.queue.bytes)
	delayed_test_free(t)


void test_cancel_before_and_after_execution():
	delayed_test* t = delayed_test_new()
	fake_fs_request* before = delayed_submit(t, FAKE_FS_OP_WRITE, c"never", 5, 10, 10)
	fake_fs_async_cancel(t.queue, before)
	io_result r
	assert_equal(IO_OK, fake_fs_async_result(t.queue, before, &r))
	assert_equal(IO_CANCELLED, r.status)
	fake_fs_request* after = delayed_submit(t, FAKE_FS_OP_WRITE, c"kept", 4, 5, 20)
	delayed_step(t, 5)
	fake_fs_async_cancel(t.queue, after)
	assert_equal(1, after.cancelled)
	assert_equal(IO_WOULD_BLOCK, fake_fs_async_result(t.queue, after, &r))
	assert_equal(IO_WOULD_BLOCK, fake_fs_async_release(t.queue, after))
	delayed_step(t, 20)
	assert_equal(IO_OK, fake_fs_async_result(t.queue, after, &r))
	assert_equal(IO_OK, r.status)
	assert_equal(4, r.transferred)
	assert1(fake_fs_file_equals(t.fs, c"data", c"kept", 4))
	fake_fs_request* sync_req = delayed_submit(t, FAKE_FS_OP_SYNC, 0, 0, 0, 5)
	delayed_step(t, 0)
	fake_fs_async_cancel(t.queue, sync_req)
	assert_equal(IO_WOULD_BLOCK, fake_fs_async_result(t.queue, sync_req, &r))
	delayed_step(t, 5)
	assert_equal(IO_OK, fake_fs_async_result(t.queue, sync_req, &r))
	assert_equal(IO_OK, r.status)
	assert_equal(1, sync_req.cancelled)
	fake_fs_crash(t.fs, 0)
	assert1(fake_fs_file_equals(t.fs, c"data", c"kept", 4))
	delayed_test_free(t)


void test_notifications_can_complete_out_of_submission_order():
	delayed_test* t = delayed_test_new()
	fake_fs_request* slow = delayed_submit(t, FAKE_FS_OP_WRITE, c"a", 1, 0, 30)
	fake_fs_request* fast = delayed_submit(t, FAKE_FS_OP_WRITE, c"b", 1, 10, 0)
	delayed_step(t, 10)
	io_result r
	assert_equal(IO_WOULD_BLOCK, fake_fs_async_result(t.queue, slow, &r))
	assert_equal(IO_OK, fake_fs_async_result(t.queue, fast, &r))
	assert_equal(IO_OK, r.status)
	assert1(fake_fs_file_equals(t.fs, c"data", c"ab", 2))
	delayed_step(t, 20)
	assert_equal(IO_OK, fake_fs_async_result(t.queue, slow, &r))
	assert_equal(IO_OK, r.status)
	delayed_test_free(t)


# Crash before write, between write and sync, or after sync but before
# its notification. No outstanding handle may publish a stale success.
void test_crash_at_each_delayed_persistence_boundary():
	for phase in range(3):
		delayed_test* t = delayed_test_new()
		fake_fs_request* write_req = delayed_submit(t, FAKE_FS_OP_WRITE, c"record", 6, 10, 0)
		fake_fs_request* sync_req = delayed_submit(t, FAKE_FS_OP_SYNC, 0, 0, 20, 10)
		fake_fs_request* late = delayed_submit(t, FAKE_FS_OP_WRITE, c"stale", 5, 100, 0)
		delayed_step(t, phase * 10)
		fake_fs_crash(t.fs, 0)
		io_result r
		assert_equal(IO_OK, fake_fs_async_result(t.queue, sync_req, &r))
		assert_equal(IO_CANCELLED, r.status)
		assert_equal(1, sync_req.crashed)
		assert_equal(IO_OK, fake_fs_async_result(t.queue, late, &r))
		assert_equal(IO_CANCELLED, r.status)
		assert_equal(IO_OK, fake_fs_async_result(t.queue, write_req, &r))
		if (phase == 0): assert_equal(IO_CANCELLED, r.status)
		else: assert_equal(IO_OK, r.status)
		delayed_step(t, 100)
		if (phase == 2): assert1(fake_fs_file_equals(t.fs, c"data", c"record", 6))
		else: assert_equal(0, fake_fs_file_size(t.fs, c"data"))
		# A new descriptor after reboot is not targeted by an old request.
		int fd = 0
		assert_equal(IO_OK, file_ops_open(fake_fs_ops(t.fs), c"data", FILE_OPS_WRITE | FILE_OPS_APPEND, 0, &fd, &r))
		assert1(fd != t.fd)
		delayed_test_free(t)


void test_directory_sync_delay_controls_name_durability():
	for synced in range(2):
		delayed_test* t = delayed_test_new()
		io_result r
		assert_equal(IO_OK, file_ops_rename(fake_fs_ops(t.fs), c"data", c"renamed", &r))
		fake_fs_request* req = delayed_submit(t, FAKE_FS_OP_SYNC_DIR, c".", 1, 10, 20)
		delayed_step(t, synced * 10)
		fake_fs_crash(t.fs, 0)
		assert_equal(synced, fake_fs_exists(t.fs, c"renamed"))
		assert_equal(1 - synced, fake_fs_exists(t.fs, c"data"))
		assert_equal(IO_OK, fake_fs_async_result(t.queue, req, &r))
		assert_equal(IO_CANCELLED, r.status)
		delayed_test_free(t)


void test_delayed_errors_short_reads_and_retry_results():
	delayed_test* t = delayed_test_new()
	io_result r
	int[5] errors
	errors[0] = FAKE_FS_EINTR
	errors[1] = FAKE_FS_EAGAIN
	errors[2] = FAKE_FS_ENOSPC
	errors[3] = FAKE_FS_EIO
	errors[4] = FAKE_FS_ZERO
	int[5] statuses
	statuses[0] = IO_INTERRUPTED
	statuses[1] = IO_WOULD_BLOCK
	statuses[2] = IO_NO_SPACE
	statuses[3] = IO_IO_ERROR
	statuses[4] = IO_OK
	for i in range(5):
		fake_fs_fail_nth(t.fs, FAKE_FS_OP_WRITE, 1, errors[i])
		fake_fs_request* req = delayed_submit(t, FAKE_FS_OP_WRITE, c"abc", 3, 0, 10)
		delayed_step(t, 0)
		assert_equal(IO_WOULD_BLOCK, fake_fs_async_result(t.queue, req, &r))
		delayed_step(t, 10)
		assert_equal(IO_OK, fake_fs_async_result(t.queue, req, &r))
		assert_equal(statuses[i], r.status)
		assert_equal(0, r.transferred)
		if (i < 4): assert_equal(errors[i], r.native_error)
		assert_equal(IO_OK, fake_fs_async_release(t.queue, req))
	assert_equal(0, fake_fs_file_size(t.fs, c"data"))
	fake_fs_set_capacity(t.fs, 2)
	fake_fs_request* short_write = delayed_submit(t, FAKE_FS_OP_WRITE, c"abc", 3, 0, 0)
	delayed_step(t, 0)
	assert_equal(IO_OK, fake_fs_async_result(t.queue, short_write, &r))
	assert_equal(IO_OK, r.status)
	assert_equal(2, r.transferred)
	int read_fd = 0
	assert_equal(IO_OK, file_ops_open(fake_fs_ops(t.fs), c"data", FILE_OPS_READ, 0, &read_fd, &r))
	fake_fs_request* read_req = 0
	assert_equal(IO_OK, fake_fs_async_submit(t.queue, FAKE_FS_OP_READ, read_fd, 0, 4, 5, 5, &read_req))
	delayed_step(t, 10)
	assert_equal(IO_OK, fake_fs_async_result(t.queue, read_req, &r))
	assert_equal(IO_OK, r.status)
	assert_equal(2, r.transferred)
	assert_bytes_equal(c"ab", read_req.data, 2)
	fake_fs_request* eof = 0
	assert_equal(IO_OK, fake_fs_async_submit(t.queue, FAKE_FS_OP_READ, read_fd, 0, 4, 0, 0, &eof))
	delayed_step(t, 0)
	assert_equal(IO_OK, fake_fs_async_result(t.queue, eof, &r))
	assert_equal(IO_EOF, r.status)
	delayed_test_free(t)


void test_queue_bounds_ownership_and_invalid_submission():
	delayed_test* t = delayed_test_new()
	t.queue.max_requests = 1
	t.queue.max_bytes = sizeof(fake_fs_request) + 4
	fake_fs_request* req = delayed_submit(t, FAKE_FS_OP_WRITE, c"abc", 3, 10, 10)
	fake_fs_request* extra = req
	assert_equal(IO_WOULD_BLOCK, fake_fs_async_submit(t.queue, FAKE_FS_OP_SYNC, t.fd, 0, 0, 0, 0, &extra))
	assert1(extra == 0)
	delayed_step(t, 20)
	assert_equal(IO_WOULD_BLOCK, fake_fs_async_submit(t.queue, FAKE_FS_OP_SYNC, t.fd, 0, 0, 0, 0, &extra))
	assert_equal(IO_OK, fake_fs_async_release(t.queue, req))
	assert_equal(0, t.queue.bytes)
	assert_equal(IO_NO_SPACE, fake_fs_async_submit(t.queue, FAKE_FS_OP_READ, t.fd, 0, checked_int_max(), 0, 0, &extra))
	assert_equal(IO_IO_ERROR, fake_fs_async_submit(t.queue, FAKE_FS_OP_WRITE, t.fd, 0, 1, 0, 0, &extra))
	assert_equal(IO_IO_ERROR, fake_fs_async_submit(t.queue, FAKE_FS_OP_READ, t.fd, 0, -1, 0, 0, &extra))
	assert_equal(IO_IO_ERROR, fake_fs_async_submit(t.queue, FAKE_FS_OP_SYNC, t.fd, 0, 0, 1, FAKE_FS_ASYNC_MAX_DELAY, &extra))
	assert_equal(IO_IO_ERROR, fake_fs_async_submit(t.queue, FAKE_FS_OP_SYNC_DIR, 0, c".\0x", 3, 0, 0, &extra))
	assert_equal(IO_UNSUPPORTED, fake_fs_async_submit(t.queue, FAKE_FS_OP_RENAME, 0, 0, 0, 0, 0, &extra))
	assert_equal(0, t.queue.bytes)
	assert_equal(IO_OK, fake_fs_async_submit(t.queue, FAKE_FS_OP_SYNC, t.fd, 0, 0, 0, 0, &extra))
	delayed_step(t, 0)
	assert_equal(IO_OK, fake_fs_async_release(t.queue, extra))
	delayed_test_free(t)


void test_clock_errors_wall_jumps_and_word_wrap():
	delayed_test* t = delayed_test_new()
	wclock_virtual_advance_ms(t.clock, 2147483640)
	fake_fs_request* req = delayed_submit(t, FAKE_FS_OP_WRITE, c"x", 1, 10, 10)
	wclock_virtual_jump_wall_ms(t.clock, 1000000)
	delayed_step(t, 10)
	io_result r
	assert_equal(IO_WOULD_BLOCK, fake_fs_async_result(t.queue, req, &r))
	int delay = 0
	assert_equal(IO_OK, fake_fs_async_next_delay(t.queue, &delay))
	assert_equal(10, delay)
	wclock_virtual_fail(t.clock, WCLOCK_MONOTONIC, IO_IO_ERROR)
	wclock_virtual_advance_ms(t.clock, 10)
	assert_equal(IO_IO_ERROR, fake_fs_async_poll(t.queue))
	assert_equal(IO_IO_ERROR, fake_fs_async_next_delay(t.queue, &delay))
	assert_equal(IO_WOULD_BLOCK, fake_fs_async_result(t.queue, req, &r))
	fake_fs_request* rejected = 0
	assert_equal(IO_IO_ERROR, fake_fs_async_submit(t.queue, FAKE_FS_OP_SYNC, t.fd, 0, 0, 0, 0, &rejected))
	assert1(rejected == 0)
	wclock_virtual_fail(t.clock, WCLOCK_MONOTONIC, IO_OK)
	delayed_step(t, 0)
	assert_equal(IO_OK, fake_fs_async_result(t.queue, req, &r))
	assert_equal(IO_OK, r.status)
	assert_equal(IO_OK, fake_fs_async_next_delay(t.queue, &delay))
	assert_equal(-1, delay)
	delayed_test_free(t)


void test_byte_budget_recovers_after_release_and_teardown_does_no_io():
	delayed_test* t = delayed_test_new()
	t.queue.max_bytes = sizeof(fake_fs_request) + 5
	for i in range(100):
		fake_fs_request* req = delayed_submit(t, FAKE_FS_OP_WRITE, c"data", 4, 10, 10)
		fake_fs_request* extra = 0
		assert_equal(IO_WOULD_BLOCK, fake_fs_async_submit(t.queue, FAKE_FS_OP_SYNC, t.fd, 0, 0, 0, 0, &extra))
		assert_equal(t.queue.max_bytes, t.queue.bytes)
		fake_fs_async_cancel(t.queue, req)
		assert_equal(IO_OK, fake_fs_async_release(t.queue, req))
		assert_equal(0, t.queue.bytes)
		assert_equal(0, t.queue.requests.length)
	delayed_submit(t, FAKE_FS_OP_WRITE, c"data", 4, 0, 0)
	fake_fs_async_free(t.queue)
	assert_equal(0, fake_fs_file_size(t.fs, c"data"))
	wclock_free(t.clock)
	fake_fs_free(t.fs)
	free(t)


int delayed_replay(int seed, int jump):
	delayed_test* t = delayed_test_new()
	prng* rng = prng_new(seed)
	for i in range(20):
		char value = 'a' + i
		delayed_submit(t, FAKE_FS_OP_WRITE, &value, 1, prng_range(rng, 30), prng_range(rng, 30))
	# Polling once past the end must preserve execution order too.
	if (jump): delayed_step(t, 60)
	else:
		for i in range(60): delayed_step(t, 1)
	io_result r
	for i in range(t.queue.requests.length):
		assert_equal(IO_OK, fake_fs_async_result(t.queue, t.queue.requests[i], &r))
		assert_equal(IO_OK, r.status)
	# Frozen byte order also proves the x86 and x64 schedules agree.
	if (seed == 123): assert1(fake_fs_file_equals(t.fs, c"data", c"qroansdfecipbkjmghtl", 20))
	if (seed == 456): assert1(fake_fs_file_equals(t.fs, c"data", c"hmrjpegladsfcibntokq", 20))
	int hash = fake_fs_state_hash(t.fs)
	fake_fs_crash(t.fs, rng)
	hash = fake_fs_mix(hash, fake_fs_state_hash(t.fs))
	prng_free(rng)
	delayed_test_free(t)
	return hash


void test_seeded_schedules_replay_with_different_poll_granularity():
	assert_equal(delayed_replay(123, 0), delayed_replay(123, 1))
	assert_equal(delayed_replay(456, 0), delayed_replay(456, 1))
	assert1(delayed_replay(123, 0) != delayed_replay(456, 0))
	delayed_test* t = delayed_test_new()
	delayed_submit(t, FAKE_FS_OP_WRITE, c"a", 1, 10, 0)
	delayed_submit(t, FAKE_FS_OP_WRITE, c"b", 1, 10, 0)
	delayed_submit(t, FAKE_FS_OP_WRITE, c"c", 1, 10, 0)
	delayed_step(t, 10)
	assert1(fake_fs_file_equals(t.fs, c"data", c"abc", 3))
	delayed_test_free(t)


struct delayed_loop_test:
	event_loop* loop
	fake_fs_async* queue
	fake_fs_request* sync_req
	int ticks
	int replies
	int failures


void delayed_loop_tick(int id, void* context):
	delayed_loop_test* t = cast(delayed_loop_test*, context)
	t.ticks = t.ticks + 1
	# Timer work can continue while the sync or its notification is held.
	assert_equal(0, t.replies)


void delayed_loop_pump(int id, void* context):
	delayed_loop_test* t = cast(delayed_loop_test*, context)
	assert_equal(IO_OK, fake_fs_async_poll(t.queue))
	io_result r
	if (fake_fs_async_result(t.queue, t.sync_req, &r) == IO_OK):
		if (r.status == IO_OK): t.replies = t.replies + 1
		else: t.failures = t.failures + 1
		return
	int delay = 0
	assert_equal(IO_OK, fake_fs_async_next_delay(t.queue, &delay))
	assert1(delay >= 0)
	event_loop_add_timer(t.loop, delay, delayed_loop_pump, context)


void test_event_loop_withholds_reply_until_sync_completion():
	for failing in range(2):
		delayed_test* t = delayed_test_new()
		delayed_submit(t, FAKE_FS_OP_WRITE, c"wal", 3, 0, 0)
		delayed_step(t, 0)
		if (failing): fake_fs_fail_nth(t.fs, FAKE_FS_OP_SYNC, 1, FAKE_FS_EIO)
		event_sim* sim = event_sim_new(t.clock)
		event_loop* loop = event_loop_new_with(t.clock, event_sim_poller(sim))
		delayed_loop_test* context = new delayed_loop_test()
		context.loop = loop
		context.queue = t.queue
		context.sync_req = delayed_submit(t, FAKE_FS_OP_SYNC, 0, 0, 10, 20)
		event_loop_add_timer(loop, 0, delayed_loop_pump, context)
		event_loop_add_timer(loop, 5, delayed_loop_tick, context)
		event_loop_add_timer(loop, 15, delayed_loop_tick, context)
		event_loop_add_timer(loop, 25, delayed_loop_tick, context)
		assert_equal(0, event_loop_run(loop))
		assert_equal(3, context.ticks)
		assert_equal(1 - failing, context.replies)
		assert_equal(failing, context.failures)
		assert_equal(30, event_sim_now(sim))
		fake_fs_crash(t.fs, 0)
		if (failing): assert_equal(0, fake_fs_file_size(t.fs, c"data"))
		else: assert1(fake_fs_file_equals(t.fs, c"data", c"wal", 3))
		free(context)
		event_loop_free(loop)
		event_sim_free(sim)
		delayed_test_free(t)


void test_sim_env_crash_invalidates_pending_completions():
	sim_net* net = sim_new(9, 0, 0, 0)
	sim_env* env = sim_env_new(net, 1, 9, 0)
	fake_fs_async* q = fake_fs_async_new(env.fs, sim_env_clock(env), 2, 4096)
	io_result r
	int fd = 0
	assert_equal(IO_OK, file_ops_open(sim_env_ops(env), c"wal", FILE_OPS_WRITE | FILE_OPS_CREATE, 420, &fd, &r))
	fake_fs_request* req = 0
	assert_equal(IO_OK, fake_fs_async_submit(q, FAKE_FS_OP_WRITE, fd, c"x", 1, 10, 10, &req))
	sim_advance(net, 10)
	assert_equal(IO_OK, fake_fs_async_poll(q))
	assert_equal(IO_WOULD_BLOCK, fake_fs_async_result(q, req, &r))
	sim_env_crash(env)
	sim_advance(net, 20)
	assert_equal(IO_OK, fake_fs_async_poll(q))
	assert_equal(IO_OK, fake_fs_async_result(q, req, &r))
	assert_equal(IO_CANCELLED, r.status)
	assert_equal(1, req.crashed)
	fake_fs_async_free(q)
	sim_env_free(env)
	sim_free(net)
