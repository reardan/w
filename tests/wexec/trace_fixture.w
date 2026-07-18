# Helper binary for wexec_trace_test (build.base.json): opens a
# declared-input file and an undeclared file for reading, then exits.
# Compiled ahead of time (not under trace) so the traced step is just
# running the already-built binary -- see tests/wexec/trace.json.
import lib.lib

int main():
	int fd1 = open(c"tests/wexec/trace_declared.txt", 0, 0)
	if (fd1 >= 0):
		close(fd1)
	int fd2 = open(c"tests/wexec/trace_undeclared.txt", 0, 0)
	if (fd2 >= 0):
		close(fd2)
	println(c"trace fixture ran")
	return 0
