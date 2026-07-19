# Optimization: v0 (generated-code peephole) vs. v2 (AST passes) — an assessment for #110

Status: design assessment only, 2026-07-19. No code changes ship with this
file. Answers issue #110 verbatim: "Optimization pass - either from the
generated code (v0), or additional passes of the AST (v2)." Companion to
`docs/projects/compilation_model.md` (#338/#337 — the AST/artifact
assessment whose "no AST, no IR" grounding is shared here) and
`docs/projects/wbuildd.md` (#231 — the AST options (a)/(b)/(c) reused
in §4 rather than re-derived) and `docs/projects/parser_generator.md`
(the PG's AST/streaming modes — the only materialized tree in this tree
today).

## 0. Summary

Every measurement below was taken on this checkout, this machine,
2026-07-19, after `git fetch origin
claude/sonnet-subagent-task-list-u9hi5v && git reset --hard FETCH_HEAD`
(program-branch tip `11ef109`).

- The single-pass, no-AST, no-IR emission model
  (`code_generator/x86.w`, fused with `grammar/*.w`) produces real,
  large, mechanically regular redundancy. §1 disassembles and quantifies
  three classes; the biggest — a dead address-materializing `mov`
  before every local/parameter reference — is **~7-8% of the static
  instruction count and byte size of the self-hosted compiler binary
  itself**, on both x86 and x64.
- Runtime cost is real but workload-dependent (§2): a synthetic
  compute-bound benchmark spent ~100% of wall time in generated code; a
  synthetic I/O-bound benchmark spent >23x more wall time in the kernel
  than in generated code. Codegen quality cannot matter when a
  workload's time is spent inside `write(2)`.
- **v0** (a peephole/dead-store pass over emitted bytes) is concretely
  actionable now, entirely below `./wbuild verify`'s self-host fixpoint
  — exactly as verifiable as any other compiler change — and the
  biggest single finding (§1.1) is small enough that it may not even
  need a generic "peephole pass," just a one-line conditional at its
  one emission call site (§3).
