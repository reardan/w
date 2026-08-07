# Fixture for c_import_torture_test: imported C bit-field members are
# readable and writable (grammar/promote.w bit_field_promote,
# bit_field_assign_store), but a field no single word-sized load can
# cover — an i386 'long long' field wider than the 4-byte word, like
# ci_bf_wide.a (unsigned long long a : 33) — stays a dedicated compile
# error instead of a miscompile. This fixture compiles for the default
# 32-bit target, where that limit is real; every i386-accessible member
# is exercised positively by c_import_bitfield_fixture.w, and the x64
# run test covers these wide fields with gcc-pinned values.
# expect_fail
# expect_stderr: struct field 'a' is an imported C bit-field that spans more than a word on this target; member access is not supported
# wbuild: fixture_group=c_import_torture_test
c_import "libc.so.6" c"tests/c_import_bitfield_fixture.h"


int main(int argc, int argv):
	ci_bf_wide* wide = 0
	return wide.a
