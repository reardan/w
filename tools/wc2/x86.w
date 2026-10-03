# Leaf backend: reuse the structured assembler, without production parser
# globals. Every expression leaves its value in eax and balances the stack.
import tools.wc2.semantics
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


struct wc2_codegen:
	wc2_semantics* semantic
	asm_buffer* out
	list[int] offsets
	list[int] call_positions
	list[int] call_functions
	list[int] breaks
	int loop_start
	int current_function


void wc2_memory(asm_buffer* out, char* mnemonic, int reg, int base, int displacement, int store):
	asm_insn insn
	asm_insn_clear(&insn)
	insn.mnemonic = mnemonic
	asm_operand* memory = &insn.op2
	asm_operand* register_operand = &insn.op1
	if (store):
		memory = &insn.op1
		register_operand = &insn.op2
	wc2_register(register_operand, reg, 4)
	memory.kind = ASM_OP_MEM
	memory.base = base
	memory.disp = displacement
	memory.size = 4
	asserts(c"wc2: unsupported internal memory instruction", asm_x86_encode(out, &insn) > 0)


# Fixed-width near branches avoid invalidating offsets when code grows.
int wc2_branch(asm_buffer* out, int opcode):
	if (opcode == 0x84): asm_buffer_byte(out, 0x0f)
	if (opcode == 0x85): asm_buffer_byte(out, 0x0f)
	asm_buffer_byte(out, opcode)
	int position = out.length
	asm_buffer_int32(out, 0)
	return position


void wc2_patch_branch(asm_buffer* out, int position, int target):
	asm_buffer_patch_int32(out, position, target - position - 4)


void wc2_call(wc2_codegen* c, int id):
	c.call_positions.push(wc2_branch(c.out, 0xe8))
	c.call_functions.push(id)


void wc2_boolean(asm_buffer* out, int type_id):
	if (type_id != wc2_bool_type): return
	wc2_x86(out, c"test", 0, 0)
	wc2_condition(out, c"setne")


# Aggregate expressions carry an address. This subset's scalar fields each
# occupy a private four-byte slot; no external ABI or layout is exposed.
void wc2_store(wc2_codegen* c, int type_id, int slot):
	if (type_id >= wc2_struct_type_base):
		for i in range(wc2_type_size(c.semantic, type_id) / 4):
			wc2_memory(c.out, c"mov", 2, 0, i * 4, 0)
			wc2_memory(c.out, c"mov", 2, 5, slot + i * 4, 1)
		wc2_memory(c.out, c"lea", 0, 5, slot, 0)
	else:
		wc2_boolean(c.out, type_id)
		wc2_memory(c.out, c"mov", 0, 5, slot, 1)


# eax=LHS, ecx=RHS. edx may be clobbered.
void wc2_emit_binary(asm_buffer* out, char* op):
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


void wc2_emit_expression(wc2_codegen* c, wc2_node* node):
	wc2_semantics* s = c.semantic
	wc2_module* m = s.module
	asm_buffer* out = c.out
	char* op = node.text
	if (node.kind == wc2_integer_kind):
		int value = 0
		assert1(wc2_integer32(op, &value))
		wc2_immediate(out, 0, value)
		return
	if ((node.kind == wc2_name_kind) || (node.kind == wc2_member_kind)):
		char* mnemonic = c"mov"
		if (s.types[node.id] >= wc2_struct_type_base): mnemonic = c"lea"
		wc2_memory(out, mnemonic, 0, 5, s.slots[node.id], 0)
		return
	if (node.kind == wc2_call_kind):
		int id = s.bindings[node.id]
		wc2_node* callee = m.nodes[id]
		int argument_size = 0
		# W evaluates arguments left to right. Each value is pushed before
		# the next argument, so nested calls cannot overwrite earlier ones.
		for i in range(1, node.children.length):
			wc2_emit_expression(c, wc2_child(m, node, i))
			int type_id = s.types[callee.children[i - 1]]
			int size = wc2_type_size(s, type_id)
			argument_size = argument_size + size
			if (type_id >= wc2_struct_type_base):
				int offset = size - 4
				while (offset >= 0):
					wc2_memory(out, c"mov", 2, 0, offset, 0)
					wc2_x86(out, c"push", 2, -1)
					offset = offset - 4
			else:
				wc2_boolean(out, type_id)
				wc2_x86(out, c"push", 0, -1)
		wc2_call(c, id)
		wc2_memory(out, c"lea", 4, 4, argument_size, 0)
		return
	if (node.kind == wc2_assignment_kind):
		wc2_node* left = wc2_child(m, node, 0)
		int compound = strcmp(op, c"=") != 0
		if (compound):
			wc2_emit_expression(c, left)
			wc2_x86(out, c"push", 0, -1)
		wc2_emit_expression(c, wc2_child(m, node, 1))
		if (compound):
			wc2_x86(out, c"mov", 1, 0)
			wc2_x86(out, c"pop", 0, -1)
			char[4] operator_text
			int length = strlen(op) - 1
			for i in range(length): operator_text[i] = op[i]
			operator_text[length] = 0
			wc2_emit_binary(out, operator_text)
		wc2_store(c, s.types[left.id], s.slots[left.id])
		return
	wc2_emit_expression(c, wc2_child(m, node, 0))
	if (node.kind == wc2_unary_kind):
		if (strcmp(op, c"-") == 0): wc2_x86(out, c"neg", 0, -1)
		if (strcmp(op, c"~") == 0): wc2_x86(out, c"not", 0, -1)
		if (strcmp(op, c"!") == 0):
			wc2_x86(out, c"test", 0, 0)
			wc2_condition(out, c"sete")
		return
	if (node.kind == wc2_logical_kind):
		wc2_boolean(out, wc2_bool_type)
		wc2_x86(out, c"test", 0, 0)
		int opcode = 0x84
		if (strcmp(op, c"||") == 0): opcode = 0x85
		int fixup = wc2_branch(out, opcode)
		wc2_emit_expression(c, wc2_child(m, node, 1))
		wc2_boolean(out, wc2_bool_type)
		wc2_patch_branch(out, fixup, out.length)
		return
	wc2_x86(out, c"push", 0, -1)
	wc2_emit_expression(c, wc2_child(m, node, 1))
	wc2_x86(out, c"mov", 1, 0)
	wc2_x86(out, c"pop", 0, -1)
	wc2_emit_binary(out, op)


