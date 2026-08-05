/*
Atomic intrinsics: the GPU forms (docs/projects/cuda.md Stage 4) plus
the host x86/x64 forms (docs/projects/threads.md staging item 3):

  int     atomic_add(int* p, int v)         old value; gpu + host x86/x64
  int     atomic_min(int* p, int v)         signed; int* only; gpu only
  int     atomic_max(int* p, int v)         signed; int* only; gpu only
  float32 atomic_add(float32* p, float32 v) gpu only
  int     atomic_cas(int* p, int expected, int desired)  host x86/x64 only

Each returns the value at *p from before the update (the PTX atom
result operand / the x86 fetched value), so the shared name means the
same thing on both sides of a kernel launch. In device (PTX) bodies
the pointer must reference device-accessible global memory
(gpu_alloc/gpu_device_alloc); atomics on stack locals are undefined on
the GPU. float64 atomics need sm_60 and the module targets sm_52, so
float64* operands are rejected.

The host lowering is a lock-prefixed x86 read-modify-write at the full
word width (lock xadd / lock cmpxchg, code_generator/x86.w), a full
barrier on x86/x64; lib/thread.w's mutex and condvar build on it.
atomic_min/atomic_max stay device-only (a host lowering needs a
cmpxchg loop) and atomic_cas host-only (the PTX twin, atom.cas.b32, is
unimplemented); the arm64 (LSE/ll-sc) and wasm (threads proposal) host
ports are staged in docs/projects/threads.md.

The intrinsics parse as ordinary calls — no new syntax, so the
parser-generator grammar is untouched — and are not reserved words: a
user symbol with one of these names that is already defined at the
call site takes precedence (the limb-intrinsic shadowing rule).

This file is compiled by the committed seed: only seed-understood
syntax here.
*/
int expression();


# Intrinsic index for the current token: 1 atomic_add, 2 atomic_min,
# 3 atomic_max, 4 atomic_cas; 0 when the token is not an intrinsic name.
int atomic_builtin_kind():
	if (peek(c"atomic_add")):
		return 1
	if (peek(c"atomic_min")):
		return 2
	if (peek(c"atomic_max")):
		return 3
	if (peek(c"atomic_cas")):
		return 4
	return 0


char* atomic_builtin_name(int kind):
	if (kind == 1):
		return c"atomic_add"
	if (kind == 2):
		return c"atomic_min"
	if (kind == 3):
		return c"atomic_max"
	return c"atomic_cas"


int atomic_builtin_ready():
	if (nextc != '('):
		return 0
	if (atomic_builtin_kind() == 0):
		return 0
	if (sym_lookup(token) >= 0):
		return 0
	return 1


# atomic_add/atomic_min/atomic_max/atomic_cas(...): the intrinsic's
# name is the current token and '(' directly follows. Leaves ')'
# current for primary_expr's trailing get_token().
int atomic_builtin_expr():
	int kind = atomic_builtin_kind()
	char* name = atomic_builtin_name(kind)
	int on_gpu = 0
	if (target_isa == 3):
		on_gpu = 1
	if (on_gpu && (kind == 4)):
		error(c"atomic_cas is not available in gpu code yet")
	if (on_gpu == 0):
		if ((kind == 2) || (kind == 3)):
			error(c"atomic_min/atomic_max are only available in gpu code")
		if (target_isa != 0):
			error(c"host atomics are not available on this target yet")
	int int_type = type_lookup(c"int")
	get_token()
	expect(c"(")

	# The target pointer: int* (all ops), or float32* for gpu atomic_add
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
	if (on_gpu):
		if (flavor == 0):
			error(c"gpu atomics require an int* or float32* first argument")
		if ((flavor == 2) && (kind != 1)):
			error(c"atomic_min/atomic_max require an int* first argument")
	else:
		if (flavor != 1):
			error(c"host atomics require an int* first argument")
	push_eax()
	stack_pos = stack_pos + 1

	expect(c",")
	if (kind == 4):
		# expected and desired: the pointer sits pushed under the
		# expected value; the emitter takes the pointer in ebx, expected
		# in eax and desired in ecx (the mul_wide/add_carry register
		# plan from grammar/limb_builtin.w).
		limb_builtin_int_argument(name, 1, int_type)
		push_eax()
		stack_pos = stack_pos + 1
		expect(c",")
		limb_builtin_int_argument(name, 2, int_type)
		mov_ecx_eax()
		pop_eax()
		pop_ebx()
		stack_pos = stack_pos - 2
		alu_atomic_cas()
	else:
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
			if (on_gpu):
				ptx_atomic_int(kind)
			else:
				alu_atomic_add()
	if (peek(c")") == 0):
		diag_part(c"')' expected in ")
		error(name)
	if (flavor == 2):
		return float32_value_type
	return type_value(int_type)
