/*
Stub-generator core for the runtime stubs committed as hand-hexed
emit()/a64(op()) calls in code_generator/{x86,x64,arm64}_asm.w
(docs/projects/assembler_disassembler.md, issue #170).

Three pieces, shared by tools/gen_stubs.w and tests/asm_stubs_test.w:

1. A loader for the assembly-text stub sources
   (tests/asm/stubs_{x86,x64,arm64}.asm): `arch x86|x64|arm64` picks the
   encoder, `func NAME` opens a stub, one instruction per tab-indented
   line, a tab followed by '#' starts a trailing comment (the canonical
   instruction text never contains a tab). Each function is assembled
   through the libs/asm text parsers + encoders as it loads.

2. An extractor that reads a committed *_asm.w file back into the same
   per-function byte streams: emit(n, c"\xNN...") strings are decoded
   (and n is checked against the escape count — a mismatch means the
   stub emits stray or truncated bytes), a64(op(0xAA, 0xBBBBBB)) words
   are rebuilt little-endian in source text order, and
   sym_define_declare_global_function(c"...") / top-level `void f():`
   lines delimit the functions. Conditionally emitted words (target_os,
   arm64_pac) and loop base words appear in text order exactly as the
   stub sources list them.

3. asm_stub_check(): assemble a stub source, extract its committed
   twin, and exit(1) with a byte diff on any drift.

Compiled by the seed-compat gate (asm_seed_gate): only seed-understood
syntax here.
*/
import lib.lib
import lib.file
import libs.asm.insn
import libs.asm.hexutil
import libs.asm.text
import libs.asm.x86_encode
import libs.asm.arm64_text
import libs.asm.arm64_encode


# Architecture selectors for one stub source (word size; 2 marks the
# fixed-width arm64 encoder).
int ASM_STUB_X86():
	return 4


int ASM_STUB_X64():
	return 8


int ASM_STUB_ARM64():
	return 2


struct asm_stub_func:
	char* name
	int line_start   # first index into asm_stub_source.texts (-1: extracted)
	int line_count
	asm_buffer* bytes


struct asm_stub_source:
	int arch
	list[char*] texts             # instruction texts, whole-file order
	list[asm_stub_func] funcs


void asm_stub_fail(char* path, int line, char* message, char* detail):
	print2(path)
	print2(c":")
	print2(itoa(line))
	print2(c": ")
	print2(message)
	if (cast(int, detail) != 0):
		print2(c": ")
		print2(detail)
	println2(c"")
	exit(1)


# Substring search; returns the index of pat in line or -1.
int asm_stub_find(char* line, char* pat):
	int n = strlen(line)
	int m = strlen(pat)
	int i = 0
	while (i + m <= n):
		int j = 0
		while (j < m && line[i + j] == pat[j]):
			j = j + 1
		if (j == m):
			return i
		i = i + 1
	return -1


# Copy [start, end) of line into a fresh string.
char* asm_stub_slice(char* line, int start, int end):
	char* out = malloc(end - start + 1)
	int i = 0
	while (start + i < end):
		out[i] = line[start + i]
		i = i + 1
	out[i] = 0
	return out


# Assemble one instruction line for arch into b. Returns the number of
# bytes appended, or -1 when the parser/encoder rejects the text.
int asm_stub_assemble_line(int arch, char* text, asm_buffer* b):
	asm_insn insn
	if (arch == ASM_STUB_ARM64()):
		if (asm_arm64_parse(text, &insn) == 0):
			return -1
		return asm_arm64_encode(b, &insn)
	int parse_arch = ASM_ARCH_X86()
	if (arch == ASM_STUB_X64()):
		parse_arch = ASM_ARCH_X64()
	if (asm_x86_parse(text, parse_arch, &insn) == 0):
		return -1
	return asm_x86_encode(b, &insn)


############################ stub source loader ###############################

