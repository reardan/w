/*
Structural W^X check for the win64 PE backend (docs/projects/wx_split.md
Stage A). Wine -- the project's win64 CI proxy -- does not enforce HVCI's
W^X rule, so a green wine run cannot prove the section split holds. This
test inspects the emitted bytes instead: it parses the PE section table
of bin/win64_wx_section_input.exe (compiled from tests/win64_hello.w by
the build target's first step) and asserts the properties HVCI needs:

- no section is both WRITE and EXECUTE,
- the entry point lies in an executable, non-writable section,
- every import descriptor's FirstThunk (IAT slot) lies in a writable,
  non-executable section, so the loader's bind writes never target an
  executable page.

Runs as a normal Linux test; no wine or objdump involved.
*/
import lib.testing
import lib.assert


char* wxs_path():
	return c"bin/win64_wx_section_input.exe"


# The whole image, read once and cached; wxs_size() is its length.
char* wxs_bytes
int wxs_length


char* wxs_image():
	if (wxs_bytes != 0):
		return wxs_bytes
	int fd = open(wxs_path(), 0, 0)
	asserts(c"input PE opened", fd >= 0)
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
	asserts(c"input PE is not empty", total > 512)
	wxs_bytes = buf
	wxs_length = total
	return wxs_bytes


int wxs_u8(int off):
	char* b = wxs_image()
	asserts(c"read stays inside the file", off >= 0 && off < wxs_length)
	return b[off] & 255


int wxs_u16(int off):
	return wxs_u8(off) | (wxs_u8(off + 1) << 8)


int wxs_u32(int off):
	return wxs_u16(off) | (wxs_u16(off + 2) << 16)


# Offsets inside the image.
int wxs_pe_off():
	return wxs_u32(60)


int wxs_opt_off():
	return wxs_pe_off() + 24


int wxs_section_count():
	return wxs_u16(wxs_pe_off() + 6)


int wxs_section_off(int i):
	return wxs_opt_off() + wxs_u16(wxs_pe_off() + 20) + i * 40


# IMAGE_SECTION_HEADER fields.
int wxs_sect_vsize(int i):
	return wxs_u32(wxs_section_off(i) + 8)


int wxs_sect_rva(int i):
	return wxs_u32(wxs_section_off(i) + 12)


int wxs_sect_rawsize(int i):
	return wxs_u32(wxs_section_off(i) + 16)


int wxs_sect_rawptr(int i):
	return wxs_u32(wxs_section_off(i) + 20)


# Characteristics bits, extracted with shifts so the sign extension of a
# 32-bit load with bit 31 (WRITE) set never matters.
int wxs_sect_exec(int i):
	return (wxs_u32(wxs_section_off(i) + 36) >> 29) & 1


int wxs_sect_write(int i):
	return (wxs_u32(wxs_section_off(i) + 36) >> 31) & 1


# Index of the section whose virtual span contains the RVA, or -1.
int wxs_section_of_rva(int rva):
	int i = 0
	while (i < wxs_section_count()):
		int lo = wxs_sect_rva(i)
		if (rva >= lo && rva < lo + wxs_sect_vsize(i)):
			return i
		i = i + 1
	return 0 - 1


# File offset of an RVA that must land inside a section's raw bytes.
int wxs_rva_to_file(int rva):
	int i = wxs_section_of_rva(rva)
	asserts(c"RVA belongs to a section", i >= 0)
	int delta = rva - wxs_sect_rva(i)
	asserts(c"RVA is backed by file bytes", delta < wxs_sect_rawsize(i))
	return wxs_sect_rawptr(i) + delta


void test_pe_signature():
	asserts(c"MZ magic", wxs_u16(0) == 23117) # 0x5a4d "MZ"
	int pe = wxs_pe_off()
	asserts(c"PE signature", wxs_u32(pe) == 17744) # 0x00004550 "PE\0\0"
	asserts(c"machine is x86-64", wxs_u16(pe + 4) == 34404)


void test_two_sections():
	assert_equal(2, wxs_section_count())


void test_no_section_is_write_and_execute():
	int i = 0
	while (i < wxs_section_count()):
		asserts(c"section is not WRITE+EXECUTE", (wxs_sect_write(i) & wxs_sect_exec(i)) == 0)
		i = i + 1


void test_image_has_exec_and_write_sections():
	int execs = 0
	int writes = 0
	int i = 0
	while (i < wxs_section_count()):
		execs = execs + wxs_sect_exec(i)
		writes = writes + wxs_sect_write(i)
		i = i + 1
	asserts(c"an executable section exists", execs > 0)
	asserts(c"a writable section exists", writes > 0)


void test_entry_point_in_exec_section():
	int entry_rva = wxs_u32(wxs_opt_off() + 16)
	int i = wxs_section_of_rva(entry_rva)
	asserts(c"entry point lies in a section", i >= 0)
	asserts(c"entry section is executable", wxs_sect_exec(i) == 1)
	asserts(c"entry section is not writable", wxs_sect_write(i) == 0)


# The HVCI failure mode: the loader writes resolved import addresses
# through each descriptor's FirstThunk. Every one of those slots must be
# in a writable, non-executable section.
void test_iat_slots_in_writable_section():
	int idt_rva = wxs_u32(wxs_opt_off() + 120) # data directory 1: imports
	int idt_size = wxs_u32(wxs_opt_off() + 124)
	asserts(c"import directory exists", idt_rva != 0 && idt_size >= 40)
	int desc = wxs_rva_to_file(idt_rva)
	int checked = 0
	# Walk descriptors until the all-zero terminator.
	while (wxs_u32(desc) != 0 || wxs_u32(desc + 12) != 0 || wxs_u32(desc + 16) != 0):
		int first_thunk = wxs_u32(desc + 16)
		int i = wxs_section_of_rva(first_thunk)
		asserts(c"IAT slot lies in a section", i >= 0)
		asserts(c"IAT slot section is writable", wxs_sect_write(i) == 1)
		asserts(c"IAT slot section is not executable", wxs_sect_exec(i) == 0)
		# The lookup table (OriginalFirstThunk) stays read-only metadata.
		int ilt = wxs_u32(desc)
		int j = wxs_section_of_rva(ilt)
		asserts(c"ILT lies in a section", j >= 0)
		asserts(c"ILT section is not writable", wxs_sect_write(j) == 0)
		checked = checked + 1
		desc = desc + 20
	asserts(c"at least one import descriptor checked", checked > 0)
