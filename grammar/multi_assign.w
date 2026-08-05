/*
Parallel assignment statement (issue #360 item 6):

    lv1, lv2[, lv3 ...] = e1, e2[, e3 ...]

Statement position only, the same flag discipline as postfix '++'
(grammar/increment.w): statement()'s expression fallback (and the REPL's
bare-expression path) sets increment_statement_context, expression()
consumes it on entry, and only then does a ',' after the first
conditional-expr dispatch here. A nested expression() call (a call
argument, a case label, an 'if' condition, the right side of '=') never
sees the flag, so a ',' there still belongs to the enclosing construct.

Both sides must list the same number of elements; a mismatch is a
compile error naming both counts. Every right-hand expression is
evaluated into a stack temporary BEFORE any store happens, then the
stores run left to right — so 'a, b = b, a' swaps and 'a, b = b, a + b'
reads the old values on the right. Each pair type-checks like the
matching plain '=' (same coerce, same frozen mismatch warning).

Excluded on purpose (v1, statement-level sugar only):
- declaration forms: 'int a, b = 1, 2' and 'a, b := 1, 2' stay errors;
- map/set elements on the left ('m[k], x = ...'): the pending-slot
  write path (grammar/hash_builtin.w) would need its own deferred
  emission; spell them as separate statements. ndarray elements
  ('a[i, j], x = ...', grammar/ndarray_index.w) are rejected for the
  same reason;
- whole-struct targets: a struct's "value" is its address, so a parked
  address is no temporary at all and 's1, s2 = s2, s1' would alias
  instead of swap; scalar and pointer targets (fields included) work.

Deferred statements re-parse through bare expression() at function
exits (grammar/defer.w), which is expression position: 'defer a, b =
...' is rejected there like 'defer x++' is.

This file is compiled by the committed seed: only seed-understood
syntax here. The 'a, b = ...' spelling itself is exercised only under
tests/ until a SEEDS bump (docs/release.md).
*/

# Defined later in the grammar (grammar/expression.w); the single-pass
# compiler needs the declarations up front.
int expression();
void assign_store(int type);


# Per-statement scratch, grown on demand and reused for the compile's
# lifetime. Parsing is strictly sequential and a multi-assignment can
# only start at statement position, so a right-hand expression can
# never contain another one — the buffers are never live twice.
int* multi_assign_lhs_types   # declared type of each target lvalue
int* multi_assign_lhs_slots   # stack_pos of each parked target address
int* multi_assign_rhs_slots   # stack_pos of each parked value temporary
int multi_assign_capacity


# Entries are word-sized ints, so sizes use __word_size__ (not 4) —
# see code_generator/x86.w's ctrl_stack_reserve for the f13ab7f lesson.
void multi_assign_reserve(int count):
	if (count <= multi_assign_capacity):
		return;
	int old_bytes = multi_assign_capacity * __word_size__
	if (multi_assign_capacity == 0):
		multi_assign_capacity = 8
	while (multi_assign_capacity < count):
		multi_assign_capacity = multi_assign_capacity << 1
	int new_bytes = multi_assign_capacity * __word_size__
	if (old_bytes == 0):
		multi_assign_lhs_types = cast(int*, malloc(new_bytes))
		multi_assign_lhs_slots = cast(int*, malloc(new_bytes))
		multi_assign_rhs_slots = cast(int*, malloc(new_bytes))
	else:
		multi_assign_lhs_types = cast(int*, realloc(multi_assign_lhs_types, old_bytes, new_bytes))
		multi_assign_lhs_slots = cast(int*, realloc(multi_assign_lhs_slots, old_bytes, new_bytes))
		multi_assign_rhs_slots = cast(int*, realloc(multi_assign_rhs_slots, old_bytes, new_bytes))


# The same target checks the '=' branch of expression() performs, plus
# the two v1 exclusions documented above. The parsed lvalue's address is
# in eax, untouched; 'type' is its declared type.
void multi_assign_check_target(int type):
	if (hash_index_pending):
		error(c"multi-assignment does not support map or set elements")
	if (nd_index_pending):
		error(c"multi-assignment does not support ndarray elements")
	if (expression_lhs_readonly):
		error(c"cannot assign to read-only buffer field")
	if ((type_is_value(type)) || (type == 3) || (type == 4)):
		error(c"assignment target is not assignable")
	if (type_is_const(type)):
		error(c"assignment to const")
	if (type_num_args(type_canonical(type)) > 0):
		error(c"multi-assignment does not support struct values")


# Entered from expression() with the first target already parsed (its
# address in eax, 'first_type' its type) and ',' as the current token.
# Parses the rest of the statement. Like '=', eax ends holding the last
# stored value and the returned type is that value's type — a value
# type, so the REPL's echo promote() never emits a stray load.
int multi_assign(int first_type):
	int entry_stack = stack_pos
	int lhs_count = 0
	int type = first_type
	while (1):
		multi_assign_check_target(type)
		multi_assign_reserve(lhs_count + 1)
		multi_assign_lhs_types[lhs_count] = type
		push_eax()
		stack_pos = stack_pos + 1
		multi_assign_lhs_slots[lhs_count] = stack_pos
		lhs_count = lhs_count + 1
		if (accept(c",") == 0):
			break
		expression_lhs_readonly = 0
		type = conditional_expr()
	expect(c"=")
	expression_lhs_readonly = 0

	# Right side: every element is evaluated and parked before any
	# store. Target i's type is already known (the left side parsed
	# first), so each element is coerced and checked at parse time and
	# the store phase below is pure data movement.
	int rhs_count = 0
	int more = 1
	while (more):
		# Recursion-depth guard (compiler/tokenizer.w): same counter,
		# limit and message as expression()'s '=' branch — each element
		# recurses expression() directly.
		expr_nesting_depth = expr_nesting_depth + 1
		if (expr_nesting_depth > 1000):
			error(c"expression nesting too deep")
		int got = promote(expression())
		expr_nesting_depth = expr_nesting_depth - 1
		if (rhs_count < lhs_count):
			int want = multi_assign_lhs_types[rhs_count]
			coerce(want, got)
			if (types_compatible_with_expression(want, got) == 0):
				warn_type_mismatch(c"assignment", want, got)
		multi_assign_reserve(rhs_count + 1)
		push_eax()
		stack_pos = stack_pos + 1
		multi_assign_rhs_slots[rhs_count] = stack_pos
		rhs_count = rhs_count + 1
		if (accept(c",") == 0):
			more = 0
	if (rhs_count != lhs_count):
		diag_part(c"multi-assignment arity mismatch: ")
		diag_part(itoa(lhs_count))
		diag_part(c" targets but ")
		diag_part(itoa(rhs_count))
		error(c" values")

	# Store phase, left to right. Slots are read esp-relative through
	# their recorded stack_pos: a call inside a later element may have
	# parked its own words (a struct return buffer) between ours, and
	# stack_pos-based offsets stay exact regardless.
	int i = 0
	while (i < lhs_count):
		mov_eax_esp_plus((stack_pos - multi_assign_rhs_slots[i]) << word_size_log2)
		mov_ebx_esp_plus((stack_pos - multi_assign_lhs_slots[i]) << word_size_log2)
		assign_store(multi_assign_lhs_types[i])
		i = i + 1

	# Unlike '=' (whose result can point into a buried struct-return
	# buffer), nothing of this statement's value points into the parked
	# span once the stores ran: pop all of it, buried words included.
	be_pop(stack_pos - entry_stack)
	stack_pos = entry_stack
	return type_value(multi_assign_lhs_types[lhs_count - 1])
