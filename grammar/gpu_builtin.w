/*
GPU device-code common state and the thread-index intrinsics
(docs/projects/cuda.md, Stage 2):

  thread_idx()   %tid.x      index of this thread within its block
  block_idx()    %ctaid.x    index of this thread's block within the grid
  block_dim()    %ntid.x     threads per block
  grid_dim()     %nctaid.x   blocks in the grid

plus the atomic-reduction intrinsics (docs/projects/torch.md, Stage 1):

  gpu_atomic_add(float32* p, float32 v)   red.add.f32 [p], v
  gpu_atomic_add_int(int* p, int v)       red.add.u64 [p], v

The atomics are the primitive that makes reductions expressible in
device code at all: 'gpu for' captures are device-local copies, so
accumulating through a captured scalar is silently lost.

The intrinsics are only meaningful inside device (PTX) bodies — kernel
functions (grammar/kernel_decl.w) and 'gpu for' loops — and parse as
ordinary calls there, so the parser-generator grammar is untouched. They
are not reserved words: like the limb intrinsics, a user symbol with one
of these names takes precedence at the call site, and outside device mode
the names stay plain identifiers.

This file is compiled by the committed seed: only seed-understood syntax.
*/


# Base of the current device body's symbol scope: symbols at table
# offsets below this were declared by the enclosing host scope. A kernel
# body may not touch them; 'gpu for' captures them as kernel parameters.
int device_symbol_base

# 1 while a 'gpu for' body compiles (grammar/gpu_for.w): 'return' and
# 'defer' are rejected there, and enclosing-scope references become
# captures instead of errors.
int in_gpu_for_body


# The gpu features imply the x64 Linux host target: libcuda.so is 64-bit
# only, and the host side leans on the ELF dynamic-linking path.
void gpu_target_check():
	if ((word_size != 8) | (target_isa != 0) | (target_os != 0)):
		error(c"gpu kernels require the x64 target")


# Intrinsic index for the current token: 1 thread_idx, 2 block_idx,
# 3 block_dim, 4 grid_dim, 5 gpu_atomic_add, 6 gpu_atomic_add_int;
# 0 when the token is not an intrinsic name.
int gpu_builtin_kind():
	if (peek(c"thread_idx")):
		return 1
	if (peek(c"block_idx")):
		return 2
	if (peek(c"block_dim")):
		return 3
	if (peek(c"grid_dim")):
		return 4
	if (peek(c"gpu_atomic_add")):
		return 5
	if (peek(c"gpu_atomic_add_int")):
		return 6
	return 0


int gpu_builtin_ready():
	if (target_isa != 3):
		return 0
	if (nextc != '('):
		return 0
	if (gpu_builtin_kind() == 0):
		return 0
	if (sym_lookup(token) >= 0):
		return 0
	return 1


int expression();


# One operand of the atomic intrinsics: parse, warn on a type mismatch
# (limb_builtin's shared warning shape) and coerce, leaving the value in
# the accumulator.
void gpu_atomic_argument(char* name, int arg_index, int want_type):
	int got = expression()
	got = promote(got)
	limb_builtin_check_argument(name, arg_index, want_type, got)
	coerce(want_type, got)


# gpu_atomic_add(float32* p, float32 v) / gpu_atomic_add_int(int* p, int v):
# an atomic add to *p with no fetched result (PTX red.add). kind is
# 5 (float32) or 6 (int); '(' is already consumed. Leaves ')' current.
int gpu_atomic_expr(int kind):
	char* name = c"gpu_atomic_add"
	int elem_type = type_lookup(c"float32")
	if (kind == 6):
		name = c"gpu_atomic_add_int"
		elem_type = type_lookup(c"int")
	gpu_atomic_argument(name, 0, type_get_next_pointer(elem_type))
	push_eax()
	stack_pos = stack_pos + 1
	expect(c",")
	gpu_atomic_argument(name, 1, elem_type)
	if (kind == 5):
		movd_xmm(0, 0) /* addend bits -> %fa */
	pop_ebx()
	stack_pos = stack_pos - 1
	if (kind == 5):
		ptx_red_add_f32()
	else:
		ptx_red_add_s64()
	if (peek(c")") == 0):
		diag_part(c"')' expected in ")
		error(name)
	return type_value(type_lookup(c"void"))


# thread_idx()/block_idx()/block_dim()/grid_dim() and the atomics: the
# intrinsic's name is the current token and '(' directly follows. Leaves
# ')' current for primary_expr's trailing get_token().
int gpu_builtin_expr():
	int kind = gpu_builtin_kind()
	get_token()
	expect(c"(")
	if (kind >= 5):
		return gpu_atomic_expr(kind)
	if (peek(c")") == 0):
		error(c"gpu builtins take no arguments")
	ptx_special_reg(kind)
	return 3 /* constant: the value is already in the accumulator */
