/*
Structural W^X check for the Linux ELF backends (docs/projects/wx_split.md
Stages B and C). Parses the program headers of freshly built images of
tests/elf_wx_segment_input.w (compiled by the build target's first steps)
and asserts the properties the split exists for:

- exactly two PT_LOAD segments, one R+X and one R+W -- no segment is
  writable and executable at once,
- the entry point lies inside the R+X load,
- the R+W load sits at the fixed data base (image base + 16MB), with a
  page-congruent file offset,
- every dynamic relocation's target (GOT slots the loader binds, COPY
  space it fills) lies inside the R+W load, never in the R+X one.

The mutable-global compile-and-run half of the story is covered by this
test binary itself (wx_check_global below runs as a split image) and by
the extern_data/dynamic test targets, which execute loader-bound
binaries for real.
*/
import lib.testing
import lib.assert


# The image under inspection, read once per wx_load_image call.
char* wx_bytes
int wx_length
int wx_class      /* 1 = ELFCLASS32, 2 = ELFCLASS64 */


void wx_load_image(char* path):
	if (wx_bytes != 0):
		free(wx_bytes)
		wx_bytes = 0
	int fd = open(path, 0, 0)
	asserts(c"input ELF opened", fd >= 0)
	int cap = 65536
	char* buf = malloc(cap)
	int total = 0
	int n = read(fd, &buf[total], cap - total)
	while (n > 0):
		total = total + n
		if (total == cap):
			buf = realloc(buf, cap, cap * 2)
			cap = cap * 2
		n = read(fd, &buf[total], cap - total)
	close(fd)
	asserts(c"input ELF is not empty", total > 128)
	wx_bytes = buf
	wx_length = total


int wx_u8(int off):
	asserts(c"read stays inside the file", off >= 0 && off < wx_length)
	return wx_bytes[off] & 255


int wx_u16(int off):
	return wx_u8(off) | (wx_u8(off + 1) << 8)


int wx_u32(int off):
	return wx_u16(off) | (wx_u16(off + 2) << 16)


# A word-sized field: 4 bytes on ELFCLASS32, 8 on ELFCLASS64. Every value
# in these images fits in 32 bits (the layout tops out below 0x0a000000),
# so the high half must be zero -- asserted rather than truncated.
int wx_word(int off):
	int v = wx_u32(off)
	if (wx_class == 2):
		asserts(c"field fits in 32 bits", wx_u32(off + 4) == 0)
	return v


# --- ELF header fields ---------------------------------------------------

int wx_entry():
	return wx_word(24)


int wx_phoff():
	if (wx_class == 2):
		return wx_word(32)
	return wx_u32(28)


int wx_phentsize():
	if (wx_class == 2):
		return wx_u16(54)
	return wx_u16(42)


int wx_phnum():
	if (wx_class == 2):
		return wx_u16(56)
	return wx_u16(44)


# --- Program header fields (index i) -------------------------------------

int wx_ph_off(int i):
	return wx_phoff() + i * wx_phentsize()


int wx_ph_type(int i):
	return wx_u32(wx_ph_off(i))


int wx_ph_flags(int i):
	if (wx_class == 2):
		return wx_u32(wx_ph_off(i) + 4)
	return wx_u32(wx_ph_off(i) + 24)


int wx_ph_offset(int i):
	if (wx_class == 2):
		return wx_word(wx_ph_off(i) + 8)
	return wx_u32(wx_ph_off(i) + 4)


int wx_ph_vaddr(int i):
	if (wx_class == 2):
		return wx_word(wx_ph_off(i) + 16)
	return wx_u32(wx_ph_off(i) + 8)


int wx_ph_filesz(int i):
	if (wx_class == 2):
		return wx_word(wx_ph_off(i) + 32)
	return wx_u32(wx_ph_off(i) + 16)


int wx_ph_memsz(int i):
	if (wx_class == 2):
		return wx_word(wx_ph_off(i) + 40)
	return wx_u32(wx_ph_off(i) + 20)


# Index of the first program header of the given type from `from`, or -1.
int wx_ph_find(int ptype, int from):
	int i = from
	while (i < wx_phnum()):
		if (wx_ph_type(i) == ptype):
			return i
		i = i + 1
	return 0 - 1


# --- The structural assertions -------------------------------------------

