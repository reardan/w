/*
DWARF debugging information entries and call-frame information for the
ELF targets (issue #536).

code_generator/dwarf.w records, while the single-pass compiler emits
code, which functions were compiled (with their frame-pointer prologue),
the lexical blocks they opened, and every local and parameter with its
stack slot. emit_debugging_symbols (compiler/symbol_table.w) calls the
functions here at ELF finalisation to turn those notes into:

  .debug_abbrev  the abbreviation table for everything below
  .debug_info    one DWARF 2 compile unit holding a DW_TAG_subprogram per
                 framed function (name, declaration file/line, return
                 type, pc range, frame base), its
                 DW_TAG_formal_parameter / DW_TAG_variable children with
                 DW_OP_fbreg locations, nested DW_TAG_lexical_blocks, and
                 the base, pointer, struct/union and array types they use
  .debug_frame   a CIE plus one FDE per framed x86/x64 function, so
                 unwinders follow push fp ; mov fp,sp ... leave ; ret

Frame layout (code_generator/arm64.w be_function_prologue, x86.w
be_return): after the prologue the frame pointer (ebp / rbp / x29)
points at the saved caller frame pointer, the return address sits one
word above it and the arguments above that, pushed first to last.
stack_pos counts the W stack words since entry (the saved frame pointer
is word 1), so a local declared at slot s spanning w words starts at
fp - (s + w - 1) * word, and parameter s of a function with n argument
words at fp + (n - s - w + 3) * word (the same arithmetic
debugger/locals.w and grammar/ast_expression.w use, rebased on fp).
On x86/x64, where .debug_frame describes the frame, DW_AT_frame_base is
DW_OP_call_frame_cfa (fp + 2 words in the body) so parameters also read
right on the prologue and 'ret' instructions; arm64 uses DW_OP_breg29.

Everything is derived from compile-time state in compile order, so the
output is deterministic and the self-host fixpoint covers it.
*/
import code_generator.dwarf


# Abbreviation codes (dwarf_abbrev_emit)
const int dw_abbrev_cu = 1
const int dw_abbrev_subprogram = 2
const int dw_abbrev_subprogram_void = 3
const int dw_abbrev_parameter = 4
const int dw_abbrev_variable = 5
const int dw_abbrev_block = 6
const int dw_abbrev_base = 7
const int dw_abbrev_pointer = 8
const int dw_abbrev_pointer_void = 9
const int dw_abbrev_struct = 10
const int dw_abbrev_member = 11
const int dw_abbrev_union = 12
const int dw_abbrev_array = 13
const int dw_abbrev_subrange = 14
const int dw_abbrev_subprogram_leaf = 15
const int dw_abbrev_subprogram_void_leaf = 16

# DW_FORM_*
const int dw_form_addr = 1
const int dw_form_block1 = 10
const int dw_form_data1 = 11
const int dw_form_data2 = 5
const int dw_form_data4 = 6
const int dw_form_string = 8
const int dw_form_flag = 12
const int dw_form_sdata = 13
const int dw_form_udata = 15
const int dw_form_ref4 = 19


# DWARF number of the frame-pointer register the variables are addressed
# from: ebp (5) on x86, rbp (6) on x64, x29 on arm64; -1 elsewhere.
int dwarf_frame_register():
	if (target_isa == 0):
		if (word_size == 8): return 6
		return 5
	if (target_isa == 1): return 29
	return -1


int dw_subprogram_abbrev(int with_type, int children):
	if (with_type):
		if (children): return dw_abbrev_subprogram
		return dw_abbrev_subprogram_leaf
	if (children): return dw_abbrev_subprogram_void
	return dw_abbrev_subprogram_void_leaf


void dw_abbrev(int code, int tag, int children):
	emit_uleb(code)
	emit_uleb(tag)
	emit_int8(children)


void dw_attr(int attribute, int form):
	emit_uleb(attribute)
	emit_uleb(form)


void dw_abbrev_end():
	emit_uleb(0)
	emit_uleb(0)


