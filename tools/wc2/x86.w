# Leaf backend: reuse the structured assembler, without production parser
# globals. Every expression leaves its value in eax and balances the stack.
import tools.wc2.validate
import libs.asm.x86_encode
import lib.assert


void wc2_register(asm_operand* operand, int reg, int size):
	if (reg < 0): return
	operand.kind = ASM_OP_REG
	operand.reg = reg
	operand.size = size


void wc2_x86(asm_buffer* out, char* mnemonic, int dest, int source):
	asm_insn insn
	asm_insn_clear(&insn)
	insn.mnemonic = mnemonic
	wc2_register(&insn.op1, dest, 4)
	wc2_register(&insn.op2, source, 4)
	if ((strcmp(mnemonic, c"shl") == 0) || (strcmp(mnemonic, c"sar") == 0)): insn.op2.size = 1
	asserts(c"wc2: unsupported internal instruction", asm_x86_encode(out, &insn) > 0)


void wc2_immediate(asm_buffer* out, int reg, int value):
	asm_insn insn
	asm_insn_clear(&insn)
	insn.mnemonic = c"mov"
	wc2_register(&insn.op1, reg, 4)
	insn.op2.kind = ASM_OP_IMM
	insn.op2.imm = value
	insn.op2.size = 4
	asserts(c"wc2: unsupported internal immediate", asm_x86_encode(out, &insn) > 0)


# Consume flags, canonicalize to a full 32-bit 0/1 value without changing
# flags before SETcc. MOVZX is unnecessary when eax was first zeroed by MOV.
void wc2_condition(asm_buffer* out, char* mnemonic):
	wc2_immediate(out, 0, 0)
	asm_insn insn
	asm_insn_clear(&insn)
	insn.mnemonic = mnemonic
	wc2_register(&insn.op1, 0, 1)
	asserts(c"wc2: unsupported internal condition", asm_x86_encode(out, &insn) > 0)


char* wc2_binary_instruction(char* op):
	if (strcmp(op, c"+") == 0): return c"add"
	if (strcmp(op, c"-") == 0): return c"sub"
	if (strcmp(op, c"*") == 0): return c"imul"
	if (strcmp(op, c"&") == 0): return c"and"
	if (strcmp(op, c"|") == 0): return c"or"
	if (strcmp(op, c"^") == 0): return c"xor"
	if (strcmp(op, c"<<") == 0): return c"shl"
	if (strcmp(op, c">>") == 0): return c"sar"
	return 0


char* wc2_comparison(char* op):
	if (strcmp(op, c"==") == 0): return c"sete"
	if (strcmp(op, c"!=") == 0): return c"setne"
	if (strcmp(op, c"<") == 0): return c"setl"
	if (strcmp(op, c"<=") == 0): return c"setle"
	if (strcmp(op, c">") == 0): return c"setg"
	if (strcmp(op, c">=") == 0): return c"setge"
	return 0


void wc2_emit_expression(wc2_module* m, wc2_node* node, asm_buffer* out):
	char* op = node.text
	if (node.kind == wc2_integer_kind):
		int value = 0
		assert1(wc2_integer32(op, &value))
		wc2_immediate(out, 0, value)
		return
	wc2_emit_expression(m, wc2_child(m, node, 0), out)
	if (node.kind == wc2_unary_kind):
		if (strcmp(op, c"-") == 0): wc2_x86(out, c"neg", 0, -1)
		if (strcmp(op, c"~") == 0): wc2_x86(out, c"not", 0, -1)
		if (strcmp(op, c"!") == 0):
			wc2_x86(out, c"test", 0, 0)
			wc2_condition(out, c"sete")
		return
	if (node.kind == wc2_logical_kind):
		wc2_x86(out, c"test", 0, 0)
		wc2_condition(out, c"setne")
		wc2_x86(out, c"test", 0, 0)
		# Near JZ/JNZ over the RHS; keep the normalized LHS on that path.
		asm_buffer_byte(out, 0x0f)
		int opcode = 0x84
		if (strcmp(op, c"||") == 0): opcode = 0x85
		asm_buffer_byte(out, opcode)
		int fixup = out.length
		asm_buffer_int32(out, 0)
		wc2_emit_expression(m, wc2_child(m, node, 1), out)
		wc2_x86(out, c"test", 0, 0)
		wc2_condition(out, c"setne")
		asm_buffer_patch_int32(out, fixup, out.length - fixup - 4)
		return
	# ecx holds RHS only after its subtree completes; nested expressions
	# may freely clobber ecx/edx. The LHS lives on the machine stack.
	wc2_x86(out, c"push", 0, -1)
	wc2_emit_expression(m, wc2_child(m, node, 1), out)
	wc2_x86(out, c"mov", 1, 0)
	wc2_x86(out, c"pop", 0, -1)
	if ((strcmp(op, c"/") == 0) || (strcmp(op, c"%") == 0)):
		wc2_x86(out, c"cdq", -1, -1)
		wc2_x86(out, c"idiv", 1, -1)
		if (strcmp(op, c"%") == 0): wc2_x86(out, c"mov", 0, 2)
		return
	char* mnemonic = wc2_binary_instruction(op)
	if (mnemonic != 0):
		wc2_x86(out, mnemonic, 0, 1)
		return
	mnemonic = wc2_comparison(op)
	assert1(mnemonic != 0)
	wc2_x86(out, c"cmp", 0, 1)
	wc2_condition(out, mnemonic)
