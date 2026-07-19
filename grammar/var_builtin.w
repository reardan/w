/*
Compiler lowering for the dynamic 'var' type.

A var value is one word: a pointer to a heap-allocated tagged box (tags:
null, int, char*, string). coerce() delegates to var_coerce() whenever
either side is var, which emits calls to the __w_var_box and __w_var_unbox
helpers in structures/w_dynamic.w; the binary expression layers call
var_binary_arithmetic()/var_binary_compare_*() to dispatch + - * / and
the comparisons at runtime when either operand is var.

structures/w_dynamic.w is not auto-imported, so the module is imported
on demand like the template string runtime (grammar/template_string.w):
call sites emitted before the import go through per-helper backpatch
chains, and the drivers call var_finish_import() at a top-level boundary
once compilation of the user's files is done.

Design notes: docs/projects/dynamic_var.md.
*/
int import_module(char* dotted);
void print_error_type(int type_index);


# Set when a compiled program used var; the drivers call
# var_finish_import() once compilation is done.
int var_needed

# Backpatch chain heads for the runtime helpers, indexed like
# var_fn_name. Encoding matches the 'U' symbol chains: each mov-imm
# slot holds the previous slot's absolute address, code_offset ends the
# chain. A symbol-table forward declaration would not survive
# function_definition's scope truncation, so the chains live here.
char* var_chains


int var_helper_count():
	return 13


char* var_fn_name(int i):
	if (i == 0):
		return c"__w_var_box_int"
	if (i == 1):
		return c"__w_var_box_cstr"
	if (i == 2):
		return c"__w_var_box_str"
	if (i == 3):
		return c"__w_var_unbox_int"
	if (i == 4):
		return c"__w_var_unbox_cstr"
	if (i == 5):
		return c"__w_var_unbox_str"
	if (i == 6):
		return c"__w_var_add"
	if (i == 7):
		return c"__w_var_sub"
	if (i == 8):
		return c"__w_var_mul"
	if (i == 9):
		return c"__w_var_div"
	if (i == 10):
		return c"__w_var_eq"
	if (i == 11):
		return c"__w_var_cmp"
	return c"__w_var_to_cstr"


# Leave helper i's address in eax: directly when the runtime module is
# already compiled (the program imported structures.w_dynamic itself),
# through the helper's backpatch chain otherwise.
void var_emit_helper_address(int i):
	char* name = var_fn_name(i)
	if (sym_lookup(name) >= 0):
		sym_get_value(name)
		return;
	if (var_chains == 0):
		var_chains = malloc(var_helper_count() * 4)
		int j = 0
		while (j < var_helper_count()):
			save_int(var_chains + j * 4, 0)
			j = j + 1
	int head = load_int(var_chains + i * 4)
	if (head == 0):
		head = code_offset
	be_addr_slot_emit() /* mov $n,%eax (x86) / adrp+add pair (arm64) */
	be_addr_slot_write(codepos - 4, head)
	save_int(var_chains + i * 4, codepos + code_offset - 4)


