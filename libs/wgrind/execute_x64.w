# Instruction shadow effects for the Linux x64 reference executor.
# Every unsupported instruction fails before the tracee executes it.
import libs.wgrind.decode_x64
import libs.wgrind.execute_integer


int wg_native_same(asm_operand* a, asm_operand* b):
	return (a.kind == ASM_OP_REG) && (b.kind == ASM_OP_REG) && (a.reg == b.reg) && (a.size == b.size) && (a.rclass == b.rclass)


int wg_native_stack(wg_machine* m, int oldsp, int newsp):
	if ((newsp < m.stack_low + 128) || (newsp > m.stack_high)): return wg_native_incomplete(m)
	if (newsp < oldsp): return wg_mark(m.context, newsp - 128, oldsp - newsp, 3, 255, m.raw[16])
	if (newsp > oldsp): return wg_mark(m.context, oldsp - 128, newsp - oldsp, 0, 0, 0)
	return 1


int wg_native_push(wg_machine* m, wg_value* value):
	wg_value stack
	if (wg_register_read(m.context, &m.registers, 4, 0, 8, m.raw[16], &stack) == 0): return 0
	if (wg_use(m.context, &stack, m.raw[16]) == 0): return 0
	return wg_store(m.context, stack.value - 8, 8, m.raw[16], value)


int wg_native_pop(wg_machine* m, int address, wg_value* value):
	if (wg_load(m.context, address, 8, m.raw[16], value) == 0): return 0
	if (wg_native_reader(m.pid, address, 8, &value.value) == 0): return wg_native_incomplete(m)
	return 1


int wg_native_instruction(wg_machine* m):
	asm_insn* insn = &m.instruction
	wg_context* c = m.context
	char* name = insn.mnemonic
	int site = m.raw[16]
	wg_value left
	wg_value right
	wg_value result
	if (strcmp(name, c"nop") == 0): return 1
	if (strcmp(name, c"mov") == 0):
		if (wg_native_read(m, &insn.op2, &result) == 0): return 0
		return wg_native_write(m, &insn.op1, &result)
	if ((strcmp(name, c"movzx") == 0) || (strcmp(name, c"movsx") == 0) || (strcmp(name, c"movsxd") == 0)):
		if (wg_native_read(m, &insn.op2, &result) == 0): return 0
		if (strcmp(name, c"movzx") != 0):
			int sign = 1 << (insn.op2.size * 8 - 1)
			if (result.value & sign): result.value = result.value | ~wg_mask(insn.op2.size)
			if (result.undefined & sign): result.undefined = result.undefined | ~wg_mask(insn.op2.size)
		return wg_native_write(m, &insn.op1, &result)
	if (strcmp(name, c"lea") == 0):
		if (insn.op2.kind != ASM_OP_MEM): return wg_native_incomplete(m)
		if (wg_native_address(m, &insn.op2, 0, &result) == 0): return 0
		return wg_native_write(m, &insn.op1, &result)
	if ((strcmp(name, c"jcc") == 0) || (strcmp(name, c"setcc") == 0)):
		if (wg_flags_condition(c, &m.flags, m.condition, site, &result) == 0): return 0
		if (strcmp(name, c"jcc") == 0): return wg_use(c, &result, site)
		return wg_native_write(m, &insn.op1, &result)
	if ((strcmp(name, c"jmp") == 0) || (strcmp(name, c"call") == 0)):
		if (insn.op1.kind != ASM_OP_LABEL):
			if (wg_native_read(m, &insn.op1, &result) == 0): return 0
			if (wg_use(c, &result, site) == 0): return 0
		if (strcmp(name, c"call") == 0):
			wg_value_set(&result, site + insn.length, 0, 0)
			return wg_native_push(m, &result)
		return 1
	if (strcmp(name, c"push") == 0):
		if (insn.op1.size == 2): return wg_native_incomplete(m)
		if (wg_native_read(m, &insn.op1, &result) == 0): return 0
		return wg_native_push(m, &result)
	if ((strcmp(name, c"pop") == 0) || (strcmp(name, c"ret") == 0) || (strcmp(name, c"leave") == 0)):
		if ((strcmp(name, c"pop") == 0) && ((insn.op1.kind != ASM_OP_REG) || (insn.op1.size != 8) || (insn.op1.reg == 4))): return wg_native_incomplete(m)
		int reg = 4
		if (strcmp(name, c"leave") == 0): reg = 5
		if (wg_register_read(c, &m.registers, reg, 0, 8, site, &left) == 0): return 0
		if (wg_use(c, &left, site) == 0): return 0
		if (wg_native_pop(m, left.value, &result) == 0): return 0
		if (strcmp(name, c"ret") == 0): return wg_use(c, &result, site)
		if (strcmp(name, c"leave") == 0): return wg_register_write(c, &m.registers, 5, 0, 8, 0, site, &result)
		return wg_native_write(m, &insn.op1, &result)
	int op = 0
	if ((strcmp(name, c"and") == 0) || (strcmp(name, c"test") == 0)): op = WG_AND
	else if (strcmp(name, c"or") == 0): op = WG_OR
	else if (strcmp(name, c"xor") == 0): op = WG_XOR
	else if (strcmp(name, c"add") == 0): op = WG_ADD
	else if ((strcmp(name, c"sub") == 0) || (strcmp(name, c"cmp") == 0)): op = WG_SUB
	if (op):
		if (wg_native_read(m, &insn.op1, &left) == 0): return 0
		if (wg_native_read(m, &insn.op2, &right) == 0): return 0
		if (((op == WG_XOR) || (op == WG_SUB)) && wg_native_same(&insn.op1, &insn.op2)):
			# Proven operand identity, including cmp r,r, eliminates unknowns.
			wg_value_set(&left, left.value, 0, 0)
			wg_value_set(&right, right.value, 0, 0)
		if (wg_binary(c, op, insn.op1.size, &left, &right, &result) == 0): return 0
		if (wg_flags_update(c, &m.flags, op, insn.op1.size, &left, &right, &result, site) == 0): return 0
		if ((strcmp(name, c"cmp") == 0) || (strcmp(name, c"test") == 0)): return 1
		return wg_native_write(m, &insn.op1, &result)
	if (strcmp(name, c"not") == 0):
		if (wg_native_read(m, &insn.op1, &result) == 0): return 0
		result.value = ~result.value
		return wg_native_write(m, &insn.op1, &result)
	if (strcmp(name, c"neg") == 0):
		if (wg_native_read(m, &insn.op1, &right) == 0): return 0
		wg_value_set(&left, 0, 0, 0)
		if (wg_binary(c, WG_SUB, insn.op1.size, &left, &right, &result) == 0): return 0
		if (wg_flags_update(c, &m.flags, WG_SUB, insn.op1.size, &left, &right, &result, site) == 0): return 0
		return wg_native_write(m, &insn.op1, &result)
	int handled = wg_native_integer(m)
	if (handled >= 0): return handled
	return wg_native_incomplete(m)
