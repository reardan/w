# A long-running debuggee for the attach test: sets itself ptraceable by
# any process (so YAMA ptrace_scope does not block a sibling tracer), then
# spins incrementing a global forever. wdbg attaches, inspects and kills it.
import lib.lib

int attach_counter

# Typed data for the restricted-eval cases (#123 phase 6): a struct value,
# a pointer to it, and a heap int array, all initialized before the spin
# loop so the attach test can read them through p/set at any stop.
struct at_pair:
	int first
	int second

at_pair attach_pair
at_pair* attach_pair_ref
int* attach_items

# A nested call with a local in each frame, so the attach test can exercise
# args/locals inspection and frame selection (#123 phase 5) against a real
# two-level call stack: a breakpoint in bump gives frame 0 = bump (arg n,
# local inc), frame 1 = slow_step (arg n, local step), frame 2 = main.
int bump(int n):
	int inc = n + 1
	return inc

int slow_step(int n):
	# The fixed 7000000 call-site offset makes bump's n distinguishable
	# from slow_step's n at the same stop, so attach_test.sh's frame
	# selection case can assert 'up; p n' really addresses the caller's
	# slot (the two frames' n used to hold the same value, which hid
	# frame-base regressions). Undone on return, so attach_counter still
	# advances by exactly one per iteration.
	int step = bump(n + 7000000)
	return step - 7000000

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
	attach_pair.first = 1234
	attach_pair.second = 5678
	attach_pair_ref = &attach_pair
	attach_items = cast(int*, malloc(4 * __word_size__))
	attach_items[0] = 111
	attach_items[1] = 222
	attach_items[2] = 333
	attach_items[3] = 444
	attach_counter = 1000
	while (1):
		attach_counter = slow_step(attach_counter)
		int j = 0
		while (j < 200000):
			j = j + 1
	return 0
