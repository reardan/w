/*
Raw CUDA-style kernel declarations (docs/projects/cuda.md M1, Stage 2):

	kernel add(float32* a, float32* b, float32* c, int n):
		int i = block_idx() * block_dim() + thread_idx()
		if i < n:
			c[i] = a[i] + b[i]

The 'kernel' marker is contextual, parsed in grammar/program.w before
the usual "type-name identifier (" declaration (the 'generator'
pattern; a user type or symbol named 'kernel' shadows the marker).
Kernels return nothing — the return type is implicitly void — and their
parameters must be word-sized scalars or pointers: the launch path
passes every argument as an 8-byte cell (float32 rides as raw bits, the
host convention).

The body compiles in DEVICE MODE: target_isa flips to 3, so every emit
helper the grammar calls routes to its ptx_* twin
(code_generator/ptx.w), appending PTX text to the embedded module
instead of machine bytes to the host image. Parameters are lowered as
ordinary locals — the prologue loads each .param into the accumulator
and pushes it, declaring the name at that stack slot — so the existing
'L' addressing machinery works unchanged and &param stays legal.

The kernel's symbol is defined at address 0 and flagged with
sym_set_kernel: host code referencing the name gets "kernels cannot be
called; use 'launch'" (compiler/symbol_table.w), and the launch
statement checks the flag and the recorded arity/parameter types.

This file is compiled by the committed seed: only seed-understood syntax.
*/


# Saved host compilation state across a device body. Device bodies get a
# fresh evaluation stack and loop/switch context (break/continue must not
# escape to host control-flow regions), and bounds checks are disabled:
# the trap path calls host runtime diagnostics that do not exist on
# device (documented in docs/projects/cuda.md). Kernels are top-level and
# 'gpu for' cannot nest inside device code, so plain globals suffice.
int device_saved_stack_pos
int device_saved_loop_depth
int device_saved_switch_depth
int device_saved_break_in_switch
int device_saved_bounds
int device_saved_num_args
int device_saved_function_symbol
int device_saved_symbol_base


void device_mode_enter():
	device_saved_stack_pos = stack_pos
	device_saved_loop_depth = loop_depth
	device_saved_switch_depth = switch_depth
	device_saved_break_in_switch = break_in_switch
	device_saved_bounds = bounds_mode
	device_saved_num_args = number_of_args
	device_saved_function_symbol = current_function_symbol
	device_saved_symbol_base = device_symbol_base
	stack_pos = 0
	loop_depth = 0
	switch_depth = 0
	break_in_switch = 0
	bounds_mode = 0
	number_of_args = 0
	device_symbol_base = table_pos
	target_isa = 3


void device_mode_exit():
	target_isa = 0
	stack_pos = device_saved_stack_pos
	loop_depth = device_saved_loop_depth
	switch_depth = device_saved_switch_depth
	break_in_switch = device_saved_break_in_switch
	bounds_mode = device_saved_bounds
	number_of_args = device_saved_num_args
	current_function_symbol = device_saved_function_symbol
	device_symbol_base = device_saved_symbol_base


/*
'gpu for' capture table (docs/projects/cuda.md M2). An enclosing-scope
variable referenced inside a 'gpu for' body becomes a kernel parameter:
its host value is pushed at the launch site and the kernel prologue
stores parameter k into the fixed slot [%bp - (k+1)*8]
(ptx_kernel_end's reserve layout). Because the slots hang off %bp — the
top of the device stack — a capture discovered mid-body never
invalidates addresses already emitted, which is what makes single-pass
outlining work. Slot 0 is always the range bound (recorded with symbol
-1). Captured scalars are device-local copies: writes do not propagate
back to the host variable.
*/


int gpu_capture_count
char* gpu_capture_names    # per-slot host symbol name (owned strclone)
char* gpu_capture_syms     # per-slot host symbol table offset (-1 = bound)


int gpu_capture_limit():
	return 32


