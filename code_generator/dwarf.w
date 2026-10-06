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
	if (debug_files == 0): debug_files = malloc(256 * __word_size__)


char* debug_file_name(int index):
	if ((index < 0) || (index >= debug_file_count)): return c""
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
	if (debug_file_count >= 256): return 0
	save_ptr(debug_files + debug_file_count * __word_size__, cast(int, strclone(filename)))
	debug_last_file = debug_file_count
	debug_file_count = debug_file_count + 1
	return debug_last_file


# Record that the code being generated at codepos comes from filename:line.
# stmt_stack_pos is the symbol table's stack_pos at the statement's start,
# passed in by the caller because this file is compiled before the symbol
# table module and cannot reference its globals directly.
void debug_line_note(int stmt_stack_pos):
	# Device (PTX) bodies do not advance codepos, so address-keyed line
	# records would pile up at the same host position: skip them.
	if (target_isa == 3): return;
	debug_files_ensure()
	if (debug_line_addresses == 0):
		debug_line_capacity = 65536
		debug_line_addresses = malloc(debug_line_capacity * 4)
		debug_line_lines = malloc(debug_line_capacity * 4)
		debug_line_file_indexes = malloc(debug_line_capacity * 4)
		debug_line_stack_pos = malloc(debug_line_capacity * 4)
	if (debug_line_count >= debug_line_capacity): return;

	int line = line_number + 1
	int file_index = debug_line_file_index()

	if (debug_line_count > 0):
		int prev = debug_line_count - 1
		int prev_line = load_int(debug_line_lines + prev * 4)
		int prev_file = load_int(debug_line_file_indexes + prev * 4)
		# Same source position again: nothing new to record
		if ((prev_line == line) && (prev_file == file_index)): return;
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


void dwarf_variable_note(int local_index, int kind);  /* below */


void debug_local_note(char* name, int slot, int kind, int type):
	# Device (PTX) locals live on the GPU-side stack; the wdbg runtime
	# records are host-only.
	if (target_isa == 3): return;
	if (debug_local_capacity == 0):
		debug_local_capacity = 4096
		debug_local_names = malloc(debug_local_capacity * __word_size__)
		debug_local_slots = malloc(debug_local_capacity * 4)
		debug_local_kinds = malloc(debug_local_capacity * 4)
		debug_local_types = malloc(debug_local_capacity * 4)
		debug_local_addresses = malloc(debug_local_capacity * 4)
	if (debug_local_count >= debug_local_capacity):
		# names holds pointers (word-sized entries); the other four are
		# 4-byte ints. Growing names with the int-array sizes made the
		# new x64 buffer half the needed length, so save_ptr below wrote
		# past the block once the compiler had >4096 locals to record —
		# an ASLR-sensitive heap corruption (build_x64 segfaults).
		# W_DEBUG_ALLOC reports the oldlen mismatch directly.
		int old = debug_local_capacity * 4
		int old_names = debug_local_capacity * __word_size__
		debug_local_capacity = debug_local_capacity * 2
		int x = debug_local_capacity * 4
		int x_names = debug_local_capacity * __word_size__
		debug_local_names = realloc(debug_local_names, old_names, x_names)
		debug_local_slots = realloc(debug_local_slots, old, x)
		debug_local_kinds = realloc(debug_local_kinds, old, x)
		debug_local_types = realloc(debug_local_types, old, x)
		debug_local_addresses = realloc(debug_local_addresses, old, x)
	save_ptr(debug_local_names + debug_local_count * __word_size__, cast(int, strclone(name)))
	save_int(debug_local_slots + debug_local_count * 4, slot)
	save_int(debug_local_kinds + debug_local_count * 4, kind)
	save_int(debug_local_types + debug_local_count * 4, type)
	save_int(debug_local_addresses + debug_local_count * 4, codepos)
	dwarf_variable_note(debug_local_count, kind)
	debug_local_count = debug_local_count + 1


