# wbuild: target=wbuildgen_scratch_test tag=tests dep=wbuildgen
# wbuild: step="bin/wv2 tools/wbuildgen_scratch_e2e.w -o bin/wbuildgen_scratch_e2e"
# wbuild: step="bin/wbuildgen_scratch_e2e" expect_stdout="wbuildgen_scratch_test: OK"
/*
Regression fixture for bin/wbuildgen's manifest write/check pair
(docs/projects/ai_tooling_next_steps.md, 2026-07-25 manifest-race
entry):
  1. 'wbuildgen' (no --check) rewrites the manifest atomically via a
     sibling '<out>.tmp' + rename(2), so a concurrent reader -- the
     manifest_check byte-compare, or bin/wexec parsing the manifest --
     never sees a torn file;
  2. a committed manifest that fails to parse gets its own distinct
     --check message instead of the misleading "manifests differ in
     formatting only".
Everything runs against a scratch --base/--out pair in a pid-scoped
directory under bin/, never a real manifest. The scratch dir has none
of wbuildgen's scan directories (tests/, lib/, ...), so nothing is
generated and the rendered output is deterministic.

Run by the wbuildgen_scratch_test target (directives above). It replaced
tools/wbuildgen_scratch_test.sh (issue #323: no shell scripts); every
child is spawned through lib/process.w with an argv vector -- no
/bin/sh. The concurrent writer loop that the script ran as a background
subshell is a forked copy of this process.
*/
import lib.lib
import lib.process
import lib.path
import lib.file
import lib.str
import lib.shell_commands
import structures.string


char* WBUILDGEN
char* DIR


void err_out(char* s):
	write(2, s, strlen(s))


void fail(char* msg):
	err_out(c"wbuildgen_scratch_test: FAIL: ")
	err_out(msg)
	err_out(c"\n")
	shell_commands_rm_one(DIR, 1, 1)
	exit(1)


# Runs bin/wbuildgen [--check] --base base.json --out out.json in DIR.
process_result* run_wbuildgen(int check):
	spawn_options* opts = spawn_options_new()
	opts.cwd = DIR
	int n = 5
	if (check):
		n = 6
	char** argv = strv_new(n)
	int i = 0
	strv_set(argv, i, WBUILDGEN)
	i = i + 1
	if (check):
		strv_set(argv, i, c"--check")
		i = i + 1
	strv_set(argv, i, c"--base")
	strv_set(argv, i + 1, c"base.json")
	strv_set(argv, i + 2, c"--out")
	strv_set(argv, i + 3, c"out.json")
	process_result* r = process_run(WBUILDGEN, argv, opts, 0, 120000)
	free(opts)
	free(cast(void*, argv))
	if (r == 0):
		fail(c"could not spawn bin/wbuildgen")
	return r


char* in_dir(char* name):
	return path_join(DIR, name)


int main(int argc, char** argv):
	char* root = malloc(4096)
	if (getcwd(root, 4096) <= 0):
		err_out(c"wbuildgen_scratch_test: getcwd failed\n")
		return 1
	WBUILDGEN = path_join(root, c"bin/wbuildgen")
	if (path_exists(WBUILDGEN) == 0):
		err_out(c"wbuildgen_scratch_test: bin/wbuildgen must be built first\n")
		return 1

	string_builder* d = string_new()
	string_append(d, root)
	string_append(d, c"/bin/wbuildgen_scratch_e2e_")
	string_append_int(d, getpid())
	DIR = d.data
	shell_commands_rm_one(DIR, 1, 1)
	if (shell_commands_mkdir_one(DIR, 1) != 0):
		err_out(c"wbuildgen_scratch_test: cannot create the scratch directory\n")
		return 1

	if (file_write_text(in_dir(c"base.json"), c"{\n\t\"targets\": [\n\t]\n}\n") == 0):
		fail(c"cannot write base.json")

	# ===== Atomic rewrite: temp file + rename, sibling to --out. A stale
	# '<out>.tmp' sentinel must be overwritten and renamed away; were
	# wbuildgen still writing out.json directly, the sentinel would
	# survive the run untouched.
	file_write_text(in_dir(c"out.json.tmp"), c"sentinel\n")
	process_result* r = run_wbuildgen(0)
	if (r.status != 0):
		fail(c"initial manifest write failed")
	process_result_free(r)
	if (path_exists(in_dir(c"out.json")) == 0):
		fail(c"manifest write produced no out.json")
	if (path_exists(in_dir(c"out.json.tmp"))):
		fail(c"out.json.tmp left behind (write is not temp-file + rename)")

	# ===== No reader ever sees a torn manifest: rewrite in a loop while
	# --check (the manifest_check byte-compare) runs concurrently. The
	# content never changes, so under an atomic rename every check must
	# pass; the old in-place rewrite (open + truncate + write) let a
	# concurrent check read a prefix of the file and fail spuriously.
	int pid = fork()
	if (pid < 0):
		fail(c"fork failed")
	if (pid == 0):
		int i = 0
		while (i < 40):
			process_result* w = run_wbuildgen(0)
			if (w.status != 0):
				exit(1)
			process_result_free(w)
			i = i + 1
		exit(0)
	process* writer = new process()
	writer.pid = pid
	writer.stdin_fd = -1
	writer.stdout_fd = -1
	writer.stderr_fd = -1
	writer.status = 0
	writer.reaped = 0
	writer.win_handle = 0
	while (process_try_wait(writer) == process_status_running()):
		process_result* c = run_wbuildgen(1)
		if (c.status != 0):
			err_out(c.stderr_text)
			process_kill(writer, sigkill())
			process_wait(writer)
			fail(c"concurrent --check saw a torn manifest mid-rewrite")
		process_result_free(c)
	if (process_wait(writer) != 0):
		fail(c"background manifest writer failed")

	# ===== Distinct --check message for an unparseable committed manifest
	file_write_text(in_dir(c"out.json"), c"{\"targets\": [")
	r = run_wbuildgen(1)
	if (r.status == 0):
		fail(c"--check exited 0 on an unparseable manifest")
	if (contains(r.stderr_text, c"committed manifest failed to parse: out.json") == 0):
		fail(c"missing 'committed manifest failed to parse' message")
	if (contains(r.stderr_text, c"manifests differ in formatting only")):
		fail(c"unparseable manifest still reported as formatting-only drift")
	process_result_free(r)

	# ===== The formatting-only message still covers real formatting drift
	# (same parsed structure, different bytes), pinning the triage split.
	file_write_text(in_dir(c"out.json"), c"{\"targets\": []}")
	r = run_wbuildgen(1)
	if (r.status == 0):
		fail(c"--check exited 0 on formatting drift")
	if (contains(r.stderr_text, c"manifests differ in formatting only") == 0):
		fail(c"missing formatting-only drift message")
	process_result_free(r)

	shell_commands_rm_one(DIR, 1, 1)
	write(1, c"wbuildgen_scratch_test: OK\n", 27)
	return 0
