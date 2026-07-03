/*
table: stack of symbols
symbol format:
string: symbol
char: \0 
char: [DULA]
int: 2: address
int: 6: type
int: 10: symtype
int: 14: size
int: 18: pointer indirection level
int: 22: number of declared parameters (functions), -1 when unknown
int: 26: declared parameter types (up to 10 slots of 4 bytes each)
*/
char *table
int table_size
int table_pos
int stack_pos


int symbol_data_size():
	return 66


int next_token(int t):
	return t + symbol_data_size()


void sym_table_info():
	print_error("sym_table_info(")
	print_int0("table_size: ", table_size)
	print_int0(", table_pos: ", table_pos)
	print_int0(", stack_pos: ", stack_pos)
	print_error(")\x0a")


void sym_info(int symbol):
	print_error("sym_info(")
	int t = table + symbol
	print_hex0("address: ", load_int(t + 2))
	print_error(", visibility: ")
	put_error(load_i(t + 1 ,1))
	print_int0(", type: ", load_int(t + 6))
	print_int0(", symtype: ", load_int(t + 10))
	print_int0(", size: ", load_int(t + 14))
	print_int0(", pointer: ", load_int(t + 18))
	print_error(")\x0a")


void sym_last_info():
	sym_info(table_pos - symbol_data_size())
	

# Returns the table offset of the symbol's data block, or -1 when not found.
# 0 is a valid offset (the first declared symbol), so callers must test for < 0.
int sym_lookup(char *s):
	int t = 0
	int current_symbol = -1
	while (t <= table_pos - 1):
		int i = 0
		while ((s[i] == table[t]) & (s[i] != 0)):
			i = i + 1
			t = t + 1

		if (s[i] == table[t]):
			current_symbol = t

		while (table[t] != 0):
			t = t + 1

		t = next_token(t)

	return current_symbol


int sym_address(char *s):
	int t = sym_lookup(s)
	if (t < 0):
		return 0
	return load_int(table + t + 2)


int sym_symtype(char *s):
	int t = sym_lookup(s)
	if (t < 0):
		return 0
	return load_int(table + t + 10)


int sym_type(char *s):
	int t = sym_lookup(s)
	if (t < 0):
		return 0
	return load_int(table + t + 6)


void sym_print_info(char *s):
	sym_info(sym_lookup(s))


/*
s: zero terminated string to declare
type: variable type e.g. int, char, etc.
visibility: 'DUAL' Defined global, Undefined global, Argument, Local
value: memory address
symtype: 0:notype, 1:object, 2:func
*/
int pointer_indirection
void sym_declare(char *s, int type, int visibility, int value, int symtype):
	if (verbosity >= 1):
		print2(itoa(line_number))
		print_string0(": sym_declare('", s)
		print_int0("', type=", type)
		print_char0(", visibility='", visibility)
		print_hex0("', value=", value)
		print_int0(", symtype=", symtype)
		println2(")")

	int t = table_pos
	int i = 0
	while (s[i] != 0):
		if (table_size <= next_token(t)):
			int x = next_token(t) << 1
			table = realloc(table, table_size, x)
			table_size = x

		table[t] = s[i]
		i = i + 1
		t = t + 1

	table[t] = 0
	table[t + 1] = visibility
	save_int(table + t + 2, value)
	save_int(table + t + 6, type)
	save_int(table + t + 10, symtype)
	save_int(table + t + 14, 0) /* size: recycled malloc blocks are not zeroed */
	save_int(table + t + 18, pointer_indirection)
	save_int(table + t + 22, -1) /* parameter count unknown until a '(...)' is parsed */
	table_pos = next_token(t)


char *last_global_declaration
int sym_declare_global(char *s, int type, int symtype):
	strcpy(last_global_declaration, s)
	int current_symbol = sym_lookup(s)
	if (current_symbol < 0):
		sym_declare(s, type, 'U', code_offset, symtype)
		current_symbol = table_pos - symbol_data_size()

	return current_symbol


void sym_define_global(int current_symbol):
	int i
	int j
	int t = current_symbol
	int v = codepos + code_offset
	if (table[t + 1] != 'U'):
		print_error("symbol redefined: '")
		print_error(last_global_declaration)
		error("'")
	i = load_int(table + t + 2) - code_offset
	while (i):
		j = load_int(code + i) - code_offset
		save_int(code + i, v)
		i = j

	table[t + 1] = 'D'
	save_int(table + t + 2, v)


int number_of_args

