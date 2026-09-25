# wbuild: deps=tests/asm/
# x86 (32-bit) assembler tests (issue #166) over tests/asm/corpus_x86.txt
# and bin/wv2; see tests/asm_x86_roundtrip_common.w.
import tests.asm_x86_roundtrip_common


int main():
	asm_check_corpus(c"tests/asm/corpus_x86.txt", 4, 4)
	asm_check_encode_identity(c"bin/wv2", 4)
	println(c"asm_x86_asm_test passed")
	return 0