# .debug_abbrev for dwarf_info_emit.
void dwarf_abbrev_emit():
	dw_abbrev(dw_abbrev_cu, 17, 1) /* DW_TAG_compile_unit */
	dw_attr(3, dw_form_string) /* DW_AT_name */
	dw_attr(16, dw_form_data4) /* DW_AT_stmt_list */
	dw_attr(17, dw_form_addr) /* DW_AT_low_pc */
	dw_attr(18, dw_form_addr) /* DW_AT_high_pc */
	dw_attr(37, dw_form_string) /* DW_AT_producer */
	dw_attr(19, dw_form_data2) /* DW_AT_language */
	dw_abbrev_end()

	# Subprograms: with/without DW_AT_type, with/without children
	int variant = 0
	while (variant < 4):
		int with_type = variant & 1
		int children = 1 - (variant >> 1)
		dw_abbrev(dw_subprogram_abbrev(with_type, children), 46, children) /* DW_TAG_subprogram */
		dw_attr(3, dw_form_string) /* DW_AT_name */
		dw_attr(58, dw_form_udata) /* DW_AT_decl_file */
		dw_attr(59, dw_form_udata) /* DW_AT_decl_line */
		if (with_type): dw_attr(73, dw_form_ref4) /* DW_AT_type */
		dw_attr(63, dw_form_flag) /* DW_AT_external */
		dw_attr(17, dw_form_addr) /* DW_AT_low_pc */
		dw_attr(18, dw_form_addr) /* DW_AT_high_pc */
		dw_attr(64, dw_form_block1) /* DW_AT_frame_base */
		dw_abbrev_end()
		variant = variant + 1

	dw_abbrev(dw_abbrev_parameter, 5, 0) /* DW_TAG_formal_parameter */
	dw_attr(3, dw_form_string)
	dw_attr(73, dw_form_ref4)
	dw_attr(2, dw_form_block1) /* DW_AT_location */
	dw_abbrev_end()

	dw_abbrev(dw_abbrev_variable, 52, 0) /* DW_TAG_variable */
	dw_attr(3, dw_form_string)
	dw_attr(73, dw_form_ref4)
	dw_attr(2, dw_form_block1)
	dw_abbrev_end()

	dw_abbrev(dw_abbrev_block, 11, 1) /* DW_TAG_lexical_block */
	dw_attr(17, dw_form_addr)
	dw_attr(18, dw_form_addr)
	dw_abbrev_end()

	dw_abbrev(dw_abbrev_base, 36, 0) /* DW_TAG_base_type */
	dw_attr(3, dw_form_string)
	dw_attr(62, dw_form_data1) /* DW_AT_encoding */
	dw_attr(11, dw_form_udata) /* DW_AT_byte_size */
	dw_abbrev_end()

	dw_abbrev(dw_abbrev_pointer, 15, 0) /* DW_TAG_pointer_type */
	dw_attr(11, dw_form_data1)
	dw_attr(73, dw_form_ref4)
	dw_abbrev_end()

	dw_abbrev(dw_abbrev_pointer_void, 15, 0)
	dw_attr(11, dw_form_data1)
	dw_abbrev_end()

	dw_abbrev(dw_abbrev_struct, 19, 1) /* DW_TAG_structure_type */
	dw_attr(3, dw_form_string)
	dw_attr(11, dw_form_udata)
	dw_abbrev_end()

	dw_abbrev(dw_abbrev_member, 13, 0) /* DW_TAG_member */
	dw_attr(3, dw_form_string)
	dw_attr(73, dw_form_ref4)
	dw_attr(56, dw_form_block1) /* DW_AT_data_member_location */
	dw_abbrev_end()

	dw_abbrev(dw_abbrev_union, 23, 1) /* DW_TAG_union_type */
	dw_attr(3, dw_form_string)
	dw_attr(11, dw_form_udata)
	dw_abbrev_end()

	dw_abbrev(dw_abbrev_array, 1, 1) /* DW_TAG_array_type */
	dw_attr(73, dw_form_ref4)
	dw_abbrev_end()

	dw_abbrev(dw_abbrev_subrange, 33, 0) /* DW_TAG_subrange_type */
	dw_attr(47, dw_form_sdata) /* DW_AT_upper_bound */
	dw_abbrev_end()

	emit_int8(0) /* end of abbreviations */