# Walk PT_DYNAMIC for one entry's value (DT_REL=17, DT_RELA=7, ...);
# returns 0 when the tag is absent. The dynamic section lives in the text
# load, whose file offset equals vaddr - base, so it is read in place.
int wx_dyn_value(int tag):
	int d = wx_ph_find(2, 0)
	if (d < 0):
		return 0
	int entsize = 8
	if (wx_class == 2):
		entsize = 16
	int off = wx_ph_offset(d)
	int end = off + wx_ph_filesz(d)
	while (off < end):
		int t = wx_u32(off)
		if (wx_class == 2):
			t = wx_word(off)
		if (t == 0):
			return 0
		if (t == tag):
			if (wx_class == 2):
				return wx_word(off + 8)
			return wx_u32(off + 4)
		off = off + entsize
	return 0


void wx_check_image(char* path, int expected_class):
	wx_load_image(path)

	# ELF identification.
	asserts(c"ELF magic", wx_u32(0) == 1179403647) /* 0x7f 'E' 'L' 'F' */
	wx_class = wx_u8(4)
	assert_equal(expected_class, wx_class)

	# Exactly two PT_LOADs: R+X text holding the entry point, R+W data at
	# base + 16MB. No load may be writable and executable at once.
	int text = wx_ph_find(1, 0)
	asserts(c"a first PT_LOAD exists", text >= 0)
	int data_seg = wx_ph_find(1, text + 1)
	asserts(c"a second PT_LOAD exists", data_seg >= 0)
	asserts(c"no third PT_LOAD", wx_ph_find(1, data_seg + 1) < 0)

	assert_equal(5, wx_ph_flags(text))     /* R+X */
	assert_equal(6, wx_ph_flags(data_seg)) /* R+W */

	# Entry point inside the text load; text maps the file head in place.
	asserts(c"entry in the R+X load", wx_entry() >= wx_ph_vaddr(text) && wx_entry() < wx_ph_vaddr(text) + wx_ph_memsz(text))
	assert_equal(0, wx_ph_offset(text))
	assert_equal(134512640, wx_ph_vaddr(text)) /* 0x08048000 */

	# Data load: fixed base 16MB above the image, page-congruent file
	# offset (the loader requirement), and real contents.
	assert_equal(134512640 + 16777216, wx_ph_vaddr(data_seg)) /* 0x09048000 */
	assert_equal(0, (wx_ph_vaddr(data_seg) - wx_ph_offset(data_seg)) & 4095)
	asserts(c"data load is not empty", wx_ph_memsz(data_seg) > 0)
	asserts(c"data load is fully backed", wx_ph_filesz(data_seg) == wx_ph_memsz(data_seg))
	asserts(c"data bytes inside the file", wx_ph_offset(data_seg) + wx_ph_filesz(data_seg) <= wx_length)

	# Every loader-written relocation target (GOT slot, COPY space) lies
	# inside the R+W load. DT_RELA (tag 7) on 64-bit, DT_REL (17) on
	# 32-bit; entry sizes 24 and 8, r_offset is the leading word of each.
	int rel_vaddr = wx_dyn_value(7)
	int rel_size = wx_dyn_value(8)
	int rel_ent = 24
	if (wx_class == 1):
		rel_vaddr = wx_dyn_value(17)
		rel_size = wx_dyn_value(18)
		rel_ent = 8
	asserts(c"dynamic relocations exist", rel_vaddr != 0 && rel_size > 0)
	int lo = wx_ph_vaddr(data_seg)
	int hi = lo + wx_ph_memsz(data_seg)
	int off = rel_vaddr - 134512640 /* text load: file offset == vaddr - base */
	int end = off + rel_size
	int checked = 0
	while (off < end):
		int target = wx_u32(off)
		if (wx_class == 2):
			target = wx_word(off)
		asserts(c"relocation targets the R+W load", target >= lo && target < hi)
		off = off + rel_ent
		checked = checked + 1
	asserts(c"at least three relocations checked", checked >= 3)


# This test binary is itself a split image: a mutable global write + read
# proves the RW data segment is mapped and writable at run time.
int wx_test_global


void wx_check_global():
	wx_test_global = 7
	wx_test_global = wx_test_global * 6
	assert_equal(42, wx_test_global)


void test_own_global_write():
	wx_check_global()


void test_x64_image():
	wx_check_image(c"bin/elf_wx_segment_input64", 2)
