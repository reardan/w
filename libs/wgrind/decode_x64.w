# Strict decoder adapter for native execution. The general disassembler
# accepts prefixes it does not model; an execution checker must reject them.
import libs.asm.x86_decode
import libs.wgrind.registers
import libs.wgrind.flags


struct wg_machine:
	wg_context* context
	wg_registers registers
	wg_x64_flags flags
	asm_insn instruction
	char[16] bytes
	int rex
	int condition
	int pid
	int[27] raw
	int stack_low
	int stack_high
	int steps


int wg_native_incomplete(wg_machine* m):
	return wg_error(m.context, WG_INCOMPLETE, m.raw[16], 0, m.raw[16], 0)


int wg_native_reader(int opaque, int address, int size, int* out):
	if ((size < 1) || (size > 8) || (wg_range(address, size) == 0)): return 0
	int value = 0
	int aligned = address & ~7
	if (sys_ptrace(2, opaque, aligned, cast(int, &value)) < 0): return 0
	int offset = address & 7
	int first = 8 - offset
	if (first > size): first = size
	int result = (value >> (offset * 8)) & wg_mask(first)
	if (first < size):
		if (sys_ptrace(2, opaque, aligned + 8, cast(int, &value)) < 0): return 0
		result = result | ((value & wg_mask(size - first)) << (first * 8))
	*out = result
	return 1


int wg_decode_native(wg_machine* m):
	int count = 0
	while (count < 15):
		int chunk = 15 - count
		if (chunk > 8): chunk = 8
		int value = 0
		if (wg_native_reader(m.pid, m.raw[16] + count, chunk, &value)):
			for i in range(chunk): m.bytes[count + i] = (value >> (i * 8)) & 255
			count = count + chunk
		else:
			# A short instruction at the end of a mapping is valid even
			# when an eager eight-byte fetch crosses into unmapped memory.
			for i in range(chunk):
				if (wg_native_reader(m.pid, m.raw[16] + count, 1, &value) == 0): break
				m.bytes[count] = value
				count = count + 1
			break
	if (count == 0): return wg_native_incomplete(m)
	# The display decoder returns zero without advancing at end-of-input.
	# Pad its private buffer so a truncated field still consumes its full
	# encoding length; reject that length against the actual readable bytes.
	for i in range(count, 16): m.bytes[i] = 0
	# ENDBR64 is a landing-pad hint and has no data/flag effects.
	if ((count >= 4) && ((m.bytes[0] & 255) == 0xf3) && (m.bytes[1] == 0x0f) && (m.bytes[2] == 0x1e) && ((m.bytes[3] & 255) == 0xfa)):
		asm_insn_clear(&m.instruction)
		m.instruction.mnemonic = c"nop"
		m.instruction.address = m.raw[16]
		m.instruction.length = 4
		return 1
	int at = 0
	m.rex = 0
	m.condition = -1
	int operand_prefix = 0
	if (m.bytes[at] == 0x66):
		operand_prefix = 1
		at = at + 1
	if ((at < count) && (m.bytes[at] >= 0x40) && (m.bytes[at] <= 0x4f)):
		m.rex = m.bytes[at]
		at = at + 1
	if (at >= count): return wg_native_incomplete(m)
	int op = m.bytes[at] & 255
	if ((op == 0x67) || (op == 0x64) || (op == 0x65) || (op == 0xf2) || (op == 0xf3) || (op == 0xf0) || (op == 0x66) || ((op >= 0x40) && (op <= 0x4f))): return wg_native_incomplete(m)
	# Relative-control decodes in the formatter allocate printable labels.
	# Build these directly so the execution loop allocates no label strings.
	int immediate = 0
	int branch = 0
	char* name = c"jmp"
	if ((op >= 0x70) && (op <= 0x7f)):
		m.condition = op - 0x70
		immediate = 1
		branch = 1
		name = c"jcc"
	else if ((op == 0xeb) || (op == 0xe8) || (op == 0xe9)):
		immediate = 4
		if (op == 0xeb): immediate = 1
		if (op == 0xe8): name = c"call"
		branch = 1
	else if ((op == 0x0f) && (at + 1 < count)):
		int second = m.bytes[at + 1] & 255
		if ((second >= 0x80) && (second <= 0x8f)):
			m.condition = second - 0x80
			at = at + 1
			immediate = 4
			branch = 1
			name = c"jcc"
		else if ((second >= 0x40) && (second <= 0x4f)):
			if (at + 2 >= count): return wg_native_incomplete(m)
			asm_x86_dec d
			d.bytes = &m.bytes[0]
			d.length = 15
			d.pos = at + 2
			d.mode = 8
			d.opsize = 4
			if (operand_prefix): d.opsize = 2
			if (m.rex & 8): d.opsize = 8
			d.rex = m.rex
			d.rep = 0
			d.seg = 0
			d.pfx66 = operand_prefix
			asm_insn_clear(&m.instruction)
			m.instruction.mnemonic = c"cmovcc"
			m.instruction.address = m.raw[16]
			m.condition = second - 0x40
			asm_x86_modrm_gp(&d, &m.instruction.op1, &m.instruction.op2)
			m.instruction.length = d.pos
			if (d.pos > count): return wg_native_incomplete(m)
			return 1
		else if ((second >= 0x90) && (second <= 0x9f)): m.condition = second - 0x90
	if (branch):
		if (operand_prefix || (at + 1 + immediate > count)): return wg_native_incomplete(m)
		int relative = 0
		for i in range(immediate): relative = relative | ((m.bytes[at + 1 + i] & 255) << (i * 8))
		if (relative & (1 << (immediate * 8 - 1))): relative = relative - (1 << (immediate * 8))
		asm_insn_clear(&m.instruction)
		m.instruction.mnemonic = name
		m.instruction.address = m.raw[16]
		m.instruction.length = at + 1 + immediate
		m.instruction.branch_target = m.raw[16] + m.instruction.length + relative
		m.instruction.op1.kind = ASM_OP_LABEL
		return 1
	asm_x86_decode(&m.bytes[0], 15, m.raw[16], 8, &m.instruction)
	if (m.condition >= 0):
		free(m.instruction.mnemonic)
		m.instruction.mnemonic = c"setcc"
	if ((m.instruction.length < 1) || (m.instruction.length > count) || (strcmp(m.instruction.mnemonic, c".byte") == 0)): return wg_native_incomplete(m)
	return 1


