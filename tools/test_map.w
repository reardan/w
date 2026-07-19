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
      changes. --defhash (opt-in, see below) further skips a path's
      own closure additions when 'bin/wv2 defhash' proves its recorded
      definitions did not change.

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
      - tests/wexec/remote_cache.json -> wexec_remote_cache_test: the
        target's own manifest steps only name the compiled test binary;
        the fixture path itself is a literal inside the test's source,
        passed to a bin/wexec subprocess as a "-f" argument at run
        time, so neither rule (a) nor rule (b) can see the coupling.
      - build.json / wbuild / build.base.json -> wexec_test + tests (the
        manifest drives every target); build.base.json additionally ->
        manifest_check (it feeds bin/wbuildgen). Exception: when
        --base-manifest supplies the committed baseline build.json and
        the structural diff against it is EXACTLY additions, removals,
        or in-place regenerations of wbuildgen-shaped leaf test targets
        (plus the matching tests/tests_x64/tests_win64 membership
        edits), a changed build.json selects just those targets +
        manifest_check + wexec_test instead of the whole suite — the
        "added one conventional test and reran ./wbuild manifest"
        workflow. Anything else in the diff (a hand-written base
        target, a toolchain step, the manifest's root members) falls
        back to the full residue; so does a missing or unparseable
        baseline. Under-selection is fenced twice: manifest_check is
        always co-selected (a hand-edited build.json fails it), and a
        build.base.json edit keeps the full residue through its own
        changed path.
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
bin/wtest changed). An empty selection prints 'wtest: 0 targets
selected' to stderr — stdout stays clean (it is piped into 'xargs -r
./wbuild'), but a caller looking at the terminal can tell "nothing to
test" apart from a green run.

'wtest for <path>...' (issue #323 stage 1) is 'changed' with its path
list required as positional args instead of optionally read from
stdin: the same selection (rules a/b/c above, unchanged) for a caller
that already knows which paths it cares about, without a
'git diff --name-only HEAD |' pipe. Every flag 'changed' accepts,
'for' accepts identically, --run included; unlike 'changed', 'for'
with no path arguments is a usage error rather than an empty-stdin
selection, since a bare 'wtest for' has no plausible caller.

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

--base-manifest names the BASELINE build.json to structurally diff the
current manifest against for the leaf-target special case above; with
no baseline the build.json residue always selects the full suite.
'./wbuild test_changed' extracts it with 'git show <base>:build.json';
tests point it at fixture manifests, mirroring -f.

--available drops, after normal selection, targets whose steps name a
runner this host cannot execute — arm64 run targets (they shell through
'sh tools/run_arm64.sh', which itself falls back to qemu-aarch64-static
off an aarch64 host), win64 run targets ('wine'/'wine64'), or a
tools/mac/ script — so the printed selection is runnable as-is instead
of failing on a missing qemu/wine/Mac. Detection is mechanical and
conservative: only a step whose argv[0] (or, for the arm64 wrapper,
argv[1]) is one of those recognized shapes is checked for presence on
PATH (or, for tools/mac/, as a file); anything else is left alone, so a
target is only ever dropped on positive evidence. One 'wtest: dropped N
unavailable target(s) (<reason>)' line per distinct reason is printed to
stderr, plus a 'dropped N unavailable targets total' line when more than
one reason fired. './wbuild test_changed' passes --available by default.

--defhash (opt-in; 'changed' and 'for' both accept it) refines rule (b)
per .w path: 'bin/wv2 defhash' is run on both the worktree copy and
'git show HEAD:<path>' (staged to a scratch file under bin/), and when
the recorded definition name set and every name's hash come back
identical, that path's import-closure additions are skipped for this
run — rule (a) literal matches and the rule (c) residue mappings still
apply, so a comment/formatting-only edit stops recommending every
importer without under-selecting the fixed rules. It fails OPEN: a path
new to HEAD, a git or 'bin/wv2 defhash' error, an actual
addition/removal/hash change in the recorded definitions, or a file
whose text trips wtest_defhash_risky_text (the literal word 'operator',
or an identifier immediately followed by a bracket whose
comma-separated contents are all-uppercase-led names — this codebase's
own type-parameter convention, 'T' / 'K, V' — a cheap textual stand-in
for "this file may define an operator overload or explicit-generics
function/struct invisible to defhash", docs/projects/
ai_tooling_next_steps.md's defhash section) all fall back to the
ordinary closure scan for that path instead. The risk scan is text, not
a parse, so it may over-fire (safe: just less selective) but must never
under-fire. Selection without --defhash is unchanged byte-for-byte.
('HEAD' above generalizes to the commit-ranged left endpoint below when
a range is active; see wtest_range_left / wtest_range_right and
wtest_defhash_unchanged's left_rev/right_is_worktree.)

Commit-ranged selection (issue #251 direction 4b; 'changed' only, not
'for'): a single positional argument containing '..' is a git revision
range instead of a changed-file path — no tracked path in this tree
ever contains '..', so the two are unambiguous, and only the first such
argument is honored. Accepted spellings mirror 'git diff
--name-only's own argument: 'A..B' and 'A...B' (three-dot: wtest
resolves the actual 'git merge-base A B' itself as the comparison's
left endpoint, so the per-file --defhash comparison below diffs the
same pair 'git diff A...B' itself would), and an open right side
('A..') meaning "A versus the worktree". A bare single revision with no
dots at all ('A') is deliberately NOT auto-detected — indistinguishable
from an ordinary changed-file argument — so 'A..' is the documented
spelling for "one revision versus the worktree" instead. Getting that
open-range case to actually reach the worktree takes care wtest does
itself rather than delegating to git's own range parsing: a dotted
rangespec's omitted side defaults to HEAD (a specific commit), never
the working tree — 'git diff --name-only A..' silently answers "what
changed between A and HEAD", dropping any uncommitted edit entirely, a
materially different (and wrong) answer here. wtest_range_setup instead
splits the spec itself and resolves each side up front (wtest_range_left
always a real commit-ish, wtest_range_right either a resolved commit or
0 meaning "the worktree"); wtest_range_expand then runs 'git diff
--no-renames --name-only <left> <right>' as two separate arguments when
both are commits (documented git-equivalent of '<left>..<right>'), or
just 'git diff --no-renames --name-only <left>' — a bare single
argument, which does reach the worktree+index — when the right side is
open. Renames are disabled (--no-renames) so a rename surfaces as the
ordinary old-path-deleted + new-path-added pair, which residue rule
(c)'s existing deleted-file handling already covers, rather than git's
default rename-following silently hiding the old path. Every path
returned goes through the ordinary wtest_map_path, generalized in
exactly two places: the "does this .w file still exist" check that rule
(c) uses to choose the deleted-file residue instead of a closure scan is
evaluated against the range's right-hand endpoint (a real commit for a
closed 'A..B'/'A...B' range, the live worktree for an open one) instead
of unconditionally the live worktree, and --defhash's own comparison
generalizes from HEAD-vs-worktree to left-vs-right content ('git show
<left>:<path>' vs 'git show <right>:<path>', or the worktree file when
the right side is open) — see wtest_range_setup, wtest_range_exists,
wtest_defhash_unchanged. Rule (b)'s closure computation itself is NOT
range-aware: it always reflects the CURRENT worktree's import graph via
the same bin/.wtest_deps_cache every other invocation uses —
recomputing historical closures per commit is the deferred "persistent
semantic index over history" work (docs/projects/build_system_next.md
direction 4b); reusing the live graph is exact for the common case
(import structure rarely changes across a range) and can only ever
over-select, never under-select. An invalid revision on either side is
a hard error (wtest exits 1 before any selection is printed) rather
than a silent fallback, unlike --defhash's per-file fail-open: a bad
range means the whole invocation is meaningless, not just one file's
precision. Without a range argument, 'changed' (and 'for', which never
looks for one)
behave byte-for-byte as before.

The first 'changed' invocation to touch an import closure (rule b) after
a build, or after bin/.wtest_deps_cache is otherwise missing or fully
stale, prints one 'wtest: building import-closure cache...' note to
stderr before shelling out to 'bin/wv2 deps' for every root — that pass
can take minutes on a big tree with nothing printed otherwise. A warm
cache prints nothing extra.
*/
import lib.lib
import lib.env
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
int wtest_available_flag
int wtest_defhash_flag
char* wtest_manifest_path
char* wtest_base_manifest_path       # 0 = no --base-manifest given
json_value* wtest_base_manifest      # parsed baseline, 0 until loaded
int wtest_closures_ready
int wtest_mask32

