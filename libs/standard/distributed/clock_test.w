# wbuild: x64
import lib.testing
import libs.standard.distributed.clock


# ---- vector clocks ----------------------------------------------------------

void test_vclock_compare_equal():
	vclock* a = vclock_new()
	vclock* b = vclock_new()
	# two empty clocks are equal
	assert_equal(0, vclock_compare(a, b))
	vclock_tick(a, 1)
	vclock_tick(a, 2)
	vclock_tick(b, 2)
	vclock_tick(b, 1)
	assert_equal(0, vclock_compare(a, b))
	assert_equal(0, vclock_compare(b, a))
	vclock_free(a)
	vclock_free(b)


void test_vclock_compare_before_after():
	vclock* a = vclock_new()
	vclock_tick(a, 1)
	vclock* b = vclock_clone(a)
	vclock_tick(b, 1)
	assert_equal(0 - 1, vclock_compare(a, b))
	assert_equal(1, vclock_compare(b, a))
	# dominance via a node a has never seen
	vclock* c = vclock_clone(a)
	vclock_tick(c, 7)
	assert_equal(0 - 1, vclock_compare(a, c))
	assert_equal(1, vclock_compare(c, a))
	vclock_free(a)
	vclock_free(b)
	vclock_free(c)


void test_vclock_compare_concurrent_disjoint():
	# disjoint node sets: neither descends from the other
	vclock* a = vclock_new()
	vclock* b = vclock_new()
	vclock_tick(a, 1)
	vclock_tick(b, 2)
	assert_equal(2, vclock_compare(a, b))
	assert_equal(2, vclock_compare(b, a))
	vclock_free(a)
	vclock_free(b)


void test_vclock_compare_concurrent_crossed():
	# same node set, counters crossing: a = {1:2, 2:1}, b = {1:1, 2:2}
	vclock* a = vclock_new()
	vclock_tick(a, 1)
	vclock_tick(a, 1)
	vclock_tick(a, 2)
	vclock* b = vclock_new()
	vclock_tick(b, 1)
	vclock_tick(b, 2)
	vclock_tick(b, 2)
	assert_equal(2, vclock_compare(a, b))
	assert_equal(2, vclock_compare(b, a))
	vclock_free(a)
	vclock_free(b)


void test_vclock_tick_get():
	vclock* v = vclock_new()
	assert_equal(0, vclock_get(v, 5))
	vclock_tick(v, 5)
	assert_equal(1, vclock_get(v, 5))
	vclock_tick(v, 5)
	vclock_tick(v, 5)
	assert_equal(3, vclock_get(v, 5))
	# other nodes stay at the implicit zero
	assert_equal(0, vclock_get(v, 6))
	vclock_free(v)


void test_vclock_merge_pointwise_max():
	vclock* a = vclock_new()
	vclock_tick(a, 1)
	vclock_tick(a, 1)
	vclock_tick(a, 1)
	vclock_tick(a, 2)
	vclock* b = vclock_new()
	vclock_tick(b, 1)
	vclock_tick(b, 3)
	vclock_tick(b, 3)
	vclock_tick(b, 3)
	vclock_tick(b, 3)
	vclock_merge(a, b)
	assert_equal(3, vclock_get(a, 1))   # a's 3 beats b's 1
	assert_equal(1, vclock_get(a, 2))   # untouched by merge
	assert_equal(4, vclock_get(a, 3))   # adopted from b
	# merged clock descends from both inputs
	assert_equal(1, vclock_descends(a, b))
	# b is unchanged
	assert_equal(1, vclock_get(b, 1))
	assert_equal(0, vclock_get(b, 2))
	assert_equal(4, vclock_get(b, 3))
	vclock_free(a)
	vclock_free(b)


void test_vclock_clone_independent():
	vclock* a = vclock_new()
	vclock_tick(a, 1)
	vclock* b = vclock_clone(a)
	assert_equal(0, vclock_compare(a, b))
	vclock_tick(b, 1)
	vclock_tick(b, 2)
	# mutating the clone leaves the original alone
	assert_equal(1, vclock_get(a, 1))
	assert_equal(0, vclock_get(a, 2))
	assert_equal(2, vclock_get(b, 1))
	assert_equal(1, vclock_get(b, 2))
	assert_equal(0 - 1, vclock_compare(a, b))
	vclock_free(a)
	vclock_free(b)


