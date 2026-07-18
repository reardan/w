void emit_x64_opcode():
	if (word_size == 8):
		emit(1, c"\x48")



################################# x86 opcodes #################################
# Each helper dispatches to its AArch64 twin (code_generator/arm64.w) when
# target_isa == 1; the x86/x64 byte sequences below are otherwise unchanged,
# so those targets stay byte-identical.

/* push dword 0x12 */
void push_int8(int v):
	if (target_isa == 3):
		ptx_push_const(v)
		return
	if (target_isa == 2):
		wasm_push_const(v)
		return
	if (target_isa == 1):
		arm64_push_imm(v)
		return
	emit_int8(106)
	emit_int8(v)


/* push dword op(0x12, 0x345678) */
void push_int32(int v):
	if (target_isa == 3):
		ptx_push_const(v)
		return
	if (target_isa == 2):
		wasm_push_const(v)
		return
	if (target_isa == 1):
		arm64_push_imm(v)
		return
	emit_int8(104)
	emit_int32(v)


void push_int(int v):
	if (target_isa == 2):
		wasm_push_const(v)
		return
	push_int32(v)


/* mov eax,[eax] */
void promote_eax():
	if (target_isa == 3):
		ptx_ld_ax(c".u64")
		return
	if (target_isa == 2):
		wasm_promote_eax_op(0x28)
		return
	if (target_isa == 1):
		a64(op(0xf9, 0x400000))   # ldr x0,[x0]
		return
	emit_x64_opcode()
	emit(2, c"\x8b\x00")


/* mov ebx,[ebx] */
void promote_ebx():
	if (target_isa == 3):
		ptx_promote_bx()
		return
	if (target_isa == 2):
		wasm_promote_ebx()
		return
	if (target_isa == 1):
		a64(op(0xf9, 0x400021))   # ldr x1,[x1]
		return
	emit_x64_opcode()
	emit(2, c"\x8b\x1b")


/* movsx eax, byte [eax] */
void promote_int8_eax():
	if (target_isa == 3):
		ptx_ld_ax(c".s8")
		return
	if (target_isa == 2):
		wasm_promote_eax_op(0x2c)
		return
	if (target_isa == 1):
		a64(op(0x39, 0x800000))   # ldrsb x0,[x0]
		return
	emit_x64_opcode() /* needed ?? */
	emit(3, c"\x0f\xbe\x00")


/* movsx eax, word [eax] */
void promote_int16_eax():
	if (target_isa == 3):
		ptx_ld_ax(c".s16")
		return
	if (target_isa == 2):
		wasm_promote_eax_op(0x2e)
		return
	if (target_isa == 1):
		a64(op(0x79, 0x800000))   # ldrsh x0,[x0]
		return
	emit_x64_opcode() /* needed ?? */
	emit(3, c"\x0f\xbf\x00")


/* x86: mov eax,[eax] ; x64: movsxd rax, dword [rax] (4-byte int32 load) */
void promote_int32_eax():
	if (target_isa == 3):
		ptx_ld_ax(c".s32")
		return
	if (target_isa == 2):
		wasm_promote_eax_op(0x28)
		return
	if (target_isa == 1):
		a64(op(0xb9, 0x800000))   # ldrsw x0,[x0]
		return
	if (word_size == 8):
		emit(3, c"\x48\x63\x00")
	else:
		emit(2, c"\x8b\x00")


/* mov %eax,(%ebx) */
void store_ebx_int32():
	if (target_isa == 3):
		ptx_st_bx(c".u32")
		return
	if (target_isa == 2):
		wasm_store_ebx_op(0x36)
		return
	if (target_isa == 1):
		a64(op(0xb9, 0x000020))   # str w0,[x1]
		return
	emit(2, c"\x89\x03")


/* mov [ebx],eax at the full word width (4 bytes on x86, 8 on x64) */
void store_ebx_word():
	if (target_isa == 3):
		ptx_st_bx(c".u64")
		return
	if (target_isa == 2):
		wasm_store_ebx_op(0x36)
		return
	if (target_isa == 1):
		a64(op(0xf9, 0x000020))   # str x0,[x1]
		return
	emit_x64_opcode()
	emit(2, c"\x89\x03")


/* mov %ax,(%ebx) */
void store_ebx_int16():
	if (target_isa == 3):
		ptx_st_bx(c".u16")
		return
	if (target_isa == 2):
		wasm_store_ebx_op(0x3b)
		return
	if (target_isa == 1):
		a64(op(0x79, 0x000020))   # strh w0,[x1]
		return
	emit(3, c"\x66\x89\x03")


/* mov %al,(%ebx) */
void store_ebx_int8():
	if (target_isa == 3):
		ptx_st_bx(c".u8")
		return
	if (target_isa == 2):
		wasm_store_ebx_op(0x3a)
		return
	if (target_isa == 1):
		a64(op(0x39, 0x000020))   # strb w0,[x1]
		return
	emit(2, c"\x88\x03")


/* mov eax, op(0x12, 0x345678) */
void mov_eax_int32(int v):
	if (target_isa == 3):
		ptx_mov_ax_int(v)
		return
	if (target_isa == 2):
		wasm_mov_eax_int(v)
		return
	if (target_isa == 1):
		arm64_mov_eax_int32(v)
		return
	emit(1, c"\xb8")
	emit_int32(v)


/* mov rax, 0x1234567890123456 */
void mov_rax_int64(int v):
	if (target_isa == 3):
		ptx_mov_ax_int(v)
		return
	if (target_isa == 1):
		arm64_mov_rax_int64(v)
		return
	emit_x64_opcode()
	emit(1, c"\xb8")
	emit_int64(v)


/* mov rax, imm64 with the immediate given as two 32-bit halves. The
   compiler itself may run as a 32-bit process, where a single int cannot
   carry a full 64-bit pattern (e.g. float64 literal bits). */
