/*
Native C header preprocessor used by c_import.

This is intentionally small and deterministic: macro definitions are stored in
insertion order for any future order-sensitive lowering, while lookups remain
linear because header import is not a hot path yet.
*/
import lib.lib
import lib.path
import structures.array_list
import structures.string
import libs.extras.parser_generator.source_writer
import libs.extras.parser_generator.diagnostics
import code_generator.code_emitter


struct ci_pp_macro:
	char* name
	char* body
	array_list* params
	int function_like
	int variadic
	int disabled
	int active


struct ci_pp_cond:
	int parent_active
	int branch_taken
	int active
	int seen_else


struct ci_pp_frame:
	char* path
	char* dir
	int include_index


struct ci_pp_include_result:
	char* path
	int index


struct ci_pp:
	array_list* macros
	array_list* include_paths
	array_list* once_paths
	array_list* frames
	array_list* conds
	pg_diagnostics* diagnostics


struct ci_pp_expr:
	ci_pp* pp
	char* text
	int index
	char* filename
	int line


array_list* ci_pp_user_include_paths


char* ci_pp_expand_text(ci_pp* pp, char* text, char* filename, int line);
int ci_pp_eval_expr(ci_pp* pp, char* text, char* filename, int line);
int ci_pp_expr_conditional(ci_pp_expr* expr);
void ci_pp_process_file(ci_pp* pp, char* path, int include_index, string_builder* out);


array_list* ci_pp_user_paths():
	if (ci_pp_user_include_paths == 0):
		ci_pp_user_include_paths = array_list_new()
	return ci_pp_user_include_paths


void c_import_add_include_path(char* path):
	array_list_push(ci_pp_user_paths(), strclone(path))


int ci_pp_is_space(int c):
	return (c == ' ') | (c == 9) | (c == 13)


int ci_pp_is_line_space(int c):
	return ci_pp_is_space(c) | (c == 10)


int ci_pp_is_ident_start(int c):
	return ((c >= 'a') & (c <= 'z')) | ((c >= 'A') & (c <= 'Z')) | (c == '_')


int ci_pp_is_ident_part(int c):
	return ci_pp_is_ident_start(c) | ((c >= '0') & (c <= '9'))


int ci_pp_skip_space(char* text, int index):
	while (ci_pp_is_space(text[index])):
		index = index + 1
	return index


int ci_pp_skip_line_space(char* text, int index):
	while (ci_pp_is_line_space(text[index])):
		index = index + 1
	return index


char* ci_pp_clone_range(char* text, int start, int end):
	return path_clone_range(text + start, end - start)


char* ci_pp_trim_clone(char* text, int start, int end):
	while ((start < end) & ci_pp_is_line_space(text[start])):
		start = start + 1
	while ((end > start) & ci_pp_is_line_space(text[end - 1])):
		end = end - 1
	return ci_pp_clone_range(text, start, end)


void ci_pp_append_range(string_builder* out, char* text, int start, int end):
	while (start < end):
		string_append_char(out, text[start])
		start = start + 1


void ci_pp_append_quoted(string_builder* out, char* text):
	string_append_char(out, '"')
	int i = 0
	while (text[i]):
		if ((text[i] == '"') | (text[i] == 92)):
			string_append_char(out, 92)
		if (text[i] == 10):
			string_append(out, "\\n")
		else:
			string_append_char(out, text[i])
		i = i + 1
	string_append_char(out, '"')


void ci_pp_error(char* filename, int line, char* message):
	print_error(filename)
	print_error(":")
	print_error(itoa(line))
	print_error(": c preprocessor: ")
	error(message)


int ci_pp_list_contains(array_list* list, char* value):
	int i = 0
	while (i < list.length):
		if (strcmp(array_list_get(list, i), value) == 0):
			return 1
		i = i + 1
	return 0


void ci_pp_list_add_unique(array_list* list, char* value):
	if (ci_pp_list_contains(list, value) == 0):
		array_list_push(list, strclone(value))


void ci_pp_add_include_path(ci_pp* pp, char* path):
	ci_pp_list_add_unique(pp.include_paths, path)


ci_pp_macro* ci_pp_macro_new(char* name, char* body):
	ci_pp_macro* macro = new ci_pp_macro()
	macro.name = strclone(name)
	macro.body = strclone(body)
	macro.params = array_list_new()
	macro.function_like = 0
	macro.variadic = 0
	macro.disabled = 0
	macro.active = 1
	return macro


