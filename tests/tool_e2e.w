/*
Helpers for tests that spawn a built bin/ tool as a real subprocess
(tests/wvc_e2e_test.w, wvc_sync_e2e_test.w, wvc_pack_e2e_test.w,
wbuildgen_directive_errors_test.w), rather than linking a library and
running in-process.
*/
import lib.assert
import lib.process
import lib.path
import lib.container
import structures.string


char* tool_root_cache


# The checkout root: the test's cwd, captured on first use.
char* tool_root():
	if (tool_root_cache == 0):
		char* buf = malloc(4096)
		assert1(getcwd(buf, 4096) > 0)
		tool_root_cache = buf
	return tool_root_cache


# Absolute bin/<name>. It must be absolute: a spawn with a cwd would
# otherwise resolve it against the NEW cwd (chdir happens before execve
# in process_spawn).
char* tool_bin(char* name):
	return path_join(tool_root(), strjoin(c"bin/", name))


# bin/<prefix><pid>: a scratch path no parallel run shares.
char* tool_scratch(char* prefix):
	string_builder* p = string_new()
	string_append(p, c"bin/")
	string_append(p, prefix)
	string_append_int(p, getpid())
	char* path = p.data
	free(p)
	return path


void tool_rm_rf(char* path):
	char** argv = strv_new(3)
	strv_set(argv, 0, c"/bin/rm")
	strv_set(argv, 1, c"-rf")
	strv_set(argv, 2, path)
	process_result* r = process_run(c"/bin/rm", argv, 0, 0, 10000)
	if (r != 0):
		process_result_free(r)
	free(cast(void*, argv))


# Runs bin/<argv[0]> with argv under cwd (0 inherits) for at most
# timeout_ms, asserting that it spawned. argv is consumed.
process_result* tool_spawn(char* cwd, int timeout_ms, list[char*] argv):
	spawn_options* opts = 0
	if (cwd != 0):
		opts = spawn_options_new()
		opts.cwd = cwd
	char** v = strv_new(argv.length)
	int i = 0
	for char* a in argv:
		strv_set(v, i, a)
		i = i + 1
	process_result* r = process_run(tool_bin(argv[0]), v, opts, 0, timeout_ms)
	assert1(r != 0)
	if (opts != 0):
		free(opts)
	free(cast(void*, v))
	list_free[char*](argv)
	return r


list[char*] tool_argv(char*[] words):
	list[char*] argv = new list[char*]
	for char* w in words:
		argv.push(w)
	return argv


# tool_spawn with a 10 s budget: 'tool_run(0, c"wvc", c"status", dir)'.
process_result* tool_run(char* cwd, char*... argv):
	return tool_spawn(cwd, 10000, tool_argv(argv))


# A run that must exit 0; returns its stdout (owned).
char* tool_ok(char* cwd, char*... argv):
	process_result* r = tool_spawn(cwd, 10000, tool_argv(argv))
	assert_equal(0, r.status)
	char* out = strclone(r.stdout_text)
	process_result_free(r)
	return out


# A fresh copy of s without its trailing '\n' / '\r' characters (a
# tool printing one value per line).
char* trim_eol(char* s):
	char* out = strclone(s)
	int n = strlen(out)
	while ((n > 0) && ((out[n - 1] == 10) || (out[n - 1] == 13))):
		n = n - 1
		out[n] = 0
	return out
