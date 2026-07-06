/*
Expression evaluation at a breakpoint (the repl model).

The whole compiler is already in this process, and the debuggee's code
buffer, symbol table and type table are all live. dbg_eval() stages
"return <expr>" in /tmp, compiles it as the body of a fresh anonymous
function appended to the code buffer, calls it and prints the result.
Expressions can read and write the debuggee's globals and call its
functions. A compile error rolls back cleanly via the repl_setjmp
recovery hook instead of killing wdbg.

Locals and arguments visible at the stop are bound as temporary symbols
so expressions like "x + y * 2" or "add(x, 1)" work on locals too. The
generated code addresses symbols with 32-bit immediates, and on x64 the
debuggee's stack sits above 4GB, so each local's value is copied into a
low-memory scratch slot that the symbol points at; after the expression
runs the slots are copied back, so assignments to locals stick. The
bindings are declared after the checkpoint and dropped with the eval
function's other symbols, so nothing leaks between evaluations.
*/
import debugger.breakpoints


int dbg_eval_counter

# Scratch copies of the bound locals (allocated once, low memory) and
# the copy-back list: runtime address, scratch address, byte size.
char* dbg_eval_scratch
char* dbg_eval_bound_from
char* dbg_eval_bound_to
char* dbg_eval_bound_size
int dbg_eval_bound_count


int dbg_eval_bound_max():
	return 128


int dbg_eval_scratch_size():
	return 8192


void dbg_eval_copy(int from, int to, int n):
	char* src = cast(char*, from)
	char* dst = cast(char*, to)
	int i = 0
	while (i < n):
		dst[i] = src[i]
		i = i + 1


# Bind every local and argument visible at the stop as a defined global
# object pointing at a scratch copy of its value. Later declarations win
# in sym_lookup, so inner shadowing declarations take precedence over
# outer ones and over real globals, like in the source.
void dbg_eval_bind_locals(int stop_addr, int esp):
	dbg_eval_bound_count = 0
	dbg_frame_compute(stop_addr)
	if (dbg_frame_ok == 0):
		return;
	if (dbg_eval_scratch == 0):
		dbg_eval_scratch = malloc(dbg_eval_scratch_size())
		dbg_eval_bound_from = malloc(dbg_eval_bound_max() * __word_size__)
		dbg_eval_bound_to = malloc(dbg_eval_bound_max() * __word_size__)
		dbg_eval_bound_size = malloc(dbg_eval_bound_max() * 4)
	int rel = stop_addr - code_offset
	int saved_indirection = pointer_indirection
	int used = 0
	int i = 0
	while (i < debug_local_count):
		if (dbg_local_visible(i, rel)):
			int type = dbg_local_type(i)
			int size = __word_size__
			if ((type_get_pointer_level(type) == 0) & (type_num_args(type) > 0)):
				# struct value: whole object, rounded up to words
				size = (type_get_size(type) + __word_size__ - 1) / __word_size__ * __word_size__
			int addr = dbg_local_runtime_addr(i, esp)
			if ((used + size <= dbg_eval_scratch_size()) & (dbg_eval_bound_count < dbg_eval_bound_max())):
				if (dbg_mem_readable(addr, size)):
					int slot = cast(int, dbg_eval_scratch) + used
					dbg_eval_copy(addr, slot, size)
					int b = dbg_eval_bound_count
					save_word(dbg_eval_bound_from + b * __word_size__, addr)
					save_word(dbg_eval_bound_to + b * __word_size__, slot)
					save_int(dbg_eval_bound_size + b * 4, size)
					dbg_eval_bound_count = b + 1
					used = used + size
					pointer_indirection = type_get_pointer_level(type)
					sym_declare(dbg_local_name_at(i), type, 'D', slot, 1)
		i = i + 1
	pointer_indirection = saved_indirection


