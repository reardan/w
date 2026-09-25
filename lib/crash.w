/*
Symbolized crash reports for fatal signals (issue #378).

crash_handler_install() installs handlers for SIGILL, SIGBUS, SIGFPE
and SIGSEGV that write the crash metadata (signal, pc, faulting
address) and a symbolized stack trace - function names and file:line
resolved from the running binary's own .symtab and .debug_line
sections via lib/stack_trace.w - to stderr:

	fatal signal: SIGSEGV (invalid memory reference), pc=0x08048b31, faulting address 0x00000000
	registers:
	  eax=0x00000000 ebx=0x00000000 ecx=0x00000003 edx=0x00000000
	  esi=0x00000008 edi=0x00000000 ebp=0x00000000 esp=0xffc3124c
	  eip=0x08048b31 eflags=0x00010246
	build-id: 199db5dc9bd729cb179241cc99048232e56f26cb
	stack trace (most recent call first):
	  at crash_deep (tests/crash_null_deref_fixture.w:11)
	  at crash_mid (tests/crash_null_deref_fixture.w:15)
	  at main (tests/crash_null_deref_fixture.w:20)
	crash dump written to /tmp/app.1234.core (inspect with: wcore /tmp/app.1234.core)
	terminating with the default action for signal 11 (core dump per RLIMIT_CORE)

The "crash dump written" line appears only when W_CRASH_DUMP=<path> is
set ("%p" expands to the pid): the handler then also writes an ELF
ET_CORE dump of the process itself - registers, siginfo, the executable
path and every readable mapping - that gdb and tools/wcore.w read, even
when kernel cores are disabled or piped away (lib/crash_dump.w). The
build-id line is the image's NT_GNU_BUILD_ID, for matching the report
against a binary.

The handler then restores the signal's default disposition and returns;
the kernel re-executes the faulting instruction and the process dies of
the original signal. Exit status, WIFSIGNALED, core dumps (subject to
RLIMIT_CORE) and anything a test harness observes stay exactly as
without the handler - the report is purely additive on stderr.

Accuracy: the innermost frame comes from the faulting pc and is always
real. Older frames come from lib/stack_trace.w's st_unwind, which
follows the frame-pointer chain the compiler maintains on x86/x64
(push ebp ; mov ebp,esp in every function) and arm64 (stp x29,x30 onto
the W stack ; mov x29,x28): exact, every frame in
order, up to main. When the chain is broken (a corrupted stack, or an
image without frame pointers) the rest of the trace falls back to the
heuristic return-address scan, where a caller can be missing and a
stale stack slot can add a frame not on the call path; the report then
ends with

	note: part of the trace is heuristic (return-address scan): frames can be missing or stale

Traces longer than crash_frames_max() frames are cut off with a
"... trace truncated" line.

macOS (arm64_darwin): the same report, from the darwin ucontext -
x0..x28, fp, lr, sp, pc and cpsr, the faulting address from the
exception state, and the image's LC_UUID where ELF prints its build-id.
SIGTRAP (W's brk traps) and SIGBUS (10 on darwin) are covered too.
Frames carry function names and file:line (from __TEXT,__debug_line);
the trace follows the arm64 frame chain (x29 on the W stack), exact like
x86/x64. Handlers enter through the compiler's
signal_trampoline stub, found by name in the image's symbol table; an
image built by a compiler without the stub, or an arm64e (--pac=full)
image, gets no handler (see crash_install_darwin). No crash
dump is written (W_CRASH_DUMP writes ELF cores only).

Installation is opt-in - import this file and call
crash_handler_install() from main - and is a silent no-op when
W_CRASH_TRACE=0 is set in the environment, or when the running image
is neither a Linux x86/x64 ELF, a win64 PE, nor an arm64 Mach-O with
readable symbols (arm64 Linux has no sigcontext accessors here). The
compiler driver (w.w) and the test runner main (lib/testing.w) install
it, so compiler crashes and crashing tests report symbolized traces.

Windows (win64): the same report, from a vectored exception handler
(win_crash_filter_install in lib/__arch__/win64/syscalls.w) entered
through a C -> W callback thunk -- the NTSTATUS code and name
(EXCEPTION_ACCESS_VIOLATION, ...), the reading/writing address of an
access violation, the CONTEXT registers and the frame-pointer trace
symbolized from the PE's embedded symbol table. The handler returns
EXCEPTION_CONTINUE_SEARCH, so the process still dies with the original
exception code; W_CRASH_DUMP writes nothing there.

Handler safety: everything the handler path needs is preallocated by
crash_handler_install() (the frame buffer, the SIG_DFL sigaction, and
lib/stack_trace.w's scratch buffers), and every stack probe goes
through mincore(), so the handler allocates nothing and cannot fault
on a wild stack pointer even when the fault came from a corrupted
heap. A fault inside the handler itself re-raises with the default
disposition already restored, so it cannot loop. Known limitation: a
stack-overflow SIGSEGV cannot be reported (there is no sigaltstack,
so the kernel cannot push the handler frame and kills the process
directly with the unchanged default semantics).

This file is in the seed's import graph (w.w imports it): seed-era
syntax only.
*/
import lib.signal
import lib.stack_trace
import lib.crash_dump
import lib.env
import debugger.sigcontext


