/*
wbuildgen: generates build.json from build.base.json plus the source tree.

build.base.json is the hand-maintained manifest: toolchain targets,
fixture targets, anything with expectations, stdin, timeouts, or an
unconventional shape. Conventional test targets are not written by hand;
wbuildgen derives them from the tree and appends them, so adding a plain
test is just creating the source file and rerunning `./wbuild manifest`.

Generation rules:

- Every `*_test.w` file under tests/, lib/, structures/, graphics/,
  libs/ and tools/ (walked recursively, like wexec's input hashing) is a
  candidate. A source dir/X_test.w yields the target

      {"name": "X_test", "deps": ["wv2"],
       "steps": [{"cmd": ["bin/wv2", "dir/X_test.w", "-o", "bin/X_test"]},
                 {"cmd": ["bin/X_test"]}]}

- `# wbuild:` directive lines in the source refine the generated
  targets: `x64` also yields the X_64_test twin (the same file compiled
  with the `x64` argument), and the key=value vocabulary documented
  above wbg_parse_directives (timeout=, stdin=, expect_stdout=,
  expect_stderr=, expect_fail, deps=, extra_compile=, arch=) adds
  run-step expectations, piped stdin, timeouts, declared run-time data
  inputs and extra compile-only steps — the irregular shapes that used
  to need hand-written base targets.
- The platform axis: `arch=arm64` and `arch=win64` yield run-capable
  twins X_arm64 / X_win64 (repeatable — e.g. `x64 arch=arm64` yields
  three targets from one source), mirroring the existing hand-written
  arm64/win64 test idiom byte for byte: `bin/wv2 arm64|win64
  dir/X_test.w -o bin/X_arm64|bin/X_win64.exe`, then `sh
  tools/run_arm64.sh bin/X_arm64` or `wine bin/X_win64.exe`. `arch=
  arm64_darwin` yields a compile-only twin X_darwin (Mach-O
  cross-compiled on Linux, matching graphics_darwin/net_darwin/
  pac_darwin — no run step; execution rides
  tools/mac/run_darwin_tests.sh on a Mac). Run-step directives
  (expect_stdout= and friends) decorate every run-capable twin
  generated from the source and are rejected when the source only
  generates compile-only (arm64_darwin) twins.
- Base wins by name: when build.base.json already defines X_test (or
  X_64_test, X_arm64, X_win64, X_darwin), that definition is kept and
  nothing is generated for the name. This is how a test with extra
  hand-written steps keeps its 32-bit target in base while still
  generating its conventional twin.
- Sources listed in build.base.json's "generate": {"exclude": [...]}
  are skipped entirely; that list holds sources whose targets live in
  base under unconventional names (crypto_base64_test for
  base64_test.w, the pac/darwin fixtures, the parser-generator outputs
  that cannot carry directives because they are regenerated and
  diffed). The "generate" key is not copied into build.json.
- Umbrellas: generated 32-bit and arm64_darwin (compile-only) targets
  are appended to "tests", and generated x64 / win64 twins to
  "tests_x64" / "tests_win64", each sorted by name, except names
  already pinned by an explicit mention in a step-less base target's
  deps (that is how sha2/hmac/hkdf/x25519's twins stay members of
  "tests" instead). Generated arm64 twins join no umbrella: like the
  hand-written arm64 run targets they mirror (build_arm64,
  dynamic_test_arm64, ...), they need qemu and stay individually
  invoked.
- Output is deterministic: base targets keep their order and field
  order, generated targets are appended sorted by name, and the same
  tree always serializes to byte-identical build.json.

Path-based target dependencies (2026-07, wave 2d — the bucket C/K gap
in docs/projects/build_system_next.md): before this, a generated
target's "deps" was always exactly ["wv2"] — a test whose compiled
binary shells out to another tool binary at runtime (wvc_e2e_test ->
bin/wvc, wexec_remote_cache_test -> bin/wexec) had no way to add that
tool to "deps" except by moving the whole target into build.base.json
by hand, and a family of wfixture-driven "run a list of *_fixture.w
files through wfixture" targets (warning_test, type_system_error_test,
...) had no single-source shape to hang a directive on at all. Two
additive mechanisms close both gaps without touching the existing
per-source generation rules above:

- `# wbuild: tool=<path>` (repeatable) on an ordinary generated
  `*_test.w` source resolves <path> — a tool's own .w source, e.g.
  "tools/wvc.w" — to the name of the *existing* build.base.json target
  that compiles it (wbg_find_target_by_source scans base targets for
  the "bin/wv2 [arch] <path> -o <binary>" shape every bucket-C tool
  target already has: single step, first arg "bin/wv2", <path>
  present verbatim), and appends that resolved name to the generated
  target's "deps" alongside "wv2". The tool target itself stays
  hand-written in build.base.json (it is not `*_test.w`-shaped, so
  wbuildgen's scan never touches it) — only the *dependent* stops
  needing a hand-written entry.
- Fixture-group targets, layered on the same resolver: a file (usually
  `tests/*_fixture.w`, but any scanned source works) carrying
  `# wbuild: fixture_group=<name>` is not compiled-and-run itself — it
  is one member of a single wfixture invocation named <name>, gathered
  from every file sharing that group name (alphabetical path order,
  since the scan already walks the tree in sorted order) into

      {"name": <name>, "deps": ["wv2", <wfixture's resolved name>],
       "steps": [{"cmd": [<wfixture's resolved binary>, "bin/wv2",
                  <member>, <member>, ...]}]}

  — exactly the shape every hand-written wfixture-driven bucket-K
  target already has. `wfixture`'s own target name and output binary
  path are looked up via the same wbg_find_target_by_source resolver
  the `tool=` directive uses (currently always "wfixture" /
  "bin/wfixture", but derived rather than hardcoded, so a rename keeps
  working). A fixture-group member cannot also carry a run/arch/tool/
  deps directive — it has no compile-and-run shape of its own, only a
  place in its group's wfixture invocation. Order note: a hand-written
  target's fixture list was sometimes in an intentional (non-
  alphabetical) order; the generated list is always alphabetical by
  path. This is a behavior-preserving reordering — each fixture's
  pass/fail is independent and wfixture's own exit status is an
  aggregate over all of them, so no target's assertions depend on
  invocation order (verified by diffing old vs. new build.json for
  every migrated target when this landed).

`fixture_group=` almost always needs the sidecar form
(`<fixture>.w.wbuild`, see wbg_parse_directives) rather than an inline
header line: a compile-diagnostic fixture's own `# expect_stderr:`
routinely embeds this file's exact line numbers (e.g. "got 3 bits at
<file>.w:10"), so inserting a header line shifts every line reference
below it and breaks the fixture it decorates — caught by actually
running the migrated fixture targets, not by inspection, which is why
every fixture-group member in this migration uses the sidecar.

Usage: wbuildgen [--check] [--base build.base.json] [--out build.json]

--check regenerates to bin/build.json.gen, byte-compares it with the
committed build.json, and exits 1 with a per-target drift summary when
they differ (the CI gate: `./wbuild manifest_check`). Without --check
the manifest is rewritten in place (`./wbuild manifest`).

Design notes: docs/projects/wexec.md (manifest generation section).
*/
import lib.lib
import lib.file
import lib.stream
import structures.string
import structures.json


