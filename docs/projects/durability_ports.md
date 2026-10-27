# Durability architecture adapters (#608)

`lib/fs.w` has native positional I/O, truncation, directory-relative/exclusive
creation, advisory process-lifetime locks and durability adapters on Linux
x86/x64/ARM64 and ARM64 Darwin. ARM64 Linux runs the shared suites and the
fault/crash harness under qemu-user in `tests_arm64`; its native
qualification (a real ARM64 Linux kernel, filesystem and device) remains
pending. Darwin/APFS has native
process-crash and fault-injection coverage on an M3 Pro; physical power-loss
qualification remains pending. A successful syscall
is not evidence that a device survives power loss.

| Operation | ARM64 Linux | ARM64 Darwin |
|---|---|---|
| Positional I/O | `pread64` 67 / `pwrite64` 68 | `pread` 153 / `pwrite` 154 |
| Truncate | `ftruncate` 46 | `ftruncate` 201 |
| Relative/exclusive create | `openat` 56, translated ARM flag assignments | `openat` 463, translated flags and `AT_FDCWD=-2` |
| Advisory lock | `flock` 32 | `flock` 131 |
| Durability barrier | `fsync` 82 | `fsync` 95 then `fcntl(F_FULLFSYNC=51)` |
| Publish | `renameat` 38 | `rename` 128 |

Offsets are signed 64-bit words. The kernel receives one positional operation;
there is no seek/write emulation and concurrent use does not alter shared file
position. Negative offsets and overflowing ranges fail before I/O. Native errno
values are retained; portable categories use the target's errno ABI (for example
Darwin lock contention is native EAGAIN 35, Linux EAGAIN 11). Cooperative task
cancellation and deadline errors use those same target values.

