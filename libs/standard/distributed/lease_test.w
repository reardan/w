# wbuild: x64
import lib.testing
import libs.standard.distributed.lease


void test_fresh_acquire():
	lease_table* t = lease_table_new(100)
	u64* e = u64_new()
	assert_equal(1, lease_acquire(t, 1, 7, 1000, e))
	# the very first grant carries epoch 1
	assert_equal(1, u64_to_int(e))
	assert_equal(7, lease_holder(t, 1, 1000))
	assert_equal(100, lease_remaining_ms(t, 1, 1000))
	assert_equal(60, lease_remaining_ms(t, 1, 1040))
	assert_equal(1, lease_check(t, 1, 7, e, 1099))
	u64_free(e)
	lease_table_free(t)


void test_unknown_resource():
	lease_table* t = lease_table_new(100)
	u64* e = u64_new()
	assert_equal(0 - 1, lease_holder(t, 9, 1000))
	assert_equal(0, lease_remaining_ms(t, 9, 1000))
	assert_equal(0, lease_check(t, 9, 1, e, 1000))
	assert_equal(0, lease_renew(t, 9, 1, e, 1000))
	assert_equal(0, lease_release(t, 9, 1, e))
	u64_free(e)
	lease_table_free(t)


void test_contention_then_expiry():
	lease_table* t = lease_table_new(100)
	u64* e1 = u64_new()
	u64* e2 = u64_new()
	assert_equal(1, lease_acquire(t, 1, 7, 1000, e1))
	# a competing holder is refused while the lease is live, and its
	# epoch_out is left untouched
	u64_set_int(e2, 777)
	assert_equal(0, lease_acquire(t, 1, 8, 1050, e2))
	assert_equal(777, u64_to_int(e2))
	assert_equal(0, lease_acquire(t, 1, 8, 1099, e2))
	assert_equal(7, lease_holder(t, 1, 1099))
	# at the deadline the lease has expired and the competitor wins,
	# with a strictly greater epoch
	assert_equal(1, lease_acquire(t, 1, 8, 1100, e2))
	assert1(u64_cmp(e2, e1) > 0)
	assert_equal(8, lease_holder(t, 1, 1100))
	u64_free(e1)
	u64_free(e2)
	lease_table_free(t)


void test_fencing_stale_writer():
	# The Chubby §2.4 / fencing-token story end to end: A holds epoch
	# e1, stalls, and its lease expires without ever being released;
	# B acquires and gets e2 > e1. The downstream gate rejects A's
	# stale token and accepts B's — A is fenced even though it never
	# learned it lost the lease.
	lease_table* t = lease_table_new(100)
	u64* e1 = u64_new()
	u64* e2 = u64_new()
	assert_equal(1, lease_acquire(t, 5, 1, 0, e1))
	assert_equal(1, lease_acquire(t, 5, 2, 200, e2))
	assert1(u64_cmp(e2, e1) > 0)
	assert_equal(0, lease_check(t, 5, 1, e1, 210))
	assert_equal(1, lease_check(t, 5, 2, e2, 210))
	u64_free(e1)
	u64_free(e2)
	lease_table_free(t)


void test_reacquire_same_holder():
	lease_table* t = lease_table_new(100)
	u64* e1 = u64_new()
	u64* e2 = u64_new()
	assert_equal(1, lease_acquire(t, 3, 7, 1000, e1))
	# a live re-acquire by the same holder succeeds, extends the
	# deadline, and issues a fresh strictly higher epoch
	assert_equal(1, lease_acquire(t, 3, 7, 1050, e2))
	assert1(u64_cmp(e2, e1) > 0)
	assert_equal(100, lease_remaining_ms(t, 3, 1050))
	# the superseded grant's epoch is fenced out immediately
	assert_equal(0, lease_check(t, 3, 7, e1, 1050))
	assert_equal(1, lease_check(t, 3, 7, e2, 1050))
	u64_free(e1)
	u64_free(e2)
	lease_table_free(t)


void test_renew():
	lease_table* t = lease_table_new(100)
	u64* e = u64_new()
	assert_equal(1, lease_acquire(t, 1, 7, 1000, e))
	assert_equal(20, lease_remaining_ms(t, 1, 1080))
	# the right holder+epoch extends by a full ttl from now
	assert_equal(1, lease_renew(t, 1, 7, e, 1080))
	assert_equal(100, lease_remaining_ms(t, 1, 1080))
	# renewal keeps the epoch: the same token still passes the gate
	assert_equal(1, lease_check(t, 1, 7, e, 1080))
	# a wrong epoch does not renew
	u64* wrong = u64_clone(e)
	u64_inc(wrong)
	assert_equal(0, lease_renew(t, 1, 7, wrong, 1080))
	# a wrong holder does not renew
	assert_equal(0, lease_renew(t, 1, 8, e, 1080))
	# after expiry (renewed deadline was 1180) even the right pair fails
	assert_equal(0, lease_renew(t, 1, 7, e, 1180))
	u64_free(e)
	u64_free(wrong)
	lease_table_free(t)