json_value* wbg_base                     # parsed build.base.json
map[char*, json_value*] wbg_base_targets # name -> target object
list[char*] wbg_base_names               # base manifest order
map[char*, int] wbg_exclude              # source path -> 1
map[char*, int] wbg_pinned               # names listed in step-less base deps
list[json_value*] wbg_generated          # generated targets, sorted by name
map[char*, int] wbg_gen_seen             # generated names, for collisions
list[char*] wbg_gen32_names
list[char*] wbg_gen64_names
list[char*] wbg_gen_arm64_names
list[char*] wbg_gen_win64_names
list[char*] wbg_gen_darwin_names


# Arch codes for wbg_make_target/wbg_add_generated (functions, not
# global variables, so they read as constants like json_type_*()).
int wbg_arch_default():
	return 0


int wbg_arch_x64():
	return 1


int wbg_arch_arm64():
	return 2


int wbg_arch_win64():
	return 3


int wbg_arch_arm64_darwin():
	return 4


void wbg_error(char* message):
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"wbuildgen: error: ")
	stream_write_line(err, message)
	stream_flush(err)


void wbg_error2(char* message, char* detail):
	string_builder* s = string_new()
	string_append(s, message)
	string_append(s, detail)
	wbg_error(s.data)
	string_free(s)


void wbg_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: wbuildgen [--check] [--base build.base.json] [--out build.json]")
	stream_flush(err)


char* wbg_get_string(json_value* object, char* key):
	json_value* value = json_object_get(object, key)
	if (value == 0):
		return 0
	if (value.type != json_type_string()):
		return 0
	return value.string_value


int wbg_load_uint16(char* p):
	return (p[0] & 255) + ((p[1] & 255) << 8)


# Recursively collect every regular file under path, the same getdents
# walk wexec uses for directory inputs (d_reclen 2 bytes after the two
# word-sized ino/off fields, d_type in the record's last byte).
void wbg_collect_dir(char* path, list[char*] files):
	# 65536 = O_DIRECTORY
	int fd = open(path, 65536, 0)
	if (fd < 0):
		return
	int buffer_size = 65536
	char* buffer = malloc(buffer_size)
	int n = getdents(fd, buffer, buffer_size)
	while (n > 0):
		int off = 0
		while (off < n):
			char* entry = buffer + off
			int reclen = wbg_load_uint16(entry + 2 * __word_size__)
			char* entry_name = entry + 2 * __word_size__ + 2
			int kind = entry[reclen - 1] & 255
			if ((strcmp(entry_name, c".") != 0) && (strcmp(entry_name, c"..") != 0)):
				string_builder* child = string_new()
				string_append(child, path)
				string_append(child, c"/")
				string_append(child, entry_name)
				if (kind == 4):
					wbg_collect_dir(child.data, files)
					string_free(child)
				else if (kind == 8):
					char* owned = child.data
					free(child)
					files.push(owned)
				else:
					string_free(child)
			off = off + reclen
		n = getdents(fd, buffer, buffer_size)
	free(buffer)
	close(fd)


# Insertion sort: getdents order depends on filesystem state, and the
# output must not.
void wbg_sort_strings(list[char*] names):
	int i = 1
	while (i < names.length):
		char* value = names[i]
		int j = i - 1
		while ((j >= 0) && (strcmp(names[j], value) > 0)):
			names[j + 1] = names[j]
			j = j - 1
		names[j + 1] = value
		i = i + 1


char* wbg_basename(char* path):
	int i = 0
	int last = 0
	while (path[i] != 0):
		if (path[i] == '/'):
			last = i + 1
		i = i + 1
	return path + last


# The first (length - n) characters of text, as a fresh string.
char* wbg_strip_suffix(char* text, int n):
	int keep = strlen(text) - n
	string_builder* s = string_new()
	int i = 0
	while (i < keep):
		string_append_char(s, text[i])
		i = i + 1
	char* out = s.data
	free(s)
	return out


char* wbg_concat(char* left, char* right):
	string_builder* s = string_new()
	string_append(s, left)
	string_append(s, right)
	char* out = s.data
	free(s)
	return out


/* Directive parsing.

A directive is a source line starting with "# wbuild:" followed by
whitespace-separated tokens; a source may carry several such lines.
Bare tokens are flags; key=value tokens carry a value, either a bare
word or a double-quoted string with \n, \t, \", \\ escapes. The
vocabulary:

  x64                      also generate the X_64_test twin
  arch=x64                 keyed spelling of the same flag
  arch=arm64               also generate the X_arm64 twin: compiled
                           with `arm64`, run wrapped in `sh
                           tools/run_arm64.sh` (qemu, or native on an
                           arm64 Linux host — see tools/run_arm64.sh)
  arch=win64               also generate the X_win64 twin: compiled
                           with `win64` to bin/X_win64.exe, run wrapped
                           in `wine` (present or not, the target's
                           shape is identical; it just fails to spawn
                           without wine, same as the hand-written win64
                           targets)
  arch=arm64_darwin        also generate the X_darwin twin: compiled
                           with `arm64_darwin` (Mach-O, cross-compiled
                           on Linux), compile-only — no run step, since
                           running needs a Mac (tools/mac/
                           run_darwin_tests.sh)
  expect_fail              the run step must exit nonzero
  timeout=<ms>             "timeout_ms" on the run step
  stdin="text"             text piped to the run step's stdin
  expect_stdout="substr"   the run step's stdout must contain substr
  expect_stderr="substr"   same for stderr; both are repeatable, and
                           several values emit the array form
  deps=<path>              declare a non-W run-time input (a data
                           file, or a directory prefix ending in '/');
                           emitted as the target-level "data" array,
                           which bin/wtest matches changed paths
                           against (tools/test_map.w, rule a)
  extra_compile="args"     append one more 'bin/wv2 <args>' step
                           (whitespace-split, no shell) after the run
                           step, on the default-arch target only
  tool=<path>              resolve <path> (another tool's own .w
                           source, e.g. "tools/wvc.w") to the name of
                           the build.base.json target that compiles
                           it, and append that name to the generated
                           target's "deps" alongside "wv2" (repeatable;
                           see wbg_find_target_by_source below)

Run-step fields apply to every run-capable target generated from the
source (32-bit, x64, arm64, win64 twins alike — arm64_darwin has no run
step to decorate). `tool=` applies to every twin the source generates,
run-capable or not, since it is a build-order dependency, not a run-step
decoration. Unknown tokens, malformed values, and directives that no
generated target can honor are errors, so typos fail the manifest run
instead of silently generating nothing.

A separate, fixture-group-only directive is documented above
wbg_dir_fixture_group below: `# wbuild: fixture_group=<name>` does not
belong to a generated *_test.w run target at all, so it is parsed by
the same wbg_parse_directives/wbg_apply_directive machinery but handled
by its own code path in wbg_scan rather than by wbg_make_target. */


