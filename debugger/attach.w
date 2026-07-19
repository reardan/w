/*
Attach to a running process (wdbg --attach <pid> [file.w]).

Unlike the rest of wdbg, which runs the debuggee inside its own address
space and drives it from signal handlers, attach mode controls a separate,
already-running process through ptrace(2). It is a self-contained command
loop: wdbg.w's signal handlers and execution-control state are never
entered, so attaching cannot perturb the self-hosting model and needs
none of that machinery. Memory and register inspection are where attach
mode plugs into shared code: debugger/memory.w's target-access seam (#123
phase 2) dispatches dbg_mem_readable/dbg_mem_read/dbg_mem_write_word
through a registered reader/writer, and debugger/registers.w's
dbg_reg_pc/dbg_reg_sp dispatch the same way for the trapped pc/sp. This
file installs at_mem_readable/at_mem_read/at_mem_write (thin wrappers
around the existing PTRACE_PEEKDATA/POKEDATA calls below) and
dbg_reg_pc_attach/dbg_reg_sp_attach (PTRACE_GETREGS) as those seams'
backends (wdbg_attach_run), so at_examine (x/st), frame walking and locals
all go through the same entry points the in-process debugger uses.

Two levels of capability:

  * Raw mode (always): registers, memory (x), stack (st), breakpoints,
    single-step and continue, and disassembly (disas, by absolute
    address or from the stopped ip; bytes read via PTRACE_PEEKDATA),
    all in absolute target addresses. Needs no source and works
    whenever ptrace attach succeeds.

  * Symbolized mode (when a source file is given and validates): function
    names, file:line and source listing for addresses inside the
    debuggee's code, plus locals/args inspection and frame selection
    (#123 phase 5). wdbg recompiles the source in-process to regenerate
    the symbol and line tables (which are never emitted into the ELF), then
    maps target addresses to those tables through a constant delta.

    The delta is derived from the target's ELF entry point and the compiler's
    fixed header/entry-stub prologue, then VALIDATED by comparing the first
    bytes of the runtime-stub region in the process against the freshly
    compiled bytes. A mismatch (stale source, different compiler, or a PIE
    binary) disables symbols and falls back to raw mode rather than printing
    wrong names. Symbolization works for both x86 and x86-64 targets:
    wdbg_attach_compile (debugger/wdbg.w) recompiles for whichever word size
    the running debugger binary itself was built for, so bin/wdbg64
    symbolizes 64-bit attach targets and bin/wdbg symbolizes 32-bit ones.

Registers: attach mode's own model (user_regs_struct via PTRACE_GETREGS)
is installed as debugger/registers.w's dbg_reg_pc/dbg_reg_sp seam backend
(dbg_reg_pc_attach/dbg_reg_sp_attach below), the same seam the in-process
debugger's sigcontext reads are installed behind (#123 phase 2 remainder).
Frame walking (at_frames_compute) and locals/args (reusing
debugger/locals.w directly) are built on that register seam plus the
memory seam above, so they work the same way against a ptrace-attached
process that debugger/wdbg.w's equivalents do in-process.

Scope: Linux, statically linked non-PIE x86/x86-64 ELF debuggees, attached
locally. Expression evaluation (print/set are name lookups only, not a
general evaluator) is not yet wired into attach mode; see
docs/projects/debugger_attach.md.
*/
import lib.lib
import lib.line_edit
import debugger.lines
import debugger.symbols
import debugger.breakpoints
import debugger.disas
import debugger.memory
import debugger.registers
import debugger.locals


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


# Word-sized write through the seam (debugger/memory.w's dbg_mem_write_fn),
# a thin wrapper around the existing PTRACE_POKEDATA write below -- no new
# ptrace semantics, mirroring at_mem_read/at_mem_readable above. Installed
# so 'set' can write a local, argument or global in attach mode the same
# way dbg_set_command does in-process.
int at_mem_write(int addr, int value):
	int r = at_write_word(addr, value)
	if ((r < 0) && (r >= -4095)):
		return 0
	return 1


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


