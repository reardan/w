# wbuild: arch_only=x64
# wbuild: deps=tests/kernel_codegen/
# --kernel-codegen (docs/projects/object_files.md, "Kernel code
# generation"): code that is safe in kernel context. The corpus
# (tests/kernel_codegen/corpus.w) is compiled with --emit=obj
# --freestanding --kernel-codegen, linked with a libc-free startup built
# with -mno-red-zone, and run twice: once plainly and once single-stepped
# under ptrace with the memory below %rsp overwritten before every
# instruction, which is what an interrupt on the same stack does. Both
# runs must print the same checksum. A C leaf that does use its red
# zone is the negative control proving the clobbering bites.
import lib.testing
import tests.tool_e2e
import lib.file
import lib.str


char* kc_dir


char* kc_path(char* name):
	return path_join(kc_dir, name)


void kc_compile(char*... args):
	list[char*] argv = new list[char*]
	argv.push(c"wv2")
	for char* arg in args: argv.push(arg)
	process_result* r = tool_spawn(0, 60000, argv)
	if (r.status != 0): println2(r.stderr_text)
	assert_equal(0, r.status)
	process_result_free(r)


# The compile fails with a diagnostic naming the problem.
void kc_reject(char* diagnostic, char*... args):
	list[char*] argv = new list[char*]
	argv.push(c"wv2")
	for char* arg in args: argv.push(arg)
	process_result* r = tool_spawn(0, 60000, argv)
	if (r.status != 1): println2(r.stderr_text)
	assert_equal(1, r.status)
	assert_contains(r.stderr_text, diagnostic)
	process_result_free(r)


# A host tool (cc, objdump, ld) through the shell; returns its stdout
# and requires exit status 0.
char* kc_shell(char* command):
	char** argv = strv_new(3)
	strv_set(argv, 0, c"/bin/sh")
	strv_set(argv, 1, c"-c")
	strv_set(argv, 2, command)
	process_result* r = process_run(c"/bin/sh", argv, 0, 0, 120000)
	assert1(r != 0)
	if (r.status != 0):
		println2(command)
		println2(r.stdout_text)
		println2(r.stderr_text)
	assert_equal(0, r.status)
	char* out = strclone(r.stdout_text)
	process_result_free(r)
	free(cast(void*, argv))
	return out


# Compile a W source to <name>.o in kernel mode.
char* kc_object(char* source, char* name):
	char* object = kc_path(strjoin(name, c".o"))
	kc_compile(c"x64", c"--emit=obj", c"--freestanding", c"--kernel-codegen", source, c"-o", object)
	return object


# Link object(s) with the bare startup into a static executable.
char* kc_link(char* name, char* objects):
	char* exe = kc_path(name)
	string_builder* cmd = string_new()
	string_append(cmd, c"cc -O1 -nostdlib -static -fno-pie -no-pie -mno-red-zone -fno-stack-protector -fno-asynchronous-unwind-tables -o ")
	string_append(cmd, exe)
	string_append(cmd, c" tests/kernel_codegen/start.c ")
	string_append(cmd, objects)
	free(kc_shell(cmd.data))
	return exe


void test_kernel_codegen_setup():
	kc_dir = tool_scratch(c"kernel_codegen_")
	assert_equal(0, mkdir(kc_dir, 493))


############################ the ptrace stepper ############################
# Linux delivers signals 128 bytes below %rsp on x86-64, so a signal
# cannot show red-zone use; a debugger can. kc_trace runs exe with its
# stdout in out_path, single-stepping it, and before every instruction
# overwrites kc_clobber bytes below the tracee's %rsp through
# /proc/<pid>/mem. It also follows calls and returns, keeping each
# function entry's deepest stack use (bytes from the caller's %rsp
# before the call down to the lowest %rsp inside, callees excluded),
# for the --stack-usage cross-check.

