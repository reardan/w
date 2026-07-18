/*
Attach to a running process (wdbg --attach <pid> [file.w]).

Unlike the rest of wdbg, which runs the debuggee inside its own address
space and drives it from signal handlers, attach mode controls a separate,
already-running process through ptrace(2). It is a self-contained command
loop: wdbg.w's signal handlers and execution-control state are never
entered, so attaching cannot perturb the self-hosting model and needs
none of that machinery. Memory inspection is the one place attach mode
plugs into shared code: debugger/memory.w's target-access seam (#123
phase 2) dispatches dbg_mem_readable/dbg_mem_read through a registered
reader, and this file installs at_mem_readable/at_mem_read -- thin
wrappers around the existing PTRACE_PEEKDATA read below -- as that
reader (wdbg_attach_run), so at_examine (x/st) goes through the same
entry points the in-process debugger uses. Registers stay a separate,
attach-local model (user_regs_struct via PTRACE_GETREGS, not the
in-process sigcontext accessors); unifying those is future work.

Two levels of capability:

  * Raw mode (always): registers, memory (x), stack (st), breakpoints,
    single-step and continue, and disassembly (disas, by absolute
    address or from the stopped ip; bytes read via PTRACE_PEEKDATA),
    all in absolute target addresses. Needs no source and works
    whenever ptrace attach succeeds.

  * Symbolized mode (when a source file is given and validates): function
    names, file:line and source listing for addresses inside the
    debuggee's code. wdbg recompiles the source in-process to regenerate
    the symbol and line tables (which are never emitted into the ELF), then
    maps target addresses to those tables through a constant delta.

    The delta is derived from the target's ELF entry point and the compiler's
    fixed header/entry-stub prologue, then VALIDATED by comparing the first
    bytes of the runtime-stub region in the process against the freshly
    compiled bytes. A mismatch (stale source, different compiler, a PIE or
    non-x86 binary) disables symbols and falls back to raw mode rather than
    printing wrong names. Symbolization is currently x86 (32-bit) only; on
    other word sizes attach mode stays in raw mode.

Scope: Linux, statically linked non-PIE x86/x86-64 ELF debuggees, attached
locally. Expression evaluation and locals inspection are not yet wired into
attach mode; see docs/projects/debugger_attach.md.
*/
import lib.lib
import lib.line_edit
import debugger.lines
import debugger.symbols
import debugger.breakpoints
import debugger.disas
import debugger.memory


# --- ptrace request numbers (classic ABI, identical on i386 and x86-64) ---
int at_PEEKDATA():
	return 2
int at_POKEDATA():
	return 5
int at_CONT():
	return 7
int at_SINGLESTEP():
	return 9
int at_GETREGS():
	return 12
int at_SETREGS():
	return 13
int at_ATTACH():
	return 16
int at_DETACH():
	return 17


# Byte offsets of the fields we use inside the ptrace user_regs_struct.
# The layout differs from the signal-frame sigcontext, so these are their
# own accessors. i386: 17 words; x86-64: 27 words.
int at_off_ip():
	if (__word_size__ == 8):
		return 128 /* rip: index 16 */
	return 48 /* eip: index 12 */
int at_off_sp():
	if (__word_size__ == 8):
		return 152 /* rsp: index 19 */
	return 60 /* esp: index 15 */


# --- state ---
int attach_pid
int attach_alive        /* 1 while the tracee is stopped under our control */
int attach_pending_sig  /* signal to redeliver on the next resume, or 0 */
int attach_symbolized   /* 1 when the source validated against the process */
int attach_delta        /* target_address = in_process_address + attach_delta */
int attach_wordbuf      /* scratch for PTRACE_PEEK results */
int attach_statusbuf    /* scratch for wait4 status */
int attach_regs         /* user_regs_struct buffer */


# --- memory access through ptrace ---
int attach_read_ok