void mov_rax_int64_halves(int lo, int hi):
	if (target_isa == 3):
		ptx_mov_ax_int64_halves(lo, hi)
		return
	if (target_isa == 1):
		arm64_mov_rax_int64_halves(lo, hi)
		return
	emit(2, c"\x48\xb8")
	emit_int32(lo)
	emit_int32(hi)


/* xor eax, imm32; on x64 this also zeroes the upper half of rax */
void xor_eax_int32(int v):
	if (target_isa == 3):
		ptx_xor_ax_int32(v)
		return
	if (target_isa == 2):
		wasm_ax_op_const(0x73, v)
		return
	if (target_isa == 1):
		# Only w9's low 32 bits reach the eor, but the scratch load spills
		# v into an 8-byte literal, and a bit-31 value (the float sign
		# mask) folds positive on a 64-bit host and negative on the 32-bit
		# seed — breaking the arm64 self-host fixpoint. Canonicalize to
		# the sign-extended-32 form both hosts can represent.
		int high = (v >> 31) & 1
		v = v & 2147483647
		if (high):
			v = v - 2147483647 - 1
		arm64_load_scratch(9, v)
		a64(op(0x4a, 0x090000))   # eor w0,w0,w9 (zero-extends upper half)
		return
	emit(1, c"\x35")
	emit_int32(v)


/* movzx eax, word [eax]: a zero-extending 16-bit load. The promote_int16
   path sign-extends, which would corrupt float16 bit patterns. */
void promote_uint16_eax():
	if (target_isa == 3):
		ptx_ld_ax(c".u16")
		return
	if (target_isa == 2):
		wasm_promote_eax_op(0x2f)
		return
	if (target_isa == 1):
		a64(op(0x79, 0x400000))   # ldrh w0,[x0]
		return
	emit(3, c"\x0f\xb7\x00")


/* mov eax, op(0x12, 0x345678) */
void mov_eax_int(int v):
	if (target_isa == 2):
		wasm_mov_eax_int(v)
		return
	if (target_isa == 1):
		arm64_mov_rax_int64(v)
		return
	if (word_size == 8):
		mov_rax_int64(v)
	else:
		mov_eax_int32(v)


void add_eax_int32(int v):
	if (target_isa == 3):
		ptx_add_ax_int(v)
		return
	if (target_isa == 2):
		wasm_ax_op_const(0x6a, v)
		return
	if (target_isa == 1):
		arm64_add_eax_int32(v)
		return
	emit_x64_opcode()
	emit(1, c"\x05") /* \x2d add eax,... */
	emit_int32(v)


/* imul eax, eax, imm32 */
void imul_eax_int32(int v):
	if (target_isa == 3):
		ptx_mul_ax_int(v)
		return
	if (target_isa == 2):
		wasm_ax_op_const(0x6c, v)
		return
	if (target_isa == 1):
		arm64_imul_eax_int32(v)
		return
	emit_x64_opcode()
	emit(2, c"\x69\xc0")
	emit_int32(v)


void call_eax():
	if (target_isa == 3):
		error(c"gpu code cannot call functions")
		return
	if (target_isa == 2):
		wasm_call_eax()
		return
	if (target_isa == 1):
		if (arm64_pac == 2):
			# pac=full: every W code pointer was paciza-signed at
			# materialization (be_code_ptr_sign), so authenticate and
			# branch. A forged pointer traps here on FPAC hardware.
			a64(op(0xd6, 0x3f081f))   # blraaz x0
			return
		a64(op(0xd6, 0x3f0000))   # blr x0
		return
	emit(2, c"\xff\xd0") /* call *%eax */


void call_relative32(int v):
	emit(1, c"\xe8")
	emit_int32(v)


void not_eax():
	if (target_isa == 3):
		ptx_not_ax()
		return
	if (target_isa == 2):
		wasm_not_eax()
		return
	if (target_isa == 1):
		a64(op(0xaa, 0x2003e0))   # mvn x0,x0
		return
	emit_x64_opcode()
	emit(2, c"\xf7\xd0") /* not eax */


/* push eax */
void push_eax():
	if (target_isa == 3):
		ptx_push_ax()
		return
	if (target_isa == 2):
		wasm_push_eax()
		return
	if (target_isa == 1):
		a64(op(0xf8, 0x1f8f80))   # str x0,[x28,#-8]!
		return
	emit(1, c"\x50")


void push_ebx():
	if (target_isa == 3):
		ptx_push_bx()
		return
	if (target_isa == 2):
		wasm_push_ebx()
		return
	if (target_isa == 1):
		a64(op(0xf8, 0x1f8f81))   # str x1,[x28,#-8]!
		return
	emit(1, c"\x53")


void pop_ebx():
	if (target_isa == 3):
		ptx_pop_bx()
		return
	if (target_isa == 2):
		wasm_pop_ebx()
		return
	if (target_isa == 1):
		a64(op(0xf8, 0x408781))   # ldr x1,[x28],#8
		return
	emit(1, c"\x5b")


void pop_eax():
	if (target_isa == 3):
		ptx_pop_ax()
		return
	if (target_isa == 2):
		wasm_pop_eax()
		return
	if (target_isa == 1):
		a64(op(0xf8, 0x408780))   # ldr x0,[x28],#8
		return
	emit(1, c"\x58")


/* mov eax, ebx */
void mov_eax_ebx():
	if (target_isa == 3):
		ptx_mov_ax_bx()
		return
	if (target_isa == 2):
		wasm_mov_eax_ebx()
		return
	if (target_isa == 1):
		a64(op(0xaa, 0x0103e0))   # mov x0,x1
		return
	emit_x64_opcode()
	emit(2, c"\x89\xd8")


/* lea eax,[esp+op(0x12, 0x345678)] */
void lea_eax_esp_plus(int v):
	if (target_isa == 3):
		ptx_lea_ax_sp(v)
		return
	if (target_isa == 2):
		wasm_lea_eax_esp_plus(v)
		return
	if (target_isa == 1):
		arm64_lea_eax_esp_plus(v)
		return
	emit_x64_opcode()
	emit(3, c"\x8d\x84\x24")
	emit_int(v)


