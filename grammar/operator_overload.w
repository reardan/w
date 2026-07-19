# Operator overloading v1 (docs/projects/operator_overloading.md):
# 'vec3 operator+(vec3 a, vec3 b):' defines what the binary arithmetic
# operators + - * / % mean for struct values. A definition is an
# ordinary function under a mangled name ('op$+$vec3$vec3'); the
# additive and multiplicative lowering layers dispatch to it when at
# least one operand is a struct VALUE (pointer level 0). Struct
# pointers keep pointer arithmetic and scalars never change meaning;
# a struct-value operand with no matching definition is a compile
# error instead of today's silent address arithmetic.

void function_definition(int current_symbol); /* grammar/program.w */
void check_call_argument(int callee, int signature_type, char* callee_name, int arg_index, int arg_type); /* grammar/postfix_expr.w */
void coerce_call_argument(int param_type, int arg_type); /* grammar/postfix_expr.w */
void push_call_argument(int arg_type); /* grammar/postfix_expr.w */
int finish_call(int callee_type, int s, int expected_args, int callee_sym, char* callee_name, int declared_return, int passed_args, int has_return_buffer, int w_variadic_fixed); /* grammar/postfix_expr.w */


# 1 when an operand of type t is a struct (or union) value: overloads
# are consulted only for these. Pointers to structs keep today's
# pointer arithmetic, exactly like C++.
int operand_is_struct_value(int t):
	t = type_unqualified(t)
	if (t < 0):
		return 0
	if (type_get_pointer_level(t) > 0):
		return 0
	return type_num_args(t) > 0


# The operand-type component of a mangled operator name. Declared
# parameter types and promoted use-site expression types must map to
# the same string: constants read as 'int', every float32-kind type
# (float, float32, float16 and their value forms) as 'float', float64
# as 'float64', strings and vars by their base name, slice values by
# their storage slice record ('int[]'), and everything else as the
# type's name plus one '*' per pointer level (generic_mangle_arg's
# scheme).
char* operator_mangle_type_name(int t):
	t = type_unqualified(t)
	if (t == 3):
		return strclone(c"int")
	int kind = type_float_kind(t)
	if (kind == 1):
		return strclone(c"float")
	if (kind == 2):
		return strclone(c"float64")
	if (type_is_string(t)):
		return strclone(c"string")
	if (type_is_var(t)):
		return strclone(c"var")
	# A slice value (the 'int[] value' record promote gives a use-site
	# slice or array expression) mangles as its storage slice record,
	# the spelling a declared 'int[]' parameter maps to.
	if (type_get_kind(t) == type_kind_slice_value()):
		t = type_get_slice(type_get_element_type(t))
	char* name = strclone(type_get_name(t))
	int stars = type_get_pointer_level(t)
	while (stars > 0):
		char* with_star = strjoin(name, c"*")
		free(name)
		name = with_star
		stars = stars - 1
	return name


# Build 'op$<spelling>$<left>$<right>' from the operand component
# strings. '$' is not a valid identifier character, so no user symbol
# can collide (the generic_mangle precedent).
char* operator_build_name(int op, char* left_name, char* right_name):
	char* name = malloc(strlen(left_name) + strlen(right_name) + 8)
	name[0] = 'o'
	name[1] = 'p'
	name[2] = '$'
	name[3] = op
	name[4] = '$'
	int i = 5
	int j = 0
	while (left_name[j] != 0):
		name[i] = left_name[j]
		i = i + 1
		j = j + 1
	name[i] = '$'
	i = i + 1
	j = 0
	while (right_name[j] != 0):
		name[i] = right_name[j]
		i = i + 1
		j = j + 1
	name[i] = 0
	return name


char* operator_mangled_name(int op, int left_type, int right_type):
	char* left_name = operator_mangle_type_name(left_type)
	char* right_name = operator_mangle_type_name(right_type)
	char* name = operator_build_name(op, left_name, right_name)
	free(left_name)
	free(right_name)
	return name