int wbg_dir_x64
int wbg_dir_arm64
int wbg_dir_win64
int wbg_dir_arm64_darwin
int wbg_dir_expect_fail
int wbg_dir_timeout_ms             # 0 = unset
char* wbg_dir_stdin                # 0 = unset
list[char*] wbg_dir_expect_stdout
list[char*] wbg_dir_expect_stderr
list[char*] wbg_dir_extra_compile
list[char*] wbg_dir_data
list[char*] wbg_dir_tool           # resolved target names from 'tool=' directives

# '# wbuild: fixture_group=<name>' (fixture files only — see wbg_scan's
# fixture-group pass): the file is not compiled/run itself, it is one
# member of the single wfixture invocation named <name>. 0 = unset.
char* wbg_dir_fixture_group


void wbg_reset_directives():
	wbg_dir_x64 = 0
	wbg_dir_arm64 = 0
	wbg_dir_win64 = 0
	wbg_dir_arm64_darwin = 0
	wbg_dir_expect_fail = 0
	wbg_dir_timeout_ms = 0
	wbg_dir_stdin = 0
	wbg_dir_expect_stdout = new list[char*]
	wbg_dir_expect_stderr = new list[char*]
	wbg_dir_extra_compile = new list[char*]
	wbg_dir_data = new list[char*]
	wbg_dir_tool = new list[char*]
	wbg_dir_fixture_group = 0


# Directives that decorate the generated run step (as opposed to the
# x64 flag, which chooses what to generate).
int wbg_dir_has_run_fields():
	if (wbg_dir_expect_fail | (wbg_dir_timeout_ms > 0)):
		return 1
	if (wbg_dir_stdin != 0):
		return 1
	if ((wbg_dir_expect_stdout.length > 0) || (wbg_dir_expect_stderr.length > 0)):
		return 1
	return 0


void wbg_token_error(char* path, char* message, char* token):
	string_builder* s = string_new()
	string_append(s, message)
	string_append(s, c"'")
	string_append(s, token)
	string_append(s, c"' in ")
	string_append(s, path)
	wbg_error(s.data)
	string_free(s)


# Strictly-digits millisecond count; -1 on anything else.
int wbg_parse_ms(char* text):
	if (text[0] == 0):
		return -1
	int value = 0
	int i = 0
	while (text[i] != 0):
		if ((text[i] < '0') || (text[i] > '9')):
			return -1
		value = value * 10 + (text[i] - '0')
		i = i + 1
	return value


int wbg_need_value(char* path, char* key, int has_value):
	if (has_value):
		return 0
	wbg_token_error(path, c"missing value for '# wbuild:' directive ", key)
	return 1


int wbg_no_value(char* path, char* key, int has_value):
	if (has_value == 0):
		return 0
	wbg_token_error(path, c"'# wbuild:' flag takes no value: ", key)
	return 1


/* Path-based tool-dependency resolution (wave 2d).

wbg_find_target_by_source is the one mechanism both new directives
build on: given a tool's own .w source path, find the existing
build.base.json target that compiles it, so a generated target's
"deps" (or a fixture-group target's "deps" and step "cmd") can
reference that target by its *resolved* name/binary instead of the
generator hardcoding it. */

# The output path a base target's first compile step produces: the
# argument immediately following "-o" in that step's "cmd" array.
# Returns 0 if the shape doesn't match (defensive — every bucket-C
# tool target and every generated _test.w target has this shape).
char* wbg_target_binary_path(json_value* target):
	json_value* steps = json_object_get(target, c"steps")
	if ((steps == 0) || (steps.type != json_type_array()) || (json_array_length(steps) == 0)):
		return 0
	json_value* first = json_array_get(steps, 0)
	json_value* cmd = json_object_get(first, c"cmd")
	if ((cmd == 0) || (cmd.type != json_type_array())):
		return 0
	int i = 0
	while (i < json_array_length(cmd)):
		json_value* element = json_array_get(cmd, i)
		if ((element.type == json_type_string()) && (strcmp(element.string_value, c"-o") == 0) && (i + 1 < json_array_length(cmd))):
			json_value* out = json_array_get(cmd, i + 1)
			if (out.type == json_type_string()):
				return out.string_value
		i = i + 1
	return 0


# Finds the build.base.json target whose first step compiles src_path
# directly: "bin/wv2 [arch] <src_path> -o <binary>" — the shape every
# bucket-C tool target (wfixture, wvc, wexec, ...) already has by hand.
# Returns the target's json_value, or 0 if no base target matches.
json_value* wbg_find_target_by_source(char* src_path):
	for char* name in wbg_base_names:
		json_value* target = wbg_base_targets[name]
		json_value* steps = json_object_get(target, c"steps")
		if ((steps == 0) || (steps.type != json_type_array()) || (json_array_length(steps) == 0)):
			continue
		json_value* first = json_array_get(steps, 0)
		json_value* cmd = json_object_get(first, c"cmd")
		if ((cmd == 0) || (cmd.type != json_type_array()) || (json_array_length(cmd) < 1)):
			continue
		json_value* head = json_array_get(cmd, 0)
		if ((head.type != json_type_string()) || (strcmp(head.string_value, c"bin/wv2") != 0)):
			continue
		int i = 1
		int matched = 0
		while ((i < json_array_length(cmd)) && (matched == 0)):
			json_value* element = json_array_get(cmd, i)
			if ((element.type == json_type_string()) && (strcmp(element.string_value, src_path) == 0)):
				matched = 1
			i = i + 1
		if (matched):
			return target
	return 0


# The target name for a 'tool=' (or fixture-group) path: wraps
# wbg_find_target_by_source, returning just the resolved name. Returns
# 0 if no base target compiles src_path.
char* wbg_resolve_tool_name(char* src_path):
	json_value* target = wbg_find_target_by_source(src_path)
	if (target == 0):
		return 0
	return wbg_get_string(target, c"name")


