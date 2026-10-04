# wbuild: x64 timeout=120000
# Regression test for task_xchan's cross-thread completion racing a
# cancellation or timeout (lib/task_runtime.w). A peer on another worker
# completes a parked waiter and posts the wake to the waiter's inbox;
# before that message is read, the waiter resumes on its own (cancelled,
# or its deadline fired), sees the completion, returns and -- being
# detached -- is reclaimed. The late wake must then be a no-op: it used
# to name the waiter by (task*, park sequence) and read the freed task.
# The guard-page debug allocator is forced on (lib/memory_debug.w), so
# such a read faults instead of silently waking whatever task reused
# the address.
import lib.lib
import lib.assert
import lib.memory
import lib.crash
import lib.time
import lib.thread
import lib.task
import lib.task_runtime


struct xr_state:
	task_xchan* ch
	int role_send      # the detached waiter sends (else receives)
	int timeout_ms     # the waiter's own timeout (-1: none)
	int armed          # rounds whose waiter is parked
	int fired          # rounds whose peer has acted
	int peer_result    # the peer's try_send / try_recv result
	int peer_value     # what the peer received
	int got            # the waiter's result
	int got_value      # what the waiter received
	int finished       # rounds whose waiter returned
	int completed      # rounds the peer completed
	int rounds


int xr_load(int* p):
	return atomic_add(p, 0)


generator int xr_waiter(xr_state* st, int round):
	int v = 0
	int r = 0
	if (st.role_send): r = task_xchan_send_timeout(st.ch, 1000 + round, st.timeout_ms)
	else: r = task_xchan_recv_timeout(st.ch, &v, st.timeout_ms)
	st.got = r
	st.got_value = v
	atomic_add(&st.finished, 1)


# The peer (another worker): completes the parked waiter from its side.
void xr_peer_act(xr_state* st, int round):
	if (st.role_send):
		int v = 0
		st.peer_result = task_xchan_try_recv(st.ch, &v)
		st.peer_value = v
	else:
		st.peer_result = task_xchan_try_send(st.ch, 1000 + round)
	atomic_add(&st.fired, 1)


# Did the peer complete the waiter's operation?
int xr_peer_completed(xr_state* st):
	if (st.role_send): return st.peer_result == 1
	return st.peer_result == 0


void xr_check_round(xr_state* st, int round, int cancelled):
	if (xr_peer_completed(st)):
		# The completion wins over the cancellation / timeout.
		st.completed = st.completed + 1
		if (st.role_send):
			assert_equal(0, st.got)
			assert_equal(1000 + round, st.peer_value)
		else:
			assert_equal(1, st.got)
			assert_equal(1000 + round, st.got_value)
	else:
		assert_equal(task_err_would_block(), st.peer_result)
		if (cancelled): assert_equal(task_err_cancelled(), st.got)
		else: assert_equal(task_err_timed_out(), st.got)


/* Deterministic: the waiter's worker is held busy while the peer
   completes it, then cancels it, so the waiter resumes, returns and is
   reclaimed before its worker reads the wake from its inbox. */

generator int xr_cancel_host(xr_state* st):
	for round in range(st.rounds):
		task* w = task_go(xr_waiter(st, round))
		task_detach(w)
		task_yield_now()          # w runs and parks
		atomic_add(&st.armed, 1)
		# Block this whole worker (not just this task) until the peer has
		# completed w: the inbox stays unread meanwhile.
		while (xr_load(&st.fired) <= round): sleep_ms(0)
		assert_equal(1, task_cancel(w))
		# w runs before this worker polls its inbox again.
		task_yield_now()
		assert_equal(round + 1, xr_load(&st.finished))
		# Keep the loop turning so the stale wake is delivered now.
		task_sleep_ms(1)
		xr_check_round(st, round, 1)


generator int xr_peer(xr_state* st, int jitter):
	for round in range(st.rounds):
		while (xr_load(&st.armed) <= round): task_yield_now()
		if (jitter):
			# Act somewhere around the waiter's deadline.
			sleep_ms(st.timeout_ms - 1 + round % 3)
			int spin = (round * 7919) % 20000
			int sink = 0
			for k in range(spin): sink = sink + k
			if (sink < 0): println(c"")
		xr_peer_act(st, round)


/* Racy: the peer acts right around the waiter's own timeout while the
   waiter's worker runs freely. */

generator int xr_timeout_host(xr_state* st):
	for round in range(st.rounds):
		task* w = task_go(xr_waiter(st, round))
		task_detach(w)
		task_yield_now()
		atomic_add(&st.armed, 1)
		while ((xr_load(&st.finished) <= round) || (xr_load(&st.fired) <= round)): task_sleep_ms(1)
		# Let any wake still in flight arrive while this worker polls.
		task_sleep_ms(1)
		xr_check_round(st, round, 0)


xr_state* xr_state_new(int role_send, int timeout_ms, int rounds):
	xr_state* st = new xr_state()
	st.ch = task_xchan_new(0)
	st.role_send = role_send
	st.timeout_ms = timeout_ms
	st.armed = 0
	st.fired = 0
	st.finished = 0
	st.completed = 0
	st.rounds = rounds
	return st


void xr_state_free(xr_state* st):
	assert_equal(0, st.ch.senders.length)
	assert_equal(0, st.ch.receivers.length)
	task_xchan_free(st.ch)
	free(cast(void*, st))


void test_late_wake_after_cancel(int role_send):
	xr_state* st = xr_state_new(role_send, -1, 40)
	task_runtime* rt = task_runtime_new(2)
	task_runtime_spawn_on(rt, 0, xr_cancel_host(st))
	task_runtime_spawn_on(rt, 1, xr_peer(st, 0))
	assert_equal(0, task_runtime_run(rt))
	assert_equal(st.rounds, st.finished)
	assert_equal(st.rounds, st.completed)
	task_runtime_free(rt)
	xr_state_free(st)


void test_late_wake_after_timeout(int role_send):
	xr_state* st = xr_state_new(role_send, 2, 150)
	task_runtime* rt = task_runtime_new(2)
	task_runtime_spawn_on(rt, 0, xr_timeout_host(st))
	task_runtime_spawn_on(rt, 1, xr_peer(st, 1))
	assert_equal(0, task_runtime_run(rt))
	assert_equal(st.rounds, st.finished)
	print(c"  rounds the peer completed: ")
	print(itoa(st.completed))
	print(c" of ")
	println(itoa(st.rounds))
	task_runtime_free(rt)
	xr_state_free(st)


int main():
	malloc_force_debug_mode()
	crash_handler_install()
	test_late_wake_after_cancel(0)
	println(c"cancelled receiver: ok")
	test_late_wake_after_cancel(1)
	println(c"cancelled sender: ok")
	test_late_wake_after_timeout(0)
	println(c"timed-out receiver: ok")
	test_late_wake_after_timeout(1)
	println(c"timed-out sender: ok")
	println(c"All tests passed!")
	return 0
