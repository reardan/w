# wbuild: x64
import lib.testing
import libs.standard.distributed.sim


/*
Every hardcoded expectation below (delivery times, the reorder order,
the accepted-send count) was observed once on the x86 target and is
frozen: prng.w produces identical sequences on every target, so the
x64 twin of this test must reproduce each value exactly. A divergence
means a word-size bug, not a flaky test.
*/


void test_zero_delay_immediate_delivery():
	sim_net* s = sim_new(1, 0, 0, 0)
	int from = 0
	int to = 0
	# empty queue: nothing due
	assert1(sim_take_due(s, &from, &to) == 0)
	assert_equal(0, sim_now(s))
	assert_equal(1, sim_send(s, 1, 2, c"hello"))
	assert_equal(1, sim_pending(s))
	char* p = sim_take_due(s, &from, &to)
	assert_strings_equal(c"hello", p)
	assert_equal(1, from)
	assert_equal(2, to)
	assert_equal(0, sim_pending(s))
	# drained queue: nothing due again
	assert1(sim_take_due(s, &from, &to) == 0)
	sim_free(s)


void test_delay_window_respected():
	sim_net* s = sim_new(7, 5, 20, 0)
	int from = 0
	int to = 0
	assert_equal(1, sim_send(s, 1, 2, c"slow"))
	sim_advance(s, 4)
	# before min_delay: not due yet
	assert1(sim_take_due(s, &from, &to) == 0)
	int delivered_at = 0 - 1
	while (sim_now(s) < 20 && delivered_at < 0):
		sim_advance(s, 1)
		char* p = sim_take_due(s, &from, &to)
		if (p != 0):
			assert_strings_equal(c"slow", p)
			delivered_at = sim_now(s)
	assert1(delivered_at >= 5)
	assert1(delivered_at <= 20)
	# seed 7's delay roll lands on 12 (observed once, frozen)
	assert_equal(12, delivered_at)
	sim_free(s)


void test_fifo_tie_break_same_tick():
	sim_net* s = sim_new(3, 0, 0, 0)
	int from = 0
	int to = 0
	assert_equal(1, sim_send(s, 1, 2, c"first"))
	assert_equal(1, sim_send(s, 1, 2, c"second"))
	# equal deliver_at: seq (send order) breaks the tie
	assert_strings_equal(c"first", sim_take_due(s, &from, &to))
	assert_strings_equal(c"second", sim_take_due(s, &from, &to))
	assert1(sim_take_due(s, &from, &to) == 0)
	sim_free(s)


void test_reordering_from_delay_rolls():
	# Seed 3 with delays in [1, 50] rolls 12 for the first send and 4
	# for the second (observed once, frozen): the second send overtakes
	# the first.
	sim_net* s = sim_new(3, 1, 50, 0)
	int from = 0
	int to = 0
	assert_equal(1, sim_send(s, 1, 2, c"a"))
	assert_equal(1, sim_send(s, 1, 2, c"b"))
	sim_advance(s, 3)
	assert1(sim_take_due(s, &from, &to) == 0)
	sim_advance(s, 1)
	# t = 4: "b" due, "a" still in flight
	assert_strings_equal(c"b", sim_take_due(s, &from, &to))
	assert1(sim_take_due(s, &from, &to) == 0)
	sim_advance(s, 8)
	# t = 12: "a" due
	assert_strings_equal(c"a", sim_take_due(s, &from, &to))
	assert_equal(0, sim_pending(s))
	sim_free(s)


