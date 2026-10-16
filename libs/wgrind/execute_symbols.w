# Bounded ELF64 allocator symbol discovery for the native executor.
# Section metadata is read defensively: disassembler helpers deliberately
# accept fewer address bits and are not suitable for untrusted ELF input.
import lib.file
import libs.wgrind.shadow


struct wg_allocator_symbol:
	int address
	int size
	int kind # malloc1, free2, realloc3, calloc4; SysV argument registers


struct wg_symbols:
	wg_context* context
	list[wg_allocator_symbol] allocators
	int w_abi
	int limit


char* wg_symbol_read_file(char* path, int* length):
	*length = 0
	int fd = open(path, 0, 0)
	if (fd < 0): return 0
	int size = file_size(fd)
	if ((size < 0) || (size > 67108864)):
		close(fd)
		return 0
	char* data = cast(char*, malloc(size + 1))
	if (data == 0):
		close(fd)
		return 0
	int at = 0
	while (at < size):
		int n = read(fd, data + at, size - at)
		if (n == -4): continue
		if (n <= 0):
			free(data)
			close(fd)
			return 0
		at = at + n
	close(fd)
	data[size] = 0
	*length = size
	return data


int wg_elf_range(int length, int offset, int count):
	return (offset >= 0) && (count >= 0) && (offset <= length) && (count <= length - offset)


int wg_elf_u16(char* data, int offset):
	return (data[offset] & 255) | ((data[offset + 1] & 255) << 8)


int wg_elf_u32(char* data, int offset):
	return wg_elf_u16(data, offset) | (wg_elf_u16(data, offset + 2) << 16)


int wg_elf_u64(char* data, int offset):
	return (wg_elf_u32(data, offset) & wg_mask(4)) | (wg_elf_u32(data, offset + 4) << 32)


int wg_elf64(char* data, int length):
	if (__word_size__ != 8): return 0
	if (length < 64): return 0
	if ((data[0] != 127) || (data[1] != 'E') || (data[2] != 'L') || (data[3] != 'F')): return 0
	if ((data[4] != 2) || (data[5] != 1) || (data[6] != 1) || (wg_elf_u16(data, 18) != 62)): return 0
	int kind = wg_elf_u16(data, 16)
	return (kind == 2) || (kind == 3)


void wg_symbols_init(wg_symbols* s, wg_context* context, int limit):
	s.context = context
	s.allocators = new list[wg_allocator_symbol]
	s.w_abi = 0
	s.limit = limit


void wg_symbols_destroy(wg_symbols* s):
	s.allocators.free()


int wg_symbol_kind(char* name):
	if ((strcmp(name, c"malloc") == 0) || (strcmp(name, c"__libc_malloc") == 0)): return 1
	if ((strcmp(name, c"free") == 0) || (strcmp(name, c"__libc_free") == 0)): return 2
	if ((strcmp(name, c"realloc") == 0) || (strcmp(name, c"__libc_realloc") == 0)): return 3
	if ((strcmp(name, c"calloc") == 0) || (strcmp(name, c"__libc_calloc") == 0)): return 4
	return 0


int wg_symbols_append(wg_symbols* s, int address, int size, int kind):
	for i in range(s.allocators.length):
		wg_allocator_symbol entry = s.allocators[i]
		if (entry.address == address):
			if (entry.kind != kind): return wg_error(s.context, WG_INCOMPLETE, address, 0, 0, 0)
			if (entry.size != size): return wg_error(s.context, WG_INCOMPLETE, address, size, 0, 0)
			return 1
	if (s.allocators.length >= s.limit): return wg_error(s.context, WG_INCOMPLETE, address, 0, 0, 0)
	wg_allocator_symbol entry
	entry.address = address
	entry.size = size
	entry.kind = kind
	s.allocators.push(entry)
	return 1


