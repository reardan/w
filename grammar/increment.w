/*
'++' and '--' increment/decrement statements (issue #103,
docs/projects/increment_decrement.md).

v1 is statement-position only: 'x++', 'x--', '++x' and '--x' are
statements, each pure sugar for 'x += 1' / 'x -= 1' through the same
compound-assignment lowering (compound_assign_apply), so every '+= 1'
behavior carries over unchanged — including pointer stepping by raw
BYTES, not sizeof(T) (test_compound_pointer_arithmetic in
tests/compound_assign_test.w states that contract for '+='). There is
no expression form and no pre/post value distinction: '++'/'--'
inside a larger expression is a compile error
(increment_expression_error), and a map/set element operand
('m[k]++') is rejected too — the pending-slot read/write path would
need its own emission; spell it 'm[k] += 1'.

Statement recognition has two halves (grammar/statement.w):
- prefix: a statement starting with '++'/'--' dispatches to
  increment_prefix_statement(), like the other keyword statements;
- postfix: statement()'s expression fallback sets
  increment_statement_context before calling expression(), which
  consumes the flag on entry and only then claims a trailing
  '++'/'--'. A nested expression() call (a call argument, an 'if'
  condition, the right side of '=') never sees the flag, so the
  statement-only restriction is real rather than advisory.

Deferred statements re-parse through bare expression() at function
exits (grammar/defer.w), which is expression position: 'defer x++' is
rejected like any other embedded use.

This file is compiled by the committed seed: only seed-understood
syntax here. The '++'/'--' spelling itself is exercised only under
tests/ until a SEEDS bump (docs/release.md).
*/

# Defined later in the grammar (grammar/expression.w); the single-pass
# compiler needs the declarations up front.
int compound_assign_apply(int op, int left_type, int right_type);
void assign_store(int type);


# 1 while the next expression() call parses a full expression statement
# and may claim a trailing '++'/'--'; consumed (cleared) by
# expression() on entry.
int increment_statement_context


# '+' when the current token is '++', '-' when it is '--', 0 otherwise
# — the marker shape compound_assign_op() uses.
int increment_op():
	if (peek(c"++")):
		return '+'
	if (peek(c"--")):
		return '-'
	return 0


# Frozen diagnostic for '++'/'--' in expression position, shared by the
# prefix (grammar/unary_expression.w) and postfix (grammar/expression.w)
# parses. Also the message behind the old double-unary reading of
# '++x'/'--x', which lexes as one token since #103.
void increment_expression_error():
	diag_part(c"'")
	diag_part(token)
	diag_part(c"' is a statement and cannot be used inside an expression")
	error(c"")


# Shared lowering for both statement forms. The operand has been parsed
# (lvalue address in eax, 'type' its declared type) and the '++'/'--'
# token consumed. Feeds compound_assign_apply an immediate 1 instead of
# a parsed right-hand side — otherwise byte-for-byte the compound
# assignment sequence in expression(); eax ends holding the stored
# value, and the assignability checks and messages are the same ones
# '+= 1' would produce.
int increment_apply(int op, int type):
	if (hash_index_pending):
		error(c"'++' and '--' are not supported on map or set elements")
	if (expression_lhs_readonly):
		error(c"cannot assign to read-only buffer field")
	if ((type_is_value(type)) | (type == 3) | (type == 4)):
		error(c"assignment target is not assignable")
	if (type_is_const(type)):
		error(c"assignment to const")
	if (type_num_args(type_canonical(type)) > 0):
		error(c"compound assignment is not supported on struct values")
	if (type_is_buffer(type_canonical(type))):
		error(c"compound assignment is not supported on string, array or slice values")
	expression_lhs_readonly = 0
	push_eax()  # lhs address, kept for the final store
	stack_pos = stack_pos + 1
	int left_type = promote(type)  # eax still holds the address: load
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_int(1)  # the implicit right-hand side
	int right_type = 3  # constant, exactly like a parsed '1' literal
	if (var_binary_operands(left_type, right_type)):
		error(c"compound assignment does not support var operands")
	int result_type = compound_assign_apply(op, left_type, right_type)
	coerce(type, result_type)
	pop_ebx()
	stack_pos = stack_pos - 1
	if (types_compatible_with_expression(type, result_type) == 0):
		warn_type_mismatch(c"assignment", type, result_type)
	assign_store(type)
	return type_value(type)  # like '+=', eax holds the stored value


# Statement dispatch hook (grammar/statement.w): '++x' / '--x'. The
# operand is a unary_expression, so postfix chains ('p.x', 'arr[i]'),
# '*p' and parenthesized lvalues all work; a non-lvalue operand fails
# increment_apply's assignability checks.
int increment_prefix_statement():
	int op = increment_op()
	if (op == 0):
		return 0
	get_token()
	expression_lhs_readonly = 0
	int type = unary_expression()
	increment_apply(op, type)
	return 1
