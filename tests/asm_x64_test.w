# x86-64 assembler tests (issue #167): the mode-8 (REX / 64-bit /
# RIP-relative) path over tests/asm/corpus_x64.txt and an ELF64
# self-host build; see tests/asm_x86_roundtrip_common.w.
import tests.asm_x86_roundtrip_common


int main():
	asm_check_corpus(c"tests/asm/corpus_x64.txt", ASM_ARCH_X64(), 8)
	asm_check_encode_identity(c"bin/asm_x64_selfhost", 8)
	println(c"asm_x64_test passed")
	return 0
# wbuild: target=asm_x64_test tag=tests dep=wv2 input=libs/asm/ input=tests/asm/ input=tests/asm_x64_test.w input=tests/asm_x86_roundtrip_common.w input=w.w
# wbuild: step="bin/wv2 x64 w.w -o bin/asm_x64_selfhost"
# wbuild: step="bin/wv2 tests/asm_x64_test.w -o bin/asm_x64_test"
# wbuild: step="bin/asm_x64_test"
