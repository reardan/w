/*
Seed-compatibility gate for libs/asm (issue #164, Phase 0.5): the
asm_seed_gate build target compiles THIS FILE WITH THE COMMITTED SEED
./w and runs it, mechanically enforcing that everything under libs/asm/
sticks to seed-understood syntax. That rule exists because its
consumers (debugger/, and code_generator/asm_text.w, which assembles
the runtime stubs at compile time, issue #207) live in w.w's seed-
compiled import graph; see docs/projects/assembler_disassembler.md.

If this target fails to compile after a libs/asm change, the change
uses post-seed syntax and must be rewritten (or wait for a seed
refresh via ./wbuild update).
*/
import lib.lib
import lib.assert
import libs.asm.insn
import libs.asm.registers
import libs.asm.hexutil
import libs.asm.binary_reader
import libs.asm.x86_decode
import libs.asm.x86_encode
import libs.asm.text
import libs.asm.format
import libs.asm.arm64_decode
import libs.asm.arm64_format
import libs.asm.arm64_encode
import libs.asm.arm64_text
import code_generator.asm_text


int main():
	# One touch per module so every file is pulled in and linked.
	asm_buffer* b = asm_buffer_new()
	asm_buffer_int32(b, 0x12345678)
	assert_equal(4, b.length)
	assert_equal(0x78, b.data[0] & 255)

	assert_equal(5, asm_reg_number(asm_reg_lookup_x86(c"ebp")))
	assert_equal(30, asm_reg_number(asm_reg_lookup_arm64(c"x30")))

	char* bytes = malloc(4)
	assert_equal(1, asm_hex_decode(c"c3", bytes, 4))
	assert_equal(0xc3, bytes[0] & 255)

	assert_equal(0, cast(int, asm_binary_open(c"tests/asm_seed_check.w")))

	# decode + format round-trip one instruction (mov eax,[esp+16]).
	char* x86_code = malloc(4)
	x86_code[0] = 0x8b
	x86_code[1] = 0x44
	x86_code[2] = 0x24
	x86_code[3] = 0x10
	asm_insn insn
	assert_equal(4, asm_x86_decode(x86_code, 4, 0, 4, &insn))
	assert_strings_equal(c"mov eax,[esp+0x10]", asm_format(&insn))

	# parse + encode round-trips back to the same bytes.
	asm_insn parsed
	asm_x86_parse(c"mov eax,[esp+0x10]", 4, &parsed)
	asm_buffer* enc = asm_buffer_new()
	assert_equal(4, asm_x86_encode(enc, &parsed))
	assert_equal(0x8b, enc.data[0] & 255)
	assert_equal(0x10, enc.data[3] & 255)

	# arm64: decode + format one word (ldr x8,[x28,#24] = 880f40f9), then
	# parse + encode it back to the same little-endian bytes.
	char* a64 = malloc(4)
	a64[0] = 0x88
	a64[1] = 0x0f
	a64[2] = 0x40
	a64[3] = 0xf9
	asm_insn ainsn
	assert_equal(4, asm_arm64_decode(a64, 4, 0, &ainsn))
	assert_strings_equal(c"ldr x8,[x28,#24]", asm_arm64_format(&ainsn))
	asm_insn aparsed
	asm_arm64_parse(c"ldr x8,[x28,#24]", &aparsed)
	asm_buffer* aenc = asm_buffer_new()
	assert_equal(4, asm_arm64_encode(aenc, &aparsed))
	assert_equal(0x88, aenc.data[0] & 255)
	assert_equal(0xf9, aenc.data[3] & 255)

	# x64 (mode 8): decode a REX.W instruction and re-encode it, so the
	# seed gate covers the new REX / 64-bit code paths too.
	# 48 8b 44 24 10 = mov rax,[rsp+0x10]
	char* code64 = malloc(5)
	code64[0] = 0x48
	code64[1] = 0x8b
	code64[2] = 0x44
	code64[3] = 0x24
	code64[4] = 0x10
	asm_insn insn64
	assert_equal(5, asm_x86_decode(code64, 5, 0, 8, &insn64))
	assert_strings_equal(c"mov rax,[rsp+0x10]", asm_format(&insn64))
	asm_buffer* enc64 = asm_buffer_new()
	assert_equal(5, asm_x86_encode(enc64, &insn64))
	assert_equal(0x48, enc64.data[0] & 255)
	assert_equal(0x8b, enc64.data[1] & 255)
	assert_equal(0x10, enc64.data[4] & 255)

	# asm_text: the compiler's compile-time stub assembler, one line per
	# encoder family plus a db raw-byte line, emitted at codepos.
	code_size = 64
	code = malloc(code_size)
	codepos = 0
	x86_asm(c"ret")
	x64_asm(c"mov rax,[rsp+0x10]")
	a64_asm(c"ret")
	x86_asm(c"db 0x66, 0x8c, 0xe0")
	assert_equal(13, codepos)
	assert_equal(0xc3, code[0] & 255)
	assert_equal(0x48, code[1] & 255)
	assert_equal(0xd6, code[9] & 255)
	assert_equal(0xe0, code[12] & 255)

	println(c"asm_seed_check passed")
	return 0