void test_vclock_descends_truth_table():
	vclock* base = vclock_new()
	vclock_tick(base, 1)
	vclock* same = vclock_clone(base)
	vclock* ahead = vclock_clone(base)
	vclock_tick(ahead, 1)
	vclock* conc = vclock_new()
	vclock_tick(conc, 2)
	# equal: descends both ways
	assert_equal(1, vclock_descends(base, same))
	assert_equal(1, vclock_descends(same, base))
	# strictly after: descends one way only
	assert_equal(1, vclock_descends(ahead, base))
	assert_equal(0, vclock_descends(base, ahead))
	# concurrent: descends neither way
	assert_equal(0, vclock_descends(base, conc))
	assert_equal(0, vclock_descends(conc, base))
	vclock_free(base)
	vclock_free(same)
	vclock_free(ahead)
	vclock_free(conc)


# ---- lamport clocks ---------------------------------------------------------

void test_lamport_tick_sequence():
	lamport_clock* c = lamport_new()
	assert_equal(0, lamport_time(c))
	assert_equal(1, lamport_tick(c))
	assert_equal(2, lamport_tick(c))
	assert_equal(3, lamport_tick(c))
	assert_equal(3, lamport_time(c))
	lamport_free(c)


void test_lamport_observe_remote_ahead():
	lamport_clock* c = lamport_new()
	lamport_tick(c)
	lamport_tick(c)
	# t = 2, remote 10 ahead: max(2, 10) + 1
	assert_equal(11, lamport_observe(c, 10))
	assert_equal(11, lamport_time(c))
	lamport_free(c)


void test_lamport_observe_remote_behind():
	lamport_clock* c = lamport_new()
	int i = 0
	while (i < 5):
		lamport_tick(c)
		i = i + 1
	# t = 5, remote 1 behind: max(5, 1) + 1
	assert_equal(6, lamport_observe(c, 1))
	# tie: max(6, 6) + 1
	assert_equal(7, lamport_observe(c, 6))
	# remote 0 (a fresh peer) still advances the clock
	assert_equal(8, lamport_observe(c, 0))
	lamport_free(c)


# ---- hybrid logical clocks --------------------------------------------------

# out >> 16 as a host int (physical ms part of a packed timestamp).
int hlc_test_physical(u64* out):
	u64* p = u64_clone(out)
	u64_shr(p, 16)
	int v = u64_to_int(p)
	u64_free(p)
	return v


void test_hlc_same_wall_strictly_increases():
	hlc* h = hlc_new()
	u64* wall = u64_new_int(1000)
	u64* a = u64_new()
	u64* b = u64_new()
	u64* c = u64_new()
	hlc_now(h, wall, a)
	hlc_now(h, wall, b)
	hlc_now(h, wall, c)
	assert1(u64_cmp(a, b) < 0)
	assert1(u64_cmp(b, c) < 0)
	# stalled wall clock: physical part frozen, counter increments
	assert_equal(0, a.w0)
	assert_equal(1, b.w0)
	assert_equal(2, c.w0)
	assert_equal(1000, hlc_test_physical(a))
	assert_equal(1000, hlc_test_physical(c))
	u64_free(wall)
	u64_free(a)
	u64_free(b)
	u64_free(c)
	hlc_free(h)


void test_hlc_wall_backwards_still_increases():
	hlc* h = hlc_new()
	u64* wall = u64_new_int(1000)
	u64* prev = u64_new()
	hlc_now(h, wall, prev)
	# wall clock steps backwards
	u64_set_int(wall, 500)
	u64* out = u64_new()
	hlc_now(h, wall, out)
	assert1(u64_cmp(out, prev) > 0)
	# l held at 1000, counter took the tick
	assert_equal(1000, hlc_test_physical(out))
	assert_equal(1, out.w0)
	u64_free(wall)
	u64_free(prev)
	u64_free(out)
	hlc_free(h)


void test_hlc_wall_advance_resets_counter():
	hlc* h = hlc_new()
	u64* wall = u64_new_int(1000)
	u64* out = u64_new()
	hlc_now(h, wall, out)
	hlc_now(h, wall, out)
	hlc_now(h, wall, out)
	assert_equal(2, out.w0)
	u64* prev = u64_clone(out)
	# wall advances past everything: counter resets to 0
	u64_set_int(wall, 2000)
	hlc_now(h, wall, out)
	assert1(u64_cmp(out, prev) > 0)
	assert_equal(2000, hlc_test_physical(out))
	assert_equal(0, out.w0)
	u64_free(wall)
	u64_free(prev)
	u64_free(out)
	hlc_free(h)


