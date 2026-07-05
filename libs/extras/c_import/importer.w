/*
Lower a declaration-oriented C header subset into the compiler's existing
type table, symbol table, and dynamic FFI registry.

Broad libc headers are preprocessed (libs/extras/c_preprocessor), parsed with
the generated C parser, and imported declaration by declaration. Symbol
collisions follow "first definition wins": names already known to the
compiler (W definitions or earlier c_import statements) are skipped instead
of redefined, so several overlapping headers can be imported together.
*/
import lib.lib
import compiler.type_table
import compiler.symbol_table
import code_generator.code_emitter
import code_generator.dynamic_registry
import code_generator.ffi
import structures.hash_map
import structures.string
import libs.extras.parser_generator.runtime
import libs.extras.parser_generator.source_writer
import libs.extras.c_import.generated_c_parser
import libs.extras.c_preprocessor.pp_token
import libs.extras.c_preprocessor.pp_macro
import libs.extras.c_preprocessor.pp_expr
import libs.extras.c_preprocessor.pp_directives


struct ci_decl_info:
	int is_typedef
	int is_extern
	int is_static
	int is_inline
	int base_type


struct ci_declarator_info:
	char* name
	int type
	int is_function
	pg_ast_node* params
	int is_function_pointer
	int has_array
	int array_length


int extern_max_params();


# Session state shared by every c_import statement in one compilation.
hash_map* ci_imported_functions
hash_map* ci_const_values
hash_map* ci_type_alignments
int ci_anon_counter

# ABI classes (see ffi_type_class) of the parameters most recently lowered
# by ci_lower_params_from, one byte per parameter.
char* ci_param_classes


void ci_session_init():
	if (ci_imported_functions == 0):
		ci_imported_functions = hash_map_new()
		ci_const_values = hash_map_new()
		ci_type_alignments = hash_map_new()
		ci_param_classes = malloc(extern_max_params())


int ci_type_from_specs(pg_ast_node* specs);
int ci_import_enumerators(pg_ast_node* node, int enum_type, int value);
void ci_import_struct_declarator_list(int struct_type, int base_type, pg_ast_node* node, int* offset, int* max_align);
ci_declarator_info* ci_read_declarator(int base_type, pg_ast_node* declarator);
int ci_eval_const(pg_ast_node* node);


int ci_is_ast(pg_ast_node* node, int kind):
	if (node == 0):
		return 0
	return (node.token == 0) & (node.kind == kind)


int ci_is_token(pg_ast_node* node, int kind):
	if (node == 0):
		return 0
	return (node.token != 0) & (node.kind == kind)


pg_ast_node* ci_child_ast(pg_ast_node* node, int kind):
	int i = 0
	while (i < pg_ast_child_count(node)):
		pg_ast_node* child = pg_ast_child(node, i)
		if (ci_is_ast(child, kind)):
			return child
		i = i + 1
	return 0


pg_ast_node* ci_child_token(pg_ast_node* node, int kind):
	int i = 0
	while (i < pg_ast_child_count(node)):
		pg_ast_node* child = pg_ast_child(node, i)
		if (ci_is_token(child, kind)):
			return child
		i = i + 1
	return 0


pg_ast_node* ci_find_ast(pg_ast_node* node, int kind):
	if (node == 0):
		return 0
	if (ci_is_ast(node, kind)):
		return node
	int i = 0
	while (i < pg_ast_child_count(node)):
		pg_ast_node* found = ci_find_ast(pg_ast_child(node, i), kind)
		if (found != 0):
			return found
		i = i + 1
	return 0


pg_ast_node* ci_find_token(pg_ast_node* node, int kind):
	if (node == 0):
		return 0
	if (ci_is_token(node, kind)):
		return node
	int i = 0
	while (i < pg_ast_child_count(node)):
		pg_ast_node* found = ci_find_token(pg_ast_child(node, i), kind)
		if (found != 0):
			return found
		i = i + 1
	return 0


int ci_has_token(pg_ast_node* node, int kind):
	return ci_find_token(node, kind) != 0


int ci_count_token(pg_ast_node* node, int kind):
	if (node == 0):
		return 0
	int count = 0
	if (ci_is_token(node, kind)):
		count = 1
	int i = 0
	while (i < pg_ast_child_count(node)):
		count = count + ci_count_token(pg_ast_child(node, i), kind)
		i = i + 1
	return count


int ci_is_header_control(int c):
	if ((c <= 0) | (c >= 32)):
		return 0
	if ((c == 9) | (c == 10) | (c == 13)):
		return 0
	return 1


int ci_is_ident_start_char(int c):
	return ((c >= 'a') & (c <= 'z')) | ((c >= 'A') & (c <= 'Z')) | (c == '_')


int ci_is_ident_part_char(int c):
	return ci_is_ident_start_char(c) | ((c >= '0') & (c <= '9'))


int ci_known_noop_header_ident(char* name):
	if (strcmp(name, c"__BEGIN_DECLS") == 0):
		return 1
	if (strcmp(name, c"__END_DECLS") == 0):
		return 1
	if (strcmp(name, c"__THROW") == 0):
		return 1
	if (strcmp(name, c"__THROWNL") == 0):
		return 1
	if (strcmp(name, c"__nonnull") == 0):
		return 1
	if (strcmp(name, c"__attribute__") == 0):
		return 1
	if (strcmp(name, c"__attribute_malloc__") == 0):
		return 1
	if (strcmp(name, c"__wur") == 0):
		return 1
	if (strcmp(name, c"__restrict") == 0):
		return 1
	if (strcmp(name, c"__extension__") == 0):
		return 1
	if (strcmp(name, c"__attr_dealloc") == 0):
		return 1
	if (strcmp(name, c"__attr_dealloc_fclose") == 0):
		return 1
	if (strcmp(name, c"__attr_access") == 0):
		return 1
	if (strcmp(name, c"__fortified_attr_access") == 0):
		return 1
	return 0


void ci_append_header_space_span(string_builder* out, char* source, int start, int end):
	while (start < end):
		if (source[start] == 10):
			string_append_char(out, 10)
		else:
			string_append_char(out, ' ')
		start = start + 1


