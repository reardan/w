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
# Attributes (grammar/object_attributes.w) and the literal and zero
# globals split the buffers into named sections (object_layout): every
# reference whose two ends move apart -- recorded call cells included --
# is rewritten or relocated against the target's section. Exported
# functions are global symbols at their System V adapters
# (elf_exports.w), or under --c-abi every root function not marked
# 'static' at its System V entry (c_abi.w); globals declared in the
# command-line roots (and not 'static') are global data symbols; every
# other W function and global stays local.
# docs/projects/object_files.md describes the mode and its limits.
#
# This file is compiled by the committed seed: only seed-understood
# syntax here.
import code_generator.code_emitter
import code_generator.static_link
import code_generator.elf_exports
import code_generator.c_abi
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


# --- Placement records, filled while the program compiles -------------
#
# Attributes (grammar/object_attributes.w) and a few emitters note what
# the writer below needs to split the code and data buffers into named
# sections. Each list is created on first use.

# Displacement cells of every `call rel32` (call_relative32, the export
# adapters' calls): text-to-text references that need a relocation or a
# fixup once code is split across sections. A fold that rolls codepos
# back drops the cells past it (object_rel32_rollback).
list[int] object_rel32_sites
# Function definitions with a section or alignment: code buffer offsets.
list[int] object_text_place_start
list[int] object_text_place_end
list[int] object_text_place_align
list[char*] object_text_place_section
# Globals with a section or alignment: symbol-table offsets.
list[int] object_data_place_symbol
list[int] object_data_place_align
list[char*] object_data_place_section
# Read-only literal bytes in the data buffer: data buffer offsets.
list[int] object_rodata_start
list[int] object_rodata_end
# Symbol names with weak binding (definitions and undefined references).
list[char*] object_weak_names
# Function aliases: a second global name for a definition.
list[char*] object_alias_names
list[char*] object_alias_targets
list[int] object_alias_symbols
list[int] object_alias_is_function
int object_records_ready


void object_records_init():
	if (object_records_ready): return
	object_records_ready = 1
	object_rel32_sites = new list[int]
	object_text_place_start = new list[int]
	object_text_place_end = new list[int]
	object_text_place_align = new list[int]
	object_text_place_section = new list[char*]
	object_data_place_symbol = new list[int]
	object_data_place_align = new list[int]
	object_data_place_section = new list[char*]
	object_rodata_start = new list[int]
	object_rodata_end = new list[int]
	object_weak_names = new list[char*]
	object_alias_names = new list[char*]
	object_alias_targets = new list[char*]
	object_alias_symbols = new list[int]
	object_alias_is_function = new list[int]


void object_note_rel32(int pos):
	object_records_init()
	object_rel32_sites.push(pos)


void object_rel32_rollback(int pos):
	if (object_records_ready == 0): return
	while ((object_rel32_sites.length > 0) && (object_rel32_sites[object_rel32_sites.length - 1] >= pos)): object_rel32_sites.pop()


void object_place_function(int start, int end, char* section, int align):
	object_records_init()
	object_text_place_start.push(start)
	object_text_place_end.push(end)
	object_text_place_section.push(section)
	object_text_place_align.push(align)


void object_place_global(int symbol, char* section, int align):
	object_records_init()
	object_data_place_symbol.push(symbol)
	object_data_place_section.push(section)
	object_data_place_align.push(align)


# Emit n literal bytes into the data buffer as read-only data (.rodata in
# the object), padded to a word; returns their vaddr.
int object_rodata_bytes(char* bytes, int n):
	object_records_init()
	int padded = (n + 7) & (-8)
	int vaddr = emit_data_zeros(padded)
	for i in range(n): data[vaddr - data_offset + i] = bytes[i]
	object_rodata_start.push(vaddr - data_offset)
	object_rodata_end.push(vaddr - data_offset + padded)
	return vaddr


int object_name_in(list[char*] names, char* name):
	for i in range(names.length):
		if (strcmp(names[i], name) == 0): return 1
	return 0


void object_note_weak(char* name):
	object_records_init()
	if (object_name_in(object_weak_names, name) == 0): object_weak_names.push(strclone(name))


int object_name_is_weak(char* name):
	if (object_records_ready == 0): return 0
	return object_name_in(object_weak_names, name)


int object_weak_count():
	if (object_records_ready == 0): return 0
	return object_weak_names.length


# An '@alias("target")' declaration (symbol t, named name): the W symbol
# is defined at the target's address as soon as the target is defined
# (object_alias_defined, called by sym_define_global_at), so W code may
# use either name; the object gets a global symbol for it.
void sym_define_global_at(int current_symbol, int v);
char* sym_record_name(int t);
int sym_lookup(char* s);
int sym_value_at(int t);


void object_note_alias(int t, char* name, char* target, int is_function):
	object_records_init()
	object_alias_names.push(strclone(name))
	object_alias_targets.push(strclone(target))
	object_alias_symbols.push(t)
	object_alias_is_function.push(is_function)
	int target_symbol = sym_lookup(target)
	if ((target_symbol >= 0) && (table[target_symbol + 1] == 'D')):
		sym_define_global_at(t, sym_value_at(target_symbol))
		c_abi_alias_defined(t, target_symbol)
	else: object_alias_pending = object_alias_pending + 1


