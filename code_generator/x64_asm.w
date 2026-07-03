import code_generator.code_emitter


void sym_define_declare_global_function(char* name); /* defined in symbol_table */


void define_asm_functions_x64():
	sym_define_declare_global_function("syscall")
	/* mov rax,[rsp+32] ; mov rdi,[rsp+24] ; mov rsi,[rsp+16] ; mov rdx,[rsp+8] ; syscall ; ret */
	emit(20, "\x48\x8b\x44\x24\x20\x48\x8b\x7c\x24\x18\x48\x8b\x74\x24\x10\x48\x8b\x54\x24\x08")
	emit(3, "\x0f\x05\xc3")

	sym_define_declare_global_function("syscall7")
	/* mov rax,[rsp+56] ; mov rdi,[rsp+48] ; mov rsi,[rsp+40] ; mov rdx,[rsp+32] ; mov r10,[rsp+24] ; mov r8,[rsp+16] ; mov r9,[rsp+8] ; syscall ; ret */
	emit(20, "\x48\x8b\x44\x24\x38\x48\x8b\x7c\x24\x30\x48\x8b\x74\x24\x28\x48\x8b\x54\x24\x20")
	emit(18, "\x4c\x8b\x54\x24\x18\x4c\x8b\x44\x24\x10\x4c\x8b\x4c\x24\x08\x0f\x05\xc3")

	# get_context(ctx): fill the 16-word context struct at ctx with the
	# caller's registers. rcx is saved before the pushed rax is popped
	# through it, so the stored rsp is the value at function entry.
	sym_define_declare_global_function("get_context")
	/* push rax ; mov rax,[rsp+16] ; mov [rax+8],rcx ; pop rcx ; mov [rax],rcx */
	emit(20, "\x50\x48\x8b\x44\x24\x10\x48\x89\x48\x08\x59\x48\x89\x08\x48\x89\x50\x10\x48\x89")
	/* mov [rax+16],rdx ; [rax+24],rbx ; [rax+32],rsp ; [rax+40],rbp ; [rax+48],rsi ; [rax+56],rdi */
	emit(20, "\x58\x18\x48\x89\x60\x20\x48\x89\x68\x28\x48\x89\x70\x30\x48\x89\x78\x38\x4c\x89")
	/* mov [rax+64],r8 ... mov [rax+120],r15 ; ret */
	emit(20, "\x40\x40\x4c\x89\x48\x48\x4c\x89\x50\x50\x4c\x89\x58\x58\x4c\x89\x60\x60\x4c\x89")
	emit(11, "\x68\x68\x4c\x89\x70\x70\x4c\x89\x78\x78\xc3")

	# store_context(ctx): like get_context but preserves rax instead of
	# recording it (mirrors the x86 stub's behavior).
	sym_define_declare_global_function("store_context")
	/* push rax ; mov rax,[rsp+16] ; mov [rax+8],rcx ; [rax+16],rdx ; [rax+24],rbx */
	emit(20, "\x50\x48\x8b\x44\x24\x10\x48\x89\x48\x08\x48\x89\x50\x10\x48\x89\x58\x18\x48\x89")
	/* mov [rax+32],rsp ; [rax+40],rbp ; [rax+48],rsi ; [rax+56],rdi ; [rax+64],r8 */
	emit(20, "\x60\x20\x48\x89\x68\x28\x48\x89\x70\x30\x48\x89\x78\x38\x4c\x89\x40\x40\x4c\x89")
	/* mov [rax+72],r9 ... mov [rax+120],r15 ; pop rax ; ret */
	emit(20, "\x48\x48\x4c\x89\x50\x50\x4c\x89\x58\x58\x4c\x89\x60\x60\x4c\x89\x68\x68\x4c\x89")
	emit(8, "\x70\x70\x4c\x89\x78\x78\x58\xc3")

	/* mock: always returns 0 (the REPL only targets x86) */
	sym_define_declare_global_function("repl_setjmp")
	emit(3, "\x31\xc0\xc3") /* xor eax,eax ; ret */
	sym_define_declare_global_function("repl_longjmp")
	emit(1, "\xc3") /* ret */
