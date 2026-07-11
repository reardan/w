/*
wtest: map changed paths to focused build targets.

Selection is manifest-driven: build.json (the same manifest wexec runs)
is parsed at startup, so the target registry can never drift from the
build. For a changed path P the emitted targets are the union of:

  (a) literal references — every runnable target one of whose steps
      names P in its argv (exact element, or an element containing P
      when P has a '/') or mentions P in its piped stdin. This covers
      fixtures, grammars, scripts and data files exactly. A target may
      also declare non-W run-time inputs in a target-level "data"
      array (generated from '# wbuild: deps=' directives, see
      tools/wbuildgen.w): an entry ending in '/' matches as a
      directory prefix, anything else as an exact path. Declared data
      is checked before the doc-only filter below, so a data file with
      a doc-like extension (.txt) still selects its targets.

  (b) import closures — every runnable target one of whose root
      sources' transitive import closure (computed by shelling out to
      'bin/wv2 deps [selector] <root>') contains P. Root sources are
      the (arch, .w file) pairs named in compile steps
      ('bin/wv2 [selector] [flags] <file>.w ... -o out', including
      seed './w' compiles), taken from the target's own steps and from
      the steps of its dependency targets — so wexec_test inherits
      tools/wexec.w from its 'wexec' dep and debug_test inherits
      debugger/debugger.w from 'wdbg'. Closures are per-arch: a root
      compiled with a target selector (x64, arm64, arm64_darwin,
      win64) resolves lib/__arch__/ and other per-target imports for
      that target, so arch-only modules (lib/__arch__/x64/,
      graphics/cocoa.w) select exactly the targets that compile them.
      A root that fails to compile falls back to literal matching
      only. Closures are cached in bin/.wtest_deps_cache and re-used
      until the content hash of any file in the cached closure
      changes.

  (c) RESIDUE RULES for coupling the import graph cannot see:
      - w.w / grammar.w / codegen.w and compiler/ grammar/
        code_generator/ paths -> verify + self_host_warning_test. The
        self-host fixpoint is the designed gate for compiler internals;
        every program's closure contains the compiler-emitted runtime
        and every target depends on bin/wv2, so closure selection for
        compiler paths would degenerate to the full suite. w.w is
        excluded as a closure root for the same reason, and
        compiler-tree paths skip rule (b). *_asm.w runtime stubs also
        -> asm_stubs_test (drift-checked against tests/asm/, #170).
      - every changed .w file that exists -> parser_generator_w_test:
        that target parses every tracked .w file, so any .w change can
        break it (PR #151 escaped the old per-directory rule).
      - lib/ structures/ libs/ paths, and every deleted (missing) .w
        path anywhere -> metadata_check: package.wmeta declares module
        trees that must resolve to files (#145 escaped the old rules).
        A deleted .w additionally -> tests, because importers of a
        deleted module no longer compile, so their closures cannot be
        computed.
      - (the former lib/__arch__/ and graphics/ rules are retired: the
        per-arch closures of rule (b) see those modules exactly where
        a target compiles them. An arch module no target compiles at
        all — e.g. lib/__arch__/win64/socket_abi.w while nothing links
        net on win64 — selects only metadata_check and
        parser_generator_w_test, which is also exactly its current
        test coverage.)
      - tests/asm/ -> the asm suite (including the asm_fuzz_* property/
        fuzz targets, which sample the same tests/asm/corpus_*.txt
        fixtures): the .txt/.asm text sources are read at run time, not
        imported. tools/gen_stubs.w -> asm_stubs_test (the stub drift
        check compares its generated output).
      - libs/extras/c_import/ and c_preprocessor/ -> the c_import
        suite: the C-import machinery is loaded by the compiler itself,
        not through recorded imports.
      - libs/standard/net/x509_fixtures/ -> net_x509_test and
        tests/metadata/ -> metadata_test: run-time fixture data.
      - build.json / wbuild / build.base.json -> wexec_test + tests (the
        manifest drives every target); build.base.json additionally ->
        manifest_check (it feeds bin/wbuildgen).
      - *_test.w under a wbuildgen scan directory -> manifest_check:
        conventional test sources are generator inputs, so adding or
        deleting one must regenerate build.json.
      - docs/, *.md, *.txt, .cursor/ -> nothing, except tests/asm/*.txt
        (the corpus fixtures), which the tests/asm/ rule above still
        covers despite the extension.
      - anything still unmatched -> tests.

Safety: update / update_darwin (seed promotion) and the darwin-native
bootstrap targets (build_darwin, verify_darwin, wexec_darwin — their
steps execute Mach-O binaries) are never emitted; step-less aggregate
targets (tests, tests_x64, tests_win64) are never selected by (a)/(b).

Output: unique target names, one per line, in manifest order ('tests'
is last in the manifest). --verbose prints 'path -> target' notes to
stderr. Paths come from arguments or stdin (git diff --name-only HEAD |
bin/wtest changed).

--run additionally executes the selection itself, through the same
executor './wbuild test_changed' pipes into via 'xargs -r ./wbuild'
(which execs bin/wexec) -- but as a single direct child that inherits
this process's stdio, so build output streams live exactly as it does
through that pipeline. An empty selection is a no-op, matching
'xargs -r's behavior on empty input: no child is spawned. wtest exits
with the child's status (0 on success).

-f overrides the manifest path (default build.json) for both selection
and, under --run, execution. It exists mainly for isolated testing
(tests/wtest/): pointing wtest at a throwaway manifest lets --run be
exercised without ever selecting a real target that itself shells out to
bin/wtest, which would recurse.
*/
import lib.lib
import lib.file
import lib.process
import lib.stream
import structures.string
import structures.json


