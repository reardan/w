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
  through 'bin/wrun wasm', with the wrun target added to its deps);
- flags= injects extra compiler arguments between the arch selector
  and the source path of every generated compile command;
- group=<target>@<arch> collects several sources' compile+run pairs
  into one aggregate target closed by an 'echo <target> OK' epilogue,
  with each member's own run-field directives on its own run step;
  group_only suppresses a member's standalone targets, and the misuse
  shapes (group_only with no group=, group_only with standalone
  directives, members disagreeing on the group's arch, a value with no
  '@<arch>') are hard errors;
- "generate": {"tool_targets": [...]} entries (the whole target is one
  already-built tool invocation, no compile step) generate with "deps"
  derived from the step commands via the base targets' declared
  "outputs" (staged outputs resolve; an entry's own earlier-step -o
  products are self-satisfied), and the misuse shapes (a hand-declared
  "deps", an unknown entry key, a bin/-prefixed command word nothing
  produces, an entry name still hand-written in "targets") are hard
  errors;
- step="cmd args" appends an extra step after the default-arch run
  step, decorated by the fields that follow it on its line, turns the
  target into a FORCE target, and rejects unknown fields, two steps on
  one line, and sources with no default-arch target;
- a base target's "tags" puts it in the named umbrellas (ahead of the
  generated members) and never reaches the manifest, and a tag naming
  no umbrella is a hard error;
- target=/binary= lines make a source own whole targets (binary= adds
  the wv2 dep, source input, bin/<name> output and a compile step,
  optionally staged), their step= lines keep quoted words whole and
  stay out of the source's own test target, and a name clash with
  build.base.json, a step-less target, 'staged' on target=, or a
  target= that does not start its line are hard errors.
*/
# wbuild: tool=tools/wbuildgen.w
import lib.testing
import lib.process
import tests.tool_e2e
import lib.path
import lib.file
import structures.string


char* wdet_dir():
	return tool_scratch(c"wbuildgen_directive_errors_test_")


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
	process_result* r = process_run(tool_bin(c"wbuildgen"), argv, opts, 0, 20000)
	assert1(r != 0)
	free(opts)
	free(cast(void*, argv))
	return r


# wbuildgen in dir must fail, naming want on stderr.
void wdet_expect_error(char* dir, char* want):
	process_result* r = wdet_run(dir)
	assert1(r.status != 0)
	assert_contains(r.stderr_text, want)
	process_result_free(r)


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
	assert_contains(out, c"\"cmd\": [\"bin/wv2\", \"x64\", \"tests/solo_test.w\", \"-o\", \"bin/solo_test\"]")
	# ...no default 32-bit twin exists...
	assert_lacks(out, c"[\"bin/wv2\", \"tests/solo_test.w\"")
	# ...it joins the x64 umbrella, not the 32-bit one...
	assert_contains(out, c"\"name\": \"tests_x64\",\n\t\t\t\"deps\": [\n\t\t\t\t\"solo_test\"\n\t\t\t]")
	# ...the .w deps= value lands in wtest's "data" and the cache
	# "inputs" (alongside the source), and the binary in "outputs".
	assert_contains(out, c"\"data\": [\"tests/rt_data.w\"]")
	assert_contains(out, c"\"inputs\": [\"tests/solo_test.w\", \"tests/rt_data.w\"]")
	assert_contains(out, c"\"outputs\": [\"bin/solo_test\"]")
	free(out)
	free(out_path)


void test_arch_only_rejects_twin_flags():
	char* dir = wdet_case_dir(c"arch_only_combo")
	wdet_write(dir, c"tests/combo_test.w", c"# wbuild: arch_only=x64 x64\nint main():\n\treturn 0\n")
	wdet_expect_error(dir, c"'arch_only=' replaces the default target and cannot combine with 'x64'/'arch=' twin directives")


