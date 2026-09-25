/*
Structural check of the win64 PE backend's output, in plain W so it
runs the same on Linux and natively on Windows (no objdump, no wine).
It parses bin/win64_header_input.exe (compiled from tests/win64_hello.w
by the build target's first step): the PE32+ console header, the
.text/.data sections, the kernel32.dll!ExitProcess import, IAT slots
pre-filled from the lookup table (Windows leaves zero slots unbound),
and the embedded symbol header stack traces read.

It also carries the W^X layout gate (docs/projects/wx_split.md Stage A).
Wine does not enforce HVCI's W^X rule, so a green wine run cannot prove
the section split holds; the bytes are asserted directly instead:

- no section is both WRITE and EXECUTE,
- the entry point lies in an executable, non-writable section,
- every import descriptor's FirstThunk (IAT slot) lies in a writable,
  non-executable section, so the loader's bind writes never target an
  executable page.
*/
import lib.testing
import lib.assert


char* wxs_path():
	return c"bin/win64_header_input.exe"


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


# 1 when the NUL-terminated string at file offset off equals s.
int wxs_cstr_at(int off, char* s):
	int i = 0
	while (s[i] != 0):
		if (wxs_u8(off + i) != (s[i] & 255)):
			return 0
		i = i + 1
	return wxs_u8(off + i) == 0


# Index of the section named name (8-byte, NUL-padded field), or -1.
int wxs_section_named(char* name):
	int i = 0
	while (i < wxs_section_count()):
		if (wxs_cstr_at(wxs_section_off(i), name)):
			return i
		i = i + 1
	return 0 - 1


void test_optional_header_is_pe32_plus():
	assert_equal(523, wxs_u16(wxs_opt_off()))   # 0x20b
	assert_equal(3, wxs_u16(wxs_opt_off() + 68))  # subsystem: console


# .text is read-execute code, .data read-write data (what objdump -h
# printed as "READONLY, CODE" and ".data").
void test_text_and_data_sections():
	int text = wxs_section_named(c".text")
	int data = wxs_section_named(c".data")
	asserts(c".text section exists", text >= 0)
	asserts(c".data section exists", data >= 0)
	int text_flags = wxs_u32(wxs_section_off(text) + 36)
	asserts(c".text is CODE", (text_flags >> 5) & 1)
	asserts(c".text is READ", (text_flags >> 30) & 1)
	asserts(c".text is executable", wxs_sect_exec(text))
	asserts(c".text is not writable", wxs_sect_write(text) == 0)
	asserts(c".data is writable", wxs_sect_write(data))


# Every import is named in the directory, and kernel32.dll!ExitProcess
# (the entry stub's own import) is among them.
void test_imports_name_kernel32_exit_process():
	int desc = wxs_rva_to_file(wxs_u32(wxs_opt_off() + 120))
	int found = 0
	while (wxs_u32(desc) != 0 || wxs_u32(desc + 12) != 0 || wxs_u32(desc + 16) != 0):
		int dll = wxs_rva_to_file(wxs_u32(desc + 12))
		int hint_name = wxs_rva_to_file(wxs_u32(wxs_rva_to_file(wxs_u32(desc))))
		if (wxs_cstr_at(dll, c"kernel32.dll") && wxs_cstr_at(hint_name + 2, c"ExitProcess")):
			found = 1
		desc = desc + 20
	asserts(c"kernel32.dll!ExitProcess is imported", found)


# The on-disk IAT must mirror the lookup table: Windows walks the IAT
# and stops at the first zero slot, so a zero-filled slot is never bound
# and every call through it jumps to address 0.
void test_iat_slots_prefilled_from_ilt():
	int desc = wxs_rva_to_file(wxs_u32(wxs_opt_off() + 120))
	while (wxs_u32(desc) != 0 || wxs_u32(desc + 12) != 0 || wxs_u32(desc + 16) != 0):
		int ilt = wxs_rva_to_file(wxs_u32(desc))
		int iat = wxs_rva_to_file(wxs_u32(desc + 16))
		asserts(c"IAT slot is not zero", wxs_u32(iat) != 0)
		asserts(c"IAT slot equals its ILT entry", wxs_u32(iat) == wxs_u32(ilt))
		asserts(c"IAT slot high half equals its ILT entry", wxs_u32(iat + 4) == wxs_u32(ilt + 4))
		desc = desc + 20


# Stack traces and crash reports symbolize win64 frames through a
# stand-in ELF64 header at the start of .text (code_generator/pe_64.w)
# carrying the .symtab/.debug_line section table.
void test_embedded_symbol_header():
	int text = wxs_section_named(c".text")
	int base = wxs_sect_rawptr(text)
	asserts(c"ELF magic at the start of .text", wxs_u32(base) == 1179403647)  # 0x464c457f
	assert_equal(2, wxs_u8(base + 4))      # ELFCLASS64
	assert_equal(62, wxs_u16(base + 18))   # EM_X86_64
	asserts(c"section headers present", wxs_u16(base + 60) >= 7)
	int shoff = wxs_u32(base + 40)
	asserts(c"section table inside the file", base + shoff + 64 * wxs_u16(base + 60) <= wxs_length)
