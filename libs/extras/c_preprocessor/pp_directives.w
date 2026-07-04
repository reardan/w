/*
Directive driver for C preprocessing.
*/
import lib.lib
import lib.path
import structures.array_list
import structures.hash_map
import structures.string
import libs.extras.parser_generator.source_writer
import libs.extras.c_preprocessor.pp_token
import libs.extras.c_preprocessor.pp_lexer
import libs.extras.c_preprocessor.pp_macro
import libs.extras.c_preprocessor.pp_expr
import libs.extras.c_preprocessor.pp_init


struct cpp_cond:
	int parent_active
	int current_active
	int saw_true
	int saw_else


struct cpp_preprocessor:
	hash_map* macros
	hash_map* once_files
	array_list* include_paths
	array_list* conds
	string_builder* output
	int active
	char* current_file
	int current_include_index


struct cpp_result:
	char* text
	hash_map* macros


cpp_token* cpp_clone_range(cpp_token* start, cpp_token* end):
	cpp_token head
	head.next = 0
	cpp_token* tail = &head
	while ((start != 0) & (start != end)):
		if (start.kind == cpp_token_eof()):
			break
		tail.next = cpp_token_clone_one(start)
		tail = tail.next
		start = start.next
	tail.next = 0
	return head.next


cpp_token* cpp_body_range(cpp_token* start, cpp_token* end):
	cpp_token* body = cpp_clone_range(start, end)
	cpp_token* eof = cpp_token_new(cpp_token_eof(), "", "<macro>", 0, 0, 0)
	if (body == 0):
		return eof
	cpp_token* last = cpp_token_last(body)
	last.next = eof
	return body


cpp_token* cpp_next_line(cpp_token* token):
	token = token.next
	while (token != 0):
		if (token.kind == cpp_token_eof()):
			return token
		if (token.at_bol):
			return token
		token = token.next
	return token


cpp_preprocessor* cpp_preprocessor_new():
	cpp_preprocessor* pp = new cpp_preprocessor()
	pp.macros = hash_map_new()
	pp.once_files = hash_map_new()
	pp.include_paths = array_list_new()
	pp.conds = array_list_new()
	pp.output = string_new()
	pp.active = 1
	pp.current_file = "<input>"
	pp.current_include_index = -1
	array_list_push(pp.include_paths, "libs/extras/c_preprocessor/include")
	array_list_push(pp.include_paths, "/usr/lib/gcc/x86_64-linux-gnu/14/include")
	array_list_push(pp.include_paths, "/usr/lib/gcc/x86_64-linux-gnu/13/include")
	array_list_push(pp.include_paths, "/usr/include/x86_64-linux-gnu")
	array_list_push(pp.include_paths, "/usr/include")
	cpp_init_predefined_macros(pp.macros)
	return pp


char* cpp_unquote_header(char* text):
	int length = strlen(text)
	if (length < 2):
		return strclone(text)
	return cpp_substr(text, 1, length - 1)


char* cpp_angle_header(cpp_token* token, cpp_token* end):
	string_builder* out = string_new()
	if (cpp_token_is_punct(token, "<")):
		token = token.next
	while ((token != 0) & (token != end)):
		if (cpp_token_is_punct(token, ">")):
			char* result = strclone(out.data)
			string_free(out)
			return result
		string_append(out, token.text)
		token = token.next
	char* result = strclone(out.data)
	string_free(out)
	return result


int cpp_cond_parent_active(cpp_preprocessor* pp):
	if (pp.conds.length == 0):
		return 1
	cpp_cond* cond = cast(cpp_cond*, array_list_get(pp.conds, pp.conds.length - 1))
	return cond.parent_active


cpp_cond* cpp_cond_top(cpp_preprocessor* pp):
	if (pp.conds.length == 0):
		return 0
	return cast(cpp_cond*, array_list_get(pp.conds, pp.conds.length - 1))


void cpp_cond_push(cpp_preprocessor* pp, int value):
	cpp_cond* cond = new cpp_cond()
	cond.parent_active = pp.active
	cond.current_active = cond.parent_active & (value != 0)
	cond.saw_true = value != 0
	cond.saw_else = 0
	array_list_push(pp.conds, cast(int, cond))
	pp.active = cond.current_active


void cpp_cond_elif(cpp_preprocessor* pp, int value):
	cpp_cond* cond = cpp_cond_top(pp)
	if (cond == 0):
		return
	if (cond.saw_else):
		pp.active = 0
		return
	if ((cond.parent_active != 0) & (cond.saw_true == 0) & (value != 0)):
		cond.current_active = 1
		cond.saw_true = 1
	else:
		cond.current_active = 0
	pp.active = cond.current_active


