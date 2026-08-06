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
      win64, wasm) resolves lib/__arch__/ and other per-target imports
      for that target, so arch-only modules (lib/__arch__/x64/,
      graphics/cocoa.w) select exactly the targets that compile them.
      A root that fails to compile falls back to literal matching
      only. Closures are cached in bin/.wtest_deps_cache and re-used
      until the content hash of any file in the cached closure
      changes (failures are cached far more conservatively — see the
      cache-format comment above wtest_cache_load). --defhash (opt-in,
      see below) further skips a path's
      own closure additions when 'bin/wv2 defhash' proves its recorded
      definitions did not change.

  (c) RESIDUE RULES for coupling the import graph cannot see:
      - seed-graph paths -> verify + self_host_warning_test. The
        self-host fixpoint is the designed gate for anything the
        compiler itself is built from, and that set is DERIVED, not
        hard-coded: a .w path counts as seed-graph when it appears in
        'bin/wv2 deps w.w' (cached in bin/.wtest_deps_cache under the
        root id "x86 w.w", exactly like a rule-(b) closure). That is
        how debugger/, repl/, the seed libs/extras/ trees
        (parser_generator, c_import, c_preprocessor), the auto-imported
        container runtime (structures/hash_table.w, w_list.w,
        prelude.w, ...) and the lib/ files the compiler imports get the
        gate — an edit there rebuilds every compiler stage and can
        corrupt self-hosting exactly like a compiler/ edit
        (ai_tooling_next_steps.md, 3x 2026-07-28). When the closure is
        unavailable (bin/wv2 missing or w.w mid-edit broken, deps
        fails), the rule fails OPEN to the hard-coded prefix floor —
        w.w / grammar.w / codegen.w and compiler/ grammar/
        code_generator/ paths (wtest_compiler_tree) — never narrower
        than the historical behavior, SAYS SO with a one-line stderr
        warning, and never persists the failure (it used to be cached
        against w.w's content hash, which silently pinned the rule to
        the prefix floor until w.w itself changed even after bin/wv2
        reappeared — the 2026-07-28 residue). Only that prefix floor skips
        rule (b) (closure selection for compiler internals would
        degenerate; w.w is excluded as a closure root for the same
        reason); the derived remainder keeps its closure selection, so
        a debugger/ edit still recommends the wdbg/attach/repl targets
        alongside verify. *_asm.w runtime stubs also -> asm_stubs_test
        (drift-checked against tests/asm/, #170).
      - lib/__arch__/<arch>/ paths in that arch's OWN seed closure
        ('bin/wv2 <arch> deps w.w', cached as "<arch> w.w") -> the
        arch's self-host fixpoint (verify_x64 / verify_arm64 /
        verify_wasm / verify_win), when the manifest has that target —
        verify_darwin is on the never-emit list, so arm64_darwin
        runtime edits add nothing here. The default-arch rule above
        cannot see these: lib/__arch__/x64/syscalls.w is not in the
        x86 closure, yet an edit there can corrupt exactly the x64
        fixpoint (the build_wasm/verify_wasm chain's only root is w.w,
        invisible to rule (b) since w.w is an excluded root).
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
        tests/c_import_skip_note_fixture.h additionally ->
        c_import_verbose_note_test, and
        tests/c_import_error_directive_fixture.h ->
        c_import_error_directive_test: those headers are read by
        c_import at compile time, invisible to the import graph.
      - libs/standard/net/x509_fixtures/ -> net_x509_test and
        tests/metadata/ -> metadata_test: run-time fixture data.
      - tests/wexec/remote_cache.json -> wexec_remote_cache_test: the
        target's own manifest steps only name the compiled test binary;
        the fixture path itself is a literal inside the test's source,
        passed to a bin/wexec subprocess as a "-f" argument at run
        time, so neither rule (a) nor rule (b) can see the coupling.
      - tools/mac/run_darwin_tests.sh -> the darwin cross-compile
        targets whose Mach-O binaries it executes on a Mac
        (arm64_darwin_smoke_test, net_darwin, graphics_darwin,
        pac_darwin): the run leg lives outside the manifest, so no
        argv or import records the coupling. (Its arm64 counterpart
        tools/run_arm64.sh needs no rule: the qemu targets invoke it
        directly in their steps, which rule (a) sees.)
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
steps execute Mach-O binaries) are never emitted, and neither is
manifest (it rewrites build.json in place, and running it in the same
parallel selection as manifest_check raced the check's byte-compare
against the mid-rewrite file — manifest_check alone is the drift gate);
step-less aggregate targets (tests, tests_x64, tests_win64) are never
selected by (a)/(b).

Output: unique target names, one per line, in manifest order ('tests'
is last in the manifest). --verbose prints 'path -> target' notes to
stderr. Paths come from arguments or stdin (git diff --name-only HEAD |
bin/wtest changed). An empty selection prints 'wtest: 0 targets
selected' to stderr — stdout stays clean (it is piped into 'xargs -r
./wbuild'), but a caller looking at the terminal can tell "nothing to
test" apart from a green run.

Enormous selections COLLAPSE to umbrella targets: editing a file in
every program's import closure (structures/w_list.w and the rest of
the auto-imported runtime, lib/__arch__/x86/syscalls.w, ...) selects
essentially the whole manifest — correct, but useless as a printed
list (~450 lines, ai_tooling_next_steps.md 2026-07-28 / issue #360
item 5). When more than half of the manifest's selectable targets are
selected, every step-less umbrella target (tests, tests_x64,
tests_win64 — detected structurally: no steps, a nonempty deps list)
that has more than half of its own members selected replaces those
members in the output, and one summary line says what happened:
'wtest: collapsed N targets into <umbrellas> (selection covered E of
T selectable targets)'. Selected targets no umbrella covers (the
arm64/wasm/darwin gates, tool builds) stay listed individually, so
the collapsed output is still a complete, valid target list for
'./wbuild test_changed' / 'xargs -r ./wbuild'. The collapse is
arch-accurate for free: an x86-only runtime edit selects few
tests_x64 members, so only 'tests' collapses and the x64 umbrella is
never pulled in. Below either threshold nothing changes.

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
off an aarch64 host), wasm run targets ('sh tools/run_wasm.sh', which
needs wasmtime or node), win64 run targets ('wine'/'wine64'), or a
tools/mac/ script — so the printed selection is runnable as-is instead
of failing on a missing qemu/wasm-runtime/wine/Mac. Detection is
mechanical and conservative: only a step whose argv[0] (or, for the
arm64/wasm wrappers, argv[1]) is one of those recognized shapes is
checked for presence on PATH (or, for tools/mac/, as a file); anything
else is left alone, so a target is only ever dropped on positive
evidence. One 'wtest: dropped N
unavailable target(s) (<reason>)' line per distinct reason is printed to
stderr, plus a 'dropped N unavailable targets total' line when more than
one reason fired. './wbuild test_changed' passes --available by default.

--runnable-here is --available plus deeper host probes, for hosts where
the runner-shape checks above are not enough (ai_tooling_next_steps.md
2026-07-28: agents kept chasing env-blocked failures for the 32-bit
dynamically linked tests). Everything --available drops, it drops; in
addition it pairs each run step with the compile step that produced its
binary ('bin/wv2 [selector] ... src.w ... -o bin/X' followed by a step
whose argv[0] is 'bin/X') and reads the needs off the source text of
EVERY FILE in the root's cached import closure — rule (b)'s machinery
(the run-local store when this selection already computed closures,
else bin/.wtest_deps_cache loaded lazily and only ever READ: the filter
never shells out to 'bin/wv2 deps' and never writes the cache file) —
falling back to the root file alone when the closure is unknown (never
computed, stale, or a recorded compile failure). So a directive buried
in an imported module is attributed to every target that links it:
graphics/gl_linux.w's c_lib reaches graphics_gl_smoke_test, lib/
tensor.w's 'import lib.cuda' reaches the tensor_gpu_test family
(ai_tooling_next_steps.md 2026-07-29). The needs themselves: a
column-0 'c_lib'/'c_import' directive means the produced binary is
dynamically linked and needs the target word size's ELF interpreter
(/lib/ld-linux.so.2 for x86, /lib64/ld-linux-x86-64.so.2 for x64 —
probed as files, not hardcoded per machine), and a column-0 'import
lib.cuda' means it opens the NVIDIA driver (/dev/nvidiactl,
/dev/nvidia0 or nvidia-smi on PATH). Column-0 text inside a '#' line
comment or a block comment is never a directive — closure scanning
made that matter: lib/safetensors.w's header prose contains a column-0
'import lib.cuda or ...' sentence that must not flag every
safetensors importer as GPU-needing. A tools/mac/ step additionally
requires an actual macOS host (/System/Library/CoreServices/
SystemVersion.plist), not just the script existing in the checkout.
Detection stays positive-evidence-only, and arm64/wasm/win64 run steps
are already covered by --available's runner probes (qemu serves the
loader role under emulation). Reporting reuses --available's 'dropped
N unavailable target(s) (<reason>)' lines.

--defhash (opt-in; 'changed' and 'for' both accept it) refines rule (b)
per .w path: 'bin/wv2 defhash' is run on both the worktree copy and
'git show HEAD:<path>' (staged to a scratch file under bin/), and when
the recorded definition name set and every name's hash come back
identical, that path's import-closure additions are skipped for this
run — rule (a) literal matches and the rule (c) residue mappings still
apply, so a comment/formatting-only edit stops recommending every
importer without under-selecting the fixed rules. It fails OPEN: a path
new to HEAD, a git or 'bin/wv2 defhash' error, or an actual
addition/removal/hash change in the recorded definitions all fall back
to the ordinary closure scan for that path instead. Selection without
--defhash is unchanged byte-for-byte. When the path list arrives on
stdin and one or more paths compare byte-identical between HEAD and the
worktree, a warning goes to stderr suggesting the ranged form: 'git
diff --name-only main..HEAD | wtest changed --defhash' after committing
is a footgun — every piped path reads unchanged against the worktree,
so closure selection silently skips all of them
(wtest_defhash_clean_warning; stdout selection is untouched).
('HEAD' above generalizes to the commit-ranged left endpoint below when
a range is active; see wtest_range_left / wtest_range_right and
wtest_defhash_unchanged's left_rev/right_is_worktree.)

Generic and operator-overload definitions are covered by 'bin/wv2
defhash' itself now (wave plan C task 4f: grammar/generic.w,
grammar/operator_overload.w both call defhash_note), so the name-set
and per-name hash comparison above already catches a real edit to one --
no separate textual pre-check is needed. Earlier (task 2g) this function
also ran a textual 'risky-shaped content' scan (the literal word
'operator', or an identifier directly followed by a bracket of
uppercase-led names) that forced a fallback on ANY file merely
containing those shapes, comment-only edits included, as a stand-in for
the coverage gap; it has been removed now that the gap is closed
(git history has it, tools/test_map.w, if a similar stand-in is ever
needed for some future defhash blind spot).

