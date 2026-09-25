/*
Compiler lowering for the built-in polymorphic print/println
(docs/projects/golf_ergonomics.md).

print(x) writes x to stdout formatted by its static type: int-likes
(int, fixed-width ints, bool, enums) as decimals, char as the
character itself, char* and string as their bytes, float32 through
ftoa, var through its runtime tag, and list[T] of scalar elements as
'[a, b, c]'. println(x) appends a newline; println() writes just the
newline. Anything else (maps, sets, structs, non-char pointers,
float64) is a compile error. Only genuinely char-typed values print
as characters: character literals are untyped constants and char
arithmetic yields int, so both keep printing numerically; list[char]
elements keep the numeric rendering of the f-string helper table.

lib/lib.w keeps its print(string)/println(string) functions: the
builtin intercepts direct 'print(' / 'println(' call sites in
primary_expr and behaves identically for the types those functions
accepted, so existing programs compile unchanged.

The calls lower to the __w_print_* helpers in structures/prelude.w.
Like the f-string runtime the module is imported on demand: call sites
emitted before the import go through per-helper backpatch chains and
the drivers call prelude_finish_import() at a top-level boundary.

This file is compiled by the committed seed: only seed-understood
syntax here.
*/
int expression();
void var_emit_to_cstr();


# The prelude runtime (structures/prelude.w), imported on demand by
# prelude_finish_import(). Helper indexes: 0 __w_print_int, 1
# __w_print_cstr, 2 __w_print_str, 3 __w_print_float32, 4
# __w_print_list, 5 __w_print_nl, 6-8 the input helpers, 9-11
# max/min/abs, 12 strlen (len(char*) borrows lib/lib.w's: the prelude
# import pulls lib.lib in, so the chain always resolves at patch time),
# 13 __w_print_char, 14/15 any/all, 16 __w_enum_name.
lazy_runtime* print_rt


void print_emit_helper_address(int i):
	if (cast(int, print_rt) == 0):
		print_rt = lazy_runtime_new(c"structures.prelude", c"__w_print_int __w_print_cstr __w_print_str __w_print_float32 __w_print_list __w_print_nl input read_all ints __w_max __w_min __w_abs strlen __w_print_char __w_any __w_all __w_enum_name")
	lazy_emit_helper(print_rt, i)


# Rendering class of a promoted value, shared by print, f-strings
# (grammar/template_string.w), var boxing (grammar/var_builtin.w) and
# the prelude's int-like argument checks.
enum value_class:
	VC_NONE    # functions, non-char pointers, structs, maps, sets, buffers
	VC_INT     # constants, int, fixed-width ints, bool, enums
	VC_CHAR    # a genuinely char-typed value
	VC_CSTR    # char*
	VC_STRING  # string
	VC_VAR     # var
	VC_F32     # float32
	VC_F64     # float64
	VC_LIST    # list[T]


int value_class(int got):
	if (got == 3): /* constant: an int-like value */
		return VC_INT
	if (got == 4): /* function */
		return VC_NONE
	int t = type_unqualified(got)
	if (type_is_string(t)):
		return VC_STRING
	if (type_is_char_pointer(t)):
		return VC_CSTR
	if (type_is_var(t)):
		return VC_VAR
	# Character literals are untyped constants (the got == 3 branch
	# above) and char arithmetic yields int.
	if (type_is_char(t)):
		return VC_CHAR
	if (type_float_kind(t) == 1):
		return VC_F32
	if (type_float_kind(t) == 2):
		return VC_F64
	if (type_is_list(t)):
		return VC_LIST
	if ((type_get_pointer_level(t) > 0) || (type_num_args(t) > 0)):
		return VC_NONE
	if (type_is_map(t) | type_is_set(t) | type_is_buffer(t)):
		return VC_NONE
	if ((type_get_kind(t) == type_kind_enum) || (t == type_unqualified(bool_type))):
		return VC_INT
	int size = type_get_size(t)
	if ((size == 1) || (size == 2) || (size == 4) || (size == 8)):
		return VC_INT
	return VC_NONE


int value_class_is_int_like(int vc):
	return (vc == VC_INT) || (vc == VC_CHAR)


# "<what> '<type>'" for an unsupported value: the shared tail of the
# print/f-string/len diagnostics.
void value_type_error(char* what, int got):
	diag_part(what)
	diag_part(c" '")
	if (got == 3):
		diag_part(c"constant")
	else if (got == 4):
		diag_part(c"function")
	else:
		print_error_type(got)
	error(c"'")


void print_unsupported(int t):
	value_type_error(c"unsupported print argument type:", t)


