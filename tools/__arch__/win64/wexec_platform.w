# Per-target platform facts for tools/wexec.w (see the x86 sibling
# file). win64 resolution, compiled into bin/wexec_win.exe.


# 1: directory listings work here. wexec_collect_dir's os_windows()
# branch walks directories with FindFirstFileA/FindNextFileA and
# returns before the Linux-layout getdents parsing is ever reached, so
# the dirent-layout caveat this flag guards does not apply on Windows.
int wexec_dirents_supported():
	return 1


/* Run-step process-group cleanup: not available on win64 -- there is
no fork/setpgid model here, and wexec only activates the cleanup when
wexec_process_groups_supported() is 1, so these stubs are never
reached with expectations attached; behavior is byte-for-byte the
pre-existing one (same degrade-to-status-quo pattern as the statx and
remote-cache stubs). */


int wexec_process_groups_supported():
	return 0


int wexec_process_group_enter():
	return -1


void wexec_process_group_assign(int pid):
	return


void wexec_process_group_kill(int pid):
	return


void wexec_install_termination_handler(int handler):
	return
