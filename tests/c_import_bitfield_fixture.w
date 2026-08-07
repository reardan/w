# Compile-only fixture for c_import_torture_test: C bit-field layout
# under the 32-bit (i386 SysV) rules — storage-unit packing, straddle
# handling, ':0', unnamed bit-fields, typedef/enum-typed bit-fields,
# plain members sharing storage units, tail padding, and union
# bit-fields (tests/c_import_bitfield_fixture.h). The body reads the
# plain members around every bit-field region, so an import or layout
# regression that loses a member fails this compile, and reads AND
# writes every bit-field member accessible on i386 (everything except
# the 'long long' fields wider than the 4-byte word — those stay a
# compile error, pinned by c_import_bitfield_access_fixture.w), so the
# 32-bit extract/insert codegen keeps compiling. Runtime offset, size
# and access-value assertions live in tests/x64_c_import_bitfield_test.w
# (the 32-bit dynamic run tests need the i386 loader).
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


# Read and write every bit-field member the i386 word covers: int and
# short units, straddle-adjusted fields, typedef/enum types, unions,
# signed and unsigned, and the sub-word windows of 'long long' units
# (ci_bf_sll.b spans bytes 4..8 of its 8-byte unit; ci_bf_union_wide.b
# reads through a 4-byte window at offset 0). Compile-only: the i386
# extract and read-modify-write sequences must assemble.
int ci_bf_access_all():
	int total = 0
	ci_bf_basic bb
	bb.b = 5
	bb.c = 19
	bb.b += 2
	total = total + bb.b + bb.c
	ci_bf_straddle st
	st.a = (1 << 30) - 5
	st.b = 11
	total = total + st.a + st.b
	ci_bf_short sh
	sh.b = 300
	total = total + sh.b
	ci_bf_mixed mx
	mx.b = -4096
	total = total + mx.b
	ci_bf_typedef td
	td.a = 9
	td.b = 4321
	total = total + td.a + td.b
	ci_bf_enum en
	en.mode = CI_BF_M2
	en.rest = (1 << 30) - 1
	total = total + en.mode + en.rest
	ci_bf_tail tl
	tl.b = 6
	total = total + tl.b
	ci_bf_union ub
	ub.b = 5
	total = total + ub.b
	ci_bf_union_wide uwb
	uwb.b = 1
	total = total + uwb.b
	ci_bf_signed sg
	sg.a = -4
	sg.b = -16
	sg.c = 7
	sg.d = -1000000
	sg.a++
	total = total + sg.a + sg.b + sg.c + sg.d
	ci_bf_sll sl
	sl.b = (1 << 24) - 2
	sl.c = -500000
	total = total + sl.b + sl.c
	ci_bf_s16 s6
	s6.a = -200
	s6.b = -64
	s6.c = 1000
	total = total + s6.a + s6.b + s6.c
	ci_bf_su su1
	su1.u = 31
	total = total + su1.s
	return total


int main(int argc, int argv):
	return 0
