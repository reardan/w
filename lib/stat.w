/*
Portable file-metadata helpers on top of Linux statx(2) and the sibling
chmod / utimensat / readlink / symlink wrappers in lib/__arch__/syscalls.w.

struct statx (uapi/linux/stat.h) is 256 bytes with an identical field
layout on every Linux ABI the compiler targets; only the syscall NUMBER
differs (x86 383 / x64 332 / arm64 291). Parsing therefore lives once
here with explicit byte offsets. On i386, 64-bit fields are read via
load_word (low 32 bits) -- the same accepted limit lib/time.w documents
for time_now() and that libs/extras/vcs/index.w used for size/mtime.

Darwin / win64 / wasm stubs return -1 from the arch wrappers; callers
see a negative errno-style failure.

Design notes: libs/standard/plans/05_filesystem.md (Phase 1 foundation).
*/
import lib.lib


struct file_stat:
	int mode
	int size
	int mtime
	int atime
	int ctime
	int uid
	int gid
	int nlink
	int ino
	int dev


int FILE_STATX_BUF_SIZE():
	return 256


int FILE_STATX_BASIC_STATS():
	return 2047


# struct statx field offsets (verified against linux/stat.h).
int FILE_STATX_NLINK_OFFSET():
	return 16


int FILE_STATX_UID_OFFSET():
	return 20


int FILE_STATX_GID_OFFSET():
	return 24


int FILE_STATX_MODE_OFFSET():
	return 28


int FILE_STATX_INO_OFFSET():
	return 32


int FILE_STATX_SIZE_OFFSET():
	return 40


int FILE_STATX_ATIME_OFFSET():
	return 64


int FILE_STATX_CTIME_OFFSET():
	return 96


int FILE_STATX_MTIME_OFFSET():
	return 112


int FILE_STATX_DEV_MAJOR_OFFSET():
	return 136


int FILE_STATX_DEV_MINOR_OFFSET():
	return 140


# S_IFMT / type bits from the st_mode word.
int FILE_S_IFMT():
	return 61440


int FILE_S_IFREG():
	return 32768


int FILE_S_IFDIR():
	return 16384


int FILE_S_IFLNK():
	return 40960


int FILE_MODE_PERM_MASK():
	return 511


# Pack major/minor into a single word (traditional low-8-minor makedev).
# Enough for comparing and printing; not a full 64-bit dev_t.
int file_stat_makedev(int major, int minor):
	return ((major & 4095) << 8) | (minor & 255)


# Fills `out` from a successful statx buffer. mode is u16 at offset 28;
# load_int then mask so the adjacent spare halfword is ignored.
void file_stat_from_statx(char* buf, file_stat* out):
	out.mode = load_int(buf + FILE_STATX_MODE_OFFSET()) & 65535
	out.nlink = load_int(buf + FILE_STATX_NLINK_OFFSET())
	out.uid = load_int(buf + FILE_STATX_UID_OFFSET())
	out.gid = load_int(buf + FILE_STATX_GID_OFFSET())
	out.ino = load_word(buf + FILE_STATX_INO_OFFSET())
	out.size = load_word(buf + FILE_STATX_SIZE_OFFSET())
	out.atime = load_word(buf + FILE_STATX_ATIME_OFFSET())
	out.ctime = load_word(buf + FILE_STATX_CTIME_OFFSET())
	out.mtime = load_word(buf + FILE_STATX_MTIME_OFFSET())
	int major = load_int(buf + FILE_STATX_DEV_MAJOR_OFFSET())
	int minor = load_int(buf + FILE_STATX_DEV_MINOR_OFFSET())
	out.dev = file_stat_makedev(major, minor)


int file_statx_fill(char* path, int flags, file_stat* out):
	char* buf = malloc(FILE_STATX_BUF_SIZE())
	int err = statx(path, flags, FILE_STATX_BASIC_STATS(), buf)
	if (err == 0):
		file_stat_from_statx(buf, out)
	free(buf)
	return err


# Follow symlinks (stat(2) behavior). Named file_stat_path rather than
# file_stat so it does not collide with the struct's constructor.
int file_stat_path(char* path, file_stat* out):
	return file_statx_fill(path, 0, out)


# Do not follow symlinks (lstat(2) behavior).
int file_lstat_path(char* path, file_stat* out):
	return file_statx_fill(path, at_symlink_nofollow(), out)


int file_is_reg(file_stat* st):
	return (st.mode & FILE_S_IFMT()) == FILE_S_IFREG()


int file_is_dir(file_stat* st):
	return (st.mode & FILE_S_IFMT()) == FILE_S_IFDIR()


int file_is_lnk(file_stat* st):
	return (st.mode & FILE_S_IFMT()) == FILE_S_IFLNK()


int file_mode_perm(file_stat* st):
	return st.mode & FILE_MODE_PERM_MASK()


int file_chmod(char* path, int mode):
	return chmod(path, mode)


# Update atime/mtime to now. When create_if_missing is set and the path
# does not exist, create an empty regular file first (mode 0666 & ~umask
# via create_file's 420 = 0644 default used elsewhere in the tree).
int file_touch(char* path, int create_if_missing):
	int err = utimensat(path, 0, 0)
	if (err == 0):
		return 0
	if ((create_if_missing == 0) | (err != (0 - 2))):
		return err
	# ENOENT: create then stamp.
	int fd = create_file(path, 420)
	if (fd < 0):
		return fd
	close(fd)
	return utimensat(path, 0, 0)


# Copy the symlink target into buf (NUL-terminated when there is room).
# Returns the byte count of the target (excluding the NUL we may add),
# or a negative errno. When the kernel wrote exactly `size` bytes the
# buffer is not NUL-terminated -- match readlink(2).
int file_readlink(char* path, char* buf, int size):
	int n = readlink(path, buf, size)
	if (n < 0):
		return n
	if (n < size):
		buf[n] = 0
	return n


int file_symlink(char* target, char* linkpath):
	return symlink(target, linkpath)
