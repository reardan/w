import code_generator.code_emitter
import code_generator.asm_text


void sym_define_declare_global_function(char* name); /* defined in symbol_table */
void sym_stub_alias(char* name); /* defined in symbol_table */
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
	x64_asm(c"push rax")
	x64_asm(c"mov rax,[rsp+0x10]")
	x64_asm(c"mov [rax+8],rcx")
	x64_asm(c"pop rcx")
	x64_asm(c"mov [rax],rcx")
	x64_asm(c"mov [rax+0x10],rdx")
	x64_asm(c"mov [rax+0x18],rbx")
	x64_asm(c"mov [rax+0x20],rsp")
	x64_asm(c"mov [rax+0x28],rbp")
	x64_asm(c"mov [rax+0x30],rsi")
	x64_asm(c"mov [rax+0x38],rdi")
	x64_asm(c"mov [rax+0x40],r8")
	x64_asm(c"mov [rax+0x48],r9")
	x64_asm(c"mov [rax+0x50],r10")
	x64_asm(c"mov [rax+0x58],r11")
	x64_asm(c"mov [rax+0x60],r12")
	x64_asm(c"mov [rax+0x68],r13")
	x64_asm(c"mov [rax+0x70],r14")
	x64_asm(c"mov [rax+0x78],r15")
	x64_asm(c"ret")

	# store_context(ctx): like get_context but preserves rax instead of
	# recording it (mirrors the x86 stub's behavior).
	sym_define_declare_global_function(c"store_context")
	x64_asm(c"push rax")
	x64_asm(c"mov rax,[rsp+0x10]")
	x64_asm(c"mov [rax+8],rcx")
	x64_asm(c"mov [rax+0x10],rdx")
	x64_asm(c"mov [rax+0x18],rbx")
	x64_asm(c"mov [rax+0x20],rsp")
	x64_asm(c"mov [rax+0x28],rbp")
	x64_asm(c"mov [rax+0x30],rsi")
	x64_asm(c"mov [rax+0x38],rdi")
	x64_asm(c"mov [rax+0x40],r8")
	x64_asm(c"mov [rax+0x48],r9")
	x64_asm(c"mov [rax+0x50],r10")
	x64_asm(c"mov [rax+0x58],r11")
	x64_asm(c"mov [rax+0x60],r12")
	x64_asm(c"mov [rax+0x68],r13")
	x64_asm(c"mov [rax+0x70],r14")
	x64_asm(c"mov [rax+0x78],r15")
	x64_asm(c"pop rax")
	x64_asm(c"ret")

	# repl_setjmp(buf): save return address, caller rsp and rbp into the
	# 24-byte buffer, then return 0. repl_longjmp resumes here returning
	# the value it was given. Mirrors the x86 stub: the W codegen keeps no
	# live values in callee-saved registers across calls, so rsp/rbp are
	# all that must survive.
	sym_define_declare_global_function(c"repl_setjmp")
	# Public C-style name for the same stub (lib/setjmp.w, issue #435)
	sym_stub_alias(c"setjmp")
	x64_asm(c"mov rax,[rsp+8]")
	x64_asm(c"mov rcx,[rsp]")
	x64_asm(c"mov [rax],rcx")
	x64_asm(c"lea rcx,[rsp+8]")
	x64_asm(c"mov [rax+8],rcx")
	x64_asm(c"mov [rax+0x10],rbp")
	x64_asm(c"xor eax,eax")
	x64_asm(c"ret")

	# repl_longjmp(buf, val): restore rsp/rbp and jump to the address
	# saved by repl_setjmp with val in rax. Like all stubs, the first
	# argument sits at the highest stack offset.
	sym_define_declare_global_function(c"repl_longjmp")
	# Public C-style name for the same stub (lib/setjmp.w, issue #435)
	sym_stub_alias(c"longjmp")
	x64_asm(c"mov rax,[rsp+8]")
	x64_asm(c"mov rcx,[rsp+0x10]")
	x64_asm(c"mov rsp,[rcx+8]")
	x64_asm(c"mov rbp,[rcx+0x10]")
	x64_asm(c"jmp [rcx]")

	# gen_switch(int* save_esp_here, int restore_esp): the generator
	# context switch (docs/projects/iteration.md), x64 flavor. Saves the
	# callee-saved registers (rbx, rbp, r12-r15) and rsp on the current
	# stack, stores rsp through arg1, loads arg2 into rsp, restores the
	# registers saved there and returns on the other stack.
	sym_define_declare_global_function(c"gen_switch")
	x64_asm(c"push rbx")
	x64_asm(c"push rbp")
	x64_asm(c"push r12")
	x64_asm(c"push r13")
	x64_asm(c"push r14")
	x64_asm(c"push r15")
	x64_asm(c"mov rax,[rsp+0x40]")
	x64_asm(c"mov rcx,[rsp+0x38]")
	x64_asm(c"mov [rax],rsp")
	x64_asm(c"mov rsp,rcx")
	x64_asm(c"pop r15")
	x64_asm(c"pop r14")
	x64_asm(c"pop r13")
	x64_asm(c"pop r12")
	x64_asm(c"pop rbp")
	x64_asm(c"pop rbx")
	x64_asm(c"ret")