json_value* wtest_manifest
list[char*] wtest_target_names       # manifest order = output order
map[char*, json_value*] wtest_target_defs
map[char*, int] wtest_enabled
map[char*, int] wtest_never_emit

# (root id, owning target) pairs; a root owned by several targets
# repeats. Root ids are "<arch> <root>" (wtest_root_id).
list[char*] wtest_pair_roots
list[char*] wtest_pair_targets
list[char*] wtest_roots              # deduplicated root ids

# root id -> closure blob ("\n" + one path per line + trailing "\n");
# parallel lists. A root whose deps run failed stores 0.
list[char*] wtest_closure_roots
list[char*] wtest_closure_blobs

map[char*, char*] wtest_file_hashes  # path -> content hash hex (memo)

int wtest_verbose
int wtest_run_flag
char* wtest_manifest_path
int wtest_closures_ready
int wtest_mask32


void wtest_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: wtest changed [--verbose] [--run] [-f manifest.json] [file...]")
	stream_flush(err)


void wtest_error(char* message, char* detail):
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"wtest: error: ")
	stream_write_cstr(err, message)
	stream_write_line(err, detail)
	stream_flush(err)


void wtest_note(char* path, char* target):
	if (wtest_verbose == 0):
		return
	wstream* err = stderr_writer()
	stream_write_cstr(err, path)
	stream_write_cstr(err, c" -> ")
	stream_write_line(err, target)
	stream_flush(err)


int wtest_str_contains(char* haystack, char* needle):
	int n = strlen(needle)
	if (n == 0):
		return 1
	int i = 0
	while (haystack[i] != 0):
		int j = 0
		while ((j < n) & (haystack[i + j] == needle[j])):
			j = j + 1
		if (j == n):
			return 1
		i = i + 1
	return 0


int wtest_file_exists(char* path):
	int fd = open(path, 0, 0)
	if (fd < 0):
		return 0
	close(fd)
	return 1


/* Manifest loading (the read-only subset of tools/wexec.w's parser). */

char* wtest_get_string(json_value* object, char* key):
	json_value* value = json_object_get(object, key)
	if (value == 0):
		return 0
	if (value.type != json_type_string()):
		return 0
	return value.string_value


int wtest_load_manifest():
	char* text = file_read_text(wtest_manifest_path)
	if (text == 0):
		wtest_error(c"cannot read ", wtest_manifest_path)
		return 1
	wtest_manifest = json_parse(text)
	free(text)
	if (wtest_manifest == 0):
		wtest_error(c"manifest is not valid JSON: ", wtest_manifest_path)
		return 1
	json_value* targets = json_object_get(wtest_manifest, c"targets")
	if (targets == 0):
		wtest_error(c"manifest has no targets array: ", wtest_manifest_path)
		return 1
	if (targets.type != json_type_array()):
		wtest_error(c"manifest targets is not an array: ", wtest_manifest_path)
		return 1
	wtest_target_names = new list[char*]
	wtest_target_defs = new map[char*, json_value*]
	wtest_enabled = new map[char*, int]
	wtest_never_emit = new map[char*, int]
	wtest_never_emit[c"update"] = 1
	wtest_never_emit[c"update_darwin"] = 1
	wtest_never_emit[c"build_darwin"] = 1
	wtest_never_emit[c"verify_darwin"] = 1
	wtest_never_emit[c"wexec_darwin"] = 1
	int i = 0
	while (i < json_array_length(targets)):
		json_value* target = json_array_get(targets, i)
		if (target.type == json_type_object()):
			char* name = wtest_get_string(target, c"name")
			if (name != 0):
				wtest_target_defs[name] = target
				wtest_target_names.push(name)
		i = i + 1
	return 0


