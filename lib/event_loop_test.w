# wbuild: x64
import lib.testing
import lib.net
import lib.event_loop


# Set by test_zz_poll_backend_passes_the_suite to rerun every test on
# the poll(2) backend; the default is epoll where the kernel has it.
int loop_test_force_poll


event_loop* loop_test_new():
	if (loop_test_force_poll):
		return event_loop_new_poll()
	return event_loop_new()


/* Timer callbacks record firing order in a shared log. */

struct loop_test_log:
	int count
	int first_id
	int second_id
	event_loop* loop


void loop_test_record(int timer_id, void* ctx):
	loop_test_log* log = cast(loop_test_log*, ctx)
	if (log.count == 0):
		log.first_id = timer_id
	else if (log.count == 1):
		log.second_id = timer_id
	log.count = log.count + 1


void loop_test_record_and_stop(int timer_id, void* ctx):
	loop_test_record(timer_id, ctx)
	loop_test_log* log = cast(loop_test_log*, ctx)
	event_loop_stop(log.loop)


void test_timers_fire_in_deadline_order():
	event_loop* loop = loop_test_new()
	loop_test_log* log = new loop_test_log()
	log.count = 0
	log.loop = loop

	int slow = event_loop_add_timer(loop, 40, loop_test_record_and_stop, cast(void*, log))
	int fast = event_loop_add_timer(loop, 5, loop_test_record, cast(void*, log))
	assert_equal(0, event_loop_run(loop))

	assert_equal(2, log.count)
	assert_equal(fast, log.first_id)
	assert_equal(slow, log.second_id)

	free(cast(char*, log))
	event_loop_free(loop)


void test_cancelled_timer_does_not_fire():
	event_loop* loop = loop_test_new()
	loop_test_log* log = new loop_test_log()
	log.count = 0
	log.loop = loop

	int doomed = event_loop_add_timer(loop, 5, loop_test_record, cast(void*, log))
	int keeper = event_loop_add_timer(loop, 20, loop_test_record_and_stop, cast(void*, log))
	assert_equal(1, event_loop_cancel_timer(loop, doomed))
	# Cancelling twice reports failure.
	assert_equal(0, event_loop_cancel_timer(loop, doomed))

	assert_equal(0, event_loop_run(loop))
	assert_equal(1, log.count)
	assert_equal(keeper, log.first_id)

	free(cast(char*, log))
	event_loop_free(loop)


void loop_test_count_to_three(int timer_id, void* ctx):
	loop_test_log* log = cast(loop_test_log*, ctx)
	log.count = log.count + 1
	if (log.count == 3):
		event_loop_cancel_timer(log.loop, timer_id)
		event_loop_stop(log.loop)


void test_interval_timer_repeats():
	event_loop* loop = loop_test_new()
	loop_test_log* log = new loop_test_log()
	log.count = 0
	log.loop = loop

	event_loop_add_interval(loop, 5, loop_test_count_to_three, cast(void*, log))
	assert_equal(0, event_loop_run(loop))
	assert_equal(3, log.count)

	free(cast(char*, log))
	event_loop_free(loop)


/* Descriptor callbacks. */

struct loop_test_io:
	int fd
	int revents
	int reads
	event_loop* loop


void loop_test_on_readable(int fd, int revents, void* ctx):
	loop_test_io* io = cast(loop_test_io*, ctx)
	io.fd = fd
	io.revents = revents
	io.reads = io.reads + 1
	char* buf = malloc(16)
	read(fd, buf, 16)
	free(buf)
	event_loop_remove_fd(io.loop, fd)
	event_loop_stop(io.loop)


void test_fd_callback_on_readable():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)

	event_loop* loop = loop_test_new()
	loop_test_io* io = new loop_test_io()
	io.reads = 0
	io.loop = loop
	event_loop_add_fd(loop, fds[1], poll_in(), loop_test_on_readable, cast(void*, io))

	assert_equal(4, write(fds[0], c"ping", 4))
	assert_equal(0, event_loop_run(loop))

	assert_equal(1, io.reads)
	assert_equal(fds[1], io.fd)
	assert_equal(poll_in(), io.revents & poll_in())

	free(cast(char*, io))
	event_loop_free(loop)
	close(fds[0])
	close(fds[1])
	free(fds)


/* Request timeout pattern: a timer fires because the peer never writes,
   and the response callback would have cancelled it. */

struct loop_test_timeout:
	int timed_out
	int fd
	event_loop* loop


void loop_test_on_timeout(int timer_id, void* ctx):
	loop_test_timeout* state = cast(loop_test_timeout*, ctx)
	state.timed_out = 1
	event_loop_remove_fd(state.loop, state.fd)
	event_loop_stop(state.loop)


