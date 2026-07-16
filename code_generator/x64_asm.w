import code_generator.code_emitter


void sym_define_declare_global_function(char* name); /* defined in symbol_table */
void sym_define_declare_global_function_arity(char* name, int num_args); /* defined in symbol_table */


# The OS-independent x64 stubs: pure register/stack operations with no
# syscall instructions, shared between the Linux ELF target
# (define_asm_functions_x64 below) and the win64 PE target
# (code_generator/pe_64.w), which must not emit the Linux syscall stubs.
void define_asm_functions_x64_portable():
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

	# gen_switch(int* save_esp_here, int restore_esp): the generator
	# context switch (docs/projects/iteration.md), x64 flavor. Saves the
	# callee-saved registers (rbx, rbp, r12-r15) and rsp on the current
	# stack, stores rsp through arg1, loads arg2 into rsp, restores the
	# registers saved there and returns on the other stack.
	sym_define_declare_global_function(c"gen_switch")
	# push rbx ; push rbp ; push r12 ; push r13 ; push r14 ; push r15 ;
	# mov rax,[rsp+64] ; mov rcx,[rsp+56]
	emit(20, c"\x53\x55\x41\x54\x41\x55\x41\x56\x41\x57\x48\x8b\x44\x24\x40\x48\x8b\x4c\x24\x38")
	# mov [rax],rsp ; mov rsp,rcx ; pop r15 ; pop r14 ; pop r13 ;
	# pop r12 ; pop rbp ; pop rbx ; ret
	emit(17, c"\x48\x89\x20\x48\x89\xcc\x41\x5f\x41\x5e\x41\x5d\x41\x5c\x5d\x5b\xc3")


void define_asm_functions_x64():
	# syscall reads exactly nr + 3 fixed stack slots, so record its arity:
	# a call with any other argument count would read garbage slots.
	sym_define_declare_global_function_arity(c"syscall", 4)
	/* mov rax,[rsp+32] ; mov rdi,[rsp+24] ; mov rsi,[rsp+16] ; mov rdx,[rsp+8] ; syscall ; ret */
	emit(20, c"\x48\x8b\x44\x24\x20\x48\x8b\x7c\x24\x18\x48\x8b\x74\x24\x10\x48\x8b\x54\x24\x08")
	emit(3, c"\x0f\x05\xc3")

	sym_define_declare_global_function_arity(c"syscall7", 7)
	/* mov rax,[rsp+56] ; mov rdi,[rsp+48] ; mov rsi,[rsp+40] ; mov rdx,[rsp+32] ; mov r10,[rsp+24] ; mov r8,[rsp+16] ; mov r9,[rsp+8] ; syscall ; ret */
	emit(20, c"\x48\x8b\x44\x24\x38\x48\x8b\x7c\x24\x30\x48\x8b\x74\x24\x28\x48\x8b\x54\x24\x20")
	emit(18, c"\x4c\x8b\x54\x24\x18\x4c\x8b\x44\x24\x10\x4c\x8b\x4c\x24\x08\x0f\x05\xc3")

	# thread_create(func): clone with a fresh 4MB stack whose top slot
	# holds func, so the child's fall-through "ret" jumps straight into
	# func (the x64 twin of the x86 stub; docs/projects/threads.md).
	# The call +0x1f targets stack_create, emitted immediately after.
	sym_define_declare_global_function(c"thread_create")
	/* call stack_create ; lea rcx,[rax+0x3ffff0] ; mov rdx,[rsp+8] ; mov [rcx],rdx */
	emit(20, c"\xe8\x1f\x00\x00\x00\x48\x8d\x88\xf0\xff\x3f\x00\x48\x8b\x54\x24\x08\x48\x89\x11")
	/* mov edi,CLONE_VM|FS|FILES|SIGHAND|PARENT|THREAD|IO ; mov rsi,rcx ; mov eax,56 ; syscall ; ret */
	emit(16, c"\xbf\x00\x8f\x01\x80\x48\x89\xce\xb8\x38\x00\x00\x00\x0f\x05\xc3")

	# stack_create(): mmap(0, 4MB, RW, PRIVATE|ANONYMOUS|GROWSDOWN, -1, 0)
	sym_define_declare_global_function(c"stack_create")
	/* xor edi,edi ; mov esi,0x400000 ; mov edx,3 ; push 0x122 ; pop r10 ; push byte -1 */
	emit(20, c"\x31\xff\xbe\x00\x00\x40\x00\xba\x03\x00\x00\x00\x68\x22\x01\x00\x00\x41\x5a\x6a")
	/* ... ; pop r8 ; xor r9,r9 ; mov eax,9 ; syscall ; ret */
	emit(14, c"\xff\x41\x58\x4d\x31\xc9\xb8\x09\x00\x00\x00\x0f\x05\xc3")

	define_asm_functions_x64_portable()
