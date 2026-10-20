# ELF inspection for compiler CLI. Keep this module seed-compatible.
import lib.args
import libs.asm.binary_reader
import libs.asm.x86_decode
import libs.asm.format
import libs.asm.arm64_decode
import libs.asm.arm64_format

struct inspect_section:
	char* name
	int kind
	int flags
	int address
	int offset
	int size
	int link
	int entsize

struct inspect_symbol:
	char* name
	int value
	int size
	int info
	int section

struct inspect_binary:
	char* data
	int length
	int elf_class
	int machine
	int kind
	list[inspect_section] sections
	list[inspect_symbol] symbols

char* inspect_error

int inspect_fail(char* message):
	if (inspect_error == 0): inspect_error = message
	return 0

# Subtraction avoids overflow in adversarial offset/length pairs.
int inspect_range(int length, int offset, int size):
	return offset >= 0 && size >= 0 && offset <= length && size <= length - offset

# W output uses low 32-bit addresses. Reject unsupported wide fields,
# rather than silently truncating them when inspecting with an x86 host.
int inspect_word(char* data, int offset, int elf_class):
	if (elf_class == 2 && asm_read_u32(data, offset + 4) != 0):
		inspect_fail(c"64-bit field exceeds supported 32-bit range")
	return asm_read_u32(data, offset)

char* inspect_string(inspect_binary* binary, inspect_section* strings, int offset):
	if (offset < 0 || offset >= strings.size):
		inspect_fail(c"string table offset out of range")
		return c""
	int pos = offset
	while (pos < strings.size):
		if (binary.data[strings.offset + pos] == 0): return binary.data + strings.offset + offset
		pos = pos + 1
	inspect_fail(c"unterminated string table entry")
	return c""

# The input buffer remains caller-owned. All bounds are checked before
# reading a table, and names are checked before any C-string operation.
int inspect_parse(inspect_binary* binary, char* data, int length):
	inspect_error = 0
	binary.data = data
	binary.length = length
	binary.sections = new list[inspect_section]
	binary.symbols = new list[inspect_symbol]
	if (length < 16 || asm_is_elf(data, length) == 0): return inspect_fail(c"not an ELF file")
	binary.elf_class = asm_read_u8(data, 4)
	if (binary.elf_class != 1 && binary.elf_class != 2): return inspect_fail(c"unsupported ELF class")
	if (asm_read_u8(data, 5) != 1): return inspect_fail(c"only little-endian ELF is supported")
	if (asm_read_u8(data, 6) != 1): return inspect_fail(c"unsupported ELF version")
	int is64 = binary.elf_class == 2
	int header_size = 52
	int section_size = 40
	int shoff_at = 32
	int counts_at = 46
	if (is64):
		header_size = 64
		section_size = 64
		shoff_at = 40
		counts_at = 58
	if (length < header_size): return inspect_fail(c"truncated ELF header")
	binary.machine = asm_read_u16(data, 18)
	binary.kind = asm_read_u16(data, 16)
	if (asm_read_u32(data, 20) != 1): return inspect_fail(c"unsupported ELF version")
	if (asm_read_u16(data, counts_at - 6) != header_size): return inspect_fail(c"invalid ELF header size")
	int shoff = inspect_word(data, shoff_at, binary.elf_class)
	int stride = asm_read_u16(data, counts_at)
	int count = asm_read_u16(data, counts_at + 2)
	int names = asm_read_u16(data, counts_at + 4)
	if (inspect_error != 0): return 0
	if (shoff == 0 && count == 0 && names == 0): return 1
	if (count == 0 || names == 65535): return inspect_fail(c"extended section numbering is unsupported")
	if (shoff < header_size || stride < section_size || names >= count): return inspect_fail(c"invalid section header table")
	if (inspect_range(length, shoff, 0) == 0 || count > (length - shoff) / stride): return inspect_fail(c"truncated section header table")
	for i in range(count):
		int at = shoff + i * stride
		inspect_section section
		section.name = c""
		section.kind = asm_read_u32(data, at + 4)
		section.flags = asm_read_u32(data, at + 8)
		int fields = at + 12
		int width = 4
		if (is64):
			fields = at + 16
			width = 8
		section.address = inspect_word(data, fields, binary.elf_class)
		section.offset = inspect_word(data, fields + width, binary.elf_class)
		section.size = inspect_word(data, fields + 2 * width, binary.elf_class)
		section.link = asm_read_u32(data, fields + 3 * width)
		section.entsize = inspect_word(data, at + section_size - width, binary.elf_class)
		if (inspect_error != 0): return 0
		if (section.size < 0): return inspect_fail(c"section size exceeds supported range")
		if (section.kind != 0 && section.kind != 8 && inspect_range(length, section.offset, section.size) == 0): return inspect_fail(c"section data outside file")
		binary.sections.push(section)
	if (names != 0):
		inspect_section strings = binary.sections[names]
		if (strings.kind != 3): return inspect_fail(c"section names must reference a string table")
		for i in range(count):
			inspect_section section = binary.sections[i]
			section.name = inspect_string(binary, &strings, asm_read_u32(data, shoff + i * stride))
			binary.sections[i] = section
	else:
		for i in range(count):
			if (asm_read_u32(data, shoff + i * stride) != 0): return inspect_fail(c"section names without a string table")
	if (inspect_error != 0): return 0
	for i in range(count):
		inspect_section table = binary.sections[i]
		if (table.kind == 2 || table.kind == 11):
			int symbol_size = 16
			if (is64): symbol_size = 24
			if (table.entsize < symbol_size || table.size % table.entsize != 0): return inspect_fail(c"invalid symbol table entry size")
			if (table.link <= 0 || table.link >= count): return inspect_fail(c"invalid symbol string table link")
			inspect_section strings = binary.sections[table.link]
			if (strings.kind != 3): return inspect_fail(c"symbols must reference a string table")
			for j in range(table.size / table.entsize):
				int at = table.offset + j * table.entsize
				inspect_symbol symbol
				symbol.name = inspect_string(binary, &strings, asm_read_u32(data, at))
				if (is64):
					symbol.info = asm_read_u8(data, at + 4)
					symbol.section = asm_read_u16(data, at + 6)
					symbol.value = inspect_word(data, at + 8, 2)
					symbol.size = inspect_word(data, at + 16, 2)
				else:
					symbol.value = asm_read_u32(data, at + 4)
					symbol.size = asm_read_u32(data, at + 8)
					symbol.info = asm_read_u8(data, at + 12)
					symbol.section = asm_read_u16(data, at + 14)
				if (inspect_error != 0): return 0
				if (symbol.size < 0): return inspect_fail(c"symbol size exceeds supported range")
				if (symbol.section >= count && symbol.section < 65280): return inspect_fail(c"symbol section index out of range")
				binary.symbols.push(symbol)
	return 1