json_value* wtest_target_steps(char* name):
	json_value* target = wtest_target_defs.get(name, 0)
	if (target == 0):
		return 0
	json_value* steps = json_object_get(target, c"steps")
	if (steps == 0):
		return 0
	if (steps.type != json_type_array()):
		return 0
	return steps


# A target participates in literal/closure selection when it has steps
# to run and is not on the never-emit list. Aggregates (tests, ...) and
# the seed/darwin bootstrap targets are excluded.
int wtest_selectable(char* name):
	if (wtest_never_emit.get(name, 0)):
		return 0
	json_value* steps = wtest_target_steps(name)
	if (steps == 0):
		return 0
	return json_array_length(steps) > 0


void wtest_add(char* path, char* target):
	wtest_note(path, target)
	if (wtest_never_emit.get(target, 0)):
		return
	if (wtest_target_defs.get(target, 0) != 0):
		wtest_enabled[target] = 1
	else:
		wtest_enabled[c"tests"] = 1


/* Rule (a): literal step references. */

int wtest_step_mentions(json_value* step, char* path, int path_has_slash):
	if (step.type != json_type_object()):
		return 0
	json_value* cmd = json_object_get(step, c"cmd")
	if (cmd != 0):
		if (cmd.type == json_type_array()):
			int i = 0
			while (i < json_array_length(cmd)):
				json_value* piece = json_array_get(cmd, i)
				if (piece.type == json_type_string()):
					if (strcmp(piece.string_value, path) == 0):
						return 1
					if (path_has_slash && wtest_str_contains(piece.string_value, path)):
						return 1
				i = i + 1
	char* stdin_text = wtest_get_string(step, c"stdin")
	if (stdin_text != 0):
		if (wtest_str_contains(stdin_text, path)):
			return 1
	return 0


int wtest_target_mentions(char* name, char* path, int path_has_slash):
	json_value* steps = wtest_target_steps(name)
	if (steps == 0):
		return 0
	int i = 0
	while (i < json_array_length(steps)):
		if (wtest_step_mentions(json_array_get(steps, i), path, path_has_slash)):
			return 1
		i = i + 1
	return 0


# Rule (a) for declared run-time data: the target-level "data" array
# ('# wbuild: deps=' directives, tools/wbuildgen.w). An entry ending
# in '/' is a directory prefix, anything else an exact path.
int wtest_target_data_mentions(char* name, char* path):
	json_value* target = wtest_target_defs.get(name, 0)
	if (target == 0):
		return 0
	json_value* data = json_object_get(target, c"data")
	if (data == 0):
		return 0
	if (data.type != json_type_array()):
		return 0
	int i = 0
	while (i < json_array_length(data)):
		json_value* entry = json_array_get(data, i)
		if (entry.type == json_type_string()):
			char* text = entry.string_value
			if (strcmp(text, path) == 0):
				return 1
			int n = strlen(text)
			if ((n > 0) && (text[n - 1] == '/') && starts_with(path, text)):
				return 1
		i = i + 1
	return 0


int wtest_map_data(char* path):
	int matched = 0
	for char* name in wtest_target_names:
		if (wtest_selectable(name)):
			if (wtest_target_data_mentions(name, path)):
				wtest_add(path, name)
				matched = 1
	return matched


/* Rule (b): compile roots and their import closures. */

# w.w is never a closure root: every target depends on the compiler, so
# selecting through it would always emit everything. verify is the
# designed gate (residue rule). grammar.w/codegen.w are its aggregators.
int wtest_excluded_root(char* path):
	if (strcmp(path, c"w.w") == 0):
		return 1
	if (strcmp(path, c"grammar.w") == 0):
		return 1
	if (strcmp(path, c"codegen.w") == 0):
		return 1
	return 0


int wtest_selector(char* word):
	if (strcmp(word, c"x64") == 0):
		return 1
	if (strcmp(word, c"arm64") == 0):
		return 1
	if (strcmp(word, c"arm64_darwin") == 0):
		return 1
	if (strcmp(word, c"win64") == 0):
		return 1
	return 0


# Root ids are "<arch> <root>" pairs ("x64 lib/lib_test.w"); the arch
# column is the compile step's target selector, "x86" for the default
# target, so one source file compiled for several targets gets one
# closure per target.
char* wtest_root_id(char* arch, char* root):
	string_builder* s = string_new()
	string_append(s, arch)
	string_append_char(s, ' ')
	string_append(s, root)
	char* id = s.data
	free(s)
	return id


