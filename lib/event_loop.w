# Single-threaded readiness event loop with monotonic timers.
#
# Descriptors are watched with a callback per fd; timers are one-shot or
# repeating and can be cancelled by id, which is how request timeouts and
# cancellation work: schedule a timer that fails the operation, cancel it
# when the response arrives. W has no closures, so callbacks are plain
# functions taking an explicit context pointer.
#
# Backends: epoll(7) on Linux (x86, x86-64, arm64), where each wait costs
# O(ready descriptors) and interest changes are applied incrementally;
# poll(2) everywhere else (or when epoll_create1 fails), which rebuilds
# the pollfd array every iteration. Both are level-triggered and deliver
# the same revents bits (POLLIN/POLLOUT/POLLERR/POLLHUP; POLLNVAL for a
# descriptor that is not open). event_loop_new_poll forces the poll
# backend. Timers live in a binary heap ordered by deadline, so arming,
# cancelling and firing are O(log n) whatever the timer count.
#
# One caveat of the epoll backend: close a descriptor only after its
# watches were removed (or in the same callback that removes them). A
# registration whose descriptor was dup'd elsewhere outlives close(2) in
# the kernel.
import lib.lib
import lib.poll
import lib.time
import lib.math
import lib.container
import structures.heap


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
	int pass            # loop pass that added it (epoll dispatch skips new watches)


struct event_timer:
	int active
	int id
	int fire_at_ms
	int interval_ms
	event_timer_cb* callback
	void* context


# epoll backend: every watched fd has a slot holding its watches and the
# interest mask currently registered with the kernel.
struct event_fd_slot:
	int fd
	int registered      # mask in the kernel's interest list, 0 when absent
	int dirty           # queued for a mask resync before the next wait
	int synthetic       # nonzero: epoll refused the fd; revents to fake
	int live            # active watches
	list[event_watch*] watches


struct event_loop:
	list[event_watch*] watches      # poll backend only
	heap[event_timer*]* timer_heap  # every armed timer, cancelled ones lazily dropped
	map[int, event_timer*] timer_ids
	int next_timer_id
	int running
	int watch_count                 # active watches
	int timer_count                 # active timers
	int pass
	# epoll backend
	int epfd                        # -1: poll backend
	event_fd_slot** slots           # indexed by fd
	int slot_capacity
	list[event_fd_slot*] dirty
	list[event_fd_slot*] synthetic
	char* events                    # epoll_wait output buffer
	int event_capacity


# Deadline order; equal deadlines fire in arming (id) order. Signed
# differences keep the wrapping 32-bit monotonic clock correct.
int event_timer_compare(int a, int b):
	event_timer* x = cast(event_timer*, a)
	event_timer* y = cast(event_timer*, b)
	int d = x.fire_at_ms - y.fire_at_ms
	if (d != 0):
		return d
	return x.id - y.id


event_loop* event_loop_new_poll():
	event_loop* loop = new event_loop()
	loop.watches = new list[event_watch*]
	loop.timer_heap = heap_new_by[event_timer*](event_timer_compare)
	loop.timer_ids = new map[int, event_timer*]
	loop.next_timer_id = 1
	loop.running = 0
	loop.watch_count = 0
	loop.timer_count = 0
	loop.pass = 0
	loop.epfd = -1
	loop.slots = 0
	loop.slot_capacity = 0
	loop.dirty = new list[event_fd_slot*]
	loop.synthetic = new list[event_fd_slot*]
	loop.events = 0
	loop.event_capacity = 0
	return loop


# EPOLL_CLOEXEC
int event_loop_epoll_cloexec():
	return 524288


event_loop* event_loop_new():
	event_loop* loop = event_loop_new_poll()
	int epfd = epoll_create1(event_loop_epoll_cloexec())
	if (epfd >= 0):
		loop.epfd = epfd
		loop.event_capacity = 256
		loop.events = malloc(loop.event_capacity * epoll_event_bytes())
	return loop


# 1 when the loop uses epoll, 0 for poll.
int event_loop_uses_epoll(event_loop* loop):
	return loop.epfd >= 0