# Formatter for a scalar value: 0 int-like, 1 char* (and var, rendered
# through __w_var_to_cstr), 2 string, 3 float32, 13 char (a genuinely
# char-typed value prints as the character itself, while println('a')
# and println(c + 1) keep printing numerically). -1 asks the caller to
# take the list path.
int print_helper_for_type(int got):
	int vc = value_class(got)
	if (vc == VC_INT):
		return 0
	if ((vc == VC_CSTR) || (vc == VC_VAR)):
		return 1
	if (vc == VC_STRING):
		return 2
	if (vc == VC_CHAR):
		return 13
	if (vc == VC_F32):
		return 3
	if (vc == VC_F64):
		error(c"print does not support float64 yet")
	if (vc == VC_LIST):
		return -1
	print_unsupported(got)
	return 0


# Element formatter code for list printing, matching the f-string
# helper table: 2 char*, 3 int-like, 4 string.
int print_list_element_kind(int element_type):
	int t = type_unqualified(element_type)
	if (type_is_string(t)):
		return 4
	if (type_is_char_pointer(t)):
		return 2
	if (type_num_args(t) > 0):
		error(c"print supports lists of scalar elements only")
	if (type_float_kind(t)):
		error(c"print does not support float list elements yet")
	if (type_is_map(t) | type_is_set(t) | type_is_list(t)):
		error(c"print supports lists of scalar elements only")
	if (type_get_pointer_level(t) > 0):
		error(c"print supports lists of scalar elements only")
	return 3


# __w_print_nl()
void print_emit_nl():
	print_emit_helper_address(5)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_call_finish(s)


# helper(value) with the value in the given stack slot
void print_emit_call1(int helper, int value_slot):
	print_emit_helper_address(helper)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(value_slot)
	hash_call_finish(s)


# __w_print_list(list, kind)
void print_emit_call_list(int value_slot, int kind):
	print_emit_helper_address(4)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(value_slot)
	mov_eax_int(kind)
	push_eax()
	stack_pos = stack_pos + 1
	hash_call_finish(s)


# print(expr) / println(expr): the builtin's name is the current token
# and '(' directly follows it. Leaves ')' current for primary_expr's
# trailing get_token(). Returns void value.
int print_builtin_expr(int newline):
	get_token()
	expect(c"(")
	int base_stack = stack_pos
	# println() with no argument writes just the newline
	if (peek(c")")):
		if (newline == 0):
			error(c"print requires an argument")
		print_emit_nl()
		return type_value(type_lookup(c"void"))
	int got = expression()
	if (peek(c")") == 0):
		error(c"')' expected in print")
	got = promote(got)
	int helper = print_helper_for_type(got)
	if (type_is_var(type_unqualified(got))):
		var_emit_to_cstr()
	push_eax()
	stack_pos = stack_pos + 1
	int value_slot = stack_pos
	if (helper < 0):
		int element_type = type_list_element_type(type_unqualified(got))
		print_emit_call_list(value_slot, print_list_element_kind(element_type))
	else:
		print_emit_call1(helper, value_slot)
	if (newline):
		print_emit_nl()
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(type_lookup(c"void"))


# Prelude input helper index for the current token, or -1. These are
# ordinary functions in structures/prelude.w, reachable without an
# import so one-liner scripts can read stdin; any user-defined or
# imported symbol with the same name takes precedence.
int prelude_input_helper():
	if (peek(c"input")):
		return 6
	if (peek(c"read_all")):
		return 7
	if (peek(c"ints")):
		return 8
	return -1


int prelude_input_ready():
	if (nextc != '('):
		return 0
	if (prelude_input_helper() < 0):
		return 0
	if (sym_lookup(token) >= 0):
		return 0
	return 1


# input() / read_all() / ints() with no user symbol of that name in
# scope. Leaves ')' current for primary_expr's trailing get_token().
int prelude_input_expr():
	int helper = prelude_input_helper()
	get_token()
	expect(c"(")
	if (peek(c")") == 0):
		error(c"the prelude input helpers take no arguments")
	print_emit_helper_address(helper)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_call_finish(s)
	if (helper == 8):
		return type_value(type_get_list(type_lookup(c"int")))
	if (helper == 6):
		# input() returns the line as a UTF-8 string (issue #360)
		return type_value(type_lookup(c"string"))
	return type_value(type_lookup_pointer(c"char", 1))


# Prelude math helper index for the current token, or -1: bare
# max/min/abs call sites lower to the __w_ helpers in
# structures/prelude.w when no user symbol shadows the name (issue
# #360). len is handled separately below: it is a compile-time
# polymorphic length read, not a runtime helper (except the char*
# case, which borrows lib/lib.w's strlen).
int prelude_math_helper():
	if (peek(c"max")):
		return 9
	if (peek(c"min")):
		return 10
	if (peek(c"abs")):
		return 11
	return -1


