# Disk-change detection and compare-and-swap saves for the Mermaid editor.
#
# A save publishes only over the exact bytes the editor last read or wrote
# (its baseline). It stages the new bytes in a same-directory temp file,
# claims the current file by renaming it aside, compares the claimed bytes
# with the baseline and only then places the temp file with a no-replace
# link. A writer that replaced, created or deleted the file at any point
# before the claim is detected; one that creates the path after the claim
# makes the placement fail. Either way nothing it wrote is overwritten, and
# the save reports MM_SAVE_CONFLICT. See docs/projects/mermaid.md.
#
# Windows has no lib.fs adapter (fs_open is ENOSYS there), so the same
# protocol runs on the portable open/write/fsync/rename calls: MoveFile
# never replaces an existing name, which gives the no-replace placement,
# and NTFS journals the rename itself (there is no directory barrier).
import libs.extras.mermaid.io
import lib.stat
import lib.__arch__.hardlink

const int MM_SAVE_OK = 0
const int MM_SAVE_CONFLICT = 1
const int MM_SAVE_FAILED = 2

const int MM_DISK_SAME = 0
const int MM_DISK_CHANGED = 1
const int MM_DISK_MISSING = 2

# Test-only race injection: called with the target path and a stage
# (1 after the pre-check, before the claim; 2 after the claim, before the
# placement; 3 after the placement, before the claimed copy is released).
type mm_save_hook_fn = fn(char*, int) -> int
mm_save_hook_fn* mm_save_race_hook
int mm_save_sequence

# Cheap polling fingerprint. Win64 and wasm report no metadata, so callers
# fall back to content comparison there.
struct mm_disk_stamp:
	int valid
	int size
	int mtime
	int ctime
	int ino
	int dev

void mm_disk_stamp_read(char* path, mm_disk_stamp* out):
	file_stat st
	out.valid = file_stat_path(path, &st) == 0
	out.size = 0
	out.mtime = 0
	out.ctime = 0
	out.ino = 0
	out.dev = 0
	if (out.valid == 0): return
	out.size = st.size
	out.mtime = st.mtime
	out.ctime = st.ctime
	out.ino = st.ino
	out.dev = st.dev

int mm_disk_stamp_same(mm_disk_stamp* a, mm_disk_stamp* b):
	if (a.valid == 0 || b.valid == 0): return 0
	return a.size == b.size && a.mtime == b.mtime && a.ctime == b.ctime && a.ino == b.ino && a.dev == b.dev

void mm_save_hook(char* path, int stage):
	if (mm_save_race_hook != 0): mm_save_race_hook(path, stage)

# 1 when path holds exactly baseline's bytes. Unreadable or oversized files
# never match.
int mm_disk_matches(char* path, char* baseline):
	int length = 0
	char* disk = mm_read_source(path, &length)
	if (disk == 0): return 0
	int same = length == strlen(baseline)
	if (same):
		for i in range(length):
			if (disk[i] != baseline[i]):
				same = 0
				break
	free(disk)
	return same

# Treat unreadable paths as occupied; only ENOENT means absent. On
# Windows any failed open counts as absent (no errno is reported).
int mm_disk_present(char* path):
	if (os_windows()):
		int handle = open(path, 0, 0)
		if (handle < 0): return 0
		close(handle)
		return 1
	io_result result
	int fd = fs_open(path, FS_O_RDONLY, 0, &result)
	if (fd < 0): return result.native_error != 2
	io_close(fd, &result)
	return 1

# 0 when an existing file refuses writing: no write permission, or the
# Windows read-only attribute. The save replaces the file by rename, which
# only needs the directory to be writable, so without this check a
# read-only file would be silently replaced. Opening for writing without
# truncation checks exactly the file's own permission and leaves its bytes
# and timestamps alone.
int mm_disk_writable(char* path):
	if (os_windows()):
		int handle = open(path, FS_O_WRONLY, 0)
		if (handle < 0): return 0
		close(handle)
		return 1
	io_result result
	int fd = fs_open(path, FS_O_WRONLY, 0, &result)
	if (fd < 0): return 0
	io_close(fd, &result)
	return 1

# MM_DISK_* for path against the baseline the editor holds. present says
# whether the baseline is an existing file (0: the path should be absent).
int mm_disk_compare(char* path, int present, char* baseline):
	if (mm_disk_present(path) == 0):
		if (present): return MM_DISK_MISSING
		return MM_DISK_SAME
	if (present == 0): return MM_DISK_CHANGED
	if (mm_disk_matches(path, baseline)): return MM_DISK_SAME
	return MM_DISK_CHANGED

char* mm_save_sibling(char* path, char* kind):
	string_builder* name = string_from(path)
	string_append(name, kind)
	string_append_int(name, getpid())
	string_append_char(name, '.')
	string_append_int(name, mm_save_sequence)
	mm_save_sequence = mm_save_sequence + 1
	char* text = name.data
	free(name)
	return text

