# WLIB64 v1 stores a compiled x64 module with independent text/data
# relocation records. It is a W archive, consumed by --link, not a
# platform ar archive. All fields below are little-endian 32-bit words.
import code_generator.elf_exports


void static_library_bytes(char* bytes, int count):
	if (write(output_fd, bytes, count) != count): error(c"could not write static library")


void static_library_word(int value):
	char* bytes = cast(char*, &value)
	static_library_bytes(bytes, 4)


# Return the final target only for surviving cross-segment LEA slots.
# Direct-call folding discards function-address slots; neither those nor
# intra-text references need relocations when a whole module is moved.
int static_library_data_target(int pos):
	if ((pos < 3) || (pos > codepos - 4)): return -1
	int lea = ((code[pos - 3] & 255) == 0x48) && ((code[pos - 2] & 255) == 0x8d) && ((code[pos - 1] & 255) == 5)
	int indirect_call = ((code[pos - 2] & 255) == 0xff) && ((code[pos - 1] & 255) == 0x15)
	if ((lea == 0) && (indirect_call == 0)): return -1
	int target = code_offset + pos + 4 + load_int(code + pos)
	if ((target < data_offset) || (target > data_offset + datapos)): return -1
	return target - data_offset


void static_library_write():
	if (dyn_import_count > 0): error(c"--static does not support dynamic imports")
	if (tls_size > 0): error(c"--static does not support thread_local storage")
	# Every independently compiled module owns allocator bookkeeping.
	# Sharing the process brk would let those heaps overlap; mmap keeps
	# each module's allocations independent, as for shared libraries.
	int mmap_mode = sym_address(c"malloc_mmap_mode")
	if (mmap_mode): save_i(data + mmap_mode - data_offset, 1, word_size)
	int fixups = 0
	for i in range(static_address_count):
		int pos = load_int(static_address_slots + i * 4)
		if (static_library_data_target(pos) >= 0): fixups = fixups + 1
	static_library_bytes(c"WLIB64\x00\x01", 8)
	static_library_word(codepos)
	static_library_word(datapos)
	static_library_word(fixups)
	static_library_word(rebase_count)
	static_library_word(wasm_export_count)
	static_library_word(code_offset)
	static_library_word(data_offset)
	static_library_bytes(code, codepos)
	static_library_bytes(data, datapos)
	for i in range(static_address_count):
		int pos = load_int(static_address_slots + i * 4)
		int target = static_library_data_target(pos)
		if (target >= 0):
			static_library_word(pos)
			static_library_word(target)
	for i in range(rebase_count):
		int cell = load_i(rebase_table + i * 8, 8) - data_offset
		if ((cell < 0) || (cell > datapos - 8)): error(c"static library pointer relocation is outside data")
		int target = load_i(data + cell, 8)
		int segment = 0
		int offset = target - code_offset
		if ((target >= data_offset) && (target <= data_offset + datapos)):
			segment = 1
			offset = target - data_offset
		else if ((offset < 0) || (offset > codepos)):
			error(c"static library pointer relocation has an invalid target")
		static_library_word(cell)
		static_library_word(segment)
		static_library_word(offset)
	for e in range(wasm_export_count):
		char* name = cast(char*, load_i(wasm_export_names + e * __word_size__, __word_size__))
		int len = strlen(name)
		static_library_word(len)
		static_library_bytes(name, len)
		static_library_word(load_i(elf_export_addresses + e * __word_size__, __word_size__) - code_offset)