const int kc_clobber = 256
const int kc_max_entries = 512
int[512] kc_entry_addr
int[512] kc_entry_depth
int kc_entry_count
int kc_steps


int kc_entry_slot(int addr):
	for i in range(kc_entry_count):
		if (kc_entry_addr[i] == addr): return i
	assert1(kc_entry_count < kc_max_entries)
	kc_entry_addr[kc_entry_count] = addr
	kc_entry_depth[kc_entry_count] = 0
	kc_entry_count = kc_entry_count + 1
	return kc_entry_count - 1


# Returns the tracee's exit status.
int kc_trace(char* exe, char* out_path, int clobber):
	int out_fd = open(out_path, 577, 420)
	assert1(out_fd >= 0)
	int pid = fork()
	if (pid == 0):
		dup2(out_fd, 1)
		sys_ptrace(0, 0, 0, 0)   # PTRACE_TRACEME
		char** argv = strv_new(1)
		strv_set(argv, 0, exe)
		char** envp = strv_new(0)
		execve(exe, argv, envp)
		exit(127)
	close(out_fd)
	int status = 0
	wait4(pid, &status, 0, 0)
	assert_equal(0x7f, status & 0xff)   # stopped at the exec
	char* mem_path = strjoin(strjoin(c"/proc/", itoa(pid)), c"/mem")
	int mem = open(mem_path, 2, 0)
	assert1(mem >= 0)
	char* regs = cast(char*, malloc(27 * 8))
	char* poison = cast(char*, malloc(kc_clobber))
	for i in range(kc_clobber): poison[i] = cast(char, 0xa5)
	char[16] insn
	# the open frames: entry address, caller %rsp before the call, lowest %rsp
	int[4096] frame_entry
	int[4096] frame_base
	int[4096] frame_low
	int depth = 0
	kc_entry_count = 0
	kc_steps = 0
	while (1):
		assert_equal(0, sys_ptrace(12, pid, 0, cast(int, regs)))   # PTRACE_GETREGS
		int rip = load_word(regs + 128)
		int rsp = load_word(regs + 152)
		if (depth > 0):
			if (rsp < frame_low[depth - 1]): frame_low[depth - 1] = rsp
		if (clobber): sys_pwrite(mem, poison, kc_clobber, rsp - kc_clobber)
		insn[0] = 0
		insn[1] = 0
		sys_pread(mem, &insn[0], 16, rip)
		int op = insn[0] & 255
		int modrm = insn[1] & 255
		int is_call = (op == 0xe8) || ((op == 0xff) && (((modrm >> 3) & 7) == 2))
		int is_ret = op == 0xc3
		assert_equal(0, sys_ptrace(9, pid, 0, 0))   # PTRACE_SINGLESTEP
		wait4(pid, &status, 0, 0)
		kc_steps = kc_steps + 1
		if ((status & 0x7f) == 0): break   # exited
		assert_equal(0x7f, status & 0xff)
		# a stop other than the step's SIGTRAP is the tracee faulting
		if (((status >> 8) & 0xff) != 5):
			println2(strjoin(c"tracee stopped by signal ", itoa((status >> 8) & 0xff)))
			kill(pid, 9)
			wait4(pid, &status, 0, 0)
			return 256
		if (is_call):
			assert1(depth < 4096)
			assert_equal(0, sys_ptrace(12, pid, 0, cast(int, regs)))
			int sp = load_word(regs + 152)
			frame_entry[depth] = load_word(regs + 128)
			frame_base[depth] = sp + 8
			frame_low[depth] = sp
			depth = depth + 1
		else if (is_ret && (depth > 0)):
			depth = depth - 1
			int slot = kc_entry_slot(frame_entry[depth])
			int used = frame_base[depth] - frame_low[depth]
			if (used > kc_entry_depth[slot]): kc_entry_depth[slot] = used
	close(mem)
	free(regs)
	free(poison)
	free(mem_path)
	return (status >> 8) & 0xff


