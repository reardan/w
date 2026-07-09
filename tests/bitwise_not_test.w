import lib.testing


int not_global


void test_basic_not():
	assert_equal(-1, ~0)
	assert_equal(0, ~-1)
	assert_equal(-6, ~5)
	assert_equal(4, ~-5)


void test_identity_with_negation():
	# two's complement: ~a == -a - 1 for any a
	int a = 12345
	assert_equal(-a - 1, ~a)
	a = -7
	assert_equal(-a - 1, ~a)


void test_stacking():
	assert_equal(5, ~~5)
	assert_equal(6, -~5)
	assert_equal(1, !~-1)


void test_binds_tighter_than_binary():
	# ~0 & 4 = (~0) & 4, not ~(0 & 4)
	assert_equal(4, ~0 & 4)
	assert_equal(-5, ~5 + 1)
	assert_equal(240, ~15 & 255)


void test_globals_and_locals_agree():
	not_global = 170
	int local = 170
	assert_equal(~local, ~not_global)
	assert_equal(85, ~not_global & 255)