############################### type references ###############################
# A type reference is a "code": type index * 4 + variant, where variant
# 0 is the type itself, 1 a pointer to it that the type table may not
# hold (an array descriptor's data pointer), and 2 the raw element array
# behind a T[N] descriptor. DIEs are written after the subprograms, so
# references are DW_FORM_ref4 placeholders patched once every queued
# type has its DIE offset.

int dw_unit_start
list[int] dw_type_die     /* per code: CU-relative DIE offset, -1 queued, 0 none */
list[int] dw_type_queue   /* codes in first-reference order */
list[int] dw_fixups       /* (codepos of a ref4, code) pairs */


int dw_type_normalize(int type):
	if (type < -1): type = 0 - type - 2 /* a value type: its storage type */
	if (type < 0): return -1
	return type_unqualified(type)


# 1 for types with no storage that no variable can have (void, the
# constant/function pseudo-types): no DIE describes them.
int dw_type_is_void(int type):
	type = dw_type_normalize(type)
	if (type < 0): return 1
	if (type_get_pointer_level(type) > 0): return 0
	if (type_num_args(type) > 0): return 0
	return type_get_size(type) == 0


void dw_type_ref_code(int code):
	while (dw_type_die.length <= code): dw_type_die.push(0)
	if (dw_type_die[code] == 0):
		dw_type_die[code] = -1
		dw_type_queue.push(code)
	dw_fixups.push(codepos)
	dw_fixups.push(code)
	emit_int32(0)


void dw_type_ref(int type):
	type = dw_type_normalize(type)
	if (type < 0): type = 0 /* void: only reachable through bad input */
	dw_type_ref_code(type * 4)


# DW_ATE_* for a scalar type.
int dw_base_encoding(int type):
	if (type_float_kind(type) > 0): return 4 /* DW_ATE_float */
	int kind = type_get_kind(type)
	if (kind == type_kind_enum): return 5 /* DW_ATE_signed */
	if ((kind == type_kind_slice) || (kind == type_kind_string) || (kind == type_kind_map) ||
			(kind == type_kind_set) || (kind == type_kind_list) || (kind == type_kind_var)):
		return 1 /* DW_ATE_address: runtime handles */
	char* name = type_get_name(type)
	if (strcmp(name, c"bool") == 0): return 2 /* DW_ATE_boolean */
	if (strcmp(name, c"char") == 0): return 6 /* DW_ATE_signed_char */
	if ((strcmp(name, c"byte") == 0) || (strcmp(name, c"uint8") == 0)): return 8 /* DW_ATE_unsigned_char */
	if (starts_with(name, c"uint") || (strcmp(name, c"pointer") == 0)): return 7 /* DW_ATE_unsigned */
	return 5 /* DW_ATE_signed */


# DW_AT_data_member_location as DW_OP_plus_uconst offset.
void dw_member(char* name, int type_code, int offset):
	emit_uleb(dw_abbrev_member)
	emit_string(name)
	dw_type_ref_code(type_code)
	int at = codepos
	emit_int8(0)
	emit_int8(35) /* DW_OP_plus_uconst */
	emit_uleb(offset)
	code[at] = codepos - at - 1