ci_pp_macro* ci_pp_find_macro(ci_pp* pp, char* name):
	int i = pp.macros.length - 1
	while (i >= 0):
		ci_pp_macro* macro = array_list_get(pp.macros, i)
		if (macro.active):
			if (strcmp(macro.name, name) == 0):
				return macro
		i = i - 1
	return 0


void ci_pp_define_object(ci_pp* pp, char* name, char* body):
	ci_pp_macro* old = ci_pp_find_macro(pp, name)
	if (old != 0):
		old.active = 0
	array_list_push(pp.macros, ci_pp_macro_new(name, body))


void ci_pp_define_function(ci_pp* pp, char* name, array_list* params, int variadic, char* body):
	ci_pp_macro* old = ci_pp_find_macro(pp, name)
	if (old != 0):
		old.active = 0
	ci_pp_macro* macro = ci_pp_macro_new(name, body)
	macro.function_like = 1
	macro.variadic = variadic
	macro.params = params
	array_list_push(pp.macros, macro)


void ci_pp_undef(ci_pp* pp, char* name):
	ci_pp_macro* macro = ci_pp_find_macro(pp, name)
	if (macro != 0):
		macro.active = 0


int ci_pp_macro_param_index(ci_pp_macro* macro, char* name):
	int i = 0
	while (i < macro.params.length):
		if (strcmp(array_list_get(macro.params, i), name) == 0):
			return i
		i = i + 1
	if (macro.variadic):
		if (strcmp(name, "__VA_ARGS__") == 0):
			return macro.params.length - 1
	return -1


ci_pp_frame* ci_pp_current_frame(ci_pp* pp):
	if (pp.frames.length == 0):
		return 0
	return array_list_get(pp.frames, pp.frames.length - 1)


int ci_pp_active(ci_pp* pp):
	if (pp.conds.length == 0):
		return 1
	ci_pp_cond* cond = array_list_get(pp.conds, pp.conds.length - 1)
	return cond.active


void ci_pp_push_cond(ci_pp* pp, int condition):
	ci_pp_cond* cond = new ci_pp_cond()
	cond.parent_active = ci_pp_active(pp)
	cond.active = cond.parent_active & condition
	cond.branch_taken = cond.active
	cond.seen_else = 0
	array_list_push(pp.conds, cond)


void ci_pp_elif_cond(ci_pp* pp, int condition, char* filename, int line):
	if (pp.conds.length == 0):
		ci_pp_error(filename, line, "#elif without #if")
	ci_pp_cond* cond = array_list_get(pp.conds, pp.conds.length - 1)
	if (cond.seen_else):
		ci_pp_error(filename, line, "#elif after #else")
	if ((cond.parent_active != 0) & (cond.branch_taken == 0) & condition):
		cond.active = 1
		cond.branch_taken = 1
	else:
		cond.active = 0


void ci_pp_else_cond(ci_pp* pp, char* filename, int line):
	if (pp.conds.length == 0):
		ci_pp_error(filename, line, "#else without #if")
	ci_pp_cond* cond = array_list_get(pp.conds, pp.conds.length - 1)
	if (cond.seen_else):
		ci_pp_error(filename, line, "duplicate #else")
	cond.seen_else = 1
	if ((cond.parent_active != 0) & (cond.branch_taken == 0)):
		cond.active = 1
		cond.branch_taken = 1
	else:
		cond.active = 0


void ci_pp_pop_cond(ci_pp* pp, char* filename, int line):
	if (pp.conds.length == 0):
		ci_pp_error(filename, line, "#endif without #if")
	array_list_pop(pp.conds)


char* ci_pp_splice_lines(char* source):
	string_builder* out = string_new_sized(strlen(source) + 1)
	int i = 0
	while (source[i]):
		if ((source[i] == 92) & (source[i + 1] == 13) & (source[i + 2] == 10)):
			i = i + 3
		else if ((source[i] == 92) & (source[i + 1] == 10)):
			i = i + 2
		else:
			string_append_char(out, source[i])
			i = i + 1
	char* result = out.data
	free(out)
	return result


int ci_pp_skip_quoted(char* source, int index, string_builder* out):
	int quote = source[index]
	string_append_char(out, quote)
	index = index + 1
	while ((source[index] != 0) & (source[index] != quote)):
		string_append_char(out, source[index])
		if (source[index] == 92):
			index = index + 1
			if (source[index] != 0):
				string_append_char(out, source[index])
		index = index + 1
	if (source[index] == quote):
		string_append_char(out, quote)
		index = index + 1
	return index