# Commit-ranged selection (header comment, "Commit-ranged selection"):
# wtest_range_active is 0 until a range argument is recognized and
# resolved; wtest_range_spec is the raw argument as given (error
# messages only). wtest_range_left is always a resolved commit-ish
# (the range's left endpoint, or the resolved merge-base for a
# three-dot range) once active. wtest_range_right is the resolved
# right-hand commit-ish, or 0 meaning "the live worktree" (an open
# range, e.g. 'A..').
int wtest_range_active
char* wtest_range_spec
char* wtest_range_left
char* wtest_range_right


void wtest_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: wtest changed [--verbose] [--run] [--available] [-f manifest.json] [--base-manifest base.json] [file...] [--defhash] [A..B | A...B | A..]")
	stream_write_line(err, c"       wtest for <file>... [--verbose] [--run] [--available] [-f manifest.json] [--base-manifest base.json] [--defhash]")
	stream_write_line(err, c"       wtest archs <file>... [--check] [-f manifest.json]")
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
		while ((j < n) && (haystack[i + j] == needle[j])):
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


# The committed baseline manifest (--base-manifest), consumed only by
# the build.json leaf-diff special case (wtest_manifest_leaf_diff). A
# baseline the caller named but cannot be read is a loud error, like
# -f; structural oddities inside it just fall back to the full residue.
int wtest_load_base_manifest():
	char* text = file_read_text(wtest_base_manifest_path)
	if (text == 0):
		wtest_error(c"cannot read ", wtest_base_manifest_path)
		return 1
	wtest_base_manifest = json_parse(text)
	free(text)
	if (wtest_base_manifest == 0):
		wtest_error(c"base manifest is not valid JSON: ", wtest_base_manifest_path)
		return 1
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


# Program names whose argv this file knows how to read as a root
# compile: the ordinary self-hosted compiler ('bin/wv2'), the seed
# ('./w'), and the darwin-native compiler stage built by build_darwin/
# wexec_darwin ('bin/wv2_darwin') -- the only place a target compiles
# something other than w.w with the arm64_darwin selector via a program
# other than plain 'bin/wv2' (see 'archs' below).
int wtest_root_program(char* program):
	if (strcmp(program, c"bin/wv2") == 0):
		return 1
	if (strcmp(program, c"./w") == 0):
		return 1
	if (strcmp(program, c"bin/wv2_darwin") == 0):
		return 1
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
		if (wtest_root_program(program.string_value) == 0):
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
	if ((root == 0) || (expected == 0)):
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
		if ((c == 10) || (c == 0)):
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
	# Cold/stale cache: every root not already satisfied by wtest_cache_load
	# needs a 'bin/wv2 deps' shell-out below, which can take minutes right
	# after a build or a large merge (docs/projects/ai_tooling_next_steps.md,
	# 2026-07-16) with nothing printed otherwise. A warm cache (the common
	# case) skips this entirely.
	int cold = 0
	for char* root in wtest_roots:
		if (wtest_closure_known(root) == 0):
			cold = 1
	if (cold):
		wstream* err = stderr_writer()
		stream_write_line(err, c"wtest: building import-closure cache (first run after a build; this can take a minute)...")
		stream_flush(err)
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


/* --defhash (opt-in): refine rule (b) via 'bin/wv2 defhash' (header
comment). Everything below is only ever consulted when wtest_defhash_flag
is set, so the default (no --defhash) selection path never runs it. */

# execve does no PATH lookup (lib/process.w), so a bare command name like
# "git" must be resolved against PATH here first -- mirrors
# tools/wexec.w's wexec_resolve_program (and this file's own
# wtest_path_has), minus the Windows suffix handling: git is never one of
# the runners --available checks for, and this codebase's git-based tools
# already assume a POSIX host. Returns 'name' unresolved when it is not
# found (or already contains a '/'), so the caller's spawn fails cleanly
# instead of silently doing the wrong thing.
char* wtest_resolve_program(char* name):
	int i = 0
	while (name[i] != 0):
		if (name[i] == '/'):
			return name
		i = i + 1
	char* path = env_get(c"PATH")
	if (path == 0):
		path = c"/usr/bin:/bin"
	string_builder* candidate = string_new()
	int p = 0
	int at_end = 0
	int found = 0
	while ((at_end == 0) && (found == 0)):
		string_clear(candidate)
		while ((path[p] != ':') && (path[p] != 0)):
			string_append_char(candidate, path[p])
			p = p + 1
		if (path[p] == 0):
			at_end = 1
		else:
			p = p + 1
		if (candidate.length > 0):
			string_append_char(candidate, '/')
			string_append(candidate, name)
			if (wtest_file_exists(candidate.data)):
				found = 1
	char* result = name
	if (found):
		result = strclone(candidate.data)
	string_free(candidate)
	return result


# 'git show <rev>:<path>' -- <path> as recorded at <rev>, with no
# working-tree edits applied. Returns 0 (fail open, header comment) on
# any spawn failure or nonzero exit: a path new to <rev> (e.g. added but
# not yet committed, when <rev> is "HEAD"), a git error, no repository
# at all, or <path> simply not existing at <rev> (deleted or not yet
# added there).
char* wtest_git_show(char* rev, char* path):
	char* git = wtest_resolve_program(c"git")
	string_builder* spec = string_new()
	string_append(spec, rev)
	string_append(spec, c":")
	string_append(spec, path)
	char** argv = strv_new(3)
	strv_set(argv, 0, git)
	strv_set(argv, 1, c"show")
	strv_set(argv, 2, spec.data)
	process_result* result = process_run(git, argv, 0, 0, 30000)
	free(cast(char*, argv))
	string_free(spec)
	if (result == 0):
		return 0
	if (result.status != 0):
		process_result_free(result)
		return 0
	char* text = strclone(result.stdout_text)
	process_result_free(result)
	return text


# 'git show HEAD:<path>' -- kept as a thin wrapper: this is still the
# default-mode comparison (no commit-ranged argument given).
char* wtest_git_show_head(char* path):
	return wtest_git_show(c"HEAD", path)


# 'git cat-file -e <rev>:<path>' -- whether <path> exists in the tree
# recorded at <rev> (exit 0), used by wtest_range_exists to decide
# deleted-vs-present at the range's right-hand endpoint instead of
# always checking the live filesystem (header comment, "Commit-ranged
# selection"). Fails closed to "does not exist" on any spawn failure or
# nonzero exit, same as wtest_git_show's fail-open callers treat a 0
# return -- either way the caller ends up at the conservative
# deleted-file residue rule instead of a bogus closure scan.
int wtest_git_exists_at(char* rev, char* path):
	char* git = wtest_resolve_program(c"git")
	string_builder* spec = string_new()
	string_append(spec, rev)
	string_append(spec, c":")
	string_append(spec, path)
	char** argv = strv_new(4)
	strv_set(argv, 0, git)
	strv_set(argv, 1, c"cat-file")
	strv_set(argv, 2, c"-e")
	strv_set(argv, 3, spec.data)
	process_result* result = process_run(git, argv, 0, 0, 30000)
	free(cast(char*, argv))
	string_free(spec)
	if (result == 0):
		return 0
	int ok = result.status == 0
	process_result_free(result)
	return ok


# 'git rev-parse --verify <rev>^{commit}' -- whether <rev> resolves to a
# real commit. Used to validate both endpoints of a range up front, so a
# typo'd revision is a clean "wtest: error: ..." exit 1 instead of every
# per-file git-show call silently failing open one at a time.
int wtest_git_rev_valid(char* rev):
	char* git = wtest_resolve_program(c"git")
	string_builder* spec = string_new()
	string_append(spec, rev)
	string_append(spec, c"^{commit}")
	char** argv = strv_new(4)
	strv_set(argv, 0, git)
	strv_set(argv, 1, c"rev-parse")
	strv_set(argv, 2, c"--verify")
	strv_set(argv, 3, spec.data)
	process_result* result = process_run(git, argv, 0, 0, 30000)
	free(cast(char*, argv))
	string_free(spec)
	if (result == 0):
		return 0
	int ok = result.status == 0
	process_result_free(result)
	return ok


