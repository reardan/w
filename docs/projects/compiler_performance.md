# Compiler performance: where self-compile time actually goes

Status: measurement report, 2026-08-08. Companion to
`docs/projects/optimization.md`, which is about making the *emitted*
code faster; this one is about making the *compiler* faster.

**Update 2026-08-08: §6 is implemented — self-compile 14.7 s → 0.82 s,
a 19.2× speedup, and the quadratic is gone. See §8 for what landed and
what the profile looks like now.** The report below is left as written
so the before-picture and the reasoning stay legible; §8 is the after.
**§10 is the round after that**: `load_i`/`save_i`, the 35% §9 pointed
at, replaced with native-width loads and stores.

Every number below was taken on one machine, one checkout: a 4-core
Intel Xeon @ 2.80GHz, 16 GB RAM, x86_64 Linux container, seed `v0.1.0`
per `SEEDS`, at commit `60e2e14`. The compiler under test is `bin/wv3`
(the self-host fixpoint), targeting 32-bit x86 unless stated. Wall
times are the minimum of 5 runs after a warmup, taken with a
`fork`/`wait4` harness; instruction counts are callgrind (valgrind
3.22) `Ir`; addresses are resolved through the compiler's own DWARF
with `addr2line`.

## 0. Summary

One function, `sym_lookup` (`compiler/symbol_table.w:67`), is
**90.5% of all instructions executed during a `w.w` self-compile**.
It is a full linear scan of the symbol table, run on every symbol
reference, with no early exit. That makes compile time quadratic in
the number of declared symbols, which is why the compiler runs at
35,500 lines/s on a 3k-line program and 3,900 lines/s on itself.

The quadratic term is ~87% of the 14.7 s self-compile. Because
`./wbuild build` runs five self-compiles and `verify` three, this
single scan sets the pace of the entire developer loop, and it is the
long pole of the test suite as well (`check_roots_test`, 63 s, is four
`w check` runs over `w.w`).

Codegen is not the bottleneck: x86, x64 and arm64 self-compiles are
within 1.5% of each other, and `check` — which writes no output at all
— is within noise of a full compile. Memory is not a concern either
(8.9 MB peak RSS). The compiler is 100% CPU-bound; a small compile
issues 155 syscalls total.

## 1. Headline timings

| workload | time |
| --- | --- |
| `wv3 w.w -o out` (x86; 154 files, 57,406 lines) | 14.66 s |
| `wv3 x64 w.w -o out` | 14.72 s |
| `wv3 arm64 w.w -o out` | 14.85 s |
| `wv3 check --json w.w` (writes nothing) | 14.63 s |
| `wv3 symbols --json w.w` | 14.74 s |
| `wv3 deps w.w` (prints 154 paths) | 14.78 s |
| 2-line `int main(): return 0` | 83.7 ms |

Bootstrap stages, each a full self-compile: `wv2`→`wv3` 15.47 s,
`wv3`→`wv4` 14.67 s, `wv4`→`wv5` 14.72 s. `./wbuild build` from a
clean `bin/` is 100.5 s (101.8 s including the seed download);
`./wbuild verify` is 1.2 s only because `build` already produced the
three stages it compares.

That `check`, `symbols` and `deps` all cost the same as a full compile
is the first result worth pausing on: essentially none of the time is
parsing-to-machine-code or ELF/DWARF emission. In the 1000-function
profile below, `dwarf.w` is 0.07% and `code_emitter.w` 0.35%.

## 2. What scales, and what does not

Synthetic programs, varying one dimension at a time. The figure is
wall time; the ratio is the cost multiplier per doubling of `n` (2.0
would be linear, 4.0 quadratic), computed after subtracting the 84 ms
fixed floor from §4:

| n | `stmts` | `funcs` | `locals` | `globals` | `structs` |
| --- | --- | --- | --- | --- | --- |
| 250 | 96 ms | 101 ms | 108 ms | 91 ms | 95 ms |
| 500 | 111 | 120 | 134 | 100 | 109 |
| 1000 | 139 | 170 | 202 | 123 | 157 |
| 2000 | 192 | 315 | 401 | 193 | 320 |
| 4000 | 299 | 769 | 1028 | 420 | 925 |
| ratio at n=4000 | **1.99** | 2.97 | 2.98 | 3.07 | **3.57** |