char* ci_pp_strip_comments(char* source):
	string_builder* out = string_new_sized(strlen(source) + 1)
	int i = 0
	while (source[i]):
		if ((source[i] == '"') | (source[i] == 39)):
			i = ci_pp_skip_quoted(source, i, out)
		else if ((source[i] == '/') & (source[i + 1] == '/')):
			while ((source[i] != 0) & (source[i] != 10)):
				i = i + 1
		else if ((source[i] == '/') & (source[i + 1] == '*')):
			string_append_char(out, ' ')
			i = i + 2
			while (source[i] != 0):
				if ((source[i] == '*') & (source[i + 1] == '/')):
					i = i + 2
					break
				if (source[i] == 10):
					string_append_char(out, 10)
				i = i + 1
		else:
			string_append_char(out, source[i])
			i = i + 1
	char* result = out.data
	free(out)
	return result


int ci_pp_parse_macro_args(char* text, int index, array_list* args):
	int depth = 0
	int start = index + 1
	index = index + 1
	while (text[index]):
		if ((text[index] == '"') | (text[index] == 39)):
			int quote = text[index]
			index = index + 1
			while ((text[index] != 0) & (text[index] != quote)):
				if (text[index] == 92):
					index = index + 1
				if (text[index] != 0):
					index = index + 1
			if (text[index] == quote):
				index = index + 1
		else if (text[index] == '('):
			depth = depth + 1
			index = index + 1
		else if (text[index] == ')'):
			if (depth == 0):
				if (index > start):
					array_list_push(args, ci_pp_trim_clone(text, start, index))
				else if (args.length != 0):
					array_list_push(args, strclone(""))
				return index + 1
			depth = depth - 1
			index = index + 1
		else if ((text[index] == ',') & (depth == 0)):
			array_list_push(args, ci_pp_trim_clone(text, start, index))
			index = index + 1
			start = index
		else:
			index = index + 1
	return index


char* ci_pp_get_arg(array_list* args, int index):
	if ((index < 0) | (index >= args.length)):
		return ""
	return array_list_get(args, index)


char* ci_pp_join_variadic(array_list* args, int start):
	string_builder* out = string_new()
	int i = start
	while (i < args.length):
		if (i > start):
			string_append(out, ", ")
		string_append(out, array_list_get(args, i))
		i = i + 1
	char* result = out.data
	free(out)
	return result


char* ci_pp_substitute_macro(ci_pp* pp, ci_pp_macro* macro, array_list* raw_args, char* filename, int line):
	array_list* expanded_args = array_list_new()
	int i = 0
	while (i < raw_args.length):
		array_list_push(expanded_args, ci_pp_expand_text(pp, array_list_get(raw_args, i), filename, line))
		i = i + 1

	if (macro.variadic & (raw_args.length >= macro.params.length)):
		char* joined_raw = ci_pp_join_variadic(raw_args, macro.params.length - 1)
		char* joined_expanded = ci_pp_expand_text(pp, joined_raw, filename, line)
		array_list_set(raw_args, macro.params.length - 1, joined_raw)
		array_list_set(expanded_args, macro.params.length - 1, joined_expanded)

	string_builder* out = string_new_sized(strlen(macro.body) + 1)
	i = 0
	while (macro.body[i]):
		if ((macro.body[i] == '#') & (macro.body[i + 1] == '#')):
			i = i + 2
			while (ci_pp_is_line_space(macro.body[i])):
				i = i + 1
		else if (macro.body[i] == '#'):
			int j = ci_pp_skip_line_space(macro.body, i + 1)
			if (ci_pp_is_ident_start(macro.body[j])):
				int start = j
				while (ci_pp_is_ident_part(macro.body[j])):
					j = j + 1
				char* name = ci_pp_clone_range(macro.body, start, j)
				int param = ci_pp_macro_param_index(macro, name)
				if (param >= 0):
					ci_pp_append_quoted(out, ci_pp_get_arg(raw_args, param))
					i = j
				else:
					string_append_char(out, '#')
					i = i + 1
				free(name)
			else:
				string_append_char(out, '#')
				i = i + 1
		else if (ci_pp_is_ident_start(macro.body[i])):
			int start2 = i
			while (ci_pp_is_ident_part(macro.body[i])):
				i = i + 1
			char* name2 = ci_pp_clone_range(macro.body, start2, i)
			int param2 = ci_pp_macro_param_index(macro, name2)
			if (param2 >= 0):
				string_append(out, ci_pp_get_arg(expanded_args, param2))
			else:
				string_append(out, name2)
			free(name2)
		else:
			string_append_char(out, macro.body[i])
			i = i + 1
	char* substituted = out.data
	free(out)
	return ci_pp_expand_text(pp, substituted, filename, line)