void event_loop_free(event_loop* loop):
	int i = 0
	while (i < loop.watches.length):
		free(cast(char*, loop.watches[i]))
		i = i + 1
	i = 0
	while (i < loop.timer_heap.length):
		free(cast(char*, loop.timer_heap.items[i]))
		i = i + 1
	i = 0
	while (i < loop.slot_capacity):
		event_fd_slot* slot = loop.slots[i]
		if (cast(int, slot) != 0):
			int j = 0
			while (j < slot.watches.length):
				free(cast(char*, slot.watches[j]))
				j = j + 1
			list_free[event_watch*](slot.watches)
			free(cast(char*, slot))
		i = i + 1
	if (cast(int, loop.slots) != 0):
		free(cast(char*, loop.slots))
	if (loop.epfd >= 0):
		close(loop.epfd)
		free(loop.events)
	list_free[event_watch*](loop.watches)
	list_free[event_fd_slot*](loop.dirty)
	list_free[event_fd_slot*](loop.synthetic)
	heap_free[event_timer*](loop.timer_heap)
	loop.timer_ids.free()
	free(loop)


/* epoll interest bookkeeping. */

int event_epoll_ctl_add():
	return 1


int event_epoll_ctl_del():
	return 2


int event_epoll_ctl_mod():
	return 3


event_fd_slot* event_loop_slot(event_loop* loop, int fd):
	if (fd >= loop.slot_capacity):
		int capacity = loop.slot_capacity * 2
		if (capacity < 64):
			capacity = 64
		while (capacity <= fd):
			capacity = capacity * 2
		event_fd_slot** grown = cast(event_fd_slot**, malloc(capacity * __word_size__))
		int i = 0
		while (i < capacity):
			if (i < loop.slot_capacity):
				grown[i] = loop.slots[i]
			else:
				grown[i] = 0
			i = i + 1
		if (cast(int, loop.slots) != 0):
			free(cast(char*, loop.slots))
		loop.slots = grown
		loop.slot_capacity = capacity
	event_fd_slot* slot = loop.slots[fd]
	if (cast(int, slot) == 0):
		slot = new event_fd_slot()
		slot.fd = fd
		slot.registered = 0
		slot.dirty = 0
		slot.synthetic = 0
		slot.live = 0
		slot.watches = new list[event_watch*]
		loop.slots[fd] = slot
	return slot


event_fd_slot* event_loop_find_slot(event_loop* loop, int fd):
	if ((fd < 0) || (fd >= loop.slot_capacity)):
		return 0
	return loop.slots[fd]


int event_loop_epoll_ctl(event_loop* loop, int op, int fd, int events):
	int size = epoll_event_bytes()
	char* ev = malloc(size)
	int i = 0
	while (i < size):
		ev[i] = 0
		i = i + 1
	int* mask = cast(int*, ev)
	mask[0] = events
	int* data = cast(int*, ev + epoll_event_data_offset())
	data[0] = fd
	int r = epoll_ctl(loop.epfd, op, fd, cast(int, ev))
	free(ev)
	return r


void event_loop_mark_dirty(event_loop* loop, event_fd_slot* slot):
	if (slot.dirty == 0):
		slot.dirty = 1
		loop.dirty.push(slot)


# A watch became inactive: drop the kernel registration at once when it
# was the fd's last one, so a close(2) plus fd-number reuse before the
# next wait cannot leave a stale mask cached here.
void event_loop_slot_watch_gone(event_loop* loop, event_fd_slot* slot):
	slot.live = slot.live - 1
	if (slot.live == 0):
		if (slot.registered != 0):
			event_loop_epoll_ctl(loop, event_epoll_ctl_del(), slot.fd, 0)
			slot.registered = 0
		slot.synthetic = 0
	event_loop_mark_dirty(loop, slot)