# Number of declared parameters for the function symbol at table offset t,
# or -1 when unknown (e.g. asm runtime stubs without a parameter list).
int sym_num_args(int t):
	return load_int(table + t + 22)


# Parameter type slots per symbol; arguments past the limit are unchecked.
int sym_max_param_slots():
	return 10


# Declared type of the function's parameter at index i (0-based), or -1
# when unknown: no parameter list was parsed or the slot was not recorded.
int sym_param_type(int t, int i):
	int num_args = load_int(table + t + 22)
	if (num_args < 0):
		return -1
	if (i >= num_args):
		return -1
	if (i >= sym_max_param_slots()):
		return -1
	return load_int(table + t + 26 + (i << 2))


# Emits code leaving the symbol's ADDRESS in eax and returns its type index.
# Functions are the exception: their address is their value, so they return
# the "function" type (4), which promote() leaves untouched.
int sym_get_value(char *s):
	int t
	if ((t = sym_lookup(s)) < 0):
		print_error("Cannot find symbol: '")
		print_error(token)
		error("'")
	emit(5, "\xb8....") /* mov $n,%eax */
	save_int(code + codepos - 4, load_int(table + t + 2))

	char scope_type = table[t + 1]
	int type = load_int(table + t + 6)
	int symtype = load_int(table + t + 10)

	int k = 0
	if (verbosity >= 2):
		print_error(s)
		print_error(": ")
		sym_info(t)

	/* defined global */
	if (scope_type == 'D') {
		# Nothing needed since it directly uses the address from above
	}

	/* undefined global: link this site into the backpatch chain */
	else if (scope_type == 'U'):
		save_int(table + t + 2, codepos + code_offset - 4)

	/* local variable */
	else if (scope_type == 'L'):
		k = (stack_pos - table[t + 2] - 1) << word_size_log2

	/* argument */
	else if (scope_type == 'A'):
		k = (stack_pos + number_of_args - table[t + 2] + 1) << word_size_log2

	else:
		print_error("Error getting symbol value for '")
		print_error(s)
		print_error("', table[t + 1]='")
		put_error(table[t + 1])
		error("'")

	if ((scope_type == 'L') | (scope_type == 'A')):
		# emit(7, "\x8d\x84\x24....") /* lea (n * 4)(%esp),%eax */
		lea_eax_esp_plus(0) /* 0 is a placeholder */

		# Structs occupy several stack words; point at the lowest address (last
		# pushed word) so positive field offsets stay inside the struct.
		int num_args = type_num_args(type)
		if (num_args > 0):
			int struct_words = (type_get_size(type) + word_size - 1) >> word_size_log2
			k = k - ((struct_words - 1) << word_size_log2)
		save_int(code + codepos - 4, k)

	if (symtype == 2):
		if ((scope_type == 'D') | (scope_type == 'U')):
			return 4 /* function */

	return type


void sym_define_declare_global_function(char* name):
	sym_define_global(sym_declare_global(name, 4, 2))


void print_symbol_table(int t):
	print_error("printing symbol table since ")
	print_error(itoa(t))
	print_error(":\x0a")
	int symbol = 0
	while (t <= table_pos - 1):
		char* sym = table + t
		t = t + strlen(table + t)

		print_error(itoa(symbol))
		print_error(": ")
		print_error(sym)

		print_error(" type(")
		put_error(table[t + 6] + '0')
		print_error(") visibility(")
		put_error(table[t + 1])
		print_error(") address(")
		int address = table + t + 2
		print_error(hex(*address))
		print_error(") symtype(")
		put_error(table[t + 10] + '0')
		print_int0(") size (", load_int(table + t + 14))
		print_int0(") pointer (", load_int(table + t + 18))
		print_error(")\x0a")

		t = next_token(t)
		symbol = symbol + 1


int emit_string_table():
	if (verbosity >= 1):
		print_error("dumping string table\x0a")
	int t = 0
	int n = 0
	int count = 0
	emit_int8(0) /* index 0 must be the empty string */
	while (t <= table_pos - 1):
		char* sym = table + t
		n = strlen(table + t)
		t = t + n
		emit(n + 1, sym)
		t = next_token(t)
		count = count + 1

	return count


