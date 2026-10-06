/*
DWARF subprograms, variables and types from retained semantics (#536).

Under -g the compiler retains the AST forest (compiler/retained_ast.w,
compiler/retained_semantic.w) and installs the two emitters below as
code_generator/dwarf.w's debug_abbrev_hook / debug_info_hook. The compile
unit then carries:

- one DW_TAG_subprogram per retained function definition, its pc range
  read from the function's symbol (address and the size the emitter
  recorded when the body closed) and its frame base the frame pointer
  the prologue set up (ebp / rbp / x29);
- DW_TAG_formal_parameter / DW_TAG_variable for the retained parameters
  and locals, located with DW_OP_fbreg from the same slot arithmetic
  sym_emit_value() compiles and the runtime variable notes (dwarf.w,
  debug_local_*) record for wdbg. A local is scoped to a
  DW_TAG_lexical_block spanning from its declaration to the first
  statement whose recorded stack depth no longer covers its slot (the
  rule wdbg's dbg_local_visible applies at a stop); stack discipline
  makes those ranges nest, so the blocks form a proper tree;
- DW_TAG_base_type / pointer_type / structure_type / union_type /
  typedef / const_type / enumeration_type / array_type / subroutine_type
  for every retained type those DIEs reach (retained_types), emitted
  once each after the subprograms and referenced with DW_FORM_ref4.

Nothing here runs without -g: default images keep dwarf.w's childless
unit byte for byte. Call-frame information (.debug_frame) is #536's
follow-up, so debuggers unwind outer frames with their own prologue
analysis; the frame-pointer chain the prologue keeps makes that exact on
x86/x64.
*/
import compiler.retained_ast


# Abbreviation codes. Every code that can own children also has a
# childless twin at code + dwarf_code_leaf, used when a DIE turns out to
# have none (DWARF consumers flag DW_CHILDREN_yes with no children).
const int dwarf_code_unit = 1
const int dwarf_code_subprogram = 2         # + 1: no return type; + 2: no frame base
const int dwarf_code_parameter = 6          # + 1: variable; + 2/3: untyped
const int dwarf_code_block = 10
const int dwarf_code_base = 11
const int dwarf_code_pointer = 12           # + 1: pointer to void
const int dwarf_code_structure = 14
const int dwarf_code_union = 15
const int dwarf_code_member = 16
const int dwarf_code_typedef = 17
const int dwarf_code_const = 18
const int dwarf_code_enumeration = 19
const int dwarf_code_enumerator = 20
const int dwarf_code_array = 21
const int dwarf_code_subrange = 22
const int dwarf_code_subroutine = 23        # + 1: void return
const int dwarf_code_subroutine_parameter = 25
const int dwarf_code_member_untyped = 26
const int dwarf_code_typedef_void = 27
const int dwarf_code_count = 27
const int dwarf_code_leaf = 64

# Set by -g (compiler/compiler.w): emit the rich unit.
int dwarf_types_mode

# Per-unit emission state. dwarf_type_dies[id] is the CU-relative DIE
# offset of retained type id, 0 while unassigned, -1 once queued.
int dwarf_unit_start
list[int] dwarf_type_dies
# Retained type id -> the newest record of the same compiler type. One
# compiler type can be retained more than once (a struct noted while its
# fields were still being declared, then again complete); within one
# compile the newest record is the complete one, so each compiler type
# gets a single DIE.
list[int] dwarf_type_canonical
list[int] dwarf_type_queue
list[int] dwarf_fixup_positions
list[int] dwarf_fixup_types
char* dwarf_last_path
int dwarf_last_file

# Counts for --stats and the tests.
int dwarf_subprograms_emitted
int dwarf_variables_emitted
int dwarf_types_emitted


void dwarf_abbrev_begin(int number, int tag, int children):
	emit_uleb(number)
	emit_uleb(tag)
	emit_int8(children)


void dwarf_abbrev_attr(int attribute, int form):
	emit_uleb(attribute)
	emit_uleb(form)


void dwarf_abbrev_end():
	emit_uleb(0)
	emit_uleb(0)


# DW_AT_name DW_FORM_string
void dwarf_abbrev_name():
	dwarf_abbrev_attr(3, 8)