Commit-ranged selection (issue #251 direction 4b; 'changed' only, not
'for'): a single positional argument containing '..' is a git revision
range instead of a changed-file path — no tracked path in this tree
ever contains '..', so the two are unambiguous; a second range
argument is an argument error. Accepted spellings mirror 'git diff
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
stale, prints a 'wtest: building import-closure cache...' banner with
the outstanding root count to stderr, then one progress line per 20
computed roots carrying the elapsed wall time and an extrapolated
time-left estimate — that pass can take several minutes on a big tree
(over 20 under parallel load, ai_tooling_next_steps.md 2026-07-29),
the progress lines distinguish slow-but-alive from hung, and the
estimate lets a caller under a per-command timeout decide between
waiting and re-invoking. The cache file is checkpointed at every
progress line (its entries validate individually), so an interrupted
first run resumes from the last checkpoint instead of restarting. A
warm cache prints nothing extra.

'wtest cache [-f manifest.json]' pays that cost deliberately, so CI or
a fresh checkout can run './wbuild wtest_cache' once right after
'./wbuild build' and every later selection starts warm instead of the
first 'wtest changed' being the invocation that eats the cold walk. It
warms every root any selection can consult: the archs superset of rule
(b)'s compile roots plus the seed-graph w.w roots — "x86 w.w" always,
"<arch> w.w" for each arch whose verify target the manifest carries,
mirroring wtest_map_residue's own gate (the per-arch 'bin/wv2 deps
<arch> w.w' runs are near-full compiles, the single most expensive
entries). A warm rerun revalidates content hashes and computes
nothing. It exits 1 only when warming is impossible (unreadable
manifest, bin/wv2 missing); a root that fails to compile is an
ordinary, reported state — the summary line counts it, selection falls
back to literal matching for it — not a warming failure.