/* mov eax,[esp+op(0x12, 0x345678)] */
void mov_eax_esp_plus(int v):
	if (target_isa == 3):
		ptx_ld_ax_sp(v)
		return
	if (target_isa == 2):
		wasm_mov_eax_esp_plus(v)
		return
	if (target_isa == 1):
		arm64_ldr_reg_wsp(0, v)
		return
	emit_x64_opcode()
	emit(3, c"\x8b\x84\x24")
	emit_int(v)


/* mov ebx,[esp] */
void mov_ebx_esp():
	if (target_isa == 3):
		ptx_ld_bx_sp(0)
		return
	if (target_isa == 2):
		wasm_mov_ebx_esp()
		return
	if (target_isa == 1):
		a64(op(0xf9, 0x400381))   # ldr x1,[x28]
		return
	emit_x64_opcode()
	emit(3, c"\x8b\x1c\x24")


/* mov ebx,[esp+op(0x12, 0x345678)] */
void mov_ebx_esp_plus(int v):
	if (target_isa == 3):
		ptx_ld_bx_sp(v)
		return
	if (target_isa == 2):
		wasm_mov_ebx_esp_plus(v)
		return
	if (target_isa == 1):
		arm64_ldr_reg_wsp(1, v)
		return
	emit_x64_opcode()
	emit(3, c"\x8b\x9c\x24")
	emit_int(v)


/* add ebx, op(0x12, 0x345678) */
void add_ebx_int32(int v):
	if (target_isa == 3):
		ptx_add_bx_int(v)
		return
	if (target_isa == 2):
		wasm_add_ebx_int(v)
		return
	if (target_isa == 1):
		arm64_add_ebx_int32(v)
		return
	emit_x64_opcode()
	emit(2, c"\x81\xc3")
	emit_int32(v)


/* push dword [eax+op(0x12, 0x345678)] */
void push_eax_plus(int v):
	if (target_isa == 3):
		ptx_push_ax_plus(v)
		return
	if (target_isa == 2):
		wasm_push_eax_plus(v)
		return
	if (target_isa == 1):
		arm64_push_eax_plus(v)
		return
	emit(2, c"\xff\xb0")
	emit_int32(v)


/* mov [esp+op(0x12, 0x345678)], eax */
void store_stack_var(int variable_offset):
	if (target_isa == 3):
		ptx_st_sp_ax(variable_offset)
		return
	if (target_isa == 2):
		wasm_store_stack_var(variable_offset)
		return
	if (target_isa == 1):
		arm64_str_reg_wsp(0, variable_offset)
		return
	emit_x64_opcode()
	emit(3, c"\x89\x84\x24")
	emit_int(variable_offset)


/* mov [esp+op(0x12, 0x345678)], ebx */
void store_ebx_stack_var(int variable_offset):
	if (target_isa == 3):
		ptx_st_sp_bx(variable_offset)
		return
	if (target_isa == 2):
		wasm_store_ebx_stack_var(variable_offset)
		return
	if (target_isa == 1):
		arm64_str_reg_wsp(1, variable_offset)
		return
	emit_x64_opcode()
	emit(3, c"\x89\x9c\x24")
	emit_int(variable_offset)


/* add esp, (n * word_size) */
void be_pop(int n):
	if (target_isa == 3):
		ptx_be_pop(n)
		return
	if (target_isa == 2):
		wasm_be_pop(n)
		return
	if (target_isa == 1):
		arm64_be_pop(n)
		return
	emit_x64_opcode()
	emit(6, c"\x81\xc4....")
	save_int(code + codepos - 4, n << word_size_log2)


void jmp_zero_int32(int v):
	if (target_isa == 1):
		arm64_emit_cbz(v)   # cbz x0, <link/placeholder>
		return
	emit_x64_opcode()
	emit(4, c"\x85\xc0\x0f\x84") /* test %eax,%eax ; je ... */
	emit_int32(v)


void jmp_nonzero_int32(int v):
	if (target_isa == 1):
		arm64_emit_cbnz(v)   # cbnz x0, <link/placeholder>
		return
	emit_x64_opcode()
	emit(4, c"\x85\xc0\x0f\x85") /* test %eax,%eax ; jne ... */
	emit_int32(v)


void jmp_int32(int v):
	if (target_isa == 1):
		arm64_emit_b(v)   # b <link/placeholder>
		return
	emit(1, c"\xe9") /* jmp ... */
	emit_int32(v)


###################### structured control-flow regions ########################
# The grammar's branch protocol (docs/projects/wasm_backend.md D3). Every
# forward jump the grammar emits targets the end of an enclosing region
# opened earlier, and every backward jump targets the start of an enclosing
# region — W has no goto, so this covers all of them. Expressing that
# structure explicitly is what lets a target without arbitrary branches
# (WebAssembly's block/loop/br) lower control flow at all; on x86/x64/arm64
# the helpers reproduce the original jump-and-patch bytes exactly, so those
# targets are unaffected.
#
# Protocol: be_ctrl_block() opens a forward-merge region whose branches land
# at its be_ctrl_end(); be_ctrl_loop() opens a backward region whose
# branches land at its start. be_br* branch to an open region by handle.
# Regions strictly nest: be_ctrl_end pops the most recently opened region
# (LIFO), which is what lets a wasm backend compute label depths at branch
# time. On x86/x64/arm64, block regions keep the classic patch chain
# (each site's displacement field holds the previous site's codepos, 0 ends
# the chain) resolved at be_ctrl_end; loop regions record their start and
# patch each branch immediately.

int[256] ctrl_kind_stack    # 0 = forward merge (block), 1 = backward (loop)
int[256] ctrl_val_stack     # block: patch-chain head; loop: start codepos
int ctrl_stack_pos

