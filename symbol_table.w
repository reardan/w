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

void print_symbol_table(int t):
	put_error("printing symbol table since ")
	put_error(itoa(t))
	put_error(":\x0a")
	while (t <= table_pos - 1):
		char* sym = table + t
		t = t + strlen(table + t)

		put_error(sym)

		put_error(": type(")
		puterror(table[t + 6] + '0')
		put_error(") symtype(")
		puterror(table[t + 1])
		put_error(") address(")
		int address = table + t + 2
		put_error(hex(*address))
		put_error(")\x0a")

		t = t + 10
	

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

		t = t + 10

	return current_symbol

void sym_declare(char *s, int type, int symtype, int value):
	int t = table_pos
	int i = 0
	while (s[i] != 0):
		if (table_size <= t + 10):
			int x = (t + 10) << 1
			table = realloc(table, table_size, x)
			table_size = x

		table[t] = s[i]
		i = i + 1
		t = t + 1

	table[t] = 0
	table[t + 1] = symtype
	save_int(table + t + 2, value)
	table[t + 6] = type
	table_pos = t + 10


char *last_global_declaration
int sym_declare_global(char *s, int type):
	strcpy(last_global_declaration, s)
	int current_symbol = sym_lookup(s)
	if (current_symbol == 0):
		sym_declare(s, type, 'U', code_offset)
		current_symbol = table_pos - 10

	return current_symbol

void sym_define_global(int current_symbol):
	int i
	int j
	int t = current_symbol
	int v = codepos + code_offset
	if (table[t + 1] != 'U'):
		put_error("symbol redefined: '")
		put_error(last_global_declaration)
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
		put_error("Cannot find symbol: '")
		put_error(token)
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
		put_error("Error getting symbol value for '")
		put_error(s)
		put_error("', table[t + 1]='")
		puterror(table[t + 1])
		error("'")


void sym_define_declare_global_function(char* name):
	sym_define_global(sym_declare_global(name, 4))