int ci_pp_copy_quoted_text(char* text, int index, string_builder* out):
	int quote = text[index]
	string_append_char(out, quote)
	index = index + 1
	while ((text[index] != 0) & (text[index] != quote)):
		string_append_char(out, text[index])
		if (text[index] == 92):
			index = index + 1
			if (text[index] != 0):
				string_append_char(out, text[index])
		index = index + 1
	if (text[index] == quote):
		string_append_char(out, quote)
		index = index + 1
	return index


char* ci_pp_expand_text(ci_pp* pp, char* text, char* filename, int line):
	string_builder* out = string_new_sized(strlen(text) + 16)
	int i = 0
	while (text[i]):
		if ((text[i] == '"') | (text[i] == 39)):
			i = ci_pp_copy_quoted_text(text, i, out)
		else if (ci_pp_is_ident_start(text[i])):
			int start = i
			while (ci_pp_is_ident_part(text[i])):
				i = i + 1
			char* name = ci_pp_clone_range(text, start, i)
			if (strcmp(name, "__LINE__") == 0):
				string_append_int(out, line)
			else if (strcmp(name, "__FILE__") == 0):
				ci_pp_append_quoted(out, filename)
			else:
				ci_pp_macro* macro = ci_pp_find_macro(pp, name)
				if (macro != 0):
					if (macro.disabled == 0):
						if (macro.function_like):
							int j = ci_pp_skip_space(text, i)
							if (text[j] == '('):
								array_list* args = array_list_new()
								int end = ci_pp_parse_macro_args(text, j, args)
								macro.disabled = 1
								char* expanded = ci_pp_substitute_macro(pp, macro, args, filename, line)
								macro.disabled = 0
								string_append(out, expanded)
								i = end
							else:
								string_append(out, name)
						else:
							macro.disabled = 1
							char* expanded2 = ci_pp_expand_text(pp, macro.body, filename, line)
							macro.disabled = 0
							string_append(out, expanded2)
						free(name)
					else:
						string_append(out, name)
						free(name)
				else:
					string_append(out, name)
					free(name)
		else:
			string_append_char(out, text[i])
			i = i + 1
	char* result = out.data
	free(out)
	return result


void ci_pp_expr_skip(ci_pp_expr* expr):
	expr.index = ci_pp_skip_line_space(expr.text, expr.index)


int ci_pp_expr_match(ci_pp_expr* expr, char* op):
	ci_pp_expr_skip(expr)
	if (starts_with(expr.text + expr.index, op)):
		expr.index = expr.index + strlen(op)
		return 1
	return 0


int ci_pp_hex_digit(int c):
	if ((c >= '0') & (c <= '9')):
		return c - '0'
	if ((c >= 'a') & (c <= 'f')):
		return c - 'a' + 10
	if ((c >= 'A') & (c <= 'F')):
		return c - 'A' + 10
	return -1


int ci_pp_expr_number(ci_pp_expr* expr):
	ci_pp_expr_skip(expr)
	int value = 0
	if ((expr.text[expr.index] == '0') & ((expr.text[expr.index + 1] == 'x') | (expr.text[expr.index + 1] == 'X'))):
		expr.index = expr.index + 2
		while (ci_pp_hex_digit(expr.text[expr.index]) >= 0):
			value = value * 16 + ci_pp_hex_digit(expr.text[expr.index])
			expr.index = expr.index + 1
	else:
		while ((expr.text[expr.index] >= '0') & (expr.text[expr.index] <= '9')):
			value = value * 10 + expr.text[expr.index] - '0'
			expr.index = expr.index + 1
	while (ci_pp_is_ident_part(expr.text[expr.index])):
		expr.index = expr.index + 1
	return value