# Start a fresh capture set with slot 0 = the range bound.
void gpu_capture_reset():
	if (gpu_capture_names == 0):
		gpu_capture_names = malloc(gpu_capture_limit() * __word_size__)
		gpu_capture_syms = malloc(gpu_capture_limit() * 4)
	int i = 0
	while (i < gpu_capture_count):
		char* name = cast(char*, load_ptr(gpu_capture_names + i * __word_size__))
		if (name != 0):
			free(name)
		i = i + 1
	save_ptr(gpu_capture_names, 0)
	save_int(gpu_capture_syms, -1)
	gpu_capture_count = 1


# Reserve one extra leading capture slot with no backing symbol: the
# 'gpu for' range START when the two-argument form is used (slot 0 =
# start, slot 1 = end; the one-argument form keeps slot 0 = end).
void gpu_capture_reserve():
	save_ptr(gpu_capture_names + gpu_capture_count * __word_size__, 0)
	save_int(gpu_capture_syms + gpu_capture_count * 4, -1)
	gpu_capture_count = gpu_capture_count + 1


char* gpu_capture_name(int slot):
	return cast(char*, load_ptr(gpu_capture_names + slot * __word_size__))


# Capture slot for the host symbol at table offset t (reusing an
# existing slot on a repeated reference).
int gpu_capture_slot(int t, char* name):
	int i = 1
	while (i < gpu_capture_count):
		if (load_int(gpu_capture_syms + i * 4) == t):
			return i
		i = i + 1
	if (gpu_capture_count >= gpu_capture_limit()):
		error(c"too many variables captured in 'gpu for'")
	save_ptr(gpu_capture_names + gpu_capture_count * __word_size__, cast(int, strclone(name)))
	save_int(gpu_capture_syms + gpu_capture_count * 4, t)
	gpu_capture_count = gpu_capture_count + 1
	return gpu_capture_count - 1


# Device-mode symbol reference: the target_isa == 3 arm of sym_get_value
# (compiler/symbol_table.w). Locals declared inside the device body use
# the normal W-stack addressing (against the device %sp); enclosing-
# scope variables become captures inside 'gpu for'; everything host-only
# is rejected.
int gpu_sym_get_value(char* s):
	int t
	if ((t = sym_lookup(s)) < 0):
		diag_part(c"Cannot find symbol: '")
		diag_part(token)
		error(c"'")
	if (load_int(table + t + 10) == 2):
		error(c"gpu code cannot call functions")
	char scope_type = table[t + 1]
	if ((scope_type == 'D') || (scope_type == 'U')):
		error(c"global variables are not accessible in gpu code")
	int type = load_int(table + t + 6)
	if (t < device_symbol_base):
		if (in_gpu_for_body == 0):
			error(c"enclosing-scope variables are not accessible in gpu code")
		# Word-sized values only: each capture rides one 8-byte cell.
		# Containers and strings are host-heap structures the device
		# cannot follow, so they never capture.
		if (type_stack_words(type) != 1):
			error(c"'gpu for' captures must be word-sized")
		int real_type = type_unqualified(type)
		if (type_is_map(real_type) | type_is_set(real_type) | type_is_list(real_type) | type_is_string(real_type)):
			error(c"containers and strings cannot be captured in 'gpu for'")
		int slot = gpu_capture_slot(t, s)
		ptx_lea_ax_bp_minus((slot + 1) << word_size_log2)
		# Captured scalars are device-local copies: a write inside the
		# body would silently vanish on the host side, so they come
		# back const-qualified and the existing assignment-to-const
		# enforcement rejects the write. Pointers are exempt (writes
		# THROUGH a captured pointer are the point, and const-wrapping
		# a pointer record breaks element-type lookup); bool and var
		# are exempt (their coerce paths re-promote const records).
		int unqual = type_unqualified(type)
		if ((type_get_pointer_level(unqual) == 0) && (unqual != bool_type) && (type_is_var(unqual) == 0)):
			if (type_is_const(type) == 0):
				int const_type = type_lookup_const(unqual)
				if (const_type < 0):
					const_type = type_push_const(unqual)
				type = const_type
		return type
	int k = (stack_pos - load_int(table + t + 2) - 1) << word_size_log2
	# Aggregates occupy several stack words; point at the lowest address
	# (last pushed word), like the host path in sym_get_value.
	int words = type_stack_words(type)
	if (words > 1):
		k = k - ((words - 1) << word_size_log2)
	be_lea_acc_wstack(k)
	return type


