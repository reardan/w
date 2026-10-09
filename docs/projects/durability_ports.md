# Durability architecture adapters (#608)

`lib/fs.w` has native positional I/O, truncation, directory-relative/exclusive
creation, advisory process-lifetime locks and durability adapters on Linux
x86/x64/ARM64 and ARM64 Darwin. The ARM64 implementations are cross-compiled;
native hardware/filesystem qualification remains pending. A successful syscall
is not evidence that a device survives power loss.

| Operation | ARM64 Linux | ARM64 Darwin |
|---|---|---|
| Positional I/O | `pread64` 67 / `pwrite64` 68 | `pread` 153 / `pwrite` 154 |
| Truncate | `ftruncate` 46 | `ftruncate` 201 |
| Relative/exclusive create | `openat` 56, translated ARM flag assignments | `openat` 463, translated flags and `AT_FDCWD=-2` |
| Advisory lock | `flock` 32 | `flock` 131 |
| Durability barrier | `fsync` 82 | `fcntl(F_FULLFSYNC=51)` |
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
remain errors. No APFS/HFS+/external-drive combination is claimed qualified yet.

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
python3 tools/qualify_native.py --suite durability --rounds 20 \
  --scratch /path/on/filesystem-under-test --output bin/durability-native.json
```

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
The x64 Linux supplementary harness passes in all three modes. This session had
no ARM64 Linux or Apple Silicon hardware; native qualification for #608 is still
pending. In particular Darwin directory-barrier support must be established on
the exact filesystem/device before claiming durable replacement there.

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