# Read one word at a target address. Sets attach_read_ok to 0 when the
# address is unmapped (the raw peek returns a negative errno). The peeked
# word is written by the kernel to *data, so we read it back from the
# scratch buffer rather than from the return value.
int at_read_word(int addr):
	int r = sys_ptrace(at_PEEKDATA(), attach_pid, addr, attach_wordbuf)
	if ((r < 0) && (r >= -4095)):
		attach_read_ok = 0
		return 0
	attach_read_ok = 1
	return load_word(cast(char*, attach_wordbuf))


int at_read_byte(int addr):
	return at_read_word(addr) & 255


int at_write_word(int addr, int value):
	return sys_ptrace(at_POKEDATA(), attach_pid, addr, value)


# --- target-access seam (#123 phase 2, docs/projects/debugger_attach.md) ---
# Installed as debugger/memory.w's dbg_mem_readable_fn/dbg_mem_read_fn by
# wdbg_attach_run, so the shared inspection entry points (dbg_mem_readable,
# dbg_mem_read, dbg_mem_read_word) work against an attached target exactly
# like they work in-process: at_examine (the x/st commands) goes through
# them below instead of calling at_read_word directly. No new ptrace
# semantics -- both adapters are read-only wrappers around the existing
# at_read_word peek.

# n is at most __word_size__ for every caller today (a single peek covers
# it); the loop is a safety net for a hypothetically larger range.
int at_mem_readable(int addr, int n):
	if (n <= __word_size__):
		at_read_word(addr)
		return attach_read_ok
	int end = addr + n
	int a = addr
	while (a < end):
		at_read_word(a)
		if (attach_read_ok == 0):
			return 0
		a = a + __word_size__
	return 1


# PTRACE_PEEKDATA reads at any byte address on x86/x86-64 Linux (no
# alignment requirement), so the word at addr already holds the requested
# narrower value in its low bytes -- just mask.
int at_mem_read(int addr, int width):
	int v = at_read_word(addr)
	dbg_mem_read_ok = attach_read_ok
	if (width >= __word_size__):
		return v
	return v & ((1 << (width * 8)) - 1)


# --- registers ---
void at_getregs():
	sys_ptrace(at_GETREGS(), attach_pid, 0, attach_regs)


int at_reg(int offset):
	return load_word(cast(char*, attach_regs + offset))


# Overwrite the tracee's instruction pointer (in the local buffer, then
# push the whole register file back). Used to rewind past a hit int3.
void at_set_ip(int value):
	save_word(cast(char*, attach_regs + at_off_ip()), value)
	sys_ptrace(at_SETREGS(), attach_pid, 0, attach_regs)


# --- wait status ---
int at_wait():
	wait4(attach_pid, cast(int*, attach_statusbuf), 0, 0)
	return load_int(cast(char*, attach_statusbuf))

int at_status_exited(int status):
	return (status & 127) == 0
int at_status_exitcode(int status):
	return (status >> 8) & 255
int at_status_signalled(int status):
	int s = status & 127
	return (s != 0) & (s != 127)
int at_status_termsig(int status):
	return status & 127
int at_status_stopsig(int status):
	return (status >> 8) & 255


# --- breakpoints (attach-mode table, absolute target addresses) ---
int at_bp_max():
	return 64

int attach_bp_addrs   /* target address, 0 = free (word slots) */
int attach_bp_orig    /* saved original low byte (int slots) */
int attach_bp_armed   /* 1 while the int3 is written (int slots) */
int attach_bp_count


int at_bp_addr(int i):
	return load_word(cast(char*, attach_bp_addrs + i * __word_size__))


# Slot index of the breakpoint at a target address, or -1.
int at_bp_find(int addr):
	int i = 0
	while (i < attach_bp_count):
		if (at_bp_addr(i) == addr):
			return i
		i = i + 1
	return -1


