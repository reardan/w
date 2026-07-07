# AArch64 register context: layout matches the get_context/store_context
# stubs in code_generator/arm64_asm.w, which store x0..x30 into 31
# word-sized slots. Identical to lib/__arch__/arm64/context.w — the
# context capture is ISA-level, not OS-level.

struct register_context:
	int x0
	int x1
	int x2
	int x3
	int x4
	int x5
	int x6
	int x7
	int x8
	int x9
	int x10
	int x11
	int x12
	int x13
	int x14
	int x15
	int x16
	int x17
	int x18
	int x19
	int x20
	int x21
	int x22
	int x23
	int x24
	int x25
	int x26
	int x27
	int x28
	int x29
	int x30


void print_stack():
	println2(c"Stack:")
	register_context context
	get_context(&context)
	# x28 is the W evaluation stack pointer.
	print_words(context.x28, 20)


void print_registers():
	println2(c"Registers:")
	register_context context
	get_context(&context)
	print_hex(c"x0:  ", context.x0)
	print_hex(c"x1:  ", context.x1)
	print_hex(c"x2:  ", context.x2)
	print_hex(c"x28: ", context.x28)
	print_hex(c"x29: ", context.x29)
	print_hex(c"x30: ", context.x30)
	println2(c"")
