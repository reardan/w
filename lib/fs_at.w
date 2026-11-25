/*
Confined, descriptor-relative file access: open, list, stat, chmod,
rename and unlink files beneath a directory descriptor such that a path
can never resolve outside that directory and never through a symlink.

Each guarantee comes from the kernel atomically, never from checking a
path and then using it (which a concurrent rename or symlink swap can
race):

  x86 / x86-64 Linux  openat2 (5.6+) with RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS
  arm64 Darwin        openat with O_RESOLVE_BENEATH | O_NOFOLLOW_ANY
                      (macOS, iOS device and simulator)

There is deliberately no fallback. fs_at_supported() reports whether
the running kernel honours both rules; a caller that needs confinement
must refuse to run when it does not. Other targets have no
implementation yet, so importing this module there fails to compile.

Flags are Linux-numbered, as everywhere in lib/ (FS_O_* in lib/fs.w);
the Darwin layer translates them. Every descriptor is close-on-exec.
Results are a descriptor or 0 on success, or a negative errno. ENOENT is
-2 on every target; other errno values are the target's own.

  fs_at_open_beneath(dirfd, path, flags, mode)
      openat beneath dirfd. path is relative ("." names dirfd itself).
      Linux O_PATH is refused on Darwin (-22): use fs_at_open_regular.
  fs_at_open_regular(dirfd, path, out)
      A read-only descriptor for path when it is a regular file, filled
      into out; -22 for any other type. A FIFO or device never blocks the
      caller: Linux inspects it through O_PATH before opening it, Darwin
      opens with O_NONBLOCK | O_NOCTTY and checks the type with fstat.
  fs_at_stat(fd, out)        fstat into lib/stat.w's file_stat.
  fs_at_chmod(fd, mode)      fchmod.
  fs_at_rename(dirfd, from, to)
      renameat of one entry to another in the same directory; both must
      be single names (fs_at_leaf), so no lookup leaves dirfd.
  fs_at_unlink(dirfd, name)  unlinkat of a single name in dirfd.
  fs_at_supported()          1 when the confinement above is enforced.

Directory contents: lib/dir.w's dir_read_fd lists a descriptor opened
here with FS_O_DIRECTORY.
*/
import lib.lib
import lib.stat
import lib.fs


# 1 when name is a single directory entry name: not empty, not "." or
# "..", with no '/'. The only names rename and unlink accept, because
# those calls resolve without the beneath/no-symlink rules.
int fs_at_leaf(char* name):
	if ((name == 0) || (name[0] == 0)): return 0
	if ((name[0] == '.') && ((name[1] == 0) || ((name[1] == '.') && (name[2] == 0)))): return 0
	int i = 0
	while (name[i]):
		if (name[i] == '/'): return 0
		i = i + 1
	return 1


import lib.__arch__.fs_at