# 'git merge-base <a> <b>', trailing newline trimmed -- the correct left
# endpoint for a three-dot 'A...B' range's own per-file content
# comparisons (git diff A...B itself diffs merge-base(A,B) against B, so
# using bare 'A' as the left side of a --defhash comparison would
# compare the wrong pair of file versions). Returns 0 on any spawn
# failure, nonzero exit (e.g. unrelated histories), or empty output.
char* wtest_git_merge_base(char* a, char* b):
	char* git = wtest_resolve_program(c"git")
	char** argv = strv_new(4)
	strv_set(argv, 0, git)
	strv_set(argv, 1, c"merge-base")
	strv_set(argv, 2, a)
	strv_set(argv, 3, b)
	process_result* result = process_run(git, argv, 0, 0, 30000)
	free(cast(char*, argv))
	if (result == 0):
		return 0
	if (result.status != 0):
		process_result_free(result)
		return 0
	char* text = strclone(result.stdout_text)
	process_result_free(result)
	int n = strlen(text)
	if ((n > 0) && (text[n - 1] == 10)):
		text[n - 1] = 0
	if (strlen(text) == 0):
		free(text)
		return 0
	return text


# Index of the first '.' of the '..'/'...' run in a range spec the
# caller has already proved (via wtest_str_contains) contains "..".
# Never returns -1 in practice for such a caller, but the sentinel is
# kept for safety.
int wtest_range_dot_index(char* spec):
	int i = 0
	while (spec[i] != 0):
		if ((spec[i] == '.') && (spec[i + 1] == '.')):
			return i
		i = i + 1
	return -1


# Splits a rev-range spec ('A..B', 'A...B', 'A..', '..B') around its
# '..'/'...' run and resolves both endpoints (header comment,
# "Commit-ranged selection"): sets wtest_range_left/right/active/spec on
# success. wtest_range_right stays 0 (worktree) for an open right side.
# An omitted left side defaults to HEAD (gitrevisions(7)'s own
# convention for a range with one side blank). Returns 1 and prints a
# "wtest: error: ..." line (no selection is attempted) when either side
# fails to resolve as a real commit, a three-dot range has no
# right-hand side, or the two sides share no merge base.
int wtest_range_setup(char* spec):
	int idx = wtest_range_dot_index(spec)
	if (idx < 0):
		wtest_error(c"not a revision range: ", spec)
		return 1
	int three_dot = spec[idx + 2] == '.'
	int dots = 2
	if (three_dot):
		dots = 3
	string_builder* left_b = string_new()
	int i = 0
	while (i < idx):
		string_append_char(left_b, spec[i])
		i = i + 1
	char* left = strclone(left_b.data)
	string_free(left_b)
	if (strlen(left) == 0):
		left = c"HEAD"
	char* right_raw = spec + idx + dots
	char* right = 0
	if (strlen(right_raw) > 0):
		right = strclone(right_raw)
	if (wtest_git_rev_valid(left) == 0):
		wtest_error(c"invalid revision in range: ", left)
		return 1
	if ((right != 0) && (wtest_git_rev_valid(right) == 0)):
		wtest_error(c"invalid revision in range: ", right)
		return 1
	if (three_dot):
		if (right == 0):
			wtest_error(c"three-dot range needs a right-hand revision: ", spec)
			return 1
		char* base = wtest_git_merge_base(left, right)
		if (base == 0):
			wtest_error(c"no merge base for range: ", spec)
			return 1
		wtest_range_left = base
	else:
		wtest_range_left = left
	wtest_range_right = right
	wtest_range_spec = spec
	wtest_range_active = 1
	return 0


# Range-aware existence check used in place of a bare wtest_file_exists
# for the "does this .w path still exist" gate (header comment,
# "Commit-ranged selection"): the live worktree in default mode or an
# open range, the range's resolved right-hand commit for a closed one.
int wtest_range_exists(char* path):
	if (wtest_range_active == 0):
		return wtest_file_exists(path)
	if (wtest_range_right == 0):
		return wtest_file_exists(path)
	return wtest_git_exists_at(wtest_range_right, path)


int wtest_defhash_ident_char(int c):
	if ((c >= 'a') && (c <= 'z')):
		return 1
	if ((c >= 'A') && (c <= 'Z')):
		return 1
	if ((c >= '0') && (c <= '9')):
		return 1
	if (c == '_'):
		return 1
	return 0


# Whole-word occurrence of 'word' in 'text' (bounded by non-identifier
# characters or the string's edges) -- a plain substring search would also
# match identifiers that merely CONTAIN the word (e.g. 'operator_name'),
# which is not the signal we want.
int wtest_defhash_word_present(char* text, char* word):
	int wlen = strlen(word)
	int i = 0
	while (text[i] != 0):
		int j = 0
		while ((j < wlen) && (text[i + j] == word[j])):
			j = j + 1
		if (j == wlen):
			int before_ok = 1
			if (i > 0):
				before_ok = wtest_defhash_ident_char(text[i - 1] & 255) == 0
			int after_ok = wtest_defhash_ident_char(text[i + wlen] & 255) == 0
			if (before_ok && after_ok):
				return 1
		i = i + 1
	return 0


# Does 'item' (optionally with one leading space, the '[K, V]' spacing
# convention) look like a type-parameter name -- non-empty, first
# character an uppercase ASCII letter, the rest identifier characters?
# Every real type name in this codebase is lowercase snake_case (struct/
# union/enum/alias names throughout lib/, structures/, compiler/, ...),
# so this never matches an ordinary built-in-container instantiation
# ('map[char*, int]', 'list[T_lowercase_alias]') or an array/list index
# ('a[i]', 'argv[0]') -- only the documented type-parameter convention
# used by explicit generics ('T', 'K', 'V', docs/projects/generics.md).
int wtest_defhash_item_ok(char* item):
	if (item[0] == ' '):
		item = item + 1
	int len = strlen(item)
	if (len == 0):
		return 0
	int c0 = item[0] & 255
	if ((c0 < 'A') || (c0 > 'Z')):
		return 0
	int i = 1
	while (i < len):
		if (wtest_defhash_ident_char(item[i] & 255) == 0):
			return 0
		i = i + 1
	return 1


# 'content' is the text strictly between one '[' and its matching ']'
# (the caller has already excluded any nested bracket): true when every
# comma-separated piece looks like a type-parameter name per
# wtest_defhash_item_ok, e.g. "T" or "K, V".
int wtest_defhash_bracket_all_type_params(char* content):
	string_builder* item = string_new()
	int i = 0
	int ok = 1
	while (content[i] != 0):
		if (content[i] == ','):
			if (wtest_defhash_item_ok(item.data) == 0):
				ok = 0
			string_clear(item)
		else:
			string_append_char(item, content[i])
		i = i + 1
	if (wtest_defhash_item_ok(item.data) == 0):
		ok = 0
	string_free(item)
	return ok


# Cheap textual scan for the explicit-generics bracket syntax
# (docs/projects/generics.md: 'T max[T](T a, T b):', 'struct pair[T]:',
# 'K pick_first[K, V](...)') -- an identifier immediately followed by '['
# whose (unnested) bracket content is entirely type-parameter-shaped
# pieces. Not a parse: nested brackets inside the pair bail out of that
# one occurrence (treated as "not a match" for it, not an error), and nothing
# distinguishes a real definition from an explicit instantiation
# ('max[int](...)') that merely happens to spell its type argument with an
# initial capital -- both are treated as risky alike, which only ever
# causes an unnecessary (safe) fallback, never a missed one.
int wtest_defhash_has_generic_brackets(char* text):
	int i = 0
	while (text[i] != 0):
		if ((text[i] == '[') && (i > 0) && wtest_defhash_ident_char(text[i - 1] & 255)):
			string_builder* content = string_new()
			int j = i + 1
			int stop = 0
			int closed = 0
			int nested = 0
			while ((stop == 0) && (text[j] != 0)):
				if (text[j] == ']'):
					closed = 1
					stop = 1
				else if (text[j] == '['):
					nested = 1
					stop = 1
				else:
					string_append_char(content, text[j])
					j = j + 1
			if (closed && (nested == 0)):
				if (wtest_defhash_bracket_all_type_params(content.data)):
					string_free(content)
					return 1
			string_free(content)
		i = i + 1
	return 0


