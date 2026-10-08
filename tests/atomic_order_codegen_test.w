# wbuild: x64
import lib.assert
import compiler.compiler
import libs.asm.arm64_decode
import libs.asm.arm64_format
import libs.asm.arm64_encode
import libs.asm.arm64_text


void atomic_codegen_reset(int isa, int width):
	target_isa = isa
	word_size = width
	word_size_log2 = 2
	if (width == 8): word_size_log2 = 3
	codepos = 64
	be_notes_reset()
	# Seed a live load-fold note. Every ordering operation must kill it.
	load_note_end = codepos


void atomic_codegen_word(int pos, int expected):
	for i in range(4):
		assert_equal((expected >> (i * 8)) & 255, code[pos + i] & 255)


void test_atomic_arm64_encodings():
	atomic_codegen_reset(1, 8)
	alu_atomic_load(1)
	assert_equal(68, codepos)
	atomic_codegen_word(64, op(0xc8, 0xdffc00))
	assert_equal(0, load_note_end)
	alu_atomic_store(1)
	atomic_codegen_word(68, op(0xc8, 0x9ffc20))
	alu_atomic_fence()
	atomic_codegen_word(72, op(0xd5, 0x033bbf))
	alu_atomic_load(0)
	atomic_codegen_word(76, op(0xf9, 0x400000))
	alu_atomic_store(0)
	atomic_codegen_word(80, op(0xf9, 0x000020))
	assert_equal(84, codepos)
	char*[5] texts
	texts[0] = c"ldar x0,[x0]"
	texts[1] = c"stlr x0,[x1]"
	texts[2] = c"dmb ish"
	texts[3] = c"ldr x0,[x0]"
	texts[4] = c"str x0,[x1]"
	for i in range(5):
		asm_insn insn
		assert_equal(4, asm_arm64_decode(code + 64 + i * 4, 4, 0, &insn))
		char* formatted = asm_arm64_format(&insn)
		assert_strings_equal(texts[i], formatted)
		free(formatted)
		asm_buffer* encoded = asm_buffer_new()
		assert_equal(4, asm_arm64_encode(encoded, &insn))
		assert_equal(1, arm64_encode_reconstructed)
		assert_bytes_equal(code + 64 + i * 4, encoded.data, 4)
		asm_buffer_free(encoded)


void test_atomic_x86_encodings():
	for wide in range(2):
		atomic_codegen_reset(0, 4 + 4 * wide)
		alu_atomic_load(1)
		int pos = 64
		if (wide):
			assert_equal(0x48, code[pos] & 255)
			pos = pos + 1
		assert_bytes_equal(code + pos, c"\x8b\x00", 2)
		assert_equal(pos + 2, codepos)
		assert_equal(0, load_note_end)
		pos = codepos
		alu_atomic_store(1)
		if (wide):
			assert_equal(0x48, code[pos] & 255)
			pos = pos + 1
		assert_bytes_equal(code + pos, c"\x89\x03", 2)
		assert_equal(pos + 2, codepos)
		pos = codepos
		alu_atomic_fence()
		assert_bytes_equal(code + pos, c"\xf0\x83\x0c\x24\x00", 5)
		assert_equal(pos + 5, codepos)


void test_atomic_arm64_rejects_unencodable_offsets():
	asm_insn insn
	asm_buffer* encoded = asm_buffer_new()
	assert_equal(1, asm_arm64_parse(c"stlr x0,[x1,#8]", &insn))
	assert_equal(-1, asm_arm64_encode(encoded, &insn))
	assert_equal(0, encoded.length)
	assert_equal(1, asm_arm64_parse(c"ldar x2,[x3,#16]!", &insn))
	assert_equal(-1, asm_arm64_encode(encoded, &insn))
	assert_equal(0, encoded.length)
	assert_equal(1, asm_arm64_parse(c"stlr x4,[x5,x6]", &insn))
	assert_equal(-1, asm_arm64_encode(encoded, &insn))
	assert_equal(0, encoded.length)
	asm_buffer_free(encoded)


int main():
	code_size = 4096
	code = cast(char*, malloc(code_size))
	test_atomic_arm64_encodings()
	test_atomic_x86_encodings()
	test_atomic_arm64_rejects_unencodable_offsets()
	free(code)
	return 0

# wbuild: target=atomic_order_portable_test tag=tests dep=wv2
# wbuild: step="bin/wv2 tests/atomic_order_fixture.w -o bin/atomic_order_fixture"
# wbuild: step="bin/atomic_order_fixture"
# wbuild: step="bin/wv2 --streaming tests/atomic_order_fixture.w -o bin/atomic_order_streaming_fixture"
# wbuild: step="bin/atomic_order_streaming_fixture"
# wbuild: step="bin/wv2 x64 --ast-required --ast-retain --ast-opt tests/atomic_order_fixture.w -o bin/atomic_order_retained_fixture"
# wbuild: step="bin/atomic_order_retained_fixture"
# wbuild: step="bin/wv2 arm64 --ast-required tests/atomic_order_fixture.w -o bin/atomic_order_arm64_fixture"
# wbuild: step="bin/wv2 arm64 --streaming tests/atomic_order_fixture.w -o bin/atomic_order_arm64_streaming_fixture"
# wbuild: step="bin/wv2 arm64_darwin --ast-required tests/atomic_order_fixture.w -o bin/atomic_order_darwin_fixture"
# wbuild: step="bin/wv2 win64 --ast-required tests/atomic_order_fixture.w -o bin/atomic_order_win64_fixture.exe"

# wbuild: target=atomic_order_diagnostics_test tag=tests dep=wv2 dep=wfixture
# wbuild: step="bin/wfixture bin/wv2 tests/atomic_order_operand_warning_fixture.w tests/atomic_order_arity_error_fixture.w tests/atomic_order_wasm_error_fixture.w tests/atomic_order_gpu_error_fixture.w"
