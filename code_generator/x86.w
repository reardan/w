void emit_x64_opcode():
	if (word_size == 8):
		emit(1, c"\x48")



################################# x86 opcodes #################################
# Each helper dispatches to its AArch64 twin (code_generator/arm64.w) when
# target_isa == 1; the x86/x64 byte sequences below are otherwise unchanged,
# so those targets stay byte-identical.

/* push dword 0x12 */
void push_int8(int v):
	if (target_isa == 1):
		arm64_push_imm(v)
		return
	emit_int8(106)
	emit_int8(v)


/* push dword op(0x12, 0x345678) */
void push_int32(int v):
	if (target_isa == 1):
		arm64_push_imm(v)
		return
	emit_int8(104)
	emit_int32(v)


void push_int(int v):
	push_int32(v)


/* mov eax,[eax] */
void promote_eax():
	if (target_isa == 1):
		a64(op(0xf9, 0x400000))   # ldr x0,[x0]
		return
	emit_x64_opcode()
	emit(2, c"\x8b\x00")


/* mov ebx,[ebx] */
void promote_ebx():
	if (target_isa == 1):
		a64(op(0xf9, 0x400021))   # ldr x1,[x1]
		return
	emit_x64_opcode()
	emit(2, c"\x8b\x1b")


/* movsx eax, byte [eax] */
void promote_int8_eax():
	if (target_isa == 1):
		a64(op(0x39, 0x800000))   # ldrsb x0,[x0]
		return
	emit_x64_opcode() /* needed ?? */
	emit(3, c"\x0f\xbe\x00")


/* movsx eax, word [eax] */
void promote_int16_eax():
	if (target_isa == 1):
		a64(op(0x79, 0x800000))   # ldrsh x0,[x0]
		return
	emit_x64_opcode() /* needed ?? */
	emit(3, c"\x0f\xbf\x00")


/* x86: mov eax,[eax] ; x64: movsxd rax, dword [rax] (4-byte int32 load) */
void promote_int32_eax():
	if (target_isa == 1):
		a64(op(0xb9, 0x800000))   # ldrsw x0,[x0]
		return
	if (word_size == 8):
		emit(3, c"\x48\x63\x00")
	else:
		emit(2, c"\x8b\x00")


/* mov %eax,(%ebx) */
void store_ebx_int32():
	if (target_isa == 1):
		a64(op(0xb9, 0x000020))   # str w0,[x1]
		return
	emit(2, c"\x89\x03")


/* mov [ebx],eax at the full word width (4 bytes on x86, 8 on x64) */
void store_ebx_word():
	if (target_isa == 1):
		a64(op(0xf9, 0x000020))   # str x0,[x1]
		return
	emit_x64_opcode()
	emit(2, c"\x89\x03")


/* mov %ax,(%ebx) */
void store_ebx_int16():
	if (target_isa == 1):
		a64(op(0x79, 0x000020))   # strh w0,[x1]
		return
	emit(3, c"\x66\x89\x03")


/* mov %al,(%ebx) */
void store_ebx_int8():
	if (target_isa == 1):
		a64(op(0x39, 0x000020))   # strb w0,[x1]
		return
	emit(2, c"\x88\x03")


/* mov eax, op(0x12, 0x345678) */
void mov_eax_int32(int v):
	if (target_isa == 1):
		arm64_mov_eax_int32(v)
		return
	emit(1, c"\xb8")
	emit_int32(v)


/* mov rax, 0x1234567890123456 */
void mov_rax_int64(int v):
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
	if (target_isa == 1):
		arm64_mov_rax_int64_halves(lo, hi)
		return
	emit(2, c"\x48\xb8")
	emit_int32(lo)
	emit_int32(hi)


/* xor eax, imm32; on x64 this also zeroes the upper half of rax */
void xor_eax_int32(int v):
	if (target_isa == 1):
		arm64_load_scratch(9, v)
		a64(op(0x4a, 0x090000))   # eor w0,w0,w9 (zero-extends upper half)
		return
	emit(1, c"\x35")
	emit_int32(v)


/* movzx eax, word [eax]: a zero-extending 16-bit load. The promote_int16
   path sign-extends, which would corrupt float16 bit patterns. */
void promote_uint16_eax():
	if (target_isa == 1):
		a64(op(0x79, 0x400000))   # ldrh w0,[x0]
		return
	emit(3, c"\x0f\xb7\x00")


/* mov eax, op(0x12, 0x345678) */
void mov_eax_int(int v):
	if (target_isa == 1):
		arm64_mov_rax_int64(v)
		return
	if (word_size == 8):
		mov_rax_int64(v)
	else:
		mov_eax_int32(v)


