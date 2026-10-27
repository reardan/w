# lib/fs.w's native layer on Windows x64 (#608). This is a Windows
# contract, not POSIX parity; docs/projects/durability_ports.md
# ("Windows") lists every difference. Kept out of syscalls.w so the
# compiler's own win64 import graph does not grow.
#
# - Descriptors are kernel32 HANDLEs opened synchronous (no
#   FILE_FLAG_OVERLAPPED), sharing read, write and delete so that a
#   durable replacement can rename over a file other fs_open users hold.
# - Paths are UTF-8, converted to UTF-16 for the W entry points.
# - Failures return the negated POSIX-equivalent errno (Linux numbering,
#   which win64's lib/io.w classifies) of the Win32 error; the exact
#   Win32 code of the latest failure is kept in fs_win32_last_error.
# - Positional I/O is one ReadFile/WriteFile with an OVERLAPPED offset:
#   never seek + read/write. On a synchronous handle Windows also moves
#   the handle's file pointer to the end of the transfer.
# - Locks are LockFileEx byte-range locks on one byte far beyond any
#   data, so they exclude other fs_lock_acquire handles without blocking
#   I/O to the lock file's contents (Windows range locks are mandatory).
# - fsync is FlushFileBuffers; publication is MoveFileExW with
#   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH, followed by a
#   flush of the replaced file (FS_NATIVE_PUBLISH_SYNCS_DIR is 0).

c_lib "kernel32.dll"
extern int CreateFileW(char* path, int access, int share, char* security, int creation, int flags, int template_file)
extern int MoveFileExW(char* oldpath, char* newpath, int flags)
extern int DeleteFileW(char* path)
extern int GetFileAttributesW(char* path)
extern int MultiByteToWideChar(int codepage, int flags, char* source, int source_length, char* destination, int destination_length)
extern int GetFileInformationByHandle(int handle, char* info)
extern int GetFileType(int handle)
extern int LockFileEx(int handle, int flags, int reserved, int length_low, int length_high, char* overlapped)
extern int UnlockFileEx(int handle, int reserved, int length_low, int length_high, char* overlapped)

c_lib "ntdll.dll"
extern int NtCreateFile(int* handle, int access, char* attributes, char* status_block, int allocation_size, int file_attributes, int share, int disposition, int options, int ea_buffer, int ea_length)
extern int NtSetInformationFile(int handle, char* status_block, char* information, int length, int information_class)
extern int RtlNtStatusToDosError(int status)


# fs_sync_dir opens directories read-write: FlushFileBuffers needs a
# handle with write access, which Windows grants on directories.
const int FS_NATIVE_DIR_SYNC_ACCESS = 2

# fs_replace_durable's final barrier flushes the replaced file itself
# (Windows has no supported directory fsync; see fs_native_rename).
const int FS_NATIVE_PUBLISH_SYNCS_DIR = 0

# Win32 error of the most recent failing call in this module (0 before
# any failure). Windows threads are not wired up in W yet, so one
# process-wide slot is unambiguous.
int fs_win32_last_error


# Positive POSIX errno (Linux numbering) for a Win32 error code. Codes
# without an equivalent become EIO; fs_win32_last_error keeps the original.
int fs_native_errno_from_win32(int code):
	if ((code == 2) || (code == 3) || (code == 15) || (code == 161)): return 2  # file/path not found, bad drive/path: ENOENT
	if (code == 4): return 24  # too many open files: EMFILE
	if (code == 5): return 13  # access denied: EACCES
	if (code == 6): return 9  # invalid handle: EBADF
	if ((code == 8) || (code == 14) || (code == 1450)): return 12  # out of memory/resources: ENOMEM
	if (code == 17): return 18  # not same device: EXDEV
	if (code == 19): return 30  # write protected: EROFS
	if (code == 32): return 16  # sharing violation: EBUSY
	if (code == 33): return 11  # lock violation: EAGAIN (contention)
	if ((code == 39) || (code == 112)): return 28  # disk full: ENOSPC
	if ((code == 1) || (code == 50)): return 95  # invalid function, not supported: EOPNOTSUPP
	if ((code == 80) || (code == 183)): return 17  # file/already exists: EEXIST
	if ((code == 87) || (code == 123)): return 22  # invalid parameter/name: EINVAL
	if ((code == 109) || (code == 232)): return 32  # broken pipe, no data: EPIPE
	if (code == 120): return 38  # not implemented: ENOSYS
	if (code == 145): return 39  # directory not empty: ENOTEMPTY
	if (code == 206): return 36  # name too long: ENAMETOOLONG
	if (code == 267): return 20  # not a directory: ENOTDIR
	if ((code == 995) || (code == 1235)): return 125  # aborted: ECANCELED
	if ((code == 1816) || (code == 1295)): return 122  # quota: EDQUOT
	if (code == 1113): return 84  # no Unicode translation (invalid UTF-8 path): EILSEQ
	return 5


