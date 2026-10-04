# Linux snapshot-memory constants (uapi/linux/memfd.h, fcntl.h and
# asm-generic/mman-common.h). The syscall wrappers are provided by
# lib.__arch__.syscalls through lib.lib: mmap_fd, memfd_create, madvise,
# sys_ftruncate, sys_fcntl, munmap and close.
#
# Create with MFD_ALLOW_SEALING, size with sys_ftruncate, initialize a
# MAP_SHARED mapping, then UNMAP it before adding F_SEAL_WRITE. A seal
# fails with -EBUSY while any shared writable mapping is alive (making
# it read-only with mprotect is insufficient). Add WRITE|SHRINK|GROW to
# make immutable backing; SEAL optionally prevents any further seals.
# Each MAP_PRIVATE mapping shares clean pages until written; discard
# its dirty pages with MADV_DONTNEED to restore the backing bytes.
# Closing the fd does not invalidate existing mappings; unmap them too.
#
# mmap_fd offsets are signed word-sized BYTES on every Linux target:
# at most 2^31-1 on x86, 2^63-1 on x64/arm64, aligned to host pages.
# Linux wrappers return raw negative errno, NOT libc's -1 plus errno.
# A mapped x86 address can look negative: only [-4095, -1] is an error.
# Darwin/win64/wasm return -1 for the three new primitives; do not send
# these Linux fcntl commands to their native sys_fcntl implementations.
# M0 of docs/projects/vms.md; no VM execution or isolation yet.
import lib.lib

const int MFD_CLOEXEC = 1
const int MFD_ALLOW_SEALING = 2

const int F_ADD_SEALS = 1033
const int F_GET_SEALS = 1034
const int F_SEAL_SEAL = 1
const int F_SEAL_SHRINK = 2
const int F_SEAL_GROW = 4
const int F_SEAL_WRITE = 8

const int PROT_NONE = 0
const int PROT_READ = 1
const int PROT_WRITE = 2
const int PROT_EXEC = 4
const int MAP_SHARED = 1
const int MAP_PRIVATE = 2
const int MAP_ANONYMOUS = 32

const int MADV_DONTNEED = 4
