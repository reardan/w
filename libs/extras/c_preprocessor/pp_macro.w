/*
Macro storage and Prosser-style expansion.
*/
import lib.lib
import structures.array_list
import structures.hash_map
import structures.string
import libs.extras.c_preprocessor.pp_token
import libs.extras.c_preprocessor.pp_lexer


struct cpp_macro:
	char* name
	int is_function
	int is_variadic
	array_list* params
	cpp_token* body
	int builtin


struct cpp_macro_args:
	array_list* items
	cpp_token* after
	cpp_hideset* rparen_hideset
	int variadic_has_tokens


cpp_token* cpp_expand_tokens(hash_map* macros, cpp_token* token);
cpp_token* cpp_substitute_macro(hash_map* macros, cpp_macro* macro, cpp_macro_args* args, cpp_hideset* hideset);
cpp_token* cpp_remove_last_token(cpp_token* head);


int cpp_macro_builtin_none():
	return 0


int cpp_macro_builtin_file():
	return 1


int cpp_macro_builtin_line():
	return 2


cpp_macro* cpp_macro_new(char* name):
	cpp_macro* macro = new cpp_macro()
	macro.name = strclone(name)
	macro.is_function = 0
	macro.is_variadic = 0
	macro.params = array_list_new()
	macro.body = 0
	macro.builtin = cpp_macro_builtin_none()
	return macro


cpp_macro* cpp_macro_lookup(hash_map* macros, char* name):
	if (hash_map_contains(macros, name) == 0):
		return 0
	return hash_map_get(macros, name)


void cpp_macro_define(hash_map* macros, cpp_macro* macro):
	hash_map_set(macros, macro.name, macro)


void cpp_macro_undef(hash_map* macros, char* name):
	hash_map_set(macros, name, 0)


void cpp_macro_define_object(hash_map* macros, char* name, cpp_token* body):
	cpp_macro* macro = cpp_macro_new(name)
	macro.body = body
	cpp_macro_define(macros, macro)


void cpp_macro_define_builtin(hash_map* macros, char* name, int builtin):
	cpp_macro* macro = cpp_macro_new(name)
	macro.builtin = builtin
	cpp_macro_define(macros, macro)


int cpp_macro_param_index(cpp_macro* macro, char* name):
	int i = 0
	while (i < macro.params.length):
		char* param = array_list_get(macro.params, i)
		if (strcmp(param, name) == 0):
			return i
		i = i + 1
	return -1


cpp_token* cpp_token_list_without_eof(cpp_token* token):
	cpp_token head
	head.next = 0
	cpp_token* tail = &head
	while (token != 0):
		if (token.kind == cpp_token_eof()):
			break
		tail.next = cpp_token_clone_one(token)
		tail = tail.next
		token = token.next
	tail.next = 0
	return head.next


cpp_token* cpp_token_append_list(cpp_token* left, cpp_token* right):
	if (left == 0):
		return right
	cpp_token* last = cpp_token_last(left)
	last.next = right
	return left


cpp_token* cpp_make_placemarker():
	return cpp_token_new(cpp_token_placemarker(), "", "<macro>", 0, 0, 0)


cpp_token* cpp_arg_token(array_list* args, int index):
	if (index < 0):
		return 0
	if (index >= args.length):
		return 0
	return array_list_get(args, index)


cpp_token* cpp_clone_arg_or_marker(array_list* args, int index):
	cpp_token* arg = cpp_arg_token(args, index)
	if (arg == 0):
		return cpp_make_placemarker()
	if (arg.kind == cpp_token_eof()):
		return cpp_make_placemarker()
	return cpp_token_list_without_eof(arg)


int cpp_arg_has_tokens(cpp_token* arg):
	if (arg == 0):
		return 0
	return arg.kind != cpp_token_eof()


void cpp_args_push_token(cpp_token* head, cpp_token* token):
	cpp_token* copy = cpp_token_clone_one(token)
	copy.next = 0
	cpp_token_append(head, copy)


cpp_macro_args* cpp_collect_args(cpp_token* lparen):
	cpp_macro_args* args = new cpp_macro_args()
	args.items = array_list_new()
	args.after = 0
	args.rparen_hideset = 0
	args.variadic_has_tokens = 0
	cpp_token current_head
	current_head.next = 0
	int depth = 0
	cpp_token* token = lparen.next
	while (token != 0):
		if (cpp_token_is_punct(token, "(")):
			depth = depth + 1
			cpp_args_push_token(&current_head, token)
		else if (cpp_token_is_punct(token, ")")):
			if (depth == 0):
				array_list_push(args.items, current_head.next)
				args.after = token.next
				args.rparen_hideset = token.hideset
				return args
			depth = depth - 1
			cpp_args_push_token(&current_head, token)
		else if (cpp_token_is_punct(token, ",") & (depth == 0)):
			array_list_push(args.items, current_head.next)
			current_head.next = 0
		else:
			cpp_args_push_token(&current_head, token)
		token = token.next
	return args


