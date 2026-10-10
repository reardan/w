# Host-side validation runs without an Android device or QEMU.
# wbuild: binary=android_elf_test tag=tests
# wbuild: step="bin/wv2 arm64_android tests/android_elf_fixture.w -o bin/android_static_pie"
# wbuild: step="bin/wv2 arm64_android tests/android_elf_fixture.w tests/android_elf_imports.w -o bin/android_dynamic_pie"
# wbuild: step="bin/wv2 arm64_android --shared tests/android_elf_fixture.w tests/android_elf_imports.w -o bin/libandroid_elf.so"
# wbuild: step="bin/wv2 arm64_android --pac=ret --shared tests/android_elf_fixture.w tests/android_elf_imports.w -o bin/libandroid_elf_pac.so"
# wbuild: step="bin/wv2 arm64 --pie tests/android_elf_fixture.w -o bin/arm64_static_pie"
# wbuild: step="bin/wv2 arm64 --shared tests/android_elf_fixture.w -o bin/libarm64_elf.so"
# wbuild: step="bin/wv2 arm64_android --shared tests/extern_data_test.w -o bin/android_bad_data.so" expect_fail expect_stderr="extern data objects are not supported on arm64 targets yet"
# wbuild: step="bin/android_elf_test" expect_stdout="All tests passed!"
import lib.testing
import lib.file
import lib.process

char* android_phdr(char* image, int kind):
	int off = load_int(image + 32)
	for i in range(load_i(image + 56, 2)):
		char* ph = image + off + i * 56
		if (load_int(ph) == kind): return ph
	return 0

int android_dynamic_value(char* image, int tag):
	char* ph = android_phdr(image, 2)
	int off = load_int(ph + 8)
	for i in range(0, load_int(ph + 32), 16):
		if (load_int(image + off + i) == tag): return load_int(image + off + i + 8)
	return 0

void android_headers(char* path, int dynamic, int shared, int page):
	char* image = file_read_text(path)
	assert1(image != 0)
	assert_equal(3, load_i(image + 16, 2))
	assert_equal(183, load_i(image + 18, 2))
	if (shared): assert_equal(0, load_int(image + 24))
	else: assert1(load_int(image + 24) != 0)
	int off = load_int(image + 32)
	int loads = 0
	for i in range(load_i(image + 56, 2)):
		char* ph = image + off + i * 56
		if (load_int(ph) == 1):
			loads += 1
			assert_equal(page, load_int(ph + 48))
			assert_equal(0, (load_int(ph + 16) - load_int(ph + 8)) & (page - 1))
			assert1((load_int(ph + 4) & 3) != 3)
	assert_equal(2, loads)
	char* text = android_phdr(image, 1)
	int base = load_int(text + 16)
	assert1(android_phdr(image, 6) < text)
	assert_equal(6, load_int(android_phdr(image, 1685382481) + 4))
	# The entry walk rebases static PIE only. Dynamic PIE must not slide
	# the same cells again after the loader applies RELATIVE entries.
	if (shared == 0):
		int entry_off = load_int(image + 24) - base
		int table_addr = load_int(image + entry_off + 44)
		char* data_ph = image + off + 2 * 56
		if (dynamic): data_ph = image + off + 3 * 56
		int table_off = table_addr - load_int(data_ph + 16) + load_int(data_ph + 8)
		if (dynamic): assert_equal(0, load_int(image + table_off))
		else: assert1(load_int(image + table_off) > 0)
	char* interp = android_phdr(image, 3)
	char* dyn = android_phdr(image, 2)
	if (dynamic == 0):
		assert_equal(0, cast(int, interp))
		assert_equal(0, cast(int, dyn))
		free(image)
		return
	assert1(dyn != 0)
	if (shared): assert_equal(0, cast(int, interp))
	else:
		assert1(interp != 0 && interp < text)
		assert_strings_equal(c"/system/bin/linker64", image + load_int(interp + 8))
	char* relro = android_phdr(image, 1685382482)
	assert1(relro != 0)
	int relro_start = load_int(relro + 16)
	int relro_end = relro_start + load_int(relro + 40)
	assert_equal(0, relro_start & (page - 1))
	assert_equal(0, relro_end & (page - 1))
	int rel = android_dynamic_value(image, 7) - base
	int relsz = android_dynamic_value(image, 8)
	int pointers = 0
	int imports = 0
	for i in range(0, relsz, 24):
		int addr = load_int(image + rel + i)
		int kind = load_int(image + rel + i + 8)
		if (kind == 1027):
			pointers += 1
			assert1(addr >= relro_end)
		else:
			assert_equal(1025, kind)
			assert1(addr >= relro_start && addr < relro_end)
			imports += 1
	assert1(pointers > 0 && imports > 0)
	assert_equal(0, android_dynamic_value(image, 22)) # no text relocations
	int str = android_dynamic_value(image, 5) - base
	assert_strings_equal(c"libc.so", image + str + android_dynamic_value(image, 1))
	if (shared):
		assert_equal(0, android_dynamic_value(image, 1879048187))
		assert_strings_equal(c"libandroid_elf.so", image + str + android_dynamic_value(image, 14))
	else: assert_equal(134217728, android_dynamic_value(image, 1879048187))
	# Android validates the section table, not just program headers.
	int shoff = load_int(image + 40)
	int shnum = load_i(image + 60, 2)
	int found = 0
	for i in range(shnum):
		char* sh = image + shoff + i * 64
		if (load_int(sh + 4) == 6):
			found += 1
			assert_equal(load_int(dyn + 8), load_int(sh + 24))
			assert_equal(load_int(dyn + 32), load_int(sh + 32))
			int link = load_int(sh + 40)
			assert1(link < shnum)
			char* strings = image + shoff + link * 64
			assert_equal(3, load_int(strings + 4))
			assert_equal(str, load_int(strings + 24))
			assert_equal(android_dynamic_value(image, 10), load_int(strings + 32))
	assert_equal(1, found)
	free(image)

