# --c-abi (with --emit=obj --freestanding, x64): W functions and function
# pointers that C and assembly can use directly
# (docs/projects/object_files.md, "The C ABI mode").
#
# Direct W-to-W calls keep W's stack convention. Every function defined
# through be_function_define gets a 5-byte System V entry right before
# its W entry:
#
#   entry - 5:  jmp adapter      (patched by c_abi_emit_adapters)
#   entry:      the W function
#
# and c_abi_emit_adapters, after the last function, emits each adapter:
# System V arguments (rdi, rsi, rdx, rcx, r8, r9, xmm0-7, then the
# stack) pushed as W stack words, the W function called, the System V
# callee-saved registers preserved. A function's address taken as a
# value is entry - 5, so every function pointer is a System V pointer,
# and a call through a function-pointer value uses the System V
# convention (c_abi_indirect_call). An extern C function's address is
# the C symbol itself, read from its relocated import slot. Root-file
# functions not marked 'static' (and 'export'ed ones) are global
# symbols bound to their stubs (elf_object.w), so a C pointer to a W
# function compares equal to the one W hands out.
#
# This file is compiled by the committed seed: only seed-understood
# syntax here.
import code_generator.code_emitter
import code_generator.ffi
import code_generator.static_link

int object_file_is_root(int file_index);   /* code_generator/elf_object.w */
int object_symbol_is_alias(int t);
void object_note_rel32(int pos);


# Functions with a System V entry stub, in definition order: the symbol
# and the buffer offset of the stub's jmp. c_abi_stub_index maps a
# symbol to its index + 1.
list[int] c_abi_stub_syms
list[int] c_abi_stub_positions
map[int, int] c_abi_stub_index
# Functions whose address became a value: each must end up with a
# stub and a supported signature (checked by c_abi_emit_adapters).
list[int] c_abi_taken_syms
# Functions bound to global symbols, in definition order.
list[int] c_abi_global_syms
list[char*] c_abi_global_names
map[int, int] c_abi_global_index
# Static pointer cells holding an extern C function's address: the cell
# and the function's import slot (relocated against the C symbol).
list[int] c_abi_extern_cells
list[int] c_abi_extern_slots
# Each stub's adapter (or trap) code range, in stub order, for the
# object writer to place it with its function (elf_object.w).
list[int] c_abi_adapter_starts
list[int] c_abi_adapter_ends
# Globals and functions marked 'static': local symbols in an object.
map[int, int] object_static_symbols


void c_abi_reset():
	c_abi_stub_syms = 0
	object_static_symbols = 0


void c_abi_init():
	if (cast(int, c_abi_stub_syms) != 0): return
	c_abi_stub_syms = new list[int]
	c_abi_stub_positions = new list[int]
	c_abi_stub_index = new map[int, int]
	c_abi_taken_syms = new list[int]
	c_abi_global_syms = new list[int]
	c_abi_global_names = new list[char*]
	c_abi_global_index = new map[int, int]
	c_abi_extern_cells = new list[int]
	c_abi_extern_slots = new list[int]
	c_abi_adapter_starts = new list[int]
	c_abi_adapter_ends = new list[int]


# 'static int f(...)' / 'static int g': a file-local symbol.
void object_note_static(int t):
	if (cast(int, object_static_symbols) == 0): object_static_symbols = new map[int, int]
	object_static_symbols[t] = 1


int object_symbol_is_static(int t):
	if (cast(int, object_static_symbols) == 0): return 0
	return object_static_symbols.get(t, 0)


# be_function_define, right before the symbol is defined: the System V
# entry stub (its jmp displacement is patched once the adapter exists).
void c_abi_function_entry(int t):
	if (c_abi_mode == 0): return
	c_abi_init()
	if (c_abi_stub_index.get(t, 0) != 0): error3(c"internal error: --c-abi function '", sym_record_name(t), c"' defined twice")
	c_abi_stub_syms.push(t)
	c_abi_stub_positions.push(codepos)
	c_abi_stub_index[t] = c_abi_stub_syms.length
	emit_int8(0xe9)   # jmp rel32
	emit_int32(0)
	# the jmp leaves the function's section when it has one
	if (elf_object): object_note_rel32(codepos - 4)


