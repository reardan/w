# Driven by tests/testing_runner_test.w: a lib/testing.w program with two
# clean tests and one that leaks a heap block, for the runner's filter,
# --list, summary and W_TEST_LEAKS steps.
import lib.testing


void test_clean_alpha():
	char* p = cast(char*, malloc(32))
	p[0] = 'a'
	free(p)


void test_clean_beta():
	assert_equal(4, 2 + 2)


char* runner_fixture_kept


void test_leaks_one_block():
	runner_fixture_kept = cast(char*, malloc(40))
	runner_fixture_kept[0] = 'x'
