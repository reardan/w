---
name: w-arm64-qemu
description: Build and test the ARM64 Linux backend, running the produced aarch64 ELF binaries under qemu. Use for any arm64 codegen change, when a task names verify_arm64 or the arm64 run targets, or when an arm64 binary must actually execute on an x86 host.
---

# Testing the ARM64 backend under qemu

The compiler cross-emits arm64 from any host (`./bin/wv2 arm64 file.w
-o out` produces a static AArch64 Linux ELF), so *compiling* for arm64
never needs special hardware. *Running* the output on an x86 host needs
`qemu-user-static` — every arm64 run target wraps execution in
`tools/run_arm64.sh`, which execs natively on an aarch64 Linux host and
otherwise falls back to `qemu-aarch64-static -cpu max` (override the
emulator with the `QEMU_ARM64` environment variable). `-cpu max`
enables FEAT_PAuth/FPAC, so `--pac=ret|full` binaries are enforced
under qemu with Apple-M3-equivalent trap semantics.

## Commands

```sh
./wbuild verify_arm64        # arm64 self-host fixpoint (needs qemu)
./wbuild arm64_smoke_test    # six representative tests under qemu
./bin/wv2 arm64 file.w -o out && sh tools/run_arm64.sh out
./bin/wv2 check --json arm64 file.w   # compile-only, no qemu needed
```

`verify_arm64` is the arm64 analog of `./wbuild verify`: the x86
compiler cross-compiles `w.w` to `bin/wv2_arm64`, that binary runs
under qemu to recompile `w.w` as `bin/wv3_arm64`, and the two must be
byte-identical. Run it for any arm64 codegen change — and keep
`./wbuild verify` / `verify_x64` green too, since the backends share
dispatch code that must stay byte-identical for the x86 targets.

## qemu-only run targets (outside the default `tests` umbrella)

`verify_arm64`, `arm64_smoke_test`, `dynamic_test_arm64`,
`float_abi_test_arm64`, `pac_full_test_arm64`, `pac_corrupt_test_arm64`
(the PAC corruption fixtures must *die*, exit >= 128),
`vcs_cas_test_arm64`, `wbuild_platform_test_arm64`. None of them are in
`./wbuild tests`, so a green full suite says nothing about arm64
runtime behavior.

## Without qemu (env-blocked hosts)

If `qemu-aarch64-static` is missing, `run_arm64.sh` fails with exit 127
(`qemu-aarch64-static: not found`); install `qemu-user-static` or treat
the run targets above as env-blocked and verify what still works:

- Cross-compilation: `./bin/wv2 arm64 file.w -o out` and
  `./bin/wv2 check --json arm64 file.w` work on any host.
- The arm64 coverage inside the default `tests` umbrella is
  compile-side and qemu-free: `asm_arm64_test` / `asm_fuzz_arm64_test`
  decode the compiler's own arm64 output with the in-house A64
  disassembler (`libs/asm/` — no cross binutils needed),
  `arm64_darwin_smoke_test` cross-compiles the smoke programs to
  Mach-O without running them, and `pac_flag_test` asserts `--pac`
  byte patterns in the emitted artifacts.

State clearly in your report which targets were env-blocked rather than
skipping them silently. Design and status notes:
`docs/projects/arm64.md`.