`stmts` adds statements to one function without adding symbols, and it
is flatly linear (1.99 per doubling, across the whole range). Every
dimension that adds *names* — functions, locals, globals, struct types
— is superlinear and heading for 4.0. Code volume is not the problem;
symbol count is.

Cross-validated against real code: a least-squares fit of
`ms = a + b·L + c·L²` over the 172 test files whose import closure `L`
ranges from 2,992 to 21,862 lines gives

    ms = -28.2 + 2.579e-2·L + 3.887e-6·L²     (Pearson r = 0.871)

Extrapolating that fit — built entirely from small test files — to
`w.w`'s 57,406-line closure predicts **14,261 ms** against **14,700 ms**
measured, a 3.0% error over a 2.6× extrapolation in `L`. A linear fit
on the same data predicts 5,499 ms, low by 2.7×. At `L` = 57,406 the
quadratic term is 12.8 s of the 14.3 s. The two terms cross at
`L` ≈ 6,600 lines, and 30 of the 172 test closures are already past it.

## 3. The cause

`callgrind` on the `w.w` self-compile, 95,446,254,617 instructions:

| Ir | share | function |
| --- | --- | --- |
| 86,362,830,806 | **90.48%** | `sym_lookup` (`compiler/symbol_table.w:67`) |
| 2,363,018,245 | 2.48% | `load_i` (`code_generator/integer.w:56`) |
| 2,036,158,692 | 2.13% | `next_token` (`compiler/symbol_table.w:36`) |
| 540,018,864 | 0.57% | `strcmp` (`lib/lib.w:335`) |
| 509,065,677 | 0.53% | `symbol_data_size` (`compiler/symbol_table.w:32`) |
| 403,600,770 | 0.42% | `__w_list_addr` (`structures/w_list.w:124`) |
| 380,075,159 | 0.40% | `peek` (`compiler/tokenizer.w:548`) |
| 229,491,233 | 0.24% | `type_lookup` (`compiler/type_table.w:348`) |

The same profile on a 1000-function program puts `sym_lookup` at
61.94%. The share climbing from 62% to 90% as the input grows is the
quadratic, visible directly in the profile.

The mechanism is in the data structure. The symbol table is a stack of
variable-length records — name bytes, a NUL, then a fixed 142-byte
block — packed forward and truncated by assigning `table_pos` on scope
exit. Because the records are variable-length and forward-packed, there
is no way to walk the table backwards, and because an inner declaration
must shadow an outer one, `sym_lookup` has to return the *last* match.
So it scans from offset 0 to `table_pos` on every single lookup and
never breaks early, even on a hit:

```
	while (t <= table_pos - 1):
		...
		if (s[i] == table[t]):
			current_symbol = t     # found it, but keep scanning
		...
		t = next_token(t)
```

Instrumenting `sym_lookup` with counters (patch applied, measured,
reverted) gives the cost in records visited, and — by recording where
the winning match sat — what a backwards scan with an early exit would
have cost instead:

| workload | calls | records scanned | per call | backwards | per call | ratio |
| --- | --- | --- | --- | --- | --- | --- |
| 2-line program | 3,775 | 779,420 | 206 | 130,366 | 35 | 6.0× |
| 1000 functions | 5,777 | 2,430,064 | 421 | 957,868 | 166 | 2.5× |
| 4000 functions | 11,777 | 19,380,064 | 1,646 | 9,440,368 | 802 | 2.1× |
| `tests/vcs_pack_test.w` | 16,877 | 9,398,632 | 557 | 1,963,434 | 116 | 4.8× |
| `w.w` self-compile | 87,043 | **169,929,944** | **1,952** | 40,721,025 | 468 | **4.2×** |

87,043 lookups cost 170 million record visits. Only 4,336 of those
lookups (5.0%) are misses, so the scan is almost always walking past
the answer rather than failing to find one.