int crash_installed
int crash_active
char* crash_pcs    /* preallocated frame pc buffer */
int* crash_dfl_act /* zeroed struct sigaction: SIG_DFL */


int crash_frames_max():
	return 256


char* crash_signal_name(int sig):
	if (st_macho):
		if (sig == 5):
			return c"SIGTRAP (trace/breakpoint trap)"
		if (sig == 10):
			return c"SIGBUS (bus error)"
		if (sig == 7):
			return c"unknown"
	if (sig == 4):
		return c"SIGILL (illegal instruction)"
	if (sig == 7):
		return c"SIGBUS (bus error)"
	if (sig == 8):
		return c"SIGFPE (arithmetic exception)"
	if (sig == 11):
		return c"SIGSEGV (invalid memory reference)"
	return c"unknown"


# One "  at name (file:line)" trace line; mirrors print_stack_trace's
# per-frame output (lib/stack_trace.w) so both traces read the same.
void crash_write_frame(int addr):
	st_write_cstr(c"  at ")
	int e = st_func_entry(addr)
	if (e != 0):
		st_write_cstr(cast(char*, st_entry_name(e)))
	else:
		st_write_hex(addr)
	if (st_line_lookup(addr)):
		st_write_cstr(c" (")
		int fname = st_file_name(st_file_found)
		if (fname != 0):
			st_write_cstr(cast(char*, fname))
			st_write_cstr(c":")
		st_write_dec(st_line_found)
		st_write_cstr(c")")
	st_write_cstr(c"\n")


# Register display order (same as wcore and wdbg attach mode):
# eax ebx ecx edx esi edi ebp esp [r8..r15] eip eflags.
int crash_reg_count():
	if (__word_size__ == 8):
		return 18
	return 10


char* crash_reg_name(int k):
	char* names = c"eaxebxecxedxesiediebpesp"
	if (__word_size__ == 8):
		names = c"raxrbxrcxrdxrsirdirbprspr8 r9 r10r11r12r13r14r15"
	if (k == crash_reg_count() - 2):
		if (__word_size__ == 8):
			return c"rip"
		return c"eip"
	if (k == crash_reg_count() - 1):
		return c"eflags"
	return &names[k * 3]


int crash_reg_offset(int k):
	if (k == crash_reg_count() - 2):
		return sigcontext_eip()
	if (k == crash_reg_count() - 1):
		return sigcontext_eflags()
	if (k == 0):
		return sigcontext_eax()
	if (k == 1):
		return sigcontext_ebx()
	if (k == 2):
		return sigcontext_ecx()
	if (k == 3):
		return sigcontext_edx()
	if (k == 4):
		return sigcontext_esi()
	if (k == 5):
		return sigcontext_edi()
	if (k == 6):
		return sigcontext_ebp()
	if (k == 7):
		return sigcontext_esp()
	return (k - 8) * 8 /* r8..r15 at the start of the 64-bit sigcontext */


# "registers:" then four "name=value" pairs per line.
void crash_write_registers(int context):
	st_write_cstr(c"registers:")
	int k = 0
	while (k < crash_reg_count()):
		if ((k & 3) == 0):
			st_write_cstr(c"\n ")
		st_write_cstr(c" ")
		# Names are 3 letters (r8/r9 padded with a space) or "eflags".
		char* name = crash_reg_name(k)
		int n = 3
		if (name[2] == 'l'):
			n = 6
		if (name[2] == ' '):
			n = 2
		write(2, name, n)
		st_write_cstr(c"=")
		st_write_hex(ctx_reg(context, crash_reg_offset(k)))
		k = k + 1
	st_write_cstr(c"\n")


