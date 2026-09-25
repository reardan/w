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
void print_error_type(int type_index);


# The var runtime (structures/w_dynamic.w), imported on demand by
# var_finish_import(). Helper indexes: 0-2 box int/cstr/str, 3-5 unbox
# int/cstr/str, 6-9 add/sub/mul/div, 10 eq, 11 cmp, 12 to_cstr.
lazy_runtime* var_rt


void var_emit_helper_address(int i):
	if (cast(int, var_rt) == 0):
		var_rt = lazy_runtime_new(c"structures.w_dynamic", c"__w_var_box_int __w_var_box_cstr __w_var_box_str __w_var_unbox_int __w_var_unbox_cstr __w_var_unbox_str __w_var_add __w_var_sub __w_var_mul __w_var_div __w_var_eq __w_var_cmp __w_var_to_cstr")
	lazy_emit_helper(var_rt, i)


# Call helper i with the single argument in eax; the result stays in eax.
void var_emit_call1(int i):
	int base_stack = stack_pos
	int value_slot = push_slot()
	var_emit_helper_address(i)
	int s = stack_pos
	push_slot()
	push_slot_copy(value_slot)
	rt_call_end(s)
	pop_to(base_stack)


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
	error_type(c"cannot convert var to '", t, c"'")


# Box helper index for a promoted non-var value: 0 int-like (int,
# fixed-width ints, char, bool, enums, constants), 1 char*, 2 string;
# -1 when the type cannot be boxed.
int var_box_helper_for_type(int got):
	int vc = value_class(got)
	if (value_class_is_int_like(vc)):
		return 0
	if (vc == VC_CSTR):
		return 1
	if (vc == VC_STRING):
		return 2
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
	int base_stack = stack_pos
	int right_value_slot = push_slot()
	mov_eax_ebx()
	if (type_is_var(type_unqualified(left_type)) == 0):
		int left_helper = var_box_helper_for_type(left_type)
		if (left_helper < 0):
			var_box_unsupported(left_type)
		var_emit_call1(left_helper)
	int left_slot = push_slot()
	load_slot(right_value_slot)
	if (type_is_var(type_unqualified(right_type)) == 0):
		int right_helper = var_box_helper_for_type(right_type)
		if (right_helper < 0):
			var_box_unsupported(right_type)
		var_emit_call1(right_helper)
	int right_slot = push_slot()
	var_emit_helper_address(i)
	int s = stack_pos
	push_slot()
	push_slot_copy(left_slot)
	push_slot_copy(right_slot)
	rt_call_end(s)
	pop_to(base_stack)


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
	push_slot()
	pop_ebx_slot()
	mov_eax_int(0)
	alu_cmp_set(setcc_opcode)
	return type_value(bool_type)


# Deferred on-demand import of the var runtime. Called by the drivers
# (link_impl, the REPL, wdbg) at a top-level boundary once compilation
# of the user's files is done (grammar/lazy_runtime.w).
void var_finish_import():
	lazy_finish_import(var_rt)