int ci_skip_quoted_header_text(char* source, int index):
	int quote = source[index]
	index = index + 1
	while ((source[index] != 0) & (source[index] != quote)):
		if (source[index] == 92):
			index = index + 1
			if (source[index] == 0):
				return index
		index = index + 1
	if (source[index] == quote):
		index = index + 1
	return index


int ci_skip_balanced_header_parens(char* source, int index):
	if (source[index] != '('):
		return index
	int depth = 0
	while (source[index] != 0):
		if ((source[index] == '"') | (source[index] == 39)):
			index = ci_skip_quoted_header_text(source, index)
		else:
			if (source[index] == '('):
				depth = depth + 1
			else if (source[index] == ')'):
				depth = depth - 1
				if (depth == 0):
					return index + 1
			index = index + 1
	return index


int ci_skip_inline_header_space(char* source, int index):
	while ((source[index] == ' ') | (source[index] == 9) | (source[index] == 13)):
		index = index + 1
	return index


int ci_prepare_known_header_ident_end(char* source, int index):
	int end = index
	while (ci_is_ident_part_char(source[end])):
		end = end + 1
	int saved = source[end]
	source[end] = 0
	int is_known = ci_known_noop_header_ident(source + index)
	source[end] = saved
	if (is_known == 0):
		return index
	int args = ci_skip_inline_header_space(source, end)
	if (source[args] == '('):
		return ci_skip_balanced_header_parens(source, args)
	return end


char* ci_prepare_header_source(char* source):
	string_builder* out = string_new_sized(strlen(source) + 1)
	int i = 0
	while (source[i] != 0):
		int end = i
		if (ci_is_ident_start_char(source[i])):
			end = ci_prepare_known_header_ident_end(source, i)
		if (end != i):
			ci_append_header_space_span(out, source, i, end)
			i = end
		else:
			if (ci_is_header_control(source[i])):
				string_append_char(out, ' ')
			else:
				string_append_char(out, source[i])
			i = i + 1
	char* prepared = out.data
	free(out)
	return prepared


int ci_lookup_type(char* name):
	int type = type_lookup(name)
	if (type >= 0):
		return type
	if (strcmp(name, c"__builtin_va_list") == 0):
		return type_push_alias(strclone(name), type_get_next_pointer(type_lookup(c"char")))
	print_error(c"c_import: unsupported C type '")
	print_error(name)
	error(c"'")


int ci_void_pointer_type():
	return type_get_next_pointer(ci_lookup_type(c"void"))


int ci_apply_pointers(int type, int count):
	while (count > 0):
		type = type_get_next_pointer(type)
		count = count - 1
	return type


# Alignment bookkeeping for imported C layouts. W's own structs pack fields
# without padding, so imported structs insert explicit filler fields; the
# alignment of each imported type is recorded here.
void ci_set_type_alignment(int type_index, int alignment):
	char* key = itoa(type_index)
	hash_map_set(ci_type_alignments, key, alignment)
	free(key)


int ci_pow2_alignment(int size):
	int a = 1
	while (((a + a) <= size) & ((a + a) <= word_size)):
		a = a + a
	return a


int ci_type_alignment(int type_index):
	type_index = type_unqualified(type_index)
	if (type_index < 0):
		return 1
	if (type_get_pointer_level(type_index) > 0):
		return word_size
	char* key = itoa(type_index)
	int recorded = hash_map_get_default(ci_type_alignments, key, 0)
	free(key)
	if (recorded != 0):
		return recorded
	int size = type_get_size(type_index)
	if (size <= 0):
		return 1
	return ci_pow2_alignment(size)


# Opaque byte-blob types used for array fields and struct padding.
int ci_filler_type(int size):
	char* n = itoa(size)
	char* name = strjoin(c"__ci_bytes_", n)
	free(n)
	int existing = type_lookup(name)
	if (existing >= 0):
		free(name)
		return existing
	int filler = type_push_size(name, size)
	ci_set_type_alignment(filler, 1)
	return filler


char* ci_unique_name(char* prefix):
	ci_anon_counter = ci_anon_counter + 1
	char* n = itoa(ci_anon_counter)
	char* name = strjoin(prefix, n)
	free(n)
	return name


# First direct child identifier token; unlike ci_find_token this does not
# descend, so an anonymous struct body's field names are not mistaken for
# the tag name.
char* ci_direct_ident(pg_ast_node* node):
	pg_ast_node* ident = ci_child_token(node, clang_token_IDENT())
	if (ident == 0):
		return 0
	return ident.text


char* ci_first_ident(pg_ast_node* node):
	pg_ast_node* ident = ci_find_token(node, clang_token_IDENT())
	if (ident == 0):
		return 0
	return ident.text


pg_ast_node* ci_declaration_specs(pg_ast_node* node):
	pg_ast_node* specs = ci_child_ast(node, clang_ast_declaration_specifiers())
	if (specs == 0):
		specs = ci_child_ast(node, clang_ast_typedef_name_declaration_specifiers())
	return specs


pg_ast_node* ci_qualifier_specs(pg_ast_node* node):
	pg_ast_node* specs = ci_child_ast(node, clang_ast_specifier_qualifier_list())
	if (specs == 0):
		specs = ci_child_ast(node, clang_ast_typedef_name_specifier_qualifier_list())
	return specs


/* ---------- constant expression evaluation ---------- */


int ci_hex_digit(int c):
	if ((c >= '0') & (c <= '9')):
		return c - '0'
	if ((c >= 'a') & (c <= 'f')):
		return c - 'a' + 10
	if ((c >= 'A') & (c <= 'F')):
		return c - 'A' + 10
	return -1


# Integer constants: decimal, hex, octal; integer suffixes are ignored.
int ci_parse_number_text(char* text):
	int base = 10
	int i = 0
	if (text[0] == '0'):
		if ((text[1] == 'x') | (text[1] == 'X')):
			base = 16
			i = 2
		else if (text[1] != 0):
			base = 8
			i = 1
	int value = 0
	while (text[i] != 0):
		int digit = -1
		if (base == 16):
			digit = ci_hex_digit(text[i])
		else if ((text[i] >= '0') & (text[i] <= '9')):
			digit = text[i] - '0'
		if ((digit < 0) | (digit >= base)):
			return value
		value = value * base + digit
		i = i + 1
	return value


