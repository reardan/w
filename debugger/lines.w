/*
Source line table lookups for wdbg.

The in-process compile records (codepos, file, line, stack_pos) for every
statement in the debug_line_* arrays (code_generator/dwarf.w). Addresses
are recorded in increasing order, so lookups scan until they pass the
target. Everything here works on debuggee-relative addresses (rel =
absolute - code_offset).
*/
import compiler.compiler
import debugger.memory


# Index of the last line entry at or before rel, or -1.
int dbg_find_line(int rel):
	int best = -1
	int i = 0
	while (i < debug_line_count):
		if (load_int(debug_line_addresses + i * 4) <= rel):
			best = i
		else:
			return best
		i = i + 1
	return best


int dbg_line_addr(int i):
	return load_int(debug_line_addresses + i * 4)


int dbg_line_line(int i):
	return load_int(debug_line_lines + i * 4)


int dbg_line_file(int i):
	return load_int(debug_line_file_indexes + i * 4)


int dbg_line_stack(int i):
	return load_int(debug_line_stack_pos + i * 4)


char* dbg_file_name(int file_index):
	if ((file_index < 0) || (file_index >= debug_file_count)):
		return c"?"
	return cast(char*, load_ptr(debug_files + file_index * __word_size__))


# 1 when the absolute address lies inside the debuggee's code buffer.
int dbg_in_debuggee(int addr):
	int rel = addr - code_offset
	if ((rel < 0) || (rel >= codepos)):
		return 0
	return 1


# Registered file index for a name the user typed. Matches the full
# recorded path or any path-separator-aligned suffix of it, so plain
# "debug_fixture.w" finds "/repo/tests/debug_fixture.w".
int dbg_file_index_for(char* name):
	int i = 0
	while (i < debug_file_count):
		char* stored = cast(char*, load_ptr(debug_files + i * __word_size__))
		if (strcmp(stored, name) == 0):
			return i
		if (ends_with(stored, name)):
			int at = strlen(stored) - strlen(name)
			if (at > 0):
				if (stored[at - 1] == '/'):
					return i
		i = i + 1
	return -1


# Levenshtein distance between a and b, for "did you mean" suggestions on
# an unresolved break/log target.
int dbg_edit_distance(char* a, char* b):
	int la = strlen(a)
	int lb = strlen(b)
	char* d = malloc((la + 1) * (lb + 1) * 4)
	int i = 0
	while (i <= la):
		save_int(d + i * (lb + 1) * 4, i)
		i = i + 1
	int j = 0
	while (j <= lb):
		save_int(d + j * 4, j)
		j = j + 1
	i = 1
	while (i <= la):
		j = 1
		while (j <= lb):
			int cost = 1
			if (a[i - 1] == b[j - 1]):
				cost = 0
			int del = load_int(d + ((i - 1) * (lb + 1) + j) * 4) + 1
			int ins = load_int(d + (i * (lb + 1) + j - 1) * 4) + 1
			int sub = load_int(d + ((i - 1) * (lb + 1) + j - 1) * 4) + cost
			int best = del
			if (ins < best):
				best = ins
			if (sub < best):
				best = sub
			save_int(d + (i * (lb + 1) + j) * 4, best)
			j = j + 1
		i = i + 1
	int result = load_int(d + (la * (lb + 1) + lb) * 4)
	free(d)
	return result


# How many edits still count as "similar" for a name of this length.
int dbg_similar_threshold(int len):
	if (len <= 3):
		return 1
	if (len <= 6):
		return 2
	return 3


# Trailing path component: what a user is likely to type for a file.
char* dbg_basename(char* path):
	int i = strlen(path)
	while (i > 0):
		if (path[i - 1] == '/'):
			return path + i
		i = i - 1
	return path


# Print "did you mean: a, b" for registered files whose basename is close
# to name, when any are close enough. No newline when nothing matches.
void dbg_suggest_files(char* name):
	char* base = dbg_basename(name)
	int threshold = dbg_similar_threshold(strlen(base))
	int shown = 0
	int i = 0
	while (i < debug_file_count):
		char* stored = cast(char*, load_ptr(debug_files + i * __word_size__))
		if (dbg_edit_distance(base, dbg_basename(stored)) <= threshold):
			if (shown == 0):
				print(c"did you mean: ")
			else:
				print(c", ")
			print(stored)
			shown = shown + 1
		i = i + 1
	if (shown > 0):
		put_char(10)


# Entry index of the first statement at or after file:line, or -1 when the
# file has no code there. Prefers the exact line, else the closest one
# after it (so a breakpoint on a comment slides down to real code).
int dbg_entry_for_line(int file_index, int line):
	int best = -1
	int best_line = 0
	int i = 0
	while (i < debug_line_count):
		if (load_int(debug_line_file_indexes + i * 4) == file_index):
			int l = load_int(debug_line_lines + i * 4)
			if (l >= line):
				if ((best < 0) || (l < best_line)):
					best = i
					best_line = l
		i = i + 1
	return best


# Print "file:line" for an absolute address (no newline).
void dbg_print_file_line(int addr):
	if (dbg_in_debuggee(addr) == 0):
		print(c"outside the debuggee")
		return;
	int i = dbg_find_line(addr - code_offset)
	if (i < 0):
		print(c"no line info")
		return;
	print(dbg_file_name(dbg_line_file(i)))
	print(c":")
	char* digits = itoa(dbg_line_line(i))
	print(digits)
	free(digits)


# Print source lines [first, last] of a file with line numbers, marking
# 'current' with an arrow. Reads the file the compiler recorded, which is
# an absolute path, so this works from any working directory.
void dbg_print_source_range(char* path, int first, int last, int current):
	int f = open(path, 0, 0)
	if (f < 0):
		print(c"cannot open ")
		println(path)
		return;
	getchar_reset(f)
	if (first < 1):
		first = 1
	int line = 1
	int c = getchar(f)
	while ((c != -1) && (line <= last)):
		if (line >= first):
			if (line == current):
				print(c"-> ")
			else:
				print(c"   ")
			char* digits = itoa(line)
			print(digits)
			free(digits)
			print(c"\x09")
		while ((c != 10) && (c != -1)):
			if (line >= first):
				put_char(c)
			c = getchar(f)
		if (line >= first):
			put_char(10)
		if (c == 10):
			c = getchar(f)
		line = line + 1
	close(f)


# The single source line for an absolute address, arrow included.
void dbg_print_source_at(int addr):
	if (dbg_in_debuggee(addr) == 0):
		return;
	int i = dbg_find_line(addr - code_offset)
	if (i < 0):
		return;
	int line = dbg_line_line(i)
	dbg_print_source_range(dbg_file_name(dbg_line_file(i)), line, line, line)
