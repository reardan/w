# Fixture for tests/profile_use_test.w (unit P2,
# docs/projects/register_allocation_pgo.md §3.4): a program whose profile
# marks exactly one loop hot. The test compiles it plain, then with
# --profile-generate to take a profile, then with --profile-use and
# asserts the output is unchanged and the hot loop head got its
# alignment pad.
#
#   hot_sum(n): entered 4 times with n = 1000, so its while head runs
#   4004 times, 1001 per entry: hot (>= 16 per entry, >= 256 in all).
#   cold_step: entered once, its for-range head runs 4 times: matched,
#   not hot, so cold. never_called: compiled in, never run, absent from
#   the profile while its file is covered: cold. main's own loop runs 5
#   times: not hot.
import lib.lib


int hot_sum(int n):
	int s = 0
	int i = 0
	while (i < n):
		s = s + i
		i = i + 1
	return s


int cold_step(int n):
	int c = 0
	for i in range(3): c = c + 1
	return c + n


int never_called(int n):
	int t = 0
	while (n > 0):
		t = t + n
		n = n - 1
	return t


int main(int argc, int argv):
	int total = 0
	for k in range(4): total = total + hot_sum(1000)
	total = total + cold_step(2)
	if (argc > 7): total = total + never_called(argc)
	println(itoa(total))
	return 0
