# wbuild: x64
import lib.testing
import lib.net
import lib.event_sim
import libs.standard.distributed.prng


/*
Event loops on a virtual clock and scripted readiness (lib/event_sim.w),
plus dispatch fairness on the real poll and epoll backends.
*/


# Records (callback kind, id, virtual ms) triples in firing order.
struct sim_test_log:
	event_loop* loop
	wclock* clock
	list[int] ids
	list[int] times
	int stop_after          # stop the loop after this many records (0: never)
	int jump_ms             # wall jump applied by sim_test_jump_wall


sim_test_log* sim_test_log_new(event_loop* loop, wclock* clock):
	sim_test_log* log = new sim_test_log()
	log.loop = loop
	log.clock = clock
	log.ids = new list[int]
	log.times = new list[int]
	log.stop_after = 0
	log.jump_ms = 0
	return log


void sim_test_log_free(sim_test_log* log):
	list_free[int](log.ids)
	list_free[int](log.times)
	free(log)


void sim_test_record(sim_test_log* log, int id):
	int now = 0
	assert_equal(IO_OK, wclock_monotonic_ms(log.clock, &now))
	log.ids.push(id)
	log.times.push(now)
	if ((log.stop_after > 0) && (log.ids.length >= log.stop_after)): event_loop_stop(log.loop)


void sim_test_on_timer(int timer_id, void* ctx):
	sim_test_record(cast(sim_test_log*, ctx), 1000 + timer_id)


void sim_test_on_fd(int fd, int revents, void* ctx):
	sim_test_record(cast(sim_test_log*, ctx), fd)


void sim_test_jump_wall(int fd, int revents, void* ctx):
	sim_test_log* log = cast(sim_test_log*, ctx)
	wclock_virtual_jump_wall_ms(log.clock, log.jump_ms)
	sim_test_record(log, fd)


# A 10-minute timer completes at once: virtual time skips to deadlines.
void test_timers_fire_at_virtual_deadlines():
	wclock* clock = wclock_virtual_new(1700000000)
	event_sim* sim = event_sim_new(clock)
	event_loop* loop = event_loop_new_with(clock, event_sim_poller(sim))
	assert_equal(0, event_loop_uses_epoll(loop))
	sim_test_log* log = sim_test_log_new(loop, clock)
	int long_id = event_loop_add_timer(loop, 600000, sim_test_on_timer, cast(void*, log))
	int short_id = event_loop_add_timer(loop, 25, sim_test_on_timer, cast(void*, log))
	int real_before = time_monotonic_ms()
	assert_equal(0, event_loop_run(loop))
	assert1((time_monotonic_ms() - real_before) < 5000)
	assert_equal(2, log.ids.length)
	assert_equal(1000 + short_id, log.ids[0])
	assert_equal(25, log.times[0])
	assert_equal(1000 + long_id, log.ids[1])
	assert_equal(600000, log.times[1])
	assert_equal(600000, sim.advanced_ms)
	sim_test_log_free(log)
	event_loop_free(loop)
	event_sim_free(sim)
	wclock_free(clock)


# Scripted readiness arrives at its virtual time, interleaved with timers.
void test_scripted_events_and_timers_interleave():
	wclock* clock = wclock_virtual_new(0)
	event_sim* sim = event_sim_new(clock)
	event_loop* loop = event_loop_new_with(clock, event_sim_poller(sim))
	sim_test_log* log = sim_test_log_new(loop, clock)
	event_loop_add_fd(loop, 7, poll_in, sim_test_on_fd, cast(void*, log))
	event_loop_add_fd(loop, 9, poll_out, sim_test_on_fd, cast(void*, log))
	event_sim_at(sim, 40, 7, poll_in)
	event_sim_at(sim, 10, 9, poll_out)
	# Interest mismatch: fd 9 is not watched for input, so this never fires.
	event_sim_at(sim, 20, 9, poll_in)
	int t = event_loop_add_timer(loop, 30, sim_test_on_timer, cast(void*, log))
	log.stop_after = 3
	assert_equal(0, event_loop_run(loop))
	assert_equal(3, log.ids.length)
	assert_equal(9, log.ids[0])
	assert_equal(10, log.times[0])
	assert_equal(1000 + t, log.ids[1])
	assert_equal(30, log.times[1])
	assert_equal(7, log.ids[2])
	assert_equal(40, log.times[2])
	assert_equal(1, event_sim_pending(sim))
	sim_test_log_free(log)
	event_loop_free(loop)
	event_sim_free(sim)
	wclock_free(clock)