########################## DWARF scope notes (#536) ###########################
# Side tables for .debug_info subprograms, lexical blocks and variables,
# and for the .debug_frame FDEs (code_generator/dwarf_info.w emits them
# at ELF finalisation). The compiler is single pass with no tree, so the
# grammar and backend report each fact once, at the point it is known:
#
#   be_function_define     -> dwarf_function_define (the symbol)
#   be_function_prologue   -> dwarf_function_open   (push fp ; mov fp,sp)
#   be_return*             -> dwarf_leave_note      (each 'leave' on x86/x64)
#   be_function_epilogue   -> dwarf_function_close  (end of the body)
#   statement() blocks     -> dwarf_block_begin / dwarf_block_end
#   function_definition    -> dwarf_params_begin    (parameters come first)
#   debug_local_note       -> dwarf_variable_note   (locals and arguments)
#
# Only functions with a frame-pointer prologue on the native targets are
# described: their frame base is the frame pointer, which every
# variable's slot is addressed from (dwarf_info.w). Functions nested in
# another's prologue/epilogue pair are not described.

# Per function (dwarf_func_stride words): symbol table offset, start
# codepos (the push), body codepos (after mov fp,sp), end codepos,
# argument words, first event, end of events (event numbers), cloned name.
list[int] dwarf_funcs
const int dwarf_func_stride = 8
# Events in compile order, 2 words each: kind ('B' block begin, 'b'
# block end, 'V' variable), and the block or debug_local index.
list[int] dwarf_events
# Per block (3 words): start codepos, end codepos, 1 when the block or a
# nested one declares a variable (empty blocks are not emitted).
list[int] dwarf_blocks
list[int] dwarf_block_stack
# 'leave' positions (2 words): function index, codepos.
list[int] dwarf_leaves
# Parameters are declared before the prologue opens the function, so
# they wait here (debug_local indexes) for the function whose
# definition started at dwarf_params_symbol.
list[int] dwarf_pending_params
int dwarf_params_symbol
int dwarf_define_symbol
char* dwarf_define_name
int dwarf_open_func    /* 1-based index of the open function, 0 = none */
int dwarf_open_depth   /* prologues opened and not yet closed */


void dwarf_notes_ensure():
	if (dwarf_funcs == 0):
		dwarf_funcs = new list[int]
		dwarf_events = new list[int]
		dwarf_blocks = new list[int]
		dwarf_block_stack = new list[int]
		dwarf_leaves = new list[int]
		dwarf_pending_params = new list[int]


# The parser is about to read the parameter list of the function whose
# symbol table offset is symbol.
void dwarf_params_begin(int symbol):
	dwarf_notes_ensure()
	dwarf_pending_params.clear()
	dwarf_params_symbol = symbol


void dwarf_function_define(int symbol, char* name):
	dwarf_define_symbol = symbol
	dwarf_define_name = name


void dwarf_block_begin():
	if ((dwarf_open_func == 0) || (dwarf_open_depth != 1)): return;
	int block = dwarf_blocks.length / 3
	dwarf_blocks.push(codepos)
	dwarf_blocks.push(codepos)
	dwarf_blocks.push(0)
	dwarf_block_stack.push(block)
	dwarf_events.push('B')
	dwarf_events.push(block)


void dwarf_block_end():
	if ((dwarf_open_func == 0) || (dwarf_open_depth != 1)): return;
	if (dwarf_block_stack.length == 0): return;
	int block = dwarf_block_stack.pop()
	dwarf_blocks[block * 3 + 1] = codepos
	dwarf_events.push('b')
	dwarf_events.push(block)


# The prologue starting at start has just been emitted (codepos is the
# body's first instruction).
void dwarf_function_open(int start):
	if ((target_isa != 0) && (target_isa != 1)): return;
	dwarf_notes_ensure()
	dwarf_open_depth = dwarf_open_depth + 1
	if (dwarf_open_depth > 1): return;
	dwarf_funcs.push(dwarf_define_symbol)
	dwarf_funcs.push(start)
	dwarf_funcs.push(codepos)
	dwarf_funcs.push(codepos)
	dwarf_funcs.push(0)
	dwarf_funcs.push(dwarf_events.length / 2)
	dwarf_funcs.push(dwarf_events.length / 2)
	dwarf_funcs.push(cast(int, strclone(dwarf_define_name)))
	dwarf_open_func = dwarf_funcs.length / dwarf_func_stride
	dwarf_block_stack.clear()
	if (dwarf_params_symbol == dwarf_define_symbol):
		for i in range(dwarf_pending_params.length):
			dwarf_events.push('V')
			dwarf_events.push(dwarf_pending_params[i])
	dwarf_pending_params.clear()
	dwarf_params_symbol = -1