# Records code and returns the negated errno: the syscall convention.
int fs_native_fail(int code):
	fs_win32_last_error = code
	return 0 - fs_native_errno_from_win32(code)


# Records an NTSTATUS failure from ntdll the same way.
int fs_native_fail_status(int status):
	int low = status & ((1 << 32) - 1)
	if (low == 3221225658): # STATUS_FILE_IS_A_DIRECTORY (0xC00000BA)
		fs_win32_last_error = 5
		return 0 - 21  # EISDIR
	return fs_native_fail(RtlNtStatusToDosError(low))


# 1 when an NTSTATUS (in the low 32 bits) reports an error or warning.
int fs_native_status_failed(int status):
	return (status & 2147483648) != 0


# A malloc'd NUL-terminated UTF-16 copy of a UTF-8 path, or 0 when the
# path is not valid UTF-8 (fs_win32_last_error then says why).
char* fs_native_wide(char* path):
	int units = MultiByteToWideChar(65001, 8, path, -1, 0, 0)
	if (units <= 0):
		fs_win32_last_error = GetLastError()
		return 0
	char* wide = cast(char*, malloc(units * 2))
	if (MultiByteToWideChar(65001, 8, path, -1, wide, units) != units):
		fs_win32_last_error = GetLastError()
		free(wide)
		return 0
	return wide


# 1 when path is absolute (or drive-relative), so openat ignores dirfd
# exactly as POSIX does.
int fs_native_absolute(char* path):
	if ((path[0] == '/') || (path[0] == 92)): return 1
	return (path[0] != 0) && (path[1] == ':')


# The open handle's FILE_ATTRIBUTE_* word, or -1 on failure.
int fs_native_attributes(int handle):
	char[56] info
	if (GetFileInformationByHandle(handle, &info[0]) == 0): return -1
	return load_int32(&info[0])


# Win32 CreateFileW creation disposition for the portable flags.
int fs_native_creation(int flags):
	if (flags & 64):
		if (flags & 128): return 1  # CREATE_NEW
		if (flags & 512): return 2  # CREATE_ALWAYS
		return 4                    # OPEN_ALWAYS
	if (flags & 512): return 5      # TRUNCATE_EXISTING
	return 3                        # OPEN_EXISTING


# GENERIC_READ / GENERIC_WRITE for the portable access mode.
int fs_native_access(int flags):
	int rw = flags & 3
	if (rw == 0): return 2147483648
	if (rw == 1): return 1073741824
	return 2147483648 + 1073741824


# Validates the portable flags shared by both open paths: 0 or -errno.
int fs_native_check_flags(int flags):
	int rw = flags & 3
	if (rw == 3): return 0 - 22
	# Windows truncation needs write access; O_RDONLY|O_TRUNC is
	# unspecified on POSIX, so it is refused rather than guessed.
	if ((flags & 512) && (rw == 0)): return 0 - 22
	# A directory is opened, never created or truncated.
	if ((flags & 65536) && (flags & (64 | 512))): return 0 - 22
	return 0


# Opens path relative to the current directory (or absolute) with
# CreateFileW. Without FS_O_CLOEXEC the handle is inheritable, matching
# POSIX descriptors without O_CLOEXEC; with it the handle stays private.
int fs_native_open_path(char* path, int flags):
	char* wide = fs_native_wide(path)
	if (wide == 0): return 0 - fs_native_errno_from_win32(fs_win32_last_error)
	int directory = flags & 65536
	int attributes = 128  # FILE_ATTRIBUTE_NORMAL
	# FILE_FLAG_BACKUP_SEMANTICS is what lets CreateFileW open a
	# directory; it is only requested where a directory is acceptable.
	if (directory || ((flags & 3) == 0)): attributes = attributes + 33554432
	int[3] security
	security[0] = 24  # SECURITY_ATTRIBUTES.nLength
	security[1] = 0   # lpSecurityDescriptor: inherit the parent's ACL
	security[2] = 1   # bInheritHandle
	char* inherit = cast(char*, &security[0])
	if (flags & 524288): inherit = 0
	int handle = CreateFileW(wide, fs_native_access(flags), 7, inherit, fs_native_creation(flags), attributes, 0)
	if (handle == -1):
		int code = GetLastError()
		# Linux reports a write open of a directory as EISDIR.
		if ((code == 5) && (directory == 0)):
			int found = GetFileAttributesW(wide)
			if ((found != -1) && (found & 16)):
				free(wide)
				fs_win32_last_error = code
				return 0 - 21
		free(wide)
		return fs_native_fail(code)
	free(wide)
	return handle


