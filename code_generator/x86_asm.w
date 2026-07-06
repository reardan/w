import code_generator.code_emitter


void sym_define_declare_global_function(char* name); /* defined in symbol_table */

void define_asm_functions():
	sym_define_declare_global_function(c"syscall")
	/* mov eax,[esp+16] ; mov ebx,[esp+12] ; mov ecx,[esp+8] ; mov edx,[esp+4] ; int 0x80 ; ret */
	emit(19, c"\x8b\x44\x24\x10\x8b\x5c\x24\x0c\x8b\x4c\x24\x08\x8b\x54\x24\x04\xcd\x80\xc3")

	sym_define_declare_global_function(c"syscall7")
	/* mov eax,[esp+28] ; mov ebx,[esp+24] ; mov ecx,[esp+20] ; mov edx,[esp+16] ; mov esi,[esp+12] ; mov edi,[esp+8] ; mov ebp,[esp+4] ; int 0x80 ; ret */
	emit(20, c"\x8b\x44\x24\x1c\x8b\x5c\x24\x18\x8b\x4c\x24\x14\x8b\x54\x24\x10\x8b\x74\x24\x0c")
	emit(11, c"\x8b\x7c\x24\x08\x8b\x6c\x24\x04\xcd\x80\xc3")

	# debug
	sym_define_declare_global_function(c"get_context")
	# push eax; mov eax,[esp+8] ; mov [eax+4],ecx ; pop ecx ; mov [eax+0],ecx ; mov [eax+8],edx ; mov [eax+12],ebx; mov [eax+16],esp ; mov [eax+20], ebp ; mov [eax+24], esi ; mov [eax+28],edi ; ret
	emit(20, c"\x50\x8b\x44\x24\x08\x89\x48\x04\x59\x89\x08\x89\x50\x08\x89\x58\x0c\x89\x60\x10")
	emit(10, c"\x89\x68\x14\x89\x70\x18\x89\x78\x1c\xc3")

	# push eax ; mov eax,[esp+8] ; mov [eax+4],ecx ; mov [eax+8],edx ; mov [eax+12],ebx ; mov [eax+16],esp ; mov [eax+20],ebp ; mov [eax+24],esi ; mov [eax+28],edi ; pop eax ; ret ;
	sym_define_declare_global_function(c"store_context")
	emit(20, c"\x50\x8b\x44\x24\x08\x89\x48\x04\x89\x50\x08\x89\x58\x0c\x89\x60\x10\x89\x68\x14")
	emit(9, c"\x89\x70\x18\x89\x78\x1c\x58\xc3")

	# repl_setjmp(buf): save return address, caller esp and ebp into the
	# 12-byte buffer, then return 0. repl_longjmp resumes here returning 1.
	sym_define_declare_global_function(c"repl_setjmp")
	# mov eax,[esp+4] ; mov ecx,[esp] ; mov [eax],ecx ; lea ecx,[esp+4] ;
	# mov [eax+4],ecx ; mov [eax+8],ebp ; xor eax,eax ; ret
	emit(20, c"\x8b\x44\x24\x04\x8b\x0c\x24\x89\x08\x8d\x4c\x24\x04\x89\x48\x04\x89\x68\x08\x31")
	emit(2, c"\xc0\xc3")

	# repl_longjmp(buf, val): restore esp/ebp and jump to the address saved
	# by repl_setjmp with val in eax. Like all stubs, the first argument
	# sits at the highest stack offset.
	sym_define_declare_global_function(c"repl_longjmp")
	# mov eax,[esp+4] ; mov ecx,[esp+8] ; mov esp,[ecx+4] ; mov ebp,[ecx+8] ; jmp [ecx]
	emit(16, c"\x8b\x44\x24\x04\x8b\x4c\x24\x08\x8b\x61\x04\x8b\x69\x08\xff\x21")

	# endian
	sym_define_declare_global_function(c"swap_endian")
	emit(7, c"\x8b\x44\x24\x04\x0f\xc8\xc3")

	sym_define_declare_global_function(c"swap_endian16")
	emit(11, c"\x8b\x44\x24\x04\x0f\xc8\xb1\x10\xd3\xfb\xc3")

	# tcp.asm
	sym_define_declare_global_function(c"socket_connect")
	emit(52, c"\xb8\x66\x00\x00\x00\xbb\x01\x00\x00\x00\x31\xd2\x52\x53\x6a\x02\x89\xe1\xcd\x80\x92\xb0\x66\x68\x7f\x01\x01\x01\x66\x68\x11\x5c\x43\x66\x53\x89\xe1\x6a\x10\x51\x52\x89\xe1\x43\xcd\x80\x83\xc4\x20\x89\xd0\xc3")

	sym_define_declare_global_function(c"socket_connect_new")
	emit(76, c"\xb8\x66\x00\x00\x00\xbb\x01\x00\x00\x00\x31\xd2\x6a\x00\x6a\x01\x6a\x02\x89\xe1\xcd\x80\x83\xc4\x0c\x50\x50\xb8\x66\x00\x00\x00\x8b\x54\x24\x04\x83\xc4\x08\x68\x7f\x01\x01\x01\x66\x68\x11\x5c\xbb\x02\x00\x00\x00\x66\x53\x89\xe1\x6a\x10\x51\x52\x89\xe1\xbb\x03\x00\x00\x00\xcd\x80\x83\xc4\x14\x89\xd0\xc3")

	sym_define_declare_global_function(c"socket")
	emit(35, c"\x8b\x44\x24\x04\x8b\x5c\x24\x08\x8b\x4c\x24\x0c\x50\x53\x51\x89\xe1\xb8\x66\x00\x00\x00\xbb\x01\x00\x00\x00\x31\xd2\xcd\x80\x83\xc4\x0c\xc3")

	sym_define_declare_global_function(c"connect")
	emit(55, c"\x89\xe5\x8b\x55\x0c\x8b\x45\x08\x8b\x5d\x04\x0f\xc8\x50\x0f\xcb\xb1\x10\xd3\xfb\x66\x53\xbb\x02\x00\x00\x00\x66\x53\x89\xe1\x6a\x10\x51\x52\x89\xe1\xb8\x66\x00\x00\x00\xbb\x03\x00\x00\x00\xcd\x80\x83\xc4\x14\x89\xd0\xc3")

	sym_define_declare_global_function(c"setsockopt")
	emit(30, c"\x8b\x54\x24\x04\x6a\x04\x54\x6a\x02\x6a\x01\x52\x89\xe1\xb8\x66\x00\x00\x00\xbb\x0e\x00\x00\x00\xcd\x80\x83\xc4\x14\xc3")

	sym_define_declare_global_function(c"bind")
	emit(45, c"\x8b\x54\x24\x08\x8b\x5c\x24\x04\x0f\xcb\xb1\x10\xd3\xfb\x6a\x00\x66\x53\x66\x6a\x02\x89\xe1\x6a\x10\x51\x52\xb8\x66\x00\x00\x00\xbb\x02\x00\x00\x00\x89\xe1\xcd\x80\x83\xc4\x14\xc3")

	sym_define_declare_global_function(c"listen")
	emit(27, c"\x8b\x54\x24\x04\x6a\x00\x52\x89\xe1\xb8\x66\x00\x00\x00\xbb\x04\x00\x00\x00\xcd\x80\x83\xc4\x08\x89\xd0\xc3")

	sym_define_declare_global_function(c"socket_accept")
	emit(29, c"\x8b\x54\x24\x04\xb8\x66\x00\x00\x00\xbb\x05\x00\x00\x00\x6a\x00\x6a\x00\x52\x89\xe1\xcd\x80\x89\xc2\x83\xc4\x0c\xc3")

	# thread_i386.s
	# thread_create(func): clone with a fresh 4MB stack whose top slot holds func,
	# so the child's fall-through "ret" jumps straight into func.
	# The call +25 targets stack_create, which is emitted immediately after.
	sym_define_declare_global_function(c"thread_create")
	/* call stack_create ; lea ecx,[eax+0x3ffff0] ; mov edx,[esp+4] ; mov [ecx],edx */
	emit(17, c"\xe8\x19\x00\x00\x00\x8d\x88\xf0\xff\x3f\x00\x8b\x54\x24\x04\x89\x11")
	/* mov ebx,CLONE_VM|FS|FILES|SIGHAND|PARENT|THREAD|IO ; mov eax,120 ; int 0x80 ; ret */
	emit(13, c"\xbb\x00\x8f\x01\x80\xb8\x78\x00\x00\x00\xcd\x80\xc3")

	# stack_create(): mmap2(0, 4MB, RW, PRIVATE|ANONYMOUS|GROWSDOWN, -1, 0)
	sym_define_declare_global_function(c"stack_create")
	emit(20, c"\xbb\x00\x00\x00\x00\xb9\x00\x00\x40\x00\xba\x03\x00\x00\x00\xbe\x22\x01\x00\x00")
	/* mov edi,-1 ; mov ebp,0 ; mov eax,192 ; int 0x80 ; ret */
	emit(18, c"\xbf\xff\xff\xff\xff\xbd\x00\x00\x00\x00\xb8\xc0\x00\x00\x00\xcd\x80\xc3")

	# function_call(func_ptr)
	sym_define_declare_global_function(c"function_call")
	# mov eax,[esp+4]; jmp eax
	emit(6, c"\x8b\x44\x24\x04\xff\xe0")

	# gen_switch(int* save_esp_here, int restore_esp): the generator
	# context switch (docs/projects/iteration.md). Saves the callee-saved
	# registers and esp on the current stack, stores esp through arg1,
	# loads arg2 into esp, restores the registers saved there and returns
	# on the other stack. One stub serves both yield and resume.
	sym_define_declare_global_function(c"gen_switch")
	# push ebx ; push esi ; push edi ; push ebp ; mov eax,[esp+24] ;
	# mov ecx,[esp+20] ; mov [eax],esp ; mov esp,ecx ;
	# pop ebp ; pop edi ; pop esi ; pop ebx ; ret
	emit(20, c"\x53\x56\x57\x55\x8b\x44\x24\x18\x8b\x4c\x24\x14\x89\x20\x89\xcc\x5d\x5f\x5e\x5b")
	emit(1, c"\xc3")