There is a second, independent cost riding on top. The loop's step is
`t = next_token(t)`, which calls `symbol_data_size()`, which returns
the constant 142 — two non-inlined calls per record visited. In the
1000-function profile `sym_lookup` was entered 5,777 times and
`next_token` 2,448,729 times.

## 4. The fixed 84 ms floor

Every W program auto-imports the container runtime, and the smallest
possible program pays for all of it: 9 modules, 2,987 lines,
**83.7 ms**, 3,775 symbol lookups and 779,420 record visits before a
line of user code is compiled. That floor is the minimum wall time of
any compile in the tree, and it is visible as the `min 84 ms` in §5.

Across a suite run it is not small: 356 test targets × 84 ms ≈ 30 s of
recompiling the identical prelude, and it recurs in each of the five
bootstrap stages. Note that removing it is architectural, not a tweak
— "single-pass, no AST, no IR" means there is no compiled-module
artifact to cache. Fixing §3 shrinks this floor too, since 779,420 of
its record visits are the same linear scan.

## 5. Test suite

`build.json` has 643 targets; the `tests` umbrella pulls 356 and
`tests_x64` 204.

- Full suite from a clean `bin/`, `-j 4 --keep-going`: **625 s**, 646
  targets executed.
- Re-run with a warm content-hash cache: 270 s.
- 7 failures, and they are exactly the seven tests `CLAUDE.md`
  documents as needing `libc6:i386` — `dynamic_test`, `c_import_test`,
  `c_import_errno_test`, `c_import_libc_test`, `float_abi_test`,
  `varargs_test`, `extern_data_test`. All fail with exit 127,
  "ELF interpreter /lib/ld-linux.so.2 does not exist". This container
  has no 32-bit loader; nothing here is a regression.

Compile cost across the 186 `tests/*_test.w` files (`check --json`,
one run each): total 48.4 s, mean 260 ms, median 183 ms, p90 438 ms,
p95 718 ms, p99 1,832 ms, min 84 ms, max 2,357 ms
(`wvc_sync_e2e_test.w`, a 21,862-line closure). Import closures run
10–56 files and 2,992–21,862 lines, median 4,949.

### Parallelism

The suite parallelizes poorly, but not because of the scheduler. On a
fixed 40-target subset: `-j 1` 131.3 s, `-j 2` 103.3 s, `-j 4` 88.5 s
— only 1.48× on 4 cores. A control run with the toolchain pre-warmed
reproduced it (132.2 s → 86.0 s).

The cause is one long pole. Timed individually, those 40 targets sum
to 103.2 s, of which **`check_roots_test` alone is 63.0 s (61%)** — it
runs `w check` over `w.w` and other roots four times, so it is §3's
quadratic, billed four times, in a single unsplittable target. No
amount of `-j` gets that subset below 63 s.

Raw parallelism on this machine is fine: four independent compiles
take 3.405 s sequentially and 0.890 s concurrently, a 3.83× speedup on
4 cores (96% efficiency), with 8 concurrent taking exactly twice the 4
concurrent time. The scheduling is not the problem; the target
granularity and the compile speed are.

## 6. What to do about it

In rough order of payoff per unit of risk. The first is a one-line
change; the last two are the real fix. All of `compiler/` is inside
`w.w`'s import closure, so any of this must compile under the pinned
seed — no new syntax (see the seed constraint in `CLAUDE.md`).

1. **Inline the record stride in the scan loop.** Replace
   `t = next_token(t)` with the addition it expands to, so the inner
   step stops making two function calls to obtain the constant 142.
   Worth ~2.7% of total instructions on its own, and it is local,
   mechanical, and semantics-preserving.

2. **Scan backwards with an early exit.** Keep a side array of record
   offsets, pushed in `sym_declare` and truncated wherever `table_pos`
   is already restored on scope exit (`grammar/statement.w`,
   `grammar/program.w`, and the seven other sites). Then walk it from
   the top and stop at the first hit — which is by construction the
   innermost declaration, so the shadowing semantics are preserved
   exactly. Measured at 4.2× fewer record visits on the self-compile.

3. **Index by name.** A hash map from name to a stack of offsets,
   popped with the scope, turns the lookup into expected O(1) and
   removes the scan rather than shortening it.