# Write the int3 for slot i (remembering the original low byte).
void at_bp_arm(int i):
	int addr = at_bp_addr(i)
	if (addr == 0):
		return;
	if (load_int(cast(char*, attach_bp_armed + i * 4))):
		return;
	int word = at_read_word(addr)
	if (attach_read_ok == 0):
		return;
	save_int(cast(char*, attach_bp_orig + i * 4), word & 255)
	at_write_word(addr, word - (word & 255) + 204) /* int3 = 0xcc */
	save_int(cast(char*, attach_bp_armed + i * 4), 1)


# Restore the original byte for slot i.
void at_bp_disarm(int i):
	int addr = at_bp_addr(i)
	if (addr == 0):
		return;
	if (load_int(cast(char*, attach_bp_armed + i * 4)) == 0):
		return;
	int word = at_read_word(addr)
	if (attach_read_ok == 0):
		return;
	int orig = load_int(cast(char*, attach_bp_orig + i * 4))
	at_write_word(addr, word - (word & 255) + orig)
	save_int(cast(char*, attach_bp_armed + i * 4), 0)


# Create and arm a breakpoint at a target address; returns the slot or -1.
int at_bp_add(int addr):
	if (at_bp_find(addr) >= 0):
		println(c"a breakpoint is already set there")
		return -1
	if (attach_bp_count >= at_bp_max()):
		println(c"too many breakpoints")
		return -1
	int i = attach_bp_count
	attach_bp_count = i + 1
	save_word(cast(char*, attach_bp_addrs + i * __word_size__), addr)
	save_int(cast(char*, attach_bp_armed + i * 4), 0)
	at_bp_arm(i)
	return i


# Byte reader for the shared disassembly code (debugger/disas.w):
# PTRACE_PEEKDATA through at_read_byte, with an armed attach-mode
# breakpoint's remembered original byte substituted for its int3 patch.
# Returns -1 when the address is unreadable.
int at_disas_read(int addr):
	int bp = at_bp_find(addr)
	if (bp >= 0):
		if (load_int(cast(char*, attach_bp_armed + bp * 4))):
			return load_int(cast(char*, attach_bp_orig + bp * 4))
	int v = at_read_byte(addr)
	if (attach_read_ok == 0):
		return -1
	return v


# --- address mapping and symbolization ---
# In-process (compiler-table) address for a target address, valid only when
# symbolized. The shared dbg_* helpers all work in in-process addresses.
int at_to_v(int target):
	return target - attach_delta


# 1 when a target address lands inside the debuggee's recompiled code.
int at_in_code(int target):
	if (attach_symbolized == 0):
		return 0
	return dbg_in_debuggee(at_to_v(target))


# Print "function (file:line)" plus the source line for a target address,
# or a bare hex address when it cannot be symbolized.
void at_print_location(int target):
	if (at_in_code(target)):
		int v = at_to_v(target)
		print(dbg_function_name(v))
		print(c" (")
		dbg_print_file_line(v)
		println(c")")
		dbg_print_source_at(v)
		return;
	print(c"at ")
	char* h = hex_word(target)
	println(h)
	free(h)


# Source file index at a target address, or -1: what a bare line number in
# a break target resolves against.
int at_current_file(int target):
	if (at_in_code(target) == 0):
		return -1
	int entry = dbg_find_line(at_to_v(target) - code_offset)
	if (entry < 0):
		return -1
	return dbg_line_file(entry)


# --- symbolization calibration ---
# The source was recompiled through the same ELF backend that built the
# on-disk binary (wdbg_attach_compile), so code_offset is the load base
# (0x08048000) and the symbol/line tables already hold absolute target
# addresses: the mapping delta is zero. Confirm by comparing the first
# bytes of the compiled image (ELF header + entry stubs) against the running
# process; a mismatch means a stale source or a differently built binary, so
# symbols stay off and attach runs in raw mode.
void at_calibrate():
	if (word_size != 4):
		return; /* symbolization is x86 (32-bit ELF) only for now */
	attach_delta = 0
	char* cp = code
	int i = 0
	while (i < 32):
		int tb = at_read_byte(code_offset + i)
		if (attach_read_ok == 0):
			return;
		if (tb != (cp[i] & 255)):
			println2(c"wdbg: the running binary does not match this source; symbol names are disabled (raw addresses only)")
			return;
		i = i + 1
	attach_symbolized = 1