cpp_token* cpp_join_variadic_args(cpp_macro_args* args, int first):
	cpp_token head
	head.next = 0
	cpp_token* tail = &head
	int i = first
	while (i < args.items.length):
		if (i > first):
			tail.next = cpp_token_new(cpp_token_punct(), ",", "<macro>", 0, 0, 0)
			tail = tail.next
		cpp_token* arg = cpp_arg_token(args.items, i)
		if (cpp_arg_has_tokens(arg)):
			args.variadic_has_tokens = 1
			cpp_token* copy = cpp_token_list_without_eof(arg)
			tail.next = copy
			tail = cpp_token_last(copy)
		i = i + 1
	return head.next


void cpp_normalize_args(cpp_macro* macro, cpp_macro_args* args):
	if (macro.is_variadic == 0):
		return
	array_list* normalized = array_list_new()
	int fixed_count = macro.params.length - 1
	int i = 0
	while (i < fixed_count):
		if (i < args.items.length):
			array_list_push(normalized, array_list_get(args.items, i))
		else:
			array_list_push(normalized, 0)
		i = i + 1
	array_list_push(normalized, cpp_join_variadic_args(args, fixed_count))
	args.items = normalized


cpp_token* cpp_builtin_expand(cpp_macro* macro, cpp_token* origin):
	if (macro.builtin == cpp_macro_builtin_line()):
		char* text = itoa(origin.line)
		cpp_token* token = cpp_token_new(cpp_token_number(), text, origin.filename, origin.line, origin.has_space, origin.at_bol)
		free(text)
		return token
	if (macro.builtin == cpp_macro_builtin_file()):
		string_builder* s = string_new()
		string_append_char(s, '"')
		string_append(s, origin.filename)
		string_append_char(s, '"')
		cpp_token* token = cpp_token_new(cpp_token_string(), s.data, origin.filename, origin.line, origin.has_space, origin.at_bol)
		string_free(s)
		return token
	return 0


void cpp_stringize_append_escaped(string_builder* out, char* text):
	int i = 0
	while (text[i] != 0):
		if ((text[i] == '"') | (text[i] == 92)):
			string_append_char(out, 92)
		string_append_char(out, text[i])
		i = i + 1


cpp_token* cpp_stringize_arg(cpp_token* arg):
	string_builder* out = string_new()
	string_append_char(out, '"')
	int need_space = 0
	while (arg != 0):
		if (arg.kind == cpp_token_eof()):
			break
		if (arg.has_space | need_space):
			if (out.data[out.length - 1] != '"'):
				string_append_char(out, ' ')
		cpp_stringize_append_escaped(out, arg.text)
		need_space = 0
		arg = arg.next
	string_append_char(out, '"')
	cpp_token* token = cpp_token_new(cpp_token_string(), out.data, "<macro>", 0, 0, 0)
	string_free(out)
	return token


int cpp_token_is_param(cpp_macro* macro, cpp_token* token):
	if (token == 0):
		return 0
	if (token.kind != cpp_token_ident()):
		return 0
	return cpp_macro_param_index(macro, token.text) >= 0


cpp_token* cpp_param_replacement(hash_map* macros, cpp_macro* macro, cpp_macro_args* args, cpp_token* token, int raw):
	int index = cpp_macro_param_index(macro, token.text)
	if (raw):
		return cpp_clone_arg_or_marker(args.items, index)
	cpp_token* arg = cpp_arg_token(args.items, index)
	if (arg == 0):
		return 0
	return cpp_expand_tokens(macros, cpp_token_list_without_eof(arg))


cpp_token* cpp_subst_first_pass(hash_map* macros, cpp_macro* macro, cpp_macro_args* args):
	cpp_token head
	head.next = 0
	cpp_token* tail = &head
	cpp_token* token = macro.body
	int last_was_paste = 0
	while (token != 0):
		if (token.kind == cpp_token_eof()):
			break
		if (cpp_token_is_punct(token, "#") & cpp_token_is_param(macro, token.next)):
			int index = cpp_macro_param_index(macro, token.next.text)
			tail.next = cpp_stringize_arg(cpp_arg_token(args.items, index))
			tail = tail.next
			token = token.next.next
			last_was_paste = 0
		else if (cpp_token_is_punct(token, "##") & cpp_token_is_param(macro, token.next)):
			int index = cpp_macro_param_index(macro, token.next.text)
			cpp_token* arg = cpp_arg_token(args.items, index)
			if (cpp_token_is_ident(token.next, "__VA_ARGS__") & (cpp_arg_has_tokens(arg) == 0)):
				cpp_token* comma = cpp_remove_last_token(&head)
				if (comma != 0):
					if (strcmp(comma.text, ",") != 0):
						tail = cpp_token_last(&head)
						tail.next = comma
						tail = comma
					else:
						tail = cpp_token_last(&head)
				else:
					tail = cpp_token_last(&head)
				token = token.next.next
			else:
				tail.next = cpp_token_clone_one(token)
				tail = tail.next
				last_was_paste = 1
				token = token.next
		else if (cpp_token_is_param(macro, token)):
			int raw = 0
			if (cpp_token_is_punct(token.next, "##") | last_was_paste):
				raw = 1
			cpp_token* replacement = cpp_param_replacement(macros, macro, args, token, raw)
			if (replacement != 0):
				tail.next = replacement
				tail = cpp_token_last(tail.next)
			token = token.next
			last_was_paste = 0
		else:
			tail.next = cpp_token_clone_one(token)
			tail = tail.next
			last_was_paste = cpp_token_is_punct(token, "##")
			token = token.next
	tail.next = 0
	return head.next


