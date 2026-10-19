/*
High-level file operations (Python's shutil; libs/standard/plans/
05_filesystem.md phase 6): copy file contents and permission bits,
copy and remove directory trees, move across filesystems, and report
disk usage.

Every function returns 0 on success or a negative errno (Linux
numbering: -2 ENOENT, -17 EEXIST, -18 EXDEV, -20 ENOTDIR, -21 EISDIR,
-22 EINVAL, ...). Paths are borrowed, never freed.

copy fast paths: shutil_copyfile first tries copy_file_range(2) (Linux
>= 4.5; reflinks on CoW filesystems), then sendfile(2), then a plain
read/write loop. A fast path that fails before copying anything (ENOSYS
on an old kernel or a non-Linux target, EXDEV across filesystems,
EINVAL for special files) or that reports EOF on its first call (procfs
and sysfs files claim size 0) hands over to the next method. The arch
wrappers live in lib/__arch__/<target>/copy_range.w; Darwin, win64 and
wasm report ENOSYS there and always copy with read/write.
shutil_last_copy_method says which method finished the last copy.

Metadata: on win64 and wasm lib/stat.w's statx and chmod are
stubs, so copy_mode / the same-file check / directory detection fail or
are skipped there; Linux x86, x64, arm64 and Darwin are supported.
shutil_disk_usage likewise needs statfs(2) (Linux only).

Symlinks are followed when copying (Python's default symlinks=False):
a link to a file is copied as a regular file, a link to a directory as
a directory. shutil_rmtree never follows them.
*/
import lib.lib
import lib.path
import lib.fs
import lib.stat
import lib.dir
import lib.__arch__.copy_range


const int SHUTIL_ENOENT = 2
const int SHUTIL_EINTR = 4
const int SHUTIL_EEXIST = 17
const int SHUTIL_EXDEV = 18
const int SHUTIL_ENOTDIR = 20
const int SHUTIL_EISDIR = 21
const int SHUTIL_EINVAL = 22

# shutil_copy_fd strategies / shutil_last_copy_method values.
const int SHUTIL_COPY_AUTO = 0
const int SHUTIL_COPY_RANGE = 1       # copy_file_range(2)
const int SHUTIL_COPY_SENDFILE = 2    # sendfile(2)
const int SHUTIL_COPY_READ_WRITE = 3  # user-space buffer loop

const int SHUTIL_BUF_SIZE = 65536
# Largest single fast-path request: positive on every word size.
const int SHUTIL_CHUNK = 1073741824

# Files created by copyfile: 0666 before umask, like open(dst, "wb").
const int SHUTIL_FILE_MODE = 438
const int SHUTIL_DIR_MODE = 511

# Method that completed the most recent shutil_copy_fd / copyfile.
int shutil_last_copy_method = 0


/* Descriptor-level copy */

# Runs one fast path (SHUTIL_COPY_RANGE or SHUTIL_COPY_SENDFILE) from
# in_fd's position to EOF. Returns bytes copied (>= 0) when it reached
# EOF, -1 when it could not start (nothing copied: try another method),
# or another negative errno when it failed part-way.
int shutil_fast_copy(int in_fd, int out_fd, int method):
	int total = 0
	while (1):
		int got = 0
		if (method == SHUTIL_COPY_RANGE): got = copy_range_file(in_fd, out_fd, SHUTIL_CHUNK)
		else: got = copy_range_sendfile(out_fd, in_fd, SHUTIL_CHUNK)
		if (got > 0): total = total + got
		else if (got == 0):
			if (total == 0): return -1
			return total
		else if (got != (0 - SHUTIL_EINTR)):
			if (total == 0): return -1
			return got
	return total


# User-space copy of in_fd's remaining bytes to out_fd. Returns 0 or a
# negative errno.
int shutil_read_write_copy(int in_fd, int out_fd):
	char* buf = cast(char*, malloc(SHUTIL_BUF_SIZE))
	int status = 0
	int done = 0
	while (done == 0):
		int got = read(in_fd, buf, SHUTIL_BUF_SIZE)
		if (got == 0): done = 1
		else if (got < 0):
			if (got != (0 - SHUTIL_EINTR)):
				status = got
				done = 1
		else:
			int off = 0
			while ((off < got) && (status == 0)):
				int put = write(out_fd, &buf[off], got - off)
				if (put > 0): off = off + put
				else if (put == 0): status = 0 - 5
				else if (put != (0 - SHUTIL_EINTR)): status = put
			if (status != 0): done = 1
	free(buf)
	return status