# Opens path below the directory handle dirfd with NtCreateFile's
# RootDirectory: a true directory-relative open that a concurrent rename
# of the directory cannot redirect. NT resolves no "." or ".." itself;
# "." components and repeated separators are dropped, ".." is EINVAL.
int fs_native_open_relative(int dirfd, char* path, int flags):
	if (dirfd < 0): return 0 - 9
	# Canonical relative name with backslash separators.
	int length = strlen(path)
	char* name = cast(char*, malloc(length + 1))
	int used = 0
	int start = 0
	while (start <= length):
		int end = start
		while ((end < length) && (path[end] != '/') && (path[end] != 92)): end = end + 1
		int size = end - start
		if ((size == 2) && (path[start] == '.') && (path[start + 1] == '.')):
			free(name)
			return 0 - 22
		if ((size > 0) && !((size == 1) && (path[start] == '.'))):
			if (used > 0):
				name[used] = 92
				used = used + 1
			for i in range(size): name[used + i] = path[start + i]
			used = used + size
		start = end + 1
	name[used] = 0
	char* wide = fs_native_wide(name)
	free(name)
	if (wide == 0): return 0 - fs_native_errno_from_win32(fs_win32_last_error)
	int bytes = 0
	while (load_int16(wide + bytes) != 0): bytes = bytes + 2
	if (bytes > 65534):
		free(wide)
		return 0 - 36
	int[2] unicode
	unicode[0] = bytes + (bytes << 16)  # Length, MaximumLength
	unicode[1] = cast(int, wide)
	int[6] object
	object[0] = 48       # OBJECT_ATTRIBUTES.Length
	object[1] = dirfd    # RootDirectory
	object[2] = cast(int, &unicode[0])
	object[3] = 64       # OBJ_CASE_INSENSITIVE, as Win32 resolves names
	if ((flags & 524288) == 0): object[3] = 64 + 2  # OBJ_INHERIT
	object[4] = 0
	object[5] = 0
	int disposition = 1                      # FILE_OPEN
	if (flags & 64):
		disposition = 3                      # FILE_OPEN_IF
		if (flags & 128): disposition = 2    # FILE_CREATE
		else if (flags & 512): disposition = 5  # FILE_OVERWRITE_IF
	else if (flags & 512): disposition = 4   # FILE_OVERWRITE
	int options = 32                         # FILE_SYNCHRONOUS_IO_NONALERT
	if (flags & 65536): options = options + 1  # FILE_DIRECTORY_FILE
	else if (flags & 3): options = options + 64  # FILE_NON_DIRECTORY_FILE
	# SYNCHRONIZE (synchronous I/O) and FILE_READ_ATTRIBUTES beside the
	# generic rights.
	int access = fs_native_access(flags) + 1048576 + 128
	int[2] status_block
	status_block[0] = 0
	status_block[1] = 0
	int handle = 0
	int status = NtCreateFile(&handle, access, cast(char*, &object[0]), cast(char*, &status_block[0]), 0, 128, 7, disposition, options, 0, 0)
	free(wide)
	if (fs_native_status_failed(status)): return fs_native_fail_status(status)
	return handle


int fs_native_openat(int dirfd, char* path, int flags, int mode):
	if (path == 0): return 0 - 14
	int bad = fs_native_check_flags(flags)
	if (bad < 0): return bad
	int handle = 0
	if ((dirfd == 0 - 100) || fs_native_absolute(path)): handle = fs_native_open_path(path, flags)
	else: handle = fs_native_open_relative(dirfd, path, flags)
	if (handle < 0): return handle
	if (flags & 65536):
		int attributes = fs_native_attributes(handle)
		if ((attributes == -1) || ((attributes & 16) == 0)):
			CloseHandle(handle)
			fs_win32_last_error = 267
			return 0 - 20  # ENOTDIR
	return handle


# An OVERLAPPED block carrying offset: Offset and OffsetHigh are the
# low and high halves of the third little-endian word.
void fs_native_overlapped(int* block, int offset):
	block[0] = 0
	block[1] = 0
	block[2] = offset
	block[3] = 0


# A transfer is one DWORD at most; larger requests become partial.
int fs_native_clamp(int count):
	if (count > 1073741824): return 1073741824
	return count


