/*
Signal handler installation for the Linux x86/x64 targets.

i386: a non-SA_SIGINFO handler is called with the classic frame
[restorer][sig][sigcontext...] on the stack, so &sig + 4 is the
sigcontext, and the kernel's vdso trampoline performs sigreturn when
the handler returns. Callers pass a 1-argument entry wrapper that
computes the context and forwards to their real 2-argument handler.

x86-64: the kernel always builds an rt frame and calls the handler with
sig in rdi and the ucontext pointer in rdx, and rt_sigaction requires
an SA_RESTORER trampoline. Neither matches a W function, so tiny
runtime thunks emitted into an executable page convert the register
convention into a W stack call of handler(sig, ucontext + 40) - the
sigcontext is the uc_mcontext field at offset 40 - and a shared
restorer performs rt_sigreturn. Callers pass the 2-argument handler
directly then.

Shared by the in-process debugger (debugger/wdbg.w) and the fatal-crash
reporter (lib/crash.w); repl/core.w predates this file and keeps its
own copy for the fault-recovery path. This file is in the seed's import
graph: seed-era syntax only.
*/
import lib.assert


int signal_thunk_page
int signal_thunk_pos
int signal_restorer


void signal_thunk_emit(int n, char* bytes):
	char* p = cast(char*, signal_thunk_page + signal_thunk_pos)
	for i in range(n): p[i] = bytes[i]
	signal_thunk_pos = signal_thunk_pos + n


# The thunk page is never writable and executable at once (W^X, issue
# #526): it is mapped read-write, and each emission flips it back to
# read-execute once the bytes are in place.
void signal_thunk_writable(int writable):
	int prot = 5 /* R+X */
	if (writable): prot = 3 /* R+W */
	asserts(c"mprotect of signal thunk page failed", mprotect(signal_thunk_page, 4096, prot) == 0)


void signal_thunk_init():
	if (signal_thunk_page != 0): return;
	signal_thunk_page = mmap(0, 4096, 3, 34) /* RW, PRIVATE|ANONYMOUS */
	asserts(c"mmap of signal thunk page failed", (signal_thunk_page > 0) | (signal_thunk_page < -4095))
	signal_restorer = signal_thunk_page
	/* mov eax,15 ; syscall  (rt_sigreturn) */
	signal_thunk_emit(7, c"\xb8\x0f\x00\x00\x00\x0f\x05")
	signal_thunk_writable(0)


# Emit an x64 thunk calling handler(sig, &uc_mcontext) with the W stack
# convention (first argument at the highest address). The handler
# address uses a full-width immediate, including PIE load addresses.
int signal_emit_handler_thunk(int handler):
	signal_thunk_writable(1)
	int addr = signal_thunk_page + signal_thunk_pos
	/* push rdi ; lea rax,[rdx+40] ; push rax ; movabs rax,imm64 */
	signal_thunk_emit(8, c"\x57\x48\x8d\x42\x28\x50\x48\xb8")
	save_i(cast(char*, signal_thunk_page + signal_thunk_pos), handler, 8)
	signal_thunk_pos = signal_thunk_pos + 8
	/* call rax ; add rsp,16 ; ret  (returns into the restorer) */
	signal_thunk_emit(7, c"\xff\xd0\x48\x83\xc4\x10\xc3")
	signal_thunk_writable(0)
	return addr


# SA_ONSTACK: deliver on the thread's alternate signal stack, when it
# has one (signal_altstack_install); without one the flag is ignored.
const int signal_sa_onstack = 0x08000000


# Make [base, base + size) the calling thread's alternate signal stack
# (Linux stack_t {ss_sp, ss_flags, ss_size}, one word per field), so a
# handler installed with signal_sa_onstack still runs when the thread's
# own stack is exhausted -- a stack-overflow SIGSEGV is reported instead
# of killing the process outright. Per thread: a CLONE_VM child starts
# without one. Returns 0 or -errno.
int signal_altstack_install(int base, int size):
	int[3] ss
	ss[0] = base
	ss[1] = 0
	ss[2] = size
	return sys_sigaltstack(cast(int, &ss[0]), 0)


# struct sigaction: on i386 {handler, flags, restorer, mask[2]} with
# 4-byte fields, no SA_SIGINFO/SA_RESTORER (the vdso trampoline does
# sigreturn); on x86-64 {handler, flags, restorer, mask} with 8-byte
# fields, SA_SIGINFO (4) | SA_RESTORER (0x04000000) and the thunks.
void signal_install_handler(int signum, int handler, int flags):
	int* act = cast(int*, malloc(5 * __word_size__))
	if (__word_size__ == 8):
		signal_thunk_init()
		act[0] = signal_emit_handler_thunk(handler)
		act[1] = flags | 4 | 0x04000000
		act[2] = signal_restorer
		act[3] = 0
	else:
		act[0] = handler
		act[1] = flags
		act[2] = 0
		act[3] = 0
		act[4] = 0
	int err = rt_sigaction(signum, act, 0)
	asserts(c"rt_sigaction failed", err == 0)
	free(act)
