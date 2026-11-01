# Per-OS pieces of the in-process engine's code buffer on macOS AArch64
# (repl/jit_arm64.w, docs/projects/scripting.md Phase A2).
#
# Native gate: tools/mac/run_darwin_tests.sh. Apple Silicon refuses RWX pages unless they are mapped with MAP_JIT, and a
# MAP_JIT page is writable or executable per thread, switched by
# pthread_jit_write_protect_np; instruction-cache maintenance goes through
# libSystem's sys_icache_invalidate.
import lib.lib

c_lib "/usr/lib/libSystem.B.dylib"
extern void jit_host_pthread_jit_write_protect_np(int enabled) = "pthread_jit_write_protect_np"
extern void jit_host_sys_icache_invalidate(int start, int length) = "sys_icache_invalidate"


int jit_host_darwin():
	return 1


# An RWX MAP_JIT mapping (MAP_PRIVATE 0x2 | MAP_ANON 0x1000 | MAP_JIT
# 0x800). lib/darwin/syscalls.w's mmap translates only the Linux flag
# bits, so this issues mmap (197) itself. XNU honours a free hint but has
# no MAP_FIXED_NOREPLACE; the caller checks where the mapping landed.
int jit_host_map(int hint, int size):
	return syscall7(197, hint, size, 7, 6146, -1, 0)


# executable 1: this thread may run the JIT pages (and not write them);
# 0: it may write them (and not run them).
void jit_host_write_protect(int executable):
	jit_host_pthread_jit_write_protect_np(executable)


int jit_host_icache_invalidate(int start, int length):
	jit_host_sys_icache_invalidate(start, length)
	return 1
