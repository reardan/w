import lib.lib
import lib.time
import structures.array_list


type sched_cb = fn(int, void*) -> void


struct sched_event:
	int active
	int id
	int fire_at_ms
	int priority
	int sequence
	sched_cb* callback
	void* context


struct scheduler:
	array_list* events
	int next_event_id
	int next_sequence
	int running


scheduler* sched_new():
	scheduler* s = new scheduler()
	s.events = array_list_new()
	s.next_event_id = 1
	s.next_sequence = 1
	s.running = 0
	return s


void sched_free(scheduler* s):
	int i = 0
	while (i < s.events.length):
		free(cast(void*, array_list_get(s.events, i)))
		i = i + 1
	array_list_free(s.events)
	free(s)


int sched_enter_at(scheduler* s, int fire_at_ms, int priority, sched_cb* cb, void* ctx):
	sched_event* event = new sched_event()
	event.active = 1
	event.id = s.next_event_id
	s.next_event_id = s.next_event_id + 1
	event.fire_at_ms = fire_at_ms
	event.priority = priority
	event.sequence = s.next_sequence
	s.next_sequence = s.next_sequence + 1
	event.callback = cb
	event.context = ctx
	array_list_push(s.events, cast(int, event))
	return event.id


int sched_enter(scheduler* s, int delay_ms, int priority, sched_cb* cb, void* ctx):
	return sched_enter_at(s, time_monotonic_ms() + delay_ms, priority, cb, ctx)


int sched_cancel(scheduler* s, int event_id):
	int i = 0
	while (i < s.events.length):
		sched_event* event = cast(sched_event*, array_list_get(s.events, i))
		if ((event.id == event_id) & event.active):
			event.active = 0
			return 1
		i = i + 1
	return 0


void sched_stop(scheduler* s):
	s.running = 0


void sched_compact(scheduler* s):
	int i = 0
	while (i < s.events.length):
		sched_event* event = cast(sched_event*, array_list_get(s.events, i))
		if (event.active == 0):
			free(event)
			array_list_remove(s.events, i)
		else:
			i = i + 1


int sched_active_count(scheduler* s):
	int count = 0
	int i = 0
	while (i < s.events.length):
		sched_event* event = cast(sched_event*, array_list_get(s.events, i))
		if (event.active):
			count = count + 1
		i = i + 1
	return count


sched_event* sched_next_due(scheduler* s, int now_ms):
	sched_event* best = 0
	int i = 0
	while (i < s.events.length):
		sched_event* event = cast(sched_event*, array_list_get(s.events, i))
		if (event.active & ((event.fire_at_ms - now_ms) <= 0)):
			if (cast(int, best) == 0):
				best = event
			else if (event.fire_at_ms < best.fire_at_ms):
				best = event
			else if ((event.fire_at_ms == best.fire_at_ms) & (event.priority < best.priority)):
				best = event
			else if ((event.fire_at_ms == best.fire_at_ms) & (event.priority == best.priority) & (event.sequence < best.sequence)):
				best = event
		i = i + 1
	return best


int sched_next_delay(scheduler* s, int now_ms):
	int found = 0
	int best = 0
	int i = 0
	while (i < s.events.length):
		sched_event* event = cast(sched_event*, array_list_get(s.events, i))
		if (event.active):
			int delay = event.fire_at_ms - now_ms
			if (delay < 0):
				delay = 0
			if ((found == 0) | (delay < best)):
				best = delay
				found = 1
		i = i + 1
	if (found == 0):
		return -1
	return best


void sched_run_pending_at(scheduler* s, int now_ms):
	sched_event* event = sched_next_due(s, now_ms)
	while (cast(int, event) != 0):
		event.active = 0
		event.callback(event.id, event.context)
		event = sched_next_due(s, now_ms)
	sched_compact(s)


void sched_run_pending(scheduler* s):
	sched_run_pending_at(s, time_monotonic_ms())


void sched_run(scheduler* s):
	s.running = 1
	while (s.running & (sched_active_count(s) > 0)):
		int delay = sched_next_delay(s, time_monotonic_ms())
		if (delay > 0):
			sleep_ms(delay)
		sched_run_pending(s)
