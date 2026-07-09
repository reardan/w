/*
Compiler lowering for the built-in polymorphic print/println
(docs/projects/golf_ergonomics.md).

print(x) writes x to stdout formatted by its static type: int-likes
(int, fixed-width ints, char, bool, enums) as decimals, char* and
string as their bytes, float32 through ftoa, var through its runtime
tag, and list[T] of scalar elements as '[a, b, c]'. println(x) appends
a newline; println() writes just the newline. Anything else (maps,
sets, structs, non-char pointers, float64) is a compile error.

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
int import_module(char* dotted);
void var_emit_to_cstr();


# Set when a compiled program used print/println or referenced one of
# the prelude input helpers; the drivers call prelude_finish_import()
# once compilation is done.
int print_builtin_needed

# Backpatch chain heads for the runtime helpers, indexed like
# print_fn_name; the encoding matches the 'U' symbol chains.
char* print_chains


int print_helper_count():
	return 9


char* print_fn_name(int i):
	if (i == 0):
		return c"__w_print_int"
	if (i == 1):
		return c"__w_print_cstr"
	if (i == 2):
		return c"__w_print_str"
	if (i == 3):
		return c"__w_print_float32"
	if (i == 4):
		return c"__w_print_list"
	if (i == 5):
		return c"__w_print_nl"
	if (i == 6):
		return c"input"
	if (i == 7):
		return c"read_all"
	return c"ints"


# Leave helper i's address in eax: directly when the runtime module is
# already compiled, through the helper's backpatch chain otherwise.
void print_emit_helper_address(int i):
	char* name = print_fn_name(i)
	if (sym_lookup(name) >= 0):
		sym_get_value(name)
		return;
	if (print_chains == 0):
		print_chains = malloc(print_helper_count() * 4)
		int j = 0
		while (j < print_helper_count()):
			save_int(print_chains + j * 4, 0)
			j = j + 1
	int head = load_int(print_chains + i * 4)
	if (head == 0):
		head = code_offset
	be_addr_slot_emit() /* mov $n,%eax (x86) / adrp+add pair (arm64) */
	be_addr_slot_write(codepos - 4, head)
	save_int(print_chains + i * 4, codepos + code_offset - 4)
	# pac=full: chain slots materialize a callee like sym_get_value does,
	# so the value needs the same signature (emitted after the chain
	# bookkeeping so the recorded cell stays the slot's add instruction).
	be_code_ptr_sign()


void print_unsupported(int t):
	diag_part(c"unsupported print argument type: '")
	if (t == 4):
		diag_part(c"function")
	else:
		print_error_type(t)
	error(c"'")


# Formatter for a scalar value: 0 int-like, 1 char*, 2 string,
# 3 float32. -1 asks the caller to try the container path.
int print_helper_for_type(int got):
	if (got == 3): /* constant: an int-like value */
		return 0
	if (got == 4): /* function */
		print_unsupported(got)
	int t = type_unqualified(got)
	if (type_is_string(t)):
		return 2
	if (type_is_char_pointer(t)):
		return 1
	# var renders through __w_var_to_cstr, then prints as a char*
	if (type_is_var(t)):
		return 1
	if (type_float_kind(t) == 1):
		return 3
	if (type_float_kind(t) == 2):
		error(c"print does not support float64 yet")
	if (type_is_list(t)):
		return -1
	if (type_get_pointer_level(t) > 0):
		print_unsupported(got)
	if (type_num_args(t) > 0):
		print_unsupported(got)
	if (type_is_map(t) | type_is_set(t)):
		print_unsupported(got)
	if (type_is_array(t) | type_is_slice(t)):
		print_unsupported(got)
	if (type_get_kind(t) == type_kind_enum):
		return 0
	if (t == type_unqualified(bool_type)):
		return 0
	int size = type_get_size(t)
	if ((size == 1) | (size == 2) | (size == 4) | (size == 8)):
		return 0
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
	print_builtin_needed = 1
	print_emit_helper_address(5)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_call_finish(s)


# helper(value) with the value in the given stack slot
void print_emit_call1(int helper, int value_slot):
	print_builtin_needed = 1
	print_emit_helper_address(helper)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(value_slot)
	hash_call_finish(s)


# __w_print_list(list, kind)
void print_emit_call_list(int value_slot, int kind):
	print_builtin_needed = 1
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
	print_builtin_needed = 1
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
	return type_value(type_lookup_pointer(c"char", 1))


void print_patch_chain(int i):
	int head = load_int(print_chains + i * 4)
	if (head == 0):
		return;
	int v = sym_address(print_fn_name(i))
	int p = head - code_offset
	while (p):
		int next = be_addr_slot_read(p) - code_offset
		be_addr_slot_write(p, v)
		p = next
	save_int(print_chains + i * 4, 0)


# Deferred on-demand import of the prelude runtime, called by the
# drivers at a top-level boundary once compilation of the user's files
# is done (the template_string_finish_import pattern).
void prelude_finish_import():
	if (print_builtin_needed == 0):
		return;
	import_module(c"structures.prelude")
	if (print_chains == 0):
		return;
	int i = 0
	while (i < print_helper_count()):
		print_patch_chain(i)
		i = i + 1
