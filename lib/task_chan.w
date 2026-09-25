/*
Channels and select for tasks (docs/projects/async.md).

A task_chan carries words (ints or pointers) between tasks on one
scheduler. capacity > 0 buffers that many values; capacity 0 is a
rendezvous channel where every send waits for a receiver. Senders and
receivers park FIFO, values are handed over directly, and closing a
channel wakes everyone: receivers drain what is buffered and then see
0, senders fail with task_err_closed().

	task_chan* ch = task_chan_new(16)
	# producer task                     # consumer task
	task_chan_send(ch, job)             int job = 0
	task_chan_close(ch)                 while (task_chan_recv(ch, &job) > 0):
	                                        handle(job)

task_select waits on several channel operations at once and performs
exactly one of them:

	task_select sel
	task_select_init(&sel)
	int got_msg = task_select_recv(&sel, messages)
	int got_quit = task_select_recv(&sel, quit)
	int which = task_select_wait(&sel, 1000)    # case index or error
	if (which == got_msg): ... task_select_value(&sel) ...
	task_select_free(&sel)
*/
import lib.lib
import lib.container
import lib.task
import structures.deque


struct task_chan:
	deque[int]* buffer
	int capacity
	int closed
	task_wait_queue senders     # waiter.value: the value to send
	task_wait_queue receivers   # waiter.value: filled in on completion


task_chan* task_chan_new(int capacity):
	task_chan* ch = new task_chan()
	ch.buffer = deque_new[int]()
	if (capacity < 0): capacity = 0
	ch.capacity = capacity
	ch.closed = 0
	task_wait_queue_init(&ch.senders)
	task_wait_queue_init(&ch.receivers)
	return ch


# Free a channel nobody is parked on any more.
void task_chan_free(task_chan* ch):
	deque_free[int](ch.buffer)
	free(cast(void*, ch))


int task_chan_length(task_chan* ch):
	return ch.buffer.length


int task_chan_is_closed(task_chan* ch):
	return ch.closed


# Close the channel: parked receivers wake with 0 (after the buffer
# drains, later receives also return 0) and parked or later senders
# fail with task_err_closed(). Closing twice is harmless.
void task_chan_close(task_chan* ch):
	ch.closed = 1
	task_wait_queue_fire_all(&ch.receivers, task_waiter_closed, 0)
	task_wait_queue_fire_all(&ch.senders, task_waiter_closed, 0)


# Send without parking: 0 when the value was delivered or buffered,
# task_err_would_block() when that would need a wait,
# task_err_closed() on a closed channel.
int task_chan_try_send(task_chan* ch, int value):
	if (ch.closed): return task_err_closed()
	task_waiter* w = task_wait_queue_first(&ch.receivers)
	if (cast(int, w) != 0):
		# A parked receiver means the buffer is empty: hand it over.
		w.value = value
		task_waiter_fire(w, task_waiter_completed, 0)
		return 0
	if (ch.buffer.length < ch.capacity):
		deque_push_back[int](ch.buffer, value)
		return 0
	return task_err_would_block()


# Receive without parking: 1 with *out set, 0 when the channel is
# closed and drained, task_err_would_block() when empty but open.
int task_chan_try_recv(task_chan* ch, int* out):
	if (ch.buffer.length > 0):
		*out = deque_pop_front[int](ch.buffer)
		# Room freed: move the longest-waiting sender's value in.
		task_waiter* s = task_wait_queue_first(&ch.senders)
		if (cast(int, s) != 0):
			deque_push_back[int](ch.buffer, s.value)
			task_waiter_fire(s, task_waiter_completed, 0)
		return 1
	task_waiter* w = task_wait_queue_first(&ch.senders)
	if (cast(int, w) != 0):
		# Rendezvous: take the value straight from the sender.
		*out = w.value
		task_waiter_fire(w, task_waiter_completed, 0)
		return 1
	if (ch.closed): return 0
	return task_err_would_block()


# Send value, parking up to timeout_ms (-1: forever) while the channel
# is full. Returns 0, task_err_closed(), task_err_timed_out() or
# task_err_cancelled().
int task_chan_send_timeout(task_chan* ch, int value, int timeout_ms):
	int r = task_chan_try_send(ch, value)
	if (r != task_err_would_block()):
		return r
	task* t = task_current()
	int err = task_park_check(t)
	if (err < 0):
		return err
	task_waiter w
	task_waiter_init(&w, t)
	w.value = value
	r = task_park_on(&ch.senders, &w, timeout_ms)
	if (w.status == task_waiter_completed): return 0
	if (w.status == task_waiter_closed): return task_err_closed()
	return r


int task_chan_send(task_chan* ch, int value):
	return task_chan_send_timeout(ch, value, -1)


