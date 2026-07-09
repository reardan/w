/*
Compiler lowering for f"..." template string literals.

An f-string is an expression producing a string value (the two-word
{data_ptr, length} descriptor; see docs/projects/arrays_slices_strings.md).
The tokenizer delivers the literal in chunks: the current token holds the
raw text up to the first embedded '{' expression or the closing quote
(see take_template_chunk in compiler/tokenizer.w). This file alternates
between appending the decoded chunk bytes and compiling the embedded
expression with the ordinary expression() rule, then asks the tokenizer
for the next chunk with get_token_template_chunk(). Doubled braces
('{{'/'}}') decode to literal braces; the usual escapes (\n, \t, \r, \0,
\xHH, \uHHHH, \UHHHHHHHH) work in chunks exactly like in s"..." literals.

The whole literal lowers to calls into the __w_template_* helpers in
structures/string.w: a string_builder is created, every chunk and value
is appended, and __w_template_finish converts the accumulated bytes into
a string descriptor. Supported embedded value types are int-likes (int,
fixed-width ints, char, bool, enums append via itoa), char* and string;
anything else is a compile error.

structures/string.w is not auto-imported, so the module is imported on
demand: like the json codec (grammar/json_builtin.w), call sites emitted
before the import go through per-helper backpatch chains, and the
drivers call template_string_finish_import() at a top-level boundary
once compilation of the user's files is done.
*/
int expression();
int import_module(char* dotted);
void var_emit_to_cstr();


# Set when a compiled program used an f-string; the drivers call
# template_string_finish_import() once compilation is done.
int template_string_needed

# Backpatch chain heads for the runtime helpers, indexed like
# template_fn_name. Encoding matches the 'U' symbol chains: each mov-imm
# slot holds the previous slot's absolute address, code_offset ends the
# chain. A symbol-table forward declaration would not survive
# function_definition's scope truncation, so the chains live here.
char* template_chains


int template_helper_count():
	return 6


char* template_fn_name(int i):
	if (i == 0):
		return c"__w_template_new"
	if (i == 1):
		return c"__w_template_bytes"
	if (i == 2):
		return c"__w_template_cstr"
	if (i == 3):
		return c"__w_template_int"
	if (i == 4):
		return c"__w_template_str"
	return c"__w_template_finish"


# Leave helper i's address in eax: directly when the runtime module is
# already compiled (the program imported structures.string itself),
# through the helper's backpatch chain otherwise.
void template_emit_helper_address(int i):
	char* name = template_fn_name(i)
	if (sym_lookup(name) >= 0):
		sym_get_value(name)
		return;
	if (template_chains == 0):
		template_chains = malloc(template_helper_count() * 4)
		int j = 0
		while (j < template_helper_count()):
			save_int(template_chains + j * 4, 0)
			j = j + 1
	int head = load_int(template_chains + i * 4)
	if (head == 0):
		head = code_offset
	be_addr_slot_emit() /* mov $n,%eax (x86) / adrp+add pair (arm64) */
	be_addr_slot_write(codepos - 4, head)
	save_int(template_chains + i * 4, codepos + code_offset - 4)


int template_chunk_final

# Decode the escapes and brace pairs of the f-string chunk starting at
# token[j], writing the raw bytes to the front of token (in place, like
# process_string_literal_from; decoding never expands, so the write
# cursor stays at or behind the read cursor). The chunk ends at the
# closing quote (template_chunk_final = 1) or at the single '{' that
# opens an embedded expression (template_chunk_final = 0). Returns the
# decoded byte count.
int template_process_chunk(int j):
	int i = 0
	int k
	template_chunk_final = 0
	while (token[j] != '"'):
		if (token[j] == '{'):
			if (token[j + 1] != '{'):
				return i
			token[i] = '{'
			j = j + 2

		# the tokenizer only lets doubled closing braces through
		else if (token[j] == '}'):
			token[i] = '}'
			j = j + 2

		else if ((token[j] == 92) & (token[j + 1] == 'x')):
			k = string_hex_value(j + 2, 2)
			token[i] = k
			j = j + 4

		else if ((token[j] == 92) & (token[j + 1] == 'u')):
			k = string_hex_value(j + 2, 4)
			i = string_append_utf8(i, k) - 1
			j = j + 6

		else if ((token[j] == 92) & (token[j + 1] == 'U')):
			k = string_hex_value(j + 2, 8)
			i = string_append_utf8(i, k) - 1
			j = j + 10

		# standard escapes: \n \t \r \0 (anything else is taken literally)
		else if (token[j] == 92):
			k = token[j + 1]
			if (k == 'n'):
				k = 10
			else if (k == 't'):
				k = 9
			else if (k == 'r'):
				k = 13
			else if (k == '0'):
				k = 0
			token[i] = k
			j = j + 2

		else:
			token[i] = token[j]
			j = j + 1

		i = i + 1
	template_chunk_final = 1
	return i