# Applies one parsed key[=value] token to the wbg_dir_* state.
# Returns 0 on success, 1 after reporting an error.
int wbg_apply_directive(char* path, char* key, int has_value, char* value):
	if (strcmp(key, c"x64") == 0):
		if (wbg_no_value(path, key, has_value)):
			return 1
		wbg_dir_x64 = 1
		return 0
	if (strcmp(key, c"expect_fail") == 0):
		if (wbg_no_value(path, key, has_value)):
			return 1
		wbg_dir_expect_fail = 1
		return 0
	if (strcmp(key, c"arch") == 0):
		if (wbg_need_value(path, key, has_value)):
			return 1
		if (strcmp(value, c"x64") == 0):
			wbg_dir_x64 = 1
			return 0
		if (strcmp(value, c"arm64") == 0):
			wbg_dir_arm64 = 1
			return 0
		if (strcmp(value, c"win64") == 0):
			wbg_dir_win64 = 1
			return 0
		if (strcmp(value, c"arm64_darwin") == 0):
			wbg_dir_arm64_darwin = 1
			return 0
		wbg_token_error(path, c"unsupported '# wbuild:' arch (x64, arm64, win64, arm64_darwin) ", value)
		return 1
	if (strcmp(key, c"timeout") == 0):
		if (wbg_need_value(path, key, has_value)):
			return 1
		if (wbg_dir_timeout_ms != 0):
			wbg_token_error(path, c"duplicate '# wbuild:' directive ", key)
			return 1
		int ms = wbg_parse_ms(value)
		if (ms <= 0):
			wbg_token_error(path, c"'# wbuild:' timeout needs a positive millisecond count, got ", value)
			return 1
		wbg_dir_timeout_ms = ms
		return 0
	if (strcmp(key, c"stdin") == 0):
		if (wbg_need_value(path, key, has_value)):
			return 1
		if (wbg_dir_stdin != 0):
			wbg_token_error(path, c"duplicate '# wbuild:' directive ", key)
			return 1
		wbg_dir_stdin = strclone(value)
		return 0
	if ((strcmp(key, c"expect_stdout") == 0) | (strcmp(key, c"expect_stderr") == 0)):
		if (wbg_need_value(path, key, has_value)):
			return 1
		if (value[0] == 0):
			wbg_token_error(path, c"empty '# wbuild:' expectation ", key)
			return 1
		if (strcmp(key, c"expect_stdout") == 0):
			wbg_dir_expect_stdout.push(strclone(value))
		else:
			wbg_dir_expect_stderr.push(strclone(value))
		return 0
	if (strcmp(key, c"deps") == 0):
		if (wbg_need_value(path, key, has_value)):
			return 1
		if (ends_with(value, c".w")):
			wbg_token_error(path, c"'deps=' is for non-W inputs, imports already track ", value)
			return 1
		# A missing path usually means a typo or a deleted data file;
		# fail loudly, like generate.exclude staleness.
		int fd = open(value, 0, 0)
		if (fd < 0):
			wbg_token_error(path, c"'# wbuild:' deps path does not exist: ", value)
			return 1
		close(fd)
		wbg_dir_data.push(strclone(value))
		return 0
	if (strcmp(key, c"extra_compile") == 0):
		if (wbg_need_value(path, key, has_value)):
			return 1
		if (value[0] == 0):
			wbg_token_error(path, c"empty '# wbuild:' directive ", key)
			return 1
		wbg_dir_extra_compile.push(strclone(value))
		return 0
	if (strcmp(key, c"tool") == 0):
		if (wbg_need_value(path, key, has_value)):
			return 1
		if (ends_with(value, c".w") == 0):
			wbg_token_error(path, c"'tool=' expects a tool's '.w' source path, got ", value)
			return 1
		# A missing path usually means a typo; fail loudly, like deps=.
		int fd = open(value, 0, 0)
		if (fd < 0):
			wbg_token_error(path, c"'# wbuild:' tool path does not exist: ", value)
			return 1
		close(fd)
		char* tool_name = wbg_resolve_tool_name(value)
		if (tool_name == 0):
			wbg_token_error(path, c"'tool=' path has no matching build.base.json compile target (want 'bin/wv2 <path> -o bin/<name>'): ", value)
			return 1
		wbg_dir_tool.push(strclone(tool_name))
		return 0
	if (strcmp(key, c"fixture_group") == 0):
		if (wbg_need_value(path, key, has_value)):
			return 1
		if (wbg_dir_fixture_group != 0):
			wbg_token_error(path, c"duplicate '# wbuild:' directive ", key)
			return 1
		if (value[0] == 0):
			wbg_token_error(path, c"empty '# wbuild:' directive ", key)
			return 1
		wbg_dir_fixture_group = strclone(value)
		return 0
	wbg_token_error(path, c"unknown '# wbuild:' directive ", key)
	return 1


# Parses a directive value at text[j]: a bare word, or a double-quoted
# string with \n \t \" \\ escapes. Appends the decoded value to out;
# returns the index just past the value, or -1 on a malformed value.
int wbg_parse_value(char* text, int j, string_builder* out):
	if (text[j] != '"'):
		while ((text[j] != 0) && (text[j] != '\n') && (text[j] != ' ') && (text[j] != '\t')):
			string_append_char(out, text[j])
			j = j + 1
		return j
	j = j + 1
	while (text[j] != '"'):
		if ((text[j] == 0) || (text[j] == '\n')):
			return -1
		if (text[j] == 92):
			j = j + 1
			if (text[j] == 'n'):
				string_append_char(out, '\n')
			else if (text[j] == 't'):
				string_append_char(out, '\t')
			else if (text[j] == '"'):
				string_append_char(out, '"')
			else if (text[j] == 92):
				string_append_char(out, 92)
			else:
				return -1
		else:
			string_append_char(out, text[j])
		j = j + 1
	return j + 1


# One whitespace-delimited key[=value] token starting at text[j].
# Returns the index just past the token, or -1 after reporting an
# error against path.
int wbg_parse_directive_token(char* text, int j, char* path):
	string_builder* key = string_new()
	while ((text[j] != 0) && (text[j] != '\n') && (text[j] != ' ') && (text[j] != '\t') && (text[j] != '=')):
		string_append_char(key, text[j])
		j = j + 1
	int has_value = text[j] == '='
	string_builder* value = string_new()
	if (has_value):
		j = wbg_parse_value(text, j + 1, value)
		if (j < 0):
			wbg_token_error(path, c"malformed '# wbuild:' value for ", key.data)
			string_free(key)
			string_free(value)
			return -1
	int failed = wbg_apply_directive(path, key.data, has_value, value.data)
	string_free(key)
	string_free(value)
	if (failed):
		return -1
	return j


# Parses every "# wbuild:" line of the source into the wbg_dir_*
# state. Returns 0 on success, -1 after reporting errors.
#
# Sidecar fallback (mirrors wfixture's own "<fixture>.expect" fallback,
# tools/wfixture.w): a source whose byte content cannot safely carry an
# extra header line -- a compile-diagnostic fixture whose own
# expect_stderr text embeds this file's exact line numbers, so any
# inserted line would shift every reference below it, or a fixture that
# deliberately ends without a trailing newline -- may put its
# '# wbuild:' directive lines in a "<path>.wbuild" file next to it
# instead. When the sidecar exists it is read instead of the source
# (never both), so the source's own bytes stay untouched.
int wbg_parse_directives(char* path):
	wbg_reset_directives()
	string_builder* sidecar_path = string_new()
	string_append(sidecar_path, path)
	string_append(sidecar_path, c".wbuild")
	char* text = file_read_text(sidecar_path.data)
	string_free(sidecar_path)
	if (text == 0):
		text = file_read_text(path)
	if (text == 0):
		wbg_error2(c"cannot read source ", path)
		return -1
	int failed = 0
	int at_line_start = 1
	int i = 0
	while (text[i] != 0):
		if (at_line_start && starts_with(text + i, c"# wbuild:")):
			int j = i + 9
			int at_end = 0
			while (at_end == 0):
				while ((text[j] == ' ') || (text[j] == '\t')):
					j = j + 1
				if ((text[j] == 0) || (text[j] == '\n')):
					at_end = 1
				else:
					j = wbg_parse_directive_token(text, j, path)
					if (j < 0):
						failed = 1
						at_end = 1
		at_line_start = text[i] == '\n'
		i = i + 1
	free(text)
	if (failed):
		return -1
	return 0


