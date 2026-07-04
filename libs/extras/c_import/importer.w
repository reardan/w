/*
Lower a small, declaration-oriented C header subset into the compiler's
existing type table, symbol table, and dynamic FFI registry.
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


int ci_type_from_specs(pg_ast_node* specs);
int ci_import_enumerators(pg_ast_node* node, int enum_type, int value);
void ci_import_struct_declarator_list(int struct_type, int base_type, pg_ast_node* node);


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
	if (strcmp(name, "__BEGIN_DECLS") == 0):
		return 1
	if (strcmp(name, "__END_DECLS") == 0):
		return 1
	if (strcmp(name, "__THROW") == 0):
		return 1
	if (strcmp(name, "__THROWNL") == 0):
		return 1
	if (strcmp(name, "__nonnull") == 0):
		return 1
	if (strcmp(name, "__attribute__") == 0):
		return 1
	if (strcmp(name, "__attribute_malloc__") == 0):
		return 1
	if (strcmp(name, "__wur") == 0):
		return 1
	if (strcmp(name, "__restrict") == 0):
		return 1
	if (strcmp(name, "__extension__") == 0):
		return 1
	if (strcmp(name, "__attr_dealloc") == 0):
		return 1
	if (strcmp(name, "__attr_dealloc_fclose") == 0):
		return 1
	if (strcmp(name, "__attr_access") == 0):
		return 1
	if (strcmp(name, "__fortified_attr_access") == 0):
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
	if (type < 0):
		print_error("c_import: unsupported C type '")
		print_error(name)
		error("'")
	return type


int ci_apply_pointers(int type, int count):
	while (count > 0):
		type = type_get_next_pointer(type)
		count = count - 1
	return type


int ci_constant_int(pg_ast_node* node):
	pg_ast_node* number = ci_find_token(node, clang_token_NUMBER())
	if (number == 0):
		return 0
	if ((number.text[0] == '0') & ((number.text[1] == 'x') | (number.text[1] == 'X'))):
		return from_hex(number.text + 2)
	return atoi(number.text)


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


int ci_primitive_type(pg_ast_node* specs):
	if (ci_has_token(specs, clang_token_KW_VOID())):
		return ci_lookup_type("void")
	if (ci_has_token(specs, clang_token_KW_DOUBLE())):
		return ci_lookup_type("float64")
	if (ci_has_token(specs, clang_token_KW_FLOAT())):
		return ci_lookup_type("float32")
	if (ci_has_token(specs, clang_token_KW_CHAR())):
		if (ci_has_token(specs, clang_token_KW_UNSIGNED())):
			return ci_lookup_type("uint8")
		return ci_lookup_type("char")
	if (ci_has_token(specs, clang_token_KW_SHORT())):
		if (ci_has_token(specs, clang_token_KW_UNSIGNED())):
			return ci_lookup_type("uint16")
		return ci_lookup_type("int16")
	if (ci_count_token(specs, clang_token_KW_LONG()) > 1):
		if (ci_has_token(specs, clang_token_KW_UNSIGNED())):
			return ci_lookup_type("uint64")
		return ci_lookup_type("int64")
	if (ci_has_token(specs, clang_token_KW_UNSIGNED())):
		return ci_lookup_type("uint")
	return ci_lookup_type("int")


int ci_import_struct(pg_ast_node* specifier):
	char* name = ci_first_ident(specifier)
	if (name == 0):
		error("c_import: anonymous structs/unions are not supported yet")
	int existing = type_lookup(name)
	pg_ast_node* body = ci_child_ast(specifier, clang_ast_struct_body())
	if ((existing >= 0) & (body == 0)):
		return existing
	int type_index = existing
	if (type_index < 0):
		type_index = type_push_size(strclone(name), 0)
		sym_declare_global(name, type_index, 1)
	if (ci_has_token(ci_child_ast(specifier, clang_ast_struct_or_union()), clang_token_KW_UNION())):
		type_set_kind(type_index, type_kind_union)
	if (body != 0):
		int i = 0
		while (i < pg_ast_child_count(body)):
			pg_ast_node* field_decl = pg_ast_child(body, i)
			if (ci_is_ast(field_decl, clang_ast_struct_declaration())):
				pg_ast_node* field_specs = ci_qualifier_specs(field_decl)
				int field_base = ci_type_from_specs(field_specs)
				pg_ast_node* list = ci_child_ast(field_decl, clang_ast_struct_declarator_list())
				ci_import_struct_declarator_list(type_index, field_base, list)
			i = i + 1
	return type_index


int ci_import_enum(pg_ast_node* specifier):
	char* name = ci_first_ident(specifier)
	if (name == 0):
		error("c_import: anonymous enums are not supported yet")
	int type_index = type_lookup(name)
	if (type_index < 0):
		type_index = type_push_size(strclone(name), 4)
		type_set_kind(type_index, type_kind_enum)
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


int ci_declarator_pointer_count(pg_ast_node* declarator):
	pg_ast_node* pointer = ci_child_ast(declarator, clang_ast_pointer())
	if (pointer == 0):
		return 0
	return ci_count_token(pointer, clang_token_STAR())


pg_ast_node* ci_declarator_params(pg_ast_node* node):
	if (node == 0):
		return 0
	if (ci_is_ast(node, clang_ast_direct_declarator_tail())):
		return ci_child_ast(node, clang_ast_parameter_type_list())
	int i = 0
	while (i < pg_ast_child_count(node)):
		pg_ast_node* found = ci_declarator_params(pg_ast_child(node, i))
		if (found != 0):
			return found
		i = i + 1
	return 0


ci_declarator_info* ci_read_declarator(int base_type, pg_ast_node* declarator):
	ci_declarator_info* info = new ci_declarator_info()
	info.name = ci_first_ident(declarator)
	info.type = ci_apply_pointers(base_type, ci_declarator_pointer_count(declarator))
	info.params = ci_declarator_params(declarator)
	info.is_function = info.params != 0
	return info


int ci_parameter_type(pg_ast_node* parameter):
	pg_ast_node* specs = ci_declaration_specs(parameter)
	int type = ci_type_from_specs(specs)
	pg_ast_node* declarator = ci_child_ast(parameter, clang_ast_declarator())
	if (declarator != 0):
		ci_declarator_info* info = ci_read_declarator(type, declarator)
		type = info.type
	return type


int ci_parameter_is_void_only(pg_ast_node* parameter):
	pg_ast_node* specs = ci_declaration_specs(parameter)
	if (ci_has_token(specs, clang_token_KW_VOID()) == 0):
		return 0
	return ci_child_ast(parameter, clang_ast_declarator()) == 0


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
				if (param_count <= sym_max_param_slots()):
					save_int(table + sym + 22 + (param_count << 2), ptype)
		else:
			param_count = ci_lower_params_from(parameter, sym, param_count)
		i = i + 1
	if ((start_count == 0) & void_only):
		return 0
	return param_count


int ci_params_have_ellipsis(pg_ast_node* params):
	return ci_find_ast(params, clang_ast_parameter_ellipsis()) != 0


void ci_skip_extern_function(char* name, char* reason):
	if (verbosity >= 1):
		print_error("warning: c_import skipped '")
		print_error(name)
		print_error("': ")
		print_error(reason)
		print_error("\x0a")


void ci_lower_extern_function(char* name, int ret_type, pg_ast_node* params):
	int sym = sym_declare_global(name, ret_type, 2)
	int param_count = ci_lower_params_from(params, sym, 0)
	save_int(table + sym + 22, param_count)
	int got_vaddr = code_offset + codepos
	emit_zeros(word_size)
	dyn_add_import(name, got_vaddr)
	sym_define_global(sym)
	emit_ffi_shim(param_count, got_vaddr)


int ci_import_enumerators(pg_ast_node* node, int enum_type, int value):
	if (ci_is_ast(node, clang_ast_enumerator())):
		char* name = ci_first_ident(node)
		pg_ast_node* enum_value = ci_child_ast(node, clang_ast_enum_value())
		if (enum_value != 0):
			value = ci_constant_int(enum_value)
		int current_symbol = sym_declare_global(name, enum_type, 1)
		sym_define_global(current_symbol)
		emit_int32(value)
		return value + 1
	int i = 0
	while (i < pg_ast_child_count(node)):
		value = ci_import_enumerators(pg_ast_child(node, i), enum_type, value)
		i = i + 1
	return value


void ci_import_struct_declarator_list(int struct_type, int base_type, pg_ast_node* node):
	if (node == 0):
		return
	if (ci_is_ast(node, clang_ast_struct_declarator())):
		pg_ast_node* declarator = ci_child_ast(node, clang_ast_declarator())
		if (declarator != 0):
			ci_declarator_info* info = ci_read_declarator(base_type, declarator)
			type_add_arg(struct_type, strclone(info.name), info.type)
		return
	int i = 0
	while (i < pg_ast_child_count(node)):
		ci_import_struct_declarator_list(struct_type, base_type, pg_ast_child(node, i))
		i = i + 1


void ci_import_init_declarators(ci_decl_info* decl, pg_ast_node* node):
	if (node == 0):
		return
	if (ci_is_ast(node, clang_ast_init_declarator())):
		pg_ast_node* declarator = ci_child_ast(node, clang_ast_declarator())
		ci_declarator_info* info = ci_read_declarator(decl.base_type, declarator)
		if (info.name != 0):
			if (decl.is_typedef):
				if (strcmp(type_get_name(decl.base_type), info.name) != 0):
					type_push_alias(strclone(info.name), info.type)
			else if (info.is_function):
				if (decl.is_static | decl.is_inline):
					ci_skip_extern_function(info.name, "static/inline function")
				else if (ci_params_have_ellipsis(info.params)):
					ci_skip_extern_function(info.name, "variadic function")
				else:
					ci_lower_extern_function(info.name, info.type, info.params)
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


void ci_import_translation_unit(pg_ast_node* root):
	int i = 0
	while (i < pg_ast_child_count(root)):
		pg_ast_node* declaration = ci_child_ast(pg_ast_child(root, i), clang_ast_declaration())
		if (declaration != 0):
			ci_import_declaration(declaration)
		i = i + 1


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
	if (strcmp(token.text, "(") == 0):
		return 1
	if (strcmp(token.text, ")") == 0):
		return 1
	if (strcmp(token.text, "?") == 0):
		return 1
	if (strcmp(token.text, ":") == 0):
		return 1
	if (strcmp(token.text, "+") == 0):
		return 1
	if (strcmp(token.text, "-") == 0):
		return 1
	if (strcmp(token.text, "*") == 0):
		return 1
	if (strcmp(token.text, "/") == 0):
		return 1
	if (strcmp(token.text, "%") == 0):
		return 1
	if (strcmp(token.text, "<<") == 0):
		return 1
	if (strcmp(token.text, ">>") == 0):
		return 1
	if (strcmp(token.text, "<") == 0):
		return 1
	if (strcmp(token.text, ">") == 0):
		return 1
	if (strcmp(token.text, "<=") == 0):
		return 1
	if (strcmp(token.text, ">=") == 0):
		return 1
	if (strcmp(token.text, "==") == 0):
		return 1
	if (strcmp(token.text, "!=") == 0):
		return 1
	if (strcmp(token.text, "&") == 0):
		return 1
	if (strcmp(token.text, "^") == 0):
		return 1
	if (strcmp(token.text, "|") == 0):
		return 1
	if (strcmp(token.text, "&&") == 0):
		return 1
	if (strcmp(token.text, "||") == 0):
		return 1
	if (strcmp(token.text, "!") == 0):
		return 1
	if (strcmp(token.text, "~") == 0):
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
	int current_symbol = sym_declare_global(name, ci_lookup_type("int"), 1)
	sym_define_global(current_symbol)
	emit_int(value)


void ci_export_macro_constants(hash_map* macros):
	int cursor = hash_map_iter_begin(macros)
	while (hash_map_iter_done(macros, cursor) == 0):
		char* name = hash_map_iter_value(macros, cursor)
		cpp_macro* macro = hash_map_get(macros, name)
		ci_export_macro_constant(macros, name, macro)
		cursor = hash_map_iter_next(macros, cursor)


void c_import_header(char* soname, char* header_path):
	dyn_add_lib(soname)
	cpp_result* preprocessed = cpp_preprocess_file(header_path)
	char* source = preprocessed.text
	source = ci_prepare_header_source(source)
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = clang_parse(source, header_path, diagnostics)
	if ((root == 0) | (pg_diagnostics_count(diagnostics) != 0)):
		pg_diagnostics_print(diagnostics)
		error("c_import: header parse failed")
	ci_import_translation_unit(root)
	ci_export_macro_constants(preprocessed.macros)