# bias is zero for ET_EXEC and the loader's load bias for ET_DYN.
# W has a different allocator ABI, including internal optimized entries.
# Discover its metadata but never mistake W allocator symbols for C ABI.
int wg_symbols_image(wg_symbols* s, char* data, int length, int bias):
	if (s.context.error): return 0
	if (wg_elf64(data, length) == 0): return wg_error(s.context, WG_INCOMPLETE, 0, length, 0, 0)
	int section_offset = wg_elf_u64(data, 40)
	int section_size = wg_elf_u16(data, 58)
	int section_count = wg_elf_u16(data, 60)
	if ((section_offset == 0) && (section_count == 0)): return 1
	if ((section_size != 64) || (section_count == 0) || (wg_elf_range(length, section_offset, section_count * 64) == 0)):
		return wg_error(s.context, WG_INCOMPLETE, 0, length, 0, 0)
	int is_w = 0
	# First pass identifies the ABI before adding any allocator entries.
	for pass_index in range(2):
		for section in range(section_count):
			int header = section_offset + section * 64
			int type = wg_elf_u32(data, header + 4)
			if ((type != 2) && (type != 11)): continue
			int offset = wg_elf_u64(data, header + 24)
			int size = wg_elf_u64(data, header + 32)
			int link = wg_elf_u32(data, header + 40)
			if ((wg_elf_u64(data, header + 56) != 24) || (size % 24 != 0) || (wg_elf_range(length, offset, size) == 0) || (link < 0) || (link >= section_count)):
				return wg_error(s.context, WG_INCOMPLETE, 0, length, 0, 0)
			int strings_header = section_offset + link * 64
			int strings = wg_elf_u64(data, strings_header + 24)
			int strings_size = wg_elf_u64(data, strings_header + 32)
			if ((wg_elf_u32(data, strings_header + 4) != 3) || (wg_elf_range(length, strings, strings_size) == 0)):
				return wg_error(s.context, WG_INCOMPLETE, 0, length, 0, 0)
			for index in range(size / 24):
				int symbol = offset + index * 24
				if ((data[symbol + 4] & 15) != 2): continue
				if (wg_elf_u16(data, symbol + 6) == 0): continue
				int name_offset = wg_elf_u32(data, symbol)
				if ((name_offset < 0) || (name_offset >= strings_size)): return wg_error(s.context, WG_INCOMPLETE, 0, length, 0, 0)
				int end = name_offset
				while ((end < strings_size) && data[strings + end]): end = end + 1
				if (end == strings_size): return wg_error(s.context, WG_INCOMPLETE, 0, length, 0, 0)
				char* name = data + strings + name_offset
				if (pass_index == 0):
					if (strcmp(name, c"malloc_backend") == 0): is_w = 1
				else if (is_w == 0):
					int kind = wg_symbol_kind(name)
					if (kind):
						int value = wg_elf_u64(data, symbol + 8)
						if (wg_elf_u16(data, 16) == 3):
							if (wg_less(value + bias, value)): return wg_error(s.context, WG_INCOMPLETE, value, 0, 0, 0)
							value = value + bias
						int extent = wg_elf_u64(data, symbol + 16)
						if (wg_range(value, extent) == 0): return wg_error(s.context, WG_INCOMPLETE, value, extent, 0, 0)
						if (wg_symbols_append(s, value, extent, kind) == 0): return 0
	if (is_w): s.w_abi = 1
	return 1


int wg_symbols_load(wg_symbols* s, char* path, int bias):
	int length = 0
	char* data = wg_symbol_read_file(path, &length)
	if (data == 0): return wg_error(s.context, WG_INCOMPLETE, 0, 0, 0, 0)
	int result = wg_symbols_image(s, data, length, bias)
	free(data)
	return result


int wg_symbols_at(wg_symbols* s, int address):
	for i in range(s.allocators.length):
		wg_allocator_symbol entry = s.allocators[i]
		if (entry.address == address): return entry.kind
	return 0


# A symbol with no extent cannot establish a trusted allocator boundary.
# Callers must reject control flow leaving the selected function, including
# callbacks into user code, rather than extending trust to all descendants.
int wg_symbols_allocator_contains(wg_symbols* s, int entry, int pc):
	for i in range(s.allocators.length):
		wg_allocator_symbol symbol = s.allocators[i]
		if (symbol.address == entry):
			return (symbol.size > 0) && (wg_less(pc, entry) == 0) && wg_less(pc - entry, symbol.size)
	return 0
