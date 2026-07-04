# x86 register context: layout must match the get_context/store_context
# stubs in code_generator/x86_asm.w (eight 4-byte slots).

struct register_context:
	int32 eax
	int32 ecx
	int32 edx
	int32 ebx
	int32 esp
	int32 ebp
	int32 esi
	int32 edi


void print_stack():
	println2(c"Stack:")
	register_context context
	get_context(&context)
	print_words(context.esp, 20)


void print_registers():
	println2(c"Registers:")
	register_context context
	get_context(&context)
	print_hex(c"eax: ", context.eax)
	print_hex(c"ecx: ", context.ecx)
	print_hex(c"edx: ", context.edx)
	print_hex(c"ebx: ", context.ebx)
	print_hex(c"esp: ", context.esp)
	print_hex(c"ebp: ", context.ebp)
	print_hex(c"esi: ", context.esi)
	print_hex(c"edi: ", context.edi)
	println2(c"")
