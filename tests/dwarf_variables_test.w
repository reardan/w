/*
DIE-level regression test for -g's DWARF subprograms, variables and
types (code_generator/dwarf_types.w, issue #536).

The build target compiles tests/dwarf_variables_fixture.w with -g for
x86, x64 and arm64 (plus a default x86 image), and this program walks
each -g image's .debug_abbrev and .debug_info with a small DIE reader
(lib/stack_trace.w only reads the line table) and asserts:
 - the unit parses form by form and ends exactly at unit_length, every
   DW_AT_type reference lands on a DIE, and every lexical block lies
   inside its parent's pc range;
 - probe/shapes/main are subprograms whose pc ranges are their .symtab
   ranges and whose frame base is the frame pointer (ebp/rbp/x29);
 - parameters and locals carry the DW_OP_fbreg offsets of the slot
   arithmetic, nested locals sit in nested lexical blocks, and their
   types resolve to base, pointer, structure, enumeration, typedef and
   fixed-array (header + element array) DIEs;
 - on x86 and x64 the running fixture's own frame agrees: argument and
   local address differences, the argument values at the described
   slots and the return address one word above the frame base;
 - -g changes no code: the default and -g images share every byte from
   the end of the build-id note to the end of .text.
*/
import lib.lib
import lib.assert
import lib.process
import libs.asm.binary_reader


struct dwarf_die:
	int offset          # CU-relative
	int tag
	int depth
	int parent          # index of the parent DIE, -1 for the unit
	char* name
	int low_pc
	int high_pc
	int type_ref        # CU-relative DIE offset, -1 when absent
	int has_location
	int fbreg
	int frame_register  # DW_OP_breg<n> of DW_AT_frame_base, -1 when absent
	int byte_size
	int encoding
	int const_value
	int member_offset
	int upper_bound
	int language
	char* producer


# Abbreviations by code: tag, children flag and an attribute/form list.
int* abbrev_tags
int* abbrev_children
int* abbrev_specs
int abbrev_limit = 256


int read_uleb(char* data, int* at):
	int result = 0
	int shift = 0
	while (1):
		int b = asm_read_u8(data, *at)
		*at = *at + 1
		result = result | ((b & 127) << shift)
		shift = shift + 7
		if ((b & 128) == 0): return result


int read_sleb(char* data, int* at):
	int result = 0
	int shift = 0
	int b = 0
	while (1):
		b = asm_read_u8(data, *at)
		*at = *at + 1
		result = result | ((b & 127) << shift)
		shift = shift + 7
		if ((b & 128) == 0): break
	if ((shift < 8 * __word_size__) && ((b & 64) != 0)): result = result | (0 - (1 << shift))
	return result


# File offset of the named section; its size is stored through size_out.
int section_find(asm_binary* binary, char* want, int* size_out):
	char* data = binary.data
	int is64 = binary.elf_class == ASM_ELF_CLASS64
	int shoff_at = 32
	int shentsize_at = 46
	int shnum_at = 48
	int shstrndx_at = 50
	int sh_offset_at = 16
	int sh_size_at = 20
	if (is64):
		shoff_at = 40
		shentsize_at = 58
		shnum_at = 60
		shstrndx_at = 62
		sh_offset_at = 24
		sh_size_at = 32
	int shoff = asm_read_word(data, shoff_at, binary.elf_class)
	int shentsize = asm_read_u16(data, shentsize_at)
	int shnum = asm_read_u16(data, shnum_at)
	int shstr_header = shoff + asm_read_u16(data, shstrndx_at) * shentsize
	int shstr_offset = asm_read_word(data, shstr_header + sh_offset_at, binary.elf_class)
	for index in range(shnum):
		int header = shoff + index * shentsize
		if (strcmp(data + shstr_offset + asm_read_u32(data, header), want) == 0):
			*size_out = asm_read_word(data, header + sh_size_at, binary.elf_class)
			return asm_read_word(data, header + sh_offset_at, binary.elf_class)
	print(c"missing section: ")
	println(want)
	exit(1)
	return 0