# 1 when the token following 'operator' in declaration position looks
# like an operator spelling, claiming the declaration for
# operator_definition (which then validates the overloadable five and
# rejects the rest with a clear error). A bare '=' stays an ordinary
# declaration of a global named 'operator'.
int operator_definition_starts_here():
	int c0 = token[0]
	int is_op = (c0 == '+') | (c0 == '-') | (c0 == '*') | (c0 == '/') |
			(c0 == '%') | (c0 == '<') | (c0 == '>') | (c0 == '!') |
			(c0 == '&') | (c0 == '|') | (c0 == '^') | (c0 == '~') | (c0 == '=')
	if (is_op == 0):
		return 0
	if ((c0 == '=') && (token[1] == 0)):
		return 0
	return 1


# Parse 'type operator<op>(T a, U b) [; | body]'. program() consumed
# the 'operator' word; the current token is the operator spelling.
# The definition becomes an ordinary function under the mangled name,
# so prototypes, bodies, imports and call emission all reuse the
# existing machinery (duplicate definitions fall out of the normal
# symbol-redefinition error via the mangled name).
void operator_definition(int decl_type):
	int op = token[0]
	int overloadable = (op == '+') | (op == '-') | (op == '*') | (op == '/') | (op == '%')
	if (token[1] != 0):
		overloadable = 0
	if (overloadable == 0):
		diag_part(c"operator '")
		diag_part(token)
		error(c"' cannot be overloaded")
	get_token()
	expect(c"(")
	# Pre-scan the parameter types to build the mangled name, then
	# rewind so function_definition parses the list normally (the
	# save/seek/restore lookahead of grammar/generic.w).
	char* save = generic_reparse_save()
	int left_type = -1
	int right_type = -1
	int param_count = 0
	while ((peek(c")") == 0) & (token[0] != 0)):
		int t = type_name()
		# 'T... rest' (the w-variadic marker function_definition accepts
		# after a parameter type) never fits an operator: use sites
		# always pass exactly two operands. Reject it here, before the
		# rewind hands the list to function_definition.
		if (accept(c".")):
			error(c"operator definitions do not support variadic parameters")
		if (param_count == 0):
			left_type = t
		if (param_count == 1):
			right_type = t
		param_count = param_count + 1
		# Skip the parameter name and any default value
		while ((peek(c",") == 0) & (peek(c")") == 0) & (token[0] != 0)):
			get_token()
		accept(c",")
	getchar_seek(file, load_ptr(save + 7 * __word_size__))
	generic_reparse_restore(save)
	if (param_count != 2):
		error(c"operator definition takes 2 parameters")
	if ((operand_is_struct_value(left_type) == 0) & (operand_is_struct_value(right_type) == 0)):
		error(c"operator parameters require a struct type")
	char* name = operator_mangled_name(op, left_type, right_type)
	int current_symbol = sym_declare_global(name, decl_type, 1)
	free(name)
	function_definition(current_symbol)


