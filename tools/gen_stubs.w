/*
Offline generator for the runtime stubs in code_generator/{x86,x64,
arm64}_asm.w (docs/projects/assembler_disassembler.md, issue #170).

Assembles an assembly-text stub source (tests/asm/stubs_*.asm) through
the libs/asm encoders and prints the exact W lines to paste into the
committed file: sym_define_declare_global_function() plus emit(n,
c"\xNN...") chunks for x86/x64, or a64(op(0xAA, 0xBBBBBB)) words with
their assembly comments for arm64. This replaces the old objdump-parsing
debugger/convert.w.

    ./wbuild gen_stubs
    bin/gen_stubs tests/asm/stubs_x86.asm
    bin/gen_stubs check tests/asm/stubs_x86.asm code_generator/x86_asm.w

`check` performs the drift test (also run by asm_stubs_test): the
assembled bytes must match the committed file's byte strings exactly.

Standalone tool: NOT imported by w.w, so the compiler's seed import
graph — and the ./wbuild verify fixpoint — is untouched.
*/
import lib.lib
import libs.asm.insn
import libs.asm.hexutil
import libs.asm.stubgen


# emit() chunk size for the printed x86/x64 byte strings; matches the
# committed files' predominant style.
int GEN_STUBS_CHUNK():
	return 20


# "\xNN" spelling of one chunk of bytes (92 = '\'; the seed's char
# literals have no hex escapes).
char* gen_stubs_escape(char* bytes, int n):
	char* digits = c"0123456789abcdef"
	char* out = malloc(n * 4 + 1)
	int i = 0
	while (i < n):
		int v = bytes[i] & 255
		out[i * 4] = 92
		out[i * 4 + 1] = 'x'
		out[i * 4 + 2] = digits[v >> 4]
		out[i * 4 + 3] = digits[v & 15]
		i = i + 1
	out[n * 4] = 0
	return out


# Zero-padded lowercase hex, for op(0xAA, 0xBBBBBB) words.
char* gen_stubs_hex_pad(int v, int width):
	char* digits = c"0123456789abcdef"
	char* out = malloc(width + 1)
	int i = 0
	while (i < width):
		out[width - 1 - i] = digits[(v >> (i * 4)) & 15]
		i = i + 1
	out[width] = 0
	return out


void gen_stubs_print_x86(asm_stub_source* src):
	int i = 0
	while (i < src.funcs.length):
		asm_stub_func func = src.funcs[i]
		print(c"\tsym_define_declare_global_function(c\x22")
		print(func.name)
		println(c"\x22)")
		# the assembly as one /* ... */ comment line, ' ; '-joined
		print(c"\t/* ")
		int line = 0
		while (line < func.line_count):
			if (line > 0):
				print(c" ; ")
			print(src.texts[func.line_start + line])
			line = line + 1
		println(c" */")
		int pos = 0
		while (pos < func.bytes.length):
			int chunk = func.bytes.length - pos
			if (chunk > GEN_STUBS_CHUNK()):
				chunk = GEN_STUBS_CHUNK()
			print(c"\temit(")
			print(itoa(chunk))
			print(c", c\x22")
			print(gen_stubs_escape(func.bytes.data + pos, chunk))
			println(c"\x22)")
			pos = pos + chunk
		println(c"")
		i = i + 1


void gen_stubs_print_arm64(asm_stub_source* src):
	int i = 0
	while (i < src.funcs.length):
		asm_stub_func func = src.funcs[i]
		print(c"\t# --- ")
		print(func.name)
		println(c" ---")
		int line = 0
		while (line < func.line_count):
			char* data = func.bytes.data + line * 4
			int word = (data[0] & 255) | ((data[1] & 255) << 8) | ((data[2] & 255) << 16) | ((data[3] & 255) << 24)
			print(c"\ta64(op(0x")
			print(gen_stubs_hex_pad((word >> 24) & 255, 2))
			print(c", 0x")
			print(gen_stubs_hex_pad(word & 0xffffff, 6))
			print(c"))   # ")
			println(src.texts[func.line_start + line])
			line = line + 1
		println(c"")
		i = i + 1


void gen_stubs_usage():
	println2(c"usage: gen_stubs <stubs.asm>                    print the emit()/a64(op()) lines")
	println2(c"       gen_stubs check <stubs.asm> <stubs.w>    drift-check against the committed file")


int main(int argc, int argv):
	if (argc == 4):
		char** command = argv + __word_size__
		if (strcmp(*command, c"check") != 0):
			gen_stubs_usage()
			return 1
		char** stub_path = argv + 2 * __word_size__
		char** committed_path = argv + 3 * __word_size__
		asm_stub_check(*stub_path, *committed_path)
		return 0
	if (argc != 2):
		gen_stubs_usage()
		return 1
	char** path = argv + __word_size__
	asm_stub_source* src = asm_stub_source_load(*path)
	if (src.arch == ASM_STUB_ARM64()):
		gen_stubs_print_arm64(src)
	else:
		gen_stubs_print_x86(src)
	return 0