int ci_pp_expr_primary(ci_pp_expr* expr):
	ci_pp_expr_skip(expr)
	if (ci_pp_expr_match(expr, "(")):
		int value = ci_pp_expr_conditional(expr)
		ci_pp_expr_match(expr, ")")
		return value
	if ((expr.text[expr.index] >= '0') & (expr.text[expr.index] <= '9')):
		return ci_pp_expr_number(expr)
	if (expr.text[expr.index] == 39):
		expr.index = expr.index + 1
		int char_value = expr.text[expr.index]
		if (expr.text[expr.index] == 92):
			expr.index = expr.index + 1
			char_value = expr.text[expr.index]
		while ((expr.text[expr.index] != 0) & (expr.text[expr.index] != 39)):
			expr.index = expr.index + 1
		if (expr.text[expr.index] == 39):
			expr.index = expr.index + 1
		return char_value
	if (ci_pp_is_ident_start(expr.text[expr.index])):
		int start = expr.index
		while (ci_pp_is_ident_part(expr.text[expr.index])):
			expr.index = expr.index + 1
		char* name = ci_pp_clone_range(expr.text, start, expr.index)
		if (strcmp(name, "defined") == 0):
			ci_pp_expr_skip(expr)
			int paren = ci_pp_expr_match(expr, "(")
			ci_pp_expr_skip(expr)
			start = expr.index
			while (ci_pp_is_ident_part(expr.text[expr.index])):
				expr.index = expr.index + 1
			char* def_name = ci_pp_clone_range(expr.text, start, expr.index)
			int result = ci_pp_find_macro(expr.pp, def_name) != 0
			if (paren):
				ci_pp_expr_match(expr, ")")
			free(def_name)
			free(name)
			return result
		if (strcmp(name, "__has_attribute") == 0):
			if (ci_pp_expr_match(expr, "(")):
				while ((expr.text[expr.index] != 0) & (expr.text[expr.index] != ')')):
					expr.index = expr.index + 1
				ci_pp_expr_match(expr, ")")
			free(name)
			return 0
		if (strcmp(name, "__has_include") == 0):
			if (ci_pp_expr_match(expr, "(")):
				while ((expr.text[expr.index] != 0) & (expr.text[expr.index] != ')')):
					expr.index = expr.index + 1
				ci_pp_expr_match(expr, ")")
			free(name)
			return 0
		ci_pp_macro* macro = ci_pp_find_macro(expr.pp, name)
		if (macro != 0):
			if ((macro.function_like == 0) & (macro.disabled == 0)):
				macro.disabled = 1
				int macro_value = ci_pp_eval_expr(expr.pp, macro.body, expr.filename, expr.line)
				macro.disabled = 0
				free(name)
				return macro_value
		free(name)
		return 0
	return 0


int ci_pp_expr_unary(ci_pp_expr* expr):
	if (ci_pp_expr_match(expr, "!")):
		return ci_pp_expr_unary(expr) == 0
	if (ci_pp_expr_match(expr, "~")):
		return 0 - ci_pp_expr_unary(expr) - 1
	if (ci_pp_expr_match(expr, "-")):
		return 0 - ci_pp_expr_unary(expr)
	if (ci_pp_expr_match(expr, "+")):
		return ci_pp_expr_unary(expr)
	return ci_pp_expr_primary(expr)


int ci_pp_expr_mul(ci_pp_expr* expr):
	int value = ci_pp_expr_unary(expr)
	while (1):
		if (ci_pp_expr_match(expr, "*")):
			value = value * ci_pp_expr_unary(expr)
		else if (ci_pp_expr_match(expr, "/")):
			int rhs = ci_pp_expr_unary(expr)
			if (rhs != 0):
				value = value / rhs
		else if (ci_pp_expr_match(expr, "%")):
			int rhs2 = ci_pp_expr_unary(expr)
			if (rhs2 != 0):
				value = value % rhs2
		else:
			return value


int ci_pp_expr_add(ci_pp_expr* expr):
	int value = ci_pp_expr_mul(expr)
	while (1):
		if (ci_pp_expr_match(expr, "+")):
			value = value + ci_pp_expr_mul(expr)
		else if (ci_pp_expr_match(expr, "-")):
			value = value - ci_pp_expr_mul(expr)
		else:
			return value


int ci_pp_expr_shift(ci_pp_expr* expr):
	int value = ci_pp_expr_add(expr)
	while (1):
		if (ci_pp_expr_match(expr, "<<")):
			value = value << ci_pp_expr_add(expr)
		else if (ci_pp_expr_match(expr, ">>")):
			value = value >> ci_pp_expr_add(expr)
		else:
			return value


int ci_pp_expr_rel(ci_pp_expr* expr):
	int value = ci_pp_expr_shift(expr)
	while (1):
		if (ci_pp_expr_match(expr, "<=")):
			value = value <= ci_pp_expr_shift(expr)
		else if (ci_pp_expr_match(expr, ">=")):
			value = value >= ci_pp_expr_shift(expr)
		else if (ci_pp_expr_match(expr, "<")):
			value = value < ci_pp_expr_shift(expr)
		else if (ci_pp_expr_match(expr, ">")):
			value = value > ci_pp_expr_shift(expr)
		else:
			return value