# 1 when t is a struct (or union) passed by value.
int c_abi_type_is_aggregate(int type):
	if (type < 0): return 0
	if (type_get_pointer_level(type) > 0): return 0
	if (type_num_args(type) > 0): return 1
	return type_stack_words(type) != 1


# Why function t cannot have a System V entry, or 0 when it can.
char* c_abi_signature_problem(int t):
	if (sym_is_generator(t)): return c"' is a generator, which has no System V entry"
	if (sym_w_variadic_fixed_args(t) >= 0): return c"' is variadic, which --c-abi does not support yet"
	int n = sym_num_args(t)
	if (n > sym_max_param_slots): return c"' has more than 10 parameters, which --c-abi does not support"
	int ret_type = load_int(table + t + 6)
	if ((ret_type != 4) && c_abi_type_is_aggregate(ret_type)):
		return c"' returns a struct by value, which --c-abi does not support yet"
	for i in range(n):
		if (c_abi_type_is_aggregate(sym_param_type(t, i))):
			return c"' takes a struct by value, which --c-abi does not support yet"
	return 0


void c_abi_check_signature(int t):
	if (sym_num_args(t) < 0): return
	char* problem = c_abi_signature_problem(t)
	if (problem != 0): error3(c"function '", sym_record_name(t), problem)


# A function definition just parsed (grammar/program.w). Root-file
# functions not marked 'static', and 'export'ed ones, become global
# symbols at their System V entries.
void c_abi_definition_note(int t, char* name, int exported, int is_static):
	if (table[t + 1] != 'D'): return
	c_abi_init()
	# An '@alias' prototype shares its target's entry; its global symbol
	# is the object writer's (elf_object.w).
	if (object_symbol_is_alias(t)): return
	if (is_static): object_note_static(t)
	if (is_static || (c_abi_global_index.get(t, 0) != 0)): return
	if ((exported == 0) && (object_file_is_root(decl_file_index()) == 0)): return
	char* problem = c_abi_signature_problem(t)
	if (problem != 0): error3(c"function '", name, problem)
	c_abi_global_syms.push(t)
	c_abi_global_names.push(strclone(name))
	c_abi_global_index[t] = c_abi_global_syms.length


# rax = the System V address of function t, for a value use of its name
# ('fp = f', '&f', an argument): the stub before its W entry, or for an
# extern C function the C symbol, loaded from its import slot.
int c_abi_function_value(int t, char* name):
	c_abi_init()
	int slot = sym_got_vaddr(t)
	if (slot != 0):
		be_addr_slot_emit()
		be_addr_slot_write(codepos - 4, slot)
		emit(3, c"\x48\x8b\x00")   # mov rax,[rax]
		return 4
	if ((table[t + 1] == 'D') && (c_abi_stub_index.get(t, 0) == 0)):
		error3(c"--c-abi cannot take the address of '", sym_record_name(t), c"': it has no System V entry")
	c_abi_check_signature(t)
	sym_emit_value(t, name)
	emit(4, c"\x48\x83\xe8\x05")   # sub rax,5: the System V stub
	c_abi_taken_syms.push(t)
	return 4


# A static address initializer naming function t ('fp = f' at file
# scope, stored into the data cell at vaddr cell): the value to store.
# An extern C function's cell is relocated against its C symbol
# instead (elf_object.w), so it holds 0 here.
int c_abi_static_function_value(int t, int cell):
	c_abi_init()
	int slot = sym_got_vaddr(t)
	if (slot != 0):
		c_abi_extern_cells.push(cell)
		c_abi_extern_slots.push(slot)
		return 0
	if (c_abi_stub_index.get(t, 0) == 0):
		error3(c"--c-abi cannot take the address of '", sym_record_name(t), c"': it has no System V entry")
	c_abi_check_signature(t)
	c_abi_taken_syms.push(t)
	return sym_value_at(t) - 5


