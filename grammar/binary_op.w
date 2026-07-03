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


void float_load_left_xmm0(int type, int kind):
	int left_kind = type_float_kind(type)
	if (kind == 2):
		if (left_kind == 2):
			movq_xmm0_rbx()
		else if (left_kind == 1):
			movd_xmm0_ebx()
			cvtss2sd_xmm0()
		else:
			cvtsi2sd_xmm0_rbx()
	else:
		if (left_kind == 1):
			movd_xmm0_ebx()
		else:
			cvtsi2ss_xmm0_ebx()


void float_load_right_xmm1(int type, int kind):
	int right_kind = type_float_kind(type)
	if (kind == 2):
		if (right_kind == 2):
			movq_xmm1_rax()
		else if (right_kind == 1):
			movd_xmm1_eax()
			cvtss2sd_xmm1()
		else:
			cvtsi2sd_xmm1_rax()
	else:
		if (right_kind == 1):
			movd_xmm1_eax()
		else:
			cvtsi2ss_xmm1_eax()


void float_load_left_xmm1(int type, int kind):
	int left_kind = type_float_kind(type)
	if (kind == 2):
		if (left_kind == 2):
			movq_xmm1_rbx()
		else if (left_kind == 1):
			movd_xmm1_ebx()
			cvtss2sd_xmm1()
		else:
			cvtsi2sd_xmm1_rbx()
	else:
		if (left_kind == 1):
			movd_xmm1_ebx()
		else:
			cvtsi2ss_xmm1_ebx()


void float_load_right_xmm0(int type, int kind):
	int right_kind = type_float_kind(type)
	if (kind == 2):
		if (right_kind == 2):
			movq_xmm0_rax()
		else if (right_kind == 1):
			movd_xmm0_eax()
			cvtss2sd_xmm0()
		else:
			cvtsi2sd_xmm0_rax()
	else:
		if (right_kind == 1):
			movd_xmm0_eax()
		else:
			cvtsi2ss_xmm0_eax()


int float_binary_arithmetic(int left_type, int right_type, int op):
	int kind = binary_float_kind(left_type, right_type)
	if (kind == 0):
		return 0
	float_load_left_xmm0(left_type, kind)
	float_load_right_xmm1(right_type, kind)
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
		float_load_right_xmm0(right_type, kind)
		float_load_left_xmm1(left_type, kind)
	else:
		float_load_left_xmm0(left_type, kind)
		float_load_right_xmm1(right_type, kind)
	if (kind == 2):
		ucomisd()
	else:
		ucomiss()
	setcc_movzx_eax(setcc_opcode)
	return 3
