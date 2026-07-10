/*
Compiler lowering for the bit-manipulation intrinsics (#249):

  int shr(int a, int n)    logical (unsigned) right shift by n mod 32
  int rotl(int a, int n)   rotate left by n mod 32
  int rotr(int a, int n)   rotate right by n mod 32
  int popcount(int a)      number of set bits
  int clz(int a)           leading zeros; clz(0) == 32
  int ctz(int a)           trailing zeros; ctz(0) == 32

All six are defined on the operands' LOW 32 BITS AS UNSIGNED, following
the "masked 32-bit word" convention (lib/sha256.w, grammar/limb_builtin.w):
only the low 32 bits of the result are meaningful, and on the 64-bit
targets they come back zero-extended, exactly like a `& mask32` result,
so the same source observes the same low 32 bits on every target.
Shift/rotate counts are masked to 5 bits (count mod 32) — the hardware
behavior of both the x86 32-bit shifts and the A64 w-register LSRV/RORV.

The intrinsics parse as ordinary calls — no new syntax, so the
parser-generator grammar is untouched. They are not reserved words: a
user symbol with one of these names that is already defined at the call
site takes precedence (the shadowing rule from grammar/limb_builtin.w).

This file is compiled by the committed seed: only seed-understood
syntax here.
*/
int expression();


# Intrinsic index for the current token: 1 shr, 2 rotl, 3 rotr,
# 4 popcount, 5 clz, 6 ctz; 0 when the token is not an intrinsic name.
int bit_builtin_kind():
	if (peek(c"shr")):
		return 1
	if (peek(c"rotl")):
		return 2
	if (peek(c"rotr")):
		return 3
	if (peek(c"popcount")):
		return 4
	if (peek(c"clz")):
		return 5
	if (peek(c"ctz")):
		return 6
	return 0


char* bit_builtin_name(int kind):
	if (kind == 1):
		return c"shr"
	if (kind == 2):
		return c"rotl"
	if (kind == 3):
		return c"rotr"
	if (kind == 4):
		return c"popcount"
	if (kind == 5):
		return c"clz"
	return c"ctz"


int bit_builtin_ready():
	if (nextc != '('):
		return 0
	if (bit_builtin_kind() == 0):
		return 0
	if (sym_lookup(token) >= 0):
		return 0
	return 1


# shr/rotl/rotr/popcount/clz/ctz(...): the intrinsic's name is the
# current token and '(' directly follows it. Leaves ')' current for
# primary_expr's trailing get_token(). Operand parsing and the argument
# type mismatch warning are shared with grammar/limb_builtin.w.
int bit_builtin_expr():
	int kind = bit_builtin_kind()
	char* name = bit_builtin_name(kind)
	int int_type = type_lookup(c"int")
	get_token()
	expect(c"(")
	limb_builtin_int_argument(name, 0, int_type)
	if (kind <= 3):
		push_eax()
		stack_pos = stack_pos + 1
		expect(c",")
		limb_builtin_int_argument(name, 1, int_type)
		pop_ebx()
		stack_pos = stack_pos - 1
		if (kind == 1):
			alu_shr32()
		else if (kind == 2):
			alu_rotl32()
		else:
			alu_rotr32()
	else if (kind == 4):
		alu_popcount32()
	else if (kind == 5):
		alu_clz32()
	else:
		alu_ctz32()
	if (peek(c")") == 0):
		diag_part(c"')' expected in ")
		error(name)
	return type_value(int_type)
