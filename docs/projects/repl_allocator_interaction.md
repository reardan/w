# The `string_free(b); free(b)` heap corruption: root cause (Wave 3 task 3e)

Status: root-caused 2026-07-18, no code change. This closes the
"worth a proper root-cause pass" note left in
`docs/projects/ai_tooling_next_steps.md`'s REPL section (issue #276 P3,
2026-07-16). The existing workaround in `repl.w` is correct and stays;
this doc explains the mechanism so the workaround doesn't have to be
taken on faith, and records why the original bisection made it look
REPL/JIT-specific when it isn't.

## Symptom (as originally reported)

`repl_eval_json`'s helper built a `string_builder`, read a captured
output file into it, and did the textbook-looking:

```
char* result = strclone(b.data)
string_free(b)
free(b)
return result
```

The caller's very next `json_object()`/`json_object_set()` call would
then see a `json_value*` with a garbage `.type` field, or segfault
outright on a later `malloc`/`free`. The 2026-07-16 bisection (~40
throwaway repro programs, recorded in `ai_tooling_next_steps.md`)
concluded: not reproducible with `structures.string` + `lib.lib` alone
in a tight loop; reproducible once a program linked `repl.w`'s full
import set, called `repl_init()` plus the wdbg trap-handler install,
and ran at least one `repl_eval()` before the free pair. That made the
JIT checkpoint/rollback machinery and the signal-handler install look
like plausible culprits.

## Mechanism

**`string_free(b); free(b)` is a plain double free of the same
pointer, `b`.** `structures/string.w:144`:

```
void string_free(string_builder* s):
	free(s.data)
	free(s)
```

`string_free(b)` already frees `b` itself (the struct pointer), on top
of `b.data`. So `string_free(b)` followed by `free(b)` frees `b` twice.
Hypothesis 3 in the task brief is exactly right, and there is no
"aliased pointer" subtlety needed to see it: `string_free`'s own body
frees the same address the caller frees again immediately after.

**The production allocator (`lib/memory_freelist.w`) has no double-free
detection, and a double free corrupts its free list into a permanent
self-loop that aliases every later allocation of that size class.**
`freelist_free` (`lib/memory_freelist.w:244`) and the `malloc_bin_push`
helper it calls (`lib/memory_freelist.w:169`) are:

```
void malloc_bin_push(int block, int size):
	malloc_save_word(block, size)
	int head = malloc_bins + malloc_size_bin(size) * __word_size__
	malloc_save_word(block + __word_size__, malloc_load_word(head))
	malloc_save_word(head, block)


int freelist_free(void* mem_address):
	if (mem_address == 0):
		return 0
	if (malloc_bins == 0):
		return 0
	int block = mem_address - 2 * __word_size__
	malloc_bin_push(block, malloc_load_word(block))
	return 1
```

Trace freeing the same block `B` twice, with the bin currently empty
(head = 0):

1. First `free(B)`: `malloc_bin_push` sets `B.next = 0` (the old head)
   and `head = B`.
2. Second `free(B)`: `malloc_bin_push` reads the *current* head, which
   is now `B` itself, and writes `B.next = B` — a self-loop — then sets
   `head = B` again (unchanged).