int emit_symbol_table():
	if (verbosity >= 1):
		print_error("dumping symbol table\x0a")
	int t = 0
	int n = 0
	int symbol = 1 /* string table starts with a null byte */
	int count = 1
	elf_sym_table_entry(0, 0, 0, 0, 0, 0) /* mandatory null symbol */
	while (t <= table_pos - 1):
		char* sym = table + t
		n = strlen(table + t)
		t = t + n

		int visibility = table[t + 1]
		int binding = 1  /* global by default */
		if (visibility != 'D'):
			binding = 0
		int symtype = table[t + 10]
		int address = table + t + 2
		int size = load_int(table + t + 14)
		elf_sym_table_entry(symbol, *address, size, binding, symtype, 1) /* shndx 1 = .text */

		t = next_token(t)
		symbol = symbol + n + 1
		count = count + 1

	return count


void emit_section_name(char* s, int header_addr, int strings_addr):
	save_int(code + header_addr, codepos - strings_addr)
	emit_string(s)


# Set a section header's file offset and size, and zero the symtab-oriented
# defaults that only apply to .symtab.
void section_set_range(int header, int addr, int length):
	save_int(code + header + 16, addr) /* offset */
	save_int(code + header + 20, length) /* size */
	save_int(code + header + 24, 0) /* link */
	save_int(code + header + 36, 0) /* entry size */


void emit_debugging_symbols(int word_size):
	int text_end = codepos

	# Store start of section header
	int header_addr = codepos

	# Save section header address + number of sections
	# Section order: null, text, debug_info, debug_abbrev, debug_line, strings, symtab
	elf_save_section_info(word_size, header_addr, 7, 5)

	# Mandatory null section 0
	emit_zeros(40)

	# .text covers the whole loaded image (headers + code + data)
	int text_section_header = codepos
	elf_section_header(1)
	save_int(code + text_section_header + 8, 6) /* flags: alloc + exec */
	save_int(code + text_section_header + 12, code_offset) /* addr */
	save_int(code + text_section_header + 16, 0) /* offset */
	save_int(code + text_section_header + 20, text_end) /* size */
	save_int(code + text_section_header + 24, 0) /* link */
	save_int(code + text_section_header + 36, 0) /* entry size */

	# Emit debug info section header
	int debug_info_section_header = codepos
	elf_section_header(1)

	int debug_abbrev_section_header = codepos
	elf_section_header(1)

	int debug_line_section_header = codepos
	elf_section_header(1)

	# Emit string section header
	int string_section_header = codepos
	elf_section_header(3)

	# Emit symbol section header
	int symbol_section_header = codepos
	elf_section_header(2)

	# Emit strings
	int strings_addr = codepos
	int string_count = emit_string_table()

	# Emit section header name strings
	emit_section_name("strings", string_section_header, strings_addr)
	emit_section_name(".symtab", symbol_section_header, strings_addr)
	emit_section_name(".text", text_section_header, strings_addr)
	emit_section_name(".debug_info", debug_info_section_header, strings_addr)
	emit_section_name(".debug_abbrev", debug_abbrev_section_header, strings_addr)
	emit_section_name(".debug_line", debug_line_section_header, strings_addr)

	# Store string strings_addr + length
	int length = codepos - strings_addr
	save_int(code + string_section_header + 12, strings_addr)
	save_int(code + string_section_header + 16, strings_addr)
	save_int(code + string_section_header + 20, length)
	save_int(code + string_section_header + 24, 0) /* link */
	save_int(code + string_section_header + 28, 0) /* info */
	save_int(code + string_section_header + 36, 0) /* entry size */

	# Emit symbols
	int sym_table_addr = codepos
	int symbol_count = emit_symbol_table()
	int sym_table_length = codepos - sym_table_addr
	save_int(code + symbol_section_header + 12, sym_table_addr)
	save_int(code + symbol_section_header + 16, sym_table_addr)
	save_int(code + symbol_section_header + 20, sym_table_length)
	save_int(code + symbol_section_header + 24, 5) /* link: the strings section */
	save_int(code + symbol_section_header + 28, 0) /* info: no leading locals */

	# Emit the DWARF payloads
	int debug_info_addr = codepos
	debug_info_emit(text_end)
	section_set_range(debug_info_section_header, debug_info_addr, codepos - debug_info_addr)

	int debug_abbrev_addr = codepos
	debug_abbrev_emit()
	section_set_range(debug_abbrev_section_header, debug_abbrev_addr, codepos - debug_abbrev_addr)

	int debug_line_addr = codepos
	debug_line_emit()
	section_set_range(debug_line_section_header, debug_line_addr, codepos - debug_line_addr)

	emit_int8(0) /* placeholder so reader doesn't read beyond the end of the file */