int object_symbol_is_alias(int t):
	if (object_records_ready == 0): return 0
	for i in range(object_alias_symbols.length):
		if (object_alias_symbols[i] == t): return 1
	return 0


void object_alias_defined(int t, int v):
	char* name = sym_record_name(t)
	for i in range(object_alias_targets.length):
		int alias = object_alias_symbols[i]
		if ((strcmp(object_alias_targets[i], name) == 0) && (table[alias + 1] != 'D')):
			object_alias_pending = object_alias_pending - 1
			sym_define_global_at(alias, v)
			c_abi_alias_defined(alias, t)


void object_aliases_check():
	if (object_records_ready == 0): return
	for i in range(object_alias_symbols.length):
		if (table[object_alias_symbols[i] + 1] != 'D'):
			error3(c"alias target '", object_alias_targets[i], c"' is never defined")


# --- Sections of the object --------------------------------------------

struct object_section:
	char* name
	int source      # 0: code buffer, 1: data buffer
	int type        # SHT_PROGBITS (1) or SHT_NOBITS (8)
	int flags
	int align
	int size
	object_buffer* bytes
	object_buffer* rela
	int index
	int name_offset
	int symbol


# A contiguous run of the code or data buffer and where it lands.
struct object_piece:
	int start
	int end
	int section
	int out
	int align


list[object_section*] object_sections
list[object_piece*] object_text_pieces
list[object_piece*] object_data_pieces

object_buffer* object_symtab
object_buffer* object_strtab
int object_symbol_count


int object_has_prefix(char* s, char* prefix):
	int n = strlen(prefix)
	for i in range(n):
		if (s[i] != prefix[i]): return 0
	return 1


int object_contains(char* s, char* part):
	int n = strlen(s)
	int m = strlen(part)
	for i in range(n - m + 1):
		int same = 1
		for j in range(m):
			if (s[i + j] != part[j]): same = 0
		if (same): return 1
	return 0


# The section named name, created on first use with gcc's flags for what
# it holds: code is AX; data is A in a .rodata-like section, otherwise
# WA, and NOBITS in a .bss-like one.
int object_section_for(char* name, int source):
	for i in range(object_sections.length):
		object_section* s = object_sections[i]
		if (strcmp(s.name, name) == 0):
			if (s.source != source): error3(c"section '", name, c"' holds both functions and data")
			return i
	object_section* s = cast(object_section*, malloc(sizeof(object_section)))
	s.name = name
	s.source = source
	s.type = 1
	s.flags = 6
	s.align = 16
	s.size = 0
	s.bytes = 0
	s.rela = object_buffer_new()
	s.index = 0
	s.name_offset = 0
	s.symbol = 0
	if (source == 1):
		s.align = 8
		s.flags = 3
		if (object_contains(name, c".rodata")): s.flags = 2
		if (object_has_prefix(name, c".bss") || object_has_prefix(name, c".tbss") || object_contains(name, c"..bss")): s.type = 8
	object_sections.push(s)
	return object_sections.length - 1


object_piece* object_piece_new(int start, int end, int section, int align):
	object_piece* p = cast(object_piece*, malloc(sizeof(object_piece)))
	p.start = start
	p.end = end
	p.section = section
	p.out = 0
	p.align = align
	return p


# Insert a placed range in start order (the ranges arrive nearly sorted).
void object_piece_insert(list[object_piece*] pieces, object_piece* p):
	pieces.push(p)
	int i = pieces.length - 1
	while ((i > 0) && (pieces[i - 1].start > p.start)):
		pieces[i] = pieces[i - 1]
		i = i - 1
	pieces[i] = p


# Fill the gaps between the placed ranges of [low, high) with pieces of
# the default section, then give every piece its offset in its section.
# A piece without an explicit alignment keeps its buffer offset modulo
# 16, so whatever alignment the code generator gave its contents holds.
list[object_piece*] object_pieces_complete(list[object_piece*] placed, int low, int high, int default_section):
	list[object_piece*] pieces = new list[object_piece*]
	int at = low
	for i in range(placed.length):
		object_piece* p = placed[i]
		if (p.start < at): error(c"internal error: --emit=obj placed ranges overlap")
		if (p.start > at): pieces.push(object_piece_new(at, p.start, default_section, 0))
		pieces.push(p)
		at = p.end
	if (at < high): pieces.push(object_piece_new(at, high, default_section, 0))
	for i in range(pieces.length):
		object_piece* p = pieces[i]
		object_section* s = object_sections[p.section]
		int out = s.size
		if (p.align > 0):
			out = (out + p.align - 1) & (-p.align)
			if (p.align > s.align): s.align = p.align
		else:
			if (s.align < 16): s.align = 16
			while ((out & 15) != (p.start & 15)): out = out + 1
		p.out = out
		s.size = out + p.end - p.start
	return pieces


