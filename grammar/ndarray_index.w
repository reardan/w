/*
Comma-separated ndarray index sugar (docs/projects/ndarray.md Stage 5):

	m[i, j]        ->  ndf_at2(m, i, j)                      (read)
	m[i, j] = v    ->  ndf_set2(m, i, j, v)                  (assignment)
	m[i, j] += v   ->  ndf_set2(m, i, j, ndf_at2(m, i, j) + v)

Typed-builtin lowering, following the map/list builtin precedent
(grammar/hash_builtin.w, grammar/list_builtin.w): no operator
overloading and no new descriptor kind. The '[' handler in
grammar/postfix_expr.w dispatches here when a ',' follows the first
index expression and the indexed expression's static type is one of
the lib/ndarray.w / lib/ndarray64.w structs -- ndf, ndi or ndf64, as a
value, an lvalue or a single pointer (either way eax holds the
struct's address, which is exactly the accessors' ndX* receiver).

The receiver and every index value are parked in recorded stack slots
and the element access becomes a pending pseudo-lvalue, the
hash_index_* discipline: expression() claims a following '='
(ndX_setN) or compound operator (ndX_atN + op + ndX_setN, receiver and
indices evaluated exactly once); every read position finalizes through
promote() or expression() into the ndX_atN call. The emitted calls are
byte-for-byte what the spelled-out accessor calls produce -- same
argument order, same per-axis asserts -- so m[i, j] and
ndf_at2(m, i, j) are interchangeable.

The index count (2-4) is checked at compile time -- it selects the
accessor arity. Rank itself lives in the descriptor at run time (the
struct type does not carry it), so a rank mismatch keeps the
accessors' own per-axis extent asserts. Dispatch is by struct name and
the lowering is a plain symbol lookup, so indexing a struct named
ndf/ndi/ndf64 without the matching _atN/_setN accessor in scope is a
compile error naming the missing accessor.

A single index is NOT claimed here: m[i] on any type keeps its
existing meaning (raw pointer/element indexing), so rank-1 arrays
spell ndf_at1/ndf_set1 out.

This file is compiled by the committed seed: only seed-understood
syntax here. The 'm[i, j]' spelling itself is exercised only under
tests/ until a SEEDS bump (docs/release.md).
*/

# Defined later in the grammar; the single-pass compiler needs the
# declarations up front (grammar/hash_builtin.w precedent).
int expression();
int promote(int type);
void coerce(int want, int got);
int types_compatible_with_expression(int want, int got);
void warn_type_mismatch(char* context, int want, int got);
void print_error_type(int type_index);
int compound_assign_apply(int op, int left_type, int right_type);
int var_binary_operands(int left_type, int right_type);


# Pending ndarray element, the hash_index_* discipline: the receiver
# (the ndX struct's address) and the index values sit in recorded
# stack slots until expression()/promote() decides read or write. The
# slot fields are only valid while nd_index_pending is set; a nested
# index inside a later consumer's expression re-fills them (the
# consumers snapshot what they need into locals first).
int nd_index_pending
int nd_index_base_stack
int nd_index_recv_slot
int nd_index_slot0
int nd_index_slot1
int nd_index_slot2
int nd_index_slot3
int nd_index_count
int nd_index_struct


# The ndarray struct type behind an indexable expression: 'type' is an
# ndf/ndi/ndf64 struct (value or lvalue) or a single pointer to one.
# Returns the struct's type index, or -1 when the comma-index sugar
# does not apply.
int ndarray_index_struct(int type):
	if ((type == 3) || (type == 4)):
		return -1
	int t = type_unqualified(type)
	if (t < 0):
		return -1
	int level = type_get_pointer_level(t)
	if (level == 1):
		int base = type_lookup_previous_pointer(t)
		if (base < 0):
			return -1
		t = type_unqualified(base)
		if (t < 0):
			return -1
	else if (level != 0):
		return -1
	if (type_num_args(t) == 0):
		return -1
	char* name = type_get_name(t)
	if (strcmp(name, c"ndf") == 0):
		return t
	if (strcmp(name, c"ndi") == 0):
		return t
	if (strcmp(name, c"ndf64") == 0):
		return t
	return -1