int be_ctrl_block():
	ctrl_kind_stack[ctrl_stack_pos] = 0
	ctrl_val_stack[ctrl_stack_pos] = 0
	ctrl_stack_pos = ctrl_stack_pos + 1
	if (target_isa == 3):
		# The region's value is a PTX label id; its "Ln:" line lands at
		# the merge point in be_ctrl_end.
		ctrl_val_stack[ctrl_stack_pos - 1] = ptx_new_label()
	if (target_isa == 2):
		wasm_ctrl_block()
	return ctrl_stack_pos - 1

int be_ctrl_loop():
	ctrl_kind_stack[ctrl_stack_pos] = 1
	ctrl_val_stack[ctrl_stack_pos] = codepos
	ctrl_stack_pos = ctrl_stack_pos + 1
	if (target_isa == 3):
		# Backward region: the label is placed at the loop start, here.
		int ptx_loop_label = ptx_new_label()
		ctrl_val_stack[ctrl_stack_pos - 1] = ptx_loop_label
		ptx_place_label(ptx_loop_label)
	if (target_isa == 2):
		wasm_ctrl_loop()
	return ctrl_stack_pos - 1

# A branch site just emitted with region h's chain head in its displacement
# field becomes the new chain head (no-op for loop regions, which patch
# immediately). The bounds-check helpers below use this to thread their
# condition-coded branches through the same protocol.
void be_ctrl_link(int h):
	if (ctrl_kind_stack[h] == 0):
		ctrl_val_stack[h] = codepos

# Branch unconditionally to region h.
void be_br(int h):
	if (target_isa == 3):
		ptx_bra(ctrl_val_stack[h])
		return
	if (target_isa == 2):
		wasm_br(ctrl_stack_pos - 1 - h)
		return
	if (ctrl_kind_stack[h]):
		jmp_int32(0)
		be_branch_patch(codepos, ctrl_val_stack[h])
		return
	jmp_int32(ctrl_val_stack[h])
	be_ctrl_link(h)

# Branch to region h when the accumulator is zero.
void be_br_zero(int h):
	if (target_isa == 3):
		ptx_bra_zero(ctrl_val_stack[h])
		return
	if (target_isa == 2):
		wasm_br_zero(ctrl_stack_pos - 1 - h)
		return
	if (ctrl_kind_stack[h]):
		jmp_zero_int32(0)
		be_branch_patch(codepos, ctrl_val_stack[h])
		return
	jmp_zero_int32(ctrl_val_stack[h])
	be_ctrl_link(h)

# Branch to region h when the accumulator is nonzero.
void be_br_nonzero(int h):
	if (target_isa == 3):
		ptx_bra_nonzero(ctrl_val_stack[h])
		return
	if (target_isa == 2):
		wasm_br_nonzero(ctrl_stack_pos - 1 - h)
		return
	if (ctrl_kind_stack[h]):
		jmp_nonzero_int32(0)
		be_branch_patch(codepos, ctrl_val_stack[h])
		return
	jmp_nonzero_int32(ctrl_val_stack[h])
	be_ctrl_link(h)

# Close the most recently opened region. Block regions resolve their patch
# chain to the current position (their merge point); loop regions have
# nothing to patch.
void be_ctrl_end(int h):
	ctrl_stack_pos = ctrl_stack_pos - 1
	if (target_isa == 3):
		# Forward regions place their merge label here; backward regions
		# placed theirs at the loop start.
		if (ctrl_kind_stack[h] == 0):
			ptx_place_label(ctrl_val_stack[h])
		return
	if (target_isa == 2):
		wasm_ctrl_end()
		return
	if (ctrl_kind_stack[h]):
		return
	int chain = ctrl_val_stack[h]
	while (chain):
		int next_site = be_branch_link_get(chain)
		be_branch_patch(chain, codepos)
		chain = next_site


void inc_dword_esp_plus(int v):
	if (target_isa == 3):
		ptx_inc_sp_slot(v)
		return
	if (target_isa == 2):
		wasm_inc_dword_esp_plus(v)
		return
	if (target_isa == 1):
		arm64_inc_dword_esp_plus(v)
		return
	emit_x64_opcode()
	emit(3, c"\xff\x84\x24") /* inc dword[esp+op(0x12, 0x345678)] */
	emit_int(v)


void neg_eax():
	if (target_isa == 3):
		ptx_neg_ax()
		return
	if (target_isa == 2):
		wasm_neg_eax()
		return
	if (target_isa == 1):
		a64(op(0xcb, 0x0003e0))   # neg x0,x0
		return
	emit_x64_opcode()
	emit(2, c"\xf7\xd8") /* neg %eax */


void add_dword_esp_plus_eax(int v):
	if (target_isa == 3):
		ptx_add_sp_slot_ax(v)
		return
	if (target_isa == 2):
		wasm_add_dword_esp_plus_eax(v)
		return
	if (target_isa == 1):
		arm64_add_dword_esp_plus_eax(v)
		return
	emit_x64_opcode()
	emit(3, c"\x01\x84\x24") /* add [esp+op(0x12, 0x345678)], eax */
	emit_int(v)


/* add word-sized [esp+offset], imm32 */
void add_stack_word_int32(int offset, int v):
	if (target_isa == 3):
		ptx_add_sp_slot_int(offset, v)
		return
	if (target_isa == 2):
		wasm_add_stack_word_int32(offset, v)
		return
	if (target_isa == 1):
		arm64_add_stack_word_int32(offset, v)
		return
	emit_x64_opcode()
	emit(3, c"\x81\x84\x24")
	emit_int(offset)
	emit_int32(v)


############################ word-width ALU helpers ############################
# Each helper emits one binary operator's code at the target word width:
# emit_x64_opcode() prefixes REX.W so 64-bit pointers are not truncated.

/* add %ebx,%eax */
void alu_add():
	if (target_isa == 3):
		ptx_alu_ax_bx(c"add.s64")
		return
	if (target_isa == 2):
		wasm_ax_op_bx(0x6a)
		return
	if (target_isa == 1):
		a64(op(0x8b, 0x010000))   # add x0,x0,x1
		return
	emit_x64_opcode()
	emit(2, c"\x01\xd8")