# The piece holding buffer offset off (one past the last byte maps to
# the piece that ends there), or 0.
object_piece* object_piece_at(list[object_piece*] pieces, int off):
	int lo = 0
	int hi = pieces.length - 1
	if ((hi < 0) || (off < pieces[0].start)): return cast(object_piece*, 0)
	while (lo < hi):
		int mid = (lo + hi + 1) >> 1
		if (pieces[mid].start <= off): lo = mid
		else: hi = mid - 1
	object_piece* p = pieces[lo]
	if (off > p.end): return cast(object_piece*, 0)
	return p


object_piece* object_text_piece(int vaddr):
	object_piece* p = object_piece_at(object_text_pieces, vaddr - code_offset)
	if (cast(int, p) == 0): error(c"internal error: --emit=obj code address outside the object")
	return p


object_piece* object_data_piece(int vaddr):
	object_piece* p = object_piece_at(object_data_pieces, vaddr - data_offset)
	if (cast(int, p) == 0): error(c"internal error: --emit=obj data address outside the object")
	return p


int object_text_offset(int vaddr):
	object_piece* p = object_text_piece(vaddr)
	return p.out + vaddr - code_offset - p.start


int object_data_offset(int vaddr):
	object_piece* p = object_data_piece(vaddr)
	return p.out + vaddr - data_offset - p.start


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


# A symbol at a code or data vaddr: its section and offset come from the
# piece holding it.
int object_text_symbol(char* name, int binding, int vaddr):
	object_piece* p = object_text_piece(vaddr)
	object_section* s = object_sections[p.section]
	return object_symbol(name, binding, 2, s.index, p.out + vaddr - code_offset - p.start, 0)


int object_data_symbol(char* name, int binding, int vaddr, int size):
	object_piece* p = object_data_piece(vaddr)
	object_section* s = object_sections[p.section]
	return object_symbol(name, binding, 1, s.index, p.out + vaddr - data_offset - p.start, size)


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


# Index of the extern function slot at vaddr, or -1.
int object_import_index(int vaddr):
	for i in range(object_import_slots.length):
		if (object_import_slots[i] == vaddr): return i
	return -1


# Name already given to a global or undefined symbol: a local W symbol of
# the same name (an exported body, an extern shim) is left out.
list[char*] object_global_names


int object_name_is_global(char* name):
	return object_name_in(object_global_names, name)


# A fixed array global keeps the {data, length} header W code indexes
# through in front of its elements; in an object the header is a piece of
# its own in .data, and the global's symbol, section, alignment and .bss
# placement all belong to the elements, so C sees a plain array.
int object_array_header_size(int type):
	if (type_is_array(type_canonical(type))): return 2 * word_size
	return 0


# A symbol's size is the object's (C sees 'int32' as 4 bytes, a packed
# record as its exact size, an array as its elements), not the
# word-rounded storage reserved for it.
int object_symbol_size(int type):
	if (type_is_array(type_canonical(type))): return type_get_size(type) - 2 * word_size
	if ((type_get_pointer_level(type) == 0) && (type_get_size(type) > 0)): return type_get_size(type)
	# An empty record is 0 bytes to C (gcc's symbol size), though W
	# reserves it a word of its own (global_storage_size).
	int kind = type_get_kind(type_canonical(type))
	if ((type_get_pointer_level(type) == 0) && ((kind == 0) || (kind == type_kind_union))): return 0
	return word_size


# 1 for a data symbol of the table that owns storage in the object.
int object_table_data_symbol(int t, int value, int type):
	if (object_symbol_is_extern_pointer(t)): return 0
	return (load_int(table + t + 10) == 1) && object_in_data(value) && (value < data_offset + datapos) && (object_extern_data_at(value + object_array_header_size(type)) < 0) && (type_get_kind(type) != type_kind_enum)


# Weak symbols defined in text: their vaddrs and symbol indices, so
# references to them bind through the symbol (a strong definition
# elsewhere in the link wins).
list[int] object_weak_text_vaddrs
list[int] object_weak_text_symbols
# --c-abi weak functions: W entry vaddr -> symbol. A function value
# materializes the W entry and subtracts 5 (c_abi_function_value), so its
# address slot binds to the symbol plus 5; direct W calls take the same
# path (c_abi_calls_through_symbol).
list[int] object_weak_entry_vaddrs
list[int] object_weak_entry_symbols


# Local symbols for W functions and the non-root globals; with
# want_global, the root globals (and every weak definition) instead.
void object_table_symbols(int want_global):
	int t = 0
	while (t <= table_pos - 1):
		char* name = table + t
		t = t + strlen(table + t)
		int value = sym_value_at(t)
		int symtype = load_int(table + t + 10)
		int type = load_int(table + t + 6)
		if (table[t + 1] == 'D'):
			int weak = object_name_is_weak(name)
			if ((symtype == 2) && object_in_text(value) && (value < code_offset + codepos) && (object_name_is_global(name) == 0)):
				if (weak == want_global):
					int index = object_text_symbol(name, weak << 1, value)
					if (weak):
						object_weak_text_vaddrs.push(value)
						object_weak_text_symbols.push(index)
			else if (object_table_data_symbol(t, value, type)):
				int binding = object_file_is_root(sym_decl_file_index(t)) && (object_symbol_is_static(t) == 0)
				if (weak): binding = 2
				if ((binding != 0) == want_global):
					object_data_symbol(name, binding, value + object_array_header_size(type), object_symbol_size(type))
					if (binding != 0): object_global_names.push(name)
		t = next_token(t)


