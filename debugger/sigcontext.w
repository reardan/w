/*
Offsets into the struct sigcontext the kernel builds for a signal
handler, for both targets (arch/x86/include/uapi/asm/sigcontext.h).

i386: the frame of a non-SA_SIGINFO handler is [restorer][sig]
[sigcontext...]; the handler receives 'sig' as its argument, so the
sigcontext starts at &sig + 4.

x86-64: the kernel always builds an rt frame and calls the handler with
sig in rdi and the ucontext pointer in rdx; the sigcontext (uc_mcontext)
sits at ucontext + 40. wdbg's runtime thunk (debugger/wdbg.w) converts
that register convention into a W stack call carrying &uc_mcontext.

The accessor names keep the i386 register names; on x64 they read the
corresponding r-register (eip -> rip, esp -> rsp, eax -> rax).
*/
import lib.lib


int sigcontext_edi():
	if (__word_size__ == 8):
		return 64 /* rdi */
	return 16
int sigcontext_esi():
	if (__word_size__ == 8):
		return 72 /* rsi */
	return 20
int sigcontext_ebp():
	if (__word_size__ == 8):
		return 80 /* rbp */
	return 24
int sigcontext_esp():
	if (__word_size__ == 8):
		return 120 /* rsp */
	return 28
int sigcontext_ebx():
	if (__word_size__ == 8):
		return 88 /* rbx */
	return 32
int sigcontext_edx():
	if (__word_size__ == 8):
		return 96 /* rdx */
	return 36
int sigcontext_ecx():
	if (__word_size__ == 8):
		return 112 /* rcx */
	return 40
int sigcontext_eax():
	if (__word_size__ == 8):
		return 104 /* rax */
	return 44
int sigcontext_trapno():
	if (__word_size__ == 8):
		return 160
	return 48
int sigcontext_err():
	if (__word_size__ == 8):
		return 152
	return 52
int sigcontext_eip():
	if (__word_size__ == 8):
		return 128 /* rip */
	return 56
int sigcontext_eflags():
	if (__word_size__ == 8):
		return 136
	return 64
# Fault address of the last page fault (only meaningful for SIGSEGV)
int sigcontext_cr2():
	if (__word_size__ == 8):
		return 176
	return 84
# x64-only: r8..r15 sit at the start of the 64-bit sigcontext
int sigcontext_r8():
	return 0
int sigcontext_r9():
	return 8
int sigcontext_r10():
	return 16
int sigcontext_r11():
	return 24
int sigcontext_r12():
	return 32
int sigcontext_r13():
	return 40
int sigcontext_r14():
	return 48
int sigcontext_r15():
	return 56


# Registers are word-sized fields: 4 bytes on i386, 8 on x86-64.
int ctx_reg(int context, int offset):
	return load_word(context + offset)


int ctx_eip(int context):
	return ctx_reg(context, sigcontext_eip())


void ctx_set_eip(int context, int eip):
	save_word(context + sigcontext_eip(), eip)


int ctx_esp(int context):
	return ctx_reg(context, sigcontext_esp())


int ctx_eax(int context):
	return ctx_reg(context, sigcontext_eax())


int ctx_trapno(int context):
	return ctx_reg(context, sigcontext_trapno())


int ctx_eflags(int context):
	return ctx_reg(context, sigcontext_eflags())


# The x86 trap flag (bit 8 of eflags): when set through the sigcontext,
# sigreturn restores it and the CPU raises SIGTRAP after one instruction.
void ctx_set_trap_flag(int context):
	save_word(context + sigcontext_eflags(), ctx_eflags(context) | 256)


void ctx_clear_trap_flag(int context):
	int flags = ctx_eflags(context)
	# eflags & ~0x100 without a bitwise-not operator on constants
	if (flags & 256):
		save_word(context + sigcontext_eflags(), flags - 256)
