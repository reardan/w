/*
gpu for — the parallel range loop (docs/projects/cuda.md M2, Stage 3):

	gpu for int i in range(n):
		c[i] = a[i] + b[i]

The body is outlined into a PTX kernel: each GPU thread runs one
iteration, with the loop variable initialized to
block_idx()*block_dim()+thread_idx() and the bound enforced by a
compiler-inserted i < n guard. Enclosing-scope variables referenced in
the body are captured as kernel parameters (grammar/kernel_decl.w's
capture table; capture slot 0 is the bound), their host values pushed
at the loop site and the launch delegated to __w_gpu_launch
(lib/cuda.w: 256-thread blocks, grid sized to cover n, ASYNC — call
gpu_sync() before the host touches the results).

Single-pass shape: the bound evaluates in host mode into a hidden
stack slot; the body then parses in device mode, emitting PTX text to
a scratch buffer while capture slots hand out fixed %bp-relative
addresses; ptx_kernel_end stitches header + capture prologue + body
into the module; and only then does the host stream continue with the
capture pushes and the runtime call — the two instruction streams
never interleave, so no backpatching is needed.

Captured scalars are device-local copies (writes do not propagate);
pointers must reference device-accessible memory (gpu_alloc's managed
allocations). break/continue/return/defer are rejected in the body;
nested ordinary loops work.

This file is compiled by the committed seed: only seed-understood syntax.
*/


int gpu_for_kernel_count


char* gpu_for_kernel_name():
	char* name = malloc(32)
	strcpy(name, c"__w_gpu_kernel_")
	strcpy(name + strlen(name), itoa(gpu_for_kernel_count))
	gpu_for_kernel_count = gpu_for_kernel_count + 1
	return name


# Emit __w_gpu_launch(name, n, vals, count). On entry the stack holds
# [bound, capture1..captureK-1] starting at base+1; vals is the address
# of the LAST capture cell, so slot k lives at vals + (count-1-k)*8.
void gpu_for_emit_runtime_call(char* kernel_name, int base, int count):
	sym_get_value(c"__w_gpu_launch")
	push_eax()
	stack_pos = stack_pos + 1
	be_emit_inline_cstr(strlen(kernel_name), kernel_name)
	push_eax() /* arg 1: name */
	stack_pos = stack_pos + 1
	mov_eax_esp_plus((stack_pos - (base + 1)) << word_size_log2)
	push_eax() /* arg 2: n (the bound, capture slot 0) */
	stack_pos = stack_pos + 1
	lea_eax_esp_plus((stack_pos - (base + count)) << word_size_log2)
	push_eax() /* arg 3: vals (the last capture cell) */
	stack_pos = stack_pos + 1
	mov_eax_int(count)
	push_eax() /* arg 4: count */
	stack_pos = stack_pos + 1
	mov_eax_esp_plus(4 << word_size_log2)
	call_eax()


# 'gpu for' opens the statement; any other continuation is an ordinary
# expression using a symbol named 'gpu' (rewound with the reparse
# save/seek/restore trick).
int gpu_for_statement():
	if (peek(c"gpu") == 0):
		return 0
	char* save = generic_reparse_save()
	get_token()
	if (peek(c"for") == 0):
		getchar_seek(file, load_ptr(save + 7 * __word_size__))
		generic_reparse_restore(save)
		return 0
	free(cast(char*, load_ptr(save + 11 * __word_size__)))
	free(save)

	if (target_isa == 3):
		error(c"'gpu for' cannot nest inside gpu code")
	gpu_target_check()
	if (sym_lookup(c"__w_gpu_launch") < 0):
		error(c"gpu code requires 'import lib.cuda'")

	int gpu_for_tab_level = tab_level
	get_token() /* consume 'for' */

	# Loop variable: 'int name' (one thread index per iteration)
	int int_type = type_lookup(c"int")
	int type = type_name()
	if (type_unqualified(type) != int_type):
		error(c"'gpu for' loop variable must be an int")
	char* var_name = strclone(token)
	get_token()
	expect(c"in")
	if (accept(c"range") == 0):
		error(c"'gpu for' supports only range iteration")

	# The bound, evaluated in host mode: both the launch's grid input
	# and capture slot 0 (the device-side guard reloads it from there).
	int base = stack_pos
	int has_parens = accept(c"(")
	coerce(int_type, promote(expression()))
	if (accept(c",")):
		error(c"'gpu for' supports only range(end)")
	if (has_parens):
		expect(c")")
	push_eax()
	stack_pos = stack_pos + 1

	# Device side: outline the body into a fresh kernel
	int n = table_pos
	char* kernel_name = gpu_for_kernel_name()
	char* launch_name = strclone(kernel_name)
	device_mode_enter()
	gpu_capture_reset()
	in_gpu_for_body = 1
	ptx_kernel_begin(kernel_name)

	# i = block_idx() * block_dim() + thread_idx()
	ptx_special_reg(2)
	push_eax()
	stack_pos = stack_pos + 1
	ptx_special_reg(3)
	pop_ebx()
	stack_pos = stack_pos - 1
	alu_imul()
	push_eax()
	stack_pos = stack_pos + 1
	ptx_special_reg(1)
	pop_ebx()
	stack_pos = stack_pos - 1
	alu_add()
	sym_declare(var_name, int_type, 'L', stack_pos, 1)
	pointer_indirection = 0
	push_eax()
	stack_pos = stack_pos + 1
	free(var_name)

	# Compiler-inserted guard: threads past the bound do nothing
	int h_guard = be_ctrl_block()
	mov_eax_esp_plus(0) /* i */
	push_eax()
	stack_pos = stack_pos + 1
	ptx_lea_ax_bp_minus(1 << word_size_log2) /* capture slot 0: the bound */
	promote_eax()
	pop_ebx()
	stack_pos = stack_pos - 1
	alu_cmp_set(0x9c) /* setl: i < bound */
	be_br_zero(h_guard)

	enclosing_tab_level = gpu_for_tab_level
	statement()

	be_ctrl_end(h_guard)
	ret()
	ptx_kernel_end(gpu_capture_count, gpu_capture_limit() << word_size_log2)
	in_gpu_for_body = 0
	device_mode_exit()
	table_pos = n

	# Host side: push the remaining captures' current values (slot
	# order; the bound already sits at base+1), then launch.
	int k = 1
	while (k < gpu_capture_count):
		promote(sym_get_value(gpu_capture_name(k)))
		push_eax()
		stack_pos = stack_pos + 1
		k = k + 1
	gpu_for_emit_runtime_call(launch_name, base, gpu_capture_count)
	be_pop(stack_pos - base)
	stack_pos = base
	free(launch_name)
	return 1
