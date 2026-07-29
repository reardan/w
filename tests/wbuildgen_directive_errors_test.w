/*
Generator-level exercise of wbuildgen's directive validation and target
shaping (tools/wbuildgen.w), run against throwaway scratch trees the
way wvc_e2e_test.w drives bin/wvc: each case builds a pid-scoped
directory under bin/ holding a minimal tests/ tree plus a base
manifest, spawns bin/wbuildgen with cwd pointing at it (wbg_collect_dir
walks tests/ etc. relative to the working directory), and asserts on
the exit status, stderr, and generated JSON. Covers the 2026-07
directive-gap closures:

- arch_only=<arch> generates the single non-default-arch target and no
  32-bit twin, and rejects combining with the x64/arch= twin flags;
- deps= accepts a .w value (a run-time text input the import closure
  cannot see) and lands it in both "data" and the cache "inputs";
- generated compile+run targets declare "inputs"/"outputs" (they used
  to be silent FORCE targets);
- a source with both inline '# wbuild:' lines and a '.wbuild' sidecar,
  and a *_fixture.w carrying non-fixture_group directives with no
  fixture_group=, are hard errors instead of silent no-ops;
- wasm is a recognized arch (compile with the wasm selector, run
  through 'sh tools/run_wasm.sh');
- flags= injects extra compiler arguments between the arch selector
  and the source path of every generated compile command;
- group=<target>@<arch> collects several sources' compile+run pairs
  into one aggregate target closed by an 'echo <target> OK' epilogue,
  with each member's own run-field directives on its own run step;
  group_only suppresses a member's standalone targets, and the misuse
  shapes (group_only with no group=, group_only with standalone
  directives, members disagreeing on the group's arch, a value with no
  '@<arch>') are hard errors.
*/
# wbuild: tool=tools/wbuildgen.w
import lib.testing
import lib.process
import lib.path
import lib.file
import structures.string


char* wdet_root_cache
char* wdet_root():
	if (wdet_root_cache == 0):
		char* buf = malloc(4096)
		int n = getcwd(buf, 4096)
		assert1(n > 0)
		wdet_root_cache = buf
	return wdet_root_cache


char* wdet_bin_cache
char* wdet_bin():
	if (wdet_bin_cache == 0):
		wdet_bin_cache = path_join(wdet_root(), c"bin/wbuildgen")
	return wdet_bin_cache


