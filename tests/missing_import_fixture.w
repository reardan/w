# Compile-only fixture for missing_file_test (#190): the import below
# names a module that exists nowhere on the upward search path, so the
# compile must fail with one clean "cannot locate" diagnostic that
# points at this file's import line — not the freed-buffer garbage or
# the per-directory retry spam the walk used to print.
# expect_fail
# expect_stderr: cannot locate 'lib/definitely_not_a_real_module.w' (searched the current directory and every parent)
# expect_stderr: tests/missing_import_fixture.w:11
# reject_stderr: went up one directory
# reject_stderr: not found error
import lib.definitely_not_a_real_module


int main():
	return 0
