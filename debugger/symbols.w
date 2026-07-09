/*
Symbol table queries for wdbg.

After the in-process compile the compiler's symbol table still holds every
global the debuggee defined: functions carry their absolute start address
(offset 2) and code length (offset 14), which is enough to map any address
back to the function containing it.

Offsets returned by these helpers point at the START of the symbol's name;
the data block starts after the name's terminating zero (dbg_sym_data).
*/
import debugger.lines


int dbg_sym_data(int name_offset):
	return name_offset + strlen(table + name_offset)


char* dbg_sym_name(int name_offset):
	return table + name_offset


int dbg_sym_address(int name_offset):
	return load_int(table + dbg_sym_data(name_offset) + 2)


int dbg_sym_size(int name_offset):
	return load_int(table + dbg_sym_data(name_offset) + 14)


int dbg_sym_symtype(int name_offset):
	return load_int(table + dbg_sym_data(name_offset) + 10)


int dbg_sym_type(int name_offset):
	return load_int(table + dbg_sym_data(name_offset) + 6)


int dbg_sym_visibility(int name_offset):
	return table[dbg_sym_data(name_offset) + 1]


# Name offset of the defined function whose code contains the absolute
# address, or -1. Asm runtime stubs record no length and are not found.
int dbg_function_at(int addr):
	int t = 0
	while (t <= table_pos - 1):
		int name_offset = t
		while (table[t] != 0):
			t = t + 1
		if (table[t + 1] == 'D'):
			if (load_int(table + t + 10) == 2):
				int start = load_int(table + t + 2)
				int size = load_int(table + t + 14)
				if (size > 0):
					if ((addr >= start) & (addr < start + size)):
						return name_offset
		t = next_token(t)
	return -1


# Name offset of the defined global (function or variable) called `name`,
# or -1. sym_lookup returns the LAST match, which is what we want: eval
# helper functions may shadow nothing important.
int dbg_global_find(char* name):
	int t = 0
	int found = -1
	while (t <= table_pos - 1):
		int name_offset = t
		int i = 0
		while ((name[i] == table[t]) & (name[i] != 0)):
			i = i + 1
			t = t + 1
		if ((name[i] == 0) & (table[t] == 0)):
			if (table[t + 1] == 'D'):
				found = name_offset
		while (table[t] != 0):
			t = t + 1
		t = next_token(t)
	return found


# Function name for an address, or "?" when unknown.
char* dbg_function_name(int addr):
	int f = dbg_function_at(addr)
	if (f < 0):
		return c"?"
	return dbg_sym_name(f)


# Print "did you mean: a, b" for defined functions whose name is close to
# name, when any are close enough. No newline when nothing matches.
void dbg_suggest_functions(char* name):
	int threshold = dbg_similar_threshold(strlen(name))
	int shown = 0
	int t = 0
	while (t <= table_pos - 1):
		int name_offset = t
		while (table[t] != 0):
			t = t + 1
		if (table[t + 1] == 'D'):
			if (load_int(table + t + 10) == 2):
				char* candidate = table + name_offset
				if (dbg_edit_distance(name, candidate) <= threshold):
					if (shown == 0):
						print(c"did you mean: ")
					else:
						print(c", ")
					print(candidate)
					shown = shown + 1
		t = next_token(t)
	if (shown > 0):
		put_char(10)


# List the debuggee's defined functions with address and size.
void dbg_print_functions():
	int t = 0
	while (t <= table_pos - 1):
		int name_offset = t
		while (table[t] != 0):
			t = t + 1
		if (table[t + 1] == 'D'):
			if (load_int(table + t + 10) == 2):
				char* h = hex(load_int(table + t + 2))
				print(h)
				free(h)
				print(c"  ")
				char* digits = itoa(load_int(table + t + 14))
				print(digits)
				free(digits)
				print(c"\x09")
				println(str_from_cstr(table + name_offset))
		t = next_token(t)
