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
the real manifest). Each comparison runs twice (the second answer is
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
# wbuild: tool=tools/wexec_main.w
# The daemon exits when bin/wexec is replaced. Finish that build before
# starting it, including when a shard schedules wexec independently.
import lib.testing
import lib.process
import lib.file
import structures.string
import structures.json
import lib.str


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
			if (word.length > 0): words.push(strclone(word.data))
			string_clear(word)
			if (c == 0): break
		else: string_append_char(word, c)
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
	# The daemon's lifecycle is this test's to drive (start/stop, and
	# the fallback once it is gone); tests/wbuildd_build_test.w covers
	# auto-start.
	argv.push(c"--no-autostart")
	for char* w in wbt_words(args): argv.push(w)
	return argv


process_result* wbt_client_run(char* args):
	return wbt_run(wbt_client(args), 0)


json_value* wbt_status():
	process_result* r = wbt_client_run(c"status --json")
	if (r.status != 0): print(r.stderr_text)
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
	for waited in range(0, 300000, 100):
		json_value* v = wbt_status()
		json_value* state = json_object_get(v, c"prewarm")
		int idle = strcmp(state.string_value, c"idle") == 0
		json_free(v)
		if (idle): return
		process_sleep_ms(100)
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
	println(c"--- daemon log:")
	println(file_read_text(wbt_path(c"log")))


# stderr minus bin/wtest's import-closure cache progress lines ("wtest:
# building import-closure cache..." and "wtest: import-closure cache:
# N/M roots computed..."). Whether a root is cold depends on timing, not
# on the answer: the daemon's own prewarm (bin/wtest cache) can rewrite
# bin/.wtest_deps_cache between the warm-up below and the compared runs,
# because an edit's inotify event can reach the daemon after
# wbt_wait_prewarm_idle has already seen it idle. Every other stderr
# byte is still compared.
char* wbt_stderr_without_cache_progress(char* text):
	string_builder* out = string_new()
	int i = 0
	while (text[i] != 0):
		int end = i
		while ((text[end] != 0) && (text[end] != 10)): end = end + 1
		char* line = &text[i]
		int progress = starts_with(line, c"wtest: building import-closure cache") || starts_with(line, c"wtest: import-closure cache: ")
		if (progress == 0):
			for k in range(i, end): string_append_char(out, text[k])
			if (text[end] == 10): string_append_char(out, 10)
		if (text[end] == 10): end = end + 1
		i = end
	return out.data


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
		for char* w in wbt_words(args): warm.push(w)
		process_result_free(wbt_run(warm, stdin_text))
	list[char*] daemon_argv = wbt_client(strjoin(c"--require-daemon ", args))
	process_result* daemon = wbt_run(daemon_argv, stdin_text)
	list[char*] oneshot_argv = new list[char*]
	oneshot_argv.push(tool)
	for char* w in wbt_words(args): oneshot_argv.push(w)
	process_result* oneshot = wbt_run(oneshot_argv, stdin_text)
	print(c"compare: ")
	println(args)
	if (strcmp(oneshot.stdout_text, daemon.stdout_text) != 0):
		wbt_report(c"stdout", args, oneshot.stdout_text, daemon.stdout_text)
		asserts(c"daemon stdout differs from the one-shot command", 0)
	char* want_err = oneshot.stderr_text
	char* got_err = daemon.stderr_text
	if (strcmp(tool, c"bin/wtest") == 0):
		want_err = wbt_stderr_without_cache_progress(want_err)
		got_err = wbt_stderr_without_cache_progress(got_err)
	if (strcmp(want_err, got_err) != 0):
		wbt_report(c"stderr", args, want_err, got_err)
		asserts(c"daemon stderr differs from the one-shot command", 0)
	if (oneshot.status != daemon.status):
		print_int(c"one-shot status: ", oneshot.status)
		print_int(c"daemon status: ", daemon.status)
		asserts(c"daemon exit status differs from the one-shot command", 0)
	char* out = strclone(daemon.stdout_text)
	process_result_free(daemon)
	process_result_free(oneshot)
	return out


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
	for attempt in range(10):
		process_result_free(wbt_client_run(args))
		int before = wbt_status_int(c"hits")
		process_result_free(wbt_client_run(args))
		if (wbt_status_int(c"hits") > before):
			assert1(wbt_status_int(c"cached_entries") > 0)
			return
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


# The import shadowing case needs a top-level directory: an import of
# wbuildd_shadow_<pid>.m resolves to bin/wbuildd_shadow_<pid>/m.w (the
# compiler's fallback search root) until the same path appears at the
# checkout root.
char* wbt_shadow_dir(char* top):
	string_builder* p = string_new()
	string_append(p, top)
	string_append(p, c"wbuildd_shadow_")
	string_append_int(p, getpid())
	char* dir = p.data
	free(p)
	return dir


void wbt_cleanup():
	char* names = c"a.w b.w c.w d.w helper.w manifest.json log d.sock a b g1.w g2.w g3.w gh.w gh.w.tmp e.w s.w"
	for char* name in wbt_words(names): unlink(wbt_path(name))
	unlink(wbt_path(c"sub/x.w"))
	unlink(wbt_path(c"sub2/x.w"))
	rmdir(wbt_path(c"sub"))
	rmdir(wbt_path(c"sub2"))
	rmdir(wbt_dir())
	for char* top in wbt_words(c"bin/ ./"):
		char* dir = wbt_shadow_dir(top)
		unlink(strjoin(dir, c"/m.w"))
		rmdir(dir)


char* wbt_status_string(char* key):
	json_value* v = wbt_status()
	json_value* field = json_object_get(v, key)
	assert1((field != 0) && (field.type == json_type_string()))
	char* text = strclone(field.string_value)
	json_free(v)
	return text


# The background re-check is done (and nothing is queued).
void wbt_wait_refresh_idle():
	for waited in range(0, 300000, 20):
		if (strcmp(wbt_status_string(c"refresh"), c"idle") == 0): return
		process_sleep_ms(20)
	asserts(c"the re-check never went idle", 0)


char* wbt_importing(char* module, char* body):
	string_builder* s = string_new()
	string_append(s, c"import ")
	string_append(s, module)
	string_append(s, c"\n")
	string_append(s, body)
	char* text = s.data
	free(s)
	return text


# A save the way many editors do it: a temporary file renamed over the
# original (IN_MOVED_TO, not a modification).
void wbt_save_by_rename(char* name, char* text):
	char* tmp = strjoin(name, c".tmp")
	wbt_write(tmp, text)
	assert_equal(0, rename(wbt_path(tmp), wbt_path(name)))


# Does the memoized answer of a query survive an event? Another target
# of a parallel './wbuild tests' can legitimately drop the whole memo
# (a rebuilt bin/wv2, a C header): such an attempt is retried, while a
# regression (an event dropping answers that never read what it
# touched) fails every attempt.
void wbt_expect_kept(char* query, char* event_name, char* event_text):
	char* args = strjoin(c"--require-daemon ", query)
	for attempt in range(10):
		process_result_free(wbt_client_run(args))
		int clears = wbt_status_int(c"memo_clears")
		int invalidations = wbt_status_int(c"invalidations")
		int hits = wbt_status_int(c"hits")
		if (event_text != 0): wbt_write(event_name, event_text)
		else: unlink(wbt_path(event_name))
		process_result_free(wbt_client_run(args))
		if (wbt_status_int(c"memo_clears") != clears): continue
		assert_equal(invalidations, wbt_status_int(c"invalidations"))
		assert_equal(hits + 1, wbt_status_int(c"hits"))
		return
	asserts(c"the memo was dropped on every attempt", 0)


# The memo's module graph (compiler/module_graph.w): an edit drops only
# the answers that read what it touched, whatever kind of event it is,
# and those answers are re-checked in the background.
void wbt_graph_invalidation():
	char* g1 = wbt_path(c"g1.w")
	char* g2 = wbt_path(c"g2.w")
	char* check_g1 = wbt_args2(c"check --json ", c"g1.w")
	char* check_g2 = wbt_args2(c"check --json ", c"g2.w")
	wbt_write(c"gh.w", c"int gh():\n\treturn 0\n")
	# tools.wexec makes g1's check slow enough to catch its re-check
	# running.
	wbt_write(c"g1.w", wbt_importing(wbt_module(c"gh"), c"import tools.wexec\n\n\nint main():\n\treturn gh()\n"))
	wbt_write(c"g2.w", c"int main():\n\treturn 2\n")
	wbt_compare(c"bin/wv2", check_g1, 0)
	wbt_compare(c"bin/wv2", check_g2, 0)

	# 'affected' answers from the graph: g1's answers read gh.w, g2's did not.
	process_result* affected = wbt_client_run(strjoin(c"affected ", wbt_path(c"gh.w")))
	assert_equal(0, affected.status)
	print(c"affected by gh.w:\n")
	print(affected.stdout_text)
	assert1(has_line(affected.stdout_text, strjoin(c"check --json ", g1)))
	assert1(has_line(affected.stdout_text, strjoin(c"deps ", g1)))
	assert1(contains(affected.stdout_text, g2) == 0)
	process_result_free(affected)

	# A module created, then deleted, that no answer read drops nothing
	# (it used to drop the whole memo).
	wbt_expect_kept(check_g2, c"e.w", c"int e():\n\treturn 0\n")
	wbt_expect_kept(check_g2, c"e.w", 0)

	# A save by rename drops g1's answer only; the answer changes.
	char* before = wbt_compare(c"bin/wv2", check_g1, 0)
	wbt_save_by_rename(c"gh.w", c"int gh():\n\treturn 0\n\n\nvoid gh_warn(char* s):\n\tint* q = s\n")
	char* after = wbt_compare(c"bin/wv2", check_g1, 0)
	assert1(strcmp(before, after) != 0)
	wbt_expect_kept(check_g2, c"e.w", c"int e():\n\treturn 1\n")

	# The re-check: after an edit, g1's next query is answered from a
	# memo the daemon refilled in the background.
	int stored = 0
	for attempt in range(10):
		int refreshed = wbt_status_int(c"refreshed")
		wbt_write(c"gh.w", c"int gh():\n\treturn 1\n")
		wbt_wait_refresh_idle()
		if (wbt_status_int(c"refreshed") == refreshed): continue
		int hits = wbt_status_int(c"hits")
		wbt_compare(c"bin/wv2", check_g1, 0)
		if (wbt_status_int(c"hits") > hits):
			stored = 1
			break
	assert1(stored)

	# An edit landing while that re-check runs overtakes it: the run is
	# discarded and redone, never stored with what it read before.
	int caught = 0
	for attempt in range(10):
		if (caught): break
		int discarded = wbt_status_int(c"refresh_discarded")
		wbt_write(c"gh.w", c"int gh():\n\treturn 2\n")
		for waited in range(0, 5000, 5):
			if (strcmp(wbt_status_string(c"refresh"), c"running") == 0):
				wbt_write(c"gh.w", c"int gh():\n\treturn 3\n\n\nvoid gh_warn3(char* s):\n\tint* q = s\n")
				caught = 1
				break
			process_sleep_ms(5)
		wbt_wait_refresh_idle()
		if (caught): assert1(wbt_status_int(c"refresh_discarded") > discarded)
	print_int(c"caught a re-check running: ", caught)
	char* raced = wbt_compare(c"bin/wv2", check_g1, 0)
	# Only the second edit has a warning (diagnostics name no function).
	if (caught): assert1(contains(raced, c"\"severity\": \"warning\""))

	# A module moved away with its directory: the importer's answer goes.
	assert_equal(0, mkdir(wbt_path(c"sub"), 493))
	wbt_write(c"sub/x.w", c"int x():\n\treturn 0\n")
	char* x_module = strjoin(wbt_module(c"sub"), c".x")
	wbt_write(c"g3.w", wbt_importing(x_module, c"int main():\n\treturn x()\n"))
	char* check_g3 = wbt_args2(c"check --json ", c"g3.w")
	wbt_compare(c"bin/wv2", check_g3, 0)
	assert_equal(0, rename(wbt_path(c"sub"), wbt_path(c"sub2")))
	wbt_compare(c"bin/wv2", check_g3, 0)
	wbt_compare(c"bin/wv2", check_g2, 0)

	# A module appearing at the checkout root shadows the bin/ copy an
	# import resolved to until now.
	char* bin_shadow = wbt_shadow_dir(c"bin/")
	char* top_shadow = wbt_shadow_dir(c"")
	assert_equal(0, mkdir(bin_shadow, 493))
	assert1(file_write_text(strjoin(bin_shadow, c"/m.w"), c"int shadowed():\n\treturn 0\n"))
	char* shadow_module = strjoin(top_shadow, c".m")
	wbt_write(c"s.w", wbt_importing(shadow_module, c"int main():\n\treturn shadowed()\n"))
	char* deps_s = wbt_args2(c"deps ", c"s.w")
	char* check_s = wbt_args2(c"check --json ", c"s.w")
	char* deps_before = wbt_compare(c"bin/wv2", deps_s, 0)
	assert1(has_line(deps_before, strjoin(bin_shadow, c"/m.w")))
	char* unshadowed = wbt_compare(c"bin/wv2", check_s, 0)
	assert1(contains(unshadowed, c"\"severity\": \"warning\"") == 0)
	assert_equal(0, mkdir(top_shadow, 493))
	assert1(file_write_text(strjoin(top_shadow, c"/m.w"), c"int shadowed():\n\treturn 1\n\n\nvoid shadow_warn(char* s):\n\tint* q = s\n"))
	char* deps_after = wbt_compare(c"bin/wv2", deps_s, 0)
	assert1(has_line(deps_after, strjoin(top_shadow, c"/m.w")))
	char* shadow_check = wbt_compare(c"bin/wv2", check_s, 0)
	assert1(contains(shadow_check, c"\"severity\": \"warning\""))
	unlink(strjoin(top_shadow, c"/m.w"))
	rmdir(top_shadow)
	unlink(strjoin(bin_shadow, c"/m.w"))
	rmdir(bin_shadow)
	wbt_compare_all()


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
	# The count proves the edit itself dropped the answer, unless the
	# whole memo went first: an inotify queue overflow under a parallel
	# './wbuild tests' (memo_clears and last_clear in status say so).
	# Until the module graph, any scratch .w file another test created
	# under bin/ dropped the whole memo too, which is how this assertion
	# flaked under load.
	int clears_before = wbt_status_int(c"memo_clears")
	char* before_edit = wbt_compare(c"bin/wv2", a_check_args, 0)
	int invalidations_before = wbt_status_int(c"invalidations")
	wbt_write(c"helper.w", c"int helper():\n\treturn 0\n\n\nvoid helper2(char* s):\n\tint* q = s\n")
	char* after_edit = wbt_compare(c"bin/wv2", a_check_args, 0)
	assert1(strcmp(before_edit, after_edit) != 0)
	if (wbt_status_int(c"memo_clears") == clears_before): assert1(wbt_status_int(c"invalidations") > invalidations_before)
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
	assert1(has_line(selected_before, c"wbt_a"))
	assert1(has_line(selected_after, c"wbt_a") == 0)
	wbt_compare_all()

	# A new module and a deleted one (resolution-changing events).
	wbt_write(c"d.w", c"int main():\n\treturn 1\n")
	wbt_compare(c"bin/wv2", wbt_args2(c"check --json ", c"d.w"), 0)
	unlink(wbt_path(c"helper.w"))
	wbt_compare_all()

	wbt_graph_invalidation()

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
	for char* w in wbt_words(wbt_args2(c"check --json ", c"b.w")): direct_argv.push(w)
	process_result* direct = wbt_run(direct_argv, 0)
	assert_strings_equal(direct.stdout_text, via_client.stdout_text)
	assert_strings_equal(direct.stderr_text, via_client.stderr_text)
	assert_equal(direct.status, via_client.status)
	wbt_cleanup()
