# Fixture for c_import_missing_header_test: a c_import naming a header
# path that does not exist must fail with pp_directives.w's
# "could not read" diagnostic (cpp_preprocess_file_into). This pins the
# branch's reachable route: the top-level entry (cpp_preprocess_file)
# takes the header path straight from the c_import statement with no
# existence pre-check, unlike the #include route, where
# cpp_find_include has already path_exists-checked the path and only
# the stat-then-open TOCTOU window remains.
# expect_fail
# expect_stderr: c preprocessor: could not read tests/c_import_missing_header_fixture_no_such.h
c_import "libc.so.6" c"tests/c_import_missing_header_fixture_no_such.h"


int main(int argc, int argv):
	return 0
