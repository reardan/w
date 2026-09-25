# wbuild: target=wtest_defhash_test tag=tests dep=wtest
# wbuild: step="bin/wv2 tools/wtest_defhash_e2e.w -o bin/wtest_defhash_e2e"
# wbuild: step="bin/wtest_defhash_e2e" expect_stdout="wtest_defhash_scratch_test: OK"
/*
Self-contained fixture for bin/wtest's --defhash refinement (wave plan C
task 2g, tools/test_map.w), run by the `wtest_defhash_test` target. It
replaced tools/wtest_defhash_scratch_test.sh (issue #323: no shell
scripts); every child is spawned through lib/process.w with an argv
vector -- no /bin/sh. The FAIL messages and the final OK line keep the
old script's name so the target's expectations are unchanged.

The '-f manifest.json' fixtures elsewhere in tests/wtest/ cover rule
(a)/(c) selection with synthetic "true"/"echo" steps and no
real git history, but --defhash's own machinery shells out to
'git show HEAD:<path>' and 'bin/wv2 defhash', which only mean something
against a real commit and a real compilable root -- hence a throwaway git
repository (a pid-scoped directory under bin/) instead of another -f
fixture, per the wave plan's "self-contained git init-in-a-scratch-dir"
note.

The scratch repo gets its own symlinked copies of bin/wv2, bin/wtest,
and the lib/ structures/ code_generator/ trees: link_impl unconditionally
auto-imports structures.hash_table and structures.w_list before compiling
any user file (compiler/compiler.w's cold-start auto-import block), and
those transitively reach into lib/ and code_generator/integer.w, so even
the two-function program below needs all three trees reachable at the
scratch repo's own relative paths -- exactly like this repo's own
build_relative_import_test (build.base.json) demonstrates a bare tmp dir
with none of them fails with "cannot locate 'structures/hash_table.w'".
*/
import lib.lib
import lib.path
import lib.file
import tools.wtest_scratch


void sc_setup():
	sc_init(c"wtest_defhash_scratch_test", c"wtest_defhash_e2e_")
	sc_require(c"bin/wv2")
	sc_require(c"bin/wtest")
	sc_mkdir(c"bin")
	sc_link(c"bin/wv2", c"bin/wv2")
	sc_link(c"bin/wtest", c"bin/wtest")
	sc_link(c"lib", c"lib")
	sc_link(c"structures", c"structures")
	sc_link(c"code_generator", c"code_generator")