void loop_test_unexpected_read(int fd, int revents, void* ctx):
	asserts(c"descriptor became readable but nobody wrote", 0)


void test_timeout_fires_when_peer_is_silent():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)

	event_loop* loop = loop_test_new()
	loop_test_timeout* state = new loop_test_timeout()
	state.timed_out = 0
	state.fd = fds[1]
	state.loop = loop

	event_loop_add_fd(loop, fds[1], poll_in(), loop_test_unexpected_read, cast(void*, state))
	event_loop_add_timer(loop, 30, loop_test_on_timeout, cast(void*, state))

	assert_equal(0, event_loop_run(loop))
	assert_equal(1, state.timed_out)

	free(cast(char*, state))
	event_loop_free(loop)
	close(fds[0])
	close(fds[1])
	free(fds)


void test_run_once_returns_zero_when_idle():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)

	event_loop* loop = loop_test_new()
	loop_test_io* io = new loop_test_io()
	io.reads = 0
	io.loop = loop
	event_loop_add_fd(loop, fds[1], poll_in(), loop_test_on_readable, cast(void*, io))

	assert_equal(0, event_loop_run_once(loop, 0))
	assert_equal(0, io.reads)

	free(cast(char*, io))
	event_loop_free(loop)
	close(fds[0])
	close(fds[1])
	free(fds)


void test_run_returns_when_nothing_is_watched():
	event_loop* loop = loop_test_new()
	assert_equal(0, event_loop_run(loop))
	event_loop_free(loop)


/* Backend-specific behavior. */

void test_linux_uses_epoll():
	event_loop* loop = event_loop_new()
	assert_equal(1, event_loop_uses_epoll(loop))
	event_loop_free(loop)
	loop = event_loop_new_poll()
	assert_equal(0, event_loop_uses_epoll(loop))
	event_loop_free(loop)


struct loop_test_pair:
	int in_revents
	int out_revents
	int calls
	event_loop* loop


void loop_test_record_in(int fd, int revents, void* ctx):
	loop_test_pair* p = cast(loop_test_pair*, ctx)
	p.in_revents = revents
	p.calls = p.calls + 1
	event_loop_remove_fd(p.loop, fd)


void loop_test_record_out(int fd, int revents, void* ctx):
	loop_test_pair* p = cast(loop_test_pair*, ctx)
	p.out_revents = revents
	p.calls = p.calls + 1


# Two watches on one fd each see their own interest bits.
void test_two_watches_share_an_fd():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	event_loop* loop = loop_test_new()
	loop_test_pair* p = new loop_test_pair()
	p.in_revents = 0
	p.out_revents = 0
	p.calls = 0
	p.loop = loop
	event_loop_add_watch(loop, fds[1], poll_in(), loop_test_record_in, cast(void*, p))
	event_watch* out = event_loop_add_watch(loop, fds[1], poll_out(), loop_test_record_out, cast(void*, p))
	assert_equal(4, write(fds[0], c"ping", 4))
	assert_equal(2, event_loop_run_once(loop, 1000))
	assert_equal(poll_in(), p.in_revents)
	assert_equal(poll_out(), p.out_revents)
	# The reader removed itself; the writer keeps firing alone.
	event_loop_run_once(loop, 1000)
	assert_equal(3, p.calls)
	event_loop_remove_watch(loop, out)
	assert_equal(0, event_loop_watch_count(loop))
	free(cast(char*, p))
	event_loop_free(loop)
	close(fds[0])
	close(fds[1])
	free(fds)


void loop_test_count_ready(int fd, int revents, void* ctx):
	loop_test_io* io = cast(loop_test_io*, ctx)
	io.revents = revents
	io.reads = io.reads + 1


# poll reports regular files as always ready and closed descriptors as
# POLLNVAL; the epoll backend (which refuses both) fakes the same.
void test_file_and_closed_fd_revents():
	int file = open(c"/proc/self/stat", 0, 0)
	asserts(c"open /proc/self/stat", file >= 0)
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	# The loop first: its epoll fd would otherwise take the closed number.
	event_loop* loop = loop_test_new()
	int closed_fd = fds[0]
	close(closed_fd)
	loop_test_io* ready = new loop_test_io()
	ready.reads = 0
	ready.revents = 0
	loop_test_io* nval = new loop_test_io()
	nval.reads = 0
	nval.revents = 0
	event_loop_add_fd(loop, file, poll_in(), loop_test_count_ready, cast(void*, ready))
	event_loop_add_fd(loop, closed_fd, poll_in(), loop_test_count_ready, cast(void*, nval))
	event_loop_run_once(loop, 1000)
	event_loop_run_once(loop, 1000)
	assert_equal(2, ready.reads)
	assert_equal(poll_in(), ready.revents & poll_in())
	assert_equal(2, nval.reads)
	assert_equal(poll_nval(), nval.revents & poll_nval())
	free(cast(char*, ready))
	free(cast(char*, nval))
	event_loop_free(loop)
	close(file)
	close(fds[1])
	free(fds)