# Call helper i with the single argument in eax; the result stays in eax.
void var_emit_call1(int i):
	var_needed = 1
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int value_slot = stack_pos
	var_emit_helper_address(i)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(value_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack


void var_box_unsupported(int t):
	# The float "value" pseudo-types would leak their internal names
	if (t == float32_value_type):
		t = float32_type
	if (t == float64_value_type):
		t = float64_type
	diag_part(c"cannot convert '")
	if (t == 4):
		diag_part(c"function")
	else:
		print_error_type(t)
	error(c"' to var")


void var_unbox_unsupported(int t):
	diag_part(c"cannot convert var to '")
	print_error_type(t)
	error(c"'")


# Box helper index for a promoted non-var value: 0 int-like (int,
# fixed-width ints, char, bool, enums, constants), 1 char*, 2 string;
# -1 when the type cannot be boxed.
int var_box_helper_for_type(int got):
	if (got == 3): /* constant: already a plain value */
		return 0
	if (got == 4): /* function */
		return -1
	int t = type_unqualified(got)
	if (type_is_string(t)):
		return 2
	if (type_is_char_pointer(t)):
		return 1
	if (type_float_kind(t)):
		return -1
	if (type_get_pointer_level(t) > 0):
		return -1
	if (type_num_args(t) > 0):
		return -1
	if (type_is_map(t) | type_is_set(t) | type_is_list(t)):
		return -1
	if (type_is_array(t) | type_is_slice(t)):
		return -1
	int size = type_get_size(t)
	if ((size == 1) || (size == 2) || (size == 4) || (size == 8)):
		return 0
	return -1


# Emit the conversion between var and a non-var type; the value is in
# eax. Called from coerce() when either side is var (types already
# unqualified). Unsupported conversions are compile-time errors.
void var_coerce(int want, int got):
	if (type_is_var(want) & type_is_var(got)):
		return; /* pointer copy: aliasing */
	if ((want == 3) || (want == 4)):
		return;
	if (type_is_var(want)):
		int helper = var_box_helper_for_type(got)
		if (helper < 0):
			var_box_unsupported(got)
		var_emit_call1(helper)
		return;
	# got is var: unbox into want
	if (type_is_string(want)):
		var_emit_call1(5)
		return;
	if (type_is_char_pointer(want)):
		var_emit_call1(4)
		return;
	if (type_is_void_pointer(want)):
		return; /* escape hatch: expose the raw box pointer */
	if (var_box_helper_for_type(want) != 0):
		var_unbox_unsupported(want)
	var_emit_call1(3)
	if (want == type_unqualified(bool_type)):
		alu_test_set(0x95) /* setne: normalize the unboxed word */


# Convert the var box in eax to a char* rendering (template strings).
void var_emit_to_cstr():
	var_emit_call1(12)


# 1 when a binary operator needs runtime var dispatch (either promoted
# operand is var).
int var_binary_operands(int left_type, int right_type):
	if (type_is_var(type_unqualified(left_type))):
		return 1
	return type_is_var(type_unqualified(right_type))


# Shared lowering for var binary operators: left operand in ebx, right
# in eax (both promoted). Boxes non-var operands, then calls helper i
# with (left, right); the result stays in eax.
void var_binary_call(int left_type, int right_type, int i):
	var_needed = 1
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int right_value_slot = stack_pos
	mov_eax_ebx()
	if (type_is_var(type_unqualified(left_type)) == 0):
		int left_helper = var_box_helper_for_type(left_type)
		if (left_helper < 0):
			var_box_unsupported(left_type)
		var_emit_call1(left_helper)
	push_eax()
	stack_pos = stack_pos + 1
	int left_slot = stack_pos
	mov_eax_esp_plus((stack_pos - right_value_slot) << word_size_log2)
	if (type_is_var(type_unqualified(right_type)) == 0):
		int right_helper = var_box_helper_for_type(right_type)
		if (right_helper < 0):
			var_box_unsupported(right_type)
		var_emit_call1(right_helper)
	push_eax()
	stack_pos = stack_pos + 1
	int right_slot = stack_pos
	var_emit_helper_address(i)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(left_slot)
	hash_push_stack_slot(right_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack


# Runtime-dispatched + - * / when either operand is var: box the non-var
# operand and call the matching __w_var_* helper. Returns the result
# type ("var value") or 0 when neither operand is var.
int var_binary_arithmetic(int left_type, int right_type, int op):
	if (var_binary_operands(left_type, right_type) == 0):
		return 0
	int i = 6
	if (op == '-'):
		i = 7
	if (op == '*'):
		i = 8
	if (op == '/'):
		i = 9
	var_binary_call(left_type, right_type, i)
	return type_value(var_type)


# ==/!= on var operands: __w_var_eq compares same-tag values (content
# compare for text tags); negate inverts for '!='. Returns bool value
# type or 0 when neither operand is var.
int var_binary_compare_eq(int left_type, int right_type, int negate):
	if (var_binary_operands(left_type, right_type) == 0):
		return 0
	var_binary_call(left_type, right_type, 10)
	if (negate):
		alu_test_set(0x94) /* sete: invert the 0/1 result */
	return type_value(bool_type)


# < <= > >= on var operands: __w_var_cmp returns -1/0/1 (ints only,
# traps otherwise); compare that against 0 with the operator's setcc.
# Returns bool value type or 0 when neither operand is var.
int var_binary_compare_order(int left_type, int right_type, int setcc_opcode):
	if (var_binary_operands(left_type, right_type) == 0):
		return 0
	var_binary_call(left_type, right_type, 11)
	push_eax()
	stack_pos = stack_pos + 1
	pop_ebx()
	stack_pos = stack_pos - 1
	mov_eax_int(0)
	alu_cmp_set(setcc_opcode)
	return type_value(bool_type)


void var_patch_chain(int i):
	int head = load_int(var_chains + i * 4)
	if (head == 0):
		return;
	int v = sym_address(var_fn_name(i))
	int p = head - code_offset
	while (p):
		int next = be_addr_slot_read(p) - code_offset
		be_addr_slot_write(p, v)
		p = next
	save_int(var_chains + i * 4, 0)


# Deferred on-demand import of the var runtime. Called by the drivers
# (link_impl, the REPL, wdbg) at a top-level boundary once compilation
# of the user's files is done; import_module de-duplicates repeat calls.
# After the module has defined the helpers, resolve the call sites that
# were emitted before the import.
void var_finish_import():
	if (var_needed == 0):
		return;
	import_module(c"structures.w_dynamic")
	if (var_chains == 0):
		return;
	int i = 0
	while (i < var_helper_count()):
		var_patch_chain(i)
		i = i + 1