char* wdet_dir_cache
char* wdet_dir():
	if (wdet_dir_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/wbuildgen_directive_errors_test_")
		string_append_int(p, getpid())
		wdet_dir_cache = p.data
		free(p)
	return wdet_dir_cache


int wdet_index_of(char* haystack, char* needle):
	int hl = strlen(haystack)
	int nl = strlen(needle)
	if (nl == 0):
		return 0
	int i = 0
	while ((i + nl) <= hl):
		int j = 0
		while ((j < nl) && (haystack[i + j] == needle[j])):
			j = j + 1
		if (j == nl):
			return i
		i = i + 1
	return -1


void wdet_assert_contains(char* haystack, char* needle):
	int found = wdet_index_of(haystack, needle) >= 0
	if (found == 0):
		wstream* err = stderr_writer()
		stream_write_cstr(err, c"expected to find '")
		stream_write_cstr(err, needle)
		stream_write_cstr(err, c"' in: ")
		stream_write_line(err, haystack)
		stream_flush(err)
	assert1(found)


void wdet_assert_lacks(char* haystack, char* needle):
	int found = wdet_index_of(haystack, needle) >= 0
	if (found):
		wstream* err = stderr_writer()
		stream_write_cstr(err, c"expected NOT to find '")
		stream_write_cstr(err, needle)
		stream_write_cstr(err, c"' in: ")
		stream_write_line(err, haystack)
		stream_flush(err)
	assert1(found == 0)


# A fresh scratch tree bin/..._<pid>/<case>/ with a tests/ subdirectory
# and a minimal base manifest (empty umbrellas for the generated names
# to extend), returned as the path wbuildgen should run in.
char* wdet_case_dir(char* case_name):
	mkdir(c"bin", 493)
	mkdir(wdet_dir(), 493)
	char* dir = path_join(wdet_dir(), case_name)
	mkdir(dir, 493)
	char* tests_dir = path_join(dir, c"tests")
	mkdir(tests_dir, 493)
	free(tests_dir)
	char* base_path = path_join(dir, c"base.json")
	assert_equal(1, file_write_text(base_path, c"{\n\t\"targets\": [\n\t\t{\n\t\t\t\"name\": \"tests\",\n\t\t\t\"deps\": []\n\t\t},\n\t\t{\n\t\t\t\"name\": \"tests_x64\",\n\t\t\t\"deps\": []\n\t\t}\n\t]\n}\n"))
	free(base_path)
	return dir


void wdet_write(char* dir, char* rel, char* text):
	char* path = path_join(dir, rel)
	assert_equal(1, file_write_text(path, text))
	free(path)


# Runs bin/wbuildgen --base base.json --out out.json with cwd=dir.
process_result* wdet_run(char* dir):
	spawn_options* opts = spawn_options_new()
	opts.cwd = dir
	char** argv = strv_new(5)
	strv_set(argv, 0, c"wbuildgen")
	strv_set(argv, 1, c"--base")
	strv_set(argv, 2, c"base.json")
	strv_set(argv, 3, c"--out")
	strv_set(argv, 4, c"out.json")
	process_result* r = process_run(wdet_bin(), argv, opts, 0, 20000)
	assert1(r != 0)
	free(opts)
	free(cast(void*, argv))
	return r


void test_arch_only_single_target():
	char* dir = wdet_case_dir(c"arch_only")
	wdet_write(dir, c"tests/rt_data.w", c"# consumed as run-time text, never imported\n")
	wdet_write(dir, c"tests/solo_test.w", c"# wbuild: arch_only=x64 expect_stdout=\"solo OK\"\n# wbuild: deps=tests/rt_data.w\nint main():\n\treturn 0\n")
	process_result* r = wdet_run(dir)
	assert_equal(0, r.status)
	process_result_free(r)
	char* out_path = path_join(dir, c"out.json")
	char* out = file_read_text(out_path)
	assert1(out != 0)
	# The one generated target compiles with the x64 selector under the
	# basename-derived name...
	wdet_assert_contains(out, c"\"cmd\": [\"bin/wv2\", \"x64\", \"tests/solo_test.w\", \"-o\", \"bin/solo_test\"]")
	# ...no default 32-bit twin exists...
	wdet_assert_lacks(out, c"[\"bin/wv2\", \"tests/solo_test.w\"")
	# ...it joins the x64 umbrella, not the 32-bit one...
	wdet_assert_contains(out, c"\"name\": \"tests_x64\",\n\t\t\t\"deps\": [\n\t\t\t\t\"solo_test\"\n\t\t\t]")
	# ...the .w deps= value lands in wtest's "data" and the cache
	# "inputs" (alongside the source), and the binary in "outputs".
	wdet_assert_contains(out, c"\"data\": [\"tests/rt_data.w\"]")
	wdet_assert_contains(out, c"\"inputs\": [\"tests/solo_test.w\", \"tests/rt_data.w\"]")
	wdet_assert_contains(out, c"\"outputs\": [\"bin/solo_test\"]")
	free(out)
	free(out_path)


void test_arch_only_rejects_twin_flags():
	char* dir = wdet_case_dir(c"arch_only_combo")
	wdet_write(dir, c"tests/combo_test.w", c"# wbuild: arch_only=x64 x64\nint main():\n\treturn 0\n")
	process_result* r = wdet_run(dir)
	assert1(r.status != 0)
	wdet_assert_contains(r.stderr_text, c"'arch_only=' replaces the default target and cannot combine with 'x64'/'arch=' twin directives")
	process_result_free(r)


void test_arch_only_rejects_bad_value():
	char* dir = wdet_case_dir(c"arch_only_value")
	wdet_write(dir, c"tests/value_test.w", c"# wbuild: arch_only=riscv\nint main():\n\treturn 0\n")
	process_result* r = wdet_run(dir)
	assert1(r.status != 0)
	wdet_assert_contains(r.stderr_text, c"unsupported '# wbuild:' arch_only")
	process_result_free(r)


void test_wasm_arch_shape():
	char* dir = wdet_case_dir(c"wasm_arch")
	wdet_write(dir, c"tests/wasmy_test.w", c"# wbuild: arch_only=wasm\nint main():\n\treturn 0\n")
	process_result* r = wdet_run(dir)
	assert_equal(0, r.status)
	process_result_free(r)
	char* out_path = path_join(dir, c"out.json")
	char* out = file_read_text(out_path)
	assert1(out != 0)
	# Compiled with the wasm selector, run through the wasm runner
	# wrapper, no default 32-bit twin.
	wdet_assert_contains(out, c"\"cmd\": [\"bin/wv2\", \"wasm\", \"tests/wasmy_test.w\", \"-o\", \"bin/wasmy_test\"]")
	wdet_assert_contains(out, c"\"cmd\": [\"sh\", \"tools/run_wasm.sh\", \"bin/wasmy_test\"]")
	wdet_assert_lacks(out, c"[\"bin/wv2\", \"tests/wasmy_test.w\"")
	free(out)
	free(out_path)


void test_flags_in_compile_command():
	char* dir = wdet_case_dir(c"flags")
	wdet_write(dir, c"tests/flagy_test.w", c"# wbuild: arch_only=arm64 flags=--pac=full\nint main():\n\treturn 0\n")
	process_result* r = wdet_run(dir)
	assert_equal(0, r.status)
	process_result_free(r)
	char* out_path = path_join(dir, c"out.json")
	char* out = file_read_text(out_path)
	assert1(out != 0)
	# flags= lands between the arch selector and the source path.
	wdet_assert_contains(out, c"\"cmd\": [\"bin/wv2\", \"arm64\", \"--pac=full\", \"tests/flagy_test.w\", \"-o\", \"bin/flagy_test\"]")
	wdet_assert_contains(out, c"\"cmd\": [\"sh\", \"tools/run_arm64.sh\", \"bin/flagy_test\"]")
	free(out)
	free(out_path)


void test_group_aggregate():
	char* dir = wdet_case_dir(c"group")
	wdet_write(dir, c"tests/alpha_test.w", c"# wbuild: group=combo_test_x64@x64 expect_stdout=\"alpha OK\"\nint main():\n\treturn 0\n")
	wdet_write(dir, c"tests/beta_test.w", c"# wbuild: group_only group=combo_test_x64@x64\nint main():\n\treturn 0\n")
	process_result* r = wdet_run(dir)
	assert_equal(0, r.status)
	process_result_free(r)
	char* out_path = path_join(dir, c"out.json")
	char* out = file_read_text(out_path)
	assert1(out != 0)
	# One aggregate holds both members' compile+run pairs (member
	# binaries splice the arch in before _test), a member's own
	# run-field directive decorates only its own run step, and the
	# shared epilogue closes the target.
	wdet_assert_contains(out, c"\"name\": \"combo_test_x64\"")
	wdet_assert_contains(out, c"\"cmd\": [\"bin/wv2\", \"x64\", \"tests/alpha_test.w\", \"-o\", \"bin/alpha_x64_test\"]")
	wdet_assert_contains(out, c"{\"cmd\": [\"bin/alpha_x64_test\"], \"expect_stdout\": \"alpha OK\"}")
	wdet_assert_contains(out, c"{\"cmd\": [\"bin/beta_x64_test\"]}")
	wdet_assert_contains(out, c"\"cmd\": [\"echo\", \"combo_test_x64 OK\"]")
	wdet_assert_contains(out, c"\"inputs\": [\"tests/alpha_test.w\", \"tests/beta_test.w\"]")
	wdet_assert_contains(out, c"\"outputs\": [\"bin/alpha_x64_test\", \"bin/beta_x64_test\"]")
	# alpha keeps its standalone default target; group_only beta does
	# not get one.
	wdet_assert_contains(out, c"\"cmd\": [\"bin/wv2\", \"tests/alpha_test.w\", \"-o\", \"bin/alpha_test\"]")
	wdet_assert_lacks(out, c"\"bin/wv2\", \"tests/beta_test.w\"")
	# The x64 aggregate joins the x64 umbrella.
	wdet_assert_contains(out, c"\"name\": \"tests_x64\",\n\t\t\t\"deps\": [\n\t\t\t\t\"combo_test_x64\"\n\t\t\t]")
	free(out)
	free(out_path)


void test_group_only_needs_group():
	char* dir = wdet_case_dir(c"group_only_alone")
	wdet_write(dir, c"tests/lonely_test.w", c"# wbuild: group_only\nint main():\n\treturn 0\n")
	process_result* r = wdet_run(dir)
	assert1(r.status != 0)
	wdet_assert_contains(r.stderr_text, c"'group_only' needs at least one 'group=' membership: tests/lonely_test.w")
	process_result_free(r)


void test_group_only_rejects_standalone_directives():
	char* dir = wdet_case_dir(c"group_only_combo")
	wdet_write(dir, c"tests/mixed_test.w", c"# wbuild: group_only group=combo_test_x64@x64 x64\nint main():\n\treturn 0\n")
	process_result* r = wdet_run(dir)
	assert1(r.status != 0)
	wdet_assert_contains(r.stderr_text, c"'group_only' suppresses every standalone target")
	process_result_free(r)


void test_group_rejects_missing_arch():
	char* dir = wdet_case_dir(c"group_value")
	wdet_write(dir, c"tests/tagless_test.w", c"# wbuild: group=combo_test\nint main():\n\treturn 0\n")
	process_result* r = wdet_run(dir)
	assert1(r.status != 0)
	wdet_assert_contains(r.stderr_text, c"'group=' needs '<target>@<arch>'")
	process_result_free(r)


void test_group_rejects_arch_mismatch():
	char* dir = wdet_case_dir(c"group_arch_mismatch")
	wdet_write(dir, c"tests/first_test.w", c"# wbuild: group=combo_smoke_test@arm64\nint main():\n\treturn 0\n")
	wdet_write(dir, c"tests/second_test.w", c"# wbuild: group=combo_smoke_test@wasm\nint main():\n\treturn 0\n")
	process_result* r = wdet_run(dir)
	assert1(r.status != 0)
	wdet_assert_contains(r.stderr_text, c"'group=' members disagree on the group's arch: tests/second_test.w")
	process_result_free(r)


void test_sidecar_and_inline_is_an_error():
	char* dir = wdet_case_dir(c"sidecar_inline")
	wdet_write(dir, c"tests/dup_test.w", c"# wbuild: x64\nint main():\n\treturn 0\n")
	wdet_write(dir, c"tests/dup_test.w.wbuild", c"# wbuild: x64\n")
	process_result* r = wdet_run(dir)
	assert1(r.status != 0)
	wdet_assert_contains(r.stderr_text, c"'# wbuild:' lines in both the source and its '.wbuild' sidecar (keep exactly one): tests/dup_test.w")
	process_result_free(r)


void test_fixture_stray_directives_are_an_error():
	char* dir = wdet_case_dir(c"stray_fixture")
	wdet_write(dir, c"tests/stray_fixture.w", c"# wbuild: x64\nint main():\n\treturn 0\n")
	process_result* r = wdet_run(dir)
	assert1(r.status != 0)
	wdet_assert_contains(r.stderr_text, c"'# wbuild:' directives on a fixture need 'fixture_group=' (a fixture is not a test target): tests/stray_fixture.w")
	process_result_free(r)


void test_cleanup():
	# Best-effort removal of the pid-scoped scratch root; a leftover
	# tree only wastes bin/ space (bin/ is gitignored and never walked
	# by the real manifest run).
	char** argv = strv_new(3)
	strv_set(argv, 0, c"/bin/rm")
	strv_set(argv, 1, c"-rf")
	strv_set(argv, 2, wdet_dir())
	process_result* r = process_run(c"/bin/rm", argv, 0, 0, 10000)
	if (r != 0):
		process_result_free(r)
	free(cast(void*, argv))
