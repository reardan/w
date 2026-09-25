# wbuild: name=verify_warm
# wbuild: tool=tools/wbuildd.w
# wbuild: tool=tools/wexec_main.w
/*
verify_warm: the gate for wbuildd's build RPC (issue #483,
docs/projects/wbuildd.md §8 "Build RPC"). Binaries a build produces
through the daemon must be byte-identical to a cold one-shot build's,
and the run itself must look exactly like 'bin/wexec ARGS' -- the same
stdout, stderr and exit status -- in the way tests/wbuildd_test.w holds
the daemon's query answers to the one-shot commands.

Everything lives in a pid-scoped bin/verify_warm_<pid>/ tree: a root
importing a helper module, a root that does not compile, and a
throwaway manifest (-f) whose targets compile them for x86 and x64,
self-compile the compiler (w.w) into the scratch tree, and run the
result. The daemon is this test's own (--socket in the scratch tree,
--idle-timeout-ms so a failed run cannot leave it behind), and every
daemon run uses --require-daemon, so a silent fallback to the one-shot
path cannot make a comparison vacuous.

Covered: cold (--no-cache) builds, compared output file by output
file; cached runs; a failing target, alone and under --keep-going; the
default manifest (--list, cold and then from the daemon's warm
manifest); an edit inside an import closure, which the warm content
hashes must notice (the rebuilt binary again matches a cold build);
signal forwarding (SIGTERM to the client ends the build child with
wexec's 128+15); and auto-start (a client with no daemon listening
starts one, silently).
*/
import lib.testing
import lib.process
import lib.file
import lib.env
import structures.string
import structures.json
import lib.str