char* kc_run_traced(char* exe, int clobber):
	char* out_path = strjoin(exe, c".out")
	assert_equal(0, kc_trace(exe, out_path, clobber))
	char* out = file_read_text(out_path)
	assert1(out != 0)
	free(out_path)
	return out


void test_kernel_codegen_red_zone():
	char* object = kc_object(c"tests/kernel_codegen/corpus.w", c"corpus")
	char* exe = kc_link(c"corpus", object)
	char* plain = kc_shell(exe)
	assert1(strlen(plain) > 1)
	char* traced = kc_run_traced(exe, 1)
	assert_strings_equal(plain, traced)
	assert1(kc_steps > 10000)


# The control: a C leaf compiled with the red zone keeps its locals
# below %rsp (gcc -O0 does not move %rsp in a leaf), so clobbering
# changes its result (or crashes it), which proves the stepper would catch W doing so.
void test_kernel_codegen_red_zone_control():
	char* source = kc_path(c"control.c")
	assert_equal(1, file_write_text(source, c"long kc_main(void) { volatile long a[8]; long s = 0; for (int i = 0; i < 8; i++) a[i] = i * 3; for (int i = 0; i < 8; i++) s += a[i]; return s; }\nlong kc_callback(long a, long b) { return a + b; }\n"))
	char* object = kc_path(c"control.o")
	free(kc_shell(strjoin(strjoin(strjoin(c"cc -O0 -fno-pie -fno-stack-protector -c -o ", object), c" "), source)))
	char* exe = kc_link(c"control", object)
	char* plain = kc_shell(exe)
	assert_strings_equal(c"84\n", plain)
	# clobbered: a wrong sum, or a crash once the loop index is garbage
	char* out_path = strjoin(exe, c".out")
	int status = kc_trace(exe, out_path, 1)
	char* traced = file_read_text(out_path)
	assert1((status != 0) || (strcmp(plain, traced) != 0))
	char* unclobbered = kc_run_traced(exe, 0)
	assert_strings_equal(plain, unclobbered)


########################### the disassembly scan ###########################
# objdump decodes .text linearly, but W keeps some literal bytes in
# .text (string bytes after a function, or behind a 'jmp'; moving them
# out is the section-placement work), which the decoder reads as
# garbage. Code after an unconditional 'ret'/'jmp'/'ud2' is reachable
# only as a branch or call target or a symbol, so the scan skips lines
# from such a terminator until one of those addresses; when the decoder
# steps over that address (desynchronized by the data), objdump is
# restarted there.

int kc_hex(char* s, int* end):
	int v = 0
	int i = 0
	while (1):
		int c = s[i]
		if ((c >= '0') && (c <= '9')): v = v * 16 + c - '0'
		else if ((c >= 'a') && (c <= 'f')): v = v * 16 + c - 'a' + 10
		else: break
		i = i + 1
	*end = i
	return v


# One decoded instruction line: "  <hex addr>:\t<mnemonic> <operands>".
# Returns the address, or -1 for any other line; *text_out is the
# instruction text.
int kc_insn_line(char* line, char** text_out):
	int i = 0
	while (line[i] == ' '): i = i + 1
	int n = 0
	int addr = kc_hex(line + i, &n)
	if ((n == 0) || (line[i + n] != ':') || (line[i + n + 1] != 9)): return -1
	*text_out = line + i + n + 2
	return addr


# A symbol line "<16 hex digits> <name>:": its address, else -1.
int kc_symbol_line(char* line):
	int n = 0
	int addr = kc_hex(line, &n)
	if ((n != 16) || (line[16] != ' ') || (line[17] != '<')): return -1
	return addr


