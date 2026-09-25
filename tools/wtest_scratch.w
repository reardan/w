/*
Shared harness for bin/wtest's end-to-end fixtures
(tools/wtest_{defhash,nofailcache,range,runnable}_e2e.w and
tests/wtest/{cache,timeout,why}_scratch_e2e.w). They replaced shell
scripts (issue #323), so their FAIL lines and final OK line keep each
old script's name ('<sc_name>: FAIL: ...', '<sc_name>: OK') -- the
targets' expect_stdout depends on it.

Most of them need a throwaway checkout: a pid-scoped directory under
bin/ (so parallel targets never collide) holding symlinks to the real
bin/wtest (and bin/wv2, lib/, ... as the scenario needs), a fixture
build.json, and sometimes a FAKE bin/wv2 -- a tiny W program written
into the checkout and compiled with the real compiler -- so each deps
outcome is deterministic and instant. Every child is spawned through
lib/process.w with an argv vector (no /bin/sh), with cwd = the scratch
checkout.
*/
import lib.lib
import lib.process
import lib.path
import lib.file
import lib.str
import lib.container
import structures.string


char* sc_name = 0    # the fixture's name in its FAIL/OK lines
char* sc_root = 0    # the real checkout (the cwd the fixture started in)
char* sc_dir = 0     # the scratch checkout; 0 until sc_init made it
char** sc_env = 0    # environment for sc_exec children; 0 inherits


void sc_err(char* s):
	write(2, s, strlen(s))


void sc_rm_rf(char* path):
	char** argv = strv_new(3)
	strv_set(argv, 0, c"/bin/rm")
	strv_set(argv, 1, c"-rf")
	strv_set(argv, 2, path)
	process_result* r = process_run(c"/bin/rm", argv, 0, 0, 60000)
	if (r != 0):
		process_result_free(r)
	free(cast(void*, argv))


void sc_cleanup():
	if (sc_dir != 0):
		sc_rm_rf(sc_dir)


void fail(char* msg):
	sc_err(sc_name)
	sc_err(c": FAIL: ")
	sc_err(msg)
	sc_err(c"\n")
	sc_cleanup()
	exit(1)


# The passing epilogue: remove the scratch checkout, print '<name>: OK'.
int sc_ok():
	sc_cleanup()
	print(sc_name)
	println(c": OK")
	return 0


# Exit 1 (without a FAIL line: the fixture never ran) unless the real
# checkout has built rel.
void sc_require(char* rel):
	char* path = path_join(sc_root, rel)
	if (path_exists(path) == 0):
		sc_err(sc_name)
		sc_err(c": ")
		sc_err(rel)
		sc_err(c" must be built first\n")
		sc_cleanup()
		exit(1)
	free(path)


# Name the fixture and create its empty scratch directory,
# <root>/bin/<prefix><pid>.
void sc_init(char* name, char* prefix):
	sc_name = name
	char* buf = malloc(4096)
	if (getcwd(buf, 4096) <= 0):
		fail(c"getcwd failed")
	sc_root = buf
	char* rel = strjoin(c"bin/", prefix)
	sc_dir = path_join(sc_root, strjoin(rel, itoa(getpid())))
	sc_cleanup()
	if (mkdir(sc_dir, 493) < 0):
		sc_dir = 0
		fail(c"could not create the scratch directory")


# rel inside the scratch checkout (fresh string).
char* sc_path(char* rel):
	return path_join(sc_dir, rel)


void sc_mkdir(char* rel):
	mkdir(sc_path(rel), 493)


# A scratch file's contents, or 0 when it does not exist.
char* sc_read(char* rel):
	return file_read_text(sc_path(rel))


void sc_write(char* rel, char* text):
	if (file_write_text(sc_path(rel), text) == 0):
		fail(strjoin(c"could not write ", rel))


void sc_append(char* rel, char* text):
	char* old = sc_read(rel)
	if (old == 0):
		fail(c"could not read a scratch file")
	sc_write(rel, strjoin(old, text))
	free(old)


