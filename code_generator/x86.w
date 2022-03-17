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
	mov_eax_int32(v)


/* push eax */
void push_eax():
	emit(1, "\x50")


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


/*
pop %ebx ; cmp %eax,%ebx ; setl %al ; movzbl %al,%eax
                           opcode_char_ptr
						   "\x9c"
*/
char* compare_opcode(char* opcode_char_ptr):
	char* result = "\x5b\x39\xc3\x0f\x9c\xc0\x0f\xb6\xc0"
	result[4] = opcode_char_ptr[0]
	return result


############################## end of x86 opcodes ##############################