# 1 when 'text' might contain an operator-overload or explicit-generics
# definition -- both invisible to 'bin/wv2 defhash' by design
# (compiler/compiler.w's defhash_main doc comment), so a real edit to one
# could otherwise look like "no change" to the plain name/hash comparison
# below. A cheap textual stand-in for a real check (header comment): may
# over-fire (a comment merely mentioning "operator", an instantiation
# whose type argument starts uppercase) but must never under-fire.
int wtest_defhash_risky_text(char* text):
	if (wtest_defhash_word_present(text, c"operator")):
		return 1
	if (wtest_defhash_has_generic_brackets(text)):
		return 1
	return 0


# Runs 'bin/wv2 defhash <file_path>' and collects its NDJSON into a
# name -> hash map (default, root-only scope -- exactly the definitions
# declared directly in this file, matching what we are comparing). Returns
# 0 (fail open) on a spawn failure, a nonzero exit (a compile error, most
# likely an import that does not resolve for the HEAD-content temp file),
# or any record that fails to parse as a JSON object with both fields.
map[char*, char*] wtest_defhash_collect(char* file_path):
	char** argv = strv_new(3)
	strv_set(argv, 0, c"bin/wv2")
	strv_set(argv, 1, c"defhash")
	strv_set(argv, 2, file_path)
	process_result* result = process_run(c"bin/wv2", argv, 0, 0, 120000)
	free(cast(char*, argv))
	if (result == 0):
		return 0
	if (result.status != 0):
		process_result_free(result)
		return 0
	map[char*, char*] out = new map[char*, char*]
	string_builder* line = string_new()
	char* text = result.stdout_text
	int i = 0
	int at_end = 0
	int failed = 0
	while ((at_end == 0) && (failed == 0)):
		int c = text[i]
		if (c == 0):
			at_end = 1
		if ((c == 10) || (c == 0)):
			if (line.length > 0):
				json_value* rec = json_parse(line.data)
				if (rec == 0):
					failed = 1
				else if (rec.type != json_type_object()):
					failed = 1
				else:
					char* name = wtest_get_string(rec, c"name")
					char* hash = wtest_get_string(rec, c"hash")
					if ((name == 0) || (hash == 0)):
						failed = 1
					else:
						out[name] = strclone(hash)
			string_clear(line)
		else:
			string_append_char(line, c)
		i = i + 1
	string_free(line)
	process_result_free(result)
	if (failed):
		return 0
	return out


# The --defhash decision for one changed .w path: 1 when it is safe to
# skip this path's rule-(b) closure additions (its recorded definitions
# are provably unchanged between the comparison's two sides, and it
# carries none of the defhash-invisible shapes wtest_defhash_risky_text
# watches for), 0 otherwise -- fail open in every other case, per the
# header comment. Outside a commit range the two sides are HEAD (left)
# and the worktree (right), exactly as before wtest_range_* existed;
# inside one they are the range's resolved left/right endpoints (header
# comment, "Commit-ranged selection") -- rev-vs-rev content instead of
# HEAD-vs-worktree. wtest_note calls make the decision visible under
# --verbose without adding new output surface.
int wtest_defhash_unchanged(char* path):
	int right_is_worktree = (wtest_range_active == 0) || (wtest_range_right == 0)
	char* right_text = 0
	if (right_is_worktree):
		right_text = file_read_text(path)
	else:
		right_text = wtest_git_show(wtest_range_right, path)
	if (right_text == 0):
		wtest_note(path, c"defhash: fallback (no right-hand version, or git error)")
		return 0
	if (wtest_defhash_risky_text(right_text)):
		free(right_text)
		wtest_note(path, c"defhash: fallback (operator/generic-shaped text)")
		return 0
	char* left_rev = c"HEAD"
	if (wtest_range_active):
		left_rev = wtest_range_left
	char* left_text = wtest_git_show(left_rev, path)
	if (left_text == 0):
		free(right_text)
		wtest_note(path, c"defhash: fallback (no left-hand version, or git error)")
		return 0
	if (wtest_defhash_risky_text(left_text)):
		free(right_text)
		free(left_text)
		wtest_note(path, c"defhash: fallback (operator/generic-shaped text)")
		return 0
	mkdir(c"bin", 493)
	char* left_tmp = c"bin/.wtest_defhash_left.w"
	file_write_text(left_tmp, left_text)
	free(left_text)
	map[char*, char*] left_defs = wtest_defhash_collect(left_tmp)
	if (left_defs == 0):
		free(right_text)
		wtest_note(path, c"defhash: fallback (defhash error on left-hand version)")
		return 0
	map[char*, char*] right_defs = 0
	if (right_is_worktree):
		# Fast path, and today's exact behavior outside a range: the
		# worktree copy is already at 'path' on disk, so defhash it
		# directly instead of staging a second temp file.
		free(right_text)
		right_defs = wtest_defhash_collect(path)
	else:
		char* right_tmp = c"bin/.wtest_defhash_right.w"
		file_write_text(right_tmp, right_text)
		free(right_text)
		right_defs = wtest_defhash_collect(right_tmp)
	if (right_defs == 0):
		wtest_note(path, c"defhash: fallback (defhash error on right-hand version)")
		return 0
	list[char*] left_keys = left_defs.keys()
	list[char*] right_keys = right_defs.keys()
	if (left_keys.length != right_keys.length):
		wtest_note(path, c"defhash: fallback (definition set changed)")
		return 0
	for char* name in left_keys:
		char* right_hash = right_defs.get(name, 0)
		if (right_hash == 0):
			wtest_note(path, c"defhash: fallback (definition set changed)")
			return 0
		char* left_hash = left_defs.get(name, 0)
		if (strcmp(right_hash, left_hash) != 0):
			wtest_note(path, c"defhash: fallback (definition hash changed)")
			return 0
	wtest_note(path, c"defhash: skip (definitions unchanged)")
	return 1


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


/* The build.json leaf-diff special case (--base-manifest).

Adding one conventional test regenerates build.json, and the plain
manifest residue rule then recommends the entire pre-merge suite for
every "add one test" diff. When the caller supplies the committed
baseline manifest, the structural diff is inspected instead: if it is
exactly additions/removals/in-place regenerations of leaf test targets
in the shape tools/wbuildgen.w generates (plus the matching umbrella
membership edits), only those targets + manifest_check + wexec_test
are selected. Every check errs toward returning 0, which keeps the
full 'wexec_test + tests' residue — never under-select silently. */

int wtest_json_equal(json_value* a, json_value* b):
	char* left = json_stringify(a)
	char* right = json_stringify(b)
	int same = strcmp(left, right) == 0
	free(left)
	free(right)
	return same


# The umbrellas wbuildgen appends generated leaf targets to.
int wtest_umbrella_name(char* name):
	if (strcmp(name, c"tests") == 0):
		return 1
	if (strcmp(name, c"tests_x64") == 0):
		return 1
	if (strcmp(name, c"tests_win64") == 0):
		return 1
	return 0


# The names wbg_make_target can produce: X_test, X_64_test (also
# ..._test), and the X_test_{arm64,win64,darwin} platform twins.
int wtest_leaf_name(char* name):
	if (ends_with(name, c"_test")):
		return 1
	if (ends_with(name, c"_arm64")):
		return 1
	if (ends_with(name, c"_win64")):
		return 1
	if (ends_with(name, c"_darwin")):
		return 1
	return 0


# A step may carry only "cmd" (compile / extra_compile steps) or "cmd"
# plus the run-step decoration fields wbuildgen emits.
int wtest_step_only_keys(json_value* step, int run_fields):
	if (step.type != json_type_object()):
		return 0
	int ok = 1
	for char* key, json_value* member in step.object_values:
		if (strcmp(key, c"cmd") == 0):
			continue
		if (run_fields):
			if (strcmp(key, c"stdin") == 0):
				continue
			if (strcmp(key, c"expect_fail") == 0):
				continue
			if (strcmp(key, c"expect_stdout") == 0):
				continue
			if (strcmp(key, c"expect_stderr") == 0):
				continue
			if (strcmp(key, c"timeout_ms") == 0):
				continue
		ok = 0
	return ok


# The step's cmd as a nonempty all-string array, or 0.
json_value* wtest_step_cmd(json_value* step):
	json_value* cmd = json_object_get(step, c"cmd")
	if (cmd == 0):
		return 0
	if (cmd.type != json_type_array()):
		return 0
	int n = json_array_length(cmd)
	if (n == 0):
		return 0
	int i = 0
	while (i < n):
		json_value* piece = json_array_get(cmd, i)
		if (piece.type != json_type_string()):
			return 0
		i = i + 1
	return cmd


