# wbuild: arch_only=x64 expect_stdout="x64 c_import bitfield OK"
# True end-to-end for imported C bit-field layout on x86-64 SysV: every
# sizeof (via &p[1] on a null struct pointer) and neighboring plain
# member offset (via &p.member) below is pinned against gcc/clang for
# the battery in tests/c_import_bitfield_fixture.h — storage-unit
# packing, the straddle rule, ':0', unnamed bit-fields, typedef/enum
# bit-field types, plain members sharing the storage unit, tail
# padding, and union bit-fields. x64-only: the 32-bit twin would need
# the i386 loader (see the env-blocked c_import_test family); the i386
# shapes stay covered compile-only by c_import_bitfield_fixture.w.
import lib.lib
import lib.assert

c_import "libc.so.6" c"tests/c_import_bitfield_fixture.h"


int main(int argc, int argv):
	# char a; uint b:3; uint c:5; char d — b/c pack into the int unit
	# right after a; d shares that unit at byte 2
	ci_bf_basic* basic = 0
	assert_equal(4, cast(int, &basic[1]))
	assert_equal(2, cast(int, &basic.d))

	# char a; int :0; char b — ':0' closes the int unit; no alignment
	# contribution (size 5, not 8)
	ci_bf_zero* zero = 0
	assert_equal(5, cast(int, &zero[1]))
	assert_equal(4, cast(int, &zero.b))

	# uint a:30; uint b:4 — b would straddle the int unit boundary, so
	# it moves to the next unit; c shares b's unit
	ci_bf_straddle* straddle = 0
	assert_equal(8, cast(int, &straddle[1]))
	assert_equal(5, cast(int, &straddle.c))

	# unnamed uint:24 allocates bits without affecting struct alignment
	ci_bf_unnamed* unnamed = 0
	assert_equal(5, cast(int, &unnamed[1]))
	assert_equal(4, cast(int, &unnamed.b))

	# ushort b:9 cannot fit the first short unit after a, moves to bits
	# 16..24; c at the next free byte
	ci_bf_short* shorts = 0
	assert_equal(6, cast(int, &shorts[1]))
	assert_equal(4, cast(int, &shorts.c))

	# ull a:33 spans 5 bytes; b shares the 8-byte unit at byte 5
	ci_bf_wide* wide = 0
	assert_equal(8, cast(int, &wide[1]))
	assert_equal(5, cast(int, &wide.b))

	# ull b:40 after uint a:30 straddles the 8-byte unit, moves to byte
	# 8; c at byte 13; tail-padded to the long long alignment
	ci_bf_span* span = 0
	assert_equal(16, cast(int, &span[1]))
	assert_equal(13, cast(int, &span.c))

	# ull b:40 fits the 8-byte unit right after c (on i386 it may span
	# its two 4-byte units — same size there, compile-only covered)
	ci_bf_pack* pack = 0
	assert_equal(8, cast(int, &pack[1]))

	# int b:24 after a short straddles its int unit, moves to byte 4;
	# c shares the unit at byte 7
	ci_bf_mixed* mixed = 0
	assert_equal(8, cast(int, &mixed[1]))
	assert_equal(0, cast(int, &mixed.s))
	assert_equal(7, cast(int, &mixed.c))

	# typedef'd ushort bit-fields keep the underlying type's units
	ci_bf_typedef* typedefs = 0
	assert_equal(6, cast(int, &typedefs[1]))
	assert_equal(4, cast(int, &typedefs.c))

	# enum-typed bit-field packs into an int unit with uint rest:30
	ci_bf_enum* enums = 0
	assert_equal(8, cast(int, &enums[1]))
	assert_equal(4, cast(int, &enums.v))

	# trailing bit-field region is materialized and tail-padded
	ci_bf_tail* tail = 0
	assert_equal(8, cast(int, &tail[1]))

	# 'long long :0' closes an 8-byte unit even between chars
	ci_bf_llzero* llzero = 0
	assert_equal(9, cast(int, &llzero[1]))
	assert_equal(8, cast(int, &llzero.d))

	# union bit-fields size the union like their declared type's bytes
	ci_bf_union* u = 0
	assert_equal(4, cast(int, &u[1]))
	ci_bf_union_wide* uw = 0
	assert_equal(8, cast(int, &uw[1]))

	# imported enum constants still evaluate
	assert_equal(1, CI_BF_M1)
	assert_equal(2, CI_BF_M2)

	# runtime read/write through the plain members around bit-fields:
	# distinct values survive, so the members do not alias the bit
	# storage or each other
	ci_bf_mixed m
	m.s = 1234
	m.c = 56
	assert_equal(1234, m.s)
	assert_equal(56, m.c)
	ci_bf_basic b
	b.a = 7
	b.d = 9
	assert_equal(7, b.a)
	assert_equal(9, b.d)

	println(c"x64 c_import bitfield OK")
	return 0
