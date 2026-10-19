# wbuild: x64
# wbuild: step="bin/wv2 tests/inspect_probe.w -o bin/inspect_probe"
# wbuild: step="bin/wv2 x64 tests/inspect_probe.w -o bin/inspect_probe_64"
# wbuild: step="bin/wv2 arm64 tests/inspect_probe.w -o bin/inspect_probe_arm64"
# wbuild: step="bin/wv2 inspect bin/inspect_probe --sections" expect_stdout="Sections:" expect_stdout=".text"
# wbuild: step="bin/wv2 inspect bin/inspect_probe --symbols" expect_stdout="Symbols:" expect_stdout="inspect_answer"
# wbuild: step="bin/wv2 inspect bin/inspect_probe --disasm inspect_answer" expect_stdout="Disassembly of inspect_answer:" expect_stdout="ret"
# wbuild: step="bin/wv2 inspect bin/inspect_probe_64 --disasm inspect_answer" expect_stdout="Disassembly of inspect_answer:" expect_stdout="ret"
# wbuild: step="bin/wv2 inspect bin/inspect_probe_arm64 --disasm inspect_answer" expect_stdout="Disassembly of inspect_answer:" expect_stdout="ret"
# wbuild: step="bin/wv2 inspect bin/inspect_probe" expect_stdout="Sections:" expect_stdout="Symbols:"
# wbuild: step="bin/wv2 inspect bin/inspect_probe --sections --symbols --disasm main" expect_stdout="Sections:" expect_stdout="Symbols:" expect_stdout="Disassembly of main:"
# wbuild: step="bin/wv2 inspect --help" expect_stdout="usage: w inspect"
# wbuild: step="bin/wv2 inspect -h" expect_stdout="usage: w inspect"
# wbuild: step="bin/wv2 inspect" expect_fail expect_stderr="usage: w inspect"
# wbuild: step="bin/wv2 inspect bin/inspect_probe --disasm" expect_fail expect_stderr="usage: w inspect"
# wbuild: step="bin/wv2 inspect bin/inspect_probe --bad" expect_fail expect_stderr="usage: w inspect"
# wbuild: step="bin/wv2 inspect bin/inspect_probe extra" expect_fail expect_stderr="usage: w inspect"
# wbuild: step="bin/wv2 inspect bin/inspect_probe --disasm missing_inspect_symbol" expect_fail expect_stderr="function not found"
# wbuild: step="bin/wv2 inspect tests/inspect_probe.w" expect_fail expect_stderr="not an ELF file"
# wbuild: step="bin/wv2 inspect bin/no-such-inspect-input" expect_fail expect_stderr="inspect: cannot read"
import tools.inspect
import lib.assert
import lib.mem

# Synthetic ELF32 with .text, .shstrtab, .symtab and .strtab. Its text
# address differs from its file offset to catch accidental direct reads.
char* inspect_test_image():
	char* data = cast(char*, malloc(512))
	mem_fill[char](data, 0, 512)
	data[0] = 127
	data[1] = 'E'
	data[2] = 'L'
	data[3] = 'F'
	data[4] = 1
	data[5] = 1
	data[6] = 1
	save_int16(data + 16, 2)
	save_int16(data + 18, 3)
	save_int32(data + 20, 1)
	save_int32(data + 32, 256)
	save_int16(data + 40, 52)
	save_int16(data + 46, 40)
	save_int16(data + 48, 5)
	save_int16(data + 50, 2)
	data[64] = 0x90
	data[65] = 0xc3
	mem_copy(data + 80, c"\0.text\0.shstrtab\0.symtab\0.strtab\0", 33)
	mem_copy(data + 120, c"\0demo\0next\0", 11)
	# Section one: code.
	save_int32(data + 296, 1)
	save_int32(data + 300, 1)
	save_int32(data + 304, 6)
	save_int32(data + 308, 4096)
	save_int32(data + 312, 64)
	save_int32(data + 316, 2)
	# Section two: section names.
	save_int32(data + 336, 7)
	save_int32(data + 340, 3)
	save_int32(data + 352, 80)
	save_int32(data + 356, 33)
	# Section three: symbols, two named entries after the null entry.
	save_int32(data + 376, 17)
	save_int32(data + 380, 2)
	save_int32(data + 392, 144)
	save_int32(data + 396, 48)
	save_int32(data + 400, 4)
	save_int32(data + 412, 16)
	# Section four: symbol strings.
	save_int32(data + 416, 25)
	save_int32(data + 420, 3)
	save_int32(data + 432, 120)
	save_int32(data + 436, 11)
	save_int32(data + 160, 1)
	save_int32(data + 164, 4096)
	data[172] = 18
	save_int16(data + 174, 1)
	save_int32(data + 176, 6)
	save_int32(data + 180, 4097)
	data[188] = 18
	save_int16(data + 190, 1)
	return data

