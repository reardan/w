# wbuild: tool=tools/wprof.w deps=tests/profile_generate_fixture.w
# wbuild: target=verify_profile_generate tag=tests dep=build dep=build_x64
# wbuild: step="bin/wv2 --profile-generate --strict w.w -o bin/prof_wv3"
# wbuild: step="bin/prof_wv3 --profile-generate --strict w.w -o bin/prof_wv4"
# wbuild: step="cmp bin/prof_wv3 bin/prof_wv4"
# wbuild: step="cmp bin/prof_wv3.wprofmap bin/prof_wv4.wprofmap"
# wbuild: step="bin/wv2 --profile-generate --streaming --strict w.w -o bin/prof_streaming_wv3"
# wbuild: step="cmp bin/prof_wv3 bin/prof_streaming_wv3"
# wbuild: step="cmp bin/prof_wv3.wprofmap bin/prof_streaming_wv3.wprofmap"
# wbuild: step="bin/wv2_64 x64 --profile-generate --strict w.w -o bin/prof_wv3_64"
# wbuild: step="bin/prof_wv3_64 x64 --profile-generate --strict w.w -o bin/prof_wv4_64"
# wbuild: step="cmp bin/prof_wv3_64 bin/prof_wv4_64"
# wbuild: step="cmp bin/prof_wv3_64.wprofmap bin/prof_wv4_64.wprofmap"
# wbuild: step="echo profile-generate fixpoint OK: prof_wv3 == prof_wv4, streaming == retained, x86 and x64"
/*
--profile-generate end to end (unit P1, docs/projects/register_allocation_pgo.md
§3.2-§3.3): compile tests/profile_generate_fixture.w with the flag for
x86 and x64, run each binary twice with W_PROFILE_OUT set (once leaving
main by return, once through a direct exit() call), merge the dumps
with bin/wprof, and assert the exact entry and loop-head counts, that
the map's hash for `work` is the one 'w defhash' prints, that counts
sum across runs and across the two targets' maps, and that a run
without W_PROFILE_OUT writes nothing.

The verify_profile_generate target above is the fixpoint with the flag
on, like ast_expression_verify: a compiler built with --profile-generate
reproduces itself and its map, the streaming grammar and the retained
AST path instrument identically, on both word sizes.
*/
import lib.lib
import lib.testing
import lib.assert
import lib.file
import lib.str
import lib.env
import lib.process
import structures.string


char* pg_fixture():
	return c"tests/profile_generate_fixture.w"


# Run path with argv (NULL-terminated) and an optional env; stdout is
# returned (malloc'd) and the exit status stored in status[0].
char* pg_run(char* path, char** argv, char** env, int* status):
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_null
	opts.stdout_mode = process_pipe
	opts.env = env
	process* child = process_spawn(path, argv, opts)
	free(opts)
	asserts(c"spawn failed", child != 0)
	string_builder* text = string_new()
	char* chunk = cast(char*, malloc(4096))
	int n = read(child.stdout_fd, chunk, 4096)
	while (n > 0):
		string_append_bytes(text, chunk, n)
		n = read(child.stdout_fd, chunk, 4096)
	free(chunk)
	close(child.stdout_fd)
	status[0] = process_wait(child)
	process_free(child)
	char* result = strclone(text.data)
	string_free(text)
	return result


int pg_run_status(char* path, char** argv, char** env):
	int status = 0
	char* text = pg_run(path, argv, env, &status)
	free(text)
	return status


# bin/wv2 [x64] --quiet --profile-generate fixture -o out
void pg_compile(char* arch, char* out):
	char** argv = strv_new(8)
	int n = 0
	strv_set(argv, n, c"bin/wv2")
	n = n + 1
	if (strcmp(arch, c"x64") == 0):
		strv_set(argv, n, c"x64")
		n = n + 1
	strv_set(argv, n, c"--quiet")
	n = n + 1
	strv_set(argv, n, c"--profile-generate")
	n = n + 1
	strv_set(argv, n, pg_fixture())
	n = n + 1
	strv_set(argv, n, c"-o")
	n = n + 1
	strv_set(argv, n, out)
	assert_equal(0, pg_run_status(c"bin/wv2", argv, 0))
	free(cast(void*, argv))


# The fixture binary once, with W_PROFILE_OUT=raw (or inherited env when
# raw is 0) and an optional single argument.
void pg_run_fixture(char* binary, char* raw, char* arg):
	char** argv = strv_new(3)
	strv_set(argv, 0, binary)
	if (arg != 0): strv_set(argv, 1, arg)
	char** env = 0
	if (raw != 0): env = env_copy_with(env_current(), c"W_PROFILE_OUT", raw)
	assert_equal(0, pg_run_status(binary, argv, env))
	free(cast(void*, argv))


void pg_merge(char* out, char* map, char* raw):
	char** argv = strv_new(7)
	strv_set(argv, 0, c"bin/wprof")
	strv_set(argv, 1, c"merge")
	strv_set(argv, 2, c"-o")
	strv_set(argv, 3, out)
	strv_set(argv, 4, map)
	strv_set(argv, 5, raw)
	assert_equal(0, pg_run_status(c"bin/wprof", argv, 0))
	free(cast(void*, argv))


