# wbuild: target=wgrind_source_test tag=tests dep=wv2 dep=wgrind_compiler_test
# wbuild: step="bin/wv2 x64 tests/wgrind_source_test.w -o bin/wgrind_source_test"
# wbuild: step="bin/wgrind_source_test" expect_stdout="wgrind_source_test: OK"
import lib.assert
import libs.wgrind.source
import structures.json


void source_leb_cases():
	char[16] bytes
	wg_dwarf_reader r
	r.data = &bytes[0]
	r.end = 1
	r.at = 0
	r.valid = 1
	bytes[0] = 127
	assert_equal(-1, wg_dwarf_leb(&r, 1))
	assert_equal(1, r.valid)
	r.at = 0
	assert_equal(127, wg_dwarf_leb(&r, 0))
	for i in range(10): bytes[i] = 128
	r.at = 0
	r.end = 10
	r.valid = 1
	wg_dwarf_leb(&r, 0)
	assert_equal(0, r.valid)
	r.at = 0
	r.end = 1
	r.valid = 1
	wg_dwarf_string(&r)
	assert_equal(0, r.valid)
	char[128] text
	int n = wg_source_json(&text[0], 0, c"a\"b\\c\nd")
	text[n] = 0
	json_value* parsed = json_parse(&text[0])
	assert1(parsed != 0)
	assert_strings_equal(c"a\"b\\c\nd", parsed.string_value)
	json_free(parsed)


void source_real_image():
	int length = 0
	char* data = wg_symbol_read_file(c"bin/wgrind_compiler_fixture", &length)
	assert1(data != 0)
	int phdr = wg_elf_u64(data, 32)
	int base = wg_elf_u64(data, phdr + 16) - wg_elf_u64(data, phdr + 8)
	int found = 0
	int site = 0
	char[1024] path
	for at in range(length - 24):
		if ((data[at] != 15) || (data[at + 1] != 11) || (data[at + 7] != 5)): continue
		if (wg_elf_u32(data, at + 2) != 0x44524757): continue
		int line = 0
		assert1(wg_source_image(data, length, base + at, &path[0], 1024, &line))
		assert_equal(wg_elf_u64(data, at + 16), line)
		if (ends_with(&path[0], c"/tests/wgrind_compiler_fixture.w") && (line == 22)):
			# The real instruction after a source marker uses the DWARF
			# line machine, while the marker itself uses its exact payload.
			site = base + at + 24
			assert1(wg_source_image(data, length, site, &path[0], 1024, &line))
			assert_equal(22, line)
			found = 1
	assert1(found)
	int line = 0
	assert_equal(0, wg_source_image(data, length, 0, &path[0], 1024, &line))
	assert_equal(0, wg_source_image(data, length, site, &path[0], 1, &line))
	for size in range(512):
		assert_equal(0, wg_source_image(data, size, site, &path[0], 1024, &line))
	# Malformed section-table coordinates must not become reads beyond
	# the supplied image, even though the file has a valid ELF header.
	int saved = wg_elf_u64(data, 40)
	*cast(int*, data + 40) = -1
	assert_equal(0, wg_source_image(data, length, site, &path[0], 1024, &line))
	*cast(int*, data + 40) = saved
	free(data)


int main():
	source_leb_cases()
	source_real_image()
	println(c"wgrind_source_test: OK")
	return 0