void inspect_free(inspect_binary* binary):
	__w_list_free(cast(__w_list*, binary.sections))
	__w_list_free(cast(__w_list*, binary.symbols))

void inspect_print_hex(int value):
	char* formatted = asm_hex_min(value)
	print(formatted)
	free(formatted)

void inspect_sections(inspect_binary* binary):
	println(c"Sections: index name type address offset size")
	for i in range(binary.sections.length):
		inspect_section section = binary.sections[i]
		print(itoa(i))
		print(c" ")
		print(section.name)
		print(c" ")
		print(itoa(section.kind))
		print(c" ")
		inspect_print_hex(section.address)
		print(c" ")
		inspect_print_hex(section.offset)
		print(c" ")
		print(itoa(section.size))
		put_char(10)

void inspect_symbols(inspect_binary* binary):
	println(c"Symbols: address size type binding section name")
	for i in range(binary.symbols.length):
		inspect_symbol symbol = binary.symbols[i]
		if (symbol.name[0] != 0):
			inspect_print_hex(symbol.value)
			print(c" ")
			print(itoa(symbol.size))
			print(c" ")
			print(itoa(symbol.info & 15))
			print(c" ")
			print(itoa(symbol.info >> 4))
			print(c" ")
			print(itoa(symbol.section))
			print(c" ")
			println(symbol.name)

