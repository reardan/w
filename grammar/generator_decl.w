/*
Generator declarations and call lowering (docs/projects/iteration.md,
stackful coroutines, model A):

	generator int counter(int n):
		yield i

The 'generator' marker is parsed in grammar/program.w before the usual
"type-name identifier (" declaration. The body compiles like a normal
function plus a hidden trailing generator* parameter (__w_gen_self)
that the call trampoline places just above the return-address slot, so
yield can reach the generator object like any other parameter.

Calling a generator function does not run the body: the call lowers to
__w_gen_create(fn, argv, argc) (lib/generator.w), which allocates the
object plus a fresh 64KB stack seeded with a trampoline frame holding
the copied arguments; the first gen_next switches into the body. The
call expression's static type is generator*.

Programs must 'import lib.generator' before declaring or calling a
generator (a missing import is a compile error); the compiler finds
the runtime through the 'generator' struct type and the __w_gen_*
helper symbols it declares.
*/


# Defined in grammar/program.w (shared with function_definition)
int parse_constant_default();


# The generator* type for call results and the hidden self parameter.
# Errors out when lib.generator has not been imported.
int generator_object_pointer_type():
	int generator_type = type_lookup(c"generator")
	if (generator_type < 0):
		error(c"generator functions require 'import lib.generator'")
	return type_get_next_pointer(generator_type)


# Emit __w_gen_return(__w_gen_self): mark the generator done and switch
# back to the consumer permanently. Used for 'return' inside a
# generator body and for falling off the end; never returns, so the
# body never executes a plain ret.
void emit_generator_finish_call():
	sym_get_value(c"__w_gen_return")
	push_eax()
	stack_pos = stack_pos + 1
	sym_get_value(c"__w_gen_self")
	promote_eax()
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_esp_plus(1 << word_size_log2)
	call_eax()
	be_pop(2)
	stack_pos = stack_pos - 2


# Emit __w_gen_yield(__w_gen_self, value) with the yield value in eax:
# store it into the object and switch back to the consumer until the
# next gen_next.
void emit_generator_yield_call():
	push_eax()
	stack_pos = stack_pos + 1
	sym_get_value(c"__w_gen_yield")
	push_eax()
	stack_pos = stack_pos + 1
	sym_get_value(c"__w_gen_self")
	promote_eax()
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_esp_plus(2 << word_size_log2)
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_esp_plus(2 << word_size_log2)
	call_eax()
	be_pop(4)
	stack_pos = stack_pos - 4


# Parses "parameter-list ) [; | body]" for the generator symbol at
# table offset current_symbol; 'generator', the yield type, the name
# and the opening "(" have already been consumed. Mirrors
# function_definition in grammar/program.w, except that parameters
# must be word-sized (the call trampoline copies them by the word),
# the body gets the hidden __w_gen_self parameter, and the epilogue
# finishes the generator instead of returning.
void generator_function_definition(int current_symbol):
	int self_type = generator_object_pointer_type()
	table[current_symbol + 10] = 2 /* store function type */
	int n = table_pos
	number_of_args = 0
	int param_count = 0
	int saw_default = 0
	int function_start = codepos
	while (accept(c")") == 0):
		param_count = param_count + 1
		number_of_args = number_of_args + 1
		int type = type_name()
		if (accept(c".")):
			error(c"variadic generator parameters are not supported")
		if (type_stack_words(type) != 1):
			error(c"generator parameters must be word-sized")
		if (type_num_args(type_real(type)) > 0):
			error(c"generator parameters must be word-sized")
		if (param_count <= sym_max_param_slots()):
			save_int(table + current_symbol + 22 + (param_count << 2), type)
		if (peek(c")") == 0):
			sym_declare(token, type, 'A', number_of_args, 1)
			pointer_indirection = 0
			get_token()

		# "= constant" records a default, exactly like function_definition
		# in grammar/program.w; generator_call_suffix pushes them for
		# missing trailing arguments.
		if (accept(c"=")):
			if (param_count > sym_max_param_slots()):
				error(c"default values are only supported on the first 10 parameters")
			int default_value = parse_constant_default()
			if (saw_default == 0):
				sym_clear_param_defaults(current_symbol)
			saw_default = 1
			sym_set_param_default(current_symbol, param_count - 1, default_value)
		else if (saw_default):
			error(c"parameter without a default follows a parameter with a default")

		accept(c",") /* ignore trailing comma */

	save_int(table + current_symbol + 22, param_count)
	sym_set_generator(current_symbol)

	if (accept(c";") == 0):
		# The hidden self parameter sits just above the return-address
		# slot, like a real last parameter pushed by the trampoline
		number_of_args = number_of_args + 1
		pointer_indirection = 1
		sym_declare(c"__w_gen_self", self_type, 'A', number_of_args, 1)
		pointer_indirection = 0
		sym_define_global(current_symbol)
		current_function_symbol = current_symbol
		in_generator_body = 1
		enclosing_tab_level = 0
		debug_func_note(function_start, number_of_args)
		statement()
		# Falling off the end finishes the generator; __w_gen_return
		# switches back to the consumer and never returns
		emit_generator_finish_call()
		in_generator_body = 0
		save_int(table + current_symbol + 14, codepos - function_start)

	table_pos = n


