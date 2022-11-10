import code_generator.code_emitter


void sym_define_declare_global_function(char* name); /* defined in symbol_table */


void define_asm_functions_x64():
	sym_define_declare_global_function("syscall")
	/* mov rax,[rsp+32] ; mov rdi,[rsp+24] ; mov rsi,[rsp+16] ; mov rdx,[rsp+8] ; syscall ; ret */
	emit(20, "\x48\x8b\x44\x24\x20\x48\x8b\x7c\x24\x18\x48\x8b\x74\x24\x10\x48\x8b\x54\x24\x08")
	emit(3, "\x0f\x05\xc3")

	sym_define_declare_global_function("syscall7")
	/* mov rax,[esp+56] ; mov rdi,[esp+48] ; mov rsi,[esp+40] ; mov rdx,[esp+32] ; mov r10,[esp+24] ; mov r8,[esp+16] ; mov r9,[esp+8] ; syscall ; ret */
	emit(20, "\x67\x48\x8b\x44\x24\x38\x67\x48\x8b\x7c\x24\x30\x67\x48\x8b\x74\x24\x28\x67\x48")
	emit(20, "\x8b\x54\x24\x20\x67\x48\x8b\x54\x24\x18\x67\x48\x8b\x44\x24\x10\x67\x48\x8b\x4c")
	emit(5,  "\x24\x08\x0f\x05\xc3")


	/* temporary mocks: */
	sym_define_declare_global_function("get_context")
	sym_define_declare_global_function("store_context")
	emit(1, "\xc3") /* ret */