# Return the target vaddr of the address slot at pos, -1 for a slot a
# peephole has since rewritten (the same filter
# static_library_data_target applies).
int object_slot_target(int pos):
	if ((pos < 3) || (pos > codepos - 4)): return -1
	int lea = ((code[pos - 3] & 255) == 0x48) && ((code[pos - 2] & 255) == 0x8d) && ((code[pos - 1] & 255) == 5)
	int indirect_call = ((code[pos - 2] & 255) == 0xff) && ((code[pos - 1] & 255) == 0x15)
	if ((lea == 0) && (indirect_call == 0)): return -1
	int target = code_offset + pos + 4 + load_int(code + pos)
	if (object_in_data(target) || object_in_text(target)): return target
	error(c"internal error: --emit=obj address slot leaves the object")
	return -1


# Return the target vaddr of the `call rel32` (or `jmp rel32`) cell at
# pos, -1 for a cell a fold has since rewritten.
int object_rel32_target(int pos):
	if ((pos < elf_object_text_start + 1) || (pos > codepos - 4)): return -1
	int opcode = code[pos - 1] & 255
	if ((opcode != 0xe8) && (opcode != 0xe9)): return -1
	int target = code_offset + pos + 4 + load_int(code + pos)
	if ((target < object_text_vaddr()) || (target >= code_offset + codepos)): return -1
	return target


int object_weak_text_symbol(int vaddr):
	for i in range(object_weak_text_vaddrs.length):
		if (object_weak_text_vaddrs[i] == vaddr): return object_weak_text_symbols[i]
	return -1


# A PC-relative disp32 at code buffer offset pos reaching text vaddr
# target: unchanged inside one piece, rewritten when both pieces share
# a section, otherwise relocated against the target section (or against
# a weak definition's own symbol, R_X86_64_PLT32 for a call).
void object_text_reference(int pos, int target, int is_call):
	object_piece* site = object_text_piece(code_offset + pos)
	object_section* site_section = object_sections[site.section]
	int site_off = site.out + pos - site.start
	int weak = object_weak_text_symbol(target)
	if (weak >= 0):
		int rtype = 2
		if (is_call): rtype = 4
		object_rela(site_section.rela, site_off, weak, rtype, -4)
		save_int32(site_section.bytes.bytes + site_off, 0)
		return
	object_piece* dest = object_text_piece(target)
	if (dest == site): return
	int dest_off = dest.out + target - code_offset - dest.start
	if (dest.section == site.section):
		save_int32(site_section.bytes.bytes + site_off, dest_off - site_off - 4)
		return
	object_section* dest_section = object_sections[dest.section]
	object_rela(site_section.rela, site_off, dest_section.symbol, 2, dest_off - 4)
	save_int32(site_section.bytes.bytes + site_off, 0)


# A datapos + 1 byte map with 1 at the data pointer cell of every array
# header no text address slot or pointer cell reaches: an array only C
# (or a linker script) sees keeps no relocation from .data into its
# elements' section, which may be discarded (.modinfo, .discard.*).
char* object_unused_array_headers():
	char* skip = cast(char*, malloc(datapos + 1))
	for j in range(datapos + 1): skip[j] = 0
	char* reached = cast(char*, malloc(datapos + 1))
	for j in range(datapos + 1): reached[j] = 0
	for i in range(static_address_count):
		int pos = load_int32(static_address_slots + i * 4)
		if ((pos >= elf_object_text_start) && (pos <= codepos - 4)):
			int target = object_slot_target(pos)
			if ((target >= 0) && object_in_data(target)): reached[target - data_offset] = 1
	for r in range(rebase_count):
		int cell = load_i(rebase_table + r * 8, 8) - data_offset
		if ((cell >= 0) && (cell <= datapos - 8)):
			int value = load_i(data + cell, 8)
			if (object_in_data(value)): reached[value - data_offset] = 1
	int t = 0
	while (t <= table_pos - 1):
		t = t + strlen(table + t)
		int value = sym_value_at(t)
		int type = load_int(table + t + 6)
		int header = object_array_header_size(type)
		if ((table[t + 1] == 'D') && (header > 0) && object_table_data_symbol(t, value, type)):
			int used = 0
			for j in range(header):
				if (reached[value - data_offset + j]): used = 1
			if (used == 0): skip[value - data_offset] = 1
		t = next_token(t)
	free(reached)
	return skip


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


int object_data_all_zero(int start, int end):
	for i in range(start, end):
		if (data[i] != 0): return 0
	return 1