void test_arch_only_rejects_bad_value():
	char* dir = wdet_case_dir(c"arch_only_value")
	wdet_write(dir, c"tests/value_test.w", c"# wbuild: arch_only=riscv\nint main():\n\treturn 0\n")
	wdet_expect_error(dir, c"unsupported '# wbuild:' arch_only")


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
	assert_contains(out, c"\"cmd\": [\"bin/wv2\", \"wasm\", \"tests/wasmy_test.w\", \"-o\", \"bin/wasmy_test\"]")
	assert_contains(out, c"\"cmd\": [\"bin/wrun\", \"wasm\", \"bin/wasmy_test\"]")
	assert_contains(out, c"\"deps\": [\"wv2\", \"wrun\"]")
	assert_lacks(out, c"[\"bin/wv2\", \"tests/wasmy_test.w\"")
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
	assert_contains(out, c"\"cmd\": [\"bin/wv2\", \"arm64\", \"--pac=full\", \"tests/flagy_test.w\", \"-o\", \"bin/flagy_test\"]")
	assert_contains(out, c"\"cmd\": [\"bin/wrun\", \"arm64\", \"bin/flagy_test\"]")
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
	assert_contains(out, c"\"name\": \"combo_test_x64\"")
	assert_contains(out, c"\"cmd\": [\"bin/wv2\", \"x64\", \"tests/alpha_test.w\", \"-o\", \"bin/alpha_x64_test\"]")
	assert_contains(out, c"{\"cmd\": [\"bin/alpha_x64_test\"], \"expect_stdout\": \"alpha OK\"}")
	assert_contains(out, c"{\"cmd\": [\"bin/beta_x64_test\"]}")
	assert_contains(out, c"\"cmd\": [\"echo\", \"combo_test_x64 OK\"]")
	assert_contains(out, c"\"inputs\": [\"tests/alpha_test.w\", \"tests/beta_test.w\"]")
	assert_contains(out, c"\"outputs\": [\"bin/alpha_x64_test\", \"bin/beta_x64_test\"]")
	# alpha keeps its standalone default target; group_only beta does
	# not get one.
	assert_contains(out, c"\"cmd\": [\"bin/wv2\", \"tests/alpha_test.w\", \"-o\", \"bin/alpha_test\"]")
	assert_lacks(out, c"\"bin/wv2\", \"tests/beta_test.w\"")
	# The x64 aggregate joins the x64 umbrella.
	assert_contains(out, c"\"name\": \"tests_x64\",\n\t\t\t\"deps\": [\n\t\t\t\t\"combo_test_x64\"\n\t\t\t]")
	free(out)
	free(out_path)


void test_group_only_needs_group():
	char* dir = wdet_case_dir(c"group_only_alone")
	wdet_write(dir, c"tests/lonely_test.w", c"# wbuild: group_only\nint main():\n\treturn 0\n")
	wdet_expect_error(dir, c"'group_only' needs at least one 'group=' membership: tests/lonely_test.w")


void test_group_only_rejects_standalone_directives():
	char* dir = wdet_case_dir(c"group_only_combo")
	wdet_write(dir, c"tests/mixed_test.w", c"# wbuild: group_only group=combo_test_x64@x64 x64\nint main():\n\treturn 0\n")
	wdet_expect_error(dir, c"'group_only' suppresses every standalone target")


void test_group_rejects_missing_arch():
	char* dir = wdet_case_dir(c"group_value")
	wdet_write(dir, c"tests/tagless_test.w", c"# wbuild: group=combo_test\nint main():\n\treturn 0\n")
	wdet_expect_error(dir, c"'group=' needs '<target>@<arch>'")


void test_group_rejects_arch_mismatch():
	char* dir = wdet_case_dir(c"group_arch_mismatch")
	wdet_write(dir, c"tests/first_test.w", c"# wbuild: group=combo_smoke_test@arm64\nint main():\n\treturn 0\n")
	wdet_write(dir, c"tests/second_test.w", c"# wbuild: group=combo_smoke_test@wasm\nint main():\n\treturn 0\n")
	wdet_expect_error(dir, c"'group=' members disagree on the group's arch: tests/second_test.w")


