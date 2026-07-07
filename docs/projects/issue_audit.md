# Issue audit after July 2026 feature merges

Snapshot taken against `main` at merge PR #88, with recent merged PRs #74,
#83, #85, #88 and #89 considered. This file is a close/re-scope checklist for
GitHub issues whose original acceptance criteria are now implemented or whose
remaining work has moved to narrower follow-up docs.

## Suggested closures

- #44 **Support raw system headers in c_import** - close. Suggested note:
  "Implemented by the C preprocessor + broad `c_import` path. `make tests`
  now imports raw libc/system headers (`stdio.h`, `stdlib.h`, `string.h`,
  `unistd.h`, `fcntl.h`, `errno.h`, `time.h`, `signal.h`, `ctype.h`,
  `math.h`, `dirent.h`, `locale.h`, `sys/stat.h`) on x86 and x64 via
  `c_import_libc_test`. Remaining C-import limitations are narrower
  follow-ups: K&R declarations, bit-field layout fidelity, extern arrays of
  unknown length, and additional torture fixtures."
- #22 **Generators** - close. Suggested note: "Generators/yield are
  implemented as stackful coroutines on x86 and x64, with `lib/generator.w`,
  `gen_switch` stubs, `generator_test`/`generator_64_test`, and `for x in
  generator()` consumption through the cursor protocol."
- #26 **Typed Containers or Generics** - close. Suggested note: "Both halves
  are implemented: built-in typed `map[K, V]`, `set[K]`, `list[T]`, aggregate
  values, list/map ergonomics, and true generic functions/structs with
  explicit instantiation plus call-site inference. Remaining container polish
  is tracked as narrower work."
- #19 **Hash map native syntax and delete support** - close. Suggested note:
  "Native `map[K, V]` syntax, literals, `m[k]` get/set, membership, key/value
  iteration, and removal have landed. The shipped spelling is `m.remove(k)`
  / `s.remove(k)` rather than `delete`."
- #18 **ArrayList native literal and indexing syntax** - close. Suggested
  note: "Superseded by built-in `list[T]`: `list[T]{...}` literals, `l[i]`
  get/set, `.length`, `push`/`pop`, iteration, `insert`/`remove`/`clear`,
  membership, and algorithm methods are implemented."
- #25 **AI Tooling** - close if the issue represents the first tooling
  milestone. Suggested note: "The MVP has landed: `w check --json`, `w
  symbols --json`, `bin/wtest changed`, W-native `bin/wmcp`, W-native
  `bin/wlsp`, the edit-check hook, agent skills/rules, and documentation.
  Follow-up items live in `docs/projects/ai_tooling_next_steps.md`."

## Keep open or re-scope

- #29 **ARM Backend** - keep open. AArch64 Linux ELF Stages 1-3 are done and
  Stage 4 Phases 1-3 groundwork is merged, but Mach-O output, in-house ad-hoc
  signing, Darwin test targets, `--pac=full`, and arm64e enforcement remain.
- #38 **Debugger: remaining and future work after PR #36** - keep open but
  edit the body. x64 wdbg, locals in expression eval, frames, line editing and
  software watchpoints are now done. Remaining items are conditional
  breakpoints/hit counts, hardware watchpoints via ptrace, asm/disasm helpers,
  web UI, and possibly logpoints/fuzzy break resolution if still desired.
- #33 **REPL: v1 improvements landed, future work** - keep open or re-scope.
  Line editing/history and x64 REPL are done; remaining useful work is `:load`,
  `:symbols`, bracketed paste, and deeper rebinding semantics.
- #17 **Floating point: finish float16/bfloat16 and cleanup docs** - keep open.
  float32 and float64 are implemented; float16 and bfloat16 are still deferred.
- #28 **CUDA Backend** - keep open. Host-side dynamic linking and
  `cuda_smoke` landed; PTX emission and `gpu for` are still future stages.
- #16, #27, #30, #31 - keep open. No merged implementation was found for
  protobuf, matrix class, WebAssembly, or OpenGL/graphics support.

## Active work not represented by an issue

- PR #87 adds an early Win64 PE32+ backend. If merged, consider opening or
  linking a Windows backend tracking issue for post-MVP work such as PE
  relocations/ASLR, W^X section split, CodeView/PDB, sockets/process spawning,
  imported data objects, and self-hosting on Windows.