# Split the code and data buffers into sections: placed functions (and
# the export adapters of placed functions), placed globals, read-only
# literals, zero-initialized globals (.bss), and the rest in .text and
# .data.
void object_layout():
	object_sections = new list[object_section*]
	int text_section = object_section_for(c".text", 0)
	int data_section = object_section_for(c".data", 1)

	list[object_piece*] placed = new list[object_piece*]
	for i in range(object_text_place_start.length):
		if (object_text_place_end[i] > object_text_place_start[i]):
			char* name = object_text_place_section[i]
			if (name == 0): name = c".text"
			object_piece_insert(placed, object_piece_new(object_text_place_start[i], object_text_place_end[i], object_section_for(name, 0), object_text_place_align[i]))
	# An exported function's adapter follows its body into its section;
	# the adapters are contiguous, the last one ends at codepos.
	int placed_functions = placed.length
	for e in range(wasm_export_count):
		int body = sym_address(cast(char*, load_i(wasm_export_names + e * __word_size__, __word_size__))) - code_offset
		int adapter = load_i(elf_export_addresses + e * __word_size__, __word_size__) - code_offset
		int adapter_end = codepos
		if (e + 1 < wasm_export_count): adapter_end = load_i(elf_export_addresses + (e + 1) * __word_size__, __word_size__) - code_offset
		for i in range(placed_functions):
			object_piece* p = placed[i]
			if ((body >= p.start) && (body < p.end)):
				object_piece_insert(placed, object_piece_new(adapter, adapter_end, p.section, 0))
				break
	# --c-abi: each System V adapter follows its function's entry stub.
	if (c_abi_mode && (cast(int, c_abi_stub_syms) != 0)):
		for k in range(c_abi_stub_positions.length):
			int stub = c_abi_stub_positions[k]
			if (c_abi_adapter_ends[k] > c_abi_adapter_starts[k]):
				for i in range(placed_functions):
					object_piece* p = placed[i]
					if ((stub >= p.start) && (stub < p.end)):
						object_piece_insert(placed, object_piece_new(c_abi_adapter_starts[k], c_abi_adapter_ends[k], p.section, 0))
						break
	object_text_pieces = object_pieces_complete(placed, elf_object_text_start, codepos, text_section)

	placed = new list[object_piece*]
	for i in range(object_rodata_start.length):
		object_piece_insert(placed, object_piece_new(object_rodata_start[i], object_rodata_end[i], object_section_for(c".rodata", 1), 8))
	# Explicitly placed globals, then every other zero global into .bss.
	char* cells = cast(char*, malloc(datapos + 1))
	for j in range(datapos + 1): cells[j] = 0
	for r in range(rebase_count):
		int cell = load_i(rebase_table + r * 8, 8) - data_offset
		if ((cell >= 0) && (cell <= datapos)): cells[cell] = 1
	# Extern function slots and C function-pointer cells are relocated
	# too: a NOBITS section cannot carry them (ld -r drops the records).
	for i in range(object_import_slots.length):
		int slot = object_import_slots[i] - data_offset
		if ((slot >= 0) && (slot <= datapos)): cells[slot] = 1
	if (c_abi_mode):
		for i in range(c_abi_extern_cells.length):
			int cell = c_abi_extern_cells[i] - data_offset
			if ((cell >= 0) && (cell <= datapos)): cells[cell] = 1
	int t = 0
	while (t <= table_pos - 1):
		t = t + strlen(table + t)
		int value = sym_value_at(t)
		int type = load_int(table + t + 6)
		if ((table[t + 1] == 'D') && object_table_data_symbol(t, value, type)):
			int start = value - data_offset + object_array_header_size(type)
			int end = value - data_offset + global_storage_size(type)
			char* name = 0
			int align = 0
			for i in range(object_data_place_symbol.length):
				if (object_data_place_symbol[i] == t):
					if (object_data_place_section[i] != 0): name = object_data_place_section[i]
					if (object_data_place_align[i] > align): align = object_data_place_align[i]
			int fresh = 1
			for i in range(placed.length):
				if ((placed[i].start < end) && (placed[i].end > start)): fresh = 0
			if (fresh):
				int zero = object_data_all_zero(start, end)
				for j in range(start, end):
					if (cells[j]): zero = 0
				if (name == 0):
					name = c".data"
					if (zero): name = c".bss"
				int section = object_section_for(name, 1)
				if ((object_sections[section].type == 8) && (zero == 0)):
					error3(c"global in section '", name, c"' must be zero-initialized")
				# A moved global is word aligned, so the globals of one
				# section pack like C's (an initcall-style table).
				if ((section != data_section) || (align > 0)):
					if (align < 8): align = 8
					object_piece_insert(placed, object_piece_new(start, end, section, align))
		t = next_token(t)
	free(cells)
	object_data_pieces = object_pieces_complete(placed, 0, datapos, data_section)