# Bring one slot's kernel registration in line with its active watches
# and free its removed watches (only ever done between dispatch passes).
void event_loop_sync_slot(event_loop* loop, event_fd_slot* slot):
	slot.dirty = 0
	int mask = 0
	int i = 0
	while (i < slot.watches.length):
		event_watch* w = slot.watches[i]
		if (w.active == 0):
			free(cast(char*, w))
			list_remove_at[event_watch*](slot.watches, i)
		else:
			mask = mask | w.events
			i = i + 1
	if (slot.live == 0):
		return
	# POLLERR/POLLHUP are always reported; register at least one bit so
	# a watch with an empty mask still hears about them.
	int want = mask | poll_err() | poll_hup()
	if (slot.synthetic != 0):
		slot.synthetic = (want & (poll_in() | poll_out())) | (slot.synthetic & poll_nval())
		return
	if (want == slot.registered):
		return
	int r = 0
	if (slot.registered == 0):
		r = event_loop_epoll_ctl(loop, event_epoll_ctl_add(), slot.fd, want)
		if (r == -17): /* EEXIST: still registered from a dup'd fd */
			r = event_loop_epoll_ctl(loop, event_epoll_ctl_mod(), slot.fd, want)
	else:
		r = event_loop_epoll_ctl(loop, event_epoll_ctl_mod(), slot.fd, want)
		if (r == -2): /* ENOENT: the kernel dropped it on close */
			r = event_loop_epoll_ctl(loop, event_epoll_ctl_add(), slot.fd, want)
	if (r >= 0):
		slot.registered = want
		return
	# epoll refuses regular files (EPERM) and closed fds (EBADF); poll
	# reports the first as always ready and the second as POLLNVAL.
	# Fake those revents every pass until the watches go away.
	slot.registered = 0
	if (r == -9): /* EBADF */
		slot.synthetic = poll_nval()
	else:
		slot.synthetic = want & (poll_in() | poll_out())
		if (slot.synthetic == 0):
			slot.synthetic = poll_in()
	loop.synthetic.push(slot)


void event_loop_sync(event_loop* loop):
	int i = 0
	while (i < loop.dirty.length):
		event_loop_sync_slot(loop, loop.dirty[i])
		i = i + 1
	loop.dirty.clear()


/* Watches. */

event_watch* event_loop_find_watch(event_loop* loop, int fd):
	if (loop.epfd >= 0):
		event_fd_slot* slot = event_loop_find_slot(loop, fd)
		if (cast(int, slot) == 0):
			return 0
		int j = 0
		while (j < slot.watches.length):
			event_watch* w = slot.watches[j]
			if (w.active):
				return w
			j = j + 1
		return 0
	int i = 0
	while (i < loop.watches.length):
		event_watch* watch = loop.watches[i]
		if ((watch.fd == fd) & watch.active):
			return watch
		i = i + 1
	return 0


# Adds a watch and returns its handle. Several watches may share one fd
# (a reader and a writer task on the same socket); remove them by
# handle with event_loop_remove_watch.
event_watch* event_loop_add_watch(event_loop* loop, int fd, int events, event_fd_cb* callback, void* context):
	event_watch* watch = new event_watch()
	watch.fd = fd
	watch.events = events
	watch.callback = callback
	watch.context = context
	watch.active = 1
	watch.pass = loop.pass
	loop.watch_count = loop.watch_count + 1
	if (loop.epfd >= 0):
		event_fd_slot* slot = event_loop_slot(loop, fd)
		slot.watches.push(watch)
		slot.live = slot.live + 1
		event_loop_mark_dirty(loop, slot)
	else:
		loop.watches.push(watch)
	return watch


void event_loop_add_fd(event_loop* loop, int fd, int events, event_fd_cb* callback, void* context):
	event_loop_add_watch(loop, fd, events, callback, context)


# Removes one watch by handle; safe inside callbacks like
# event_loop_remove_fd. The handle must not be used afterwards.
void event_loop_remove_watch(event_loop* loop, event_watch* watch):
	if (watch.active == 0):
		return
	watch.active = 0
	loop.watch_count = loop.watch_count - 1
	if (loop.epfd >= 0):
		event_loop_slot_watch_gone(loop, event_loop_find_slot(loop, watch.fd))


# Changes the interest mask of an existing watch.
int event_loop_modify_fd(event_loop* loop, int fd, int events):
	event_watch* watch = event_loop_find_watch(loop, fd)
	if (cast(int, watch) == 0):
		return 0
	watch.events = events
	if (loop.epfd >= 0):
		event_loop_mark_dirty(loop, event_loop_find_slot(loop, fd))
	return 1


# Safe to call from inside a callback: the watch is only marked inactive
# and physically removed after the current dispatch pass.
int event_loop_remove_fd(event_loop* loop, int fd):
	event_watch* watch = event_loop_find_watch(loop, fd)
	if (cast(int, watch) == 0):
		return 0
	event_loop_remove_watch(loop, watch)
	return 1