int wbg_load_base(char* path):
	char* text = file_read_text(path)
	if (text == 0):
		wbg_error2(c"cannot read base manifest ", path)
		return 1
	wbg_base = json_parse(text)
	free(text)
	if (wbg_base == 0):
		wbg_error2(c"base manifest is not valid JSON: ", path)
		return 1
	if (wbg_base.type != json_type_object()):
		wbg_error2(c"base manifest root must be a JSON object: ", path)
		return 1
	json_value* targets = json_object_get(wbg_base, c"targets")
	if (targets == 0):
		wbg_error2(c"base manifest has no \"targets\" array: ", path)
		return 1
	if (targets.type != json_type_array()):
		wbg_error2(c"\"targets\" must be an array: ", path)
		return 1

	wbg_base_targets = new map[char*, json_value*]
	wbg_base_names = new list[char*]
	wbg_pinned = new map[char*, int]
	int i = 0
	while (i < json_array_length(targets)):
		json_value* target = json_array_get(targets, i)
		if (target.type != json_type_object()):
			wbg_error2(c"every target must be a JSON object: ", path)
			return 1
		char* name = wbg_get_string(target, c"name")
		if (name == 0):
			wbg_error2(c"target without a \"name\" string: ", path)
			return 1
		if (name in wbg_base_targets):
			wbg_error2(c"duplicate base target ", name)
			return 1
		wbg_base_targets[name] = target
		wbg_base_names.push(name)
		# Deps of step-less (umbrella) targets pin their members: a
		# generated name listed there keeps that hand-chosen placement
		# instead of being auto-appended to its conventional umbrella.
		if (json_object_has(target, c"steps") == 0):
			json_value* deps = json_object_get(target, c"deps")
			if (deps != 0):
				if (deps.type == json_type_array()):
					int d = 0
					while (d < json_array_length(deps)):
						json_value* dep = json_array_get(deps, d)
						if (dep.type == json_type_string()):
							wbg_pinned[dep.string_value] = 1
						d = d + 1
		i = i + 1

	wbg_exclude = new map[char*, int]
	json_value* generate = json_object_get(wbg_base, c"generate")
	if (generate != 0):
		if (generate.type != json_type_object()):
			wbg_error(c"\"generate\" must be an object")
			return 1
		json_value* exclude = json_object_get(generate, c"exclude")
		if (exclude != 0):
			if (exclude.type != json_type_array()):
				wbg_error(c"\"generate\".\"exclude\" must be an array")
				return 1
			int e = 0
			while (e < json_array_length(exclude)):
				json_value* entry = json_array_get(exclude, e)
				if (entry.type != json_type_string()):
					wbg_error(c"\"generate\".\"exclude\" entries must be strings")
					return 1
				# A stale entry usually means a test was deleted without
				# updating the base manifest; fail loudly.
				int fd = open(entry.string_value, 0, 0)
				if (fd < 0):
					wbg_error2(c"generate.exclude entry does not exist: ", entry.string_value)
					return 1
				close(fd)
				wbg_exclude[entry.string_value] = 1
				e = e + 1
	return 0


# The manifest form of repeated expect_* directives: a bare string
# for one value, the array form for several (both accepted by wexec).
json_value* wbg_expectation(list[char*] values):
	if (values.length == 1):
		return json_string(values[0])
	json_value* out = json_array()
	for char* value in values:
		json_array_push(out, json_string(value))
	return out


# An "extra_compile=" step: 'bin/wv2' plus the directive's args,
# whitespace-split (no shell).
json_value* wbg_extra_compile_step(char* args):
	json_value* cmd = json_array()
	json_array_push(cmd, json_string(c"bin/wv2"))
	string_builder* token = string_new()
	int i = 0
	int at_end = 0
	while (at_end == 0):
		int c = args[i]
		if ((c == ' ') || (c == '\t') || (c == 0)):
			if (token.length > 0):
				json_array_push(cmd, json_string(token.data))
				string_clear(token)
			if (c == 0):
				at_end = 1
		else:
			string_append_char(token, c)
		i = i + 1
	string_free(token)
	json_value* step = json_object()
	json_object_set(step, c"cmd", cmd)
	return step


# The arch flag token passed to bin/wv2 for a non-default arch, or 0
# for the default (32-bit x86) arch.
char* wbg_arch_flag(int arch):
	if (arch == wbg_arch_x64()):
		return c"x64"
	if (arch == wbg_arch_arm64()):
		return c"arm64"
	if (arch == wbg_arch_win64()):
		return c"win64"
	if (arch == wbg_arch_arm64_darwin()):
		return c"arm64_darwin"
	return 0


