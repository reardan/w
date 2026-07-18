# Compilation Model: Libraries for Everything (#338) and LLVM Offload (#337)

Status: design only, 2026-07-18. No code changes ship with this file.
Assessment for two open epics that both, in different ways, ask "what
counts as a compiled artifact in this compiler." Companion to
`docs/projects/wx_split.md` (per-target container-writer work, the
prior art for adding a new output *shape*), `docs/projects/wbuildd.md`
(the daemon/AST design that overlaps #338's performance motivation and
directly informs #337's AST-availability question), and
`docs/projects/parser_generator.md` (the PG's AST/streaming modes,
milestone 3 of which just landed). Also carries short scoping notes for
two "Future:" issues, #332 (streaming types) and #333 (type operators),
per wave 4 task 4e (`docs/projects/sonnet_wave_plan_2026_07b.md`).

## 0. Why one doc for two issues

#338 and #337 are nominally unrelated (packaging vs. a new backend),
but both are really questions about the same thing: what this compiler
treats as a unit of compiled output. #338 asks whether that unit can be
something other than "one whole-program executable, rebuilt from
source every time." #337 asks whether the *last step* of turning
source into that unit can be handed to an external toolchain instead of
`code_generator/*.w`. Neither can be answered without first being
precise about what "compile" currently means in this codebase — §1
below is that grounding, shared by both sections.

## 1. How W compiles today

- **Whole-program, single-pass, no AST, no IR** (cc500 heritage):
  grammar rules in `grammar/*.w` fuse parsing and code emission,
  writing machine-code bytes through `code_generator/x86.w` as they
  parse (CLAUDE.md, "Architecture"). There is no intermediate
  representation to serialize, cache, or hand to another tool — by the
  time a function's closing statement is parsed, its machine code is
  already written into the output buffer.
- **No object files, no linker.** Every compile re-parses its *entire*
  transitive import closure from source text, every invocation
  (`docs/projects/wbuildd.md` §1.2 measures this precisely: `w check`/
  `wv2 deps` on `w.w`'s closure cost ~7.1s on every single call, cold or
  warm, because there is no cache layer between invocations at all).
  There is no format for "here is function `f`'s compiled code plus a
  list of the symbols it still needs" — a definition's final address
  depends on everything the compiler has already emitted before it in
  the same run, because emission is direct and immediate, not staged
  through relocatable references.
- **Two output shapes exist, and only one direction of dynamic
  linking.** By default `w`/`wv2` emits a single static `PT_LOAD`
  segment (`code_generator/elf_32.w:19` hardcodes `emit_int16(2)`, ELF
  `e_type = ET_EXEC` — there is no `ET_DYN` path anywhere in the
  container writers). A program using `c_lib`/`extern`/`c_import` gets
  `PT_INTERP`/`PT_DYNAMIC` records and eager GOT relocations
  (`code_generator/elf_dynamic.w`) so it can *consume* an existing
  shared library (libc, libcuda) at load time — but nothing in the
  tree writes an `ET_DYN` shared object of W's own code that another
  program could link against. `docs/projects/wx_split.md` (the W^X
  split project, in-tree at three of five target container writers) is
  the closest recent precedent for "add a new capability to a
  container writer," and it is exactly this scale of work *per target*
  — two `PT_LOAD` segments instead of one, still nothing like emitting
  a linkable artifact.
- **The closest existing thing to a "library" is a source package.**
  `package.wmeta` (`docs/package_metadata.txt`) already models a
  "package": a name, version, a `modules:` list of dotted source paths,
  and a `dependencies:` list with version constraints, validated by
  `tools/wmeta.w`. It is explicit that this changes nothing about
  compilation: "Do not add compiler import search paths in this
  design... Do not add dependency fetching... or code generation
  metadata" (`docs/package_metadata.txt`). A "library" today, in other
  words, already exists — but it is a set of `.w` source files plus a
  manifest, resolved by the ordinary `import a.b` → `a/b.w` path walk
  and recompiled from scratch by every consumer, not a compiled,
  distributable artifact.

## 2. #338 "Libraries for Everything"

Issue text, verbatim: "1. Implement each module as library - either
shared or static (prolly start with static to match current format).
2. Everything should be a library, cli tools are just thin wrappers
around the library."

### 2.1 The issue is really two separable claims

**Claim 1** — modules should compile to a library *artifact*, shared or
static. **Claim 2** — CLI tools should already just be thin wrappers
over such libraries. These have very different costs: claim 2 is
partly true today and partly a straightforward refactor with *zero*
new compiler capability; claim 1 requires inventing an artifact format
this compiler has never had.

### 2.2 What "static library" could even mean here

In the traditional (C/Unix) sense, a static library is an **archive of
relocatable object files** — each `.o` has machine code with *unresolved*
external symbols and relocation records, and a linker resolves them and
assigns final addresses only when the archive is actually linked into a
program. W has none of the three pieces that sentence depends on:

- No relocatable object emission — `code_generator/*.w` always emits
  final, absolute-or-PC-relative bytes into one continuous buffer for
  one whole program (`docs/projects/build_system_next.md`'s §4d, on why
  *incremental* recompilation is hard, states the identical fact for a
  narrower goal: "single-pass direct byte emission means every
  definition's address depends on everything emitted before it").
- No archive container format (the `.a`/`ar` format, or any equivalent).
- No linker — nothing in the tree resolves cross-object symbol
  references or performs address fixups after code generation; `link()`
  in `w.w`/`compiler/compiler.w` names the entry point that drives a
  single compile-to-executable pass, not a link step over pre-built
  units.

So "start with static to match current format" doesn't actually
describe a small step: **the current format has no static-library
analog to match**, because it has no notion of a partially-compiled,
symbol-unresolved unit at all. A "static library" in this compiler
either means (i) a source module — which already exists and is
already the unit of reuse, just uncompiled — or (ii) a genuinely new
relocatable-object-plus-linker subsystem, which is a different kind of
project than "package the existing format."

### 2.3 Four options

**(a) Status quo + source-level libraries.** Ship nothing new; treat
`import`ed `.w` modules plus `package.wmeta` packages as "the library,"
and make claim 2 (thin CLI wrappers) actually true everywhere by
refactoring the tools that aren't.

Is claim 2 already true? Genuinely mixed, checked directly against the
tree:

- **Already thin**: `w.w` itself is 49 lines dispatching to
  `compiler/compiler.w`'s `link`/`check_main`/`deps_main`/
  `symbols_main` and `debugger/wdbg.w`'s `wdbg_main` — the flagship CLI
  *is* a thin wrapper. `tools/wmeta.w` (67 lines) and
  `tools/parser_generator.w` (56 lines) are the same shape: a handful
  of lines of argument parsing calling straight into `lib.wmeta` /
  `libs.extras.parser_generator.*`.
- **A real library + porcelain split**: `tools/wvc.w` (1,308 lines) is
  the CLI porcelain over `libs/extras/vcs/` (`cas.w`, `tree.w`,
  `commit.w`, `diff.w`, `index.w`, `dag.w`, `merge3.w`, `sync.w` — 5,937
  lines total), imported explicitly (`tools/wvc.w`'s import block lists
  all eight). `docs/projects/version_control.md` names this split
  outright: `tools/wvc.w` is "porcelain," `libs/extras/vcs/` is the
  engine. This is the pattern #338 is asking for, already landed.
- **Not thin at all**: `tools/wexec.w` (2,769 lines, ~118 top-level
  definitions) imports only `lib.*`/`structures.*` leaf modules — there
  is no `libs/extras/wexec_core` backing it; the build orchestrator's
  entire cache-key/dependency/execution logic lives directly in the CLI
  file. `tools/test_map.w` (1,718 lines) and `tools/wbuildgen.w` (1,124
  lines) are the same shape: substantial applications with no separate
  library underneath them to be a "thin wrapper" around.

So (a)'s honest answer is: **claim 2 is proven achievable and already
half-done**, not a new capability — extracting `libs/extras/wexec_core.w`
(and equivalents for `test_map.w`/`wbuildgen.w`) is ordinary refactoring
that could start today, at zero architectural risk, following the
`cas.w`/`wvc.w` precedent exactly. **Claim 1 is not satisfied by (a) at
all** — no compiled artifact exists under this option, only source
modules, which is what already existed before the issue was filed.

**(b) A relocatable object/archive format + linker.** The literal
reading of claim 1's "static ... to match current format": emit
per-module output with unresolved external references and relocation
records, an archive container bundling several, and a new linker tool
that resolves symbols and produces final addresses before handing off
to the existing ELF/PE/Mach-O finishing code.

This is a new compilation *phase*, not a new container shape like
`wx_split.md`'s two-`PT_LOAD` change or the arm64/win64/wasm backends
(`docs/projects/wasm_backend.md`'s "ISA / OS ABI / container / forcing
constraint" framing all assumed the *existing* single-pass, whole-
program emission model — only the target ISA and container changed).
This option changes the emission model itself: two-phase (emit-with-
holes, then re-link) instead of one-shot direct byte emission. It
touches `code_generator/*` (every emission site needs a
relocation-record option), `compiler/symbol_table.w` (external vs.
resolved symbols), and needs a wholly new tool that must itself be
seed-safe if any seed-graph artifact is ever built through it. This is
squarely the thing `docs/projects/build_system_next.md` §4d already
priced out and declined for a *narrower* goal (incremental recompiles
only, not general library distribution): "flagged as research,
probably skip... this becomes its own project (a relocatable fast-path
backend)." #338's claim 1, read literally, asks for exactly that
project, just for a different reason (distribution/modularity instead
of build speed).

**(c) Shared libraries via the existing `elf_dynamic.w` path (W-to-W
`.so`).** More tractable than (b) because it extends an existing
per-target writer rather than inventing a new compilation phase — the
same *kind* of change `wx_split.md` makes to `elf_64.w`/`pe_64.w`, just
adding an `ET_DYN` output mode instead of a second `PT_LOAD`. But it is
not small: `elf_dynamic.w` today only ever writes the *consumer* side —
undefined symbols with GOT slots the loader fills in
(`code_generator/elf_dynamic.w:120-136`). Producing a `.so` means:

- A real `.dynsym` with **defined** symbols at real addresses (the
  opposite of today's all-`SHN_UNDEF` import table).
- `ET_DYN` instead of the hardcoded `ET_EXEC` (`elf_32.w:19`), which in
  practice means **position-independent code** — every target's fixed
  load address assumption (`wx_split.md`: "x86, x64 and win64 all stay
  fixed-base... exactly like arm64 does today") would need to become
  relative addressing for at least the exported-symbol surface, a
  codegen change with much wider blast radius than the container-layout
  change `wx_split.md` itself scopes.
- A defined calling convention/ABI story for W-to-W calls across the
  `.so` boundary (name stability, no name-mangling churn across
  compiler versions) — orthogonal to the existing C ABI shims
  `code_generator/ffi.w` already provides for calling *into* C
  libraries, which is a different problem (consuming a foreign ABI, not
  publishing a stable one).

This would deliver claim 1's "shared" half without inventing a linker,
but PIC codegen is a real, load-bearing prerequisite this doc cannot
size down further without its own `wasm_backend.md`/`arm64.md`-style
target-definition writeup.

**(d) Daemon/cache-based compile avoidance (`wbuildd`) — the goal
without a library format.** `docs/projects/wbuildd.md` is already fully
designed and staged (its own §5) and measures the actual pain a
"rebuild the whole world every time" complaint like #338 is plausibly
reaching for: `wtest changed`'s import-closure computation goes from
~143s cold to 0.13s warm (wbuildd.md §1.2) once results are cached and
served from a resident daemon instead of recomputed by every
invocation. None of this needs a relocatable format, a linker, or an
ABI decision — it needs an inotify shim, a unix-socket listener, and a
JSON-RPC surface reusing `wexec`'s existing cache-key logic exactly
(wbuildd.md §2.4). If the actual motivation behind #338 is "compiling
feels slow and repetitive, like it should reuse previously-built
pieces," (d) is the cheapest, already-scoped answer to that — it
answers "do I even need to recompute this," which is a different
question from "can this be an artifact I hand to a linker," but for
many practical purposes produces the same felt experience (fast,
warm-state builds) without touching the compilation model at all.

### 2.4 Recommendation with staging

1. **Immediate, no new compiler capability**: do (a)'s refactor.
   Extract `libs/extras/wexec_core.w` (or similarly scoped modules) out
   of `tools/wexec.w`, and the equivalent for `test_map.w`/
   `wbuildgen.w`, matching the `cas.w`/`wvc.w` split already proven in
   `libs/extras/vcs/`. This closes claim 2 honestly where it is not
   already true, at essentially zero risk.
2. **Ride `wbuildd`** (already gated on maintainer answers,
   `sonnet_wave_plan_2026_07b.md` §6) for the performance motivation
   most likely hiding inside #338 — no new scheduling needed here, just
   note the overlap so nobody re-derives it under this issue's name.
3. **If claim 1 is truly wanted literally**, schedule (c) — shared
   library production — as the next real "library format" milestone,
   scoped as its own design doc once (1) and (2) are through: it is
   additive to the existing per-target-writer pattern (`wx_split.md`'s
   template) rather than a new compilation phase, but PIC codegen and
   an ABI-stability story are large enough to need their own sizing.
4. **Do not schedule (b)** — relocatable objects, an archive format, a
   linker — without an explicit maintainer decision made with full
   knowledge of the cost: it changes the single-pass emission model
   itself, and `build_system_next.md` §4d already priced out and
   declined this exact machinery for a narrower goal. If the maintainer
   wants it anyway (e.g., for reasons beyond #338 — true separate
   compilation as a language feature in its own right), it deserves a
   dedicated design doc at the scale of `arm64.md`'s original staged
   plan, not a subsection of this one.

## 3. #337 "LLVM Offload"

Issue text, verbatim: "Have a listener or visitor parse the AST into an
LLVM compatible format then it generate the backend code."

### 3.1 Read literally, against what exists

The issue names two components: (i) something that "parses the AST" —
implying an AST exists to parse, and (ii) a lowering step to "LLVM
compatible format," with LLVM doing backend codegen from there. Neither
half matches the production compiler as-is (§1: no AST, no IR), but
both have a real, if partial, analog in the **ParserGenerator**
subsystem (`libs/extras/parser_generator/`,
`docs/projects/parser_generator.md`), which is deliberately outside the
compiler core and generates ordinary W modules rather than touching
`compiler/`/`grammar/`/`code_generator/` (`parser_generator.md`'s "Why
it is outside the compiler core").

### 3.2 The PG's AST — and why its brand-new streaming mode is the
wrong half of it for this purpose

`libs/extras/parser_generator/ast_node.w` already produces a full
`pg_ast_node` tree for any grammar it generates a parser from,
including `tests/parser_generator/w.pg` — a real, exercised AST over W
source today (`parser_generator_w_test` parses every tracked `.w` file
through it). `docs/projects/wbuildd.md` §3.2 already assessed this
exact AST as option (b) for a different project (a daemon-friendly
`bin/wc2` codegen spike) and its conclusions carry over directly here:
the AST gives *shape*, not *meaning* — "`w.pg` is still explicitly a
syntax-shaped validator, not a semantic one... a `wc2` built on today's
`w.pg` AST would need to re-derive every one of [the compiler's
context-sensitive] decisions itself (type table, declaration-before-use
symbol resolution)."

The **milestone 3 streaming/listener mode** that just landed
(`docs/projects/parser_generator.md`'s "Since 2026-07 (issue #329
milestone 3)" section; `mode streaming` directive, `on_enter_<rule>`/
`on_exit_<rule>` callbacks, *no* `pg_ast_node` tree ever materialized)
is specifically the wrong tool for what #337 asks for, and
`wbuildd.md` already says why in almost so many words: "a codegen
backend wants the *opposite* of streaming (a full tree to walk and
re-walk), making M3's investment orthogonal rather than a prerequisite"
(`wbuildd.md:398-401`). An LLVM-IR emitter needs to walk (and likely
re-walk, for anything beyond the most trivial single-pass expression
lowering) a materialized tree with type information attached — the
AST *mode* PG already had before M3, not the new listener mode M3 adds.
Whichever PG mode is used, `w.pg` itself is syntax-only and stays that
way deliberately (`parser_generator.md`: "does not perform symbol
resolution, type checking, or code generation... the existing compiler
remains the executable source of truth") — so any AST-based W-to-LLVM
tool inherits the same semantic gap `wbuildd.md` flags for option (b):
it would have to reimplement type checking and symbol resolution from
scratch to know what to emit, which is most of what `grammar/*.w`
already does inline in the production compiler.

### 3.3 What "LLVM compatible format" would actually mean

Three distinct sub-choices, each with a different dependency profile:

1. **LLVM IR text (`.ll`)** — a human-readable SSA form. Emitting it
   requires no libLLVM linkage at all (it's just text an emitter
   writes), but *running* it requires `llc`/`opt`/`clang` on `PATH` —
   an external toolchain, not vendored, not something this repo builds.
2. **LLVM bitcode (`.bc`)** — the binary form. Producing it directly
   needs either shelling out to `llvm-as` (converts `.ll` to `.bc`, so
   this reduces to option 1 plus one more external tool) or linking
   libLLVM's C API to emit bitcode natively, which is a large added
   dependency for a marginal benefit over just writing text.
3. **Embedding LLVM as a library** — binding libLLVM's C API directly
   from W via `c_import`, which has real precedent for large C
   surfaces (`docs/projects/c_import.md`'s glibc/libcuda imports). But
   LLVM's C API is enormous and versioned across releases; this is a
   multi-month binding project by itself, before any codegen logic
   exists at all — disproportionate for an experiment.

### 3.4 Cost side: the self-hosting tension

Every existing backend (x86, x64, arm64, `arm64_darwin`, win64,
wasm32/WASI) is emitted by W itself with **zero external toolchain at
build time** — this is stated as the project's identity in CLAUDE.md's
opening description ("no assembler, linker, or libc dependency") and
is true of every target added since (`docs/projects/arm64.md`,
`wasm_backend.md`). An LLVM path is a genuine first: it inherently
needs an external toolchain (`llc` at minimum) between W's output and a
runnable binary. This is not automatically disqualifying —
`docs/projects/cuda.md` already accepts external-toolchain dependence
for a *device* target with no alternative (`libcuda.so`/the CUDA
driver are not things W could ever emit itself) — but it is a new
category of dependency for the *host* backend the LLVM issue is
actually asking about, and it does not have to threaten the
seed/bootstrap chain **as long as it stays a leaf, opt-in tool**: the
same seed-safety story
`wbuildd.md` §3.2 already gives `bin/wc2` ("it does not enter the
seed's transitive import closure unless and until it is promoted...
Risk appears only if/when [it] is proposed as a *replacement* front
end, which is a different, much later decision") applies here without
modification.

### 3.5 What it buys, and why the marginal value is lower than usual

**Buys**: optimization passes (register allocation quality, inlining,
vectorization) this small a project will likely never write itself,
and "free" access to every target LLVM already supports. **But**: W
has already added arm64/win64/wasm by hand, each a bounded,
self-contained project following the `arm64.md` staged-target
template — so the marginal *new-target* value LLVM would add here is
lower than it would be for a language starting from zero backends.
What's left as LLVM's distinguishing value is optimization quality on
targets W already reaches, not new reach itself — a real but narrower
win than "LLVM offload" sounds like at first read.

### 3.6 Minimal experiment proposal

A leaf tool, structurally identical to `wbuildd.md` §3.2's `bin/wc2`
spike: parse a small, fixed W subset (integer arithmetic, `if`/`while`,
plain function calls — no structs, generics, or containers initially)
through `w.pg`'s **AST mode** (not streaming — the tree is required),
walk the resulting `pg_ast_node` tree, and emit LLVM IR **text** for
that subset. Then shell out to an external `llc`/`clang` — gated on
`command -v`, printing a "...OK (skipped: no llc on PATH)" success
rather than a failure when absent, the exact pattern
`docs/projects/compress.md` §8 uses for its optional zlib-interop
target and `tools/openssl_interop_test.sh` uses today — to produce a
native binary, and diff its runtime behavior against the same program
compiled by `bin/wv2`. This:

- Lives under `tools/`, imports only the PG's existing AST modules —
  **no seed exposure**, no new dependency on any required `build`/
  `verify`/`tests` path, mirroring `wbuildd.md` stage 4 exactly.
- Answers a concrete, decidable question — "is LLVM IR emission from
  this AST tractable for W's semantics at all" — before anyone commits
  to a real backend with an unbounded scope.
- Is explicitly **not** a path to replacing `w.w`'s compile path, same
  disclaimer `wbuildd.md` gives `bin/wc2` for the identical reason.

### 3.7 Recommendation

Don't schedule a real LLVM backend now: the dependency cost (an
external toolchain at minimum, a multi-month binding project at worst)
is disproportionate for a project whose entire identity is
zero-dependency self-hosting, and the semantic gap (`w.pg` has no
symbol/type resolution) means most of the actual engineering — redoing
what `grammar/*.w` already does inline — would have to happen a second
time in whatever front end feeds LLVM, exactly the tension `wbuildd.md`
already surfaces for its own option (b)/(c). Do schedule the minimal
experiment (§3.6) whenever a wave has slack: it is cheap, non-blocking,
produces the evidence a real go/no-go decision needs, and costs nothing
if it turns out to be a dead end. Treat "LLVM offload" as validating a
spike, not a committed roadmap item, until that spike reports back.

## 4. Scoping note: #332 "Future: Streaming Types"

Issue text (abridged): wants to "stream" from one object/type to
another so complex systems compose in one line — `TCP -> Protocol ->
LoadBalancer -> Cluster -> HashMap` (memcached-shaped),
`LoadBalancer -> Cluster -> Sharder -> SSTable -> WAL` (a database), a
query-planner/executor pipeline, and `HashMap -> List[T]` (a
defaultdict). No design taken here — this section only maps what
exists onto the ask, so a real design doc has a starting point.

- **`lib/stream.w`** (`docs/projects/streams.md`) is the closest
  existing primitive: a single buffered `wstream` (reader or writer,
  never both) over one fd, with helpers for line/whole-buffer reads and
  writes. It is exactly **one hop**, not a composable pipeline — there
  is no operator or type for chaining a `wstream` into a parser into a
  hash map. `streams.md`'s own "Follow-ups" section already flags
  moving `repl_read_line`/the tokenizer's `getc` onto it as unfinished,
  which is a smaller, single-consumer version of the same "wire one
  stream into one more thing" problem #332 wants generalized.
- **The PG's listener/streaming mode** (#329 M3, `parser_generator.md`)
  is a real, already-landed instance of a *push-based* pipeline stage:
  tokens flow through `on_token`/`on_enter_<rule>`/`on_exit_<rule>`
  callbacks with no materialized intermediate. It is scoped narrowly to
  parser callbacks today, but it is the nearest existing precedent for
  "one stage pushes into the next without buffering the whole thing" —
  a real design would need to say whether #332 wants that same
  callback shape generalized to arbitrary producers/consumers (TCP
  socket → protocol decoder → hash map, as push callbacks), or a
  pull-based cursor protocol instead (the `for T x in container`
  iteration protocol containers already use, per `typed_containers.md`
  and `structures/array_list.w`'s "cursor-protocol exemplar"), or a
  coroutine/task model (`lib/task.w`'s scheduler, which already runs
  concurrent stages that block on each other).
- **Relation to #338's composition story**: if modules eventually gain
  a defined artifact/interface boundary (§2's options (b)/(c)), a
  streaming-types design would need to say what the `->` operator's
  *type* is generically — is `TCP -> Protocol` a value transformation
  (ordinary function composition, resolved entirely at compile time) or
  a running-process wiring (each stage is a live task/thread, closer to
  `lib/task.w`'s coroutine model or an OS process pipeline)? Those imply
  very different runtimes and very different answers to what a
  "library" boundary between stages would even mean.

Open questions a real design would need to answer: what does one line
of `A -> B -> C` actually compile to (a synchronous call chain? A
struct of channels? Threads/processes per stage?); is a stage pull- or
push-driven, and can the two compose; how does backpressure/blocking
propagate across stages of different speeds; does spelling a pipeline's
static type need generics (`docs/projects/generics.md`, already landed)
or the type operators #333 asks for (§5); and is this purely a library
addition over the existing `wstream`/`task` primitives, or does it need
new syntax. None of that is decided here.

## 5. Scoping note: #333 "Future: Type Operators"

Issue text (abridged): "Add type operators that allow the user to
seamlessly construct complex types" — `hash_map + queue`, `hash_map *
list`, `hash_map * list(0)`. No design taken here, same as §4.

- **Relation to generics** (`docs/projects/generics.md`, landed):
  user-defined generic functions and structs already exist with
  explicit (`pair[int]`) and call-site-inferred instantiation. This is
  a real, working generic-type mechanism today — but it composes types
  by bracket instantiation (`pair[T]`), not by an infix operator over
  type names, so `hash_map + queue` has no existing syntactic home.
- **Relation to typed containers** (`docs/projects/typed_containers.md`):
  the built-in `map`/`set`/`list[T]` are a **deliberately closed set**,
  not generalized to user-defined generic containers — the type table
  stores one parse-time-monomorphized record per distinct
  element/key/value combination, a design chosen specifically to avoid
  the AST-free compiler having to support arbitrary user-defined
  generic container instantiation (`typed_containers.md`'s "Decision:
  built-in typed containers, not generics" section spells out why).
  Composite shapes like "a map whose values are lists" already exist
  today with existing syntax — `typed_containers.md` shows
  `list[list[int]] grid` and map value slots that are themselves
  containers — so part of what #333 asks for (`map[K, list[V]]`-shaped
  composition) may already be expressible; what's actually new is the
  *infix operator* spelling, not the underlying capability.
- **Relation to operator overloading**
  (`docs/projects/operator_overloading.md`): value-level operator
  overloading (`operator +` on struct instances) is already
  implemented. #333's `+`/`*` are pitched at **types**, not values — a
  different, unimplemented axis entirely (evaluated at compile time
  over type expressions, not at runtime over struct instances) that the
  existing mechanism does not cover and was not designed to cover.
- **The examples don't disambiguate the actual semantics wanted.**
  `hash_map + queue` could mean a sum type, a struct combining both, or
  sugar for `map[K, queue[V]]`. `hash_map * list` and especially
  `hash_map * list(0)` have no evident W meaning at all — is `list(0)`
  a zero-argument call, an index, a size hint? Nothing in the issue or
  the surrounding "Future:" filing (#332, filed the same day, one
  minute apart) explains it.

Open questions a real design would need to answer: do `+`/`*` denote
anything semantically consistent (algebraic sum/product types?), or
are they sugar for composite shapes already expressible with today's
bracket generics (in which case the actual gap is documentation/
examples, not a language feature); if new syntax is warranted, does it
live in the type-name grammar (`grammar/type_name.w`) alongside the
existing `list[T]`/`pair[T]` forms or somewhere new; and — the concrete
blocker — what do the `*` examples actually mean, since neither this
doc nor the issue text can resolve that without the maintainer
supplying worked examples of what `hash_map[string, int] + queue[int]`
should compile to. No design is attempted here pending that answer.

## 6. Summary

| Issue | This doc's read | Recommended next step |
|---|---|---|
| #338 claim 2 (thin CLI wrappers) | Already proven achievable (`wvc.w`/`cas.w`); several tools (`wexec.w`, `test_map.w`, `wbuildgen.w`) are the counter-example | Refactor those three into a library + porcelain split, no new compiler work |
| #338 claim 1 (compiled library format) | No relocatable/archive format exists; a "static library" has nothing to match today | Don't schedule the archive+linker option (b) without an explicit maintainer sizing call; shared-library production (c) is the more tractable literal reading if wanted |
| #338 performance motivation | Likely the same complaint `wbuildd` already solves | Ride `wbuildd`'s existing schedule, already gated in `sonnet_wave_plan_2026_07b.md` §6 |
| #337 | AST exists (PG, syntax-only) but the new streaming mode is the wrong half of it; a real backend needs an external LLVM toolchain, in tension with the project's zero-dependency identity | Run the bounded, seed-safe `bin/wllvm`-style experiment (§3.6); do not commit to a full backend before it reports back |
| #332 | Real primitives exist (`lib/stream.w`, PG listener mode, `lib/task.w`) but nothing composes them into a pipeline today | Scope a dedicated design doc once the push-vs-pull and #338/#333 dependencies are answered |
| #333 | Generics and typed containers already cover much of the underlying capability; the operator spelling and the `*` examples are unresolved | Get worked examples from the maintainer before any design work starts |