void test_android_elf_layout():
	android_headers(c"bin/android_static_pie", 0, 0, 16384)
	android_headers(c"bin/android_dynamic_pie", 1, 0, 16384)
	android_headers(c"bin/libandroid_elf.so", 1, 1, 16384)
	android_headers(c"bin/arm64_static_pie", 0, 0, 4096)


void android_export_native_stack(char* path, int pac):
	char* image = file_read_text(path)
	int base = load_int(android_phdr(image, 1) + 16)
	int syms = android_dynamic_value(image, 6) - base
	int hash = android_dynamic_value(image, 4) - base
	int nsym = load_int(image + hash + 4)
	int exports = 0
	for i in range(1, nsym):
		char* sym = image + syms + i * 24
		if (load_i(sym + 6, 2) == 0): continue
		exports += 1
		int pos = load_int(sym + 8) - base
		# Native save frame and all twelve callee-saved registers.
		assert_equal(cast(int, 0xd10283ff), load_int(image + pos))
		for r in range(12):
			assert_equal(cast(int, 0xf90003e0) | (r << 10) | (19 + r), load_int(image + pos + 4 + r * 4))
		int reserve = 0
		int restore = 0
		while (load_int(image + pos) != cast(int, 0xd65f03c0)):
			if (((load_int(image + pos) >> 26) & 63) == 37):
				int delta = (load_int(image + pos) & 0x3ffffff) << 2
				if (delta & 0x8000000): delta = delta - 0x10000000
				# The exported W body defaults to ARMv8.0 instructions.
				int first = cast(int, 0xa9bf7b9d)
				if (pac): first = cast(int, 0xdac1039e)
				assert_equal(first, load_int(image + pos + delta))
			if (load_int(image + pos) == cast(int, 0xd14103ff)): reserve += 1
			if (load_int(image + pos) == cast(int, 0x914103ff)): restore += 1
			pos += 4
			assert1(pos < syms)
		assert_equal(1, reserve)
		assert_equal(1, restore)
	assert_equal(4, exports)
	free(image)


void test_android_export_native_stack():
	android_export_native_stack(c"bin/libandroid_elf.so", 0)
	android_export_native_stack(c"bin/libandroid_elf_pac.so", 1)


void test_android_soname_windows_separator():
	# A literal backslash in a Linux filename exercises the same -o text
	# supplied by a Windows cross-build, without requiring a Windows host.
	char* path = c"bin/android_soname\\libprobe.so"
	char** args = strv_new(6)
	strv_set(args, 0, c"bin/wv2")
	strv_set(args, 1, c"arm64_android")
	strv_set(args, 2, c"--shared")
	strv_set(args, 3, c"tests/android_elf_fixture.w")
	strv_set(args, 4, c"-o")
	strv_set(args, 5, path)
	process_result* result = process_run(args[0], args, 0, 0, 30000)
	assert1(result != 0)
	if (result.status != 0): println2(result.stderr_text)
	assert_equal(0, result.status)
	process_result_free(result)
	free(cast(void*, args))
	char* image = file_read_text(path)
	assert1(image != 0)
	int base = load_int(android_phdr(image, 1) + 16)
	int str = android_dynamic_value(image, 5) - base
	assert_strings_equal(c"libprobe.so", image + str + android_dynamic_value(image, 14))
	free(image)
	unlink(path)
