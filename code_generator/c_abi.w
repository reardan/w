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
void sse_kernel_reject();   /* code_generator/sse.w */
void stack_usage_c_abi_adapter(int symbol, int words);   /* code_generator/stack_usage.w */
void stack_usage_extra(int words);
int object_symbol_is_alias(int t);
int object_name_is_weak(char* name);
int object_weak_count();
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
# 'extern T[] name' pointer cells (linkage_ast.w): W globals that are
# no symbols of the object.
map[int, int] object_extern_pointer_symbols
# Static address cells naming a global ('&x', '&x + n' in a global
# initializer): cell vaddr -> the vaddr of x itself. The relocation binds
# to x (its piece, or for extern data its symbol) even when the offset
# leaves x (one past the end of an array, C's 'a + N'), and an
# 'extern T[]' name means the C array, not W's pointer cell.
map[int, int] object_address_bases


# 1 under 'w check' (no code is kept): C-variadic definitions need no
# --c-abi there, unsized extern arrays no --emit=obj.
int c_abi_check_only


void c_abi_reset():
	c_abi_stub_syms = 0
	sym_wide_param_types = 0
	object_static_symbols = 0
	object_extern_pointer_symbols = 0
	object_address_bases = 0


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


void object_note_extern_pointer(int t):
	if (cast(int, object_extern_pointer_symbols) == 0): object_extern_pointer_symbols = new map[int, int]
	object_extern_pointer_symbols[t] = 1


void object_note_address_base(int cell, int base):
	if (cast(int, object_address_bases) == 0): object_address_bases = new map[int, int]
	object_address_bases[cell] = base


# The global a static address cell names (its vaddr), or 0.
int object_address_base_at(int cell):
	if (cast(int, object_address_bases) == 0): return 0
	return object_address_bases.get(cell, 0)


int object_symbol_is_extern_pointer(int t):
	if (cast(int, object_extern_pointer_symbols) == 0): return 0
	return object_extern_pointer_symbols.get(t, 0)


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


# 1 when t is a struct (or union) passed by value, or another value
# wider than a word.
int c_abi_type_is_aggregate(int type):
	if (type < 0): return 0
	if (type_get_pointer_level(type) > 0): return 0
	if (type_num_args(type) > 0): return 1
	return type_stack_words(type) != 1


# 1 when t is a by-value struct or union: W passes its words on the
# stack and returns it through a hidden buffer, System V classifies it.
int c_abi_type_is_record(int type):
	if (type < 0): return 0
	if (type_get_pointer_level(type) > 0): return 0
	return type_num_args(type) > 0


# A by-value value with no System V form: wider than a word but not a
# record (W's own multi-word values).
int c_abi_type_unsupported(int type):
	return c_abi_type_is_aggregate(type) && (c_abi_type_is_record(type) == 0)


# W stack words of an argument of this type (-1: one word).
int c_abi_arg_words(int type):
	if (c_abi_type_is_record(type)): return type_stack_words(type)
	return 1


# 1 for a C-variadic definition ('int f(int n, ... va)'): its last
# parameter is the va_list its System V entry builds.
int c_abi_is_c_variadic_definition(int t):
	return (sym_variadic_fixed_args(t) >= 0) && (sym_got_vaddr(t) == 0)


# Why function t cannot have a System V entry, or 0 when it can.
char* c_abi_signature_problem(int t):
	if (sym_is_generator(t)): return c"' is a generator, which has no System V entry"
	if (sym_w_variadic_fixed_args(t) >= 0): return c"' is W-variadic (T... name), which has no System V entry; declare a C-variadic '...' parameter instead"
	int n = sym_num_args(t)
	int ret_type = load_int(table + t + 6)
	if ((ret_type != 4) && c_abi_type_unsupported(ret_type)):
		return c"' returns a multi-word value that is not a struct, which --c-abi does not support"
	for i in range(n):
		if (c_abi_type_unsupported(sym_param_type_wide(t, i))):
			return c"' takes a multi-word value that is not a struct, which --c-abi does not support"
	return 0


void c_abi_check_signature(int t):
	if (sym_num_args(t) < 0): return
	char* problem = c_abi_signature_problem(t)
	if (problem != 0): error3(c"function '", sym_record_name(t), problem)


