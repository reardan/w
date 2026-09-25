# wbuild: x64
# lib/core_file.w on a synthetic ET_CORE file at the running word size:
# ELF header, a PT_NOTE with NT_PRSTATUS and the W crash handler's exe
# note, and one PT_LOAD standing in for dumped stack memory.
import lib.testing
import lib.core_file
import lib.mem


int core_test_wsize():
	return __word_size__


void core_test_put(char* buf, int off, int v, int n):
	int i = 0
	while (i < n):
		buf[off + i] = (v >> (i * 8)) & 255
		i = i + 1


void core_test_putw(char* buf, int off, int v):
	core_test_put(buf, off, v, core_test_wsize())


void core_test_phdr(char* buf, int p, int type, int offset, int vaddr, int size):
	core_test_put(buf, p, type, 4)
	if (core_test_wsize() == 8):
		core_test_putw(buf, p + 8, offset)
		core_test_putw(buf, p + 16, vaddr)
		core_test_putw(buf, p + 32, size)
		core_test_putw(buf, p + 40, size)
	else:
		core_test_putw(buf, p + 4, offset)
		core_test_putw(buf, p + 8, vaddr)
		core_test_putw(buf, p + 16, size)
		core_test_putw(buf, p + 20, size)


int core_test_size():
	return 1024


# Lays out: header, two program headers, notes at 256, stack at 768.
char* core_test_image():
	int w = core_test_wsize()
	char* buf = malloc(core_test_size())
	mem_fill(buf, 0, core_test_size())
	buf[0] = 127
	buf[1] = 'E'
	buf[2] = 'L'
	buf[3] = 'F'
	buf[4] = w / 4
	buf[5] = 1
	core_test_put(buf, 16, 4, 2)
	int phoff = 52
	int phentsize = 32
	if (w == 8):
		core_test_put(buf, 18, 62, 2)
		phoff = 64
		phentsize = 56
		core_test_putw(buf, 32, phoff)
		core_test_put(buf, 54, phentsize, 2)
		core_test_put(buf, 56, 2, 2)
	else:
		core_test_put(buf, 18, 3, 2)
		core_test_putw(buf, 28, phoff)
		core_test_put(buf, 42, phentsize, 2)
		core_test_put(buf, 44, 2, 2)

	# NT_PRSTATUS ("CORE"), then the W exe-path note.
	int prreg_off = 72
	int nregs = 17
	int pc_index = 12
	int sp_index = 15
	if (w == 8):
		prreg_off = 112
		nregs = 27
		pc_index = 16
		sp_index = 19
	int descsz = prreg_off + nregs * w
	int n = 256
	core_test_put(buf, n, 5, 4)
	core_test_put(buf, n + 4, descsz, 4)
	core_test_put(buf, n + 8, 1, 4)
	strcpy(&buf[n + 12], c"CORE")
	int desc = n + 20
	core_test_put(buf, desc + 12, 11, 2)
	core_test_putw(buf, desc + prreg_off + pc_index * w, 0x8049123)
	core_test_putw(buf, desc + prreg_off + sp_index * w, 0x1000)
	n = desc + (descsz + 3) / 4 * 4
	core_test_put(buf, n, 2, 4)
	core_test_put(buf, n + 4, 8, 4)
	core_test_put(buf, n + 8, 0x57455845, 4)
	strcpy(&buf[n + 12], c"W")
	strcpy(&buf[n + 16], c"/bin/xy")
	int notes_end = n + 24

	core_test_phdr(buf, phoff, 4, 256, 0, notes_end - 256)
	core_test_phdr(buf, phoff + phentsize, 1, 768, 0x1000, 64)
	core_test_putw(buf, 768 + w, 0x1234)
	return buf


char* core_test_path():
	if (core_test_wsize() == 8):
		return c"bin/core_file_test_64.core"
	return c"bin/core_file_test_32.core"


void core_test_write(char* path, char* data, int size):
	int fd = open(path, 577, 420)
	assert1(fd >= 0)
	assert_equal(size, write(fd, data, size))
	close(fd)


void test_core_file_reads_synthetic_core():
	core_test_write(core_test_path(), core_test_image(), core_test_size())
	assert1(cf_load_core(core_test_path()) == 0)
	assert_equal(core_test_wsize(), cf_wsize)
	assert1(cf_exe_note != 0)
	assert_strings_equal(c"/bin/xy", cast(char*, cf_exe_note))
	assert1(cf_read_prstatus() == 0)
	assert_equal(11, cf_sig)
	assert_equal(0x8049123, cf_pc)
	assert_equal(0x1000, cf_sp)
	assert_equal(0x1234, cf_core_word(0x1000 + core_test_wsize()))
	assert_equal(1, cf_read_ok)
	cf_core_word(0x2000)
	assert_equal(0, cf_read_ok)
	assert1(cf_have_fault() == 0)
	unlink(core_test_path())


void test_core_file_rejects_non_elf():
	char* path = c"bin/core_file_test_text.core"
	if (core_test_wsize() == 8):
		path = c"bin/core_file_test_text_64.core"
	core_test_write(path, c"not a core file, just some text padding it out to size", 52)
	assert_strings_equal(c"not an ELF file:", cf_load_core(path))
	assert_strings_equal(path, cf_error_path)
	unlink(path)
	assert_strings_equal(c"cannot read core file", cf_load_core(c"bin/core_file_test_missing"))


void test_core_file_names():
	assert_strings_equal(c"SIGSEGV", cf_signal_name(11))
	assert_strings_equal(c"unknown", cf_signal_name(99))
	assert_strings_equal(c"abort", cf_signal_desc(6))
	cf_wsize = 4
	assert_strings_equal(c"0x0000001f", cf_hex(31))
	# A 64-bit core needs a 64-bit build (cf_load_core refuses otherwise).
	if (core_test_wsize() == 8):
		cf_wsize = 8
		assert_strings_equal(c"0x000000000000001f", cf_hex(31))
	assert_strings_equal(c"0aff", cf_id_hex(cast(int, c"\n\xff"), 2))