/* sub %eax,%ebx ; mov %ebx,%eax */
void alu_sub():
	if (target_isa == 3):
		ptx_alu_sub()
		return
	if (target_isa == 2):
		wasm_bx_op_ax(0x6b)
		return
	if (target_isa == 1):
		a64(op(0xcb, 0x000020))   # sub x0,x1,x0
		return
	emit_x64_opcode()
	emit(2, c"\x29\xc3")
	emit_x64_opcode()
	emit(2, c"\x89\xd8")


/* imul %ebx,%eax */
void alu_imul():
	if (target_isa == 3):
		ptx_alu_ax_bx(c"mul.lo.s64")
		return
	if (target_isa == 2):
		wasm_ax_op_bx(0x6c)
		return
	if (target_isa == 1):
		a64(op(0x9b, 0x017c00))   # mul x0,x0,x1
		return
	emit_x64_opcode()
	emit(3, c"\x0f\xaf\xc3")


/* mov %eax,%ebx ; pop %eax ; cdq/cqo ; idiv %ebx (quotient in eax) */
void alu_idiv():
	if (target_isa == 3):
		ptx_alu_pop(c"div.s64")
		return
	if (target_isa == 2):
		wasm_pop_op_ax(0x6d)
		return
	if (target_isa == 1):
		a64(op(0xf8, 0x408789))   # ldr x9,[x28],#8   (pop left operand)
		a64(op(0x9a, 0xc00d20))   # sdiv x0,x9,x0
		return
	emit_x64_opcode()
	emit(2, c"\x89\xc3")
	emit(1, c"\x58")
	emit_x64_opcode()
	emit(1, c"\x99")
	emit_x64_opcode()
	emit(2, c"\xf7\xfb")


/* idiv, then mov %edx,%eax to keep the remainder */
void alu_imod():
	if (target_isa == 3):
		ptx_alu_pop(c"rem.s64")
		return
	if (target_isa == 2):
		wasm_pop_op_ax(0x6f)
		return
	if (target_isa == 1):
		a64(op(0xf8, 0x408789))   # ldr x9,[x28],#8   (pop left operand)
		a64(op(0x9a, 0xc00d2a))   # sdiv x10,x9,x0
		a64(op(0x9b, 0x00a540))   # msub x0,x10,x0,x9  (x0 = x9 - x10*x0)
		return
	alu_idiv()
	emit_x64_opcode()
	emit(2, c"\x89\xd0")


/* mov %eax,%ecx ; pop %eax ; shl %cl,%eax */
void alu_shl():
	if (target_isa == 3):
		ptx_alu_shift(c"shl.b64")
		return
	if (target_isa == 2):
		wasm_pop_op_ax(0x74)
		return
	if (target_isa == 1):
		a64(op(0xf8, 0x408789))   # ldr x9,[x28],#8
		a64(op(0x9a, 0xc02120))   # lslv x0,x9,x0
		return
	emit(2, c"\x89\xc1")
	emit(1, c"\x58")
	emit_x64_opcode()
	emit(2, c"\xd3\xe0")


/* mov %eax,%ecx ; pop %eax ; sar %cl,%eax */
void alu_sar():
	if (target_isa == 3):
		ptx_alu_shift(c"shr.s64")
		return
	if (target_isa == 2):
		wasm_pop_op_ax(0x75)
		return
	if (target_isa == 1):
		a64(op(0xf8, 0x408789))   # ldr x9,[x28],#8
		a64(op(0x9a, 0xc02920))   # asrv x0,x9,x0
		return
	emit(2, c"\x89\xc1")
	emit(1, c"\x58")
	emit_x64_opcode()
	emit(2, c"\xd3\xf8")


/* and %ebx,%eax */
void alu_and():
	if (target_isa == 3):
		ptx_alu_ax_bx(c"and.b64")
		return
	if (target_isa == 2):
		wasm_ax_op_bx(0x71)
		return
	if (target_isa == 1):
		a64(op(0x8a, 0x010000))   # and x0,x0,x1
		return
	emit_x64_opcode()
	emit(2, c"\x21\xd8")


/* or %ebx,%eax */
void alu_or():
	if (target_isa == 3):
		ptx_alu_ax_bx(c"or.b64")
		return
	if (target_isa == 2):
		wasm_ax_op_bx(0x72)
		return
	if (target_isa == 1):
		a64(op(0xaa, 0x010000))   # orr x0,x0,x1
		return
	emit_x64_opcode()
	emit(2, c"\x09\xd8")


/* xor %ebx,%eax */
void alu_xor():
	if (target_isa == 3):
		ptx_alu_ax_bx(c"xor.b64")
		return
	if (target_isa == 2):
		wasm_ax_op_bx(0x73)
		return
	if (target_isa == 1):
		a64(op(0xca, 0x010000))   # eor x0,x0,x1
		return
	emit_x64_opcode()
	emit(2, c"\x31\xd8")


/* cmp %eax,%ebx ; setCC %al ; movzbl %al,%eax
   setcc_opcode is the second setCC byte: 0x9c setl, 0x9d setge, 0x9e setle,
   0x9f setg, 0x94 sete, 0x95 setne */
void alu_cmp_set(int setcc_opcode):
	if (target_isa == 3):
		ptx_alu_cmp_set(setcc_opcode)
		return
	if (target_isa == 2):
		wasm_alu_cmp_set(setcc_opcode)
		return
	if (target_isa == 1):
		arm64_alu_cmp_set(setcc_opcode)
		return
	emit_x64_opcode()
	emit(2, c"\x39\xc3")
	emit_int8(15)
	emit_int8(setcc_opcode)
	emit(4, c"\xc0\x0f\xb6\xc0")


/* booleanize: test %eax,%eax ; setCC %al ; movzbl %al,%eax
   setcc_opcode: 0x94 sete (logical not), 0x95 setne (truth value) */
