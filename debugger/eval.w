/*
Expression evaluation at a breakpoint (the repl model).

The whole compiler is already in this process, and the debuggee's code
buffer, symbol table and type table are all live. dbg_eval() stages
"return <expr>" in /tmp, compiles it as the body of a fresh anonymous
function appended to the code buffer, calls it and prints the result.
Expressions can read and write the debuggee's globals and call its
functions. A compile error rolls back cleanly via the repl_setjmp
recovery hook instead of killing wdbg.

Locals are handled before eval is reached (debugger/locals.w): the
compiler cannot address another frame's stack slots.
*/
import debugger.breakpoints


int dbg_eval_counter


# Compile `return <expr>` as an anonymous function; returns its address,
# or 0 when the expression failed to compile.
int dbg_eval_compile(char* expr):
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
		number_of_args = saved_number_of_args
		length = saved_type_count
		current_function_symbol = saved_function_symbol
		pointer_indirection = 0
		close(file)
		return 0

	filename = path
	file = open(path, 0, 511)
	asserts(c"could not reopen eval buffer", file >= 0)
	line_number = 0
	tab_level = 0
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
	number_of_args = 0
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


# Evaluate the expression and print its value.
void dbg_eval(char* expr):
	int f = dbg_eval_compile(expr)
	if (f == 0):
		return;
	int v = f()
	print(c"= ")
	dbg_print_int_value(v)
	put_char(10)
