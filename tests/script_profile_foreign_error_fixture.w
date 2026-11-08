# A module compiled after the runtime from outside the --import-root list
# (here pulled in by a root module's own import) is not the profiled
# file's to name: the allowlist bounds names as well as imports.
# wfixture: --profile=script --import-root=tests/script_profile_roots
# expect_fail
# expect_stderr: script profile: 'sp_outside_value' is declared in a module outside this addon's import roots
import sp_alpha


int main():
	return sp_outside_value()
# wbuild: fixture_group=script_profile_error_test
