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

int word_size
int word_size_log2

# Target instruction-set family: 0 = x86/x86-64, 1 = arm64 (AArch64).
# word_size still distinguishes 32- vs 64-bit pointers; target_isa selects
# which instruction emitter the x86.w helpers dispatch to. Defaults to 0 so
# the x86 and x64 targets are wholly unaffected.
int target_isa

# Target operating system / executable container: 0 = linux (ELF),
# 1 = darwin (Mach-O, the arm64_darwin target, docs/projects/arm64.md
# Stage 4), 2 = windows (PE32+, the win64 target,
# docs/projects/windows.md). Selects the container writer, the __arch__
# library modules and the extern C ABI. Defaults to 0 so every existing
# Linux target is wholly unaffected.
int target_os

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
	if (code_size <= codepos + n):
		int x = (codepos + n) << 1
		code = realloc(code, code_size, x)
		code_size = x


void emit(int n, char *s):
	resize_code(n)
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
	char* p = code + codepos
	save_i(p, v, n)
	codepos = codepos + n


# --- RW data segment (Stage 3 W^X split) --------------------------------
# Global-variable storage is appended here through these helpers, keeping
# the hot code-emission path (emit / emit_i) untouched.

void ensure_data(int n):
	if (data_size <= datapos + n):
		int x = (datapos + n) << 1
		if (x < 4096):
			x = 4096
		data = realloc(data, data_size, x)
		data_size = x


# Reserve n zero bytes and return the vaddr of the reserved region's start.
int emit_data_zeros(int n):
	ensure_data(n)
	int start = datapos
	int i = 0
	while (i < n):
		data[datapos] = 0
		datapos = datapos + 1
		i = i + 1
	return data_offset + start


# Append one target word (8 bytes on the 64-bit arm64 target).
void emit_data_word(int v):
	ensure_data(word_size)
	save_i(data + datapos, v, word_size)
	datapos = datapos + word_size


# --- Rebase table (PIE groundwork, arm64 targets) ------------------------
# Pointer-sized cells in the RW data segment that hold absolute linked
# vaddrs (string-descriptor data pointers, global array headers) are
# recorded here during compilation. The container writer appends the
# table (count + entries, one word each) to the data segment and the
# entry stub adds the load slide to every listed cell at startup, so the
# image stays correct when the kernel slides it (always 0 for the ET_EXEC
# ELF; the Mach-O target is mandatorily PIE). Code needs no entries:
# address materialization is PC-relative (adrp+add) on arm64.

char* rebase_table
int rebase_table_size
int rebase_count


# Record the vaddr of one pointer-sized data cell whose stored value
# must be slid at startup.
void rebase_note(int vaddr):
	int needed = (rebase_count + 1) * 8
	if (rebase_table_size < needed):
		int x = needed << 1
		if (x < 4096):
			x = 4096
		rebase_table = realloc(rebase_table, rebase_table_size, x)
		rebase_table_size = x
	save_i(rebase_table + rebase_count * 8, vaddr, 8)
	rebase_count = rebase_count + 1


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