# 'int f(int n, ... va):' just parsed (grammar/program.w): calls pass
# the arguments after the fixed ones the C way, through its System V
# entry. Only --c-abi gives it one ('w check' accepts it regardless).
void c_variadic_definition_note(int t, int fixed):
	if ((c_abi_mode == 0) && (c_abi_check_only == 0)):
		error(c"a C-variadic definition ('...') requires --c-abi")
	sym_set_variadic(t, fixed)


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


# 1 when a call of W function t binds through its symbol: --c-abi
# object code calling a weak definition (one declared '@weak' before
# the call) goes through the System V entry its symbol names, so a
# strong definition elsewhere in the link wins. The callee value is
# c_abi_function_value's and finish_call makes a System V call; direct
# W calls, inlining and register calls would bind the local body.
int c_abi_calls_through_symbol(int t):
	if ((c_abi_mode == 0) || (elf_object == 0) || (t < 0)): return 0
	if (object_weak_count() == 0): return 0
	if ((table[t + 1] != 'D') && (table[t + 1] != 'U')): return 0
	if ((load_int(table + t + 10) != 2) || (sym_got_vaddr(t) != 0)): return 0
	return object_name_is_weak(sym_record_name(t))


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


############################ System V aggregates #############################
# The x86-64 psABI classification of a by-value struct or union: up to
# 16 bytes it travels in one or two eightbytes, each INTEGER (a general
# register) or SSE (an xmm register) -- INTEGER when any integer or
# pointer byte shares it; anything larger, or with an unaligned field,
# is MEMORY (copied to the stack, or for a result written through a
# hidden pointer the caller passes in rdi and the callee returns in rax).
# Under --kernel-codegen an SSE eightbyte is rejected like any float.

# c_abi_classify's result: the eightbytes' classes (0 INTEGER, 1 SSE,
# -1 padding only).
int c_abi_eb0
int c_abi_eb1
int c_abi_eb_unaligned


void c_abi_mark(int offset, int size, int sse):
	if (size <= 0): return
	int last = (offset + size - 1) >> 3
	for k in range(offset >> 3, last + 1):
		if (k == 0):
			if (sse == 0): c_abi_eb0 = 0
			else if (c_abi_eb0 < 0): c_abi_eb0 = 1
		else if (k == 1):
			if (sse == 0): c_abi_eb1 = 0
			else if (c_abi_eb1 < 0): c_abi_eb1 = 1


void c_abi_classify_at(int type, int offset, int depth):
	if (type < 0): return
	type = type_unqualified(type)
	int size = type_get_size(type)
	if ((type_get_pointer_level(type) == 0) && (type_num_args(type) > 0) && (depth < 32)):
		for i in range(type_num_args(type)):
			c_abi_classify_at(type_get_field_type_at(type, i), offset + type_get_field_offset_at(type, i), depth + 1)
		return
	int sse = 0
	if ((type_get_pointer_level(type) == 0) && (type_is_array(type) == 0)):
		sse = type_float_kind(type) != 0
		int align = size
		if (align > 8): align = 8
		if ((align == 2) || (align == 4) || (align == 8)):
			if ((offset & (align - 1)) != 0): c_abi_eb_unaligned = 1
	else if ((offset & 7) != 0): c_abi_eb_unaligned = 1
	c_abi_mark(offset, size, sse)


# The eightbytes a record passes in registers (1 or 2, classes in
# c_abi_eb0/c_abi_eb1), or 0 when it is MEMORY.
int c_abi_classify(int type):
	int size = type_get_size(type)
	if ((size <= 0) || (size > 16)): return 0
	c_abi_eb0 = -1
	c_abi_eb1 = -1
	c_abi_eb_unaligned = 0
	c_abi_classify_at(type, 0, 0)
	if (c_abi_eb_unaligned): return 0
	if (c_abi_eb0 < 0): c_abi_eb0 = 0
	if (size <= 8): return 1
	if (c_abi_eb1 < 0): c_abi_eb1 = 0
	return 2