void test_hlc_observe_remote_ahead():
	hlc* h = hlc_new()
	u64* wall = u64_new_int(1000)
	u64* prev = u64_new()
	hlc_now(h, wall, prev)
	# remote = (5000 << 16) | 7: physical 5000 ahead of our wall
	u64* remote = u64_new_int(5000)
	u64_shl(remote, 16)
	u64_add_int(remote, 7)
	u64* out = u64_new()
	hlc_observe(h, wall, remote, out)
	assert1(u64_cmp(out, remote) > 0)
	assert1(u64_cmp(out, prev) > 0)
	# only the remote ties for max: c' = rc + 1
	assert_equal(5000, hlc_test_physical(out))
	assert_equal(8, out.w0)
	u64_free(wall)
	u64_free(prev)
	u64_free(remote)
	u64_free(out)
	hlc_free(h)


void test_hlc_observe_equal_physical():
	hlc* h = hlc_new()
	u64* wall = u64_new_int(3000)
	u64* out = u64_new()
	hlc_now(h, wall, out)
	hlc_now(h, wall, out)
	hlc_now(h, wall, out)   # l = 3000, c = 2
	# remote at the same physical time with a bigger counter
	u64* remote = u64_new_int(3000)
	u64_shl(remote, 16)
	u64_add_int(remote, 9)
	hlc_observe(h, wall, remote, out)
	# both tie for max: c' = max(2, 9) + 1
	assert_equal(3000, hlc_test_physical(out))
	assert_equal(10, out.w0)
	# now the local counter is the bigger one: c' = max(10, 1) + 1
	u64_set_int(remote, 3000)
	u64_shl(remote, 16)
	u64_add_int(remote, 1)
	hlc_observe(h, wall, remote, out)
	assert_equal(3000, hlc_test_physical(out))
	assert_equal(11, out.w0)
	u64_free(wall)
	u64_free(remote)
	u64_free(out)
	hlc_free(h)


void test_hlc_observe_wall_ahead_resets():
	hlc* h = hlc_new()
	u64* wall = u64_new_int(1000)
	u64* out = u64_new()
	hlc_now(h, wall, out)
	hlc_now(h, wall, out)   # l = 1000, c = 1
	u64* remote = u64_new_int(900)
	u64_shl(remote, 16)
	u64_add_int(remote, 3)
	u64* prev = u64_clone(out)
	# our wall reading alone is the max: counter restarts at 0
	u64_set_int(wall, 4000)
	hlc_observe(h, wall, remote, out)
	assert1(u64_cmp(out, prev) > 0)
	assert1(u64_cmp(out, remote) > 0)
	assert_equal(4000, hlc_test_physical(out))
	assert_equal(0, out.w0)
	u64_free(wall)
	u64_free(remote)
	u64_free(prev)
	u64_free(out)
	hlc_free(h)


void test_hlc_last_does_not_advance():
	hlc* h = hlc_new()
	u64* wall = u64_new_int(1000)
	u64* t1 = u64_new()
	hlc_now(h, wall, t1)
	u64* t2 = u64_new()
	hlc_last(h, t2)
	assert_equal(1, u64_eq(t1, t2))
	# repeated reads keep returning the same timestamp
	hlc_last(h, t2)
	assert_equal(1, u64_eq(t1, t2))
	# the next event still only advances by one counter step
	u64* t3 = u64_new()
	hlc_now(h, wall, t3)
	assert1(u64_cmp(t3, t1) > 0)
	assert_equal(1, t3.w0)
	u64_free(wall)
	u64_free(t1)
	u64_free(t2)
	u64_free(t3)
	hlc_free(h)


void test_hlc_counter_overflow_bumps_physical():
	hlc* h = hlc_new()
	u64* wall = u64_new_int(100)
	u64* out = u64_new()
	hlc_now(h, wall, out)   # l = 100, c = 0
	int i = 0
	while (i < 65535):
		hlc_now(h, wall, out)
		i = i + 1
	# counter saturated
	assert_equal(65535, out.w0)
	assert_equal(100, hlc_test_physical(out))
	u64* prev = u64_clone(out)
	# one more event: counter wraps to 0 and l borrows a millisecond
	hlc_now(h, wall, out)
	assert1(u64_cmp(out, prev) > 0)
	assert_equal(0, out.w0)
	assert_equal(101, hlc_test_physical(out))
	u64_free(wall)
	u64_free(prev)
	u64_free(out)
	hlc_free(h)
