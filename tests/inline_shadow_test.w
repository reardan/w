# wbuild: tool=tools/wprof.w deps=tests/inline_shadow_fixture.w
/*
A body inlined at a --profile-use hot site whose parameter has the name
of a caller's register-resident local (tests/inline_shadow_fixture.w,
the shape of lib/memory_freelist.w's freelist_malloc, whose inlined
malloc_bin_push(block, ...) made the x64 self-compile under
profiles/self_x64.wprof crash). The loop-register liveness check
(compiler/regalloc_scan.w, rl_entry_live) asked sym_probe(name) == t,
which the shadowing parameter answers with its own record: the caller's
'block' looked dead, the body's call was not bracketed by its spill and
reload, and the callee clobbered it. The liveness now asks whether the
record is still on the name's chain (sym_record_live).

x64: compile the fixture plain, take its profile, compile it with
--profile-use and check the hot site was inlined and the output is the
plain build's.
*/
import lib.lib
import lib.testing
import lib.assert
import lib.str
import lib.env
import lib.process
import structures.string


char* is_run(char* path, char** argv, char** env, int* status, char** stderr_out):
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_null
	opts.stdout_mode = process_pipe
	opts.stderr_mode = process_pipe
	opts.env = env
	process* child = process_spawn(path, argv, opts)
	free(opts)
	asserts(c"spawn failed", child != 0)
	string_builder* err = string_new()
	string_builder* text = string_new()
	char* chunk = cast(char*, malloc(4096))
	int n = read(child.stderr_fd, chunk, 4096)
	while (n > 0):
		string_append_bytes(err, chunk, n)
		n = read(child.stderr_fd, chunk, 4096)
	close(child.stderr_fd)
	n = read(child.stdout_fd, chunk, 4096)
	while (n > 0):
		string_append_bytes(text, chunk, n)
		n = read(child.stdout_fd, chunk, 4096)
	free(chunk)
	close(child.stdout_fd)
	status[0] = process_wait(child)
	process_free(child)
	char* result = strclone(text.data)
	if (stderr_out != 0): stderr_out[0] = strclone(err.data)
	string_free(text)
	string_free(err)
	return result


# bin/wv2 x64 --quiet [flag] [--stats] fixture -o out: the compiler's stderr.
char* is_compile(char* flag, int stats, char* out):
	char** argv = strv_new(9)
	int n = 0
	strv_set(argv, n, c"bin/wv2")
	n = n + 1
	strv_set(argv, n, c"x64")
	n = n + 1
	strv_set(argv, n, c"--quiet")
	n = n + 1
	if (flag != 0):
		strv_set(argv, n, flag)
		n = n + 1
	if (stats):
		strv_set(argv, n, c"--stats")
		n = n + 1
	strv_set(argv, n, c"tests/inline_shadow_fixture.w")
	n = n + 1
	strv_set(argv, n, c"-o")
	n = n + 1
	strv_set(argv, n, out)
	int status = 0
	char* err = 0
	free(is_run(c"bin/wv2", argv, 0, &status, &err))
	free(cast(void*, argv))
	if (status != 0): println2(err)
	assert_equal(0, status)
	return err


char* is_run_fixture(char* binary, char* raw):
	char** argv = strv_new(2)
	strv_set(argv, 0, binary)
	char** env = 0
	if (raw != 0): env = env_copy_with(env_current(), c"W_PROFILE_OUT", raw)
	int status = 0
	char* text = is_run(binary, argv, env, &status, 0)
	assert_equal(0, status)
	free(cast(void*, argv))
	return text


void test_inlined_parameter_does_not_hide_caller_register():
	char* plain = c"bin/inline_shadow_fixture_plain"
	char* instrumented = c"bin/inline_shadow_fixture_gen"
	char* map = c"bin/inline_shadow_fixture_gen.wprofmap"
	char* raw = c"bin/inline_shadow_fixture_gen.wprofraw"
	char* profile = c"bin/inline_shadow_fixture.wprof"
	char* pgo = c"bin/inline_shadow_fixture_pgo"
	free(is_compile(0, 0, plain))
	char* expected = is_run_fixture(plain, 0)
	assert_strings_equal(c"101582528\n", expected)

	free(is_compile(c"--profile-generate", 0, instrumented))
	unlink(raw)
	free(is_run_fixture(instrumented, raw))
	char** argv = strv_new(7)
	strv_set(argv, 0, c"bin/wprof")
	strv_set(argv, 1, c"merge")
	strv_set(argv, 2, c"-o")
	strv_set(argv, 3, profile)
	strv_set(argv, 4, map)
	strv_set(argv, 5, raw)
	int status = 0
	free(is_run(c"bin/wprof", argv, 0, &status, 0))
	assert_equal(0, status)
	free(cast(void*, argv))

	char* use_flag = strjoin(c"--profile-use=", profile)
	char* err = is_compile(use_flag, 1, pgo)
	asserts(c"the hot site of sf_push is inlined", index_of(err, c"inline:   sf_push: sites 1 ") >= 0)
	char* produced = is_run_fixture(pgo, 0)
	assert_strings_equal(expected, produced)
	free(err)
	free(use_flag)
	free(produced)
	free(expected)