void add_eax_int32(int v):
	if (target_isa == 1):
		arm64_add_eax_int32(v)
		return
	emit_x64_opcode()
	emit(1, c"\x05") /* \x2d add eax,... */
	emit_int32(v)


/* imul eax, eax, imm32 */
void imul_eax_int32(int v):
	if (target_isa == 1):
		arm64_imul_eax_int32(v)
		return
	emit_x64_opcode()
	emit(2, c"\x69\xc0")
	emit_int32(v)


void call_eax():
	if (target_isa == 1):
		a64(op(0xd6, 0x3f0000))   # blr x0
		return
	emit(2, c"\xff\xd0") /* call *%eax */


void call_relative32(int v):
	emit(1, c"\xe8")
	emit_int32(v)


void not_eax():
	if (target_isa == 1):
		a64(op(0xaa, 0x2003e0))   # mvn x0,x0
		return
	emit_x64_opcode()
	emit(2, c"\xf7\xd0") /* not eax */


/* push eax */
void push_eax():
	if (target_isa == 1):
		a64(op(0xf8, 0x1f8f80))   # str x0,[x28,#-8]!
		return
	emit(1, c"\x50")


void push_ebx():
	if (target_isa == 1):
		a64(op(0xf8, 0x1f8f81))   # str x1,[x28,#-8]!
		return
	emit(1, c"\x53")


void pop_ebx():
	if (target_isa == 1):
		a64(op(0xf8, 0x408781))   # ldr x1,[x28],#8
		return
	emit(1, c"\x5b")


void pop_eax():
	if (target_isa == 1):
		a64(op(0xf8, 0x408780))   # ldr x0,[x28],#8
		return
	emit(1, c"\x58")


/* mov eax, ebx */
void mov_eax_ebx():
	if (target_isa == 1):
		a64(op(0xaa, 0x0103e0))   # mov x0,x1
		return
	emit_x64_opcode()
	emit(2, c"\x89\xd8")


/* lea eax,[esp+op(0x12, 0x345678)] */
void lea_eax_esp_plus(int v):
	if (target_isa == 1):
		arm64_lea_eax_esp_plus(v)
		return
	emit_x64_opcode()
	emit(3, c"\x8d\x84\x24")
	emit_int(v)


/* mov eax,[esp+op(0x12, 0x345678)] */
void mov_eax_esp_plus(int v):
	if (target_isa == 1):
		arm64_ldr_reg_wsp(0, v)
		return
	emit_x64_opcode()
	emit(3, c"\x8b\x84\x24")
	emit_int(v)


/* mov ebx,[esp] */
void mov_ebx_esp():
	if (target_isa == 1):
		a64(op(0xf9, 0x400381))   # ldr x1,[x28]
		return
	emit_x64_opcode()
	emit(3, c"\x8b\x1c\x24")


/* mov ebx,[esp+op(0x12, 0x345678)] */
void mov_ebx_esp_plus(int v):
	if (target_isa == 1):
		arm64_ldr_reg_wsp(1, v)
		return
	emit_x64_opcode()
	emit(3, c"\x8b\x9c\x24")
	emit_int(v)


/* add ebx, op(0x12, 0x345678) */
void add_ebx_int32(int v):
	if (target_isa == 1):
		arm64_add_ebx_int32(v)
		return
	emit_x64_opcode()
	emit(2, c"\x81\xc3")
	emit_int32(v)


/* push dword [eax+op(0x12, 0x345678)] */
void push_eax_plus(int v):
	if (target_isa == 1):
		arm64_push_eax_plus(v)
		return
	emit(2, c"\xff\xb0")
	emit_int32(v)


/* mov [esp+op(0x12, 0x345678)], eax */
void store_stack_var(int variable_offset):
	if (target_isa == 1):
		arm64_str_reg_wsp(0, variable_offset)
		return
	emit_x64_opcode()
	emit(3, c"\x89\x84\x24")
	emit_int(variable_offset)


/* mov [esp+op(0x12, 0x345678)], ebx */
void store_ebx_stack_var(int variable_offset):
	if (target_isa == 1):
		arm64_str_reg_wsp(1, variable_offset)
		return
	emit_x64_opcode()
	emit(3, c"\x89\x9c\x24")
	emit_int(variable_offset)


/* add esp, (n * word_size) */
void be_pop(int n):
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


void inc_dword_esp_plus(int v):
	if (target_isa == 1):
		arm64_inc_dword_esp_plus(v)
		return
	emit_x64_opcode()
	emit(3, c"\xff\x84\x24") /* inc dword[esp+op(0x12, 0x345678)] */
	emit_int(v)


void neg_eax():
	if (target_isa == 1):
		a64(op(0xcb, 0x0003e0))   # neg x0,x0
		return
	emit_x64_opcode()
	emit(2, c"\xf7\xd8") /* neg %eax */