void inspect_test_bad(char* data, int length, char* message):
	inspect_binary binary
	assert_equal(0, inspect_parse(&binary, data, length))
	asserts(message, assert_has(inspect_error, message))
	inspect_free(&binary)

void inspect_test_change(int offset, int value, char* message):
	char* data = inspect_test_image()
	save_int32(data + offset, value)
	inspect_test_bad(data, 512, message)
	free(data)

void inspect_test_valid():
	char* data = inspect_test_image()
	inspect_binary binary
	assert_equal(1, inspect_parse(&binary, data, 512))
	assert_equal(5, binary.sections.length)
	assert_equal(3, binary.symbols.length)
	inspect_section section = binary.sections[1]
	assert_strings_equal(c".text", section.name)
	int offset = 0
	int size = 0
	int address = 0
	assert_equal(1, inspect_function(&binary, c"demo", &offset, &size, &address))
	assert_equal(64, offset)
	assert_equal(1, size)
	assert_equal(4096, address)
	assert_equal(1, inspect_function(&binary, c"next", &offset, &size, &address))
	assert_equal(65, offset)
	assert_equal(1, size)
	assert_equal(0, inspect_function(&binary, c"absent", &offset, &size, &address))
	inspect_free(&binary)
	# A nonzero st_size must stay inside its executable section.
	save_int32(data + 168, 100)
	assert_equal(1, inspect_parse(&binary, data, 512))
	assert_equal(0, inspect_function(&binary, c"demo", &offset, &size, &address))
	asserts(c"function size validation", assert_has(inspect_error, c"function size outside"))
	inspect_free(&binary)
	# SHT_NULL has no file data; malicious executable flags cannot make it
	# a disassembly source, even with an otherwise valid function symbol.
	save_int32(data + 168, 0)
	save_int32(data + 300, 0)
	save_int32(data + 312, 0x7fffffff)
	assert_equal(1, inspect_parse(&binary, data, 512))
	assert_equal(0, inspect_function(&binary, c"demo", &offset, &size, &address))
	inspect_free(&binary)
	# Relocatable symbols are section-relative, not virtual addresses.
	save_int32(data + 300, 1)
	save_int32(data + 312, 64)
	save_int16(data + 16, 1)
	save_int32(data + 164, 0)
	save_int32(data + 180, 1)
	assert_equal(1, inspect_parse(&binary, data, 512))
	assert_equal(1, inspect_function(&binary, c"demo", &offset, &size, &address))
	assert_equal(64, offset)
	assert_equal(1, size)
	assert_equal(0, address)
	inspect_free(&binary)
	free(data)

void inspect_test_invalid():
	char* data = inspect_test_image()
	inspect_test_bad(data, 3, c"not an ELF")
	inspect_test_bad(data, 40, c"truncated ELF header")
	inspect_test_bad(data, 400, c"truncated section header table")
	data[4] = 2
	inspect_test_bad(data, 52, c"truncated ELF header")
	data[4] = 3
	inspect_test_bad(data, 512, c"unsupported ELF class")
	data[4] = 1
	data[5] = 2
	inspect_test_bad(data, 512, c"little-endian")
	free(data)
	inspect_test_change(32, 0x7ffffff0, c"truncated section header table")
	inspect_test_change(312, 511, c"section data outside")
	inspect_test_change(316, 0x7fffffff, c"section data outside")
	inspect_test_change(296, 100, c"string table offset")
	inspect_test_change(400, 99, c"symbol string table link")
	inspect_test_change(412, 0, c"symbol table entry size")
	inspect_test_change(412, 17, c"symbol table entry size")
	inspect_test_change(160, 100, c"string table offset")
	data = inspect_test_image()
	data[130] = 'x'
	inspect_test_bad(data, 512, c"unterminated string table entry")
	free(data)
	# Reject wide ELF64 fields explicitly, without truncation on x86.
	data = inspect_test_image()
	data[4] = 2
	save_int16(data + 52, 64)
	save_int16(data + 58, 64)
	save_int16(data + 60, 1)
	save_int16(data + 62, 0)
	save_int32(data + 40, 256)
	save_int32(data + 44, 1)
	inspect_test_bad(data, 512, c"64-bit field exceeds")
	save_int32(data + 44, 0)
	save_int32(data + 276, 1)
	inspect_test_bad(data, 512, c"64-bit field exceeds")
	free(data)

int main():
	inspect_test_valid()
	inspect_test_invalid()
	println(c"inspect_test passed")
	return 0
