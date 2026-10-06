# W Codebase Fundamentals Audit

Audited on 2026-10-04 at reardan/w commit 3e58449 (release 0.3.0); file and
line references are to that snapshot.

## Summary

W is far more complete than a typical self-hosted language project: it
bootstraps on five targets with a byte-identical fixpoint, runs an 802-target
test suite in about three minutes on every pull request, and carries a
cryptography and TLS stack tested against RFC vectors. The fundamentals it
lacks cluster in four places.

- Correctness of the core. Two reproducible compiler defects: a struct store
  overwrites the memory after any struct whose size is not a word multiple,
  and `bool b = n` segfaults for any non-constant int. The type checker treats
  most type errors as warnings or accepts them silently, locals and `new T`
  are uninitialised, and no specification says what is defined.
- Safety of the output. 32-bit binaries run with an executable stack, heap and
  data segment because no ELF writer emits PT_GNU_STACK; no Linux binary has
  address-space randomisation; the release allocator detects no double free,
  bad free or overflow and accepts `malloc(-1)`; stack overflow dies without a
  report and worker threads keep their thread-local block where the overflow
  lands first.
- Algorithmic basics in the library. `list.sort()` is an O(n²) insertion sort
  (13 s for 80,000 ints), the built-in map uses an unseeded hash that
  colliding keys slow 190-fold, `split` in lib/str.w is quadratic (157 s on 1
  MB), and `f64toa(1e20)` prints -9223372036854775808.
- Engineering process. A public repository with no licence, no code review or
  branch protection while 98% of recent commits are AI co-authored, five
  backends never executed by any workflow, tests that pass by printing SKIP,
  and no coverage, fuzzing or mutation testing. The companion repository's
  main branch is red at the time of writing.

What is in place is covered next; the six fixes that remove the worst of the
above are each a day or less of work and are ranked at the end.

## Scope and method

The audit covers both repositories at their heads on 2026-10-04: reardan/w at
commit 3e58449 (release 0.3.0) and reardan/w-private at commit ad5cbb8. It
asks one question of each area: which fundamentals a textbook compiler,
runtime, standard library and engineering process would have, and whether this
codebase has them.

| Repository | Tracked files | Source | Design docs | Build or test targets |
| --- | --- | --- | --- | --- |
| reardan/w | 1,663 | 1,311 W files, about 269,000 lines (lib 47k, libs 82k, tests 50k, tools 26k, graphics 19k, grammar 14.5k, code_generator 10k, compiler 7k) | 99 Markdown files, 74 of them under docs/projects | 879 targets in the generated manifest, 601 test sources under tests/ |
| reardan/w-private | 711 | 163 W files, 192 C fixture files, 72 shell scripts, 14 Python files | 65 Markdown files | per-product build scripts plus one CI workflow |

Evidence came from three sources: the orientation documents (README, AGENTS,
CLAUDE, docs/todo.txt and the design docs), the code itself, and the behaviour
of a toolchain built for the audit from the pinned v0.3.0 seed. Where a claim
depends on runtime behaviour (integer overflow, zeroing of allocations, crash
output, parser robustness) it was checked by compiling and running small W
programs rather than by reading alone. Each finding below names its evidence:
a file path, a command and its output, or a document passage. Findings that
rest on reading rather than running are marked as such.

Since the snapshot: this document was prepared against main at 7ccc2a0, 31
commits later. Those commits add an opt-in expression AST
(`ast_expressions_mode`, off by default) and the wc2 semantic-AST front end,
which bear on the intermediate-representation and AST items below, and
refactor one helper in grammar/promote.w. Checked against that diff, the
struct-copy and int-to-bool defects and every other finding are unchanged; the
cited lines in grammar/expression.w and grammar/promote.w now sit three lines
lower.

The wc2 experiment mentioned in that historical snapshot was retired on
2026-10-04. Ongoing AST work lives in the
[production compiler](projects/ast_migration.md); the
[retirement record](projects/wc2.md) preserves its findings.

Updates since the audit (2026-10-06, against main at 5bbce83). The findings
below are left as audited; these notes record what has changed since.