# --- register seam (#123 phase 2 remainder, docs/projects/debugger_attach.md) ---
# Installed as debugger/registers.w's dbg_reg_pc_fn/dbg_reg_sp_fn by
# wdbg_attach_run, mirroring the memory seam install just above: frame
# walking (at_frames_compute below) and anything else that only needs "the
# current pc" / "the current sp" goes through dbg_reg_pc()/dbg_reg_sp()
# instead of calling at_getregs()+at_reg() directly, so the same call sites
# work whether the register file came from a sigcontext (in-process) or a
# ptrace user_regs_struct (here). Nothing about the byte layout (attach_regs
# vs. a sigcontext buffer) crosses the seam -- only the two logical values.
int dbg_reg_pc_attach():
	at_getregs()
	return at_reg(at_off_ip())


int dbg_reg_sp_attach():
	at_getregs()
	return at_reg(at_off_sp())


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


# --- frame list, selection and locals (#123 phase 5: docs/projects/debugger_attach.md) ---
# A frame list of (pc, base) pairs, walked from the current stop through
# the target's stack -- the same shape debugger/wdbg.w keeps in-process
# (dbg_fr_pc/dbg_fr_base there), rebuilt here on top of the two seams: the
# memory seam above (dbg_mem_readable/dbg_mem_read_word, already shared
# with the in-process debugger) and the register seam
# (dbg_reg_pc/dbg_reg_sp, debugger/registers.w) for the trapped pc/sp this
# task adds. debugger/locals.w's stack-slot arithmetic
# (dbg_frame_compute/dbg_local_runtime_addr) needs nothing else: it already
# takes a plain pc/esp pair and reads through dbg_mem_*, so it works
# unmodified once attach mode can supply those two values for any selected
# frame, not just frame 0.
#
# wdbg.w's in-process frame walker also recognizes one case that has no
# attach-mode equivalent: main()'s own return address there points outside
# the debuggee entirely, into wdbg's own directly-addressable image (wdbg
# calls the debuggee's main() itself). In attach mode main is called by the
# debuggee's own entry stub, which is part of the same recompiled code
# range, so the walk below just stops once it reaches main -- there is no
# separate process boundary to cross.
int at_fr_max():
	return 16

int attach_fr_pc   /* absolute pc per frame (word slots) */
int attach_fr_base /* frame base per frame, 0 = unknown (word slots) */
int attach_fr_count
int attach_fr_sel


void at_fr_store(int pc, int base):
	if (attach_fr_count >= at_fr_max()):
		return;
	save_word(cast(char*, attach_fr_pc + attach_fr_count * __word_size__), pc)
	save_word(cast(char*, attach_fr_base + attach_fr_count * __word_size__), base)
	attach_fr_count = attach_fr_count + 1


int at_fr_pc_at(int n):
	return load_word(cast(char*, attach_fr_pc + n * __word_size__))


int at_fr_base_at(int n):
	return load_word(cast(char*, attach_fr_base + n * __word_size__))


# 1 when the bytes just before a target address decode as one of the
# compiler's call forms (call *eax/*rax, or call rel32 in asm stubs) --
# mirrors wdbg.w's dbg_looks_like_return, reading through the disassembly
# byte-seam (debugger/disas.w's dbg_disas_read_byte) instead of a direct
# pointer deref, so it works against ptrace-attached memory.
int at_looks_like_return(int v):
	if (at_in_code(v - 2)):
		if ((dbg_disas_read_byte(v - 2) == 255) && (dbg_disas_read_byte(v - 1) == 208)):
			return 1
	if (at_in_code(v - 5)):
		if (dbg_disas_read_byte(v - 5) == 232):
			return 1
	return 0


