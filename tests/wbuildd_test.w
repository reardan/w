/*
tools/wbuildd.w end-to-end: the verify gate for the daemon's read-only
milestone (docs/projects/wbuildd.md "Decisions", item 4). Every
daemon-served answer must be byte-identical -- stdout, stderr and exit
status -- to the one-shot command it stands in for:

	bin/wbuildd check ...    vs  bin/wv2 check ...
	bin/wbuildd deps ...     vs  bin/wv2 deps ...
	bin/wbuildd symbols ...  vs  bin/wv2 symbols ...
	bin/wbuildd changed ...  vs  bin/wtest changed ...

The client runs with --require-daemon, so a silent fallback to the
one-shot path (which would make the comparison vacuous) fails the test
instead. Inputs live in a pid-scoped bin/wbuildd_test_<pid>/ tree: a
root importing a helper module, a root with a warning, a root with a
syntax error, plus a throwaway wtest manifest compiling two of them
(the "-f" isolation trick tests/wtest/ uses, so bin/wtest never reads
the real build.json). Each comparison runs twice (the second answer is
served from the daemon's memo, which status --json must show as hits),
then the files are EDITED -- a warning appears in the imported helper,
the root stops importing it, a module is created and one deleted -- and
every comparison is repeated, which is what exercises the inotify
invalidation: a stale memo would still answer with the pre-edit bytes.
Lifecycle is covered too: start (with the test_changed prewarm pointed
at the scratch manifest), status, stop, and the fallback path once the
daemon is gone. The daemon runs with --idle-timeout-ms, so a failed
run cannot leave it behind.
*/
# wbuild: tool=tools/wbuildd.w
# wbuild: tool=tools/test_map.w
import lib.testing
import lib.process
import lib.file
import structures.string
import structures.json