# The plan of one System V signature (c_abi_plan): for each argument its
# W stack words, the words of the arguments after it (its distance from
# the last one), the register of each of its first two eightbytes
# (0..5 rdi rsi rdx rcx r8 r9, 16 + k xmm k), its first stack eightbyte
# (-1 in registers) and the class an xmm load uses (ffi classes).
int* c_plan_words
int* c_plan_after
int* c_plan_slot0
int* c_plan_slot1
int* c_plan_stack
int* c_plan_fclass
int c_plan_gp
int c_plan_sse
int c_plan_stack_words
int c_plan_total_words
# The result: 0 a scalar (or void), 1 a record in registers (eightbytes
# c_plan_ret_words, classes c_plan_ret_eb0/1), 2 a MEMORY record.
int c_plan_ret
int c_plan_ret_words
int c_plan_ret_eb0
int c_plan_ret_eb1


void c_abi_plan_free():
	free(cast(void*, c_plan_words))
	free(cast(void*, c_plan_after))
	free(cast(void*, c_plan_slot0))
	free(cast(void*, c_plan_slot1))
	free(cast(void*, c_plan_stack))
	free(cast(void*, c_plan_fclass))


void c_abi_plan_result(int ret_type):
	c_plan_ret = 0
	c_plan_ret_words = 0
	if (c_abi_type_is_record(ret_type) == 0): return
	c_plan_ret_words = c_abi_classify(ret_type)
	if (c_plan_ret_words == 0):
		c_plan_ret = 2
		return
	c_plan_ret = 1
	c_plan_ret_eb0 = c_abi_eb0
	c_plan_ret_eb1 = c_abi_eb1
	if ((c_abi_eb0 == 1) || ((c_plan_ret_words == 2) && (c_abi_eb1 == 1))): sse_kernel_reject()


# Assign the n arguments of types (-1: an integer word) to registers and
# stack eightbytes, left to right as the psABI does: a record whose
# eightbytes do not all fit in the registers left goes to the stack
# whole. Call c_abi_plan_result first: a MEMORY result takes rdi.
void c_abi_plan(int n, int* types):
	int bytes = (n + 1) * __word_size__
	c_plan_words = cast(int*, malloc(bytes))
	c_plan_after = cast(int*, malloc(bytes))
	c_plan_slot0 = cast(int*, malloc(bytes))
	c_plan_slot1 = cast(int*, malloc(bytes))
	c_plan_stack = cast(int*, malloc(bytes))
	c_plan_fclass = cast(int*, malloc(bytes))
	int gp = 0
	if (c_plan_ret == 2): gp = 1
	int sse = 0
	int st = 0
	for i in range(n):
		int type = types[i]
		c_plan_words[i] = 1
		c_plan_slot0[i] = -1
		c_plan_slot1[i] = -1
		c_plan_stack[i] = -1
		c_plan_fclass[i] = 2
		if (c_abi_type_is_record(type)):
			c_plan_words[i] = type_stack_words(type)
			int eightbytes = c_abi_classify(type)
			int need_gp = 0
			int need_sse = 0
			if (eightbytes > 0):
				need_gp = c_abi_eb0 == 0
				need_sse = c_abi_eb0 == 1
				if (eightbytes == 2):
					need_gp = need_gp + (c_abi_eb1 == 0)
					need_sse = need_sse + (c_abi_eb1 == 1)
			if ((eightbytes > 0) && (gp + need_gp <= 6) && (sse + need_sse <= 8)):
				if (need_sse > 0): sse_kernel_reject()
				if (c_abi_eb0 == 0):
					c_plan_slot0[i] = gp
					gp = gp + 1
				else:
					c_plan_slot0[i] = 16 + sse
					sse = sse + 1
				if (eightbytes == 2):
					if (c_abi_eb1 == 0):
						c_plan_slot1[i] = gp
						gp = gp + 1
					else:
						c_plan_slot1[i] = 16 + sse
						sse = sse + 1
			else:
				c_plan_stack[i] = st
				st = st + c_plan_words[i]
		else:
			int arg_class = ffi_type_class(type)
			c_plan_fclass[i] = arg_class
			if ((arg_class == 0) && (gp < 6)):
				c_plan_slot0[i] = gp
				gp = gp + 1
			else if ((arg_class != 0) && (sse < 8)):
				c_plan_slot0[i] = 16 + sse
				sse = sse + 1
			else:
				c_plan_stack[i] = st
				st = st + 1
	int after = 0
	int k = n - 1
	while (k >= 0):
		c_plan_after[k] = after
		after = after + c_plan_words[k]
		k = k - 1
	c_plan_gp = gp
	c_plan_sse = sse
	c_plan_stack_words = st
	c_plan_total_words = after


