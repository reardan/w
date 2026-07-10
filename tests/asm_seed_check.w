/*
Seed-compatibility gate for libs/asm (issue #164, Phase 0.5): the
asm_seed_gate build target compiles THIS FILE WITH THE COMMITTED SEED
./w and runs it, mechanically enforcing that everything under libs/asm/
sticks to seed-understood syntax. That rule exists because the endgame
consumers (debugger/, potentially code_generator/) live in w.w's seed-
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
	char* code = malloc(4)
	code[0] = 0x8b
	code[1] = 0x44
	code[2] = 0x24
	code[3] = 0x10
	asm_insn insn
	assert_equal(4, asm_x86_decode(code, 4, 0, 4, &insn))
	assert_strings_equal(c"mov eax,[esp+0x10]", asm_format(&insn))

	# parse + encode round-trips back to the same bytes.
	asm_insn parsed
	asm_x86_parse(c"mov eax,[esp+0x10]", 4, &parsed)
	asm_buffer* enc = asm_buffer_new()
	assert_equal(4, asm_x86_encode(enc, &parsed))
	assert_equal(0x8b, enc.data[0] & 255)
	assert_equal(0x10, enc.data[3] & 255)

	println(c"asm_seed_check passed")
	return 0
