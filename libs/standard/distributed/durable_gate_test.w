# wbuild: x64
import lib.testing
import libs.standard.distributed.durable_gate


/*
The durable completion gate on its own, with no Raft or storage
underneath: messages wait for the sequence they depend on, a completion
releases exactly the covered prefix in hold order, and a failure hands
every held message back and keeps the gate failed.
*/


void test_release_waits_for_covering_sequence():
	durable_gate* g = durable_gate_new()
	list[char*] out = new list[char*]
	assert_equal(1, durable_gate_hold(g, c"ack-1", 1))
	assert_equal(1, durable_gate_hold(g, c"ack-3", 3))
	assert_equal(1, durable_gate_hold(g, c"ack-2", 2))
	assert_equal(3, durable_gate_pending(g))
	# nothing is durable yet: nothing leaves
	assert_equal(0, durable_gate_complete(g, 0, out))
	assert_equal(0, out.length)
	# writes through 2 are durable: ack-1 and ack-2, in hold order
	assert_equal(2, durable_gate_complete(g, 2, out))
	assert_equal(2, out.length)
	assert_strings_equal(c"ack-1", out[0])
	assert_strings_equal(c"ack-2", out[1])
	assert_equal(1, durable_gate_pending(g))
	assert_equal(2, durable_gate_durable_seq(g))
	# a stale (lower) completion never moves the durable mark back
	assert_equal(0, durable_gate_complete(g, 1, out))
	assert_equal(2, durable_gate_durable_seq(g))
	assert_equal(1, durable_gate_complete(g, 3, out))
	assert_strings_equal(c"ack-3", out[2])
	assert_equal(0, durable_gate_pending(g))
	# a message whose writes are already durable leaves at the next completion
	assert_equal(1, durable_gate_hold(g, c"late", 1))
	assert_equal(1, durable_gate_complete(g, 3, out))
	assert_strings_equal(c"late", out[3])
	durable_gate_free(g)


void test_failed_sync_never_releases():
	durable_gate* g = durable_gate_new()
	list[char*] out = new list[char*]
	list[char*] dropped = new list[char*]
	durable_gate_hold(g, c"a", 1)
	durable_gate_hold(g, c"b", 2)
	assert_equal(1, durable_gate_complete(g, 1, out))
	# the sync covering b fails: b comes back for disposal, never as success
	assert_equal(1, durable_gate_fail(g, dropped))
	assert_equal(1, dropped.length)
	assert_strings_equal(c"b", dropped[0])
	assert_equal(1, durable_gate_failed(g))
	# sticky: later holds are refused and later completions release nothing
	assert_equal(0, durable_gate_hold(g, c"c", 3))
	assert_equal(0, durable_gate_complete(g, 99, out))
	assert_equal(1, out.length)
	assert_equal(0, durable_gate_pending(g))
	durable_gate_free(g)