# Windows staging: callers pass fresh per-process names, so a presence
# check stands in for O_EXCL; FlushFileBuffers is the barrier.
int mm_save_write_new_windows(char* path, char* data, int length):
	if (mm_disk_present(path)): return 1
	int fd = open(path, FS_O_WRONLY | FS_O_CREAT | FS_O_TRUNC, 0)
	if (fd < 0): return 2
	int done = 0
	while (done < length):
		int count = write(fd, data + done, length - done)
		if (count <= 0): break
		done = done + count
	int ok = done == length && fsync(fd) == 0
	if (close(fd) != 0): ok = 0
	if (ok): return 0
	unlink(path)
	return 2

# Exclusive, synced creation of a new file; 0 when it was fully written.
int mm_save_write_new(char* path, char* data, int length, int mode):
	if (os_windows()): return mm_save_write_new_windows(path, data, length)
	io_result result
	int fd = fs_create_exclusive(path, mode, &result)
	if (fd < 0):
		if (fs_result_exists(&result)): return 1
		return 2
	int ok = io_write_all(fd, data, length, &result) == IO_OK
	if (fs_fsync(fd, &result) != IO_OK): ok = 0
	if (io_close(fd, &result) != IO_OK): ok = 0
	if (ok): return 0
	unlink(path)
	return 2

# Stage bytes in a fresh sibling; returns its malloc'd name or 0.
char* mm_save_stage(char* path, char* data, int length, int mode):
	for attempt in range(16):
		char* temp = mm_save_sibling(path, c".tmp.")
		int status = mm_save_write_new(temp, data, length, mode)
		if (status == 0): return temp
		free(temp)
		if (status != 1): return 0
	return 0

# Publish src at dst without ever replacing an existing dst: 0 placed,
# 1 dst exists (conflict), 2 failed. Windows' MoveFile never replaces; POSIX
# targets use link(2). Filesystems without hard links fall back to an
# exclusive copy, which is still no-replace but not atomic for readers.
int mm_save_place(char* src, char* dst, char* data, int length, int mode):
	if (os_windows()):
		if (rename(src, dst) == 0): return 0
		if (mm_disk_present(dst)): return 1
		return 2
	int linked = shell_hardlink(src, dst)
	if (linked == 0):
		unlink(src)
		return 0
	if (linked == 0 - FS_EEXIST): return 1
	int copied = mm_save_write_new(dst, data, length, mode)
	if (copied == 0): unlink(src)
	return copied

# Put a claimed copy back where it came from, never over a newer file. On
# failure the claim stays on disk and its name is returned for recovery.
char* mm_save_restore(char* claim, char* path):
	if (claim == 0): return 0
	if (os_windows() == 0 && shell_hardlink(claim, path) == 0):
		unlink(claim)
		free(claim)
		return 0
	if (os_windows() && rename(claim, path) == 0):
		free(claim)
		return 0
	return claim

# Compare-and-swap save. present/baseline describe what the editor last saw.
# *recovery receives a malloc'd path when another writer's bytes had to be
# set aside (they are never deleted); the caller reports and frees it.
int mm_save_cas(char* path, int present, char* baseline, char* data, int length, char** recovery):
	*recovery = 0
	if (mm_disk_compare(path, present, baseline) != MM_DISK_SAME): return MM_SAVE_CONFLICT
	if (present && mm_disk_writable(path) == 0): return MM_SAVE_FAILED
	int mode = FS_DEFAULT_MODE
	file_stat st
	if (present && os_windows() == 0 && file_stat_path(path, &st) == 0): mode = st.mode & FILE_MODE_PERM_MASK
	char* temp = mm_save_stage(path, data, length, mode)
	if (temp == 0): return MM_SAVE_FAILED
	mm_save_hook(path, 1)
	char* claim = 0
	if (present):
		claim = mm_save_sibling(path, c".claim.")
		if (rename(path, claim) != 0):
			free(claim)
			unlink(temp)
			free(temp)
			if (mm_disk_present(path) == 0): return MM_SAVE_CONFLICT
			return MM_SAVE_FAILED
		if (mm_disk_matches(claim, baseline) == 0):
			*recovery = mm_save_restore(claim, path)
			unlink(temp)
			free(temp)
			return MM_SAVE_CONFLICT
	else if (mm_disk_present(path)):
		unlink(temp)
		free(temp)
		return MM_SAVE_CONFLICT
	mm_save_hook(path, 2)
	int placed = mm_save_place(temp, path, data, length, mode)
	if (placed != 0):
		unlink(temp)
		free(temp)
		if (claim != 0):
			if (mm_disk_matches(claim, baseline)):
				# The claim holds only the baseline, which the editor has.
				if (mm_disk_present(path)):
					unlink(claim)
					free(claim)
				else: *recovery = mm_save_restore(claim, path)
			else: *recovery = claim
		if (placed == 1): return MM_SAVE_CONFLICT
		return MM_SAVE_FAILED
	free(temp)
	mm_save_hook(path, 3)
	int status = MM_SAVE_OK
	if (claim != 0):
		# An in-place writer still holding the old file wrote into the claim.
		if (mm_disk_matches(claim, baseline)):
			unlink(claim)
			free(claim)
		else:
			*recovery = claim
			status = MM_SAVE_CONFLICT
	if (os_windows()): return status
	io_result result
	if (fs_sync_parent_dir(path, &result) != IO_OK && status == MM_SAVE_OK): status = MM_SAVE_FAILED
	return status
