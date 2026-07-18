# Device (PTX) bodies are pure compute: no function calls of any kind
# (covers user helpers, print, new and the container runtime alike).
# Compiled with the x64 selector by the cuda_diagnostics_test target;
# the expectations live there (wfixture runs the default target only).
int helper(int x):
	return x + 1

kernel bad(int* v, int n):
	int i = thread_idx()
	if i < n:
		v[i] = helper(v[i])

int main():
	return 0
