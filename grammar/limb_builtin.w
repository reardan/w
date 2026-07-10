/*
Compiler lowering for the 32-bit limb-arithmetic intrinsics (#213):

  int mul_hi(int a, int b)                 high 32 bits of the unsigned product
  int mul_wide(int a, int b, int* hi)      low 32 bits; the high half to *hi
  int add_carry(int a, int b, int* carry)  (a+b) mod 2^32; carry-out (0/1) to *carry

All three are defined on the operands' LOW 32 BITS AS UNSIGNED: every
backend's hardware produces the full product/carry for free (x86 MUL ->
EDX:EAX, A64 UMULL), while W's word-sized signed int cannot reach the
high half — the gap every 32-bit-safe crypto module worked around with
undersized limbs. Results follow the "masked 32-bit word" convention
(lib/sha256.w): only the low 32 bits are meaningful, and on the 64-bit
targets they come back zero-extended, exactly like a `& mask32` result,
so the same source observes the same low 32 bits on every target.

The intrinsics parse as ordinary calls — no new syntax, so the
parser-generator grammar is untouched. They are not reserved words: a
user symbol with one of these names that is already defined at the call
site takes precedence (the prelude-helper shadowing rule from
grammar/print_builtin.w).

This file is compiled by the committed seed: only seed-understood
syntax here.
*/
int expression();


# Intrinsic index for the current token: 1 mul_hi, 2 mul_wide,
# 3 add_carry; 0 when the token is not an intrinsic name.
int limb_builtin_kind():
	if (peek(c"mul_hi")):
		return 1
	if (peek(c"mul_wide")):
		return 2
	if (peek(c"add_carry")):
		return 3
	return 0


char* limb_builtin_name(int kind):
	if (kind == 1):
		return c"mul_hi"
	if (kind == 2):
		return c"mul_wide"
	return c"add_carry"


int limb_builtin_ready():
	if (nextc != '('):
		return 0
	if (limb_builtin_kind() == 0):
		return 0
	if (sym_lookup(token) >= 0):
		return 0
	return 1


# The check_call_argument warning, with the intrinsic standing in for the
# callee symbol so call sites read like any function's type mismatch.
void limb_builtin_check_argument(char* name, int arg_index, int param_type, int arg_type):
	if (types_compatible_with_expression(param_type, arg_type)):
		return;
	diag_part(c"warning: function '")
	diag_part(name)
	diag_part(c"' argument ")
	diag_part(itoa(arg_index + 1))
	diag_part(c" type mismatch: expected '")
	print_error_type(param_type)
	diag_part(c"', got '")
	print_error_type(arg_type)
	warning(c"'")


# One int-valued operand, left in eax.
void limb_builtin_int_argument(char* name, int arg_index, int int_type):
	int got = expression()
	got = promote(got)
	limb_builtin_check_argument(name, arg_index, int_type, got)
	coerce(int_type, got)


# mul_hi/mul_wide/add_carry(...): the intrinsic's name is the current
# token and '(' directly follows it. Leaves ')' current for
# primary_expr's trailing get_token().
int limb_builtin_expr():
	int kind = limb_builtin_kind()
	char* name = limb_builtin_name(kind)
	int int_type = type_lookup(c"int")
	get_token()
	expect(c"(")
	limb_builtin_int_argument(name, 0, int_type)
	push_eax()
	stack_pos = stack_pos + 1
	expect(c",")
	limb_builtin_int_argument(name, 1, int_type)
	if (kind == 1):
		pop_ebx()
		stack_pos = stack_pos - 1
		alu_mul_hi()
	else:
		push_eax()
		stack_pos = stack_pos + 1
		expect(c",")
		int pointer_type = type_get_next_pointer(int_type)
		int got = expression()
		got = promote(got)
		limb_builtin_check_argument(name, 2, pointer_type, got)
		coerce(pointer_type, got)
		mov_ecx_eax()
		pop_eax()
		pop_ebx()
		stack_pos = stack_pos - 2
		if (kind == 2):
			alu_mul_wide()
		else:
			alu_add_carry()
	if (peek(c")") == 0):
		diag_part(c"')' expected in ")
		error(name)
	return type_value(int_type)