# <op> [rbp+disp32] with a ModRM reg field: the rbp-relative encodings.
void c_abi_rbp_op(int bytes, char* opcode, int reg, int disp):
	emit(bytes, opcode)
	emit_int8(0x85 | ((reg & 7) << 3))
	emit_int32(disp)


# Load register slot (0..5 System V argument registers, 16 + k xmm k)
# from [rbp+disp] (an xmm one as float class fclass).
void c_abi_load_slot(int slot, int fclass, int disp):
	if (slot >= 16): emit_x64_load_xmm_reg(slot - 16, fclass, disp)
	else: emit_x64_load_gp_reg(slot, disp)


# A System V call of n arguments of types (W words above rbp + arg_base:
# the last argument's first word there, a struct's words in memory
# order, a struct result's hidden buffer pointer above all of them),
# through got_vaddr's import slot or, when it is 0, r11. Records go in
# registers or on the stack per their classification; a register record
# result is stored through the W hidden buffer pointer. Returns the W
# words the arguments (and a hidden buffer pointer) occupy.
int c_abi_emit_call(int n, int* types, int ret_type, int got_vaddr, int arg_base):
	c_abi_plan_result(ret_type)
	c_abi_plan(n, types)
	int hidden = arg_base + c_plan_total_words * 8
	emit_x64_c_frame_begin()
	if ((c_plan_stack_words & 1) == 1): emit(4, c"\x48\x83\xec\x08")   # sub rsp,8
	int i = n - 1
	while (i >= 0):
		if (c_plan_stack[i] >= 0):
			int k = c_plan_words[i] - 1
			while (k >= 0):
				emit(2, c"\xff\xb5")   # push qword [rbp+disp32]
				emit_int32(arg_base + (c_plan_after[i] + k) * 8)
				k = k - 1
		i = i - 1
	for j in range(n):
		if (c_plan_stack[j] < 0):
			int disp = arg_base + c_plan_after[j] * 8
			c_abi_load_slot(c_plan_slot0[j], c_plan_fclass[j], disp)
			if (c_plan_slot1[j] >= 0): c_abi_load_slot(c_plan_slot1[j], 2, disp + 8)
	if (c_plan_ret == 2): emit_x64_load_gp_reg(0, hidden)   # rdi: the result buffer
	emit(1, c"\xb8")   # mov eax,imm32: xmm registers used
	emit_int32(c_plan_sse)
	if (got_vaddr == 0): emit(3, c"\x41\xff\xd3")   # call r11
	else:
		emit(2, c"\xff\x15")   # call qword ptr [rip+disp32]
		static_note_address(codepos)
		emit_int32(got_vaddr - code_offset - codepos - 4)
	int ret_class = 0
	if (c_plan_ret == 1):
		emit_x64_load_gp_reg(3, hidden)   # rcx: the W result buffer
		if (c_plan_ret_eb0 == 0): emit(3, c"\x48\x89\x01")   # mov [rcx],rax
		else: emit(4, c"\x66\x0f\xd6\x01")   # movq [rcx],xmm0
		if (c_plan_ret_words == 2):
			if (c_plan_ret_eb1 == 0):
				if (c_plan_ret_eb0 == 0): emit(4, c"\x48\x89\x51\x08")   # mov [rcx+8],rdx
				else: emit(4, c"\x48\x89\x41\x08")   # mov [rcx+8],rax
			else:
				if (c_plan_ret_eb0 == 1): emit(5, c"\x66\x0f\xd6\x49\x08")   # movq [rcx+8],xmm1
				else: emit(5, c"\x66\x0f\xd6\x41\x08")   # movq [rcx+8],xmm0
	else if (c_plan_ret == 0): ret_class = ffi_type_class(ret_type)
	emit_x64_c_frame_end(ret_class)
	c_abi_plan_free()
	return ((hidden - arg_base) >> 3) + (c_plan_ret != 0)