- AST and IR: the AST spike (#488) is closed as completed, and the
  production AST migration has landed on main (merged 2026-10-04). Since
  completion-plan unit P1.4 the AST front end is the default (still one
  pass: each root is lowered as soon as it is parsed); `--streaming` selects
  the old streaming front end, `--ast-required` rejects any expression that
  would fall back to streaming, and `./wbuild ast_expression_suite` runs the
  test suite that way.
  `--ast-retain` keeps the traversal trees, but they are not yet an
  executable module IR. #489 (an AST in the compiler proper) stays open,
  with a completion plan in
  [ast_completion_plan.md](projects/ast_completion_plan.md); the status is
  in [ast_migration.md](projects/ast_migration.md).
- Multi-error diagnostics: `w check --all-errors` (#523, POSIX hosts)
  isolates each failure and keeps checking, so a file with four unknown
  symbols reports all four, where the default check stops at the first.
  Plain compiles still stop at the first error. JSON diagnostics still
  carry no error code, end column or related-location notes.
- Closures: lambdas (#107) were closed as not planned in July 2026;
  `it`-expressions remain the substitute.

## What is already strong

W has more fundamentals in place than most self-hosted language projects, and
several of them are done to a professional standard.

- Self-hosting with a byte-identical fixpoint on x86 and x64 on every pull
  request, with reproducible output and a content-hash build-id; the wasm,
  arm64, darwin and win64 backends self-host as well, checked at release time.
- Compile speed and compiler data structures: the compiler compiles its own
  58,000 lines in about half a second with 10 MB of peak memory, and symbol
  and type lookup are hashed.
- Diagnostics in the rustc layout with edit-distance suggestions and
  machine-readable JSON, frozen by 35 fixture suites over 151 fixture files.
- Safety defaults: bounds traps on arrays, slices, lists and strings with
  symbolised stack traces, PAC-signed return addresses on arm64, guard pages
  on generator stacks, and read-only text with read-write data in every file
  image.
- Crash reporting: an async-signal-safe handler that prints registers,
  build-id and an exact frame-pointer trace, W-generated core dumps readable
  by gdb, and a core-dump reader (wcore).
- Allocator and threads: a 41-bin allocator that reports exhaustion,
  mimalloc-style per-thread heaps with lock-free remote frees, futex mutexes
  and a lost-wakeup-proof condition variable with a written memory-order
  contract.
- A checked I/O layer (lib/io.w, landed 2026-10-03) with allocation-free
  result records, sticky stream errors, durable-replace primitives, a fake
  filesystem and a simulated event loop for tests.
- Cryptography and TLS tested against RFC and NIST vectors and a Wycheproof
  subset, an RFC 8448 handshake replay, constant-time tag comparison, a
  getrandom-backed CSPRNG, chain and hostname verification on by default, and
  weak primitives quarantined under libs/x/unsafe.
- Protocol parsers with explicit limits: HTTP/1.1 header and body caps with
  request-smuggling rejection, HTTP/2 flow control and SETTINGS enforcement,
  WebSocket message caps and UTF-8 validation, a strict bounded DER reader.
- A distributed-systems toolkit (Raft with WAL and membership changes, SWIM,
  phi-accrual failure detection, LSM storage, leases) tested under
  deterministic simulation, and in w-private a database prototype whose
  durability path (WAL, fsync, atomic publish, fail-closed recovery, fault
  injection) is textbook.
- A build system that hashes content rather than timestamps (verified), with a
  validated DAG, cycle detection, parallel scheduling, keep-going, per-step
  timeouts and a dedicated test for each; a manifest generated from source
  directives; generators that reproduce byte-identical output.
- An in-house assembler and disassembler that round-trips all 384,433
  instructions of the compiler binary with zero mismatches, runs randomised
  round-trip tests, and assembles the runtime stubs from text at every
  compile.
- Documentation: 72 design documents, 12 library plans, a measured
  compiler-performance report, an engineering log that records its own cache
  incidents, and agent guides whose 148 back-ticked paths all resolve.
- Self-awareness: open issues already name several of the gaps below (fuzzing
  #440, an AST #489, a hermetic CI gate #486, optimisation #110, a formatter
  #25), and the reliability design filed on 2026-10-03 (#514) shipped its
  first stages the same day.

## Language design and type system

The type checker reports most ill-typed programs as warnings or not at all,
and two memory-safety defects were reproduced during the audit: struct stores
that overwrite neighbouring fields, and an int-to-bool conversion that crashes
the compiled program. The language also has no written specification, no sum
types, closures or interfaces, and one flat namespace shared with the
auto-imported prelude.

| Fundamental | Status in W | Evidence |
| --- | --- | --- |
| Sound struct copies | Defect. A store of a struct whose size is not a word multiple writes whole words and clobbers what follows: storing a 1-byte struct into a field turned the neighbouring int 0x12345678 into 0x123456; storing into element 0 of a `tiny[4]` array rewrote elements 1 to 3; copies through pointers and into heap arrays do the same. Structs are packed, so every struct of 1 to 7 bytes (9 to 15 on x64) is exposed. | grammar/expression.w:34-49 rounds the copy up to words; grammar/postfix_expr.w:155-157; reproduced during the audit on x64 |
| int to bool conversion | Defect. `bool b = n` for any non-constant int segfaults on x86 and x64, as do int arguments to bool parameters, int returns from bool functions and stores into bool fields; literals and comparisons work. | grammar/promote.w:357-360 promotes an already-promoted value and loads it as an address; reproduced during the audit on both targets |
| Rejecting ill-typed programs | Weak. Wrong arity, int to pointer, struct to struct, const stripping and function-pointer signature mismatches are warnings that exit 0 unless `--strict`. Silent: narrowing (300 into a char becomes 44), signed and unsigned mixing, bool and int, enum and int, `void*` to any pointer, float to int truncation, pointer-versus-int comparison, duplicate case labels, `==` on structs (compares addresses), a non-void function falling off its end, `return 5` in a void function, calling an int variable. | `./bin/wv2 check --json` over about 40 probe files; compiler/type_table.w:963-975 |
| Definite assignment and initialisation | Missing. Locals read garbage; `new T` and `new T()` return uninitialised memory while `new T[n]` and `new T(field: v)` zero theirs; a declared but unconstructed `list[int]` or `map` segfaults on first use and reports a garbage length. | grammar/unary_expression.w:48-58,386-412; probes run on both targets |
| Language specification | Missing. No document states syntax plus semantics or names undefined behaviour; the grammar file is syntax only; "W has no memory model in the language yet". Design docs contradict the compiler: type_system_p0.md says int to enum needs a cast and const conversion is implicit, yet `color c = 5` compiles silently and `const int* p = q` warns. | docs/projects/threads.md:244; docs/projects/type_system_p0.md:289,395; README.md:12 |
| Portable integer semantics | Weak. Literals are 32-bit and sign-extended on every target: `-2147483648` is positive on x64, `1 << 40` is 256 on x86 and 2^40 on x64, `int64 big = 10000000000` is a compile error, `uint32 1 > int -1` differs by target. Signed overflow, shifts past the width and `INT_MIN / -1` follow the hardware with no stated policy. | grammar/int_literal.w:55-80; CLAUDE.md gotcha list is the only collection point |
| Module privacy and namespaces | Missing. Two imported modules defining the same helper is "symbol redefined"; a user function named `input`, `ints` or `read_all` collides with the auto-imported prelude; a module's helpers leak to importers of its importers; aliases only add a warning. | structures/prelude.w:134,155,174; docs/todo.txt:534-535 |
| Sum types and pattern matching | Missing by stated design: unions are untagged, pattern matching is a non-goal. | docs/projects/type_system_p0.md:418,470 |
| Closures | Missing: `it`-expressions compile to inline loops; lambdas (#107) were closed as not planned. | docs/projects/golf_ergonomics.md:126-129 |
| Interfaces, traits or bounded generics | Missing: polymorphism is duck-typed protocols plus function pointers; generic bodies are checked per instantiation; inference does not bind through `list[T]`, `pair[T]*` or forward calls. | docs/projects/generics.md, iteration.md |
| Option or nullable type | Missing: `wresult[T]` is a heap-allocated three-word record and null pointers remain the idiom (`input()` returns 0 at end of input). | docs/error_results.txt |
| Destructors or RAII | Missing: function-scoped `defer` only; container `.free()` is shallow. | docs/projects/defer.md |
| Honest surface syntax | Two traps: README advertises relational chaining but `3 > 2 > 1` is 0 (C semantics under a Python-like surface); `byte`, `string`, `var`, `float`, `new`, `cast`, `sizeof` and `in` cannot be identifiers while `it`, `range`, `list`, `map`, `print`, `len` and `max` can, and no document lists either set. `char` is signed on every target and the README type list does not say so. | README.md:199; docs/mvp.txt:19; probes |

Already in place: bounds-checked arrays, slices, lists and strings with
symbolised traces; `cast(T, e)` as the single escape hatch, with a hard error
for address-to-sub-word casts; precisely specified unsigned word operations;
typed function pointers with signature and arity checks; `wresult[T]` with `?`
propagation under a written contract; monomorphised generics with call-site
inference and an error catalogue; and `check --json`, `--strict` and opt-in
lint for unreachable code, shadowing and unused locals.

## Compiler architecture, code generation and diagnostics

The compiler is fast and deterministic, but the single-pass design omits three
textbook layers: an intermediate representation (so there is no optimizer and
no register allocator), multi-error diagnostics, and symbolic debug
information. The ELF writer also omits two standard hardening features, and
one of them undoes the documented W^X split at load time.

| Fundamental | Status in W | Evidence |
| --- | --- | --- |
| Non-executable stack and data (PT_GNU_STACK) | Missing. No ELF target emits the header, so 32-bit programs run with an executable stack, heap and data segment (the kernel applies READ_IMPLIES_EXEC). 64-bit programs are protected only because kernels since 5.8 ignore the omission. | code_generator/elf_all.w:104,160-165; a fresh 32-bit program printing /proc/self/maps shows `[stack] rwxp`, `[heap] rwxp` and the data segment `rwxp` (run during the audit, kernel 6.18); docs/projects/wx_split.md claims every target is W^X and elf_wx_segment_test checks only file headers |
| Address-space randomisation (PIE) | Missing on every Linux target. Binaries are fixed-address ET_EXEC at 0x08048000, x64 included. The x64 backend materialises absolute 32-bit addresses (`mov eax, imm32; call eax`), so PIE is blocked by the code model, not just unimplemented. | elf_all.w:127,170; repl/core.w:993-996 ("must sit in the low 2GB"); no RELRO, canaries, CFI or .eh_frame anywhere (grep) |
| Intermediate representation | Missing by design (cc500 heritage). Grammar rules parse and emit machine code in one pass; generics are re-parsed by seeking the source file per instantiation. | grammar/binary_op.w:121-147; grammar/generic.w:283-340; issue #489 tracks adding an AST. Update: an opt-in production AST path has since landed and #488 is closed; see the updates above |
| Optimisation and register allocation | Only byte-adjacent peepholes, x86 family only. Every local lives in memory, no CSE, dead-code or dead-function elimination, inlining, tail calls, or -O flag. | A pointer-sum loop compiles to 42 instructions (30 per iteration) against gcc -O0 23 and -O2 15; bin/wv2 carries 10,458 dead `add esp,0` (2.5% of its instructions) and 80% of its calls are indirect through a materialised constant; hello world links 328 functions and 86 KB |
| Multi-error diagnostics and stable error codes | Missing. The first error calls exit(1). The JSON diagnostics carry no code, end column or related-location notes. | compiler/tokenizer.w:385-393; compiler/diagnostics.w:318-343; README states recovery is out of scope. Update: `w check --all-errors` (#523) now reports multiple errors; error codes are still missing |
| Symbolic debug information | Line tables only. DWARF has a single childless compile unit: no subprograms, variables, types or CFI, so gdb shows "No symbol table info available" for locals and arguments. Variable locations exist only in the in-process debugger's memory. | code_generator/dwarf.w:103-108,293-308; gdb session on a two-function program |
| Backend abstraction | None. Four instruction sets and five container formats are selected by if/elif chains on a global `target_isa` inside about 110 emitter helpers; roughly 6,100 lines implement the same helper surface four times. | code_generator/x86.w (231 target_isa mentions), docs/projects/arm64.md decision D3 |
| Separate or incremental compilation | Missing. Every build is whole-program with no object files or linker; mitigated by speed (the compiler compiles its own 58,000 lines in about 0.5 s). | docs/projects/compilation_model.md §1; timed during the audit |
| Documented internal calling convention | Code comments only. All arguments pass on W's own stack with no register arguments on any target; struct values are copied word by word. | grammar/postfix_expr.w:150-215, code_generator/ffi.w:1-45; no ABI document under docs/ |
| Independent oracle for instruction encodings | Partial. The in-house assembler round-trips 384,433 instructions of bin/wv2 with zero mismatches and runs randomised round-trip tests, but no automated check compares against an external assembler. | asm_x86_asm_test run during the audit; docs/projects/assembler_disassembler.md asks for a manual cross-check |

Already in place: symbol lookup is hashed and O(1) expected
(compiler/symbol_table.w:60-170), the self-compile runs at roughly 100,000
lines per second with 10 MB peak memory, output is byte-reproducible with a
content-hash build-id, array and slice bounds checks are on by default, arm64
return addresses are PAC-signed by default, generator stacks have guard pages,
and diagnostics follow the rustc layout with edit-distance suggestions.

## Runtime, memory safety and concurrency

The runtime has a well-designed allocator, per-thread heaps, futex mutexes and
an async-signal-safe crash reporter, but the release build detects no heap
misuse at all, stack overflow cannot be diagnosed, and worker threads keep
their thread-local block exactly where a deep recursion overwrites it first.

| Fundamental | Status in W | Evidence |
| --- | --- | --- |
| Heap integrity checks in release builds | Missing. A double free hands out the same pointer twice; freeing a stack address is silent; writing 40 bytes into an 8-byte block and freeing it succeeds and corrupts later allocations; `malloc(-1)` returns an 8-byte block because sizes below 1 are clamped to 1. The only detection is the opt-in debug allocator. | lib/memory_freelist.w:233-236,306-312; probes run during the audit on x64 |
| Overflow-checked size arithmetic and allocation failure | Missing. List capacity doubling, string-builder growth and hash-table slot sizing multiply unchecked, and a negative result becomes a tiny block. `new`, list and map creation never test for a null allocation: `new int[64M]` under a memory limit prints the out-of-memory notice and then segfaults at address 0. | structures/w_list.w:105-110; structures/string.w:34-37; structures/hash_table.w:226-227; grammar/unary_expression.w:398-402 |
| Stack overflow diagnosis | Missing. Infinite recursion dies with a bare "Segmentation fault" even with the crash handler installed, because handlers run on the overflowing stack (no sigaltstack on Linux). | lib/crash.w:88-93; lib/signal.w:65-81; probe run during the audit |
| Guard pages on thread stacks | Missing. Worker stacks are a plain 4 MB mapping and the thread_local block sits at its bottom, so a deep recursion silently overwrites the per-thread heap pointer before any fault. Generator stacks, by contrast, have a 16 KB guard. | code_generator/x86_asm.w:128; lib/thread.w:191-200; lib/generator.w:53-74 |
| Debug allocator correctness | Two defects: under W_DEBUG_ALLOC=1, `malloc(13)` returns a pointer that is 3 mod 8, and a shrinking realloc copies the old length into the smaller block and segfaults on its own guard page. Block lookup is a linear scan. | lib/memory_debug.w:140-146,217,243-256 |
| Close-on-exec for spawned processes | Missing. Children inherit every parent descriptor; there is no O_CLOEXEC, pipe2 or close_range anywhere in lib. `process_free` closes and frees without reaping, so a caller who skips `process_wait` leaves a zombie. | lib/process.w:423-456,649-653; probe run during the audit |
| Atomics and a memory model | Partial. Only `atomic_add` and `atomic_cas`, on x86 and x64; no atomic load or store, no fences. Flag handoffs rest on x86 total store order plus the observation that the single-pass compiler never caches values in registers, which the docs say is not a language guarantee. Threads exist on Linux x86 and x64 only. | grammar/atomic_builtin.w:5-9,74; docs/projects/threads.md:247-254,298-307 |
| Thread API completeness | Partial. No recursive or timed locks, cancellation, detach or deadlock detection; only the main thread may spawn, join or run `parallel_for`; `println` is two raw writes so lines from threads interleave; `getchar` uses global buffers. | lib/thread.w; lib/lib.w:351-357,523-525 |
| Deterministic resource cleanup | Weak. No destructors; an abandoned generator leaks its whole mapping (500 abandoned generators grew the process from 8 to 1,008 mappings); `return` or `?` out of a for-over-generator skips the free; cancelled timers stay in the heap until their deadline. | grammar/for_statement.w:700-705; lib/event_loop.w:470-477; probe run during the audit |
| Leak checks in the suite | Weak. Only 4 of 230 tests under tests/ call the leak report and no manifest step sets W_DEBUG_ALLOC. | `tests/*_test.w` grep |
| Error reporting at the edges | Partial. `print` discards the result of `write`: with SIGPIPE ignored, every write to a closed pipe fails yet the program prints "finished all writes" and exits 0. There is no documented exit-code convention for W programs. Division by zero and null dereference exit by signal with a report; container traps exit 1. | lib/lib.w:317-318,472-473; probe run during the audit |
| Ownership documentation | Partial: 33 of 135 lib functions returning `char*` or `string` say who frees the result. | `lib/*.w` sample |

Already in place: a 41-bin segregated free-list allocator with brk-to-mmap
fallback that returns null with a notice on exhaustion; mimalloc-style
per-thread heaps with lock-free remote frees, so any thread may free any
block; Drepper-style futex mutexes and a lost-wakeup-proof condition variable,
with a written memory-order contract; an epoll event loop with binary-heap
timers and an injectable clock; process capture that polls both pipes so a
chatty child cannot deadlock; a genuinely async-signal-safe crash handler
printing registers, build-id and an exact frame-pointer trace; W-generated
core dumps readable by gdb; bounds traps on by default; and the new checked
I/O layer in lib/io.w, which latches write failures on streams.

## Standard library, data structures and algorithms

The cryptography, TLS and protocol-parsing code is the best-engineered part of
the library, but the everyday primitives miss textbook complexity bounds: the
built-in sort is quadratic, the built-in hash is unseeded and floodable,
string splitting is quadratic, and float formatting overflows. Six
error-handling conventions coexist and the documented one is the least used.

| Fundamental | Status in W | Evidence |
| --- | --- | --- |
| O(n log n) sorting | Missing. `list.sort()`, `sort_by`, `sorted` and `sort_keys` are an insertion sort whose comment says the lists "are small". Measured: 10,000 ints 214 ms, 40,000 ints 3.3 s, 80,000 ints 13 s (four times per doubling). O(n log n) sorts exist only as private helpers in lib/stats.w and lib/byte_map.w. | structures/w_list.w:321; benchmark run during the audit on x64 |
| Hash-flooding resistance | Missing in the built-in map and set. Unseeded djb2 (`h*33 + c`) with linear probing: 16,384 distinct keys insert in 14 ms, 16,384 colliding keys in 2.6 s and the curve is quadratic; int keys that are multiples of 65,536 are 750 times slower than sequential ones. JSON object keys and HTTP header maps use this map. lib/byte_map.w already has the right design (keyed HalfSipHash with a CSPRNG seed) but nothing else uses it. | structures/hash_table.w:130-139,258,325; benchmark run during the audit |
| Linear-time string splitting | Missing in lib/str.w: every piece calls `substring`, which begins with `strlen` of the whole input. 1 MB with 200,000 separators took 157 s; the import-free prelude `split` is linear and takes 17 ms on the same input. The two share a name and are chosen by whether a program imports lib.str. | lib/str.w:10,76; structures/prelude.w:206-220; benchmark run during the audit |
| Correct float text conversion | Weak. No string-to-float parser exists in lib/ (only the tokenizer and the JSON parser parse decimals). `ftoa`, `f64toa` and f-string interpolation are fixed six-digit truncating converters: `f64toa(1e-7)` prints 0.000000 and `f64toa(1e20)` prints -9223372036854775808.000000 because the integer part is converted through a word-sized int. The JSON parser, which claims correct rounding, parses 2.2250738585072011e-308 one ulp high and prints DBL_MAX as `2e308`, which other JSON readers reject. | lib/float_text.w:14; structures/json_float64_impl.w:23; probe run during the audit |
| Regular expressions | Weak. lib/regex.w has no groups, alternation, counted repetition or classes like `\d`, and a 1,048,576-step budget turns exponential patterns into silent non-matches: `a?^25 a^25` against 25 a's returns no match although it matches. | lib/regex.w:50-51; probe run during the audit |
| Textbook containers | Partial. Present: list, insertion-ordered map and set, string builder, bitset, binary heap, ring deque, keyed byte map, Bloom filter, consistent-hash ring, LSM memtable and SSTable, ndarray and matrix. Missing: ordered map or set (no balanced tree or skip list), trie, union-find, general graph algorithms, string search beyond O(nm) `index_of`, LRU cache, a public binary-search API, a general signed bigint (crypto/bignum.w is unsigned with a fixed cap and 15-bit limbs, and the 32-bit limb intrinsics from #213 have no consumer). | structures/, lib/, libs/standard/distributed/; grep |
| Unicode text operations | Partial. UTF-8 decoding, grapheme segmentation (Unicode 15.0.0) and identifier screening exist; `tolower` and `toupper` are ASCII-only and there is no case folding, normalisation or collation anywhere. `input()`, `read_all()` and `lines()` return unvalidated bytes and JSON strings accept invalid UTF-8 verbatim. | lib/str.w:120-154; structures/prelude.w; grep |
| Path and time basics | Partial. lib/path.w has no normalisation: `path_join("/srv/static", "../../etc/passwd")` returns the unnormalised path and an absolute second argument replaces the first. Time is UTC only with no zones or local time, and `time_utc_from_unix` traps on negative timestamps. | lib/path.w:24; lib/time.w |
| One error-handling convention | Missing. docs/error_results.txt prescribes `wresult[T]` with `?`, but core lib/ uses at least six conventions: 0 on failure (file_read_text), io_result status codes (lib/io.w), -1 and -2 sentinels (sockets), negative errno (raw net), decoded status with -1000 sentinels (process_wait), 0/1/2 enums (memtable_get), traps (json_object_get, time), silent clamping (split, substring). `wresult[T]` appears in two lib/ files and `?` has about five non-test call sites. | lib/file.w, lib/net.w, lib/process.w, structures/json.w; grep |
| Cryptography and TLS assurance | Partial but strong. RFC and NIST vectors for ChaCha20-Poly1305 (including a Wycheproof subset), HMAC, HKDF, X25519, ECDSA and SHA-2; an RFC 8448 handshake replay through the real client; constant-time tag compares; getrandom-backed CSPRNG; chain and hostname verification on by default. Gaps: no live interop test against OpenSSL or curl in any workflow (the interop target is explicitly manual and plan 11 lists it as future work); Wycheproof vectors only for one primitive; ECDSA signing performs variable-time bignum operations on the secret nonce and key, which the source documents as a residual caveat; no revocation (CRL or OCSP) or name constraints in x509.w. | libs/standard/crypto/ecdsa_p256.w:17,519-523; libs/standard/plans/11_native_http_tls.md:343-355; tests/openssl_tls_interop.w |
| Network-service robustness | Partial. Request-line, header, chunk, body and WebSocket message limits exist and request smuggling is rejected. Gaps: the plain accept loop is strictly serial with per-wait 30 s timeouts rather than a whole-request deadline, so one slow client can hold it; no header-count limit; the HTTP client will buffer a 1 GiB body from a hostile server; lib/framing.w has no Content-Length cap and an unchecked `value*10`. | libs/standard/web/http_server.w:237,1140-1158; http_client.w:155; lib/framing.w:117-131 |
| API documentation and test coverage | Partial. 48% of top-level functions in a ten-file lib/ sample have a doc comment (lib/lib.w 26%); there is no library reference or doc generator. 31 of 120 lib/ and structures/ modules are imported by no test, among them lib/float_text.w (where the formatting bug lives), lib/logging.w (imported by nothing), lib/crash_dump.w and the GPU stack. | scripts written for the audit (not committed); grep |

Already in place: a hash table with tombstones, in-place rehash and
Python-dict insertion-order semantics; a JSON parser with a depth limit of 128
that rejected 100,000 nested brackets cleanly, last-wins duplicate keys and
correct surrogate handling; bounded HTTP/1.1, HTTP/2 (flow control, SETTINGS
limits, ENHANCE_YOUR_CALM) and WebSocket parsers; a strict bounded DER reader;
weak primitives quarantined under libs/x/unsafe; a conformant DEFLATE
implementation with CRC32, CRC32C and Adler-32; a distributed toolkit (Raft
with WAL and membership changes, SWIM, phi-accrual failure detection, LSM
storage, leases) tested under deterministic simulation; and lib/byte_map.w as
a model for how the built-in map should hash.

## Testing and verification

The suite is large and well automated for 32- and 64-bit Linux, but five
backends never execute in any workflow, several tests pass by skipping
themselves, and the standard measurement tools are absent: coverage, mutation
testing, property-based testing with shrinking, and fuzzing in CI.

| Fundamental | Status in W | Evidence |
| --- | --- | --- |
| CI across every supported target | Partial. The `tests` umbrella runs 802 targets on each pull request, including all 261 64-bit twins and both self-host fixpoints. 71 targets sit in no umbrella: all 14 wasm targets, 19 of 22 arm64 targets, the win64 suite, the darwin fixpoint, 12 GPU targets and the zlib and OpenSSL interop tests. Release tags add only byte-compare fixpoints for win, wasm and darwin, so no wasm, arm64, win64 or darwin program ever runs in any workflow. | bin/build.json closure analysis run during the audit; .github/workflows/ci.yml and release.yml; tools/wbuildgen_lib.w:148-151 says the arm64 and wasm twins join no umbrella by design |
| Tests that cannot pass by skipping | Missing. At least five tests print SKIP and exit 0 when no display or /dev/kvm is present (gl_smoke_test, gl_texture_test, cocoa_input_test, ui/smoke_test, wvm_test). CI installs no Xvfb, so the real GL path never runs and nothing reports the skip count. | graphics/gl_smoke_test.w:52-55; ci.yml |
| Code coverage | Missing. No coverage tool exists for W; the word appears only in prose. | grep over tools/ and docs/ |
| Fuzzing, property-based and mutation testing | Missing from CI. tools/fuzz/core.w landed on 2026-10-03 and runs nowhere; issue #440 (Fuzzing) has been open since 2026-08-08. Fixed-seed randomised round-trips exist for the assembler and the Raft sweep. | tools/fuzz/core.w; `asm_fuzz_*` targets; raft_sweep_test |
| Test framework features | Partial. Discovery is compiler-synthesised and want/got messages are good, but the first failure exits the binary (no summary), and there is no name filter, setup or teardown, skip API, parametrisation, seed control or TAP/JUnit output. | lib/testing.w (61 lines), lib/assert.w (106 lines), compiler/test_registry.w |
| Unit tests of compiler internals | Thin. type_table has 8 unit tests and bignum 4; the tokenizer and symbol table have none; compiler/compiler_test.w is a 5-line stub. Everything else is end-to-end. | grep of test imports |
| Differential testing against references | Partial. Float formatting is diffed against a C reference program inside `tests`; the zlib and OpenSSL interop tests exist but run in no workflow; x509 real-certificate fixtures were cross-checked with OpenSSL offline. | tests/openssl_tls_interop.w header: "NOT part of the tests umbrella" |
| Grammar as a specification | Missing. tests/parser_generator/w.pg is a second, hand-maintained grammar; the test only checks that it accepts every tracked file plus two negative cases. Nothing checks that the compiler rejects what the grammar rejects or vice versa, and the generator reports 64 overlapping-alternative conflicts for it. | generated_w_parser_test.w:121-122; `bin/parser_generator w.pg --report` run during the audit |
| Rendering verification | Missing in CI. 2 of 34 graphics tests read pixels back and both skip headless; there are no golden images. | docs/projects/ai_tooling_next_steps.md:529-552 acknowledges it |
| Performance regression tracking | Missing. tools/wbench.w is in no umbrella and nothing records results over time; compiler_performance.md is a one-off report. | manifest |
| Flaky-test policy | None. wexec has no retry, and a CI flake affecting about half of runs is recorded undiagnosed. Of the last 40 CI runs, 32 passed, 3 failed and 3 were cancelled by concurrency on main. | docs/projects/ai_tooling_next_steps.md:278-291; GitHub Actions history |
| Hermeticity gate | Manual. `wexec --trace --hermetic` finds undeclared inputs but runs in no CI job; issue #486 proposes the gate. | tools/wexec_trace.w |

Already in place: a median 3.3-minute run of the 802-target suite;
byte-identical self-compilation checked for both word sizes on every pull
request; 35 fixture suites over 151 fixture files that freeze diagnostic text
beside the code that provokes it; manifest-generated test discovery from `#
wbuild:` directives with structural gates (manifest_check, metadata_check,
parser_generator_w_test, asm_seed_gate); per-step timeouts; and deterministic
generators that reproduced byte-identical output when forced.

## Engineering practice

reardan/w is a public, single-maintainer repository with no licence, no code
review and no branch protection; 98% of recent commits are AI co-authored and
merge when their author decides. The supporting practices (contributor guide,
security policy, changelog, formatter, hash-pinned actions, release signing)
are absent, while design documentation is unusually rich.

| Fundamental | Status | Evidence |
| --- | --- | --- |
| Open-source licence | Missing. The repository is public with no LICENSE file; GitHub reports no licence; the only licence text is the Liberation font's. The cc500 origin is credited in one line with no licence terms recorded. Without a licence nobody may legally copy, modify or contribute. | `git ls-files`; GitHub repository metadata; docs/references.txt:3 |
| Code review and branch protection | Missing. The main branch has no protection rules; the 11 most recently merged pull requests have zero reviews and the author merged each one, usually within 10 to 60 minutes of opening; 6 of the last 71 first-parent commits were pushed straight to main. PR #513 changed 1,006 files (+34,969, -69,713) unreviewed. | GitHub API; `git log --first-parent` |
| Independent check on generated code | Thin. 212 of the last 216 non-merge commits carry Claude co-author trailers; 44 of 50 pull-request merges came from `claude/*` branches; 265 commits landed in one ISO week. The test suite is the only check between generated code and main. | `git log -300` on the shallow clone |
| Contributor-facing files | Missing: CONTRIBUTING, SECURITY, CODE_OF_CONDUCT, CODEOWNERS, pull-request and issue templates, CHANGELOG (release notes are auto-generated), .editorconfig despite the tabs-only rule, Dependabot or Renovate. GitHub's community profile scores 14%. | .github/ holds only ci.yml and release.yml |
| Lint enforcement and formatting | Opt-in and not clean: the audit's `check --lint` run found 239 warnings in lib/, 101 in the compiler tree and 142 in tools/, mostly line length. No formatter; `check --fix` is whitespace only (wfmt is issue #25). | docs/projects/lint.md:98 |
| Supply-chain pinning and release signing | Partial. Seeds are pinned by sha256 (good). GitHub Actions are pinned by tag (`checkout@v7`) rather than commit SHA; releases carry a SHA256SUMS produced by the same job that built the binaries and no signature. | SEEDS; release.yml |
| Bootstrap trust | Single root. The only seed path is a CI-built binary of the previous release; there is no second implementation, reproducible-bootstrap plan or diverse-double-compilation discussion, and the darwin seed segfault was worked around by cross-compiling from the Linux seed. | release.yml comments; grep over docs/ |
| Versioning and compatibility policy | Asserted, not defined. docs/release.md says SemVer but nothing defines a breaking change; `w_language >=0.1.0` in package.wmeta is advisory and the compiler does not read it. | docs/release.md:3; package.wmeta:3 |
| Language and library reference | Missing. No specification; README's "Language snapshot" is the closest. No standard-library reference (docs/library.txt is a 191-byte wish list); `w symbols` is the substitute. Update: `./wbuild library_reference` now generates a library reference from `w symbols --json` (#539), and docs/library.txt is retired. | grep over docs/ |
| Documentation drift | Minor. README says structures/ holds a linked list (actual: bitset, deque, hash_table, heap, json, json_codec, string, w_list, w_dynamic); package.wmeta still cites the removed Makefile; docs/folder_structure.txt, compiler.txt and library.txt are stale plans. Of 148 back-ticked paths in README, AGENTS and CLAUDE, all resolve. Update (#539): the README structures list and package.wmeta are fixed, the stale docs/*.txt plans are retired, and mvp.txt and ui.txt are refreshed. | README.md:154; package.wmeta:2 |
| One planning surface | Split across docs/todo.txt (665 lines), docs/done.txt, README's open areas, libs/standard/plans/01-11 and GitHub issues (25 open, mostly default labels, no milestones); no roadmap. | docs/, GitHub issues |
| Hermetic and incremental builds | Partial. wexec hashes content rather than mtimes (verified), but cache keys omit undeclared compile-time inputs: editing a `c_import` header leaves c_import_test cached, the seed binary is absent from wv2's key, host tools and the environment are unkeyed, and outputs are checked for existence only. 134 members of `tests` are FORCE targets, so a no-op `./wbuild tests` is never incremental. | tools/wexec.w:666-760,1424; `./bin/wexec --trace c_import_test` reported four undeclared headers |
| Test selection coverage | Blind spot. `wtest changed` selects nothing for `*.txt` data (an edit to tools/unicode/UnicodeData.txt selects 0 targets); undeclared headers and fonts fall back to the whole suite. | tools/test_map.w:1630-1638,1924 |
| Code shape | 28 functions exceed 100 lines and 7 exceed 200 (postfix_expr 378, ptx_promote 348, link_impl 294); the largest files are tools/test_map.w (3,381 lines) and tools/wexec.w (3,119). Debt markers are low: 7 upper-case TODO or FIXME in 270,000 lines. | wc, grep |

Already in place: least-privilege CI permissions, concurrency cancellation,
timeouts and a dispatchable dry run of the release workflow that checks the
version against the tag; sha256-pinned seeds that the build refuses on
mismatch; 72 design documents, 12 library plans, a measured
compiler-performance report and an engineering log that records its own cache
incidents honestly; commit messages with bodies in 90% of cases and issue
references in half; a build executor with a validated DAG, cycle detection,
parallel scheduling, keep-going and per-step timeouts, each with its own test;
and the inotify daemon's careful handling of queue overflow and moved
directories.

## w-private

The companion repository was audited at the same time (commit ad5cbb8).
reardan/w is public, so its product-level findings are not reproduced here and
stay with that repository. In one line: wdb and wed implement durability and
data-structure fundamentals with care, while the build layer, lint discipline
and merge gating are uneven, and main was red at the time of the audit.

## Prioritized recommendations

Fix the two code-generation bugs and the two hardening omissions first: each
is a day or less of work and removes the most serious findings. Then gate the
repository (licence, branch protection, every backend in CI) before investing
in the long-horizon items (specification, intermediate representation, PIE).

| | Less effort | More effort |
| --- | --- | --- |
| More impact | **Do first**: add a licence; emit PT_GNU_STACK; fix the struct-copy and int-to-bool defects; seed the hash and sort in O(n log n); guard pages and sigaltstack; protect main and require review | **Plan**: run every backend in CI; fuzzing and hermetic CI gates; write the language specification; an AST and IR for an optimizer and multi-error diagnostics; PIE and ASLR |
| Less impact | **Quick wins**: Xvfb and skip reporting; zero `new T` and a linear split; pin actions and add contributor files | **Later**: DWARF variables and types; closures, sum types and traits |

The six items in the top-left cell are each days of work and close the audit's
most serious findings; the five in the top-right are the multi-week
investments that change what the compiler can do.

1. Fix the two code-generation defects. Copy the tail of a struct store
   byte-wise (grammar/expression.w struct_copy) and remove the double
   promotion in the bool branch of `coerce` (grammar/promote.w:357-360); add
   fixtures for odd-sized struct stores and for int-to-bool in every position.
2. Emit a PT_GNU_STACK header marked RW in every ELF writer, and extend
   elf_wx_segment_test to read /proc/self/maps at run time so the W^X claim is
   checked where it matters. Run the crash handler on a sigaltstack and give
   worker stacks a PROT_NONE guard, with the thread_local block above the
   guard rather than at the bottom of the stack.
3. Add a LICENSE file and record cc500's terms beside the attribution, then
   turn on branch protection with the CI check required, so a red run cannot
   merge and direct pushes to main stop.
4. Replace the insertion sort with the merge sort already in lib/byte_map.w,
   seed the built-in hash with that file's HalfSipHash, and make lib/str.w's
   split linear (or drop it in favour of the prelude's).
5. Make `new T` zero its memory as `new T[n]` does, make `malloc` reject
   negative sizes instead of clamping them to 1, and make `new`, list and map
   creation check for a null allocation.
6. Run the backends that CI never executes: a qemu-user leg for arm64, a wine
   leg for win64 and a node or wasmtime leg for wasm, plus Xvfb for the GL
   tests; make a test that would print SKIP fail instead when its prerequisite
   is missing in CI.

For the planning horizon: a language specification that fixes syntax,
semantics, the integer model and undefined behaviour (the type_system_p0
contradictions are a starting list); fuzzing in CI now that tools/fuzz exists,
together with the `--trace --hermetic` gate from issue #486; correct float
parsing and shortest-round-trip formatting shared by ftoa, f-strings and JSON;
the production AST (#489; the #488 spike is done) as the one path to an optimizer,
multi-error diagnostics and DWARF variable information; and PIE, which needs a
RIP-relative code model on x64 and is the longest item on the list.