# Sign- or zero-extend the narrow integer in rax to a full word, as a
# value of type `type` (System V leaves the upper bits of narrow
# arguments and results unspecified).
void c_abi_extend_rax(int type):
	if (type < 0): return
	if (type_get_pointer_level(type) > 0): return
	if (type_float_kind(type) || (type_num_args(type) > 0)): return
	int size = type_get_size(type)
	int is_unsigned = type_is_unsigned_fixed(type)
	if (size == 1):
		if (is_unsigned): emit(3, c"\x0f\xb6\xc0")   # movzx eax,al
		else: emit(4, c"\x48\x0f\xbe\xc0")   # movsx rax,al
	else if (size == 2):
		if (is_unsigned): emit(3, c"\x0f\xb7\xc0")   # movzx eax,ax
		else: emit(4, c"\x48\x0f\xbf\xc0")   # movsx rax,ax
	else if (size == 4):
		if (is_unsigned): emit(2, c"\x89\xc0")   # mov eax,eax
		else: emit(3, c"\x48\x63\xc0")   # movsxd rax,eax


# A call through a function-pointer value (grammar/postfix_expr.w
# finish_call): rax holds the callee, the passed_args arguments are the
# W stack words above the callee slot s + 1. Converts them to a System V
# call through r11 and leaves the result in rax.
void c_abi_indirect_call(int callee_type, int s, int passed_args, int has_return_buffer, int declared_return):
	if (has_return_buffer || c_abi_type_is_aggregate(declared_return)):
		error(c"--c-abi does not support calls through function pointers that return a struct by value yet")
	int signature = -1
	if (type_get_pointer_level(callee_type) > 0):
		int base = type_lookup_previous_pointer(callee_type)
		if ((base >= 0) && type_is_function_signature(base)): signature = base
	int n = stack_pos - s - 1
	if (n != passed_args):
		error(c"--c-abi does not support passing a struct by value through a function pointer yet")
	char* classes = cast(char*, malloc(n + 1))
	for i in range(n):
		classes[i] = 0
		if ((signature >= 0) && (i < type_function_param_count(signature))):
			int param = type_function_param_type(signature, i)
			if (c_abi_type_is_aggregate(param)):
				error(c"--c-abi does not support passing a struct by value through a function pointer yet")
			classes[i] = ffi_type_class(param)
	int ret_class = 0
	if (declared_return >= 0): ret_class = ffi_type_class(declared_return)
	emitted_call_count = emitted_call_count + 1
	# The arguments must all be real stack words, and loop-owned
	# registers survive the callee in their homes (as call_eax does).
	if (ers_count != 0): ers_spill_all()
	inline_real_calls = inline_real_calls + 1
	regalloc_call_spill()
	emit(3, c"\x49\x89\xc3")   # mov r11,rax
	emit_c_abi_call_x64(n, classes, ret_class, 0, 8)
	regalloc_call_reload()
	if (ret_class == 0): c_abi_extend_rax(declared_return)
	free(classes)


# mov rax,<System V argument register 0..5>
void c_abi_mov_rax_arg(int reg):
	if (reg == 0): emit(3, c"\x48\x89\xf8")   # rdi
	else if (reg == 1): emit(3, c"\x48\x89\xf0")   # rsi
	else if (reg == 2): emit(3, c"\x48\x89\xd0")   # rdx
	else if (reg == 3): emit(3, c"\x48\x89\xc8")   # rcx
	else if (reg == 4): emit(3, c"\x4c\x89\xc0")   # r8
	else: emit(3, c"\x4c\x89\xc8")   # r9