'wtest why [<arch>] <file.w> [-f manifest.json]' explains one root's
deps/closure story (ai_tooling_next_steps.md 2026-08-05: the aggregate
deps-failure warning above names the failing roots; this answers "so
what happened to this one?"). The arch word defaults to x86. It
reports: which targets compile the (arch, file) pair; what
bin/.wtest_deps_cache records for it — a success entry (file count,
the informational 'V' bin/wv2 hash, whether the closure digest still
validates) or a failure entry (the recorded hashes, the 'M' missing
import and whether it is still absent, the 'E' stderr line, and
whether the entry still holds) — via a RAW scan, so even a stale
entry the validating loader silently drops is explained; the live
state (bin/wv2 presence, plus a fresh 'bin/wv2 deps' run when nothing
usable is cached — the outcome goes through the ordinary cache
machinery, so a 'why' also warms the cache); and the selection story
for the root's file, computed by the same wtest_map_path machinery a
'changed' run uses, with every selected target attributed to the
rule(s) that reach it (closure of which root(s), literal step
reference, or residue). Timeouts are still never cached, so a
timed-out root reads as "no cache entry" plus whatever the live
re-run finds.

Each 'bin/wv2 deps' shell-out runs under a 120-second timeout
(WTEST_DEPS_TIMEOUT_MS overrides the budget, mainly so tests can
shrink it). A shell-out that TIMES OUT is retried once immediately —
under parallel load a 'deps <arch> w.w' near-full compile can
transiently exceed the budget (ai_tooling_next_steps.md 2026-07-29,
U4) — and when the retry also fails the root falls back exactly like
any other deps failure for this run, but the failure is NEVER
persisted to the cache file (only real nonzero compile exits are,
under the conservative X-entry validation above wtest_cache_load), so
the next run retries it instead of a stale entry silently pinning
selection — per-arch verify selection included — until the root's
content changes. Every failed shell-out (timeout, nonzero exit, spawn
failure) prints one stderr line naming the root, so a lost closure is
visible at the moment it is lost instead of silent.
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
int wtest_runnable_here_flag
int wtest_defhash_flag
# source path -> needs bits + 1 (--runnable-here memo, per closure
# FILE, not per root; bit 1 = c_lib/c_import dynamic linking, bit 2 =
# lib.cuda GPU access).
map[char*, int] wtest_source_needs_memo
# root id -> extra cache lines ('V <bin/wv2 hash>', optionally
# 'M <missing import>' and 'E <stderr first line>') for a PERSISTABLE
# deps failure; a failed root with no entry here (bin/wv2 missing,
# spawn failure) is memoized for this run only and never written to
# the cache file.
map[char*, char*] wtest_failure_meta
# Set by wtest_run_deps when the failure it just returned 0 for is
# persistable (see wtest_failure_meta); 0 otherwise.
char* wtest_last_failure_meta
# root id -> one-line human-readable failure detail for the most
# recent failed deps run of ANY flavor (compile stderr, timeout
# marker, spawn failure). Run-local; for persistable compile failures
# the same line also rides the cache entry's 'E ' line, so it survives
# across runs for the aggregate warning and 'wtest why'.
map[char*, char*] wtest_failure_lines
# Set by wtest_run_deps on EVERY failure path (unlike
# wtest_last_failure_meta, which only persistable failures carry).
char* wtest_last_failure_line
# root id -> the bin/wv2 content hash a SUCCESSFUL closure was
# computed under (set on live computes and restored from a cache
# entry's informational 'V ' line): 'wtest why' reports it, and
# wtest_cache_save carries it forward so a revalidated entry keeps
# the hash of the compiler that actually computed it.
map[char*, char*] wtest_closure_vhash
# Seed-closure root ids whose fallback warning already printed this
# run, so per-path wtest_seed_graph calls warn once per arch.
map[char*, int] wtest_seed_warned
# Paths whose --defhash comparison (outside a range) found HEAD and the
# worktree byte-identical — committed-clean, the ranged-form footgun's
# signature. Feeds wtest_defhash_clean_warning for stdin-piped runs.
int wtest_defhash_clean_count
char* wtest_manifest_path
char* wtest_base_manifest_path       # 0 = no --base-manifest given
json_value* wtest_base_manifest      # parsed baseline, 0 until loaded
int wtest_closures_ready
int wtest_mask32
# Resolved 'bin/wv2 deps' shell-out budget in ms; 0 until first read
# (wtest_deps_budget_ms).
int wtest_deps_budget

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
	stream_write_line(err, c"usage: wtest changed [--verbose] [--run] [--available] [-f manifest.json] [--base-manifest base.json] [file...] [--defhash] [--runnable-here] [A..B | A...B | A..]")
	stream_write_line(err, c"       wtest for <file>... [--verbose] [--run] [--available] [-f manifest.json] [--base-manifest base.json] [--defhash] [--runnable-here]")
	stream_write_line(err, c"       wtest archs <file>... [--check] [-f manifest.json]")
	stream_write_line(err, c"       wtest why [<arch>] <file.w> [-f manifest.json]")
	stream_write_line(err, c"       wtest cache [-f manifest.json]")
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
	# 'manifest' rewrites build.json in place — a worktree mutation, not
	# a gate. Selecting it alongside manifest_check made './wbuild
	# test_changed' race the two under bin/wexec's parallel scheduler
	# (they share only the wbuildgen dep), and manifest_check's
	# byte-compare could read build.json mid-rewrite. manifest_check
	# alone is the drift gate; 'manifest' is the fix a failing gate tells
	# the caller to run.
	wtest_never_emit[c"manifest"] = 1
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
	if (strcmp(word, c"wasm") == 0):
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
  V <content hash of the bin/wv2 that computed it>   (informational)
  F <closure file> (one line per file, in deps output order)
An entry is valid when re-hashing every F file reproduces H; otherwise
'bin/wv2 deps [selector]' is re-run. The V line is never validated —
'wtest why' reports it — and a line whose leading tag is unknown is
skipped by the parser, so caches written before a tag existed (and
caches written after a new one is added) stay readable in both
directions without a format-marker bump.

Failures are cached conservatively, so a transient environment problem
can never pin a rule (the 2026-07-28 residue: a 'deps w.w' failure
cached while bin/wv2 was merely missing silently kept the seed-graph
rule on its prefix floor until w.w itself changed). A root whose
compile failed with bin/wv2 PRESENT is cached as
  X <arch> <root>
  H <content hash of the root file itself>
  V <content hash of bin/wv2>
  M <import path the compile reported missing>   (only when one was)
  E <first line of the failed compile's stderr>  (informational)
and revalidated on load against all three: the root's own content, the
compiler binary (a rebuilt or restored bin/wv2 retries every failure),
and — when the failure was a missing import, e.g. a bin/-generated
parser source not built yet — that path still being absent, so the
failure retries the moment the missing file appears. A failure with
bin/wv2 missing (or a spawn failure) is never written at all, and
neither is a deps run that TIMED OUT (after its one immediate retry,
see wtest_run_deps): a timeout says nothing about the root's content,
only about this machine's load, so persisting it under the root's
hash pinned per-arch verify selection until the root changed (the
2026-07-29 U4/U5 residue). Both are memoized for the current run only
and retried next run. Entries without an arch column, or 'X' entries
without a V line — caches written by older wtest builds — fail to
parse and simply recompute. */

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


# The import path a failed compile's stderr reports missing, or 0.
# The compiler stops at its first error, so at most one path is ever
# reported; both spellings are covered ("cannot locate '<path>'" for
# an import that does not resolve, "no such file: '<path>'" for a
# missing root). Returns a clone of the quoted path.
char* wtest_missing_import(char* stderr_text):
	int i = 0
	while (stderr_text[i] != 0):
		int hit = 0
		if (starts_with(&stderr_text[i], c"cannot locate '")):
			hit = strlen(c"cannot locate '")
		else if (starts_with(&stderr_text[i], c"no such file: '")):
			hit = strlen(c"no such file: '")
		if (hit > 0):
			string_builder* path = string_new()
			int j = i + hit
			while ((stderr_text[j] != 0) && (stderr_text[j] != 39) && (stderr_text[j] != 10)):
				string_append_char(path, stderr_text[j])
				j = j + 1
			char* out = path.data
			free(path)
			if (strlen(out) > 0):
				return out
			free(out)
			return 0
		i = i + 1
	return 0


# The first non-empty line of a failed deps run's stderr (cloned), or
# 0 when there is none: the one-line failure detail wtest_failure_lines
# records and a persistable failure's 'E ' cache line carries. One line
# is enough — the compiler stops at its first error — and keeping it
# single-line means it can ride the line-oriented cache format as-is.
char* wtest_stderr_first_line(char* stderr_text):
	int i = 0
	string_builder* line = string_new()
	while (stderr_text[i] != 0):
		if (stderr_text[i] == 10):
			if (line.length > 0):
				char* out = line.data
				free(line)
				return out
		else:
			string_append_char(line, stderr_text[i])
		i = i + 1
	if (line.length > 0):
		char* tail = line.data
		free(line)
		return tail
	string_free(line)
	return 0


# The per-shell-out 'bin/wv2 deps' timeout budget in ms: 120000 unless
# WTEST_DEPS_TIMEOUT_MS overrides it with a positive integer (mainly so
# tests can exercise the timeout path in milliseconds instead of 120s).
int wtest_deps_budget_ms():
	if (wtest_deps_budget == 0):
		wtest_deps_budget = 120000
		char* override = env_get(c"WTEST_DEPS_TIMEOUT_MS")
		if (override != 0):
			int value = atoi(override)
			if (value > 0):
				wtest_deps_budget = value
	return wtest_deps_budget


# One stderr line per failed 'bin/wv2 deps' shell-out (header comment):
# a lost closure must be visible the moment it is lost, not only in the
# aggregate fallback counts wtest_compute_closures prints at the end.
void wtest_deps_shellout_warn(char* what, char* id, char* tail):
	wstream* err = stderr_writer()
	string_builder* note = string_new()
	string_append(note, c"wtest: warning: 'bin/wv2 deps' ")
	string_append(note, what)
	string_append(note, c" for root '")
	string_append(note, id)
	string_append(note, c"'")
	string_append(note, tail)
	stream_write_line(err, note.data)
	string_free(note)
	stream_flush(err)


# Run 'bin/wv2 deps [selector] <root>' for one root id; returns a
# newline-guarded closure blob or 0 when the root does not compile for
# its target (literal matching still applies). A run that exceeds the
# timeout budget is retried once immediately (header comment: a
# timeout is load, not content), and a still-timed-out root is a
# NON-persistable failure. On a failure that is safe to cache (bin/wv2
# was present and the compile really exited nonzero, rather than a
# missing/broken toolchain or a timeout), wtest_last_failure_meta
# carries the extra validation lines the cache entry needs (header
# comment above wtest_cache_load); otherwise it is 0 and the failure
# must not be persisted. Every failure path prints one stderr line
# naming the root.
char* wtest_run_deps(char* id):
	wtest_last_failure_meta = 0
	wtest_last_failure_line = 0
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
	int budget = wtest_deps_budget_ms()
	process_result* result = process_run(c"bin/wv2", argv, 0, 0, budget)
	if ((result != 0) && (result.status == process_status_timeout())):
		wtest_deps_shellout_warn(c"timed out", id, c"; retrying once")
		process_result_free(result)
		result = process_run(c"bin/wv2", argv, 0, 0, budget)
	free(cast(char*, argv))
	free(arch)
	if (result == 0):
		wtest_deps_shellout_warn(c"failed", id, c" (could not run bin/wv2)")
		wtest_last_failure_line = c"could not run bin/wv2 (spawn failure; never cached)"
		return 0
	if (result.status == process_status_timeout()):
		# Never persisted (header comment above wtest_cache_load): a
		# run-local memo only, so the next run retries instead of a
		# stale cache entry pinning selection until the root changes.
		wtest_deps_shellout_warn(c"timed out again", id, c"; giving up for this run (timeouts are never cached)")
		string_builder* mark = string_new()
		string_append(mark, c"timed out twice (budget ")
		string_append_int(mark, budget)
		string_append(mark, c"ms; timeouts are never cached)")
		wtest_last_failure_line = mark.data
		free(mark)
		process_result_free(result)
		return 0
	if (result.status != 0):
		wtest_deps_shellout_warn(c"failed", id, c"")
		char* detail = wtest_stderr_first_line(result.stderr_text)
		if (detail == 0):
			string_builder* fallback = string_new()
			string_append(fallback, c"exit status ")
			string_append_int(fallback, result.status)
			string_append(fallback, c" with empty stderr")
			detail = fallback.data
			free(fallback)
		wtest_last_failure_line = detail
		# Persistable only when the compiler itself was there to fail:
		# key the failure to bin/wv2's content (a restored/rebuilt
		# compiler retries it) and, when the compile named a missing
		# import, to that path staying absent (a generated source
		# appearing retries it immediately). The 'E ' line is purely
		# informational (never validated): the recorded stderr detail,
		# so 'wtest why' can report the reason across runs.
		if (wtest_file_exists(c"bin/wv2")):
			string_builder* meta = string_new()
			string_append(meta, c"V ")
			string_append(meta, wtest_file_hash(c"bin/wv2"))
			string_append_char(meta, 10)
			char* missing = wtest_missing_import(result.stderr_text)
			if (missing != 0):
				string_append(meta, c"M ")
				string_append(meta, missing)
				string_append_char(meta, 10)
				free(missing)
			string_append(meta, c"E ")
			string_append(meta, detail)
			string_append_char(meta, 10)
			wtest_last_failure_meta = meta.data
			free(meta)
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


# Compute one root's closure via wtest_run_deps and record it in the
# store, keeping the failure-persistence bookkeeping in one place: a
# persistable failure's validation lines move from
# wtest_last_failure_meta into wtest_failure_meta so wtest_cache_save
# writes them; a non-persistable one stays a run-local memo. Either
# way the one-line failure detail lands in wtest_failure_lines (the
# named aggregate warning and 'wtest why' read it), and a SUCCESS
# records the computing bin/wv2's hash for the cache's informational
# 'V ' line.
char* wtest_closure_compute(char* root):
	char* blob = wtest_run_deps(root)
	wtest_closure_store(root, blob)
	if ((blob == 0) && (wtest_last_failure_meta != 0)):
		if (wtest_failure_meta == 0):
			wtest_failure_meta = new map[char*, char*]
		wtest_failure_meta[root] = wtest_last_failure_meta
	if ((blob == 0) && (wtest_last_failure_line != 0)):
		if (wtest_failure_lines == 0):
			wtest_failure_lines = new map[char*, char*]
		wtest_failure_lines[root] = wtest_last_failure_line
	if (blob != 0):
		if (wtest_closure_vhash == 0):
			wtest_closure_vhash = new map[char*, char*]
		wtest_closure_vhash[root] = wtest_file_hash(c"bin/wv2")
	return blob


# Finalize one parsed cache entry: keep it only when it still
# validates (header comment above wtest_cache_load). kind 1 = success
# ('R'): the closure digest must match. kind 2 = failure ('X'): the
# root's own hash, the recorded bin/wv2 hash (V) and — when present —
# the recorded missing import (M) still being absent must ALL hold;
# anything else (including a legacy entry with no V line, or a
# pre-arch-column id) is silently dropped and recomputes, so a stale
# failure can never pin a rule. 'detail' (the 'E ' stderr line) and a
# success entry's 'V ' line are informational only — never validated,
# just carried into the run-local maps for 'wtest why' and re-saved.
void wtest_cache_entry(int kind, char* root, char* expected, char* vhash, char* missing, char* detail, string_builder* blob):
	if ((root == 0) || (expected == 0)):
		return
	if (kind == 1):
		if (blob != 0):
			if (strcmp(wtest_closure_digest(blob.data), expected) == 0):
				wtest_closure_store(root, blob.data)
				if (vhash != 0):
					if (wtest_closure_vhash == 0):
						wtest_closure_vhash = new map[char*, char*]
					wtest_closure_vhash[root] = vhash
	if (kind == 2):
		char* path = wtest_root_id_path(root)
		if ((path == 0) || (vhash == 0)):
			return
		if (strcmp(wtest_file_hash(path), expected) != 0):
			return
		if (strcmp(wtest_file_hash(c"bin/wv2"), vhash) != 0):
			return
		if ((missing != 0) && wtest_file_exists(missing)):
			return
		wtest_closure_store(root, 0)
		string_builder* meta = string_new()
		string_append(meta, c"V ")
		string_append(meta, vhash)
		string_append_char(meta, 10)
		if (missing != 0):
			string_append(meta, c"M ")
			string_append(meta, missing)
			string_append_char(meta, 10)
		if (detail != 0):
			string_append(meta, c"E ")
			string_append(meta, detail)
			string_append_char(meta, 10)
		if (wtest_failure_meta == 0):
			wtest_failure_meta = new map[char*, char*]
		wtest_failure_meta[root] = meta.data
		free(meta)
		if (detail != 0):
			if (wtest_failure_lines == 0):
				wtest_failure_lines = new map[char*, char*]
			wtest_failure_lines[root] = detail


# Load cache entries whose content hashes still match; anything stale
# or unparseable is simply dropped (deps re-runs for it).
void wtest_cache_load():
	char* text = file_read_text(c"bin/.wtest_deps_cache")
	if (text == 0):
		return
	int kind = 0
	char* root = 0
	char* expected = 0
	char* vhash = 0
	char* missing = 0
	char* detail = 0
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
				wtest_cache_entry(kind, root, expected, vhash, missing, detail, blob)
				kind = 1
				if (entry[0] == 'X'):
					kind = 2
				root = strclone(entry + 2)
				expected = 0
				vhash = 0
				missing = 0
				detail = 0
				blob = string_new()
				string_append_char(blob, 10)
			else if (starts_with(entry, c"H ")):
				expected = strclone(entry + 2)
			else if (starts_with(entry, c"V ")):
				vhash = strclone(entry + 2)
			else if (starts_with(entry, c"M ")):
				missing = strclone(entry + 2)
			else if (starts_with(entry, c"E ")):
				detail = strclone(entry + 2)
			else if (starts_with(entry, c"F ")):
				if (blob != 0):
					string_append(blob, entry + 2)
					string_append_char(blob, 10)
			string_clear(line)
		else:
			string_append_char(line, c)
		i = i + 1
	wtest_cache_entry(kind, root, expected, vhash, missing, detail, blob)
	string_free(line)
	free(text)


void wtest_cache_save():
	string_builder* out = string_new()
	int i = 0
	while (i < wtest_closure_roots.length):
		char* blob = wtest_closure_blobs[i]
		if (blob == 0):
			# Failed root: persist only a failure whose validation meta
			# was recorded (a real compile failure with bin/wv2
			# present); a toolchain-missing failure is this run's memo
			# only, so it is retried next run instead of pinning
			# anything (header comment above wtest_cache_load).
			char* meta = 0
			if (wtest_failure_meta != 0):
				meta = wtest_failure_meta.get(wtest_closure_roots[i], 0)
			if (meta != 0):
				string_append(out, c"X ")
				string_append(out, wtest_closure_roots[i])
				string_append_char(out, 10)
				string_append(out, c"H ")
				string_append(out, wtest_file_hash(wtest_root_id_path(wtest_closure_roots[i])))
				string_append_char(out, 10)
				string_append(out, meta)
		else:
			string_append(out, c"R ")
			string_append(out, wtest_closure_roots[i])
			string_append_char(out, 10)
			string_append(out, c"H ")
			string_append(out, wtest_closure_digest(blob))
			string_append_char(out, 10)
			# Informational only (never validated): the bin/wv2 this
			# closure was computed under, reported by 'wtest why'. A
			# closure restored from an older cache without one simply
			# stays without one.
			char* vhash = 0
			if (wtest_closure_vhash != 0):
				vhash = wtest_closure_vhash.get(wtest_closure_roots[i], 0)
			if (vhash != 0):
				string_append(out, c"V ")
				string_append(out, vhash)
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


# Append a duration in seconds as '<n>s', or '<n>m' from two minutes
# up — cold-tree estimates run tens of minutes, where second precision
# is noise.
void wtest_append_duration(string_builder* s, int seconds):
	if (seconds >= 120):
		string_append_int(s, seconds / 60)
		string_append_char(s, 'm')
	else:
		string_append_int(s, seconds)
		string_append_char(s, 's')


# Cold/stale-cache closure computation shared by wtest_ensure_closures,
# wtest_archs_ensure_closures and wtest_cache_main: shell out to
# 'bin/wv2 deps' for every
# root wtest_cache_load did not satisfy. Right after a build (or a large
# merge) every root is outstanding and the pass can take several minutes
# (docs/projects/ai_tooling.md), so the banner announces the outstanding
# root count up front, a progress line follows every 20 computed roots
# with the elapsed wall time and an extrapolated time-left estimate
# (header comment: a caller under a per-command timeout can tell
# whether waiting will pay off), and bin/.wtest_deps_cache is
# checkpointed at each progress line —
# cache entries validate individually (wtest_cache_load), so an
# interrupted first run resumes from the last checkpoint instead of
# restarting. A warm cache (the common case) prints and writes nothing.
void wtest_compute_closures(list[char*] roots):
	int missing = 0
	for char* root in roots:
		if (wtest_closure_known(root) == 0):
			missing = missing + 1
	if (missing == 0):
		return
	wstream* err = stderr_writer()
	string_builder* banner = string_new()
	string_append(banner, c"wtest: building import-closure cache, ")
	string_append_int(banner, missing)
	string_append(banner, c" root")
	if (missing != 1):
		string_append_char(banner, 's')
	string_append(banner, c" to compute (first run after a build; this can take several minutes)...")
	stream_write_line(err, banner.data)
	string_free(banner)
	stream_flush(err)
	int done = 0
	int failed = 0
	list[char*] failed_roots = new list[char*]
	int start_ms = process_monotonic_ms()
	for char* pending in roots:
		if (wtest_closure_known(pending) == 0):
			if (wtest_closure_compute(pending) == 0):
				failed = failed + 1
				failed_roots.push(pending)
			done = done + 1
			if ((done % 20) == 0):
				wtest_cache_save()
				# Extrapolated wall estimate in whole seconds: cheap,
				# and roots are similar enough in cost (one compiler
				# front-end run each) for a linear projection to be
				# honest.
				int elapsed_s = (process_monotonic_ms() - start_ms) / 1000
				int left_s = elapsed_s * (missing - done) / done
				string_builder* progress = string_new()
				string_append(progress, c"wtest: import-closure cache: ")
				string_append_int(progress, done)
				string_append_char(progress, '/')
				string_append_int(progress, missing)
				string_append(progress, c" roots computed, ")
				wtest_append_duration(progress, elapsed_s)
				string_append(progress, c" elapsed, ~")
				wtest_append_duration(progress, left_s)
				string_append(progress, c" left")
				stream_write_line(err, progress.data)
				string_free(progress)
				stream_flush(err)
	if ((done % 20) != 0):
		wtest_cache_save()
	if (failed > 0):
		# Say so (header comment, rule b), and say WHICH roots: the
		# anonymous count alone could not tell a caller whether the
		# fallback lost selection coverage for its diff or which roots
		# need fixing (ai_tooling_next_steps.md 2026-08-05). These
		# roots fall back to literal matching this run. A transient
		# failure (bin/wv2 missing) is not persisted, so it is retried
		# next run.
		string_builder* note = string_new()
		string_append(note, c"wtest: warning: 'bin/wv2 deps' failed for ")
		string_append_int(note, failed)
		string_append(note, c" root")
		if (failed != 1):
			string_append_char(note, 's')
		string_append(note, c"; falling back to literal matching for them: ")
		int shown = failed_roots.length
		if (shown > 5):
			shown = 5
		int k = 0
		while (k < shown):
			if (k > 0):
				string_append(note, c", ")
			string_append(note, failed_roots[k])
			k = k + 1
		if (failed_roots.length > shown):
			string_append(note, c" (and ")
			string_append_int(note, failed_roots.length - shown)
			string_append(note, c" more)")
		stream_write_line(err, note.data)
		string_free(note)
		# One representative failure reason (the compiler stops at its
		# first error, so one line is the whole story for that root),
		# plus the pointer to the full per-root explanation.
		char* first_detail = 0
		if (wtest_failure_lines != 0):
			first_detail = wtest_failure_lines.get(failed_roots[0], 0)
		if (first_detail != 0):
			string_builder* sample = string_new()
			string_append(sample, c"wtest: warning: e.g. root '")
			string_append(sample, failed_roots[0])
			string_append(sample, c"': ")
			string_append(sample, first_detail)
			stream_write_line(err, sample.data)
			string_free(sample)
		stream_write_line(err, c"wtest: note: 'wtest why [<arch>] <file.w>' explains any root's selection story")
		stream_flush(err)


void wtest_ensure_closures():
	if (wtest_closures_ready):
		return
	wtest_closures_ready = 1
	wtest_ensure_roots()
	# The store may already be initialized: the seed-graph residue rule
	# (wtest_seed_closure) loads the cache lazily before rule (b) ever
	# runs. Re-initializing here would leak its w.w entries and re-read
	# the cache file for nothing (mirrors wtest_archs_ensure_closures).
	if (wtest_closure_roots == 0):
		wtest_closure_roots = new list[char*]
		wtest_closure_blobs = new list[char*]
		wtest_cache_load()
	wtest_compute_closures(wtest_roots)


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
					char* kind = wtest_get_string(rec, c"kind")
					char* hash = wtest_get_string(rec, c"hash")
					if ((name == 0) || (kind == 0) || (hash == 0)):
						failed = 1
					else:
						# Key by kind+name: W permits e.g. a struct
						# and a function with the same name, and a
						# name-only key would let the later record
						# mask a real edit to the earlier one. A
						# duplicate kind+name key means this map
						# cannot represent the file faithfully --
						# fail open rather than compare it.
						string_builder* keyb = string_new()
						string_append(keyb, kind)
						string_append(keyb, c":")
						string_append(keyb, name)
						char* key = strclone(keyb.data)
						string_free(keyb)
						if (key in out):
							failed = 1
						else:
							out[key] = strclone(hash)
			string_clear(line)
		else:
			string_append_char(line, c)
		i = i + 1
	string_free(line)
	process_result_free(result)
	if (failed):
		return 0
	return out


# Concatenated column-0 'import' lines of a source text, in order.
# Imports belong to no definition span, so identical per-definition
# hashes cannot prove an import-only edit away: swapping or adding an
# import redirects which module supplies a called symbol and changes
# every importer's binary while every defhash record stays identical.
char* wtest_import_signature(char* text):
	string_builder* sig = string_new()
	int i = 0
	int bol = 1
	while (text[i] != 0):
		int c = text[i]
		if (bol && (starts_with(&text[i], c"import ") || starts_with(&text[i], c"import\t"))):
			while ((text[i] != 10) && (text[i] != 0)):
				string_append_char(sig, text[i])
				i = i + 1
			string_append_char(sig, 10)
			bol = 1
			if (text[i] != 0):
				i = i + 1
		else:
			bol = (c == 10)
			i = i + 1
	char* out = strclone(sig.data)
	string_free(sig)
	return out


# The --defhash decision for one changed .w path: 1 when it is safe to
# skip this path's rule-(b) closure additions (its recorded definitions
# are provably unchanged between the comparison's two sides), 0
# otherwise -- fail open in every other case, per the header comment.
# Generic and operator-overload definitions are recorded by 'bin/wv2
# defhash' itself now (wave plan C task 4f), so no separate textual
# pre-check is needed here any more (task 2g's
# wtest_defhash_risky_text, removed). Outside a commit range the two
# sides are HEAD (left) and the worktree (right), exactly as before
# wtest_range_* existed; inside one they are the range's resolved
# left/right endpoints (header comment, "Commit-ranged selection") --
# rev-vs-rev content instead of HEAD-vs-worktree. wtest_note calls make
# the decision visible under --verbose without adding new output
# surface.
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
	char* left_rev = c"HEAD"
	if (wtest_range_active):
		left_rev = wtest_range_left
	char* left_text = wtest_git_show(left_rev, path)
	if (left_text == 0):
		free(right_text)
		wtest_note(path, c"defhash: fallback (no left-hand version, or git error)")
		return 0
	# Committed-clean footgun bookkeeping (header comment, --defhash):
	# outside a range this comparison is HEAD vs the worktree, so a
	# byte-identical pair means the path carries no uncommitted edit at
	# all — when the path list was piped in, it almost certainly came
	# from a ranged diff and the caller wanted the ranged form. Counted
	# here, warned about once in main; the decision below is unchanged.
	if ((wtest_range_active == 0) && (strcmp(left_text, right_text) == 0)):
		wtest_defhash_clean_count = wtest_defhash_clean_count + 1
	# Import-only edits are invisible to the per-definition hashes (see
	# wtest_import_signature) -- compare the import lines textually
	# before trusting the hash comparison at all.
	char* left_imports = wtest_import_signature(left_text)
	char* right_imports = wtest_import_signature(right_text)
	int imports_differ = strcmp(left_imports, right_imports) != 0
	free(left_imports)
	free(right_imports)
	if (imports_differ):
		free(left_text)
		free(right_text)
		wtest_note(path, c"defhash: fallback (import lines changed)")
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


# The committed-clean footgun warning (header comment, --defhash): one
# or more stdin-piped paths compared byte-identical between HEAD and
# the worktree under the un-ranged form, so their closure refinement
# skipped silently — the signature of piping a ranged diff's path list
# ('git diff --name-only main..HEAD') after committing. stderr only;
# the selection on stdout is untouched.
void wtest_defhash_clean_warning():
	wstream* err = stderr_writer()
	string_builder* line = string_new()
	string_append(line, c"wtest: warning: --defhash without a range compares HEAD vs the worktree, and ")
	string_append_int(line, wtest_defhash_clean_count)
	string_append(line, c" piped path")
	if (wtest_defhash_clean_count == 1):
		string_append(line, c" is")
	else:
		string_append(line, c"s are")
	string_append(line, c" committed-clean vs HEAD, so closure selection skipped ")
	if (wtest_defhash_clean_count == 1):
		string_append(line, c"it")
	else:
		string_append(line, c"them")
	stream_write_line(err, line.data)
	string_free(line)
	stream_write_line(err, c"wtest: warning: for committed changes use the ranged form: wtest changed A..B --defhash")
	stream_flush(err)


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


# The hard-coded compiler-tree prefix floor. Callers that gate BEHAVIOR
# on "compiler internals" (rule b's closure-scan skip, and the root
# exclusion of w.w/grammar.w/codegen.w) key off exactly this set, same
# as always. The verify residue rule instead uses wtest_seed_graph
# below, which widens this floor with the derived 'bin/wv2 deps w.w'
# closure — debugger/, repl/, the seed libs/extras/ trees, the
# auto-imported runtime — without ever narrowing it (header comment,
# rule c).
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


# The import closure blob of w.w compiled for 'arch' ("x86" for the
# default target) — the seed graph, everything the compiler itself is
# built from. Stored and cached exactly like a rule-(b) closure
# (bin/.wtest_deps_cache, root id "<arch> w.w"; the store is the
# memo), so a warm run costs one strcmp scan and a cold one costs a
# single 'bin/wv2 deps [arch] w.w' shell-out, checkpointed
# immediately. Returns 0 when deps fails (bin/wv2 missing, or w.w
# mid-edit broken) — callers fail open to wtest_compiler_tree's
# prefix floor, never silently narrower than the historical rule, and
# the fallback is ANNOUNCED on stderr (once per arch per run — the
# store memoizes the 0). The failure itself is only persisted under
# the conservative X-entry validation (header comment above
# wtest_cache_load); in particular a missing bin/wv2 is never cached,
# so the rule recovers on the first run after the compiler reappears
# instead of staying pinned until w.w changes.
# The fallback announcement (header comment above): printed for a
# fresh failure AND for one loaded from a still-valid X entry (w.w
# genuinely broken across runs) — the fallback is active either way —
# but only once per arch per run, however many changed paths consult
# the rule.
void wtest_seed_warn(char* arch, char* id):
	if (wtest_seed_warned == 0):
		wtest_seed_warned = new map[char*, int]
	if (wtest_seed_warned.get(id, 0)):
		return
	# Clone the key: the known-hit caller frees its id after this call.
	wtest_seed_warned[strclone(id)] = 1
	wstream* err = stderr_writer()
	string_builder* note = string_new()
	string_append(note, c"wtest: warning: 'bin/wv2 deps' failed for root '")
	string_append(note, id)
	if (strcmp(arch, c"x86") == 0):
		string_append(note, c"'; seed-graph residue falls back to the compiler-tree prefix floor this run")
	else:
		string_append(note, c"'; skipping the ")
		string_append(note, arch)
		string_append(note, c" arch-verify residue this run")
	stream_write_line(err, note.data)
	string_free(note)
	stream_flush(err)


char* wtest_seed_closure(char* arch):
	if (wtest_closure_roots == 0):
		wtest_closure_roots = new list[char*]
		wtest_closure_blobs = new list[char*]
		wtest_cache_load()
	char* id = wtest_root_id(arch, c"w.w")
	if (wtest_closure_known(id)):
		char* known = wtest_closure_get(id)
		if (known == 0):
			wtest_seed_warn(arch, id)
		free(id)
		return known
	char* blob = wtest_closure_compute(id)
	if (blob == 0):
		wtest_seed_warn(arch, id)
	wtest_cache_save()
	return blob


# Whether 'path' is part of what the compiler is built from (header
# comment, rule c): the hard-coded prefix floor first (free, and the
# fail-open answer), then the derived default-arch seed closure. Only
# .w paths consult the closure — it contains nothing else, and the
# early-out keeps data/doc-file selection from ever paying the deps
# shell-out.
int wtest_seed_graph(char* path):
	if (wtest_compiler_tree(path)):
		return 1
	if (ends_with(path, c".w") == 0):
		return 0
	return wtest_closure_contains(wtest_seed_closure(c"x86"), path)


# The '<arch>' segment of a 'lib/__arch__/<arch>/...' path (cloned), or
# 0 for any other shape (including a bare 'lib/__arch__/<arch>' with no
# trailing component).
char* wtest_arch_dir_selector(char* path):
	if (starts_with(path, c"lib/__arch__/") == 0):
		return 0
	int i = strlen(c"lib/__arch__/")
	string_builder* s = string_new()
	while ((path[i] != 0) && (path[i] != '/')):
		string_append_char(s, path[i])
		i = i + 1
	if ((path[i] != '/') || (s.length == 0)):
		string_free(s)
		return 0
	char* arch = s.data
	free(s)
	return arch


# An arch selector word -> its self-host fixpoint target. verify_darwin
# is on the never-emit list (its steps execute Mach-O binaries), so
# returning it is harmless: wtest_add drops never-emit names.
char* wtest_arch_verify_target(char* arch):
	if (strcmp(arch, c"x64") == 0):
		return c"verify_x64"
	if (strcmp(arch, c"arm64") == 0):
		return c"verify_arm64"
	if (strcmp(arch, c"wasm") == 0):
		return c"verify_wasm"
	if (strcmp(arch, c"win64") == 0):
		return c"verify_win"
	if (strcmp(arch, c"arm64_darwin") == 0):
		return c"verify_darwin"
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
	if (wtest_seed_graph(path)):
		wtest_add(path, c"verify")
		wtest_add(path, c"self_host_warning_test")
		if (ends_with(path, c"_asm.w")):
			wtest_add(path, c"asm_stubs_test")
		matched = 1
	# An arch runtime file in that arch's own seed closure gates that
	# arch's fixpoint (header comment, rule c): the build/verify chain's
	# only root is w.w, which rule (b) excludes, so no closure ever
	# reaches the per-arch verify targets. The manifest lookup comes
	# first so a fixture manifest (-f) without the target never pays the
	# deps shell-out, and wtest_add's unknown-name 'tests' fallback is
	# never triggered by a missing verify twin.
	char* arch_dir = wtest_arch_dir_selector(path)
	if (arch_dir != 0):
		if (wtest_selector(arch_dir)):
			char* arch_verify = wtest_arch_verify_target(arch_dir)
			if (arch_verify != 0):
				if (wtest_target_defs.get(arch_verify, 0) != 0):
					if (wtest_closure_contains(wtest_seed_closure(arch_dir), path)):
						wtest_add(path, arch_verify)
						matched = 1
		free(arch_dir)
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
	if (strcmp(path, c"tools/mac/run_darwin_tests.sh") == 0):
		wtest_add(path, c"arm64_darwin_smoke_test")
		wtest_add(path, c"net_darwin")
		wtest_add(path, c"graphics_darwin")
		wtest_add(path, c"pac_darwin")
		matched = 1
	if (starts_with(path, c"libs/extras/c_import/") | starts_with(path, c"libs/extras/c_preprocessor/")):
		wtest_add(path, c"c_import_test")
		wtest_add(path, c"c_preprocessor_test")
		wtest_add(path, c"c_import_errno_test")
		wtest_add(path, c"c_import_libc_test")
		wtest_add(path, c"c_import_verbose_note_test")
		wtest_add(path, c"c_import_error_directive_test")
		matched = 1
	if (strcmp(path, c"tests/c_import_skip_note_fixture.h") == 0):
		wtest_add(path, c"c_import_verbose_note_test")
		matched = 1
	if (strcmp(path, c"tests/c_import_error_directive_fixture.h") == 0):
		wtest_add(path, c"c_import_error_directive_test")
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

	# (b) import closures — compiler-tree PREFIX paths are covered by
	# verify (see header; deliberately the narrow wtest_compiler_tree
	# floor, not wtest_seed_graph: derived seed-graph files like
	# debugger/ or lib/stream.w appear in real leaf closures — wdbg,
	# repl, the stream tests — and must keep that selection alongside
	# the verify residue), deleted files cannot appear in a computable
	# closure, and only .w files ever appear in one. --defhash (opt-in) can skip
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


# tools/run_wasm.sh execs wasmtime when installed and falls back to
# node's built-in WASI (node >= 20); either one on PATH is positive
# evidence a wasm run step can execute.
int wtest_wasm_runtime_available():
	if (wtest_path_has(c"wasmtime")):
		return 1
	return wtest_path_has(c"node")


/* --runnable-here (header comment): host probes beyond --available's
runner shapes. All detection is positive evidence — a probe that
cannot decide leaves the target alone. */

# Needs bits of one source file, read off its text (memoized): bit 1 =
# a column-0 c_lib/c_import directive (the produced binary is
# dynamically linked), bit 2 = a column-0 'import lib.cuda' or a c_lib
# line naming libcuda (either way the binary opens the NVIDIA driver).
# Comment-aware: column-0 text inside a '#' line comment or a /* */
# block comment is prose, not a directive — closure-level attribution
# scans library files whose header comments legitimately contain
# directive-shaped sentences (lib/safetensors.w's column-0 'import
# lib.cuda or ...'), so the scan tracks both comment forms the
# tokenizer knows before matching.
int wtest_source_needs(char* path):
	if (wtest_source_needs_memo == 0):
		wtest_source_needs_memo = new map[char*, int]
	int memo = wtest_source_needs_memo.get(path, 0)
	if (memo != 0):
		return memo - 1
	int needs = 0
	char* text = file_read_text(path)
	if (text != 0):
		int i = 0
		int bol = 1
		int in_block = 0
		while (text[i] != 0):
			if (in_block):
				if ((text[i] == '*') && (text[i + 1] == '/')):
					in_block = 0
					bol = 0
					i = i + 2
				else:
					bol = (text[i] == 10)
					i = i + 1
			else if (text[i] == '#'):
				# Line comment: skip to the newline (kept, so bol stays
				# accurate for the next line).
				while ((text[i] != 0) && (text[i] != 10)):
					i = i + 1
			else if ((text[i] == '/') && (text[i + 1] == '*')):
				in_block = 1
				i = i + 2
			else:
				if (bol):
					if (starts_with(&text[i], c"c_lib ") || starts_with(&text[i], c"c_import ")):
						needs = needs | 1
						if (starts_with(&text[i], c"c_lib \"libcuda")):
							needs = needs | 2
					if (starts_with(&text[i], c"import lib.cuda")):
						needs = needs | 2
				bol = (text[i] == 10)
				i = i + 1
		free(text)
	wtest_source_needs_memo[path] = needs + 1
	return needs


# Needs bits of one compiled (arch, root) pair at CLOSURE level
# (ai_tooling_next_steps.md 2026-07-29): the OR of wtest_source_needs
# over every file in the root's cached import closure, so a directive
# buried in an imported module (graphics/gl_linux.w's c_lib,
# lib/tensor.w's 'import lib.cuda') is attributed to every target that
# links it. The closure comes from rule (b)'s machinery — the run-local
# store when this selection already computed it, else
# bin/.wtest_deps_cache loaded lazily (mirroring wtest_seed_closure) —
# and is only ever READ here: no 'bin/wv2 deps' shell-out, no cache
# write, so a selection that skipped rule (b) stays as cheap as
# before. A root whose closure is unknown (never computed, stale, or
# recorded as a compile failure) falls back to the root file alone —
# the pre-closure behavior, positive evidence only.
int wtest_closure_needs(char* arch, char* root):
	if (wtest_closure_roots == 0):
		wtest_closure_roots = new list[char*]
		wtest_closure_blobs = new list[char*]
		wtest_cache_load()
	char* id = wtest_root_id(arch, root)
	char* blob = wtest_closure_get(id)
	free(id)
	if (blob == 0):
		return wtest_source_needs(root)
	int needs = 0
	string_builder* line = string_new()
	int i = 0
	while (blob[i] != 0):
		if (blob[i] == 10):
			if (line.length > 0):
				needs = needs | wtest_source_needs(line.data)
				string_clear(line)
		else:
			string_append_char(line, blob[i])
		i = i + 1
	if (line.length > 0):
		needs = needs | wtest_source_needs(line.data)
	string_free(line)
	return needs


# The ELF interpreter a dynamically linked binary for 'arch' needs at
# run time on this host, or 0 for targets whose run steps go through a
# runner wrapper --available already checks (qemu/wine/wasm serve the
# loader role there).
char* wtest_arch_loader(char* arch):
	if (strcmp(arch, c"x86") == 0):
		return c"/lib/ld-linux.so.2"
	if (strcmp(arch, c"x64") == 0):
		return c"/lib64/ld-linux-x86-64.so.2"
	return 0


int wtest_gpu_available():
	if (wtest_file_exists(c"/dev/nvidiactl")):
		return 1
	if (wtest_file_exists(c"/dev/nvidia0")):
		return 1
	return wtest_path_has(c"nvidia-smi")


int wtest_macos_host():
	return wtest_file_exists(c"/System/Library/CoreServices/SystemVersion.plist")


# The --runnable-here reason a target cannot run here, or 0. Pairs
# each run step with the compile step that produced its binary: a
# compile step records '-o <out>' -> (arch, first .w argument), and a
# later step whose argv[0] is that out path runs the binary, so the
# root's closure-level needs (wtest_closure_needs) are probed against
# this host.
char* wtest_target_runnable_reason(char* name):
	json_value* steps = wtest_target_steps(name)
	if (steps == 0):
		return 0
	list[char*] outs = new list[char*]
	list[char*] out_archs = new list[char*]
	list[char*] out_srcs = new list[char*]
	int s = 0
	while (s < json_array_length(steps)):
		json_value* step = json_array_get(steps, s)
		s = s + 1
		if (step.type != json_type_object()):
			continue
		json_value* cmd = wtest_step_cmd(step)
		if (cmd == 0):
			continue
		json_value* program = json_array_get(cmd, 0)
		if (wtest_root_program(program.string_value) == 0):
			continue
		int n = json_array_length(cmd)
		char* arch = c"x86"
		if (n >= 2):
			json_value* selector_piece = json_array_get(cmd, 1)
			if (wtest_selector(selector_piece.string_value)):
				arch = selector_piece.string_value
		char* out_path = 0
		char* src = 0
		int i = 1
		while (i < n):
			json_value* piece = json_array_get(cmd, i)
			char* element = piece.string_value
			if (strcmp(element, c"-o") == 0):
				if (i + 1 < n):
					json_value* out_piece = json_array_get(cmd, i + 1)
					out_path = out_piece.string_value
				i = i + 2
				continue
			if ((src == 0) && ends_with(element, c".w")):
				src = element
			i = i + 1
		if ((out_path != 0) && (src != 0)):
			outs.push(out_path)
			out_archs.push(arch)
			out_srcs.push(src)
	s = 0
	while (s < json_array_length(steps)):
		json_value* step = json_array_get(steps, s)
		s = s + 1
		if (step.type != json_type_object()):
			continue
		json_value* cmd = wtest_step_cmd(step)
		if (cmd == 0):
			continue
		json_value* first = json_array_get(cmd, 0)
		int k = 0
		while (k < outs.length):
			if (strcmp(outs[k], first.string_value) == 0):
				int needs = wtest_closure_needs(out_archs[k], out_srcs[k])
				if ((needs & 2) && (wtest_gpu_available() == 0)):
					return c"no NVIDIA GPU (/dev/nvidiactl, /dev/nvidia0 and nvidia-smi all missing)"
				if (needs & 1):
					char* loader = wtest_arch_loader(out_archs[k])
					if ((loader != 0) && (wtest_file_exists(loader) == 0)):
						string_builder* reason = string_new()
						string_append(reason, loader)
						string_append(reason, c" not found (dynamically linked ")
						string_append(reason, out_archs[k])
						string_append(reason, c" binary)")
						char* text = reason.data
						free(reason)
						return text
			k = k + 1
	return 0


# The reason this step's runner is unavailable on this host, or 0 when it
# is available, or when the step's program is not one of the recognized
# runner shapes (wine/wine64, the arm64 qemu wrapper, the wasm runtime
# wrapper, a tools/mac/ script) — unrecognized programs are always left
# alone, per the "positive evidence only" rule in the header comment.
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
				if (strcmp(second.string_value, c"tools/run_wasm.sh") == 0):
					if (wtest_wasm_runtime_available() == 0):
						return c"no wasm runtime (wasmtime or node) found"
		return 0
	if (starts_with(program, c"tools/mac/")):
		if (wtest_file_exists(program) == 0):
			string_builder* s = string_new()
			string_append(s, program)
			string_append(s, c" not found")
			char* reason = s.data
			free(s)
			return reason
		# --runnable-here only: the script existing in the checkout is
		# not evidence it can run — tools/mac/ scripts need a Mac.
		if (wtest_runnable_here_flag && (wtest_macos_host() == 0)):
			return c"tools/mac/ scripts need a macOS host"
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
	if (wtest_runnable_here_flag):
		return wtest_target_runnable_reason(name)
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


# An umbrella target: no steps of its own and a nonempty all-string
# deps list — build.json's step-less aggregates (tests, tests_x64,
# tests_win64), detected structurally so fixture manifests can define
# their own. Never selected by rules (a)/(b) (wtest_selectable), but
# the collapse below may emit one to stand in for most of its members.
int wtest_umbrella_target(char* name):
	json_value* target = wtest_target_defs.get(name, 0)
	if (target == 0):
		return 0
	json_value* steps = wtest_target_steps(name)
	if (steps != 0):
		if (json_array_length(steps) > 0):
			return 0
	json_value* deps = json_object_get(target, c"deps")
	if (deps == 0):
		return 0
	if (deps.type != json_type_array()):
		return 0
	if (json_array_length(deps) == 0):
		return 0
	int i = 0
	while (i < json_array_length(deps)):
		json_value* dep = json_array_get(deps, i)
		if (dep.type != json_type_string()):
			return 0
		i = i + 1
	return 1


# Collapse an enormous selection to umbrella targets (header comment):
# when more than half of the manifest's selectable targets are
# selected, each umbrella with more than half of its own members
# selected replaces those members, and one stderr line says what
# happened. The output stays a complete, valid target list — selected
# targets no umbrella covers are left alone. Below either threshold
# this is a no-op, so ordinary selections are byte-identical.
void wtest_collapse_selection():
	int total = 0
	int enabled = 0
	for char* name in wtest_target_names:
		if (wtest_selectable(name)):
			total = total + 1
			if (name in wtest_enabled):
				enabled = enabled + 1
	if (total == 0):
		return
	if (enabled * 2 <= total):
		return
	int collapsed = 0
	list[char*] umbrellas = new list[char*]
	for char* name in wtest_target_names:
		if (wtest_never_emit.get(name, 0)):
			continue
		if (wtest_umbrella_target(name) == 0):
			continue
		json_value* target = wtest_target_defs.get(name, 0)
		json_value* deps = json_object_get(target, c"deps")
		int member_total = 0
		int member_enabled = 0
		int i = 0
		while (i < json_array_length(deps)):
			json_value* dep = json_array_get(deps, i)
			if (wtest_selectable(dep.string_value)):
				member_total = member_total + 1
				if (dep.string_value in wtest_enabled):
					member_enabled = member_enabled + 1
			i = i + 1
		if (member_enabled == 0):
			continue
		if (member_enabled * 2 <= member_total):
			continue
		i = 0
		while (i < json_array_length(deps)):
			json_value* dep = json_array_get(deps, i)
			# Selectable members only: 'tests' lists 'tests_x64' among
			# its deps, and removing a just-enabled sibling umbrella
			# would silently drop its collapsed members from the
			# output entirely.
			if (wtest_selectable(dep.string_value) && (dep.string_value in wtest_enabled)):
				wtest_enabled.remove(dep.string_value)
				collapsed = collapsed + 1
			i = i + 1
		wtest_enabled[name] = 1
		umbrellas.push(name)
	if (collapsed == 0):
		return
	wstream* err = stderr_writer()
	string_builder* line = string_new()
	string_append(line, c"wtest: collapsed ")
	string_append_int(line, collapsed)
	string_append(line, c" target")
	if (collapsed != 1):
		string_append_char(line, 's')
	string_append(line, c" into ")
	int u = 0
	while (u < umbrellas.length):
		if (u > 0):
			string_append(line, c", ")
		string_append(line, umbrellas[u])
		u = u + 1
	string_append(line, c" (selection covered ")
	string_append_int(line, enabled)
	string_append(line, c" of ")
	string_append_int(line, total)
	string_append(line, c" selectable targets)")
	stream_write_line(err, line.data)
	string_free(line)
	stream_flush(err)


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
	wtest_compute_closures(wtest_archs_roots)


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


# Append '<n> file' / '<n> files'.
void wtest_append_file_count(string_builder* s, int n):
	string_append_int(s, n)
	string_append(s, c" file")
	if (n != 1):
		string_append_char(s, 's')


# Non-empty line count of a closure blob (its file count).
int wtest_closure_count(char* blob):
	int count = 0
	int in_line = 0
	int i = 0
	while (blob[i] != 0):
		if (blob[i] == 10):
			in_line = 0
		else:
			if (in_line == 0):
				count = count + 1
			in_line = 1
		i = i + 1
	return count


# The 'wtest why' cache section: a RAW, non-validating scan of
# bin/.wtest_deps_cache for one root id. wtest_cache_load (the
# validating loader) silently DROPS a stale entry, which is exactly
# the entry 'why' most needs to describe — so this reads the same
# line-tag format (R/X/H/V/M/E/F, format comment above
# wtest_cache_load) itself and reports what is recorded alongside
# whether it still validates, using the same checks the loader
# applies.
void wtest_why_cache_section(char* id, wstream* out):
	char* text = file_read_text(c"bin/.wtest_deps_cache")
	if (text == 0):
		stream_write_line(out, c"cache: no bin/.wtest_deps_cache (cold; 'bin/wv2 deps' runs on the next selection)")
		return
	int kind = 0
	int in_match = 0
	int found = 0
	char* expected = 0
	char* vhash = 0
	char* missing = 0
	char* detail = 0
	int files = 0
	string_builder* blob = string_new()
	string_append_char(blob, 10)
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
				in_match = 0
				if (strcmp(entry + 2, id) == 0):
					found = 1
					in_match = 1
					kind = 1
					if (entry[0] == 'X'):
						kind = 2
			else if (in_match):
				if (starts_with(entry, c"H ")):
					expected = strclone(entry + 2)
				else if (starts_with(entry, c"V ")):
					vhash = strclone(entry + 2)
				else if (starts_with(entry, c"M ")):
					missing = strclone(entry + 2)
				else if (starts_with(entry, c"E ")):
					detail = strclone(entry + 2)
				else if (starts_with(entry, c"F ")):
					files = files + 1
					string_append(blob, entry + 2)
					string_append_char(blob, 10)
			string_clear(line)
		else:
			string_append_char(line, c)
		i = i + 1
	string_free(line)
	free(text)
	if (found == 0):
		stream_write_line(out, c"cache: no entry for this root (never computed, or the last failure was non-persistable: timeouts, spawn failures and bin/wv2-missing runs are never cached)")
		string_free(blob)
		return
	if (kind == 1):
		string_builder* s = string_new()
		string_append(s, c"cache: success entry (")
		wtest_append_file_count(s, files)
		string_append_char(s, ')')
		stream_write_line(out, s.data)
		string_free(s)
		if (vhash != 0):
			string_builder* v = string_new()
			string_append(v, c"  computed under bin/wv2 ")
			string_append(v, vhash)
			if (strcmp(wtest_file_hash(c"bin/wv2"), vhash) == 0):
				string_append(v, c" (current bin/wv2: same)")
			else:
				string_append(v, c" (current bin/wv2 differs; the closure stays valid while its file contents do)")
			stream_write_line(out, v.data)
			string_free(v)
		int valid = 0
		if (expected != 0):
			if (strcmp(wtest_closure_digest(blob.data), expected) == 0):
				valid = 1
		if (valid):
			stream_write_line(out, c"  status: valid -- rule (b) closure selection is live for this root")
		else:
			stream_write_line(out, c"  status: STALE (closure contents changed) -- 'bin/wv2 deps' re-runs on the next selection")
	if (kind == 2):
		stream_write_line(out, c"cache: failure entry (the last 'bin/wv2 deps' run exited nonzero)")
		int valid = 1
		char* root_path = wtest_root_id_path(id)
		int root_same = 0
		if ((expected != 0) && (root_path != 0)):
			if (strcmp(wtest_file_hash(root_path), expected) == 0):
				root_same = 1
		if (root_same):
			stream_write_line(out, c"  root content: unchanged since the failure")
		else:
			valid = 0
			stream_write_line(out, c"  root content: changed since the failure -> retried on the next selection")
		if (vhash != 0):
			string_builder* v = string_new()
			string_append(v, c"  recorded under bin/wv2 ")
			string_append(v, vhash)
			if (strcmp(wtest_file_hash(c"bin/wv2"), vhash) == 0):
				string_append(v, c" (current: same)")
			else:
				valid = 0
				string_append(v, c" (current bin/wv2 differs -> retried on the next selection)")
			stream_write_line(out, v.data)
			string_free(v)
		else:
			# A legacy entry with no V line never validates (the loader
			# drops it), so it cannot pin anything.
			valid = 0
		if (missing != 0):
			string_builder* m = string_new()
			string_append(m, c"  missing import: ")
			string_append(m, missing)
			if (wtest_file_exists(missing)):
				valid = 0
				string_append(m, c" (now present -> retried on the next selection)")
			else:
				string_append(m, c" (still absent)")
			stream_write_line(out, m.data)
			string_free(m)
		if (detail != 0):
			string_builder* d = string_new()
			string_append(d, c"  deps stderr: ")
			string_append(d, detail)
			stream_write_line(out, d.data)
			string_free(d)
		if (valid):
			stream_write_line(out, c"  status: valid -- rule (b) is disabled for this root; its targets select via literal/residue rules only")
		else:
			stream_write_line(out, c"  status: stale -- 'bin/wv2 deps' re-runs on the next selection")
	string_free(blob)


# 'wtest why [<arch>] <file.w> [-f manifest.json]' (header comment):
# explain one root's deps/closure story. Written for the reader of the
# aggregate deps-failure warning: that line names the failing roots,
# this names the reason and the consequences for one of them. Exits 0
# whenever a story was printed (a failed root is an ordinary, reported
# state, mirroring 'wtest cache'); 1 only on argument/manifest errors.
int wtest_why_main(int argc, int argv):
	wtest_manifest_path = c"build.json"
	char* arch = 0
	char* path = 0
	int i = 2
	while (i < argc):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"-f") == 0):
			i = i + 1
			if (i >= argc):
				wtest_usage()
				return 1
			char** value = argv + i * __word_size__
			wtest_manifest_path = *value
		else if ((arch == 0) && (path == 0) && (wtest_selector(*arg) || (strcmp(*arg, c"x86") == 0))):
			arch = *arg
		else if (path == 0):
			path = *arg
		else:
			wtest_usage()
			return 1
		i = i + 1
	if (path == 0):
		wtest_usage()
		return 1
	if (arch == 0):
		arch = c"x86"
	if (wtest_load_manifest()):
		return 1
	char* id = wtest_root_id(arch, path)
	wstream* out = stdout_writer()
	string_builder* head = string_new()
	string_append(head, c"wtest: why root '")
	string_append(head, id)
	string_append_char(head, 39)
	stream_write_line(out, head.data)
	string_free(head)
	if (wtest_file_exists(path)):
		stream_write_line(out, c"root file: present")
	else:
		stream_write_line(out, c"root file: MISSING (no closure can be computed; deleted paths select via residue rules)")
	# Owning targets, from the archs superset of rule (b)'s pairs so
	# even a root only a never-emit target compiles is explained.
	wtest_archs_ensure_roots()
	int owned = 0
	for char* known_root in wtest_archs_roots:
		if (strcmp(known_root, id) == 0):
			owned = 1
	if (owned):
		string_builder* own = string_new()
		string_append(own, c"compile root of: ")
		char* targets = wtest_archs_targets_for(id)
		string_append(own, targets)
		free(targets)
		stream_write_line(out, own.data)
		string_free(own)
	else if (strcmp(path, c"w.w") == 0):
		stream_write_line(out, c"compile root of: (none -- w.w is the seed-graph root; its closure drives residue rule (c), not rule (b))")
	else:
		stream_write_line(out, c"compile root of: no target in this manifest compiles this (arch, file) pair -- rule (b) never consults it")
	wtest_why_cache_section(id, out)
	if (wtest_file_exists(c"bin/wv2")):
		stream_write_line(out, c"bin/wv2: present")
	else:
		stream_write_line(out, c"bin/wv2: MISSING -- 'bin/wv2 deps' cannot run (run a build first)")
	stream_flush(out)
	# Live closure state, through the ordinary validated store: a valid
	# cached success or failure holds exactly as a selection would see
	# it; anything else is computed NOW and saved, so a 'why' also
	# warms the cache (mirroring wtest_seed_closure).
	if (wtest_closure_roots == 0):
		wtest_closure_roots = new list[char*]
		wtest_closure_blobs = new list[char*]
		wtest_cache_load()
	if (wtest_closure_known(id)):
		char* cached = wtest_closure_get(id)
		if (cached != 0):
			string_builder* c1 = string_new()
			string_append(c1, c"closure: ")
			wtest_append_file_count(c1, wtest_closure_count(cached))
			string_append(c1, c" (validated cache)")
			stream_write_line(out, c1.data)
			string_free(c1)
		else:
			stream_write_line(out, c"closure: unavailable (the cached failure above still holds)")
	else:
		char* blob = wtest_closure_compute(id)
		wtest_cache_save()
		if (blob != 0):
			string_builder* c2 = string_new()
			string_append(c2, c"closure: computed now (")
			wtest_append_file_count(c2, wtest_closure_count(blob))
			string_append(c2, c"; cache updated)")
			stream_write_line(out, c2.data)
			string_free(c2)
		else:
			string_builder* c3 = string_new()
			string_append(c3, c"closure: unavailable -- live 'bin/wv2 deps' run failed: ")
			char* live_detail = 0
			if (wtest_failure_lines != 0):
				live_detail = wtest_failure_lines.get(id, 0)
			if (live_detail != 0):
				string_append(c3, live_detail)
			else:
				string_append(c3, c"(no detail)")
			stream_write_line(out, c3.data)
			string_free(c3)
	stream_flush(out)
	# Selection story: run the real machinery for this one path
	# (identical to 'wtest changed <path>', cold-cache closure
	# computation included), then attribute every selected target to
	# the rule(s) that reach it.
	string_builder* sel = string_new()
	string_append(sel, c"selection for a change to '")
	string_append(sel, path)
	string_append(sel, c"':")
	stream_write_line(out, sel.data)
	string_free(sel)
	stream_flush(out)
	wtest_map_path(path)
	wtest_ensure_roots()
	int has_slash = wtest_str_contains(path, c"/")
	int printed = 0
	for char* name in wtest_target_names:
		if (wtest_enabled.get(name, 0) == 0):
			continue
		string_builder* entry = string_new()
		string_append(entry, c"  ")
		string_append(entry, name)
		string_append(entry, c" (")
		int first = 1
		int j = 0
		while (j < wtest_pair_roots.length):
			if (strcmp(wtest_pair_targets[j], name) == 0):
				if (wtest_closure_contains(wtest_closure_get(wtest_pair_roots[j]), path)):
					if (first == 0):
						string_append(entry, c"; ")
					string_append(entry, c"closure of root '")
					string_append(entry, wtest_pair_roots[j])
					string_append_char(entry, 39)
					first = 0
			j = j + 1
		if (wtest_target_mentions(name, path, has_slash) || wtest_target_data_mentions(name, path)):
			if (first == 0):
				string_append(entry, c"; ")
			string_append(entry, c"literal step reference")
			first = 0
		if (first):
			string_append(entry, c"residue rule")
		string_append_char(entry, ')')
		stream_write_line(out, entry.data)
		string_free(entry)
		printed = printed + 1
	if (printed == 0):
		stream_write_line(out, c"  (nothing selected)")
	stream_flush(out)
	return 0