# Recompute the frame list for a stop at (target) stop_addr, using the
# register seam for the current sp and the memory seam to walk the stack.
# Only meaningful once symbolized -- raw mode has no line/stack_pos tables
# to interpret stack words with.
void at_frames_compute(int stop_addr):
	if (attach_fr_pc == 0):
		attach_fr_pc = cast(int, malloc(at_fr_max() * __word_size__))
		attach_fr_base = cast(int, malloc(at_fr_max() * __word_size__))
	attach_fr_count = 0
	attach_fr_sel = 0
	int esp = dbg_reg_sp()
	int base0 = 0
	if (at_in_code(stop_addr)):
		int entry = dbg_find_line(at_to_v(stop_addr) - code_offset)
		if (entry >= 0):
			if (dbg_line_stack(entry) >= 0):
				base0 = esp + dbg_line_stack(entry) * __word_size__
	at_fr_store(stop_addr, base0)
	int main_at = dbg_function_at(sym_address(c"main"))
	int done = (dbg_function_at(at_to_v(stop_addr)) == main_at)
	int i = 0
	while ((i < 2048) && (attach_fr_count < at_fr_max()) && (done == 0)):
		int slot = esp + i * __word_size__
		if (dbg_mem_readable(slot, __word_size__) == 0):
			return;
		int v = dbg_mem_read_word(slot)
		if (at_in_code(v)):
			if (at_looks_like_return(v)):
				save_word(cast(char*, attach_fr_base + (attach_fr_count - 1) * __word_size__), slot)
				if (dbg_function_at(at_to_v(v) - 1) == main_at):
					done = 1
				else:
					at_fr_store(v - 1, 0)
		i = i + 1


# The selected frame's pc: the current stop for frame 0 (via the register
# seam), the return-site address for an older frame.
int at_sel_pc():
	if ((attach_fr_sel <= 0) || (attach_fr_sel >= attach_fr_count)):
		return dbg_reg_pc()
	return at_fr_pc_at(attach_fr_sel)


# sp at the selected frame's statement boundary, or 0 when the frame's base
# or line info is unknown (locals cannot be addressed then).
int at_sel_esp():
	if ((attach_fr_sel <= 0) || (attach_fr_sel >= attach_fr_count)):
		return dbg_reg_sp()
	int base = at_fr_base_at(attach_fr_sel)
	if (base == 0):
		return 0
	int pc = at_fr_pc_at(attach_fr_sel)
	if (at_in_code(pc) == 0):
		return 0
	int entry = dbg_find_line(at_to_v(pc) - code_offset)
	if (entry < 0):
		return 0
	int depth = dbg_line_stack(entry)
	if (depth < 0):
		return 0
	return base - depth * __word_size__


void at_frame_announce(int n):
	print(c"#")
	char* digits = itoa(n)
	print(digits)
	free(digits)
	print(c"  ")
	at_print_location(at_fr_pc_at(n))


void at_frame_select(int n):
	attach_fr_sel = n
	at_frame_announce(n)
	if (n > 0):
		if (at_sel_esp() == 0):
			println(c"(frame base unknown: locals are not addressable here)")


# frame [n]: select a frame (no argument: show the selected frame).
void at_frame_command(char* arg):
	if (attach_symbolized == 0):
		println(c"no source: frame selection unavailable")
		return;
	int n = attach_fr_sel
	if (arg[0] != 0):
		n = atoi(arg)
		if ((n < 0) || (n >= attach_fr_count)):
			print(c"no frame ")
			println(arg)
			return;
	at_frame_select(n)


# --- symbolization calibration ---
# The source was recompiled through the same ELF backend that built the
# on-disk binary (wdbg_attach_compile), so code_offset is the load base
# (0x08048000) and the symbol/line tables already hold absolute target
# addresses: the mapping delta is zero. Confirm by reading /proc/<pid>/exe
# and comparing it byte-for-byte against the freshly compiled image
# (code[0..codepos), the exact bytes elf_32.w/elf_64.w write(output_fd, ...)
# would put on disk): W's static ET_EXEC ELFs load at a fixed address with
# no ASLR and a single PT_LOAD segment mapping file offset 0 to code_offset,
# so file byte i is process byte code_offset+i, and the self-host fixpoint
# means a matching source recompiles to identical bytes. A mismatch (stale
# source, a different compiler, or /proc/<pid>/exe being unreadable) means
# the tables cannot be trusted, so symbols stay off and attach runs in raw
# mode rather than risk printing wrong names.
int at_read_exe_image(int pid, char* buf, int n):
	char* pid_str = itoa(pid)
	char* p1 = strjoin(c"/proc/", pid_str)
	char* path = strjoin(p1, c"/exe")
	free(pid_str)
	free(p1)
	int f = open(path, 0, 0)
	free(path)
	if (f < 0):
		return 0
	int got = 0
	while (got < n):
		int r = read(f, buf + got, n - got)
		if (r <= 0):
			close(f)
			return 0
		got = got + r
	close(f)
	return 1


