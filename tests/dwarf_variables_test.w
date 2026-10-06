/*
Structural test for the DWARF debugging information entries and call
frame information (issue #536; code_generator/dwarf_info.w).

The dwarf_variables_test build target compiles
tests/dwarf_variables_fixture.w for x86 (bin/dwarf_variables_fixture_32)
and x64 (bin/dwarf_variables_fixture_64), runs both, then runs this
program, which parses each ELF from disk with a small DIE walker over
.debug_abbrev/.debug_info and asserts:
 - DW_TAG_subprogram entries for scale, report and main whose pc ranges
   lie inside .text, with declaration lines and (for report) no type;
 - scale's DW_TAG_formal_parameters p and factor and DW_TAG_variables
   sx and sy, plus inner inside a nested DW_TAG_lexical_block, with the
   DW_OP_fbreg offsets of the frame layout relative to the CFA frame base;
 - p's type is a pointer to the structure point (two int members at
   offsets 0 and word), int is a signed base type of word size, and
   report's local digits is the int[3] descriptor;
 - .debug_frame holds a CIE and an FDE starting at scale's low_pc.
*/
import lib.lib
import lib.assert
import libs.asm.binary_reader


# File offset of the named section's payload; the size is stored through
# size_out. Exits with a diagnostic when the section is missing.
int section_find(char* data, int elf_class, char* want, int* size_out):
	int is64 = 0
	if (elf_class == ASM_ELF_CLASS64): is64 = 1
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
	int shoff = asm_read_word(data, shoff_at, elf_class)
	int shentsize = asm_read_u16(data, shentsize_at)
	int shnum = asm_read_u16(data, shnum_at)
	int shstrndx = asm_read_u16(data, shstrndx_at)
	int shstr_header = shoff + shstrndx * shentsize
	int shstr_offset = asm_read_word(data, shstr_header + sh_offset_at, elf_class)
	for index in range(shnum):
		int header = shoff + index * shentsize
		int name_index = asm_read_u32(data, header)
		char* name = data + shstr_offset + name_index
		if (strcmp(name, want) == 0):
			*size_out = asm_read_word(data, header + sh_size_at, elf_class)
			return asm_read_word(data, header + sh_offset_at, elf_class)
	print(c"missing section: ")
	println(want)
	exit(1)
	return 0


# LEB128 reader over the file image; reader_pos advances past each value.
char* reader_data
int reader_pos


int read_uleb():
	int result = 0
	int shift = 0
	while (1):
		int b = asm_read_u8(reader_data, reader_pos)
		reader_pos = reader_pos + 1
		result = result | ((b & 127) << shift)
		shift = shift + 7
		if ((b & 128) == 0): return result


int read_sleb():
	int result = 0
	int shift = 0
	while (1):
		int b = asm_read_u8(reader_data, reader_pos)
		reader_pos = reader_pos + 1
		result = result | ((b & 127) << shift)
		shift = shift + 7
		if ((b & 128) == 0):
			if ((b & 64) != 0): result = result | (0 - (1 << shift))
			return result


# One parsed DIE. Attributes the test does not look at are skipped.
struct die:
	int offset      # CU-relative
	int tag
	int depth
	int parent      # index into dies, -1 for the compile unit
	char* name
	int low_pc
	int high_pc
	int type_ref    # CU-relative offset, -1 when absent
	int fbreg       # DW_OP_fbreg operand of DW_AT_location
	int has_fbreg
	int frame_base_op
	int member_offset
	int byte_size
	int encoding
	int decl_line


list[die*] dies
int word


# Read one attribute value of the given form at reader_pos into d.
void read_attribute(die* d, int attribute, int form):
	int value = 0
	int block_start = 0
	int block_length = -1
	if (form == 1):
		value = asm_read_u32(reader_data, reader_pos)
		if (word == 8): assert_equal(0, asm_read_u32(reader_data, reader_pos + 4))
		reader_pos = reader_pos + word
	else if (form == 10):
		block_length = asm_read_u8(reader_data, reader_pos)
		reader_pos = reader_pos + 1
		block_start = reader_pos
	else if (form == 11):
		value = asm_read_u8(reader_data, reader_pos)
		reader_pos = reader_pos + 1
	else if (form == 5):
		value = asm_read_u16(reader_data, reader_pos)
		reader_pos = reader_pos + 2
	else if ((form == 6) || (form == 19)):
		value = asm_read_u32(reader_data, reader_pos)
		reader_pos = reader_pos + 4
	else if (form == 8):
		char* text = reader_data + reader_pos
		if (attribute == 3): d.name = text
		reader_pos = reader_pos + strlen(text) + 1
		return
	else if (form == 12):
		value = asm_read_u8(reader_data, reader_pos)
		reader_pos = reader_pos + 1
	else if (form == 13): value = read_sleb()
	else if (form == 15): value = read_uleb()
	else:
		print_int0(c"unexpected DW_FORM ", form)
		println(c"")
		exit(1)
	if (block_length >= 0):
		reader_pos = block_start
		int op = asm_read_u8(reader_data, reader_pos)
		reader_pos = reader_pos + 1
		if ((attribute == 2) && (op == 145)):
			d.fbreg = read_sleb()
			d.has_fbreg = 1
		else if (attribute == 64): d.frame_base_op = op
		else if ((attribute == 56) && (op == 35)): d.member_offset = read_uleb()
		reader_pos = block_start + block_length
		return
	if (attribute == 17): d.low_pc = value
	else if (attribute == 18): d.high_pc = value
	else if (attribute == 73): d.type_ref = value
	else if (attribute == 11): d.byte_size = value
	else if (attribute == 62): d.encoding = value
	else if (attribute == 59): d.decl_line = value


