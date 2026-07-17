# End-to-end exercise of the extended '# wbuild:' directive vocabulary
# (tools/wbuildgen.w): the generated targets carry piped stdin, an
# expect_stdout assertion, a run timeout and a declared run-time data
# file, and the x64 twin inherits the same run-step fields.
# wbuild: x64 timeout=20000
# wbuild: stdin="ping\n" expect_stdout="pong"
# wbuild: deps=tests/wbuild_directive_data.txt
import lib.lib
import lib.assert


int main():
	# The data file is read at run time, so it is invisible to the
	# import graph; the deps= directive declares it, and 'bin/wtest
	# changed' maps edits of it back to this target.
	int fd = open(c"tests/wbuild_directive_data.txt", 0, 0)
	assert1(fd >= 0)
	char* data = malloc(16)
	int n = read(fd, data, 15)
	close(fd)
	assert_equal(5, n)
	data[n] = 0
	assert_strings_equal(c"pong\n", data)
	# stdin= pipes "ping\n"; echo the data file's word back so the
	# expect_stdout= directive has something to assert.
	char* line = malloc(16)
	int m = read(0, line, 15)
	assert_equal(5, m)
	line[m] = 0
	assert_strings_equal(c"ping\n", line)
	print(data)
	return 0