void elf_object_write():
	# A retained W runtime owns a private heap, as in a static library:
	# mmap keeps it clear of the host program's brk-based malloc.
	int mmap_mode = sym_address(c"malloc_mmap_mode")
	if (mmap_mode): save_i(data + mmap_mode - data_offset, 1, word_size)
	object_records_init()
	object_aliases_check()
	object_layout()

	# Section indices: the content sections first, then the fixed ones,
	# then one .rela section per content section that needs it.
	int section_index = 1
	for i in range(object_sections.length):
		object_sections[i].index = section_index
		section_index = section_index + 1
	int stack_index = section_index
	int symtab_index = stack_index + 1
	int strtab_index = stack_index + 2

	object_symtab = object_buffer_new()
	object_strtab = object_buffer_new()
	object_global_names = new list[char*]
	object_weak_text_vaddrs = new list[int]
	object_weak_text_symbols = new list[int]
	object_weak_entry_vaddrs = new list[int]
	object_weak_entry_symbols = new list[int]
	object_symbol_count = 0
	object_u8(object_strtab, 0)
	object_symbol(0, 0, 0, 0, 0, 0)
	for i in range(object_sections.length):
		object_sections[i].symbol = object_symbol(0, 0, 3, object_sections[i].index, 0, 0)

	# Global and undefined names first, so their local twins are skipped.
	for e in range(wasm_export_count):
		object_global_names.push(cast(char*, load_i(wasm_export_names + e * __word_size__, __word_size__)))
	for i in range(object_import_names.length): object_global_names.push(object_import_names[i])
	for i in range(dyn_import_count):
		if (dyn_import_get_symtype(i) == 1): object_global_names.push(dyn_import_name(i))
	for i in range(object_alias_names.length):
		if (object_alias_is_function[i]): object_global_names.push(object_alias_names[i])
	if (c_abi_mode):
		for i in range(c_abi_global_names.length): object_global_names.push(c_abi_global_names[i])
	object_table_symbols(0)
	int first_global = object_symbol_count
	for e in range(wasm_export_count):
		char* name = cast(char*, load_i(wasm_export_names + e * __word_size__, __word_size__))
		int adapter = load_i(elf_export_addresses + e * __word_size__, __word_size__)
		int binding = 1
		if (object_name_is_weak(name)): binding = 2
		object_text_symbol(name, binding, adapter)
	# --c-abi: global functions at their System V entry stubs (c_abi.w),
	# the same address W's function-pointer values hold; a weak one binds
	# those values through its symbol
	if (c_abi_mode):
		for i in range(c_abi_global_syms.length):
			int c_entry = c_abi_entry_of(c_abi_global_syms[i])
			int c_binding = 1
			if (object_name_is_weak(c_abi_global_names[i])): c_binding = 2
			int c_index = object_text_symbol(c_abi_global_names[i], c_binding, c_entry)
			if (c_binding == 2):
				object_weak_text_vaddrs.push(c_entry)
				object_weak_text_symbols.push(c_index)
				object_weak_entry_vaddrs.push(c_entry + 5)
				object_weak_entry_symbols.push(c_index)
	# A function alias names the target's global entry: its System V
	# entry under --c-abi, its adapter when the target is exported, else
	# its W entry.
	for i in range(object_alias_names.length):
		if (object_alias_is_function[i]):
			int vaddr = sym_value_at(object_alias_symbols[i])
			for e in range(wasm_export_count):
				if (strcmp(cast(char*, load_i(wasm_export_names + e * __word_size__, __word_size__)), object_alias_targets[i]) == 0):
					vaddr = load_i(elf_export_addresses + e * __word_size__, __word_size__)
			if (c_abi_mode && c_abi_has_entry(object_alias_symbols[i])): vaddr = c_abi_entry_of(object_alias_symbols[i])
			int binding = 1
			if (object_name_is_weak(object_alias_names[i])): binding = 2
			object_text_symbol(object_alias_names[i], binding, vaddr)
	object_table_symbols(1)
	int first_import = object_symbol_count
	for i in range(object_import_names.length):
		int binding = 1
		if (object_name_is_weak(object_import_names[i])): binding = 2
		object_symbol(object_import_names[i], binding, 0, 0, 0, 0)
	char* data_symbols = cast(char*, malloc(dyn_import_count * 4 + 4))
	for i in range(dyn_import_count):
		if (dyn_import_get_symtype(i) == 1):
			int binding = 1
			if (object_name_is_weak(dyn_import_name(i))): binding = 2
			save_int32(data_symbols + i * 4, object_symbol(dyn_import_name(i), binding, 0, 0, 0, 0))

	# Section contents: code pieces, then data pieces with every pointer
	# cell cleared (its relocation supplies the value).
	char* data_copy = cast(char*, malloc(datapos + 1))
	for j in range(datapos): data_copy[j] = data[j]
	for r in range(rebase_count):
		int cell = load_i(rebase_table + r * 8, 8) - data_offset
		if ((cell >= 0) && (cell <= datapos - 8)): save_i(data_copy + cell, 0, 8)
	for i in range(object_sections.length):
		object_section* s = object_sections[i]
		s.bytes = object_buffer_new()
		if (s.type == 1):
			object_buffer_reserve(s.bytes, s.size)
			for j in range(s.size): s.bytes.bytes[j] = 0
			s.bytes.length = s.size
	for i in range(object_text_pieces.length):
		object_piece* p = object_text_pieces[i]
		object_section* s = object_sections[p.section]
		for j in range(p.end - p.start): s.bytes.bytes[p.out + j] = code[p.start + j]
	for i in range(object_data_pieces.length):
		object_piece* p = object_data_pieces[i]
		object_section* s = object_sections[p.section]
		if (s.type == 1):
			for j in range(p.end - p.start): s.bytes.bytes[p.out + j] = data_copy[p.start + j]
	free(data_copy)

	# Text relocations: address slots (to data, extern data or code) and
	# call cells. Slots are noted on every write (backpatch chains
	# rewrite them), so each is taken once.
	char* seen = cast(char*, malloc(codepos + 1))
	for p in range(codepos + 1): seen[p] = 0
	# Extern function slots some code still loads (a function value, a
	# variadic call) keep their relocation; the rest are never read.
	char* import_used = cast(char*, malloc(object_import_slots.length + 1))
	for j in range(object_import_slots.length): import_used[j] = (c_abi_mode == 0)
	for i in range(static_address_count):
		int pos = load_int32(static_address_slots + i * 4)
		int target = -1
		if ((pos >= elf_object_text_start) && (pos <= codepos - 4)):
			if (seen[pos] == 0): target = object_slot_target(pos)
			seen[pos] = 1
		if (target >= 0):
			int weak_entry = -1
			for w in range(object_weak_entry_vaddrs.length):
				if (object_weak_entry_vaddrs[w] == target): weak_entry = object_weak_entry_symbols[w]
			if (weak_entry >= 0):
				object_piece* entry_site = object_text_piece(code_offset + pos)
				object_section* entry_section = object_sections[entry_site.section]
				int entry_offset = entry_site.out + pos - entry_site.start
				object_rela(entry_section.rela, entry_offset, weak_entry, 2, 1)
				save_int32(entry_section.bytes.bytes + entry_offset, 0)
			else if (object_in_text(target)): object_text_reference(pos, target, 0)
			else:
				object_piece* site = object_text_piece(code_offset + pos)
				object_section* site_section = object_sections[site.section]
				int offset = site.out + pos - site.start
				int extern_data = object_extern_data_at(target)
				int import_index = object_import_index(target)
				# R_X86_64_PC32 (2): S + A - P, P being the disp32 itself.
				# A weak reference may stay undefined, which a PIE cannot
				# reach PC-relatively: its lea loads the address from the
				# GOT instead (R_X86_64_REX_GOTPCRELX, 42), like gcc's.
				int weak_lea = 0
				if (extern_data >= 0):
					weak_lea = object_name_is_weak(dyn_import_name(extern_data)) && ((code[pos - 2] & 255) == 0x8d) && (target == dyn_import_got_vaddr(extern_data))
				# --c-abi: an FFI shim's 'call [rip+slot]' becomes a
				# direct 'addr32 call rel32' to the C symbol
				# (R_X86_64_PLT32), as ld relaxes GOTPCRELX calls, so
				# no data word links code to its callee.
				if ((import_index >= 0) && c_abi_mode && ((code[pos - 2] & 255) == 0xff) && ((code[pos - 1] & 255) == 0x15)):
					site_section.bytes.bytes[offset - 2] = 0x67
					site_section.bytes.bytes[offset - 1] = 0xe8
					object_rela(site_section.rela, offset, first_import + import_index, 4, -4)
				else if (weak_lea):
					site_section.bytes.bytes[offset - 2] = 0x8b
					object_rela(site_section.rela, offset, load_int32(data_symbols + extern_data * 4), 42, -4)
				else if (extern_data >= 0):
					object_rela(site_section.rela, offset, load_int32(data_symbols + extern_data * 4), 2, target - dyn_import_got_vaddr(extern_data) - 4)
				else:
					if (import_index >= 0): import_used[import_index] = 1
					object_piece* dest = object_data_piece(target)
					object_section* dest_section = object_sections[dest.section]
					object_rela(site_section.rela, offset, dest_section.symbol, 2, dest.out + target - data_offset - dest.start - 4)
				save_int32(site_section.bytes.bytes + offset, 0)
	for i in range(object_rel32_sites.length):
		int pos = object_rel32_sites[i]
		if ((pos >= 0) && (pos <= codepos - 4)):
			if (seen[pos] == 0):
				seen[pos] = 1
				int target = object_rel32_target(pos)
				if (target >= 0): object_text_reference(pos, target, 1)
	free(seen)

	# Data relocations: absolute pointer cells, then the extern function
	# slots. The header cell of an array nothing in the object reaches
	# stays unrelocated.
	char* cell_seen = object_unused_array_headers()
	for r in range(rebase_count):
		int cell = load_i(rebase_table + r * 8, 8) - data_offset
		if ((cell < 0) || (cell > datapos - 8)): error(c"internal error: --emit=obj pointer cell is outside data")
		if (cell_seen[cell] == 0):
			cell_seen[cell] = 1
			int value = load_i(data + cell, 8)
			object_piece* site = object_data_piece(data_offset + cell)
			object_section* site_section = object_sections[site.section]
			int offset = site.out + cell - site.start
			# The global the cell names, when an initializer said so:
			# what the cell binds to, whatever the offset.
			int base = object_address_base_at(data_offset + cell)
			if (base == 0): base = value
			int extern_cell = object_extern_data_at(base)
			# R_X86_64_64 (1): S + A, the cell's linked value. A null
			# cell stays null.
			if (value != 0):
				if (site_section.type != 1): error(c"internal error: --emit=obj pointer cell in a NOBITS section")
				if (extern_cell >= 0):
					object_rela(site_section.rela, offset, load_int32(data_symbols + extern_cell * 4), 1, value - dyn_import_got_vaddr(extern_cell))
				else if (object_in_data(base)):
					object_piece* dest = object_data_piece(base)
					object_rela(site_section.rela, offset, object_sections[dest.section].symbol, 1, dest.out + value - data_offset - dest.start)
				else if (object_in_text(value)):
					int weak = object_weak_text_symbol(value)
					if (weak >= 0): object_rela(site_section.rela, offset, weak, 1, 0)
					else:
						object_piece* dest = object_text_piece(value)
						object_rela(site_section.rela, offset, object_sections[dest.section].symbol, 1, dest.out + value - code_offset - dest.start)
				else: error(c"internal error: --emit=obj pointer cell leaves the object")
	free(cell_seen)
	for i in range(object_import_slots.length):
		if (import_used[i] == 0): continue
		object_piece* site = object_data_piece(object_import_slots[i])
		object_rela(object_sections[site.section].rela, site.out + object_import_slots[i] - data_offset - site.start, first_import + i, 1, 0)
	# --c-abi static cells holding an extern C function's address
	if (c_abi_mode):
		for i in range(c_abi_extern_cells.length):
			for j in range(object_import_slots.length):
				if (object_import_slots[j] == c_abi_extern_slots[i]):
					object_piece* cell_site = object_data_piece(c_abi_extern_cells[i])
					object_rela(object_sections[cell_site.section].rela, cell_site.out + c_abi_extern_cells[i] - data_offset - cell_site.start, first_import + j, 1, 0)
	free(data_symbols)
	free(import_used)

	object_buffer* names = object_buffer_new()
	object_u8(names, 0)
	int rela_count = 0
	for i in range(object_sections.length):
		object_section* s = object_sections[i]
		s.name_offset = object_string(names, s.name)
		if (s.rela.length > 0): rela_count = rela_count + 1
		if ((s.rela.length > 0) && (s.type != 1)): error(c"internal error: --emit=obj relocation in a NOBITS section")
	int name_stack = object_string(names, c".note.GNU-stack")
	int name_symtab = object_string(names, c".symtab")
	int name_strtab = object_string(names, c".strtab")
	int* rela_names = cast(int*, malloc((object_sections.length + 1) * 8))
	for i in range(object_sections.length):
		object_section* s = object_sections[i]
		if (s.rela.length > 0): rela_names[i] = object_string(names, strjoin(c".rela", s.name))
	int name_shstrtab = object_string(names, c".shstrtab")
	int section_count = strtab_index + rela_count + 2

	# File layout: header, the content sections, .symtab, .strtab, the
	# .rela sections, .shstrtab, section headers.
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
	object_u16(out, section_count)
	object_u16(out, section_count - 1)
	int* offsets = cast(int*, malloc((object_sections.length + 1) * 8))
	for i in range(object_sections.length):
		object_section* s = object_sections[i]
		object_align(out, 16)
		offsets[i] = out.length
		if (s.type == 1): object_put(out, s.bytes.bytes, s.size)
	object_align(out, 8)
	int symtab_off = out.length
	object_put(out, object_symtab.bytes, object_symtab.length)
	int strtab_off = out.length
	object_put(out, object_strtab.bytes, object_strtab.length)
	object_align(out, 8)
	int* rela_offsets = cast(int*, malloc((object_sections.length + 1) * 8))
	for i in range(object_sections.length):
		object_section* s = object_sections[i]
		rela_offsets[i] = out.length
		object_put(out, s.rela.bytes, s.rela.length)
	int names_off = out.length
	object_put(out, names.bytes, names.length)
	object_align(out, 8)
	save_int32(out.bytes + shoff_at, out.length)

	object_section_header(out, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	for i in range(object_sections.length):
		object_section* s = object_sections[i]
		object_section_header(out, s.name_offset, s.type, s.flags, offsets[i], s.size, 0, 0, s.align, 0)
	object_section_header(out, name_stack, 1, 0, offsets[0], 0, 0, 0, 1, 0)
	object_section_header(out, name_symtab, 2, 0, symtab_off, object_symtab.length, strtab_index, first_global, 8, 24)
	object_section_header(out, name_strtab, 3, 0, strtab_off, object_strtab.length, 0, 0, 1, 0)
	for i in range(object_sections.length):
		object_section* s = object_sections[i]
		if (s.rela.length > 0):
			object_section_header(out, rela_names[i], 4, 64, rela_offsets[i], s.rela.length, symtab_index, i + 1, 8, 24)
	object_section_header(out, name_shstrtab, 3, 0, names_off, names.length, 0, 0, 1, 0)

	if (write(output_fd, out.bytes, out.length) != out.length): error(c"could not write object file")
