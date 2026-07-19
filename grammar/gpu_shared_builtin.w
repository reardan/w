/*
GPU shared-memory builtins (docs/projects/torch.md Stage 4):

  float* gpu_shared_f32(N)   declares an N-element .shared float32
                             array in the current kernel and returns
                             its generic address. N must be a positive
                             decimal integer literal — a PTX .shared
                             declaration's size is static. Each call
                             site is its own array: call once per
                             buffer at the top of the kernel, not in a
                             loop.
  int    gpu_barrier()       bar.sync 0 — block-wide barrier (returns
                             0). EVERY thread of the block must reach
                             it: a barrier under divergent control flow
                             hangs the GPU, so use it in `kernel`
                             bodies where the guard structure is
                             explicit, not under `gpu for`'s implicit
                             per-thread bounds guard.

Device (PTX) bodies only — host use is a compile error, mirroring the
gpu atomics (grammar/atomic_builtin.w): no host lowering is provided.

The intrinsics parse as ordinary calls — no new syntax, so the
parser-generator grammar is untouched — and are not reserved words: a
user symbol with one of these names that is already defined at the
call site takes precedence (the limb-intrinsic shadowing rule).

This file is compiled by the committed seed: only seed-understood
syntax here.
*/


# Intrinsic index for the current token: 1 gpu_shared_f32,
# 2 gpu_barrier; 0 when the token is not an intrinsic name.
int gpu_shared_builtin_kind():
	if (peek(c"gpu_shared_f32")):
		return 1
	if (peek(c"gpu_barrier")):
		return 2
	return 0


char* gpu_shared_builtin_name(int kind):
	if (kind == 1):
		return c"gpu_shared_f32"
	return c"gpu_barrier"


int gpu_shared_builtin_ready():
	if (nextc != '('):
		return 0
	if (gpu_shared_builtin_kind() == 0):
		return 0
	if (sym_lookup(token) >= 0):
		return 0
	return 1


# gpu_shared_f32(N)/gpu_barrier(): the intrinsic's name is the current
# token and '(' directly follows. Leaves ')' current for primary_expr's
# trailing get_token().
int gpu_shared_builtin_expr():
	int kind = gpu_shared_builtin_kind()
	char* name = gpu_shared_builtin_name(kind)
	if (target_isa != 3):
		error(c"gpu_shared_f32/gpu_barrier are only available in gpu code")
	get_token()
	expect(c"(")

	if (kind == 2):
		ptx_barrier()
		mov_eax_int(0)
		if (peek(c")") == 0):
			diag_part(c"')' expected in ")
			error(name)
		return type_value(type_lookup(c"int"))

	# gpu_shared_f32: the element count must be a positive decimal
	# integer literal, because the .shared declaration's byte size is
	# emitted right here — there is no runtime sizing of shared memory
	# in this model (dynamic shared memory via cuLaunchKernel's
	# sharedMemBytes is future work).
	int n = 0
	int i = 0
	if ((token[0] < '0') || (token[0] > '9')):
		error(c"gpu_shared_f32 requires a positive integer literal element count")
	while (token[i]):
		if ((token[i] < '0') || (token[i] > '9')):
			error(c"gpu_shared_f32 requires a positive integer literal element count")
		n = (n << 1) + (n << 3) + token[i] - '0'
		i = i + 1
	if (n == 0):
		error(c"gpu_shared_f32 requires a positive integer literal element count")
	# sm_52's static shared-memory limit is 48KB per block; a single
	# over-limit array can be rejected here rather than as a driver JIT
	# error at run time. (The cumulative multi-array total is still the
	# JIT's to enforce.)
	if (n > 12288):
		error(c"gpu_shared_f32: element count exceeds the 48KB shared-memory block limit")
	get_token()

	ptx_shared_f32(n)
	if (peek(c")") == 0):
		diag_part(c"')' expected in ")
		error(name)
	int ptr_type = type_lookup_pointer(c"float", 1)
	if (ptr_type < 0):
		ptr_type = type_push_pointer(c"float", word_size, 1)
	return type_value(ptr_type)
