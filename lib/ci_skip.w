/*
Host-capability test skips that CI can turn into failures (issue #531).

A test that cannot run on this host (no display, no /dev/kvm, no
python3/openssl peer for an interop check) reports it through
test_skip(message) instead of a bare println: the message is printed as
before and the call returns, so the test can carry on or exit 0. When
the environment sets W_CI_NO_SKIP (to any value), test_skip prints the
message, a note on stderr, and exits 1 instead, so a CI leg that is
meant to provide the capability fails loudly when it does not, rather
than passing on a SKIP line.

Opt-in suites that need explicit configuration (WVM_TEST_KERNEL,
WVM_TEST_CGROUP, ...) keep plain SKIP lines: they are not missing host
capabilities, and CI only counts them.
*/
import lib.lib
import lib.env


# 1 when W_CI_NO_SKIP is set: skips are failures.
int test_skip_strict():
	return env_get(c"W_CI_NO_SKIP") != 0


# Print message (one line, stdout). Under W_CI_NO_SKIP, exit 1.
void test_skip(char* message):
	println(message)
	if (test_skip_strict()):
		print_error(c"W_CI_NO_SKIP is set: this skip is a failure\n")
		exit(1)