# The path column of a root id (after the arch word), or 0 when the id
# has no arch column (a stale cache entry from an older wtest).
char* wtest_root_id_path(char* id):
	int i = 0
	while (id[i] != 0):
		if (id[i] == ' '):
			return id + i + 1
		i = i + 1
	return 0


# (arch, .w file) root ids named in this target's own compile steps
# ('bin/wv2 [selector] [flags] file.w ... -o out', or seed './w'
# compiles).
void wtest_collect_own_roots(char* name, list[char*] out):
	json_value* steps = wtest_target_steps(name)
	if (steps == 0):
		return
	int s = 0
	while (s < json_array_length(steps)):
		json_value* step = json_array_get(steps, s)
		s = s + 1
		if (step.type != json_type_object()):
			continue
		json_value* cmd = json_object_get(step, c"cmd")
		if (cmd == 0):
			continue
		if (cmd.type != json_type_array()):
			continue
		int n = json_array_length(cmd)
		if (n < 2):
			continue
		json_value* program = json_array_get(cmd, 0)
		if (program.type != json_type_string()):
			continue
		if ((strcmp(program.string_value, c"bin/wv2") != 0) && (strcmp(program.string_value, c"./w") != 0)):
			continue
		int has_output = 0
		int i = 1
		while (i < n):
			json_value* piece = json_array_get(cmd, i)
			if (piece.type == json_type_string()):
				if (strcmp(piece.string_value, c"-o") == 0):
					has_output = 1
			i = i + 1
		if (has_output == 0):
			continue
		char* arch = c"x86"
		json_value* selector_piece = json_array_get(cmd, 1)
		if (selector_piece.type == json_type_string()):
			if (wtest_selector(selector_piece.string_value)):
				arch = selector_piece.string_value
		i = 1
		while (i < n):
			json_value* piece = json_array_get(cmd, i)
			if (piece.type == json_type_string()):
				char* element = piece.string_value
				if (strcmp(element, c"-o") == 0):
					i = i + 2
					continue
				if (ends_with(element, c".w") && (wtest_excluded_root(element) == 0)):
					out.push(wtest_root_id(arch, element))
			i = i + 1


# Roots of a target = its own compile roots plus the compile roots of
# its transitive dependency targets (build targets like wexec, wdbg or
# wtest carry the compile step for the binary the test target runs).
void wtest_collect_target_roots(char* name, list[char*] out):
	map[char*, int] visited = new map[char*, int]
	list[char*] stack = new list[char*]
	stack.push(name)
	while (stack.length > 0):
		char* current = stack.pop()
		if (visited.get(current, 0)):
			continue
		visited[current] = 1
		json_value* target = wtest_target_defs.get(current, 0)
		if (target == 0):
			continue
		wtest_collect_own_roots(current, out)
		json_value* deps = json_object_get(target, c"deps")
		if (deps != 0):
			if (deps.type == json_type_array()):
				int i = 0
				while (i < json_array_length(deps)):
					json_value* dep = json_array_get(deps, i)
					if (dep.type == json_type_string()):
						stack.push(dep.string_value)
					i = i + 1


void wtest_ensure_roots():
	if (wtest_pair_roots != 0):
		return
	wtest_pair_roots = new list[char*]
	wtest_pair_targets = new list[char*]
	wtest_roots = new list[char*]
	map[char*, int] seen = new map[char*, int]
	for char* name in wtest_target_names:
		if (wtest_selectable(name) == 0):
			continue
		list[char*] roots = new list[char*]
		wtest_collect_target_roots(name, roots)
		map[char*, int] target_seen = new map[char*, int]
		for char* root in roots:
			if (target_seen.get(root, 0)):
				continue
			target_seen[root] = 1
			wtest_pair_roots.push(root)
			wtest_pair_targets.push(name)
			if (seen.get(root, 0) == 0):
				seen[root] = 1
				wtest_roots.push(root)


/* Closure computation, memoized per run and cached across runs.

The cache file (bin/.wtest_deps_cache) stores one entry per root id
("<arch> <root>", see wtest_root_id):
  R <arch> <root>
  H <combined content hash of every file in the closure>
  F <closure file> (one line per file, in deps output order)
An entry is valid when re-hashing every F file reproduces H; otherwise
'bin/wv2 deps [selector]' is re-run. A root that failed to compile for
its target is cached as
  X <arch> <root>
  H <content hash of the root file itself>
and retried once the root's own content changes. (A root that fails
because an *imported* file is broken keeps its stale failure entry
until the root is touched — acceptable, because such roots are error
fixtures or transient mid-edit states, and literal matching still
covers them.) Entries without an arch column — caches written by older
wtest builds — fail to parse and simply recompute. */

