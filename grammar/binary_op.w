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