char* vw_dir_cache
char* vw_dir():
	if (vw_dir_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/verify_warm_")
		string_append_int(p, getpid())
		vw_dir_cache = p.data
		free(p)
	return vw_dir_cache


char* vw_path(char* name):
	return strjoin(strjoin(vw_dir(), c"/"), name)


char* vw_module(char* name):
	string_builder* p = string_new()
	string_append(p, c"bin.verify_warm_")
	string_append_int(p, getpid())
	string_append_char(p, '.')
	string_append(p, name)
	char* module = p.data
	free(p)
	return module


list[char*] vw_words(char* text):
	list[char*] words = new list[char*]
	string_builder* word = string_new()
	int i = 0
	while (1):
		int c = text[i]
		if ((c == ' ') || (c == 0)):
			if (word.length > 0):
				words.push(strclone(word.data))
			string_clear(word)
			if (c == 0):
				break
		else:
			string_append_char(word, c)
		i = i + 1
	string_free(word)
	return words


process_result* vw_run_env(list[char*] argv_list, char** env):
	char** v = strv_new(argv_list.length)
	int i = 0
	for char* a in argv_list:
		strv_set(v, i, a)
		i = i + 1
	spawn_options* opts = spawn_options_new()
	opts.env = env
	process_result* result = process_run(argv_list[0], v, opts, 0, 900000)
	assert1(result != 0)
	return result


process_result* vw_run(list[char*] argv_list):
	return vw_run_env(argv_list, 0)


list[char*] vw_client(char* flags, char* args):
	list[char*] argv = new list[char*]
	argv.push(c"bin/wbuildd")
	argv.push(c"--socket")
	argv.push(vw_path(c"d.sock"))
	for char* w in vw_words(flags):
		argv.push(w)
	for char* w in vw_words(args):
		argv.push(w)
	return argv


list[char*] vw_oneshot(char* args):
	list[char*] argv = new list[char*]
	argv.push(c"bin/wexec")
	for char* w in vw_words(args):
		argv.push(w)
	return argv


json_value* vw_status():
	process_result* r = vw_run(vw_client(c"", c"status --json"))
	if (r.status != 0):
		print(r.stderr_text)
	assert_equal(0, r.status)
	json_value* v = json_parse(r.stdout_text)
	assert1(v != 0)
	return v


int vw_status_int(char* key):
	json_value* v = vw_status()
	json_value* field = json_object_get(v, key)
	assert1(field != 0)
	int n = field.int_value
	json_free(v)
	return n


void vw_report(char* what, char* label, char* want, char* got):
	println(c"")
	print(c"MISMATCH (")
	print(what)
	print(c") for: ")
	println(label)
	println(c"--- one-shot:")
	println(want)
	println(c"--- daemon:")
	println(got)


void vw_same_result(char* label, process_result* oneshot, process_result* daemon):
	if (strcmp(oneshot.stdout_text, daemon.stdout_text) != 0):
		vw_report(c"stdout", label, oneshot.stdout_text, daemon.stdout_text)
		asserts(c"daemon build stdout differs from bin/wexec", 0)
	if (strcmp(oneshot.stderr_text, daemon.stderr_text) != 0):
		vw_report(c"stderr", label, oneshot.stderr_text, daemon.stderr_text)
		asserts(c"daemon build stderr differs from bin/wexec", 0)
	if (oneshot.status != daemon.status):
		print_int(c"one-shot status: ", oneshot.status)
		print_int(c"daemon status: ", daemon.status)
		asserts(c"daemon build exit status differs from bin/wexec", 0)


# One-shot first, then the daemon, with nothing changed in between:
# same stdout, stderr and status. Returns the daemon's result.
process_result* vw_compare(char* args):
	print(c"compare: ")
	println(args)
	process_result* oneshot = vw_run(vw_oneshot(args))
	process_result* daemon = vw_run(vw_client(c"--no-autostart --require-daemon", strjoin(c"build ", args)))
	vw_same_result(args, oneshot, daemon)
	process_result_free(oneshot)
	return daemon


# Whole-file byte comparison (binaries hold NULs, so not strcmp).
char* vw_read_bytes(char* path, int* length):
	int fd = open(path, 0, 0)
	if (fd < 0):
		print(c"cannot open ")
		println(path)
		asserts(c"missing build output", 0)
	string_builder* s = string_new()
	char* buf = malloc(65536)
	int n = read(fd, buf, 65536)
	while (n > 0):
		string_append_bytes(s, buf, n)
		n = read(fd, buf, 65536)
	free(buf)
	close(fd)
	*length = s.length
	char* data = s.data
	free(s)
	return data


void vw_assert_same_file(char* cold, char* warm):
	int cold_length = 0
	int warm_length = 0
	char* a = vw_read_bytes(cold, &cold_length)
	char* b = vw_read_bytes(warm, &warm_length)
	int same = cold_length == warm_length
	int i = 0
	while (same && (i < cold_length)):
		if (a[i] != b[i]):
			same = 0
		i = i + 1
	if (same == 0):
		print(c"differs from the cold build: ")
		println(warm)
		asserts(c"daemon-built binary is not byte-identical to the cold build", 0)
	free(a)
	free(b)


char* vw_outputs():
	return c"a a64 wv_self"


# Moves every output aside as <name>.cold.
void vw_stash_cold():
	for char* name in vw_words(vw_outputs()):
		char* cold = strjoin(vw_path(name), c".cold")
		unlink(cold)
		assert_equal(0, rename(vw_path(name), cold))


void vw_assert_outputs_match_cold():
	for char* name in vw_words(vw_outputs()):
		vw_assert_same_file(strjoin(vw_path(name), c".cold"), vw_path(name))


void vw_write(char* name, char* text):
	assert1(file_write_text(vw_path(name), text))


char* vw_a_source():
	return strjoin(strjoin(c"import ", vw_module(c"helper")), c"\n\n\nint main():\n\tprintln(helper())\n\treturn 0\n")


# JSON array text of one step's argv: "[\"bin/wv2\", ...]".
char* vw_cmd(char* words):
	string_builder* s = string_new()
	string_append_char(s, '[')
	int first = 1
	for char* w in vw_words(words):
		if (first == 0):
			string_append(s, c", ")
		first = 0
		string_append_char(s, '"')
		string_append(s, w)
		string_append_char(s, '"')
	string_append_char(s, ']')
	char* text = s.data
	free(s)
	return text


char* vw_target(char* name, char* inputs, char* output, char* steps):
	string_builder* s = string_new()
	string_append(s, c"\t\t{\"name\": \"")
	string_append(s, name)
	string_append(s, c"\", \"inputs\": [\"")
	string_append(s, inputs)
	string_append(s, c"\"], \"outputs\": [\"")
	string_append(s, output)
	string_append(s, c"\"], \"steps\": [")
	string_append(s, steps)
	string_append(s, c"]},\n")
	char* text = s.data
	free(s)
	return text


char* vw_step(char* words):
	return strjoin(strjoin(c"{\"cmd\": ", vw_cmd(words)), c"}")


char* vw_manifest():
	char* a = vw_path(c"a")
	string_builder* s = string_new()
	string_append(s, c"{\n\t\"dirs\": [\"bin\"],\n\t\"targets\": [\n")
	string_append(s, vw_target(c"vw_a", vw_path(c"a.w"), a, strjoin(strjoin(vw_step(strjoin(strjoin(strjoin(c"bin/wv2 ", vw_path(c"a.w")), c" -o "), a)), c", "), strjoin(strjoin(c"{\"cmd\": [\"", a), c"\"], \"expect_stdout\": \"helped\"}"))))
	string_append(s, vw_target(c"vw_a64", vw_path(c"a.w"), vw_path(c"a64"), vw_step(strjoin(strjoin(strjoin(c"bin/wv2 x64 ", vw_path(c"a.w")), c" -o "), vw_path(c"a64")))))
	string_append(s, vw_target(c"vw_self", c"w.w", vw_path(c"wv_self"), vw_step(strjoin(c"bin/wv2 --strict w.w -o ", vw_path(c"wv_self")))))
	string_append(s, vw_target(c"vw_bad", vw_path(c"bad.w"), vw_path(c"bad"), vw_step(strjoin(strjoin(strjoin(c"bin/wv2 ", vw_path(c"bad.w")), c" -o "), vw_path(c"bad")))))
	string_append(s, c"\t\t{\"name\": \"vw_sleep\", \"steps\": [{\"cmd\": [\"sleep\", \"60\"]}]},\n")
	string_append(s, c"\t\t{\"name\": \"vw_all\", \"deps\": [\"vw_a\", \"vw_a64\", \"vw_self\"], \"steps\": []}\n")
	string_append(s, c"\t]\n}\n")
	char* text = s.data
	free(s)
	return text


# After the --list runs the daemon holds a warm manifest and warm
# hashes. Under a parallel './wbuild tests' another target editing a
# source outside bin/ legitimately drops the manifest in between, so a
# cold answer is retried a few times before it counts as a failure.
void vw_expect_warm():
	for attempt in range(10):
		json_value* status = vw_status()
		int warm = json_object_get(status, c"warm_manifest").int_value && (json_object_get(status, c"warm_hashes").int_value > 0)
		json_free(status)
		if (warm):
			return
		process_result_free(vw_run(vw_client(c"--no-autostart --require-daemon", strjoin(strjoin(c"build -f ", vw_path(c"manifest.json")), c" -j 1 vw_a"))))
		process_result_free(vw_run(vw_client(c"--no-autostart --require-daemon", c"build --list")))
	asserts(c"the daemon never kept a warm manifest and warm hashes", 0)


void vw_cleanup():
	char* names = c"a.w bad.w helper.w manifest.json log d.sock d.sock.log a a64 wv_self bad a.cold a64.cold wv_self.cold"
	for char* name in vw_words(names):
		unlink(vw_path(name))
	rmdir(vw_dir())


void vw_start_daemon():
	string_builder* start = string_new()
	string_append(start, c"start --no-prewarm --log ")
	string_append(start, vw_path(c"log"))
	string_append(start, c" --idle-timeout-ms 300000")
	process_result* started = vw_run(vw_client(c"", start.data))
	if (started.status != 0):
		print(started.stderr_text)
		print(file_read_text(vw_path(c"log")))
	assert_equal(0, started.status)
	process_result_free(started)


void vw_stop_daemon():
	process_result* stopped = vw_run(vw_client(c"", c"stop"))
	assert_equal(0, stopped.status)
	process_result_free(stopped)


void test_verify_warm():
	vw_cleanup()
	assert_equal(0, mkdir(vw_dir(), 493))
	vw_write(c"helper.w", c"char* helper():\n\treturn c\"helped\"\n")
	vw_write(c"a.w", vw_a_source())
	vw_write(c"bad.w", c"int main(:\n")
	vw_write(c"manifest.json", vw_manifest())
	char* m = strjoin(c"-f ", vw_path(c"manifest.json"))
	vw_start_daemon()

	# Cold: every target runs; the binaries must match byte for byte.
	process_result* one = vw_run(vw_oneshot(strjoin(m, c" --no-cache -j 1 vw_all")))
	vw_stash_cold()
	process_result* two = vw_run(vw_client(c"--no-autostart --require-daemon", strjoin(strjoin(c"build ", m), c" --no-cache -j 1 vw_all")))
	vw_same_result(c"cold vw_all", one, two)
	assert_equal(0, two.status)
	vw_assert_outputs_match_cold()

	# Cached: both sides see the stamps the runs above left.
	process_result_free(vw_compare(strjoin(m, c" -j 1 vw_all")))
	process_result_free(vw_compare(strjoin(m, c" -j 1 vw_all")))

	# Failures, alone and under --keep-going.
	process_result* bad = vw_compare(strjoin(m, c" vw_bad"))
	assert1(bad.status != 0)
	process_result_free(vw_compare(strjoin(m, c" -j 1 --keep-going vw_bad vw_a")))

	# The default manifest: generated cold by the first daemon build,
	# then served warm.
	process_result_free(vw_compare(c"--list"))
	process_result_free(vw_compare(c"--list"))
	vw_expect_warm()

	# An edit inside a.w's closure: the daemon's warm hashes must not
	# hide it -- vw_a and vw_a64 rebuild, and match a cold build of the
	# edited sources.
	vw_write(c"helper.w", c"char* helper():\n\treturn c\"helped again\"\n")
	process_result* edited = vw_run(vw_client(c"--no-autostart --require-daemon", strjoin(strjoin(c"build ", m), c" -j 1 vw_all")))
	assert_equal(0, edited.status)
	assert1(contains(edited.stdout_text, c"wexec: target vw_a\n"))
	assert1(contains(edited.stdout_text, c"wexec: target vw_a64\n"))
	assert1(contains(edited.stdout_text, c"wexec: target vw_self (cached)"))
	process_result* recheck = vw_compare(strjoin(m, c" -j 1 vw_all"))
	assert_equal(0, recheck.status)
	process_result* cold_edit = vw_run(vw_oneshot(strjoin(m, c" --no-cache -j 1 vw_all")))
	assert_equal(0, cold_edit.status)
	vw_stash_cold()
	process_result_free(vw_run(vw_client(c"--no-autostart --require-daemon", strjoin(strjoin(c"build ", m), c" -j 1 --no-cache vw_all"))))
	vw_assert_outputs_match_cold()

	# SIGTERM to the client reaches the build child: wexec's handler
	# ends the build with 128+15, as a one-shot run exits.
	list[char*] sleeper = vw_client(c"--no-autostart --require-daemon", strjoin(strjoin(c"build ", m), c" vw_sleep"))
	char** v = strv_new(sleeper.length)
	int i = 0
	for char* a in sleeper:
		strv_set(v, i, a)
		i = i + 1
	spawn_options* quiet = spawn_options_new()
	quiet.stdout_mode = process_null
	quiet.stderr_mode = process_null
	process* client = process_spawn(sleeper[0], v, quiet)
	assert1(client != 0)
	int waited = 0
	while ((vw_status_int(c"builds_active") == 0) && (waited < 30000)):
		process_sleep_ms(50)
		waited = waited + 50
	assert_equal(1, vw_status_int(c"builds_active"))
	process_kill(client, 15)
	assert_equal(143, process_wait(client))
	assert_equal(0, vw_status_int(c"builds_active"))

	vw_stop_daemon()

	# Auto-start: no daemon listens, and a plain client starts one
	# without printing anything of its own.
	char** env = env_copy_with(env_current(), c"WBUILDD_PREWARM", c"0")
	env = env_copy_with(env, c"WBUILDD_IDLE_TIMEOUT_MS", c"300000")
	process_result* auto_one = vw_run(vw_oneshot(strjoin(m, c" -j 1 vw_a")))
	process_result* auto_two = vw_run_env(vw_client(c"", strjoin(strjoin(c"build ", m), c" -j 1 vw_a")), env)
	vw_same_result(c"auto-start", auto_one, auto_two)
	assert1(vw_status_int(c"builds") >= 1)
	vw_stop_daemon()
	vw_cleanup()
