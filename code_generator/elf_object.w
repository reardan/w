# --emit=obj: an x64 ELF ET_REL object for a system linker (cc, ld).
#
# The code generator already keeps what a static library needs: x64
# code reaches data only through RIP-relative address slots (noted in
# static_address_slots) and every absolute pointer stored in data is a
# PIE rebase cell (rebase_table). Those records become relocations here:
#
#   text -> data address slot   R_X86_64_PC32 against .data (+ offset)
#   data pointer cell           R_X86_64_64 against .text / .data
#   extern function slot        R_X86_64_64 against the undefined symbol
#   extern data reference       R_X86_64_PC32 / _64 against that symbol
#
# Text-to-text references are PC-relative and need nothing. Exported
# functions are global symbols at their System V adapters
# (elf_exports.w); globals declared in the command-line roots are
# global data symbols; every other W function and global stays local.
# docs/projects/object_files.md describes the mode and its limits.
#
# This file is compiled by the committed seed: only seed-understood
# syntax here.
import code_generator.code_emitter
import code_generator.static_link
import code_generator.elf_exports
import code_generator.dynamic_registry

int sym_address(char* s);
char* debug_file_name(int index);
int global_storage_size(int type);
int next_token(int t);


# Roots named on the command line (compile_attempt records each file it
# opens while object_root_pending is set): their globals are global.
int object_root_pending
list[char*] object_root_files


void object_note_root(char* path):
	if (cast(int, object_root_files) == 0): object_root_files = new list[char*]
	object_root_files.push(strclone(path))


int object_file_is_root(int file_index):
	if (cast(int, object_root_files) == 0): return 0
	char* name = debug_file_name(file_index)
	for i in range(object_root_files.length):
		if (strcmp(object_root_files[i], name) == 0): return 1
	return 0


struct object_buffer:
	char* bytes
	int length
	int capacity


object_buffer* object_buffer_new():
	object_buffer* b = cast(object_buffer*, malloc(sizeof(object_buffer)))
	b.capacity = 4096
	b.bytes = cast(char*, malloc(b.capacity))
	b.length = 0
	return b


void object_buffer_reserve(object_buffer* b, int n):
	if (b.length + n <= b.capacity): return
	int grown = (b.length + n) * 2
	b.bytes = cast(char*, realloc(b.bytes, b.capacity, grown))
	b.capacity = grown


void object_put(object_buffer* b, char* src, int n):
	object_buffer_reserve(b, n)
	for i in range(n): b.bytes[b.length + i] = src[i]
	b.length = b.length + n


void object_u8(object_buffer* b, int v):
	object_buffer_reserve(b, 1)
	b.bytes[b.length] = v
	b.length = b.length + 1


void object_u16(object_buffer* b, int v):
	object_u8(b, v & 255)
	object_u8(b, (v >> 8) & 255)


void object_u32(object_buffer* b, int v):
	object_buffer_reserve(b, 4)
	save_int32(b.bytes + b.length, v)
	b.length = b.length + 4


# A sign-extended 64-bit field. Every value fits 32 bits, and writing
# the halves avoids a 64-bit shift on the 32-bit host compiler.
void object_i64(object_buffer* b, int v):
	object_u32(b, v)
	if (v < 0): object_u32(b, -1)
	else: object_u32(b, 0)


void object_align(object_buffer* b, int a):
	while ((b.length % a) != 0): object_u8(b, 0)


# NUL-terminated string; returns its offset in the table.
int object_string(object_buffer* b, char* s):
	int at = b.length
	object_put(b, s, strlen(s) + 1)
	return at


# Section indices of the object (fixed layout, see elf_object_write).
const int object_sec_text = 1
const int object_sec_data = 2
const int object_sec_symtab = 4
const int object_sec_count = 9

object_buffer* object_symtab
object_buffer* object_strtab
int object_symbol_count