void test_sidecar_and_inline_is_an_error():
	char* dir = wdet_case_dir(c"sidecar_inline")
	wdet_write(dir, c"tests/dup_test.w", c"# wbuild: x64\nint main():\n\treturn 0\n")
	wdet_write(dir, c"tests/dup_test.w.wbuild", c"# wbuild: x64\n")
	wdet_expect_error(dir, c"'# wbuild:' lines in both the source and its '.wbuild' sidecar (keep exactly one): tests/dup_test.w")


void test_fixture_stray_directives_are_an_error():
	char* dir = wdet_case_dir(c"stray_fixture")
	wdet_write(dir, c"tests/stray_fixture.w", c"# wbuild: x64\nint main():\n\treturn 0\n")
	wdet_expect_error(dir, c"'# wbuild:' directives on a fixture need 'fixture_group=' (a fixture is not a test target): tests/stray_fixture.w")


# A base manifest with one staged tool target (compiles to a .stage
# path, mv's it to the declared output — the bin/wexec shape) so the
# tool_targets cases can exercise resolution by *declared* outputs.
char* wdet_tool_base(char* tool_targets_json):
	string_builder* s = string_new()
	string_append(s, c"{\n\t\"targets\": [\n\t\t{\n\t\t\t\"name\": \"mytool\",\n\t\t\t\"outputs\": [\"bin/mytool\"],\n\t\t\t\"steps\": [\n\t\t\t\t{\"cmd\": [\"bin/wv2\", \"tools/mytool.w\", \"-o\", \"bin/mytool.stage\"]},\n\t\t\t\t{\"cmd\": [\"mv\", \"bin/mytool.stage\", \"bin/mytool\"]}\n\t\t\t]\n\t\t}\n\t],\n\t\"generate\": {\n\t\t\"tool_targets\": [\n")
	string_append(s, tool_targets_json)
	string_append(s, c"\n\t\t]\n\t}\n}\n")
	char* out = s.data
	free(s)
	return out


void test_tool_targets_generate():
	char* dir = wdet_case_dir(c"tool_targets")
	# mytool_check consumes the staged tool's declared output;
	# gate compiles its own binary via a non-bin/ seed command and runs
	# it (the asm_seed_gate shape: self-produced, so no deps at all).
	char* base = wdet_tool_base(c"\t\t\t{\"name\": \"mytool_check\", \"steps\": [{\"cmd\": [\"bin/mytool\", \"--check\"], \"expect_stdout\": \"ok\"}]},\n\t\t\t{\"name\": \"gate\", \"inputs\": [\"w\"], \"steps\": [{\"cmd\": [\"./seed\", \"x.w\", \"-o\", \"bin/gate_bin\"]}, {\"cmd\": [\"bin/gate_bin\"]}]}")
	wdet_write(dir, c"base.json", base)
	free(base)
	process_result* r = wdet_run(dir)
	assert_equal(0, r.status)
	process_result_free(r)
	char* out_path = path_join(dir, c"out.json")
	char* out = file_read_text(out_path)
	assert1(out != 0)
	# "deps" is derived from the step command via the declared output
	# (bin/mytool is produced as bin/mytool.stage + mv), inserted right
	# after "name"; the step passes through verbatim.
	assert_contains(out, c"\"name\": \"mytool_check\",\n\t\t\t\"deps\": [\"mytool\"],\n\t\t\t\"steps\"")
	assert_contains(out, c"{\"cmd\": [\"bin/mytool\", \"--check\"], \"expect_stdout\": \"ok\"}")
	# gate's own first step produces bin/gate_bin, so running it derives
	# nothing: no "deps" key at all, and "inputs" passes through.
	assert_contains(out, c"\"name\": \"gate\",\n\t\t\t\"inputs\": [\"w\"]")
	assert_contains(out, c"{\"cmd\": [\"bin/gate_bin\"]}")
	free(out)
	free(out_path)


