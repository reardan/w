/*
DWARF 2 line-number information.

While the grammar parses statements it calls debug_line_note(), which records
(codepos, source line, source file). emit_debugging_symbols() later calls the
debug_*_emit() functions to write .debug_line, .debug_abbrev and .debug_info
section payloads, so gdb can map addresses back to source lines.
*/
import code_generator.code_emitter
import lib.lib


# Parallel arrays of recorded mappings (raw word buffers).
char* debug_line_addresses
char* debug_line_lines
char* debug_line_file_indexes
int debug_line_count
int debug_line_capacity

# Stack depth (in words, relative to function entry) at each statement's
# first instruction. The debugger uses it to address stack variables and
# to unwind call frames at runtime; it is never emitted into the ELF.
char* debug_line_stack_pos

# Registered source files (cloned names; index = DWARF file number - 1).
char* debug_files
int debug_file_count
int debug_last_file


# The file registry is also used for declaration locations (symbol/type
# tables), which can be recorded before the first debug_line_note().
void debug_files_ensure():
	if (debug_files == 0):
		debug_files = malloc(256 * __word_size__)


char* debug_file_name(int index):
	if ((index < 0) || (index >= debug_file_count)):
		return c""
	return cast(char*, load_ptr(debug_files + index * __word_size__))


int debug_line_file_index():
	debug_files_ensure()
	# Fast path: the same file as the previous statement
	if (debug_file_count > 0):
		char* last = cast(char*, load_ptr(debug_files + debug_last_file * __word_size__))
		if (strcmp(last, filename) == 0):
			return debug_last_file
	int i = 0
	while (i < debug_file_count):
		char* name = cast(char*, load_ptr(debug_files + i * __word_size__))
		if (strcmp(name, filename) == 0):
			debug_last_file = i
			return i
		i = i + 1
	if (debug_file_count >= 256):
		return 0
	save_ptr(debug_files + debug_file_count * __word_size__, cast(int, strclone(filename)))
	debug_last_file = debug_file_count
	debug_file_count = debug_file_count + 1
	return debug_last_file


# Record that the code being generated at codepos comes from filename:line.
# stmt_stack_pos is the symbol table's stack_pos at the statement's start,
# passed in by the caller because this file is compiled before the symbol
# table module and cannot reference its globals directly.
void debug_line_note(int stmt_stack_pos):
	debug_files_ensure()
	if (debug_line_addresses == 0):
		debug_line_capacity = 65536
		debug_line_addresses = malloc(debug_line_capacity * 4)
		debug_line_lines = malloc(debug_line_capacity * 4)
		debug_line_file_indexes = malloc(debug_line_capacity * 4)
		debug_line_stack_pos = malloc(debug_line_capacity * 4)
	if (debug_line_count >= debug_line_capacity):
		return;

	int line = line_number + 1
	int file_index = debug_line_file_index()

	if (debug_line_count > 0):
		int prev = debug_line_count - 1
		int prev_line = load_int(debug_line_lines + prev * 4)
		int prev_file = load_int(debug_line_file_indexes + prev * 4)
		# Same source position again: nothing new to record
		if ((prev_line == line) && (prev_file == file_index)):
			return;
		# Same address: the earlier statement produced no code, replace it
		if (load_int(debug_line_addresses + prev * 4) == codepos):
			save_int(debug_line_lines + prev * 4, line)
			save_int(debug_line_file_indexes + prev * 4, file_index)
			save_int(debug_line_stack_pos + prev * 4, stmt_stack_pos)
			return;

	save_int(debug_line_addresses + debug_line_count * 4, codepos)
	save_int(debug_line_lines + debug_line_count * 4, line)
	save_int(debug_line_file_indexes + debug_line_count * 4, file_index)
	save_int(debug_line_stack_pos + debug_line_count * 4, stmt_stack_pos)
	debug_line_count = debug_line_count + 1


############################ runtime variable notes ############################
# In-memory records for the in-process debugger (wdbg): where each local
# variable and argument lives relative to the stack pointer, and how many
# argument words each function was compiled with. Nothing here is emitted
# into the ELF; the arrays only matter when the compiler and the debuggee
# share a process (the repl/wdbg model).