# File offset in .debug_abbrev of each abbreviation's tag (index = code).
int abbrev_entry(char* data, int abbrev, int abbrev_size, int code):
	reader_data = data
	reader_pos = abbrev
	while (reader_pos < abbrev + abbrev_size):
		int c = read_uleb()
		if (c == 0): break
		if (c == code): return reader_pos
		read_uleb() /* tag */
		reader_pos = reader_pos + 1 /* children */
		while (1):
			int attribute = read_uleb()
			int form = read_uleb()
			if ((attribute == 0) && (form == 0)): break
	print_int0(c"missing abbreviation ", code)
	println(c"")
	exit(1)
	return 0


void parse_dies(char* data, int info, int abbrev, int abbrev_size):
	dies = new list[die*]
	int unit_end = info + 4 + asm_read_u32(data, info)
	assert_equal(2, asm_read_u16(data, info + 4)) /* DWARF version */
	assert_equal(word, asm_read_u8(data, info + 10)) /* address_size */
	int position = info + 11
	list[int] parents = new list[int]
	int depth = 0
	while (position < unit_end):
		reader_data = data
		reader_pos = position
		int code = read_uleb()
		if (code == 0):
			position = reader_pos
			if (depth == 0): break
			depth = depth - 1
			parents.pop()
			continue
		int die_end_pos = reader_pos
		int spec = abbrev_entry(data, abbrev, abbrev_size, code)
		die* d = new die
		d.offset = position - info
		d.depth = depth
		d.parent = -1
		if (parents.length > 0): d.parent = parents[parents.length - 1]
		d.type_ref = -1
		d.name = c""
		reader_pos = spec
		d.tag = read_uleb()
		int children = asm_read_u8(data, reader_pos)
		int attr_pos = reader_pos + 1
		int value_pos = die_end_pos
		while (1):
			reader_pos = attr_pos
			int attribute = read_uleb()
			int form = read_uleb()
			attr_pos = reader_pos
			if ((attribute == 0) && (form == 0)): break
			reader_pos = value_pos
			read_attribute(d, attribute, form)
			value_pos = reader_pos
		position = value_pos
		dies.push(d)
		if (children):
			parents.push(dies.length - 1)
			depth = depth + 1
	assert_equal(unit_end, position)


int find_die(int tag, char* name, int parent):
	for i in range(dies.length):
		die* d = dies[i]
		if ((d.tag == tag) && (strcmp(d.name, name) == 0)):
			if ((parent < 0) || (d.parent == parent)): return i
	print(c"missing DIE: ")
	println(name)
	exit(1)
	return -1


int die_at_offset(int offset):
	for i in range(dies.length):
		die* d = dies[i]
		if (d.offset == offset): return i
	print_int0(c"dangling DW_AT_type reference ", offset)
	println(c"")
	exit(1)
	return -1


# 1 when die index child sits (at any depth) under die index ancestor.
int is_descendant(int child, int ancestor):
	int at = dies[child].parent
	while (at >= 0):
		if (at == ancestor): return 1
		at = dies[at].parent
	return 0


# First DIE with this tag and name anywhere under die index ancestor.
int find_die_under(int tag, char* name, int ancestor):
	for i in range(dies.length):
		die* d = dies[i]
		if ((d.tag == tag) && (strcmp(d.name, name) == 0) && is_descendant(i, ancestor)): return i
	print(c"missing DIE under its subprogram: ")
	println(name)
	exit(1)
	return -1


void check_frame_offset(char* name, int parent, int tag, int expected):
	int i = find_die_under(tag, name, parent)
	die* d = dies[i]
	asserts(c"variable has a DW_OP_fbreg location", d.has_fbreg)
	assert_equal(expected, d.fbreg)