# The fatal-signal handler. On x86-64 the lib/signal.w thunk calls this
# directly with &uc_mcontext; on i386 crash_entry below converts the
# classic frame first.
void crash_report(int sig, int context):
	# Restore the default disposition FIRST: any fault inside this
	# handler (or after it returns) now takes the ordinary signal death,
	# so the report can never loop.
	rt_sigaction(sig, crash_dfl_act, 0)
	if (crash_active):
		return;
	crash_active = 1
	int pc = ctx_eip(context)
	st_write_cstr(c"fatal signal: ")
	st_write_cstr(crash_signal_name(sig))
	st_write_cstr(c", pc=")
	st_write_hex(pc)
	if ((sig == 11) || (sig == 7)):
		st_write_cstr(c", faulting address ")
		st_write_hex(ctx_reg(context, sigcontext_cr2()))
	st_write_cstr(c"\n")
	crash_write_registers(context)
	if (cd_id_size > 0):
		st_write_cstr(c"build-id: ")
		crash_write_build_id()
		st_write_cstr(c"\n")
	st_write_cstr(c"stack trace (most recent call first):\n")
	# The innermost frame is the faulting pc itself; older frames come
	# from the frame-pointer chain (heuristic scan where it breaks).
	crash_write_frame(pc)
	int n = st_unwind(pc, ctx_esp(context), ctx_reg(context, sigcontext_ebp()), crash_pcs, crash_frames_max())
	int k = 0
	while (k < n):
		crash_write_frame(st_word(cast(int, crash_pcs) + k * __word_size__))
		k = k + 1
	if (n >= crash_frames_max()):
		st_write_cstr(c"  ... trace truncated\n")
	if (st_unwind_exact == 0):
		st_write_cstr(c"note: part of the trace is heuristic (return-address scan): frames can be missing or stale\n")
	if (crash_dump_enabled()):
		if (crash_dump_write(sig, context)):
			st_write_cstr(c"crash dump written to ")
			st_write_cstr(cd_path)
			st_write_cstr(c" (inspect with: wcore ")
			st_write_cstr(cd_path)
			st_write_cstr(c")\n")
		else:
			st_write_cstr(c"crash dump: cannot write ")
			st_write_cstr(cd_path)
			st_write_cstr(c"\n")
	st_write_cstr(c"terminating with the default action for signal ")
	st_write_dec(sig)
	st_write_cstr(c" (core dump per RLIMIT_CORE)\n")
	# Returning re-executes the faulting instruction with the default
	# disposition restored: the process dies of the original signal.


# The zeroed struct sigaction (SIG_DFL) the handlers restore first.
void crash_dfl_act_ensure():
	if (crash_dfl_act == 0):
		crash_dfl_act = malloc(5 * __word_size__)
		int i = 0
		while (i < 5):
			crash_dfl_act[i] = 0
			i = i + 1


# --- darwin (arm64_darwin) ---
# The ucontext's uc_mcontext pointer sits at +48; the arm64 mcontext
# is the exception state {far, esr, exception} (16 bytes) then the
# thread state {x0..x28, fp, lr, sp, pc, cpsr} at +16.
int crash_darwin_reg(int mcontext, int k):
	return st_word(mcontext + 16 + k * 8)


void crash_write_darwin_registers(int mcontext):
	st_write_cstr(c"registers:")
	char* digits = c"0123456789"
	int k = 0
	while (k < 34):
		if ((k & 3) == 0):
			st_write_cstr(c"\n ")
		st_write_cstr(c" ")
		if (k < 29):
			st_write_cstr(c"x")
			if (k >= 10):
				write(2, &digits[k / 10], 1)
			write(2, &digits[k % 10], 1)
		else if (k == 29):
			st_write_cstr(c"fp")
		else if (k == 30):
			st_write_cstr(c"lr")
		else if (k == 31):
			st_write_cstr(c"sp")
		else if (k == 32):
			st_write_cstr(c"pc")
		else:
			st_write_cstr(c"cpsr")
		st_write_cstr(c"=")
		if (k == 33):
			st_write_hex(st_int32(mcontext + 16 + 33 * 8))
		else:
			st_write_hex(crash_darwin_reg(mcontext, k))
		k = k + 1
	st_write_cstr(c"\n")


