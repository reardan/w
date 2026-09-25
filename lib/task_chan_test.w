# wbuild: x64
# Tests for task channels and select (lib/task_chan.w).
import lib.testing
import lib.task
import lib.task_chan
import lib.container
import lib.time


/* Buffered producer/consumer, closed by the producer. */

generator int produce(task_chan* ch, int count):
	int i = 1
	while (i <= count):
		assert_equal(0, task_chan_send(ch, i))
		i = i + 1
	task_chan_close(ch)


generator int consume(task_chan* ch):
	int sum = 0
	int v = 0
	while (task_chan_recv(ch, &v) > 0):
		sum = sum + v
	task_finish(sum)


void test_buffered_channel_delivers_everything():
	task_scheduler* s = task_scheduler_new()
	task_chan* ch = task_chan_new(4)
	task* c = task_spawn(s, consume(ch))
	task_spawn(s, produce(ch, 100))
	assert_equal(0, task_run(s))
	assert_equal(5050, task_result(c))
	task_chan_free(ch)
	task_scheduler_free(s)


void test_rendezvous_channel_delivers_everything():
	task_scheduler* s = task_scheduler_new()
	task_chan* ch = task_chan_new(0)
	task_spawn(s, produce(ch, 50))
	task* c = task_spawn(s, consume(ch))
	assert_equal(0, task_run(s))
	assert_equal(1275, task_result(c))
	task_chan_free(ch)
	task_scheduler_free(s)


/* Several producers and consumers keep FIFO order per producer and
   lose nothing. */

generator int consume_into(task_chan* ch, list[int] out):
	int v = 0
	while (task_chan_recv(ch, &v) > 0):
		out.push(v)


generator int produce_range(task_chan* ch, int start, int count):
	int i = 0
	while (i < count):
		task_chan_send(ch, start + i)
		i = i + 1


generator int close_after_join(task_chan* ch, task* a, task* b):
	task_join(a)
	task_join(b)
	task_chan_close(ch)


void test_many_to_many():
	task_scheduler* s = task_scheduler_new()
	task_chan* ch = task_chan_new(2)
	list[int] out1 = new list[int]
	list[int] out2 = new list[int]
	task_spawn(s, consume_into(ch, out1))
	task_spawn(s, consume_into(ch, out2))
	task* a = task_spawn(s, produce_range(ch, 0, 200))
	task* b = task_spawn(s, produce_range(ch, 1000, 200))
	task_spawn(s, close_after_join(ch, a, b))
	assert_equal(0, task_run(s))
	assert_equal(400, out1.length + out2.length)
	# Per producer, each consumer sees increasing values.
	int i = 1
	int last_a = -1
	int last_b = -1
	while (i < out1.length):
		i = i + 1
	i = 0
	while (i < out1.length):
		int v = out1[i]
		if (v < 1000):
			asserts(c"producer A reordered", v > last_a)
			last_a = v
		else:
			asserts(c"producer B reordered", v > last_b)
			last_b = v
		i = i + 1
	list_free[int](out1)
	list_free[int](out2)
	task_chan_free(ch)
	task_scheduler_free(s)


/* Closing wakes parked senders with task_err_closed(). */

generator int send_blocked(task_chan* ch):
	task_chan_send(ch, 1)
	task_finish(task_chan_send(ch, 2))


generator int close_soon(task_chan* ch):
	task_sleep_ms(2)
	task_chan_close(ch)


void test_close_fails_parked_sender():
	task_scheduler* s = task_scheduler_new()
	task_chan* ch = task_chan_new(1)
	task* t = task_spawn(s, send_blocked(ch))
	task_spawn(s, close_soon(ch))
	assert_equal(0, task_run(s))
	assert_equal(task_err_closed(), task_result(t))
	# The buffered value survives the close and drains first.
	int v = 0
	assert_equal(1, task_chan_try_recv(ch, &v))
	assert_equal(1, v)
	assert_equal(0, task_chan_try_recv(ch, &v))
	assert_equal(task_err_closed(), task_chan_try_send(ch, 3))
	task_chan_free(ch)
	task_scheduler_free(s)


/* Timeouts and cancellation while parked on a channel. */

generator int recv_with_timeout(task_chan* ch, int ms):
	int v = 0
	task_finish(task_chan_recv_timeout(ch, &v, ms))


void test_recv_timeout():
	task_scheduler* s = task_scheduler_new()
	task_chan* ch = task_chan_new(0)
	task* t = task_spawn(s, recv_with_timeout(ch, 5))
	assert_equal(0, task_run(s))
	assert_equal(task_err_timed_out(), task_result(t))
	# The timed-out waiter is gone: a send cannot find it.
	assert_equal(task_err_would_block(), task_chan_try_send(ch, 1))
	task_chan_free(ch)
	task_scheduler_free(s)