json_value* wbg_make_target(char* name, char* src, int arch):
	char* ext = c""
	if (arch == wbg_arch_win64()):
		ext = c".exe"
	char* stem = wbg_concat(c"bin/", name)
	char* binary = wbg_concat(stem, ext)
	free(stem)
	json_value* target = json_object()
	json_object_set(target, c"name", json_string(name))
	json_value* deps = json_array()
	json_array_push(deps, json_string(c"wv2"))
	for char* tool_name in wbg_dir_tool:
		json_array_push(deps, json_string(tool_name))
	json_object_set(target, c"deps", deps)
	if (wbg_dir_data.length > 0):
		json_value* data = json_array()
		for char* entry in wbg_dir_data:
			json_array_push(data, json_string(entry))
		json_object_set(target, c"data", data)
	json_value* compile_cmd = json_array()
	json_array_push(compile_cmd, json_string(c"bin/wv2"))
	char* flag = wbg_arch_flag(arch)
	if (flag != 0):
		json_array_push(compile_cmd, json_string(flag))
	json_array_push(compile_cmd, json_string(src))
	json_array_push(compile_cmd, json_string(c"-o"))
	json_array_push(compile_cmd, json_string(binary))
	json_value* compile_step = json_object()
	json_object_set(compile_step, c"cmd", compile_cmd)
	json_value* steps = json_array()
	json_array_push(steps, compile_step)
	# arm64_darwin is compile-only: no runner runs Mach-O on Linux, so
	# there is no run step to decorate or append to.
	if (arch != wbg_arch_arm64_darwin()):
		json_value* run_cmd = json_array()
		if (arch == wbg_arch_arm64()):
			json_array_push(run_cmd, json_string(c"sh"))
			json_array_push(run_cmd, json_string(c"tools/run_arm64.sh"))
		else if (arch == wbg_arch_win64()):
			json_array_push(run_cmd, json_string(c"wine"))
		json_array_push(run_cmd, json_string(binary))
		json_value* run_step = json_object()
		json_object_set(run_step, c"cmd", run_cmd)
		if (wbg_dir_stdin != 0):
			json_object_set(run_step, c"stdin", json_string(wbg_dir_stdin))
		if (wbg_dir_expect_fail):
			json_object_set(run_step, c"expect_fail", json_bool(1))
		if (wbg_dir_expect_stdout.length > 0):
			json_object_set(run_step, c"expect_stdout", wbg_expectation(wbg_dir_expect_stdout))
		if (wbg_dir_expect_stderr.length > 0):
			json_object_set(run_step, c"expect_stderr", wbg_expectation(wbg_dir_expect_stderr))
		if (wbg_dir_timeout_ms > 0):
			json_object_set(run_step, c"timeout_ms", json_int(wbg_dir_timeout_ms))
		json_array_push(steps, run_step)
		if (arch == wbg_arch_default()):
			for char* args in wbg_dir_extra_compile:
				json_array_push(steps, wbg_extra_compile_step(args))
	json_object_set(target, c"steps", steps)
	free(binary)
	return target


int wbg_add_generated(char* name, char* src, int arch):
	if (name in wbg_gen_seen):
		string_builder* s = string_new()
		string_append(s, c"generated target '")
		string_append(s, name)
		string_append(s, c"' collides (from ")
		string_append(s, src)
		string_append(s, c")")
		wbg_error(s.data)
		string_free(s)
		return 1
	wbg_gen_seen[name] = 1
	wbg_generated.push(wbg_make_target(name, src, arch))
	if (arch == wbg_arch_x64()):
		wbg_gen64_names.push(name)
	else if (arch == wbg_arch_arm64()):
		wbg_gen_arm64_names.push(name)
	else if (arch == wbg_arch_win64()):
		wbg_gen_win64_names.push(name)
	else if (arch == wbg_arch_arm64_darwin()):
		wbg_gen_darwin_names.push(name)
	else:
		wbg_gen32_names.push(name)
	return 0


void wbg_sort_generated():
	int i = 1
	while (i < wbg_generated.length):
		json_value* value = wbg_generated[i]
		char* name = wbg_get_string(value, c"name")
		int j = i - 1
		while ((j >= 0) && (strcmp(wbg_get_string(wbg_generated[j], c"name"), name) > 0)):
			wbg_generated[j + 1] = wbg_generated[j]
			j = j - 1
		wbg_generated[j + 1] = value
		i = i + 1


# The single wfixture invocation for one fixture-group: the shape
# every hand-written wfixture-driven bucket-K target (warning_test and
# friends) already has by hand —
#   {"name": name, "deps": ["wv2", wfixture_name],
#    "steps": [{"cmd": [wfixture_bin, "bin/wv2", <member>, ...]}]}
# wfixture_name/wfixture_bin come from wbg_find_target_by_source
# resolving "tools/wfixture.w", not a hardcoded "wfixture" — see
# wbg_scan's fixture-group pass.
json_value* wbg_make_fixture_group_target(char* name, list[char*] members, char* wfixture_name, char* wfixture_bin):
	json_value* target = json_object()
	json_object_set(target, c"name", json_string(name))
	json_value* deps = json_array()
	json_array_push(deps, json_string(c"wv2"))
	json_array_push(deps, json_string(wfixture_name))
	json_object_set(target, c"deps", deps)
	json_value* cmd = json_array()
	json_array_push(cmd, json_string(wfixture_bin))
	json_array_push(cmd, json_string(c"bin/wv2"))
	for char* member in members:
		json_array_push(cmd, json_string(member))
	json_value* step = json_object()
	json_object_set(step, c"cmd", cmd)
	json_value* steps = json_array()
	json_array_push(steps, step)
	json_object_set(target, c"steps", steps)
	return target


int wbg_add_fixture_group_target(char* name, list[char*] members, char* wfixture_name, char* wfixture_bin):
	if (name in wbg_base_targets):
		wbg_error2(c"'fixture_group=' target is still hand-written in build.base.json (migration incomplete): ", name)
		return 1
	if (name in wbg_gen_seen):
		string_builder* s = string_new()
		string_append(s, c"generated target '")
		string_append(s, name)
		string_append(s, c"' collides (fixture group)")
		wbg_error(s.data)
		string_free(s)
		return 1
	wbg_gen_seen[name] = 1
	wbg_generated.push(wbg_make_fixture_group_target(name, members, wfixture_name, wfixture_bin))
	return 0


