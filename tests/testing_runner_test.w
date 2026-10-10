# wbuild: x64
# lib/testing.w's runner: filter matching (unit tests below), plus the
# end-to-end behavior of --filter/W_TEST_FILTER, --list, the summary line
# and the W_TEST_LEAKS per-test leak check, driven on a fixture program.
# wbuild: step="bin/wv2 tests/testing_runner_fixture.w -o bin/testing_runner_fixture"
# wbuild: step="bin/testing_runner_fixture" expect_stdout="Summary: 3 passed, 0 failed, 0 skipped" expect_stdout="All tests passed!"
# wbuild: step="bin/testing_runner_fixture" env="W_TEST_FILTER=beta" expect_stdout="Summary: 1 passed, 0 failed, 2 skipped (filter 'beta')" reject_stdout="Run: 'test_clean_alpha()'"
# wbuild: step="bin/testing_runner_fixture --filter=alpha,beta" expect_stdout="Summary: 2 passed, 0 failed, 1 skipped" reject_stdout="test_leaks_one_block"
# wbuild: step="bin/testing_runner_fixture --filter clean" env="W_TEST_FILTER=leaks" expect_stdout="Summary: 2 passed, 0 failed, 1 skipped (filter 'clean')"
# wbuild: step="bin/testing_runner_fixture --filter nomatch" expect_fail expect_stdout="Tests FAILED: the filter matched no test." reject_stdout="All tests passed!"
# wbuild: step="bin/testing_runner_fixture --list --filter=clean" expect_stdout="test_clean_alpha" expect_stdout="test_clean_beta" reject_stdout="Run:" reject_stdout="test_leaks_one_block"
# wbuild: step="bin/testing_runner_fixture" env="W_TEST_LEAKS=1" expect_fail expect_stdout="LEAK: 'test_leaks_one_block()' returned with 1 heap block(s), 40 byte(s) still allocated" expect_stdout="Summary: 2 passed, 1 failed, 0 skipped [leak check]" expect_stdout="Leaked: test_leaks_one_block" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_runner_fixture --filter=clean" env="W_TEST_LEAKS=1" expect_stdout="Summary: 2 passed, 0 failed, 1 skipped (filter 'clean') [leak check]" expect_stdout="All tests passed!"
# wbuild: step="bin/testing_runner_fixture" env="W_TEST_LEAKS=0" expect_stdout="All tests passed!"
# wbuild: step="bin/testing_runner_fixture --list --shard 0/3" expect_stdout="test_clean_alpha" reject_stdout="test_clean_beta" reject_stdout="test_leaks_one_block" reject_stdout="Run:"
# wbuild: step="bin/testing_runner_fixture --list --shard 1/3" expect_stdout="test_clean_beta" reject_stdout="test_clean_alpha" reject_stdout="test_leaks_one_block" reject_stdout="Run:"
# wbuild: step="bin/testing_runner_fixture --list --shard 2/3" expect_stdout="test_leaks_one_block" reject_stdout="test_clean_alpha" reject_stdout="test_clean_beta" reject_stdout="Run:"
# wbuild: step="bin/testing_runner_fixture --shard=0/2" expect_stdout="Summary: 2 passed, 0 failed, 1 skipped [shard 0/2]" reject_stdout="test_clean_beta"
# wbuild: step="bin/testing_runner_fixture --shard=1/2" expect_stdout="Summary: 1 passed, 0 failed, 2 skipped [shard 1/2]" reject_stdout="test_clean_alpha" reject_stdout="test_leaks_one_block"
# wbuild: step="bin/testing_runner_fixture --shard=1/3 --filter=clean" expect_stdout="Summary: 1 passed, 0 failed, 2 skipped (filter 'clean') [shard 1/3]" expect_stdout="test_clean_beta" reject_stdout="test_clean_alpha"
# wbuild: step="bin/testing_runner_fixture --shard=2/3 --filter=clean" expect_fail expect_stdout="Tests FAILED: the shard selected no test" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_runner_fixture --list --shard=3/4" expect_fail expect_stderr="Tests FAILED: the shard selected no test"
# wbuild: step="bin/testing_runner_fixture --shard=3/4" expect_fail expect_stdout="Tests FAILED: the shard selected no test" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_runner_fixture --list --shard=0/2147483647" expect_stdout="test_clean_alpha" reject_stdout="test_clean_beta" reject_stdout="test_leaks_one_block"
# wbuild: step="bin/testing_runner_fixture --shard" expect_fail expect_stderr="--shard requires I/N"
# wbuild: step="bin/testing_runner_fixture --shard=0/0" expect_fail expect_stderr="--shard requires I/N" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_runner_fixture --shard=1/1" expect_fail expect_stderr="--shard requires I/N" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_runner_fixture --shard=-1/2" expect_fail expect_stderr="--shard requires I/N" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_runner_fixture --shard=0/-2" expect_fail expect_stderr="--shard requires I/N" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_runner_fixture --shard=/2" expect_fail expect_stderr="--shard requires I/N" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_runner_fixture --shard=0/" expect_fail expect_stderr="--shard requires I/N" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_runner_fixture --shard=0/2x" expect_fail expect_stderr="--shard requires I/N" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_runner_fixture --shard=0/2147483648" expect_fail expect_stderr="--shard requires I/N" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_runner_fixture --shard=4294967296/2" expect_fail expect_stderr="--shard requires I/N" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_runner_fixture --shard=0/2/3" expect_fail expect_stderr="--shard requires I/N" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_runner_fixture --filter" expect_fail expect_stderr="--filter requires a value" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_runner_fixture --list --filter=nomatch" expect_fail expect_stderr="Tests FAILED: the filter matched no test."
# wbuild: step="bin/testing_runner_fixture" env="W_DEBUG_ALLOC=1" expect_stdout="Summary: 3 passed, 0 failed, 0 skipped" reject_stdout="LEAK:"
# wbuild: step="bin/wv2 x64 tests/testing_runner_fixture.w -o bin/testing_runner_fixture64"
# wbuild: step="bin/testing_runner_fixture64 --shard=1/3" expect_stdout="Summary: 1 passed, 0 failed, 2 skipped [shard 1/3]" reject_stdout="test_clean_alpha" reject_stdout="test_leaks_one_block"
# wbuild: step="bin/testing_runner_fixture64 --shard=0/2147483648" expect_fail expect_stderr="--shard requires I/N"
# wbuild: step="bin/wv2 tests/testing_assertion_fixture.w -o bin/testing_assertion_fixture"
# wbuild: step="bin/testing_assertion_fixture" env="W_ASSERT_KIND=asserts" expect_fail expect_stdout="Summary: 1 passed, 1 failed, 0 skipped" expect_stdout="Tests FAILED: assertion in 'test_failure()'." reject_stdout="test_unreachable" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_assertion_fixture" env="W_ASSERT_KIND=assert1" expect_fail expect_stdout="Summary: 1 passed, 1 failed, 0 skipped" expect_stdout="Tests FAILED: assertion in 'test_failure()'." reject_stdout="test_unreachable" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_assertion_fixture" env="W_ASSERT_KIND=equal" expect_fail expect_stdout="Summary: 1 passed, 1 failed, 0 skipped" expect_stdout="Tests FAILED: assertion in 'test_failure()'." reject_stdout="test_unreachable" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_assertion_fixture" env="W_ASSERT_KIND=hex" expect_fail expect_stdout="Summary: 1 passed, 1 failed, 0 skipped" expect_stdout="Tests FAILED: assertion in 'test_failure()'." reject_stdout="test_unreachable" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_assertion_fixture" env="W_ASSERT_KIND=strings" expect_fail expect_stdout="Summary: 1 passed, 1 failed, 0 skipped" expect_stdout="Tests FAILED: assertion in 'test_failure()'." reject_stdout="test_unreachable" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_assertion_fixture" env="W_ASSERT_KIND=contains" expect_fail expect_stdout="Summary: 1 passed, 1 failed, 0 skipped" expect_stdout="Tests FAILED: assertion in 'test_failure()'." reject_stdout="test_unreachable" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_assertion_fixture" env="W_ASSERT_KIND=lacks" expect_fail expect_stdout="Summary: 1 passed, 1 failed, 0 skipped" expect_stdout="Tests FAILED: assertion in 'test_failure()'." reject_stdout="test_unreachable" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_assertion_fixture" env="W_ASSERT_KIND=bytes" expect_fail expect_stdout="Summary: 1 passed, 1 failed, 0 skipped" expect_stdout="Tests FAILED: assertion in 'test_failure()'." reject_stdout="test_unreachable" reject_stdout="All tests passed!"
# wbuild: step="bin/testing_assertion_fixture" env="W_ASSERT_KIND=near" expect_fail expect_stdout="Summary: 1 passed, 1 failed, 0 skipped" expect_stdout="Tests FAILED: assertion in 'test_failure()'." reject_stdout="test_unreachable" reject_stdout="All tests passed!"
# wbuild: step="bin/wv2 x64 tests/testing_assertion_fixture.w -o bin/testing_assertion_fixture64"
# wbuild: step="bin/testing_assertion_fixture64" env="W_ASSERT_KIND=equal" expect_fail expect_stdout="Summary: 1 passed, 1 failed, 0 skipped" expect_stderr="Assertion failed."
import lib.testing


