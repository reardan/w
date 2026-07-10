# Assembly-text source for the x86 (32-bit) runtime stubs committed as
# hand-hexed emit() calls in code_generator/x86_asm.w (issue #170).
# tools/gen_stubs.w assembles this file through libs/asm and prints the
# emit() lines; tests/asm_stubs_test.w regenerates the bytes and asserts
# they match the committed file exactly, so the two cannot drift apart.
#
# Format: `arch` picks the encoder, `func NAME` opens the stub named by
# the sym_define_declare_global_function() call, one instruction per
# indented line (canonical Intel syntax, docs/projects/
# assembler_disassembler.md Phase 0.2). A tab followed by `#` starts a
# trailing comment (arm64 operand text itself contains ` #`).
# Functions appear in the same order as in x86_asm.w.

arch x86

# syscall(nr, a1, a2, a3): the first declared argument sits at the
# highest stack offset (W calling convention), int 0x80 traps.
func syscall
	mov eax,[esp+0x10]
	mov ebx,[esp+0xc]
	mov ecx,[esp+8]
	mov edx,[esp+4]
	int 0x80
	ret

func syscall7
	mov eax,[esp+0x1c]
	mov ebx,[esp+0x18]
	mov ecx,[esp+0x14]
	mov edx,[esp+0x10]
	mov esi,[esp+0xc]
	mov edi,[esp+8]
	mov ebp,[esp+4]
	int 0x80
	ret

# get_context(ctx): fill the 8-word context struct with the caller's
# registers. ecx is saved before the pushed eax is popped through it, so
# the stored esp is the value at function entry.
func get_context
	push eax
	mov eax,[esp+8]
	mov [eax+4],ecx
	pop ecx
	mov [eax],ecx
	mov [eax+8],edx
	mov [eax+0xc],ebx
	mov [eax+0x10],esp
	mov [eax+0x14],ebp
	mov [eax+0x18],esi
	mov [eax+0x1c],edi
	ret

# store_context(ctx): like get_context but preserves eax instead of
# recording it.
func store_context
	push eax
	mov eax,[esp+8]
	mov [eax+4],ecx
	mov [eax+8],edx
	mov [eax+0xc],ebx
	mov [eax+0x10],esp
	mov [eax+0x14],ebp
	mov [eax+0x18],esi
	mov [eax+0x1c],edi
	pop eax
	ret

# repl_setjmp(buf): save return address, caller esp and ebp into the
# 12-byte buffer, then return 0. repl_longjmp resumes here returning 1.
func repl_setjmp
	mov eax,[esp+4]
	mov ecx,[esp]
	mov [eax],ecx
	lea ecx,[esp+4]
	mov [eax+4],ecx
	mov [eax+8],ebp
	xor eax,eax
	ret

# repl_longjmp(buf, val): restore esp/ebp and jump to the address saved
# by repl_setjmp with val in eax.
func repl_longjmp
	mov eax,[esp+4]
	mov ecx,[esp+8]
	mov esp,[ecx+4]
	mov ebp,[ecx+8]
	jmp [ecx]

func swap_endian
	mov eax,[esp+4]
	bswap eax
	ret

# swap_endian16(v): byte-swap the low 16 bits. The shift targets eax
# (the return register); the committed stub shifted ebx until #175.
func swap_endian16
	mov eax,[esp+4]
	bswap eax
	mov cl,0x10
	sar eax,cl
	ret

func socket_connect
	mov eax,0x66
	mov ebx,1
	xor edx,edx
	push edx
	push ebx
	push byte 2
	mov ecx,esp
	int 0x80
	xchg edx,eax
	mov al,0x66
	push dword 0x101017f
	pushw 0x5c11
	inc ebx
	push bx
	mov ecx,esp
	push byte 0x10
	push ecx
	push edx
	mov ecx,esp
	inc ebx
	int 0x80
	add esp,0x20
	mov eax,edx
	ret