int wbg_scan():
	wbg_generated = new list[json_value*]
	wbg_gen_seen = new map[char*, int]
	wbg_gen32_names = new list[char*]
	wbg_gen64_names = new list[char*]
	wbg_gen_arm64_names = new list[char*]
	wbg_gen_win64_names = new list[char*]
	wbg_gen_darwin_names = new list[char*]

	list[char*] files = new list[char*]
	wbg_collect_dir(c"tests", files)
	wbg_collect_dir(c"lib", files)
	wbg_collect_dir(c"structures", files)
	wbg_collect_dir(c"graphics", files)
	wbg_collect_dir(c"libs", files)
	wbg_collect_dir(c"tools", files)
	wbg_sort_strings(files)

	# Fixture-group accumulation (wave 2d): members are collected here,
	# in the same alphabetical path order 'files' already has, and
	# turned into one generated target per group name after the main
	# loop (see below wbg_sort_generated()).
	map[char*, list[char*]] fixture_groups = new map[char*, list[char*]]
	list[char*] fixture_group_names = new list[char*]

	for char* src in files:
		int is_test = ends_with(src, c"_test.w")
		int is_fixture = ends_with(src, c"_fixture.w")
		if ((is_test == 0) && (is_fixture == 0)):
			continue
		if (src in wbg_exclude):
			continue
		if (wbg_parse_directives(src)):
			return 1
		if (wbg_dir_fixture_group != 0):
			# A fixture-group member has no compile-and-run shape of its
			# own — it is one line in its group's single wfixture
			# invocation — so run/arch/tool/deps directives (which all
			# decorate or extend a generated compile+run target) do not
			# apply here; catch a copy-paste mistake instead of silently
			# ignoring it.
			int forbidden = wbg_dir_x64 | wbg_dir_arm64 | wbg_dir_win64 | wbg_dir_arm64_darwin | wbg_dir_has_run_fields() | (wbg_dir_extra_compile.length > 0) | (wbg_dir_tool.length > 0) | (wbg_dir_data.length > 0)
			if (forbidden):
				wbg_error2(c"'fixture_group=' cannot combine with run/arch/tool/deps directives: ", src)
				return 1
			if ((wbg_dir_fixture_group in fixture_groups) == 0):
				fixture_groups[wbg_dir_fixture_group] = new list[char*]
				fixture_group_names.push(wbg_dir_fixture_group)
			fixture_groups[wbg_dir_fixture_group].push(strclone(src))
			continue
		if (is_test == 0):
			continue
		char* name32 = wbg_strip_suffix(wbg_basename(src), 2)
		int gen32 = 0
		int gen64 = 0
		int gen_arm64 = 0
		int gen_win64 = 0
		int gen_darwin = 0
		if ((name32 in wbg_base_targets) == 0):
			if (wbg_add_generated(name32, strclone(src), wbg_arch_default())):
				return 1
			gen32 = 1
		if (wbg_dir_x64):
			char* stem = wbg_strip_suffix(name32, 5)
			char* name64 = wbg_concat(stem, c"_64_test")
			free(stem)
			if ((name64 in wbg_base_targets) == 0):
				if (wbg_add_generated(name64, strclone(src), wbg_arch_x64())):
					return 1
				gen64 = 1
		if (wbg_dir_arm64):
			char* name_arm64 = wbg_concat(name32, c"_arm64")
			if ((name_arm64 in wbg_base_targets) == 0):
				if (wbg_add_generated(name_arm64, strclone(src), wbg_arch_arm64())):
					return 1
				gen_arm64 = 1
		if (wbg_dir_win64):
			char* name_win64 = wbg_concat(name32, c"_win64")
			if ((name_win64 in wbg_base_targets) == 0):
				if (wbg_add_generated(name_win64, strclone(src), wbg_arch_win64())):
					return 1
				gen_win64 = 1
		if (wbg_dir_arm64_darwin):
			char* name_darwin = wbg_concat(name32, c"_darwin")
			if ((name_darwin in wbg_base_targets) == 0):
				if (wbg_add_generated(name_darwin, strclone(src), wbg_arch_arm64_darwin())):
					return 1
				gen_darwin = 1
		# Directives that nothing generated can honor are as fatal as
		# typos: they mean the target moved to build.base.json without
		# the source shedding its directive lines (or vice versa).
		int gen_run_capable = gen32 | gen64 | gen_arm64 | gen_win64
		int gen_any = gen_run_capable | gen_darwin
		if ((gen32 == 0) && (wbg_dir_extra_compile.length > 0)):
			wbg_error2(c"'extra_compile=' needs a generated default target, but build.base.json defines it: ", src)
			return 1
		if ((gen_run_capable == 0) && wbg_dir_has_run_fields()):
			wbg_error2(c"'# wbuild:' run-step directives have no generated run-capable target (only compile-only twins, or build.base.json defines them all): ", src)
			return 1
		if ((gen_any == 0) && (wbg_dir_data.length > 0)):
			wbg_error2(c"'# wbuild:' directives have no generated target (build.base.json defines them all): ", src)
			return 1
		if ((gen_any == 0) && (wbg_dir_tool.length > 0)):
			wbg_error2(c"'tool=' directive has no generated target (build.base.json defines them all): ", src)
			return 1

	# One wfixture invocation per fixture-group name, resolved via the
	# same wbg_find_target_by_source path-based lookup 'tool=' uses —
	# see the module doc comment's "Path-based target dependencies"
	# section.
	if (fixture_group_names.length > 0):
		json_value* wfixture_target = wbg_find_target_by_source(c"tools/wfixture.w")
		if (wfixture_target == 0):
			wbg_error(c"'fixture_group=' targets need a build.base.json target compiling tools/wfixture.w")
			return 1
		char* wfixture_name = wbg_get_string(wfixture_target, c"name")
		char* wfixture_bin = wbg_target_binary_path(wfixture_target)
		if (wfixture_bin == 0):
			wbg_error2(c"cannot determine wfixture's output binary from target ", wfixture_name)
			return 1
		for char* group_name in fixture_group_names:
			if (wbg_add_fixture_group_target(group_name, fixture_groups[group_name], wfixture_name, wfixture_bin)):
				return 1

	wbg_sort_generated()
	wbg_sort_strings(wbg_gen32_names)
	wbg_sort_strings(wbg_gen64_names)
	wbg_sort_strings(wbg_gen_arm64_names)
	wbg_sort_strings(wbg_gen_win64_names)
	wbg_sort_strings(wbg_gen_darwin_names)
	return 0


# Append the generated members of one umbrella (already sorted), minus
# the pinned names, to the umbrella target's deps.
int wbg_extend_umbrella(char* umbrella, list[char*] names):
	list[char*] wanted = new list[char*]
	for char* name in names:
		if ((name in wbg_pinned) == 0):
			wanted.push(name)
	if (wanted.length == 0):
		return 0
	json_value* target = wbg_base_targets.get(umbrella, 0)
	if (target == 0):
		wbg_error2(c"missing umbrella target ", umbrella)
		return 1
	json_value* deps = json_object_get(target, c"deps")
	if (deps == 0):
		wbg_error2(c"umbrella target has no \"deps\": ", umbrella)
		return 1
	if (deps.type != json_type_array()):
		wbg_error2(c"umbrella \"deps\" is not an array: ", umbrella)
		return 1
	for char* name in wanted:
		json_array_push(deps, json_string(name))
	return 0


/* Serialization.

The manifest layout is fixed so regeneration is reproducible:
- scalar and array fields print compact on one line with ", " and ": "
  separators;
- each step prints on its own line;
- the deps of step-less (umbrella) targets print one per line;
- base targets keep their parse order, field order included. */

void wbg_append_compact(string_builder* out, json_value* value):
	if (value.type == json_type_string()):
		json_append_escaped_string(out, value.string_value)
	else if (value.type == json_type_int()):
		string_append_int(out, value.int_value)
	else if (value.type == json_type_bool()):
		if (value.int_value):
			string_append(out, c"true")
		else:
			string_append(out, c"false")
	else if (value.type == json_type_array()):
		string_append_char(out, '[')
		int i = 0
		while (i < json_array_length(value)):
			if (i > 0):
				string_append(out, c", ")
			wbg_append_compact(out, json_array_get(value, i))
			i = i + 1
		string_append_char(out, ']')
	else if (value.type == json_type_object()):
		string_append_char(out, '{')
		int first = 1
		for char* key, json_value* member in value.object_values:
			if (first == 0):
				string_append(out, c", ")
			first = 0
			json_append_escaped_string(out, key)
			string_append(out, c": ")
			wbg_append_compact(out, member)
		string_append_char(out, '}')
	else:
		string_append(out, c"null")