To size 2 and 3: the scan and its two helpers are 93.14% of
instructions at self-compile scale. *If* cost stays proportional to
records visited — a model, not a measurement, since neither fix is
implemented — the 4.2× reduction of option 2 puts the self-compile at
roughly 29% of its current instruction count, so ~3.4× faster, and
option 3's ceiling is ~14×, which real hashing costs will erode.
Either way the win multiplies straight through `verify` (3 stages) and
`build` (5), and takes `check_roots_test` down with it.

Two further items, smaller but real:

4. **`w deps` should not run the whole compiler.** It costs a full
   compile (14.8 s for `w.w`) because it *is* one — `deps_mode` just
   records each path as the compiler opens it
   (`compiler/compiler.w:83`). It only needs import lines, which is a
   tokenizer-level scan, linear in source size. This is what makes
   `bin/.wtest_deps_cache` "take several minutes" to populate, as
   `CLAUDE.md` warns.

5. **The type table is next.** `type_lookup` and friends are also
   linear scans (`compiler/type_table.w:347`, and eight more
   `type_lookup_*` variants), and they are only ~1% today because
   programs declare far fewer types than symbols. But `structs` is the
   steepest curve in §2 (3.57 per doubling), so this becomes the
   bottleneck once §3 is fixed. `type_lookup_pointer` also evaluates a
   `verbosity >= 1` test inside its scan loop.

## 7. Reproducing

The synthetic generators, the `fork`/`wait4` timing harness and the
`sym_lookup` instrumentation patch are not committed — they are ~120
lines of Python and a 20-line patch, all described precisely enough
above to rebuild. The profiles come from:

```sh
valgrind --tool=callgrind --callgrind-out-file=cg.out ./bin/wv3 --quiet w.w -o /tmp/o
callgrind_annotate cg.out
addr2line -f -e bin/wv3 <address>     # the compiler's own DWARF resolves it
```

Note the flag-order trap when scripting this: `w --quiet check f.w`
does not work. Selectors may precede a subcommand but option flags may
not, so `check` is taken as a filename and the run dies with
`no such file: 'check' in check:1`.

## 8. What shipped (2026-08-08)

Five commits, in the order they landed. Each was gated on `verify` and
measured with `bin/wbench`, which this work added.

| | self-compile | records visited |
| --- | --- | --- |
| before | 15,811 ms | 169,820,252 |
| stride hoisted out of the scan loop | 14,943 ms | unchanged |
| offset array + newest-first scan | 3,228 ms | 40,871,895 |
| name index | 1,060 ms | 82,901 |
| type table | **823 ms** | 82,922 |

**19.2× on the self-compile, and 2,048× fewer records visited.** The
quadratic is gone: 4× the symbols cost 9.3× the time before and 4.4×
now (net of the prelude floor).

Downstream, all measured on the same machine as §1:

| | before | after |
| --- | --- | --- |
| `./wbuild build` (5 self-compiles, cold) | 100.5 s | 36.7 s |
| `./wbuild tests -j 4` (cold) | 625 s | 151 s |
| `check_roots_test` (the §5 long pole) | 63.0 s | 5.3 s |
| `w deps w.w` | 14.8 s | 0.85 s |
| trivial 2-line program (the §4 floor) | 91 ms | 42 ms |

### How it works

The symbol table is still the same packed blob of variable-length
records — `t` offsets are stable handles threaded through backpatch
chains, GOT slots and debug bookkeeping, so the blob itself could not
move (`docs/projects/typed_containers.md:190-200` anticipated exactly
this constraint). What changed is that it now carries an index beside
it: an array of record offsets, a same-name chain, and a
`map[char*, int]` from name to newest live record.

The part worth remembering is that **scope exit needed no cooperation
from anything**. `table_pos` is only ever raised by `sym_declare`, and
all eleven other assignments restore a smaller saved value, so the index
can discard truncated records lazily on next use. Not one of the eleven
truncation sites in `grammar/` and `repl/` changed, and neither did any
of the direct table walkers.

Two hazards drove the design and are worth not re-discovering:

- `debugger/eval.w` retires a wdbg scratch binding by corrupting the
  first byte of its name *in place*, because the bindings cannot be
  popped (persistent definitions from the same entry live above them).
  A name-keyed index keeps resolving those names unless told not to, and
  popping such a record later would read a name that is now a lie and
  repair the wrong map entry. Hence `sym_index_unbind()` and the `-2`
  chain sentinel.
- That same path had a latent bug predating this work: after a REPL
  rollback the recorded offset can belong to an unrelated live symbol,
  and the old code corrupted it anyway. `sym_index_unbind()` now reports
  whether a live record really starts there, and the caller only writes
  the sentinel byte if so.

### Checking it

`verify` is the load-bearing gate — lookup results feed addresses, types
and backpatch chains straight into codegen, so byte-identical
wv3/wv4/wv5 means every lookup in a full self-compile resolved exactly
as before. It does not cover the REPL and debugger, so:

- `w --stats-selfcheck` computes every lookup both through the index and
  through a linear scan and aborts on disagreement. A self-compile under
  it is an exhaustive equivalence proof over all 87,255 lookups.
- The wdbg bind/unbind paths were diffed directly against a build from
  the previous commit — `p` at a stop, `repl` mode with a definition
  persisting above the bindings, and re-eval after both — byte-identical.

`w --stats` prints the counters. Records visited is deterministic for a
given input, so it is the figure to quote and the one a test can assert;
wall time is not.

## 9. Where the time goes now

Re-profiled after the above (callgrind, `w.w` self-compile). Total
instructions fell from 95,446,254,617 to **8,359,097,015** — 11.4×.
`sym_lookup` is no longer in the profile at all.

| share | function |
| --- | --- |
| 35.26% | `load_i` (`code_generator/integer.w:57`) |
| 7.59% | `strcmp` (`lib/lib.w:336`) |
| 6.68% | `__w_list_addr` (`structures/w_list.w:125`) |
| 5.08% | `peek` (`compiler/tokenizer.w:549`) |
| 4.09% | `getchar_checked` (`lib/lib.w:497`) |
| 3.39% | `type_lookup` (`compiler/type_table.w:349`) |

**`load_i` is the next thing to look at, and it is a big one.** It and
its counterpart `save_i` read and write integers a byte at a time in a
loop (`while (n > 0): result = (result << 8) + (p[n - 1] & 255)`), and
between them they are ~38% of the compiler. Every symbol-table field
access, every type-record slot, every code-emitter patch goes through
them. They are written that way to be byte-order- and width-portable
across five backends, so the fix is not free — either unrolling the
common widths, or exposing a native word load/store the codegen can emit
directly. Nothing here has attempted it; the 35% figure is the case for
looking. **Done — see §10**: the native-width route, −31.8% off the
whole self-compile.

Two things deliberately *not* done:

- **`w deps` was not rewritten as a tokenizer-level import scan**, which
  §6 item 4 proposed. It is expensive because it *is* a full compile, so
  the work above took it from 14.8 s to 0.85 s and the `bin/.wtest_deps_cache`
  pain it caused is gone. A standalone scanner would have to duplicate
  `__arch__` resolution, the upward directory search and its `argv[0]`
  fallback, two layers of import dedup, the compiler-internal root
  substitution rule, and the four *use-triggered* deferred runtime
  imports that the grammar decides — a second resolver that can silently
  diverge from the real one, for a benefit that has already evaporated.
- **`deps_dump`'s O(n²) dedupe was left alone.** The largest import
  closure in the tree is `w.w`'s own 154 paths, so it does ~12,000 short
  `strcmp`s — microseconds inside an 850 ms run. Changing it would be
  unmeasurable.

## 10. The integer accessors (2026-08-08)

§9 named `load_i` as the next thing to look at, at 35% of the profile.
This is what happened when it was looked at.

`code_generator/integer.w` serialized every integer a byte at a time:

```
int load_i(char* p, int n):
	int result = 0
	while (n > 0):
		result = (result << 8) + (p[n - 1] & 255)
		n = n - 1
	return result
```

