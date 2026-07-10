/*
Stub drift test (issue #170): the runtime stubs committed as hand-hexed
emit()/a64(op()) calls in code_generator/{x86,x64,arm64}_asm.w must
match what the libs/asm assemblers produce from their assembly-text
sources in tests/asm/stubs_{x86,x64,arm64}.asm.

Any mismatch means either the committed bytes or the stub source drifted
— tools/gen_stubs.w prints the regenerated lines to paste into the
committed file. asm_stub_check() also verifies each emit(n, ...) length
against its string's escape count, so a stub cannot silently emit stray
NUL bytes (the pre-#170 store_context did exactly that).

docs/projects/assembler_disassembler.md.
*/
import lib.lib
import libs.asm.stubgen


int main():
	asm_stub_check(c"tests/asm/stubs_x86.asm", c"code_generator/x86_asm.w")
	asm_stub_check(c"tests/asm/stubs_x64.asm", c"code_generator/x64_asm.w")
	asm_stub_check(c"tests/asm/stubs_arm64.asm", c"code_generator/arm64_asm.w")
	println(c"asm_stubs_test passed")
	return 0
