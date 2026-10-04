/*
Deterministic poll provider for lib/event_loop.w
(docs/projects/simulation.md, issue #514 stage W4).

event_sim replaces poll(2) with scripted readiness and a virtual clock
(lib/wclock.w), so an event loop runs a timeline instead of waiting on
the kernel:

	wclock* clock = wclock_virtual_new(0)
	event_sim* sim = event_sim_new(clock)
	event_loop* loop = event_loop_new_with(clock, event_sim_poller(sim))
	event_sim_at(sim, 250, fd, poll_in)    # fd readable at t = 250 ms
	event_loop_run(loop)

Descriptors are plain numbers here: the kernel is never asked about
them. Two kinds of readiness:

- one-shot events (event_sim_at): delivered once, by the first wait at
  or after their virtual time whose pollfd set watches the fd with a
  matching interest bit (ERR/HUP/NVAL always match), then consumed.
- level readiness (event_sim_set_ready): reported on every wait until
  event_sim_set_ready(sim, fd, 0) clears it, like a socket with unread
  data.

A wait never sleeps. When nothing is ready it advances the virtual clock
straight to the earlier of its timeout (the loop's next timer deadline)
and the next deliverable scripted event, then reports what is ready at
that instant. With nothing ready, no scripted event pending for a
watched fd and an infinite timeout, nothing can ever wake the wait: it
returns -EDEADLK (-35), which ends event_loop_run with that status
rather than spinning. Same script => same callbacks at the same virtual
times, on every target.

The loop must be built with the same virtual clock this provider
advances. One-shot events are consumed when reported; with an fd
dispatch limit (event_loop_set_dispatch_limits) a reported one-shot
event the loop did not reach is lost, so fairness tests use level
readiness, as real descriptors are level-triggered.
*/
import lib.lib
import lib.assert
import lib.poll
import lib.io
import lib.wclock
import lib.event_loop


const int EVENT_SIM_EDEADLK = 35


struct event_sim_event:
	int at_ms       # virtual monotonic ms (wrapping, compared by difference)
	int fd
	int revents
	int seq         # scripting order: the tiebreaker for equal times


struct event_sim:
	wclock* clock
	event_poller* poller
	list[event_sim_event*] scripted
	map[int, int] level             # fd -> revents reported every wait
	int next_seq
	int waits                       # provider calls
	int advanced_ms                 # virtual ms skipped instead of slept


int event_sim_now(event_sim* sim);
int event_sim_next_due(event_sim* sim, pollfd* fds, int nfds, int* out);
int event_sim_deliver(event_sim* sim, pollfd* fds, int nfds, int now);


# The event_poller wait function (poll(2) contract; see the header).
int event_sim_wait(void* self, pollfd* fds, int nfds, int timeout_ms):
	event_sim* sim = cast(event_sim*, self)
	sim.waits = sim.waits + 1
	int now = event_sim_now(sim)
	int ready = event_sim_deliver(sim, fds, nfds, now)
	if ((ready > 0) || (timeout_ms == 0)): return ready
	int next = 0
	int has_next = event_sim_next_due(sim, fds, nfds, &next)
	int target = 0
	if (has_next): target = next
	if (timeout_ms > 0):
		int deadline = now + timeout_ms
		if ((has_next == 0) || ((deadline - target) < 0)): target = deadline
	else if (has_next == 0):
		return 0 - EVENT_SIM_EDEADLK
	int step = target - now
	if (step > 0):
		wclock_virtual_advance_ms(sim.clock, step)
		sim.advanced_ms = sim.advanced_ms + step
	return event_sim_deliver(sim, fds, nfds, event_sim_now(sim))


event_sim* event_sim_new(wclock* clock):
	asserts(c"event_sim_new: needs a virtual clock", clock.is_virtual)
	event_sim* sim = new event_sim()
	sim.clock = clock
	sim.poller = new event_poller()
	sim.poller.wait = event_sim_wait
	sim.poller.self = cast(void*, sim)
	sim.scripted = new list[event_sim_event*]
	sim.level = new map[int, int]
	sim.next_seq = 0
	sim.waits = 0
	sim.advanced_ms = 0
	return sim