# Parses a top-level generator declaration; peek(c"generator") has
# already matched and the 'generator' keyword is the current token.
void generator_declaration():
	get_token() /* consume 'generator' */
	int yield_type = type_name()
	if ((type_get_size(yield_type) == 0) | (type_stack_words(yield_type) != 1)):
		error(c"generator yield type must be a word-sized value")
	if (type_num_args(type_real(yield_type)) > 0):
		error(c"generator yield type must be a word-sized value")
	int current_symbol = sym_declare_global(token, yield_type, 1)
	get_token()
	expect(c"(")
	generator_function_definition(current_symbol)


# Call lowering for a direct call of a generator function; the callee's
# address is in eax and the opening "(" has been consumed. Parses and
# pushes the arguments like a normal call, then calls
# __w_gen_create(fn, argv, argc) instead of the function itself.
# Returns the call expression's type: generator* (as a value).
int generator_call_suffix(int callee_sym, char* callee_name, int expected_args):
	int result_type = generator_object_pointer_type()
	int s = stack_pos
	push_eax() /* the generator function's address */
	stack_pos = stack_pos + 1
	int passed_args = 0
	if (accept(c")") == 0):
		int arg_type = expression()
		arg_type = promote(arg_type)
		if (type_num_args(type_real(arg_type)) > 0):
			error(c"struct arguments are not supported in generator calls")
		check_call_argument(callee_sym, -1, callee_name, passed_args, arg_type)
		int param_type = sym_param_type(callee_sym, passed_args)
		if (param_type >= 0):
			coerce_call_argument(param_type, arg_type)
		push_eax()
		stack_pos = stack_pos + 1
		passed_args = passed_args + 1
		while (accept(c",")):
			arg_type = expression()
			arg_type = promote(arg_type)
			if (type_num_args(type_real(arg_type)) > 0):
				error(c"struct arguments are not supported in generator calls")
			check_call_argument(callee_sym, -1, callee_name, passed_args, arg_type)
			int loop_param_type = sym_param_type(callee_sym, passed_args)
			if (loop_param_type >= 0):
				coerce_call_argument(loop_param_type, arg_type)
			push_eax()
			stack_pos = stack_pos + 1
			passed_args = passed_args + 1
		expect(c")")

	# Missing trailing arguments whose parameters all carry defaults are
	# filled in with the recorded constants, like parse_call_suffix
	if ((callee_sym >= 0) && (expected_args > passed_args)):
		int missing_all_defaulted = 1
		int check_index = passed_args
		while (check_index < expected_args):
			if (sym_param_has_default(callee_sym, check_index) == 0):
				missing_all_defaulted = 0
			check_index = check_index + 1
		if (missing_all_defaulted):
			while (passed_args < expected_args):
				mov_eax_int(sym_param_default(callee_sym, passed_args))
				int default_param_type = sym_param_type(callee_sym, passed_args)
				if (default_param_type >= 0):
					coerce(default_param_type, 3)
				push_eax()
				stack_pos = stack_pos + 1
				passed_args = passed_args + 1

	if (expected_args >= 0):
		if (passed_args != expected_args):
			diag_part(c"warning: function '")
			diag_part(callee_name)
			diag_part(c"' expects ")
			diag_part(itoa(expected_args))
			diag_part(c" arguments, got ")
			warning(itoa(passed_args))
	if (callee_name != 0):
		free(callee_name)

	# Stack: argN .. arg1, fn. Call __w_gen_create(fn, argv, argc)
	# where argv points at argN (the copy loop walks upwards).
	sym_get_value(c"__w_gen_create")
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_esp_plus((passed_args + 1) << word_size_log2)
	push_eax() /* arg 1: fn */
	stack_pos = stack_pos + 1
	lea_eax_esp_plus(2 << word_size_log2)
	push_eax() /* arg 2: argv */
	stack_pos = stack_pos + 1
	mov_eax_int(passed_args)
	push_eax() /* arg 3: argc */
	stack_pos = stack_pos + 1
	mov_eax_esp_plus(3 << word_size_log2)
	call_eax()
	be_pop(stack_pos - s)
	stack_pos = s
	last_call_return_type = result_type
	last_call_end = codepos
	return type_value(result_type)