# 1 when a signature needs c_abi_emit_call: a record argument or result.
int c_abi_signature_has_records(int n, int* types, int ret_type):
	if (c_abi_type_is_record(ret_type)): return 1
	for i in range(n):
		if (c_abi_type_is_record(types[i])): return 1
	return 0


# The FFI shim of extern function sym (n parameters): the classic one
# (code_generator/ffi.w) unless an x64 System V signature passes or
# returns a record by value.
void c_abi_emit_extern_shim(int sym, int n, char* classes, int ret_class, int got_vaddr):
	if ((target_isa != 0) || (word_size != 8) || (target_os == 2)):
		emit_ffi_shim(n, classes, ret_class, got_vaddr)
		return
	int* types = cast(int*, malloc((n + 1) * __word_size__))
	for i in range(n): types[i] = sym_param_type_wide(sym, i)
	int ret_type = load_int(table + sym + 6)
	if (c_abi_signature_has_records(n, types, ret_type) == 0):
		free(cast(void*, types))
		emit_ffi_shim(n, classes, ret_class, got_vaddr)
		return
	int words = c_abi_emit_call(n, types, ret_type, got_vaddr, 16)
	emit(1, c"\xc3")   # ret
	if (stack_usage_mode): stack_usage_shim(words)
	free(cast(void*, types))


# A call through a function-pointer value (grammar/postfix_expr.w
# finish_call): rax holds the callee, the passed_args arguments are the
# W stack words above the callee slot s + 1 (after a struct result's
# hidden buffer pointer). Converts them to a System V call through r11
# and leaves the result in rax.
void c_abi_indirect_call(int callee_type, int callee_sym, int s, int passed_args, int has_return_buffer, int declared_return):
	int signature = -1
	if (type_get_pointer_level(callee_type) > 0):
		int base = type_lookup_previous_pointer(callee_type)
		if ((base >= 0) && type_is_function_signature(base)): signature = base
	int n = stack_pos - s - 1
	int* types = cast(int*, malloc((passed_args + 1) * __word_size__))
	int words = 0
	if (has_return_buffer): words = 1
	for i in range(passed_args):
		types[i] = -1
		if ((signature >= 0) && (i < type_function_param_count(signature))): types[i] = type_function_param_type(signature, i)
		# a weak function called through its symbol (c_abi_calls_through_symbol)
		if ((signature < 0) && (callee_sym >= 0) && (i < sym_num_args(callee_sym))): types[i] = sym_param_type(callee_sym, i)
		if (c_abi_type_unsupported(types[i])):
			error(c"--c-abi cannot pass a multi-word value that is not a struct through a function pointer")
		words = words + c_abi_arg_words(types[i])
	if (words != n):
		error(c"--c-abi cannot pass a struct by value through a function pointer without a signature")
	int ret_type = declared_return
	if ((has_return_buffer == 0) && c_abi_type_is_aggregate(declared_return)):
		error(c"--c-abi cannot return a multi-word value that is not a struct through a function pointer")
	emitted_call_count = emitted_call_count + 1
	# The arguments must all be real stack words, and loop-owned
	# registers survive the callee in their homes (as call_eax does).
	if (ers_count != 0): ers_spill_all()
	inline_real_calls = inline_real_calls + 1
	regalloc_call_spill()
	emit(3, c"\x49\x89\xc3")   # mov r11,rax
	# the inline C frame: saved frame pointer, alignment, stack arguments
	if (stack_usage_mode): stack_usage_extra(3 + n)
	c_abi_emit_call(passed_args, types, ret_type, 0, 8)
	regalloc_call_reload()
	if (has_return_buffer == 0): c_abi_extend_rax(declared_return)
	free(cast(void*, types))