# Parse and assemble a stub source file. Any malformed line or
# unencodable instruction prints a diagnostic and exits(1).
asm_stub_source* asm_stub_source_load(char* path):
	asm_stub_source* src = cast(asm_stub_source*, malloc(12))
	src.arch = 0
	src.texts = new list[char*]
	src.funcs = new list[asm_stub_func]
	list[char*] lines = file_read_lines(path)
	if (cast(int, lines) == 0):
		asm_stub_fail(path, 0, c"cannot read stub source", 0)
	int have_func = 0
	asm_stub_func current
	current.name = 0
	current.line_start = 0
	current.line_count = 0
	current.bytes = asm_buffer_new()
	int index = 0
	while (index < lines.length):
		char* line = lines[index]
		index = index + 1
		if (line[0] == 0):
			continue
		if (line[0] == '#'):
			continue
		if (line[0] == '\t'):
			# instruction line: text runs to end of line or to the
			# trailing-comment tab
			if (have_func == 0):
				asm_stub_fail(path, index, c"instruction before any 'func'", line)
			int start = 1
			int end = start
			while (line[end] != 0 && line[end] != '\t'):
				end = end + 1
			while (end > start && line[end - 1] == ' '):
				end = end - 1
			char* text = asm_stub_slice(line, start, end)
			int n = asm_stub_assemble_line(src.arch, text, current.bytes)
			if (n <= 0):
				asm_stub_fail(path, index, c"cannot assemble", text)
			src.texts.push(text)
			current.line_count = current.line_count + 1
			continue
		if (starts_with(line, c"arch ")):
			if (strcmp(line + 5, c"x86") == 0):
				src.arch = ASM_STUB_X86()
			else if (strcmp(line + 5, c"x64") == 0):
				src.arch = ASM_STUB_X64()
			else if (strcmp(line + 5, c"arm64") == 0):
				src.arch = ASM_STUB_ARM64()
			else:
				asm_stub_fail(path, index, c"unknown arch", line + 5)
			continue
		if (starts_with(line, c"func ")):
			if (src.arch == 0):
				asm_stub_fail(path, index, c"'func' before 'arch'", line)
			if (have_func):
				src.funcs.push(current)
			current.name = strclone(line + 5)
			current.line_start = src.texts.length
			current.line_count = 0
			current.bytes = asm_buffer_new()
			have_func = 1
			continue
		asm_stub_fail(path, index, c"unrecognized line", line)
	if (have_func):
		src.funcs.push(current)
	return src


########################### committed-file extractor ##########################

# Decode the c"\xNN..." string of an emit() call; `at` indexes right
# after "emit(". Appends the bytes to b and returns the escape count, or
# -1 on a malformed string. (34 = '"', 92 = '\'; the seed's char
# literals have no hex escapes.)
int asm_stub_read_emit(char* line, int at, asm_buffer* b):
	int i = at
	while (line[i] != 0 && line[i] != ','):
		i = i + 1
	if (line[i] != ','):
		return -1
	int quote_at = asm_stub_find(line + i, c"c\x22")
	if (quote_at < 0):
		return -1
	i = i + quote_at + 2
	int count = 0
	while (line[i] != 0 && line[i] != 34):
		if (line[i] != 92):
			return -1
		if (line[i + 1] != 'x'):
			return -1
		int hi = asm_hex_digit(line[i + 2])
		if (hi < 0):
			return -1
		int lo = asm_hex_digit(line[i + 3])
		if (lo < 0):
			return -1
		asm_buffer_byte(b, (hi << 4) | lo)
		count = count + 1
		i = i + 4
	if (line[i] != 34):
		return -1
	return count


# Parse the declared length of an emit(n, ...) call at `at` (the index
# right after "emit(").
int asm_stub_read_emit_length(char* line, int at):
	int n = 0
	while (line[at] >= '0' && line[at] <= '9'):
		n = n * 10 + (line[at] - '0')
		at = at + 1
	return n


# Parse a hex number (digits only, no 0x prefix) starting at `at`.
int asm_stub_read_hex(char* line, int at):
	int v = 0
	while (asm_hex_digit(line[at]) >= 0):
		v = (v << 4) | asm_hex_digit(line[at])
		at = at + 1
	return v


# Extract the per-function byte streams from a committed *_asm.w file.
# Stubs whose calls are arity-checked by the compiler: the committed
# files declare them with sym_define_declare_global_function_arity, and
# gen_stubs prints that form back. Returns the argument count, or -1
# for stubs declared without one.
int asm_stub_known_arity(char* name):
	if (strcmp(name, c"syscall") == 0):
		return 4
	if (strcmp(name, c"syscall7") == 0):
		return 7
	return -1