# The LC_UUID, formatted the way dwarfdump --uuid prints it.
void crash_write_darwin_uuid():
	char* digits = c"0123456789ABCDEF"
	int i = 0
	while (i < cd_id_size):
		if ((i == 4) || (i == 6) || (i == 8) || (i == 10)):
			st_write_cstr(c"-")
		int b = st_byte(cd_id_addr + i)
		write(2, &digits[b >> 4], 1)
		write(2, &digits[b & 15], 1)
		i = i + 1


# The darwin handler, entered from signal_trampoline with the
# ucontext. Mirrors crash_report.
void crash_report_darwin(int sig, int ucontext):
	rt_sigaction(sig, crash_dfl_act, 0)
	if (crash_active):
		return;
	crash_active = 1
	int mcontext = st_word(ucontext + 48)
	int pc = st_code_address(crash_darwin_reg(mcontext, 32))
	st_write_cstr(c"fatal signal: ")
	st_write_cstr(crash_signal_name(sig))
	st_write_cstr(c", pc=")
	st_write_hex(pc)
	if ((sig == 11) || (sig == 10)):
		st_write_cstr(c", faulting address ")
		st_write_hex(st_word(mcontext))
	st_write_cstr(c"\n")
	crash_write_darwin_registers(mcontext)
	if (cd_id_size > 0):
		st_write_cstr(c"uuid: ")
		crash_write_darwin_uuid()
		st_write_cstr(c"\n")
	st_write_cstr(c"stack trace (most recent call first):\n")
	crash_write_frame(pc)
	# W functions keep a frame chain on the W stack (x28): [x29] is the
	# caller's x29, [x29 + 8] the return address. A fault in an asm
	# stub, or in a prologue before its stp, leaves its return address
	# only in lr: lead with it when the walk does not.
	int w_sp = crash_darwin_reg(mcontext, 28)
	int n = st_unwind(pc, w_sp, crash_darwin_reg(mcontext, 29), crash_pcs, crash_frames_max())
	int lr = st_code_address(crash_darwin_reg(mcontext, 30))
	if (st_is_return(lr) && (st_func_entry(pc) != st_func_entry(lr - 1))):
		if ((n == 0) || (st_word(cast(int, crash_pcs)) != lr - 1)):
			crash_write_frame(lr - 1)
	int k = 0
	while (k < n):
		crash_write_frame(st_word(cast(int, crash_pcs) + k * __word_size__))
		k = k + 1
	if (n >= crash_frames_max()):
		st_write_cstr(c"  ... trace truncated\n")
	if (st_unwind_exact == 0):
		st_write_cstr(c"note: part of the trace is heuristic (return-address scan): frames can be missing or stale\n")
	st_write_cstr(c"terminating with the default action for signal ")
	st_write_dec(sig)
	st_write_cstr(c"\n")


# --- Windows (win64) ---
# The vectored exception handler, entered through a win_callback thunk
# with the EXCEPTION_POINTERS address: {EXCEPTION_RECORD*, CONTEXT*}.
# EXCEPTION_RECORD: ExceptionCode (u32) at +0, ExceptionAddress at +16,
# NumberParameters at +24, ExceptionInformation[] at +32. The x64
# CONTEXT keeps EFlags (u32) at +0x44, rax..r15 from +0x78 in encoding
# order (rax rcx rdx rbx rsp rbp rsi rdi r8..r15) and rip at +0xf8.

char* crash_win_exception_name(int code):
	if (code == -1073741819):   /* 0xC0000005 */
		return c"EXCEPTION_ACCESS_VIOLATION"
	if (code == -1073741676):   /* 0xC0000094 */
		return c"EXCEPTION_INT_DIVIDE_BY_ZERO"
	if (code == -1073741675):   /* 0xC0000095 */
		return c"EXCEPTION_INT_OVERFLOW"
	if (code == -1073741795):   /* 0xC000001D */
		return c"EXCEPTION_ILLEGAL_INSTRUCTION"
	if (code == -1073741674):   /* 0xC0000096 */
		return c"EXCEPTION_PRIV_INSTRUCTION"
	if (code == -1073741571):   /* 0xC00000FD */
		return c"EXCEPTION_STACK_OVERFLOW"
	if (code == -2147483645):   /* 0x80000003 */
		return c"EXCEPTION_BREAKPOINT"
	if (code == -2147483646):   /* 0x80000002 */
		return c"EXCEPTION_DATATYPE_MISALIGNMENT"
	if (code == -1073741818):   /* 0xC0000006 */
		return c"EXCEPTION_IN_PAGE_ERROR"
	return c"unknown exception"


