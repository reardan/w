# Compile-only fixture for c_import_torture_test: C bit-field layout
# under the 32-bit (i386 SysV) rules — storage-unit packing, straddle
# handling, ':0', unnamed bit-fields, typedef/enum-typed bit-fields,
# plain members sharing storage units, tail padding, and union
# bit-fields (tests/c_import_bitfield_fixture.h). The body reads the
# plain members around every bit-field region, so an import or layout
# regression that loses a member fails this compile. Runtime offset and
# size assertions live in tests/x64_c_import_bitfield_test.w (the
# 32-bit dynamic run tests need the i386 loader).
# reject_stderr: c_import:
# reject_stderr: header parse failed
# wbuild: fixture_group=c_import_torture_test
c_import "libc.so.6" c"tests/c_import_bitfield_fixture.h"


int ci_bf_use_all():
	ci_bf_basic* basic = 0
	ci_bf_zero* zero = 0
	ci_bf_straddle* straddle = 0
	ci_bf_unnamed* unnamed = 0
	ci_bf_short* shorts = 0
	ci_bf_wide* wide = 0
	ci_bf_span* span = 0
	ci_bf_mixed* mixed = 0
	ci_bf_typedef* typedefs = 0
	ci_bf_enum* enums = 0
	ci_bf_tail* tail = 0
	ci_bf_llzero* llzero = 0
	ci_bf_union* u = 0
	ci_bf_union_wide* uw = 0
	int total = CI_BF_M1 + CI_BF_M2
	if (basic != 0):
		total = total + basic.a + basic.d
	if ((zero != 0) && (straddle != 0)):
		total = total + zero.b + straddle.c
	if ((unnamed != 0) && (shorts != 0)):
		total = total + unnamed.b + shorts.c
	ci_bf_pack* pack = 0
	if ((wide != 0) && (span != 0) && (pack != 0)):
		total = total + wide.b + span.c + pack.c
	if ((mixed != 0) && (typedefs != 0)):
		total = total + mixed.s + mixed.c + typedefs.c
	if ((enums != 0) && (tail != 0)):
		total = total + enums.v + tail.a
	if ((llzero != 0) && (u != 0) && (uw != 0)):
		total = total + llzero.c + llzero.d + u.c
	return total


int main(int argc, int argv):
	return 0
