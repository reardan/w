# Fixture for tests/profile_generate_test.w (unit P1,
# docs/projects/register_allocation_pgo.md §3.2): a program with known
# call and loop-head counts. Compiled with --profile-generate and run
# with W_PROFILE_OUT by the test, which merges the dump with bin/wprof
# and asserts the exact numbers below.
#
#   work(n): entered once per call; loop 1 (for-range) evaluates its
#   head n+1 times, loop 2 (while) 6 times, loop 3 (for-in over a
#   list) 4 times (3 elements + the exit check).
#   main: entered once; its for-range head runs 4 times (3 calls).
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