# {"cmd": ["bin/wv2", (selector)?, ..., "src.w", ..., "-o", "bin/X"]}
# and nothing else.
int wtest_leaf_compile_step(json_value* step):
	if (wtest_step_only_keys(step, 0) == 0):
		return 0
	json_value* cmd = wtest_step_cmd(step)
	if (cmd == 0):
		return 0
	json_value* program = json_array_get(cmd, 0)
	if (strcmp(program.string_value, c"bin/wv2") != 0):
		return 0
	int has_output = 0
	int has_source = 0
	int i = 1
	while (i < json_array_length(cmd)):
		json_value* piece = json_array_get(cmd, i)
		if (strcmp(piece.string_value, c"-o") == 0):
			has_output = 1
		if (ends_with(piece.string_value, c".w")):
			has_source = 1
		i = i + 1
	return has_output && has_source


# A run or extra_compile step: the compiled binary (or another bin/
# tool for extra compiles), the arm64 qemu wrapper, or wine — plus at
# most the decoration fields.
int wtest_leaf_run_step(json_value* step):
	if (wtest_step_only_keys(step, 1) == 0):
		return 0
	json_value* cmd = wtest_step_cmd(step)
	if (cmd == 0):
		return 0
	json_value* program = json_array_get(cmd, 0)
	if (starts_with(program.string_value, c"bin/")):
		return 1
	if (strcmp(program.string_value, c"wine") == 0):
		return 1
	if (strcmp(program.string_value, c"sh") == 0):
		if (json_array_length(cmd) >= 2):
			json_value* script = json_array_get(cmd, 1)
			if (strcmp(script.string_value, c"tools/run_arm64.sh") == 0):
				return 1
	return 0


# The conventional compile(+run) shape tools/wbuildgen.w generates for
# a leaf test target (wbg_make_target): only the keys it emits, deps
# exactly ["wv2"], a bin/wv2 compile step first, decorated run /
# extra-compile steps after. A hand-written base target that happens
# to match is indistinguishable, which is safe: editing one requires a
# build.base.json change, and that path keeps the full residue.
int wtest_leaf_target(json_value* target):
	if (target == 0):
		return 0
	if (target.type != json_type_object()):
		return 0
	int keys_ok = 1
	for char* key, json_value* member in target.object_values:
		if ((strcmp(key, c"name") != 0) && (strcmp(key, c"deps") != 0) && (strcmp(key, c"data") != 0) && (strcmp(key, c"steps") != 0)):
			keys_ok = 0
	if (keys_ok == 0):
		return 0
	char* name = wtest_get_string(target, c"name")
	if (name == 0):
		return 0
	if (wtest_leaf_name(name) == 0):
		return 0
	json_value* deps = json_object_get(target, c"deps")
	if (deps == 0):
		return 0
	if (deps.type != json_type_array()):
		return 0
	if (json_array_length(deps) != 1):
		return 0
	json_value* dep = json_array_get(deps, 0)
	if (dep.type != json_type_string()):
		return 0
	if (strcmp(dep.string_value, c"wv2") != 0):
		return 0
	json_value* data = json_object_get(target, c"data")
	if (data != 0):
		if (data.type != json_type_array()):
			return 0
		int d = 0
		while (d < json_array_length(data)):
			json_value* entry = json_array_get(data, d)
			if (entry.type != json_type_string()):
				return 0
			d = d + 1
	json_value* steps = json_object_get(target, c"steps")
	if (steps == 0):
		return 0
	if (steps.type != json_type_array()):
		return 0
	if (json_array_length(steps) == 0):
		return 0
	if (wtest_leaf_compile_step(json_array_get(steps, 0)) == 0):
		return 0
	int i = 1
	while (i < json_array_length(steps)):
		if (wtest_leaf_run_step(json_array_get(steps, i)) == 0):
			return 0
		i = i + 1
	return 1


# The deps array as a name set, or 0 when it is not all strings.
map[char*, int] wtest_dep_set(json_value* deps):
	if (deps == 0):
		return 0
	if (deps.type != json_type_array()):
		return 0
	map[char*, int] out = new map[char*, int]
	int i = 0
	while (i < json_array_length(deps)):
		json_value* dep = json_array_get(deps, i)
		if (dep.type != json_type_string()):
			return 0
		out[dep.string_value] = 1
		i = i + 1
	return out


# An umbrella may differ from its baseline only in deps, and only by
# entries that are exactly this diff's added/removed leaf names.
int wtest_umbrella_diff_ok(json_value* base_target, json_value* current_target, map[char*, int] added, map[char*, int] removed):
	int base_count = 0
	int members_ok = 1
	for char* key, json_value* member in base_target.object_values:
		if (strcmp(key, c"deps") != 0):
			base_count = base_count + 1
			json_value* other = json_object_get(current_target, key)
			if (other == 0):
				members_ok = 0
			else if (wtest_json_equal(member, other) == 0):
				members_ok = 0
	int current_count = 0
	for char* current_key, json_value* current_member in current_target.object_values:
		if (strcmp(current_key, c"deps") != 0):
			current_count = current_count + 1
	if ((members_ok == 0) || (base_count != current_count)):
		return 0
	json_value* base_deps = json_object_get(base_target, c"deps")
	json_value* current_deps = json_object_get(current_target, c"deps")
	map[char*, int] base_set = wtest_dep_set(base_deps)
	map[char*, int] current_set = wtest_dep_set(current_deps)
	if ((base_set == 0) || (current_set == 0)):
		return 0
	int i = 0
	while (i < json_array_length(current_deps)):
		json_value* gained = json_array_get(current_deps, i)
		if ((base_set.get(gained.string_value, 0) == 0) && (added.get(gained.string_value, 0) == 0)):
			return 0
		i = i + 1
	i = 0
	while (i < json_array_length(base_deps)):
		json_value* lost = json_array_get(base_deps, i)
		if ((current_set.get(lost.string_value, 0) == 0) && (removed.get(lost.string_value, 0) == 0)):
			return 0
		i = i + 1
	return 1


# Root members other than "targets" (the "dirs" list, any future
# member) must be identical; otherwise the manifest change is more
# than a target-list regeneration.
int wtest_manifest_roots_match():
	int base_count = 0
	int members_ok = 1
	for char* key, json_value* member in wtest_base_manifest.object_values:
		if (strcmp(key, c"targets") != 0):
			base_count = base_count + 1
			json_value* other = json_object_get(wtest_manifest, key)
			if (other == 0):
				members_ok = 0
			else if (wtest_json_equal(member, other) == 0):
				members_ok = 0
	int current_count = 0
	for char* current_key, json_value* current_member in wtest_manifest.object_values:
		if (strcmp(current_key, c"targets") != 0):
			current_count = current_count + 1
	if (base_count != current_count):
		return 0
	return members_ok


