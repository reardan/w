# wbuild: x64 expect_stdout="extern data OK"
# Imported data objects on both targets: extern without a parameter list
# reserves space that the dynamic loader fills through a COPY relocation.
# Statically initialized libc data (stdout, stderr, optind) proves the
# copy carries the library's initial value.
import lib.lib
import lib.assert

c_lib "libc.so.6"

extern int fputs(char* s, void* stream)
extern int fprintf(void* stream, char* fmt, ...)
extern int fflush(int stream)

extern void* stdout
extern void* stderr
extern char** environ
extern int optind


int main(int argc, int argv):
	# glibc initializes these FILE pointers statically; a null value would
	# mean the COPY relocation did not run.
	assert1(stdout != 0)
	assert1(stderr != 0)
	assert_equal(1, optind)

	fputs(c"extern data stdout write\x0a", stdout)

	# fprintf: an imported data object as the fixed argument of a variadic
	# import.
	fprintf(stderr, c"extern data stderr %d %s\x0a", 42, c"formatted")

	# environ starts null: W's entry stub never runs libc's startup code,
	# which is what fills it. The COPY space itself must still be readable.
	assert_equal(0, cast(int, environ))

	fflush(0)
	println(c"extern data OK")
	return 0
