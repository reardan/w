/*
GPU atomic intrinsics (docs/projects/cuda.md Stage 4):

  int     atomic_add(int* p, int v)         old value; also float32 form
  int     atomic_min(int* p, int v)         signed; int* only
  int     atomic_max(int* p, int v)         signed; int* only
  float32 atomic_add(float32* p, float32 v)

Each returns the value at *p from before the update (the PTX atom
result operand). Device (PTX) bodies only — host use is a compile
error. The pointer must reference device-accessible global memory
(gpu_alloc/gpu_device_alloc); atomics on stack locals are undefined on
the GPU. float64 atomics need sm_60 and the module targets sm_52, so
float64* operands are rejected.

The intrinsics parse as ordinary calls — no new syntax, so the
parser-generator grammar is untouched — and are not reserved words: a
user symbol with one of these names that is already defined at the
call site takes precedence (the limb-intrinsic shadowing rule).

This file is compiled by the committed seed: only seed-understood
syntax here.
*/
int expression();


# Intrinsic index for the current token: 1 atomic_add, 2 atomic_min,
# 3 atomic_max; 0 when the token is not an intrinsic name.
int atomic_builtin_kind():
	if (peek(c"atomic_add")):
		return 1
	if (peek(c"atomic_min")):
		return 2
	if (peek(c"atomic_max")):
		return 3
	return 0


char* atomic_builtin_name(int kind):
	if (kind == 1):
		return c"atomic_add"
	if (kind == 2):
		return c"atomic_min"
	return c"atomic_max"


int atomic_builtin_ready():
	if (nextc != '('):
		return 0
	if (atomic_builtin_kind() == 0):
		return 0
	if (sym_lookup(token) >= 0):
		return 0
	return 1


# atomic_add/atomic_min/atomic_max(...): the intrinsic's name is the
# current token and '(' directly follows. Leaves ')' current for
# primary_expr's trailing get_token().
int atomic_builtin_expr():
	int kind = atomic_builtin_kind()
	char* name = atomic_builtin_name(kind)
	if (target_isa != 3):
		error(c"atomic_add/atomic_min/atomic_max are only available in gpu code")
	int int_type = type_lookup(c"int")
	get_token()
	expect(c"(")

	# The target pointer: int* (all three ops) or float32* (add only)
	int got = expression()
	got = promote(got)
	int pointer_type = type_unqualified(got)
	int flavor = 0 /* 1 = int, 2 = float32 */
	if (type_get_pointer_level(pointer_type) == 1):
		int pointee = type_lookup_previous_pointer(pointer_type)
		if (pointee >= 0):
			int unqual = type_unqualified(pointee)
			if (unqual == int_type):
				flavor = 1
			if (unqual == float32_type):
				flavor = 2
	if (flavor == 0):
		error(c"gpu atomics require an int* or float32* first argument")
	if ((flavor == 2) & (kind != 1)):
		error(c"atomic_min/atomic_max require an int* first argument")
	push_eax()
	stack_pos = stack_pos + 1

	expect(c",")
	int value_type = expression()
	value_type = promote(value_type)
	if (flavor == 2):
		coerce(float32_type, value_type)
	else:
		coerce(int_type, value_type)
	pop_ebx()
	stack_pos = stack_pos - 1

	if (flavor == 2):
		ptx_atomic_add_f32()
	else:
		ptx_atomic_int(kind)
	if (peek(c")") == 0):
		diag_part(c"')' expected in ")
		error(name)
	if (flavor == 2):
		return float32_value_type
	return type_value(int_type)