# 'wtest cache [-f manifest.json]': pre-warm bin/.wtest_deps_cache for
# every root any selection can consult (header comment) — the archs
# superset of compile roots plus the seed w.w roots: "x86 w.w" always,
# "<arch> w.w" for each arch whose verify target the manifest carries,
# mirroring wtest_map_residue's own gate. './wbuild wtest_cache' runs
# this right after a build so the first 'wtest changed' is not the
# invocation paying the cold-walk cost (ai_tooling_next_steps.md
# 2026-07-29). Exits 1 only when warming is impossible (unreadable
# manifest, bin/wv2 missing); a root that fails to compile is an
# ordinary, reported state — counted in the summary, selection falls
# back to literal matching for it — not a warming failure.
int wtest_cache_main(int argc, int argv):
	wtest_manifest_path = c"build.json"
	int i = 2
	while (i < argc):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"-f") == 0):
			i = i + 1
			if (i >= argc):
				wtest_usage()
				return 1
			char** value = argv + i * __word_size__
			wtest_manifest_path = *value
		else:
			wtest_usage()
			return 1
		i = i + 1
	if (wtest_load_manifest()):
		return 1
	if (wtest_file_exists(c"bin/wv2") == 0):
		wtest_error(c"cannot warm the deps cache: ", c"bin/wv2 not found (run a build first)")
		return 1
	wtest_archs_ensure_roots()
	if (wtest_closure_roots == 0):
		wtest_closure_roots = new list[char*]
		wtest_closure_blobs = new list[char*]
		wtest_cache_load()
	list[char*] roots = new list[char*]
	roots.push(wtest_root_id(c"x86", c"w.w"))
	list[char*] arch_words = new list[char*]
	arch_words.push(c"x64")
	arch_words.push(c"arm64")
	arch_words.push(c"arm64_darwin")
	arch_words.push(c"win64")
	arch_words.push(c"wasm")
	for char* arch in arch_words:
		char* arch_verify = wtest_arch_verify_target(arch)
		if (arch_verify != 0):
			if (wtest_target_defs.get(arch_verify, 0) != 0):
				roots.push(wtest_root_id(arch, c"w.w"))
	# The archs superset never contains w.w (wtest_excluded_root), so
	# the concatenation stays duplicate-free.
	for char* archs_root in wtest_archs_roots:
		roots.push(archs_root)
	wtest_compute_closures(roots)
	int failed = 0
	for char* warmed in roots:
		if (wtest_closure_get(warmed) == 0):
			failed = failed + 1
	wstream* out = stdout_writer()
	string_builder* line = string_new()
	string_append(line, c"wtest: deps cache ready (")
	string_append_int(line, roots.length)
	string_append(line, c" roots")
	if (failed > 0):
		string_append(line, c", ")
		string_append_int(line, failed)
		string_append(line, c" failed")
	string_append_char(line, ')')
	stream_write_line(out, line.data)
	string_free(line)
	stream_flush(out)
	return 0


