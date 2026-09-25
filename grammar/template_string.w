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
void var_emit_to_cstr();


# The f-string runtime (structures/string.w), imported on demand by
# template_string_finish_import(). Helper indexes: 0 __w_template_new,
# 1 __w_template_bytes, 2 __w_template_cstr, 3 __w_template_int, 4
# __w_template_str, 5 __w_template_finish, 6 __w_template_fmt, 7
# __w_template_float.
lazy_runtime* template_rt


void template_emit_helper_address(int i):
	if (cast(int, template_rt) == 0):
		template_rt = lazy_runtime_new(c"structures.string", c"__w_template_new __w_template_bytes __w_template_cstr __w_template_int __w_template_str __w_template_finish __w_template_fmt __w_template_float")
	lazy_emit_helper(template_rt, i)


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

		else if ((token[j] == 92) && (token[j + 1] == 'x')):
			k = string_hex_value(j + 2, 2)
			token[i] = k
			j = j + 4

		else if ((token[j] == 92) && (token[j + 1] == 'u')):
			k = string_hex_value(j + 2, 4)
			i = string_append_utf8(i, k) - 1
			j = j + 6

		else if ((token[j] == 92) && (token[j + 1] == 'U')):
			k = string_hex_value(j + 2, 8)
			i = string_append_utf8(i, k) - 1
			j = j + 10

		# standard escapes: \n \t \r \0 (anything else is taken literally)
		else if (token[j] == 92):
			k = escape_char_value(token[j + 1])
			if (k < 0):
				k = token[j + 1]
			token[i] = k
			j = j + 2

		else:
			token[i] = token[j]
			j = j + 1

		i = i + 1
	template_chunk_final = 1
	return i


void template_unsupported(int t):
	value_type_error(c"unsupported template string expression type:", t)


# A parsed '{value:spec}' format spec, the Python mini-language subset
# [[fill]align][0][width][.precision][type]: align '<' '>' '^' or '='
# (sign-aware, what the '0' flag selects), type one of d x X o b c s f
# (0 when absent). template_spec_present is 0 for a bare '{value}'.
int template_spec_present
int template_spec_fill
int template_spec_align
int template_spec_width
int template_spec_precision
int template_spec_type


int template_spec_is_align(int c):
	return (c == '<') || (c == '>') || (c == '^') || (c == '=')


void template_spec_error(char* why):
	diag_part(c"invalid template string format spec '")
	diag_part(token)
	diag_part(c"': ")
	error(why)


# Read the raw format spec after the ':' that follows an embedded
# expression: the characters up to the closing '}' become the token,
# and the '}' is consumed so get_token_template_chunk() resumes right
# after it (the same state a bare '{value}' leaves).
void template_take_spec():
	token_i = 0
	while (nextc != '}'):
		if ((nextc == -1) || (nextc == 10) || (nextc == '"')):
			error(c"'}' expected in template string expression")
		takechar()
	takechar()
	token_i = token_i - 1
	token[token_i] = 0


void template_parse_spec():
	template_spec_fill = ' '
	template_spec_align = 0
	template_spec_width = 0
	template_spec_precision = -1
	template_spec_type = 0
	int i = 0
	if ((token[0] != 0) && template_spec_is_align(token[1])):
		if (token[0] < 32):
			template_spec_error(c"the fill must be a printable ASCII character")
		template_spec_fill = token[0]
		template_spec_align = token[1]
		i = 2
	else if (template_spec_is_align(token[0])):
		template_spec_align = token[0]
		i = 1
	if (token[i] == '0'):
		# zero padding: '0' fill (unless one was given), sign-aware
		if (i < 2):
			template_spec_fill = '0'
		if (template_spec_align == 0):
			template_spec_align = '='
		i = i + 1
	while (('0' <= token[i]) && (token[i] <= '9')):
		template_spec_width = template_spec_width * 10 + token[i] - '0'
		if (template_spec_width > 4096):
			template_spec_error(c"width is limited to 4096")
		i = i + 1
	if (token[i] == '.'):
		i = i + 1
		if ((token[i] < '0') || (token[i] > '9')):
			template_spec_error(c"'.' must be followed by a precision")
		template_spec_precision = 0
		while (('0' <= token[i]) && (token[i] <= '9')):
			template_spec_precision = template_spec_precision * 10 + token[i] - '0'
			if (template_spec_precision > 60):
				template_spec_error(c"precision is limited to 60")
			i = i + 1
	int c = token[i]
	if ((c == 'd') || (c == 'x') || (c == 'X') || (c == 'o') || (c == 'b') || (c == 'c') || (c == 's') || (c == 'f')):
		template_spec_type = c
		i = i + 1
	if (token[i] != 0):
		template_spec_error(c"expected [[fill]align][0][width][.precision][type] with type one of d x X o b c s f")


