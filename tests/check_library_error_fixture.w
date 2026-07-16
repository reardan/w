# A library module (no _main) whose body still contains a real error:
# 'w check' must keep reporting errors in main-less compilation units
# even though a missing entry point is no longer one of them. Asserted
# by check_roots_test in build.base.json.
int check_library_error_fixture_broken(int x):
	return undefined_symbol_for_check_fixture(x)