# Locals and arguments: name, stack slot index (the value sym_declare
# stores), kind ('L' local / 'A' argument), type table index, and the
# codepos at the declaration site (for picking the innermost shadowing
# declaration and for scoping names to their function).
char* debug_local_names
char* debug_local_slots
char* debug_local_kinds
char* debug_local_types
char* debug_local_addresses
int debug_local_count
int debug_local_capacity


void debug_local_note(char* name, int slot, int kind, int type):
	if (debug_local_capacity == 0):
		debug_local_capacity = 4096
		debug_local_names = malloc(debug_local_capacity * __word_size__)
		debug_local_slots = malloc(debug_local_capacity * 4)
		debug_local_kinds = malloc(debug_local_capacity * 4)
		debug_local_types = malloc(debug_local_capacity * 4)
		debug_local_addresses = malloc(debug_local_capacity * 4)
	if (debug_local_count >= debug_local_capacity):
		int old = debug_local_capacity * 4
		debug_local_capacity = debug_local_capacity * 2
		int x = debug_local_capacity * 4
		debug_local_names = realloc(debug_local_names, old, x)
		debug_local_slots = realloc(debug_local_slots, old, x)
		debug_local_kinds = realloc(debug_local_kinds, old, x)
		debug_local_types = realloc(debug_local_types, old, x)
		debug_local_addresses = realloc(debug_local_addresses, old, x)
	save_ptr(debug_local_names + debug_local_count * __word_size__, cast(int, strclone(name)))
	save_int(debug_local_slots + debug_local_count * 4, slot)
	save_int(debug_local_kinds + debug_local_count * 4, kind)
	save_int(debug_local_types + debug_local_count * 4, type)
	save_int(debug_local_addresses + debug_local_count * 4, codepos)
	debug_local_count = debug_local_count + 1


# Functions: start codepos and the number of argument words the body was
# compiled with (structs passed by value span several words, so this can
# differ from the declared parameter count in the symbol table).
char* debug_func_starts
char* debug_func_arg_words
int debug_func_count
int debug_func_capacity


void debug_func_note(int start, int arg_words):
	if (debug_func_capacity == 0):
		debug_func_capacity = 1024
		debug_func_starts = malloc(debug_func_capacity * 4)
		debug_func_arg_words = malloc(debug_func_capacity * 4)
	if (debug_func_count >= debug_func_capacity):
		int old = debug_func_capacity * 4
		debug_func_capacity = debug_func_capacity * 2
		int x = debug_func_capacity * 4
		debug_func_starts = realloc(debug_func_starts, old, x)
		debug_func_arg_words = realloc(debug_func_arg_words, old, x)
	save_int(debug_func_starts + debug_func_count * 4, start)
	save_int(debug_func_arg_words + debug_func_count * 4, arg_words)
	debug_func_count = debug_func_count + 1


# Argument words for the function whose body starts at codepos 'start',
# or -1 when unknown (e.g. asm stubs).
int debug_func_args_at(int start):
	int i = 0
	while (i < debug_func_count):
		if (load_int(debug_func_starts + i * 4) == start):
			return load_int(debug_func_arg_words + i * 4)
		i = i + 1
	return -1


void emit_uleb(int v):
	while (1):
		int b = v & 127
		v = v >> 7
		if (v == 0):
			emit_int8(b)
			return;
		emit_int8(b | 128)


void emit_sleb(int v):
	while (1):
		int b = v & 127
		v = v >> 7
		if ((v == 0) && ((b & 64) == 0)):
			emit_int8(b)
			return;
		if ((v == -1) && ((b & 64) != 0)):
			emit_int8(b)
			return;
		emit_int8(b | 128)