void check_binary(char* path, int word_size):
	word = word_size
	asm_binary* binary = asm_binary_open(path)
	asserts(c"fixture opens as ELF", cast(int, binary) != 0)
	char* data = binary.data
	int info_size = 0
	int info = section_find(data, binary.elf_class, c".debug_info", &info_size)
	int abbrev_size = 0
	int abbrev = section_find(data, binary.elf_class, c".debug_abbrev", &abbrev_size)
	parse_dies(data, info, abbrev, abbrev_size)

	int text_lo = binary.text_vaddr
	int text_hi = binary.text_vaddr + binary.text_size

	# Subprograms (DW_TAG_subprogram = 0x2e)
	int scale = find_die(46, c"scale", 0)
	die* s = dies[scale]
	asserts(c"scale low_pc in .text", (s.low_pc >= text_lo) && (s.low_pc < text_hi))
	asserts(c"scale high_pc after low_pc", (s.high_pc > s.low_pc) && (s.high_pc <= text_hi))
	assert_equal(16, s.decl_line)
	assert_equal(156, s.frame_base_op) /* DW_OP_call_frame_cfa */
	asserts(c"scale returns int", s.type_ref >= 0)
	int report = find_die(46, c"report", 0)
	assert_equal(-1, dies[report].type_ref) /* void */
	int main_die = find_die(46, c"main", 0)
	asserts(c"main follows scale", dies[main_die].low_pc >= s.high_pc)

	# Parameters (0x05) and locals (0x34), DW_OP_fbreg from the CFA:
	# the saved frame pointer and return address are the two words
	# below it, arguments pushed first-to-last above it.
	check_frame_offset(c"p", scale, 5, word_size)
	check_frame_offset(c"factor", scale, 5, 0)
	check_frame_offset(c"sx", scale, 52, -3 * word_size)
	check_frame_offset(c"sy", scale, 52, -4 * word_size)
	check_frame_offset(c"inner", scale, 52, -5 * word_size)
	int inner = find_die_under(52, c"inner", scale)
	int block = dies[inner].parent
	assert_equal(11, dies[block].tag) /* DW_TAG_lexical_block */
	asserts(c"block nested in the body block", dies[dies[block].parent].tag == 11)
	asserts(c"block range inside scale", (dies[block].low_pc > s.low_pc) && (dies[block].high_pc < s.high_pc))

	# Types: p is point*, point has x@0 and y@word, int is signed
	int p = find_die(5, c"p", scale)
	int pointer = die_at_offset(dies[p].type_ref)
	assert_equal(15, dies[pointer].tag) /* DW_TAG_pointer_type */
	assert_equal(word_size, dies[pointer].byte_size)
	int point = die_at_offset(dies[pointer].type_ref)
	assert_equal(19, dies[point].tag) /* DW_TAG_structure_type */
	asserts(c"struct named point", strcmp(dies[point].name, c"point") == 0)
	assert_equal(2 * word_size, dies[point].byte_size)
	assert_equal(0, dies[find_die(13, c"x", point)].member_offset)
	assert_equal(word_size, dies[find_die(13, c"y", point)].member_offset)
	int int_die = die_at_offset(dies[find_die(13, c"y", point)].type_ref)
	assert_equal(36, dies[int_die].tag) /* DW_TAG_base_type */
	asserts(c"base type named int", strcmp(dies[int_die].name, c"int") == 0)
	assert_equal(word_size, dies[int_die].byte_size)
	assert_equal(5, dies[int_die].encoding) /* DW_ATE_signed */
	int digits = find_die_under(52, c"digits", report)
	int array = die_at_offset(dies[digits].type_ref)
	asserts(c"T[N] descriptor named int[3]", strcmp(dies[array].name, c"int[3]") == 0)
	assert_equal(2 * word_size, dies[find_die(13, c"items", array)].member_offset)

	# .debug_frame: CIE (id 0xffffffff), then the FDEs; one covers scale
	int frame_size = 0
	int frame = section_find(data, binary.elf_class, c".debug_frame", &frame_size)
	asserts(c".debug_frame has content", frame_size > 0)
	assert_equal(65535, asm_read_u16(data, frame + 4)) /* CIE_id */
	assert_equal(65535, asm_read_u16(data, frame + 6))
	int position = frame + 4 + asm_read_u32(data, frame)
	int found = 0
	while (position < frame + frame_size):
		int length = asm_read_u32(data, position)
		assert_equal(0, asm_read_u32(data, position + 4)) /* CIE_pointer */
		int start = asm_read_u32(data, position + 8)
		int range = asm_read_u32(data, position + 8 + word_size)
		if (start == s.low_pc):
			assert_equal(s.high_pc - s.low_pc, range)
			found = 1
		position = position + 4 + length
	assert_equal(frame + frame_size, position)
	asserts(c"FDE for scale", found)
	println(path)


int main():
	check_binary(c"bin/dwarf_variables_fixture_32", 4)
	check_binary(c"bin/dwarf_variables_fixture_64", 8)
	println(c"dwarf_variables_test passed")
	return 0