# DW_AT_type DW_FORM_ref4
void dwarf_abbrev_type():
	dwarf_abbrev_attr(73, 19)


# DW_AT_low_pc / DW_AT_high_pc, both DW_FORM_addr (DWARF 2)
void dwarf_abbrev_range():
	dwarf_abbrev_attr(17, 1)
	dwarf_abbrev_attr(18, 1)


# DW_AT_decl_file / DW_AT_decl_line, both udata
void dwarf_abbrev_declared():
	dwarf_abbrev_attr(58, 15)
	dwarf_abbrev_attr(59, 15)


# 1 when DIEs with this abbreviation code can own children.
int dwarf_code_parent(int number):
	if ((number >= dwarf_code_subprogram) && (number < dwarf_code_parameter)): return 1
	if ((number == dwarf_code_structure) || (number == dwarf_code_union)): return 1
	if ((number == dwarf_code_enumeration) || (number == dwarf_code_array)): return 1
	if ((number == dwarf_code_subroutine) || (number == dwarf_code_subroutine + 1)): return 1
	return (number == dwarf_code_unit) || (number == dwarf_code_block)


# DW_TAG_* of an abbreviation code.
int dwarf_code_tag(int number):
	if (number == dwarf_code_unit): return 17 /* DW_TAG_compile_unit */
	if (number < dwarf_code_parameter): return 46 /* DW_TAG_subprogram */
	if ((number == dwarf_code_parameter) || (number == dwarf_code_parameter + 2)): return 5 /* DW_TAG_formal_parameter */
	if (number < dwarf_code_block): return 52 /* DW_TAG_variable */
	if (number == dwarf_code_block): return 11 /* DW_TAG_lexical_block */
	if (number == dwarf_code_base): return 36 /* DW_TAG_base_type */
	if (number <= dwarf_code_pointer + 1): return 15 /* DW_TAG_pointer_type */
	if (number == dwarf_code_structure): return 19 /* DW_TAG_structure_type */
	if (number == dwarf_code_union): return 23 /* DW_TAG_union_type */
	if ((number == dwarf_code_member) || (number == dwarf_code_member_untyped)): return 13 /* DW_TAG_member */
	if ((number == dwarf_code_typedef) || (number == dwarf_code_typedef_void)): return 22 /* DW_TAG_typedef */
	if (number == dwarf_code_const): return 38 /* DW_TAG_const_type */
	if (number == dwarf_code_enumeration): return 4 /* DW_TAG_enumeration_type */
	if (number == dwarf_code_enumerator): return 40 /* DW_TAG_enumerator */
	if (number == dwarf_code_array): return 1 /* DW_TAG_array_type */
	if (number == dwarf_code_subrange): return 33 /* DW_TAG_subrange_type */
	if (number == dwarf_code_subroutine_parameter): return 5 /* DW_TAG_formal_parameter */
	return 21 /* DW_TAG_subroutine_type */


