# Per-OS pieces of the in-process engine's code buffer on Android AArch64
# (Linux kernel; repl/jit_arm64.w, docs/projects/scripting.md Phase A1).
import lib.lib


# MAP_FIXED_NOREPLACE (Linux 4.17+): map exactly at the hint or fail with
# -EEXIST instead of replacing an existing mapping. Older kernels ignore
# the flag and treat the address as a plain hint, so callers still check
# where the mapping landed.
const int jit_host_map_fixed_noreplace = 0x100000


int jit_host_darwin():
	return 0


# An RWX private anonymous mapping of size bytes at hint (0: anywhere).
int jit_host_map(int hint, int size):
	int flags = 34 /* PRIVATE|ANONYMOUS */
	if (hint != 0): flags = flags | jit_host_map_fixed_noreplace
	return mmap(hint, size, 7, flags)


# Linux maps the buffer read-write-execute: nothing to toggle.
void jit_host_write_protect(int executable):
	return;


# 0: no OS service; the caller runs its own dc cvau / ic ivau sequence
# (repl_a64_flush), which Linux permits at EL0 (SCTLR_EL1.UCI/UCT).
int jit_host_icache_invalidate(int start, int length):
	return 0