# Resolve by section index, never by assuming address == file offset.
# Zero-sized function symbols extend to the next symbol or section end.
int inspect_function(inspect_binary* binary, char* name, int* offset, int* size, int* address):
	for i in range(binary.symbols.length):
		inspect_symbol symbol = binary.symbols[i]
		if (strcmp(symbol.name, name) != 0): continue
		if (symbol.section <= 0 || symbol.section >= binary.sections.length): continue
		if ((symbol.info & 15) != 2 && (symbol.info & 15) != 0): continue
		inspect_section section = binary.sections[symbol.section]
		if ((section.flags & 4) == 0 || section.kind == 0 || section.kind == 8): continue
		int relative = symbol.value - section.address
		if (binary.kind == 1): relative = symbol.value
		if (relative < 0 || relative >= section.size): return inspect_fail(c"function address outside section")
		int extent = symbol.size
		if (extent == 0):
			extent = section.size - relative
			for j in range(binary.symbols.length):
				inspect_symbol next = binary.symbols[j]
				int distance = next.value - symbol.value
				if (next.section == symbol.section && distance > 0 && distance < extent): extent = distance
		if (extent > section.size - relative): return inspect_fail(c"function size outside section")
		if (inspect_range(binary.length, section.offset + relative, extent) == 0): return inspect_fail(c"function data outside file")
		*offset = section.offset + relative
		*size = extent
		*address = symbol.value
		return 1
	return inspect_fail(c"function not found in an executable section")

int inspect_disasm(inspect_binary* binary, char* name):
	int mode = 4
	if (binary.machine == 62 && binary.elf_class == 2): mode = 8
	else if (binary.machine == 183 && binary.elf_class == 2): mode = 0
	else if (binary.machine != 3 || binary.elf_class != 1): return inspect_fail(c"unsupported machine/class for disassembly")
	int offset = 0
	int size = 0
	int address = 0
	if (inspect_function(binary, name, &offset, &size, &address) == 0): return 0
	print(c"Disassembly of ")
	print(name)
	println(c":")
	int pos = 0
	while (pos < size):
		asm_insn instruction
		int consumed = 0
		char* formatted = 0
		if (mode == 0 && size - pos >= 4):
			consumed = asm_arm64_decode(binary.data + offset + pos, size - pos, address + pos, &instruction)
			formatted = asm_arm64_format(&instruction)
		else if (mode != 0):
			consumed = asm_x86_decode(binary.data + offset + pos, size - pos, address + pos, mode, &instruction)
			formatted = asm_format(&instruction)
		inspect_print_hex(address + pos)
		print(c"  ")
		if (consumed <= 0 || consumed > size - pos):
			consumed = 1
			print(c".byte ")
			inspect_print_hex(asm_read_u8(binary.data, offset + pos))
		else: print(formatted)
		put_char(10)
		if (formatted != 0): free(formatted)
		pos = pos + consumed
	return 1

char* inspect_usage():
	return c"usage: w inspect FILE [--sections] [--symbols] [--disasm FUNCTION]"

int inspect_main(int argc, int argv):
	args_init(argc, argv)
	char* path = 0
	char* function_name = 0
	int sections = 0
	int symbols = 0
	int options = 1
	int i = 2
	while (i < argc):
		char* arg = args_get(i)
		if (options && (strcmp(arg, c"--help") == 0 || strcmp(arg, c"-h") == 0)):
			println(inspect_usage())
			println(c"Default: sections and symbols. Supports little-endian ELF32/ELF64.")
			return 0
		else if (options && strcmp(arg, c"--") == 0): options = 0
		else if (options && strcmp(arg, c"--sections") == 0): sections = 1
		else if (options && strcmp(arg, c"--symbols") == 0): symbols = 1
		else if (options && strcmp(arg, c"--disasm") == 0):
			i = i + 1
			if (i >= argc || function_name != 0):
				println2(inspect_usage())
				return 1
			function_name = args_get(i)
		else if ((options && arg[0] == '-') || path != 0):
			println2(inspect_usage())
			return 1
		else: path = arg
		i = i + 1
	if (path == 0):
		println2(inspect_usage())
		return 1
	if (sections == 0 && symbols == 0 && function_name == 0):
		sections = 1
		symbols = 1
	int length = 0
	char* data = asm_binary_read_file(path, &length)
	if (data == 0):
		print2(c"inspect: cannot read ")
		println2(path)
		return 1
	inspect_binary binary
	int ok = inspect_parse(&binary, data, length)
	if (ok):
		if (sections): inspect_sections(&binary)
		if (symbols): inspect_symbols(&binary)
		if (function_name != 0): ok = inspect_disasm(&binary, function_name)
	if (ok == 0):
		print2(c"inspect: ")
		println2(inspect_error)
	inspect_free(&binary)
	free(data)
	return 1 - ok
