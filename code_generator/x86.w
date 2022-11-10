void emit_x64_opcode():
	if (word_size == 8):
		emit(1, "\x48")



################################# x86 opcodes #################################
/* push dword 0x12 */
void push_int8(int v):
	emit_int8("\x6a")
	emit_int8(v)


/* push dword 0x12345678 */
void push_int32(int v):
	emit_int8("\x68")
	emit_int32(v)


void push_int(int v):
	push_int32(v)


/* mov eax,[eax] */
void promote_eax():
	emit_x64_opcode()
	emit(2, "\x8b\x00")


/* movsx eax, byte [eax] */
void promote_int8_eax():
	emit_x64_opcode() /* needed ?? */
	emit(3, "\x0f\xbe\x00")


/* movsx eax, word [eax] */
void promote_int16_eax():
	emit_x64_opcode() /* needed ?? */
	emit(3, "\x0f\xbf\x00")


/* mov %eax,(%ebx) */
void store_ebx_int32():
	emit(2, "\x89\x03")


/* mov %ax,(%ebx) */
void store_ebx_int16():
	emit(3, "\x66\x89\x03")


/* mov %al,(%ebx) */
void store_ebx_int8():
	emit(2, "\x88\x03")


/* mov eax, 0x12345678 */
void mov_eax_int32(int v):
	emit(1, "\xb8")
	emit_int32(v)


/* mov rax, 0x1234567890123456 */
void mov_rax_int64(int v):
	emit_x64_opcode()
	emit(1, "\xb8")
	emit_int64(v)


/* mov eax, 0x12345678 */
void mov_eax_int(int v):
	if (word_size == 8):
		mov_rax_int64(v)
	else:
		mov_eax_int32(v)


void add_eax_int32(int v):
	emit(1, "\x05") /* \x2d add eax,... */
	emit_int32(v)


void call_eax():
	emit(2, "\xff\xd0") /* call *%eax */


void call_relative32(int v):
	emit(1, "\xe8")
	emit_int32(v)


void not_eax():
	emit(2, "\xf7\xd0") /* not eax */


/* push eax */
void push_eax():
	emit(1, "\x50")


void push_ebx():
	emit(1, "\x53")


void pop_ebx():
	emit(1, "\x5b")


void pop_eax():
	emit(1, "\x58")


/* lea eax,[esp+0x12345678] */
void lea_eax_esp_plus(int v):
	emit_x64_opcode()
	emit(3, "\x8d\x84\x24")
	emit_int(v)


/* mov eax,[esp+0x12345678] */
void mov_eax_esp_plus(int v):
	emit_x64_opcode()
	emit(3, "\x8b\x84\x24")
	emit_int(v)


/* mov [esp+0x12345678], eax */
void store_stack_var(int variable_offset):
	emit_x64_opcode()
	emit(3, "\x89\x84\x24")
	emit_int(variable_offset)


/* add esp, (n * word_size) */
void be_pop(int n):
	emit_x64_opcode()
	emit(6, "\x81\xc4....") 
	save_int(code + codepos - 4, n << word_size_log2)


void jmp_zero_int32(int v):
	emit(4, "\x85\xc0\x0f\x84") /* test %eax,%eax ; je ... */
	emit_int32(v)


void jmp_int32(int v):
	emit(1, "\xe9") /* jmp ... */
	emit_int32(v)


void inc_dword_esp_plus(int v):
	emit(3, "\xff\x84\x24") /* inc dword[esp+0x12345678] */
	emit_int(v)

/*
pop %ebx ; cmp %eax,%ebx ; setl %al ; movzbl %al,%eax
                           opcode_char_ptr
						   "\x9c"
*/
char* compare_opcode(char* opcode_char_ptr):
	char* result = "\x5b\x39\xc3\x0f\x9c\xc0\x0f\xb6\xc0"
	result[4] = opcode_char_ptr[0]
	return result
	

void int3():
	emit(1, "\xcc") /* int3 */
	

void nop():
	emit(1, "\x90") /* nop */


void ret(): 
	emit(1, "\xc3") /* ret */

############################## end of x86 opcodes ##############################