generator int cancel_after(task* victim, int ms):
	task_sleep_ms(ms)
	task_cancel(victim)


void test_cancel_parked_receiver():
	task_scheduler* s = task_scheduler_new()
	task_chan* ch = task_chan_new(0)
	task* t = task_spawn(s, recv_with_timeout(ch, -1))
	task_spawn(s, cancel_after(t, 2))
	assert_equal(0, task_run(s))
	assert_equal(task_err_cancelled(), task_result(t))
	task_chan_free(ch)
	task_scheduler_free(s)


void test_recv_without_peers_is_deadlock():
	task_scheduler* s = task_scheduler_new()
	task_chan* ch = task_chan_new(0)
	task_spawn(s, recv_with_timeout(ch, -1))
	assert_equal(task_err_deadlock(), task_run(s))
	task_scheduler_free(s)
	task_chan_free(ch)


/* Select. */

generator int send_after(task_chan* ch, int value, int ms):
	task_sleep_ms(ms)
	task_chan_send(ch, value)


generator int select_two(task_chan* a, task_chan* b, list[int] out):
	int round = 0
	while (round < 2):
		task_select sel
		task_select_init(&sel)
		int ia = task_select_recv(&sel, a)
		int ib = task_select_recv(&sel, b)
		int which = task_select_wait(&sel, 1000)
		if (which == ia):
			out.push(100 + task_select_value(&sel))
		else if (which == ib):
			out.push(200 + task_select_value(&sel))
		else:
			out.push(which)
		task_select_free(&sel)
		round = round + 1


void test_select_takes_whichever_is_ready():
	task_scheduler* s = task_scheduler_new()
	task_chan* a = task_chan_new(0)
	task_chan* b = task_chan_new(0)
	list[int] out = new list[int]
	task_spawn(s, select_two(a, b, out))
	task_spawn(s, send_after(b, 7, 2))
	task_spawn(s, send_after(a, 9, 10))
	assert_equal(0, task_run(s))
	assert_equal(2, out.length)
	assert_equal(207, out[0])
	assert_equal(109, out[1])
	list_free[int](out)
	task_chan_free(a)
	task_chan_free(b)
	task_scheduler_free(s)


generator int select_timeout(task_chan* a):
	task_select sel
	task_select_init(&sel)
	task_select_recv(&sel, a)
	int r = task_select_wait(&sel, 5)
	int polled = task_select_wait(&sel, 0)
	task_select_free(&sel)
	task_finish(r * 1000 + polled)


void test_select_timeout_and_poll():
	task_scheduler* s = task_scheduler_new()
	task_chan* a = task_chan_new(0)
	task* t = task_spawn(s, select_timeout(a))
	assert_equal(0, task_run(s))
	assert_equal(task_err_timed_out() * 1000 + task_err_would_block(), task_result(t))
	# No waiter left behind on the channel.
	assert_equal(1, task_wait_queue_empty(&a.receivers))
	task_chan_free(a)
	task_scheduler_free(s)


generator int select_send(task_chan* full, task_chan* open):
	task_select sel
	task_select_init(&sel)
	task_select_send(&sel, full, 1)
	int i_open = task_select_send(&sel, open, 2)
	int which = task_select_wait(&sel, -1)
	assert_equal(i_open, which)
	assert_equal(1, task_select_ok(&sel))
	task_select_free(&sel)


generator int recv_one_later(task_chan* ch, list[int] out):
	task_sleep_ms(2)
	int v = 0
	task_chan_recv(ch, &v)
	out.push(v)


void test_select_send_cases():
	task_scheduler* s = task_scheduler_new()
	task_chan* full = task_chan_new(0)
	task_chan* open = task_chan_new(0)
	list[int] out = new list[int]
	task_spawn(s, select_send(full, open))
	task_spawn(s, recv_one_later(open, out))
	assert_equal(0, task_run(s))
	assert_equal(1, out.length)
	assert_equal(2, out[0])
	# The losing send case left nothing behind.
	assert_equal(1, task_wait_queue_empty(&full.senders))
	list_free[int](out)
	task_chan_free(full)
	task_chan_free(open)
	task_scheduler_free(s)


generator int select_on_closed(task_chan* a):
	task_select sel
	task_select_init(&sel)
	task_select_recv(&sel, a)
	int which = task_select_wait(&sel, -1)
	task_finish(which * 10 + task_select_ok(&sel))
	task_select_free(&sel)


void test_select_sees_close():
	task_scheduler* s = task_scheduler_new()
	task_chan* a = task_chan_new(0)
	task* t = task_spawn(s, select_on_closed(a))
	task_spawn(s, close_soon(a))
	assert_equal(0, task_run(s))
	assert_equal(0, task_result(t))
	task_chan_free(a)
	task_scheduler_free(s)