# The provider to pass to event_loop_new_with; owned by sim.
event_poller* event_sim_poller(event_sim* sim):
	return sim.poller


void event_sim_free(event_sim* sim):
	int i = 0
	while (i < sim.scripted.length):
		free(sim.scripted[i])
		i = i + 1
	list_free[event_sim_event*](sim.scripted)
	sim.level.free()
	free(sim.poller)
	free(sim)


# Current virtual monotonic ms (wrapping like time_monotonic_ms).
int event_sim_now(event_sim* sim):
	int now = 0
	wclock_monotonic_ms(sim.clock, &now)
	return now


# Scripts a one-shot readiness event for fd at virtual time at_ms.
void event_sim_at(event_sim* sim, int at_ms, int fd, int revents):
	event_sim_event* e = new event_sim_event()
	e.at_ms = at_ms
	e.fd = fd
	e.revents = revents
	e.seq = sim.next_seq
	sim.next_seq = sim.next_seq + 1
	sim.scripted.push(e)


# Scripts a one-shot event delay_ms after the current virtual time.
void event_sim_after(event_sim* sim, int delay_ms, int fd, int revents):
	event_sim_at(sim, event_sim_now(sim) + delay_ms, fd, revents)


# Level readiness for fd, reported on every wait; 0 clears it.
void event_sim_set_ready(event_sim* sim, int fd, int revents):
	if (revents == 0):
		if (fd in sim.level): sim.level.remove(fd)
		return
	sim.level[fd] = revents


# One-shot events not yet delivered.
int event_sim_pending(event_sim* sim):
	return sim.scripted.length


# revents mask a pollfd with interest events sees for raw readiness.
int event_sim_mask(int raw, int events):
	return raw & (events | poll_err | poll_hup | poll_nval)


# 1 when some entry of fds watches fd with an interest raw matches.
int event_sim_watched(pollfd* fds, int nfds, int fd, int raw):
	for i in range(nfds):
		pollfd* p = pollfd_at(fds, i)
		if ((p.fd == fd) && (event_sim_mask(raw, p.events) != 0)): return 1
	return 0


# Earliest deliverable scripted time (by difference from now, then
# scripting order) into out; 0 when nothing deliverable is scripted.
int event_sim_next_due(event_sim* sim, pollfd* fds, int nfds, int* out):
	int found = 0
	int best = 0
	int now = event_sim_now(sim)
	for i in range(sim.scripted.length):
		event_sim_event* e = sim.scripted[i]
		if (event_sim_watched(fds, nfds, e.fd, e.revents)):
			if ((found == 0) || ((e.at_ms - now) < (best - now))):
				best = e.at_ms
				found = 1
	out[0] = best
	return found


# Fills revents for everything ready at now: level readiness plus due
# scripted events (consumed once some entry matched them). Returns the
# number of pollfd entries with nonzero revents.
int event_sim_deliver(event_sim* sim, pollfd* fds, int nfds, int now):
	for i in range(nfds):
		pollfd* p = pollfd_at(fds, i)
		p.revents = 0
		if (p.fd in sim.level): p.revents = event_sim_mask(sim.level[p.fd], p.events)
	int k = 0
	while (k < sim.scripted.length):
		event_sim_event* e = sim.scripted[k]
		int used = 0
		if ((e.at_ms - now) <= 0):
			for i in range(nfds):
				pollfd* p = pollfd_at(fds, i)
				int mine = event_sim_mask(e.revents, p.events)
				if ((p.fd == e.fd) && (mine != 0)):
					p.revents = p.revents | mine
					used = 1
		if (used):
			list_remove_at[event_sim_event*](sim.scripted, k)
			free(e)
		else: k = k + 1
	int ready = 0
	for i in range(nfds):
		pollfd* p = pollfd_at(fds, i)
		if (p.revents != 0): ready = ready + 1
	return ready
