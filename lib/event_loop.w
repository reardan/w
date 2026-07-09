# Single-threaded poll(2) event loop with monotonic timers.
#
# Descriptors are watched with a callback per fd; timers are one-shot or
# repeating and can be cancelled by id, which is how request timeouts and
# cancellation work: schedule a timer that fails the operation, cancel it
# when the response arrives. W has no closures, so callbacks are plain
# functions taking an explicit context pointer.
import lib.lib
import lib.poll
import lib.time
import lib.math
import lib.container


# fd, revents, context
type event_fd_cb = fn(int, int, void*) -> void

# timer id, context
type event_timer_cb = fn(int, void*) -> void


# Watches and timers both start with the active flag so bookkeeping that
# only needs that flag can treat them uniformly.
struct event_entry:
	int active


struct event_watch:
	int active
	int fd
	int events
	event_fd_cb* callback
	void* context


struct event_timer:
	int active
	int id
	int fire_at_ms
	int interval_ms
	event_timer_cb* callback
	void* context


struct event_loop:
	list[event_watch*] watches
	list[event_timer*] timers
	int next_timer_id
	int running


event_loop* event_loop_new():
	event_loop* loop = new event_loop()
	loop.watches = new list[event_watch*]
	loop.timers = new list[event_timer*]
	loop.next_timer_id = 1
	loop.running = 0
	return loop


void event_loop_free(event_loop* loop):
	int i = 0
	while (i < loop.watches.length):
		free(cast(char*, loop.watches[i]))
		i = i + 1
	i = 0
	while (i < loop.timers.length):
		free(cast(char*, loop.timers[i]))
		i = i + 1
	list_free[event_watch*](loop.watches)
	list_free[event_timer*](loop.timers)
	free(loop)


event_watch* event_loop_find_watch(event_loop* loop, int fd):
	int i = 0
	while (i < loop.watches.length):
		event_watch* watch = loop.watches[i]
		if ((watch.fd == fd) & watch.active):
			return watch
		i = i + 1
	return 0


void event_loop_add_fd(event_loop* loop, int fd, int events, event_fd_cb* callback, void* context):
	event_watch* watch = new event_watch()
	watch.fd = fd
	watch.events = events
	watch.callback = callback
	watch.context = context
	watch.active = 1
	loop.watches.push(watch)


# Changes the interest mask of an existing watch.
int event_loop_modify_fd(event_loop* loop, int fd, int events):
	event_watch* watch = event_loop_find_watch(loop, fd)
	if (cast(int, watch) == 0):
		return 0
	watch.events = events
	return 1


# Safe to call from inside a callback: the watch is only marked inactive
# and physically removed after the current dispatch pass.
int event_loop_remove_fd(event_loop* loop, int fd):
	event_watch* watch = event_loop_find_watch(loop, fd)
	if (cast(int, watch) == 0):
		return 0
	watch.active = 0
	return 1


int event_loop_add_timer_full(event_loop* loop, int delay_ms, int interval_ms, event_timer_cb* callback, void* context):
	event_timer* timer = new event_timer()
	timer.id = loop.next_timer_id
	loop.next_timer_id = loop.next_timer_id + 1
	timer.fire_at_ms = time_monotonic_ms() + delay_ms
	timer.interval_ms = interval_ms
	timer.callback = callback
	timer.context = context
	timer.active = 1
	loop.timers.push(timer)
	return timer.id


# One-shot timer; returns an id usable with event_loop_cancel_timer.
int event_loop_add_timer(event_loop* loop, int delay_ms, event_timer_cb* callback, void* context):
	return event_loop_add_timer_full(loop, delay_ms, 0, callback, context)


# Repeating timer with a fixed interval.
int event_loop_add_interval(event_loop* loop, int interval_ms, event_timer_cb* callback, void* context):
	return event_loop_add_timer_full(loop, interval_ms, interval_ms, callback, context)


# Returns 1 when the timer existed and was cancelled before firing.
int event_loop_cancel_timer(event_loop* loop, int timer_id):
	int i = 0
	while (i < loop.timers.length):
		event_timer* timer = loop.timers[i]
		if ((timer.id == timer_id) & timer.active):
			timer.active = 0
			return 1
		i = i + 1
	return 0