int ci_pp_expr_eq(ci_pp_expr* expr):
	int value = ci_pp_expr_rel(expr)
	while (1):
		if (ci_pp_expr_match(expr, "==")):
			value = value == ci_pp_expr_rel(expr)
		else if (ci_pp_expr_match(expr, "!=")):
			value = value != ci_pp_expr_rel(expr)
		else:
			return value


int ci_pp_expr_bit_and(ci_pp_expr* expr):
	int value = ci_pp_expr_eq(expr)
	ci_pp_expr_skip(expr)
	while ((expr.text[expr.index] == '&') & (expr.text[expr.index + 1] != '&')):
		expr.index = expr.index + 1
		value = value & ci_pp_expr_eq(expr)
		ci_pp_expr_skip(expr)
	return value


int ci_pp_bit_xor(int left, int right):
	return left + right - ((left & right) * 2)


int ci_pp_expr_bit_xor(ci_pp_expr* expr):
	int value = ci_pp_expr_bit_and(expr)
	while (ci_pp_expr_match(expr, "^")):
		value = ci_pp_bit_xor(value, ci_pp_expr_bit_and(expr))
	return value


int ci_pp_expr_bit_or(ci_pp_expr* expr):
	int value = ci_pp_expr_bit_xor(expr)
	ci_pp_expr_skip(expr)
	while ((expr.text[expr.index] == '|') & (expr.text[expr.index + 1] != '|')):
		expr.index = expr.index + 1
		value = value | ci_pp_expr_bit_xor(expr)
		ci_pp_expr_skip(expr)
	return value


int ci_pp_expr_log_and(ci_pp_expr* expr):
	int value = ci_pp_expr_bit_or(expr)
	while (ci_pp_expr_match(expr, "&&")):
		value = (value != 0) & (ci_pp_expr_bit_or(expr) != 0)
	return value


int ci_pp_expr_log_or(ci_pp_expr* expr):
	int value = ci_pp_expr_log_and(expr)
	while (ci_pp_expr_match(expr, "||")):
		value = (value != 0) | (ci_pp_expr_log_and(expr) != 0)
	return value


int ci_pp_expr_conditional(ci_pp_expr* expr):
	int value = ci_pp_expr_log_or(expr)
	if (ci_pp_expr_match(expr, "?")):
		int true_value = ci_pp_expr_conditional(expr)
		ci_pp_expr_match(expr, ":")
		int false_value = ci_pp_expr_conditional(expr)
		if (value):
			return true_value
		return false_value
	return value


int ci_pp_eval_expr(ci_pp* pp, char* text, char* filename, int line):
	ci_pp_expr* expr = new ci_pp_expr()
	expr.pp = pp
	expr.text = text
	expr.index = 0
	expr.filename = filename
	expr.line = line
	return ci_pp_expr_conditional(expr)


ci_pp_include_result* ci_pp_include_result_new(char* path, int index):
	ci_pp_include_result* result = new ci_pp_include_result()
	result.path = path
	result.index = index
	return result


ci_pp_include_result* ci_pp_find_include(ci_pp* pp, char* include_name, char* current_dir, int quoted, int start_index):
	if (include_name[0] == '/'):
		if (path_exists(include_name)):
			return ci_pp_include_result_new(strclone(include_name), -1)
	if (quoted & (start_index <= -1)):
		char* candidate = path_join(current_dir, include_name)
		if (path_exists(candidate)):
			return ci_pp_include_result_new(candidate, -1)
		free(candidate)
	int i = start_index
	if (i < 0):
		i = 0
	while (i < pp.include_paths.length):
		char* base = array_list_get(pp.include_paths, i)
		char* candidate2 = path_join(base, include_name)
		if (path_exists(candidate2)):
			return ci_pp_include_result_new(candidate2, i)
		free(candidate2)
		i = i + 1
	return 0


char* ci_pp_parse_include_name(char* text, int index, int* quoted):
	index = ci_pp_skip_line_space(text, index)
	if (text[index] == '"'):
		*quoted = 1
		int start = index + 1
		index = start
		while ((text[index] != 0) & (text[index] != '"')):
			index = index + 1
		return ci_pp_clone_range(text, start, index)
	if (text[index] == '<'):
		*quoted = 0
		int start2 = index + 1
		index = start2
		while ((text[index] != 0) & (text[index] != '>')):
			index = index + 1
		return ci_pp_clone_range(text, start2, index)
	return 0