void at_calibrate():
	# word_size always matches __word_size__ here: wdbg_attach_compile
	# (debugger/wdbg.w) recompiles for whichever word size the running
	# debugger binary itself was built for (passing the "x64" selector
	# when __word_size__ == 8), so a 32-bit attach (bin/wdbg) always
	# validates a 32-bit image and a 64-bit attach (bin/wdbg64) always
	# validates a 64-bit one -- this needs no word-size branch itself.
	attach_delta = 0
	char* buf = malloc(codepos)
	if (at_read_exe_image(attach_pid, buf, codepos) == 0):
		println2(c"wdbg: cannot read /proc/<pid>/exe to validate the recompile; symbol names are disabled (raw addresses only)")
		free(buf)
		return;
	int i = 0
	while (i < codepos):
		if ((buf[i] & 255) != (code[i] & 255)):
			println2(c"wdbg: the running binary does not match this source; symbol names are disabled (raw addresses only)")
			free(buf)
			return;
		i = i + 1
	free(buf)
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
	at_examine(dbg_reg_sp(), 16)


# Backtrace over the precomputed frame list (at_frames_compute, kept fresh
# at every stop by wdbg_attach_run/at_report_stop below), the same
# call-site-decode heuristic wdbg.w's in-process dbg_backtrace uses,
# generalized behind the register and memory seams. Only meaningful when
# symbolized: raw mode has no line/stack_pos tables to walk with.
void at_backtrace():
	if (attach_symbolized == 0):
		print(c"#0  ")
		at_print_location(dbg_reg_pc())
		println(c"(no source: raw backtrace unavailable; use st for a raw stack dump)")
		return;
	int k = 0
	while (k < attach_fr_count):
		at_frame_announce(k)
		k = k + 1


void at_where():
	at_print_location(at_sel_pc())


void at_info(char* arg):
	if ((strcmp(arg, c"f") == 0) | (strcmp(arg, c"functions") == 0)):
		if (attach_symbolized):
			dbg_print_functions()
		else:
			println(c"no source: function list unavailable")
	else if (strcmp(arg, c"files") == 0):
		if (attach_symbolized):
			int i = 0
			while (i < debug_file_count):
				println(dbg_file_name(i))
				i = i + 1
		else:
			println(c"no source: file list unavailable")
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
	else if ((strcmp(arg, c"l") == 0) | (strcmp(arg, c"locals") == 0)):
		if (attach_symbolized):
			dbg_print_frame_vars(at_to_v(at_sel_pc()), at_sel_esp(), 'L')
		else:
			println(c"no source: locals unavailable")
	else if ((strcmp(arg, c"a") == 0) | (strcmp(arg, c"args") == 0)):
		if (attach_symbolized):
			dbg_print_frame_vars(at_to_v(at_sel_pc()), at_sel_esp(), 'A')
		else:
			println(c"no source: args unavailable")
	else:
		println(c"info topics: registers breakpoints functions files locals args")


void at_help():
	println(c"attach-mode commands:")
	println(c"  c/continue  s/step  n/next  si/stepi  fin/finish  detach  q/quit  kill")
	println(c"  b/break <function | line | file:line | 0xADDR>   d/delete <n>")
	println(c"  r/registers  x <0xADDR> [count]  st/stack  bt/backtrace")
	println(c"  f/frame [n]  up  down  (select a backtrace frame)")
	println(c"  p/print <name>  set <name> <value>  (locals, args or globals)")
	println(c"  disas [addr | function] [count]   disas on|off (context at stops)")
	println(c"  l/line (where)  list [line]  i registers | breakpoints | functions | files | locals | args")


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