func socket_connect_new
	mov eax,0x66
	mov ebx,1
	xor edx,edx
	push byte 0
	push byte 1
	push byte 2
	mov ecx,esp
	int 0x80
	add esp,0xc
	push eax
	push eax
	mov eax,0x66
	mov edx,[esp+4]
	add esp,8
	push dword 0x101017f
	pushw 0x5c11
	mov ebx,2
	push bx
	mov ecx,esp
	push byte 0x10
	push ecx
	push edx
	mov ecx,esp
	mov ebx,3
	int 0x80
	add esp,0x14
	mov eax,edx
	ret

func socket
	mov eax,[esp+4]
	mov ebx,[esp+8]
	mov ecx,[esp+0xc]
	push eax
	push ebx
	push ecx
	mov ecx,esp
	mov eax,0x66
	mov ebx,1
	xor edx,edx
	int 0x80
	add esp,0xc
	ret

func connect
	mov ebp,esp
	mov edx,[ebp+0xc]
	mov eax,[ebp+8]
	mov ebx,[ebp+4]
	bswap eax
	push eax
	bswap ebx
	mov cl,0x10
	sar ebx,cl
	push bx
	mov ebx,2
	push bx
	mov ecx,esp
	push byte 0x10
	push ecx
	push edx
	mov ecx,esp
	mov eax,0x66
	mov ebx,3
	int 0x80
	add esp,0x14
	mov eax,edx
	ret

func setsockopt
	mov edx,[esp+4]
	push byte 4
	push esp
	push byte 2
	push byte 1
	push edx
	mov ecx,esp
	mov eax,0x66
	mov ebx,0xe
	int 0x80
	add esp,0x14
	ret

func bind
	mov edx,[esp+8]
	mov ebx,[esp+4]
	bswap ebx
	mov cl,0x10
	sar ebx,cl
	push byte 0
	push bx
	pushw 2
	mov ecx,esp
	push byte 0x10
	push ecx
	push edx
	mov eax,0x66
	mov ebx,2
	mov ecx,esp
	int 0x80
	add esp,0x14
	ret

func listen
	mov edx,[esp+4]
	push byte 0
	push edx
	mov ecx,esp
	mov eax,0x66
	mov ebx,4
	int 0x80
	add esp,8
	mov eax,edx
	ret

func socket_accept
	mov edx,[esp+4]
	mov eax,0x66
	mov ebx,5
	push byte 0
	push byte 0
	push edx
	mov ecx,esp
	int 0x80
	mov edx,eax
	add esp,0xc
	ret

# thread_create(func): clone with a fresh 4MB stack whose top slot holds
# func, so the child's fall-through "ret" jumps straight into func.
func thread_create
	call .+0x1e	# stack_create, emitted immediately after this stub
	lea ecx,[eax+0x3ffff0]
	mov edx,[esp+4]
	mov [ecx],edx
	mov ebx,-0x7ffe7100	# CLONE_VM|FS|FILES|SIGHAND|PARENT|THREAD|IO
	mov eax,0x78
	int 0x80
	ret

# stack_create(): mmap2(0, 4MB, RW, PRIVATE|ANONYMOUS|GROWSDOWN, -1, 0)
func stack_create
	mov ebx,0
	mov ecx,0x400000
	mov edx,3
	mov esi,0x122
	mov edi,-1
	mov ebp,0
	mov eax,0xc0
	int 0x80
	ret

func function_call
	mov eax,[esp+4]
	jmp eax

# gen_switch(int* save_esp_here, int restore_esp): the generator context
# switch (docs/projects/iteration.md).
func gen_switch
	push ebx
	push esi
	push edi
	push ebp
	mov eax,[esp+0x18]
	mov ecx,[esp+0x14]
	mov [eax],esp
	mov esp,ecx
	pop ebp
	pop edi
	pop esi
	pop ebx
	ret
