import code_generator.code_emitter


void sym_define_declare_global_function(char* name); /* defined in symbol_table */


void define_asm_functions_x64():
	sym_define_declare_global_function(c"syscall")
	/* mov rax,[rsp+32] ; mov rdi,[rsp+24] ; mov rsi,[rsp+16] ; mov rdx,[rsp+8] ; syscall ; ret */
	emit(20, c"\x48\x8b\x44\x24\x20\x48\x8b\x7c\x24\x18\x48\x8b\x74\x24\x10\x48\x8b\x54\x24\x08")
	emit(3, c"\x0f\x05\xc3")

	sym_define_declare_global_function(c"syscall7")
	/* mov rax,[rsp+56] ; mov rdi,[rsp+48] ; mov rsi,[rsp+40] ; mov rdx,[rsp+32] ; mov r10,[rsp+24] ; mov r8,[rsp+16] ; mov r9,[rsp+8] ; syscall ; ret */
	emit(20, c"\x48\x8b\x44\x24\x38\x48\x8b\x7c\x24\x30\x48\x8b\x74\x24\x28\x48\x8b\x54\x24\x20")
	emit(18, c"\x4c\x8b\x54\x24\x18\x4c\x8b\x44\x24\x10\x4c\x8b\x4c\x24\x08\x0f\x05\xc3")

	# get_context(ctx): fill the 16-word context struct at ctx with the
	# caller's registers. rcx is saved before the pushed rax is popped
	# through it, so the stored rsp is the value at function entry.
	sym_define_declare_global_function(c"get_context")
	/* push rax ; mov rax,[rsp+16] ; mov [rax+8],rcx ; pop rcx ; mov [rax],rcx */
	emit(20, c"\x50\x48\x8b\x44\x24\x10\x48\x89\x48\x08\x59\x48\x89\x08\x48\x89\x50\x10\x48\x89")
	/* mov [rax+16],rdx ; [rax+24],rbx ; [rax+32],rsp ; [rax+40],rbp ; [rax+48],rsi ; [rax+56],rdi */
	emit(20, c"\x58\x18\x48\x89\x60\x20\x48\x89\x68\x28\x48\x89\x70\x30\x48\x89\x78\x38\x4c\x89")
	/* mov [rax+64],r8 ... mov [rax+120],r15 ; ret */
	emit(20, c"\x40\x40\x4c\x89\x48\x48\x4c\x89\x50\x50\x4c\x89\x58\x58\x4c\x89\x60\x60\x4c\x89")
	emit(11, c"\x68\x68\x4c\x89\x70\x70\x4c\x89\x78\x78\xc3")

	# store_context(ctx): like get_context but preserves rax instead of
	# recording it (mirrors the x86 stub's behavior).
	sym_define_declare_global_function(c"store_context")
	/* push rax ; mov rax,[rsp+16] ; mov [rax+8],rcx ; [rax+16],rdx ; [rax+24],rbx */
	emit(20, c"\x50\x48\x8b\x44\x24\x10\x48\x89\x48\x08\x48\x89\x50\x10\x48\x89\x58\x18\x48\x89")
	/* mov [rax+32],rsp ; [rax+40],rbp ; [rax+48],rsi ; [rax+56],rdi ; [rax+64],r8 */
	emit(20, c"\x60\x20\x48\x89\x68\x28\x48\x89\x70\x30\x48\x89\x78\x38\x4c\x89\x40\x40\x4c\x89")
	/* mov [rax+72],r9 ... mov [rax+120],r15 ; pop rax ; ret */
	emit(20, c"\x48\x48\x4c\x89\x50\x50\x4c\x89\x58\x58\x4c\x89\x60\x60\x4c\x89\x68\x68\x4c\x89")
	emit(8, c"\x70\x70\x4c\x89\x78\x78\x58\xc3")

	# repl_setjmp(buf): save return address, caller rsp and rbp into the
	# 24-byte buffer, then return 0. repl_longjmp resumes here returning
	# the value it was given. Mirrors the x86 stub: the W codegen keeps no
	# live values in callee-saved registers across calls, so rsp/rbp are
	# all that must survive.
	sym_define_declare_global_function(c"repl_setjmp")
	# mov rax,[rsp+8] ; mov rcx,[rsp] ; mov [rax],rcx ; lea rcx,[rsp+8] ;
	# mov [rax+8],rcx ; mov [rax+16],rbp ; xor eax,eax ; ret
	emit(20, c"\x48\x8b\x44\x24\x08\x48\x8b\x0c\x24\x48\x89\x08\x48\x8d\x4c\x24\x08\x48\x89\x48")
	emit(8, c"\x08\x48\x89\x68\x10\x31\xc0\xc3")

	# repl_longjmp(buf, val): restore rsp/rbp and jump to the address
	# saved by repl_setjmp with val in rax. Like all stubs, the first
	# argument sits at the highest stack offset.
	sym_define_declare_global_function(c"repl_longjmp")
	# mov rax,[rsp+8] ; mov rcx,[rsp+16] ; mov rsp,[rcx+8] ; mov rbp,[rcx+16] ; jmp [rcx]
	emit(20, c"\x48\x8b\x44\x24\x08\x48\x8b\x4c\x24\x10\x48\x8b\x61\x08\x48\x8b\x69\x10\xff\x21")