# print <name>: a local, argument (at the selected frame) or a defined
# global, by name. Attach mode has no expression compiler yet (phase 6 is
# still open, docs/projects/debugger_attach.md) -- anything else is
# reported as unsupported rather than silently doing nothing.
void at_print_command(char* arg):
	if (attach_symbolized == 0):
		println(c"no source: print unavailable")
		return;
	if (arg[0] == 0):
		println(c"usage: print <name>")
		return;
	int pc = at_to_v(at_sel_pc())
	int esp = at_sel_esp()
	int note = dbg_local_find(arg, pc)
	if (note >= 0):
		dbg_print_local(note, esp)
		return;
	int g = dbg_global_find(arg)
	if (g >= 0):
		if (dbg_sym_symtype(g) != 2):
			print(arg)
			print(c" = ")
			dbg_print_typed_value(dbg_sym_address(g), dbg_sym_type(g))
			put_char(10)
			return;
	println(c"unknown variable (attach mode cannot evaluate general expressions yet)")


# set <name> <value>: writes a local, argument (at the selected frame) or
# global word.
void at_set_command(char* arg):
	if (attach_symbolized == 0):
		println(c"no source: set unavailable")
		return;
	char* value_text = at_split_word(arg)
	if ((arg[0] == 0) || (value_text[0] == 0)):
		println(c"usage: set <name> <value>")
		return;
	int v = at_number(value_text)
	int pc = at_to_v(at_sel_pc())
	int esp = at_sel_esp()
	int note = dbg_local_find(arg, pc)
	if (note >= 0):
		int addr = dbg_local_runtime_addr(note, esp)
		if (dbg_mem_readable(addr, __word_size__) == 0):
			println(c"variable is not addressable here")
			return;
		dbg_mem_write_word(addr, v)
		dbg_print_local(note, esp)
		return;
	int g = dbg_global_find(arg)
	if (g >= 0):
		if (dbg_sym_symtype(g) != 2):
			dbg_mem_write_word(dbg_sym_address(g), v)
			print(arg)
			print(c" = ")
			dbg_print_typed_value(dbg_sym_address(g), dbg_sym_type(g))
			put_char(10)
			return;
	print(c"unknown variable: ")
	println(arg)


# Multi-line source listing centered on the stopped ip (or an explicit line
# number), like wdbg.w's in-process 'list'. Only meaningful once symbolized:
# a mismatched recompile's tables cannot be trusted for anything beyond raw
# addresses, so this stays off in raw mode like 'i functions' above.
void at_list_command(char* arg):
	if (attach_symbolized == 0):
		println(c"no source: listing unavailable")
		return;
	int target = at_sel_pc()
	if (at_in_code(target) == 0):
		println(c"no line info (address is outside the debuggee)")
		return;
	int entry = dbg_find_line(at_to_v(target) - code_offset)
	if (entry < 0):
		println(c"no line info recorded")
		return;
	int current = dbg_line_line(entry)
	int center = current
	if (arg[0] != 0):
		center = at_number(arg)
	dbg_print_source_range(dbg_file_name(dbg_line_file(entry)), center - 5, center + 5, current)


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
		# A bare line number resolves against the actual stop, not the
		# selected frame -- matches wdbg.w's dbg_current_file(stop_addr).
		int v = bp_resolve_target(arg, at_current_file(dbg_reg_pc()))
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
			# Keep the frame list (and so locals/frame selection) fresh at
			# every stop, like wdbg.w's wdbg_command_loop does in-process.
			if (attach_symbolized):
				at_frames_compute(ip - 1)
			print(c"hit breakpoint ")
			char* d = itoa(bp + 1)
			print(d)
			free(d)
			print(c" ")
			at_print_location(ip - 1)
			if (dbg_disas_auto):
				dbg_disas_show_context(ip - 1)
			return;
		if (attach_symbolized):
			at_frames_compute(ip)
		at_print_location(ip)
		return;
	# Any other signal is held pending and redelivered on the next resume.
	if (sig != 19): /* not the initial/ordinary SIGSTOP */
		attach_pending_sig = sig
	if (attach_symbolized):
		at_frames_compute(ip)
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
	int bp = at_bp_find(dbg_reg_pc())
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
	int bp = at_bp_find(dbg_reg_pc())
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
		dbg_disas_show_context(dbg_reg_pc())


