# wbuild: arch_only=x64 expect_stdout="x64 c_import bitfield OK"
# True end-to-end for imported C bit-field layout AND member access on
# x86-64 SysV: every sizeof (via &p[1] on a null struct pointer),
# neighboring plain member offset (via &p.member) and bit-field
# read/write result below is pinned against gcc for the battery in
# tests/c_import_bitfield_fixture.h — storage-unit packing, the
# straddle rule, ':0', unnamed bit-fields, typedef/enum bit-field
# types, plain members sharing the storage unit, tail padding, union
# bit-fields, signed sign-extension (negative values), unsigned
# masking, write truncation to width, and read-modify-write leaving
# the neighbors intact. x64-only: the 32-bit twin would need the i386
# loader (see the env-blocked c_import_test family); the i386 shapes
# stay covered compile-only by c_import_bitfield_fixture.w.
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

	# ---- bit-field member access, all values pinned against gcc ----

	# basic: unsigned fields packing into one int unit with plain chars
	# on both sides; writes leave every neighbor intact
	ci_bf_basic bb
	bb.a = 7
	bb.b = 5
	bb.c = 19
	bb.d = 9
	assert_equal(7, bb.a)
	assert_equal(5, bb.b)
	assert_equal(19, bb.c)
	assert_equal(9, bb.d)
	bb.b += 2
	assert_equal(7, bb.b)
	assert_equal(19, bb.c)
	bb.b = 13  # truncates to width: 13 & 7
	assert_equal(5, bb.b)
	# access through a struct pointer takes the same path
	ci_bf_basic* pb = &bb
	pb.c = 21
	assert_equal(21, pb.c)
	assert_equal(21, bb.c)

	# straddle: a 30-bit field filling most of its unit, b in the next
	ci_bf_straddle st
	st.a = (1 << 30) - 5
	st.b = 11
	st.c = 33
	assert_equal((1 << 30) - 5, st.a)
	assert_equal(11, st.b)
	assert_equal(33, st.c)

	# unnamed :24 region between the plain members stays untouched
	ci_bf_unnamed un
	un.a = 1
	un.b = 2
	assert_equal(1, un.a)
	assert_equal(2, un.b)

	# short storage units
	ci_bf_short sh
	sh.a = 5
	sh.b = 300
	sh.c = 77
	assert_equal(5, sh.a)
	assert_equal(300, sh.b)
	assert_equal(77, sh.c)

	# unsigned long long fields above 32 bits
	ci_bf_wide wd
	wd.a = (1 << 33) - 3
	wd.b = 44
	assert_equal((1 << 33) - 3, wd.a)
	assert_equal(44, wd.b)
	ci_bf_span sp
	sp.a = 12345
	sp.b = (1 << 40) - 7
	sp.c = 21
	assert_equal(12345, sp.a)
	assert_equal((1 << 40) - 7, sp.b)
	assert_equal(21, sp.c)
	ci_bf_pack pk
	pk.c = 3
	pk.b = (1 << 39) + 123
	assert_equal(3, pk.c)
	assert_equal((1 << 39) + 123, pk.b)

	# signed int:24 sign-extends on read; neighbors survive the RMW
	ci_bf_mixed mx
	mx.s = 1234
	mx.c = 56
	mx.b = -1
	assert_equal(-1, mx.b)
	mx.b = (1 << 23) - 1
	assert_equal((1 << 23) - 1, mx.b)
	mx.b = -4096
	assert_equal(-4096, mx.b)
	assert_equal(1234, mx.s)
	assert_equal(56, mx.c)

	# typedef'd unsigned short fields
	ci_bf_typedef td
	td.a = 9
	td.b = 4321
	td.c = 65
	assert_equal(9, td.a)
	assert_equal(4321, td.b)
	assert_equal(65, td.c)

	# enum-typed bit-field reads unsigned (gcc: no negative enumerators)
	ci_bf_enum en
	en.mode = CI_BF_M2
	en.rest = (1 << 30) - 1
	en.v = -321
	assert_equal(2, en.mode)
	assert_equal((1 << 30) - 1, en.rest)
	assert_equal(-321, en.v)

	# trailing bit-field unit
	ci_bf_tail tl
	tl.a = 99
	tl.b = 6
	assert_equal(99, tl.a)
	assert_equal(6, tl.b)

	# union bit-fields: b aliases the low bits of c
	ci_bf_union ub
	ub.b = 5
	assert_equal(5, ub.b)
	ub.c = 65
	assert_equal(1, ub.b)  # 65 & 7
	ci_bf_union_wide uwb
	uwb.b = 1
	assert_equal(1, uwb.b)
	uwb.b = 2  # truncates to the single bit
	assert_equal(0, uwb.b)

	# signed vs unsigned: sign extension per the declared type
	ci_bf_signed sg
	sg.a = -4
	assert_equal(-4, sg.a)
	sg.a = 3
	assert_equal(3, sg.a)
	sg.b = -16
	sg.c = 7
	sg.d = -1000000
	assert_equal(-16, sg.b)
	assert_equal(7, sg.c)
	assert_equal(-1000000, sg.d)
	sg.c = -1  # unsigned :3 keeps the low bits
	assert_equal(7, sg.c)
	sg.a = 7  # signed :3 reads 0b111 back as -1
	assert_equal(-1, sg.a)
	sg.a++
	assert_equal(0, sg.a)
	assert_equal(-16, sg.b)
	assert_equal(7, sg.c)
	assert_equal(-1000000, sg.d)

	# signed long long :40 with negative values; unsigned :24 sharing
	# the unit; signed int :20 opening the next unit
	ci_bf_sll sl
	sl.a = -(1 << 39)
	sl.b = (1 << 24) - 2
	sl.c = -500000
	assert_equal(-(1 << 39), sl.a)
	assert_equal((1 << 24) - 2, sl.b)
	assert_equal(-500000, sl.c)
	sl.a = (1 << 39) - 1
	assert_equal((1 << 39) - 1, sl.a)
	assert_equal((1 << 24) - 2, sl.b)
	assert_equal(-500000, sl.c)

	# signed shorts with negative values; 511 is 9 ones, reads as -1
	ci_bf_s16 s6
	s6.a = -200
	s6.b = -64
	s6.c = 1000
	assert_equal(-200, s6.a)
	assert_equal(-64, s6.b)
	assert_equal(1000, s6.c)
	s6.a = 511
	assert_equal(-1, s6.a)

	# same union bits through a signed and an unsigned view
	ci_bf_su su1
	su1.u = 31
	assert_equal(-1, su1.s)
	su1.s = -6
	assert_equal(26, su1.u)

	# bit-field reads compose in larger expressions
	assert_equal(-1004096, sg.d + mx.b)

	println(c"x64 c_import bitfield OK")
	return 0