int fs_native_pread(int fd, char* buf, int count, int offset):
	if (fd < 0): return 0 - 9
	if ((offset < 0) || (count < 0)): return 0 - 22
	int[4] block
	fs_native_overlapped(&block[0], offset)
	int done = 0
	if (ReadFile(fd, buf, fs_native_clamp(count), &done, cast(int, &block[0])) == 0):
		int code = GetLastError()
		if (code == 38): return 0  # ERROR_HANDLE_EOF: at or past the end
		return fs_native_fail(code)
	return done & ((1 << 32) - 1)


int fs_native_pwrite(int fd, char* buf, int count, int offset):
	if (fd < 0): return 0 - 9
	if ((offset < 0) || (count < 0)): return 0 - 22
	int[4] block
	fs_native_overlapped(&block[0], offset)
	int done = 0
	if (WriteFile(fd, buf, fs_native_clamp(count), &done, cast(int, &block[0])) == 0): return fs_native_fail(GetLastError())
	return done & ((1 << 32) - 1)


# FileEndOfFileInformation (20): sets the size without touching the
# handle's file pointer (SetEndOfFile would need a seek first).
int fs_native_ftruncate(int fd, int length):
	if (fd < 0): return 0 - 9
	if (length < 0): return 0 - 22
	int[2] status_block
	status_block[0] = 0
	status_block[1] = 0
	int size = length
	int status = NtSetInformationFile(fd, cast(char*, &status_block[0]), cast(char*, &size), 8, 20)
	if (fs_native_status_failed(status)): return fs_native_fail_status(status)
	return 0


# The locked byte: far beyond any file's data (but well inside the
# signed 64-bit range every filesystem accepts).
int fs_native_lock_offset():
	return 1 << 62


# flock-style operations on a LockFileEx range: LOCK_SH (1) / LOCK_EX
# (2), optionally | LOCK_NB (4), or LOCK_UN (8). A lock belongs to its
# handle: a second handle in the same process contends like another
# process does.
int fs_native_flock(int fd, int operation):
	if (fd < 0): return 0 - 9
	int[4] block
	fs_native_overlapped(&block[0], fs_native_lock_offset())
	if (operation & 8):
		if (UnlockFileEx(fd, 0, 1, 0, cast(char*, &block[0])) == 0): return fs_native_fail(GetLastError())
		return 0
	int flags = 0
	if (operation & 2): flags = flags + 2  # LOCKFILE_EXCLUSIVE_LOCK
	if (operation & 4): flags = flags + 1  # LOCKFILE_FAIL_IMMEDIATELY
	if (LockFileEx(fd, flags, 0, 1, 0, cast(char*, &block[0])) == 0): return fs_native_fail(GetLastError())
	return 0


# FlushFileBuffers on a file or directory handle. Pipes, consoles and
# other non-disk handles are EINVAL (fs_fsync: IO_UNSUPPORTED) instead
# of FlushFileBuffers' pipe semantics, which block until the reader
# drains. A filesystem refusing the flush is EINVAL too.
int fs_native_fsync(int fd):
	if (fd < 0): return 0 - 9
	int kind = GetFileType(fd)
	if (kind != 1):  # FILE_TYPE_DISK
		int code = GetLastError()
		if ((kind == 0) && (code != 0)): return fs_native_fail(code)
		return 0 - 22
	if (FlushFileBuffers(fd) == 0):
		int code = GetLastError()
		if ((code == 1) || (code == 50) || (code == 87)):
			fs_win32_last_error = code
			return 0 - 22
		return fs_native_fail(code)
	return 0


int fs_native_close(int fd):
	if (fd < 0): return 0 - 9
	if (CloseHandle(fd) == 0): return fs_native_fail(GetLastError())
	return 0


# Publication: MoveFileExW with MOVEFILE_REPLACE_EXISTING (1) |
# MOVEFILE_WRITE_THROUGH (8). The replacement of newpath is atomic on
# NTFS/ReFS for a same-volume rename, and write-through asks the
# filesystem to commit the rename before returning. It fails while
# another handle holds newpath open without FILE_SHARE_DELETE.
int fs_native_rename(char* oldpath, char* newpath):
	char* from = fs_native_wide(oldpath)
	if (from == 0): return 0 - fs_native_errno_from_win32(fs_win32_last_error)
	char* to = fs_native_wide(newpath)
	if (to == 0):
		free(from)
		return 0 - fs_native_errno_from_win32(fs_win32_last_error)
	int ok = MoveFileExW(from, to, 9)
	free(from)
	free(to)
	if (ok == 0): return fs_native_fail(GetLastError())
	return 0


int fs_native_unlink(char* path):
	char* wide = fs_native_wide(path)
	if (wide == 0): return 0 - fs_native_errno_from_win32(fs_win32_last_error)
	int ok = DeleteFileW(wide)
	free(wide)
	if (ok == 0): return fs_native_fail(GetLastError())
	return 0
