const int wexec_process_groups_supported = 0
# Per-target platform facts for tools/wexec.w (see the x86 sibling
# file). arm64_darwin resolution, compiled into bin/wexec_darwin.


# Native discovery and recursive directory hashing are covered by
# tests/build_host_test.w and tools/mac/test_build.sh.
int wexec_dirents_supported():
	return 1


/* Run-step process-group cleanup: conservatively reported unsupported
on arm64_darwin. setpgid and kill(-pgid) do exist on Darwin, but the
sweep is anchored on a SIGHUP/SIGINT/SIGTERM handler and plain W
functions cannot be signal handlers on this target (no SA_RESTORER
story like the one debugger/wdbg.w builds for x86-64 Linux), so native discovery does not enable process-group cleanup. wexec only activates the cleanup when
wexec_process_groups_supported is 1, so behavior here is unchanged. */




int wexec_process_group_enter():
	return -1


void wexec_process_group_assign(int pid):
	return


void wexec_process_group_kill(int pid):
	return


void wexec_install_termination_handler(int handler):
	return
