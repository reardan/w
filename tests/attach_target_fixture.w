# A long-running debuggee for the attach test: sets itself ptraceable by
# any process (so YAMA ptrace_scope does not block a sibling tracer), then
# spins incrementing a global forever. wdbg attaches, inspects and kills it.
import lib.lib

int attach_counter

int slow_step(int n):
	return n + 1

int main(int argc, int argv):
	# prctl(PR_SET_PTRACER=0x59616d61, PR_SET_PTRACER_ANY=-1)
	syscall(172, 0x59616d61, -1)
	attach_counter = 1000
	while (1):
		attach_counter = slow_step(attach_counter)
		int j = 0
		while (j < 200000):
			j = j + 1
	return 0