# --- source-line stepping (#123 phase 4 remainder: s/n, run to a statement
# boundary rather than one instruction like si) ---
# Mirrors debugger/wdbg.w's dbg_step_should_stop/dbg_prepare_resume, adapted
# from "single-step via the trap flag, resume, let the signal handler
# re-check" to attach mode's own driving loop: PTRACE_SINGLESTEP + wait4,
# checked here after every instruction instead of on every re-entry to
# wdbg_trap. Same stop condition, same frame-base arithmetic (esp compared
# against the starting statement's frame_base = esp-at-start + its recorded
# stack depth), so recursion and step-out-of-frame behave identically to
# the in-process debugger; only the driving mechanism differs.
int AT_STEP_LINE():
	return 1
int AT_STEP_OVER():
	return 2

int attach_step_line   /* source line at the step's start */
int attach_step_file   /* source file index at the step's start */
int attach_step_stack  /* compile-time stack words at the start statement */
int attach_step_esp    /* esp at the step's start (frame depth) */
int attach_step_fstart /* enclosing function range at the step's start */
int attach_step_fend


void at_step_prepare():
	attach_step_esp = dbg_reg_sp()
	attach_step_line = -1
	attach_step_file = -1
	attach_step_stack = -1
	attach_step_fstart = 0
	attach_step_fend = 0
	if (at_in_code(dbg_reg_pc())):
		int entry = dbg_find_line(at_to_v(dbg_reg_pc()) - code_offset)
		if (entry >= 0):
			attach_step_line = dbg_line_line(entry)
			attach_step_file = dbg_line_file(entry)
			attach_step_stack = dbg_line_stack(entry)
		int f = dbg_function_at(at_to_v(dbg_reg_pc()))
		if (f >= 0):
			attach_step_fstart = dbg_sym_address(f)
			attach_step_fend = attach_step_fstart + dbg_sym_size(f)


int at_step_should_stop(int mode, int ip):
	if (at_in_code(ip) == 0):
		return 0
	int entry = dbg_find_line(at_to_v(ip) - code_offset)
	if (entry < 0):
		return 0
	int esp = dbg_reg_sp()
	int frame_base = attach_step_esp
	if (attach_step_stack >= 0):
		frame_base = attach_step_esp + attach_step_stack * __word_size__
	# step/next only stop at exact statement starts (local addressing is
	# only accurate there); a jump target or a call's continuation is
	# always one.
	if (ip != code_offset + dbg_line_addr(entry)):
		return 0
	if ((dbg_line_line(entry) == attach_step_line) && (dbg_line_file(entry) == attach_step_file)):
		return 0
	if (mode == AT_STEP_OVER()):
		if (attach_step_fstart == 0):
			return 1 /* unknown starting frame: behave like step */
		if (esp > frame_base):
			return 1 /* returned past the starting frame */
		if ((ip >= attach_step_fstart) && (ip < attach_step_fend)):
			if (esp == frame_base - dbg_line_stack(entry) * __word_size__):
				return 1 /* a statement boundary of the starting frame */
		return 0
	return 1