int ci_char_escape_value(int c):
	if (c == 'n'):
		return 10
	if (c == 't'):
		return 9
	if (c == 'r'):
		return 13
	if (c == '0'):
		return 0
	return c


int ci_parse_char_text(char* text):
	int i = 0
	while ((text[i] != 0) & (text[i] != 39)):
		i = i + 1
	if (text[i] == 0):
		return 0
	i = i + 1
	if (text[i] == 92):
		return ci_char_escape_value(text[i + 1])
	return text[i]


int ci_binary_op_precedence(char* op):
	if (strcmp(op, c"||") == 0):
		return 1
	if (strcmp(op, c"&&") == 0):
		return 2
	if (strcmp(op, c"|") == 0):
		return 3
	if (strcmp(op, c"^") == 0):
		return 4
	if (strcmp(op, c"&") == 0):
		return 5
	if ((strcmp(op, c"==") == 0) | (strcmp(op, c"!=") == 0)):
		return 6
	if ((strcmp(op, c"<") == 0) | (strcmp(op, c">") == 0) | (strcmp(op, c"<=") == 0) | (strcmp(op, c">=") == 0)):
		return 7
	if ((strcmp(op, c"<<") == 0) | (strcmp(op, c">>") == 0)):
		return 8
	if ((strcmp(op, c"+") == 0) | (strcmp(op, c"-") == 0)):
		return 9
	return 10


int ci_xor_value(int left, int right):
	return (left | right) & (0 - (left & right) - 1)


int ci_apply_binary_op(char* op, int left, int right):
	if (strcmp(op, c"||") == 0):
		return (left != 0) | (right != 0)
	if (strcmp(op, c"&&") == 0):
		return (left != 0) & (right != 0)
	if (strcmp(op, c"|") == 0):
		return left | right
	if (strcmp(op, c"^") == 0):
		return ci_xor_value(left, right)
	if (strcmp(op, c"&") == 0):
		return left & right
	if (strcmp(op, c"==") == 0):
		return left == right
	if (strcmp(op, c"!=") == 0):
		return left != right
	if (strcmp(op, c"<") == 0):
		return left < right
	if (strcmp(op, c">") == 0):
		return left > right
	if (strcmp(op, c"<=") == 0):
		return left <= right
	if (strcmp(op, c">=") == 0):
		return left >= right
	if (strcmp(op, c"<<") == 0):
		return left << right
	if (strcmp(op, c">>") == 0):
		return left >> right
	if (strcmp(op, c"+") == 0):
		return left + right
	if (strcmp(op, c"-") == 0):
		return left - right
	if (strcmp(op, c"*") == 0):
		return left * right
	if (strcmp(op, c"/") == 0):
		if (right == 0):
			return 0
		return left / right
	if (strcmp(op, c"%") == 0):
		if (right == 0):
			return 0
		return left % right
	return 0


# The grammar parses binary expressions as a flat operand/operator list, so
# precedence is applied here with an operand/operator stack. Operator texts
# are stored word-sized because they are heap pointers.
int ci_eval_binary(pg_ast_node* node):
	int count = pg_ast_child_count(node)
	char* values = malloc((count + 1) << 2)
	char* precedences = malloc((count + 1) << 2)
	char* ops = malloc((count + 1) * word_size)
	int value_top = 0
	int op_top = 0
	save_int(values, ci_eval_const(pg_ast_child(node, 0)))
	value_top = 1
	int i = 1
	while (i < count):
		pg_ast_node* tail = pg_ast_child(node, i)
		pg_ast_node* op_node = ci_child_ast(tail, clang_ast_binary_operator())
		pg_ast_node* op_token = pg_ast_child(op_node, 0)
		char* op = op_token.text
		int precedence = ci_binary_op_precedence(op)
		while (op_top > 0):
			if (load_int(precedences + ((op_top - 1) << 2)) < precedence):
				break
			int right = load_int(values + ((value_top - 1) << 2))
			int left = load_int(values + ((value_top - 2) << 2))
			value_top = value_top - 2
			save_int(values + (value_top << 2), ci_apply_binary_op(cast(char*, load_i(ops + (op_top - 1) * word_size, word_size)), left, right))
			value_top = value_top + 1
			op_top = op_top - 1
		save_i(ops + op_top * word_size, cast(int, op), word_size)
		save_int(precedences + (op_top << 2), precedence)
		op_top = op_top + 1
		int operand = ci_eval_const(ci_child_ast(tail, clang_ast_unary_expression()))
		save_int(values + (value_top << 2), operand)
		value_top = value_top + 1
		i = i + 1
	while (op_top > 0):
		int right = load_int(values + ((value_top - 1) << 2))
		int left = load_int(values + ((value_top - 2) << 2))
		value_top = value_top - 2
		save_int(values + (value_top << 2), ci_apply_binary_op(cast(char*, load_i(ops + (op_top - 1) * word_size, word_size)), left, right))
		value_top = value_top + 1
		op_top = op_top - 1
	int result = load_int(values)
	free(values)
	free(precedences)
	free(ops)
	return result


# Best-effort type resolution for sizeof/cast operands; returns -1 instead
# of erroring so unknown names collapse to 0.
int ci_try_type_from_name(char* name):
	if (name == 0):
		return -1
	return type_lookup(name)


int ci_abstract_is_pointer(pg_ast_node* abstract):
	if (abstract == 0):
		return 0
	if (ci_child_ast(abstract, clang_ast_pointer()) != 0):
		return 1
	return 0


int ci_eval_sizeof_type(pg_ast_node* type_name):
	pg_ast_node* abstract = ci_child_ast(type_name, clang_ast_abstract_declarator())
	if (ci_abstract_is_pointer(abstract)):
		return word_size
	pg_ast_node* specs = ci_qualifier_specs(type_name)
	pg_ast_node* typedef_spec = ci_find_ast(specs, clang_ast_typedef_name_specifier())
	if (typedef_spec != 0):
		int named = ci_try_type_from_name(ci_first_ident(typedef_spec))
		if (named < 0):
			return 0
		return type_get_size(named)
	return type_get_size(ci_type_from_specs(specs))


