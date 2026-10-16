# Optional source attribution for native diagnostics. This parser never
# changes checker success/error state: malformed or unsupported debug data
# simply leaves the original machine address in the diagnostic.
import libs.wgrind.execute_symbols
import libs.wgrind.report


struct wg_dwarf_reader:
	char* data
	int at
	int end
	int valid


int wg_dwarf_leb(wg_dwarf_reader* r, int signed):
	int value = 0
	for i in range(10):
		if (r.at >= r.end):
			r.valid = 0
			return 0
		int b = r.data[r.at] & 255
		r.at = r.at + 1
		if (i == 9):
			int payload = b & 127
			if ((signed && (payload != 0) && (payload != 127)) || ((signed == 0) && (payload > 1))):
				r.valid = 0
				return 0
		value = value | ((b & 127) << (i * 7))
		if ((b & 128) == 0):
			if (signed && (b & 64) && (i < 9)): value = value | (-1 << ((i + 1) * 7))
			return value
	r.valid = 0
	return 0


int wg_dwarf_string(wg_dwarf_reader* r):
	int start = r.at
	while ((r.at < r.end) && r.data[r.at]): r.at = r.at + 1
	if (r.at == r.end):
		r.valid = 0
		return 0
	r.at = r.at + 1
	return start


int wg_dwarf_file(char* data, int start, int program, int number, char* out, int capacity):
	if ((number < 1) || (number > 65535) || (capacity < 1)): return 0
	wg_dwarf_reader r
	r.data = data
	r.at = start
	r.end = program
	r.valid = 1
	while ((r.at < r.end) && data[r.at]):
		wg_dwarf_string(&r)
		if (r.valid == 0): return 0
	if (r.at >= r.end): return 0
	r.at = r.at + 1
	for file in range(1, number + 1):
		if ((r.at >= r.end) || (data[r.at] == 0)): return 0
		int name = wg_dwarf_string(&r)
		int length = r.at - name - 1
		int directory = wg_dwarf_leb(&r, 0)
		wg_dwarf_leb(&r, 0)
		wg_dwarf_leb(&r, 0)
		if (r.valid == 0): return 0
		if (file == number):
			# W emits complete paths with directory index zero. Do not
			# misleadingly drop a non-W compilation directory.
			if ((directory != 0) && (data[name] != '/')): return 0
			if ((length < 1) || (length >= capacity)): return 0
			for i in range(length): out[i] = data[name + i]
			out[length] = 0
			return 1
	return 0


int wg_source_marker(char* data, int length, int pc, int* file, int* line):
	int headers = wg_elf_u64(data, 32)
	int count = wg_elf_u16(data, 56)
	if ((wg_elf_u16(data, 54) != 56) || (wg_elf_range(length, headers, count * 56) == 0)): return 0
	for i in range(count):
		int header = headers + i * 56
		if (wg_elf_u32(data, header) != 1): continue
		int address = wg_elf_u64(data, header + 16)
		int size = wg_elf_u64(data, header + 32)
		if ((pc < address) || (size < 24) || (pc - address > size - 24)): continue
		int offset = wg_elf_u64(data, header + 8)
		if (wg_elf_range(length, offset, size) == 0): return 0
		int at = offset + pc - address
		if ((data[at] != 15) || (data[at + 1] != 11) || (wg_elf_u32(data, at + 2) != 0x44524757) || (data[at + 6] != 1) || (data[at + 7] != 5)): return 0
		*file = wg_elf_u64(data, at + 8) + 1
		*line = wg_elf_u64(data, at + 16)
		return (*file > 0) && (*line > 0)
	return 0


int wg_dwarf_line(char* data, int start, int length, int pc, int marker_file, int marker_line, char* out, int capacity, int* found):
	if ((length < 16) || (wg_elf_u16(data, start + 4) != 2)): return 0
	int unit = wg_elf_u32(data, start)
	if ((unit < 12) || (unit > length - 4)): return 0
	int end = start + 4 + unit
	int header = wg_elf_u32(data, start + 6)
	if ((header < 5) || (header > end - start - 10)): return 0
	int program = start + 10 + header
	int minimum = data[start + 10] & 255
	int base = data[start + 12] & 255
	if (base >= 128): base = base - 256
	int range = data[start + 13] & 255
	int opbase = data[start + 14] & 255
	int files = start + 15 + opbase - 1
	if ((range == 0) || (minimum == 0) || (opbase < 1) || (files >= program)): return 0
	if (marker_file):
		*found = marker_line
		return wg_dwarf_file(data, files, program, marker_file, out, capacity)
	wg_dwarf_reader r
	r.data = data
	r.at = program
	r.end = end
	r.valid = 1
	int address = 0
	int file = 1
	int line = 1
	int previous = -1
	int previous_file = 0
	int previous_line = 0
	while ((r.at < r.end) && r.valid):
		int op = data[r.at] & 255
		r.at = r.at + 1
		int row = 0
		int reset = 0
		if (op == 0):
			int size = wg_dwarf_leb(&r, 0)
			if ((r.valid == 0) || (size < 1) || (size > r.end - r.at)): return 0
			int sub = data[r.at] & 255
			if (sub == 1):
				row = 1
				reset = 1
			elif (sub == 2):
				if ((size != 5) && (size != 9)): return 0
				address = wg_elf_u32(data, r.at + 1)
				if (size == 9): address = wg_elf_u64(data, r.at + 1)
			r.at = r.at + size
		elif (op < opbase):
			if (op == 1): row = 1
			elif (op == 2):
				int advance = wg_dwarf_leb(&r, 0)
				if ((advance < 0) || (advance > (0x7fffffff / minimum))): return 0
				address = address + advance * minimum
			elif (op == 3): line = line + wg_dwarf_leb(&r, 1)
			elif (op == 4): file = wg_dwarf_leb(&r, 0)
			elif (op == 8): address = address + (255 - opbase) / range * minimum
			elif (op == 9):
				if (r.end - r.at < 2): return 0
				address = address + wg_elf_u16(data, r.at)
				r.at = r.at + 2
			else:
				int operands = data[start + 14 + op] & 255
				for i in range(operands): wg_dwarf_leb(&r, 0)
		else:
			int adjusted = op - opbase
			address = address + adjusted / range * minimum
			line = line + base + adjusted % range
			row = 1
		if (r.valid == 0): return 0
		if (row):
			if ((previous >= 0) && (previous <= pc) && (pc < address) && (previous_line > 0)):
				*found = previous_line
				return wg_dwarf_file(data, files, program, previous_file, out, capacity)
			previous = address
			previous_file = file
			previous_line = line
			if (reset):
				previous = -1
				address = 0
				file = 1
				line = 1
	return 0


