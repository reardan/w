/*
Offsets into the i386 struct sigcontext that the kernel builds on the
stack for a non-SA_SIGINFO handler: [restorer][sig][sigcontext...].
The handler receives 'sig' as its argument, so the sigcontext starts at
&sig + 4. See arch/x86/include/uapi/asm/sigcontext.h (32-bit layout).
*/
import lib.lib


int sigcontext_edi():
	return 16
int sigcontext_esi():
	return 20
int sigcontext_ebp():
	return 24
int sigcontext_esp():
	return 28
int sigcontext_ebx():
	return 32
int sigcontext_edx():
	return 36
int sigcontext_ecx():
	return 40
int sigcontext_eax():
	return 44
int sigcontext_trapno():
	return 48
int sigcontext_err():
	return 52
int sigcontext_eip():
	return 56
int sigcontext_eflags():
	return 64
# Fault address of the last page fault (only meaningful for SIGSEGV)
int sigcontext_cr2():
	return 84


int ctx_eip(int context):
	return load_int(context + sigcontext_eip())


void ctx_set_eip(int context, int eip):
	save_int(context + sigcontext_eip(), eip)


int ctx_esp(int context):
	return load_int(context + sigcontext_esp())


int ctx_eax(int context):
	return load_int(context + sigcontext_eax())


int ctx_trapno(int context):
	return load_int(context + sigcontext_trapno())


int ctx_eflags(int context):
	return load_int(context + sigcontext_eflags())


# The x86 trap flag (bit 8 of eflags): when set through the sigcontext,
# sigreturn restores it and the CPU raises SIGTRAP after one instruction.
void ctx_set_trap_flag(int context):
	save_int(context + sigcontext_eflags(), ctx_eflags(context) | 256)


void ctx_clear_trap_flag(int context):
	int flags = ctx_eflags(context)
	# eflags & ~0x100 without a bitwise-not operator on constants
	if (flags & 256):
		save_int(context + sigcontext_eflags(), flags - 256)
