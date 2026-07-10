# Assembly-text source for the x86-64 runtime stubs committed as
# hand-hexed emit() calls in code_generator/x64_asm.w (issue #170).
# Same format and role as stubs_x86.asm; see that file's header.
# Functions appear in the same order as in x64_asm.w: the OS-independent
# portable stubs first (shared with the win64 PE target), then the Linux
# syscall stubs.

arch x64

# get_context(ctx): fill the 16-word context struct at ctx with the
# caller's registers. rcx is saved before the pushed rax is popped
# through it, so the stored rsp is the value at function entry.
func get_context
	push rax
	mov rax,[rsp+0x10]
	mov [rax+8],rcx
	pop rcx
	mov [rax],rcx
	mov [rax+0x10],rdx
	mov [rax+0x18],rbx
	mov [rax+0x20],rsp
	mov [rax+0x28],rbp
	mov [rax+0x30],rsi
	mov [rax+0x38],rdi
	mov [rax+0x40],r8
	mov [rax+0x48],r9
	mov [rax+0x50],r10
	mov [rax+0x58],r11
	mov [rax+0x60],r12
	mov [rax+0x68],r13
	mov [rax+0x70],r14
	mov [rax+0x78],r15
	ret

# store_context(ctx): like get_context but preserves rax instead of
# recording it.
func store_context
	push rax
	mov rax,[rsp+0x10]
	mov [rax+8],rcx
	mov [rax+0x10],rdx
	mov [rax+0x18],rbx
	mov [rax+0x20],rsp
	mov [rax+0x28],rbp
	mov [rax+0x30],rsi
	mov [rax+0x38],rdi
	mov [rax+0x40],r8
	mov [rax+0x48],r9
	mov [rax+0x50],r10
	mov [rax+0x58],r11
	mov [rax+0x60],r12
	mov [rax+0x68],r13
	mov [rax+0x70],r14
	mov [rax+0x78],r15
	pop rax
	ret

# repl_setjmp(buf): save return address, caller rsp and rbp into the
# 24-byte buffer, then return 0.
func repl_setjmp
	mov rax,[rsp+8]
	mov rcx,[rsp]
	mov [rax],rcx
	lea rcx,[rsp+8]
	mov [rax+8],rcx
	mov [rax+0x10],rbp
	xor eax,eax
	ret

# repl_longjmp(buf, val): restore rsp/rbp and jump to the address saved
# by repl_setjmp with val in rax.
func repl_longjmp
	mov rax,[rsp+8]
	mov rcx,[rsp+0x10]
	mov rsp,[rcx+8]
	mov rbp,[rcx+0x10]
	jmp [rcx]

# gen_switch(int* save_esp_here, int restore_esp): the generator context
# switch (docs/projects/iteration.md), x64 flavor.
func gen_switch
	push rbx
	push rbp
	push r12
	push r13
	push r14
	push r15
	mov rax,[rsp+0x40]
	mov rcx,[rsp+0x38]
	mov [rax],rsp
	mov rsp,rcx
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbp
	pop rbx
	ret

func syscall
	mov rax,[rsp+0x20]
	mov rdi,[rsp+0x18]
	mov rsi,[rsp+0x10]
	mov rdx,[rsp+8]
	syscall
	ret

func syscall7
	mov rax,[rsp+0x38]
	mov rdi,[rsp+0x30]
	mov rsi,[rsp+0x28]
	mov rdx,[rsp+0x20]
	mov r10,[rsp+0x18]
	mov r8,[rsp+0x10]
	mov r9,[rsp+8]
	syscall
	ret
