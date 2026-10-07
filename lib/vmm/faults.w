# Bounded ELF64 symbolization for guest faults. Metadata is read from the
# original image, never guest-mutated RAM. Supports W's DWARF2 line tables;
# absent, stripped or malformed metadata simply leaves the raw RIP report.
import lib.lib
import structures.string

struct vm_debug_cursor:
	char* data
	int at
	int end
	int bad


int vm_debug_byte(vm_debug_cursor* cursor):
	if (cursor.at >= cursor.end):
		cursor.bad = 1
		return 0
	int value = cast(int, cursor.data[cursor.at]) & 255
	cursor.at = cursor.at + 1
	return value


int vm_debug_leb(vm_debug_cursor* cursor, int signed_value):
	int value = 0
	int shift = 0
	int part = 0
	while (shift < 56 && cursor.bad == 0):
		part = vm_debug_byte(cursor)
		value = value | ((part & 127) << shift)
		shift = shift + 7
		if ((part & 128) == 0):
			if (signed_value && (part & 64)): value = value | (-1 << shift)
			return value
	cursor.bad = 1
	return 0


char* vm_debug_string(vm_debug_cursor* cursor):
	int start = cursor.at
	while (cursor.at < cursor.end && cursor.at - start < 4096):
		if (vm_debug_byte(cursor) == 0): return cursor.data + start
	cursor.bad = 1
	return 0


int vm_debug_range(int offset, int size, int length):
	return offset >= 0 && size >= 0 && offset <= length && size <= length - offset


# Return a validated section header; callers may safely read its payload.
char* vm_debug_section(char* image, int length, int index):
	int offset = load_int64(image + 40)
	int count = load_int16(image + 60)
	if (load_int16(image + 58) != 64 || index < 0 || index >= count): return 0
	if (vm_debug_range(offset, count * 64, length) == 0): return 0
	char* section = image + offset + index * 64
	if (vm_debug_range(load_int64(section + 24), load_int64(section + 32), length) == 0): return 0
	return section


# Append a source position, rejecting unsupported/malformed line programs.
void vm_debug_line(string_builder* output, char* data, int size, int pc):
	if (size < 25 || load_int16(data + 4) != 2): return
	int unit = load_int32(data)
	int header = load_int32(data + 6)
	if (unit < 21 || unit > size - 4 || header < 15 || header > unit - 6): return
	int base = cast(int, data[14]) & 255
	int line_range = cast(int, data[13]) & 255
	int line_base = cast(int, data[12]) & 255
	if (line_base > 127): line_base = line_base - 256
	int min_inst = cast(int, data[10]) & 255
	if (base < 10 || base > header - 5 || line_range == 0): return
	vm_debug_cursor cursor
	cursor.data = data
	cursor.at = 15 + base - 1
	cursor.end = 10 + header
	cursor.bad = 0
	# W records absolute filenames and an empty directory table.
	if (vm_debug_byte(&cursor) != 0): return
	char*[256] files
	int count = 0
	while (cursor.at < cursor.end && cursor.bad == 0):
		char* name = vm_debug_string(&cursor)
		if (name == 0): return
		if (name[0] == 0): break
		if (count == 256): return
		files[count] = name
		count = count + 1
		vm_debug_leb(&cursor, 0)
		vm_debug_leb(&cursor, 0)
		vm_debug_leb(&cursor, 0)
	if (cursor.bad || cursor.at != cursor.end): return
	cursor.end = unit + 4
	int address = 0
	int line = 1
	int file = 1
	int best_address = -1
	int best_line = 0
	int best_file = 0
	int found = 0
	int operations = 0
	while (cursor.at < cursor.end && cursor.bad == 0 && operations < 1000000):
		operations = operations + 1
		int op = vm_debug_byte(&cursor)
		int row = 0
		if (op == 0):
			int span = vm_debug_leb(&cursor, 0)
			if (span < 1 || span > cursor.end - cursor.at): return
			int next = cursor.at + span
			int sub = vm_debug_byte(&cursor)
			if (sub == 1):
				if (best_address >= 0 && pc < address): found = 1
				if (found): break
				address = 0
				line = 1
				file = 1
				best_address = -1
			else if (sub == 2):
				if (span != 9): return
				address = load_int64(data + cursor.at)
			cursor.at = next
		else if (op == 1): row = 1
		else if (op == 2): address = address + vm_debug_leb(&cursor, 0) * min_inst
		else if (op == 3): line = line + vm_debug_leb(&cursor, 1)
		else if (op == 4): file = vm_debug_leb(&cursor, 0)
		else if (op == 5): vm_debug_leb(&cursor, 0)
		else if (op == 6 || op == 7): pass
		else if (op == 8): address = address + (255 - base) / line_range * min_inst
		else if (op == 9):
			int low = vm_debug_byte(&cursor)
			address = address + low + vm_debug_byte(&cursor) * 256
		else if (op >= base):
			int delta = op - base
			address = address + delta / line_range * min_inst
			line = line + line_base + delta % line_range
			row = 1
		else: return
		if (row && address <= pc && address >= best_address):
			best_address = address
			best_line = line
			best_file = file
	if (cursor.bad || found == 0 || best_line < 1 || best_file < 1 || best_file > count): return
	string_append(output, c" (")
	string_append(output, files[best_file - 1])
	string_append(output, c":")
	string_append_int(output, best_line)
	string_append(output, c")")