void ci_pp_handle_include(ci_pp* pp, char* rest, char* filename, int line, int include_next, string_builder* out):
	char* expanded = ci_pp_expand_text(pp, rest, filename, line)
	int quoted = 0
	char* include_name = ci_pp_parse_include_name(expanded, 0, &quoted)
	if (include_name == 0):
		ci_pp_error(filename, line, "malformed #include")
	ci_pp_frame* frame = ci_pp_current_frame(pp)
	int start_index = -1
	if (include_next):
		start_index = frame.include_index + 1
		quoted = 0
	ci_pp_include_result* result = ci_pp_find_include(pp, include_name, frame.dir, quoted, start_index)
	if (result == 0):
		ci_pp_error(filename, line, "could not resolve #include")
	ci_pp_process_file(pp, result.path, result.index, out)


void ci_pp_define_from_line(ci_pp* pp, char* line, int index):
	index = ci_pp_skip_space(line, index)
	int start = index
	while (ci_pp_is_ident_part(line[index])):
		index = index + 1
	char* name = ci_pp_clone_range(line, start, index)
	if (line[index] == '('):
		array_list* params = array_list_new()
		int variadic = 0
		index = index + 1
		while ((line[index] != 0) & (line[index] != ')')):
			index = ci_pp_skip_line_space(line, index)
			if ((line[index] == '.') & (line[index + 1] == '.') & (line[index + 2] == '.')):
				array_list_push(params, strclone("__VA_ARGS__"))
				variadic = 1
				index = index + 3
			else:
				start = index
				while (ci_pp_is_ident_part(line[index])):
					index = index + 1
				if (index > start):
					array_list_push(params, ci_pp_clone_range(line, start, index))
			index = ci_pp_skip_line_space(line, index)
			if (line[index] == ','):
				index = index + 1
		if (line[index] == ')'):
			index = index + 1
		char* body = ci_pp_trim_clone(line, index, strlen(line))
		ci_pp_define_function(pp, name, params, variadic, body)
		free(body)
	else:
		char* body2 = ci_pp_trim_clone(line, index, strlen(line))
		ci_pp_define_object(pp, name, body2)
		free(body2)
	free(name)


void ci_pp_handle_directive(ci_pp* pp, char* line, char* filename, int line_no, string_builder* out):
	int i = ci_pp_skip_space(line, 0)
	if (line[i] != '#'):
		if (ci_pp_active(pp)):
			char* expanded = ci_pp_expand_text(pp, line, filename, line_no)
			string_append(out, expanded)
		string_append_char(out, 10)
		return
	i = ci_pp_skip_space(line, i + 1)
	int start = i
	while (ci_pp_is_ident_part(line[i])):
		i = i + 1
	char* directive = ci_pp_clone_range(line, start, i)
	i = ci_pp_skip_space(line, i)
	if (strcmp(directive, "ifdef") == 0):
		char* name = ci_pp_trim_clone(line, i, strlen(line))
		ci_pp_push_cond(pp, ci_pp_find_macro(pp, name) != 0)
		free(name)
	else if (strcmp(directive, "ifndef") == 0):
		char* name2 = ci_pp_trim_clone(line, i, strlen(line))
		ci_pp_push_cond(pp, ci_pp_find_macro(pp, name2) == 0)
		free(name2)
	else if (strcmp(directive, "if") == 0):
		ci_pp_push_cond(pp, ci_pp_eval_expr(pp, line + i, filename, line_no) != 0)
	else if (strcmp(directive, "elif") == 0):
		ci_pp_elif_cond(pp, ci_pp_eval_expr(pp, line + i, filename, line_no) != 0, filename, line_no)
	else if (strcmp(directive, "else") == 0):
		ci_pp_else_cond(pp, filename, line_no)
	else if (strcmp(directive, "endif") == 0):
		ci_pp_pop_cond(pp, filename, line_no)
	else if (ci_pp_active(pp)):
		if (strcmp(directive, "define") == 0):
			ci_pp_define_from_line(pp, line, i)
		else if (strcmp(directive, "undef") == 0):
			char* undef_name = ci_pp_trim_clone(line, i, strlen(line))
			ci_pp_undef(pp, undef_name)
			free(undef_name)
		else if (strcmp(directive, "include") == 0):
			ci_pp_handle_include(pp, line + i, filename, line_no, 0, out)
		else if (strcmp(directive, "include_next") == 0):
			ci_pp_handle_include(pp, line + i, filename, line_no, 1, out)
		else if (strcmp(directive, "pragma") == 0):
			char* pragma = ci_pp_trim_clone(line, i, strlen(line))
			if (strcmp(pragma, "once") == 0):
				ci_pp_list_add_unique(pp.once_paths, filename)
			free(pragma)
		else if (strcmp(directive, "error") == 0):
			ci_pp_error(filename, line_no, "#error")
		else if ((strcmp(directive, "line") != 0) & (strlen(directive) > 0)):
			i = i
	string_append_char(out, 10)
	free(directive)