void add_dword_esp_plus_eax(int v):
	if (target_isa == 1):
		arm64_add_dword_esp_plus_eax(v)
		return
	emit_x64_opcode()
	emit(3, c"\x01\x84\x24") /* add [esp+op(0x12, 0x345678)], eax */
	emit_int(v)


/* add word-sized [esp+offset], imm32 */
void add_stack_word_int32(int offset, int v):
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
	if (target_isa == 1):
		a64(op(0x8b, 0x010000))   # add x0,x0,x1
		return
	emit_x64_opcode()
	emit(2, c"\x01\xd8")


/* sub %eax,%ebx ; mov %ebx,%eax */
void alu_sub():
	if (target_isa == 1):
		a64(op(0xcb, 0x000020))   # sub x0,x1,x0
		return
	emit_x64_opcode()
	emit(2, c"\x29\xc3")
	emit_x64_opcode()
	emit(2, c"\x89\xd8")


/* imul %ebx,%eax */
void alu_imul():
	if (target_isa == 1):
		a64(op(0x9b, 0x017c00))   # mul x0,x0,x1
		return
	emit_x64_opcode()
	emit(3, c"\x0f\xaf\xc3")


/* mov %eax,%ebx ; pop %eax ; cdq/cqo ; idiv %ebx (quotient in eax) */
void alu_idiv():
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
	if (target_isa == 1):
		a64(op(0x8a, 0x010000))   # and x0,x0,x1
		return
	emit_x64_opcode()
	emit(2, c"\x21\xd8")


/* or %ebx,%eax */
void alu_or():
	if (target_isa == 1):
		a64(op(0xaa, 0x010000))   # orr x0,x0,x1
		return
	emit_x64_opcode()
	emit(2, c"\x09\xd8")


/* xor %ebx,%eax */
void alu_xor():
	if (target_isa == 1):
		a64(op(0xca, 0x010000))   # eor x0,x0,x1
		return
	emit_x64_opcode()
	emit(2, c"\x31\xd8")


/* cmp %eax,%ebx ; setCC %al ; movzbl %al,%eax
   setcc_opcode is the second setCC byte: 0x9c setl, 0x9d setge, 0x9e setle,
   0x9f setg, 0x94 sete, 0x95 setne */
void alu_cmp_set(int setcc_opcode):
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
	if (target_isa == 1):
		arm64_alu_test_set(setcc_opcode)
		return
	emit_x64_opcode()
	emit(2, c"\x85\xc0")
	emit_int8(15)
	emit_int8(setcc_opcode)
	emit(4, c"\xc0\x0f\xb6\xc0")



void int3():
	if (target_isa == 1):
		a64(op(0xd4, 0x200000))   # brk #0
		return
	emit(1, c"\xcc") /* int3 */


/* trap when eax is negative */
void bounds_check_eax_nonnegative():
	if (target_isa == 1):
		arm64_bounds_check_eax_nonnegative()
		return
	emit_x64_opcode()
	emit(2, c"\x85\xc0") /* test eax,eax */
	emit(2, c"\x79\x01") /* jns +1 */
	int3()


/* trap unless ebx < eax (index in ebx, length in eax) */
void bounds_check_ebx_less_eax():
	if (target_isa == 1):
		arm64_bounds_check_ebx_less_eax()
		return
	emit_x64_opcode()
	emit(2, c"\x39\xc3") /* cmp eax,ebx */
	emit(2, c"\x7c\x01") /* jl +1 */
	int3()


/* trap unless ebx <= eax */
void bounds_check_ebx_less_equal_eax():
	if (target_isa == 1):
		arm64_bounds_check_ebx_less_equal_eax()
		return
	emit_x64_opcode()
	emit(2, c"\x39\xc3") /* cmp eax,ebx */
	emit(2, c"\x7e\x01") /* jle +1 */
	int3()


/* trap unless eax <= limit */
void bounds_check_eax_less_equal_int32(int limit):
	if (target_isa == 1):
		arm64_bounds_check_eax_less_equal_int32(limit)
		return
	emit_x64_opcode()
	emit(1, c"\x3d") /* cmp imm32,eax */
	emit_int32(limit)
	emit(2, c"\x7e\x01") /* jle +1 */
	int3()

void nop():
	if (target_isa == 1):
		a64(op(0xd5, 0x03201f))   # nop
		return
	emit(1, c"\x90") /* nop */


void ret(): 
	if (target_isa == 1):
		a64(op(0xf8, 0x40879e))   # ldr x30,[x28],#8  (pop the return-address slot)
		if (arm64_pac):
			a64(op(0xda, 0xc1139e))   # autia x30, x28
		a64(op(0xd6, 0x5f03c0))   # ret
		return
	emit(1, c"\xc3") /* ret */

############################## end of x86 opcodes ##############################
