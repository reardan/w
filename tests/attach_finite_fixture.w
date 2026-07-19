# A debuggee that terminates on its own, for attach_test.sh's detach case:
# unlike attach_target_fixture.w's forever loop (needed so every other case
# can kill -9 it without worrying about a race against natural exit), this
# one proves 'detach' truly restores every patched breakpoint byte and
# leaves the target able to run to completion and produce its normal
# output/exit code, not just "no longer traced". The 150ms sleep between
# iterations keeps total runtime short (~1s for 6 iterations) while
# comfortably outliving attach_test.sh's 0.4s post-fork settle delay.
import lib.lib
import lib.time

int attach_counter

# Same two-level call shape as attach_target_fixture.w, so the same
# breakpoint target (bump) can be hit and detached from mid-call.
int bump(int n):
	int inc = n + 1
	return inc

int slow_step(int n):
	int step = bump(n)
	return step

int main(int argc, int argv):
	# See attach_target_fixture.w: lets a sibling tracer attach under YAMA
	# ptrace_scope=1.
	syscall(172, 0x59616d61, -1, 0)
	attach_counter = 1000
	int i = 0
	while (i < 6):
		attach_counter = slow_step(attach_counter)
		sleep_ms(150)
		i = i + 1
	println(c"attach_finite_done")
	return 42
