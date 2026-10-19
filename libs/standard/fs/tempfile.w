/*
Temporary files and directories (Python's tempfile.mkstemp / mkdtemp /
gettempdir; libs/standard/plans/05_filesystem.md phase 5).

Names are <prefix><8 random chars><suffix>, the characters drawn from
Python's alphabet [a-z0-9_] using libs/standard/crypto/random.w. Every
candidate is created atomically -- O_CREAT|O_EXCL for files, mkdir for
directories -- so a name somebody else already took is never reused:
EEXIST just draws a fresh name, up to TEMPFILE_MAX_TRIES times. Files
are created mode 0600 and directories 0700 (before umask), readable
only by the creating user.

As in Python >= 3.12, returned paths are absolute: a relative dir is
resolved against the current working directory.

Ownership: every char* returned here is malloc'd and owned by the
caller. Failures return 0 (paths) or a negative errno (descriptors);
the path-returning helpers also leave the errno in tempfile_last_error.
*/
import lib.lib
import lib.path
import lib.env
import lib.fs
import libs.standard.crypto.random


const int TEMPFILE_MAX_TRIES = 10000
const int TEMPFILE_NAME_LEN = 8
const int TEMPFILE_FILE_MODE = 384    # 0600
const int TEMPFILE_DIR_MODE = 448     # 0700
const int TEMPFILE_EEXIST = 17
const int TEMPFILE_ENOENT = 2
const int TEMPFILE_ENOTDIR = 20


# Negative errno of the last failed path-returning call (0 after success).
int tempfile_last_error = 0

# Fallback name state, used only if the kernel CSPRNG is unavailable;
# O_EXCL keeps even predictable names safe, just slower on collisions.
int tempfile_fallback_state = 0


char* tempfile_alphabet():
	return c"abcdefghijklmnopqrstuvwxyz0123456789_"


int tempfile_fallback_next():
	if (tempfile_fallback_state == 0):
		tempfile_fallback_state = (getpid() * 2654435) + 12345
	int x = tempfile_fallback_state
	x = x ^ (x << 13)
	x = x ^ (x >> 7)
	x = x ^ (x << 17)
	if (x == 0): x = 88172645
	tempfile_fallback_state = x
	return x


# Writes TEMPFILE_NAME_LEN random name characters to out (not
# NUL-terminated).
void tempfile_random_chars(char* out):
	char* raw = cast(char*, malloc(TEMPFILE_NAME_LEN))
	int ok = random_bytes(raw, TEMPFILE_NAME_LEN)
	char* alphabet = tempfile_alphabet()
	int i = 0
	while (i < TEMPFILE_NAME_LEN):
		int v = 0
		if (ok): v = raw[i] & 255
		else: v = tempfile_fallback_next() & 1023
		out[i] = alphabet[v % 37]
		i = i + 1
	free(raw)


# A fresh malloc'd "<prefix><random><suffix>" (no directory part).
char* tempfile_random_name(char* prefix, char* suffix):
	int plen = strlen(prefix)
	int slen = strlen(suffix)
	char* name = cast(char*, malloc(plen + TEMPFILE_NAME_LEN + slen + 1))
	strcpy(name, prefix)
	tempfile_random_chars(&name[plen])
	strcpy(&name[plen + TEMPFILE_NAME_LEN], suffix)
	return name


# 1 when path names an existing directory we can open.
int tempfile_is_dir(char* path):
	if ((path == 0) || (path[0] == 0)): return 0
	int fd = sys_openat(FS_AT_FDCWD, path, FS_O_RDONLY | FS_O_DIRECTORY | FS_O_CLOEXEC, 0)
	if (fd < 0): return 0
	close(fd)
	return 1


# path made absolute against the current directory (malloc'd), or a
# clone of it when it already is, or when the cwd is unavailable.
char* tempfile_abspath(char* path):
	if (path[0] == '/'): return strclone(path)
	char* buf = cast(char*, malloc(4097))
	buf[0] = 0
	int got = getcwd(buf, 4096)
	if ((got < 0) || (buf[0] != '/')):
		free(buf)
		return strclone(path)
	char* joined = 0
	if ((path[0] == '.') && (path[1] == 0)): joined = strclone(buf)
	else: joined = path_join(buf, path)
	free(buf)
	return joined


# The first usable directory among the given environment values (each
# may be 0 or empty) and then /tmp, /var/tmp, /usr/tmp and the current
# directory -- Python's _candidate_tempdir_list order. Malloc'd and
# absolute. Split from tempfile_gettempdir so tests can drive it.
char* tempfile_choose_dir(char* tmpdir, char* temp, char* tmp):
	if (tempfile_is_dir(tmpdir)): return tempfile_abspath(tmpdir)
	if (tempfile_is_dir(temp)): return tempfile_abspath(temp)
	if (tempfile_is_dir(tmp)): return tempfile_abspath(tmp)
	if (tempfile_is_dir(c"/tmp")): return strclone(c"/tmp")
	if (tempfile_is_dir(c"/var/tmp")): return strclone(c"/var/tmp")
	if (tempfile_is_dir(c"/usr/tmp")): return strclone(c"/usr/tmp")
	return tempfile_abspath(c".")