The bin's free list is now `head -> B -> B -> B -> ...`. Look at
`freelist_malloc`'s pop logic (`lib/memory_freelist.w:176`, the
exact-bin loop): it reads `next = malloc_load_word(cur + word_size)`
and, when `prev == 0`, does `malloc_save_word(head, next)`. With the
self-loop, `next` is always `B`, so **the head never advances past
`B`**. Every subsequent `malloc()` request that lands in that size bin
(whether by matching the exact bin, or by falling into it as "first
non-empty higher bin" for a smaller request) returns `B` again,
forever, without ever truly removing it from the free list. Two or
more concurrently-live objects of a matching size class end up
**aliased onto the same address**, and whichever one writes last
clobbers the other's fields — precisely the "`json_value*` with a
garbage `.type` field" symptom.

This is a generic property of this allocator; it has nothing to do
with the REPL, the in-process JIT, or wdbg's signal handler. Minimal,
dependency-free reproduction (no `repl.w`, no `structures.string`, just
`lib.lib`):

```
import lib.lib

void main():
	int size = 16
	char* a = malloc(size)
	free(a)
	free(a)

	char* p1 = malloc(size)
	char* p2 = malloc(size)
	if (p1 == p2):
		println(c"ALIASED: p1 == p2 (heap corruption confirmed)")
```

Run standalone (built against `bin/wv2` from this checkout, both
targets):

```
$ ./bin/wv2 probe.w -o probe && ./probe
144883888
144883888
ALIASED: p1 == p2 (heap corruption confirmed)
$ ./bin/wv2 x64 probe.w -o probe_x64 && ./probe_x64
683729240
683729240
ALIASED: p1 == p2 (heap corruption confirmed)
```

Same result on x86 and x64: `p1 == p2` every time. A second probe using
`structures.string`'s own API (`string_new()` / `string_append()` /
`string_free()` / `free()`, still no REPL imports) shows the same
aliasing with visible data corruption -- two "different" live builders
end up sharing one buffer, so both `p1.data` and `p2.data` print the
same corrupted bytes after each is appended to in turn. `W_DEBUG_ALLOC=1`
against the raw-malloc probe catches it immediately and precisely:

```
memory_debug: double free() detected (address 0xf7f92ff0)
stack trace (most recent call first):
  at debug_fatal (lib/memory_debug.w:120)
  at debug_free (lib/memory_debug.w:165)
  at free (lib/memory.w:115)
  at main (probe.w:12)
```

(`lib/memory_debug.w:164`'s `debug_free` marks a freed region
`PROT_NONE` and never reuses it, so a second free trips
`debug_tbl_freed[idx]` and calls `debug_fatal` instead of corrupting
anything.)

## Why the bisection thought REPL/JIT context was required

The corruption itself happens unconditionally on the double free. What
requires more context is *observing* it: the corrupted bin only
produces a visible symptom once something else allocates from the same
size bin while the aliased block is still meaningfully "live" elsewhere.
A narrow synthetic loop that only ever asks for that one exact size,
one object at a time, degenerates into a stable-but-wrong state that
never gets contradicted: repeatedly calling just `string_new()` after
the corruption returns the *same* address every time (confirmed by a
third probe), but since nothing else is ever alive to alias against, no
visible symptom follows. `repl.w`'s full startup context does a lot of
allocation of many different struct sizes during and immediately after
`repl_init()`/`repl_eval()` (compiler tables, JSON codec structures,
the staged-entry machinery), so the odds that *something* lands in the
now-permanently-stuck bin shortly after the double free are high — that
is what turned a latent, silent bug into an observed one in the
2026-07-16 bisection, not any interaction specific to the JIT or the
signal handler.

## Hypotheses 1 and 2, ruled out by direct inspection

- **Hypothesis 1 (wdbg signal-handler install corrupts/shifts allocator
  state):** `repl_fault_install_handlers()` and the surrounding fault
  scaffolding in `repl/core.w` (roughly lines 737-925) only touch
  signal-handling state: preallocated `struct sigaction` buffers,
  `rt_sigaction` calls, and the jump buffers `repl_error_jump`/
  `repl_fault_jump_buffer` point at. None of it reads or writes
  `lib/memory_freelist.w`'s globals (`malloc_bins`, `malloc_heap_ptr`,
  `malloc_heap_end`, `malloc_mmap_mode`, `malloc_scan_steps`). The code
  even comments on its own care to avoid allocator reentrancy ("Scratch
  struct sigaction, preallocated so the fault handler itself never
  calls malloc when restoring a default disposition",
  `repl/core.w:764`) — the opposite of the hypothesis, and consistent
  with no allocator-state interaction at all.

