# A long-running debuggee for the attach test: sets itself ptraceable by
# any process (so YAMA ptrace_scope does not block a sibling tracer), then
# spins incrementing a global forever. wdbg attaches, inspects and kills it.
import lib.lib

int attach_counter

# A nested call with a local in each frame, so the attach test can exercise
# args/locals inspection and frame selection (#123 phase 5) against a real
# two-level call stack: a breakpoint in bump gives frame 0 = bump (arg n,
# local inc), frame 1 = slow_step (arg n, local step), frame 2 = main.
int bump(int n):
	int inc = n + 1
	return inc

int slow_step(int n):
	int step = bump(n)
	return step

int main(int argc, int argv):
	# prctl(PR_SET_PTRACER=0x59616d61, PR_SET_PTRACER_ANY=-1). The syscall()
	# builtin lowers exactly nr + 3 register args; the padding 0 is required —
	# with fewer args eax holds garbage and the kernel returns ENOSYS, so the
	# Yama exemption never engages and attach fails under ptrace_scope=1.
	# prctl is 172 only on i386; on x86-64 172 is iopl — prctl is 157.
	int prctl_nr = 172
	if (__word_size__ == 8):
		prctl_nr = 157
	syscall(prctl_nr, 0x59616d61, -1, 0)
	attach_counter = 1000
	while (1):
		attach_counter = slow_step(attach_counter)
		int j = 0
		while (j < 200000):
			j = j + 1
	return 0