void cpp_cond_else(cpp_preprocessor* pp):
	cpp_cond* cond = cpp_cond_top(pp)
	if (cond == 0):
		return
	cond.saw_else = 1
	cond.current_active = cond.parent_active & (cond.saw_true == 0)
	cond.saw_true = 1
	pp.active = cond.current_active


void cpp_cond_pop(cpp_preprocessor* pp):
	if (pp.conds.length == 0):
		return
	cpp_cond* cond = cast(cpp_cond*, array_list_pop(pp.conds))
	pp.active = cond.parent_active


int cpp_tokens_can_paste(cpp_token* left, cpp_token* right):
	if (left == 0):
		return 0
	if (((left.kind == cpp_token_ident()) | (left.kind == cpp_token_number())) &
			((right.kind == cpp_token_ident()) | (right.kind == cpp_token_number()))):
		return 1
	if ((left.kind == cpp_token_punct()) & (right.kind == cpp_token_punct())):
		string_builder* joined = string_new()
		string_append(joined, left.text)
		string_append(joined, right.text)
		cpp_token* one = cpp_lex_one_token(joined.data)
		int result = one != 0
		string_free(joined)
		return result
	return 0


void cpp_render_tokens(cpp_preprocessor* pp, cpp_token* token):
	cpp_token* prev = 0
	while (token != 0):
		if (token.kind == cpp_token_eof()):
			break
		if (prev != 0):
			if (token.has_space | cpp_tokens_can_paste(prev, token)):
				string_append_char(pp.output, ' ')
		string_append(pp.output, token.text)
		prev = token
		token = token.next
	string_append_char(pp.output, 10)


cpp_macro* cpp_parse_define_macro(cpp_token* name, cpp_token* end):
	cpp_macro* macro = cpp_macro_new(name.text)
	cpp_token* body = name.next
	if (cpp_token_is_punct(name.next, "(") & (name.next.has_space == 0)):
		macro.is_function = 1
		cpp_token* token = name.next.next
		while ((token != 0) & (token != end)):
			if (cpp_token_is_punct(token, ")")):
				body = token.next
				break
			if (cpp_token_is_punct(token, "...")):
				array_list_push(macro.params, cast(int, "__VA_ARGS__"))
				macro.is_variadic = 1
				token = token.next
			else if (token.kind == cpp_token_ident()):
				array_list_push(macro.params, cast(int, token.text))
				token = token.next
				if (cpp_token_is_punct(token, "...")):
					macro.is_variadic = 1
					token = token.next
			else:
				token = token.next
			if (cpp_token_is_punct(token, ",")):
				token = token.next
	macro.body = cpp_body_range(body, end)
	return macro


void cpp_process_define(cpp_preprocessor* pp, cpp_token* directive, cpp_token* end):
	cpp_token* name = directive.next
	if (name == 0):
		return
	if (name.kind != cpp_token_ident()):
		return
	cpp_macro_define(pp.macros, cpp_parse_define_macro(name, end))


char* cpp_find_include_in_paths(cpp_preprocessor* pp, char* name, int start_index, int* found_index):
	int i = start_index
	while (i < pp.include_paths.length):
		char* dir = cast(char*, array_list_get(pp.include_paths, i))
		char* path = path_join(dir, name)
		if (path_exists(path)):
			*found_index = i
			return path
		free(path)
		i = i + 1
	return 0


char* cpp_find_include(cpp_preprocessor* pp, char* name, int quoted, int include_next, int* found_index):
	*found_index = -1
	if (include_next == 0):
		if (quoted):
			char* dir = path_dirname(pp.current_file)
			char* local = path_join(dir, name)
			free(dir)
			if (path_exists(local)):
				return local
			free(local)
		return cpp_find_include_in_paths(pp, name, 0, found_index)
	return cpp_find_include_in_paths(pp, name, pp.current_include_index + 1, found_index)


void cpp_preprocess_file_into(cpp_preprocessor* pp, char* path, int include_index);


void cpp_process_include(cpp_preprocessor* pp, cpp_token* directive, cpp_token* end, int include_next):
	cpp_token* token = directive.next
	if (token == 0):
		return
	int quoted = 0
	char* name = 0
	if (token.kind == cpp_token_string()):
		quoted = 1
		name = cpp_unquote_header(token.text)
	else:
		name = cpp_angle_header(token, end)
	int found_index = -1
	char* path = cpp_find_include(pp, name, quoted, include_next, &found_index)
	if (path == 0):
		print_error("c preprocessor: include not found: ")
		print_error(name)
		error("")
	cpp_preprocess_file_into(pp, path, found_index)