# Receive into *out, parking up to timeout_ms (-1: forever) while the
# channel is empty. Returns 1 with a value, 0 once closed and drained,
# or a negative error.
int task_chan_recv_timeout(task_chan* ch, int* out, int timeout_ms):
	int r = task_chan_try_recv(ch, out)
	if (r != task_err_would_block()):
		return r
	task* t = task_current()
	int err = task_park_check(t)
	if (err < 0):
		return err
	task_waiter w
	task_waiter_init(&w, t)
	r = task_park_on(&ch.receivers, &w, timeout_ms)
	if (w.status == task_waiter_completed):
		*out = w.value
		return 1
	if (w.status == task_waiter_closed): return 0
	return r


int task_chan_recv(task_chan* ch, int* out):
	return task_chan_recv_timeout(ch, out, -1)


/* Select. */

const int task_select_kind_recv = 1
const int task_select_kind_send = 2


struct task_select_case:
	int kind
	task_chan* ch
	int value           # send: value to send; recv: value received
	task_waiter waiter


struct task_select:
	list[task_select_case*] cases
	int value           # received value of the chosen recv case
	int ok              # recv: 1 value, 0 closed; send: 1 sent, 0 closed


void task_select_init(task_select* sel):
	sel.cases = new list[task_select_case*]
	sel.value = 0
	sel.ok = 0


void task_select_free(task_select* sel):
	int i = 0
	while (i < sel.cases.length):
		free(cast(void*, sel.cases[i]))
		i = i + 1
	list_free[task_select_case*](sel.cases)


int task_select_add(task_select* sel, int kind, task_chan* ch, int value):
	task_select_case* c = new task_select_case()
	c.kind = kind
	c.ch = ch
	c.value = value
	sel.cases.push(c)
	return sel.cases.length - 1


# Add a receive case; returns its index.
int task_select_recv(task_select* sel, task_chan* ch):
	return task_select_add(sel, task_select_kind_recv, ch, 0)


# Add a send case; returns its index.
int task_select_send(task_select* sel, task_chan* ch, int value):
	return task_select_add(sel, task_select_kind_send, ch, value)


# After a recv case won: the value (valid when task_select_ok is 1).
int task_select_value(task_select* sel):
	return sel.value


# After a case won: 1 when it moved a value, 0 when its channel was
# closed (a recv on a drained closed channel, a send on a closed one).
int task_select_ok(task_select* sel):
	return sel.ok


# Try the cases in order without parking; returns the index of the
# first that could proceed, or -1.
int task_select_poll(task_select* sel):
	int i = 0
	while (i < sel.cases.length):
		task_select_case* c = sel.cases[i]
		if (c.kind == task_select_kind_recv):
			int v = 0
			int r = task_chan_try_recv(c.ch, &v)
			if (r >= 0):
				sel.ok = r
				sel.value = v
				return i
		else:
			int r = task_chan_try_send(c.ch, c.value)
			if (r == 0):
				sel.ok = 1
				return i
			if (r == task_err_closed()):
				sel.ok = 0
				return i
		i = i + 1
	return -1


# Perform exactly one ready case, parking up to timeout_ms (-1:
# forever) until one is. Returns the index of the case that ran, or
# task_err_would_block() (timeout_ms == 0 and nothing ready),
# task_err_timed_out() or task_err_cancelled(). Earlier cases win when
# several are ready at once.
int task_select_wait(task_select* sel, int timeout_ms):
	int ready = task_select_poll(sel)
	if (ready >= 0):
		return ready
	if (timeout_ms == 0): return task_err_would_block()
	task* t = task_current()
	int err = task_park_check(t)
	if (err < 0):
		return err
	int n = sel.cases.length
	task_waiter** registered = cast(task_waiter**, malloc(n * __word_size__ + __word_size__))
	int i = 0
	while (i < n):
		task_select_case* c = sel.cases[i]
		task_waiter_init(&c.waiter, t)
		if (c.kind == task_select_kind_recv): task_waiter_link(&c.ch.receivers, &c.waiter)
		else:
			c.waiter.value = c.value
			task_waiter_link(&c.ch.senders, &c.waiter)
		registered[i] = &c.waiter
		i = i + 1
	t.wait_many = registered
	t.wait_count = n
	int r = task_park(t, task_state_waiting_queue, timeout_ms, task_err_timed_out())
	free(cast(void*, registered))
	i = 0
	while (i < n):
		task_select_case* c = sel.cases[i]
		if (c.waiter.status != task_waiter_pending):
			sel.ok = c.waiter.status == task_waiter_completed
			if (c.kind == task_select_kind_recv): sel.value = c.waiter.value
			return i
		i = i + 1
	return r