Every symbol-table field, every type-record slot and every code-emitter
patch went through that loop and its `save_i` counterpart, so a 4-byte
field read cost a call plus four iterations of shift/mask/add. It is
now a single machine load:

```
int load_i(char* p, int n):
	if (n == __word_size__):
		return *cast(int*, p)
	if (n == 4):
		return *cast(uint32*, p)
	...
```

with the same treatment for the sized wrappers (`load_int32`,
`save_ptr`, and the rest), which now deref directly instead of
delegating down two more calls.

### Why this is allowed

The loops encoded three things, and only the first one was portability:

- **Byte order.** Every target is little-endian, so an n-byte field is
  by definition what a width-n machine load reads. The loop was not
  buying portability the language did not already have.
- **Extension.** The loop zero-extends (it builds the value up from
  zero), except `load_int32`, which explicitly sign-extended on a 64-bit
  host. The replacements match slot for slot: `int32*` where the loop
  sign-extended, `uint32*`/`uint16*`/`uint8*` where it did not.
- **Width.** A store must touch exactly n bytes and no neighbours —
  the symbol table packs 4-byte fields at offset 2 (see the record
  layout in `compiler/symbol_table.w`), so anything wider corrupts the
  next field. The sized pointer types store exactly their width.

Two widths keep the loop, and both matter on a 32-bit host: 3/5/6/7
have no machine type, and `save_int64` on a 32-bit host must sign-fill
the upper four bytes the way `v >> 8` did, which a 4-byte store would
not reproduce.

**Unaligned access is a hard requirement here, not an accident** — the
symbol table's fields start at offsets 2, 6, 10, ... x86, x64 and arm64
all take unaligned normal loads, and wasm treats the encoded alignment
as a hint rather than a constraint. `verify_wasm` is the interesting
gate for this: it self-compiles *under* the wasm engine, so a full
compile's worth of unaligned sized accesses runs there.

### Measured

Callgrind `Ir`, `bin/wv3 --strict w.w`, at commit `d50ccc0`, same
machine as §1. The two compilers differ only in `integer.w`.

| | before | after |
| --- | --- | --- |
| whole self-compile | 5,138,561,073 | **3,506,425,167** (−31.8%) |
| all of `integer.w` | 1,681,861,567 | 49,725,661 (−97.0%) |
| `load_i` | 1,396,499,377 | below threshold |
| `save_i` | 169,066,033 | 10,915,427 |
| `load_ptr` | 64,585,392 | 26,910,580 |

`bin/wbench`, best of 15:

| workload | before | after |
| --- | --- | --- |
| prelude | 19 ms | 18 ms |
| sym1000 | 36 ms | 27 ms |
| sym4000 | 86 ms | 70 ms |
| self | 404 ms | **294 ms** |

Symbol-lookup counters are unchanged in every workload, as they should
be — this touches no lookup logic.

(§9's absolute total, 8.36 G`Ir`, does not reproduce as the "before" of
this table; the pair above was taken as a matched before/after in one
sitting on one machine, which is the comparison that carries the claim.
The share it attributes to `load_i` does reproduce: 27.2% of the
before-total here, plus 3.3% for `save_i`.)

### Checking it

`verify`, `verify_x64` and `verify_wasm` all hold, which is the real
gate: every field these accessors read feeds addresses, types and
backpatch chains straight into codegen, so a byte-identical fixpoint
means every access in a full self-compile returned exactly what it used
to. `build_arm64`'s cross-compile step passes; its run step needs
`qemu-user-static`, absent on this box, so the arm64 fixpoint is
unverified here.

`tests/integer_accessor_test.w` is the unit-level guard: it keeps the
original byte loops as an oracle and checks all eight accessors against
them over 4,000 pseudo-random trials, at every width and at eight
offsets each, comparing whole 64-byte buffers so an over-wide store
fails as a neighbour mismatch rather than passing unnoticed.

### What is next

The accessors are no longer the top of the profile, but the *call* to
them is now most of what is left of them — `load_ptr` costs 26.9 M`Ir`
for a three-instruction body. Two follow-ups, in order of value:

1. **Index the record tables instead of calling an accessor.**
   `type_get_*` and friends spell a slot as
   `load_ptr(t + 218 * __word_size__)`. Written as
   `cast(int*, t)[218]` it is one scaled load with no call, and
   `type_table.w` has 169 such sites. Mechanical, and it also sidesteps
   the next item.
2. **Fold literal × literal.** `218 * __word_size__` is two constants
   and still emits a runtime `imul` (both operands materialized and
   pushed), because there is no constant folding — a general win beyond
   these tables, and squarely `optimization.md`'s v0 territory.

**Both done — see §11 and §12.** Item 1's proposed spelling turned out
not to parse, and a struct beat it anyway.

## 11. The record tables (2026-08-08)

§10's item 1, with one correction to its premise: **`cast(int*, t)[218]`
does not parse.** `cast` is handled in `grammar/unary_expression.w` and
returns without entering `postfix_expr`'s `[` suffix loop, so a cast
result takes no postfix suffix. Making it parse would be new syntax, and
`type_table.w` is compiled by the pinned seed, so it could not use it
until a `SEEDS` bump anyway.

A struct is the better answer regardless. Member access emits
`add_eax_int32(type_get_field_offset(...))` — one add against a constant
offset — where indexing would still emit a `mov` for the index and an
`imul` for the scale, and would therefore *depend on* §12 to become
optimal. Measured on this checkout, instructions to read one slot:

| form | caller | call | total |
| --- | --- | --- | --- |
| `load_ptr(t + 5*ws + 2*ws*i)` (was) | 24 | +6 | ~31 |
| `r.field_types[i]` | 22 | — | **22** |
| `load_ptr(t + 205*ws)` (was) | ~15 | +6 | ~21 |
| `r.kind` | 4 | — | **4** |

So the record is `struct type_rec` now, with **array fields for the two
runtime-strided regions** rather than a hand-indexed tail. The array
field wins including its bounds check (~9 of those 22 instructions), and
the bounds check is a correctness gain — a bad field index read garbage
before. An earlier draft of this work rejected array fields on a guessed
cost; the measurement said otherwise, which is the only reason the
numbers above are in this doc.

`type_alloc` uses `new` rather than `malloc`, because only `new`
initializes the array descriptors — and those descriptors point into the
record itself, which is also why a record must never be byte-copied or
stored in a `list[type_rec]`. `type_size()` is gone: the compiler
computes the size instead of a constant duplicating the declaration.

Two latent word-size bugs fell out of the sweep, both hand-computed
offsets that were correct only on a 32-bit host: `debugger/locals.w`
spelled the field-name slot `load_int(t + 16 + 8 * i)` (right at 4-byte
words, wrong at 8), and `type_table_test.w` read `num_fields` as
`load_int(t + 4)`. Both go through the accessors now.

### Measured

Callgrind `Ir`, `--quiet w.w`, matched input — both compilers given the
*same* source tree, which matters once a change alters the compiler's own
line count:

| | before | after |
| --- | --- | --- |
| whole self-compile | 3,524,504,479 | **3,440,550,863** (−2.38%) |
| `load_ptr` | 27,468,280 | 914,790 (−96.7%) |
| `type_get_alias_target` | 115,232,670 | 93,283,590 |
| `type_lookup_pointer` | 77,672,508 | 61,920,680 |
| `type_get_const_target` | 47,667,249 | 38,587,773 |
| `type_get_kind` | 24,188,010 | 18,910,626 |

The largest *increase* is `type_alloc`, 0 → 1.2 M, which is `new`
zeroing the record where `malloc` did not.

`bin/wbench` self, interleaved best-of-7 over three rounds: 309/307/305
ms before, 311/308/306 after — flat. The instructions removed were the
cheap ones (a call, a `ret`, an `imul` on constants), which is worth
stating plainly rather than quoting a wall-clock win that is not there.
A first non-interleaved pair read 299 → 316 ms and was pure noise.

## 12. Constant folding (2026-08-08)

§10's item 2. The mechanism is the one already shipped for
comparison-branch fusion (`optimization.md` §1.3): a note of
`(start, end, value)`, valid only while nothing has been emitted since
(`note_end == codepos`), consumed by rolling `codepos` back and
re-emitting.