# --- inspection commands ---
void at_pr(char* name, int offset):
	print(name)
	print(c": ")
	char* h = hex_word(at_reg(offset))
	println(h)
	free(h)


void at_print_registers():
	at_getregs()
	if (__word_size__ == 8):
		at_pr(c"rax", 80)
		at_pr(c"rbx", 40)
		at_pr(c"rcx", 88)
		at_pr(c"rdx", 96)
		at_pr(c"rsi", 104)
		at_pr(c"rdi", 112)
		at_pr(c"rbp", 32)
		at_pr(c"rsp", 152)
		at_pr(c"r8", 72)
		at_pr(c"r9", 64)
		at_pr(c"r10", 56)
		at_pr(c"r11", 48)
		at_pr(c"r12", 24)
		at_pr(c"r13", 16)
		at_pr(c"r14", 8)
		at_pr(c"r15", 0)
		at_pr(c"rip", 128)
		at_pr(c"eflags", 144)
		return;
	at_pr(c"eax", 24)
	at_pr(c"ebx", 0)
	at_pr(c"ecx", 4)
	at_pr(c"edx", 8)
	at_pr(c"esi", 12)
	at_pr(c"edi", 16)
	at_pr(c"ebp", 20)
	at_pr(c"esp", 60)
	at_pr(c"eip", 48)
	at_pr(c"eflags", 56)


# Dump n words at a target address; stops early on an unreadable page.
# Reads through the target-access seam (dbg_mem_readable/dbg_mem_read_word,
# installed to at_mem_readable/at_mem_read below), so this is the same
# call sequence the in-process debugger uses for 'x'/'st'.
void at_examine(int addr, int count):
	int i = 0
	while (i < count):
		int slot = addr + i * __word_size__
		char* ha = hex_word(slot)
		print(ha)
		free(ha)
		print(c": ")
		if (dbg_mem_readable(slot, __word_size__) == 0):
			println(c"<unreadable>")
			return;
		int v = dbg_mem_read_word(slot)
		char* hv = hex_word(v)
		print(hv)
		free(hv)
		if (at_in_code(v)):
			print(c"  ")
			print(dbg_function_name(at_to_v(v)))
		put_char(10)
		i = i + 1


void at_print_stack():
	at_getregs()
	at_examine(at_reg(at_off_sp()), 16)


# Heuristic backtrace: frame 0 is the current ip, then every stack word that
# maps to a real statement boundary in the debuggee's code is reported as a
# return address. Only meaningful when symbolized.
void at_backtrace():
	at_getregs()
	int ip = at_reg(at_off_ip())
	print(c"#0  ")
	at_print_location(ip)
	if (attach_symbolized == 0):
		println(c"(no source: raw backtrace unavailable; use st for a raw stack dump)")
		return;
	int sp = at_reg(at_off_sp())
	int shown = 1
	int i = 0
	while ((i < 4096) && (shown < 32)):
		int w = at_read_word(sp + i * __word_size__)
		if (attach_read_ok == 0):
			return;
		if (at_in_code(w)):
			int entry = dbg_find_line(at_to_v(w) - code_offset)
			if (entry >= 0):
				print(c"#")
				char* d = itoa(shown)
				print(d)
				free(d)
				print(c"  ")
				at_print_location(w)
				shown = shown + 1
		i = i + 1


void at_where():
	at_getregs()
	at_print_location(at_reg(at_off_ip()))