int wg_native_register_offset(int reg):
	# Linux user_regs_struct order: r15..r8,rax,rcx,rdx,rsi,rdi,...
	if (reg == 0): return 10
	if (reg == 1): return 11
	if (reg == 2): return 12
	if (reg == 3): return 5
	if (reg == 4): return 19
	if (reg == 5): return 4
	if (reg == 6): return 13
	if (reg == 7): return 14
	if (reg == 8): return 9
	if (reg == 9): return 8
	if (reg == 10): return 7
	if (reg == 11): return 6
	return 15 - reg


int wg_native_read_register(wg_machine* m, asm_operand* op, wg_value* out):
	if (op.rclass != ASM_RCLASS_GP): return wg_native_incomplete(m)
	int reg = op.reg
	int offset = 0
	if ((op.size == 1) && (m.rex == 0) && (reg >= 4) && (reg <= 7)):
		reg = reg - 4
		offset = 1
	return wg_register_read(m.context, &m.registers, reg, offset, op.size, m.raw[16], out)


int wg_native_address(wg_machine* m, asm_operand* op, int consequential, wg_value* out):
	wg_value base
	wg_value index
	wg_value scale
	wg_value_set(&base, 0, 0, 0)
	wg_value_set(&index, 0, 0, 0)
	if (op.base == ASM_BASE_RIP): wg_value_set(&base, m.raw[16] + m.instruction.length, 0, 0)
	else if (op.base >= 0):
		if (wg_register_read(m.context, &m.registers, op.base, 0, 8, m.raw[16], &base) == 0): return 0
	if (op.index >= 0):
		if (wg_register_read(m.context, &m.registers, op.index, 0, 8, m.raw[16], &index) == 0): return 0
		int shift = 0
		if (op.scale == 2): shift = 1
		else if (op.scale == 4): shift = 2
		else if (op.scale == 8): shift = 3
		else if (op.scale != 1): return wg_native_incomplete(m)
		wg_value_set(&scale, shift, 0, 0)
		if (wg_shift(m.context, WG_SHL, 8, &index, &scale, m.raw[16], &index) == 0): return 0
	if (wg_binary(m.context, WG_ADD, 8, &base, &index, out) == 0): return 0
	wg_value_set(&base, op.disp, 0, 0)
	if (wg_binary(m.context, WG_ADD, 8, out, &base, out) == 0): return 0
	if (consequential): return wg_use(m.context, out, m.raw[16])
	return 1


int wg_native_read(wg_machine* m, asm_operand* op, wg_value* out):
	if (op.kind == ASM_OP_REG): return wg_native_read_register(m, op, out)
	if (op.kind == ASM_OP_IMM):
		int value = op.imm
		if (op.size == 8): value = (op.imm & wg_mask(4)) | (op.imm_hi << 32)
		else if ((op.size == 4) && (m.instruction.op1.size == 8) && (value & (1 << 31))): value = value | ~wg_mask(4)
		wg_value_set(out, value, 0, 0)
		return 1
	if (op.kind != ASM_OP_MEM): return wg_native_incomplete(m)
	wg_value address
	if (wg_native_address(m, op, 1, &address) == 0): return 0
	if (wg_load(m.context, address.value, op.size, m.raw[16], out) == 0): return 0
	if (wg_native_reader(m.pid, address.value, op.size, &out.value) == 0): return wg_native_incomplete(m)
	return 1


int wg_native_write(wg_machine* m, asm_operand* op, wg_value* value):
	if (op.kind == ASM_OP_REG):
		if (op.rclass != ASM_RCLASS_GP): return wg_native_incomplete(m)
		int reg = op.reg
		int offset = 0
		if ((op.size == 1) && (m.rex == 0) && (reg >= 4) && (reg <= 7)):
			reg = reg - 4
			offset = 1
		return wg_register_write(m.context, &m.registers, reg, offset, op.size, op.size == 4, m.raw[16], value)
	if (op.kind != ASM_OP_MEM): return wg_native_incomplete(m)
	wg_value address
	if (wg_native_address(m, op, 1, &address) == 0): return 0
	return wg_store(m.context, address.value, op.size, m.raw[16], value)