int wg_source_image(char* data, int length, int pc, char* out, int capacity, int* line):
	*line = 0
	if (wg_elf64(data, length) == 0): return 0
	int headers = wg_elf_u64(data, 40)
	int count = wg_elf_u16(data, 60)
	int names_index = wg_elf_u16(data, 62)
	if ((wg_elf_u16(data, 58) != 64) || (names_index >= count) || (wg_elf_range(length, headers, count * 64) == 0)): return 0
	int names_header = headers + names_index * 64
	int names = wg_elf_u64(data, names_header + 24)
	int names_size = wg_elf_u64(data, names_header + 32)
	if (wg_elf_range(length, names, names_size) == 0): return 0
	for i in range(count):
		int header = headers + i * 64
		int name = wg_elf_u32(data, header)
		if ((name < 0) || (name > names_size - 12)): continue
		int same = 1
		char* expected = c".debug_line"
		for j in range(12):
			if (data[names + name + j] != expected[j]): same = 0
		if (same == 0): continue
		int offset = wg_elf_u64(data, header + 24)
		int size = wg_elf_u64(data, header + 32)
		if (wg_elf_range(length, offset, size) == 0): return 0
		int marker_file = 0
		int marker_line = 0
		wg_source_marker(data, length, pc, &marker_file, &marker_line)
		return wg_dwarf_line(data, offset, size, pc, marker_file, marker_line, out, capacity, line)
	return 0


int wg_source_json(char* dst, int at, char* value):
	char* digits = c"0123456789abcdef"
	dst[at] = '"'
	at = at + 1
	for i in range(strlen(value)):
		int ch = value[i] & 255
		if ((ch == '"') || (ch == '\\')):
			dst[at] = '\\'
			dst[at + 1] = ch
			at = at + 2
		elif (ch < 32):
			at = wg_text(dst, at, c"\\u00")
			dst[at] = digits[ch >> 4]
			dst[at + 1] = digits[ch & 15]
			at = at + 2
		else:
			dst[at] = ch
			at = at + 1
	dst[at] = '"'
	return at + 1


int wg_source_record(char* data, int length, int pc, int fallback, char* role, int fd):
	if (pc == 0): return 1
	char[1024] file
	int line = 0
	if (wg_source_image(data, length, pc, &file[0], 1024, &line) == 0):
		if ((fallback == 0) || (wg_source_image(data, length, fallback, &file[0], 1024, &line) == 0)): return 1
	char[8192] buffer
	char* dst = &buffer[0]
	int n = wg_text(dst, 0, c"{\"kind\":\"source-location\",\"role\":")
	n = wg_source_json(dst, n, role)
	n = wg_text(dst, n, c",\"address\":")
	n = wg_hex(dst, n, pc)
	n = wg_text(dst, n, c",\"file\":")
	n = wg_source_json(dst, n, &file[0])
	n = wg_text(dst, n, c",\"line\":")
	n = wg_decimal(dst, n, line)
	n = wg_text(dst, n, c"}\n")
	int at = 0
	while (at < n):
		int wrote = write(fd, dst + at, n - at)
		if (wrote == -4): continue
		if (wrote <= 0): return 0
		at = at + wrote
	return 1


int wg_source_report(char* path, wg_context* c, int fallback, int fd):
	int length = 0
	char* data = wg_symbol_read_file(path, &length)
	if (data == 0): return 1
	int okay = wg_source_record(data, length, c.error_site, fallback, c"access", fd)
	if (okay): okay = wg_source_record(data, length, c.error_origin, 0, c"origin", fd)
	if (okay): okay = wg_source_record(data, length, c.error_allocation, 0, c"allocation", fd)
	if (okay): okay = wg_source_record(data, length, c.error_free, 0, c"free", fd)
	free(data)
	return okay
