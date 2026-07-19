/*
GPU device-code common state and the thread-index intrinsics
(docs/projects/cuda.md, Stage 2):

  thread_idx()   %tid.x      index of this thread within its block
  block_idx()    %ctaid.x    index of this thread's block within the grid
  block_dim()    %ntid.x     threads per block
  grid_dim()     %nctaid.x   blocks in the grid

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
	if ((word_size != 8) || (target_isa != 0) || (target_os != 0)):
		error(c"gpu kernels require the x64 target")


# Intrinsic index for the current token: 1 thread_idx, 2 block_idx,
# 3 block_dim, 4 grid_dim; 0 when the token is not an intrinsic name.
int gpu_builtin_kind():
	if (peek(c"thread_idx")):
		return 1
	if (peek(c"block_idx")):
		return 2
	if (peek(c"block_dim")):
		return 3
	if (peek(c"grid_dim")):
		return 4
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


# thread_idx()/block_idx()/block_dim()/grid_dim(): the intrinsic's name
# is the current token and '(' directly follows. Leaves ')' current for
# primary_expr's trailing get_token().
int gpu_builtin_expr():
	int kind = gpu_builtin_kind()
	get_token()
	expect(c"(")
	if (peek(c")") == 0):
		error(c"gpu builtins take no arguments")
	ptx_special_reg(kind)
	return 3 /* constant: the value is already in the accumulator */