# One abbreviation: its code (number, or its leaf twin), tag, children
# flag and attribute list.
void dwarf_abbrev_entry(int number, int children):
	int code = number
	if ((children == 0) && dwarf_code_parent(number)): code = number + dwarf_code_leaf
	dwarf_abbrev_begin(code, dwarf_code_tag(number), children)
	if (number == dwarf_code_unit):
		dwarf_abbrev_name()
		dwarf_abbrev_attr(16, 6) /* DW_AT_stmt_list data4 */
		dwarf_abbrev_range()
		dwarf_abbrev_attr(19, 11) /* DW_AT_language data1 */
		dwarf_abbrev_attr(37, 8) /* DW_AT_producer string */
	else if (number < dwarf_code_parameter):
		int variant = number - dwarf_code_subprogram
		dwarf_abbrev_name()
		dwarf_abbrev_declared()
		if ((variant & 1) == 0): dwarf_abbrev_type()
		dwarf_abbrev_range()
		if ((variant & 2) == 0): dwarf_abbrev_attr(64, 10) /* DW_AT_frame_base block1 */
		dwarf_abbrev_attr(63, 12) /* DW_AT_external flag */
	else if (number < dwarf_code_block):
		dwarf_abbrev_name()
		dwarf_abbrev_declared()
		if (number < dwarf_code_parameter + 2): dwarf_abbrev_type()
		dwarf_abbrev_attr(2, 10) /* DW_AT_location block1 */
	else if (number == dwarf_code_block): dwarf_abbrev_range()
	else if (number == dwarf_code_base):
		dwarf_abbrev_name()
		dwarf_abbrev_attr(62, 11) /* DW_AT_encoding data1 */
		dwarf_abbrev_attr(11, 15) /* DW_AT_byte_size udata */
	else if (number <= dwarf_code_pointer + 1):
		dwarf_abbrev_attr(11, 11) /* DW_AT_byte_size data1 */
		if (number == dwarf_code_pointer): dwarf_abbrev_type()
	else if ((number == dwarf_code_structure) || (number == dwarf_code_union) || (number == dwarf_code_enumeration)):
		dwarf_abbrev_name()
		dwarf_abbrev_attr(11, 15) /* DW_AT_byte_size udata */
	else if ((number == dwarf_code_member) || (number == dwarf_code_member_untyped)):
		dwarf_abbrev_name()
		if (number == dwarf_code_member): dwarf_abbrev_type()
		dwarf_abbrev_attr(56, 10) /* DW_AT_data_member_location block1 */
	else if ((number == dwarf_code_typedef) || (number == dwarf_code_typedef_void)):
		dwarf_abbrev_name()
		if (number == dwarf_code_typedef): dwarf_abbrev_type()
	else if (number == dwarf_code_enumerator):
		dwarf_abbrev_name()
		dwarf_abbrev_attr(28, 13) /* DW_AT_const_value sdata */
	else if (number == dwarf_code_subrange): dwarf_abbrev_attr(47, 15) /* DW_AT_upper_bound udata */
	else if (number != dwarf_code_subroutine + 1): dwarf_abbrev_type()
	dwarf_abbrev_end()


# The whole .debug_abbrev table of a rich unit (debug_abbrev_hook).
void dwarf_types_abbrev_emit():
	for number in range(1, dwarf_code_count + 1):
		int parent = dwarf_code_parent(number)
		dwarf_abbrev_entry(number, parent)
		if (parent && (number != dwarf_code_unit) && (number != dwarf_code_block)): dwarf_abbrev_entry(number, 0)
	emit_int8(0) /* end of abbreviations */


################################## types ######################################

int dwarf_type_valid(int id):
	if ((retained_types == 0) || (id < 0)): return 0
	return id < retained_types.length


# 1 when retained type id has a DIE to reference; 0 for void, the size-0
# pseudo types ("constant", "string value", ...) and anything built only
# on them. Pointers are always describable (a void pointer at worst), so
# the recursion below never follows a pointer and cannot cycle.
int dwarf_type_usable(int id):
	int depth = 0
	while (depth < 64):
		if (dwarf_type_valid(id) == 0): return 0
		retained_type* type = retained_types[id]
		if (type.pointer_level > 0): return 1
		if ((type.kind == type_kind_alias) || (type.kind == type_kind_gpu)): return 1
		if ((type.kind == type_kind_function) || (type.kind == type_kind_enum)): return 1
		if (type.kind == type_kind_array): return 1
		if (type.kind == type_kind_const):
			id = type.target
			depth = depth + 1
			continue
		if (type.fields.length > 0): return 1
		return type.size > 0
	return 0


# DW_AT_type (DW_FORM_ref4): the DIE offset when it is known, otherwise
# a placeholder patched by dwarf_types_patch once the type is emitted.
void dwarf_type_ref(int id):
	id = dwarf_type_canonical[id]
	int die = dwarf_type_dies[id]
	if (die > 0):
		emit_int32(die)
		return
	if (die == 0):
		dwarf_type_dies[id] = -1
		dwarf_type_queue.push(id)
	dwarf_fixup_positions.push(codepos)
	dwarf_fixup_types.push(id)
	emit_int32(0)