# Copy possibly-assigned scratch values back into the stack slots.
void dbg_eval_writeback():
	int b = 0
	while (b < dbg_eval_bound_count):
		int from = load_word(dbg_eval_bound_to + b * __word_size__)
		int to = load_word(dbg_eval_bound_from + b * __word_size__)
		dbg_eval_copy(from, to, load_int(dbg_eval_bound_size + b * 4))
		b = b + 1


# Compile `return <expr>` as an anonymous function; returns its address,
# or 0 when the expression failed to compile.
int dbg_eval_compile(char* expr, int stop_addr, int esp):
	# Stage the line in a file: the tokenizer reads from an fd
	char* path = c"/tmp/wdbg_eval.w"
	int out = create_file(path, 511)
	if (out < 0):
		println(c"could not create /tmp/wdbg_eval.w")
		return 0
	write_string(out, c"return ")
	write_string(out, expr)
	write(out, c"\x0a", 1)
	close(out)

	# Checkpoint everything a failed compile could leave half-updated
	int saved_codepos = codepos
	int saved_table_pos = table_pos
	int saved_stack_pos = stack_pos
	int saved_loop_depth = loop_depth
	int saved_loop_break_chain = loop_break_chain
	int saved_loop_continue_chain = loop_continue_chain
	int saved_loop_stack_pos = loop_stack_pos
	int saved_switch_depth = switch_depth
	int saved_switch_break_chain = switch_break_chain
	int saved_switch_stack_pos = switch_stack_pos
	int saved_break_in_switch = break_in_switch
	int saved_defer_count = defer_count
	int saved_number_of_args = number_of_args
	int saved_type_count = length /* structures.list backs the type table */
	int saved_function_symbol = current_function_symbol

	repl_recovery = 1
	if (repl_setjmp(repl_jump_buffer)):
		# error() jumped back: roll back the failed expression
		repl_recovery = 0
		codepos = saved_codepos
		table_pos = saved_table_pos
		stack_pos = saved_stack_pos
		loop_depth = saved_loop_depth
		loop_break_chain = saved_loop_break_chain
		loop_continue_chain = saved_loop_continue_chain
		loop_stack_pos = saved_loop_stack_pos
		switch_depth = saved_switch_depth
		switch_break_chain = saved_switch_break_chain
		switch_stack_pos = saved_switch_stack_pos
		break_in_switch = saved_break_in_switch
		defer_count = saved_defer_count
		number_of_args = saved_number_of_args
		length = saved_type_count
		current_function_symbol = saved_function_symbol
		pointer_indirection = 0
		diag_clear()
		close(file)
		return 0

	filename = path
	file = open(path, 0, 511)
	asserts(c"could not reopen eval buffer", file >= 0)
	line_number = 0
	column_number = 0
	tab_level = 0
	byte_offset = 0
	nextc = get_character()
	get_token()

	char* counter_digits = itoa(dbg_eval_counter)
	char* name = strjoin(c"__wdbg_eval_", counter_digits)
	free(counter_digits)
	dbg_eval_counter = dbg_eval_counter + 1

	int current_symbol = sym_declare_global(name, 1, 2)
	sym_define_global(current_symbol)
	current_function_symbol = current_symbol
	int n = table_pos
	dbg_eval_bind_locals(stop_addr, esp)
	number_of_args = 0
	defer_reset()
	stack_pos = 0
	enclosing_tab_level = 0
	while (token[0] != 0):
		statement()
	be_pop(stack_pos)
	stack_pos = saved_stack_pos
	ret()
	table_pos = n
	close(file)
	repl_recovery = 0

	int address = sym_address(name)
	free(name)
	return address


# Evaluate the expression at the stop and print its value.
void dbg_eval(char* expr, int stop_addr, int esp):
	int f = dbg_eval_compile(expr, stop_addr, esp)
	if (f == 0):
		return;
	int v = f()
	dbg_eval_writeback()
	print(c"= ")
	dbg_print_int_value(v)
	put_char(10)