# The special case itself: structurally diff the current manifest
# against the --base-manifest baseline. Returns 1 after selecting the
# added / regenerated leaf targets + manifest_check + wexec_test, or 0
# (having selected nothing) when there is no baseline or anything in
# the diff is not a pure leaf-target regeneration.
int wtest_manifest_leaf_diff(char* path):
	if (wtest_base_manifest == 0):
		return 0
	if (wtest_base_manifest.type != json_type_object()):
		return 0
	if (wtest_manifest_roots_match() == 0):
		return 0
	json_value* base_targets = json_object_get(wtest_base_manifest, c"targets")
	if (base_targets == 0):
		return 0
	if (base_targets.type != json_type_array()):
		return 0
	list[char*] base_names = new list[char*]
	map[char*, json_value*] base_defs = new map[char*, json_value*]
	int i = 0
	while (i < json_array_length(base_targets)):
		json_value* target = json_array_get(base_targets, i)
		if (target.type == json_type_object()):
			char* name = wtest_get_string(target, c"name")
			if (name != 0):
				base_defs[name] = target
				base_names.push(name)
		i = i + 1
	# The added and removed name sets come first: the umbrella check
	# below needs them complete before membership edits can be judged.
	map[char*, int] added = new map[char*, int]
	map[char*, int] removed = new map[char*, int]
	list[char*] touched = new list[char*]
	for char* added_name in wtest_target_names:
		if (base_defs.get(added_name, 0) == 0):
			if (wtest_leaf_target(wtest_target_defs.get(added_name, 0)) == 0):
				return 0
			added[added_name] = 1
			touched.push(added_name)
	for char* removed_name in base_names:
		if (wtest_target_defs.get(removed_name, 0) == 0):
			if (wtest_leaf_target(base_defs.get(removed_name, 0)) == 0):
				return 0
			removed[removed_name] = 1
	# In-place differences: an umbrella gaining/losing exactly the
	# added/removed names, or a leaf regenerated in place (a
	# '# wbuild:' directive edit) which then selects itself. A removed
	# target is never selected — it no longer exists to run;
	# manifest_check covers the regeneration.
	for char* common_name in wtest_target_names:
		json_value* base_def = base_defs.get(common_name, 0)
		if (base_def != 0):
			json_value* current_def = wtest_target_defs.get(common_name, 0)
			if (wtest_json_equal(base_def, current_def) == 0):
				if (wtest_umbrella_name(common_name)):
					if (wtest_umbrella_diff_ok(base_def, current_def, added, removed) == 0):
						return 0
				else if (wtest_leaf_target(base_def) && wtest_leaf_target(current_def)):
					touched.push(common_name)
				else:
					return 0
	for char* selected in touched:
		wtest_add(path, selected)
	wtest_add(path, c"manifest_check")
	wtest_add(path, c"wexec_test")
	return 1


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
	if (strcmp(path, c"tests/wexec/remote_cache.json") == 0):
		wtest_add(path, c"wexec_remote_cache_test")
		matched = 1
	if (starts_with(path, c"tests/metadata/")):
		wtest_add(path, c"metadata_test")
		matched = 1
	if (strcmp(path, c"build.json") == 0):
		# A regenerated manifest whose only structural change against
		# the --base-manifest baseline is wbuildgen-shaped leaf targets
		# selects just those (wtest_manifest_leaf_diff); anything else
		# keeps the full residue: the manifest drives every target.
		if (wtest_manifest_leaf_diff(path) == 0):
			wtest_add(path, c"wexec_test")
			wtest_add(path, c"tests")
		matched = 1
	if ((strcmp(path, c"wbuild") == 0) | (strcmp(path, c"build.base.json") == 0)):
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
	# wtest_range_exists checks the live worktree in default mode or an
	# open range, and the range's resolved right-hand commit for a
	# closed one (header comment, "Commit-ranged selection") -- outside
	# a range it is exactly wtest_file_exists, unchanged.
	int exists = wtest_range_exists(path)
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
	# and only .w files ever appear in one. --defhash (opt-in) can skip
	# this block entirely for a path proven unchanged (wtest_defhash_
	# unchanged, fails open); without the flag wtest_defhash_flag is 0 and
	# skip_closure stays 0, so this is exactly the prior unconditional scan.
	if (is_w && exists && (wtest_compiler_tree(path) == 0)):
		int skip_closure = 0
		if (wtest_defhash_flag):
			skip_closure = wtest_defhash_unchanged(path)
		if (skip_closure == 0):
			wtest_ensure_closures()
			int i = 0
			while (i < wtest_pair_roots.length):
				if (wtest_closure_contains(wtest_closure_get(wtest_pair_roots[i]), path)):
					wtest_add(path, wtest_pair_targets[i])
					matched = 1
				i = i + 1

	if (matched == 0):
		wtest_add(path, c"tests")


# 'git diff --no-renames --name-only <left> [<right>]' -- the
# changed-path list for a commit range, fed through the ordinary
# wtest_map_path exactly like stdin/positional paths are (header
# comment, "Commit-ranged selection"). Built from wtest_range_setup's
# own RESOLVED endpoints, not the raw spec string: 'git diff <A> <B>'
# is equivalent to 'git diff A..B' for two real commits (git's own
# documented equivalence), and a bare single argument diffs against the
# worktree+index -- which is what actually gives an open range ('A..')
# its "versus the worktree" meaning. Passing the literal spec text
# through instead (e.g. 'git diff --name-only A..') would NOT reach the
# worktree: git resolves a range's omitted side to HEAD, a specific
# commit, never the working tree, so this two-argument form is required
# for the open case to mean what task 4b (and this file's header
# comment) documents. --no-renames so a rename surfaces as an
# old-path-deleted + new-path-added pair instead of git's default of
# showing only the new name, which would hide the deletion from rule
# (c) entirely. Returns 1 (after an error message) on a spawn failure or
# nonzero exit; wtest_range_setup's own validation should make that
# unreachable for an already-validated range, short of a deeper git
# problem.
int wtest_range_expand(char* spec):
	if (wtest_range_setup(spec)):
		return 1
	char* git = wtest_resolve_program(c"git")
	char** argv = 0
	if (wtest_range_right == 0):
		argv = strv_new(5)
		strv_set(argv, 0, git)
		strv_set(argv, 1, c"diff")
		strv_set(argv, 2, c"--no-renames")
		strv_set(argv, 3, c"--name-only")
		strv_set(argv, 4, wtest_range_left)
	else:
		argv = strv_new(6)
		strv_set(argv, 0, git)
		strv_set(argv, 1, c"diff")
		strv_set(argv, 2, c"--no-renames")
		strv_set(argv, 3, c"--name-only")
		strv_set(argv, 4, wtest_range_left)
		strv_set(argv, 5, wtest_range_right)
	process_result* result = process_run(git, argv, 0, 0, 30000)
	free(cast(char*, argv))
	if (result == 0):
		wtest_error(c"could not run git diff for range: ", spec)
		return 1
	if (result.status != 0):
		process_result_free(result)
		wtest_error(c"git diff failed for range: ", spec)
		return 1
	string_builder* line = string_new()
	char* text = result.stdout_text
	int j = 0
	int at_end = 0
	while (at_end == 0):
		int c = text[j]
		if (c == 0):
			at_end = 1
		if ((c == 10) || (c == 0)):
			if (line.length > 0):
				wtest_map_path(line.data)
			string_clear(line)
		else:
			string_append_char(line, c)
		j = j + 1
	string_free(line)
	process_result_free(result)
	return 0


/* --available: drop targets this host cannot run (header comment). */

# Whether 'name' resolves to a readable file on some PATH entry (mirrors
# tools/wexec.w's wexec_resolve_program lookup, minus the Windows/.exe
# handling: the runners --available checks for are never Windows tools).
int wtest_path_has(char* name):
	char* path = env_get(c"PATH")
	if (path == 0):
		path = c"/usr/bin:/bin"
	string_builder* candidate = string_new()
	int p = 0
	int at_end = 0
	int found = 0
	while ((at_end == 0) && (found == 0)):
		string_clear(candidate)
		while ((path[p] != ':') && (path[p] != 0)):
			string_append_char(candidate, path[p])
			p = p + 1
		if (path[p] == 0):
			at_end = 1
		else:
			p = p + 1
		if (candidate.length > 0):
			string_append_char(candidate, '/')
			string_append(candidate, name)
			if (wtest_file_exists(candidate.data)):
				found = 1
	string_free(candidate)
	return found


# tools/run_arm64.sh execs its argv natively on an aarch64 Linux host and
# falls back to ${QEMU_ARM64:-qemu-aarch64-static -cpu max} everywhere
# else; an explicit QEMU_ARM64 override is itself positive evidence the
# caller has an emulator configured, so it counts as available without a
# PATH lookup.
int wtest_qemu_arm64_available():
	if (env_get(c"QEMU_ARM64") != 0):
		return 1
	return wtest_path_has(c"qemu-aarch64-static")


# The reason this step's runner is unavailable on this host, or 0 when it
# is available, or when the step's program is not one of the recognized
# runner shapes (wine/wine64, the arm64 qemu wrapper, a tools/mac/
# script) — unrecognized programs are always left alone, per the
# "positive evidence only" rule in the header comment.
char* wtest_step_unavailable_reason(json_value* step):
	if (step.type != json_type_object()):
		return 0
	json_value* cmd = json_object_get(step, c"cmd")
	if (cmd == 0):
		return 0
	if (cmd.type != json_type_array()):
		return 0
	int n = json_array_length(cmd)
	if (n == 0):
		return 0
	json_value* first = json_array_get(cmd, 0)
	if (first.type != json_type_string()):
		return 0
	char* program = first.string_value
	if (strcmp(program, c"wine") == 0):
		if (wtest_path_has(c"wine") == 0):
			return c"wine not found"
		return 0
	if (strcmp(program, c"wine64") == 0):
		if (wtest_path_has(c"wine64") == 0):
			return c"wine64 not found"
		return 0
	if (strcmp(program, c"qemu-aarch64-static") == 0):
		if (wtest_qemu_arm64_available() == 0):
			return c"qemu-aarch64-static not found"
		return 0
	if (strcmp(program, c"sh") == 0):
		if (n >= 2):
			json_value* second = json_array_get(cmd, 1)
			if (second.type == json_type_string()):
				if (strcmp(second.string_value, c"tools/run_arm64.sh") == 0):
					if (wtest_qemu_arm64_available() == 0):
						return c"qemu-aarch64-static not found"
		return 0
	if (starts_with(program, c"tools/mac/")):
		if (wtest_file_exists(program) == 0):
			string_builder* s = string_new()
			string_append(s, program)
			string_append(s, c" not found")
			char* reason = s.data
			free(s)
			return reason
		return 0
	return 0


