# Per-OS pieces of the in-process engine's code buffer (repl/jit_arm64.w,
# docs/projects/scripting.md Phase A). The x86 family keeps its own
# buffer setup in repl/core.w (MAP_32BIT on x64) and needs no cache
# maintenance or write protection: these exist so the shared import
# resolves on every target the REPL compiles for, and are never called.
import lib.lib


int jit_host_darwin():
	return 0


int jit_host_map(int hint, int size):
	return mmap(hint, size, 7, 34)


void jit_host_write_protect(int executable):
	return;


int jit_host_icache_invalidate(int start, int length):
	return 0
