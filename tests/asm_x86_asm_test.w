# wbuild: binary=asm_x86_asm_test arch=x86 tag=tests dep=build input=tests/asm/
# wbuild: step="bin/asm_x86_asm_test"
# x86 (32-bit) assembler tests (issue #166) over tests/asm/corpus_x86.txt
# and bin/wv3, the x86 self-host stage (bin/wv2 is the 64-bit seed
# build); see tests/asm_x86_roundtrip_common.w.
import tests.asm_x86_roundtrip_common


int main():
	asm_check_corpus(c"tests/asm/corpus_x86.txt", 4, 4)
	asm_check_encode_identity(c"bin/wv3", 4)
	println(c"asm_x86_asm_test passed")
	return 0