# DW_ATE_* for a field-less scalar, by the built-in type's name.
int dwarf_base_encoding(char* name):
	if (starts_with(name, c"float")): return 4 /* DW_ATE_float */
	if (strcmp(name, c"bool") == 0): return 2 /* DW_ATE_boolean */
	if (strcmp(name, c"char") == 0): return 6 /* DW_ATE_signed_char */
	if ((strcmp(name, c"byte") == 0) || (strcmp(name, c"uint8") == 0)): return 8 /* DW_ATE_unsigned_char */
	if (starts_with(name, c"int")): return 5 /* DW_ATE_signed */
	return 7 /* DW_ATE_unsigned: uint*, pointer, runtime handles */


# DW_AT_data_member_location block1: DW_OP_plus_uconst offset (DWARF 2).
void dwarf_member_location(int offset):
	int length_at = codepos
	emit_int8(0)
	emit_int8(35)
	emit_uleb(offset)
	code[length_at] = codepos - length_at - 1


void dwarf_member_emit(retained_field* field):
	if (dwarf_type_usable(field.type)):
		emit_uleb(dwarf_code_member)
		emit_string(field.name)
		dwarf_type_ref(field.type)
	else:
		emit_uleb(dwarf_code_member_untyped)
		emit_string(field.name)
	dwarf_member_location(field.offset)


# A W fixed array value is a {data, length} header followed by its
# elements (type_push_array, type_array_element_offset), in a local slot
# and in a struct field alike. It is described as that structure, with
# its pointer, length and element-array types nested inside it.
void dwarf_fixed_array_emit(retained_type* type):
	int element = dwarf_type_usable(type.target)
	emit_uleb(dwarf_code_structure)
	emit_string(type.name)
	emit_uleb(type.size)
	int pointer = codepos - dwarf_unit_start
	if (element):
		emit_uleb(dwarf_code_pointer)
		emit_int8(word_size)
		dwarf_type_ref(type.target)
	else:
		emit_uleb(dwarf_code_pointer + 1)
		emit_int8(word_size)
	int length = codepos - dwarf_unit_start
	emit_uleb(dwarf_code_base)
	emit_string(c"int")
	emit_int8(5) /* DW_ATE_signed */
	emit_uleb(word_size)
	int items = codepos - dwarf_unit_start
	if (element):
		if (type.array_length > 0):
			emit_uleb(dwarf_code_array)
			dwarf_type_ref(type.target)
			emit_uleb(dwarf_code_subrange)
			emit_uleb(type.array_length - 1)
			emit_uleb(0)
		else:
			emit_uleb(dwarf_code_array + dwarf_code_leaf)
			dwarf_type_ref(type.target)
	emit_uleb(dwarf_code_member)
	emit_string(c"data")
	emit_int32(pointer)
	dwarf_member_location(0)
	emit_uleb(dwarf_code_member)
	emit_string(c"length")
	emit_int32(length)
	dwarf_member_location(word_size)
	if (element):
		emit_uleb(dwarf_code_member)
		emit_string(c"items")
		emit_int32(items)
		dwarf_member_location(2 * word_size)
	emit_uleb(0)