# Drive PTRACE_SINGLESTEP/wait4 until the next statement boundary at the
# same-or-shallower frame (mode == AT_STEP_OVER()) or any boundary at all
# (mode == AT_STEP_LINE()). A breakpoint's int3 landing mid-step (armed
# inside the stepped range, e.g. 'next' stepping over a call that hits one)
# stops early and reports it like a normal continue, rather than silently
# stepping through it.
void at_step_line_mode(int mode):
	if (attach_alive == 0):
		println(c"process is not running")
		return;
	if (attach_symbolized == 0):
		println(c"no source: step unavailable (use si)")
		return;
	at_step_prepare()
	int count = 0
	while (1):
		int bp = at_bp_find(dbg_reg_pc())
		if (bp >= 0):
			at_bp_disarm(bp)
		at_resume(at_SINGLESTEP())
		int st = at_wait()
		if ((at_status_exited(st) == 0) && (at_status_signalled(st) == 0)):
			if (bp >= 0):
				at_bp_arm(bp)
		if (at_status_exited(st) | at_status_signalled(st)):
			at_report_stop(st)
			return;
		int sig = at_status_stopsig(st)
		if (sig != 5):
			at_report_stop(st)
			return;
		at_getregs()
		int ip = at_reg(at_off_ip())
		int hitbp = at_bp_find(ip - 1)
		if (hitbp >= 0):
			at_set_ip(ip - 1)
			if (attach_symbolized):
				at_frames_compute(ip - 1)
			print(c"hit breakpoint ")
			char* d = itoa(hitbp + 1)
			print(d)
			free(d)
			print(c" ")
			at_print_location(ip - 1)
			if (dbg_disas_auto):
				dbg_disas_show_context(ip - 1)
			return;
		count = count + 1
		if (count > 500000):
			println(c"step: no source boundary found: continuing")
			return;
		if (at_in_code(ip) == 0):
			if (dbg_reg_sp() > attach_step_esp):
				println(c"(step left the debuggee: continuing)")
				return;
			continue
		if (at_step_should_stop(mode, ip)):
			if (attach_symbolized):
				at_frames_compute(ip)
			at_print_location(ip)
			if (dbg_disas_auto):
				dbg_disas_show_context(ip)
			return;


# The current word_size-correct return-value register (eax/rax), read from
# the register buffer at_getregs() already refreshed this stop.
int at_reg_ret():
	if (__word_size__ == 8):
		return at_reg(80)
	return at_reg(24)


