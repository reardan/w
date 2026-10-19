# Self-compile instruction growth since the program-benchmark baseline (#714)

Issue #714 reported that the `self` rows of `./wbuild bench_compare` fail the
committed `tests/bench/baseline.txt`, while the application rows pass. This
note reconciles the old baseline with measured main behavior and attributes
the growth to merged work. It does not refresh the baseline. The final
section explains why.

## What the `self` row measures

`tools/wbench.w` (`prog_run_self`) runs `bin/wv2 --quiet w.w -o <out>` for
x86 and `bin/wv2_64 x64 --quiet w.w -o <out>` for x64 under
`valgrind --tool=callgrind`, and records the total Ir divided by 1,000 (kIr).

- The x86 compiler, `bin/wv2`, is built by the pinned seed (`./w w.w`). Its
  code generation therefore depends only on the seed, which has been
  `v0.3.0` since 2026-09-25 (`SEEDS`). The x86 figure measures how much
  work the compiler's source does on its own input. Optimizer improvements
  merged since the baseline do not affect it.
- The x64 compiler, `bin/wv2_64`, is built by `bin/wv2`. Its figure also
  reflects code-generation changes.
- In both rows, the input (`w.w` and its import closure) changes with
  every commit.

The committed baseline dates from c23aeb57 (#588, 2026-10-09). It records
10,904,885 kIr / 2,570,964 bytes on x86 and 6,112,144 kIr / 2,966,952 bytes
on x64.

## Method

The commits measured are all on main's first-parent history, from c23aeb57
to 713439ae (2026-10-18, 112 merges). Each commit is unpacked into a
directory whose name has a fixed length. The x86 compiler for that commit is
built with the v0.3.0 seed, as `./wbuild wv2` does. The x64 compiler is built
by that x86 compiler, as `build_x64` does. The `self` command is then run
under callgrind 3.22.0. Commits before the shallow clone's graft point
(ec4f54c8) come from GitHub source tarballs. Instruction counts are
deterministic for a fixed binary, input and path; repeated runs of the same
binary agreed exactly. Per-function costs are callgrind self costs, with
addresses resolved through `nm` as `wbench` resolves them. Closure size is
`bin/wv2 deps w.w` piped to `wc -l`.

### The checkout path is part of the workload

The same commit gives different counts in different directories:

| Commit | Checkout path length | x86 kIr |
| --- | ---: | ---: |
| c23aeb57 | 40-character directory name | 11,518,774 |
| c23aeb57 | 10-character directory name | 11,309,728 (-1.8%) |
| 713439ae | worktree root (~58 characters) | 17,948,750 |
| 713439ae | trees directory (~90 characters) | 18,243,590 (+1.6%) |

Each extra character in the checkout path costs about 0.06% of the x86
total. Output bytes also change, because DWARF stores absolute paths. The
main cause is `debug_line_file_index_of` (`code_generator/dwarf.w`), which
runs on every statement's line row. Its fast path `strcmp`s the full
absolute source path against the previous file's path. When the paths are
equal, the comparison scans the whole path. On main this one caller
accounts for 759M of the 1.87G Ir spent in `strcmp`, about 4% of the
self-compile.

The old baseline and the issue's figures were measured on other hosts, so
none of these absolute numbers are directly comparable. Ratios between
commits measured at one fixed path are comparable. Measured that way:

- The baseline commit gives 11,309,728 kIr here. The committed 10,904,885 is
  3.6% lower.
- 792fefbb gives 17,693,330 kIr here. The issue reports 17,142,654, which is
  3.1% lower.

Both external figures sit about 3% below this host's. This is consistent with
a shorter checkout path, and with a valid baseline for its own commit. The
gap therefore comes from growth on main, not from a broken or mis-recorded
baseline.

## Attribution (x86, one fixed path)

Each row covers the interval from the previous row's commit to the named
commit. "Single" marks an interval containing exactly one first-parent
merge.

| To commit | Interval contains | kIr | Δ kIr | Δ % | Closure lines Δ % | Share of total growth |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| c23aeb57 | baseline (#588) | 11,309,728 | | | 85,651 | |
| 1bc8a212 | #605–#618, incl. AST storage/deferred trees (#618) | 11,525,364 | +215,636 | +1.9% | +1.0% | 3.1% |
| 731f0919 | #619–#639 (browser foundations, x64 libraries, REPL shell, tile/GPU retained AST) | 12,175,871 | +650,507 | +5.6% | +3.5% | 9.4% |
| 58942dbf | #640–#643 | 12,167,719 | −8,152 | −0.1% | 0.0% | −0.1% |
| a192dbab | single: optimizer — folding, wider promotion, default inlining, x64 register args, ivopts (#649) | 12,984,082 | +816,363 | +6.7% | +4.0% | 11.8% |
| a5a54fd7 | #646, #647, #650 | 13,035,588 | +51,506 | +0.4% | +0.2% | 0.7% |
| **6e6dd36b** | **single: `--safe` ownership checks (#648)** | **16,851,538** | **+3,815,950** | **+29.3%** | **+1.2%** | **55.0%** |
| 95e7b79c | #652, #653, #645, #654–#663 (incl. reference returns #663) | 16,906,602 | +55,064 | +0.3% | +0.3% | 0.8% |
| 298246c6 | #665–#675, incl. named lifetimes/aggregates/storage (#674) | 17,420,312 | +513,710 | +3.0% | +1.4% | 7.4% |
| e8c14170 | #676–#681, incl. checked borrows/control flow/storage/win64 (#681) | 17,640,032 | +219,720 | +1.3% | +0.7% | 3.2% |
| 792fefbb | #702–#705 (outlives contracts) | 17,693,330 | +53,298 | +0.3% | +0.1% | 0.8% |
| f5254be7 | #707, #711, #759, quantified callable contracts (#709) | 18,452,088 | +758,758 | +4.3% | +0.2% | 10.9% |
| 34b09fac | #763, #708, callable fast path (#761) | 17,775,970 | −676,118 | −3.7% | +0.1% | −9.8% |
| 89fcead9 | #760, #765–#774, #715, #727, #764, retained-position cache (#781) | 17,950,422 | +174,452 | +1.0% | +1.2% | 2.5% |
| 713439ae | #775–#780, #782–#788 | 18,243,590 | +293,168 | +1.6% | +0.5% | 4.2% |
| **Total** | | | **+6,933,862** | **+61.3%** | **+15.2%** | 100% |

The x64 row follows the same shape at the measured points:

| Commit | x64 kIr | Δ % from previous point |
| --- | ---: | ---: |
| c23aeb57 | 6,216,979 | |
| 1bc8a212 | 6,323,684 | +1.7% |
| 58942dbf | 6,691,399 | +5.8% |
| a5a54fd7 | 7,239,508 | +8.2% (includes #649) |
| 6e6dd36b (#648) | 8,925,207 | **+23.3%** |
| 792fefbb | 9,351,029 | +4.8% |
| 713439ae | 9,638,551 | +3.1% |
| Total | | +55.0% |

### Where the instructions went

- **#648 accounts for 55% of the x86 growth and 49% of the x64 growth.** It
  adds 3.82G Ir on x86 while the closure grows by only 1.2%. The cost is
  the application semantic retention that ordinary compilation now
  performs; `safe_mode.md` "Measured costs" already reported it as about 24%
  more wall time. New functions account for about 1.0G Ir:
  - `retained_words_differ` 239M
  - `retained_binding_note` 130M
  - `retained_expression_semantics` 121M
  - `retained_emit_semantic_check` 108M
  - `retained_type_note` 77M
  - `retained_type_matches` 72M
  - `retained_key_int` 30M

  The rest is added load on shared helpers:
  - `strcmp`: +643M, of which `retained_intern` +332M, `type_lookup_pointer` +128M, `retained_type_matches` +99M and `retained_binding_is` +52M
  - `retained_intern_hash`: +264M
  - `__w_list_addr`: +272M
  - `__w_hash_sip`: +189M
  - allocator: about +260M (`malloc_size_bin`, `freelist_malloc`, `malloc_low_bit`)

  The two follow-ups meant to reduce this cost recover little. #761 removed
  about 0.68G in its interval, offsetting most of #709's increase. #781
  saved about 0.4%.
- **Checked-contract features after #648** (#663, #674, #681, #702–#705, #709,
  #760–#788) add a net 1.4G, about 20% of the growth. Most of it is the
  #709 interval, offset by #761. These features add types and records that
  the retained checks visit. `type_lookup_pointer`, a linear name-compare
  scan, grows from 194M Ir at the baseline to 432M Ir on main.
- **Input growth and other compiler work** (#605–#647, #649, #650) account
  for 1.7G, about 25%. Over the whole range the compiler's own closure
  grows from 85,651 to 98,700 lines (+15.2%) and from 224 to 254 files. The
  cost grows faster than the line count because symbol and type lookups
  scale with table size. One example: the #649 optimizer merge adds +6.7%
  Ir for +4.0% lines, spread across tokenizer, hash, type-table and
  peephole functions rather than any single new pass.

## Is a baseline refresh justified?

The explanation is complete in one sense. Every first-parent interval
between the baseline and main is measured, the two largest steps are
single merges, and the external figures agree with these measurements up
to a constant path offset. The growth is real and attributable. It is not
measurement noise or a broken baseline.

This work does **not** refresh `tests/bench/baseline.txt`, for two reasons:

1. **Accepting the #648 cost is a project decision.** That cost is 55% of
   the growth. #714 lists "reduce default-compilation retention cost" as
   done after #781, yet the retention still costs about 29% of x86
   self-compile Ir. Refreshing the baseline now would make the gate accept
   that cost silently. Whoever refreshes should state, in the same commit,
   that the cost is accepted. The alternative is to fund further retention
   work first. The largest new hotspots are listed above.
2. **The kIr figure depends on the checkout path**, at about 0.06% per path
   character. A baseline generated in this sandbox's long worktree path would
   be about 2–4% higher than one generated on CI. It would then let a
   comparable regression pass on CI. A refresh should run `./wbuild bench`
   from the same short checkout path CI uses, or after the fix below. It
   must also copy all rows: the application rows still pass and should
   change only if their measurements change.

Recommended follow-ups, none of which are in this change:

- Make the self-compile kIr independent of the checkout path. Compare
  pointers before `strcmp` in `debug_line_file_index_of`, which helps when
  callers pass the same path string for consecutive statements (not
  verified here). Alternatively, intern or hash file names once per file.
  Either could remove up to the 4% of self-compile Ir spent there.
- Replace the linear `type_lookup_pointer` scan, now 432M Ir and growing
  with every checked type, with a keyed lookup.
- Then refresh both `self` rows together, from a short path, with this
  table cited in the commit message.
