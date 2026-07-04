/*
Local variable and argument inspection for wdbg.

The compiler records a note for every local ('L') and argument ('A')
declaration: name, stack slot, type and declaration codepos
(debug_local_* in code_generator/dwarf.w), plus each statement's stack
depth in the line table and each function's argument word count. Combining
those with the trapped esp reproduces the address arithmetic
sym_get_value() compiles into the debuggee:

	local:    esp + (stack_pos - slot - 1) * 4
	argument: esp + (stack_pos + arg_words - slot + 1) * 4

Struct values point at their lowest stack address, exactly like the
generated code. Addresses are only exact at statement boundaries, which is
where every stop lands.
*/
import debugger.symbols


# Frame description for the current stop, filled by dbg_frame_compute.
int dbg_frame_ok
int dbg_frame_start /* function start, debuggee-relative */
int dbg_frame_end   /* function end, debuggee-relative */
int dbg_frame_stack /* stack_pos at the stopped statement */
int dbg_frame_args  /* argument words of the enclosing function */


void dbg_frame_compute(int stop_addr):
	dbg_frame_ok = 0
	if (dbg_in_debuggee(stop_addr) == 0):
		return;
	int rel = stop_addr - code_offset
	int entry = dbg_find_line(rel)
	if (entry < 0):
		return;
	int f = dbg_function_at(stop_addr)
	if (f < 0):
		return;
	dbg_frame_start = dbg_sym_address(f) - code_offset
	dbg_frame_end = dbg_frame_start + dbg_sym_size(f)
	dbg_frame_stack = dbg_line_stack(entry)
	dbg_frame_args = debug_func_args_at(dbg_frame_start)
	if (dbg_frame_args < 0):
		dbg_frame_args = 0
	dbg_frame_ok = 1


char* dbg_local_name_at(int i):
	return cast(char*, load_int(debug_local_names + i * 4))


int dbg_local_slot(int i):
	return load_int(debug_local_slots + i * 4)


int dbg_local_kind(int i):
	return load_int(debug_local_kinds + i * 4)


int dbg_local_type(int i):
	return load_int(debug_local_types + i * 4)


int dbg_local_decl(int i):
	return load_int(debug_local_addresses + i * 4)


# 1 when note i names a variable that exists at the current stop: declared
# in the enclosing function before the stop address, and (for locals)
# whose stack slot has not been popped yet.
int dbg_local_visible(int i, int rel):
	if (dbg_frame_ok == 0):
		return 0
	int decl = dbg_local_decl(i)
	if ((decl < dbg_frame_start) | (decl >= dbg_frame_end)):
		return 0
	if (decl > rel):
		return 0
	if (dbg_local_kind(i) == 'L'):
		if (dbg_local_slot(i) >= dbg_frame_stack):
			return 0
	return 1


# Note index for `name` at the current stop, or -1. The last visible
# declaration wins, so inner shadowing declarations take precedence.
int dbg_local_find(char* name, int stop_addr):
	dbg_frame_compute(stop_addr)
	if (dbg_frame_ok == 0):
		return -1
	int rel = stop_addr - code_offset
	int best = -1
	int i = 0
	while (i < debug_local_count):
		if (dbg_local_visible(i, rel)):
			if (strcmp(dbg_local_name_at(i), name) == 0):
				best = i
		i = i + 1
	return best


# Runtime address of note i's value, given the trapped esp.
int dbg_local_runtime_addr(int i, int esp):
	int slot = dbg_local_slot(i)
	int type = dbg_local_type(i)
	int k
	if (dbg_local_kind(i) == 'L'):
		k = (dbg_frame_stack - slot - 1) * 4
	else:
		k = (dbg_frame_stack + dbg_frame_args - slot + 1) * 4
	# Struct values span several words; point at the lowest address so
	# positive field offsets stay inside, like sym_get_value() does
	if (type_num_args(type) > 0):
		int words = (type_get_size(type) + 3) / 4
		k = k - (words - 1) * 4
	return esp + k


void dbg_print_int_value(int v):
	char* digits = itoa(v)
	print(digits)
	free(digits)
	print(" (")
	char* h = hex(v)
	print(h)
	free(h)
	print(")")


# 1 when the type is char* (one level of pointer over char).
int dbg_type_is_string(int type):
	if (type_get_pointer_level(type) != 1):
		return 0
	return strcmp(type_get_name(type), "char") == 0


# Print the value stored at addr according to its declared type: struct
# values field by field, everything else as one word, with a string
# preview for char*.
void dbg_print_typed_value(int addr, int type):
	if (dbg_mem_readable(addr, 4) == 0):
		print("<unreadable at ")
		char* h = hex(addr)
		print(h)
		free(h)
		print(">")
		return;
	if ((type_get_pointer_level(type) == 0) & (type_num_args(type) > 0)):
		print("{")
		char* t = type_record(type)
		int n = type_num_args(type)
		int i = 0
		while (i < n):
			if (i > 0):
				print(", ")
			print(cast(char*, load_int(t + 16 + 8 * i))) /* field name */
			print(" = ")
			int field_type = type_get_field_type_at(type, i)
			int width = type_get_size(field_type)
			if (width > 4):
				width = 4
			int offset = type_get_field_offset_at(type, i)
			dbg_print_int_value(load_i(addr + offset, width))
			i = i + 1
		print("}")
		return;
	int v = load_int(cast(char*, addr))
	dbg_print_int_value(v)
	if (dbg_type_is_string(type)):
		dbg_print_string_preview(v)


# name = value, for one note.
void dbg_print_local(int i, int esp):
	print(dbg_local_name_at(i))
	print(" = ")
	dbg_print_typed_value(dbg_local_runtime_addr(i, esp), dbg_local_type(i))
	put_char(10)


# info locals ('L') / info args ('A') at the current stop. Shadowed
# declarations (a later visible note with the same name) are skipped.
void dbg_print_frame_vars(int stop_addr, int esp, int kind):
	dbg_frame_compute(stop_addr)
	if (dbg_frame_ok == 0):
		println("no frame info here")
		return;
	int rel = stop_addr - code_offset
	int printed = 0
	int i = 0
	while (i < debug_local_count):
		if (dbg_local_visible(i, rel)):
			if (dbg_local_kind(i) == kind):
				int shadowed = 0
				int j = i + 1
				while (j < debug_local_count):
					if (dbg_local_visible(j, rel)):
						if (strcmp(dbg_local_name_at(i), dbg_local_name_at(j)) == 0):
							shadowed = 1
					j = j + 1
				if (shadowed == 0):
					dbg_print_local(i, esp)
					printed = printed + 1
		i = i + 1
	if (printed == 0):
		if (kind == 'L'):
			println("no locals")
		else:
			println("no args")
