/*
Runtime-stub corpus check (issues #170, #207). The runtime stubs in
code_generator/{x86,x64,arm64}_asm.w are assembly text, assembled
through libs/asm on every compile (code_generator/asm_text.w). This test
reads those files back, assembles every instruction of each literal
x86_asm(c"...") / x64_asm(c"...") / a64_asm(c"...") line the same way, and asserts that
the text and its bytes appear as an entry of the arch's
tests/asm/corpus_*.txt. So every stub instruction is also covered by the
corpus decode/encode round-trips (asm_x86_disasm_test, asm_x86_asm_test,
asm_x64_test, asm_arm64_test), and an encoder change that would alter a
stub's bytes fails here instead of silently changing every executable.

`db 0xNN, ...` raw-byte lines have no assembly text to check and are
skipped; so are lines built at run time (arm64 get_context's loop).
A missing line is reported in corpus format (hexbytes|text), ready to
append to the corpus after checking the bytes.

docs/projects/assembler_disassembler.md.

The committed code_generator/*_asm.w files and the corpora are read as
run-time text, not imported, so the deps= directives below declare them
— both for 'bin/wtest changed' selection and for the generated target's
cache "inputs".
*/
# wbuild: deps=tests/asm/ deps=code_generator/x86_asm.w
# wbuild: deps=code_generator/x64_asm.w deps=code_generator/arm64_asm.w
import lib.lib
import lib.file
import libs.asm.insn
import libs.asm.hexutil
import libs.asm.text
import libs.asm.x86_encode
import libs.asm.arm64_text
import libs.asm.arm64_encode
import lib.str


int stubs_missing


# Assemble text for arch (ASM_ARCH_X86/X64/ARM64) into a fresh buffer;
# exits on a line the assembler rejects (the compiler would too).
asm_buffer* stubs_assemble(int arch, char* path, int line, char* text):
	asm_buffer* b = asm_buffer_new()
	asm_insn insn
	int n = 0
	if (arch == ASM_ARCH_ARM64()):
		if (asm_arm64_parse(text, &insn)):
			n = asm_arm64_encode(b, &insn)
	else:
		if (asm_x86_parse(text, arch, &insn)):
			n = asm_x86_encode(b, &insn)
	if (n <= 0):
		print2(path)
		print2(c":")
		print2(itoa(line))
		print2(c": cannot assemble ")
		println2(text)
		exit(1)
	return b


int stubs_bytes_equal(char* a, int a_length, char* b, int b_length):
	if (a_length != b_length):
		return 0
	int i = 0
	while (i < a_length):
		if (a[i] != b[i]):
			return 0
		i = i + 1
	return 1


# Assemble one stub instruction and look its text and bytes up in the
# corpus; a miss is reported in corpus format.
void stubs_check_one(char* path, int index, int arch, list[asm_corpus_entry] corpus, char* corpus_path, char* text):
	asm_buffer* b = stubs_assemble(arch, path, index, text)
	int found = 0
	int i = 0
	while (i < corpus.length && found == 0):
		asm_corpus_entry entry = corpus[i]
		if (strcmp(entry.text, text) == 0):
			if (stubs_bytes_equal(entry.bytes, entry.length, b.data, b.length)):
				found = 1
		i = i + 1
	if (found == 0):
		print2(path)
		print2(c":")
		print2(itoa(index))
		print2(c": stub instruction not in ")
		print2(corpus_path)
		print2(c": ")
		print2(asm_hex_encode(b.data, b.length))
		print2(c"|")
		println2(text)
		stubs_missing = stubs_missing + 1


# Check every literal `<call>(c"...")` line of path against corpus.
# Returns the number of stub instructions checked.
int stubs_check(char* path, char* call, int arch, char* corpus_path):
	list[asm_corpus_entry] corpus = asm_corpus_load(corpus_path)
	if (corpus.length == 0):
		print2(c"empty corpus ")
		println2(corpus_path)
		exit(1)
	list[char*] lines = file_read_lines(path)
	if (cast(int, lines) == 0):
		print2(c"cannot read ")
		println2(path)
		exit(1)
	char* pat = strjoin(call, c"(c\x22")
	int checked = 0
	int index = 0
	while (index < lines.length):
		char* line = lines[index]
		index = index + 1
		int first = 0
		while (line[first] == '\t' || line[first] == ' '):
			first = first + 1
		if (line[first] == '#'):
			continue
		int at = index_of(line, pat)
		if (at < 0):
			continue
		at = at + strlen(pat)
		int end = at
		while (line[end] != 0 && line[end] != 34):
			end = end + 1
		# A stub line may hold several ';'-separated instructions
		# (code_generator/asm_text.w, asm_text_lines).
		while (at < end):
			while (line[at] == ' '):
				at = at + 1
			int stop = at
			while (stop < end && line[stop] != ';'):
				stop = stop + 1
			int last = stop
			while (last > at && line[last - 1] == ' '):
				last = last - 1
			char* text = malloc(last - at + 1)
			int k = 0
			while (at + k < last):
				text[k] = line[at + k]
				k = k + 1
			text[k] = 0
			at = stop + 1
			if (starts_with(text, c"db ")):
				continue
			stubs_check_one(path, index, arch, corpus, corpus_path, text)
			checked = checked + 1
	return checked


int main():
	stubs_missing = 0
	int n = stubs_check(c"code_generator/x86_asm.w", c"x86_asm", ASM_ARCH_X86(), c"tests/asm/corpus_x86.txt")
	n = n + stubs_check(c"code_generator/x64_asm.w", c"x64_asm", ASM_ARCH_X64(), c"tests/asm/corpus_x64.txt")
	n = n + stubs_check(c"code_generator/arm64_asm.w", c"a64_asm", ASM_ARCH_ARM64(), c"tests/asm/corpus_arm64.txt")
	if (stubs_missing > 0):
		print2(itoa(stubs_missing))
		println2(c" stub instruction(s) missing from the corpus")
		return 1
	print(itoa(n))
	println(c" stub instructions match the corpus")
	println(c"asm_stubs_test passed")
	return 0