# Functions are delimited by sym_define_declare_global_function(c"...")
# / sym_define_declare_global_function_arity(c"...", n) calls and
# top-level `void f():` definitions; segments that emit no bytes
# (wrapper functions) are dropped.
list[asm_stub_func] asm_stub_extract_w(char* path):
	list[asm_stub_func] funcs = new list[asm_stub_func]
	list[char*] lines = file_read_lines(path)
	if (cast(int, lines) == 0):
		asm_stub_fail(path, 0, c"cannot read committed stub file", 0)
	char* define_pat = c"sym_define_declare_global_function(c\x22"
	char* define_arity_pat = c"sym_define_declare_global_function_arity(c\x22"
	int have_func = 0
	asm_stub_func current
	current.name = 0
	current.line_start = -1
	current.line_count = 0
	current.bytes = asm_buffer_new()
	int index = 0
	while (index < lines.length):
		char* line = lines[index]
		index = index + 1
		# skip '#' comment lines so prose mentioning emit()/op() is inert
		int first = 0
		while (line[first] == '\t' || line[first] == ' '):
			first = first + 1
		if (line[first] == '#'):
			continue
		int pat_len = strlen(define_arity_pat)
		int at = asm_stub_find(line, define_arity_pat)
		if (at < 0):
			at = asm_stub_find(line, define_pat)
			pat_len = strlen(define_pat)
		if (at >= 0):
			if (have_func):
				if (current.bytes.length > 0):
					funcs.push(current)
			at = at + pat_len
			int end = at
			while (line[end] != 0 && line[end] != 34):
				end = end + 1
			current.name = asm_stub_slice(line, at, end)
			current.line_start = -1
			current.line_count = 0
			current.bytes = asm_buffer_new()
			have_func = 1
			continue
		# top-level `void f():` / `int f():` definitions also delimit
		# segments (arm64_darwin_svc emits before any sym_define call)
		if (starts_with(line, c"void ") | starts_with(line, c"int ")):
			if (asm_stub_find(line, c"():") >= 0):
				if (have_func):
					if (current.bytes.length > 0):
						funcs.push(current)
				int name_at = asm_stub_find(line, c" ") + 1
				int name_end = name_at
				while (line[name_end] != 0 && line[name_end] != '('):
					name_end = name_end + 1
				current.name = asm_stub_slice(line, name_at, name_end)
				current.line_start = -1
				current.line_count = 0
				current.bytes = asm_buffer_new()
				have_func = 1
				continue
		int emit_at = asm_stub_find(line, c"emit(")
		if (emit_at >= 0):
			if (have_func == 0):
				asm_stub_fail(path, index, c"emit() before any function", line)
			int declared = asm_stub_read_emit_length(line, emit_at + 5)
			int count = asm_stub_read_emit(line, emit_at + 5, current.bytes)
			if (count < 0):
				asm_stub_fail(path, index, c"cannot parse emit() byte string", line)
			if (count != declared):
				print2(path)
				print2(c":")
				print2(itoa(index))
				print2(c": emit() length ")
				print2(itoa(declared))
				print2(c" does not match its ")
				print2(itoa(count))
				println2(c" string bytes (stray or truncated emission)")
				exit(1)
			continue
		int op_at = asm_stub_find(line, c"op(0x")
		if (op_at >= 0):
			if (have_func == 0):
				asm_stub_fail(path, index, c"a64(op()) before any function", line)
			int msb = asm_stub_read_hex(line, op_at + 5)
			int low_at = asm_stub_find(line + op_at, c", 0x")
			if (low_at < 0):
				asm_stub_fail(path, index, c"cannot parse op() word", line)
			int low = asm_stub_read_hex(line, op_at + low_at + 4)
			asm_buffer_int32(current.bytes, (msb << 24) | low)
			continue
	if (have_func):
		if (current.bytes.length > 0):
			funcs.push(current)
	return funcs


################################# drift check #################################

# Assemble stub_path, extract committed_path, and compare function names
# and bytes in order. Prints a per-file summary on success; prints a
# diff and exits(1) on any drift.
void asm_stub_check(char* stub_path, char* committed_path):
	asm_stub_source* src = asm_stub_source_load(stub_path)
	list[asm_stub_func] committed = asm_stub_extract_w(committed_path)
	if (src.funcs.length != committed.length):
		print2(stub_path)
		print2(c": ")
		print2(itoa(src.funcs.length))
		print2(c" stubs but ")
		print2(committed_path)
		print2(c" defines ")
		println2(itoa(committed.length))
		exit(1)
	int total = 0
	int i = 0
	while (i < src.funcs.length):
		asm_stub_func want = src.funcs[i]
		asm_stub_func have = committed[i]
		if (strcmp(want.name, have.name) != 0):
			print2(c"stub order mismatch at #")
			print2(itoa(i))
			print2(c": ")
			print2(stub_path)
			print2(c" has ")
			print2(want.name)
			print2(c" but ")
			print2(committed_path)
			print2(c" has ")
			println2(have.name)
			exit(1)
		char* context = strjoin(committed_path, strjoin(c" ", want.name))
		asm_assert_bytes_equal(context, have.bytes.data, have.bytes.length, want.bytes.data, want.bytes.length)
		total = total + have.bytes.length
		i = i + 1
	print2(committed_path)
	print2(c": ")
	print2(itoa(src.funcs.length))
	print2(c" stubs, ")
	print2(itoa(total))
	println2(c" bytes match")