void dwarf_type_emit(int id):
	retained_type* type = retained_types[id]
	dwarf_type_dies[id] = codepos - dwarf_unit_start
	dwarf_types_emitted = dwarf_types_emitted + 1
	if (type.pointer_level > 0):
		if (dwarf_type_usable(type.target)):
			emit_uleb(dwarf_code_pointer)
			emit_int8(word_size)
			dwarf_type_ref(type.target)
		else:
			emit_uleb(dwarf_code_pointer + 1)
			emit_int8(word_size)
		return
	if ((type.kind == type_kind_alias) || (type.kind == type_kind_gpu)):
		if (dwarf_type_usable(type.target)):
			emit_uleb(dwarf_code_typedef)
			emit_string(type.name)
			dwarf_type_ref(type.target)
		else:
			emit_uleb(dwarf_code_typedef_void)
			emit_string(type.name)
		return
	if (type.kind == type_kind_const):
		emit_uleb(dwarf_code_const)
		dwarf_type_ref(type.target)
		return
	if (type.kind == type_kind_array):
		dwarf_fixed_array_emit(type)
		return
	if (type.kind == type_kind_function):
		int parameters = 0
		for i in range(type.parameters.length):
			if (dwarf_type_usable(type.parameters[i])): parameters = parameters + 1
		int code = dwarf_code_subroutine
		if (dwarf_type_usable(type.return_type) == 0): code = code + 1
		if (parameters == 0): code = code + dwarf_code_leaf
		emit_uleb(code)
		if (dwarf_type_usable(type.return_type)): dwarf_type_ref(type.return_type)
		if (parameters == 0): return
		for i in range(type.parameters.length):
			if (dwarf_type_usable(type.parameters[i])):
				emit_uleb(dwarf_code_subroutine_parameter)
				dwarf_type_ref(type.parameters[i])
		emit_uleb(0)
		return
	int size = type.size
	if (type.kind == type_kind_enum):
		if (size <= 0): size = word_size
		if (type.constants.length == 0):
			emit_uleb(dwarf_code_enumeration + dwarf_code_leaf)
			emit_string(type.name)
			emit_uleb(size)
			return
		emit_uleb(dwarf_code_enumeration)
		emit_string(type.name)
		emit_uleb(size)
		for i in range(type.constants.length):
			retained_constant* member = type.constants[i]
			emit_uleb(dwarf_code_enumerator)
			emit_string(member.name)
			emit_sleb(member.value)
		emit_uleb(0)
		return
	if ((type.fields.length > 0) || (size > word_size)):
		# Structs and unions, plus the multi-word runtime values (slices
		# and friends) as opaque aggregates of the right size.
		int code = dwarf_code_structure
		if (type.kind == type_kind_union): code = dwarf_code_union
		if (type.fields.length == 0): code = code + dwarf_code_leaf
		emit_uleb(code)
		emit_string(type.name)
		emit_uleb(size)
		if (type.fields.length == 0): return
		for i in range(type.fields.length): dwarf_member_emit(type.fields[i])
		emit_uleb(0)
		return
	emit_uleb(dwarf_code_base)
	emit_string(type.name)
	emit_int8(dwarf_base_encoding(type.name))
	emit_uleb(size)


# Emit every queued type (each may queue more), then resolve the
# placeholders dwarf_type_ref left behind.
void dwarf_types_flush():
	while (dwarf_type_queue.length > 0):
		int id = dwarf_type_queue.pop()
		if (dwarf_type_dies[id] < 0): dwarf_type_emit(id)
	for i in range(dwarf_fixup_positions.length):
		save_int(code + dwarf_fixup_positions[i], dwarf_type_dies[dwarf_fixup_types[i]])


############################# subprograms ######################################

# DWARF register number of the frame pointer the prologue sets up, or -1.
int dwarf_frame_register():
	if (target_isa == 0):
		if (word_size == 8): return 6 /* rbp */
		return 5 /* ebp */
	if (target_isa == 1): return 29 /* x29 */
	return -1


# A DW_FORM_addr for code offset pos (see debug_info_emit_at).
void dwarf_addr_emit(int pos):
	if (target_os == 1):
		emit_int32(pos)
		emit_int32(1)
	else: emit_target_word(pos + code_offset)


# Line-table file number (1-based) for a path; 0 when unregistered.
int dwarf_file_number(char* path):
	if (path == 0): return 0
	if ((path == dwarf_last_path) && (dwarf_last_file > 0)): return dwarf_last_file
	int found = 0
	for i in range(debug_file_count):
		if (strcmp(debug_file_name(i), path) == 0):
			found = i + 1
			break
	dwarf_last_path = path
	dwarf_last_file = found
	return found


# Runtime variable note matching a retained parameter or local: the first
# unused note at or after 'from' inside [start, end) with the same name,
# slot and kind. Notes are recorded in codepos order.
int dwarf_note_find(int from, int end, char* name, int slot, int kind):
	int i = from
	while (i < debug_local_count):
		if (load_int(debug_local_addresses + i * 4) >= end): return -1
		if ((load_int(debug_local_slots + i * 4) == slot) && (load_int(debug_local_kinds + i * 4) == kind)):
			if (strcmp(cast(char*, load_ptr(debug_local_names + i * __word_size__)), name) == 0): return i
		i = i + 1
	return -1


# First runtime variable note with an address at or after pos.
int dwarf_note_lower_bound(int pos):
	int low = 0
	int high = debug_local_count
	while (low < high):
		int mid = (low + high) / 2
		if (load_int(debug_local_addresses + mid * 4) < pos): low = mid + 1
		else: high = mid
	return low