void alu_test_set(int setcc_opcode):
	if (target_isa == 3):
		ptx_alu_test_set(setcc_opcode)
		return
	if (target_isa == 2):
		wasm_alu_test_set(setcc_opcode)
		return
	if (target_isa == 1):
		arm64_alu_test_set(setcc_opcode)
		return
	emit_x64_opcode()
	emit(2, c"\x85\xc0")
	emit_int8(15)
	emit_int8(setcc_opcode)
	emit(4, c"\xc0\x0f\xb6\xc0")


########################## 32-bit limb intrinsics ##########################
# Lowering for mul_hi/mul_wide/add_carry (grammar/limb_builtin.w, #213).
# All three read only the operands' low 32 bits, as unsigned, and produce
# results whose low 32 bits are the meaningful pattern (zero-extended on
# the 64-bit targets, like a `& mask32` result). On x86/x64 the 32-bit
# MUL/ADD forms are emitted without a REX.W prefix on purpose: they read
# only the low halves and their 32-bit register writes zero-extend on
# x64, so one byte sequence serves both word sizes. Only the operations
# touching the result pointer are word-sized.

/* mov ecx, eax at the full word width (a pointer operand) */
void mov_ecx_eax():
	if (target_isa == 3):
		error(c"mul_hi/mul_wide/add_carry are not supported in gpu code")
		return
	if (target_isa == 2):
		wasm_mov_ecx_eax()
		return
	if (target_isa == 1):
		a64(op(0xaa, 0x0003e2))   # mov x2,x0
		return
	emit_x64_opcode()
	emit(2, c"\x89\xc1")


/* mul %ebx (edx:eax = eax*ebx, unsigned 32x32) ; mov %edx,%eax */
void alu_mul_hi():
	if (target_isa == 3):
		error(c"mul_hi/mul_wide/add_carry are not supported in gpu code")
		return
	if (target_isa == 2):
		wasm_alu_mul_hi()
		return
	if (target_isa == 1):
		a64(op(0x9b, 0xa07c20))   # umull x0,w1,w0
		a64(op(0xd3, 0x60fc00))   # lsr x0,x0,#32
		return
	emit(2, c"\xf7\xe3")
	emit(2, c"\x89\xd0")


/* mul %ebx ; mov [ecx],edx: low product half stays in eax, the high half
   is stored word-sized through the pointer in ecx */
void alu_mul_wide():
	if (target_isa == 3):
		error(c"mul_hi/mul_wide/add_carry are not supported in gpu code")
		return
	if (target_isa == 2):
		wasm_alu_mul_wide()
		return
	if (target_isa == 1):
		a64(op(0x9b, 0xa07c20))   # umull x0,w1,w0
		a64(op(0xd3, 0x60fc09))   # lsr x9,x0,#32
		a64(op(0xf9, 0x000049))   # str x9,[x2]
		a64(op(0x2a, 0x0003e0))   # mov w0,w0 (zero-extend the low half)
		return
	emit(2, c"\xf7\xe3")
	emit_x64_opcode()
	emit(2, c"\x89\x11")


/* add %ebx,%eax (32-bit: CF = carry out of bit 31) ; mov edx,0 (flags
   preserved) ; adc edx,0 ; the carry is stored word-sized through the
   pointer in ecx and the wrapped sum stays in eax */
void alu_add_carry():
	if (target_isa == 3):
		error(c"mul_hi/mul_wide/add_carry are not supported in gpu code")
		return
	if (target_isa == 2):
		wasm_alu_add_carry()
		return
	if (target_isa == 1):
		a64(op(0x2a, 0x0003e0))   # mov w0,w0 (zero-extend the operands:
		a64(op(0x2a, 0x0103e1))   # mov w1,w1  the sum then fits 33 bits)
		a64(op(0x8b, 0x000020))   # add x0,x1,x0
		a64(op(0xd3, 0x60fc09))   # lsr x9,x0,#32
		a64(op(0xf9, 0x000049))   # str x9,[x2]
		a64(op(0x2a, 0x0003e0))   # mov w0,w0 (keep the wrapped low half)
		return
	emit(2, c"\x01\xd8")
	emit(1, c"\xba")
	emit_int32(0)
	emit(3, c"\x83\xd2\x00")
	emit_x64_opcode()
	emit(2, c"\x89\x11")

####################### end of 32-bit limb intrinsics ######################

######################## 32-bit bit-manipulation intrinsics ########################
# Lowering for shr/rotl/rotr/popcount/clz/ctz (grammar/bit_builtin.w, #249).
# All six read only the operands' low 32 bits, as unsigned, and produce
# results whose low 32 bits are the meaningful pattern (zero-extended on
# the 64-bit targets, like a `& mask32` result). Shift/rotate counts are
# masked to 5 bits (count mod 32) — the hardware behavior of the 32-bit
# x86 shifts and the A64 w-register LSRV/RORV. On x86/x64 every form is
# emitted without a REX.W prefix on purpose: the 32-bit register writes
# zero-extend on x64, so one byte sequence serves both word sizes.
# BSR/BSF are baseline ISA; POPCNT/LZCNT/TZCNT are not, so popcount is
# the classic SWAR reduction and the clz/ctz zero case (both defined to
# return 32) is an explicit branch around the undefined-on-zero BSR/BSF.

/* two-operand entry: mov %eax,%ecx ; mov %ebx,%eax puts the value (from
   the popped left operand in ebx) into eax and the count into cl */
void alu_bit_operands():
	emit(2, c"\x89\xc1")
	emit(2, c"\x89\xd8")


/* value in ebx, count in eax: shr %cl,%eax (logical right shift) */
void alu_shr32():
	if (target_isa == 3):
		error(c"bit intrinsics are not supported in gpu code")
		return
	if (target_isa == 2):
		wasm_alu_shr32()
		return
	if (target_isa == 1):
		a64(op(0x1a, 0xc02420))   # lsrv w0,w1,w0 (count mod 32, zero-extends)
		return
	alu_bit_operands()
	emit(2, c"\xd3\xe8")