# Each test restores the runner's filter: the runner itself consults it
# for the tests that follow.
void test_no_filter_selects_everything():
	char* saved = testing_filter
	testing_filter = 0
	assert1(testing_selected(c"test_anything"))
	testing_filter = saved


void test_filter_is_a_substring_match():
	char* saved = testing_filter
	testing_filter = c"pars"
	assert1(testing_selected(c"test_parser_basics"))
	assert1(testing_selected(c"test_json_parse"))
	assert_equal(0, testing_selected(c"test_lexer"))
	testing_filter = saved


void test_filter_pieces_are_alternatives():
	char* saved = testing_filter
	testing_filter = c"lex,json"
	assert1(testing_selected(c"test_lexer"))
	assert1(testing_selected(c"test_json_parse"))
	assert_equal(0, testing_selected(c"test_parser_basics"))
	testing_filter = saved


void test_empty_filter_pieces_are_ignored():
	char* saved = testing_filter
	testing_filter = c",lex,,"
	assert1(testing_selected(c"test_lexer"))
	assert_equal(0, testing_selected(c"test_parser"))
	testing_filter = c",,"
	assert1(testing_selected(c"test_parser"))
	testing_filter = saved


void test_contains_respects_the_length():
	assert1(testing_contains(c"test_abc", c"abX", 2))
	assert_equal(0, testing_contains(c"test_abc", c"abX", 3))
	assert1(testing_contains(c"ab", c"", 0))
	assert_equal(0, testing_contains(c"a", c"ab", 2))


void test_has_prefix():
	assert1(testing_has_prefix(c"--filter=x", c"--filter="))
	assert_equal(0, testing_has_prefix(c"--filte", c"--filter="))