# Copies everything from in_fd's current position to EOF into out_fd at
# its current position. strategy SHUTIL_COPY_AUTO tries copy_file_range,
# then sendfile, then read/write; SHUTIL_COPY_RANGE or _SENDFILE try just
# that fast path before read/write; SHUTIL_COPY_READ_WRITE skips the
# fast paths. Returns 0 or a negative errno; sets shutil_last_copy_method.
int shutil_copy_fd(int in_fd, int out_fd, int strategy):
	int first = SHUTIL_COPY_RANGE
	int last = SHUTIL_COPY_SENDFILE
	if (strategy == SHUTIL_COPY_RANGE): last = SHUTIL_COPY_RANGE
	else if (strategy == SHUTIL_COPY_SENDFILE): first = SHUTIL_COPY_SENDFILE
	else if (strategy != SHUTIL_COPY_AUTO): first = SHUTIL_COPY_READ_WRITE
	int method = first
	while (method <= last):
		int r = shutil_fast_copy(in_fd, out_fd, method)
		if (r >= 0):
			shutil_last_copy_method = method
			return 0
		if (r != -1): return r
		method = method + 1
	shutil_last_copy_method = SHUTIL_COPY_READ_WRITE
	return shutil_read_write_copy(in_fd, out_fd)


/* Files */

# 1 when both paths stat successfully and name the same inode.
int shutil_same_file(char* a, char* b):
	file_stat sa
	file_stat sb
	if (file_stat_path(a, &sa) != 0): return 0
	if (file_stat_path(b, &sb) != 0): return 0
	return (sa.ino == sb.ino) && (sa.dev == sb.dev)


# 1 when path (following symlinks) is a directory.
int shutil_is_dir(char* path):
	file_stat st
	if (file_stat_path(path, &st) != 0): return 0
	return file_is_dir(&st)


# copyfile with an explicit shutil_copy_fd strategy.
int shutil_copyfile_with(char* src, char* dst, int strategy):
	if (shutil_same_file(src, dst)): return 0 - SHUTIL_EINVAL
	if (shutil_is_dir(src)): return 0 - SHUTIL_EISDIR
	int in_fd = sys_openat(FS_AT_FDCWD, src, FS_O_RDONLY | FS_O_CLOEXEC, 0)
	if (in_fd < 0): return in_fd
	int out_fd = sys_openat(FS_AT_FDCWD, dst, FS_O_WRONLY | FS_O_CREAT | FS_O_TRUNC | FS_O_CLOEXEC, SHUTIL_FILE_MODE)
	if (out_fd < 0):
		close(in_fd)
		return out_fd
	int status = shutil_copy_fd(in_fd, out_fd, strategy)
	close(in_fd)
	int rc = close(out_fd)
	if ((status == 0) && (rc < 0)): status = rc
	return status


# Copies src's contents to dst (created 0666 & ~umask, or truncated and
# overwritten when it exists; its mode is kept). No metadata is copied.
# Fails with -EINVAL when src and dst are the same file, -EISDIR when
# either is a directory, or src's open errno (e.g. -ENOENT).
int shutil_copyfile(char* src, char* dst):
	return shutil_copyfile_with(src, dst, SHUTIL_COPY_AUTO)


# Copies src's permission bits (including setuid/setgid/sticky) to dst.
int shutil_copymode(char* src, char* dst):
	file_stat st
	int err = file_stat_path(src, &st)
	if (err != 0): return err
	return file_chmod(dst, file_mode_perm(&st))


# The destination path for copy/move: dst/basename(src) when dst is an
# existing directory, else a clone of dst. Malloc'd.
char* shutil_target(char* src, char* dst):
	if (shutil_is_dir(dst) == 0): return strclone(dst)
	char* base = path_basename(src)
	char* target = path_join(dst, base)
	free(base)
	return target


# Python's shutil.copy: copyfile + copymode, where dst may be a
# directory to copy into under src's basename.
int shutil_copy(char* src, char* dst):
	char* target = shutil_target(src, dst)
	int err = shutil_copyfile(src, target)
	if (err == 0): err = shutil_copymode(src, target)
	free(target)
	return err


/* Trees */

# Recursively copies the directory src to dst, which must not exist
# (-EEXIST otherwise). Directories are created and get src's mode
# after their contents are copied; files are copied with shutil_copy;
# symlinks are followed. Copying continues past failing entries and the
# first error is returned. Refuses (-EINVAL) to copy a tree into itself.
int shutil_copytree(char* src, char* dst):
	if (shutil_is_dir(src) == 0):
		file_stat st
		int serr = file_stat_path(src, &st)
		if (serr != 0): return serr
		return 0 - SHUTIL_ENOTDIR
	list[dir_entry*] entries = dir_read(src)
	if (entries == 0): return 0 - SHUTIL_ENOENT
	int err = mkdir(dst, SHUTIL_DIR_MODE)
	if (err != 0):
		dir_entries_free(entries)
		return err
	int status = 0
	for dir_entry* e in entries:
		char* from = path_join(src, e.name)
		char* to = path_join(dst, e.name)
		int rc = 0
		if (shutil_same_file(from, dst)): rc = 0 - SHUTIL_EINVAL
		else if (shutil_is_dir(from)): rc = shutil_copytree(from, to)
		else: rc = shutil_copy(from, to)
		if ((rc != 0) && (status == 0)): status = rc
		free(from)
		free(to)
	dir_entries_free(entries)
	int mrc = shutil_copymode(src, dst)
	if ((mrc != 0) && (status == 0)): status = mrc
	return status