# The default directory for temporary files: $TMPDIR, $TEMP, $TMP (the
# first that names a directory), else /tmp (then /var/tmp, /usr/tmp,
# the cwd). Malloc'd.
char* tempfile_gettempdir():
	return tempfile_choose_dir(env_get(c"TMPDIR"), env_get(c"TEMP"), env_get(c"TMP"))


# Alias for tempfile_gettempdir (the parity doc's name).
char* temp_dir():
	return tempfile_gettempdir()


# Resolves the dir/prefix/suffix defaults shared by mkstemp and
# mkdtemp: a 0 dir is tempfile_gettempdir(), a 0 prefix "tmp", a 0
# suffix "". Returns the malloc'd absolute directory.
char* tempfile_resolve_dir(char* dir):
	if (dir == 0): return tempfile_gettempdir()
	return tempfile_abspath(dir)


char* tempfile_default_prefix(char* prefix):
	if (prefix == 0): return c"tmp"
	return prefix


char* tempfile_default_suffix(char* suffix):
	if (suffix == 0): return c""
	return suffix


# mkstemp: creates and opens a new file dir/<prefix>XXXXXXXX<suffix>
# read-write with O_CREAT|O_EXCL|O_CLOEXEC, mode 0600. Returns the
# descriptor and stores the malloc'd absolute path in *path_out, or
# returns a negative errno with *path_out = 0. dir, prefix and suffix
# may each be 0 for the defaults; path_out may be 0 to discard the name.
int tempfile_mkstemp_in(char* dir, char* prefix, char* suffix, char** path_out):
	if (path_out != 0): path_out[0] = 0
	char* base = tempfile_resolve_dir(dir)
	char* pre = tempfile_default_prefix(prefix)
	char* suf = tempfile_default_suffix(suffix)
	int err = 0 - TEMPFILE_EEXIST
	int tries = 0
	while (tries < TEMPFILE_MAX_TRIES):
		char* name = tempfile_random_name(pre, suf)
		char* path = path_join(base, name)
		free(name)
		int fd = sys_openat(FS_AT_FDCWD, path, FS_O_RDWR | FS_O_CREAT | FS_O_EXCL | FS_O_CLOEXEC, TEMPFILE_FILE_MODE)
		if (fd >= 0):
			free(base)
			if (path_out != 0): path_out[0] = path
			else: free(path)
			return fd
		free(path)
		err = fd
		if (fd != (0 - TEMPFILE_EEXIST)): tries = TEMPFILE_MAX_TRIES
		tries = tries + 1
	free(base)
	return err


# mkstemp with the file closed again: returns the malloc'd absolute path
# of a new empty mode-0600 file in tempfile_gettempdir(), or 0 (errno in
# tempfile_last_error). The caller removes it when done.
char* tempfile_mkstemp(char* prefix, char* suffix):
	char* path = 0
	int fd = tempfile_mkstemp_in(0, prefix, suffix, &path)
	if (fd < 0):
		tempfile_last_error = fd
		return 0
	close(fd)
	tempfile_last_error = 0
	return path


# mkdtemp: creates a new directory dir/<prefix>XXXXXXXX<suffix> with
# mode 0700 and returns its malloc'd absolute path, or 0 (errno in
# tempfile_last_error). 0 arguments take the mkstemp defaults.
char* tempfile_mkdtemp_in(char* dir, char* prefix, char* suffix):
	char* base = tempfile_resolve_dir(dir)
	char* pre = tempfile_default_prefix(prefix)
	char* suf = tempfile_default_suffix(suffix)
	int err = 0 - TEMPFILE_EEXIST
	int tries = 0
	while (tries < TEMPFILE_MAX_TRIES):
		char* name = tempfile_random_name(pre, suf)
		char* path = path_join(base, name)
		free(name)
		int rc = mkdir(path, TEMPFILE_DIR_MODE)
		if (rc == 0):
			free(base)
			tempfile_last_error = 0
			return path
		free(path)
		err = rc
		if (rc != (0 - TEMPFILE_EEXIST)): tries = TEMPFILE_MAX_TRIES
		tries = tries + 1
	free(base)
	tempfile_last_error = err
	return 0


# mkdtemp in tempfile_gettempdir() with no suffix.
char* tempfile_mkdtemp(char* prefix):
	return tempfile_mkdtemp_in(0, prefix, 0)
