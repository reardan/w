# True for a bool-typed lvalue operand — a declared bool variable, field
# or parameter, still in address form (not the value a comparison or call
# just produced). bitwise_and_expr/bitwise_or_expr warn when '&'/'|'
# joins two of these inside an if/while condition: such guards read as
# logical and do not short-circuit.
int operand_is_bool_lvalue(int type):
	if (type_is_value(type)):
		return 0
	return type_unqualified(type) == bool_type


# --bool-ops (opt-in `w check --bool-ops`): report the bool-bitwise
# condition hint even when one or both operands contain a function call.
# The DEFAULT hint (see operand_is_pure below) only fires when both
# operands are call-free, because that is the subset where '&&'/'||'
# conversion is semantics-preserving — short-circuiting a call-containing
# operand would skip a call the current '&'/'|' code always executes.
# Off by default: ordinary compiles and --strict self-host builds must
# stay silent on the ~165 call-containing joins deliberately still
# spelled '&'/'|' tree-wide (compiler/compiler.w parses the flag,
# mirroring check_imports_mode).
int check_bool_ops_mode


# The condition hint's operand type test: a bool lvalue always
# qualifies; a bool VALUE — the result a comparison, '!', '&&', '||' or
# 'in' just produced — qualifies too. Comparison results were opt-in
# behind --bool-ops through the 2026-07 migration; the wave-2 mechanical
# sweep converted every side-effect-free site tree-wide (see
# docs/projects/ai_tooling_next_steps.md), so the widened test is
# unconditional now. Purity (operand_is_pure below), not this function,
# is what gates the DEFAULT warning down to the semantics-preserving
# subset.
int operand_is_bool_condition(int type):
	if (operand_is_bool_lvalue(type)):
		return 1
	if (type_is_value(type) == 0):
		return 0
	return type_unqualified(type) == bool_type


# True when nothing the just-parsed operand emitted a call: call_count_
# before is emitted_call_count (code_generator/x86.w) sampled right
# before the operand's own parse started. A call anywhere in the operand
# — an explicit call, a builtin container op, an operator-overload
# dispatch, a 'new' allocation's implicit malloc, ... — bumps
# emitted_call_count at least once, so the counts differ.
int operand_is_pure(int call_count_before):
	return emitted_call_count == call_count_before


# Emit a bool-bitwise condition warning at the '&'/'|' operator's own
# source position, not wherever the tokenizer's one-token lookahead has
# moved to by the time the right operand finishes parsing (which, after
# a multi-term chain or a multi-line condition, can be a wholly
# different line/column, and — for `--json`'s "token" field — a wholly
# different token's text — found sweeping wave 2's stage-2 chunks,
# logged in ai_tooling_next_steps.md). Callers snapshot line_number/
# diag_token_line/diag_token_column right when accept()'s peek
# recognizes the operator, before consuming it advances the lookahead,
# and pass op_token_text as the operator's own literal spelling ("&" or
# "|" — always a compile-time constant at the call site, so no snapshot
# of the mutable token buffer is needed). This restores those saved
# coordinates around the warning() call and puts the current ones back
# immediately after, mirroring compile_save's own save/restore of
# line_number/diag_token_line/diag_token_column around a nested file
# compile.
void warn_bool_bitwise_at(char* message, int op_line_number, int op_diag_token_line, int op_diag_token_column, char* op_token_text):
	int cur_line_number = line_number
	int cur_diag_token_line = diag_token_line
	int cur_diag_token_column = diag_token_column
	char* cur_token = token
	line_number = op_line_number
	diag_token_line = op_diag_token_line
	diag_token_column = op_diag_token_column
	token = op_token_text
	warning(message)
	line_number = cur_line_number
	diag_token_line = cur_diag_token_line
	diag_token_column = cur_diag_token_column
	token = cur_token


int binary1(int type):
	type = promote(type)
	push_eax()
	stack_pos = stack_pos + 1
	return type


# Finish a binary operator whose emitter pops the pushed left operand
# itself (division, shifts): promote the right operand, then account for
# the popped stack word.
int binary2_finish(int type):
	promote(type)
	stack_pos = stack_pos - 1
	return 3


# Finish a binary operator that expects the left operand in ebx: promote
# the right operand and pop the left one first.
int binary2_finish_pop(int type):
	promote(type)
	pop_ebx()
	stack_pos = stack_pos - 1
	return 3


int binary2_promote_pop(int type):
	type = promote(type)
	pop_ebx()
	stack_pos = stack_pos - 1
	return type


int float_binary_result_type(int kind):
	if (kind == 2):
		return float64_value_type
	return float32_value_type


# Load one operand of a float binary operation into an XMM register at
# the operation width (kind 2 = float64, otherwise float32), converting
# from the operand's own representation. reg selects the source GPR:
# 0 is the operand in eax/rax (the right side), 1 the one in ebx/rbx
# (the left side, pushed there by binary2_promote_pop).
void float_load_xmm(int xmm, int reg, int type, int kind):
	int operand_kind = type_float_kind(type)
	if (kind == 2):
		if (operand_kind == 2):
			movq_xmm(xmm, reg)
		else if (operand_kind == 1):
			movd_xmm(xmm, reg)
			cvtss2sd_xmm(xmm)
		else:
			cvtsi2sd_xmm(xmm, reg)
	else:
		if (operand_kind == 1):
			movd_xmm(xmm, reg)
		else:
			cvtsi2ss_xmm(xmm, reg)


int float_binary_arithmetic(int left_type, int right_type, int op):
	int kind = binary_float_kind(left_type, right_type)
	if (kind == 0):
		return 0
	float_load_xmm(0, 1, left_type, kind)
	float_load_xmm(1, 0, right_type, kind)
	if (kind == 2):
		if (op == '+'):
			addsd()
		else if (op == '-'):
			subsd()
		else if (op == '*'):
			mulsd()
		else if (op == '/'):
			divsd()
		movq_rax_xmm0()
	else:
		if (op == '+'):
			addss()
		else if (op == '-'):
			subss()
		else if (op == '*'):
			mulss()
		else if (op == '/'):
			divss()
		movd_eax_xmm0()
	return float_binary_result_type(kind)


int float_binary_compare(int left_type, int right_type, int setcc_opcode, int swap):
	int kind = binary_float_kind(left_type, right_type)
	if (kind == 0):
		return 0
	if (swap):
		float_load_xmm(0, 0, right_type, kind)
		float_load_xmm(1, 1, left_type, kind)
	else:
		float_load_xmm(0, 1, left_type, kind)
		float_load_xmm(1, 0, right_type, kind)
	if (kind == 2):
		ucomisd()
	else:
		ucomiss()
	setcc_movzx_eax(setcc_opcode)
	return type_value(bool_type)