void test_tool_targets_reject_declared_deps():
	char* dir = wdet_case_dir(c"tool_targets_deps")
	char* base = wdet_tool_base(c"\t\t\t{\"name\": \"declared\", \"deps\": [\"mytool\"], \"steps\": [{\"cmd\": [\"bin/mytool\"]}]}")
	wdet_write(dir, c"base.json", base)
	free(base)
	wdet_expect_error(dir, c"\"tool_targets\" entries must not declare \"deps\" (derived from the step commands): declared")


void test_tool_targets_reject_unknown_key():
	char* dir = wdet_case_dir(c"tool_targets_key")
	char* base = wdet_tool_base(c"\t\t\t{\"name\": \"keyed\", \"extra\": 1, \"steps\": [{\"cmd\": [\"bin/mytool\"]}]}")
	wdet_write(dir, c"base.json", base)
	free(base)
	wdet_expect_error(dir, c"unknown \"tool_targets\" entry key 'extra' in keyed")


void test_tool_targets_reject_unresolved_command():
	char* dir = wdet_case_dir(c"tool_targets_typo")
	char* base = wdet_tool_base(c"\t\t\t{\"name\": \"typo_check\", \"steps\": [{\"cmd\": [\"bin/nosuch\", \"--check\"]}]}")
	wdet_write(dir, c"base.json", base)
	free(base)
	wdet_expect_error(dir, c"\"tool_targets\" entry 'typo_check': step command is not the output of any base target (or of an earlier step): bin/nosuch")


void test_tool_targets_reject_hand_written_duplicate():
	char* dir = wdet_case_dir(c"tool_targets_dup")
	char* base = wdet_tool_base(c"\t\t\t{\"name\": \"mytool\", \"steps\": [{\"cmd\": [\"bin/mytool\"]}]}")
	wdet_write(dir, c"base.json", base)
	free(base)
	wdet_expect_error(dir, c"\"tool_targets\" entry is still hand-written in build.base.json's \"targets\" (delete the hand-written entry): mytool")


void test_step_directive_shape():
	char* dir = wdet_case_dir(c"step")
	wdet_write(dir, c"tests/steppy_test.w", c"# wbuild: x64\n# wbuild: step=\"bin/wv2 tests/bad_fixture.w -o bin/bad_fixture\" expect_fail expect_stderr=\"boom\" expect_stderr=\"bang\"\n# wbuild: step=\"cat\" stdin=\"a\\nb\" stdout_file=bin/gen.w timeout=500 reject_stdout=\"nope\"\nint main():\n\treturn 0\n")
	process_result* r = wdet_run(dir)
	assert_equal(0, r.status)
	process_result_free(r)
	char* out_path = path_join(dir, c"out.json")
	char* out = file_read_text(out_path)
	assert1(out != 0)
	# The extra steps follow the run step, each carrying only the fields
	# after its own step= token; repeated expectations use the array form.
	assert_contains(out, c"{\"cmd\": [\"bin/steppy_test\"]},\n\t\t\t\t{\"cmd\": [\"bin/wv2\", \"tests/bad_fixture.w\", \"-o\", \"bin/bad_fixture\"], \"expect_fail\": true, \"expect_stderr\": [\"boom\", \"bang\"]},")
	assert_contains(out, c"{\"cmd\": [\"cat\"], \"stdin\": \"a\\nb\", \"stdout_file\": \"bin/gen.w\", \"timeout_ms\": 500, \"reject_stdout\": \"nope\"}")
	# A step= target reruns every time (no cache inputs/outputs), but
	# its x64 twin, which the steps do not touch, keeps both.
	assert_lacks(out, c"\"inputs\": [\"tests/steppy_test.w\"],\n\t\t\t\"outputs\": [\"bin/steppy_test\"]")
	assert_contains(out, c"\"outputs\": [\"bin/steppy_64_test\"]")
	free(out)
	free(out_path)


