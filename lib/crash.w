/*
Symbolized crash reports for fatal signals (issue #378).

crash_handler_install() installs handlers for SIGILL, SIGBUS, SIGFPE
and SIGSEGV that write the crash metadata (signal, pc, faulting
address) and a symbolized stack trace - function names and file:line
resolved from the running binary's own .symtab and .debug_line
sections via lib/stack_trace.w - to stderr:

	fatal signal: SIGSEGV (invalid memory reference), pc=0x08048b31, faulting address 0x00000000
	stack trace (most recent call first):
	  at crash_deep (tests/crash_null_deref_fixture.w:11)
	  at crash_mid (tests/crash_null_deref_fixture.w:15)
	  at main (tests/crash_null_deref_fixture.w:20)
	note: the trace is heuristic (return-address scan, no frame pointers): frames can be missing or stale
	terminating with the default action for signal 11 (core dump per RLIMIT_CORE)

The handler then restores the signal's default disposition and returns;
the kernel re-executes the faulting instruction and the process dies of
the original signal. Exit status, WIFSIGNALED, core dumps (subject to
RLIMIT_CORE) and anything a test harness observes stay exactly as
without the handler - the report is purely additive on stderr.

Accuracy: the innermost frame comes from the faulting pc and is always
real. Every OLDER frame comes from lib/stack_trace.w's heuristic
return-address scan (there are no frame pointers to follow, see
docs/todo.txt), so a caller can be missing and a stale stack slot that
still looks like a live return address can add a frame that is not on
the call path. Do not treat the tail of the trace as exact.

Installation is opt-in - import this file and call
crash_handler_install() from main - and is a silent no-op when
W_CRASH_TRACE=0 is set in the environment, or when the running image
is not a Linux x86/x64 ELF with readable symbol sections (arm64 has no
sigcontext accessors here; Mach-O/PE carry no symbol sections). The
compiler driver (w.w) and the test runner main (lib/testing.w) install
it, so compiler crashes and crashing tests report symbolized traces.

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
import lib.env
import debugger.sigcontext


int crash_installed
int crash_active
char* crash_pcs    /* preallocated frame pc buffer */
int* crash_dfl_act /* zeroed struct sigaction: SIG_DFL */


int crash_frames_max():
	return 32


char* crash_signal_name(int sig):
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
	st_write_cstr(c"stack trace (most recent call first):\n")
	# The innermost frame is the faulting pc itself (exact); older
	# frames come from the heuristic return-address scan.
	crash_write_frame(pc)
	int n = st_scan(ctx_esp(context), crash_pcs, crash_frames_max(), 0)
	int k = 0
	while (k < n):
		crash_write_frame(st_word(cast(int, crash_pcs) + k * __word_size__))
		k = k + 1
	st_write_cstr(c"note: the trace is heuristic (return-address scan, no frame pointers): frames can be missing or stale\n")
	st_write_cstr(c"terminating with the default action for signal ")
	st_write_dec(sig)
	st_write_cstr(c" (core dump per RLIMIT_CORE)\n")
	# Returning re-executes the faulting instruction with the default
	# disposition restored: the process dies of the original signal.


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
	if ((st_machine != 3) && (st_machine != 62)):
		return;
	if (crash_dfl_act == 0):
		crash_dfl_act = malloc(5 * __word_size__)
		int i = 0
		while (i < 5):
			crash_dfl_act[i] = 0
			i = i + 1
	int handler = cast(int, crash_entry)
	if (__word_size__ == 8):
		handler = cast(int, crash_report)
	signal_install_handler(4, handler, 0) /* SIGILL */
	signal_install_handler(7, handler, 0) /* SIGBUS */
	signal_install_handler(8, handler, 0) /* SIGFPE */
	signal_install_handler(11, handler, 0) /* SIGSEGV */
	crash_installed = 1