int main(int argc, int argv):
	wtest_mask32 = wtest_mask32_value()
	if (argc < 2):
		wtest_usage()
		return 1
	char** command = argv + __word_size__
	int for_mode = strcmp(*command, c"for") == 0
	if (strcmp(*command, c"archs") == 0):
		return wtest_archs_main(argc, argv)
	if (strcmp(*command, c"why") == 0):
		return wtest_why_main(argc, argv)
	if (strcmp(*command, c"cache") == 0):
		return wtest_cache_main(argc, argv)
	if ((strcmp(*command, c"changed") != 0) && (for_mode == 0)):
		wtest_usage()
		return 1
	wtest_manifest_path = c"build.json"
	# A first pass just for the manifest flags: both manifests must be
	# loaded before selection starts below, but "-f"/"--base-manifest"
	# may appear anywhere after "changed" (mirroring bin/wexec's own
	# flag), so they are found ahead of the argument loop that does the
	# real work. The same pass spots a commit-ranged argument (header
	# comment, "Commit-ranged selection") -- 'changed' only, the non-flag
	# argument containing ".." (a second one is an argument error) -- so
	# its index is known before the real loop below reaches it; no repo
	# path ever contains "..", so this can never misfire against an
	# ordinary changed-file path.
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
		else if ((for_mode == 0) && (argval[0] != '-') && wtest_str_contains(argval, c"..")):
			if (range_index != 0):
				wtest_error(c"only one revision range argument is allowed, got a second: ", argval)
				return 1
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
		else if (strcmp(*arg, c"--runnable-here") == 0):
			wtest_runnable_here_flag = 1
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
		# The committed-clean footgun (header comment, --defhash): only a
		# stdin-piped path list can plausibly be a ranged diff's output,
		# so the warning is scoped to this branch — positional paths were
		# named deliberately, and a range argument never reads stdin.
		if (wtest_defhash_clean_count > 0):
			wtest_defhash_clean_warning()
	if (wtest_available_flag || wtest_runnable_here_flag):
		wtest_apply_available_filter()
	wtest_collapse_selection()
	wtest_emit_targets()
	if (wtest_run_flag):
		return wtest_run_selected()
	return 0
