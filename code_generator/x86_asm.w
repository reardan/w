import code_generator.code_emitter
import code_generator.asm_text


void sym_define_declare_global_function(char* name); /* defined in symbol_table */
void sym_stub_alias(char* name); /* defined in symbol_table */
void sym_define_declare_global_function_arity(char* name, int num_args); /* defined in symbol_table */

void define_asm_functions():
	# syscall reads exactly nr + 3 fixed stack slots, so record its arity:
	# a call with any other argument count would read garbage slots.
	sym_define_declare_global_function_arity(c"syscall", 4)
	x86_asm(c"mov eax,[esp+0x10]")
	x86_asm(c"mov ebx,[esp+0xc]")
	x86_asm(c"mov ecx,[esp+8]")
	x86_asm(c"mov edx,[esp+4]")
	x86_asm(c"int 0x80")
	x86_asm(c"ret")

	sym_define_declare_global_function_arity(c"syscall7", 7)
	# The sixth syscall argument travels in ebp, which W code keeps as
	# its frame pointer (be_function_prologue): save it around the call.
	x86_asm(c"push ebp")   # W's frame pointer: the 6th argument borrows ebp
	x86_asm(c"mov eax,[esp+0x20]")
	x86_asm(c"mov ebx,[esp+0x1c]")
	x86_asm(c"mov ecx,[esp+0x18]")
	x86_asm(c"mov edx,[esp+0x14]")
	x86_asm(c"mov esi,[esp+0x10]")
	x86_asm(c"mov edi,[esp+0xc]")
	x86_asm(c"mov ebp,[esp+8]")
	x86_asm(c"int 0x80")
	x86_asm(c"pop ebp")
	x86_asm(c"ret")

	# debug
	sym_define_declare_global_function(c"get_context")
	x86_asm(c"push eax")
	x86_asm(c"mov eax,[esp+8]")
	x86_asm(c"mov [eax+4],ecx")
	x86_asm(c"pop ecx")
	x86_asm(c"mov [eax],ecx")
	x86_asm(c"mov [eax+8],edx")
	x86_asm(c"mov [eax+0xc],ebx")
	x86_asm(c"mov [eax+0x10],esp")
	x86_asm(c"mov [eax+0x14],ebp")
	x86_asm(c"mov [eax+0x18],esi")
	x86_asm(c"mov [eax+0x1c],edi")
	x86_asm(c"ret")

	sym_define_declare_global_function(c"store_context")
	x86_asm(c"push eax")
	x86_asm(c"mov eax,[esp+8]")
	x86_asm(c"mov [eax+4],ecx")
	x86_asm(c"mov [eax+8],edx")
	x86_asm(c"mov [eax+0xc],ebx")
	x86_asm(c"mov [eax+0x10],esp")
	x86_asm(c"mov [eax+0x14],ebp")
	x86_asm(c"mov [eax+0x18],esi")
	x86_asm(c"mov [eax+0x1c],edi")
	x86_asm(c"pop eax")
	x86_asm(c"ret")

	# repl_setjmp(buf): save return address, caller esp and ebp into the
	# 12-byte buffer, then return 0. repl_longjmp resumes here returning 1.
	sym_define_declare_global_function(c"repl_setjmp")
	# Public C-style name for the same stub (lib/setjmp.w, issue #435)
	sym_stub_alias(c"setjmp")
	x86_asm(c"mov eax,[esp+4]")
	x86_asm(c"mov ecx,[esp]")
	x86_asm(c"mov [eax],ecx")
	x86_asm(c"lea ecx,[esp+4]")
	x86_asm(c"mov [eax+4],ecx")
	x86_asm(c"mov [eax+8],ebp")
	x86_asm(c"xor eax,eax")
	x86_asm(c"ret")

	# repl_longjmp(buf, val): restore esp/ebp and jump to the address saved
	# by repl_setjmp with val in eax. Like all stubs, the first argument
	# sits at the highest stack offset.
	sym_define_declare_global_function(c"repl_longjmp")
	# Public C-style name for the same stub (lib/setjmp.w, issue #435)
	sym_stub_alias(c"longjmp")
	x86_asm(c"mov eax,[esp+4]")
	x86_asm(c"mov ecx,[esp+8]")
	x86_asm(c"mov esp,[ecx+4]")
	x86_asm(c"mov ebp,[ecx+8]")
	x86_asm(c"jmp [ecx]")

	# endian
	sym_define_declare_global_function(c"swap_endian")
	x86_asm(c"mov eax,[esp+4]")
	x86_asm(c"bswap eax")
	x86_asm(c"ret")

	# the shift targeted ebx (d3 fb) until #175, returning the swapped
	# halfword stuck in eax's high bits and clobbering ebx
	sym_define_declare_global_function(c"swap_endian16")
	x86_asm(c"mov eax,[esp+4]")
	x86_asm(c"bswap eax")
	x86_asm(c"mov cl,0x10")
	x86_asm(c"sar eax,cl")
	x86_asm(c"ret")

	# tcp.asm
	sym_define_declare_global_function(c"socket_connect")
	x86_asm(c"mov eax,0x66")
	x86_asm(c"mov ebx,1")
	x86_asm(c"xor edx,edx")
	x86_asm(c"push edx")
	x86_asm(c"push ebx")
	x86_asm(c"push byte 2")
	x86_asm(c"mov ecx,esp")
	x86_asm(c"int 0x80")
	x86_asm(c"xchg edx,eax")
	x86_asm(c"mov al,0x66")
	x86_asm(c"push dword 0x101017f")
	x86_asm(c"pushw 0x5c11")
	x86_asm(c"inc ebx")
	x86_asm(c"push bx")
	x86_asm(c"mov ecx,esp")
	x86_asm(c"push byte 0x10")
	x86_asm(c"push ecx")
	x86_asm(c"push edx")
	x86_asm(c"mov ecx,esp")
	x86_asm(c"inc ebx")
	x86_asm(c"int 0x80")
	x86_asm(c"add esp,0x20")
	x86_asm(c"mov eax,edx")
	x86_asm(c"ret")

	sym_define_declare_global_function(c"socket_connect_new")
	x86_asm(c"mov eax,0x66")
	x86_asm(c"mov ebx,1")
	x86_asm(c"xor edx,edx")
	x86_asm(c"push byte 0")
	x86_asm(c"push byte 1")
	x86_asm(c"push byte 2")
	x86_asm(c"mov ecx,esp")
	x86_asm(c"int 0x80")
	x86_asm(c"add esp,0xc")
	x86_asm(c"push eax")
	x86_asm(c"push eax")
	x86_asm(c"mov eax,0x66")
	x86_asm(c"mov edx,[esp+4]")
	x86_asm(c"add esp,8")
	x86_asm(c"push dword 0x101017f")
	x86_asm(c"pushw 0x5c11")
	x86_asm(c"mov ebx,2")
	x86_asm(c"push bx")
	x86_asm(c"mov ecx,esp")
	x86_asm(c"push byte 0x10")
	x86_asm(c"push ecx")
	x86_asm(c"push edx")
	x86_asm(c"mov ecx,esp")
	x86_asm(c"mov ebx,3")
	x86_asm(c"int 0x80")
	x86_asm(c"add esp,0x14")
	x86_asm(c"mov eax,edx")
	x86_asm(c"ret")

	sym_define_declare_global_function(c"socket")
	x86_asm(c"mov eax,[esp+4]")
	x86_asm(c"mov ebx,[esp+8]")
	x86_asm(c"mov ecx,[esp+0xc]")
	x86_asm(c"push eax")
	x86_asm(c"push ebx")
	x86_asm(c"push ecx")
	x86_asm(c"mov ecx,esp")
	x86_asm(c"mov eax,0x66")
	x86_asm(c"mov ebx,1")
	x86_asm(c"xor edx,edx")
	x86_asm(c"int 0x80")
	x86_asm(c"add esp,0xc")
	x86_asm(c"ret")

	# Uses ebp as its own frame base: saved and restored (push ebp ...
	# pop ebp) because W code keeps its frame pointer there.
	sym_define_declare_global_function(c"connect")
	x86_asm(c"push ebp")   # W's frame pointer: saved around the local frame base
	x86_asm(c"mov ebp,esp")
	x86_asm(c"mov edx,[ebp+0x10]")
	x86_asm(c"mov eax,[ebp+0xc]")
	x86_asm(c"mov ebx,[ebp+8]")
	x86_asm(c"bswap eax")
	x86_asm(c"push eax")
	x86_asm(c"bswap ebx")
	x86_asm(c"mov cl,0x10")
	x86_asm(c"sar ebx,cl")
	x86_asm(c"push bx")
	x86_asm(c"mov ebx,2")
	x86_asm(c"push bx")
	x86_asm(c"mov ecx,esp")
	x86_asm(c"push byte 0x10")
	x86_asm(c"push ecx")
	x86_asm(c"push edx")
	x86_asm(c"mov ecx,esp")
	x86_asm(c"mov eax,0x66")
	x86_asm(c"mov ebx,3")
	x86_asm(c"int 0x80")
	x86_asm(c"add esp,0x14")
	x86_asm(c"mov eax,edx")
	x86_asm(c"pop ebp")
	x86_asm(c"ret")

	sym_define_declare_global_function(c"setsockopt")
	x86_asm(c"mov edx,[esp+4]")
	x86_asm(c"push byte 4")
	x86_asm(c"push esp")
	x86_asm(c"push byte 2")
	x86_asm(c"push byte 1")
	x86_asm(c"push edx")
	x86_asm(c"mov ecx,esp")
	x86_asm(c"mov eax,0x66")
	x86_asm(c"mov ebx,0xe")
	x86_asm(c"int 0x80")
	x86_asm(c"add esp,0x14")
	x86_asm(c"ret")

	sym_define_declare_global_function(c"bind")
	x86_asm(c"mov edx,[esp+8]")
	x86_asm(c"mov ebx,[esp+4]")
	x86_asm(c"bswap ebx")
	x86_asm(c"mov cl,0x10")
	x86_asm(c"sar ebx,cl")
	x86_asm(c"push byte 0")
	x86_asm(c"push bx")
	x86_asm(c"pushw 2")
	x86_asm(c"mov ecx,esp")
	x86_asm(c"push byte 0x10")
	x86_asm(c"push ecx")
	x86_asm(c"push edx")
	x86_asm(c"mov eax,0x66")
	x86_asm(c"mov ebx,2")
	x86_asm(c"mov ecx,esp")
	x86_asm(c"int 0x80")
	x86_asm(c"add esp,0x14")
	x86_asm(c"ret")

	sym_define_declare_global_function(c"listen")
	x86_asm(c"mov edx,[esp+4]")
	x86_asm(c"push byte 0")
	x86_asm(c"push edx")
	x86_asm(c"mov ecx,esp")
	x86_asm(c"mov eax,0x66")
	x86_asm(c"mov ebx,4")
	x86_asm(c"int 0x80")
	x86_asm(c"add esp,8")
	x86_asm(c"mov eax,edx")
	x86_asm(c"ret")

	sym_define_declare_global_function(c"socket_accept")
	x86_asm(c"mov edx,[esp+4]")
	x86_asm(c"mov eax,0x66")
	x86_asm(c"mov ebx,5")
	x86_asm(c"push byte 0")
	x86_asm(c"push byte 0")
	x86_asm(c"push edx")
	x86_asm(c"mov ecx,esp")
	x86_asm(c"int 0x80")
	x86_asm(c"mov edx,eax")
	x86_asm(c"add esp,0xc")
	x86_asm(c"ret")

	# thread_i386.s
	# thread_create(func): clone with a fresh 4MB stack whose top slot holds func,
	# so the child's fall-through "ret" jumps straight into func.
	# The call targets stack_create, which is emitted immediately after.
	# The child zeroes ebp so its frame-pointer chain ends at the thread
	# function instead of running into the parent's frames.
	sym_define_declare_global_function(c"thread_create")
	x86_asm(c"call .+0x24")   # stack_create, emitted immediately after this stub
	x86_asm(c"lea ecx,[eax+0x3ffff0]")
	x86_asm(c"mov edx,[esp+4]")
	x86_asm(c"mov [ecx],edx")
	x86_asm(c"mov ebx,-0x7ffe7100")   # CLONE_VM|FS|FILES|SIGHAND|PARENT|THREAD|IO
	x86_asm(c"mov eax,0x78")
	x86_asm(c"int 0x80")
	x86_asm(c"test eax,eax")
	x86_asm(c"jne .+4")   # parent: keep ebp
	x86_asm(c"xor ebp,ebp")   # child: the frame-pointer chain ends here
	x86_asm(c"ret")

	# stack_create(): mmap2(0, 4MB, RW, PRIVATE|ANONYMOUS|GROWSDOWN, -1, 0)
	# The offset argument travels in ebp, the caller's frame pointer:
	# saved and restored around the syscall.
	sym_define_declare_global_function(c"stack_create")
	x86_asm(c"push ebp")   # the offset argument borrows W's frame pointer
	x86_asm(c"mov ebx,0")
	x86_asm(c"mov ecx,0x400000")
	x86_asm(c"mov edx,3")
	x86_asm(c"mov esi,0x122")
	x86_asm(c"mov edi,-1")
	x86_asm(c"mov ebp,0")
	x86_asm(c"mov eax,0xc0")
	x86_asm(c"int 0x80")
	x86_asm(c"pop ebp")
	x86_asm(c"ret")

	# Thread-local storage (docs/projects/thread_local.md).
	# __w_tls_size(): the per-thread block size, patched at finish.
	sym_define_declare_global_function(c"__w_tls_size")
	tls_size_patch_pos = codepos + 1
	x86_asm(c"mov eax,0")
	x86_asm(c"ret")
	# __w_tls_set(block): make block this thread's fs-based TLS block
	# (gs stays libc's in a dynamically linked program). Writes the self
	# pointer to block[0], then set_thread_area with the GDT entry the
	# inherited fs selector names (-1 = let the kernel pick one, on the
	# main thread), and loads fs with the entry's selector.
	sym_define_declare_global_function(c"__w_tls_set")
	x86_asm(c"push ebx")
	x86_asm(c"mov ecx,[esp+8]")
	x86_asm(c"mov [ecx],ecx")
	x86_asm(c"sub esp,0x10")
	x86_asm(c"db 0x66, 0x8c, 0xe0")   # mov ax,fs
	x86_asm(c"movzx eax,ax")
	x86_asm(c"db 0xc1, 0xe8, 0x03")   # shr eax,3
	x86_asm(c"jne .+7")   # fs already names an entry (spawned thread)
	x86_asm(c"mov eax,-1")
	x86_asm(c"mov [esp],eax")   # user_desc.entry_number
	x86_asm(c"mov [esp+4],ecx")   # base_addr
	x86_asm(c"db 0xc7, 0x44, 0x24, 0x08, 0xff, 0xff, 0x0f, 0x00")   # mov dword [esp+8],0xfffff: limit (pages)
	x86_asm(c"db 0xc7, 0x44, 0x24, 0x0c, 0x51, 0x00, 0x00, 0x00")   # mov dword [esp+12],0x51: seg_32bit | limit_in_pages | useable
	x86_asm(c"mov ebx,esp")
	x86_asm(c"mov eax,0xf3")   # set_thread_area
	x86_asm(c"int 0x80")
	x86_asm(c"mov eax,[esp]")
	x86_asm(c"db 0xc1, 0xe0, 0x03")   # shl eax,3
	x86_asm(c"or eax,3")
	x86_asm(c"db 0x8e, 0xe0")   # mov fs,ax
	x86_asm(c"add esp,0x10")
	x86_asm(c"pop ebx")
	x86_asm(c"ret")

	# function_call(func_ptr)
	sym_define_declare_global_function(c"function_call")
	x86_asm(c"mov eax,[esp+4]")
	x86_asm(c"jmp eax")

	# gen_switch(int* save_esp_here, int restore_esp): the generator
	# context switch (docs/projects/iteration.md). Saves the callee-saved
	# registers and esp on the current stack, stores esp through arg1,
	# loads arg2 into esp, restores the registers saved there and returns
	# on the other stack. One stub serves both yield and resume.
	sym_define_declare_global_function(c"gen_switch")
	x86_asm(c"push ebx")
	x86_asm(c"push esi")
	x86_asm(c"push edi")
	x86_asm(c"push ebp")
	x86_asm(c"mov eax,[esp+0x18]")
	x86_asm(c"mov ecx,[esp+0x14]")
	x86_asm(c"mov [eax],esp")
	x86_asm(c"mov esp,ecx")
	x86_asm(c"pop ebp")
	x86_asm(c"pop edi")
	x86_asm(c"pop esi")
	x86_asm(c"pop ebx")
	x86_asm(c"ret")