# .debug_line: header with the file table, then one line program sequence.
void debug_line_emit():
	int unit_start = codepos
	emit_int32(0) /* unit_length, patched below */
	emit_int16(2) /* DWARF version 2 */
	int header_length_pos = codepos
	emit_int32(0) /* header_length, patched below */
	emit_int8(1) /* minimum_instruction_length */
	emit_int8(1) /* default_is_stmt */
	emit_int8(1) /* line_base */
	emit_int8(1) /* line_range */
	emit_int8(10) /* opcode_base: only standard opcodes 1-9 are used */
	/* standard_opcode_lengths for opcodes 1..9 */
	emit(9, c"\x00\x01\x01\x01\x01\x00\x00\x00\x01")
	emit_int8(0) /* include_directories: empty */
	int i = 0
	while (i < debug_file_count):
		char* name = cast(char*, load_ptr(debug_files + i * __word_size__))
		emit_string(name)
		emit_uleb(0) /* directory index */
		emit_uleb(0) /* mtime */
		emit_uleb(0) /* file length */
		i = i + 1
	emit_int8(0) /* end of file table */
	save_int(code + header_length_pos, codepos - header_length_pos - 4)

	if (debug_line_count > 0):
		# State machine registers start at file=1, line=1, address=0
		int cur_file = 1
		int cur_line = 1
		int cur_address = load_int(debug_line_addresses)
		/* DW_LNE_set_address */
		emit(2, c"\x00\x05")
		emit_int8(2)
		emit_int32(cur_address + code_offset)

		i = 0
		while (i < debug_line_count):
			int address = load_int(debug_line_addresses + i * 4)
			int line = load_int(debug_line_lines + i * 4)
			int file_number = load_int(debug_line_file_indexes + i * 4) + 1
			if (file_number != cur_file):
				emit_int8(4) /* DW_LNS_set_file */
				emit_uleb(file_number)
				cur_file = file_number
			if (address != cur_address):
				emit_int8(2) /* DW_LNS_advance_pc */
				emit_uleb(address - cur_address)
				cur_address = address
			if (line != cur_line):
				emit_int8(3) /* DW_LNS_advance_line */
				emit_sleb(line - cur_line)
				cur_line = line
			emit_int8(1) /* DW_LNS_copy */
			i = i + 1

		emit_int8(2) /* DW_LNS_advance_pc */
		emit_uleb(1)

	/* DW_LNE_end_sequence */
	emit(3, c"\x00\x01\x01")
	save_int(code + unit_start, codepos - unit_start - 4)


# .debug_abbrev: one abbreviation - a childless compile unit.
void debug_abbrev_emit():
	emit_uleb(1) /* abbrev code */
	emit_uleb(17) /* DW_TAG_compile_unit */
	emit_int8(0) /* no children */
	emit_uleb(3) /* DW_AT_name */
	emit_uleb(8) /* DW_FORM_string */
	emit_uleb(16) /* DW_AT_stmt_list */
	emit_uleb(6) /* DW_FORM_data4 */
	emit_uleb(17) /* DW_AT_low_pc */
	emit_uleb(1) /* DW_FORM_addr */
	emit_uleb(18) /* DW_AT_high_pc */
	emit_uleb(1) /* DW_FORM_addr */
	emit_uleb(0)
	emit_uleb(0)
	emit_int8(0) /* end of abbreviations */


# .debug_info: a single compile unit pointing at the line table.
void debug_info_emit(int text_end):
	int unit_start = codepos
	emit_int32(0) /* unit_length, patched below */
	emit_int16(2) /* DWARF version 2 */
	emit_int32(0) /* offset into .debug_abbrev */
	emit_int8(4) /* address size */
	emit_uleb(1) /* abbrev code 1: the compile unit */
	char* unit_name = c"w"
	if (debug_file_count > 0):
		unit_name = cast(char*, load_ptr(debug_files))
	emit_string(unit_name) /* DW_AT_name */
	emit_int32(0) /* DW_AT_stmt_list: offset 0 in .debug_line */
	emit_int32(code_offset) /* DW_AT_low_pc */
	emit_int32(text_end + code_offset) /* DW_AT_high_pc */
	emit_uleb(0) /* end of children */
	save_int(code + unit_start, codepos - unit_start - 4)