int ci_eval_sizeof(pg_ast_node* node):
	pg_ast_node* type_name = ci_child_ast(node, clang_ast_type_name())
	if (type_name != 0):
		return ci_eval_sizeof_type(type_name)
	# sizeof expr: only "sizeof (type_alias)" shapes are resolvable here
	pg_ast_node* ident = ci_find_token(node, clang_token_IDENT())
	if (ident != 0):
		int named = ci_try_type_from_name(ident.text)
		if (named >= 0):
			return type_get_size(named)
	return word_size


int ci_eval_unary(pg_ast_node* node):
	pg_ast_node* first = pg_ast_child(node, 0)
	if (ci_is_token(first, clang_token_KW_SIZEOF())):
		return ci_eval_sizeof(node)
	if (ci_is_ast(first, clang_ast_unary_operator())):
		pg_ast_node* op_token = pg_ast_child(first, 0)
		int value = ci_eval_const(pg_ast_child(node, 1))
		if (strcmp(op_token.text, c"-") == 0):
			return 0 - value
		if (strcmp(op_token.text, c"~") == 0):
			return 0 - value - 1
		if (strcmp(op_token.text, c"!") == 0):
			return value == 0
		return value
	return ci_eval_const(first)


# An expression node that is just a single identifier (no operators),
# e.g. the "(__uint16_t)" in a typedef-name cast.
char* ci_expr_single_ident(pg_ast_node* node):
	while (node != 0):
		if (node.token != 0):
			if (node.kind == clang_token_IDENT()):
				return node.text
			return 0
		if (pg_ast_child_count(node) != 1):
			return 0
		node = pg_ast_child(node, 0)
	return 0


# A parenthesized typedef name followed by call syntax is how casts of
# typedef types parse without a symbol table: "(__uint16_t) (x)" becomes
# primary("(__uint16_t)") + call("(x)"). Evaluate such shapes as casts.
int ci_eval_postfix(pg_ast_node* node):
	pg_ast_node* primary = pg_ast_child(node, 0)
	if (pg_ast_child_count(node) > 1):
		pg_ast_node* tail = pg_ast_child(node, 1)
		pg_ast_node* expr = ci_child_ast(primary, clang_ast_expression())
		pg_ast_node* args = ci_child_ast(tail, clang_ast_argument_expression_list())
		if ((expr != 0) & (args != 0)):
			char* name = ci_expr_single_ident(expr)
			if (name != 0):
				if (ci_try_type_from_name(name) >= 0):
					return ci_eval_const(pg_ast_child(args, 0))
	return ci_eval_const(primary)


int ci_eval_primary(pg_ast_node* node):
	pg_ast_node* first = pg_ast_child(node, 0)
	if (ci_is_token(first, clang_token_NUMBER())):
		return ci_parse_number_text(first.text)
	if (ci_is_token(first, clang_token_CHAR_LITERAL())):
		return ci_parse_char_text(first.text)
	if (ci_is_token(first, clang_token_IDENT())):
		return hash_map_get_default(ci_const_values, first.text, 0)
	pg_ast_node* expr = ci_child_ast(node, clang_ast_expression())
	if (expr != 0):
		return ci_eval_const(expr)
	return 0


int ci_eval_conditional(pg_ast_node* node):
	int value = ci_eval_const(pg_ast_child(node, 0))
	pg_ast_node* tail = ci_child_ast(node, clang_ast_conditional_tail())
	if (tail == 0):
		return value
	if (value != 0):
		return ci_eval_const(ci_child_ast(tail, clang_ast_expression()))
	return ci_eval_const(ci_child_ast(tail, clang_ast_conditional_expression()))


int ci_eval_const(pg_ast_node* node):
	if (node == 0):
		return 0
	if (node.token != 0):
		if (node.kind == clang_token_NUMBER()):
			return ci_parse_number_text(node.text)
		if (node.kind == clang_token_CHAR_LITERAL()):
			return ci_parse_char_text(node.text)
		if (node.kind == clang_token_IDENT()):
			return hash_map_get_default(ci_const_values, node.text, 0)
		return 0
	if (node.kind == clang_ast_binary_expression()):
		return ci_eval_binary(node)
	if (node.kind == clang_ast_conditional_expression()):
		return ci_eval_conditional(node)
	if (node.kind == clang_ast_unary_expression()):
		return ci_eval_unary(node)
	if (node.kind == clang_ast_postfix_expression()):
		return ci_eval_postfix(node)
	if (node.kind == clang_ast_primary_expression()):
		return ci_eval_primary(node)
	if (node.kind == clang_ast_cast_expression()):
		return ci_eval_const(ci_child_ast(node, clang_ast_unary_expression()))
	if (node.kind == clang_ast_expression()):
		int count = pg_ast_child_count(node)
		if (count > 1):
			pg_ast_node* last_tail = pg_ast_child(node, count - 1)
			return ci_eval_const(ci_child_ast(last_tail, clang_ast_assignment_expression()))
		return ci_eval_const(pg_ast_child(node, 0))
	# constant_expression, enum_value, assignment_expression, expression_tail:
	# evaluate the last expression-shaped child
	int i = pg_ast_child_count(node) - 1
	while (i >= 0):
		pg_ast_node* child = pg_ast_child(node, i)
		if (child.token == 0):
			return ci_eval_const(child)
		i = i - 1
	return 0


int ci_constant_int(pg_ast_node* node):
	pg_ast_node* expr = ci_find_ast(node, clang_ast_constant_expression())
	if (expr != 0):
		return ci_eval_const(expr)
	return ci_eval_const(node)


/* ---------- struct / union / enum import ---------- */