void cpp_process_pragma(cpp_preprocessor* pp, cpp_token* directive):
	if (cpp_token_is_ident(directive.next, "once")):
		hash_map_set(pp.once_files, pp.current_file, 1)


int cpp_eval_directive_expr(cpp_preprocessor* pp, cpp_token* directive, cpp_token* end):
	cpp_token* expr = cpp_body_range(directive.next, end)
	return cpp_eval_if_expr(pp.macros, expr)


void cpp_process_directive(cpp_preprocessor* pp, cpp_token* hash, cpp_token* end):
	cpp_token* directive = hash.next
	if (directive == 0):
		return
	if (directive.kind == cpp_token_eof()):
		return
	if (cpp_token_is_ident(directive, "if")):
		if (pp.active):
			cpp_cond_push(pp, cpp_eval_directive_expr(pp, directive, end))
		else:
			cpp_cond_push(pp, 0)
	else if (cpp_token_is_ident(directive, "ifdef")):
		cpp_cond_push(pp, cpp_macro_lookup(pp.macros, directive.next.text) != 0)
	else if (cpp_token_is_ident(directive, "ifndef")):
		cpp_cond_push(pp, cpp_macro_lookup(pp.macros, directive.next.text) == 0)
	else if (cpp_token_is_ident(directive, "elif")):
		cpp_cond_elif(pp, cpp_eval_directive_expr(pp, directive, end))
	else if (cpp_token_is_ident(directive, "else")):
		cpp_cond_else(pp)
	else if (cpp_token_is_ident(directive, "endif")):
		cpp_cond_pop(pp)
	else if (pp.active == 0):
		return
	else if (cpp_token_is_ident(directive, "define")):
		cpp_process_define(pp, directive, end)
	else if (cpp_token_is_ident(directive, "undef")):
		if (directive.next != 0):
			if (directive.next.kind == cpp_token_ident()):
				cpp_macro_undef(pp.macros, directive.next.text)
	else if (cpp_token_is_ident(directive, "include")):
		cpp_process_include(pp, directive, end, 0)
	else if (cpp_token_is_ident(directive, "include_next")):
		cpp_process_include(pp, directive, end, 1)
	else if (cpp_token_is_ident(directive, "pragma")):
		cpp_process_pragma(pp, directive)
	else if (cpp_token_is_ident(directive, "error")):
		print_error("c preprocessor: #error in ")
		print_error(pp.current_file)
		error("")


void cpp_preprocess_tokens(cpp_preprocessor* pp, cpp_token* token):
	while (token != 0):
		if (token.kind == cpp_token_eof()):
			return
		cpp_token* next = cpp_next_line(token)
		if (token.at_bol & cpp_token_is_punct(token, "#")):
			cpp_process_directive(pp, token, next)
		else if (pp.active):
			cpp_token* line = cpp_body_range(token, next)
			cpp_render_tokens(pp, cpp_expand_tokens(pp.macros, line))
		token = next


void cpp_preprocess_file_into(cpp_preprocessor* pp, char* path, int include_index):
	if (hash_map_get(pp.once_files, path)):
		return
	char* source = pg_read_file_text(path)
	if (source == 0):
		print_error("c preprocessor: could not read ")
		print_error(path)
		error("")
	char* old_file = pp.current_file
	int old_index = pp.current_include_index
	pp.current_file = path
	pp.current_include_index = include_index
	cpp_preprocess_tokens(pp, cpp_tokenize_text(source, path))
	pp.current_file = old_file
	pp.current_include_index = old_index


cpp_result* cpp_preprocess_file(char* path):
	cpp_preprocessor* pp = cpp_preprocessor_new()
	cpp_preprocess_file_into(pp, path, -1)
	cpp_result* result = new cpp_result()
	result.text = pp.output.data
	result.macros = pp.macros
	free(pp.output)
	return result


cpp_result* cpp_preprocess_text(char* text, char* filename):
	cpp_preprocessor* pp = cpp_preprocessor_new()
	cpp_preprocess_tokens(pp, cpp_tokenize_text(text, filename))
	cpp_result* result = new cpp_result()
	result.text = pp.output.data
	result.macros = pp.macros
	free(pp.output)
	return result
