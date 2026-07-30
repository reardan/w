# Fixture for c_import_torture_test: old-style (K&R) C declarations.
# Unprototyped declarations (`int foo()`, `int foo(a, b)`) import as
# variadic functions with zero fixed parameters — the body below calls
# every one, which fails the compile if the import skipped them — and a
# K&R function *definition* (declaration list between declarator and
# body) parses without failing the header. Before this support, K&R
# identifier parameters were mistaken for typedef names and failed the
# whole compile with "unsupported C type", and `int foo()` shapes were
# skipped as "unspecified parameters".
# reject_stderr: unsupported C type
# reject_stderr: header parse failed
# wbuild: fixture_group=c_import_torture_test
c_import "libc.so.6" c"tests/c_import_knr_fixture.h"


int ci_knr_use_all():
	int n = ci_knr_no_params()
	n = n + ci_knr_extern_no_params()
	n = n + ci_knr_ident_params(1, c"two")
	char* s = ci_knr_ptr_ret(c"name")
	n = n + ci_knr_long_ret()
	if (s != 0):
		n = n + 1
	return n


int main(int argc, int argv):
	return 0