void test_release():
	lease_table* t = lease_table_new(100)
	u64* e1 = u64_new()
	u64* e2 = u64_new()
	assert_equal(1, lease_acquire(t, 1, 7, 1000, e1))
	# a wrong epoch does not release
	u64* wrong = u64_clone(e1)
	u64_inc(wrong)
	assert_equal(0, lease_release(t, 1, 7, wrong))
	assert_equal(7, lease_holder(t, 1, 1010))
	# a wrong holder does not release
	assert_equal(0, lease_release(t, 1, 8, e1))
	# the real holder+epoch releases: holder gone, gate closed
	assert_equal(1, lease_release(t, 1, 7, e1))
	assert_equal(0 - 1, lease_holder(t, 1, 1010))
	assert_equal(0, lease_remaining_ms(t, 1, 1010))
	assert_equal(0, lease_check(t, 1, 7, e1, 1010))
	# releasing the same grant twice reports 0
	assert_equal(0, lease_release(t, 1, 7, e1))
	# another holder can acquire immediately, well before the old
	# deadline, and gets a strictly greater epoch
	assert_equal(1, lease_acquire(t, 1, 8, 1010, e2))
	assert1(u64_cmp(e2, e1) > 0)
	assert_equal(8, lease_holder(t, 1, 1010))
	u64_free(e1)
	u64_free(e2)
	u64_free(wrong)
	lease_table_free(t)


void test_independent_resources():
	lease_table* t = lease_table_new(100)
	u64* ea = u64_new()
	u64* eb = u64_new()
	u64* ec = u64_new()
	assert_equal(1, lease_acquire(t, 1, 7, 1000, ea))
	assert_equal(1, lease_acquire(t, 2, 8, 1000, eb))
	# the fencing counter is global: epochs increase across resources
	assert_equal(1, u64_to_int(ea))
	assert_equal(2, u64_to_int(eb))
	# both are live and neither disturbed the other
	assert_equal(7, lease_holder(t, 1, 1050))
	assert_equal(8, lease_holder(t, 2, 1050))
	assert_equal(1, lease_check(t, 1, 7, ea, 1050))
	assert_equal(1, lease_check(t, 2, 8, eb, 1050))
	# releasing resource 1 leaves resource 2 held
	assert_equal(1, lease_release(t, 1, 7, ea))
	assert_equal(0 - 1, lease_holder(t, 1, 1050))
	assert_equal(8, lease_holder(t, 2, 1050))
	# the next grant anywhere continues the global sequence
	assert_equal(1, lease_acquire(t, 1, 9, 1050, ec))
	assert_equal(3, u64_to_int(ec))
	u64_free(ea)
	u64_free(eb)
	u64_free(ec)
	lease_table_free(t)


void test_acquire_across_the_32bit_wrap():
	# On the x86 target monotonic_ms wraps a 32-bit int (~24.8 days).
	# Build a timestamp just below the wrap point at runtime (no bit-31
	# literals) and lease across it: expiry must land exactly ttl later
	# even though the deadline wraps negative. On 64-bit targets the
	# same expressions simply do not wrap and the asserts are identical.
	lease_table* t = lease_table_new(100)
	u64* e1 = u64_new()
	u64* e2 = u64_new()
	int q = 1 << 30
	int now = q + q - 50                   # 2^31 - 50: deadline crosses the wrap on x86
	assert_equal(1, lease_acquire(t, 1, 7, now, e1))
	assert_equal(100, lease_remaining_ms(t, 1, now))
	# one ms before the deadline — already past the wrap on x86
	assert_equal(7, lease_holder(t, 1, now + 99))
	assert_equal(1, lease_remaining_ms(t, 1, now + 99))
	assert_equal(1, lease_check(t, 1, 7, e1, now + 99))
	# exactly ttl later the lease has expired
	assert_equal(0, lease_check(t, 1, 7, e1, now + 100))
	assert_equal(0 - 1, lease_holder(t, 1, now + 100))
	assert_equal(0, lease_remaining_ms(t, 1, now + 100))
	assert_equal(0, lease_renew(t, 1, 7, e1, now + 100))
	# and a new holder can take it on the far side of the wrap
	assert_equal(1, lease_acquire(t, 1, 8, now + 100, e2))
	assert1(u64_cmp(e2, e1) > 0)
	u64_free(e1)
	u64_free(e2)
	lease_table_free(t)
