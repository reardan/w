# Forward declaration: defhash_note is defined in compiler/compiler.w,
# which compiles after grammar/ (see compiler/tokenizer.w's defhash_mode
# comment for why the flag itself needs no such declaration).
void defhash_note(char* name, char* kind, int file_index, int line, int column, int start_offset, int end_offset);


# Quantifiers belong to this function signature, independently of aliases
# used as nested callable parameter/result types.
void function_contract_binders(list[char*] names, int* parameters, int result, int count):
	int slots = type_contract_slots(parameters, result, count)
	if (slots > 32): error(c"checked contracts support at most 32 expanded lifetime slots")
	for i in range(slots):
		char* label = function_lifetime_label(parameters, result, count, i)
		if (label == 0): continue
		int bound = 0
		for char* name in names:
			if (strcmp(name, label) == 0): bound = 1
		if (bound == 0): error(c"checked function lifetime must be quantified by fn[...]")
	for char* name in names:
		int used = 0
		for i in range(slots):
			char* label = function_lifetime_label(parameters, result, count, i)
			if ((label != 0) && (strcmp(name, label) == 0)): used = 1
		if (used == 0): error(c"quantified function lifetime names no borrowed parameter or result")


int type_alias_declaration():
	int defhash_start = token_start_offset
	if (accept(c"type")):
		char* alias_name = strclone(token)
		# Capture the alias name's position before parsing the target moves
		# the current token
		int alias_file = decl_file_index()
		int alias_line = diag_token_line
		int alias_column = diag_token_column
		get_token()
		expect(c"=")
		int target = -1
		if (accept(c"fn")):
			int checked = accept(c"[")
			list[char*] binders = 0
			if (checked):
				if ((ast_retain_mode == 0) || (retained_semantic_mode == 0) || (type_safe_entrypoint == 0)):
					error(c"checked function contracts require the retained checked frontend")
				type_safe_used = 1
				binders = new list[char*]
				while (accept(c"]") == 0):
					if (binders.length): expect(c",")
					if (is_ident_start_byte(token[0]) == 0): error(c"function quantifier requires a lifetime label")
					for char* previous in binders:
						if (strcmp(previous, token) == 0): error(c"duplicate quantified function lifetime")
					binders.push(strclone(token))
					get_token()
			expect(c"(")
			char* params = cast(char*, malloc(10 * __word_size__))
			int param_count = 0
			while (accept(c")") == 0):
				if (param_count): expect(c",")
				if (checked && (param_count == 10)): error(c"checked function contracts support at most 10 parameters")
				int param_type = type_name()
				if (param_count >= 10): params = realloc(params, param_count * __word_size__, (param_count + 1) * __word_size__)
				save_ptr(params + param_count * __word_size__, param_type)
				param_count = param_count + 1
			expect(c"-")
			expect(c">")
			int return_type = type_name()
			target = type_push_function(alias_name, return_type, param_count, cast(int, params))
			type_set_decl_location(target, alias_file, alias_line, alias_column)
			if (checked):
				function_contract_binders(binders, cast(int*, params), return_type, param_count)
				int* order = function_lifetime_order_types(cast(int*, params), return_type, param_count)
				if (order == 0): order = function_lifetime_identity(cast(int*, params), return_type, param_count)
				int slots = type_contract_slots(cast(int*, params), return_type, param_count)
				type_record(target).fn_lifetime_order = cast(int*, malloc(slots * __word_size__))
				for i in range(slots): type_record(target).fn_lifetime_order[i] = order[i]
				for char* name in binders: free(name)
				binders.free()
			free(params)
		else:
			target = type_name()
			type_set_decl_location(type_push_alias(alias_name, target), alias_file, alias_line, alias_column)
		pointer_indirection = 0
		expect_or_newline(c";")
		defhash_note(alias_name, c"alias", alias_file, alias_line, alias_column, defhash_start, token_start_offset)
		return 1
	return 0