void abbrevs_read(char* data, int at):
	abbrev_tags = cast(int*, malloc(abbrev_limit * __word_size__))
	abbrev_children = cast(int*, malloc(abbrev_limit * __word_size__))
	abbrev_specs = cast(int*, malloc(abbrev_limit * __word_size__))
	for i in range(abbrev_limit): abbrev_tags[i] = 0
	while (1):
		int code = read_uleb(data, &at)
		if (code == 0): return
		asserts(c"abbreviation code in range", code < abbrev_limit)
		asserts(c"abbreviation code defined once", abbrev_tags[code] == 0)
		abbrev_tags[code] = read_uleb(data, &at)
		abbrev_children[code] = asm_read_u8(data, at)
		at = at + 1
		abbrev_specs[code] = at
		while (1):
			int attribute = read_uleb(data, &at)
			int form = read_uleb(data, &at)
			if ((attribute == 0) && (form == 0)): break


dwarf_die* die_new(int offset, int tag, int depth, int parent):
	dwarf_die* die = new dwarf_die
	die.offset = offset
	die.tag = tag
	die.depth = depth
	die.parent = parent
	die.name = c""
	die.low_pc = 0
	die.high_pc = 0
	die.type_ref = -1
	die.has_location = 0
	die.fbreg = 0
	die.frame_register = -1
	die.byte_size = -1
	die.encoding = -1
	die.const_value = 0
	die.member_offset = -1
	die.upper_bound = -1
	die.language = -1
	die.producer = c""
	return die


# Decode one block1 location-ish attribute into the DIE.
void die_block(dwarf_die* die, int attribute, char* data, int at, int length):
	int end = at + length
	int op = asm_read_u8(data, at)
	at = at + 1
	if ((attribute == 2) && (op == 145)): /* DW_AT_location: DW_OP_fbreg */
		die.has_location = 1
		die.fbreg = read_sleb(data, &at)
	if ((attribute == 64) && (op >= 112) && (op < 144)): /* DW_AT_frame_base: DW_OP_breg<n> */
		die.frame_register = op - 112
		assert_equal(0, read_sleb(data, &at))
	if ((attribute == 56) && (op == 35)): /* DW_AT_data_member_location: DW_OP_plus_uconst */
		die.member_offset = read_uleb(data, &at)
	assert_equal(end, at)


# Walk the unit at file offset 'info'; returns every DIE in order.
list[dwarf_die*] dies_read(char* data, int info, int word_size):
	int unit_length = asm_read_u32(data, info)
	assert_equal(2, asm_read_u16(data, info + 4))
	assert_equal(word_size, asm_read_u8(data, info + 10))
	int end = info + 4 + unit_length
	int at = info + 11
	list[dwarf_die*] dies = new list[dwarf_die*]
	list[int] parents = new list[int]
	int depth = 0
	while (at < end):
		int offset = at - info
		int code = read_uleb(data, &at)
		if (code == 0):
			asserts(c"null entry closes an open parent", depth > 0)
			depth = depth - 1
			parents.pop()
			continue
		asserts(c"DIE uses a defined abbreviation", (code < abbrev_limit) && (abbrev_tags[code] != 0))
		int parent = -1
		if (parents.length > 0): parent = parents[parents.length - 1]
		dwarf_die* die = die_new(offset, abbrev_tags[code], depth, parent)
		int spec = abbrev_specs[code]
		while (1):
			int attribute = read_uleb(data, &spec)
			int form = read_uleb(data, &spec)
			if ((attribute == 0) && (form == 0)): break
			int value = 0
			if (form == 1):
				value = asm_read_u32(data, at)
				if (word_size == 8): assert_equal(0, asm_read_u32(data, at + 4))
				at = at + word_size
			else if (form == 10):
				int length = asm_read_u8(data, at)
				die_block(die, attribute, data, at + 1, length)
				at = at + 1 + length
			else if ((form == 11) || (form == 12)):
				value = asm_read_u8(data, at)
				at = at + 1
			else if (form == 5):
				value = asm_read_u16(data, at)
				at = at + 2
			else if ((form == 6) || (form == 19)):
				value = asm_read_u32(data, at)
				at = at + 4
			else if (form == 8):
				char* text = data + at
				at = at + strlen(text) + 1
				if (attribute == 3): die.name = text
				if (attribute == 37): die.producer = text
			else if (form == 13): value = read_sleb(data, &at)
			else if (form == 15): value = read_uleb(data, &at)
			else:
				print(c"unexpected form ")
				println(itoa(form))
				exit(1)
			if (attribute == 17): die.low_pc = value
			if (attribute == 18): die.high_pc = value
			if (attribute == 73): die.type_ref = value
			if (attribute == 11): die.byte_size = value
			if (attribute == 62): die.encoding = value
			if (attribute == 28): die.const_value = value
			if (attribute == 47): die.upper_bound = value
			if (attribute == 19): die.language = value
		dies.push(die)
		if (abbrev_children[code]):
			parents.push(dies.length - 1)
			depth = depth + 1
	asserts(c"unit ends exactly at unit_length", at == end)
	asserts(c"every parent closed", depth == 0)
	parents.free()
	return dies