void dwarf_function_close():
	if (dwarf_open_depth == 0): return;
	dwarf_open_depth = dwarf_open_depth - 1
	if (dwarf_open_depth > 0): return;
	int record = (dwarf_open_func - 1) * dwarf_func_stride
	dwarf_funcs[record + 3] = codepos
	# Blocks left open (an error path unwound past them) end here
	while (dwarf_block_stack.length > 0): dwarf_block_end()
	dwarf_funcs[record + 6] = dwarf_events.length / 2
	dwarf_open_func = 0


# A framed x86/x64 return: 'leave' is emitted at codepos, 'ret' right
# after it.
void dwarf_leave_note():
	if ((dwarf_open_func == 0) || (dwarf_open_depth != 1)): return;
	dwarf_leaves.push(dwarf_open_func - 1)
	dwarf_leaves.push(codepos)


void dwarf_variable_note(int local_index, int kind):
	dwarf_notes_ensure()
	if ((dwarf_open_func == 0) || (dwarf_open_depth != 1)):
		if (kind == 'A'): dwarf_pending_params.push(local_index)
		return;
	dwarf_events.push('V')
	dwarf_events.push(local_index)
	for i in range(dwarf_block_stack.length):
		dwarf_blocks[dwarf_block_stack[i] * 3 + 2] = 1


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
	if (dwarf_open_func > 0):
		int record = (dwarf_open_func - 1) * dwarf_func_stride
		if (dwarf_funcs[record + 1] == start): dwarf_funcs[record + 4] = arg_words


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
		/* DW_LNE_set_address: the extended-opcode length covers the
		   opcode byte plus one address of the target's word size
		   (5 on 32-bit targets, 9 on 64-bit ones) */
		emit_int8(0)
		emit_int8(1 + word_size)
		emit_int8(2)
		if (target_os == 1):
			# Mach-O: the table rides in __TEXT,__debug_line
			# (code_generator/macho_64.w), so it carries real vmaddrs:
			# __TEXT maps at 0x100000000 with file offset 0, making
			# the address the code offset in the low word and 1 in
			# the high word (as for the nlist values).
			emit_int32(cur_address)
			emit_int32(1)
		else: emit_target_word(cur_address + code_offset)

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


# .debug_info: a single compile unit pointing at the line table. On
# Mach-O the unit starts at code offset text_start (where __text
# begins); ELF units start at the image base and ignore it.
void debug_info_emit_at(int text_start, int text_end):
	int unit_start = codepos
	emit_int32(0) /* unit_length, patched below */
	emit_int16(2) /* DWARF version 2 */
	emit_int32(0) /* offset into .debug_abbrev */
	emit_int8(word_size) /* address_size: the target's word size */
	emit_uleb(1) /* abbrev code 1: the compile unit */
	char* unit_name = c"w"
	if (debug_file_count > 0): unit_name = cast(char*, load_ptr(debug_files))
	emit_string(unit_name) /* DW_AT_name */
	emit_int32(0) /* DW_AT_stmt_list: offset 0 in .debug_line */
	/* DW_FORM_addr fields are address_size (= target word size) wide */
	if (target_os == 1):
		# Mach-O vmaddrs (see debug_line_emit): __TEXT at 0x100000000,
		# so text_start / text_end are the code offsets, high word 1.
		emit_int32(text_start) /* DW_AT_low_pc */
		emit_int32(1)
		emit_int32(text_end) /* DW_AT_high_pc */
		emit_int32(1)
	else:
		emit_target_word(code_offset) /* DW_AT_low_pc */
		emit_target_word(text_end + code_offset) /* DW_AT_high_pc */
	emit_uleb(0) /* end of children */
	save_int(code + unit_start, codepos - unit_start - 4)


void debug_info_emit(int text_end):
	debug_info_emit_at(0, text_end)