# One array element per line, indented with four tabs.
void wbg_append_element_lines(string_builder* out, json_value* array):
	int i = 0
	while (i < json_array_length(array)):
		string_append(out, c"\t\t\t\t")
		wbg_append_compact(out, json_array_get(array, i))
		if (i + 1 < json_array_length(array)):
			string_append_char(out, ',')
		string_append_char(out, '\n')
		i = i + 1


void wbg_append_target(string_builder* out, json_value* target):
	string_append(out, c"\t\t{\n")
	int has_steps = json_object_has(target, c"steps")
	int first = 1
	for char* key, json_value* member in target.object_values:
		if (first == 0):
			string_append(out, c",\n")
		first = 0
		int multiline = 0
		if (member.type == json_type_array()):
			if (strcmp(key, c"steps") == 0):
				multiline = 1
			if ((strcmp(key, c"deps") == 0) && (has_steps == 0)):
				multiline = 1
		if (multiline):
			string_append(out, c"\t\t\t")
			json_append_escaped_string(out, key)
			string_append(out, c": [\n")
			wbg_append_element_lines(out, member)
			string_append(out, c"\t\t\t]")
		else:
			string_append(out, c"\t\t\t")
			json_append_escaped_string(out, key)
			string_append(out, c": ")
			wbg_append_compact(out, member)
	string_append(out, c"\n\t\t}")


# The whole manifest: root members in base order minus "generate",
# targets expanded one object at a time.
char* wbg_render():
	string_builder* out = string_new()
	string_append(out, c"{\n")
	int first = 1
	for char* key, json_value* member in wbg_base.object_values:
		if (strcmp(key, c"generate") == 0):
			continue
		if (first == 0):
			string_append(out, c",\n")
		first = 0
		if (strcmp(key, c"targets") == 0):
			string_append(out, c"\t\"targets\": [\n")
			int i = 0
			while (i < json_array_length(member)):
				if (i > 0):
					string_append(out, c",\n")
				wbg_append_target(out, json_array_get(member, i))
				i = i + 1
			string_append(out, c"\n\t]")
		else:
			string_append(out, c"\t")
			json_append_escaped_string(out, key)
			string_append(out, c": ")
			wbg_append_compact(out, member)
	string_append(out, c"\n}\n")
	char* text = out.data
	free(out)
	return text


/* --check drift summary: name-level triage between the committed
manifest and the regenerated one, so the failure says which target to
look at instead of just "bytes differ". */

void wbg_report_drift(char* out_path, char* current, char* rendered):
	json_value* committed = json_parse(current)
	json_value* fresh = json_parse(rendered)
	int reported = 0
	if ((committed != 0) && (fresh != 0)):
		json_value* old_targets = json_object_get(committed, c"targets")
		json_value* new_targets = json_object_get(fresh, c"targets")
		map[char*, char*] old_defs = new map[char*, char*]
		int i = 0
		while (i < json_array_length(old_targets)):
			json_value* target = json_array_get(old_targets, i)
			char* name = wbg_get_string(target, c"name")
			if (name != 0):
				old_defs[name] = json_stringify(target)
			i = i + 1
		map[char*, int] new_names = new map[char*, int]
		i = 0
		while (i < json_array_length(new_targets)):
			json_value* target = json_array_get(new_targets, i)
			char* name = wbg_get_string(target, c"name")
			if (name != 0):
				new_names[name] = 1
				char* old_def = old_defs.get(name, 0)
				if (old_def == 0):
					wbg_error2(c"target missing from committed manifest: ", name)
					reported = 1
				else:
					char* new_def = json_stringify(target)
					if (strcmp(old_def, new_def) != 0):
						wbg_error2(c"target definition drifted: ", name)
						reported = 1
					free(new_def)
			i = i + 1
		for char* name, char* def in old_defs:
			if ((name in new_names) == 0):
				wbg_error2(c"committed target no longer generated: ", name)
				reported = 1
	if (reported == 0):
		wbg_error(c"manifests differ in formatting only")
	wbg_error2(c"stale manifest; regenerate with ./wbuild manifest: ", out_path)


int main(int argc, int argv):
	char* base_path = c"build.base.json"
	char* out_path = c"build.json"
	int check_only = 0
	int i = 1
	while (i < argc):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"--check") == 0):
			check_only = 1
		else if (strcmp(*arg, c"--base") == 0):
			i = i + 1
			if (i >= argc):
				wbg_usage()
				return 1
			char** base_value = argv + i * __word_size__
			base_path = *base_value
		else if (strcmp(*arg, c"--out") == 0):
			i = i + 1
			if (i >= argc):
				wbg_usage()
				return 1
			char** out_value = argv + i * __word_size__
			out_path = *out_value
		else:
			wbg_usage()
			return 1
		i = i + 1

	if (wbg_load_base(base_path)):
		return 1
	if (wbg_scan()):
		return 1
	if (wbg_extend_umbrella(c"tests", wbg_gen32_names)):
		return 1
	# Compile-only darwin twins are cheap to verify on Linux (no qemu,
	# no wine), so they join "tests" the way graphics_darwin/net_darwin/
	# pac_darwin already do. Generated arm64 twins join no umbrella
	# (see the module doc comment); win64 twins join "tests_win64" like
	# their hand-written counterparts.
	if (wbg_extend_umbrella(c"tests", wbg_gen_darwin_names)):
		return 1
	if (wbg_extend_umbrella(c"tests_x64", wbg_gen64_names)):
		return 1
	if (wbg_extend_umbrella(c"tests_win64", wbg_gen_win64_names)):
		return 1

	json_value* targets = json_object_get(wbg_base, c"targets")
	for json_value* target in wbg_generated:
		json_array_push(targets, target)
	char* rendered = wbg_render()

	string_builder* summary = string_new()
	string_append_int(summary, json_array_length(targets))
	string_append(summary, c" targets, ")
	string_append_int(summary, wbg_generated.length)
	string_append(summary, c" generated)")

	wstream* out = stdout_writer()
	if (check_only):
		char* current = file_read_text(out_path)
		if (current != 0):
			if (strcmp(current, rendered) == 0):
				stream_write_cstr(out, c"wbuildgen: OK ")
				stream_write_cstr(out, out_path)
				stream_write_cstr(out, c" is up to date (")
				stream_write_line(out, summary.data)
				stream_flush(out)
				return 0
		# Failure (usually EEXIST) is fine, like wexec_make_dirs.
		mkdir(c"bin", 493)
		file_write_text(c"bin/build.json.gen", rendered)
		wbg_error(c"regenerated manifest written to bin/build.json.gen")
		if (current == 0):
			wbg_error2(c"cannot read committed manifest ", out_path)
		else:
			wbg_report_drift(out_path, current, rendered)
		return 1

	if (file_write_text(out_path, rendered) == 0):
		wbg_error2(c"cannot write ", out_path)
		return 1
	stream_write_cstr(out, c"wbuildgen: wrote ")
	stream_write_cstr(out, out_path)
	stream_write_cstr(out, c" (")
	stream_write_line(out, summary.data)
	stream_flush(out)
	return 0
