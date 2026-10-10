# Native x64 shared/static library exports. The parser records the same typed
# signatures as wasm exports; each entry gets a System V ABI adapter.
import code_generator.wasm_module
import code_generator.ffi

char* elf_export_addresses


void elf_emit_export_wrappers():
	if (tls_size > 0):
		if (elf_static): error(c"--static does not support thread_local storage")
		error(c"--shared does not support thread_local storage")
	for i in range(dyn_import_count):
		if (dyn_import_get_symtype(i) == 1): error(c"--shared does not support extern data")
	elf_export_addresses = cast(char*, malloc(wasm_export_count * __word_size__ + 1))
	for e in range(wasm_export_count):
		char* name = cast(char*, load_i(wasm_export_names + e * __word_size__, __word_size__))
		int sym = load_i(wasm_export_syms + e * 4, 4)
		if (sym_decl_visibility(sym) != 'D'):
			error3(c"exported function '", name, c"' is never defined")
		int address = sym_address(name)
		save_i(elf_export_addresses + e * __word_size__, code_offset + codepos, __word_size__)
		int n = load_i(wasm_export_nparams + e * 4, 4)
		char* classes = cast(char*, load_i(wasm_export_classes + e * __word_size__, __word_size__))
		char* slots = ffi_assign_slots(n, classes, 6)
		# Preserve every System V callee-saved register around the W call.
		emit(4, c"\x55\x48\x89\xe5")
		push_reg(3)
		for r in range(12, 16): push_reg(r)
		int spilled = 0
		for i in range(n):
			int slot = load_i(slots + i * 4, 4)
			if (slot < 0):
				# Native stack arguments follow the saved rbp and return address.
				emit(2, c"\xff\xb5")
				emit_int32(16 + spilled * 8)
				spilled = spilled + 1
			else if (slot >= 16):
				# movq rax,xmmN; push rax (float bits are W stack words).
				emit(4, c"\x66\x48\x0f\x7e")
				emit_int8(0xc0 | ((slot - 16) << 3))
				push_reg(0)
			else:
				int reg = slot
				if (slot == 0): reg = 7
				else if (slot == 1): reg = 6
				else if (slot == 2): reg = 2
				else if (slot == 3): reg = 1
				else: reg = slot + 4
				push_reg(reg)
		emit_int8(0xe8)
		emit_int32(address - code_offset - codepos - 4)
		if (n > 0):
			emit(3, c"\x48\x83\xc4")
			emit_int8(n * 8)
		for r in range(4): pop_reg(15 - r)
		pop_reg(3)
		emit_int8(0x5d)
		int ret_kind = load_i(wasm_export_rets + e * 4, 4)
		if (ret_kind == 2): emit(4, c"\x66\x0f\x6e\xc0")
		if (ret_kind == 3): emit(5, c"\x66\x48\x0f\x6e\xc0")
		emit_int8(0xc3)
		free(slots)
