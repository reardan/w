/*
Atomic intrinsics: GPU read-modify-writes (docs/projects/cuda.md Stage 4),
x86/x64 read-modify-writes, and portable host ordering (threads.md):

  int     atomic_add(int* p, int v)         old value; gpu + host x86/x64
  int     atomic_min(int* p, int v)         signed; int* only; gpu only
  int     atomic_max(int* p, int v)         signed; int* only; gpu only
  float32 atomic_add(float32* p, float32 v) gpu only
  int     atomic_cas(int* p, int expected, int desired)  host x86/x64 only
  int     atomic_load(int* p)             acquire; host x86/x64/arm64
  void    atomic_store(int* p, int v)      release; host x86/x64/arm64
  void    atomic_fence()                  seq-cst; host x86/x64/arm64
  int     atomic_load_relaxed(int* p)     relaxed; host x86/x64/arm64
  void    atomic_store_relaxed(int* p, int v) relaxed; host x86/x64/arm64

The read-modify-write forms return the old value (the PTX atom result
operand / the x86 fetched value), so the shared name means the
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
unimplemented); their arm64 (LSE/ll-sc) and wasm (threads proposal) ports
are staged in docs/projects/threads.md. Word loads/stores and fences have
x86/x64 and ARM64 lowerings now, with ordering documented there.

The intrinsics parse as ordinary calls — no new syntax, so the
parser-generator grammar is untouched — and are not reserved words: a
user symbol with one of these names that is already defined at the
call site takes precedence (the limb-intrinsic shadowing rule).

This file is compiled by the committed seed: only seed-understood
syntax here.
*/
int expression();


# Intrinsic index for the current token: 1 atomic_add, 2 atomic_min,
# 3 atomic_max, 4 atomic_cas, 5 load, 6 store, 7 fence, 8/9 relaxed
# load/store; 0 when the token is not an intrinsic name.
int atomic_builtin_kind():
	if (peek(c"atomic_add")): return 1
	if (peek(c"atomic_min")): return 2
	if (peek(c"atomic_max")): return 3
	if (peek(c"atomic_cas")): return 4
	if (peek(c"atomic_load")): return 5
	if (peek(c"atomic_store")): return 6
	if (peek(c"atomic_fence")): return 7
	if (peek(c"atomic_load_relaxed")): return 8
	if (peek(c"atomic_store_relaxed")): return 9
	return 0


char* atomic_builtin_name(int kind):
	if (kind == 1): return c"atomic_add"
	if (kind == 2): return c"atomic_min"
	if (kind == 3): return c"atomic_max"
	if (kind == 4): return c"atomic_cas"
	if (kind == 5): return c"atomic_load"
	if (kind == 6): return c"atomic_store"
	if (kind == 7): return c"atomic_fence"
	if (kind == 8): return c"atomic_load_relaxed"
	return c"atomic_store_relaxed"


int atomic_builtin_ready():
	if (nextc != '('): return 0
	if (atomic_builtin_kind() == 0): return 0
	if (sym_lookup(token) >= 0): return 0
	return 1


# atomic_add/atomic_min/atomic_max/atomic_cas(...): the intrinsic's
# name is the current token and '(' directly follows. Leaves ')'
# current for primary_expr's trailing get_token().
int atomic_builtin_expr():
	int kind = atomic_builtin_kind()
	char* name = atomic_builtin_name(kind)
	int on_gpu = 0
	if (target_isa == 3): on_gpu = 1
	if (on_gpu && (kind >= 5)): error(c"host atomics are not available on this target yet")
	if (on_gpu && (kind == 4)): error(c"atomic_cas is not available in gpu code yet")
	if (on_gpu == 0):
		if ((kind == 2) || (kind == 3)):
			error(c"atomic_min/atomic_max are only available in gpu code")
		if (target_isa != 0):
			if ((target_isa != 1) || (kind < 5)):
				error(c"host atomics are not available on this target yet")
	int int_type = type_lookup(c"int")
	get_token()
	expect(c"(")
	if (kind == 7):
		if (peek(c")") == 0): error2(c"')' expected in ", name)
		alu_atomic_fence()
		return type_value(type_lookup(c"void"))

	# The target pointer: int* (all ops), or float32* for gpu atomic_add.
	# The gpu path must classify the pointee hard (it picks the emitted
	# atom instruction and rejects stack locals — '&x' is the untyped
	# word-sized constant, which can never name device memory). The host
	# path always emits the int form, so it checks like an ordinary int*
	# call argument instead (the limb-intrinsic rule): a real type
	# mismatch warns, and the untyped '&x' — the natural host idiom —
	# passes.
	int got = expression()
	got = promote(got)
	int flavor = 1 /* 1 = int, 2 = float32 */
	if (on_gpu):
		int pointer_type = type_unqualified(got)
		flavor = 0
		if (type_get_pointer_level(pointer_type) == 1):
			int pointee = type_lookup_previous_pointer(pointer_type)
			if (pointee >= 0):
				int unqual = type_unqualified(pointee)
				if (unqual == int_type): flavor = 1
				if (unqual == float32_type): flavor = 2
		if (flavor == 0): error(c"gpu atomics require an int* or float32* first argument")
		if ((flavor == 2) && (kind != 1)):
			error(c"atomic_min/atomic_max require an int* first argument")
	else:
		int host_pointer_type = type_get_next_pointer(int_type)
		limb_builtin_check_argument(name, 0, host_pointer_type, got)
		coerce(host_pointer_type, got)
	if ((kind == 5) || (kind == 8)):
		if (peek(c")") == 0): error2(c"')' expected in ", name)
		alu_atomic_load(kind == 5)
		return type_value(int_type)
	push_slot()

	expect(c",")
	if ((kind == 6) || (kind == 9)):
		limb_builtin_int_argument(name, 1, int_type)
		pop_ebx_slot()
		if (peek(c")") == 0): error2(c"')' expected in ", name)
		alu_atomic_store(kind == 6)
		return type_value(type_lookup(c"void"))
	if (kind == 4):
		# expected and desired: the pointer sits pushed under the
		# expected value; the emitter takes the pointer in ebx, expected
		# in eax and desired in ecx (the mul_wide/add_carry register
		# plan from grammar/limb_builtin.w).
		limb_builtin_int_argument(name, 1, int_type)
		push_slot()
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
		if (flavor == 2): coerce(float32_type, value_type)
		else: coerce(int_type, value_type)
		pop_ebx_slot()
		if (flavor == 2): ptx_atomic_add_f32()
		else:
			if (on_gpu): ptx_atomic_int(kind)
			else: alu_atomic_add()
	if (peek(c")") == 0): error2(c"')' expected in ", name)
	if (flavor == 2):
		return float32_value_type
	return type_value(int_type)