void ci_pp_process_source(ci_pp* pp, char* source, char* filename, string_builder* out):
	char* spliced = ci_pp_splice_lines(source)
	char* clean = ci_pp_strip_comments(spliced)
	int start = 0
	int line = 1
	int i = 0
	while (clean[i]):
		if (clean[i] == 10):
			char* one_line = ci_pp_clone_range(clean, start, i)
			ci_pp_handle_directive(pp, one_line, filename, line, out)
			free(one_line)
			i = i + 1
			start = i
			line = line + 1
		else:
			i = i + 1
	if (i > start):
		char* last_line = ci_pp_clone_range(clean, start, i)
		ci_pp_handle_directive(pp, last_line, filename, line, out)
		free(last_line)


void ci_pp_process_file(ci_pp* pp, char* path, int include_index, string_builder* out):
	if (ci_pp_list_contains(pp.once_paths, path)):
		return
	char* source = pg_read_file_text(path)
	if (source == 0):
		ci_pp_error(path, 1, "could not read header")
	int cond_depth = pp.conds.length
	ci_pp_frame* frame = new ci_pp_frame()
	frame.path = strclone(path)
	frame.dir = path_dirname(path)
	frame.include_index = include_index
	array_list_push(pp.frames, frame)
	ci_pp_process_source(pp, source, path, out)
	array_list_pop(pp.frames)
	if (pp.conds.length != cond_depth):
		ci_pp_error(path, 1, "unterminated #if")


void ci_pp_define_predefined(ci_pp* pp):
	ci_pp_define_object(pp, "__STDC__", "1")
	ci_pp_define_object(pp, "__STDC_VERSION__", "201112L")
	ci_pp_define_object(pp, "__linux__", "1")
	ci_pp_define_object(pp, "__unix__", "1")
	if (word_size == 8):
		ci_pp_define_object(pp, "__x86_64__", "1")
		ci_pp_define_object(pp, "__LP64__", "1")
	else:
		ci_pp_define_object(pp, "__i386__", "1")


void ci_pp_add_default_include_paths(ci_pp* pp):
	int i = 0
	array_list* user_paths = ci_pp_user_paths()
	while (i < user_paths.length):
		ci_pp_add_include_path(pp, array_list_get(user_paths, i))
		i = i + 1
	if (path_exists("/usr/local/include")):
		ci_pp_add_include_path(pp, "/usr/local/include")
	if (path_exists("/usr/include/x86_64-linux-gnu")):
		ci_pp_add_include_path(pp, "/usr/include/x86_64-linux-gnu")
	if (path_exists("/usr/include")):
		ci_pp_add_include_path(pp, "/usr/include")


ci_pp* ci_pp_new():
	ci_pp* pp = new ci_pp()
	pp.macros = array_list_new()
	pp.include_paths = array_list_new()
	pp.once_paths = array_list_new()
	pp.frames = array_list_new()
	pp.conds = array_list_new()
	pp.diagnostics = pg_diagnostics_new()
	ci_pp_define_predefined(pp)
	ci_pp_add_default_include_paths(pp)
	return pp


char* ci_preprocess_text(char* source, char* filename):
	ci_pp* pp = ci_pp_new()
	string_builder* out = string_new_sized(strlen(source) + 1)
	ci_pp_frame* frame = new ci_pp_frame()
	frame.path = strclone(filename)
	frame.dir = path_dirname(filename)
	frame.include_index = -1
	array_list_push(pp.frames, frame)
	ci_pp_process_source(pp, source, filename, out)
	char* result = out.data
	free(out)
	return result


char* ci_preprocess_header(char* header_path):
	ci_pp* pp = ci_pp_new()
	string_builder* out = string_new()
	ci_pp_process_file(pp, header_path, -1, out)
	char* result = out.data
	free(out)
	return result