void test_identical_seeds_replay_identically():
	# Two sims with the same seed and config fed the identical script
	# must produce the identical sequence of (payload, delivery step,
	# from, to) and identical drop outcomes, step by step. The same
	# payload pointer goes to both sims, so pointer equality of the
	# deliveries proves the schedules match packet for packet.
	sim_net* a = sim_new(1234, 1, 30, 100)
	sim_net* b = sim_new(1234, 1, 30, 100)
	int fa = 0
	int ta = 0
	int fb = 0
	int tb = 0
	char* pa = 0
	char* pb = 0
	int step = 0
	while (step < 30):
		char* pl = itoa(step)
		int oka = sim_send(a, step % 3, (step + 1) % 3, pl)
		int okb = sim_send(b, step % 3, (step + 1) % 3, pl)
		assert_equal(oka, okb)
		if (oka == 0):
			free(pl)
		sim_advance(a, 2)
		sim_advance(b, 2)
		int draining = 1
		while (draining == 1):
			pa = sim_take_due(a, &fa, &ta)
			pb = sim_take_due(b, &fb, &tb)
			# same packet in both (same payload pointer), or both done
			assert1(pa == pb)
			if (pa == 0):
				draining = 0
			else:
				assert_equal(fa, fb)
				assert_equal(ta, tb)
				free(pa)
		step = step + 1
	# drain the tail after the script
	sim_advance(a, 60)
	sim_advance(b, 60)
	int tail = 1
	while (tail == 1):
		pa = sim_take_due(a, &fa, &ta)
		pb = sim_take_due(b, &fb, &tb)
		assert1(pa == pb)
		if (pa == 0):
			tail = 0
		else:
			assert_equal(fa, fb)
			assert_equal(ta, tb)
			free(pa)
	assert_equal(sim_pending(a), sim_pending(b))
	assert_equal(0, sim_pending(a))
	sim_free(a)
	sim_free(b)


void test_drop_rate_deterministic():
	sim_net* s = sim_new(42, 0, 0, 500)
	int accepted = 0
	int i = 0
	while (i < 1000):
		if (sim_send(s, 1, 2, c"d") == 1):
			accepted = accepted + 1
		i = i + 1
	# exact count for seed 42 at 500 per mille (observed once, frozen)
	assert_equal(518, accepted)
	assert1(accepted >= 400)
	assert1(accepted <= 600)
	sim_free(s)


void test_partition_blocks_both_directions():
	sim_net* s = sim_new(9, 0, 0, 0)
	int from = 0
	int to = 0
	# sent before the partition, due while partitioned: dropped
	assert_equal(1, sim_send(s, 1, 2, c"p1"))
	sim_partition(s, 1, 2)
	assert1(sim_take_due(s, &from, &to) == 0)
	assert_equal(0, sim_pending(s))
	assert_equal(1, sim_dropped_count(s))
	assert_strings_equal(c"p1", sim_take_dropped(s))
	assert_equal(0, sim_dropped_count(s))
	# the reverse direction is blocked too
	assert_equal(1, sim_send(s, 2, 1, c"p2"))
	assert1(sim_take_due(s, &from, &to) == 0)
	assert_equal(1, sim_dropped_count(s))
	assert_strings_equal(c"p2", sim_take_dropped(s))
	assert1(sim_take_dropped(s) == 0)
	# heal, then a new send delivers
	sim_heal(s, 1, 2)
	assert_equal(1, sim_send(s, 1, 2, c"p3"))
	char* p = sim_take_due(s, &from, &to)
	assert_strings_equal(c"p3", p)
	assert_equal(1, from)
	assert_equal(2, to)
	sim_free(s)


void test_in_flight_survives_heal():
	# Blocking is evaluated at delivery time: a packet sent during the
	# partition delivers when the pair heals before it comes due.
	sim_net* s = sim_new(5, 10, 10, 0)
	int from = 0
	int to = 0
	sim_partition(s, 1, 2)
	assert_equal(1, sim_send(s, 1, 2, c"late"))
	sim_heal(s, 1, 2)
	sim_advance(s, 10)
	assert_strings_equal(c"late", sim_take_due(s, &from, &to))
	assert_equal(1, from)
	assert_equal(2, to)
	assert_equal(0, sim_dropped_count(s))
	sim_free(s)


void test_partition_queries_and_idempotence():
	sim_net* s = sim_new(2, 0, 0, 0)
	assert_equal(0, sim_partitioned(s, 1, 2))
	sim_partition(s, 1, 2)
	assert_equal(1, sim_partitioned(s, 1, 2))
	assert_equal(1, sim_partitioned(s, 2, 1))
	assert_equal(0, sim_partitioned(s, 1, 3))
	# idempotent add in either order: one heal clears the pair
	sim_partition(s, 1, 2)
	sim_partition(s, 2, 1)
	sim_heal(s, 2, 1)
	assert_equal(0, sim_partitioned(s, 1, 2))
	# healing a pair that was never blocked is harmless
	sim_heal(s, 3, 4)
	assert_equal(0, sim_partitioned(s, 3, 4))
	sim_free(s)