int crash_win_is_fatal(int code):
	if ((code == -1073741819) || (code == -1073741676) || (code == -1073741675)):
		return 1
	if ((code == -1073741795) || (code == -1073741674) || (code == -1073741571)):
		return 1
	if ((code == -2147483646) || (code == -1073741818)):  /* misaligned, 0xC0000006 in-page error */
		return 1
	return 0


void crash_write_hex32(int v):
	char* digits = c"0123456789abcdef"
	st_write_cstr(c"0x")
	int i = 7
	while (i >= 0):
		write(2, &digits[(v >> (i * 4)) & 15], 1)
		i = i - 1


# CONTEXT offset of display register k (crash_reg_name order: rax rbx
# rcx rdx rsi rdi rbp rsp r8..r15 rip eflags).
int crash_win_reg_offset(int k):
	if (k == 16):
		return 248
	if (k >= 8):
		return 184 + (k - 8) * 8
	# rax rbx rcx rdx rsi rdi rbp rsp -> CONTEXT slots 0 3 1 2 6 7 5 4
	int slot = k
	if (k == 1):
		slot = 3
	else if (k == 2):
		slot = 1
	else if (k == 3):
		slot = 2
	else if (k == 4):
		slot = 6
	else if (k == 5):
		slot = 7
	else if (k == 6):
		slot = 5
	else if (k == 7):
		slot = 4
	return 120 + slot * 8


void crash_write_win_registers(int context):
	st_write_cstr(c"registers:")
	int k = 0
	while (k < 18):
		if ((k & 3) == 0):
			st_write_cstr(c"\n ")
		st_write_cstr(c" ")
		char* name = crash_reg_name(k)
		int n = 3
		if (name[2] == 'l'):
			n = 6
		if (name[2] == ' '):
			n = 2
		write(2, name, n)
		st_write_cstr(c"=")
		if (k == 17):
			crash_write_hex32(st_int32(context + 68))
		else:
			st_write_hex(st_word(context + crash_win_reg_offset(k)))
		k = k + 1
	st_write_cstr(c"\n")


# Returns EXCEPTION_CONTINUE_SEARCH (0): with no handler of its own the
# W program's fault then goes unhandled and Windows terminates the
# process with the original exception code, exactly as without the
# filter -- the report is purely additive on stderr.
int crash_report_win(int pointers):
	if (crash_active):
		return 0
	int record = st_word(pointers)
	int context = st_word(pointers + 8)
	int code = load_int32(cast(char*, record)) /* sign-extended: NTSTATUS codes are negative */
	# A vectored handler sees every first-chance exception, including
	# benign ones (OutputDebugString, thread naming, C++ throws inside
	# system DLLs): report only the fatal hardware faults.
	if (crash_win_is_fatal(code) == 0):
		return 0
	crash_active = 1
	int pc = st_word(context + 248)
	st_write_cstr(c"fatal exception: ")
	crash_write_hex32(code)
	st_write_cstr(c" (")
	st_write_cstr(crash_win_exception_name(code))
	st_write_cstr(c"), pc=")
	st_write_hex(pc)
	if ((code == -1073741819) && (st_int32(record + 24) >= 2)):
		if (st_word(record + 32) == 1):
			st_write_cstr(c", writing address ")
		else if (st_word(record + 32) == 8):
			st_write_cstr(c", executing address ")
		else:
			st_write_cstr(c", reading address ")
		st_write_hex(st_word(record + 40))
	st_write_cstr(c"\n")
	crash_write_win_registers(context)
	st_write_cstr(c"stack trace (most recent call first):\n")
	crash_write_frame(pc)
	int n = st_unwind(pc, st_word(context + 152), st_word(context + 160), crash_pcs, crash_frames_max())
	int k = 0
	while (k < n):
		crash_write_frame(st_word(cast(int, crash_pcs) + k * __word_size__))
		k = k + 1
	if (n >= crash_frames_max()):
		st_write_cstr(c"  ... trace truncated\n")
	if (st_unwind_exact == 0):
		st_write_cstr(c"note: part of the trace is heuristic (return-address scan): frames can be missing or stale\n")
	st_write_cstr(c"terminating with exception ")
	crash_write_hex32(code)
	st_write_cstr(c"\n")
	return 0