void dw_type_emit(int type_code):
	int type = type_code / 4
	int variant = type_code - type * 4
	dw_type_die[type_code] = codepos - dw_unit_start
	if (variant == 1):
		emit_uleb(dw_abbrev_pointer)
		emit_int8(word_size)
		dw_type_ref_code(type * 4)
		return
	if (variant == 2):
		emit_uleb(dw_abbrev_array)
		dw_type_ref(type_get_element_type(type))
		emit_uleb(dw_abbrev_subrange)
		emit_sleb(type_get_array_length(type) - 1)
		emit_uleb(0) /* end of array children */
		return
	if (type_get_pointer_level(type) > 0):
		int base = type_lookup_previous_pointer(type)
		if (base >= 0):
			if (type_is_function_signature(base) || dw_type_is_void(base)): base = -1
		if (base < 0):
			emit_uleb(dw_abbrev_pointer_void)
			emit_int8(word_size)
			return
		emit_uleb(dw_abbrev_pointer)
		emit_int8(word_size)
		dw_type_ref(base)
		return
	int kind = type_get_kind(type)
	if (kind == type_kind_array):
		# The T[N] descriptor: a data-pointer word, a length word, then
		# the N elements (type_array_element_offset)
		emit_uleb(dw_abbrev_struct)
		emit_string(type_get_name(type))
		emit_uleb(type_get_size(type))
		int element = dw_type_normalize(type_get_element_type(type))
		dw_member(c"data", element * 4 + 1, 0)
		dw_member(c"length", type_lookup(c"int") * 4, word_size)
		dw_member(c"items", type * 4 + 2, type_array_element_offset())
		emit_uleb(0)
		return
	int fields = type_num_args(type)
	if ((fields > 0) && ((kind == 0) || (kind == type_kind_union))):
		if (kind == type_kind_union): emit_uleb(dw_abbrev_union)
		else: emit_uleb(dw_abbrev_struct)
		emit_string(type_get_name(type))
		emit_uleb(type_get_size(type))
		for i in range(fields):
			int field_type = dw_type_normalize(type_get_field_type_at(type, i))
			dw_member(type_get_field_name_at(type, i), field_type * 4, type_get_field_offset_at(type, i))
		emit_uleb(0)
		return
	emit_uleb(dw_abbrev_base)
	emit_string(type_get_name(type))
	emit_int8(dw_base_encoding(type))
	emit_uleb(type_get_size(type))


############################### subprograms ###############################

# DW_OP_fbreg offset of a recorded local or parameter (see the header).
int dw_local_frame_offset(int local_index, int arg_words):
	int slot = load_int(debug_local_slots + local_index * 4)
	int kind = load_int(debug_local_kinds + local_index * 4)
	int words = type_stack_words(load_int(debug_local_types + local_index * 4))
	# Frame-pointer relative, then rebased when the frame base is the CFA
	int offset = 0 - (slot + words - 1) * word_size
	if (kind == 'A'): offset = (arg_words - slot - words + 3) * word_size
	if (target_isa == 0): offset = offset - 2 * word_size
	return offset


void dw_variable_emit(int local_index, int arg_words):
	int type = load_int(debug_local_types + local_index * 4)
	if (dw_type_is_void(type)): return;
	if (load_int(debug_local_kinds + local_index * 4) == 'A'): emit_uleb(dw_abbrev_parameter)
	else: emit_uleb(dw_abbrev_variable)
	emit_string(cast(char*, load_ptr(debug_local_names + local_index * __word_size__)))
	dw_type_ref(type)
	int at = codepos
	emit_int8(0)
	int reg = debug_local_register(local_index)
	# A register-resident local (register promotion): DW_OP_reg<n>. The
	# hardware number is the DWARF number on i386 and for r8-r15; x64's
	# DWARF numbering swaps rcx/rdx and puts rsi/rdi at 4/5 (the loop and
	# function-region registers, compiler/regalloc_scan.w)
	if (reg != 0):
		int dw = reg
		if (word_size == 8):
			if (reg == 6): dw = 4
			elif (reg == 7): dw = 5
			elif (reg == 1): dw = 2
			elif (reg == 2): dw = 1
		emit_int8(80 + dw) /* DW_OP_reg0 + n */
	else:
		emit_int8(145) /* DW_OP_fbreg */
		emit_sleb(dw_local_frame_offset(local_index, arg_words))
	code[at] = codepos - at - 1


void dw_address(int position):
	emit_target_word(position + code_offset)