# End of a local's live range: the first statement after its declaration
# whose recorded stack depth no longer covers the slot, else the function
# end (wdbg's dbg_local_visible rule, as a pc range).
int dwarf_local_end(int declared, int slot, int end):
	int low = 0
	int high = debug_line_count
	while (low < high):
		int mid = (low + high) / 2
		if (load_int(debug_line_addresses + mid * 4) <= declared): low = mid + 1
		else: high = mid
	int i = low
	while (i < debug_line_count):
		int address = load_int(debug_line_addresses + i * 4)
		if (address >= end): return end
		if (load_int(debug_line_stack_pos + i * 4) <= slot): return address
		i = i + 1
	return end


# Stack words a variable occupies (sym_emit_value's type_stack_words).
int dwarf_stack_words(int note, int type):
	if (note >= 0): return type_stack_words(load_int(debug_local_types + note * 4))
	if ((dwarf_type_valid(type) == 0) || (retained_types[type].pointer_level > 0)): return 1
	int size = retained_types[type].size
	if (size <= word_size): return 1
	return (size + word_size - 1) / word_size


void dwarf_variable_emit(retained_binding* binding, int offset):
	int abbrev = dwarf_code_parameter
	if (binding.scope == 'L'): abbrev = abbrev + 1
	int typed = dwarf_type_usable(binding.type)
	if (typed == 0): abbrev = abbrev + 2
	emit_uleb(abbrev)
	emit_string(binding.name)
	emit_uleb(dwarf_file_number(binding.file))
	emit_uleb(binding.line)
	if (typed): dwarf_type_ref(binding.type)
	int length_at = codepos
	emit_int8(0)
	emit_int8(145) /* DW_OP_fbreg */
	emit_sleb(offset)
	code[length_at] = codepos - length_at - 1
	dwarf_variables_emitted = dwarf_variables_emitted + 1


# Parameters, then locals nested in lexical blocks by live range. Ranges
# of stack slots nest (a local declared while another is live has a
# higher slot and dies no later), so sorting by (start, -end) and keeping
# a stack of open blocks yields a proper tree; any range that would cross
# its enclosing block is clamped to it.
void dwarf_function_variables(list[int] locals, int start, int end, int note_index):
	int frame_words = load_int(debug_func_frame_words + note_index * 4)
	int arguments = load_int(debug_func_arg_words + note_index * 4)
	int count = locals.length
	int* lows = cast(int*, malloc((count + 1) * __word_size__))
	int* highs = cast(int*, malloc((count + 1) * __word_size__))
	int* offsets = cast(int*, malloc((count + 1) * __word_size__))
	int* order = cast(int*, malloc((count + 1) * __word_size__))
	int cursor = dwarf_note_lower_bound(start)
	int argument_cursor = cursor
	int ordered = 0
	for i in range(count):
		retained_binding* binding = retained_bindings[retained_nodes[locals[i]].binding]
		int slot = binding.slot
		int note = -1
		if (binding.scope == 'A'): note = dwarf_note_find(argument_cursor, end, binding.name, slot, 'A')
		else: note = dwarf_note_find(cursor, end, binding.name, slot, 'L')
		int words = dwarf_stack_words(note, binding.type)
		lows[i] = start
		highs[i] = end
		if (binding.scope == 'A'):
			if (note >= 0): argument_cursor = note + 1
			offsets[i] = (frame_words + arguments - slot + 1 - (words - 1)) * word_size
		else:
			if (note >= 0):
				cursor = note + 1
				lows[i] = load_int(debug_local_addresses + note * 4)
				if (lows[i] < start): lows[i] = start
				highs[i] = dwarf_local_end(lows[i], slot, end)
			offsets[i] = (frame_words - slot - 1 - (words - 1)) * word_size
		# Insertion sort by (low ascending, high descending), stable.
		int at = ordered
		while ((at > 0) && ((lows[order[at - 1]] > lows[i]) || ((lows[order[at - 1]] == lows[i]) && (highs[order[at - 1]] < highs[i])))):
			order[at] = order[at - 1]
			at = at - 1
		order[at] = i
		ordered = ordered + 1
	list[int] block_lows = new list[int]
	list[int] block_highs = new list[int]
	for k in range(count):
		int i = order[k]
		int low = lows[i]
		int high = highs[i]
		while ((block_highs.length > 0) && (low >= block_highs[block_highs.length - 1])):
			block_lows.pop()
			block_highs.pop()
			emit_uleb(0) /* end of the lexical block */
		if (block_highs.length > 0):
			if (high > block_highs[block_highs.length - 1]): high = block_highs[block_highs.length - 1]
		int same = (low <= start) && (high >= end)
		if (block_highs.length > 0):
			same = (low == block_lows[block_lows.length - 1]) && (high == block_highs[block_highs.length - 1])
		if ((same == 0) && (high > low)):
			emit_uleb(dwarf_code_block)
			dwarf_addr_emit(low)
			dwarf_addr_emit(high)
			block_lows.push(low)
			block_highs.push(high)
		dwarf_variable_emit(retained_bindings[retained_nodes[locals[i]].binding], offsets[i])
	while (block_highs.length > 0):
		block_highs.pop()
		emit_uleb(0)
	block_lows.free()
	block_highs.free()
	free(cast(char*, lows))
	free(cast(char*, highs))
	free(cast(char*, offsets))
	free(cast(char*, order))