int wtest_mask32_value():
	if (__word_size__ == 8):
		int high = 1 << 16
		return high * high - 1
	return -1


struct wtest_hash:
	int h1
	int h2


void wtest_hash_init(wtest_hash* h):
	h.h1 = -2128831035 & wtest_mask32
	h.h2 = 1000003


void wtest_hash_bytes(wtest_hash* h, char* data, int n):
	int i = 0
	while (i < n):
		int value = data[i] & 255
		h.h1 = (h.h1 * 16777619 + value) & wtest_mask32
		h.h2 = (h.h2 * 1000003 + value) & wtest_mask32
		i = i + 1


void wtest_hash_cstr(wtest_hash* h, char* text):
	wtest_hash_bytes(h, text, strlen(text))
	char zero = 0
	wtest_hash_bytes(h, &zero, 1)


void wtest_append_hex(string_builder* s, int value):
	int shift = 28
	while (shift >= 0):
		int nibble = (value >> shift) & 15
		if (nibble < 10):
			string_append_char(s, '0' + nibble)
		else:
			string_append_char(s, 'a' + nibble - 10)
		shift = shift - 4


char* wtest_hash_hex(wtest_hash* h):
	string_builder* s = string_new()
	wtest_append_hex(s, h.h1)
	wtest_append_hex(s, h.h2)
	char* text = s.data
	free(s)
	return text


# Content hash of one file, memoized. Missing files hash to a sentinel
# that can never match a stored digest, so deletions invalidate entries.
char* wtest_file_hash(char* path):
	if (wtest_file_hashes == 0):
		wtest_file_hashes = new map[char*, char*]
	char* cached = wtest_file_hashes.get(path, 0)
	if (cached != 0):
		return cached
	char* digest = c"<missing>"
	int fd = open(path, 0, 0)
	if (fd >= 0):
		wtest_hash h
		wtest_hash_init(&h)
		int buffer_size = 65536
		char* buffer = malloc(buffer_size)
		int n = read(fd, buffer, buffer_size)
		while (n > 0):
			wtest_hash_bytes(&h, buffer, n)
			n = read(fd, buffer, buffer_size)
		free(buffer)
		close(fd)
		digest = wtest_hash_hex(&h)
	wtest_file_hashes[path] = digest
	return digest


# Combined digest over (path, content hash) of every file in a closure
# blob, in order.
char* wtest_closure_digest(char* blob):
	wtest_hash h
	wtest_hash_init(&h)
	string_builder* line = string_new()
	int i = 0
	while (blob[i] != 0):
		if (blob[i] == 10):
			if (line.length > 0):
				wtest_hash_cstr(&h, line.data)
				wtest_hash_cstr(&h, wtest_file_hash(line.data))
				string_clear(line)
		else:
			string_append_char(line, blob[i])
		i = i + 1
	if (line.length > 0):
		wtest_hash_cstr(&h, line.data)
		wtest_hash_cstr(&h, wtest_file_hash(line.data))
	string_free(line)
	return wtest_hash_hex(&h)


void wtest_closure_store(char* root, char* blob):
	wtest_closure_roots.push(root)
	wtest_closure_blobs.push(blob)


char* wtest_closure_get(char* root):
	int i = 0
	while (i < wtest_closure_roots.length):
		if (strcmp(wtest_closure_roots[i], root) == 0):
			return wtest_closure_blobs[i]
		i = i + 1
	return 0


int wtest_closure_known(char* root):
	int i = 0
	while (i < wtest_closure_roots.length):
		if (strcmp(wtest_closure_roots[i], root) == 0):
			return 1
		i = i + 1
	return 0


# Run 'bin/wv2 deps [selector] <root>' for one root id; returns a
# newline-guarded closure blob or 0 when the root does not compile for
# its target (literal matching still applies).
char* wtest_run_deps(char* id):
	char* arch = strclone(id)
	char* root = 0
	int i = 0
	while ((arch[i] != 0) && (root == 0)):
		if (arch[i] == ' '):
			arch[i] = 0
			root = arch + i + 1
		i = i + 1
	if (root == 0):
		free(arch)
		return 0
	int is_default = strcmp(arch, c"x86") == 0
	int count = 4
	if (is_default):
		count = 3
	char** argv = strv_new(count)
	strv_set(argv, 0, c"bin/wv2")
	strv_set(argv, 1, c"deps")
	if (is_default):
		strv_set(argv, 2, root)
	else:
		strv_set(argv, 2, arch)
		strv_set(argv, 3, root)
	process_result* result = process_run(c"bin/wv2", argv, 0, 0, 120000)
	free(cast(char*, argv))
	free(arch)
	if (result == 0):
		return 0
	if (result.status != 0):
		process_result_free(result)
		return 0
	string_builder* blob = string_new()
	string_append_char(blob, 10)
	string_append(blob, result.stdout_text)
	if (blob.length > 0):
		if (blob.data[blob.length - 1] != 10):
			string_append_char(blob, 10)
	process_result_free(result)
	char* text = blob.data
	free(blob)
	return text


