# With no import root an addon may import nothing new: the upward
# search is closed to profiled sources.
# wfixture: --profile=script
# expect_fail
# expect_stderr: script profile: import 'lib.file' is not in an import root
import lib.file


int main():
	return 0
# wbuild: fixture_group=script_profile_error_test