# The profile line for `name` in the fixture with the given kind and
# (for loops) head ordinal, or 0.
char* pg_line(list[char*] lines, char* kind, char* name, int head):
	char* marker = strjoin(strjoin(c" ", name), c" tests/profile_generate_fixture.w ")
	char* head_marker = 0
	if (head > 0):
		char* digits = itoa(head)
		head_marker = strjoin(strjoin(c" head=", digits), c" ")
		free(digits)
	for char* line in lines:
		if (starts_with(line, kind) == 0): continue
		if (line[1] != ' '): continue
		if (index_of(line, marker) < 0): continue
		if ((head_marker != 0) && (index_of(line, head_marker) < 0)): continue
		return line
	return 0


int pg_tail_value(char* line, char* field):
	int at = index_of(line, field)
	asserts(c"profile line lacks the count field", at >= 0)
	return atoi(line + at + strlen(field))


void pg_assert_counts(char* profile, int runs):
	list[char*] lines = file_read_lines(profile)
	asserts(c"cannot read merged profile", lines != 0)
	char* work = pg_line(lines, c"f", c"work", 0)
	asserts(c"no f line for work", work != 0)
	assert_equal(3 * runs, pg_tail_value(work, c"entries="))
	char* loop1 = pg_line(lines, c"l", c"work", 1)
	asserts(c"no l line for work loop 1", loop1 != 0)
	assert_equal(33 * runs, pg_tail_value(loop1, c"iters="))
	char* loop2 = pg_line(lines, c"l", c"work", 2)
	asserts(c"no l line for work loop 2", loop2 != 0)
	assert_equal(18 * runs, pg_tail_value(loop2, c"iters="))
	char* loop3 = pg_line(lines, c"l", c"work", 3)
	asserts(c"no l line for work loop 3", loop3 != 0)
	assert_equal(12 * runs, pg_tail_value(loop3, c"iters="))
	asserts(c"work has exactly three loops", pg_line(lines, c"l", c"work", 4) == 0)
	char* main_line = pg_line(lines, c"f", c"main", 0)
	asserts(c"no f line for main", main_line != 0)
	assert_equal(runs, pg_tail_value(main_line, c"entries="))
	char* main_loop = pg_line(lines, c"l", c"main", 1)
	asserts(c"no l line for main's loop", main_loop != 0)
	assert_equal(4 * runs, pg_tail_value(main_loop, c"iters="))


# 'bin/wv2 defhash fixture' -> the "hash" of the record named `name`.
char* pg_defhash(char* name):
	char** argv = strv_new(5)
	strv_set(argv, 0, c"bin/wv2")
	strv_set(argv, 1, c"defhash")
	strv_set(argv, 2, c"--quiet")
	strv_set(argv, 3, pg_fixture())
	int status = 0
	char* text = pg_run(c"bin/wv2", argv, 0, &status)
	free(cast(void*, argv))
	assert_equal(0, status)
	char* key = strjoin(strjoin(c"\"name\": \"", name), c"\"")
	list[char*] lines = split(text, 10)
	for char* line in lines:
		if (index_of(line, key) < 0): continue
		int at = index_of(line, c"\"hash\": \"")
		asserts(c"defhash record without hash", at >= 0)
		return substring(line, at + 9, at + 9 + 64)
	asserts(c"defhash record not found", 0)
	return 0


void pg_check_arch(char* arch):
	char* binary = strjoin(c"bin/profile_generate_fixture_", arch)
	char* map = strjoin(binary, c".wprofmap")
	char* raw = strjoin(binary, c".wprofraw")
	char* profile = strjoin(binary, c".wprof")
	pg_compile(arch, binary)
	unlink(raw)
	# Without W_PROFILE_OUT nothing is written (env_copy_with would
	# inherit a value from the outer environment, so build one without it).
	char** clean = env_copy_with(env_current(), c"W_PROFILE_OUT", c"")
	char** argv = strv_new(2)
	strv_set(argv, 0, binary)
	assert_equal(0, pg_run_status(binary, argv, clean))
	free(cast(void*, argv))
	asserts(c"a run without W_PROFILE_OUT must not dump", file_read_lines(raw) == 0)
	# One run returning from main, one leaving through exit(): both flush.
	pg_run_fixture(binary, raw, 0)
	pg_run_fixture(binary, raw, c"exit")
	pg_merge(profile, map, raw)
	pg_assert_counts(profile, 2)
	# The map's key for work is 'w defhash's hash of it.
	list[char*] lines = file_read_lines(profile)
	char* work = pg_line(lines, c"f", c"work", 0)
	char* expected = pg_defhash(c"work")
	asserts(c"profile line for work does not carry its defhash", index_of(work, expected) == 2)
	# The map header names the target and the counter count.
	list[char*] map_lines = file_read_lines(map)
	asserts(c"map is missing", map_lines != 0)
	char* header = strjoin(c"# wprofmap v1\x09", arch)
	asserts(c"map header names the target", starts_with(map_lines[0], header))


void test_profile_generate_x86():
	pg_check_arch(c"x86")


void test_profile_generate_x64():
	pg_check_arch(c"x64")


# Merging the two targets' profiles sums the same keys: the defhash key
# is word-size independent.
void test_profile_generate_merge_across_targets():
	char** argv = strv_new(7)
	strv_set(argv, 0, c"bin/wprof")
	strv_set(argv, 1, c"merge")
	strv_set(argv, 2, c"-o")
	strv_set(argv, 3, c"bin/profile_generate_fixture_both.wprof")
	strv_set(argv, 4, c"bin/profile_generate_fixture_x86.wprof")
	strv_set(argv, 5, c"bin/profile_generate_fixture_x64.wprof")
	assert_equal(0, pg_run_status(c"bin/wprof", argv, 0))
	free(cast(void*, argv))
	pg_assert_counts(c"bin/profile_generate_fixture_both.wprof", 4)