# Accessor symbol name for the pending element: ndf_at2, ndi_set3, ...
# op is c"_at" or c"_set"; the caller frees the result.
char* ndarray_accessor_name(char* op):
	char* prefix = strjoin(type_get_name(nd_index_struct), op)
	char* name = strjoin(prefix, itoa(nd_index_count))
	free(prefix)
	return name


# Look up the accessor the pending element lowers to; a missing symbol
# is a compile error (a struct merely NAMED ndf/ndi/ndf64 is not an
# ndarray -- the lib.ndarray accessor family is the contract).
int ndarray_accessor_sym(char* op):
	char* name = ndarray_accessor_name(op)
	int sym = sym_lookup(name)
	if (sym < 0):
		diag_part(c"ndarray index requires accessor '")
		diag_part(name)
		error(c"' in scope")
	free(name)
	return sym


# One parsed index value (promoted, in eax): coerce and check it
# against the accessors' int parameter, exactly like the spelled-out
# call would.
void ndarray_check_index(int got_type):
	int int_type = type_lookup(c"int")
	coerce(int_type, got_type)
	if (types_compatible_with_expression(int_type, got_type) == 0):
		warn_type_mismatch(c"ndarray index", int_type, got_type)


# Push the parked receiver and index slots as call arguments, oldest
# first (the accessors' parameter order).
void nd_push_index_args(int recv_slot, int slot0, int slot1, int slot2, int slot3, int count):
	hash_push_stack_slot(recv_slot)
	hash_push_stack_slot(slot0)
	hash_push_stack_slot(slot1)
	if (count >= 3):
		hash_push_stack_slot(slot2)
	if (count >= 4):
		hash_push_stack_slot(slot3)


# base[i, j(, k(, l))]: entered from the '[' handler in
# grammar/postfix_expr.w with the receiver (the struct's address)
# parked at recv_slot, the first index value promoted in eax and ','
# as the current token. Parses the remaining indices, parks
# everything and returns the element type as a pending pseudo-lvalue.
int ndarray_index_suffix(int type, int recv_slot, int first_index_type):
	int nd_struct = ndarray_index_struct(type)
	if (nd_struct < 0):
		diag_part(c"comma-separated indexing requires an ndarray (ndf, ndi or ndf64), got '")
		print_error_type(type)
		error(c"'")
	ndarray_check_index(first_index_type)
	push_eax()
	stack_pos = stack_pos + 1
	int slot0 = stack_pos
	int slot1 = 0
	int slot2 = 0
	int slot3 = 0
	int count = 1
	while (accept(c",")):
		if (count >= 4):
			error(c"ndarray index supports at most 4 indices")
		int got = promote(expression())
		ndarray_check_index(got)
		push_eax()
		stack_pos = stack_pos + 1
		if (count == 1):
			slot1 = stack_pos
		else if (count == 2):
			slot2 = stack_pos
		else:
			slot3 = stack_pos
		count = count + 1
	expect(c"]")
	# Commit the pending state only now: an index expression above may
	# itself have parked and finalized a nested pending element, and
	# these globals must describe THIS element when the consumer reads
	# them.
	nd_index_struct = nd_struct
	nd_index_count = count
	nd_index_recv_slot = recv_slot
	nd_index_slot0 = slot0
	nd_index_slot1 = slot1
	nd_index_slot2 = slot2
	nd_index_slot3 = slot3
	nd_index_base_stack = recv_slot - 1
	nd_index_pending = 1
	# The element type is the read accessor's declared return type; it
	# also validates the accessor family exists at all, read or write.
	int at_sym = ndarray_accessor_sym(c"_at")
	return load_int(table + at_sym + 6)


# Read position: lower the pending element to ndX_atN(recv, i...). The
# call result (the element value) stays in eax.
int nd_finish_pending_read():
	int at_sym = ndarray_accessor_sym(c"_at")
	int declared_return = load_int(table + at_sym + 6)
	nd_index_pending = 0
	char* at_name = ndarray_accessor_name(c"_at")
	sym_get_value(at_name)
	free(at_name)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	nd_push_index_args(nd_index_recv_slot, nd_index_slot0, nd_index_slot1, nd_index_slot2, nd_index_slot3, nd_index_count)
	hash_call_finish(s)
	be_pop(stack_pos - nd_index_base_stack)
	stack_pos = nd_index_base_stack
	return type_value(declared_return)