# Elf64_Sym: name, info (binding << 4 | type), other, shndx, value, size.
int object_symbol(char* name, int binding, int symtype, int shndx, int value, int size):
	int name_off = 0
	if (name != 0): name_off = object_string(object_strtab, name)
	object_u32(object_symtab, name_off)
	object_u8(object_symtab, (binding << 4) | symtype)
	object_u8(object_symtab, 0)
	object_u16(object_symtab, shndx)
	object_i64(object_symtab, value)
	object_i64(object_symtab, size)
	object_symbol_count = object_symbol_count + 1
	return object_symbol_count - 1


# Elf64_Rela: offset, info (symbol << 32 | type), addend.
void object_rela(object_buffer* b, int offset, int symbol, int rtype, int addend):
	object_i64(b, offset)
	object_u32(b, rtype)
	object_u32(b, symbol)
	object_i64(b, addend)


int object_text_vaddr():
	return code_offset + elf_object_text_start


int object_in_text(int vaddr):
	return (vaddr >= object_text_vaddr()) && (vaddr <= code_offset + codepos)


int object_in_data(int vaddr):
	return (vaddr >= data_offset) && (vaddr <= data_offset + datapos)


# Index into the dynamic registry of the extern data object whose
# placeholder space holds vaddr, or -1.
int object_extern_data_at(int vaddr):
	for i in range(dyn_import_count):
		if (dyn_import_get_symtype(i) == 1):
			int start = dyn_import_got_vaddr(i)
			if ((vaddr >= start) && (vaddr < start + dyn_import_get_size(i))): return i
	return -1


int object_is_extern_function_slot(int vaddr):
	for i in range(object_import_slots.length):
		if (object_import_slots[i] == vaddr): return 1
	return 0


# Name already given to a global or undefined symbol: a local W symbol of
# the same name (an exported body, an extern shim) is left out.
list[char*] object_global_names


int object_name_is_global(char* name):
	for i in range(object_global_names.length):
		if (strcmp(object_global_names[i], name) == 0): return 1
	return 0


# Local symbols for W functions and the non-root globals; with
# want_global, the root globals as global data symbols instead.
void object_table_symbols(int want_global):
	int t = 0
	while (t <= table_pos - 1):
		char* name = table + t
		t = t + strlen(table + t)
		int value = load_int(table + t + 2)
		int symtype = load_int(table + t + 10)
		int type = load_int(table + t + 6)
		if (table[t + 1] == 'D'):
			if ((symtype == 2) && (want_global == 0) && object_in_text(value) && (object_name_is_global(name) == 0)):
				object_symbol(name, 0, 2, object_sec_text, value - object_text_vaddr(), 0)
			else if ((symtype == 1) && object_in_data(value) && (value < data_offset + datapos) && (object_extern_data_at(value) < 0) && (type_get_kind(type) != type_kind_enum)):
				int is_root = object_file_is_root(sym_decl_file_index(t))
				if (is_root == want_global):
					object_symbol(name, is_root, 1, object_sec_data, value - data_offset, global_storage_size(type))
					if (is_root): object_global_names.push(name)
		t = next_token(t)


# Return the data target of the address slot at pos, -1 for an
# intra-text reference or a slot a peephole has since rewritten (the
# same filter static_library_data_target applies).
int object_slot_target(int pos):
	if ((pos < 3) || (pos > codepos - 4)): return -1
	int lea = ((code[pos - 3] & 255) == 0x48) && ((code[pos - 2] & 255) == 0x8d) && ((code[pos - 1] & 255) == 5)
	int indirect_call = ((code[pos - 2] & 255) == 0xff) && ((code[pos - 1] & 255) == 0x15)
	if ((lea == 0) && (indirect_call == 0)): return -1
	int target = code_offset + pos + 4 + load_int(code + pos)
	if (object_in_data(target)): return target
	if (object_in_text(target)): return -1
	error(c"internal error: --emit=obj address slot leaves the object")
	return -1


void object_section_header(object_buffer* b, int name, int type, int flags, int offset, int size, int link, int info, int align, int entsize):
	object_u32(b, name)
	object_u32(b, type)
	object_i64(b, flags)
	object_i64(b, 0)
	object_i64(b, offset)
	object_i64(b, size)
	object_u32(b, link)
	object_u32(b, info)
	object_i64(b, align)
	object_i64(b, entsize)