# Dispatch + call emission for 'left <op> right' (op one of + - * / %).
# Entry state (additive_expr.w / multiplicative_expr.w): the promoted
# left operand's word was pushed at left_slot by binary1, the promoted
# right operand's word is in eax, and stack_pos includes any
# temporaries the right side leaked (struct-returning calls park their
# return buffers on the stack). Declines with 0 -- emitting nothing --
# unless at least one operand is a struct value; a struct-value
# operand with no matching overload is a compile error. On a hit the
# emission mirrors the struct-method branch in grammar/postfix_expr.w:
# save the right word, park a return buffer for a struct-returning
# operator, push the callee, the hidden return-buffer argument and
# both operands, then run the shared call tail and compact the stack.
# A scalar result pops the operand saves and the right side's leaked
# temporaries, so the expression is stack-neutral like every other
# scalar expression; a struct result slides its return buffer down
# over them, so the expression leaks exactly the buffer words --
# identical to a plain struct-returning call, which every consumer
# already handles.
int operator_overload_binary(int left_type, int right_type, int op, int left_slot):
	if ((operand_is_struct_value(left_type) == 0) & (operand_is_struct_value(right_type) == 0)):
		return 0
	char* left_name = operator_mangle_type_name(left_type)
	char* right_name = operator_mangle_type_name(right_type)
	char* name = operator_build_name(op, left_name, right_name)
	int callee = sym_lookup(name)
	# A float64 operand (x64 float literals are float64) also matches
	# a 'float' parameter when no exact float64 definition exists; the
	# per-argument coerce below narrows the value.
	if ((callee < 0) & (strcmp(right_name, c"float64") == 0)):
		char* right_folded = operator_build_name(op, left_name, c"float")
		callee = sym_lookup(right_folded)
		if (callee >= 0):
			free(name)
			name = right_folded
		else:
			free(right_folded)
	if ((callee < 0) & (strcmp(left_name, c"float64") == 0)):
		char* left_folded = operator_build_name(op, c"float", right_name)
		callee = sym_lookup(left_folded)
		if (callee >= 0):
			free(name)
			name = left_folded
		else:
			free(left_folded)
	if (callee < 0):
		diag_part(c"no operator '")
		char* spelling = malloc(2)
		spelling[0] = op
		spelling[1] = 0
		diag_part(spelling)
		diag_part(c"' for operands '")
		diag_part(left_name)
		diag_part(c"', '")
		diag_part(right_name)
		error(c"'")
	free(left_name)
	free(right_name)
	int declared_return = load_int(table + callee + 6)
	int has_return_buffer = 0
	int buf_words = 0
	if (declared_return >= 0):
		if (type_num_args(declared_return) > 0):
			buf_words = (type_get_size(declared_return) + word_size - 1) >> word_size_log2
			int j = 0
			while (j < buf_words):
				push_eax()
				j = j + 1
			stack_pos = stack_pos + buf_words
			has_return_buffer = 1
	# Save the right operand's word while materializing the callee
	push_eax()
	stack_pos = stack_pos + 1
	int right_slot = stack_pos
	sym_get_value(name)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	if (has_return_buffer):
		# Hidden return-buffer argument: the buffer starts past the
		# callee word and the right-operand save
		lea_eax_esp_plus(2 << word_size_log2)
		push_eax()
		stack_pos = stack_pos + 1
	# Left operand: reload its saved word and push it as argument 0
	mov_eax_esp_plus((stack_pos - left_slot) << word_size_log2)
	check_call_argument(callee, -1, name, 0, left_type)
	int param0 = sym_param_type(callee, 0)
	if (param0 >= 0):
		coerce_call_argument(param0, left_type)
	push_call_argument(left_type)
	# Right operand: reload its save and push it as argument 1
	mov_eax_esp_plus((stack_pos - right_slot) << word_size_log2)
	check_call_argument(callee, -1, name, 1, right_type)
	int param1 = sym_param_type(callee, 1)
	if (param1 >= 0):
		coerce_call_argument(param1, right_type)
	push_call_argument(right_type)
	# The shared call tail frees name
	int result = finish_call(4, s, sym_num_args(callee), callee, name, declared_return, 2, has_return_buffer, -1)
	# Post-call compaction. Top to bottom the stack still holds the
	# right-operand save, the return buffer (struct returns only), any
	# temporaries the right side leaked and the left-operand save; base
	# is stack_pos from before binary1 pushed the left word.
	int base = left_slot - 1
	if (has_return_buffer == 0):
		# Scalar result: pop all of it in one go (be_pop preserves eax)
		be_pop(stack_pos - base)
		stack_pos = base
		return result
	# Struct result: drop the right-operand save, then slide the buffer
	# down over the junk words below it -- highest word first, the
	# overlap-safe order push_call_argument_compact uses
	be_pop(1)
	stack_pos = stack_pos - 1
	int excess = stack_pos - buf_words - base
	if (excess > 0):
		int i = buf_words - 1
		while (i >= 0):
			mov_eax_esp_plus(i << word_size_log2)
			store_stack_var((i + excess) << word_size_log2)
			i = i - 1
		be_pop(excess)
		stack_pos = stack_pos - excess
	# finish_call's return-buffer lea ran before the compaction; redo
	# it now that the buffer sits at the top of the stack
	lea_eax_esp_plus(0)
	result = type_value(declared_return)
	return result
