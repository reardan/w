# atomic_cas is host-only for now: the PTX twin (atom.cas.b32) is
# staged in docs/projects/threads.md.
# wfixture: x64
# expect_fail
# expect_stderr: atomic_cas is not available in gpu code yet
kernel bad(int* v, int n):
	int i = thread_idx()
	if i < n:
		atomic_cas(v, 0, 1)

int main(int argc, int argv):
	return 0