int ci_primitive_type(pg_ast_node* specs):
	if (ci_has_token(specs, clang_token_KW_VOID())):
		return ci_lookup_type(c"void")
	if (ci_has_token(specs, clang_token_KW_DOUBLE())):
		return ci_lookup_type(c"float64")
	if (ci_has_token(specs, clang_token_KW_FLOAT())):
		return ci_lookup_type(c"float32")
	if (ci_has_token(specs, clang_token_KW_CHAR())):
		if (ci_has_token(specs, clang_token_KW_UNSIGNED())):
			return ci_lookup_type(c"uint8")
		return ci_lookup_type(c"char")
	if (ci_has_token(specs, clang_token_KW_SHORT())):
		if (ci_has_token(specs, clang_token_KW_UNSIGNED())):
			return ci_lookup_type(c"uint16")
		return ci_lookup_type(c"int16")
	if (ci_count_token(specs, clang_token_KW_LONG()) > 1):
		if (ci_has_token(specs, clang_token_KW_UNSIGNED())):
			return ci_lookup_type(c"uint64")
		return ci_lookup_type(c"int64")
	# C 'long' follows the target word (ILP32/LP64); C 'int' is always 32-bit
	if (ci_has_token(specs, clang_token_KW_LONG())):
		if (ci_has_token(specs, clang_token_KW_UNSIGNED())):
			return ci_lookup_type(c"uint")
		return ci_lookup_type(c"int")
	if (ci_has_token(specs, clang_token_KW_UNSIGNED())):
		return ci_lookup_type(c"uint32")
	if (ci_has_token(specs, clang_token_KW_INT()) | ci_has_token(specs, clang_token_KW_SIGNED())):
		return ci_lookup_type(c"int32")
	return ci_lookup_type(c"int")


void ci_struct_pad_to(int type_index, int* offset, int alignment):
	if (alignment <= 1):
		return
	int rem = *offset % alignment
	if (rem == 0):
		return
	int pad = alignment - rem
	type_add_arg(type_index, ci_unique_name(c"__ci_pad_"), ci_filler_type(pad))
	*offset = *offset + pad


# Fields beyond the type table's slot limit collapse into one filler so the
# struct size stays correct even for very wide C structs.
int ci_struct_has_field_room(int type_index):
	return type_num_args(type_index) < 96


void ci_struct_add_field(int type_index, char* name, int field_type, int* offset, int* max_align, int is_union):
	int alignment = ci_type_alignment(field_type)
	int size = type_get_size(field_type)
	if (alignment > *max_align):
		*max_align = alignment
	if (ci_struct_has_field_room(type_index) == 0):
		return
	if (is_union == 0):
		ci_struct_pad_to(type_index, offset, alignment)
	type_add_arg(type_index, name, field_type)
	if (is_union == 0):
		*offset = *offset + size


int ci_import_struct(pg_ast_node* specifier):
	char* name = ci_direct_ident(specifier)
	int is_named = 1
	if (name == 0):
		name = ci_unique_name(c"__ci_anon_")
		is_named = 0
	int existing = type_lookup(name)
	pg_ast_node* body = ci_child_ast(specifier, clang_ast_struct_body())
	if ((existing >= 0) & (body == 0)):
		return existing
	if (existing >= 0):
		if (type_num_args(existing) > 0):
			# already imported with fields: first definition wins
			return existing
	int type_index = existing
	if (type_index < 0):
		type_index = type_push_size(strclone(name), 0)
		if (is_named & (sym_lookup(name) < 0)):
			sym_declare_global(name, type_index, 1)
	int is_union = ci_has_token(ci_child_ast(specifier, clang_ast_struct_or_union()), clang_token_KW_UNION())
	if (is_union):
		type_set_kind(type_index, type_kind_union)
	if (body != 0):
		int offset = 0
		int max_align = 1
		int i = 0
		while (i < pg_ast_child_count(body)):
			pg_ast_node* field_decl = pg_ast_child(body, i)
			if (ci_is_ast(field_decl, clang_ast_struct_declaration())):
				pg_ast_node* field_specs = ci_qualifier_specs(field_decl)
				int field_base = ci_type_from_specs(field_specs)
				pg_ast_node* list = ci_child_ast(field_decl, clang_ast_struct_declarator_list())
				if (list == 0):
					# anonymous member: embed the aggregate unnamed
					ci_struct_add_field(type_index, ci_unique_name(c"__ci_anon_member_"), field_base, &offset, &max_align, is_union)
				else:
					ci_import_struct_declarator_list(type_index, field_base, list, &offset, &max_align)
			i = i + 1
		# trailing padding so arrays of this struct lay out like C
		if (is_union):
			int union_size = type_get_size(type_index)
			int rounded = union_size
			if (max_align > 1):
				int rem = union_size % max_align
				if (rem != 0):
					rounded = union_size + max_align - rem
			if (rounded > union_size):
				type_add_arg(type_index, ci_unique_name(c"__ci_pad_"), ci_filler_type(rounded))
		else:
			ci_struct_pad_to(type_index, &offset, max_align)
		ci_set_type_alignment(type_index, max_align)
	return type_index


int ci_import_enum(pg_ast_node* specifier):
	char* name = ci_direct_ident(specifier)
	int is_named = 1
	if (name == 0):
		name = ci_unique_name(c"__ci_anon_enum_")
		is_named = 0
	int type_index = type_lookup(name)
	if (type_index < 0):
		type_index = type_push_size(strclone(name), 4)
		type_set_kind(type_index, type_kind_enum)
		if (is_named & (sym_lookup(name) < 0)):
			sym_declare_global(name, type_index, 1)
	pg_ast_node* body = ci_child_ast(specifier, clang_ast_enum_body())
	if (body != 0):
		int value = 0
		int i = 0
		while (i < pg_ast_child_count(body)):
			pg_ast_node* enumerator = pg_ast_child(body, i)
			if (ci_is_ast(enumerator, clang_ast_enumerator_list()) | ci_is_ast(enumerator, clang_ast_enumerator_tail())):
				value = ci_import_enumerators(enumerator, type_index, value)
			i = i + 1
	return type_index


int ci_type_from_specs(pg_ast_node* specs):
	pg_ast_node* struct_spec = ci_find_ast(specs, clang_ast_struct_or_union_specifier())
	if (struct_spec != 0):
		return ci_import_struct(struct_spec)
	pg_ast_node* enum_spec = ci_find_ast(specs, clang_ast_enum_specifier())
	if (enum_spec != 0):
		return ci_import_enum(enum_spec)
	pg_ast_node* typedef_name = ci_find_token(specs, clang_token_IDENT())
	if (typedef_name != 0):
		return ci_lookup_type(typedef_name.text)
	return ci_primitive_type(specs)


/* ---------- declarator analysis ---------- */


int ci_tail_is_parameter_list(pg_ast_node* tail):
	if (ci_child_ast(tail, clang_ast_parameter_type_list()) != 0):
		return 1
	if (ci_child_ast(tail, clang_ast_identifier_list()) != 0):
		return 1
	return ci_is_token(pg_ast_child(tail, 0), clang_token_LPAREN())


