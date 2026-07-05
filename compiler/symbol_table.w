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
int: 66: declaration file index (dwarf.w debug_files), -1 when unknown
int: 70: declaration line (1-based)
int: 74: declaration column (1-based)
int: 78: variadic C import: number of fixed parameters, -1 when not variadic
int: 82: GOT slot vaddr for extern imports, 0 otherwise
*/
char *table
int table_size
int table_pos
int stack_pos


int symbol_data_size():
	return 86


int next_token(int t):
	return t + symbol_data_size()


void sym_table_info():
	print_error(c"sym_table_info(")
	print_int0(c"table_size: ", table_size)
	print_int0(c", table_pos: ", table_pos)
	print_int0(c", stack_pos: ", stack_pos)
	print_error(c")\x0a")


void sym_info(int symbol):
	print_error(c"sym_info(")
	int t = table + symbol
	print_hex0(c"address: ", load_int(t + 2))
	print_error(c", visibility: ")
	put_error(load_i(t + 1 ,1))
	print_int0(c", type: ", load_int(t + 6))
	print_int0(c", symtype: ", load_int(t + 10))
	print_int0(c", size: ", load_int(t + 14))
	print_int0(c", pointer: ", load_int(t + 18))
	print_error(c")\x0a")


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


# Registered index of the file currently being parsed, or -1 when no source
# file is active (e.g. runtime stubs declared by be_start before compilation).
int decl_file_index():
	if (filename == 0):
		return -1
	return debug_line_file_index()


int sym_decl_file_index(int t):
	return load_int(table + t + 66)


int sym_decl_line(int t):
	return load_int(table + t + 70)


int sym_decl_column(int t):
	return load_int(table + t + 74)


void sym_set_decl_location(int t, int file_index, int line, int column):
	save_int(table + t + 66, file_index)
	save_int(table + t + 70, line)
	save_int(table + t + 74, column)


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
		print_string0(c": sym_declare('", s)
		print_int0(c"', type=", type)
		print_char0(c", visibility='", visibility)
		print_hex0(c"', value=", value)
		print_int0(c", symtype=", symtype)
		println2(c")")

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
	save_int(table + t + 78, -1) /* not variadic */
	save_int(table + t + 82, 0)  /* no GOT slot */
	# Declaration location: token position of the name being declared
	save_int(table + t + 66, decl_file_index())
	save_int(table + t + 70, diag_token_line)
	save_int(table + t + 74, diag_token_column)
	table_pos = next_token(t)

	# Record where locals and arguments live so the in-process debugger
	# (wdbg) can inspect them by name at runtime
	if ((visibility == 'L') | (visibility == 'A')):
		debug_local_note(s, value, visibility, type)


char *last_global_declaration
int sym_declare_global(char *s, int type, int symtype):
	strcpy(last_global_declaration, s)
	int current_symbol = sym_lookup(s)
	if (current_symbol < 0):
		sym_declare(s, type, 'U', code_offset, symtype)
		current_symbol = table_pos - symbol_data_size()
	else if (sym_decl_file_index(current_symbol) < 0):
		# Forward-referenced symbol (e.g. 'main' pre-declared by be_start):
		# this explicit declaration is the real source location
		sym_set_decl_location(current_symbol, decl_file_index(), diag_token_line, diag_token_column)

	return current_symbol


void sym_define_global(int current_symbol):
	int i
	int j
	int t = current_symbol
	int v = codepos + code_offset
	if (table[t + 1] != 'U'):
		diag_part(c"symbol redefined: '")
		diag_part(last_global_declaration)
		error(c"'")
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


# Number of fixed parameters of a variadic C import at table offset t, or
# -1 when the symbol is not variadic.
int sym_variadic_fixed_args(int t):
	return load_int(table + t + 78)


void sym_set_variadic(int t, int fixed_args):
	save_int(table + t + 78, fixed_args)


# GOT slot vaddr of an extern import (the dynamic loader stores the
# resolved C function address there), or 0 for ordinary symbols.
int sym_got_vaddr(int t):
	return load_int(table + t + 82)


void sym_set_got_vaddr(int t, int vaddr):
	save_int(table + t + 82, vaddr)


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
		diag_part(c"Cannot find symbol: '")
		diag_part(token)
		error(c"'")
	emit(5, c"\xb8....") /* mov $n,%eax */
	save_int(code + codepos - 4, load_int(table + t + 2))

	char scope_type = table[t + 1]
	int type = load_int(table + t + 6)
	int symtype = load_int(table + t + 10)

	int k = 0
	if (verbosity >= 2):
		print_error(s)
		print_error(c": ")
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
		diag_part(c"Error getting symbol value for '")
		diag_part(s)
		diag_part(c"', table[t + 1]='")
		char* visibility = malloc(2)
		visibility[0] = table[t + 1]
		visibility[1] = 0
		diag_part(visibility)
		free(visibility)
		error(c"'")

	if ((scope_type == 'L') | (scope_type == 'A')):
		# emit(7, "\x8d\x84\x24....") /* lea (n * 4)(%esp),%eax */
		lea_eax_esp_plus(0) /* 0 is a placeholder */

		# Aggregates occupy several stack words; point at the lowest address
		# (last pushed word) so positive offsets stay inside the object.
		int words = type_stack_words(type)
		if (words > 1):
			k = k - ((words - 1) << word_size_log2)
		save_int(code + codepos - 4, k)

	if (symtype == 2):
		if ((scope_type == 'D') | (scope_type == 'U')):
			return 4 /* function */

	return type


