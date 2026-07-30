# Per-target platform facts for tools/wexec.w (see the x86 sibling
# file). arm64_darwin resolution, compiled into bin/wexec_darwin.


# 0: Darwin's getdents shim returns raw getdirentries64 records whose
# layout (d_ino u64, d_seekoff u64, d_reclen u16, d_namlen u16,
# d_type u8, name) differs from the Linux layout wexec_collect_dir
# parses -- see the NOTE next to getdents in
# lib/__arch__/arm64_darwin/syscalls.w. Parsing them with the Linux
# offsets silently produced an empty file list, i.e. a stable-but-wrong
# cache key. Until per-arch dirent accessors exist
# (docs/projects/ai_tooling_next_steps.md, "wexec directory hashing is
# Linux-layout only"), reporting 0 makes wexec warn once and treat a
# directory input as empty instead of hashing that misparse: the same
# resulting hash, but an honest diagnostic. The darwin build targets
# already declare no directory "inputs" (they are FORCE-style), so
# nothing on macOS relies on directory hashing today.
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
wexec_process_groups_supported() is 1, so behavior here is unchanged. */


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