# Parses "parameter-list ) body" for the kernel symbol at table offset
# current_symbol; 'kernel', the name and the opening "(" have already
# been consumed. Mirrors generator_function_definition, except the body
# compiles in device mode and parameters become device locals.
void kernel_function_definition(int current_symbol, char* kernel_name):
	table[current_symbol + 10] = 2 /* store function type */
	sym_set_kernel(current_symbol)
	sym_define_global_at(current_symbol, 0)
	int n = table_pos
	device_mode_enter()
	ptx_kernel_begin(kernel_name)
	int param_count = 0
	while (accept(c")") == 0):
		param_count = param_count + 1
		int type = type_name()
		if (accept(c".")):
			error(c"variadic kernel parameters are not supported")
		if (type_stack_words(type) != 1):
			error(c"kernel parameters must be word-sized")
		if (type_num_args(type_real(type)) > 0):
			error(c"kernel parameters must be word-sized")
		if (param_count <= sym_max_param_slots()):
			save_int(table + current_symbol + 22 + (param_count << 2), type)
		# The parameter's value: ld.param into the accumulator, then an
		# ordinary local declaration at the slot about to be pushed.
		ptx_param_load(param_count - 1)
		if (peek(c")") == 0):
			sym_declare(token, type, 'L', stack_pos, 1)
			pointer_indirection = 0
			get_token()
		if (accept(c"=")):
			error(c"kernel parameters cannot have default values")
		push_eax()
		stack_pos = stack_pos + 1
		accept(c",") /* ignore trailing comma */

	save_int(table + current_symbol + 22, param_count)
	sym_set_w_variadic(current_symbol, -1)

	if (accept(c";")):
		error(c"a kernel declaration requires a body")
	current_function_symbol = current_symbol
	enclosing_tab_level = 0
	statement()
	ret()
	ptx_kernel_end(param_count, 0)
	device_mode_exit()
	table_pos = n


# Parses a top-level kernel declaration; peek(c"kernel") has already
# matched in program() and the 'kernel' keyword is the current token.
void kernel_declaration():
	gpu_target_check()
	get_token() /* consume 'kernel' */
	int void_type = type_lookup(c"void")
	int current_symbol = sym_declare_global(token, void_type, 1)
	char* kernel_name = strclone(token)
	get_token()
	expect(c"(")
	kernel_function_definition(current_symbol, kernel_name)


/*
launch add[blocks, threads](a, b, c, n)

Host-side kernel launch (docs/projects/cuda.md M1). Every argument is
evaluated, coerced to the kernel's declared parameter type, and pushed
as one 8-byte cell; the runtime receives the cell block plus the grid
and block dimensions and drives cuLaunchKernel
(__w_gpu_launch_raw, lib/cuda.w). Launches are ASYNC: the statement
enqueues and returns, and results are observable only after gpu_sync()
(managed-memory buffers must not be touched by the host while a kernel
that uses them is in flight).
*/