- **v2** (AST-based passes) is not a new question: it presupposes the
  same AST-existence decision `wbuildd.md` (#231) and
  `compilation_model.md` (#337) already assessed, and inherits their
  conclusions unchanged (§4) — no AST exists in the production
  compiler; the ParserGenerator's tree has shape but no semantics; a
  real AST is gated on a maintainer decision this doc cannot make and
  that has nothing specifically to do with optimization.
- **Recommendation** (§6): schedule a small, bounded v0 fix for §1.1 as
  the natural first PR; treat §1.3/§1.2 as follow-ups once a
  whole-function post-pass mechanism is proven safe. Do not schedule v2
  until the maintainer answers #231/#338's AST questions.

## 1. What the emitted code looks like today

`code_generator/x86.w` is the emission layer `grammar/*.w` calls
directly while parsing (CLAUDE.md: "grammar rules ... fuse parsing and
code emission, writing machine-code bytes through
`code_generator/x86.w`"): a one-register accumulator convention
(`eax`/`rax` is "the current value", `ebx`/`rbx` the binary-operator
scratch register), a software evaluation stack
(`push_eax`/`pop_ebx` — real `push`/`pop` on x86/x64, an `x28`-based
soft stack on arm64), local/parameter access through
`[esp+offset]`-relative loads. Every helper dispatches on `target_isa`
to its arm64/wasm/PTX twin, so the redundancies below are backend-wide.

Method: `./bin/wv2 <file>.w -o <out>`, then `objdump -d -Mintel <out>`.
Three findings, smallest-and-clearest first.

### 1.1 A dead address-materializing `mov` before every local/parameter read

`compiler/symbol_table.w`'s `sym_get_value` (resolves every identifier
reference) does this unconditionally, before it knows what kind of
symbol it has:

```
	be_addr_slot_emit() /* mov $n,%eax (x86) / adrp+add pair (arm64) */
	be_addr_slot_write(codepos - 4, load_int(table + t + 2))
	...
	/* local variable */          else if (scope_type == 'L'): ...
	if ((scope_type == 'L') || (scope_type == 'A')):
		be_lea_acc_wstack(k)   # lea (n)(%esp),%eax — overwrites eax
```

`be_addr_slot_emit()` (`code_generator/arm64.w:359`, x86 fallthrough)
always emits a full `mov eax, imm32` (5 bytes) — needed so *global*
references can carry a backpatchable address. For a local/argument
(`'L'`/`'A'`), three lines later the code unconditionally overwrites
`eax` via `be_lea_acc_wstack` before `eax` is ever read. Minimal repro
(`int identity(int a): return a`):

```
08062299 <identity>:
 8062299:	b8 01 00 00 00       	mov    eax,0x1        # dead: symbol table slot index
 806229e:	8d 84 24 04 00 00 00 	lea    eax,[esp+0x4]  # overwrites eax with the real address
 80622a5:	8b 00                	mov    eax,DWORD PTR [eax]
```

A second parameter (`int second(int a, int b): return b`) confirms the
dead immediate tracks the table slot (it becomes `0x2`), not a fixed
constant.

**Not a one-off.** Disassembling the self-hosted compiler (`bin/wv2`,
built by this doc's own `./wbuild build`) and counting every `lea
eax,[esp+...]` immediately preceded by `mov eax,0x...` with nothing
between:

| Target | Instructions | Dead `mov`+`lea` pairs | `lea` sites total | Overlap | Bytes wasted | Binary size | Byte share |
|---|---|---|---|---|---|---|---|
| x86 (`bin/wv2`) | 401,665 | 27,980 | 28,082 | 99.6% | 139,900 | 1,686,734 | 8.29% |
| x64 (`w.w` in x64 mode) | 465,663 | 28,024 | 28,038 | 99.95% | 140,120 | 1,959,787 | 7.15% |

(`objdump -d -Mintel bin/wv2 \| awk '/mov *eax,0x/{p=1;next}
{if(p&&/lea *eax,\[esp/)c++;p=0} END{print c}'`; x64 substitutes
`rsp`/`rax` — the address-slot `mov` itself stays the 32-bit `mov
eax,...` form on x64 too, per `code_generator/arm64.w`'s "on the x86
family the slot is a plain imm32 cell" note.) The 99.6%/99.95% overlap
shows this isn't adjacent-instruction noise — it's essentially the
entire population of local/argument address computations, both word
sizes: **8.3% of `bin/wv2`'s bytes are this one dead store.**

Why a blind "delete `mov eax,imm` right before `lea eax,[esp+...]`"
rule is safe: `sym_get_value` only emits `be_addr_slot_emit()`
immediately followed by `be_lea_acc_wstack()` in the L/A branch — the
D/U (global) branches never call `be_lea_acc_wstack` at all (confirmed
disassembling a global function reference: `mov eax,0x80624ef; push
eax` — the mov's value is read by the very next instruction, so it's
live, and no `lea eax` ever follows it there). "An unconditional
`eax`-write with no read before the next `eax`-write is dead" needs no
data-flow analysis here, since writer and non-reader are always emitted
back-to-back by the same call site.

### 1.2 Push/pop shuttling for binary-operator operands

`grammar/binary_op.w`'s `binary1`/`binary2_finish_pop` protocol (used
by every arithmetic/relational/bitwise binary operator) pushes the left
operand, evaluates the right operand into `eax`, pops the left operand
into `ebx`, then applies the ALU op. For `int add3(int a,int b,int c):
return a+b+c` (§1.1's dead movs kept in for realism):

```
 80622a7:	50                   	push   eax              # left operand (a) pushed
 ...
 80622b4:	8b 00                	mov    eax,DWORD PTR [eax]   # right operand (b) in eax
 80622b6:	5b                   	pop    ebx              # left operand popped back
 80622b7:	01 d8                	add    eax,ebx
```

Every `push`/`pop` pair round-trips a value through memory the compiler
already knows isn't live anywhere else — the single-pass emitter, when
it emits the `push`, cannot yet know whether the right operand's own
code will need that stack slot for something else (a nested call, a
nested binary op); in the simple case it never does. Aggregate in
`bin/wv2`: 66,796 `push eax` sites, 20,909 `pop ebx` sites — `push eax`
is dominated by legitimate ABI call-argument marshaling (which must not
be touched), so this isn't a clean measure of just this redundancy the
way §1.1's count is; it shows the idiom's volume, relevant to §3's
peephole-*reach* discussion. (`docs/projects/cuda.md`'s PTX backend
design independently proposes mirroring this exact accumulator/push
pattern for the GPU target and says outright it "produces slow [code],
but the driver JIT's optimizer will clean up some of it" — the same
redundancy, a different target, and an explicit decision to let an
*external* optimizer absorb it; the host backends have no such
downstream stage, so whatever they emit is what runs.)

### 1.3 Always-materialized boolean comparisons

`<`,`>`,`<=`,`>=`,`==`,`!=` lower to `alu_cmp_set`
(`code_generator/x86.w`): `cmp eax,ebx; setCC al; movzx eax,al`,
materializing a 0/1 value. Every `if`/`while` then calls
`be_br_zero`/`be_br_nonzero`, emitting `test eax,eax; je/jne <target>`
— re-deriving from the materialized value exactly the zero/nonzero fact
the `cmp` two instructions earlier already put in the flags register.
`int pick(int a,int b): if (a<b): return a` / `return b`:

```
 80622b7:	39 c3                	cmp    ebx,eax
 80622b9:	0f 9c c0             	setl   al
 80622bc:	0f b6 c0             	movzx  eax,al
 80622bf:	85 c0                	test   eax,eax
 80622c1:	0f 84 20 00 00 00    	je     80622e7 <pick+0x4e>
```

Five instructions (`cmp`,`setl`,`movzx`,`test`,`je`) where two
(`cmp`,`jge`) suffice, on every `if`/`while` whose condition is a bare
comparison. `bin/wv2` has 8,526 `setCC al` sites and 9,014 `test
eax,eax` sites.

## 2. Measuring where time goes

Wall-clock (`time`), this machine, single run unless noted.

### 2.1 Self-compile stages (`./wbuild verify`'s build path)

```
wv2 --strict w.w -> wv3:  9.131s real (9.118s user, 0.012s sys)
wv3 --strict w.w -> wv4:  9.113s real (9.084s user, 0.028s sys)
wv4 --strict w.w -> wv5:  8.535s real (8.506s user, 0.028s sys)
./wbuild verify (full, from clean bin/wv3-5): 27.892s real, 27.810s user
```

Essentially 100% user time every stage. This is markedly slower than
the ~4.6s self-compile CLAUDE.md/`build_system_next.md` cite and the
~7.1s `w check`/`deps` `wbuildd.md` measured 2026-07-16 — consistent
with `wbuildd.md`'s own caveat that its numbers "plausibly reflect
sandbox/host variance," stated here as this session's number rather
than reconciled. What both agree on: self-compile is single-pass and
CPU-bound, so §1's static redundancies translate fairly directly into
wall-clock cost here — every dead `mov` executes four times over across
the bootstrap chain (seed→wv2→wv3→wv4→wv5).

### 2.2 Compute-bound vs. I/O-bound representative binaries

Two throwaway benchmarks (scratchpad-only, not committed), built with
this checkout's `bin/wv2`:

- **Compute-heavy**: 2,000,000 calls to `sha256()` (`lib/sha256.w`)
  over a fixed 64-byte buffer — the same `sha256_rotr`/`sha256_block`
  functions disassembled in §1.3. **29.891s real, 29.879s user, 0.000s
  sys.** All wall time is generated code executing arithmetic — exactly
  where §1's redundancies cost real cycles, instruction for
  instruction.
- **I/O-heavy**: 200,000 iterations of `file_write_text()`
  (`lib/file.w`) rewriting a one-byte file (open+write+close per
  iteration). **17.217s real, 0.485s user, 11.354s sys.** `sys` is
  >23x `user`; the remainder (~5.4s) is scheduling/wait, not generated
  code. No amount of peephole or AST optimization touches `sys` time.

Codegen quality is a real lever for compute-bound W programs (the
compiler's own self-compile, hash/compression workloads, tight loops)
and irrelevant for I/O-bound ones (most CLI tools, `wexec`/`wbuild`
itself outside its self-compile step) — worth stating before scoping
any optimization work, so effort lands where it can move something.

### 2.3 The compile-speed-is-a-feature constraint

§2.1's ~9s/stage is a single-pass, no-caching, tokenize-and-emit walk
over the whole compiler on every stage — and that single-pass property
is *why* it's this fast at all. A multi-pass AST front end doing type
inference, building an IR, and running optimization passes would
almost certainly cost more wall-clock time per compile than it could
save in generated-code execution for any but the most extreme
compute-bound programs, and would slow every leaf compile too (`w check
tests/hello.w`: 0.054-0.056s per `wbuildd.md` §1). Compile speed is a
feature of this project, and an optimization pass that meaningfully
slows `./wbuild build` or `w check` is not free just because the
*output* runs faster.

## 3. v0: peephole over generated code

**Architecturally available**: no IR, no AST — `code_generator/x86.w`'s
helpers write bytes directly into the output buffer at `codepos`
(`compilation_model.md` §1's "no intermediate representation to
serialize, cache, or hand to another tool" applies unmodified). Two
places a peephole could live:

1. **A fixed small window over just-emitted bytes**, inside the emit
   helpers (e.g., inside `be_lea_acc_wstack`/`be_addr_slot_emit`: "does
   the last N bytes match this pattern; if so, roll `codepos` back").
   Natural home for §1.1: the dead `mov` and the overwriting `lea` are
   always emitted by the same function, a few lines apart, nothing else
   in between — no scan, no risk of crossing a branch target or a
   backpatch site. **This specific fix may not even need a "peephole
   pass"** — a direct conditional at `sym_get_value` (only call
   `be_addr_slot_emit()` for `'D'`/`'U'`) removes it with no new
   machinery. Whether that counts as "v0" or "a bug fix" is semantic;
   either way it's informative about how much of v0's win doesn't need
   a generalized framework.
2. **A whole-function post-pass over the buffer**, before backpatching
   resolves branch targets — needed for §1.2/§1.3, since both require
   recognizing a *paired* pattern that may have other emitted code
   between the halves. Real but scoped (walk the just-completed
   function's byte range once, match a short list of instruction-pair
   templates) — must run before `be_ctrl_end`'s patch-chain resolution
   and before any REPL/wdbg `codepos` bookmark assumes those bytes are
   final, which needs its own audit of every `codepos`-capturing call
   site (not attempted here) before implementation, not just design.

**What it removes, and estimated effort/win, per class**:

- §1.1 (dead mov) — removable by either mechanism above, no data-flow
  analysis needed. Small effort (one function or one shared helper).
  ~7-8% fewer static instructions/bytes tree-wide, by construction —
  but the *dynamic* win is smaller than the static share suggests: a
  register-only `mov eax,imm32` with an immediately-discarded result is
  exactly what out-of-order cores absorb cheaply via renaming. The
  durable win is code size (icache pressure — `bin/wv2`'s 8.3%
  disk-size share is a hard fact independent of microarchitecture), and
  larger on arm64, where the equivalent `adrp+add` pair is 8 bytes, not
  5. Highest confidence, smallest blast radius, single small PR.
- §1.3 (materialized comparisons) — needs the whole-function pass:
  replace `cmp;setCC;movzx;test;jcc` with `cmp;jcc'` (inverted
  condition, a mechanical ≤16-entry table) whenever nothing else uses
  `eax` between the `setCC` and the `test`; a stored comparison (`bool
  x = a<b`) or one combined with `&&`/`||` is correctly left alone.
  Small-to-medium effort once the post-pass plumbing exists; wins 2-3
  instructions on every bare-comparison `if`/`while` (8,526 sites in
  `bin/wv2`), landing in branch-heavy code — the hottest code in the
  compiler's own self-compile.
- §1.2 (push/pop) — only removable where nothing between `push` and
  its matching `pop` could itself push/pop (no nested calls or
  constructors); replace with `mov ebx,eax` when provably safe —
  `emitted_call_count` (already tracked globally, per `x86.w`'s
  `operand_is_pure` comment) gives a cheap "was there a call in this
  span" check. Medium effort, highest risk of the three, hardest to
  bound the win in advance; reasonable as a third PR once the post-pass
  mechanism is proven on §1.3, not attempted first.

Staged: §1.1 is a single small PR (**HIGH** care, touches
`compiler/`/`code_generator/`, merges last & alone, gated on
`verify`+`verify_x64`); §1.3 rides the post-pass plumbing next; §1.2
follows once that plumbing holds up. None require touching
`grammar/*.w`'s parsing logic — all three live in `code_generator/x86.w`
and its arm64/wasm/PTX twins.

**The verify-fixpoint implication**: `./wbuild verify`'s wv3==wv4==wv5
equality (CLAUDE.md's "REQUIRED gate for any compiler change") is a
built-in, byte-exact acceptance test for a peephole essentially for
free — it lives in `code_generator/x86.w`, inside `w.w`'s seed-graph
closure, so it participates in the existing fixpoint unchanged. A bug
that makes codegen non-deterministic, or that isn't preserved
identically across the four self-compile generations, fails loudly the
same way any other codegen regression does (`verify_x64` gives the same
guarantee for the word-size-sensitive twins in §1's table). What
`verify` does *not* give: proof the transformed *behavior* is unchanged
for programs other than the compiler itself — its fixpoint only
exercises redundancies the compiler's own source happens to trigger.
The existing fixture/test corpus (`warning_test`, `type_system_*_test`,
`tests/asm_*`) is the mitigation, same as for any codegen change.

## 4. v2: AST passes — inherits #231/#337's answers, doesn't reopen them

#110's v2 half presupposes an AST exists to pass over — precisely what
`wbuildd.md` §3 (#231) and `compilation_model.md` §3 (#337) already
assessed, independent of optimization. Restated against this ask:

- **(a) Cache below the AST** (`wbuildd.md` §3.1) — never builds a
  tree; nothing to run an optimization pass over. Not applicable.
- **(b) The ParserGenerator's `pg_ast_node` tree** — the only tree that
  exists today, exercised by `parser_generator_w_test` over every
  tracked `.w` file, milestone 4's actions/predicates having just
  landed. Both companion docs already say why it's the wrong substrate
  for anything semantic — "`w.pg` is still explicitly a *syntax-shaped*
  validator, not a semantic one," no type table, no
  declaration-before-use resolution. Milestone 4 makes it a **credible
  substrate for a leaf-tool measurement experiment**: a small `mode
  streaming` grammar with actions counting §1.1-shaped patterns in
  arbitrary W source, independent of the production compiler — but that
  measures, it doesn't optimize; it isn't in `code_generator/x86.w`'s
  call path at all. `compilation_model.md`'s line for #337 applies
  unchanged: "the AST gives it *shape*, not *meaning*."
- **(c) A real AST in the compiler proper** (`wbuildd.md` §3.3) — where
  a genuine v2 optimizer would live, carrying the same three priced-out
  costs regardless of *why* an AST is wanted: the **self-host
  fixpoint** (a staged migration needs the single-pass path kept as a
  verified fallback throughout — "running *two* front ends in parallel
  and diffing output," unlike v0's peephole, which joins the *existing*
  fixpoint unchanged); the **seed constraint** (unchanged — new
  AST-layer code stays seed-syntax-safe); and the **REPL/wdbg blast
  radius**, `wbuildd.md`'s "sharpest concrete risk" —
  `repl/core.w`/`debugger/eval.w` run the whole production compiler
  in-process with checkpoint/rollback over compiler globals, and an AST
  is new mutable state that machinery must also snapshot, or fail
  silently into flaky multi-session bugs instead of a loud `verify`
  failure. What (c) buys beyond #231/#337's own reasons: cross-statement
  analysis within a function (constant propagation, CSE, dead-store
  elimination not limited to §1.1's byte-adjacent special case) —
  genuinely past v0's ceiling. But §1's evidence doesn't suggest v0's
  ceiling is anywhere near reached; none of its three findings has a fix
  landed yet.

The conclusion both companion docs already reached carries over
unchanged: (a) isn't really an optimization option; (b) is a legitimate,
cheap, seed-safe *experiment* (leaf tool, no seed exposure) but bounded
to pattern-detection, not a working optimizer; (c) is where real v2
lives and is gated on the same maintainer decision already flagged open,
for reasons unrelated to optimization specifically. **v2 needs no
separate decision of its own** — it rides whichever answer #231/#338
eventually get.

## 5. Where v0 and v2 actually differ

#110 poses them as alternatives ("either... or"); they're not competing
solutions to the same problem:

| | v0 (peephole) | v2 (AST pass) |
|---|---|---|
| Substrate exists today? | Yes — `code_generator/x86.w`'s buffer | No — needs #231/#338's option (c), undecided |
| Self-host risk | None beyond the ordinary `verify` gate | Real — dual-front-end migration, staged |
| REPL/wdbg risk | None — buffer bytes, no new state shape | Real — new mutable state to checkpoint/rollback |
| Ceiling | Local, byte-adjacent/single-function redundancies (§1) | Cross-statement, whole-function, eventually whole-program |
| Effort to first shippable PR | Small (§1.1 alone) | Large, gated on a decision this doc can't make |
| Measured, unclaimed wins today | Yes — §1's three classes, none fixed yet | N/A until (c) is decided |

v0 is not "the small version of v2" — a different, smaller-scope tool
available now, low risk, with real wins sitting in the tree today. v2 is
not "v0 but more" — it's gated on a decision already asked for two other
reasons (#231, #337) and not yet answered.

## 6. Recommendation and staged plan

1. **Now (next wave with slack)**: land §1.1's fix as its own small
   PR — direct `sym_get_value` conditional or a minimal single-window
   peephole (this doc takes no position between the two
   implementations, only that the redundancy is real and small to
   remove). Gates: `verify` + `verify_x64` (seed-graph file), plus
   existing `tests/asm_*` disassembly fixtures as a spot-check. **HIGH**
   care, merges last & alone.
2. **Next, once (1) is proven**: design the whole-function post-pass
   plumbing (§3's second mechanism — buffer-range bookkeeping, the
   backpatch/REPL-codepos-safety audit not yet done), then land §1.3 as
   its first consumer (smaller table, no call/nesting tracking).
3. **After that, if (2) held up**: §1.2, scoped to provably
   call-free/nesting-free spans.
4. **Do not schedule v2** until the maintainer answers `wbuildd.md`
   §6/`compilation_model.md`'s open #231/#338 questions — there's no
   substrate for an "AST optimization pass" until one lands.
5. **Optional, non-blocking**: if a future wave runs `wbuildd.md` §5
   stage 4's already-recommended `bin/wc2` PG spike anyway, extending
   its scope to count §1.1-shaped patterns over arbitrary W source
   (not just `bin/wv2`) would show how universal these redundancies are
   outside the compiler's own source. Not required for (1)-(3).

### Open questions for the maintainer

1. Direct `sym_get_value` fix for §1.1, or a generic peephole window
   even for this first case (on the theory §1.3/§1.2 will need one
   anyway)?
2. Does the whole-function post-pass need acceptance beyond the
   self-host fixpoint — e.g. a differential-disassembly sweep over the
   tracked `.w` corpus, mirroring `parser_generator_w_test` — or is
   `verify`+`verify_x64`+existing fixtures sufficient (§3's argument:
   the fixpoint already exercises every pattern the compiler's own
   source triggers)?
3. Given §2.3, is there a budget for how much slower `./wbuild
   build`/`w check` may get in exchange for faster generated code, or
   should any such pass be opt-in (a `--optimize` flag) rather than
   always-on?