int die_at(list[dwarf_die*] dies, int offset):
	for i in range(dies.length):
		if (dies[i].offset == offset): return i
	return -1


# The DIE a DW_AT_type points at (asserted to exist).
dwarf_die* die_type(list[dwarf_die*] dies, dwarf_die* die):
	int index = die_at(dies, die.type_ref)
	asserts(c"DW_AT_type resolves", index >= 0)
	return dies[index]


# First DIE with this tag and name under DIE 'within' (any depth), or -1.
int die_find(list[dwarf_die*] dies, int within, int tag, char* name):
	for i in range(dies.length):
		dwarf_die* die = dies[i]
		if ((die.tag != tag) || (strcmp(die.name, name) != 0)): continue
		int up = die.parent
		while ((up >= 0) && (up != within)): up = dies[up].parent
		if ((within < 0) || (up == within)): return i
	print(c"missing DIE: ")
	println(name)
	exit(1)
	return -1


# The innermost lexical block (or the subprogram) enclosing DIE i.
dwarf_die* die_scope(list[dwarf_die*] dies, int i):
	return dies[dies[i].parent]


void expect_base_int(list[dwarf_die*] dies, dwarf_die* die, int word_size):
	dwarf_die* type = die_type(dies, die)
	assert_equal(36, type.tag) /* DW_TAG_base_type */
	assert_strings_equal(c"int", type.name)
	assert_equal(word_size, type.byte_size)
	assert_equal(5, type.encoding) /* DW_ATE_signed */


int member_offset(list[dwarf_die*] dies, int structure, char* name):
	return dies[die_find(dies, structure, 13, name)].member_offset


# The fixture's stdout, one integer per line.
list[int] fixture_output(char* path):
	char** args = strv_new(1)
	strv_set(args, 0, path)
	process_result* result = process_run(path, args, 0, 0, 30000)
	free(cast(void*, args))
	asserts(c"fixture ran", result != 0)
	assert_equal(0, result.status)
	list[int] values = new list[int]
	char* text = result.stdout_text
	int at = 0
	while (text[at] != 0):
		values.push(atoi(&text[at]))
		while ((text[at] != 0) && (text[at] != 10)): at = at + 1
		if (text[at] == 10): at = at + 1
	process_result_free(result)
	return values


void check_runtime(char* path, list[dwarf_die*] dies, int probe, int main_index, int word_size):
	list[int] out = fixture_output(path)
	assert_equal(8, out.length)
	assert_equal(23, out[7])
	int a = dies[die_find(dies, probe, 5, c"a")].fbreg
	int b = dies[die_find(dies, probe, 5, c"b")].fbreg
	int x = dies[die_find(dies, probe, 52, c"x")].fbreg
	int y = dies[die_find(dies, probe, 52, c"y")].fbreg
	# Address differences in the running frame match the fbreg offsets.
	assert_equal(a - x, out[0])
	assert_equal(b - x, out[1])
	assert_equal(y - x, out[2])
	# out[3 + k - 1] is the word at &x + k * word_size. The frame base is
	# &x - x: the arguments hold probe(3, 4)'s values, and the word just
	# above the saved frame pointer is a return address inside main.
	assert_equal(3, out[2 + (a - x) / word_size])
	assert_equal(4, out[2 + (b - x) / word_size])
	int return_address = out[2 + (word_size - x) / word_size]
	asserts(c"return address inside main", (return_address >= dies[main_index].low_pc) && (return_address < dies[main_index].high_pc))
	out.free()