# Emit __w_gpu_launch_raw(name, grid, block, vals, count). On entry the
# stack holds [grid, block, arg0..argN-1] pushed in that order (base is
# the stack_pos before grid); vals is the address of the LAST argument
# cell, so argument i lives at vals + (count-1-i)*8.
void launch_emit_runtime_call(char* kernel_name, int base, int passed):
	sym_get_value(c"__w_gpu_launch_raw")
	push_eax()
	stack_pos = stack_pos + 1
	be_emit_inline_cstr(strlen(kernel_name), kernel_name)
	push_eax() /* arg 1: name */
	stack_pos = stack_pos + 1
	mov_eax_esp_plus((stack_pos - (base + 1)) << word_size_log2)
	push_eax() /* arg 2: grid */
	stack_pos = stack_pos + 1
	mov_eax_esp_plus((stack_pos - (base + 2)) << word_size_log2)
	push_eax() /* arg 3: block */
	stack_pos = stack_pos + 1
	lea_eax_esp_plus((stack_pos - (base + 2 + passed)) << word_size_log2)
	push_eax() /* arg 4: vals (the last argument cell) */
	stack_pos = stack_pos + 1
	mov_eax_int(passed)
	push_eax() /* arg 5: count */
	stack_pos = stack_pos + 1
	mov_eax_esp_plus(5 << word_size_log2)
	call_eax()


# 'launch <identifier>[' opens the statement; any other continuation is
# an ordinary expression using a symbol named 'launch' (the statement
# rewinds with the reparse save/seek/restore trick and reports 0).
int launch_statement():
	if (peek(c"launch") == 0):
		return 0
	char* save = generic_reparse_save()
	get_token()
	int c0 = token[0]
	int is_ident = (('a' <= c0) & (c0 <= 'z')) | (('A' <= c0) & (c0 <= 'Z')) | (c0 == '_')
	if (is_ident == 0):
		getchar_seek(file, load_ptr(save + 7 * __word_size__))
		generic_reparse_restore(save)
		return 0
	free(cast(char*, load_ptr(save + 11 * __word_size__)))
	free(save)

	if (target_isa == 3):
		error(c"'launch' is not supported in gpu code")
	gpu_target_check()
	if (sym_lookup(c"__w_gpu_launch_raw") < 0):
		error(c"gpu code requires 'import lib.cuda'")
	int kernel_sym = sym_lookup(token)
	int is_kernel = 0
	if (kernel_sym >= 0):
		is_kernel = sym_is_kernel(kernel_sym)
	if (is_kernel == 0):
		diag_part(c"'")
		diag_part(token)
		error(c"' is not a kernel")
	char* kernel_name = strclone(token)
	get_token()

	int base = stack_pos
	expect(c"[")
	int int_type = type_lookup(c"int")
	coerce(int_type, promote(expression()))
	push_eax() /* grid */
	stack_pos = stack_pos + 1
	expect(c",")
	coerce(int_type, promote(expression()))
	push_eax() /* block */
	stack_pos = stack_pos + 1
	expect(c"]")

	expect(c"(")
	int passed = 0
	if (accept(c")") == 0):
		int arg_type = promote(expression())
		if (type_num_args(type_real(arg_type)) > 0):
			error(c"struct arguments are not supported in launch")
		check_call_argument(kernel_sym, -1, kernel_name, passed, arg_type)
		int param_type = sym_param_type(kernel_sym, passed)
		if (param_type >= 0):
			coerce_call_argument(param_type, arg_type)
		push_eax()
		stack_pos = stack_pos + 1
		passed = passed + 1
		while (accept(c",")):
			arg_type = promote(expression())
			if (type_num_args(type_real(arg_type)) > 0):
				error(c"struct arguments are not supported in launch")
			check_call_argument(kernel_sym, -1, kernel_name, passed, arg_type)
			int loop_param_type = sym_param_type(kernel_sym, passed)
			if (loop_param_type >= 0):
				coerce_call_argument(loop_param_type, arg_type)
			push_eax()
			stack_pos = stack_pos + 1
			passed = passed + 1
		expect(c")")

	# The launch path passes exactly one 8-byte cell per declared
	# parameter: a count mismatch would feed the kernel garbage cells.
	int expected_args = sym_num_args(kernel_sym)
	if (passed != expected_args):
		diag_part(c"kernel '")
		diag_part(kernel_name)
		diag_part(c"' expects ")
		diag_part(itoa(expected_args))
		diag_part(c" arguments, got ")
		error(itoa(passed))

	launch_emit_runtime_call(kernel_name, base, passed)
	be_pop(stack_pos - base)
	stack_pos = base
	free(kernel_name)
	return 1