# The direct target of a branch or call ("jne    2a5 <f+0x4e>"), or -1.
int kc_branch_target(char* text):
	if ((text[0] != 'j') && (starts_with(text, c"call") == 0)): return -1
	int k = 0
	while ((text[k] != 0) && (text[k] != ' ')): k = k + 1
	while (text[k] == ' '): k = k + 1
	int n = 0
	int target = kc_hex(text + k, &n)
	if ((n == 0) || (text[k + n] != ' ')): return -1
	return target


int kc_terminator(char* text):
	if (starts_with(text, c"ret") || starts_with(text, c"ud2")): return 1
	return starts_with(text, c"jmp ")


# Why an instruction is not kernel-safe, or 0: SSE/AVX/MMX/x87 state, or
# memory below %rsp.
char* kc_insn_problem(char* text):
	if (contains(text, c"%xmm") || contains(text, c"%ymm") || contains(text, c"%zmm")): return c"SSE/AVX register"
	if (contains(text, c"%mm") || contains(text, c"%st")): return c"MMX/x87 register"
	if (text[0] == 'f'): return c"x87 instruction"
	if (starts_with(text, c"ldmxcsr") || starts_with(text, c"stmxcsr") || starts_with(text, c"emms")): return c"FPU state"
	if (starts_with(text, c"xsave") || starts_with(text, c"xrstor") || starts_with(text, c"vzero")): return c"FPU state"
	int at = index_of(text, c"(%rsp)")
	if (at > 0):
		int k = at - 1
		while ((k > 0) && (text[k] != ' ') && (text[k] != ',') && (text[k] != '-')): k = k - 1
		if (text[k] == '-'): return c"memory below %rsp"
	return 0


# The listing split into lines (NUL-terminated in place).
list[char*] kc_lines(char* listing):
	list[char*] lines = new list[char*]
	int i = 0
	while (listing[i] != 0):
		int end = i
		while ((listing[end] != 0) && (listing[end] != 10)): end = end + 1
		int last = listing[end] == 0
		listing[end] = 0
		lines.push(listing + i)
		if (last): break
		i = end + 1
	return lines


# Scan obj's .text; returns the number of problems (each printed) and
# the number of instructions checked in *count_out.
int kc_scan(char* object, int* count_out):
	map[int, int] targets = new map[int, int]
	int problems = 0
	int count = 0
	int start = 0
	while (start >= 0):
		string_builder* cmd = string_new()
		string_append(cmd, c"objdump -d --no-show-raw-insn -j .text --start-address=")
		string_append_int(cmd, start)
		string_append(cmd, c" ")
		string_append(cmd, object)
		char* listing = kc_shell(cmd.data)
		list[char*] lines = kc_lines(listing)
		# decoded line address -> its instruction text
		map[int, char*] decoded = new map[int, char*]
		for char* line in lines:
			char* text = 0
			int addr = kc_insn_line(line, &text)
			if (addr >= 0):
				decoded[addr] = text
				int target = kc_branch_target(text)
				if (target >= 0): targets[target] = 1
			else:
				addr = kc_symbol_line(line)
				if (addr >= 0): targets[addr] = 1
		int restart = -1
		int live = 1
		int skip_to = -1
		int previous = start
		for char* line in lines:
			if (kc_symbol_line(line) >= 0):
				live = 1
				continue
			char* text = 0
			int addr = kc_insn_line(line, &text)
			if (addr < 0): continue
			if ((skip_to >= 0) && (addr < skip_to)): continue
			skip_to = -1
			if (live == 0):
				if (targets.get(addr, 0)): live = 1
				else:
					# a target inside the previous decoded line: resync there
					for a in range(previous + 1, addr):
						if (targets.get(a, 0) && (restart < 0)): restart = a
					previous = addr
					if (restart >= 0): break
					continue
			previous = addr
			count = count + 1
			char* problem = kc_insn_problem(text)
			if (problem != 0):
				println2(strjoin(strjoin(strjoin(strjoin(object, c": "), problem), c": "), line))
				problems = problems + 1
			if (kc_terminator(text)): live = 0
			# A forward 'call T' or 'jmp T' over literal bytes: the call
			# form pushes the bytes' address and lands on a 'pop'. A target
			# the decoder never reached is data in between (restart there).
			int target = kc_branch_target(text)
			int is_jump = starts_with(text, c"jmp ") || starts_with(text, c"call")
			if (is_jump && (target > addr)):
				char* at = decoded.get(target, cast(char*, 0))
				if (at == 0):
					restart = target
					break
				if (starts_with(text, c"call") && starts_with(at, c"pop")): skip_to = target
		free(listing)
		start = restart
	*count_out = count
	return problems