# Install the darwin handlers through signal_trampoline (found by name:
# see rt_sigaction in lib/__arch__/arm64_darwin/syscalls.w). Skipped on
# arm64e (--pac=full) images: there the kernel authenticates sa_tramp as
# a signed function pointer, the address from the symbol table is
# unsigned, and delivery would fault on the trampoline forever. Naming
# the stub (once SEEDS allows it) yields a signed pointer and lifts this.
void crash_install_darwin():
	if ((st_int32(st_base + 8) & 255) == 2):  /* CPU_SUBTYPE_ARM64E */
		return;
	int tramp = st_symbol_address(c"signal_trampoline")
	if (tramp == 0):
		return;
	crash_dfl_act_ensure()
	# Deliver on an alternate stack. The entry stub starts the W stack
	# (x28) at the initial sp and grows it down while sp stays put, so a
	# signal frame built below sp would land on the live W frames and
	# the handler's own W pushes would then overwrite the saved
	# ucontext. sigaltstack (53) takes a stack_t {ss_sp, ss_size,
	# ss_flags}.
	int alt_size = 131072
	int alt = mmap(0, alt_size, 3, 34) /* RW, PRIVATE|ANONYMOUS */
	if ((alt > 0) || (alt < -4095)):
		int[3] ss
		ss[0] = alt
		ss[1] = alt_size
		ss[2] = 0
		if (sys_sigaltstack(cast(int, &ss[0]), 0) != 0):
			return;
	else:
		return;
	int* act = malloc(5 * __word_size__)
	act[0] = cast(int, crash_report_darwin)
	act[1] = 0x08000000 /* SA_ONSTACK */
	act[2] = tramp
	act[3] = 0
	act[4] = 0
	rt_sigaction(4, act, 0)   /* SIGILL */
	rt_sigaction(5, act, 0)   /* SIGTRAP */
	rt_sigaction(8, act, 0)   /* SIGFPE */
	rt_sigaction(10, act, 0)  /* SIGBUS */
	rt_sigaction(11, act, 0)  /* SIGSEGV */
	crash_installed = 1


# i386 entry: the classic signal frame is [restorer][sig][sigcontext...],
# so the sigcontext starts one word past &sig (same as debugger/wdbg.w).
void crash_entry(int sig):
	crash_report(sig, &sig + 4)


# Install the fatal-signal reporters. Safe to call more than once; a
# no-op off Linux x86/x64, when the binary carries no readable symbol
# sections, or with W_CRASH_TRACE=0 in the environment.
void crash_handler_install():
	if (crash_installed):
		return;
	char* mode = env_get(c"W_CRASH_TRACE")
	if (mode != 0):
		if (strcmp(mode, c"0") == 0):
			return;
	if (crash_pcs == 0):
		crash_pcs = malloc(crash_frames_max() * __word_size__)
	# Parse the image and warm every allocation the handler path needs
	# (the mincore vector and the number-print scratch): the handler
	# itself must not allocate, the heap may be corrupt by then.
	stack_trace_collect(crash_pcs, 1)
	st_scratch_ensure()
	if (st_state != 1):
		return;
	if (os_windows()):
		if (win_crash_filter_install(cast(int, crash_report_win))):
			crash_installed = 1
		return;
	if (st_macho):
		if (st_machine == 183):
			crash_build_id()
			crash_install_darwin()
		return;
	if ((st_machine != 3) && (st_machine != 62)):
		return;
	crash_build_id()
	crash_dump_prepare(env_get(c"W_CRASH_DUMP"))
	crash_dfl_act_ensure()
	int handler = cast(int, crash_entry)
	if (__word_size__ == 8):
		handler = cast(int, crash_report)
	signal_install_handler(4, handler, 0) /* SIGILL */
	signal_install_handler(7, handler, 0) /* SIGBUS */
	signal_install_handler(8, handler, 0) /* SIGFPE */
	signal_install_handler(11, handler, 0) /* SIGSEGV */
	crash_installed = 1