void dw_subprogram_emit(int f):
	int record = f * dwarf_func_stride
	int symbol = dwarf_funcs[record]
	int arg_words = dwarf_funcs[record + 4]
	int return_type = load_int(table + symbol + 6)
	int has_type = dw_type_is_void(return_type) == 0
	# Children only when some variable will be written
	int event = dwarf_funcs[record + 5]
	int last = dwarf_funcs[record + 6]
	int children = 0
	int e = event
	while ((e < last) && (children == 0)):
		if (dwarf_events[e * 2] == 'V'):
			int local_type = load_int(debug_local_types + dwarf_events[e * 2 + 1] * 4)
			if (dw_type_is_void(local_type) == 0): children = 1
		e = e + 1
	emit_uleb(dw_subprogram_abbrev(has_type, children))
	emit_string(cast(char*, dwarf_funcs[record + 7]))
	emit_uleb(sym_decl_file_index(symbol) + 1) /* DW_AT_decl_file: 0 = unknown */
	int line = sym_decl_line(symbol)
	if (line < 0): line = 0
	emit_uleb(line)
	if (has_type): dw_type_ref(return_type)
	emit_int8(1) /* DW_AT_external */
	dw_address(dwarf_funcs[record + 1])
	dw_address(dwarf_funcs[record + 3])
	if (target_isa == 0):
		# x86/x64 have .debug_frame, so the frame base is the CFA (fp +
		# 2 words once the prologue ran): arguments then read correctly
		# at the entry and 'ret' instructions too, not just in the body.
		emit_int8(1) /* DW_AT_frame_base: DW_OP_call_frame_cfa */
		emit_int8(156)
	else:
		emit_int8(2) /* DW_AT_frame_base: DW_OP_breg<fp> 0 */
		emit_int8(112 + dwarf_frame_register())
		emit_int8(0)

	if (children == 0): return;

	# Replay the scope events; skip blocks that declare nothing
	int skip_depth = 0
	while (event < last):
		int kind = dwarf_events[event * 2]
		int value = dwarf_events[event * 2 + 1]
		if (kind == 'B'):
			if (skip_depth > 0): skip_depth = skip_depth + 1
			else if (dwarf_blocks[value * 3 + 2] == 0): skip_depth = 1
			else:
				emit_uleb(dw_abbrev_block)
				dw_address(dwarf_blocks[value * 3])
				dw_address(dwarf_blocks[value * 3 + 1])
		else if (kind == 'b'):
			if (skip_depth > 0): skip_depth = skip_depth - 1
			else: emit_uleb(0) /* end of block children */
		else if (skip_depth == 0): dw_variable_emit(value, arg_words)
		event = event + 1
	emit_uleb(0) /* end of subprogram children */


# .debug_info: one compile unit pointing at the line table, with the
# subprograms and the types they reference as children.
void dwarf_info_emit(int text_end):
	dw_unit_start = codepos
	emit_int32(0) /* unit_length, patched below */
	emit_int16(2) /* DWARF version 2 */
	emit_int32(0) /* offset into .debug_abbrev */
	emit_int8(word_size) /* address_size: the target's word size */
	emit_uleb(dw_abbrev_cu)
	char* unit_name = c"w"
	if (debug_file_count > 0): unit_name = cast(char*, load_ptr(debug_files))
	emit_string(unit_name) /* DW_AT_name */
	emit_int32(0) /* DW_AT_stmt_list: offset 0 in .debug_line */
	emit_target_word(code_offset) /* DW_AT_low_pc */
	emit_target_word(text_end + code_offset) /* DW_AT_high_pc */
	emit_string(c"w") /* DW_AT_producer */
	# DW_LANG_C99: W's expressions read as C's, so gdb's C evaluator
	# handles 'print p.x', 'print *p', casts and arithmetic.
	emit_int16(12) /* DW_AT_language */

	if ((dwarf_frame_register() >= 0) && (dwarf_funcs != 0)):
		dw_type_die = new list[int]
		dw_type_queue = new list[int]
		dw_fixups = new list[int]
		int count = dwarf_funcs.length / dwarf_func_stride
		for f in range(count): dw_subprogram_emit(f)
		# Types queue more types (fields, pointees) as they are written
		int next = 0
		while (next < dw_type_queue.length):
			dw_type_emit(dw_type_queue[next])
			next = next + 1
		int i = 0
		while (i < dw_fixups.length):
			save_int(code + dw_fixups[i], dw_type_die[dw_fixups[i + 1]])
			i = i + 2

	emit_uleb(0) /* end of compile-unit children */
	save_int(code + dw_unit_start, codepos - dw_unit_start - 4)


############################### .debug_frame ###############################

# DW_CFA_advance_loc* from position from to position to.
void dw_cfa_advance(int from, int to):
	int delta = to - from
	if (delta <= 0): return;
	if (delta < 64): emit_int8(64 + delta)
	else if (delta < 256):
		emit_int8(2) /* DW_CFA_advance_loc1 */
		emit_int8(delta)
	else if (delta < 65536):
		emit_int8(3) /* DW_CFA_advance_loc2 */
		emit_int16(delta)
	else:
		emit_int8(4) /* DW_CFA_advance_loc4 */
		emit_int32(delta)