void elf_object_write():
	# A retained W runtime owns a private heap, as in a static library:
	# mmap keeps it clear of the host program's brk-based malloc.
	int mmap_mode = sym_address(c"malloc_mmap_mode")
	if (mmap_mode): save_i(data + mmap_mode - data_offset, 1, word_size)

	object_symtab = object_buffer_new()
	object_strtab = object_buffer_new()
	object_global_names = new list[char*]
	object_symbol_count = 0
	object_u8(object_strtab, 0)
	object_symbol(0, 0, 0, 0, 0, 0)
	int text_symbol = object_symbol(0, 0, 3, object_sec_text, 0, 0)
	int data_symbol = object_symbol(0, 0, 3, object_sec_data, 0, 0)

	# Global and undefined names first, so their local twins are skipped.
	for e in range(wasm_export_count):
		object_global_names.push(cast(char*, load_i(wasm_export_names + e * __word_size__, __word_size__)))
	for i in range(object_import_names.length): object_global_names.push(object_import_names[i])
	for i in range(dyn_import_count):
		if (dyn_import_get_symtype(i) == 1): object_global_names.push(dyn_import_name(i))
	object_table_symbols(0)
	int first_global = object_symbol_count
	for e in range(wasm_export_count):
		char* name = cast(char*, load_i(wasm_export_names + e * __word_size__, __word_size__))
		int adapter = load_i(elf_export_addresses + e * __word_size__, __word_size__)
		object_symbol(name, 1, 2, object_sec_text, adapter - object_text_vaddr(), 0)
	object_table_symbols(1)
	int first_import = object_symbol_count
	for i in range(object_import_names.length): object_symbol(object_import_names[i], 1, 0, 0, 0, 0)
	char* data_symbols = cast(char*, malloc(dyn_import_count * 4 + 4))
	for i in range(dyn_import_count):
		if (dyn_import_get_symtype(i) == 1):
			save_int32(data_symbols + i * 4, object_symbol(dyn_import_name(i), 1, 0, 0, 0, 0))

	# .rela.text: address slots that reach data. Slots are noted on every
	# write (backpatch chains rewrite them), so each is taken once.
	object_buffer* rela_text = object_buffer_new()
	char* seen = cast(char*, malloc(codepos + 1))
	for p in range(codepos + 1): seen[p] = 0
	for i in range(static_address_count):
		int pos = load_int32(static_address_slots + i * 4)
		int target = -1
		if ((pos >= elf_object_text_start) && (pos <= codepos - 4)):
			if (seen[pos] == 0): target = object_slot_target(pos)
			seen[pos] = 1
		if (target >= 0):
			int offset = pos - elf_object_text_start
			int extern_data = object_extern_data_at(target)
			# R_X86_64_PC32 (2): S + A - P, P being the disp32 itself.
			if (extern_data >= 0):
				object_rela(rela_text, offset, load_int32(data_symbols + extern_data * 4), 2, target - dyn_import_got_vaddr(extern_data) - 4)
			else: object_rela(rela_text, offset, data_symbol, 2, target - data_offset - 4)
	free(seen)

	# .rela.data: absolute pointer cells, then the extern function slots.
	char* data_copy = cast(char*, malloc(datapos + 1))
	for j in range(datapos): data_copy[j] = data[j]
	object_buffer* rela_data = object_buffer_new()
	char* cell_seen = cast(char*, malloc(datapos + 1))
	for j in range(datapos + 1): cell_seen[j] = 0
	for r in range(rebase_count):
		int cell = load_i(rebase_table + r * 8, 8) - data_offset
		if ((cell < 0) || (cell > datapos - 8)): error(c"internal error: --emit=obj pointer cell is outside data")
		if (cell_seen[cell] == 0):
			cell_seen[cell] = 1
			int value = load_i(data + cell, 8)
			int extern_cell = object_extern_data_at(value)
			# R_X86_64_64 (1): S + A, the cell's linked value. A null
			# cell stays null.
			if (value != 0):
				if (extern_cell >= 0):
					object_rela(rela_data, cell, load_int32(data_symbols + extern_cell * 4), 1, value - dyn_import_got_vaddr(extern_cell))
				else if (object_in_data(value)):
					object_rela(rela_data, cell, data_symbol, 1, value - data_offset)
				else if (object_in_text(value)):
					object_rela(rela_data, cell, text_symbol, 1, value - object_text_vaddr())
				else: error(c"internal error: --emit=obj pointer cell leaves the object")
			save_i(data_copy + cell, 0, 8)
	free(cell_seen)
	for i in range(object_import_slots.length):
		object_rela(rela_data, object_import_slots[i] - data_offset, first_import + i, 1, 0)
	free(data_symbols)

	object_buffer* names = object_buffer_new()
	object_u8(names, 0)
	int name_text = object_string(names, c".text")
	int name_data = object_string(names, c".data")
	int name_stack = object_string(names, c".note.GNU-stack")
	int name_symtab = object_string(names, c".symtab")
	int name_strtab = object_string(names, c".strtab")
	int name_rela_text = object_string(names, c".rela.text")
	int name_rela_data = object_string(names, c".rela.data")
	int name_shstrtab = object_string(names, c".shstrtab")

	# File layout: header, .text, .data, .symtab, .strtab, .rela.text,
	# .rela.data, .shstrtab, section headers.
	object_buffer* out = object_buffer_new()
	object_put(out, c"\x7f\x45\x4c\x46\x02\x01\x01", 7)
	for k in range(9): object_u8(out, 0)
	object_u16(out, 1)     # ET_REL
	object_u16(out, 62)    # EM_X86_64
	object_u32(out, 1)
	object_i64(out, 0)     # e_entry
	object_i64(out, 0)     # e_phoff
	int shoff_at = out.length
	object_i64(out, 0)     # e_shoff, patched below
	object_u32(out, 0)
	object_u16(out, 64)
	object_u16(out, 0)
	object_u16(out, 0)
	object_u16(out, 64)
	object_u16(out, object_sec_count)
	object_u16(out, object_sec_count - 1)
	object_align(out, 16)
	int text_off = out.length
	int text_size = codepos - elf_object_text_start
	object_put(out, code + elf_object_text_start, text_size)
	object_align(out, 16)
	int data_off = out.length
	object_put(out, data_copy, datapos)
	free(data_copy)
	object_align(out, 8)
	int symtab_off = out.length
	object_put(out, object_symtab.bytes, object_symtab.length)
	int strtab_off = out.length
	object_put(out, object_strtab.bytes, object_strtab.length)
	object_align(out, 8)
	int rela_text_off = out.length
	object_put(out, rela_text.bytes, rela_text.length)
	int rela_data_off = out.length
	object_put(out, rela_data.bytes, rela_data.length)
	int names_off = out.length
	object_put(out, names.bytes, names.length)
	object_align(out, 8)
	save_int32(out.bytes + shoff_at, out.length)

	object_section_header(out, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	object_section_header(out, name_text, 1, 6, text_off, text_size, 0, 0, 16, 0)        # AX
	object_section_header(out, name_data, 1, 3, data_off, datapos, 0, 0, 16, 0)          # WA
	object_section_header(out, name_stack, 1, 0, data_off, 0, 0, 0, 1, 0)
	object_section_header(out, name_symtab, 2, 0, symtab_off, object_symtab.length, 5, first_global, 8, 24)
	object_section_header(out, name_strtab, 3, 0, strtab_off, object_strtab.length, 0, 0, 1, 0)
	object_section_header(out, name_rela_text, 4, 64, rela_text_off, rela_text.length, object_sec_symtab, object_sec_text, 8, 24)
	object_section_header(out, name_rela_data, 4, 64, rela_data_off, rela_data.length, object_sec_symtab, object_sec_data, 8, 24)
	object_section_header(out, name_shstrtab, 3, 0, names_off, names.length, 0, 0, 1, 0)

	if (write(output_fd, out.bytes, out.length) != out.length): error(c"could not write object file")
