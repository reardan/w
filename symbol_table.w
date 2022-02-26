/*
table: stack of symbols
symbol format:
string: symbol\0 
char: [DULA]
int: address
int: type
*/
char *table
int table_size
int table_pos
int stack_pos
int table_struct_size


int symbol_data_size():
	return 18


int next_token(int t):
	return t + symbol_data_size()
	

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
	return load_int(table + t + 2)


/*
s: zero terminated string to declare
type: variable type e.g. int, char, etc.
visibility: 'DUAL' defined global-undefined global-a-local
value: memory address
symtype: 0:notype, 1:object, 2:func
*/
void sym_declare_new(char *s, int type, int visibility, int value, int symtype):
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
	table[t + 6] = type
	table[t + 10] = symtype
	table_pos = next_token(t)


char *last_global_declaration
int sym_declare_global(char *s, int type, int symtype):
	strcpy(last_global_declaration, s)
	int current_symbol = sym_lookup(s)
	if (current_symbol == 0):
		sym_declare_new(s, type, 'U', code_offset, symtype)
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
	if (table[t + 1] == 'D') { /* defined global */
	}
	else if (table[t + 1] == 'U'): /* undefined global */
		save_int(table + t + 2, codepos + code_offset - 4)
	else if (table[t + 1] == 'L'): /* local variable */
		int k = (stack_pos - table[t + 2] - 1) << 2
		emit(7, "\x8d\x84\x24....") /* lea (n * 4)(%esp),%eax */
		save_int(code + codepos - 4, k)

	else if (table[t + 1] == 'A'): /* argument */
		int k = (stack_pos + number_of_args - table[t + 2] + 1) << 2
		emit(7, "\x8d\x84\x24....") /* lea (n * 4)(%esp),%eax */
		save_int(code + codepos - 4, k)

	else:
		print_error("Error getting symbol value for '")
		print_error(s)
		print_error("', table[t + 1]='")
		put_error(table[t + 1])
		error("'")


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
	save_int(code + string_section_header, codepos - strings_addr)
	emit_string("strings")
	save_int(code + symbol_section_header, codepos - strings_addr)
	emit_string("symbol_table")
	save_int(code + debug_info_section_header, codepos - strings_addr)
	emit_string(".debug_info")
	string_count = string_count + 3

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