`mov_eax_int` sets the note; `push_eax` carries it across a push;
`pop_ebx` arms a two-operand fold when the pushed constant and the
accumulator constant are adjacent; the ALU op consumes it.
`imul_eax_int32` and `add_eax_int32` fold their own immediate straight
into a current note, which is what collapses a constant array index and
its scale into a single `mov`.

**Only `mov_eax_int` sets the note, and that is the safety argument.**
The other producer of a `mov $imm32,%eax` is `be_addr_slot_emit`, whose
immediate is a backpatch slot rewritten later — and it emits its own
bytes without coming through here. Everything else is fail-closed: any
emission the fold did not expect advances `codepos` and the `==` check
stops matching. `be_imm_note_reset()` joins `be_cmp_note_reset()` at all
five sites where `codepos` moves backward.

A fold that overflows the compiler's own word is declined, because the
constant must come out the same whether this compiler is the 32-bit or
the 64-bit self-host or `verify` and `verify_x64` stop agreeing. `-1`
operands are declined rather than probed: the division check would have
to evaluate `INT_MIN / -1`, which traps on x86 rather than wrapping.

### Measured

**Matched input is not optional here.** Comparing each compiler against
its own tree charges this change for its own ~120 lines of new source and
reports roughly ten times its real cost (+0.26% instead of +0.045%) — the
extra source is more tokens, so `peek`, `strcmp` and `getchar_checked`
all rise about 0.25% while their machine code is byte-identical.

| | before | after |
| --- | --- | --- |
| compile cost (same `w.w`) | 3,440,698,982 | 3,442,231,944 (+0.045%) |
| `repl.w` emitted instructions | 436,927 | 436,001 (−0.21%) |
| `tools/wexec.w` emitted instructions | 163,494 | 162,837 (−0.40%) |
| `imul` with immediate in `bin/wv3` | 2,206 | 2,131 |

The compiler pays about a twentieth of a percent to take a fifth to two
fifths of a percent of the instructions out of everything it emits, once,
for every later run of that program.

Note the ordering interaction: §11 removed essentially every
`N * __word_size__` from the compiler's own source, so the `alu_imul`
fold no longer fires much on `w.w` itself. Most of what it now earns
comes from `imul_eax_int32` folding constant index scales — which is the
shape §11 introduced.

### Checking it

`verify`, `verify_x64` and `verify_wasm` hold for both sections.
`tests/const_fold_test.w` pins the fold behaviorally, in the shape of
`tests/comparison_branch_test.w`: every folded operator, `__word_size__`
operands, negative and `-1` operands, constant array and word-strided
pointer indices, products that overflow 32 bits (which must decline and
let the runtime instruction define the answer), and side-effect
preservation. **It passes identically under the pinned seed, which has
no folding at all** — an unfolded oracle for every assertion in it.

### What is next

- **`alu_add`/`alu_sub`/`alu_and`/`alu_or`/`alu_xor` are folded too**,
  but division and modulo are not: they pop their own operand rather
  than going through `pop_ebx`, so arming them needs a second protocol.
  Low value, non-zero risk.
- **The fold is x86-family only**, like `cmp_fuse`. arm64 and wasm
  materialize constants through variable-length or stateful sequences
  that a byte rollback would not undo cleanly. arm64 is the one worth
  revisiting: its constant materialization is up to four instructions.
- **The other word-strided tables are untouched** — `grammar/generic.w`
  (68 sites), `compiler/compiler.w` (24),
  `grammar/import_statement.w` (12), `structures/hash_table.w` (10),
  `code_generator/dwarf.w` (7). All are flat `char**` vectors rather
  than fixed-slot records, so they want a different treatment than §11's.
  `compiler/symbol_table.w` is deliberately excluded: its fields are
  4-byte packed at odd offsets, and word-scaled access would silently
  widen them on the 64-bit targets.
- **The 100-field cap** (`assert1(num_fields < max_fields)`) is still
  there, and still exists only because the field region is a fixed-size
  inline array — every type, including `int`, pays the whole record. A
  growable field vector would lift the cap and shrink the average
  record, but it changes allocation on a hot path and wants its own
  measurement.