# m[i, j] = rhs: lower to ndX_setN(recv, i..., rhs). Like '=', the
# expression yields the stored value.
int nd_finish_pending_assignment():
	int saved_recv = nd_index_recv_slot
	int saved_slot0 = nd_index_slot0
	int saved_slot1 = nd_index_slot1
	int saved_slot2 = nd_index_slot2
	int saved_slot3 = nd_index_slot3
	int saved_count = nd_index_count
	int saved_base = nd_index_base_stack
	int set_sym = ndarray_accessor_sym(c"_set")
	char* set_name = ndarray_accessor_name(c"_set")
	nd_index_pending = 0
	# The value parameter follows the receiver and the indices.
	int value_type = sym_param_type(set_sym, saved_count + 1)
	int got_type = expression()
	got_type = promote(got_type)
	if (value_type >= 0):
		coerce(value_type, got_type)
		if (types_compatible_with_expression(value_type, got_type) == 0):
			warn_type_mismatch(c"ndarray assignment", value_type, got_type)
	push_eax()
	stack_pos = stack_pos + 1
	int value_slot = stack_pos
	sym_get_value(set_name)
	free(set_name)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	nd_push_index_args(saved_recv, saved_slot0, saved_slot1, saved_slot2, saved_slot3, saved_count)
	hash_push_stack_slot(value_slot)
	hash_call_finish(s)
	mov_eax_esp_plus((stack_pos - value_slot) << word_size_log2)
	be_pop(stack_pos - saved_base)
	stack_pos = saved_base
	return type_value(value_type)


# m[i, j] op= rhs: the receiver and indices already sit in the parked
# slots, so the ndX_atN read and the ndX_setN write reuse them and
# every operand is evaluated exactly once. 'op' is the marker
# compound_assign_op() returned; the op token has been consumed.
int nd_finish_pending_compound(int op):
	int saved_recv = nd_index_recv_slot
	int saved_slot0 = nd_index_slot0
	int saved_slot1 = nd_index_slot1
	int saved_slot2 = nd_index_slot2
	int saved_slot3 = nd_index_slot3
	int saved_count = nd_index_count
	int saved_base = nd_index_base_stack
	int at_sym = ndarray_accessor_sym(c"_at")
	int set_sym = ndarray_accessor_sym(c"_set")
	int value_type = load_int(table + at_sym + 6)
	char* at_name = ndarray_accessor_name(c"_at")
	char* set_name = ndarray_accessor_name(c"_set")
	nd_index_pending = 0

	# Load the current element; the parked slots stay for the store.
	sym_get_value(at_name)
	free(at_name)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	nd_push_index_args(saved_recv, saved_slot0, saved_slot1, saved_slot2, saved_slot3, saved_count)
	hash_call_finish(s)

	# Same shape the scalar path feeds compound_assign_apply: loaded
	# left value on top of the stack, promoted right value in eax.
	int left_type = type_value(value_type)
	push_eax()
	stack_pos = stack_pos + 1
	int right_type = promote(expression())
	if (var_binary_operands(left_type, right_type)):
		error(c"compound assignment does not support var operands")
	int result_type = compound_assign_apply(op, left_type, right_type)
	coerce(value_type, result_type)
	if (types_compatible_with_expression(value_type, result_type) == 0):
		warn_type_mismatch(c"ndarray assignment", value_type, result_type)

	# Store back through the same receiver/index slots.
	push_eax()
	stack_pos = stack_pos + 1
	int value_slot = stack_pos
	sym_get_value(set_name)
	free(set_name)
	s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	nd_push_index_args(saved_recv, saved_slot0, saved_slot1, saved_slot2, saved_slot3, saved_count)
	hash_push_stack_slot(value_slot)
	hash_call_finish(s)

	# Like '=', the expression yields the stored value.
	mov_eax_esp_plus((stack_pos - value_slot) << word_size_log2)
	be_pop(stack_pos - saved_base)
	stack_pos = saved_base
	return type_value(value_type)


int nd_finalize_pending_read_if_needed(int type):
	if (nd_index_pending):
		return nd_finish_pending_read()
	return type