# 1 for paths rmtree refuses outright: "", "/", "." and "..", however
# spelled (trailing slashes, "./", "//").
int shutil_dangerous_root(char* path):
	if ((path == 0) || (path[0] == 0)): return 1
	char* norm = path_normalize(path)
	int bad = (strcmp(norm, c"/") == 0) || (strcmp(norm, c".") == 0) || (strcmp(norm, c"..") == 0) || (strcmp(norm, c"") == 0)
	free(norm)
	return bad


# rm -r for a directory tree: removes path and everything under it,
# never following symlinks (a symlinked subdirectory is unlinked, not
# entered). Refuses with -EINVAL for "", "/", "." and ".."; -ENOENT when
# path does not exist; -ENOTDIR when path is a file or a symlink (even
# to a directory), as Python's rmtree does. Returns 0 or -1 when part of
# the tree could not be removed (lib/dir.w's dir_remove_all).
int shutil_rmtree(char* path):
	if (shutil_dangerous_root(path)): return 0 - SHUTIL_EINVAL
	file_stat st
	int err = file_lstat_path(path, &st)
	if (err != 0): return err
	if (file_is_dir(&st) == 0): return 0 - SHUTIL_ENOTDIR
	return dir_remove_all(path)


# The EXDEV half of shutil_move: copy src to target, then remove src.
int shutil_move_copy(char* src, char* target):
	int err = 0
	if (shutil_is_dir(src)):
		err = shutil_copytree(src, target)
		if (err == 0): err = shutil_rmtree(src)
	else:
		err = shutil_copy(src, target)
		if (err == 0): err = unlink(src)
	return err


# Python's shutil.move: rename(2) src to dst (or into dst when dst is an
# existing directory); across filesystems (EXDEV) copy -- copytree for
# a directory, copy for a file -- then remove src. Returns 0 or a
# negative errno; -EEXIST when the target inside a directory dst
# already exists, -EINVAL when moving a directory into itself.
int shutil_move(char* src, char* dst):
	char* target = shutil_target(src, dst)
	if ((shutil_is_dir(dst) != 0) && (path_exists(target) != 0)):
		free(target)
		return 0 - SHUTIL_EEXIST
	if (shutil_is_dir(src) && path_is_within(src, target)):
		free(target)
		return 0 - SHUTIL_EINVAL
	int err = rename(src, target)
	if (err == (0 - SHUTIL_EXDEV)): err = shutil_move_copy(src, target)
	free(target)
	return err


/* Disk usage */

struct shutil_usage:
	int total      # bytes on the filesystem
	int used       # bytes in use (total - free blocks, incl. reserved)
	int free       # bytes available to unprivileged users
	int block_size
	int total_blocks
	int free_blocks
	int avail_blocks


# Block count * block size, clamped to the largest positive word (byte
# totals overflow 31 bits on i386 for any filesystem over 2 GiB; the
# *_blocks fields stay exact there up to 2^31 blocks).
int shutil_blocks_to_bytes(int blocks, int bsize):
	if ((blocks <= 0) || (bsize <= 0)): return 0
	int max = (1 << ((__word_size__ * 8) - 2)) - 1
	max = max + max + 1
	if (blocks > (max / bsize)): return max
	return blocks * bsize


# statvfs-style usage of the filesystem holding path (Python's
# shutil.disk_usage): fills out and returns 0, or a negative errno.
# Linux only (statfs(2)); other targets return -1.
int shutil_disk_usage(char* path, shutil_usage* out):
	file_fs_stat fs
	int err = file_statfs(path, &fs)
	if (err != 0): return err
	out.block_size = fs.bsize
	out.total_blocks = fs.blocks
	out.free_blocks = fs.bfree
	out.avail_blocks = fs.bavail
	out.total = shutil_blocks_to_bytes(fs.blocks, fs.bsize)
	out.used = shutil_blocks_to_bytes(fs.blocks - fs.bfree, fs.bsize)
	out.free = shutil_blocks_to_bytes(fs.bavail, fs.bsize)
	return 0
