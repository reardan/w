# Per-target platform facts for tools/wexec.w, resolved through the
# same lib/__arch__-style per-arch import tools/__arch__/
# wexec_remote_http.w already uses. This x86 file is the default-arch
# resolution (bin/wexec, x86 Linux).


# 1 when wexec_collect_dir can produce a real directory listing on this
# platform: its getdents parsing assumes the classic Linux dirent
# layout, which is exactly this target's own, so directory inputs hash
# correctly here. The arm64_darwin sibling returns 0 (Darwin
# getdirentries64 records use a different layout -- see the NOTE in
# lib/__arch__/arm64_darwin/syscalls.w), making wexec warn and treat
# directory inputs as empty instead of silently misparsing them.
int wexec_dirents_supported():
	return 1


/* Run-step process-group cleanup (docs/projects/wexec.md, "Run-step
timeouts and child cleanup"). */


# 1: this target has real Unix process groups -- setpgid and
# kill(-pgid) are plain Linux syscalls, and i386 signal handlers work
# as ordinary W functions (no SA_RESTORER needed: the kernel points the
# frame's return address at the vdso sigreturn trampoline, see the
# rt_sigaction note in lib/__arch__/x86/syscalls.w and
# wdbg_install_handler in debugger/wdbg.w).
int wexec_process_groups_supported():
	return 1


# setpgid(0, 0) (i386 syscall 57): make the calling process the leader
# of a fresh process group, inherited by everything it spawns.
int wexec_process_group_enter():
	return syscall(57, 0, 0, 0)


# setpgid(pid, pid) from the parent's side of the fork -- the classic
# both-sides idiom, so the group targetably exists no matter which side
# runs first. Failure is ignored: the only realistic cause is losing
# the race to the child's own wexec_process_group_enter, which leaves
# exactly the intended group in place.
void wexec_process_group_assign(int pid):
	syscall(57, pid, pid, 0)


# SIGKILL the whole group led by pid: kill with a negative pid targets
# the process group. ESRCH (everyone already gone, the common case for
# the post-reap sweep) is fine and ignored.
void wexec_process_group_kill(int pid):
	kill(0 - pid, 9)


# Install handler for SIGHUP (1), SIGINT (2) and SIGTERM (15). i386
# struct sigaction: {handler, flags, restorer, mask[2]}, five 4-byte
# fields; flags 0, no SA_RESTORER (see wexec_process_groups_supported's
# note above).
void wexec_install_termination_handler(int handler):
	int* act = malloc(5 * __word_size__)
	act[0] = handler
	act[1] = 0
	act[2] = 0
	act[3] = 0
	act[4] = 0
	rt_sigaction(1, act, 0)
	rt_sigaction(2, act, 0)
	rt_sigaction(15, act, 0)
	free(act)