# Finalize one parsed cache entry: keep it only when its content hash
# still matches (and, for 'X' entries, the id parses — pre-arch-column
# caches are silently dropped). kind 1 = success ('R'), kind 2 =
# failure ('X').
void wtest_cache_entry(int kind, char* root, char* expected, string_builder* blob):
	if ((root == 0) | (expected == 0)):
		return
	if (kind == 1):
		if (blob != 0):
			if (strcmp(wtest_closure_digest(blob.data), expected) == 0):
				wtest_closure_store(root, blob.data)
	if (kind == 2):
		char* path = wtest_root_id_path(root)
		if (path != 0):
			if (strcmp(wtest_file_hash(path), expected) == 0):
				wtest_closure_store(root, 0)


# Load cache entries whose content hashes still match; anything stale
# or unparseable is simply dropped (deps re-runs for it).
void wtest_cache_load():
	char* text = file_read_text(c"bin/.wtest_deps_cache")
	if (text == 0):
		return
	int kind = 0
	char* root = 0
	char* expected = 0
	string_builder* blob = 0
	string_builder* line = string_new()
	int i = 0
	int at_end = 0
	while (at_end == 0):
		int c = text[i]
		if (c == 0):
			at_end = 1
		if ((c == 10) | (c == 0)):
			char* entry = line.data
			if (starts_with(entry, c"R ") | starts_with(entry, c"X ")):
				wtest_cache_entry(kind, root, expected, blob)
				kind = 1
				if (entry[0] == 'X'):
					kind = 2
				root = strclone(entry + 2)
				expected = 0
				blob = string_new()
				string_append_char(blob, 10)
			else if (starts_with(entry, c"H ")):
				expected = strclone(entry + 2)
			else if (starts_with(entry, c"F ")):
				if (blob != 0):
					string_append(blob, entry + 2)
					string_append_char(blob, 10)
			string_clear(line)
		else:
			string_append_char(line, c)
		i = i + 1
	wtest_cache_entry(kind, root, expected, blob)
	string_free(line)
	free(text)


void wtest_cache_save():
	string_builder* out = string_new()
	int i = 0
	while (i < wtest_closure_roots.length):
		char* blob = wtest_closure_blobs[i]
		if (blob == 0):
			# Failed root: cache the failure against the root's own
			# content, so it is retried only once the root changes.
			string_append(out, c"X ")
			string_append(out, wtest_closure_roots[i])
			string_append_char(out, 10)
			string_append(out, c"H ")
			string_append(out, wtest_file_hash(wtest_root_id_path(wtest_closure_roots[i])))
			string_append_char(out, 10)
		else:
			string_append(out, c"R ")
			string_append(out, wtest_closure_roots[i])
			string_append_char(out, 10)
			string_append(out, c"H ")
			string_append(out, wtest_closure_digest(blob))
			string_append_char(out, 10)
			string_builder* line = string_new()
			int j = 0
			while (blob[j] != 0):
				if (blob[j] == 10):
					if (line.length > 0):
						string_append(out, c"F ")
						string_append(out, line.data)
						string_append_char(out, 10)
						string_clear(line)
				else:
					string_append_char(line, blob[j])
				j = j + 1
			string_free(line)
		i = i + 1
	mkdir(c"bin", 493)
	file_write_text(c"bin/.wtest_deps_cache", out.data)
	string_free(out)


void wtest_ensure_closures():
	if (wtest_closures_ready):
		return
	wtest_closures_ready = 1
	wtest_ensure_roots()
	wtest_closure_roots = new list[char*]
	wtest_closure_blobs = new list[char*]
	wtest_cache_load()
	int recomputed = 0
	for char* root in wtest_roots:
		if (wtest_closure_known(root) == 0):
			wtest_closure_store(root, wtest_run_deps(root))
			recomputed = 1
	if (recomputed):
		wtest_cache_save()


int wtest_closure_contains(char* blob, char* path):
	if (blob == 0):
		return 0
	string_builder* needle = string_new()
	string_append_char(needle, 10)
	string_append(needle, path)
	string_append_char(needle, 10)
	int found = wtest_str_contains(blob, needle.data)
	string_free(needle)
	return found


/* Residue rules and the selection driver. */