# Owned string; empty when no validated symbol covers pc. The containing
# function's extent prevents borrowing a line from an unrelated address.
char* cell_fault_symbol(char* image, int length, int pc):
	string_builder* output = string_new()
	if (image != 0 && length >= 64 && length <= 67108864 && load_int32(image) == 0x464c457f && image[4] == 2 && image[5] == 1):
		char* names = vm_debug_section(image, length, load_int16(image + 62))
		char* debug = 0
		int count = load_int16(image + 60)
		if (count > 4096): count = 0
		int remaining_symbols = 1000000
		int remaining_name_bytes = 1048576
		for i in range(count):
			char* section = vm_debug_section(image, length, i)
			if (section == 0): continue
			if (names != 0):
				vm_debug_cursor name
				name.data = image + load_int64(names + 24)
				name.at = load_int32(section)
				name.end = load_int64(names + 32)
				name.bad = 0
				if (name.at >= 0 && name.at < name.end):
					char* text = vm_debug_string(&name)
					if (text != 0 && strcmp(text, c".debug_line") == 0): debug = section
			if (load_int32(section + 4) != 2 || load_int64(section + 56) != 24): continue
			if (output.length != 0 || remaining_name_bytes == 0): continue
			char* strings = vm_debug_section(image, length, load_int32(section + 40))
			if (strings == 0): continue
			int entries = load_int64(section + 32) / 24
			if (entries > remaining_symbols): entries = remaining_symbols
			remaining_symbols = remaining_symbols - entries
			for j in range(entries):
				char* symbol = image + load_int64(section + 24) + j * 24
				int start = load_int64(symbol + 8)
				int size = load_int64(symbol + 16)
				if ((symbol[4] & 15) != 2 || size <= 0 || start < 0 || pc < start || pc - start >= size): continue
				vm_debug_cursor name
				name.data = image + load_int64(strings + 24)
				name.at = load_int32(symbol)
				name.end = load_int64(strings + 32)
				name.bad = 0
				if (name.at < 0 || name.at >= name.end): continue
				if (name.end - name.at > remaining_name_bytes): name.end = name.at + remaining_name_bytes
				int name_start = name.at
				char* text = vm_debug_string(&name)
				remaining_name_bytes = remaining_name_bytes - (name.at - name_start)
				if (text != 0 && output.length == 0): string_append(output, text)
				if (output.length != 0 || remaining_name_bytes == 0): break
		if (output.length > 0 && debug != 0): vm_debug_line(output, image + load_int64(debug + 24), load_int64(debug + 32), pc)
	char* result = strclone(output.data)
	string_free(output)
	return result
