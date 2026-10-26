# Durability architecture adapters (#608)

`lib/fs.w` has native positional I/O, truncation, directory-relative/exclusive
creation, advisory process-lifetime locks and durability adapters on Linux
x86/x64/ARM64 and ARM64 Darwin, and a separate Windows x64 contract
([below](#windows-x64)) whose native qualification is pending. Each target's
adapter is `lib/__arch__/<target>/fs_native.w`: the POSIX targets forward to
their syscall adapters (`lib/fs_native_posix.w`), Windows has its own. ARM64 Linux native qualification remains pending. Darwin/APFS has native
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

wasm remains explicitly unsupported (ENOSYS stubs report `IO_UNSUPPORTED`).

## Windows x64

`lib/__arch__/win64/fs_native.w` implements the same API on kernel32 and
ntdll. It is a **Windows contract, not POSIX parity**; the differences are
deliberate and tested:

| Operation | Windows x64 |
|---|---|
| Positional I/O | One `ReadFile`/`WriteFile` with an `OVERLAPPED` offset (64-bit `Offset`/`OffsetHigh`) on a synchronous handle: never seek + read/write. Windows also leaves the handle's file pointer at the end of the transfer, so do not mix positional and cursor I/O on one handle. Transfers above 1 GiB are partial. `ERROR_HANDLE_EOF` is `IO_EOF`. |
| Truncate | `NtSetInformationFile(FileEndOfFileInformation)`: the size changes and the file pointer does not move. |
| Create/open | `CreateFileW` with UTF-8 paths converted to UTF-16 (invalid UTF-8 is `EILSEQ`). `O_CREAT\|O_EXCL` is `CREATE_NEW` (no check-then-create race). Handles share read, write **and delete**. `O_CLOEXEC` means a non-inheritable handle, and without it the handle is inheritable. `mode` is ignored: the new file inherits the parent directory's ACL. `O_RDONLY\|O_TRUNC` and `O_DIRECTORY` combined with `O_CREAT`/`O_TRUNC` are `EINVAL`. |
| Directory-relative open | `NtCreateFile` with `RootDirectory` set to the directory handle. This is a true handle-relative open, so renaming the directory concurrently cannot redirect it. `.` components and repeated separators are dropped; `..` is `EINVAL`, because NT does not resolve it. Absolute paths ignore the handle, as POSIX `openat` does. |
| Lock | `LockFileEx(EXCLUSIVE\|FAIL_IMMEDIATELY)` on one byte at offset 2^62. Windows range locks are mandatory, so the locked byte sits far beyond any data and the lock file itself stays readable and writable. Locks belong to a handle: a second `fs_lock_acquire` in the same process contends. Contention (`ERROR_LOCK_VIOLATION`) is `IO_WOULD_BLOCK`/`EAGAIN`. Closing the handle releases the lock. **Release after process termination is asynchronous** on Windows, so a contender must retry rather than expect the lock the instant the owner exits. |
| File barrier | `FlushFileBuffers`. Pipes, consoles and other non-disk handles are `EINVAL` → `IO_UNSUPPORTED`; the flush is never attempted, because it would block until a pipe reader drains. A filesystem that refuses the flush (`ERROR_INVALID_FUNCTION`/`NOT_SUPPORTED`/`INVALID_PARAMETER`) is `IO_UNSUPPORTED`. |
| Directory sync | `fs_sync_dir` opens the directory read-write with `FILE_FLAG_BACKUP_SEMANTICS` (`FlushFileBuffers` needs write access) and flushes it. A refusal is `IO_UNSUPPORTED`, never reported as success. |
| Publish | `MoveFileExW(MOVEFILE_REPLACE_EXISTING \| MOVEFILE_WRITE_THROUGH)`, which is atomic for a same-volume rename and asks the filesystem to commit the rename before returning. The final `sync_dir` stage of `fs_replace_durable` then flushes the replaced file through a fresh handle, because Windows has no supported directory fsync and on NTFS a file flush also commits the metadata journal holding the rename. A failure there still reports `renamed=1`. |

Errors: each Win32 error becomes the POSIX-equivalent errno (Linux numbering,
which win64's `lib/io.w` classifies), so `fs_result_exists`, `EBADF`, `ENOENT`,
`ENOSPC`, `EAGAIN` and the `IO_*` categories behave as on POSIX targets. Codes
with no equivalent become `EIO`. The exact Win32 code of the latest failure is
kept in `fs_win32_last_error`. W has no Windows threads yet, so one slot per
process is unambiguous.

Assumptions: a local NTFS or ReFS volume (same-volume rename is atomic and
journaled), a filesystem that honors write-through, and a device that honors
flushes. Disks with write caching enabled *and* the "turn off Windows
write-cache buffer flushing" policy set void the guarantee, and so do devices
that lie about flush completion. FAT/exFAT (no metadata journal) and network
shares (SMB) are excluded. Replacement fails at the `rename` stage, with the
destination untouched and the temp file removed, while another handle holds the
destination open without `FILE_SHARE_DELETE`. Most programs, and lib's plain
`open`, do not pass that flag. On Windows versions or filesystems without POSIX
rename semantics, even `FILE_SHARE_DELETE` holders may block the replacement.
Antivirus scanners and indexers can hold files briefly and cause transient
sharing violations (`EBUSY`/`EACCES`), so callers retry.

Evidence: `fs_win64_test` (`lib/fs_win64_test.w`, `tests_win64`, the CI `win64`
job) has 18 tests. They cover:

- positional I/O and its file-pointer contract;
- range and overflow rejection;
- a sparse (`FSCTL_SET_SPARSE`) write at 5 GiB with hole reads;
- truncate without pointer movement;
- exclusive and handle-relative creation, `ENOTDIR`/`EISDIR`/`..`;
- UTF-8 paths;
- inheritance following `O_CLOEXEC`;
- file and directory flush status, including the pipe refusal;
- lock contention, plus release after `TerminateProcess` with polling;
- concurrent positional writers in separate processes;
- durable replacement, including its `open_temp`/`rename` failures and stale temp names;
- the error mapping.

The suite runs under **wine**, which maps these calls onto the Linux host's
filesystem (`FlushFileBuffers` → `fsync`, `MoveFileExW` → `rename`). That
validates the adapter, the flag and error mapping and the harness. It is **not**
Windows qualification. Still pending: a native run on Windows 10/11 with NTFS,
a Windows fault/crash harness (an import-root overlay of `fs_native.w`
intercepting `FlushFileBuffers`/`MoveFileExW`, plus `TerminateProcess` at each
boundary), and power-loss experiments.

Adapter references: [Linux generic syscall table](https://github.com/torvalds/linux/blob/master/include/uapi/asm-generic/unistd.h),
[ARM64 Linux flags](https://github.com/torvalds/linux/blob/master/arch/arm64/include/uapi/asm/fcntl.h),
[XNU syscall table](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/syscalls.master),
[XNU flags](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/fcntl.h),
[XNU errno definitions](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/errno.h).