# Integer-only programs compiled with the flag contain no SSE, AVX, MMX
# or x87 instruction and no operand below %rsp: the corpus, the object
# file test's library and freestanding-clean standard library modules.
void test_kernel_codegen_no_fpu_instructions():
	char*[8] sources
	sources[0] = c"tests/kernel_codegen/corpus.w"
	sources[1] = c"tests/object_file/library.w"
	sources[2] = c"lib/sha256.w"
	sources[3] = c"lib/hex.w"
	sources[4] = c"lib/unicode_text.w"
	sources[5] = c"lib/safe_vector.w"
	sources[6] = c"lib/memory.w"
	sources[7] = c"lib/checked.w"
	int total = 0
	for i in range(8):
		char* object = kc_object(sources[i], strjoin(c"scan", itoa(i)))
		int count = 0
		assert_equal(0, kc_scan(object, &count))
		assert1(count > 50)
		total = total + count
	assert1(total > 20000)


# The scan's control: the same kind of object built without the flag
# from float code does contain SSE, and the scan reports it.
void test_kernel_codegen_scan_control():
	char* source = kc_path(c"float.w")
	assert_equal(1, file_write_text(source, c"export int f(int x):\n\tfloat64 y = cast(float64, x) * 2.5\n\treturn cast(int, y)\n"))
	char* object = kc_path(c"float.o")
	kc_compile(c"x64", c"--emit=obj", c"--freestanding", source, c"-o", object)
	int count = 0
	assert1(kc_scan(object, &count) > 0)


void kc_float_reject(char* name, char* body):
	char* source = kc_path(name)
	assert_equal(1, file_write_text(source, body))
	kc_reject(c"floating point is not allowed with --kernel-codegen", c"x64", c"--emit=obj", c"--freestanding", c"--kernel-codegen", source, c"-o", kc_path(c"rejected.o"))
	free(source)


# Float use is a compile error under the flag: literals, arithmetic,
# conversions, float extern calls and float export signatures.
void test_kernel_codegen_rejects_float():
	kc_float_reject(c"f1.w", c"float64 add(float64 a, float64 b):\n\treturn a + b\n")
	kc_float_reject(c"f2.w", c"export int f(int x):\n\tfloat64 y = 1.5\n\treturn x\n")
	kc_float_reject(c"f3.w", c"export float32 f(int x):\n\treturn cast(float32, x)\n")
	kc_float_reject(c"f4.w", c"export int f(float64 x):\n\treturn 1\n")
	kc_float_reject(c"f5.w", c"extern float64 cf(int x)\nexport int f(int x):\n\treturn 1\n")
	kc_float_reject(c"f6.w", c"int g(int x):\n\treturn cast(int, cast(float32, x))\n")


void test_kernel_codegen_mode_rejections():
	char* object = kc_path(c"rejected.o")
	kc_reject(c"--kernel-codegen requires --emit=obj --freestanding", c"x64", c"--emit=obj", c"--kernel-codegen", c"tests/kernel_codegen/corpus.w", c"-o", object)
	kc_reject(c"--kernel-codegen requires --emit=obj --freestanding", c"x64", c"--kernel-codegen", c"tests/kernel_codegen/corpus.w", c"-o", object)


void test_kernel_codegen_cleanup():
	dir_remove_all(kc_dir)
	free(kc_dir)
