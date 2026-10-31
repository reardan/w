# Per-OS pieces of the in-process engine's code buffer (repl/jit_arm64.w,
# docs/projects/scripting.md Phase A). The in-process engine does not run
# on this target: these exist so the shared import resolves when the
# compiler (w.w) is built for it, and the buffer request always fails.
import lib.lib


int jit_host_darwin():
	return 0


# -ENOMEM: no executable buffer on this target.
int jit_host_map(int hint, int size):
	return -12


void jit_host_write_protect(int executable):
	return;


int jit_host_icache_invalidate(int start, int length):
	return 0