# A direct call of a C-variadic function (grammar/postfix_expr.w and the
# AST emitter, the n argument words just pushed): through an extern's
# import slot, or for a C-variadic W definition its System V entry.
void c_variadic_call_emit(int t, int n, char* classes, int declared_return):
	int ret_class = ffi_type_class(declared_return)
	int got_vaddr = sym_got_vaddr(t)
	if (got_vaddr != 0):
		emit_ffi_call_inline(n, classes, ret_class, got_vaddr)
		return
	emitted_call_count = emitted_call_count + 1
	if (stack_usage_mode): stack_usage_extra(3 + n)
	if (ers_count != 0): ers_spill_all()
	inline_real_calls = inline_real_calls + 1
	regalloc_call_spill()
	if (c_abi_mode):
		c_abi_function_value(t, sym_record_name(t))
		emit(3, c"\x49\x89\xc3")   # mov r11,rax
	emit_c_abi_call_x64(n, classes, ret_class, 0, 8)
	regalloc_call_reload()
	if (ret_class == 0): c_abi_extend_rax(declared_return)


# mov rax,<System V argument register 0..5>
void c_abi_mov_rax_arg(int reg):
	if (reg == 0): emit(3, c"\x48\x89\xf8")   # rdi
	else if (reg == 1): emit(3, c"\x48\x89\xf0")   # rsi
	else if (reg == 2): emit(3, c"\x48\x89\xd0")   # rdx
	else if (reg == 3): emit(3, c"\x48\x89\xc8")   # rcx
	else if (reg == 4): emit(3, c"\x4c\x89\xc0")   # r8
	else: emit(3, c"\x4c\x89\xc8")   # r9


# rax = register slot (0..5, or 16 + k: xmm k) of an incoming argument.
void c_abi_mov_rax_slot(int slot):
	if (slot >= 16):
		sse_kernel_reject()
		emit(4, c"\x66\x48\x0f\x7e")   # movq rax,xmmN
		emit_int8(0xc0 | ((slot - 16) << 3))
	else: c_abi_mov_rax_arg(slot)


# mov [rbp+disp32],<System V argument register 0..5>
void c_abi_store_arg(int reg, int disp):
	if (reg < 4): c_abi_rbp_op(2, c"\x48\x89", 7 - (reg == 1) - 5 * (reg == 2) - 6 * (reg == 3), disp)
	else: c_abi_rbp_op(2, c"\x4c\x89", reg - 4, disp)