char* wbt_dir_cache
char* wbt_dir():
	if (wbt_dir_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/wbuildd_test_")
		string_append_int(p, getpid())
		wbt_dir_cache = p.data
		free(p)
	return wbt_dir_cache


char* wbt_path(char* name):
	string_builder* p = string_new()
	string_append(p, wbt_dir())
	string_append_char(p, '/')
	string_append(p, name)
	char* path = p.data
	free(p)
	return path


# The dotted module name of a scratch file (import bin.wbuildd_test_N.x).
char* wbt_module(char* name):
	string_builder* p = string_new()
	string_append(p, c"bin.wbuildd_test_")
	string_append_int(p, getpid())
	string_append_char(p, '.')
	string_append(p, name)
	char* module = p.data
	free(p)
	return module


void wbt_write(char* name, char* text):
	assert1(file_write_text(wbt_path(name), text))


list[char*] wbt_words(char* text):
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


process_result* wbt_run(list[char*] argv_list, char* stdin_text):
	char** v = strv_new(argv_list.length)
	int i = 0
	for char* a in argv_list:
		strv_set(v, i, a)
		i = i + 1
	process_result* result = process_run(argv_list[0], v, 0, stdin_text, 600000)
	assert1(result != 0)
	return result


list[char*] wbt_client(char* args):
	list[char*] argv = new list[char*]
	argv.push(c"bin/wbuildd")
	argv.push(c"--socket")
	argv.push(wbt_path(c"d.sock"))
	for char* w in wbt_words(args):
		argv.push(w)
	return argv


process_result* wbt_client_run(char* args):
	return wbt_run(wbt_client(args), 0)


json_value* wbt_status():
	process_result* r = wbt_client_run(c"status --json")
	if (r.status != 0):
		print(r.stderr_text)
	assert_equal(0, r.status)
	json_value* v = json_parse(r.stdout_text)
	assert1(v != 0)
	return v


int wbt_status_int(char* key):
	json_value* v = wbt_status()
	json_value* field = json_object_get(v, key)
	assert1(field != 0)
	int n = field.int_value
	json_free(v)
	return n


# bin/wtest shares bin/.wtest_deps_cache with the daemon's background
# prewarm; comparisons wait for it so the cache file has one writer.
void wbt_wait_prewarm_idle():
	int waited = 0
	while (waited < 300000):
		json_value* v = wbt_status()
		json_value* state = json_object_get(v, c"prewarm")
		int idle = strcmp(state.string_value, c"idle") == 0
		json_free(v)
		if (idle):
			return
		process_sleep_ms(100)
		waited = waited + 100
	asserts(c"prewarm never went idle", 0)


void wbt_report(char* what, char* label, char* want, char* got):
	println(c"")
	print(c"MISMATCH (")
	print(what)
	print(c") for: ")
	println(label)
	println(c"--- one-shot:")
	println(want)
	println(c"--- daemon:")
	println(got)


# The gate: daemon answer == one-shot answer, byte for byte. tool is
# "bin/wv2" or "bin/wtest"; args start with the subcommand word, which
# is the same for both sides (check/deps/symbols/changed). Returns the
# daemon's stdout (owned) so callers can assert that edits changed it.
char* wbt_compare(char* tool, char* args, char* stdin_text):
	if (strcmp(tool, c"bin/wtest") == 0):
		wbt_wait_prewarm_idle()
		# Settle bin/.wtest_deps_cache first: a cold root prints
		# timing-dependent progress lines to stderr on whichever side
		# happens to compute it.
		list[char*] warm = new list[char*]
		warm.push(tool)
		for char* w in wbt_words(args):
			warm.push(w)
		process_result_free(wbt_run(warm, stdin_text))
	list[char*] daemon_argv = wbt_client(strjoin(c"--require-daemon ", args))
	process_result* daemon = wbt_run(daemon_argv, stdin_text)
	list[char*] oneshot_argv = new list[char*]
	oneshot_argv.push(tool)
	for char* w in wbt_words(args):
		oneshot_argv.push(w)
	process_result* oneshot = wbt_run(oneshot_argv, stdin_text)
	print(c"compare: ")
	println(args)
	if (strcmp(oneshot.stdout_text, daemon.stdout_text) != 0):
		wbt_report(c"stdout", args, oneshot.stdout_text, daemon.stdout_text)
		asserts(c"daemon stdout differs from the one-shot command", 0)
	if (strcmp(oneshot.stderr_text, daemon.stderr_text) != 0):
		wbt_report(c"stderr", args, oneshot.stderr_text, daemon.stderr_text)
		asserts(c"daemon stderr differs from the one-shot command", 0)
	if (oneshot.status != daemon.status):
		print_int(c"one-shot status: ", oneshot.status)
		print_int(c"daemon status: ", daemon.status)
		asserts(c"daemon exit status differs from the one-shot command", 0)
	char* out = strclone(daemon.stdout_text)
	process_result_free(daemon)
	process_result_free(oneshot)
	return out


int wbt_prefix(char* text, char* prefix, int n):
	int i = 0
	while (i < n):
		if (text[i] != prefix[i]):
			return 0
		i = i + 1
	return 1


int wbt_has_line(char* text, char* line):
	int n = strlen(line)
	int i = 0
	int at_start = 1
	while (text[i] != 0):
		if (at_start && wbt_prefix(text + i, line, n) && ((text[i + n] == 10) || (text[i + n] == 0))):
			return 1
		at_start = text[i] == 10
		i = i + 1
	return 0


char* wbt_args2(char* prefix, char* name):
	return strjoin(prefix, wbt_path(name))


# Every query shape the milestone serves, one comparison each.
void wbt_compare_all():
	wbt_compare(c"bin/wv2", wbt_args2(c"check --json ", c"a.w"), 0)
	wbt_compare(c"bin/wv2", wbt_args2(c"check --json ", c"b.w"), 0)
	wbt_compare(c"bin/wv2", wbt_args2(c"check --json ", c"c.w"), 0)
	wbt_compare(c"bin/wv2", wbt_args2(c"check --json x64 ", c"a.w"), 0)
	wbt_compare(c"bin/wv2", wbt_args2(c"deps ", c"a.w"), 0)
	wbt_compare(c"bin/wv2", wbt_args2(c"deps --json ", c"a.w"), 0)
	wbt_compare(c"bin/wv2", wbt_args2(c"deps x64 ", c"a.w"), 0)
	wbt_compare(c"bin/wv2", wbt_args2(c"deps ", c"c.w"), 0)
	wbt_compare(c"bin/wv2", wbt_args2(c"symbols --json ", c"a.w"), 0)
	char* manifest_flag = strjoin(c"changed -f ", wbt_path(c"manifest.json"))
	wbt_compare(c"bin/wtest", strjoin(manifest_flag, strjoin(c" ", wbt_path(c"helper.w"))), 0)
	wbt_compare(c"bin/wtest", strjoin(manifest_flag, strjoin(c" ", wbt_path(c"b.w"))), 0)
	# No positional paths: the list arrives on stdin, as from
	# 'git diff --name-only HEAD | ...'.
	wbt_compare(c"bin/wtest", manifest_flag, strjoin(wbt_path(c"helper.w"), c"\n"))


# A repeated query must be answered from the memo. Under a parallel
# './wbuild tests' another target creating a .w file anywhere in the
# tree legitimately clears the whole memo between two queries, so a
# miss is retried a few times before it counts as a failure.
void wbt_expect_memo_hit():
	char* args = strjoin(c"--require-daemon ", wbt_args2(c"check --json ", c"a.w"))
	int attempt = 0
	while (attempt < 10):
		process_result_free(wbt_client_run(args))
		int before = wbt_status_int(c"hits")
		process_result_free(wbt_client_run(args))
		if (wbt_status_int(c"hits") > before):
			assert1(wbt_status_int(c"cached_entries") > 0)
			return
		attempt = attempt + 1
	asserts(c"a repeated query was never answered from the memo", 0)


char* wbt_a_importing():
	string_builder* s = string_new()
	string_append(s, c"import ")
	string_append(s, wbt_module(c"helper"))
	string_append(s, c"\n\n\nint main():\n\treturn helper()\n")
	char* text = s.data
	free(s)
	return text


char* wbt_manifest():
	string_builder* s = string_new()
	string_append(s, c"{\n\t\"dirs\": [\"bin\"],\n\t\"targets\": [\n")
	string_append(s, c"\t\t{\"name\": \"wexec_test\", \"steps\": [{\"cmd\": [\"true\"]}]},\n")
	string_append(s, c"\t\t{\"name\": \"manifest_check\", \"steps\": [{\"cmd\": [\"true\"]}]},\n")
	string_append(s, c"\t\t{\"name\": \"wbt_a\", \"deps\": [\"wv2\"], \"steps\": [{\"cmd\": [\"bin/wv2\", \"")
	string_append(s, wbt_path(c"a.w"))
	string_append(s, c"\", \"-o\", \"")
	string_append(s, wbt_path(c"a"))
	string_append(s, c"\"]}]},\n")
	string_append(s, c"\t\t{\"name\": \"wbt_b\", \"deps\": [\"wv2\"], \"steps\": [{\"cmd\": [\"bin/wv2\", \"")
	string_append(s, wbt_path(c"b.w"))
	string_append(s, c"\", \"-o\", \"")
	string_append(s, wbt_path(c"b"))
	string_append(s, c"\"]}]},\n")
	string_append(s, c"\t\t{\"name\": \"tests\", \"deps\": [\"wbt_a\", \"wbt_b\"]}\n")
	string_append(s, c"\t]\n}\n")
	char* text = s.data
	free(s)
	return text


void wbt_cleanup():
	char* names = c"a.w b.w c.w d.w helper.w manifest.json log d.sock a b"
	for char* name in wbt_words(names):
		unlink(wbt_path(name))
	rmdir(wbt_dir())


void test_wbuildd_matches_one_shot():
	wbt_cleanup()
	assert_equal(0, mkdir(wbt_dir(), 493))
	wbt_write(c"helper.w", c"int helper():\n\treturn 0\n")
	wbt_write(c"a.w", wbt_a_importing())
	wbt_write(c"b.w", c"int main():\n\tchar* s = c\"x\"\n\tint* q = s\n\treturn 0\n")
	wbt_write(c"c.w", c"int main(:\n")
	wbt_write(c"manifest.json", wbt_manifest())

	# Nothing listens yet: --require-daemon refuses, plain falls back.
	process_result* refused = wbt_client_run(strjoin(c"--require-daemon check --json ", wbt_path(c"a.w")))
	assert_equal(2, refused.status)
	process_result_free(refused)
	process_result* down = wbt_client_run(c"status")
	assert_equal(1, down.status)
	process_result_free(down)

	string_builder* start = string_new()
	string_append(start, c"start --prewarm-manifest ")
	string_append(start, wbt_path(c"manifest.json"))
	string_append(start, c" --log ")
	string_append(start, wbt_path(c"log"))
	string_append(start, c" --idle-timeout-ms 120000")
	process_result* started = wbt_client_run(start.data)
	if (started.status != 0):
		print(started.stderr_text)
		print(file_read_text(wbt_path(c"log")))
	assert_equal(0, started.status)
	process_result_free(started)

	# Round 1 fills the memo; round 2 must be answered from it.
	wbt_compare_all()
	int hits_before = wbt_status_int(c"hits")
	wbt_compare_all()
	int hits_after = wbt_status_int(c"hits")
	print_int(c"memo hits in round 2: ", hits_after - hits_before)
	wbt_expect_memo_hit()

	# Edit a module in a.w's closure: the memoized check of a.w must be
	# invalidated (it now carries the helper's new warning).
	char* a_check_args = wbt_args2(c"check --json ", c"a.w")
	char* before_edit = wbt_compare(c"bin/wv2", a_check_args, 0)
	int invalidations_before = wbt_status_int(c"invalidations")
	wbt_write(c"helper.w", c"int helper():\n\treturn 0\n\n\nvoid helper2(char* s):\n\tint* q = s\n")
	char* after_edit = wbt_compare(c"bin/wv2", a_check_args, 0)
	assert1(strcmp(before_edit, after_edit) != 0)
	assert1(wbt_status_int(c"invalidations") > invalidations_before)
	wbt_compare_all()

	# The root stops importing the helper (a content edit, not a
	# create/delete): deps and the changed-selection both move.
	char* changed_helper = strjoin(c"changed -f ", strjoin(wbt_path(c"manifest.json"), strjoin(c" ", wbt_path(c"helper.w"))))
	char* deps_before = wbt_compare(c"bin/wv2", wbt_args2(c"deps ", c"a.w"), 0)
	char* selected_before = wbt_compare(c"bin/wtest", changed_helper, 0)
	wbt_write(c"a.w", c"int main():\n\treturn 0\n")
	char* deps_after = wbt_compare(c"bin/wv2", wbt_args2(c"deps ", c"a.w"), 0)
	char* selected_after = wbt_compare(c"bin/wtest", changed_helper, 0)
	assert1(strcmp(deps_before, deps_after) != 0)
	# Rule (b) closure selection really ran: wbt_a compiled a.w, whose
	# closure contained the helper until the edit.
	assert1(wbt_has_line(selected_before, c"wbt_a"))
	assert1(wbt_has_line(selected_after, c"wbt_a") == 0)
	wbt_compare_all()

	# A new module and a deleted one (resolution-changing events).
	wbt_write(c"d.w", c"int main():\n\treturn 1\n")
	wbt_compare(c"bin/wv2", wbt_args2(c"check --json ", c"d.w"), 0)
	unlink(wbt_path(c"helper.w"))
	wbt_compare_all()

	wbt_wait_prewarm_idle()
	assert1(wbt_status_int(c"prewarm_runs") >= 1)

	process_result* stopped = wbt_client_run(c"stop")
	assert_equal(0, stopped.status)
	process_result_free(stopped)
	process_result* gone = wbt_client_run(c"status")
	assert_equal(1, gone.status)
	process_result_free(gone)
	assert1(file_read_text(wbt_path(c"d.sock")) == 0)

	# With the daemon gone the client is the one-shot command.
	list[char*] fallback = wbt_client(wbt_args2(c"check --json ", c"b.w"))
	process_result* via_client = wbt_run(fallback, 0)
	list[char*] direct_argv = new list[char*]
	direct_argv.push(c"bin/wv2")
	for char* w in wbt_words(wbt_args2(c"check --json ", c"b.w")):
		direct_argv.push(w)
	process_result* direct = wbt_run(direct_argv, 0)
	assert_strings_equal(direct.stdout_text, via_client.stdout_text)
	assert_strings_equal(direct.stderr_text, via_client.stderr_text)
	assert_equal(direct.status, via_client.status)
	wbt_cleanup()
