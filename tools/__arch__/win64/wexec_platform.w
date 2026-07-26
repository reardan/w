# Per-target platform facts for tools/wexec.w (see the x86 sibling
# file). win64 resolution, compiled into bin/wexec_win.exe.


# 1: directory listings work here. wexec_collect_dir's os_windows()
# branch walks directories with FindFirstFileA/FindNextFileA and
# returns before the Linux-layout getdents parsing is ever reached, so
# the dirent-layout caveat this flag guards does not apply on Windows.
int wexec_dirents_supported():
	return 1
