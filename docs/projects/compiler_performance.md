# Compiler performance: where self-compile time actually goes

Status: measurement report, 2026-08-08. Companion to
`docs/projects/optimization.md`, which is about making the *emitted*
code faster; this one is about making the *compiler* faster. Nothing
here is implemented — it is the measurement and the case for a fix.

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