int main():
	sc_setup()
	sc_write(c"build.json", c"{\n\t\"targets\": [\n\t\t{\n\t\t\t\"name\": \"scratch_target\",\n\t\t\t\"steps\": [\n\t\t\t\t{\"cmd\": [\"bin/wv2\", \"scratch_root.w\", \"-o\", \"bin/scratch_out\"]}\n\t\t\t]\n\t\t}\n\t]\n}\n")
	sc_write(c"scratch_root.w", c"import scratch_lib\n\nint main():\n\treturn scratch_lib_add(1, 2)\n")
	sc_write(c"scratch_lib.w", c"int scratch_lib_add(int a, int b):\n\treturn a + b\n")

	git(av(c"init", c"-q"))
	git(av(c"config", c"user.email", c"test@example.com"))
	git(av(c"config", c"user.name", c"test"))
	git(av(c"add", c"-A"))
	git(av(c"commit", c"-q", c"-m", c"initial commit"))

	# Sanity baseline: an unmodified file selects scratch_target under
	# plain rule (b) closure selection -- this just proves the fixture
	# itself (the manifest's compile step, the import from
	# scratch_root.w) is wired up before trusting any skip/fallback
	# assertion below. (An unmodified file is not a meaningful --defhash
	# case on its own: HEAD and the worktree are byte-identical, so
	# "unchanged" is the only correct answer, same as every other case
	# below where the two are actually identical -- comment-only edits
	# included.)
	char* out = wtest_out(av(c"changed", c"scratch_lib.w"), 0)
	if (has_line(out, c"scratch_target") == 0):
		fail(c"baseline (no --defhash) did not select scratch_target")

	# Comment/formatting-only edit: --defhash must SKIP the
	# import-closure target (defhash's own token-stream hash excludes
	# comments/whitespace); without the flag, rule (b) keeps selecting
	# it unconditionally -- the "default selection is byte-identical
	# without the flag" property.
	sc_append(c"scratch_lib.w", c"\n# a trailing comment, no behavior change\n")
	out = wtest_out(av(c"changed", c"scratch_lib.w"), 0)
	if (has_line(out, c"scratch_target") == 0):
		fail(c"comment-only edit: plain selection dropped scratch_target")
	out = wtest_out(av(c"changed", c"--defhash", c"scratch_lib.w"), 0)
	if (has_line(out, c"scratch_target")):
		fail(c"comment-only edit: --defhash still selected scratch_target")

	# Real edit: --defhash must fall back to full closure selection (the
	# definition's own recorded hash actually changed).
	git(av(c"checkout", c"-q", c"--", c"scratch_lib.w"))
	sc_write(c"scratch_lib.w", c"int scratch_lib_add(int a, int b):\n\treturn a + b + 1\n")
	out = wtest_out(av(c"changed", c"--defhash", c"scratch_lib.w"), 0)
	if (has_line(out, c"scratch_target") == 0):
		fail(c"real edit: --defhash did not select scratch_target")

	# Explicit-generics syntax ('T max[T](T a, T b):', docs/projects/
	# generics.md): wave plan C task 4f threaded defhash bookkeeping
	# through the generic scan-ahead machinery (grammar/generic.w), so a
	# generic definition's own span is now recorded (kind
	# 'generic_function') and hashed like any other definition -- a
	# comment-only edit correctly SKIPs, same as an ordinary function,
	# instead of always falling back.
	git(av(c"checkout", c"-q", c"--", c"scratch_lib.w"))
	sc_write(c"scratch_lib.w", c"int scratch_lib_add(int a, int b):\n\treturn a + b\n\n\nT scratch_lib_first[T](T a, T b):\n\treturn a\n")
	git(av(c"add", c"scratch_lib.w"))
	git(av(c"commit", c"-q", c"-m", c"add an explicit-generics definition"))
	sc_append(c"scratch_lib.w", c"\n# comment only, generics still present\n")
	out = wtest_out(av(c"changed", c"--defhash", c"scratch_lib.w"), 0)
	if (has_line(out, c"scratch_target")):
		fail(c"generic definition: comment-only edit still selected scratch_target")

	# A REAL edit to the generic definition's body must still select the
	# target -- coverage means the change is now visible to 'bin/wv2
	# defhash', not that generics are exempt from selection.
	git(av(c"checkout", c"-q", c"--", c"scratch_lib.w"))
	sc_write(c"scratch_lib.w", c"int scratch_lib_add(int a, int b):\n\treturn a + b\n\n\nT scratch_lib_first[T](T a, T b):\n\treturn b\n")
	out = wtest_out(av(c"changed", c"--defhash", c"scratch_lib.w"), 0)
	if (has_line(out, c"scratch_target") == 0):
		fail(c"generic definition: real body edit did not select scratch_target")

	# 'operator' overload syntax (docs/projects/operator_overloading.md):
	# same story via grammar/operator_overload.w -- a real operator
	# definition is now recorded (kind 'operator', a synthetic
	# 'operator<spelling>(<types>)' name), so a comment-only edit
	# SKIPs...
	char* point_prefix = c"int scratch_lib_add(int a, int b):\n\treturn a + b\n\nstruct scratch_lib_point:\n\tint x\n\tint y\n\nscratch_lib_point operator+(scratch_lib_point a, scratch_lib_point b):\n"
	git(av(c"checkout", c"-q", c"--", c"scratch_lib.w"))
	string_builder* src = string_new()
	string_append(src, point_prefix)
	string_append(src, c"\treturn scratch_lib_point(a.x + b.x, a.y + b.y)\n")
	sc_write(c"scratch_lib.w", src.data)
	git(av(c"add", c"scratch_lib.w"))
	git(av(c"commit", c"-q", c"-m", c"add an operator overload"))
	sc_append(c"scratch_lib.w", c"\n# comment only, operator overload still present\n")
	out = wtest_out(av(c"changed", c"--defhash", c"scratch_lib.w"), 0)
	if (has_line(out, c"scratch_target")):
		fail(c"operator overload: comment-only edit still selected scratch_target")

	# ...while a REAL edit to the operator's body still selects the
	# target.
	git(av(c"checkout", c"-q", c"--", c"scratch_lib.w"))
	string_clear(src)
	string_append(src, point_prefix)
	string_append(src, c"\treturn scratch_lib_point(b.x + a.x, b.y + a.y)\n")
	sc_write(c"scratch_lib.w", src.data)
	out = wtest_out(av(c"changed", c"--defhash", c"scratch_lib.w"), 0)
	if (has_line(out, c"scratch_target") == 0):
		fail(c"operator overload: real body edit did not select scratch_target")

	# The coverage payoff (wave plan C task 4f): a file defining BOTH a
	# generic AND an operator overload alongside an ordinary function,
	# only comment-edited, now SKIPs -- before this task, the mere
	# presence of either shape (tools/test_map.w's
	# wtest_defhash_risky_text, now removed) forced a fallback on every
	# such file regardless of what actually changed.
	git(av(c"checkout", c"-q", c"--", c"scratch_lib.w"))
	string_clear(src)
	string_append(src, point_prefix)
	string_append(src, c"\treturn scratch_lib_point(a.x + b.x, a.y + b.y)\n\nT scratch_lib_first[T](T a, T b):\n\treturn a\n")
	sc_write(c"scratch_lib.w", src.data)
	string_free(src)
	git(av(c"add", c"scratch_lib.w"))
	git(av(c"commit", c"-q", c"-m", c"add a generic definition and an operator overload"))
	sc_append(c"scratch_lib.w", c"\n# comment only, generic + operator overload still present\n")
	out = wtest_out(av(c"changed", c"--defhash", c"scratch_lib.w"), 0)
	if (has_line(out, c"scratch_target")):
		fail(c"generic+operator coverage: comment-only edit still selected scratch_target")

	# Committed-clean footgun warning (tools/test_map.w header comment,
	# --defhash): piping a ranged diff's path list into the un-ranged
	# form after committing ('git diff --name-only A..B | wtest changed
	# --defhash') compares HEAD vs a byte-identical worktree and silently
	# skips every path's closure selection -- wtest now warns on stderr,
	# suggesting the ranged form, without touching the stdout selection.
	git(av(c"checkout", c"-q", c"--", c"scratch_lib.w"))
	char* piped_paths = git(av(c"diff", c"--name-only", c"HEAD~1..HEAD"))
	char* err = wtest_err(av(c"changed", c"--defhash"), piped_paths)
	if (contains(err, c"committed-clean vs HEAD") == 0):
		fail(c"footgun combo (piped committed-clean path): warning did not fire")
	if (contains(err, c"wtest changed A..B --defhash") == 0):
		fail(c"footgun combo: warning did not suggest the ranged form")

	# The stdout selection itself must stay byte-identical: only stderr
	# gains the warning.
	char* piped_out = wtest_out(av(c"changed", c"--defhash"), piped_paths)
	char* positional_out = wtest_out(av(c"changed", c"--defhash", c"scratch_lib.w"), 0)
	if (strcmp(piped_out, positional_out) != 0):
		fail(c"footgun combo: warning changed the stdout selection")

	# The ranged form is the correct spelling and must NOT warn (it
	# compares the range's own endpoints, not HEAD vs the worktree).
	err = wtest_err(av(c"changed", c"HEAD~1..HEAD", c"--defhash"), 0)
	if (contains(err, c"committed-clean")):
		fail(c"ranged form: warning fired")

	# A genuinely dirty worktree path piped in (the documented
	# 'git diff --name-only HEAD | wtest changed --defhash' workflow)
	# must NOT warn either: the path differs from HEAD, so the
	# comparison is meaningful.
	sc_append(c"scratch_lib.w", c"\n# dirty worktree, comment only\n")
	piped_paths = git(av(c"diff", c"--name-only", c"HEAD"))
	err = wtest_err(av(c"changed", c"--defhash"), piped_paths)
	if (contains(err, c"committed-clean")):
		fail(c"dirty worktree: warning fired")

	# A committed-clean path named POSITIONALLY was asked about
	# deliberately (this program's own earlier cases do exactly that),
	# so it must not warn: the warning is scoped to stdin-piped lists.
	git(av(c"checkout", c"-q", c"--", c"scratch_lib.w"))
	err = wtest_err(av(c"changed", c"--defhash", c"scratch_lib.w"), 0)
	if (contains(err, c"committed-clean")):
		fail(c"positional committed-clean path: warning fired")

	return sc_ok()
