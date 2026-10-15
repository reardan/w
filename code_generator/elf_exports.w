# Native ELF library exports. The parser records the same typed
# signatures as wasm exports; each entry gets a native C ABI adapter.
import code_generator.wasm_module
import code_generator.ffi

char* elf_export_addresses


# AAPCS64 adapter. Keep the native frame above the downward-growing W
# stack and preserve every native callee-saved GPR and low SIMD half.
# Reserve 256 KiB below x28, like the iOS callback bridge, so host signal
# frames and native-bridge transitions below sp cannot overwrite W frames.
# x18 is Android's platform register and is never touched by the adapter
# or the W ARM64 emitter. Arguments spilled by the C caller remain above
# the 160-byte save frame. W returns float bits in x0.
void elf_emit_arm64_export(int address, int n, char* classes, int ret_kind):
	char* slots = ffi_assign_slots(n, classes, 8)
	a64(op(0xd1, 0x0283ff))   # sub sp,sp,#160
	for r in range(12):
		a64(op(0xf9, 0x0003e0) | (r << 10) | (19 + r)) # str x19..x30,[sp,#8r]
	for r in range(8):
		a64(op(0xfd, 0x0003e0) | ((12 + r) << 10) | (8 + r)) # str d8..d15
	a64(op(0x91, 0x0003fc))   # mov x28,sp
	int spilled = 0
	for i in range(n):
		int slot = load_i(slots + i * 4, 4)
		int reg = slot
		if (slot < 0):
			a64(op(0xf9, 0x4003e9) | ((20 + spilled) << 10)) # ldr x9,[sp,#160+8k]
			spilled = spilled + 1
			reg = 9
		else if (slot >= 16):
			if (ffi_arg_class(classes, i) == 2): a64(op(0x9e, 0x660009) | ((slot - 16) << 5)) # fmov x9,dN
			else: a64(op(0x1e, 0x260009) | ((slot - 16) << 5)) # fmov w9,sN
			reg = 9
		a64(op(0xf8, 0x1f8f80) | reg) # str xN,[x28,#-8]!
	a64(op(0xd1, 0x4103ff))   # sub sp,sp,#64,lsl #12 (256 KiB)
	int delta = address - code_offset - codepos
	a64(op(0x94, 0x000000) | ((delta >> 2) & op(0x03, 0xffffff))) # bl W function
	a64(op(0x91, 0x4103ff))   # add sp,sp,#64,lsl #12
	for r in range(12):
		a64(op(0xf9, 0x4003e0) | (r << 10) | (19 + r))
	for r in range(8):
		a64(op(0xfd, 0x4003e0) | ((12 + r) << 10) | (8 + r))
	a64(op(0x91, 0x0283ff))   # add sp,sp,#160
	if (ret_kind == 2): a64(op(0x1e, 0x270000)) # fmov s0,w0
	if (ret_kind == 3): a64(op(0x9e, 0x670000)) # fmov d0,x0
	a64(op(0xd6, 0x5f03c0))   # ret
	free(slots)


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
		if (target_isa == 1):
			elf_emit_arm64_export(address, n, classes, load_i(wasm_export_rets + e * 4, 4))
			continue
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