void test_step_rejects_unknown_field():
	char* dir = wdet_case_dir(c"step_field")
	wdet_write(dir, c"tests/field_test.w", c"# wbuild: step=\"cat\" x64\nint main():\n\treturn 0\n")
	wdet_expect_error(dir, c"not a 'step=' field")


void test_step_rejects_two_per_line():
	char* dir = wdet_case_dir(c"step_twice")
	wdet_write(dir, c"tests/twice_test.w", c"# wbuild: step=\"cat\" step=\"cat\"\nint main():\n\treturn 0\n")
	wdet_expect_error(dir, c"one 'step=' per '# wbuild:' line")


void test_step_rejects_arch_only():
	char* dir = wdet_case_dir(c"step_arch_only")
	wdet_write(dir, c"tests/only_test.w", c"# wbuild: arch_only=x64\n# wbuild: step=\"cat\"\nint main():\n\treturn 0\n")
	wdet_expect_error(dir, c"'step=' needs a generated default-arch target")


void test_tags_join_umbrellas():
	char* dir = wdet_case_dir(c"tags")
	wdet_write(dir, c"base.json", c"{\n\t\"targets\": [\n\t\t{\n\t\t\t\"name\": \"hand\",\n\t\t\t\"tags\": [\"tests\"],\n\t\t\t\"steps\": [{\"cmd\": [\"true\"]}]\n\t\t},\n\t\t{\n\t\t\t\"name\": \"tests\",\n\t\t\t\"deps\": [\"tests_x64\"]\n\t\t},\n\t\t{\n\t\t\t\"name\": \"tests_x64\",\n\t\t\t\"deps\": []\n\t\t}\n\t]\n}\n")
	wdet_write(dir, c"tests/auto_test.w", c"int main():\n\treturn 0\n")
	process_result* r = wdet_run(dir)
	assert_equal(0, r.status)
	process_result_free(r)
	char* out_path = path_join(dir, c"out.json")
	char* out = file_read_text(out_path)
	assert1(out != 0)
	# The tagged hand-written target joins first, then the generated
	# one; "tags" itself is generator input and never reaches wexec.
	assert_contains(out, c"\"name\": \"tests\",\n\t\t\t\"deps\": [\n\t\t\t\t\"tests_x64\",\n\t\t\t\t\"hand\",\n\t\t\t\t\"auto_test\"\n\t\t\t]")
	assert_lacks(out, c"\"tags\"")
	free(out)
	free(out_path)


void test_tags_reject_unknown_umbrella():
	char* dir = wdet_case_dir(c"tags_unknown")
	wdet_write(dir, c"base.json", c"{\n\t\"targets\": [\n\t\t{\n\t\t\t\"name\": \"hand\",\n\t\t\t\"tags\": [\"testz\"],\n\t\t\t\"steps\": [{\"cmd\": [\"true\"]}]\n\t\t},\n\t\t{\n\t\t\t\"name\": \"tests\",\n\t\t\t\"deps\": []\n\t\t}\n\t]\n}\n")
	wdet_expect_error(dir, c"\"tags\" of hand names an unknown umbrella (a step-less build.base.json target): testz")


