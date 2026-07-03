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
	println2("Stack:")
	register_context context
	get_context(&context)
	print_words(context.esp, 20)


void print_registers():
	println2("Registers:")
	register_context context
	get_context(&context)
	print_hex("eax: ", context.eax)
	print_hex("ecx: ", context.ecx)
	print_hex("edx: ", context.edx)
	print_hex("ebx: ", context.ebx)
	print_hex("esp: ", context.esp)
	print_hex("ebp: ", context.ebp)
	print_hex("esi: ", context.esi)
	print_hex("edi: ", context.edi)
	println2("")