ARM64 Linux translates O_DIRECTORY/O_NOFOLLOW/O_DIRECT/O_LARGEFILE from the
portable x86 flag numbering. The raw `open` wrapper retains its existing native
flag ABI for directory enumeration. Darwin also translates the portable flags. Its durability
barrier never falls back from `F_FULLFSYNC` to ordinary `fsync`: Apple's stronger
barrier asks the device to flush volatile write caches, as described in
[Apple's fsync documentation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html). Directory synchronization
uses the same strict barrier. If a filesystem does not implement that barrier
for directories, durable replacement reports the failure at `FS_STAGE_SYNC_DIR`
with `renamed=1`; it cannot claim completion. A refused file barrier leaves the
original destination intact and reports `FS_STAGE_SYNC_FILE`. ENOTSUP and
EOPNOTSUPP become `IO_UNSUPPORTED`; native errors remain available. Other errors
remain errors. Native APFS process-crash results are recorded below; HFS+,
external drives and physical power-loss behavior remain unqualified.

Guarantees require local filesystems that honor file/directory synchronization,
atomic same-directory rename, and devices/controllers that truthfully implement
flushes. Mount options, filesystem version, storage stack and power-loss
protection affect this contract. Network filesystems are excluded. File locks
are advisory: every participant must use the same lock protocol, and the lock
file must not be unlinked/replaced while participants may hold it. Inherited or
duplicated descriptors can prolong a lock's lifetime.

## Reproducible native qualification

On each native ARM64 Linux and Apple Silicon checkout:

```sh
bin/qualify_native --suite durability --rounds 20 \
  --scratch /path/on/filesystem-under-test --output bin/durability-native.json
```

A physical Android ARM64 device attached over ADB qualifies the Linux
`arm64` adapters with the host-built static ELF fixtures, the same way the
#607 ordered-memory evidence was collected (no Bionic, no translation):

```sh
bin/qualify_native --suite durability --adb SERIAL --pac off --rounds 20 \
  --output bin/durability-native-android.json
```

`--pac off` is needed only on CPUs without pointer authentication. Each
trial runs in a fresh directory under `/data/local/tmp` (usually f2fs or
ext4 on the userdata partition, often with file-based encryption); the
report records that directory's `df` output and the device's `/proc/mounts`
so the filesystem, mount options (`nobarrier`, f2fs `fsync_mode`) and
device are part of the evidence. Results apply to that filesystem and
storage device only.

The driver records hardware/OS/compiler/source hashes, flags, filesystem location
and repetitions. It runs the fixtures under streaming, retained AST and optimized
retained AST compilation, each in a fresh scratch directory. Use a local scratch
filesystem that supports sparse files. Record filesystem type/version, mount
options and device model/firmware in the qualification report alongside the
machine-generated JSON. Failure and timeout results are retained, and outstanding
worker processes are killed.

The fixture covers a sparse offset at 5 GiB, truncation, invalid/overflowing
ranges, genuinely concurrent positional writes through an inherited shared file
description, exclusive create, relative create, lock contention, and lock
recovery after SIGKILL. A writer is terminated at five boundaries: after writing
the temporary file, after file sync, after close, after rename, and after directory
sync. Recovery checks the destination itself, tolerates the unacknowledged
publication, re-establishes directory durability and performs another durable
replacement. Error cases cover missing parent, bad descriptor and rename over a
directory, asserting replacement stage and publication flags.

These are process-crash tests with a live kernel and caches. They do not simulate
a power cut. Deterministic injected sync/write/rename failures and storage loss
remain covered separately by `lib/fake_fs_test.w` and
`lib/fake_fs_async_test.w`. Hardware qualification must additionally record
controlled power-loss/reboot experiments at the publication boundaries, checking
that acknowledged replacements survive and unacknowledged publication recovers
to a complete old or new record. Do not label SIGKILL or QEMU as that evidence.

## Current evidence and unsupported targets

Both ARM64 targets cross-compile every fixture in all three compilation modes.
The x64 Linux supplementary harness passes in all three modes. ARM64 Linux
native qualification remains pending.

ARM64 Linux runs under qemu-user in the `tests_arm64` suite (the CI `arm64`
job): the shared `lib/fs_test.w` (15 tests: 5 GiB sparse offsets, hole
reads, truncate, overflow rejection, concurrent positional access through a
shared open file description while its cursor moves, exclusive and
directory-relative creation, close-on-exec, native errno, lock contention
and release after SIGKILL, file/directory barriers and replacement
reports), `lib/io_test.w`, `tests/native_qualification_test.w`, the
`native_qualification_emulated_test` run of both qualification fixtures in
all three compilation modes, and `fs_fault_arm64_test`. That last target
(`tools/linux_fs_qualification.w`, also run for i386 and x86-64 as
`fs_fault_linux_test` in `tests`) is the Linux counterpart of the Darwin
fault harness: a private import root replaces only the `fsync` and `rename`
bodies of the target's syscall adapter with `tests/fs_linux_fault_hooks.w`,
injects EIO, EINTR, EINVAL, EOPNOTSUPP and ENOSPC at the file barrier, the
rename and the directory barrier, and SIGKILLs the writer immediately before
and after each of them (18 cases per target). Each case checks the visible
old/new contents, temp cleanup or crash leftovers, `stage`/`renamed`, the
native errno, and a successful republication afterwards.

qemu-user forwards every guest syscall to the x86_64 host kernel, so these
runs establish the AArch64 syscall numbers, flag translation, offset ABI
and error propagation end to end, but say nothing about ARM64 kernels,
filesystems or storage devices. They are regression coverage, **not**
native qualification.

On 2026-10-09, native M3 Pro/macOS 26.3 tests on local internal APFS passed
15 filesystem tests, five checked-I/O tests, and 17 injected failure/SIGKILL
cases with recovery. File and directory full barriers succeeded on this
filesystem/device. Run `./wbuild fs_durability_darwin_test`; the full scope,
assumptions and test mechanism are in [Darwin qualification](reliable_services.md#darwin-qualification-608).
The existing `tools/qualify_native.w --suite durability` fixture also passed
20 rounds in each of streaming, retained and optimized modes (60 runs), using
`--compiler bin/wv2_darwin --scratch bin`; local evidence is written to
`bin/fs608_native_qualification.json`.
These results cover process crashes with a live kernel and caches, not physical
power loss. Other filesystem/device combinations require their own evidence.

Windows is a separate port, explicitly **unsupported** by this durability API.
The win64 `sys_pread`, `sys_pwrite`, `sys_ftruncate`, `sys_openat` and `sys_flock`
stubs continue to report `IO_UNSUPPORTED`. A future port needs explicit Windows
handle sharing, positional/overlapped I/O, lock lifetime, flush and replacement
semantics, not a POSIX-parity claim. wasm is likewise unsupported.

Adapter references: [Linux generic syscall table](https://github.com/torvalds/linux/blob/master/include/uapi/asm-generic/unistd.h),
[ARM64 Linux flags](https://github.com/torvalds/linux/blob/master/arch/arm64/include/uapi/asm/fcntl.h),
[XNU syscall table](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/syscalls.master),
[XNU flags](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/fcntl.h),
[XNU errno definitions](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/errno.h).