- **Hypothesis 2 (repl_eval's checkpoint/rollback rolls back an
  allocator global):** `repl_checkpoint()`/`repl_rollback()`
  (`repl/core.w:489`-`546`) and their genesis-snapshot twins
  (`repl_genesis_checkpoint()`/`repl_reset_to_genesis()`,
  `repl/core.w:582` onward) save and restore exactly the ~20 compiler/
  parser-state globals: `codepos`, `table_pos`, `stack_pos`,
  `loop_depth`/`loop_break_chain`/`loop_continue_chain`/
  `loop_stack_pos`, `switch_depth`/`switch_break_chain`/
  `switch_stack_pos`, `break_in_switch`, `defer_count()`,
  `for_cleanup_count()`, `number_of_args`, `type_count()`,
  `imported_count`, `import_alias_base`/`import_alias_count`,
  `import_plain_base`/`import_plain_count`, `current_function_symbol`,
  and `repl_sites_count`. None of these names, nor anything else in
  `repl/core.w`, refers to `lib/memory_freelist.w`'s allocator globals
  — the checkpoint set and the allocator's owned globals are disjoint.
  The JIT's rollback cannot roll back allocator state because it never
  touches allocator state in the first place.

Both hypotheses are ruled out; hypothesis 3 (double-free semantics in
`string_free` itself, compounded by the allocator's lack of double-free
detection) is confirmed and fully explains the symptom without any
REPL-specific mechanism.

## Fix options

1. **Keep the existing workaround** (already shipped in `repl.w`):
   `repl_format_echo`'s string-typed echo case and
   `repl_json_read_capture` take `b.data` directly and `free(b)` only
   once, the same ownership-transfer idiom
   `string_builder_to_string`/`__w_template_finish` already use. This
   is correct and needs no change — it isn't "avoiding a mysterious
   bug", it's simply not double-freeing.
2. **Audit for recurrence:** confirmed by grep (see below) that no
   other `string_free(x)` call in the tree is followed by a `free()` on
   the same pointer; every other `string_free(x); free(y)` pair in the
   tree already frees two distinct pointers.
3. **Harden `freelist_free` with double-free detection in the
   production allocator** (e.g. an O(1) "already on this bin's free
   list" check, or a freed/live bit like the debug allocator's). Rejected
   for this task: `lib/memory_freelist.w` is a perf-sensitive,
   self-hosting-critical file (`tests/malloc_churn_test.w` is its
   regression benchmark) exercised by every W program including the
   compiler's own bootstrap; adding a check there is not a "small,
   obviously safe" change under this task's timebox and deserves its
   own PR with benchmarking and `verify`/`verify_x64` scrutiny, not a
   drive-by edit bundled into a root-cause doc.
4. **Recommend `W_DEBUG_ALLOC=1` (or `malloc_force_debug_mode()`)
   during development of allocator-adjacent code.** It already catches
   this exact bug immediately, with a precise stack trace to the
   offending `free()` call (demonstrated above). Worth a callout in
   `AGENTS.md`/the REPL skill for anyone debugging a "heap looks
   corrupted after a REPL/JIT-adjacent change" symptom in the future:
   reach for `W_DEBUG_ALLOC=1` first, before suspecting the JIT or
   signal handlers.

## Recommendation

No code change. The shipped workaround in `repl.w` is the right fix for
the actual call sites; the allocator's missing double-free detection is
a real hardening opportunity but is out of scope for a "small and
obviously safe" bundled fix given the file's perf sensitivity and
bootstrap centrality. Point future readers of the
`ai_tooling_next_steps.md` REPL entry at this doc instead of re-opening
the investigation.

## Repro scripts

Ad hoc probes used for this investigation (not checked in as tests,
since the bug's mechanism is now understood and there is no code change
to regression-test): a raw `malloc`/`free` double-free-aliasing probe,
a `structures.string`-only variant, and a same-address-repeats-forever
variant, all confirmed against both `./bin/wv2` (x86) and
`./bin/wv2 x64` on this checkout's freshly bootstrapped compiler.