char* wtest_target_unavailable_reason(char* name):
	json_value* steps = wtest_target_steps(name)
	if (steps == 0):
		return 0
	int i = 0
	while (i < json_array_length(steps)):
		char* reason = wtest_step_unavailable_reason(json_array_get(steps, i))
		if (reason != 0):
			return reason
		i = i + 1
	return 0


# One 'wtest: dropped N unavailable target(s) (<reason>)' line per
# distinct reason, plus a total line only when more than one reason
# fired (with a single reason the per-reason line already is the total).
void wtest_available_report(list[char*] reasons, list[int] counts, int total):
	wstream* err = stderr_writer()
	int i = 0
	while (i < reasons.length):
		string_builder* line = string_new()
		string_append(line, c"wtest: dropped ")
		string_append_int(line, counts[i])
		string_append(line, c" unavailable target")
		if (counts[i] != 1):
			string_append_char(line, 's')
		string_append(line, c" (")
		string_append(line, reasons[i])
		string_append_char(line, ')')
		stream_write_line(err, line.data)
		string_free(line)
		i = i + 1
	if (reasons.length > 1):
		string_builder* total_line = string_new()
		string_append(total_line, c"wtest: dropped ")
		string_append_int(total_line, total)
		string_append(total_line, c" unavailable targets total")
		stream_write_line(err, total_line.data)
		string_free(total_line)
	stream_flush(err)


void wtest_apply_available_filter():
	list[char*] reasons = new list[char*]
	list[int] counts = new list[int]
	int total = 0
	for char* name in wtest_target_names:
		if (name in wtest_enabled):
			char* reason = wtest_target_unavailable_reason(name)
			if (reason != 0):
				wtest_enabled.remove(name)
				total = total + 1
				int index = -1
				int i = 0
				while (i < reasons.length):
					if (strcmp(reasons[i], reason) == 0):
						index = i
					i = i + 1
				if (index == -1):
					reasons.push(reason)
					counts.push(1)
				else:
					counts[index] = counts[index] + 1
	if (total > 0):
		wtest_available_report(reasons, counts, total)


void wtest_emit_targets():
	wstream* out = stdout_writer()
	int count = 0
	for char* name in wtest_target_names:
		if (name in wtest_enabled):
			stream_write_line(out, name)
			count = count + 1
	stream_flush(out)
	if (count == 0):
		# An empty selection must be visible: stdout is piped to xargs,
		# so nothing there — but silence on stderr too made "selected
		# nothing" indistinguishable from a green test_changed run.
		wstream* err = stderr_writer()
		stream_write_line(err, c"wtest: 0 targets selected")
		stream_flush(err)


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


/* 'wtest archs <file>...' (docs/projects/ai_tooling_next_steps.md, "No
warning when an import breaks a different compile target"): enumerate
every (arch, root) a file's closure is compiled under, so an agent
editing a multi-target file (tools/wexec.w: default x86, win64,
arm64_darwin) can see what it must not break, and optionally (--check)
run 'bin/wv2 [arch] check <root>' per distinct pair right there instead
of finding out at that target's next full build.

The root set is a superset of wtest_roots/wtest_ensure_roots: it walks
every target with steps, INCLUDING wtest_never_emit ones (wexec_darwin,
build_darwin, verify_darwin, update, update_darwin). never-emit exists
to keep 'changed'/'for' from recommending a target this host cannot
run (a Mach-O binary on a Linux host, or a destructive seed-promotion
step) -- a concern about running targets, not about which archs exist.
wexec_darwin's own compile step is the ONLY place tools/wexec.w is ever
compiled with the arm64_darwin selector via a real target (every other
arm64_darwin-selected root in the manifest, e.g. tests/net_darwin_smoke_
test.w, already goes through wtest_root_program's plain 'bin/wv2'
case), so dropping never-emit here would silently make the darwin arch
invisible to the one command whose whole point is "what must I not
break" -- checking it needs no darwin host either: 'bin/wv2 arm64_darwin
check <root>' cross-checks from this Linux host exactly like the
existing arm64_darwin-selected test targets already do at compile time. */

list[char*] wtest_archs_pair_roots
list[char*] wtest_archs_pair_targets
list[char*] wtest_archs_roots
int wtest_archs_closures_ready


void wtest_archs_ensure_roots():
	if (wtest_archs_pair_roots != 0):
		return
	wtest_archs_pair_roots = new list[char*]
	wtest_archs_pair_targets = new list[char*]
	wtest_archs_roots = new list[char*]
	map[char*, int] seen = new map[char*, int]
	for char* name in wtest_target_names:
		json_value* steps = wtest_target_steps(name)
		if (steps == 0):
			continue
		if (json_array_length(steps) == 0):
			continue
		list[char*] roots = new list[char*]
		wtest_collect_target_roots(name, roots)
		map[char*, int] target_seen = new map[char*, int]
		for char* root in roots:
			if (target_seen.get(root, 0)):
				continue
			target_seen[root] = 1
			wtest_archs_pair_roots.push(root)
			wtest_archs_pair_targets.push(name)
			if (seen.get(root, 0) == 0):
				seen[root] = 1
				wtest_archs_roots.push(root)


# Shares its closure storage (wtest_closure_roots/blobs) and on-disk
# cache (bin/.wtest_deps_cache, via wtest_closure_get/known/store and
# wtest_cache_load/save) with the standard changed/for machinery: a
# root both sides care about (almost all of them -- archs' root set is
# a superset) is only ever run through 'bin/wv2 deps' once, whichever
# command hits it first.
void wtest_archs_ensure_closures():
	if (wtest_archs_closures_ready):
		return
	wtest_archs_closures_ready = 1
	wtest_archs_ensure_roots()
	if (wtest_closure_roots == 0):
		wtest_closure_roots = new list[char*]
		wtest_closure_blobs = new list[char*]
		wtest_cache_load()
	int cold = 0
	for char* root in wtest_archs_roots:
		if (wtest_closure_known(root) == 0):
			cold = 1
	if (cold):
		wstream* err = stderr_writer()
		stream_write_line(err, c"wtest: building import-closure cache (first run after a build; this can take a minute)...")
		stream_flush(err)
	int recomputed = 0
	for char* root in wtest_archs_roots:
		if (wtest_closure_known(root) == 0):
			wtest_closure_store(root, wtest_run_deps(root))
			recomputed = 1
	if (recomputed):
		wtest_cache_save()


# A root id matches 'path' either because 'path' IS that root's own
# file (checked first, and independent of whether 'bin/wv2 deps'
# succeeded for it -- the whole point of this command is surfacing an
# arch whose compile is currently BROKEN, and deps necessarily fails
# for a root that does not compile) or because the root's closure
# contains 'path'.
int wtest_archs_root_matches(char* root, char* path):
	char* root_path = wtest_root_id_path(root)
	if (root_path != 0):
		if (strcmp(root_path, path) == 0):
			return 1
	return wtest_closure_contains(wtest_closure_get(root), path)


# Distinct (dedup by root id) matching roots for 'path', in first-seen
# (manifest) order.
void wtest_archs_matches(char* path, list[char*] out_roots):
	wtest_archs_ensure_closures()
	map[char*, int] seen = new map[char*, int]
	for char* root in wtest_archs_roots:
		if (seen.get(root, 0)):
			continue
		if (wtest_archs_root_matches(root, path)):
			seen[root] = 1
			out_roots.push(root)