int ci_tail_is_array(pg_ast_node* tail):
	return ci_is_token(pg_ast_child(tail, 0), clang_token_LBRACK())


ci_declarator_info* ci_read_declarator(int base_type, pg_ast_node* declarator):
	ci_declarator_info* info = new ci_declarator_info()
	info.name = 0
	info.type = base_type
	info.is_function = 0
	info.params = 0
	info.is_function_pointer = 0
	info.has_array = 0
	info.array_length = 1
	int pointers = 0
	pg_ast_node* current = declarator
	while (current != 0):
		pointers = pointers + ci_count_token(ci_child_ast(current, clang_ast_pointer()), clang_token_STAR())
		pg_ast_node* direct = ci_child_ast(current, clang_ast_direct_declarator())
		if (direct == 0):
			break
		pg_ast_node* nested = ci_child_ast(direct, clang_ast_declarator())
		int has_params = 0
		int i = 0
		while (i < pg_ast_child_count(direct)):
			pg_ast_node* child = pg_ast_child(direct, i)
			if (ci_is_token(child, clang_token_IDENT())):
				info.name = child.text
			else if (ci_is_ast(child, clang_ast_direct_declarator_tail())):
				if (ci_tail_is_parameter_list(child)):
					has_params = 1
					if (info.params == 0):
						info.params = ci_child_ast(child, clang_ast_parameter_type_list())
				else if (ci_tail_is_array(child)):
					info.has_array = 1
					pg_ast_node* length_expr = ci_child_ast(child, clang_ast_constant_expression())
					if (length_expr == 0):
						info.array_length = 0
					else:
						info.array_length = info.array_length * ci_eval_const(length_expr)
			i = i + 1
		if (nested != 0):
			if (has_params):
				info.is_function_pointer = 1
			current = nested
		else:
			if (has_params):
				info.is_function = 1
			current = 0
	if (info.is_function_pointer):
		info.type = ci_void_pointer_type()
		info.is_function = 0
		info.has_array = 0
		return info
	info.type = ci_apply_pointers(base_type, pointers)
	return info


int ci_abstract_declarator_type(int base_type, pg_ast_node* abstract):
	int pointers = ci_count_token(ci_child_ast(abstract, clang_ast_pointer()), clang_token_STAR())
	pg_ast_node* direct = ci_child_ast(abstract, clang_ast_direct_abstract_declarator())
	if (direct != 0):
		int i = 0
		while (i < pg_ast_child_count(direct)):
			pg_ast_node* child = pg_ast_child(direct, i)
			if (ci_is_ast(child, clang_ast_direct_abstract_declarator_tail())):
				if (ci_child_ast(child, clang_ast_parameter_type_list()) != 0):
					return ci_void_pointer_type()
				if (ci_is_token(pg_ast_child(child, 0), clang_token_LPAREN())):
					return ci_void_pointer_type()
				if (ci_is_token(pg_ast_child(child, 0), clang_token_LBRACK())):
					# arrays decay to pointers in parameter position
					pointers = pointers + 1
			i = i + 1
		if (ci_child_ast(direct, clang_ast_abstract_declarator()) != 0):
			return ci_void_pointer_type()
	return ci_apply_pointers(base_type, pointers)


int ci_parameter_type(pg_ast_node* parameter):
	pg_ast_node* specs = ci_declaration_specs(parameter)
	int type = ci_type_from_specs(specs)
	pg_ast_node* param_declarator = ci_child_ast(parameter, clang_ast_parameter_declarator())
	if (param_declarator == 0):
		return type
	pg_ast_node* declarator = ci_child_ast(param_declarator, clang_ast_declarator())
	if (declarator != 0):
		ci_declarator_info* dinfo = ci_read_declarator(type, declarator)
		int result = dinfo.type
		if (dinfo.is_function | dinfo.is_function_pointer):
			result = ci_void_pointer_type()
		else if (dinfo.has_array):
			result = type_get_next_pointer(result)
		free(dinfo)
		return result
	pg_ast_node* abstract = ci_child_ast(param_declarator, clang_ast_abstract_declarator())
	if (abstract != 0):
		return ci_abstract_declarator_type(type, abstract)
	return type


int ci_parameter_is_void_only(pg_ast_node* parameter):
	pg_ast_node* specs = ci_declaration_specs(parameter)
	if (ci_has_token(specs, clang_token_KW_VOID()) == 0):
		return 0
	return ci_child_ast(parameter, clang_ast_parameter_declarator()) == 0


int ci_lower_params_from(pg_ast_node* params, int sym, int start_count):
	int param_count = start_count
	int void_only = 0
	int i = 0
	while (i < pg_ast_child_count(params)):
		pg_ast_node* parameter = pg_ast_child(params, i)
		if (ci_is_ast(parameter, clang_ast_parameter_declaration())):
			if ((param_count == 0) & ci_parameter_is_void_only(parameter)):
				void_only = 1
			else:
				int ptype = ci_parameter_type(parameter)
				param_count = param_count + 1
				if (param_count <= extern_max_params()):
					ci_param_classes[param_count - 1] = ffi_type_class(ptype)
				if (param_count <= sym_max_param_slots()):
					save_int(table + sym + 22 + (param_count << 2), ptype)
		else if (parameter.token == 0):
			param_count = ci_lower_params_from(parameter, sym, param_count)
		i = i + 1
	if ((start_count == 0) & void_only):
		return 0
	return param_count


int ci_params_have_ellipsis(pg_ast_node* params):
	return ci_find_ast(params, clang_ast_parameter_ellipsis()) != 0


# The x86-32 target has no float64 support (see coerce()), so functions
# whose C ABI involves a double cannot be imported there.
int ci_params_have_float64(pg_ast_node* params):
	int i = 0
	while (i < pg_ast_child_count(params)):
		pg_ast_node* parameter = pg_ast_child(params, i)
		if (ci_is_ast(parameter, clang_ast_parameter_declaration())):
			if (ffi_type_class(ci_parameter_type(parameter)) == 2):
				return 1
		else if (parameter.token == 0):
			if (ci_params_have_float64(parameter)):
				return 1
		i = i + 1
	return 0