# Symbol-table offset of a retained function node's definition, or -1.
int dwarf_function_symbol(retained_node* node):
	int sym = -1
	if ((node.binding >= 0) && (retained_bindings != 0) && (node.binding < retained_bindings.length)):
		sym = retained_bindings[node.binding].origin
	else: sym = sym_probe(node.name)
	if ((sym < 0) || (sym >= table_pos)): return -1
	if (table[sym + 1] != 'D'): return -1
	if (load_int(table + sym + 10) != 2): return -1
	if (load_int(table + sym + 138) != 0): return -1 /* gpu kernel: no host code */
	if (load_int(table + sym + 14) <= 0): return -1
	return sym


void dwarf_subprogram_emit(int function, list[int] locals, int text_end):
	retained_node* node = retained_nodes[function]
	int sym = dwarf_function_symbol(node)
	if (sym < 0): return
	int start = load_int(table + sym + 2) - code_offset
	int end = start + load_int(table + sym + 14)
	if ((start < 0) || (end > text_end)): return
	char* file = retained_sources[node.source].path
	int line = node.line
	int return_type = -1
	if (node.binding >= 0):
		retained_binding* binding = retained_bindings[node.binding]
		file = binding.file
		line = binding.line
		return_type = binding.type
	int note_index = debug_func_find(start)
	int frame_register = dwarf_frame_register()
	int framed = (note_index >= 0) && (frame_register >= 0)
	if (framed): framed = load_int(debug_func_frame_words + note_index * 4) > 0
	int typed = dwarf_type_usable(return_type)
	int abbrev = dwarf_code_subprogram
	if (typed == 0): abbrev = abbrev + 1
	if (framed == 0): abbrev = abbrev + 2
	int children = framed && (locals.length > 0)
	if (children == 0): abbrev = abbrev + dwarf_code_leaf
	emit_uleb(abbrev)
	emit_string(node.name)
	emit_uleb(dwarf_file_number(file))
	emit_uleb(line)
	if (typed): dwarf_type_ref(return_type)
	dwarf_addr_emit(start)
	dwarf_addr_emit(end)
	if (framed):
		emit_int8(2)
		emit_int8(112 + frame_register) /* DW_OP_breg<fp> 0 */
		emit_sleb(0)
	emit_int8(1) /* DW_AT_external */
	dwarf_subprograms_emitted = dwarf_subprograms_emitted + 1
	if (children == 0): return
	dwarf_function_variables(locals, start, end, note_index)
	emit_uleb(0) /* end of the subprogram's children */