int wtest_doc_only(char* path):
	if (starts_with(path, c"tests/asm/")):
		# The corpus_*.txt fixtures are runtime data for the asm suite
		# (including asm_fuzz_*), not documentation, despite the extension;
		# the tests/asm/ residue rule below must see them.
		return 0
	if (starts_with(path, c"docs/")):
		return 1
	if (ends_with(path, c".md")):
		return 1
	if (ends_with(path, c".txt")):
		return 1
	return 0


int wtest_compiler_tree(char* path):
	if (strcmp(path, c"w.w") == 0):
		return 1
	if (strcmp(path, c"grammar.w") == 0):
		return 1
	if (strcmp(path, c"codegen.w") == 0):
		return 1
	if (starts_with(path, c"compiler/")):
		return 1
	if (starts_with(path, c"grammar/")):
		return 1
	if (starts_with(path, c"code_generator/")):
		return 1
	return 0


# The wbuildgen scan directories (docs/projects/wexec.md, "Manifest
# generation"): a *_test.w source under any of these is a generator
# input, so manifest_check gates its addition/removal.
int wtest_scan_dir_path(char* path):
	if (starts_with(path, c"tests/")):
		return 1
	if (starts_with(path, c"lib/")):
		return 1
	if (starts_with(path, c"structures/")):
		return 1
	if (starts_with(path, c"graphics/")):
		return 1
	if (starts_with(path, c"libs/")):
		return 1
	if (starts_with(path, c"tools/")):
		return 1
	return 0


# Residue mappings (header comment, rule c). Returns 1 when any rule
# matched, so the caller can skip the tests fallback.
int wtest_map_residue(char* path, int is_w, int exists):
	int matched = 0
	if (wtest_compiler_tree(path)):
		wtest_add(path, c"verify")
		wtest_add(path, c"self_host_warning_test")
		if (ends_with(path, c"_asm.w")):
			wtest_add(path, c"asm_stubs_test")
		matched = 1
	if (is_w && exists):
		wtest_add(path, c"parser_generator_w_test")
		matched = 1
	if (is_w && (exists == 0)):
		wtest_add(path, c"metadata_check")
		wtest_add(path, c"tests")
		matched = 1
	if (starts_with(path, c"lib/") | starts_with(path, c"structures/") | starts_with(path, c"libs/")):
		wtest_add(path, c"metadata_check")
		matched = 1
	if (starts_with(path, c"tests/asm/")):
		wtest_add(path, c"asm_foundations_test")
		wtest_add(path, c"asm_x86_disasm_test")
		wtest_add(path, c"asm_x86_asm_test")
		wtest_add(path, c"asm_arm64_test")
		wtest_add(path, c"asm_x64_test")
		wtest_add(path, c"asm_seed_gate")
		wtest_add(path, c"asm_stubs_test")
		wtest_add(path, c"asm_fuzz_x86_test")
		wtest_add(path, c"asm_fuzz_x64_test")
		wtest_add(path, c"asm_fuzz_arm64_test")
		matched = 1
	if (strcmp(path, c"tools/gen_stubs.w") == 0):
		wtest_add(path, c"asm_stubs_test")
		matched = 1
	if (starts_with(path, c"libs/extras/c_import/") | starts_with(path, c"libs/extras/c_preprocessor/")):
		wtest_add(path, c"c_import_test")
		wtest_add(path, c"c_preprocessor_test")
		wtest_add(path, c"c_import_errno_test")
		wtest_add(path, c"c_import_libc_test")
		matched = 1
	if (starts_with(path, c"libs/standard/net/x509_fixtures/")):
		wtest_add(path, c"net_x509_test")
		matched = 1
	if (starts_with(path, c"tests/metadata/")):
		wtest_add(path, c"metadata_test")
		matched = 1
	if ((strcmp(path, c"build.json") == 0) | (strcmp(path, c"wbuild") == 0) | (strcmp(path, c"build.base.json") == 0)):
		wtest_add(path, c"wexec_test")
		wtest_add(path, c"tests")
		if (strcmp(path, c"build.base.json") == 0):
			# The base manifest feeds bin/wbuildgen; regeneration drift is
			# invisible to the import graph.
			wtest_add(path, c"manifest_check")
		matched = 1
	if (is_w && ends_with(path, c"_test.w") && wtest_scan_dir_path(path)):
		# Conventional test sources are wbuildgen inputs: adding, deleting
		# or renaming one must regenerate build.json (manifest_check).
		wtest_add(path, c"manifest_check")
		matched = 1
	return matched


