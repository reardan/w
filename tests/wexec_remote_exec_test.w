# wbuild: tool=tools/wexec_main.w
# End-to-end test for 'wexec --remote=<host>' (issue #487; the "Remote
# execution" block comment in tools/wexec.w). tests/wexec/fake_ssh.sh
# stands in for ssh (WEXEC_REMOTE_SSH): it runs the remote command
# string in this checkout, so the "host" is a pid-scoped --remote-dir
# under bin/. The remote dir is pre-seeded with this tree's bin/wexec
# and ./w, the warm state a host keeps between runs, so the remote
# ./wbuild only refreshes tests/wexec/remote_exec.json's no-op wv2 and
# wexec targets instead of bootstrapping a compiler.
#
#   1. a cold run uploads every input, runs remote_gen there, brings
#      its declared outputs back (the script one executable again) and
#      stamps them locally;
#   2. an unchanged rerun is a local cache hit: no ssh at all;
#   3. after an input edit only that one file is uploaded again;
#   4. remote_leak reads a file that exists here but is not declared,
#      so it fails remotely: the host sees only the shipped closure.
import lib.testing
import lib.file
import lib.env
import lib.process
import lib.stat
import lib.str
import lib.utf8
import structures.string


char* wret_dir_cache
char* wret_dir():
	if (wret_dir_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/wexec_remote_exec_host_")
		string_append_int(p, getpid())
		wret_dir_cache = p.data
		free(p)
	return wret_dir_cache


char* wret_path(char* tail):
	string_builder* p = string_new()
	string_append(p, wret_dir())
	string_append(p, tail)
	char* text = p.data
	free(p)
	return text


int wret_file_exists(char* path):
	int fd = open(path, 0, 0)
	if (fd < 0): return 0
	close(fd)
	return 1


void wret_copy_executable(char* from, char* to):
	wstream* in = stream_open_read(from)
	asserts(c"open copy source", in != 0)
	string_builder* data = string_new()
	stream_read_all(in, data)
	stream_close(in)
	# 577 = O_WRONLY | O_CREAT | O_TRUNC, 493 = rwxr-xr-x
	int fd = open(to, 577, 493)
	asserts(c"open copy destination", fd >= 0)
	asserts(c"copy bytes", write(fd, data.data, data.length) == data.length)
	close(fd)
	file_chmod(to, 493)
	string_free(data)


int wret_count_lines(char* path):
	char* text = file_read_text(path)
	if (text == 0): return 0
	int n = 0
	int i = 0
	while (text[i] != 0):
		if (text[i] == 10): n = n + 1
		i = i + 1
	free(text)
	return n


process_result* wret_run(char* target):
	char* dir_flag = cstr(f"--remote-dir={wret_dir()}")
	char** argv = strv_new(6)
	strv_set(argv, 0, c"bin/wexec")
	strv_set(argv, 1, c"-f")
	strv_set(argv, 2, c"tests/wexec/remote_exec.json")
	strv_set(argv, 3, c"--remote=fakehost")
	strv_set(argv, 4, dir_flag)
	strv_set(argv, 5, target)
	char** child_env = env_copy_with(env_current(), c"WEXEC_REMOTE_SSH", c"tests/wexec/fake_ssh.sh")
	child_env = env_copy_with(child_env, c"WEXEC_FAKE_SSH_LOG", wret_path(c".ssh_log"))
	spawn_options* opts = spawn_options_new()
	opts.env = child_env
	process_result* result = process_run(c"bin/wexec", argv, opts, 0, 120000)
	free(cast(char*, argv))
	free(opts)
	free(dir_flag)
	return result


void wret_show(process_result* r):
	if (r.status != 0):
		println2(r.stdout_text)
		println2(r.stderr_text)


void test_remote_exec():
	mkdir(wret_dir(), 493)
	mkdir(wret_path(c"/run"), 493)
	mkdir(wret_path(c"/run/bin"), 493)
	wret_copy_executable(c"bin/wexec", wret_path(c"/run/bin/wexec"))
	wret_copy_executable(c"w", wret_path(c"/run/w"))
	unlink(c"bin/.wexec_cache/tests_wexec_remote_exec.json__remote_gen")
	unlink(c"bin/wexec_remote_exec_out.txt")
	unlink(c"bin/wexec_remote_exec_tool.sh")
	asserts(c"write input", file_write_text(c"bin/wexec_remote_exec_input.txt", c"remote exec v1\n"))
	asserts(c"write undeclared", file_write_text(c"bin/wexec_remote_exec_undeclared.txt", c"not shipped\n"))

	# 1. Cold: everything uploads, the step runs remotely, the output
	# comes back and is stamped.
	process_result* r1 = wret_run(c"remote_gen")
	wret_show(r1)
	asserts(c"cold run exit 0", r1.status == 0)
	asserts(c"remote step output streamed", contains(r1.stdout_text, c"remote_gen step ran"))
	asserts(c"cold run uploads every file", contains(r1.stdout_text, c"uploading 5 of 5 input files"))
	asserts(c"both outputs restored", contains(r1.stdout_text, c"restored 2 output files"))
	char* out1 = file_read_text(c"bin/wexec_remote_exec_out.txt")
	asserts(c"output fetched", out1 != 0)
	assert_strings_equal(c"remote exec v1\n", out1)
	file_stat st
	asserts(c"script output fetched", file_stat_path(c"bin/wexec_remote_exec_tool.sh", &st) == 0)
	asserts(c"script output restored executable", (file_mode_perm(&st) & 64) != 0)
	asserts(c"local stamp written", wret_file_exists(c"bin/.wexec_cache/tests_wexec_remote_exec.json__remote_gen"))
	asserts(c"ran in the remote tree", wret_file_exists(wret_path(c"/run/bin/wexec_remote_exec_out.txt")))
	asserts(c"three ssh rounds", wret_count_lines(wret_path(c".ssh_log")) == 3)
	process_result_free(r1)

	# 2. Unchanged: the local stamp satisfies it, nothing goes remote.
	process_result* r2 = wret_run(c"remote_gen")
	wret_show(r2)
	asserts(c"cached run exit 0", r2.status == 0)
	asserts(c"cached run is a local hit", contains(r2.stdout_text, c"remote_gen (cached)"))
	asserts(c"cached run opens no connection", wret_count_lines(wret_path(c".ssh_log")) == 3)
	process_result_free(r2)

	# 3. One input changed: only its new content is uploaded.
	asserts(c"rewrite input", file_write_text(c"bin/wexec_remote_exec_input.txt", c"remote exec v2\n"))
	process_result* r3 = wret_run(c"remote_gen")
	wret_show(r3)
	asserts(c"incremental run exit 0", r3.status == 0)
	asserts(c"incremental run uploads one file", contains(r3.stdout_text, c"uploading 1 of 5 input files"))
	char* out3 = file_read_text(c"bin/wexec_remote_exec_out.txt")
	assert_strings_equal(c"remote exec v2\n", out3)
	process_result_free(r3)

	# 4. Hermetic: an undeclared file that exists here is absent there.
	process_result* r4 = wret_run(c"remote_leak")
	asserts(c"undeclared read fails remotely", r4.status != 0)
	asserts(c"failure names the remote build", contains(r4.stderr_text, c"remote: build on fakehost failed"))
	process_result_free(r4)

	unlink(c"bin/wexec_remote_exec_input.txt")
	unlink(c"bin/wexec_remote_exec_undeclared.txt")
