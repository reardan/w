# c_import binds a whole C header.
# wfixture: --profile=script
# expect_fail
# expect_stderr: script profile: c_import is not allowed
c_import "libc.so.6" "tests/c_import_fixture.h"


int main():
	return 0
# wbuild: fixture_group=script_profile_error_test
