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
where every stop lands. Stack slots are word-sized: 4 bytes on x86, 8 on
x64.

A local the compiler promoted into a callee-saved register (register
promotion, docs/projects/register_allocation_pgo.md §2.2; the note's
register is debug_local_register) has no stack address of its own. In
the stopped frame its value is the register the kernel saved in the
signal frame, so dbg_local_runtime_addr returns the address of that
sigcontext word (reads, 'set' and 'watch' all work on it, and sigreturn
restores a written value). In an outer frame the register was pushed by
the nearest inner frame whose prologue saved it (debug_func_regs_at:
word 2 + i below that frame's return-address slot, i the register's
index in the ascending push order), or it is still live in the stopped
frame when no inner frame saved it. Attach mode has no sigcontext, so
register locals are not addressable there (0).

A local or argument in a caller-saved register (a loop's registers or
the function region of compiler/regalloc_scan.w: x64 rsi rdi r8-r11,
x86 ecx edx) is the sigcontext word in the stopped frame too. In an
outer frame that register was written to the variable's own stack word
before the call (regalloc_call_spill), so there the note's stack slot
holds the value, as for a stack local.
*/
import debugger.symbols
import debugger.registers
import debugger.frames


# Frame description for the current stop, filled by dbg_frame_compute.
int dbg_frame_ok
int dbg_frame_start /* function start, debuggee-relative */
int dbg_frame_end   /* function end, debuggee-relative */
int dbg_frame_stack /* stack_pos at the stopped statement */
int dbg_frame_args  /* argument words of the enclosing function */


void dbg_frame_compute(int stop_addr):
	dbg_frame_ok = 0
	if (dbg_in_debuggee(stop_addr) == 0): return;
	int rel = stop_addr - code_offset
	int entry = dbg_find_line(rel)
	if (entry < 0): return;
	int f = dbg_function_at(stop_addr)
	if (f < 0): return;
	dbg_frame_start = dbg_sym_address(f) - code_offset
	dbg_frame_end = dbg_frame_start + dbg_sym_size(f)
	dbg_frame_stack = dbg_line_stack(entry)
	dbg_frame_args = debug_func_args_at(dbg_frame_start)
	if (dbg_frame_args < 0): dbg_frame_args = 0
	dbg_frame_ok = 1


char* dbg_local_name_at(int i):
	return cast(char*, load_ptr(debug_local_names + i * __word_size__))


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
	if (dbg_frame_ok == 0): return 0
	int decl = dbg_local_decl(i)
	if ((decl < dbg_frame_start) || (decl >= dbg_frame_end)): return 0
	if (decl > rel): return 0
	if (dbg_local_kind(i) == 'L'):
		if (dbg_local_slot(i) >= dbg_frame_stack): return 0
	return 1


# Note index for `name` at the current stop, or -1. The last visible
# declaration wins, so inner shadowing declarations take precedence.
int dbg_local_find(char* name, int stop_addr):
	dbg_frame_compute(stop_addr)
	if (dbg_frame_ok == 0): return -1
	int rel = stop_addr - code_offset
	int best = -1
	int i = 0
	while (i < debug_local_count):
		if (dbg_local_visible(i, rel)):
			if (strcmp(dbg_local_name_at(i), name) == 0): best = i
		i = i + 1
	return best


# sigcontext offset of a register a local may live in, by hardware
# number (x86 esi 6 / edi 7 and the loop registers ecx 1 / edx 2; x64
# r12-r15 and the loop/region registers rsi rdi r8-r11), -1 for anything
# else.
int dbg_reg_sigcontext_offset(int reg):
	if (__word_size__ == 8):
		if ((reg >= 8) && (reg <= 15)): return sigcontext_r8 + (reg - 8) * 8
		if (reg == 6): return sigcontext_esi()
		if (reg == 7): return sigcontext_edi()
		return -1
	if (reg == 6): return sigcontext_esi()
	if (reg == 7): return sigcontext_edi()
	if (reg == 1): return sigcontext_ecx()
	if (reg == 2): return sigcontext_edx()
	return -1


# A caller-saved register (see the header): its value lives in the
# variable's stack word in every frame but the stopped one.
int dbg_reg_caller_saved(int reg):
	if (__word_size__ == 8): return (reg >= 6) && (reg <= 11)
	return (reg == 1) || (reg == 2)