void define_asm_functions_x64():
	# syscall reads exactly nr + 3 fixed stack slots, so record its arity:
	# a call with any other argument count would read garbage slots.
	sym_define_declare_global_function_arity(c"syscall", 4)
	x64_asm(c"mov rax,[rsp+0x20]")
	x64_asm(c"mov rdi,[rsp+0x18]")
	x64_asm(c"mov rsi,[rsp+0x10]")
	x64_asm(c"mov rdx,[rsp+8]")
	x64_asm(c"syscall")
	x64_asm(c"ret")

	sym_define_declare_global_function_arity(c"syscall7", 7)
	x64_asm(c"mov rax,[rsp+0x38]")
	x64_asm(c"mov rdi,[rsp+0x30]")
	x64_asm(c"mov rsi,[rsp+0x28]")
	x64_asm(c"mov rdx,[rsp+0x20]")
	x64_asm(c"mov r10,[rsp+0x18]")
	x64_asm(c"mov r8,[rsp+0x10]")
	x64_asm(c"mov r9,[rsp+8]")
	x64_asm(c"syscall")
	x64_asm(c"ret")

	# thread_create(func): clone with a fresh 4MB stack whose top slot
	# holds func, so the child's fall-through "ret" jumps straight into
	# func (the x64 twin of the x86 stub; docs/projects/threads.md).
	# The call targets stack_create, emitted immediately after.
	# The child zeroes rbp so its frame-pointer chain ends at the thread
	# function instead of running into the parent's frames.
	sym_define_declare_global_function(c"thread_create")
	x64_asm(c"call .+0x2a")   # stack_create, emitted immediately after this stub
	x64_asm(c"lea rcx,[rax+0x3ffff0]")
	x64_asm(c"mov rdx,[rsp+8]")
	x64_asm(c"mov [rcx],rdx")
	x64_asm(c"mov edi,-0x7ffe7100")   # CLONE_VM|FS|FILES|SIGHAND|PARENT|THREAD|IO
	x64_asm(c"mov rsi,rcx")
	x64_asm(c"mov eax,0x38")   # clone
	x64_asm(c"syscall")
	x64_asm(c"test eax,eax")
	x64_asm(c"jne .+4")   # parent: keep rbp
	x64_asm(c"xor ebp,ebp")   # child: the frame-pointer chain ends here
	x64_asm(c"ret")

	# stack_create(): mmap(0, 4MB, RW, PRIVATE|ANONYMOUS|GROWSDOWN, -1, 0)
	sym_define_declare_global_function(c"stack_create")
	x64_asm(c"xor edi,edi")
	x64_asm(c"mov esi,0x400000")
	x64_asm(c"mov edx,3")
	x64_asm(c"push dword 0x122")
	x64_asm(c"pop r10")
	x64_asm(c"push byte -1")   # fd for MAP_ANONYMOUS
	x64_asm(c"pop r8")
	x64_asm(c"xor r9,r9")
	x64_asm(c"mov eax,9")   # mmap
	x64_asm(c"syscall")
	x64_asm(c"ret")

	# Thread-local storage (docs/projects/thread_local.md).
	# __w_tls_size(): the per-thread block size, patched at finish.
	sym_define_declare_global_function(c"__w_tls_size")
	tls_size_patch_pos = codepos + 1
	x64_asm(c"mov eax,0")
	x64_asm(c"ret")
	# __w_tls_set(block): write the self pointer to block[0] and make
	# block this thread's gs base (fs stays libc's in a dynamically
	# linked program): arch_prctl(ARCH_SET_GS, block).
	sym_define_declare_global_function(c"__w_tls_set")
	x64_asm(c"mov rsi,[rsp+8]")
	x64_asm(c"mov [rsi],rsi")
	x64_asm(c"mov edi,0x1001")   # ARCH_SET_GS
	x64_asm(c"mov eax,0x9e")   # arch_prctl
	x64_asm(c"syscall")
	x64_asm(c"ret")

	define_asm_functions_x64_portable()