void wtest_map_path(char* path):
	if (strlen(path) == 0):
		return
	# Declared run-time data comes before the doc-only filter: a data
	# file may carry a doc-like extension (the tests/asm/*.txt lesson,
	# #268), and its declaring targets must still be selected.
	int matched = wtest_map_data(path)
	if (wtest_doc_only(path)):
		return
	if (starts_with(path, c".cursor/")):
		# Rules and skills are agent guidance, not code under test.
		return
	int is_w = ends_with(path, c".w")
	int exists = wtest_file_exists(path)
	if (wtest_map_residue(path, is_w, exists)):
		matched = 1

	# (a) literal step references
	int path_has_slash = wtest_str_contains(path, c"/")
	for char* name in wtest_target_names:
		if (wtest_selectable(name)):
			if (wtest_target_mentions(name, path, path_has_slash)):
				wtest_add(path, name)
				matched = 1

	# (b) import closures — compiler-tree paths are covered by verify
	# (see header), deleted files cannot appear in a computable closure,
	# and only .w files ever appear in one.
	if (is_w && exists && (wtest_compiler_tree(path) == 0)):
		wtest_ensure_closures()
		int i = 0
		while (i < wtest_pair_roots.length):
			if (wtest_closure_contains(wtest_closure_get(wtest_pair_roots[i]), path)):
				wtest_add(path, wtest_pair_targets[i])
				matched = 1
			i = i + 1

	if (matched == 0):
		wtest_add(path, c"tests")


void wtest_emit_targets():
	wstream* out = stdout_writer()
	for char* name in wtest_target_names:
		if (name in wtest_enabled):
			stream_write_line(out, name)
	stream_flush(out)


# --run: hand the selection to bin/wexec as a single direct child that
# inherits our stdio, instead of relying on a caller to pipe our output
# into 'xargs -r ./wbuild' (what './wbuild test_changed' does). An empty
# selection is a no-op, matching xargs -r's behavior on empty input: no
# child is spawned and 0 is returned. -f (see wtest_manifest_path) is
# forwarded too, so an isolated caller (tests/wtest_run_test) can point
# both selection and execution at a throwaway manifest. Returns the
# child's exit status, to propagate as wtest's own.
int wtest_run_selected():
	list[char*] selected = new list[char*]
	for char* name in wtest_target_names:
		if (name in wtest_enabled):
			selected.push(name)
	if (selected.length == 0):
		return 0
	int custom_manifest = strcmp(wtest_manifest_path, c"build.json") != 0
	int prefix = 1
	if (custom_manifest):
		prefix = 3
	char** argv = strv_new(prefix + selected.length)
	strv_set(argv, 0, c"bin/wexec")
	if (custom_manifest):
		strv_set(argv, 1, c"-f")
		strv_set(argv, 2, wtest_manifest_path)
	int i = 0
	while (i < selected.length):
		strv_set(argv, prefix + i, selected[i])
		i = i + 1
	process* p = process_spawn(c"bin/wexec", argv, 0)
	free(cast(char*, argv))
	if (p == 0):
		wtest_error(c"cannot spawn ", c"bin/wexec")
		return 1
	int status = process_wait(p)
	process_free(p)
	if (status < 0):
		return 1
	return status


int main(int argc, int argv):
	wtest_mask32 = wtest_mask32_value()
	if (argc < 2):
		wtest_usage()
		return 1
	char** command = argv + __word_size__
	if (strcmp(*command, c"changed") != 0):
		wtest_usage()
		return 1
	wtest_manifest_path = c"build.json"
	# A first pass just for "-f manifest.json": the manifest must be
	# loaded before selection starts below, but "-f" may appear anywhere
	# after "changed" (mirroring bin/wexec's own flag), so it is found
	# ahead of the argument loop that does the real work.
	int pre = 2
	while (pre < argc):
		char** arg = argv + pre * __word_size__
		if (strcmp(*arg, c"-f") == 0):
			pre = pre + 1
			if (pre >= argc):
				wtest_usage()
				return 1
			char** value = argv + pre * __word_size__
			wtest_manifest_path = *value
		pre = pre + 1
	if (wtest_load_manifest()):
		return 1
	int saw_file = 0
	int i = 2
	while (i < argc):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"--verbose") == 0):
			wtest_verbose = 1
		else if (strcmp(*arg, c"--run") == 0):
			wtest_run_flag = 1
		else if (strcmp(*arg, c"-f") == 0):
			i = i + 1   # value already consumed by the pre-scan above
		else:
			wtest_map_path(*arg)
			saw_file = 1
		i = i + 1
	if (saw_file == 0):
		wstream* in = stdin_reader()
		string_builder* line = string_new()
		while (stream_read_line(in, line)):
			wtest_map_path(line.data)
		string_free(line)
	wtest_emit_targets()
	if (wtest_run_flag):
		return wtest_run_selected()
	return 0
