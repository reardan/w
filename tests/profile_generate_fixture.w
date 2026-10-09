# Fixture for tests/profile_generate_test.w (unit P1,
# docs/projects/register_allocation_pgo.md §3.2): a program with known
# call and loop-head counts. Compiled with --profile-generate and run
# with W_PROFILE_OUT by the test, which merges the dump with bin/wprof
# and asserts the exact numbers below.
#
#   work(n): entered once per call; loop 1 (for-range) runs its body
#   n times, loop 2 (while) 5 times, loop 3 (for-in over a list) 3
#   times (one per element). The counter sits at the loop's head, the
#   body's first instruction since unit A7 rotated the loops
#   (docs/projects/codegen_gap_plan.md §8), so it counts iterations,
#   not condition evaluations (one more per loop entry).
#   main: entered once; its for-range body runs 3 times (3 calls).
#   With "exit" as argv[1], main leaves through exit(0) instead of
#   returning, so the direct exit() path is exercised as well.
import lib.lib


int work(int n):
	int s = 0
	for i in range(n):
		s = s + i
	int j = 0
	while (j < 5):
		j = j + 1
	list[int] items = list[int]{1, 2, 3}
	for int v in items:
		s = s + v
	return s


int main(int argc, int argv):
	int t = 0
	for k in range(3): t = t + work(10)
	if (argc > 1): exit(0)
	return 0