int ci_signature_needs_x64(int ret_type, pg_ast_node* params):
	if (word_size == 8):
		return 0
	if (ffi_type_class(ret_type) == 2):
		return 1
	if (params == 0):
		return 0
	return ci_params_have_float64(params)


int ci_params_are_old_style(pg_ast_node* params):
	return ci_find_ast(params, clang_ast_identifier_list()) != 0


void ci_skip_extern_function(char* name, char* reason):
	if (verbosity >= 1):
		print_error(c"warning: c_import skipped '")
		print_error(name)
		print_error(c"': ")
		print_error(reason)
		print_error(c"\x0a")


# Global constants are read with word-sized loads, so they must be emitted
# word-sized (emit_int is always 4 bytes).
void ci_emit_constant(int value):
	emit_i(value, word_size)


void ci_lower_extern_function(char* name, int ret_type, pg_ast_node* params):
	int sym = sym_declare_global(name, ret_type, 2)
	int param_count = 0
	if (params != 0):
		param_count = ci_lower_params_from(params, sym, 0)
	save_int(table + sym + 22, param_count)
	int got_vaddr = code_offset + codepos
	emit_zeros(word_size)
	dyn_add_import_weak(name, got_vaddr)
	sym_define_global(sym)
	emit_ffi_shim(param_count, ci_param_classes, ffi_type_class(ret_type), got_vaddr)


# Declared in headers but provided by the compiler, not exported by libc;
# importing them would leave unresolvable dynamic relocations.
int ci_is_compiler_builtin(char* name):
	if (strcmp(name, c"alloca") == 0):
		return 1
	if (starts_with(name, c"__builtin_")):
		return 1
	return 0


void ci_import_function(char* name, int ret_type, pg_ast_node* params):
	if (hash_map_contains(ci_imported_functions, name)):
		return
	hash_map_set(ci_imported_functions, name, 1)
	if (ci_is_compiler_builtin(name)):
		ci_skip_extern_function(name, c"compiler builtin")
		return
	if (sym_lookup(name) >= 0):
		ci_skip_extern_function(name, c"symbol already defined")
		return
	if (ci_signature_needs_x64(ret_type, params)):
		ci_skip_extern_function(name, c"float64 ABI requires the x64 target")
		return
	ci_lower_extern_function(name, ret_type, params)


int ci_import_enumerators(pg_ast_node* node, int enum_type, int value):
	if (ci_is_ast(node, clang_ast_enumerator())):
		char* name = ci_direct_ident(node)
		pg_ast_node* enum_value = ci_child_ast(node, clang_ast_enum_value())
		if (enum_value != 0):
			value = ci_constant_int(enum_value)
		hash_map_set(ci_const_values, name, value)
		if (sym_lookup(name) < 0):
			int current_symbol = sym_declare_global(name, enum_type, 1)
			sym_define_global(current_symbol)
			ci_emit_constant(value)
		return value + 1
	int i = 0
	while (i < pg_ast_child_count(node)):
		value = ci_import_enumerators(pg_ast_child(node, i), enum_type, value)
		i = i + 1
	return value


void ci_import_struct_declarator_list(int struct_type, int base_type, pg_ast_node* node, int* offset, int* max_align):
	if (node == 0):
		return
	if (ci_is_ast(node, clang_ast_struct_declarator())):
		pg_ast_node* declarator = ci_child_ast(node, clang_ast_declarator())
		if (declarator == 0):
			# unnamed bit-field: layout-only, no field emitted
			return
		int is_union = type_get_kind(struct_type) == type_kind_union
		ci_declarator_info* info = ci_read_declarator(base_type, declarator)
		if (ci_child_ast(node, clang_ast_bit_field()) != 0):
			ci_skip_extern_function(info.name, c"bit-field struct member")
			free(info)
			return
		if (info.has_array):
			int element = info.type
			int element_size = type_get_size(element)
			int total = info.array_length * element_size
			if (total > 0):
				int alignment = ci_type_alignment(element)
				if (alignment > *max_align):
					*max_align = alignment
				if (ci_struct_has_field_room(struct_type)):
					if (is_union == 0):
						ci_struct_pad_to(struct_type, offset, alignment)
					if (total == element_size):
						type_add_arg(struct_type, strclone(info.name), element)
					else if (is_union):
						type_add_arg(struct_type, strclone(info.name), ci_filler_type(total))
					else:
						type_add_arg(struct_type, strclone(info.name), element)
						type_add_arg(struct_type, ci_unique_name(c"__ci_pad_"), ci_filler_type(total - element_size))
					if (is_union == 0):
						*offset = *offset + total
		else:
			ci_struct_add_field(struct_type, strclone(info.name), info.type, offset, max_align, is_union)
		free(info)
		return
	int i = 0
	while (i < pg_ast_child_count(node)):
		ci_import_struct_declarator_list(struct_type, base_type, pg_ast_child(node, i), offset, max_align)
		i = i + 1


void ci_import_typedef(ci_decl_info* decl, ci_declarator_info* info):
	if (info.name == 0):
		return
	if (type_lookup(info.name) >= 0):
		# typedef redefinition (or clash with a W type): first wins
		return
	if (info.is_function | info.is_function_pointer):
		type_push_alias(strclone(info.name), ci_void_pointer_type())
		return
	if (info.has_array):
		int total = info.array_length * type_get_size(info.type)
		if (total <= 0):
			total = word_size
		int named = type_push_size(strclone(info.name), total)
		ci_set_type_alignment(named, ci_type_alignment(info.type))
		return
	if (strcmp(type_get_name(decl.base_type), info.name) != 0):
		type_push_alias(strclone(info.name), info.type)