# fin/finish: run to the return address of the CURRENT (innermost) frame --
# not the selected one, matching wdbg.w's in-process 'fin' -- via a
# temporary breakpoint at that address (#123 phase 4's suggested approach),
# falling back to reusing an already-set user breakpoint at the same
# address instead of duplicating it. Recursion is handled by checking sp
# against the sp recorded when 'fin' started: a hit at the same address
# from a still-deeper (recursive) call is silently resumed rather than
# reported as the finish.
void at_finish():
	if (attach_alive == 0):
		println(c"process is not running")
		return;
	if (attach_symbolized == 0):
		println(c"no source: finish unavailable")
		return;
	if (attach_fr_count < 2):
		println(c"no caller frame")
		return;
	int target = at_fr_pc_at(1) + 1
	int start_esp = dbg_reg_sp()
	int temp_slot = -1
	if (at_bp_find(target) < 0):
		temp_slot = at_bp_add(target)
		if (temp_slot < 0):
			return;
	while (1):
		int bp = at_bp_find(dbg_reg_pc())
		if (bp >= 0):
			at_bp_disarm(bp)
			at_resume(at_SINGLESTEP())
			int st1 = at_wait()
			if ((at_status_exited(st1) == 0) && (at_status_signalled(st1) == 0)):
				at_bp_arm(bp)
			if (at_status_exited(st1) | at_status_signalled(st1)):
				at_report_stop(st1)
				return;
		at_resume(at_CONT())
		int st = at_wait()
		if (at_status_exited(st) | at_status_signalled(st)):
			at_report_stop(st)
			return;
		if (at_status_stopsig(st) != 5):
			if (temp_slot >= 0):
				at_bp_disarm(temp_slot)
				save_word(cast(char*, attach_bp_addrs + temp_slot * __word_size__), 0)
			at_report_stop(st)
			return;
		at_getregs()
		int ip = at_reg(at_off_ip())
		int hitbp = at_bp_find(ip - 1)
		if (hitbp < 0):
			if (temp_slot >= 0):
				at_bp_disarm(temp_slot)
				save_word(cast(char*, attach_bp_addrs + temp_slot * __word_size__), 0)
			at_report_stop(st)
			return;
		if (at_bp_addr(hitbp) == target):
			at_set_ip(ip - 1)
			if (dbg_reg_sp() > start_esp):
				if (temp_slot >= 0):
					at_bp_disarm(temp_slot)
					save_word(cast(char*, attach_bp_addrs + temp_slot * __word_size__), 0)
				print(c"value returned = ")
				dbg_print_int_value(at_reg_ret())
				put_char(10)
				# Returning from the call lands mid-statement (the caller
				# may still store the result, clean up args, etc); glide
				# forward to the next real statement boundary like
				# wdbg.w's in-process 'fin' does, rather than reporting a
				# stop where local addressing may not be accurate yet.
				at_step_line_mode(AT_STEP_LINE())
				return;
			# A recursive call returned to the same call site but has not
			# yet unwound past the frame 'fin' started in: keep going.
		else:
			at_set_ip(ip - 1)
			if (temp_slot >= 0):
				at_bp_disarm(temp_slot)
				save_word(cast(char*, attach_bp_addrs + temp_slot * __word_size__), 0)
			at_frames_compute(ip - 1)
			print(c"hit breakpoint ")
			char* d = itoa(hitbp + 1)
			print(d)
			free(d)
			print(c" ")
			at_print_location(ip - 1)
			return;


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
		else if ((strcmp(command, c"si") == 0) | (strcmp(command, c"stepi") == 0)):
			at_step()
		else if ((strcmp(command, c"s") == 0) | (strcmp(command, c"step") == 0)):
			at_step_line_mode(AT_STEP_LINE())
		else if ((strcmp(command, c"n") == 0) | (strcmp(command, c"next") == 0)):
			at_step_line_mode(AT_STEP_OVER())
		else if ((strcmp(command, c"fin") == 0) | (strcmp(command, c"finish") == 0)):
			at_finish()
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
		else if ((strcmp(command, c"f") == 0) | (strcmp(command, c"frame") == 0)):
			at_frame_command(arg)
		else if (strcmp(command, c"up") == 0):
			if (attach_symbolized == 0):
				println(c"no source: frame selection unavailable")
			else if (attach_fr_sel + 1 >= attach_fr_count):
				println(c"no caller frame")
			else:
				at_frame_select(attach_fr_sel + 1)
		else if (strcmp(command, c"down") == 0):
			if (attach_symbolized == 0):
				println(c"no source: frame selection unavailable")
			else if (attach_fr_sel <= 0):
				println(c"already at the innermost frame")
			else:
				at_frame_select(attach_fr_sel - 1)
		else if ((strcmp(command, c"p") == 0) | (strcmp(command, c"print") == 0)):
			at_print_command(arg)
		else if (strcmp(command, c"set") == 0):
			at_set_command(arg)
		else if ((strcmp(command, c"disas") == 0) | (strcmp(command, c"disassemble") == 0)):
			dbg_disas_command(at_sel_pc(), arg)
		else if ((strcmp(command, c"l") == 0) | (strcmp(command, c"line") == 0) | (strcmp(command, c"where") == 0)):
			at_where()
		else if (strcmp(command, c"list") == 0):
			at_list_command(arg)
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

	# Install this module's ptrace reads (and, now that locals/set need it,
	# write) as the target-access seam's backend (debugger/memory.w), so
	# at_examine, at_set_command and any future attach-mode consumer of the
	# shared dbg_mem_* entry points go through ptrace.
	dbg_mem_readable_fn = cast(int, at_mem_readable)
	dbg_mem_read_fn = cast(int, at_mem_read)
	dbg_mem_write_fn = cast(int, at_mem_write)

	# Install this module's ptrace GETREGS reads as the register seam's
	# backend (debugger/registers.w, #123 phase 2 remainder), so frame
	# walking and locals addressing (at_frames_compute, at_sel_pc/at_sel_esp)
	# read the current pc/sp the same way the in-process debugger's
	# sigcontext-backed seam does.
	dbg_reg_pc_fn = cast(int, dbg_reg_pc_attach)
	dbg_reg_sp_fn = cast(int, dbg_reg_sp_attach)

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
	int start_ip = dbg_reg_pc()
	if (attach_symbolized):
		at_frames_compute(start_ip)
	at_print_location(start_ip)

	at_command_loop()
	return 0