# Pad a CIE/FDE with DW_CFA_nop to a multiple of the address size and
# patch its length word.
void dw_cfa_finish(int start):
	while (((codepos - start) & (word_size - 1)) != 0): emit_int8(0)
	save_int(code + start, codepos - start - 4)


# .debug_frame for the x86/x64 frame-pointer functions: one CIE for the
# call-site state (CFA = sp + word, return address at CFA - word) and an
# FDE per function tracking push fp / mov fp,sp, and around each
# 'leave ; ret' the switch back to sp-based rules. Empty elsewhere.
void dwarf_frame_emit():
	if ((target_isa != 0) || (dwarf_funcs == 0)): return;
	int fp = dwarf_frame_register()
	int sp = 4
	int ra = 8
	if (word_size == 8):
		sp = 7
		ra = 16
	int cie = codepos
	emit_int32(0) /* length, patched */
	emit_int32(-1) /* CIE_id */
	emit_int8(1) /* version */
	emit_int8(0) /* augmentation "" */
	emit_uleb(1) /* code_alignment_factor */
	emit_sleb(0 - word_size) /* data_alignment_factor */
	emit_int8(ra) /* return_address_register */
	emit_int8(12) /* DW_CFA_def_cfa sp, word */
	emit_uleb(sp)
	emit_uleb(word_size)
	emit_int8(128 + ra) /* DW_CFA_offset ra, CFA - word */
	emit_uleb(1)
	dw_cfa_finish(cie)

	int leave = 0
	int count = dwarf_funcs.length / dwarf_func_stride
	for f in range(count):
		int record = f * dwarf_func_stride
		int start = dwarf_funcs[record + 1]
		int body = dwarf_funcs[record + 2]
		int end = dwarf_funcs[record + 3]
		int fde = codepos
		emit_int32(0) /* length, patched */
		emit_int32(0) /* CIE_pointer: the CIE opens .debug_frame */
		dw_address(start) /* initial_location */
		emit_target_word(end - start) /* address_range */
		dw_cfa_advance(start, start + 1) /* after push fp */
		emit_int8(14) /* DW_CFA_def_cfa_offset 2 words */
		emit_uleb(2 * word_size)
		emit_int8(128 + fp) /* DW_CFA_offset fp, CFA - 2 words */
		emit_uleb(2)
		dw_cfa_advance(start + 1, body) /* after mov fp,sp */
		emit_int8(13) /* DW_CFA_def_cfa_register fp */
		emit_uleb(fp)
		# Promoted-register pushes follow mov fp,sp: register i of the
		# mask (ascending order) sits at CFA - (3 + i) words
		int saved = dwarf_funcs[record + 8]
		int saved_index = 0
		for r in range(16):
			if (saved & (1 << r)):
				emit_int8(128 + r) /* DW_CFA_offset r */
				emit_uleb(3 + saved_index)
				saved_index = saved_index + 1
		int at = body
		while ((leave < dwarf_leaves.length) && (dwarf_leaves[leave] < f)): leave = leave + 2
		while ((leave < dwarf_leaves.length) && (dwarf_leaves[leave] == f)):
			int position = dwarf_leaves[leave + 1]
			if ((position >= at) && (position + 1 < end)):
				dw_cfa_advance(at, position + 1) /* after leave */
				emit_int8(10) /* DW_CFA_remember_state */
				emit_int8(12) /* DW_CFA_def_cfa sp, word */
				emit_uleb(sp)
				emit_uleb(word_size)
				emit_int8(192 + fp) /* DW_CFA_restore fp */
				for r in range(16):
					if (saved & (1 << r)): emit_int8(192 + r) /* DW_CFA_restore r */
				at = position + 1
				if (position + 2 < end):
					dw_cfa_advance(at, position + 2) /* after ret */
					emit_int8(11) /* DW_CFA_restore_state */
					at = position + 2
			leave = leave + 2
		dw_cfa_finish(fde)