void test_binary_target_shape():
	char* dir = wdet_case_dir(c"binary")
	wdet_write(dir, c"tests/mytool.w", c"# wbuild: binary=mytool arch=x64 staged tag=tests dep=tests_x64\n# wbuild: step=\"bin/mytool --check 'two words' ''\" expect_status=3 stderr_file=bin/e.txt\nint main():\n\treturn 0\n")
	process_result* r = wdet_run(dir)
	assert_equal(0, r.status)
	process_result_free(r)
	char* out_path = path_join(dir, c"out.json")
	char* out = file_read_text(out_path)
	assert1(out != 0)
	# binary= implies the wv2 dep, the source input and the bin/<name>
	# output, and compiles through a staged copy; the step= line after
	# it keeps single-quoted words whole and '' as an empty argument.
	assert_contains(out, c"\"name\": \"mytool\",\n\t\t\t\"deps\": [\"wv2\", \"tests_x64\"],\n\t\t\t\"inputs\": [\"tests/mytool.w\"],\n\t\t\t\"outputs\": [\"bin/mytool\"],")
	assert_contains(out, c"{\"cmd\": [\"bin/wv2\", \"x64\", \"tests/mytool.w\", \"-o\", \"bin/mytool.stage\"]},\n\t\t\t\t{\"cmd\": [\"mv\", \"bin/mytool.stage\", \"bin/mytool\"]},\n\t\t\t\t{\"cmd\": [\"bin/mytool\", \"--check\", \"two words\", \"\"], \"expect_status\": 3, \"stderr_file\": \"bin/e.txt\"}")
	assert_contains(out, c"\"name\": \"tests\",\n\t\t\t\"deps\": [\n\t\t\t\t\"mytool\"\n\t\t\t]")
	assert_lacks(out, c"\"tags\"")
	free(out)
	free(out_path)


void test_target_after_test_directives():
	char* dir = wdet_case_dir(c"target")
	wdet_write(dir, c"tests/spelled_test.w", c"# wbuild: expect_stdout=\"hi\"\nint main():\n\treturn 0\n# wbuild: target=spelled input=tests/spelled_test.w output=bin/spelled.txt\n# wbuild: step=\"true\"\n")
	process_result* r = wdet_run(dir)
	assert_equal(0, r.status)
	process_result_free(r)
	char* out_path = path_join(dir, c"out.json")
	char* out = file_read_text(out_path)
	assert1(out != 0)
	# target= spells everything out (no implied deps), and its step=
	# lines never leak into the source's own conventional test target.
	assert_contains(out, c"\"name\": \"spelled\",\n\t\t\t\"inputs\": [\"tests/spelled_test.w\"],\n\t\t\t\"outputs\": [\"bin/spelled.txt\"],\n\t\t\t\"steps\": [\n\t\t\t\t{\"cmd\": [\"true\"]}\n\t\t\t]")
	assert_contains(out, c"{\"cmd\": [\"bin/spelled_test\"], \"expect_stdout\": \"hi\"}\n\t\t\t]")
	free(out)
	free(out_path)


void test_target_rejects_duplicate_name():
	char* dir = wdet_case_dir(c"target_dup")
	wdet_write(dir, c"tests/dup.w", c"# wbuild: target=tests\n# wbuild: step=\"true\"\n")
	wdet_expect_error(dir, c"target 'tests' is defined both in tests/dup.w and in build.base.json (or twice in sources)")


void test_target_rejects_no_steps():
	char* dir = wdet_case_dir(c"target_empty")
	wdet_write(dir, c"tests/empty.w", c"# wbuild: target=empty tag=tests\n")
	wdet_expect_error(dir, c"source-owned target has no steps (add step= lines after it): empty")


void test_target_rejects_misplaced_fields():
	char* dir = wdet_case_dir(c"target_fields")
	wdet_write(dir, c"tests/staged.w", c"# wbuild: target=staged staged\n# wbuild: step=\"true\"\n")
	wdet_expect_error(dir, c"'staged' only applies to 'binary=': 'staged' in tests/staged.w")
	dir = wdet_case_dir(c"target_midline")
	wdet_write(dir, c"tests/midline.w", c"# wbuild: tag=tests target=late\n# wbuild: step=\"true\"\n")
	wdet_expect_error(dir, c"'target='/'binary=' must start its own '# wbuild:' line: 'late' in tests/midline.w")


void test_cleanup():
	# Best-effort removal of the pid-scoped scratch root; a leftover
	# tree only wastes bin/ space (bin/ is gitignored and never walked
	# by the real manifest run).
	tool_rm_rf(wdet_dir())
