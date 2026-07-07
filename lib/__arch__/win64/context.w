# win64 register context: identical to the x64 module because the
# get_context/store_context stubs (define_asm_functions_x64_portable in
# code_generator/x64_asm.w) are pure register operations shared by the
# Linux and Windows x86-64 targets.

struct register_context:
	int rax
	int rcx
	int rdx
	int rbx
	int rsp
	int rbp
	int rsi
	int rdi
	int r8
	int r9
	int r10
	int r11
	int r12
	int r13
	int r14
	int r15


void print_stack():
	println2(c"Stack:")
	register_context context
	get_context(&context)
	print_words(context.rsp, 20)


void print_registers():
	println2(c"Registers:")
	register_context context
	get_context(&context)
	print_hex(c"rax: ", context.rax)
	print_hex(c"rcx: ", context.rcx)
	print_hex(c"rdx: ", context.rdx)
	print_hex(c"rbx: ", context.rbx)
	print_hex(c"rsp: ", context.rsp)
	print_hex(c"rbp: ", context.rbp)
	print_hex(c"rsi: ", context.rsi)
	print_hex(c"rdi: ", context.rdi)
	print_hex(c"r8:  ", context.r8)
	print_hex(c"r9:  ", context.r9)
	print_hex(c"r10: ", context.r10)
	print_hex(c"r11: ", context.r11)
	print_hex(c"r12: ", context.r12)
	print_hex(c"r13: ", context.r13)
	print_hex(c"r14: ", context.r14)
	print_hex(c"r15: ", context.r15)
	println2(c"")