# Prelude sequence helper index for the current token, or -1: bare
# any(l)/all(l) truthiness scans over a list of int-like elements
# (issue #360), lowered to __w_any/__w_all in structures/prelude.w and
# shadowed by user symbols exactly like max/min/abs.
int prelude_seq_helper():
	if (peek(c"any")):
		return 14
	if (peek(c"all")):
		return 15
	return -1


int prelude_math_ready():
	if (nextc != '('):
		return 0
	if ((prelude_math_helper() < 0) && (prelude_seq_helper() < 0) && (peek(c"len") == 0) && (peek(c"enum_name") == 0)):
		return 0
	if (sym_lookup(token) >= 0):
		return 0
	# A user generic function of the same name shadows too: its bare
	# call sites resolve through generic argument inference
	if (generic_def_lookup(token, 0) >= 0):
		return 0
	return 1


# Constants, enums, bool, char and the fixed-width ints all pass;
# floats, pointers, containers and aggregates are rejected (import
# lib.math or write the comparison out for anything wider).
void prelude_math_require_int(char* fn_name, int got):
	if (value_class_is_int_like(value_class(got))):
		return;
	diag_part(c"prelude '")
	diag_part(fn_name)
	value_type_error(c"' argument must be an int-like value:", got)


void prelude_len_unsupported(int got):
	value_type_error(c"unsupported len argument type:", got)


# len(x): compile-time polymorphic length. list/map/set and the
# buffers (string, slice, decayed fixed array) read their length word
# at container + word_size (the '.length' rule); char* calls strlen
# through the helper chain. Leaves ')' current for primary_expr's
# trailing get_token(). Returns an int rvalue.
int prelude_len_expr():
	get_token()
	expect(c"(")
	int base_stack = stack_pos
	int got = expression()
	if (peek(c")") == 0):
		error(c"')' expected in len")
	got = promote(got)
	if ((got == 3) || (got == 4)):
		prelude_len_unsupported(got)
	int t = type_unqualified(got)
	if (type_is_char_pointer(t)):
		push_eax()
		stack_pos = stack_pos + 1
		print_emit_call1(12, stack_pos)
		be_pop(stack_pos - base_stack)
		stack_pos = base_stack
	else if (type_is_list(t) | type_is_map(t) | type_is_set(t) | type_is_buffer(t)):
		add_eax_int32(word_size)
		promote_eax()
	else:
		prelude_len_unsupported(got)
	return type_value(type_lookup(c"int"))


# any/all take one list[T] whose elements are int-like (enums, bool,
# char and the fixed-width ints): elements read as words and test
# truthy. Floats, pointers, aggregates, nested containers and the other
# container shapes (map/set, buffers) are rejected — spell those loops
# out or use the list methods.
void prelude_seq_require_int_list(char* fn_name, int got):
	if (value_class(got) == VC_LIST):
		if (value_class_is_int_like(value_class(type_list_element_type(type_unqualified(got))))):
			return;
	diag_part(c"prelude '")
	diag_part(fn_name)
	value_type_error(c"' argument must be a list of int-like elements:", got)


# any(l) / all(l) with no user symbol of that name in scope: true when
# any/every element is truthy (any([]) is false, all([]) is true, the
# Python contract). Leaves ')' current for primary_expr's trailing
# get_token().
int prelude_seq_expr(int helper):
	char* fn_name = strclone(token)
	get_token()
	expect(c"(")
	int base_stack = stack_pos
	print_emit_helper_address(helper)
	push_eax()
	stack_pos = stack_pos + 1
	int got = expression()
	got = promote(got)
	prelude_seq_require_int_list(fn_name, got)
	push_eax()
	stack_pos = stack_pos + 1
	if (peek(c")") == 0):
		diag_part(c"')' expected in prelude '")
		diag_part(fn_name)
		error(c"'")
	hash_call_finish(base_stack)
	free(fn_name)
	return type_value(type_lookup(c"int"))