cpp_token* cpp_remove_last_token(cpp_token* head):
	cpp_token* prev = head
	cpp_token* cur = head.next
	if (cur == 0):
		return 0
	while (cur.next != 0):
		prev = cur
		cur = cur.next
	prev.next = 0
	return cur


void cpp_paste_into(cpp_token* left, cpp_token* right):
	string_builder* text = string_new_sized(strlen(left.text) + strlen(right.text) + 1)
	string_append(text, left.text)
	string_append(text, right.text)
	cpp_token* pasted = cpp_lex_one_token(text.data)
	if (pasted == 0):
		print_error("c preprocessor: invalid token paste: ")
		print_error(text.data)
		error("")
	left.kind = pasted.kind
	free(left.text)
	left.text = strclone(pasted.text)
	left.hideset = cpp_hideset_intersection(left.hideset, right.hideset)
	string_free(text)


cpp_token* cpp_process_paste(cpp_token* tokens):
	cpp_token head
	head.next = 0
	cpp_token* tail = &head
	cpp_token* token = tokens
	while (token != 0):
		if (cpp_token_is_punct(token, "##")):
			cpp_token* right = token.next
			if (right == 0):
				return head.next
			cpp_token* left = cpp_remove_last_token(&head)
			if (left != 0):
				if (left.kind == cpp_token_placemarker()):
					if (right.kind != cpp_token_placemarker()):
						tail = cpp_token_last(&head)
						tail.next = right
						tail = right
						token = right.next
						tail.next = 0
					else:
						tail = cpp_token_last(&head)
						token = right.next
				else:
					if (right.kind != cpp_token_placemarker()):
						cpp_paste_into(left, right)
					tail = cpp_token_last(&head)
					tail.next = left
					tail = left
					tail.next = 0
					token = right.next
			else:
				token = right.next
		else if (token.kind == cpp_token_placemarker()):
			if (cpp_token_is_punct(token.next, "##")):
				cpp_token* next = token.next
				token.next = 0
				tail.next = token
				tail = token
				token = next
			else:
				token = token.next
		else:
			cpp_token* next = token.next
			token.next = 0
			tail.next = token
			tail = token
			token = next
	return head.next


cpp_token* cpp_substitute_macro(hash_map* macros, cpp_macro* macro, cpp_macro_args* args, cpp_hideset* hideset):
	cpp_token* first = cpp_subst_first_pass(macros, macro, args)
	cpp_token* pasted = cpp_process_paste(first)
	cpp_token_add_hideset(pasted, hideset)
	return pasted


cpp_token* cpp_attach_rest(cpp_token* replacement, cpp_token* rest):
	if (replacement == 0):
		return rest
	cpp_token* last = cpp_token_last(replacement)
	last.next = rest
	return replacement


cpp_token* cpp_expand_tokens(hash_map* macros, cpp_token* token):
	cpp_token head
	head.next = 0
	cpp_token* tail = &head
	while (token != 0):
		if (token.kind == cpp_token_eof()):
			break
		if (token.kind == cpp_token_ident()):
			cpp_macro* macro = cpp_macro_lookup(macros, token.text)
			if ((macro != 0) & (cpp_hideset_contains(token.hideset, token.text) == 0)):
				cpp_token* replacement = 0
				if (macro.builtin != cpp_macro_builtin_none()):
					replacement = cpp_builtin_expand(macro, token)
					cpp_token_add_hideset(replacement, cpp_hideset_add(token.hideset, token.text))
					token = cpp_attach_rest(replacement, token.next)
					continue
				if (macro.is_function):
					if (cpp_token_is_punct(token.next, "(")):
						cpp_macro_args* args = cpp_collect_args(token.next)
						if (args.after != 0):
							cpp_normalize_args(macro, args)
							cpp_hideset* hs = cpp_hideset_intersection(token.hideset, args.rparen_hideset)
							hs = cpp_hideset_add(hs, token.text)
							replacement = cpp_substitute_macro(macros, macro, args, hs)
							token = cpp_attach_rest(replacement, args.after)
							continue
				else:
					replacement = cpp_token_clone_list(macro.body)
					replacement = cpp_process_paste(replacement)
					cpp_token_add_hideset(replacement, cpp_hideset_add(token.hideset, token.text))
					token = cpp_attach_rest(replacement, token.next)
					continue
		cpp_token* next = token.next
		token.next = 0
		tail.next = token
		tail = token
		token = next
	return head.next