/* value in ebx, count in eax: rol %cl,%eax */
void alu_rotl32():
	if (target_isa == 3):
		error(c"bit intrinsics are not supported in gpu code")
		return
	if (target_isa == 2):
		wasm_alu_rotl32()
		return
	if (target_isa == 1):
		# A64 has no rotate-left: rotl(a,n) == rotr(a, (-n) mod 32)
		a64(op(0x4b, 0x0003e9))   # neg w9,w0
		a64(op(0x1a, 0xc92c20))   # rorv w0,w1,w9
		return
	alu_bit_operands()
	emit(2, c"\xd3\xc0")


/* value in ebx, count in eax: ror %cl,%eax */
void alu_rotr32():
	if (target_isa == 3):
		error(c"bit intrinsics are not supported in gpu code")
		return
	if (target_isa == 2):
		wasm_alu_rotr32()
		return
	if (target_isa == 1):
		a64(op(0x1a, 0xc02c20))   # rorv w0,w1,w0
		return
	alu_bit_operands()
	emit(2, c"\xd3\xc8")


/* set-bit count of the low 32 bits of eax, via the SWAR reduction
   v -= (v>>1) & 0x55555555
   v = (v & 0x33333333) + ((v>>2) & 0x33333333)
   v = (v + (v>>4)) & 0x0f0f0f0f
   v = (v * 0x01010101) >> 24
   (POPCNT is not baseline ISA; the masks have bit 31 clear, so they are
   plain immediates) */
void alu_popcount32():
	if (target_isa == 3):
		error(c"bit intrinsics are not supported in gpu code")
		return
	if (target_isa == 2):
		wasm_alu_popcount32()
		return
	if (target_isa == 1):
		a64(op(0x53, 0x017c09))   # lsr w9,w0,#1
		arm64_load_scratch(10, 0x55555555)
		a64(op(0x0a, 0x0a0129))   # and w9,w9,w10
		a64(op(0x4b, 0x090000))   # sub w0,w0,w9
		arm64_load_scratch(10, 0x33333333)
		a64(op(0x0a, 0x0a0009))   # and w9,w0,w10
		a64(op(0x53, 0x027c00))   # lsr w0,w0,#2
		a64(op(0x0a, 0x0a0000))   # and w0,w0,w10
		a64(op(0x0b, 0x090000))   # add w0,w0,w9
		a64(op(0x53, 0x047c09))   # lsr w9,w0,#4
		a64(op(0x0b, 0x090000))   # add w0,w0,w9
		arm64_load_scratch(10, 0x0f0f0f0f)
		a64(op(0x0a, 0x0a0000))   # and w0,w0,w10
		arm64_load_scratch(9, 0x01010101)
		a64(op(0x1b, 0x097c00))   # mul w0,w0,w9
		a64(op(0x53, 0x187c00))   # lsr w0,w0,#24 (zero-extends)
		return
	emit(2, c"\x89\xc2")          # mov %eax,%edx
	emit(3, c"\xc1\xea\x01")      # shr $1,%edx
	emit(2, c"\x81\xe2")          # and $0x55555555,%edx
	emit_int32(0x55555555)
	emit(2, c"\x29\xd0")          # sub %edx,%eax
	emit(2, c"\x89\xc2")          # mov %eax,%edx
	emit(3, c"\xc1\xea\x02")      # shr $2,%edx
	emit(1, c"\x25")              # and $0x33333333,%eax
	emit_int32(0x33333333)
	emit(2, c"\x81\xe2")          # and $0x33333333,%edx
	emit_int32(0x33333333)
	emit(2, c"\x01\xd0")          # add %edx,%eax
	emit(2, c"\x89\xc2")          # mov %eax,%edx
	emit(3, c"\xc1\xea\x04")      # shr $4,%edx
	emit(2, c"\x01\xd0")          # add %edx,%eax
	emit(1, c"\x25")              # and $0x0f0f0f0f,%eax
	emit_int32(0x0f0f0f0f)
	emit(2, c"\x69\xc0")          # imul $0x01010101,%eax,%eax
	emit_int32(0x01010101)
	emit(3, c"\xc1\xe8\x18")      # shr $24,%eax


/* leading-zero count of the low 32 bits of eax; clz(0) == 32.
   BSR leaves ZF set (and the destination undefined) on zero input, so
   the zero case branches over the 31-index conversion */
void alu_clz32():
	if (target_isa == 3):
		error(c"bit intrinsics are not supported in gpu code")
		return
	if (target_isa == 2):
		wasm_alu_clz32()
		return
	if (target_isa == 1):
		a64(op(0x5a, 0xc01000))   # clz w0,w0 (clz(0) == 32 in hardware)
		return
	emit(3, c"\x0f\xbd\xd0")      # bsr %eax,%edx (ZF=1 when eax==0)
	emit(1, c"\xb8")              # mov $32,%eax (flags preserved)
	emit_int32(32)
	emit(2, c"\x74\x05")          # jz +5 (zero input: keep the 32)
	emit(3, c"\x83\xf2\x1f")      # xor $31,%edx (31 - highest set index)
	emit(2, c"\x89\xd0")          # mov %edx,%eax


/* trailing-zero count of the low 32 bits of eax; ctz(0) == 32.
   BSF is undefined on zero input the same way BSR is */
void alu_ctz32():
	if (target_isa == 3):
		error(c"bit intrinsics are not supported in gpu code")
		return
	if (target_isa == 2):
		wasm_alu_ctz32()
		return
	if (target_isa == 1):
		a64(op(0x5a, 0xc00000))   # rbit w0,w0
		a64(op(0x5a, 0xc01000))   # clz w0,w0
		return
	emit(3, c"\x0f\xbc\xd0")      # bsf %eax,%edx (ZF=1 when eax==0)
	emit(1, c"\xb8")              # mov $32,%eax (flags preserved)
	emit_int32(32)
	emit(2, c"\x74\x02")          # jz +2 (zero input: keep the 32)
	emit(2, c"\x89\xd0")          # mov %edx,%eax