# Address of the word holding register reg's value for the selected
# frame (see the header), 0 when it cannot be located.
int dbg_register_local_addr(int reg):
	int offset = dbg_reg_sigcontext_offset(reg)
	if (offset < 0): return 0
	# Inner frames (newer than the selected one) that saved the register
	int j = dbg_fr_sel - 1
	while (j >= 0):
		int f = dbg_function_at(dbg_fr_pc_at(j))
		if (f >= 0):
			int mask = debug_func_regs_at(dbg_sym_address(f) - code_offset)
			if (mask & (1 << reg)):
				int base = dbg_fr_base_at(j)
				if (base == 0): return 0
				int index = 0
				int r = 0
				while (r < reg):
					if (mask & (1 << r)): index = index + 1
					r = r + 1
				return base - (2 + index) * __word_size__
		j = j - 1
	if (dbg_reg_context == 0): return 0
	return dbg_reg_context + offset


# Runtime address of note i's value, given the trapped esp.
int dbg_local_runtime_addr(int i, int esp):
	int slot = dbg_local_slot(i)
	int type = dbg_local_type(i)
	int reg = debug_local_register(i)
	if ((reg != 0) && ((dbg_reg_caller_saved(reg) == 0) || (dbg_fr_sel == 0))): return dbg_register_local_addr(reg)
	int k
	if (dbg_local_kind(i) == 'L'): k = (dbg_frame_stack - slot - 1) * __word_size__
	else: k = (dbg_frame_stack + dbg_frame_args - slot + 1) * __word_size__
	# Struct values span several words; point at the lowest address so
	# positive field offsets stay inside, like sym_get_value() does
	if (type_num_args(type) > 0):
		int words = (type_get_size(type) + __word_size__ - 1) / __word_size__
		k = k - (words - 1) * __word_size__
	return esp + k


void dbg_print_int_value(int v):
	dbg_print_dec(v)
	print(c" (")
	char* h = hex(v)
	print(h)
	free(h)
	print(c")")


# 1 when the type is char* (one level of pointer over char).
int dbg_type_is_string(int type):
	if (type_get_pointer_level(type) != 1): return 0
	return strcmp(type_get_name(type), c"char") == 0


# Print the value stored at addr according to its declared type: struct
# values field by field, everything else as one word, with a string
# preview for char*.
void dbg_print_typed_value(int addr, int type):
	if (dbg_mem_readable(addr, __word_size__) == 0):
		print(c"<unreadable at ")
		dbg_print_hex(addr)
		print(c">")
		return;
	if ((type_get_pointer_level(type) == 0) & (type_num_args(type) > 0)):
		print(c"{")
		int n = type_num_args(type)
		for i in range(n):
			if (i > 0): print(c", ")
			# Through the accessor, not a hand-computed offset: the old
			# 'load_int(t + 16 + 8 * i)' spelled the field-name slot with
			# 4-byte strides, so it only landed correctly on a 32-bit host.
			print(str_from_cstr(type_get_field_name_at(type, i)))
			print(c" = ")
			int field_type = type_get_field_type_at(type, i)
			int width = type_get_size(field_type)
			if (width > __word_size__): width = __word_size__
			int offset = type_get_field_offset_at(type, i)
			dbg_print_int_value(dbg_mem_read(addr + offset, width))
		print(c"}")
		return;
	int v = dbg_mem_read_word(addr)
	dbg_print_int_value(v)
	if (dbg_type_is_string(type)): dbg_print_string_preview(v)


# name = value, for one note.
void dbg_print_local(int i, int esp):
	print(str_from_cstr(dbg_local_name_at(i)))
	print(c" = ")
	dbg_print_typed_value(dbg_local_runtime_addr(i, esp), dbg_local_type(i))
	put_char(10)


# info locals ('L') / info args ('A') at the current stop. Shadowed
# declarations (a later visible note with the same name) are skipped.
void dbg_print_frame_vars(int stop_addr, int esp, int kind):
	dbg_frame_compute(stop_addr)
	if (dbg_frame_ok == 0):
		println(c"no frame info here")
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
						if (strcmp(dbg_local_name_at(i), dbg_local_name_at(j)) == 0): shadowed = 1
					j = j + 1
				if (shadowed == 0):
					dbg_print_local(i, esp)
					printed = printed + 1
		i = i + 1
	if (printed == 0):
		if (kind == 'L'): println(c"no locals")
		else: println(c"no args")