/* Timers. */

int event_loop_add_timer_full(event_loop* loop, int delay_ms, int interval_ms, event_timer_cb* callback, void* context):
	event_timer* timer = new event_timer()
	timer.id = loop.next_timer_id
	loop.next_timer_id = loop.next_timer_id + 1
	timer.fire_at_ms = time_monotonic_ms() + delay_ms
	timer.interval_ms = interval_ms
	timer.callback = callback
	timer.context = context
	timer.active = 1
	heap_push[event_timer*](loop.timer_heap, timer)
	loop.timer_ids[timer.id] = timer
	loop.timer_count = loop.timer_count + 1
	return timer.id


# One-shot timer; returns an id usable with event_loop_cancel_timer.
int event_loop_add_timer(event_loop* loop, int delay_ms, event_timer_cb* callback, void* context):
	return event_loop_add_timer_full(loop, delay_ms, 0, callback, context)


# Repeating timer with a fixed interval.
int event_loop_add_interval(event_loop* loop, int interval_ms, event_timer_cb* callback, void* context):
	return event_loop_add_timer_full(loop, interval_ms, interval_ms, callback, context)


# Returns 1 when the timer existed and was cancelled before firing.
int event_loop_cancel_timer(event_loop* loop, int timer_id):
	if ((timer_id in loop.timer_ids) == 0):
		return 0
	event_timer* timer = loop.timer_ids[timer_id]
	loop.timer_ids.remove(timer_id)
	# Stays in the heap until it reaches the top, then is freed.
	timer.active = 0
	loop.timer_count = loop.timer_count - 1
	return 1


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


# Active fd watches, O(1).
int event_loop_watch_count(event_loop* loop):
	return loop.watch_count


# Armed timers, O(1).
int event_loop_timer_count(event_loop* loop):
	return loop.timer_count


# Earliest armed timer, freeing cancelled ones on the way; 0 when none.
event_timer* event_loop_first_timer(event_loop* loop):
	while (loop.timer_heap.length > 0):
		event_timer* timer = heap_peek[event_timer*](loop.timer_heap)
		if (timer.active):
			return timer
		heap_pop[event_timer*](loop.timer_heap)
		free(cast(char*, timer))
	return 0


# Milliseconds until the next active timer fires (0 when already due),
# or -1 when no timer is scheduled. Uses signed differences so the
# wrapping 32-bit monotonic clock stays correct.
int event_loop_next_timer_delay(event_loop* loop):
	event_timer* timer = event_loop_first_timer(loop)
	if (cast(int, timer) == 0):
		return -1
	int delay = timer.fire_at_ms - time_monotonic_ms()
	if (delay < 0):
		return 0
	return delay


# Fires timers whose deadline has passed, earliest first. One-shot
# timers deactivate before their callback runs; intervals reschedule.
# Timers armed by these callbacks wait for the next pass. Returns fired
# count.
int event_loop_fire_due_timers(event_loop* loop):
	int fired = 0
	int now = time_monotonic_ms()
	int newest = loop.next_timer_id
	list[event_timer*] rearm = new list[event_timer*]
	while (1):
		event_timer* timer = event_loop_first_timer(loop)
		if (cast(int, timer) == 0):
			break
		if ((timer.fire_at_ms - now) > 0):
			break
		if (timer.id >= newest):
			break
		heap_pop[event_timer*](loop.timer_heap)
		if (timer.interval_ms > 0):
			timer.fire_at_ms = now + timer.interval_ms
			rearm.push(timer)
		else:
			timer.active = 0
			loop.timer_ids.remove(timer.id)
			loop.timer_count = loop.timer_count - 1
		timer.callback(timer.id, timer.context)
		fired = fired + 1
		if (timer.interval_ms <= 0):
			free(cast(char*, timer))
	int i = 0
	while (i < rearm.length):
		# Re-armed after the pass so an interval fires at most once per
		# pass; one cancelled from its own callback is freed lazily.
		heap_push[event_timer*](loop.timer_heap, rearm[i])
		i = i + 1
	list_free[event_timer*](rearm)
	return fired