# Runtime kind for __w_template_fmt (structures/string.w) of a value of
# class vc under the parsed spec: 0 decimal, 1 hex, 2 HEX, 3 octal,
# 4 binary, 5 char, 6 char*, 7 string; 8 float32 and 9 float64 go to
# their own helpers. Rejects spec/type combinations that do not apply.
int template_spec_kind(int vc):
	int c = template_spec_type
	int numeric = value_class_is_int_like(vc) || (vc == VC_F32) || (vc == VC_F64)
	if ((template_spec_align == '=') && (numeric == 0)):
		template_spec_error(c"zero padding and '=' alignment need a numeric value")
	if ((template_spec_precision >= 0) && (vc != VC_F32) && (vc != VC_F64)):
		template_spec_error(c"precision needs a float value")
	if (value_class_is_int_like(vc)):
		if ((c == 0) || (c == 'd')):
			return 0
		if (c == 'x'):
			return 1
		if (c == 'X'):
			return 2
		if (c == 'o'):
			return 3
		if (c == 'b'):
			return 4
		if (c == 'c'):
			return 5
		template_spec_error(c"an int-like value takes type d, x, X, o, b or c")
	if ((vc == VC_CSTR) || (vc == VC_VAR) || (vc == VC_STRING)):
		if ((c != 0) && (c != 's')):
			template_spec_error(c"a text value takes type s")
		if (vc == VC_STRING):
			return 7
		return 6
	if ((c != 0) && (c != 'f')):
		template_spec_error(c"a float value takes type f")
	if (vc == VC_F64):
		return 9
	return 8


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


# The float64 formatter lives in its own on-demand module: float64 is
# a 64-bit-target type, so structures/string.w (compiled everywhere,
# including by the seed) cannot mention it.
lazy_runtime* template_f64_rt


void template_emit_float64_helper_address():
	if (cast(int, template_f64_rt) == 0):
		template_f64_rt = lazy_runtime_new(c"structures.template_float64", c"__w_template_float64")
	lazy_emit_helper(template_f64_rt, 0)


# Append the embedded expression's value (in eax, already promoted) to
# the builder: a bare '{value}' of an int-like, text or string value
# takes its plain helper (int-likes, char included, render as
# decimals); floats and every spec'd value go through the formatting
# helpers with (value, kind, width, precision, fill << 8 | align).
void template_emit_value_append(int got, int builder_slot):
	int vc = value_class(got)
	if ((vc == VC_NONE) || (vc == VC_LIST)):
		template_unsupported(got)
	int kind = 0
	if (template_spec_present):
		kind = template_spec_kind(vc)
	else:
		template_spec_fill = ' '
		template_spec_align = 0
		template_spec_width = 0
		template_spec_precision = -1
		if (vc == VC_F32):
			kind = 8
		else if (vc == VC_F64):
			kind = 9
	if (vc == VC_VAR):
		var_emit_to_cstr()
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int value_slot = stack_pos
	if ((template_spec_present == 0) && (kind < 8)):
		# plain helper: 2 char*, 3 int-like, 4 string
		int helper = 3
		if ((vc == VC_CSTR) || (vc == VC_VAR)):
			helper = 2
		if (vc == VC_STRING):
			helper = 4
		template_emit_helper_address(helper)
	else if (kind == 9):
		template_emit_float64_helper_address()
	else if (kind == 8):
		template_emit_helper_address(7)
	else:
		template_emit_helper_address(6)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(builder_slot)
	hash_push_stack_slot(value_slot)
	if (template_spec_present || (kind >= 8)):
		if (kind < 8):
			mov_eax_int(kind)
			push_eax()
			stack_pos = stack_pos + 1
		# numbers align right by default, text left (Python's rule)
		int align = template_spec_align
		if (align == 0):
			align = '>'
			if ((kind == 6) || (kind == 7)):
				align = '<'
		mov_eax_int(template_spec_width)
		push_eax()
		stack_pos = stack_pos + 1
		mov_eax_int(template_spec_precision)
		push_eax()
		stack_pos = stack_pos + 1
		mov_eax_int((template_spec_fill << 8) | align)
		push_eax()
		stack_pos = stack_pos + 1
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
	if ((token[0] != 'f') || (token[1] != '"')):
		return 0
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
			int got = promote(expression())
			# '{value:spec}': the raw spec up to '}' (template_take_spec)
			template_spec_present = 0
			if (peek(c":")):
				template_take_spec()
				template_spec_present = token[0] != 0
				if (template_spec_present):
					template_parse_spec()
			else if (peek(c"}") == 0):
				error(c"'}' expected in template string expression")
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


# Deferred on-demand import of the template string runtime. Called by
# the drivers (link_impl, the REPL, wdbg) at a top-level boundary once
# compilation of the user's files is done (grammar/lazy_runtime.w).
void template_string_finish_import():
	lazy_finish_import(template_rt)
	lazy_finish_import(template_f64_rt)