# The rich unit's trailing attributes and children (debug_info_hook).
void dwarf_types_info_emit(int unit_start, int text_start):
	emit_int8(12) /* DW_AT_language: DW_LANG_C99, the closest expression syntax */
	emit_string(c"w") /* DW_AT_producer */
	dwarf_unit_start = unit_start
	dwarf_last_path = 0
	dwarf_last_file = 0
	dwarf_type_dies = new list[int]
	dwarf_type_queue = new list[int]
	dwarf_fixup_positions = new list[int]
	dwarf_fixup_types = new list[int]
	dwarf_type_canonical = new list[int]
	if (retained_types != 0):
		map[int, int] newest = new map[int, int]
		for i in range(retained_types.length):
			dwarf_type_dies.push(0)
			newest[retained_types[i].origin] = i
		for i in range(retained_types.length): dwarf_type_canonical.push(newest[retained_types[i].origin])
		newest.free()
	# Sanity bound only: every DWARF payload follows the code.
	int text_end = codepos
	int count = 0
	if (retained_nodes != 0): count = retained_nodes.length
	# Owning function of every node, and the definition chosen for each
	# function symbol: a prototype and its body share a symbol, and only
	# a node that owns statements (not just parameter inventory) is a body.
	int* owners = cast(int*, malloc((count + 1) * __word_size__))
	int* bodies = cast(int*, malloc((count + 1) * __word_size__))
	for i in range(count):
		retained_node* node = retained_nodes[i]
		int owner = -1
		int parent = node.parent
		if ((parent >= 0) && (parent < i)):
			if (retained_nodes[parent].kind == retained_function): owner = parent
			else: owner = owners[parent]
		owners[i] = owner
		bodies[i] = 0
		if ((owner >= 0) && (node.kind != retained_local)): bodies[owner] = 1
	map[int, int] chosen = new map[int, int]
	list[int] functions = new list[int]
	for i in range(count):
		retained_node* node = retained_nodes[i]
		if (node.kind != retained_function): continue
		int sym = dwarf_function_symbol(node)
		if (sym < 0): continue
		if (sym in chosen):
			int slot = chosen[sym]
			if ((bodies[functions[slot]] == 0) && bodies[i]): functions[slot] = i
		else:
			chosen[sym] = functions.length
			functions.push(i)
	# Each function's own parameters and locals, in declaration order,
	# threaded through 'links' (one pass over the forest).
	map[int, int] function_slots = new map[int, int]
	int* heads = cast(int*, malloc((functions.length + 1) * __word_size__))
	int* tails = cast(int*, malloc((functions.length + 1) * __word_size__))
	for k in range(functions.length):
		function_slots[functions[k]] = k
		heads[k] = -1
		tails[k] = -1
	# Each owners[i] is read once, before links[i] reuses its cell.
	int* links = owners
	for i in range(count):
		retained_node* node = retained_nodes[i]
		int owner = owners[i]
		links[i] = -1
		if ((node.kind != retained_local) || (owner < 0) || (node.binding < 0)): continue
		if ((owner in function_slots) == 0): continue
		retained_binding* binding = retained_bindings[node.binding]
		if ((binding.scope != 'L') && (binding.scope != 'A')): continue
		int slot_index = function_slots[owner]
		if (tails[slot_index] < 0): heads[slot_index] = i
		else: links[tails[slot_index]] = i
		tails[slot_index] = i
	list[int] locals = new list[int]
	for k in range(functions.length):
		locals.clear()
		int local = heads[k]
		while (local >= 0):
			locals.push(local)
			local = links[local]
		dwarf_subprogram_emit(functions[k], locals, text_end)
	free(cast(char*, heads))
	free(cast(char*, tails))
	dwarf_types_flush()
	locals.free()
	function_slots.free()
	functions.free()
	chosen.free()
	free(cast(char*, owners))
	free(cast(char*, bodies))
	dwarf_type_dies.free()
	dwarf_type_canonical.free()
	dwarf_type_queue.free()
	dwarf_fixup_positions.free()
	dwarf_fixup_types.free()


# -g: retain the forest and install the rich emitters (compiler/compiler.w).
void dwarf_types_enable():
	dwarf_types_mode = 1
	debug_abbrev_hook = cast(int, dwarf_types_abbrev_emit)
	debug_info_hook = cast(int, dwarf_types_info_emit)


# Per-compile reset (link_impl): the default is the childless unit.
void dwarf_types_reset():
	dwarf_types_mode = 0
	debug_abbrev_hook = 0
	debug_info_hook = 0
	dwarf_subprograms_emitted = 0
	dwarf_variables_emitted = 0
	dwarf_types_emitted = 0