void ci_import_init_declarators(ci_decl_info* decl, pg_ast_node* node):
	if (node == 0):
		return
	if (ci_is_ast(node, clang_ast_init_declarator())):
		pg_ast_node* declarator = ci_child_ast(node, clang_ast_declarator())
		ci_declarator_info* info = ci_read_declarator(decl.base_type, declarator)
		if (info.name != 0):
			if (decl.is_typedef):
				ci_import_typedef(decl, info)
			else if (info.is_function):
				if (decl.is_static | decl.is_inline):
					ci_skip_extern_function(info.name, c"static/inline function")
				else if (info.params == 0):
					ci_skip_extern_function(info.name, c"unspecified parameters")
				else if (ci_params_have_ellipsis(info.params)):
					ci_skip_extern_function(info.name, c"variadic function")
				else if (ci_params_are_old_style(info.params)):
					ci_skip_extern_function(info.name, c"old-style parameters")
				else:
					ci_import_function(info.name, info.type, info.params)
			else if (info.is_function_pointer == 0):
				if (decl.is_extern & (verbosity >= 1)):
					ci_skip_extern_function(info.name, c"extern data object")
		free(info)
		return
	int i = 0
	while (i < pg_ast_child_count(node)):
		ci_import_init_declarators(decl, pg_ast_child(node, i))
		i = i + 1


ci_decl_info* ci_read_decl_info(pg_ast_node* declaration):
	pg_ast_node* specs = ci_declaration_specs(declaration)
	ci_decl_info* decl = new ci_decl_info()
	decl.is_typedef = ci_has_token(specs, clang_token_KW_TYPEDEF())
	decl.is_extern = ci_has_token(specs, clang_token_KW_EXTERN())
	decl.is_static = ci_has_token(specs, clang_token_KW_STATIC())
	decl.is_inline = ci_has_token(specs, clang_token_KW_INLINE())
	decl.base_type = ci_type_from_specs(specs)
	return decl


void ci_import_declaration(pg_ast_node* declaration):
	ci_decl_info* decl = ci_read_decl_info(declaration)
	pg_ast_node* list = ci_child_ast(declaration, clang_ast_init_declarator_list())
	ci_import_init_declarators(decl, list)
	free(decl)


void ci_import_translation_unit(pg_ast_node* root):
	int i = 0
	while (i < pg_ast_child_count(root)):
		pg_ast_node* declaration = ci_child_ast(pg_ast_child(root, i), clang_ast_declaration())
		if (declaration != 0):
			ci_import_declaration(declaration)
		i = i + 1


/* ---------- macro constant export ---------- */


int ci_macro_public_constant_name(char* name):
	if ((name[0] < 'A') | (name[0] > 'Z')):
		return 0
	if (sym_lookup(name) >= 0):
		return 0
	if (type_lookup(name) >= 0):
		return 0
	return 1


int ci_macro_token_allowed_in_int_expr(cpp_token* token):
	if (token.kind == cpp_token_number()):
		return 1
	if (token.kind == cpp_token_char()):
		return 1
	if (token.kind != cpp_token_punct()):
		return 0
	if (strcmp(token.text, c"(") == 0):
		return 1
	if (strcmp(token.text, c")") == 0):
		return 1
	if (strcmp(token.text, c"?") == 0):
		return 1
	if (strcmp(token.text, c":") == 0):
		return 1
	if (strcmp(token.text, c"+") == 0):
		return 1
	if (strcmp(token.text, c"-") == 0):
		return 1
	if (strcmp(token.text, c"*") == 0):
		return 1
	if (strcmp(token.text, c"/") == 0):
		return 1
	if (strcmp(token.text, c"%") == 0):
		return 1
	if (strcmp(token.text, c"<<") == 0):
		return 1
	if (strcmp(token.text, c">>") == 0):
		return 1
	if (strcmp(token.text, c"<") == 0):
		return 1
	if (strcmp(token.text, c">") == 0):
		return 1
	if (strcmp(token.text, c"<=") == 0):
		return 1
	if (strcmp(token.text, c">=") == 0):
		return 1
	if (strcmp(token.text, c"==") == 0):
		return 1
	if (strcmp(token.text, c"!=") == 0):
		return 1
	if (strcmp(token.text, c"&") == 0):
		return 1
	if (strcmp(token.text, c"^") == 0):
		return 1
	if (strcmp(token.text, c"|") == 0):
		return 1
	if (strcmp(token.text, c"&&") == 0):
		return 1
	if (strcmp(token.text, c"||") == 0):
		return 1
	if (strcmp(token.text, c"!") == 0):
		return 1
	if (strcmp(token.text, c"~") == 0):
		return 1
	return 0


int ci_macro_body_is_integer_expr(hash_map* macros, cpp_macro* macro):
	if (macro == 0):
		return 0
	if (macro.is_function):
		return 0
	if (macro.builtin != cpp_macro_builtin_none()):
		return 0
	cpp_token* expanded = cpp_expand_tokens(macros, cpp_process_paste(cpp_token_clone_list(macro.body)))
	if (expanded == 0):
		return 0
	while (expanded != 0):
		if (expanded.kind == cpp_token_eof()):
			return 1
		if (ci_macro_token_allowed_in_int_expr(expanded) == 0):
			return 0
		expanded = expanded.next
	return 1


void ci_export_macro_constant(hash_map* macros, char* name, cpp_macro* macro):
	if (ci_macro_public_constant_name(name) == 0):
		return
	if (ci_macro_body_is_integer_expr(macros, macro) == 0):
		return
	int value = cpp_eval_if_expr(macros, cpp_process_paste(cpp_token_clone_list(macro.body)))
	hash_map_set(ci_const_values, name, value)
	int current_symbol = sym_declare_global(name, ci_lookup_type(c"int"), 1)
	sym_define_global(current_symbol)
	ci_emit_constant(value)


void ci_export_macro_constants(hash_map* macros):
	int cursor = hash_map_iter_begin(macros)
	while (hash_map_iter_done(macros, cursor) == 0):
		char* name = cast(char*, hash_map_iter_value(macros, cursor))
		cpp_macro* macro = cast(cpp_macro*, hash_map_get(macros, name))
		ci_export_macro_constant(macros, name, macro)
		cursor = hash_map_iter_next(macros, cursor)


void c_import_header(char* soname, char* header_path):
	ci_session_init()
	dyn_add_lib(soname)
	cpp_result* preprocessed = cpp_preprocess_file(header_path)
	char* source = preprocessed.text
	source = ci_prepare_header_source(source)
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = clang_parse(source, header_path, diagnostics)
	if ((root == 0) | (pg_diagnostics_count(diagnostics) != 0)):
		pg_diagnostics_print(diagnostics)
		error(c"c_import: header parse failed")
	ci_import_translation_unit(root)
	ci_export_macro_constants(preprocessed.macros)