void event_loop_stop(event_loop* loop):
	loop.running = 0


# Drops entries marked inactive. Never called during dispatch.
void event_loop_compact[T](event_loop* loop, list[T] entries):
	int i = 0
	while (i < entries.length):
		event_entry* entry = cast(event_entry*, entries[i])
		if (entry.active == 0):
			free(cast(char*, entry))
			list_remove_at[T](entries, i)
		else:
			i = i + 1


int event_loop_active_count[T](event_loop* loop, list[T] entries):
	int count = 0
	int i = 0
	while (i < entries.length):
		event_entry* entry = cast(event_entry*, entries[i])
		if (entry.active):
			count = count + 1
		i = i + 1
	return count


# Milliseconds until the next active timer fires (0 when already due),
# or -1 when no timer is scheduled. Uses signed differences so the
# wrapping 32-bit monotonic clock stays correct.
int event_loop_next_timer_delay(event_loop* loop):
	int found = 0
	int best = 0
	int now = time_monotonic_ms()
	int i = 0
	while (i < loop.timers.length):
		event_timer* timer = loop.timers[i]
		if (timer.active):
			int delay = timer.fire_at_ms - now
			if (delay < 0):
				delay = 0
			if ((found == 0) | (delay < best)):
				best = delay
			found = 1
		i = i + 1
	if (found == 0):
		return -1
	return best


# Fires timers whose deadline has passed. One-shot timers deactivate
# before their callback runs; intervals reschedule. Returns fired count.
int event_loop_fire_due_timers(event_loop* loop):
	int fired = 0
	int now = time_monotonic_ms()
	int i = 0
	while (i < loop.timers.length):
		event_timer* timer = loop.timers[i]
		int due = timer.fire_at_ms - now
		if (timer.active & (due <= 0)):
			if (timer.interval_ms > 0):
				timer.fire_at_ms = now + timer.interval_ms
			else:
				timer.active = 0
			timer.callback(timer.id, timer.context)
			fired = fired + 1
		i = i + 1
	return fired


# Runs one poll iteration: waits at most max_wait_ms (or less when a
# timer is due sooner; -1 waits indefinitely), fires due timers, then
# dispatches fd callbacks. Returns callbacks fired, or a negative errno.
int event_loop_run_once(event_loop* loop, int max_wait_ms):
	event_loop_compact[event_watch*](loop, loop.watches)
	event_loop_compact[event_timer*](loop, loop.timers)

	int timeout = max_wait_ms
	int timer_delay = event_loop_next_timer_delay(loop)
	if (timer_delay >= 0):
		if (timeout < 0):
			timeout = timer_delay
		else:
			timeout = min(timeout, timer_delay)

	int watch_count = loop.watches.length
	pollfd* fds = 0
	if (watch_count > 0):
		fds = pollfd_new_array(watch_count)
		int i = 0
		while (i < watch_count):
			event_watch* watch = loop.watches[i]
			pollfd_set(fds, i, watch.fd, watch.events)
			i = i + 1

	int ready = poll_wait(fds, watch_count, timeout)
	if (ready < 0):
		if (cast(int, fds) != 0):
			free(cast(char*, fds))
		# EINTR is not an error for the loop; report zero work instead.
		if (ready == -4):
			return 0
		return ready

	int fired = event_loop_fire_due_timers(loop)

	int i = 0
	while (i < watch_count):
		event_watch* watch = loop.watches[i]
		pollfd* entry = pollfd_at(fds, i)
		int revents = entry.revents
		if (watch.active & (revents != 0)):
			watch.callback(watch.fd, revents, watch.context)
			fired = fired + 1
		i = i + 1

	if (cast(int, fds) != 0):
		free(cast(char*, fds))
	return fired


# Runs until event_loop_stop() or until no active watches or timers
# remain. Returns 0 on a normal stop or a negative errno from poll.
int event_loop_run(event_loop* loop):
	loop.running = 1
	while (loop.running):
		if ((event_loop_active_count[event_watch*](loop, loop.watches) == 0) & (event_loop_active_count[event_timer*](loop, loop.timers) == 0)):
			loop.running = 0
			return 0
		int result = event_loop_run_once(loop, -1)
		if (result < 0):
			loop.running = 0
			return result
	return 0