void at_info(char* arg):
	if ((strcmp(arg, c"f") == 0) | (strcmp(arg, c"functions") == 0)):
		if (attach_symbolized):
			dbg_print_functions()
		else:
			println(c"no source: function list unavailable")
	else if ((strcmp(arg, c"r") == 0) | (strcmp(arg, c"registers") == 0)):
		at_print_registers()
	else if ((strcmp(arg, c"b") == 0) | (strcmp(arg, c"breakpoints") == 0)):
		int shown = 0
		int i = 0
		while (i < attach_bp_count):
			if (at_bp_addr(i) != 0):
				print(c"breakpoint ")
				char* d = itoa(i + 1)
				print(d)
				free(d)
				print(c" ")
				at_print_location(at_bp_addr(i))
				shown = shown + 1
			i = i + 1
		if (shown == 0):
			println(c"no breakpoints set")
	else:
		println(c"info topics: registers breakpoints functions")


void at_help():
	println(c"attach-mode commands:")
	println(c"  c/continue  si/step  detach  q/quit  kill")
	println(c"  b/break <function | line | file:line | 0xADDR>   d/delete <n>")
	println(c"  r/registers  x <0xADDR> [count]  st/stack  bt/backtrace")
	println(c"  disas [addr | function] [count]   disas on|off (context at stops)")
	println(c"  l/line (where)  i registers | breakpoints | functions")


# --- argument helpers (local: attach.w cannot import wdbg.w) ---
char* at_split_word(char* s):
	int i = 0
	while ((s[i] != 0) && (s[i] != ' ')):
		i = i + 1
	if (s[i] == 0):
		return s + i
	s[i] = 0
	i = i + 1
	while (s[i] == ' '):
		i = i + 1
	return s + i


int at_number(char* s):
	if (starts_with(s, c"0x")):
		return from_hex(s)
	return atoi(s)


# --- breakpoint / delete commands ---
void at_break_command(char* arg):
	if (arg[0] == 0):
		println(c"usage: break <function | line | file:line | 0xADDR>")
		return;
	int target = 0
	if (arg[0] == '*'):
		target = at_number(arg + 1)
	else if (((arg[0] >= '0') && (arg[0] <= '9')) && (attach_symbolized == 0)):
		target = at_number(arg)
	else:
		if (attach_symbolized == 0):
			println(c"no source: set breakpoints by address (0xADDR or *ADDR)")
			return;
		at_getregs()
		int v = bp_resolve_target(arg, at_current_file(at_reg(at_off_ip())))
		if (v == 0):
			return;
		target = v + attach_delta
	int slot = at_bp_add(target)
	if (slot >= 0):
		print(c"breakpoint ")
		char* d = itoa(slot + 1)
		print(d)
		free(d)
		print(c" ")
		at_print_location(target)


void at_delete_command(char* arg):
	if (arg[0] == 0):
		int i = 0
		while (i < attach_bp_count):
			if (at_bp_addr(i) != 0):
				at_bp_disarm(i)
				save_word(cast(char*, attach_bp_addrs + i * __word_size__), 0)
			i = i + 1
		println(c"all breakpoints deleted")
		return;
	int n = atoi(arg) - 1
	if (((n < 0) || (n >= attach_bp_count)) | (at_bp_addr(n) == 0)):
		println(c"no such breakpoint")
		return;
	at_bp_disarm(n)
	save_word(cast(char*, attach_bp_addrs + n * __word_size__), 0)
	println(c"breakpoint deleted")


# --- execution control ---
# Resume the tracee with `request`, delivering any pending signal once.
void at_resume(int request):
	sys_ptrace(request, attach_pid, 0, attach_pending_sig)
	attach_pending_sig = 0


