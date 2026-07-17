# wbuild: x64
import lib.testing
import libs.standard.distributed.quorum


int quorum_test_strict(int n, int r, int w):
	quorum_config* cfg = quorum_config_new(n, r, w)
	int s = quorum_config_strict(cfg)
	quorum_config_free(cfg)
	return s


void test_strict_truth_table():
	assert_equal(1, quorum_test_strict(3, 2, 2))
	assert_equal(0, quorum_test_strict(3, 1, 1))
	assert_equal(1, quorum_test_strict(3, 3, 1))
	assert_equal(1, quorum_test_strict(5, 3, 3))
	assert_equal(0, quorum_test_strict(5, 2, 3))
	# r or w of 0, or beyond n, is never strict
	assert_equal(0, quorum_test_strict(3, 0, 3))
	assert_equal(0, quorum_test_strict(3, 3, 0))
	assert_equal(0, quorum_test_strict(3, 4, 2))
	assert_equal(0, quorum_test_strict(3, 2, 4))
	# n < 1 is never strict
	assert_equal(0, quorum_test_strict(0, 1, 1))
	# a single replica reading and writing itself overlaps trivially
	assert_equal(1, quorum_test_strict(1, 1, 1))


void test_majority():
	assert_equal(1, quorum_majority(1))
	assert_equal(2, quorum_majority(3))
	assert_equal(3, quorum_majority(5))
	assert_equal(3, quorum_majority(4))


void test_tally_success_edge():
	quorum_tally* t = quorum_tally_new(2, 3)
	assert_equal(0, quorum_tally_succeeded(t))
	assert_equal(0, quorum_tally_failed(t))
	assert_equal(0, quorum_tally_settled(t))
	# first ack: below needed, no edge
	assert_equal(0, quorum_tally_ack(t))
	assert_equal(0, quorum_tally_succeeded(t))
	assert_equal(0, quorum_tally_settled(t))
	# second ack reaches needed: the edge fires exactly here
	assert_equal(1, quorum_tally_ack(t))
	assert_equal(1, quorum_tally_succeeded(t))
	assert_equal(0, quorum_tally_failed(t))
	assert_equal(1, quorum_tally_settled(t))
	# a straggler ack past the edge reports 0
	assert_equal(0, quorum_tally_ack(t))
	assert_equal(1, quorum_tally_succeeded(t))
	assert_equal(1, quorum_tally_settled(t))
	quorum_tally_free(t)


void test_tally_failure_edge():
	quorum_tally* t = quorum_tally_new(2, 3)
	# first nak: one ack short is still winnable (2 of 3 can ack)
	assert_equal(0, quorum_tally_nak(t))
	assert_equal(0, quorum_tally_failed(t))
	assert_equal(0, quorum_tally_settled(t))
	# second nak: only 1 possible ack < 2 needed — failure edge
	assert_equal(1, quorum_tally_nak(t))
	assert_equal(1, quorum_tally_failed(t))
	assert_equal(0, quorum_tally_succeeded(t))
	assert_equal(1, quorum_tally_settled(t))
	# a straggler nak past the edge reports 0
	assert_equal(0, quorum_tally_nak(t))
	assert_equal(1, quorum_tally_failed(t))
	assert_equal(1, quorum_tally_settled(t))
	quorum_tally_free(t)


void test_tally_mixed_failure():
	quorum_tally* t = quorum_tally_new(2, 3)
	assert_equal(0, quorum_tally_ack(t))
	assert_equal(0, quorum_tally_nak(t))
	assert_equal(0, quorum_tally_settled(t))
	# second nak leaves acks stuck at 1 < 2: failure edge
	assert_equal(1, quorum_tally_nak(t))
	assert_equal(0, quorum_tally_succeeded(t))
	assert_equal(1, quorum_tally_failed(t))
	assert_equal(1, quorum_tally_settled(t))
	quorum_tally_free(t)


void test_repair_all_equal():
	vclock* a = vclock_new()
	vclock_tick(a, 1)
	vclock_tick(a, 2)
	list[vclock*] versions = new list[vclock*]
	versions.push(a)
	versions.push(vclock_clone(a))
	versions.push(vclock_clone(a))
	repair_plan* plan = quorum_read_repair(versions)
	assert_equal(0, plan.winner_index)
	assert_equal(0, plan.conflict)
	assert_equal(0, plan.stale.length)
	repair_plan_free(plan)
	vclock_free(versions[2])
	vclock_free(versions[1])
	vclock_free(a)


void test_repair_one_newer():
	vclock* old = vclock_new()
	vclock_tick(old, 1)
	vclock* newer = vclock_clone(old)
	vclock_tick(newer, 1)
	list[vclock*] versions = new list[vclock*]
	versions.push(old)
	versions.push(newer)
	versions.push(vclock_clone(old))
	repair_plan* plan = quorum_read_repair(versions)
	assert_equal(1, plan.winner_index)
	assert_equal(0, plan.conflict)
	assert_equal(2, plan.stale.length)
	assert_equal(0, plan.stale[0])
	assert_equal(2, plan.stale[1])
	repair_plan_free(plan)
	vclock_free(versions[2])
	vclock_free(newer)
	vclock_free(old)


void test_repair_equal_copies_not_stale():
	vclock* old = vclock_new()
	vclock_tick(old, 1)
	vclock* newer = vclock_clone(old)
	vclock_tick(newer, 2)
	list[vclock*] versions = new list[vclock*]
	versions.push(newer)
	versions.push(vclock_clone(newer))
	versions.push(old)
	repair_plan* plan = quorum_read_repair(versions)
	# winner is the first of the two equal newest copies
	assert_equal(0, plan.winner_index)
	assert_equal(0, plan.conflict)
	assert_equal(1, plan.stale.length)
	assert_equal(2, plan.stale[0])
	repair_plan_free(plan)
	vclock_free(versions[1])
	vclock_free(newer)
	vclock_free(old)


void test_repair_concurrent_siblings():
	vclock* base = vclock_new()
	vclock_tick(base, 1)
	vclock* left = vclock_clone(base)
	vclock_tick(left, 2)
	vclock* right = vclock_clone(base)
	vclock_tick(right, 3)
	# sanity: the siblings really are concurrent
	assert_equal(2, vclock_compare(left, right))
	list[vclock*] versions = new list[vclock*]
	versions.push(left)
	versions.push(right)
	versions.push(base)
	repair_plan* plan = quorum_read_repair(versions)
	assert_equal(0 - 1, plan.winner_index)
	assert_equal(1, plan.conflict)
	# only the common ancestor is stale; the siblings are kept for
	# semantic reconciliation
	assert_equal(1, plan.stale.length)
	assert_equal(2, plan.stale[0])
	repair_plan_free(plan)
	vclock_free(right)
	vclock_free(left)
	vclock_free(base)


void test_repair_single_version():
	vclock* only = vclock_new()
	vclock_tick(only, 5)
	list[vclock*] versions = new list[vclock*]
	versions.push(only)
	repair_plan* plan = quorum_read_repair(versions)
	assert_equal(0, plan.winner_index)
	assert_equal(0, plan.conflict)
	assert_equal(0, plan.stale.length)
	repair_plan_free(plan)
	vclock_free(only)