# The poll timeout for this pass: max_wait_ms capped by the next timer.
int event_loop_wait_timeout(event_loop* loop, int max_wait_ms):
	int timeout = max_wait_ms
	int timer_delay = event_loop_next_timer_delay(loop)
	if (timer_delay >= 0):
		if (timeout < 0):
			timeout = timer_delay
		else:
			timeout = min(timeout, timer_delay)
	return timeout


int event_loop_run_once_poll(event_loop* loop, int max_wait_ms):
	event_loop_compact[event_watch*](loop, loop.watches)
	int timeout = event_loop_wait_timeout(loop, max_wait_ms)

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


# Deliver revents for one fd to its watches that were armed before this
# pass began, each seeing its own interest bits plus ERR/HUP/NVAL.
int event_loop_dispatch_slot(event_loop* loop, event_fd_slot* slot, int revents):
	int fired = 0
	int always = poll_err() | poll_hup() | poll_nval()
	int count = slot.watches.length
	int j = 0
	while (j < count):
		event_watch* w = slot.watches[j]
		if (w.active && (w.pass != loop.pass)):
			int mine = revents & (w.events | always)
			if (mine != 0):
				w.callback(slot.fd, mine, w.context)
				fired = fired + 1
		j = j + 1
	return fired


int event_loop_run_once_epoll(event_loop* loop, int max_wait_ms):
	# Drop slots that stopped faking readiness (before the sync, which
	# may queue a slot again).
	int s = 0
	while (s < loop.synthetic.length):
		event_fd_slot* slot = loop.synthetic[s]
		if ((slot.synthetic == 0) || (slot.live == 0)):
			slot.synthetic = 0
			list_remove_at[event_fd_slot*](loop.synthetic, s)
		else:
			s = s + 1
	event_loop_sync(loop)
	int timeout = event_loop_wait_timeout(loop, max_wait_ms)
	if (loop.synthetic.length > 0):
		timeout = 0
	loop.pass = loop.pass + 1

	int ready = epoll_wait(loop.epfd, cast(int, loop.events), loop.event_capacity, timeout)
	if (ready < 0):
		if (ready == -4):
			return 0
		return ready

	int fired = event_loop_fire_due_timers(loop)

	int size = epoll_event_bytes()
	int offset = epoll_event_data_offset()
	int i = 0
	while (i < ready):
		char* ev = loop.events + i * size
		int* mask = cast(int*, ev)
		int* data = cast(int*, ev + offset)
		int fd = data[0]
		# The u32 event mask sits in the low half of a word on 64-bit
		# targets; only the low poll bits matter.
		int revents = mask[0] & 65535
		event_fd_slot* slot = event_loop_find_slot(loop, fd)
		if (cast(int, slot) != 0):
			fired = fired + event_loop_dispatch_slot(loop, slot, revents)
		i = i + 1

	s = 0
	int synthetic_count = loop.synthetic.length
	while (s < synthetic_count):
		event_fd_slot* slot = loop.synthetic[s]
		if (slot.synthetic != 0):
			fired = fired + event_loop_dispatch_slot(loop, slot, slot.synthetic)
		s = s + 1

	# A full buffer means more events may be pending: grow for next time.
	if (ready == loop.event_capacity):
		free(loop.events)
		loop.event_capacity = loop.event_capacity * 2
		loop.events = malloc(loop.event_capacity * size)
	return fired


# Runs one iteration: waits at most max_wait_ms (or less when a timer is
# due sooner; -1 waits indefinitely), fires due timers, then dispatches
# fd callbacks. Returns callbacks fired, or a negative errno.
int event_loop_run_once(event_loop* loop, int max_wait_ms):
	if (loop.epfd >= 0):
		return event_loop_run_once_epoll(loop, max_wait_ms)
	return event_loop_run_once_poll(loop, max_wait_ms)


# Runs until event_loop_stop() or until no active watches or timers
# remain. Returns 0 on a normal stop or a negative errno from the wait.
int event_loop_run(event_loop* loop):
	loop.running = 1
	while (loop.running):
		if ((loop.watch_count == 0) && (loop.timer_count == 0)):
			loop.running = 0
			return 0
		int result = event_loop_run_once(loop, -1)
		if (result < 0):
			loop.running = 0
			return result
	return 0