# max(a, b) / min(a, b) / abs(a) with no user symbol of that name in
# scope: parse and validate the arguments and call the prelude helper.
# Leaves ')' current for primary_expr's trailing get_token().
int prelude_math_call_expr(int helper):
	char* fn_name = strclone(token)
	get_token()
	expect(c"(")
	int base_stack = stack_pos
	print_emit_helper_address(helper)
	push_eax()
	stack_pos = stack_pos + 1
	int got = expression()
	got = promote(got)
	prelude_math_require_int(fn_name, got)
	push_eax()
	stack_pos = stack_pos + 1
	if (helper != 11):
		# max and min take a second argument; abs takes exactly one
		expect(c",")
		got = expression()
		got = promote(got)
		prelude_math_require_int(fn_name, got)
		push_eax()
		stack_pos = stack_pos + 1
	if (peek(c")") == 0):
		diag_part(c"')' expected in prelude '")
		diag_part(fn_name)
		error(c"'")
	hash_call_finish(base_stack)
	free(fn_name)
	return type_value(type_lookup(c"int"))


# Registry of every declared enum constant (type, name, value) in
# declaration order, filled by grammar/enum_declaration.w for
# enum_name() reflection. Redeclaring an enum (the REPL) drops its old
# constants first.
struct enum_constant_record:
	int type
	char* name
	int value


list[enum_constant_record] enum_constants


void enum_register_into(list[enum_constant_record] l, int type_index, char* name, int value):
	enum_constant_record rec
	rec.type = type_index
	rec.name = name
	rec.value = value
	l.push(rec)


void enum_register_constant(int type_index, char* name, int value):
	if (cast(int, enum_constants) == 0):
		enum_constants = new list[enum_constant_record]
	enum_register_into(enum_constants, type_index, name, value)


void enum_forget_constants(int type_index):
	if (cast(int, enum_constants) == 0):
		return;
	int found = 0
	int i = 0
	while (i < enum_constants.length):
		if (enum_constants[i].type == type_index):
			found = 1
		i = i + 1
	if (found == 0):
		return;
	list[enum_constant_record] kept = new list[enum_constant_record]
	i = 0
	while (i < enum_constants.length):
		if (enum_constants[i].type != type_index):
			enum_register_into(kept, enum_constants[i].type, enum_constants[i].name, enum_constants[i].value)
		i = i + 1
	enum_constants = kept


# enum_name(e): the declared name of an enum value as a char*. The
# enum's constants (the registry above) are emitted
# as an inline table of NUL-separated "value" / "name" pairs next to
# the call, and __w_enum_name scans it at runtime; a value no constant
# carries renders as its decimal digits. The first of several names
# sharing a value wins. Leaves ')' current for primary_expr's trailing
# get_token().
int prelude_enum_name_expr():
	get_token()
	expect(c"(")
	int base_stack = stack_pos
	int got = promote(expression())
	int t = type_canonical(type_unqualified(got))
	if ((got == 3) || (got == 4) || (type_get_kind(t) != type_kind_enum)):
		value_type_error(c"enum_name argument must be an enum value, got", got)
	if (peek(c")") == 0):
		error(c"')' expected in enum_name")
	push_eax()
	stack_pos = stack_pos + 1
	int value_slot = stack_pos
	int capacity = 16
	char* table_text = malloc(capacity)
	int length = 0
	int i = 0
	while ((cast(int, enum_constants) != 0) && (i < enum_constants.length)):
		if (type_canonical(enum_constants[i].type) == t):
			char* digits = itoa(enum_constants[i].value)
			char* name = enum_constants[i].name
			int need = length + strlen(digits) + strlen(name) + 3
			if (need > capacity):
				table_text = realloc(table_text, capacity, need * 2)
				capacity = need * 2
			strcpy(table_text + length, digits)
			length = length + strlen(digits) + 1
			strcpy(table_text + length, name)
			length = length + strlen(name) + 1
			free(digits)
		i = i + 1
	if (length + 1 > capacity):
		table_text = realloc(table_text, capacity, length + 1)
	# the final NUL (be_emit_inline_cstr adds it) ends the table
	table_text[length] = 0
	be_emit_inline_cstr(length, table_text)
	free(table_text)
	push_eax()
	stack_pos = stack_pos + 1
	int table_slot = stack_pos
	print_emit_helper_address(16)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(table_slot)
	hash_push_stack_slot(value_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(type_lookup_pointer(c"char", 1))


# Entry for the primary_expr branch: routes len, any/all and enum_name
# separately from the max/min/abs runtime helpers.
int prelude_math_expr():
	if (peek(c"len")):
		return prelude_len_expr()
	if (peek(c"enum_name")):
		return prelude_enum_name_expr()
	if (prelude_seq_helper() >= 0):
		return prelude_seq_expr(prelude_seq_helper())
	return prelude_math_call_expr(prelude_math_helper())


# Deferred on-demand import of the prelude runtime, called by the
# drivers at a top-level boundary once compilation of the user's files
# is done (grammar/lazy_runtime.w).
void prelude_finish_import():
	lazy_finish_import(print_rt)
