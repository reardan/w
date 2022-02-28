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
*/
char *table
int table_size
int table_pos
int stack_pos


int symbol_data_size():
	return 22


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
	

int sym_lookup(char *s):
	int t = 0
	int current_symbol = 0
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
	if (t == 0):
		return 0
	return load_int(table + t + 2)


int sym_symtype(char *s):
	int t = sym_lookup(s)
	return load_int(table + t + 10)


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
	save_int(table + t + 18, pointer_indirection)
	table_pos = next_token(t)


char *last_global_declaration
int sym_declare_global(char *s, int type, int symtype):
	strcpy(last_global_declaration, s)
	int current_symbol = sym_lookup(s)
	if (current_symbol == 0):
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

void sym_get_value(char *s):
	int t
	if ((t = sym_lookup(s)) == 0):
		print_error("Cannot find symbol: '")
		print_error(token)
		error("'\x0a")
	emit(5, "\xb8....") /* mov $n,%eax */
	save_int(code + codepos - 4, load_int(table + t + 2))

	char scope_type = table[t + 1]
	int type = load_int(table + t + 6)
	int is_indirect_type = (type == 1) | (type == 1)
	int symtype = load_int(table + t + 10)
	int ptr_indirect = load_int(table + t + 18)
	int is_indirect_pointer = (ptr_indirect > 0) & is_indirect_type
	int is_function = 0 & is_indirect_type & (symtype == 2) & (scope_type == 'A')

	int k = 0
	if (verbosity >= 2):
		print_error(s)
		print_error(": ")
		sym_info(t)

	/* defined global */
	if (scope_type == 'D') {
		# Nothing needed since it directly uses the address from above
	}

	/* undefined global */
	else if (scope_type == 'U'):
		save_int(table + t + 2, codepos + code_offset - 4)

	/* local variable */
	else if (scope_type == 'L'):
		k = (stack_pos - table[t + 2] - 1) << 2

	/* argument */
	else if (scope_type == 'A'):
		k = (stack_pos + number_of_args - table[t + 2] + 1) << 2

	else:
		print_error("Error getting symbol value for '")
		print_error(s)
		print_error("', table[t + 1]='")
		put_error(table[t + 1])
		error("'")

	if ((scope_type == 'L') | (scope_type == 'A')):
		if (is_indirect_pointer):
			if (verbosity >= 1):
				print_error("pointer_indirection for ")
				sym_info(t)
				warning(s)
			emit(7, "\x8b\x84\x24....") /* mov eax, [esp + ....] */
		else:
			emit(7, "\x8d\x84\x24....") /* lea (n * 4)(%esp),%eax */
		save_int(code + codepos - 4, k)


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
	print_error("dumping string table\x0a")
	int t = 0
	int n = 0
	int count = 0
	while (t <= table_pos - 1):
		char* sym = table + t
		n = strlen(table + t)
		t = t + n
		emit(n + 1, sym)
		t = next_token(t)
		count = count + 1

	return count


int emit_symbol_table():
	print_error("dumping symbol table\x0a")
	int t = 0
	int n = 0
	int symbol = 0
	int count = 0
	while (t <= table_pos - 1):
		char* sym = table + t
		n = strlen(table + t)
		t = t + n

		int type = table[t + 6]
		int visibility = table[t + 1]
		int binding = 1  /* global by default */
		if (visibility != 'D'):
			binding = 0
		int symtype = table[t + 10]
		int address = table + t + 2
		int size = load_int(table + t + 14)
		elf_sym_table_entry(symbol, *address, size, binding, symtype, type)

		t = next_token(t)
		symbol = symbol + n + 1
		count = count + 1

	return count


void emit_section_name(char* s, int header_addr, int strings_addr):
	save_int(code + header_addr, codepos - strings_addr)
	emit_string(s)


void emit_debugging_symbols():
	# Store start of section header
	int header_addr = codepos

	# Save section header address + number of sections
	save_int(code + 32, header_addr)
	save_i(code + 48, 3, 2) /* number of section headers */
	save_i(code + 50, 1, 2) /* string index */

	# Emit debug info section header
	int debug_info_section_header = codepos
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
	emit_section_name("symbol_table", symbol_section_header, strings_addr)
	emit_section_name(".debug_info", debug_info_section_header, strings_addr)

	# Store string strings_addr + length
	int length = codepos - strings_addr
	save_int(code + string_section_header + 12, strings_addr)
	save_int(code + string_section_header + 16, strings_addr)
	save_int(code + string_section_header + 20, length)
	save_int(code + string_section_header + 28, string_count)

	# Emit symbols
	int sym_table_addr = codepos
	int symbol_count = emit_symbol_table()
	int sym_table_length = codepos - sym_table_addr
	save_int(code + symbol_section_header + 12, sym_table_addr)
	save_int(code + symbol_section_header + 16, sym_table_addr)
	save_int(code + symbol_section_header + 20, sym_table_length)
	save_int(code + symbol_section_header + 28, symbol_count)

	emit_int8(0) /* placeholder so reader doesn't read beyond the end of the file */

