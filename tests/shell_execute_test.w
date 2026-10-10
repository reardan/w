# wbuild: x64
import lib.testing
import lib.file
import lib.utf8
import repl.shell_execute


int shell_exec_test_mutations


int shell_exec_test_command(char* text, int isolated):
	if (strcmp(text, c"yes") == 0): return 0
	if (strcmp(text, c"no") == 0): return 7
	if (strcmp(text, c"mark") == 0):
		shell_exec_test_mutations++
		return 0
	if (strcmp(text, c"emit") == 0):
		println(c"out")
		println2(c"err")
		return 0
	if (strcmp(text, c"large") == 0):
		char[4096] buf
		for i in range(4096): buf[i] = 'x'
		for i in range(64):
			int sent = 0
			while (sent < 4096):
				int n = write(1, &buf[0] + sent, 4096 - sent)
				if (n <= 0): return 1
				sent = sent + n
		return 0
	if (strcmp(text, c"count") == 0):
		char[4096] buf
		int count = 0
		int n = read(0, &buf[0], 4096)
		while (n > 0):
			count = count + n
			n = read(0, &buf[0], 4096)
		if (count == 262144): return 0
		return 9
	if (strcmp(text, c"copy") == 0):
		char[1024] buf
		int n = read(0, &buf[0], 1024)
		while (n > 0):
			int sent = 0
			while (sent < n):
				int wrote = write(1, &buf[0] + sent, n - sent)
				if (wrote <= 0): return 1
				sent = sent + wrote
			n = read(0, &buf[0], 1024)
		return 0
	return 127


int shell_exec_test_run(char* text):
	shell_plan* p = shell_plan_parse(text)
	assert_equal(0, p.error)
	assert_equal(0, p.unsupported)
	int status = shell_execute_plan(p, shell_exec_test_command)
	shell_plan_free(p)
	return status


void test_shell_conditional_status_and_parent_state():
	shell_exec_test_mutations = 0
	assert_equal(0, shell_exec_test_run(c"no && mark || mark; yes || mark && mark"))
	assert_equal(2, shell_exec_test_mutations)
	assert_equal(7, shell_exec_test_run(c"no && mark"))
	assert_equal(2, shell_exec_test_mutations)
	assert_equal(0, shell_exec_test_run(c"mark | yes"))
	assert_equal(2, shell_exec_test_mutations)
	assert_equal(7, shell_exec_test_run(c"yes | no"))
	assert_equal(0, shell_exec_test_run(c"no | yes"))


void test_shell_pipeline_exceeds_pipe_capacity():
	assert_equal(0, shell_exec_test_run(c"large | copy | count"))
	assert_equal(9, shell_exec_test_run(c"yes | count"))


void test_shell_redirect_order_append_and_restore():
	char* path = cstr(f"/tmp/w_shell_exec_{getpid()}")
	char* command = cstr(f"emit > {path} 2>&1")
	assert_equal(0, shell_exec_test_run(command))
	free(command)
	char* content = file_read_text(path)
	assert_strings_equal(c"out\nerr\n", content)
	free(content)
	command = cstr(f"emit >> {path} 2> /dev/null")
	assert_equal(0, shell_exec_test_run(command))
	free(command)
	content = file_read_text(path)
	assert_strings_equal(c"out\nerr\nout\n", content)
	free(content)
	command = cstr(f"copy < {path} | copy > {path}.copy")
	assert_equal(0, shell_exec_test_run(command))
	free(command)
	char* copy = strjoin(path, c".copy")
	content = file_read_text(copy)
	assert_strings_equal(c"out\nerr\nout\n", content)
	free(content)
	assert_equal(1, shell_exec_test_run(c"emit > /no/such/wsh335/directory/file"))
	# A subsequent command must still see the parent's original stdio.
	command = cstr(f"emit > {path} 2>&1")
	assert_equal(0, shell_exec_test_run(command))
	free(command)
	content = file_read_text(path)
	assert_strings_equal(c"out\nerr\n", content)
	free(content)
	unlink(path)
	unlink(copy)
	free(path)
	free(copy)