#################### end of 32-bit bit-manipulation intrinsics ####################


void int3():
	if (target_isa == 3):
		ptx_trap()
		return
	if (target_isa == 2):
		wasm_int3()
		return
	if (target_isa == 1):
		a64(op(0xd4, 0x200000))   # brk #0
		return
	emit(1, c"\xcc") /* int3 */


/* Bounds checks (issue #228): each helper emits a compare plus a
   conditional branch into control region h (a be_ctrl_block, threaded
   through the same patch-chain protocol be_br uses). The grammar layer
   (bounds_trap_call in grammar/postfix_expr.w) opens a region ending at a
   trap block that calls the runtime diagnostic helper for the
   bounds_branch_* sites, and a region past it for the bounds_skip_* sites,
   so a failed check reports the offending index and length instead of dying
   on a bare int3/brk #0. The in-bounds fall-through path clobbers only
   flags, like the old compare + skip + int3 form. */

/* branch to region h when eax is negative: test eax,eax ; js rel32 */
void bounds_branch_eax_negative(int h):
	if (target_isa == 2):
		wasm_bounds_branch_eax_negative(ctrl_stack_pos - 1 - h)
		return
	if (target_isa == 1):
		arm64_bounds_branch_eax_negative(ctrl_val_stack[h])
		be_ctrl_link(h)
		return
	emit_x64_opcode()
	emit(2, c"\x85\xc0") /* test eax,eax */
	emit(2, c"\x0f\x88") /* js rel32 (chain link) */
	emit_int32(ctrl_val_stack[h])
	be_ctrl_link(h)


/* branch to region h when ebx is negative: test ebx,ebx ; js rel32 */
void bounds_branch_ebx_negative(int h):
	if (target_isa == 2):
		wasm_bounds_branch_ebx_negative(ctrl_stack_pos - 1 - h)
		return
	if (target_isa == 1):
		arm64_bounds_branch_ebx_negative(ctrl_val_stack[h])
		be_ctrl_link(h)
		return
	emit_x64_opcode()
	emit(2, c"\x85\xdb") /* test ebx,ebx */
	emit(2, c"\x0f\x88") /* js rel32 (chain link) */
	emit_int32(ctrl_val_stack[h])
	be_ctrl_link(h)


/* branch to region h when ebx > eax (signed): cmp eax,ebx ; jg rel32 */
void bounds_branch_ebx_greater_eax(int h):
	if (target_isa == 2):
		wasm_bounds_branch_ebx_greater_eax(ctrl_stack_pos - 1 - h)
		return
	if (target_isa == 1):
		arm64_bounds_branch_ebx_greater_eax(ctrl_val_stack[h])
		be_ctrl_link(h)
		return
	emit_x64_opcode()
	emit(2, c"\x39\xc3") /* cmp eax,ebx */
	emit(2, c"\x0f\x8f") /* jg rel32 (chain link) */
	emit_int32(ctrl_val_stack[h])
	be_ctrl_link(h)


/* branch to region h when ebx < eax (index in ebx, length in eax) */
void bounds_skip_ebx_less_eax(int h):
	if (target_isa == 2):
		wasm_bounds_skip_ebx_less_eax(ctrl_stack_pos - 1 - h)
		return
	if (target_isa == 1):
		arm64_bounds_skip_ebx_less_eax(ctrl_val_stack[h])
		be_ctrl_link(h)
		return
	emit_x64_opcode()
	emit(2, c"\x39\xc3") /* cmp eax,ebx */
	emit(2, c"\x0f\x8c") /* jl rel32 (chain link) */
	emit_int32(ctrl_val_stack[h])
	be_ctrl_link(h)


/* branch to region h when ebx <= eax */
void bounds_skip_ebx_less_equal_eax(int h):
	if (target_isa == 2):
		wasm_bounds_skip_ebx_less_equal_eax(ctrl_stack_pos - 1 - h)
		return
	if (target_isa == 1):
		arm64_bounds_skip_ebx_less_equal_eax(ctrl_val_stack[h])
		be_ctrl_link(h)
		return
	emit_x64_opcode()
	emit(2, c"\x39\xc3") /* cmp eax,ebx */
	emit(2, c"\x0f\x8e") /* jle rel32 (chain link) */
	emit_int32(ctrl_val_stack[h])
	be_ctrl_link(h)


/* branch to region h when eax <= limit */
void bounds_skip_eax_less_equal_int32(int limit, int h):
	if (target_isa == 2):
		wasm_bounds_skip_eax_less_equal_int32(limit, ctrl_stack_pos - 1 - h)
		return
	if (target_isa == 1):
		arm64_bounds_skip_eax_less_equal_int32(limit, ctrl_val_stack[h])
		be_ctrl_link(h)
		return
	emit_x64_opcode()
	emit(1, c"\x3d") /* cmp imm32,eax */
	emit_int32(limit)
	emit(2, c"\x0f\x8e") /* jle rel32 (chain link) */
	emit_int32(ctrl_val_stack[h])
	be_ctrl_link(h)

void nop():
	if (target_isa == 3):
		return
	if (target_isa == 2):
		wasm_nop()
		return
	if (target_isa == 1):
		a64(op(0xd5, 0x03201f))   # nop
		return
	emit(1, c"\x90") /* nop */


void ret():
	if (target_isa == 3):
		ptx_ret()
		return
	if (target_isa == 2):
		wasm_ret()
		return
	if (target_isa == 1):
		a64(op(0xf8, 0x40879e))   # ldr x30,[x28],#8  (pop the return-address slot)
		if (arm64_pac):
			a64(op(0xda, 0xc1139e))   # autia x30, x28
		a64(op(0xd6, 0x5f03c0))   # ret
		return
	emit(1, c"\xc3") /* ret */

############################## end of x86 opcodes ##############################