struct loop_test_reuse:
	event_loop* loop
	int first_fd
	int second_fd
	int peer
	int second_reads


void loop_test_second_readable(int fd, int revents, void* ctx):
	loop_test_reuse* r = cast(loop_test_reuse*, ctx)
	r.second_reads = r.second_reads + 1
	event_loop_remove_fd(r.loop, fd)


# The first watch fires, removes itself and closes its fd; a new socket
# reusing that fd number is watched from the same callback. The loop
# must not keep the dead registration's cached interest mask.
void loop_test_first_readable(int fd, int revents, void* ctx):
	loop_test_reuse* r = cast(loop_test_reuse*, ctx)
	event_loop_remove_fd(r.loop, fd)
	close(fd)
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	r.second_fd = fds[0]
	r.peer = fds[1]
	free(fds)
	event_loop_add_fd(r.loop, r.second_fd, poll_in(), loop_test_second_readable, ctx)
	assert_equal(1, write(r.peer, c"x", 1))


void test_fd_number_reuse_after_close():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	event_loop* loop = loop_test_new()
	loop_test_reuse* r = new loop_test_reuse()
	r.loop = loop
	r.first_fd = fds[0]
	r.second_reads = 0
	event_loop_add_fd(loop, fds[0], poll_in(), loop_test_first_readable, cast(void*, r))
	assert_equal(1, write(fds[1], c"x", 1))
	assert_equal(0, event_loop_run(loop))
	assert_equal(r.first_fd, r.second_fd)
	assert_equal(1, r.second_reads)
	close(r.second_fd)
	close(r.peer)
	close(fds[1])
	free(cast(char*, r))
	free(fds)
	event_loop_free(loop)


struct loop_test_timer_log:
	list[int] fired
	list[int] due


void loop_test_log_timer(int timer_id, void* ctx):
	loop_test_timer_log* log = cast(loop_test_timer_log*, ctx)
	log.fired.push(timer_id)


# Many timers: cancelled ones never fire, the rest fire in deadline
# order (ties in arming order).
void test_many_timers_fire_in_order():
	event_loop* loop = loop_test_new()
	loop_test_timer_log* log = new loop_test_timer_log()
	log.fired = new list[int]
	log.due = new list[int]
	list[int] ids = new list[int]
	int i = 0
	while (i < 300):
		int delay = (i * 7919) % 23
		int id = event_loop_add_timer(loop, delay, loop_test_log_timer, cast(void*, log))
		ids.push(id)
		# The absolute deadline (the clock may tick while arming).
		event_timer* armed = loop.timer_ids[id]
		log.due.push(armed.fire_at_ms)
		i = i + 1
	int cancelled = 0
	i = 0
	while (i < 300):
		if ((i % 3) == 0):
			assert_equal(1, event_loop_cancel_timer(loop, ids[i]))
			cancelled = cancelled + 1
		i = i + 1
	assert_equal(0, event_loop_cancel_timer(loop, ids[0]))
	assert_equal(300 - cancelled, event_loop_timer_count(loop))
	assert_equal(0, event_loop_run(loop))
	assert_equal(300 - cancelled, log.fired.length)
	i = 1
	while (i < log.fired.length):
		int prev = log.fired[i - 1]
		int cur = log.fired[i]
		asserts(c"cancelled timer fired", ((cur - ids[0]) % 3) != 0)
		int prev_due = log.due[prev - ids[0]]
		int cur_due = log.due[cur - ids[0]]
		int order = cur_due - prev_due
		asserts(c"timers fired out of order", (order > 0) || ((order == 0) && (prev < cur)))
		i = i + 1
	list_free[int](ids)
	list_free[int](log.fired)
	list_free[int](log.due)
	free(cast(char*, log))
	event_loop_free(loop)


# Last by name: rerun everything on the poll backend.
void test_zz_poll_backend_passes_the_suite():
	loop_test_force_poll = 1
	test_timers_fire_in_deadline_order()
	test_cancelled_timer_does_not_fire()
	test_interval_timer_repeats()
	test_fd_callback_on_readable()
	test_timeout_fires_when_peer_is_silent()
	test_run_once_returns_zero_when_idle()
	test_run_returns_when_nothing_is_watched()
	test_two_watches_share_an_fd()
	test_file_and_closed_fd_revents()
	test_fd_number_reuse_after_close()
	test_many_timers_fire_in_order()
	loop_test_force_poll = 0
