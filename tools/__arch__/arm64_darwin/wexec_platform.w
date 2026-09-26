const int wexec_process_groups_supported = 0
# Per-target platform facts for tools/wexec.w (see the x86 sibling
# file). arm64_darwin resolution, compiled into bin/wexec_darwin.


# 0: Darwin's getdents shim returns raw getdirentries64 records
# (d_ino u64, d_seekoff u64, d_reclen u16, d_namlen u16, d_type u8,
# name), which lib/__arch__/arm64_darwin/dirent.w decodes for lib/dir.w
# -- but that decoding has not been run on a Mac yet, and a misparse
# would be a silently empty listing, i.e. a stable-but-wrong cache key.
# Reporting 0 makes wexec warn once and treat a directory input as empty
# instead. The darwin build targets declare no directory "inputs" (they
# are FORCE-style), so nothing on macOS relies on directory hashing
# today; flip this to 1 once lib/dir_test.w passes natively there.
int wexec_dirents_supported():
	return 0


/* Run-step process-group cleanup: conservatively reported unsupported
on arm64_darwin. setpgid and kill(-pgid) do exist on Darwin, but the
sweep is anchored on a SIGHUP/SIGINT/SIGTERM handler and plain W
functions cannot be signal handlers on this target (no SA_RESTORER
story like the one debugger/wdbg.w builds for x86-64 Linux), and the
darwin executor's targets are compile-only cross builds today (see
wexec_dirents_supported above for the same keep-the-status-quo
reasoning). wexec only activates the cleanup when
wexec_process_groups_supported is 1, so behavior here is unchanged. */




int wexec_process_group_enter():
	return -1


void wexec_process_group_assign(int pid):
	return


void wexec_process_group_kill(int pid):
	return


void wexec_install_termination_handler(int handler):
	return