# Nothing scripted, no timer, a watch armed: the wait can never return.
void test_idle_simulation_reports_deadlock():
	wclock* clock = wclock_virtual_new(0)
	event_sim* sim = event_sim_new(clock)
	event_loop* loop = event_loop_new_with(clock, event_sim_poller(sim))
	sim_test_log* log = sim_test_log_new(loop, clock)
	event_loop_add_fd(loop, 3, poll_in, sim_test_on_fd, cast(void*, log))
	assert_equal(0 - EVENT_SIM_EDEADLK, event_loop_run(loop))
	assert_equal(0, log.ids.length)
	sim_test_log_free(log)
	event_loop_free(loop)
	event_sim_free(sim)
	wclock_free(clock)


# Wall time stepped an hour backwards (then forwards) while a timer is
# armed: the deadline is on the monotonic line and does not move.
void test_wall_clock_jump_does_not_extend_timer_deadline():
	int[2] jumps
	jumps[0] = 0 - 3600 * 1000
	jumps[1] = 3600 * 1000
	for j in range(2):
		wclock* clock = wclock_virtual_new(1700000000)
		event_sim* sim = event_sim_new(clock)
		event_loop* loop = event_loop_new_with(clock, event_sim_poller(sim))
		sim_test_log* log = sim_test_log_new(loop, clock)
		log.jump_ms = jumps[j]
		event_loop_add_fd(loop, 4, poll_in, sim_test_jump_wall, cast(void*, log))
		event_sim_at(sim, 100, 4, poll_in)
		int t = event_loop_add_timer(loop, 1000, sim_test_on_timer, cast(void*, log))
		log.stop_after = 2
		assert_equal(0, event_loop_run(loop))
		assert_equal(2, log.ids.length)
		assert_equal(100, log.times[0])
		assert_equal(1000 + t, log.ids[1])
		assert_equal(1000, log.times[1])
		wtime wall
		assert_equal(IO_OK, wclock_wall(clock, &wall))
		assert_equal(1700000001 + jumps[j] / 1000, wall.sec)
		sim_test_log_free(log)
		event_loop_free(loop)
		event_sim_free(sim)
		wclock_free(clock)


# A failed monotonic reading holds time still instead of firing early.
void test_clock_failure_holds_time():
	wclock* clock = wclock_virtual_new(0)
	event_sim* sim = event_sim_new(clock)
	event_loop* loop = event_loop_new_with(clock, event_sim_poller(sim))
	sim_test_log* log = sim_test_log_new(loop, clock)
	event_loop_add_timer(loop, 50, sim_test_on_timer, cast(void*, log))
	wclock_virtual_advance_ms(clock, 60)
	wclock_virtual_fail(clock, WCLOCK_MONOTONIC, IO_IO_ERROR)
	assert_equal(0, event_loop_run_once(loop, 0))
	assert1(loop.clock_errors > 0)
	wclock_virtual_fail(clock, WCLOCK_MONOTONIC, IO_OK)
	assert_equal(1, event_loop_run_once(loop, 0))
	assert_equal(60, log.times[0])
	sim_test_log_free(log)
	event_loop_free(loop)
	event_sim_free(sim)
	wclock_free(clock)


# One run's (id, time) trace folded into one number.
int sim_test_scenario(int seed):
	wclock* clock = wclock_virtual_new(0)
	event_sim* sim = event_sim_new(clock)
	event_loop* loop = event_loop_new_with(clock, event_sim_poller(sim))
	sim_test_log* log = sim_test_log_new(loop, clock)
	prng* rng = prng_new(seed)
	for fd in range(3, 9): event_loop_add_fd(loop, fd, poll_in, sim_test_on_fd, cast(void*, log))
	for i in range(40): event_sim_at(sim, prng_range(rng, 500), 3 + prng_range(rng, 6), poll_in)
	for i in range(5): event_loop_add_timer(loop, prng_range(rng, 500), sim_test_on_timer, cast(void*, log))
	log.stop_after = 30
	assert_equal(0, event_loop_run(loop))
	int h = 0
	for i in range(log.ids.length): h = (h * 31 + log.ids[i] * 7 + log.times[i]) & prng_mask31()
	prng_free(rng)
	sim_test_log_free(log)
	event_loop_free(loop)
	event_sim_free(sim)
	wclock_free(clock)
	return h


void test_same_script_same_trace():
	assert_equal(sim_test_scenario(11), sim_test_scenario(11))
	assert_equal(sim_test_scenario(12), sim_test_scenario(12))
	assert1(sim_test_scenario(11) != sim_test_scenario(12))


/* Fairness. */

struct fair_test:
	event_loop* loop
	list[int] order
	map[int, int] served


void fair_test_on_fd(int fd, int revents, void* ctx):
	fair_test* f = cast(fair_test*, ctx)
	f.order.push(fd)
	if (fd in f.served): f.served[fd] = f.served[fd] + 1
	else: f.served[fd] = 1


fair_test* fair_test_new(event_loop* loop):
	fair_test* f = new fair_test()
	f.loop = loop
	f.order = new list[int]
	f.served = new map[int, int]
	return f


