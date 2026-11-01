# Per-OS pieces of the in-process engine's code buffer on macOS AArch64
# (repl/jit_arm64.w, docs/projects/scripting.md Phase A2).
#
# Native gate: tools/mac/run_darwin_tests.sh. Apple Silicon refuses RWX
# pages unless they are mapped with MAP_JIT, and a
# MAP_JIT page is writable or executable per thread, switched by
# pthread_jit_write_protect_np; instruction-cache maintenance goes through
# libSystem's sys_icache_invalidate.
import lib.lib

c_lib "/usr/lib/libSystem.B.dylib"
extern void jit_host_pthread_jit_write_protect_np(int enabled) = "pthread_jit_write_protect_np"
extern int jit_host_pthread_jit_write_protect_supported_np() = "pthread_jit_write_protect_supported_np"
extern void jit_host_sys_icache_invalidate(int start, int length) = "sys_icache_invalidate"


int jit_host_code_start
int jit_host_code_size
int jit_host_use_mprotect


int jit_host_darwin():
	return 1


# An RWX MAP_JIT mapping (MAP_PRIVATE 0x2 | MAP_ANON 0x1000 | MAP_JIT
# 0x800) when per-thread protection is supported. Otherwise use ordinary
# RW pages, which mprotect can switch to RX; MAP_JIT mappings themselves
# reject mprotect on hardware supporting per-thread protection.
# The internal use_mprotect flag can also select that path before init.
# lib/darwin/syscalls.w's mmap translates only Linux flag bits, so the
# MAP_JIT allocation issues mmap (197) directly.
int jit_host_map(int hint, int size):
	jit_host_use_mprotect = jit_host_use_mprotect || (jit_host_pthread_jit_write_protect_supported_np() == 0)
	int mapped = 0
	if (jit_host_use_mprotect): mapped = mmap(hint, size, 3, 34)
	else: mapped = syscall7(197, hint, size, 7, 6146, -1, 0)
	if ((mapped > 0) || (mapped < -4095)):
		jit_host_code_start = mapped
		jit_host_code_size = size
	return mapped


# executable 1: this thread may run the JIT pages (and not write them);
# 0: it may write them (and not run them). Some virtualized macOS hosts
# do not support per-thread JIT protection: libpthread documents its
# toggle as a no-op there. Enforce W^X with process-wide mprotect instead.
# The engine is single-threaded; keep the pthread toggle as well so the
# fallback can be exercised on hardware with per-thread protection.
void jit_host_write_protect(int executable):
	jit_host_pthread_jit_write_protect_np(executable)
	if (jit_host_use_mprotect):
		int prot = 3 /* R+W */
		if (executable): prot = 5 /* R+X */
		asserts(c"mprotect of the macOS JIT code buffer failed", mprotect(jit_host_code_start, jit_host_code_size, prot) == 0)


int jit_host_icache_invalidate(int start, int length):
	jit_host_sys_icache_invalidate(start, length)
	return 1
