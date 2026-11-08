# Shared plumbing for the library fuzz harnesses (tools/fuzz/harness_*.w,
# issue #842). Each harness is a small program built with
# 'bin/wv2 --coverage' and driven by bin/wfuzz: it reads one input from
# the file named by its first argument (or stdin when there is none),
# feeds it to one library's parser, and exits
#   0  the input was accepted,
#   1  the library rejected it (a normal outcome),
#   3  an invariant the harness checks failed (fh_fail; wfuzz counts
#      any status other than 0 and 1 as a crash, like a signal).
import lib.lib
import lib.args
import lib.io
import lib.stream
import structures.string


# The input bytes (NUL-terminated for text parsers, NULs inside kept)
# with the byte count in *length. Exits 2 when it cannot be read.
char* fh_input(int argc, int argv, int* length):
	args_init(argc, argv)
	wstream* in = 0
	if (args_count() >= 2): in = stream_open_read(args_get(1))
	else: in = stream_reader(0)
	if (in == 0):
		println2(c"harness: cannot open the input")
		exit(2)
	string_builder* b = string_new()
	io_result r
	int status = stream_read_all_checked(in, b, &r)
	if (args_count() >= 2): stream_close(in)
	if (status != IO_OK):
		println2(c"harness: cannot read the input")
		exit(2)
	char* data = b.data
	*length = b.length
	free(b)
	return data


# An invariant failed: a finding, not a rejection.
void fh_fail(char* what):
	print2(c"harness: invariant failed: ")
	println2(what)
	exit(3)


void fh_check(int ok, char* what):
	if (ok == 0): fh_fail(what)


# 1 when the first n bytes of a and b match.
int fh_bytes_equal(char* a, char* b, int n):
	for i in range(n):
		if (a[i] != b[i]): return 0
	return 1