# Symlink the real checkout's repo_rel into the scratch checkout.
void sc_link(char* repo_rel, char* scratch_rel):
	char* target = path_join(sc_root, repo_rel)
	char* link = sc_path(scratch_rel)
	if (symlink(target, link) < 0):
		fail(c"could not create a scratch symlink")
	free(target)
	free(link)


# An argv tail for sc_exec.
list[char*] av(char*... words):
	list[char*] v = new list[char*]
	for char* w in words:
		v.push(w)
	return v


# Runs prog with argv0 plus args (consumed) in the scratch checkout
# under sc_env, feeding stdin_text (0 for none). A spawn failure is a
# test failure; any exit status is returned to the caller.
process_result* sc_exec(char* prog, char* argv0, list[char*] args, char* stdin_text):
	char** argv = strv_new(args.length + 1)
	strv_set(argv, 0, argv0)
	int i = 1
	for char* a in args:
		strv_set(argv, i, a)
		i = i + 1
	spawn_options* opts = spawn_options_new()
	opts.cwd = sc_dir
	opts.env = sc_env
	process_result* r = process_run(prog, argv, opts, stdin_text, 600000)
	free(opts)
	free(cast(void*, argv))
	list_free[char*](args)
	if (r == 0):
		fail(strjoin(c"could not spawn ", prog))
	return r


# 'git <args>' through /usr/bin/env (execve does no PATH lookup); must
# exit 0. Returns stdout (owned).
char* git(list[char*] args):
	args.insert(0, c"git")
	process_result* r = sc_exec(c"/usr/bin/env", c"env", args, 0)
	if (r.status != 0):
		sc_err(r.stderr_text)
		fail(c"a git command failed")
	char* out = strclone(r.stdout_text)
	process_result_free(r)
	return out


# 'bin/wtest <args>' in the scratch checkout; the caller owns the result.
process_result* wtest_run(list[char*] args, char* stdin_text):
	return sc_exec(sc_path(c"bin/wtest"), c"bin/wtest", args, stdin_text)


# 'bin/wtest <args>' that must exit 0; returns its stdout, or its
# stderr when want_err is set.
char* wtest_capture(list[char*] args, char* stdin_text, int want_err):
	process_result* r = wtest_run(args, stdin_text)
	if (r.status != 0):
		sc_err(r.stderr_text)
		fail(c"bin/wtest exited nonzero")
	char* text = r.stdout_text
	if (want_err):
		text = r.stderr_text
	text = strclone(text)
	process_result_free(r)
	return text


char* wtest_out(list[char*] args, char* stdin_text):
	return wtest_capture(args, stdin_text, 0)


char* wtest_err(list[char*] args, char* stdin_text):
	return wtest_capture(args, stdin_text, 1)


# grep -q '^prefix': some line of text starts with prefix (0 for a
# null text).
int has_line_prefix(char* text, char* prefix):
	if (text == 0):
		return 0
	for char* line in split(text, 10):
		if (starts_with(line, prefix)):
			return 1
	return 0


# One line of generated W source, indented by tabs.
void sc_src(string_builder* sb, int tabs, char* line):
	int i = 0
	while (i < tabs):
		string_append(sb, c"\t")
		i = i + 1
	string_append(sb, line)
	string_append(sb, c"\n")


# Compile source (a fake compiler's W text) with the real bin/wv2 into
# the scratch checkout's bin/wv2.
void sc_install_fake_wv2(char* source):
	sc_write(c"fake_wv2.w", source)
	char* compiler = path_join(sc_root, c"bin/wv2")
	char** argv = strv_new(4)
	strv_set(argv, 0, compiler)
	strv_set(argv, 1, sc_path(c"fake_wv2.w"))
	strv_set(argv, 2, c"-o")
	strv_set(argv, 3, sc_path(c"bin/wv2"))
	spawn_options* opts = spawn_options_new()
	opts.cwd = sc_root
	process_result* r = process_run(compiler, argv, opts, 0, 600000)
	if (r == 0):
		fail(c"could not spawn bin/wv2 for the fake compiler")
	if (r.status != 0):
		sc_err(r.stderr_text)
		fail(c"fake bin/wv2 did not compile")
	process_result_free(r)