void check_binary(char* path, char* plain, int word_size, int frame_register, int run):
	asm_binary* binary = asm_binary_open(path)
	asserts(c"fixture opens as ELF", cast(int, binary) != 0)
	char* data = binary.data
	int size = 0
	abbrevs_read(data, section_find(binary, c".debug_abbrev", &size))
	assert_equal(17, abbrev_tags[1]) /* DW_TAG_compile_unit */
	assert_equal(1, abbrev_children[1])
	list[dwarf_die*] dies = dies_read(data, section_find(binary, c".debug_info", &size), word_size)
	dwarf_die* unit = dies[0]
	assert_equal(17, unit.tag)
	assert_equal(12, unit.language) /* DW_LANG_C99 */
	assert_strings_equal(c"w", unit.producer)
	assert_equal(binary.text_vaddr, unit.low_pc)

	# Structure: references resolve, scopes nest inside their parents.
	for i in range(dies.length):
		dwarf_die* die = dies[i]
		if (die.type_ref >= 0): die_type(dies, die)
		if ((die.tag == 11) || (die.tag == 46)):
			asserts(c"pc range not empty", die.low_pc < die.high_pc)
			dwarf_die* parent = dies[die.parent]
			if (parent.tag != 17):
				asserts(c"scope inside its parent", (die.low_pc >= parent.low_pc) && (die.high_pc <= parent.high_pc))
		if ((die.tag == 5) || (die.tag == 52)):
			if (dies[die.parent].tag != 21): asserts(c"variable has a location", die.has_location)

	# probe: pc range from .symtab, frame base, parameters and locals.
	int probe = die_find(dies, -1, 46, c"probe")
	int symbol = asm_binary_symbol_named(binary, c"probe")
	asserts(c"probe in .symtab", symbol >= 0)
	asm_symbol probe_symbol = binary.symbols[symbol]
	assert_equal(probe_symbol.value, dies[probe].low_pc)
	assert_equal(probe_symbol.value + probe_symbol.size, dies[probe].high_pc)
	assert_equal(frame_register, dies[probe].frame_register)
	expect_base_int(dies, dies[probe], word_size)
	int a = die_find(dies, probe, 5, c"a")
	int b = die_find(dies, probe, 5, c"b")
	assert_equal(probe, dies[a].parent)
	assert_equal(3 * word_size, dies[a].fbreg)
	assert_equal(2 * word_size, dies[b].fbreg)
	expect_base_int(dies, dies[a], word_size)
	int x = die_find(dies, probe, 52, c"x")
	int y = die_find(dies, probe, 52, c"y")
	assert_equal(0 - word_size, dies[x].fbreg)
	assert_equal(-2 * word_size, dies[y].fbreg)
	expect_base_int(dies, dies[y], word_size)
	# y lives in a block strictly inside x's: declared later, dies with
	# the if body before probe's final 'return 0'.
	dwarf_die* x_scope = die_scope(dies, x)
	dwarf_die* y_scope = die_scope(dies, y)
	assert_equal(11, y_scope.tag) /* DW_TAG_lexical_block */
	asserts(c"y's block starts after x's", y_scope.low_pc > x_scope.low_pc)
	asserts(c"y's block ends before probe", y_scope.high_pc < dies[probe].high_pc)
	asserts(c"x's block inside probe", (x_scope.low_pc >= dies[probe].low_pc) && (x_scope.high_pc <= dies[probe].high_pc))

	# shapes: pointer -> struct, enum, typedef, fixed array.
	int shapes = die_find(dies, -1, 46, c"shapes")
	dwarf_die* pointer = die_type(dies, dies[die_find(dies, shapes, 5, c"pair")])
	assert_equal(15, pointer.tag) /* DW_TAG_pointer_type */
	assert_equal(word_size, pointer.byte_size)
	dwarf_die* pair = die_type(dies, pointer)
	assert_equal(19, pair.tag) /* DW_TAG_structure_type */
	assert_strings_equal(c"dwarf_pair", pair.name)
	assert_equal(2 * word_size, pair.byte_size)
	int pair_index = die_at(dies, pair.offset)
	assert_equal(0, member_offset(dies, pair_index, c"first"))
	assert_equal(word_size, member_offset(dies, pair_index, c"second"))
	dwarf_die* second = die_type(dies, dies[die_find(dies, pair_index, 13, c"second")])
	assert_equal(15, second.tag)
	assert_strings_equal(c"char", die_type(dies, second).name)
	dwarf_die* color = die_type(dies, dies[die_find(dies, shapes, 5, c"color")])
	assert_equal(4, color.tag) /* DW_TAG_enumeration_type */
	assert_strings_equal(c"dwarf_color", color.name)
	int color_index = die_at(dies, color.offset)
	assert_equal(0, dies[die_find(dies, color_index, 40, c"dwarf_red")].const_value)
	assert_equal(5, dies[die_find(dies, color_index, 40, c"dwarf_green")].const_value)
	dwarf_die* number = die_type(dies, dies[die_find(dies, shapes, 52, c"n")])
	assert_equal(22, number.tag) /* DW_TAG_typedef */
	assert_strings_equal(c"dwarf_number", number.name)
	expect_base_int(dies, number, word_size)
	dwarf_die* items = die_type(dies, dies[die_find(dies, shapes, 52, c"items")])
	assert_equal(19, items.tag)
	assert_strings_equal(c"int[4]", items.name)
	assert_equal(6 * word_size, items.byte_size)
	int items_index = die_at(dies, items.offset)
	assert_equal(0, member_offset(dies, items_index, c"data"))
	assert_equal(word_size, member_offset(dies, items_index, c"length"))
	assert_equal(2 * word_size, member_offset(dies, items_index, c"items"))
	dwarf_die* elements = die_type(dies, dies[die_find(dies, items_index, 13, c"items")])
	assert_equal(1, elements.tag) /* DW_TAG_array_type */
	expect_base_int(dies, elements, word_size)
	assert_equal(3, dies[die_at(dies, elements.offset) + 1].upper_bound)

	int main_index = die_find(dies, -1, 46, c"main")
	expect_base_int(dies, dies[main_index], word_size)
	if (run): check_runtime(path, dies, probe, main_index, word_size)

	# -g changes no code: every byte after the build-id note up to the end
	# of .text matches the default image (headers differ only in segment
	# sizes and the build id, which covers the debug sections).
	if (plain != 0):
		asm_binary* other = asm_binary_open(plain)
		assert_equal(binary.text_size, other.text_size)
		int note = section_find(binary, c".note.gnu.build-id", &size)
		for i in range(note + size, binary.text_size):
			if (data[i] != other.data[i]):
				print(c"code differs at ")
				println(itoa(i))
				exit(1)
	println(path)