# Decode and announce the stop the tracee just took; update attach_alive.
void at_report_stop(int status):
	if (at_status_exited(status)):
		print(c"process exited with code ")
		char* d = itoa(at_status_exitcode(status))
		println(d)
		free(d)
		attach_alive = 0
		return;
	if (at_status_signalled(status)):
		print(c"process killed by signal ")
		char* d = itoa(at_status_termsig(status))
		println(d)
		free(d)
		attach_alive = 0
		return;
	int sig = at_status_stopsig(status)
	at_getregs()
	int ip = at_reg(at_off_ip())
	if (sig == 5): /* SIGTRAP: breakpoint or single-step */
		int bp = at_bp_find(ip - 1)
		if (bp >= 0):
			at_set_ip(ip - 1) /* rewind over the executed int3 */
			print(c"hit breakpoint ")
			char* d = itoa(bp + 1)
			print(d)
			free(d)
			print(c" ")
			at_print_location(ip - 1)
			if (dbg_disas_auto):
				dbg_disas_show_context(ip - 1)
			return;
		at_print_location(ip)
		return;
	# Any other signal is held pending and redelivered on the next resume.
	if (sig != 19): /* not the initial/ordinary SIGSTOP */
		attach_pending_sig = sig
	print(c"stopped by signal ")
	char* d = itoa(sig)
	println(d)
	free(d)
	at_print_location(ip)


void at_continue():
	if (attach_alive == 0):
		println(c"process is not running")
		return;
	# If stopped on a breakpoint, single-step over the real instruction with
	# the int3 removed, then re-arm before running at full speed.
	at_getregs()
	int bp = at_bp_find(at_reg(at_off_ip()))
	if (bp >= 0):
		at_bp_disarm(bp)
		at_resume(at_SINGLESTEP())
		int st = at_wait()
		if (at_status_exited(st) | at_status_signalled(st)):
			at_report_stop(st)
			return;
		at_bp_arm(bp)
	at_resume(at_CONT())
	at_report_stop(at_wait())


void at_step():
	if (attach_alive == 0):
		println(c"process is not running")
		return;
	at_getregs()
	int bp = at_bp_find(at_reg(at_off_ip()))
	if (bp >= 0):
		at_bp_disarm(bp)
	at_resume(at_SINGLESTEP())
	int st = at_wait()
	if (at_status_exited(st) | at_status_signalled(st)):
		at_report_stop(st)
		return;
	if (bp >= 0):
		at_bp_arm(bp)
	at_report_stop(st)
	# Single-stepping is instruction-level work: always show the
	# surrounding instructions, like the in-process debugger's 'si'.
	if (attach_alive):
		dbg_disas_show_context(at_reg(at_off_ip()))


void at_detach():
	if (attach_alive == 0):
		return;
	int i = 0
	while (i < attach_bp_count):
		if (at_bp_addr(i) != 0):
			at_bp_disarm(i)
		i = i + 1
	sys_ptrace(at_DETACH(), attach_pid, 0, 0)
	attach_alive = 0
	println(c"detached; process continues")