void template_unsupported(int t):
	diag_part(c"unsupported template string expression type: '")
	if (t == 4):
		diag_part(c"function")
	else:
		print_error_type(t)
	error(c"'")


# Pick the append helper for an interpolated value: 2 char*, 3 int-like
# (int, fixed-width ints, char, bool, enum), 4 string. Anything else
# (floats, structs, containers, non-char pointers, void) is rejected.
int template_helper_for_type(int got):
	if (got == 3): /* constant: already a plain value */
		return 3
	if (got == 4): /* function */
		template_unsupported(got)
	int t = type_unqualified(got)
	if (type_is_string(t)):
		return 4
	if (type_is_char_pointer(t)):
		return 2
	# var renders through __w_var_to_cstr, then appends as a char*
	if (type_is_var(t)):
		return 2
	if (type_float_kind(t)):
		template_unsupported(got)
	if (type_get_pointer_level(t) > 0):
		template_unsupported(got)
	if (type_num_args(t) > 0):
		template_unsupported(got)
	if (type_is_map(t) | type_is_set(t) | type_is_list(t)):
		template_unsupported(got)
	if (type_is_array(t) | type_is_slice(t)):
		template_unsupported(got)
	if (type_get_kind(t) == type_kind_enum):
		return 3
	if (t == type_unqualified(bool_type)):
		return 3
	int size = type_get_size(t)
	if ((size == 1) | (size == 2) | (size == 4) | (size == 8)):
		return 3
	template_unsupported(got)
	return 0


# Emit the decoded chunk bytes into the code stream (jumped over by a
# call, like c"..." literals) and lower the append to
# __w_template_bytes(builder, data, length). The explicit length keeps
# embedded \0 escapes intact.
void template_emit_chunk_append(int length, int builder_slot):
	int base_stack = stack_pos
	token[length] = 0
	be_emit_inline_cstr(length, token)
	push_eax()
	stack_pos = stack_pos + 1
	int data_slot = stack_pos
	template_emit_helper_address(1)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(builder_slot)
	hash_push_stack_slot(data_slot)
	mov_eax_int(length)
	push_eax()
	stack_pos = stack_pos + 1
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack


# Append the embedded expression's value (in eax, already promoted) to
# the builder with the helper matching its type.
void template_emit_value_append(int got, int builder_slot):
	int helper = template_helper_for_type(got)
	if (type_is_var(type_unqualified(got))):
		var_emit_to_cstr()
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int value_slot = stack_pos
	template_emit_helper_address(helper)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(builder_slot)
	hash_push_stack_slot(value_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack


# f"..." template string literal. The current token is the opening chunk
# (f" through the first '{' or the closing quote). Returns 0 when the
# token is something else; otherwise compiles the whole literal, leaves
# the string descriptor's address in eax (string_value_type) and keeps
# the final chunk as the current token for primary_expr's trailing
# get_token().
int template_string_literal():
	if ((token[0] != 'f') | (token[1] != '"')):
		return 0
	template_string_needed = 1
	int base_stack = stack_pos

	# builder = __w_template_new()
	template_emit_helper_address(0)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_call_finish(s)
	push_eax()
	stack_pos = stack_pos + 1
	int builder_slot = stack_pos

	int start = 2
	int done = 0
	while (done == 0):
		int length = template_process_chunk(start)
		if (length > 0):
			validate_utf8_literal(length)
			template_emit_chunk_append(length, builder_slot)
		if (template_chunk_final):
			done = 1
		else:
			get_token()
			int got = expression()
			if (peek(c"}") == 0):
				error(c"'}' expected in template string expression")
			got = promote(got)
			template_emit_value_append(got, builder_slot)
			get_token_template_chunk()
			start = 0

	# result = __w_template_finish(builder)
	template_emit_helper_address(5)
	s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(builder_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return 1


void template_patch_chain(int i):
	int head = load_int(template_chains + i * 4)
	if (head == 0):
		return;
	int v = sym_address(template_fn_name(i))
	int p = head - code_offset
	while (p):
		int next = be_addr_slot_read(p) - code_offset
		be_addr_slot_write(p, v)
		p = next
	save_int(template_chains + i * 4, 0)


# Deferred on-demand import of the template string runtime. Called by
# the drivers (link_impl, the REPL, wdbg) at a top-level boundary once
# compilation of the user's files is done; import_module de-duplicates
# repeat calls. After the module has defined the helpers, resolve the
# call sites that were emitted before the import.
void template_string_finish_import():
	if (template_string_needed == 0):
		return;
	import_module(c"structures.string")
	if (template_chains == 0):
		return;
	int i = 0
	while (i < template_helper_count()):
		template_patch_chain(i)
		i = i + 1