void fair_test_free(fair_test* f):
	list_free[int](f.order)
	f.served.free()
	free(f)


# The default is unbounded: one pass serves every ready descriptor.
void test_default_dispatch_is_unbounded():
	wclock* clock = wclock_virtual_new(0)
	event_sim* sim = event_sim_new(clock)
	event_loop* loop = event_loop_new_with(clock, event_sim_poller(sim))
	fair_test* f = fair_test_new(loop)
	for fd in range(10, 20):
		event_loop_add_fd(loop, fd, poll_in, fair_test_on_fd, cast(void*, f))
		event_sim_set_ready(sim, fd, poll_in)
	assert_equal(10, event_loop_run_once(loop, 0))
	for i in range(10): assert_equal(10 + i, f.order[i])
	fair_test_free(f)
	event_loop_free(loop)
	event_sim_free(sim)
	wclock_free(clock)


# Ten always-ready descriptors, three callbacks per pass: every
# descriptor is served once before any is served twice.
void test_fd_limit_rotates_without_starvation():
	wclock* clock = wclock_virtual_new(0)
	event_sim* sim = event_sim_new(clock)
	event_loop* loop = event_loop_new_with(clock, event_sim_poller(sim))
	event_loop_set_dispatch_limits(loop, 0, 3)
	fair_test* f = fair_test_new(loop)
	for fd in range(10, 20):
		event_loop_add_fd(loop, fd, poll_in, fair_test_on_fd, cast(void*, f))
		event_sim_set_ready(sim, fd, poll_in)
	for pass in range(4):
		int n = event_loop_run_once(loop, 0)
		assert1(n <= 3)
	assert_equal(12, f.order.length)
	for i in range(10): assert_equal(10 + i, f.order[i])
	assert_equal(10, f.order[10])
	assert_equal(11, f.order[11])
	for fd in range(10, 20): assert1(fd in f.served)
	fair_test_free(f)
	event_loop_free(loop)
	event_sim_free(sim)
	wclock_free(clock)


# Five timers due at once, two per pass: 2, 2, 1, in deadline order.
void test_timer_limit_carries_due_timers_over():
	wclock* clock = wclock_virtual_new(0)
	event_sim* sim = event_sim_new(clock)
	event_loop* loop = event_loop_new_with(clock, event_sim_poller(sim))
	event_loop_set_dispatch_limits(loop, 2, 0)
	sim_test_log* log = sim_test_log_new(loop, clock)
	int first = event_loop_add_timer(loop, 5, sim_test_on_timer, cast(void*, log))
	for i in range(4): event_loop_add_timer(loop, 5, sim_test_on_timer, cast(void*, log))
	assert_equal(2, event_loop_run_once(loop, -1))
	assert_equal(2, event_loop_run_once(loop, -1))
	assert_equal(1, event_loop_run_once(loop, -1))
	assert_equal(5, log.ids.length)
	for i in range(5):
		assert_equal(1000 + first + i, log.ids[i])
		assert_equal(5, log.times[i])
	# The leftover passes did not wait: still t = 5.
	assert_equal(5, event_sim_now(sim))
	sim_test_log_free(log)
	event_loop_free(loop)
	event_sim_free(sim)
	wclock_free(clock)


# Real descriptors: six readable sockets, two callbacks per pass, on
# both backends. Within three passes every socket has been served.
void fair_test_real_backend(int use_epoll):
	event_loop* loop = event_loop_new_poll()
	if (use_epoll):
		event_loop_free(loop)
		loop = event_loop_new()
		if (event_loop_uses_epoll(loop) == 0):
			event_loop_free(loop)
			return
	event_loop_set_dispatch_limits(loop, 0, 2)
	fair_test* f = fair_test_new(loop)
	list[int] peers = new list[int]
	list[int] ends = new list[int]
	int* fds = cast(int*, malloc(__word_size__ * 2))
	for i in range(6):
		asserts(c"socket_pair failed", socket_pair(fds) >= 0)
		assert_equal(1, write(fds[0], c"x", 1))
		peers.push(fds[0])
		ends.push(fds[1])
		event_loop_add_fd(loop, fds[1], poll_in, fair_test_on_fd, cast(void*, f))
	for round in range(3): assert_equal(2, event_loop_run_once(loop, 1000))
	assert_equal(6, f.order.length)
	for i in range(6): assert_equal(1, f.served[ends[i]])
	for i in range(6):
		event_loop_remove_fd(loop, ends[i])
	event_loop_free(loop)
	for i in range(6):
		close(peers[i])
		close(ends[i])
	free(fds)
	list_free[int](peers)
	list_free[int](ends)
	fair_test_free(f)


void test_fd_limit_is_fair_on_poll_backend():
	fair_test_real_backend(0)


void test_fd_limit_is_fair_on_epoll_backend():
	fair_test_real_backend(1)