# The System V adapter of function t whose W entry is `entry`: like the
# export adapters (elf_exports.w), plus the narrow-integer extension of
# each argument to the word the W callee expects.
void c_abi_emit_adapter(int t, int entry):
	int n = sym_num_args(t)
	if (n < 0): n = 0
	char* classes = cast(char*, malloc(n + 1))
	for i in range(n): classes[i] = ffi_type_class(sym_param_type(t, i))
	char* slots = ffi_assign_slots(n, classes, 6)
	emit(4, c"\x55\x48\x89\xe5")   # push rbp; mov rbp,rsp
	push_reg(3)
	for r in range(12, 16): push_reg(r)
	int spilled = 0
	for i in range(n):
		int slot = load_int(slots + i * 4)
		if (slot < 0):
			# Stack arguments follow the saved rbp and the return address.
			emit(3, c"\x48\x8b\x85")   # mov rax,[rbp+disp32]
			emit_int32(16 + spilled * 8)
			spilled = spilled + 1
		else if (slot >= 16):
			emit(4, c"\x66\x48\x0f\x7e")   # movq rax,xmmN
			emit_int8(0xc0 | ((slot - 16) << 3))
		else: c_abi_mov_rax_arg(slot)
		if (classes[i] == 0): c_abi_extend_rax(sym_param_type(t, i))
		push_reg(0)
	emit_int8(0xe8)   # call the W entry
	emit_int32(entry - code_offset - codepos - 4)
	if (elf_object): object_note_rel32(codepos - 4)
	if (n > 0):
		emit(3, c"\x48\x83\xc4")   # add rsp,8n
		emit_int8(n * 8)
	for r in range(4): pop_reg(15 - r)
	pop_reg(3)
	emit_int8(0x5d)   # pop rbp
	int ret_type = load_int(table + t + 6)
	int ret_class = 0
	if (ret_type != 4): ret_class = ffi_type_class(ret_type)
	if (ret_class == 1): emit(4, c"\x66\x0f\x6e\xc0")   # movd xmm0,eax
	if (ret_class == 2): emit(5, c"\x66\x48\x0f\x6e\xc0")   # movq xmm0,rax
	emit_int8(0xc3)
	free(slots)
	free(classes)


# After the last function: every stub's adapter, the stub jumps patched.
# A function whose signature has no System V form (a struct by value,
# ...) jumps to a trap: nothing can reach it, because its address was
# never taken and it is not global (both are diagnosed).
void c_abi_emit_adapters():
	if (c_abi_mode == 0): return
	c_abi_init()
	for i in range(c_abi_taken_syms.length):
		int t = c_abi_taken_syms[i]
		if (c_abi_stub_index.get(t, 0) == 0):
			error3(c"--c-abi cannot take the address of '", sym_record_name(t), c"': it has no System V entry")
		c_abi_check_signature(t)
	int trap = 0
	for k in range(c_abi_stub_syms.length):
		int t = c_abi_stub_syms[k]
		int pos = c_abi_stub_positions[k]
		int adapter = 0
		int adapter_start = codepos
		if (c_abi_signature_problem(t) == 0):
			adapter = code_offset + codepos
			c_abi_emit_adapter(t, code_offset + pos + 5)
		else:
			if (trap == 0):
				trap = code_offset + codepos
				emit(2, c"\x0f\x0b")   # ud2
			adapter = trap
		c_abi_adapter_starts.push(adapter_start)
		c_abi_adapter_ends.push(codepos)
		save_int32(code + pos + 1, adapter - (code_offset + pos + 5))


# The System V entry (stub) address of function t: its global symbol's
# value and every function pointer to it, so C and W compare equal.
int c_abi_has_entry(int t):
	if ((c_abi_mode == 0) || (cast(int, c_abi_stub_syms) == 0)): return 0
	return c_abi_stub_index.get(t, 0) != 0


# An '@alias' symbol t defined as target: it shares the target's entry.
void c_abi_alias_defined(int t, int target):
	if (c_abi_has_entry(target)): c_abi_stub_index[t] = c_abi_stub_index[target]


int c_abi_entry_of(int t):
	return code_offset + c_abi_stub_positions[c_abi_stub_index.get(t, 0) - 1]
