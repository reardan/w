# wbuild: arch_only=x64 expect_stdout="x64 c_import knr OK"
# True end-to-end for the K&R and extern-array import paths: labs and
# atol are declared old-style (unprototyped / identifier-list), so the
# calls below go through the variadic zero-fixed-parameter lowering and
# must still hit the real libc functions; tzname is the unknown-length
# extern array shape (imported by address, filled by the loader), read
# after tzset() populates it. x64-only: the 32-bit twin would need the
# i386 loader (see the env-blocked c_import_test family).
import lib.lib
import lib.assert

c_import "libc.so.6" c"tests/x64_c_import_knr_fixture.h"


int main(int argc, int argv):
	assert_equal(7, labs(-7))
	assert_equal(42, atol(c"42"))
	tzset()
	assert1(tzname[0] != 0)
	assert1(tzname[1] != 0)
	assert1(strlen(tzname[0]) > 0)
	println(c"x64 c_import knr OK")
	return 0
