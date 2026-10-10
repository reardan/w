# W-native x64 compiled libraries. Loading copies code/data, applies their
# relocation records, and makes only the exported ABI adapters visible.
import code_generator.code_emitter
import code_generator.dynamic_registry
import lib.lib
import structures.string

void static_note_address(int pos);
void target_option_error(char* message);

list[char*] static_link_names
list[int] static_link_addresses
list[char*] static_link_paths


void static_link_init():
	static_link_names = new list[char*]
	static_link_addresses = new list[int]
	static_link_paths = new list[char*]


int static_link_address(char* name):
	if (static_link_names == 0): return 0
	for i in range(static_link_names.length):
		if (strcmp(static_link_names[i], name) == 0): return static_link_addresses[i]
	return 0


# Static exports use an ordinary data slot with a pointer relocation;
# unresolved extern functions retain the normal loader-owned GOT path.
int static_link_import_slot(char* name):
	int address = static_link_address(name)
	if (address == 0):
		int got = dyn_emit_import_slot()
		dyn_add_import(name, got)
		return got
	while ((datapos % 8) != 0): emit_data_zeros(1)
	int slot = data_offset + datapos
	emit_data_word(address)
	rebase_note(slot)
	return slot


void static_link_bad(char* path):
	target_option_error(strjoin(c"invalid static library: ", path))


# All lengths are bounded before arithmetic/copying. This format uses
# 32-bit little-endian offsets even when read by the 64-bit compiler.
int static_link_word(char* bytes, int size, int* cursor, char* path):
	if ((*cursor < 0) || (*cursor > size - 4)): static_link_bad(path)
	int value = load_int32(bytes + *cursor)
	*cursor = *cursor + 4
	if (value < 0): static_link_bad(path)
	return value


# Return 0 for a shared-library path/soname; .wa files must be readable
# and have the exact versioned magic. A custom-named W artifact is also
# recognized by magic, so library out= does not constrain its extension.
int static_link_load(char* path):
	if (path in static_link_paths): return 1
	int fd = open(path, 0, 0)
	if (fd < 0):
		if (ends_with(path, c".wa")): target_option_error(strjoin(c"cannot open static library: ", path))
		return 0
	char[8] magic
	int n = read(fd, magic, 8)
	int matches = n == 8
	char* expected = c"WLIB64\x00\x01"
	if (matches):
		for i in range(8):
			if (magic[i] != expected[i]): matches = 0
	if (matches == 0):
		close(fd)
		if (ends_with(path, c".wa")): static_link_bad(path)
		return 0
	if ((word_size != 8) || (target_isa != 0) || (target_os != 0) || x64_syscall_abi):
		target_option_error(c"static libraries require the x64 Linux syscall target")
	int size = file_size(fd)
	if ((size < 36) || (size > 67108864)): static_link_bad(path)
	char* bytes = cast(char*, malloc(size))
	int have = 0
	while (have < size):
		int count = read(fd, bytes + have, size - have)
		if (count <= 0): static_link_bad(path)
		have = have + count
	close(fd)
	int cursor = 8
	int text_size = static_link_word(bytes, size, &cursor, path)
	int data_size_in = static_link_word(bytes, size, &cursor, path)
	int nfixups = static_link_word(bytes, size, &cursor, path)
	int nrebase = static_link_word(bytes, size, &cursor, path)
	int nexports = static_link_word(bytes, size, &cursor, path)
	# Original link addresses are informational; all records are offsets.
	static_link_word(bytes, size, &cursor, path)
	static_link_word(bytes, size, &cursor, path)
	if ((text_size > size - cursor) || (text_size < 4)): static_link_bad(path)
	if (data_size_in > size - cursor - text_size): static_link_bad(path)
	while ((codepos % 16) != 0): emit_int8(0)
	while ((datapos % 16) != 0): emit_data_zeros(1)
	if (text_size >= data_offset - code_offset - codepos):
		target_option_error(c"static library text exceeds the image layout limit")
	int text_start = codepos
	int data_start = datapos
	emit(text_size, bytes + cursor)
	cursor = cursor + text_size
	emit_data_zeros(data_size_in)
	for j in range(data_size_in): data[data_start + j] = bytes[cursor + j]
	cursor = cursor + data_size_in
	if (nfixups > (size - cursor) / 8): static_link_bad(path)
	for i in range(nfixups):
		int pos = static_link_word(bytes, size, &cursor, path)
		int target = static_link_word(bytes, size, &cursor, path)
		if ((pos > text_size - 4) || (target > data_size_in)): static_link_bad(path)
		int site = text_start + pos
		save_int32(code + site, data_offset + data_start + target - code_offset - site - 4)
		static_note_address(site)
	if (nrebase > (size - cursor) / 12): static_link_bad(path)
	for i in range(nrebase):
		int cell = static_link_word(bytes, size, &cursor, path)
		int segment = static_link_word(bytes, size, &cursor, path)
		int target = static_link_word(bytes, size, &cursor, path)
		if ((data_size_in < 8) || (cell > data_size_in - 8) || (segment > 1)): static_link_bad(path)
		int value = code_offset + text_start + target
		if (segment == 0):
			if (target > text_size): static_link_bad(path)
		else:
			if (target > data_size_in): static_link_bad(path)
			value = data_offset + data_start + target
		save_i(data + data_start + cell, value, 8)
		rebase_note(data_offset + data_start + cell)
	if (nexports > (size - cursor) / 8): static_link_bad(path)
	for i in range(nexports):
		int length = static_link_word(bytes, size, &cursor, path)
		if ((length == 0) || (length > size - cursor - 4)): static_link_bad(path)
		char* name = cast(char*, malloc(length + 1))
		for j in range(length): name[j] = bytes[cursor + j]
		name[length] = 0
		if (strlen(name) != length): static_link_bad(path)
		cursor = cursor + length
		int address = static_link_word(bytes, size, &cursor, path)
		if (address >= text_size): static_link_bad(path)
		if (static_link_address(name)): target_option_error(strjoin(c"duplicate static library export: ", name))
		static_link_names.push(name)
		static_link_addresses.push(code_offset + text_start + address)
	if (cursor != size): static_link_bad(path)
	static_link_paths.push(strclone(path))
	free(bytes)
	return 1
