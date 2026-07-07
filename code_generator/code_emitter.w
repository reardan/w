import code_generator.integer


char *code
int code_size
int codepos
int base_code_offset
int code_offset

# W^X text/data split (Stage 3 of docs/projects/arm64.md). When data_split
# is set, mutable global-variable storage is emitted into a separate RW
# buffer (`data`) mapped at data_offset, so the executable segment stays
# read-execute and the data segment read-write. The in-process REPL and
# debugger leave data_split at 0, keeping globals inline in the single
# executed buffer (their mmap is RWX), so nothing changes for them.
char *data
int data_size
int datapos
int data_offset
int data_split

# Active emit destination: 0 = code (the default, executable image),
# 1 = the RW data segment. Only global-storage emission flips it.
int emit_target

int word_size
int word_size_log2

# Target instruction-set family: 0 = x86/x86-64, 1 = arm64 (AArch64).
# word_size still distinguishes 32- vs 64-bit pointers; target_isa selects
# which instruction emitter the x86.w helpers dispatch to. Defaults to 0 so
# the x86 and x64 targets are wholly unaffected.
int target_isa

# Where the finished ELF is written: stdout by default, or the file given
# with the -o flag.
int output_fd

# File offset of the program header table and of the rel32 displacement in
# the entry stub's "call _main". Both shift when the header layout changes
# (e.g. reserving extra program headers for dynamic linking), so the finish
# pass patches these recorded positions instead of hardcoded constants.
int phdr_table_pos
int entry_call_disp_pos


void resize_code(int n):
	if (emit_target == 1):
		if (data_size <= datapos + n):
			int x = (datapos + n) << 1
			data = realloc(data, data_size, x)
			data_size = x
		return
	if (code_size <= codepos + n):
		int x = (codepos + n) << 1
		code = realloc(code, code_size, x)
		code_size = x


# Virtual address of the current emit cursor: the data segment when
# emit_target is 1 (global-variable storage), the code segment otherwise.
int be_here():
	if (emit_target == 1):
		return data_offset + datapos
	return code_offset + codepos


void emit(int n, char *s):
	resize_code(n)
	if (emit_target == 1):
		int di = 0
		while (di < n):
			data[datapos] = s[di]
			datapos = datapos + 1
			di = di + 1
		return
	int i = 0
	while (i < n):
		code[codepos] = s[i]
		codepos = codepos + 1
		i = i + 1


void emit_string(char* s):
	emit(strlen(s) + 1, s)


void emit_string_raw(char* s):
	print_int(c"strlen(s)= ", strlen(s))
	emit(strlen(s), s)


void emit_i(int v, int n):
	resize_code(n)
	if (emit_target == 1):
		save_i(data + datapos, v, n)
		datapos = datapos + n
		return
	char* p = code + codepos
	save_i(p, v, n)
	codepos = codepos + n


void emit_int8(int v):
	emit_i(v, 1)


void emit_int16(int v):
	emit_i(v, 2)


void emit_int32(int v):
	emit_i(v, 4)


void emit_int64(int v):
	emit_i(v, 8)


void emit_target_word(int v):
	if (word_size == 8):
		emit_int64(v)
	else:
		emit_int32(v)


void emit_int(int v):
	emit_int32(v)


void emit_zeros(int num):
	while (num > 0):
		emit_int8(0)
		num = num - 1