void wc2_emit_statement(wc2_codegen* c, wc2_node* node):
	wc2_semantics* s = c.semantic
	wc2_module* m = s.module
	asm_buffer* out = c.out
	if (node.kind == wc2_block_kind):
		for int id in node.children: wc2_emit_statement(c, m.nodes[id])
	elif (node.kind == wc2_declaration_kind):
		if (node.children.length):
			wc2_emit_expression(c, wc2_child(m, node, 0))
			wc2_store(c, s.types[node.id], s.slots[node.id])
	elif (node.kind == wc2_return_kind):
		if (node.children.length): wc2_emit_expression(c, wc2_child(m, node, 0))
		else: wc2_immediate(out, 0, 0)
		wc2_boolean(out, s.types[c.current_function])
		wc2_x86(out, c"leave", -1, -1)
		wc2_x86(out, c"ret", -1, -1)
	elif (node.kind == wc2_expression_statement_kind): wc2_emit_expression(c, wc2_child(m, node, 0))
	elif (node.kind == wc2_if_kind):
		wc2_emit_expression(c, wc2_child(m, node, 0))
		wc2_x86(out, c"test", 0, 0)
		int alternate = wc2_branch(out, 0x84)
		wc2_emit_statement(c, wc2_child(m, node, 1))
		int done = wc2_branch(out, 0xe9)
		wc2_patch_branch(out, alternate, out.length)
		if (node.children.length == 3): wc2_emit_statement(c, wc2_child(m, node, 2))
		wc2_patch_branch(out, done, out.length)
	elif (node.kind == wc2_while_kind):
		int previous_start = c.loop_start
		list[int] previous_breaks = c.breaks
		c.loop_start = out.length
		c.breaks = new list[int]
		wc2_emit_expression(c, wc2_child(m, node, 0))
		wc2_x86(out, c"test", 0, 0)
		int done = wc2_branch(out, 0x84)
		wc2_emit_statement(c, wc2_child(m, node, 1))
		int back = wc2_branch(out, 0xe9)
		wc2_patch_branch(out, back, c.loop_start)
		wc2_patch_branch(out, done, out.length)
		for int fixup in c.breaks: wc2_patch_branch(out, fixup, out.length)
		wc2_free_ints(c.breaks)
		c.breaks = previous_breaks
		c.loop_start = previous_start
	elif (node.kind == wc2_break_kind): c.breaks.push(wc2_branch(out, 0xe9))
	elif (node.kind == wc2_continue_kind):
		int back = wc2_branch(out, 0xe9)
		wc2_patch_branch(out, back, c.loop_start)


void wc2_emit_functions(wc2_semantics* s, asm_buffer* out):
	wc2_codegen* c = new wc2_codegen()
	c.semantic = s
	c.out = out
	c.offsets = new list[int]
	c.call_positions = new list[int]
	c.call_functions = new list[int]
	c.breaks = new list[int]
	c.loop_start = -1
	c.current_function = -1
	for i in range(s.module.nodes.length): c.offsets.push(-1)
	wc2_call(c, s.entry)
	wc2_x86(out, c"mov", 3, 0)
	wc2_immediate(out, 0, 1)
	asm_buffer_byte(out, 0xcd)
	asm_buffer_byte(out, 0x80)
	for int id in s.module.nodes[s.module.root].children:
		wc2_node* fn_node = s.module.nodes[id]
		if (fn_node.kind != wc2_function_kind): continue
		c.current_function = id
		c.offsets[id] = out.length
		wc2_x86(out, c"push", 5, -1)
		wc2_x86(out, c"mov", 5, 4)
		wc2_memory(out, c"lea", 4, 4, 0 - s.frames[id], 0)
		wc2_emit_statement(c, wc2_child(s.module, fn_node, fn_node.children.length - 1))
		# Void fallthrough. For value functions semantic analysis proves
		# this epilogue unreachable; every return restores the whole frame.
		wc2_immediate(out, 0, 0)
		wc2_x86(out, c"leave", -1, -1)
		wc2_x86(out, c"ret", -1, -1)
	for i in range(c.call_positions.length): wc2_patch_branch(out, c.call_positions[i], c.offsets[c.call_functions[i]])
	wc2_free_ints(c.offsets)
	wc2_free_ints(c.call_positions)
	wc2_free_ints(c.call_functions)
	wc2_free_ints(c.breaks)
	free(c)
