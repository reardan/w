# Device (PTX) bodies are pure compute: no function calls of any kind
# (covers user helpers, print, new and the container runtime alike).
# wfixture: x64
# expect_fail
# expect_stderr: gpu code cannot call functions
int helper(int x):
	return x + 1

kernel bad(int* v, int n):
	int i = thread_idx()
	if i < n:
		v[i] = helper(v[i])

int main():
	return 0