void sym_define_declare_global_function(char* name):
	sym_define_global(sym_declare_global(name, 4, 2))


void print_symbol_table(int t):
	print_error(c"printing symbol table since ")
	print_error(itoa(t))
	print_error(c":\x0a")
	int symbol = 0
	while (t <= table_pos - 1):
		char* sym = table + t
		t = t + strlen(table + t)

		print_error(itoa(symbol))
		print_error(c": ")
		print_error(sym)

		print_error(c" type(")
		put_error(table[t + 6] + '0')
		print_error(c") visibility(")
		put_error(table[t + 1])
		print_error(c") address(")
		print_error(hex(load_int(table + t + 2)))
		print_error(c") symtype(")
		put_error(table[t + 10] + '0')
		print_int0(c") size (", load_int(table + t + 14))
		print_int0(c") pointer (", load_int(table + t + 18))
		print_error(c")\x0a")

		t = next_token(t)
		symbol = symbol + 1


int emit_string_table():
	if (verbosity >= 1):
		print_error(c"dumping string table\x0a")
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
		print_error(c"dumping symbol table\x0a")
	int t = 0
	int n = 0
	int symbol = 1 /* string table starts with a null byte */
	int count = 1
	elf_emit_sym_table_entry(0, 0, 0, 0, 0, 0) /* mandatory null symbol */
	while (t <= table_pos - 1):
		char* sym = table + t
		n = strlen(table + t)
		t = t + n

		int visibility = table[t + 1]
		int binding = 1  /* global by default */
		if (visibility != 'D'):
			binding = 0
		int symtype = table[t + 10]
		int address = load_int(table + t + 2)
		int size = load_int(table + t + 14)
		elf_emit_sym_table_entry(symbol, address, size, binding, symtype, 1) /* shndx 1 = .text */

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
	elf_section_set_offset(header, addr)
	elf_section_set_size(header, length)
	elf_section_set_link(header, 0)
	elf_section_set_entsize(header, 0)


void emit_debugging_symbols(int word_size):
	int text_end = codepos

	# Store start of section header
	int header_addr = codepos

	# Save section header address + number of sections
	# Section order: null, text, debug_info, debug_abbrev, debug_line, strings, symtab
	elf_save_section_info(word_size, header_addr, 7, 5)

	# Mandatory null section 0
	emit_zeros(elf_section_header_length())

	# .text covers the whole loaded image (headers + code + data)
	int text_section_header = codepos
	elf_emit_section_header(1)
	elf_section_set_flags(text_section_header, 6) /* alloc + exec */
	elf_section_set_addr(text_section_header, code_offset)
	elf_section_set_offset(text_section_header, 0)
	elf_section_set_size(text_section_header, text_end)
	elf_section_set_link(text_section_header, 0)
	elf_section_set_entsize(text_section_header, 0)

	# Emit debug info section header
	int debug_info_section_header = codepos
	elf_emit_section_header(1)

	int debug_abbrev_section_header = codepos
	elf_emit_section_header(1)

	int debug_line_section_header = codepos
	elf_emit_section_header(1)

	# Emit string section header
	int string_section_header = codepos
	elf_emit_section_header(3)

	# Emit symbol section header
	int symbol_section_header = codepos
	elf_emit_section_header(2)

	# Emit strings
	int strings_addr = codepos
	int string_count = emit_string_table()

	# Emit section header name strings
	emit_section_name(c"strings", string_section_header, strings_addr)
	emit_section_name(c".symtab", symbol_section_header, strings_addr)
	emit_section_name(c".text", text_section_header, strings_addr)
	emit_section_name(c".debug_info", debug_info_section_header, strings_addr)
	emit_section_name(c".debug_abbrev", debug_abbrev_section_header, strings_addr)
	emit_section_name(c".debug_line", debug_line_section_header, strings_addr)

	# Store string strings_addr + length
	int length = codepos - strings_addr
	elf_section_set_addr(string_section_header, strings_addr)
	elf_section_set_offset(string_section_header, strings_addr)
	elf_section_set_size(string_section_header, length)
	elf_section_set_link(string_section_header, 0)
	elf_section_set_info(string_section_header, 0)
	elf_section_set_entsize(string_section_header, 0)

	# Emit symbols
	int sym_table_addr = codepos
	int symbol_count = emit_symbol_table()
	int sym_table_length = codepos - sym_table_addr
	elf_section_set_addr(symbol_section_header, sym_table_addr)
	elf_section_set_offset(symbol_section_header, sym_table_addr)
	elf_section_set_size(symbol_section_header, sym_table_length)
	elf_section_set_link(symbol_section_header, 5) /* link: the strings section */
	elf_section_set_info(symbol_section_header, 0) /* info: no leading locals */

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

