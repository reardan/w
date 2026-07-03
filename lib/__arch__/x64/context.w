# x64 register context: layout must match the get_context/store_context
# stubs in code_generator/x64_asm.w (sixteen 8-byte slots, int is
# word-sized on x64).

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
	println2("Stack:")
	register_context context
	get_context(&context)
	print_words(context.rsp, 20)


void print_registers():
	println2("Registers:")
	register_context context
	get_context(&context)
	print_hex("rax: ", context.rax)
	print_hex("rcx: ", context.rcx)
	print_hex("rdx: ", context.rdx)
	print_hex("rbx: ", context.rbx)
	print_hex("rsp: ", context.rsp)
	print_hex("rbp: ", context.rbp)
	print_hex("rsi: ", context.rsi)
	print_hex("rdi: ", context.rdi)
	print_hex("r8:  ", context.r8)
	print_hex("r9:  ", context.r9)
	print_hex("r10: ", context.r10)
	print_hex("r11: ", context.r11)
	print_hex("r12: ", context.r12)
	print_hex("r13: ", context.r13)
	print_hex("r14: ", context.r14)
	print_hex("r15: ", context.r15)
	println2("")