# The System V adapter of function t whose W entry is `entry`: System V
# arguments (registers, then the caller's stack eightbytes; records
# per their classification) pushed as the W stack words the callee
# expects, narrow integers extended, the System V callee-saved
# registers preserved. A record result gets a hidden W buffer: 16 bytes
# of the adapter frame loaded back into rax/rdx/xmm0/xmm1, or for a
# MEMORY record the caller's own (rdi in, rax out). A C-variadic
# definition gets the register save area and an initialized va_list
# (gp_offset, fp_offset, overflow_arg_area, reg_save_area) in the frame,
# its address the last W argument.
#
#   rbp-8 .. rbp-40   rbx r12 r13 r14 r15
#   rbp-40-L ..       locals: result buffer, save area, va_list
void c_abi_emit_adapter(int t, int entry):
	int n = sym_num_args(t)
	if (n < 0): n = 0
	int variadic = c_abi_is_c_variadic_definition(t)
	int named = n
	if (variadic): named = n - 1
	int* types = cast(int*, malloc((n + 1) * __word_size__))
	for i in range(named): types[i] = sym_param_type_wide(t, i)
	int ret_type = load_int(table + t + 6)
	if (ret_type == 4): ret_type = -1
	c_abi_plan_result(ret_type)
	c_abi_plan(named, types)
	int locals = 0
	int buffer = 0
	int save = 0
	int va = 0
	if (c_plan_ret == 1):
		buffer = locals
		locals = locals + 16
	if (variadic):
		save = locals
		locals = locals + 176
		va = locals
		locals = locals + 24
	locals = (locals + 15) & (0 - 16)
	int base = 0 - 40 - locals
	int pushed = c_plan_total_words + variadic
	if (c_plan_ret != 0): pushed = pushed + 1
	if (stack_usage_mode): stack_usage_c_abi_adapter(t, pushed + (locals >> 3))
	emit(4, c"\x55\x48\x89\xe5")   # push rbp; mov rbp,rsp
	push_reg(3)
	for r in range(12, 16): push_reg(r)
	if (locals > 0):
		emit(3, c"\x48\x81\xec")   # sub rsp,imm32
		emit_int32(locals)
	if (variadic):
		for r in range(6): c_abi_store_arg(r, base + save + r * 8)
		if (kernel_codegen == 0):
			emit(4, c"\x84\xc0\x74\x38")   # test al,al; jz over the 8 stores
			for x in range(8): c_abi_rbp_op(2, c"\x0f\x11", x, base + save + 48 + x * 16)   # movups [rbp+d],xmmX
		c_abi_rbp_op(1, c"\xc7", 0, base + va)   # mov dword [rbp+d],imm32: gp_offset
		emit_int32(c_plan_gp * 8)
		c_abi_rbp_op(1, c"\xc7", 0, base + va + 4)   # fp_offset
		emit_int32(48 + c_plan_sse * 16)
		c_abi_rbp_op(2, c"\x48\x8d", 0, 16 + c_plan_stack_words * 8)   # lea rax,[rbp+d]: overflow_arg_area
		c_abi_rbp_op(2, c"\x48\x89", 0, base + va + 8)
		c_abi_rbp_op(2, c"\x48\x8d", 0, base + save)   # reg_save_area
		c_abi_rbp_op(2, c"\x48\x89", 0, base + va + 16)
	if (c_plan_ret == 2):
		c_abi_mov_rax_arg(0)
		push_reg(0)
	else if (c_plan_ret == 1):
		c_abi_rbp_op(2, c"\x48\x8d", 0, base + buffer)   # lea rax,[rbp+d]
		push_reg(0)
	for i in range(named):
		int k = c_plan_words[i] - 1
		while (k >= 0):
			if (c_plan_stack[i] >= 0):
				# the caller's stack eightbytes follow the saved rbp and
				# the return address
				c_abi_rbp_op(2, c"\x48\x8b", 0, 16 + (c_plan_stack[i] + k) * 8)   # mov rax,[rbp+d]
			else if (k == 0): c_abi_mov_rax_slot(c_plan_slot0[i])
			else: c_abi_mov_rax_slot(c_plan_slot1[i])
			if ((c_abi_type_is_record(types[i]) == 0) && (c_plan_fclass[i] == 0)): c_abi_extend_rax(types[i])
			push_reg(0)
			k = k - 1
	if (variadic):
		c_abi_rbp_op(2, c"\x48\x8d", 0, base + va)   # lea rax,[rbp+d]: the va_list
		push_reg(0)
	emit_int8(0xe8)   # call the W entry
	emit_int32(entry - code_offset - codepos - 4)
	if (elf_object): object_note_rel32(codepos - 4)
	if (c_plan_ret == 1):
		# eightbyte 0 in rax or xmm0, eightbyte 1 in the next of its kind
		if (c_plan_ret_eb0 == 0): c_abi_rbp_op(2, c"\x48\x8b", 0, base + buffer)   # mov rax,[rbp+d]
		else: c_abi_rbp_op(3, c"\xf3\x0f\x7e", 0, base + buffer)   # movq xmm0,[rbp+d]
		if (c_plan_ret_words == 2):
			int second = 0
			if (c_plan_ret_eb0 == c_plan_ret_eb1): second = 1
			if (c_plan_ret_eb1 == 0): c_abi_rbp_op(2, c"\x48\x8b", 2 * second, base + buffer + 8)   # mov rax/rdx,[rbp+d]
			else: c_abi_rbp_op(3, c"\xf3\x0f\x7e", second, base + buffer + 8)   # movq xmm0/xmm1,[rbp+d]
	else if (c_plan_ret == 2): c_abi_rbp_op(2, c"\x48\x8b", 0, base - 8)   # mov rax,[rbp+d]: the buffer
	emit(4, c"\x48\x8d\x65\xd8")   # lea rsp,[rbp-40]
	for r in range(4): pop_reg(15 - r)
	pop_reg(3)
	emit_int8(0x5d)   # pop rbp
	int ret_class = 0
	if (c_plan_ret == 0): ret_class = ffi_type_class(ret_type)
	if (ret_class != 0): sse_kernel_reject()
	if (ret_class == 1): emit(4, c"\x66\x0f\x6e\xc0")   # movd xmm0,eax
	if (ret_class == 2): emit(5, c"\x66\x48\x0f\x6e\xc0")   # movq xmm0,rax
	emit_int8(0xc3)
	c_abi_plan_free()
	free(cast(void*, types))


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