# --- command loop ---
void at_command_loop():
	char* command = malloc(256)
	while (1):
		int n = line_edit_read(c"wdbg(attach)> ", command, 256, 0)
		if (n == -2):
			continue
		if (n < 0):
			println(c"(end of input)")
			at_detach()
			free(command)
			return;
		if (n == 0):
			continue
		char* arg = at_split_word(command)
		if ((strcmp(command, c"c") == 0) | (strcmp(command, c"continue") == 0)):
			at_continue()
		else if ((strcmp(command, c"si") == 0) | (strcmp(command, c"step") == 0) | (strcmp(command, c"stepi") == 0)):
			at_step()
		else if ((strcmp(command, c"r") == 0) | (strcmp(command, c"registers") == 0)):
			at_print_registers()
		else if ((strcmp(command, c"st") == 0) | (strcmp(command, c"stack") == 0)):
			at_print_stack()
		else if (strcmp(command, c"x") == 0):
			if (arg[0] == 0):
				println(c"usage: x <0xADDR> [count]")
			else:
				char* count_text = at_split_word(arg)
				int addr = at_number(arg)
				int count = 8
				if (count_text[0] != 0):
					count = at_number(count_text)
				if (count < 1):
					count = 1
				if (count > 1024):
					count = 1024
				at_examine(addr, count)
		else if ((strcmp(command, c"b") == 0) | (strcmp(command, c"break") == 0)):
			at_break_command(arg)
		else if ((strcmp(command, c"d") == 0) | (strcmp(command, c"delete") == 0)):
			at_delete_command(arg)
		else if ((strcmp(command, c"bt") == 0) | (strcmp(command, c"backtrace") == 0)):
			at_backtrace()
		else if ((strcmp(command, c"disas") == 0) | (strcmp(command, c"disassemble") == 0)):
			at_getregs()
			dbg_disas_command(at_reg(at_off_ip()), arg)
		else if ((strcmp(command, c"l") == 0) | (strcmp(command, c"line") == 0) | (strcmp(command, c"where") == 0)):
			at_where()
		else if ((strcmp(command, c"i") == 0) | (strcmp(command, c"info") == 0)):
			at_info(arg)
		else if (strcmp(command, c"detach") == 0):
			at_detach()
			free(command)
			return;
		else if ((strcmp(command, c"q") == 0) | (strcmp(command, c"quit") == 0)):
			at_detach()
			free(command)
			return;
		else if (strcmp(command, c"kill") == 0):
			kill(attach_pid, 9)
			attach_alive = 0
			println(c"process killed")
			free(command)
			return;
		else if ((strcmp(command, c"h") == 0) | (strcmp(command, c"help") == 0) | (strcmp(command, c"?") == 0)):
			at_help()
		else:
			println(c"unknown command; type 'help' for the command list")


# Entry point: attach to pid, optionally symbolizing against the source that
# wdbg_main has already compiled into the code buffer (have_symbols).
int wdbg_attach_run(int pid, int have_symbols):
	attach_pid = pid
	attach_wordbuf = cast(int, malloc(16))
	attach_statusbuf = cast(int, malloc(16))
	attach_regs = cast(int, malloc(512))
	attach_bp_addrs = cast(int, malloc(at_bp_max() * __word_size__))
	attach_bp_orig = cast(int, malloc(at_bp_max() * 4))
	attach_bp_armed = cast(int, malloc(at_bp_max() * 4))
	attach_bp_count = 0
	attach_pending_sig = 0
	attach_symbolized = 0

	# Install this module's ptrace reads as the target-access seam's
	# backend (debugger/memory.w), so at_examine and any future attach-mode
	# consumer of the shared dbg_mem_* entry points read through ptrace.
	dbg_mem_readable_fn = cast(int, at_mem_readable)
	dbg_mem_read_fn = cast(int, at_mem_read)

	int r = sys_ptrace(at_ATTACH(), pid, 0, 0)
	if ((r < 0) && (r >= -4095)):
		print2(c"wdbg: cannot attach to pid ")
		char* d = itoa(pid)
		print2(d)
		free(d)
		if (r == -1):
			println2(c" (operation not permitted: check ptrace_scope or run as the process owner)")
		else if (r == -3):
			println2(c" (no such process)")
		else:
			println2(c"")
		return 1

	int st = at_wait()
	if (at_status_exited(st) | at_status_signalled(st)):
		println2(c"wdbg: the process exited before it could be stopped")
		return 1
	attach_alive = 1

	if (have_symbols):
		at_calibrate()

	# Disassembly reads the target through ptrace; symbol annotation is
	# available exactly when the source validated against the process.
	dbg_disas_read_fn = cast(int, at_disas_read)
	dbg_disas_symbols = attach_symbolized
	dbg_disas_delta = attach_delta

	print(c"attached to pid ")
	char* pd = itoa(pid)
	print(pd)
	free(pd)
	if (attach_symbolized):
		println(c" (symbols loaded)")
	else:
		println(c" (raw mode: no symbols)")
	at_getregs()
	at_print_location(at_reg(at_off_ip()))

	at_command_loop()
	return 0