int main():
	check_binary(c"bin/dwarf_variables_fixture_32", c"bin/dwarf_variables_fixture_plain", 4, 5, 1)
	check_binary(c"bin/dwarf_variables_fixture_64", 0, 8, 6, 1)
	check_binary(c"bin/dwarf_variables_fixture_arm64", 0, 8, 29, 0)
	println(c"dwarf_variables_test passed")
	return 0

# wbuild: target=dwarf_variables_test tag=tests dep=wv2 input=libs/asm/ input=code_generator/dwarf.w input=code_generator/dwarf_types.w input=tests/dwarf_variables_test.w input=tests/dwarf_variables_fixture.w
# wbuild: step="bin/wv2 -g tests/dwarf_variables_fixture.w -o bin/dwarf_variables_fixture_32"
# wbuild: step="bin/wv2 tests/dwarf_variables_fixture.w -o bin/dwarf_variables_fixture_plain"
# wbuild: step="bin/wv2 x64 -g tests/dwarf_variables_fixture.w -o bin/dwarf_variables_fixture_64"
# wbuild: step="bin/wv2 arm64 -g tests/dwarf_variables_fixture.w -o bin/dwarf_variables_fixture_arm64"
# wbuild: step="bin/wv2 tests/dwarf_variables_test.w -o bin/dwarf_variables_test"
# wbuild: step="bin/dwarf_variables_test" expect_stdout="dwarf_variables_test passed"