# Comma-joined target names that own 'root' (context for the report --
# a root several targets share, e.g. wexec + its dependants, is one
# check, not one per target).
char* wtest_archs_targets_for(char* root):
	string_builder* s = string_new()
	int i = 0
	int first = 1
	while (i < wtest_archs_pair_roots.length):
		if (strcmp(wtest_archs_pair_roots[i], root) == 0):
			if (first == 0):
				string_append_char(s, ',')
			string_append(s, wtest_archs_pair_targets[i])
			first = 0
		i = i + 1
	char* result = s.data
	free(s)
	return result


# Splits a "<arch> <root>" id into its two parts, mutating a clone of
# the arch column to NUL-terminate it (mirrors wtest_run_deps's split).
char* wtest_archs_split_arch(char* root):
	char* arch = strclone(root)
	int j = 0
	while (arch[j] != 0):
		if (arch[j] == ' '):
			arch[j] = 0
		j = j + 1
	return arch


void wtest_archs_no_match(char* path):
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"wtest: archs: no compiled target's closure contains ")
	stream_write_line(err, path)
	stream_flush(err)


# Plain report: one line per distinct (arch, root), with the owning
# target(s) for context.
void wtest_archs_report(char* path):
	list[char*] matches = new list[char*]
	wtest_archs_matches(path, matches)
	if (matches.length == 0):
		wtest_archs_no_match(path)
		return
	wstream* out = stdout_writer()
	for char* root in matches:
		char* arch = wtest_archs_split_arch(root)
		char* rootfile = wtest_root_id_path(root)
		stream_write_cstr(out, arch)
		stream_write_byte(out, ' ')
		stream_write_cstr(out, rootfile)
		stream_write_cstr(out, c" -> ")
		char* targets = wtest_archs_targets_for(root)
		stream_write_line(out, targets)
		free(targets)
		free(arch)
	stream_flush(out)


# --check: run 'bin/wv2 [arch] check <root>' for each distinct (arch,
# root) match and report pass/fail, surfacing an arch-incompatible
# import (the win64 sys_socket shape from the module header) before
# that target's next full build. Returns 1 if any check failed.
int wtest_archs_check(char* path):
	list[char*] matches = new list[char*]
	wtest_archs_matches(path, matches)
	if (matches.length == 0):
		wtest_archs_no_match(path)
		return 0
	wstream* out = stdout_writer()
	int failures = 0
	for char* root in matches:
		char* arch = wtest_archs_split_arch(root)
		char* rootfile = wtest_root_id_path(root)
		int is_default = strcmp(arch, c"x86") == 0
		int count = 3
		if (is_default == 0):
			count = 4
		char** argv = strv_new(count)
		strv_set(argv, 0, c"bin/wv2")
		if (is_default):
			strv_set(argv, 1, c"check")
			strv_set(argv, 2, rootfile)
		else:
			strv_set(argv, 1, arch)
			strv_set(argv, 2, c"check")
			strv_set(argv, 3, rootfile)
		process_result* result = process_run(c"bin/wv2", argv, 0, 0, 120000)
		free(cast(char*, argv))
		stream_write_cstr(out, arch)
		stream_write_byte(out, ' ')
		stream_write_cstr(out, rootfile)
		if ((result != 0) && (result.status == 0)):
			stream_write_line(out, c": OK")
		else:
			stream_write_line(out, c": FAIL")
			failures = failures + 1
			if (result != 0):
				string_builder* line = string_new()
				int k = 0
				while (result.stderr_text[k] != 0):
					int ch = result.stderr_text[k]
					if (ch == 10):
						if (line.length > 0):
							stream_write_cstr(out, c"  ")
							stream_write_line(out, line.data)
							string_clear(line)
					else:
						string_append_char(line, ch)
					k = k + 1
				if (line.length > 0):
					stream_write_cstr(out, c"  ")
					stream_write_line(out, line.data)
				string_free(line)
		if (result != 0):
			process_result_free(result)
		free(arch)
	stream_flush(out)
	if (failures > 0):
		return 1
	return 0


# 'wtest archs <file>... [--check] [-f manifest.json]': its own small
# argument loop rather than folding into the changed/for one below --
# --run/--available/--defhash/--base-manifest are meaningless here (there
# is no selection to run or refine), and unlike 'for', a bare 'wtest
# archs' with no file is caught by the same "no path is a usage error"
# rule without needing stdin fallback.
int wtest_archs_main(int argc, int argv):
	int check_flag = 0
	list[char*] paths = new list[char*]
	wtest_manifest_path = c"build.json"
	int i = 2
	while (i < argc):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"--check") == 0):
			check_flag = 1
		else if (strcmp(*arg, c"-f") == 0):
			i = i + 1
			if (i >= argc):
				wtest_usage()
				return 1
			char** value = argv + i * __word_size__
			wtest_manifest_path = *value
		else:
			paths.push(*arg)
		i = i + 1
	if (paths.length == 0):
		wtest_usage()
		return 1
	if (wtest_load_manifest()):
		return 1
	int failures = 0
	for char* path in paths:
		if (check_flag):
			if (wtest_archs_check(path)):
				failures = 1
		else:
			wtest_archs_report(path)
	return failures


int main(int argc, int argv):
	wtest_mask32 = wtest_mask32_value()
	if (argc < 2):
		wtest_usage()
		return 1
	char** command = argv + __word_size__
	int for_mode = strcmp(*command, c"for") == 0
	if (strcmp(*command, c"archs") == 0):
		return wtest_archs_main(argc, argv)
	if ((strcmp(*command, c"changed") != 0) && (for_mode == 0)):
		wtest_usage()
		return 1
	wtest_manifest_path = c"build.json"
	# A first pass just for the manifest flags: both manifests must be
	# loaded before selection starts below, but "-f"/"--base-manifest"
	# may appear anywhere after "changed" (mirroring bin/wexec's own
	# flag), so they are found ahead of the argument loop that does the
	# real work. The same pass spots a commit-ranged argument (header
	# comment, "Commit-ranged selection") -- 'changed' only, the first
	# non-flag argument containing ".." -- so its index is known before
	# the real loop below reaches it; no repo path ever contains "..",
	# so this can never misfire against an ordinary changed-file path.
	int pre = 2
	int range_index = 0
	while (pre < argc):
		char** arg = argv + pre * __word_size__
		char* argval = *arg
		if (strcmp(argval, c"-f") == 0):
			pre = pre + 1
			if (pre >= argc):
				wtest_usage()
				return 1
			char** value = argv + pre * __word_size__
			wtest_manifest_path = *value
		else if (strcmp(argval, c"--base-manifest") == 0):
			pre = pre + 1
			if (pre >= argc):
				wtest_usage()
				return 1
			char** base_value = argv + pre * __word_size__
			wtest_base_manifest_path = *base_value
		else if ((for_mode == 0) && (range_index == 0) && (argval[0] != '-') && wtest_str_contains(argval, c"..")):
			range_index = pre
		pre = pre + 1
	if (wtest_load_manifest()):
		return 1
	if (wtest_base_manifest_path != 0):
		if (wtest_load_base_manifest()):
			return 1
	int saw_file = 0
	int i = 2
	while (i < argc):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"--verbose") == 0):
			wtest_verbose = 1
		else if (strcmp(*arg, c"--run") == 0):
			wtest_run_flag = 1
		else if (strcmp(*arg, c"--available") == 0):
			wtest_available_flag = 1
		else if (strcmp(*arg, c"--defhash") == 0):
			wtest_defhash_flag = 1
		else if (strcmp(*arg, c"-f") == 0):
			i = i + 1   # value already consumed by the pre-scan above
		else if (strcmp(*arg, c"--base-manifest") == 0):
			i = i + 1   # value already consumed by the pre-scan above
		else if (i == range_index):
			if (wtest_range_expand(*arg)):
				return 1
			saw_file = 1
		else:
			wtest_map_path(*arg)
			saw_file = 1
		i = i + 1
	if ((saw_file == 0) && for_mode):
		# "for" names its paths as positional args by design (unlike
		# "changed", which is commonly piped from 'git diff --name-only');
		# no paths at all is a usage error, not an empty-stdin selection.
		wtest_usage()
		return 1
	if ((saw_file == 0) && (for_mode == 0)):
		wstream* in = stdin_reader()
		string_builder* line = string_new()
		while (stream_read_line(in, line)):
			wtest_map_path(line.data)
		string_free(line)
	if (wtest_available_flag):
		wtest_apply_available_filter()
	wtest_emit_targets()
	if (wtest_run_flag):
		return wtest_run_selected()
	return 0
