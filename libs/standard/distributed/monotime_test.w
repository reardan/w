# wbuild: x64
import lib.testing
import libs.standard.distributed.monotime


void test_plain_deltas():
	assert_equal(10, mono_delta_ms(110, 100))
	assert_equal(0 - 10, mono_delta_ms(100, 110))
	assert_equal(0, mono_delta_ms(100, 100))
	assert_equal(1, mono_before(100, 110))
	assert_equal(0, mono_before(110, 100))
	assert_equal(0, mono_before(100, 100))


void test_deadlines():
	int now = 5000
	int deadline = mono_deadline(now, 250)
	assert_equal(0, mono_expired(now, deadline))
	assert_equal(250, mono_remaining_ms(now, deadline))
	assert_equal(100, mono_remaining_ms(now + 150, deadline))
	assert_equal(1, mono_expired(now + 250, deadline))
	assert_equal(1, mono_expired(now + 300, deadline))
	assert_equal(0, mono_remaining_ms(now + 300, deadline))


void test_delta_across_the_32bit_wrap():
	# On the x86 target monotonic_ms wraps a 32-bit int (~24.8 days).
	# Build a timestamp just below the wrap point at runtime (no bit-31
	# literals) and step across it: two's-complement subtraction keeps
	# every delta exact. On 64-bit targets the same expressions simply
	# do not wrap, and the asserted deltas are identical.
	int q = 1 << 30
	int then = q + q - 3                   # 2^31 - 3: wraps to a negative int on x86
	int now = then + 10                    # crosses the wrap on x86
	assert_equal(10, mono_delta_ms(now, then))
	assert_equal(0 - 10, mono_delta_ms(then, now))
	assert_equal(1, mono_before(then, now))
	assert_equal(0, mono_before(now, then))


void test_deadline_across_the_32bit_wrap():
	int q = 1 << 30
	int now = q + q - 5                    # 2^31 - 5
	int deadline = mono_deadline(now, 100) # lands past the wrap on x86
	assert_equal(0, mono_expired(now, deadline))
	assert_equal(100, mono_remaining_ms(now, deadline))
	assert_equal(60, mono_remaining_ms(now + 40, deadline))
	assert_equal(1, mono_expired(now + 100, deadline))
	assert_equal(1, mono_expired(now + 150, deadline))
	assert_equal(0, mono_remaining_ms(now + 150, deadline))
