# The in-process engine's per-target hooks for the x86 family
# (docs/projects/scripting.md Phase A; the arm64 targets bind
# repl/jit_arm64.w instead). repl/core.w calls each of them on every
# target: here the buffer is a MAP_32BIT-style RWX mapping holding code
# and inline globals together, the instruction cache is coherent, and
# faults long-jump out of the handler. win64, wasm and iOS never run the
# engine; they share these so the compiler (w.w) builds for them.
import lib.lib


# Inline globals get cache lines of their own: a store into a line the
# core also fetched code from is a self-modifying-code pipeline flush
# (code_generator/code_emitter.w inline_global_line).
void repl_jit_configure():
	inline_global_line = 64


int repl_jit_map_code(int size, int flags):
	return mmap(0, size, 7, flags) /* RWX */


# Code and data share the whole mapping.
int repl_jit_data_init(int buffer, int size):
	return size


void repl_jit_align_global():
	return;


# 0: core.w installs the handler itself.
int repl_jit_install(int signum, int handler, int flags):
	return 0


# 0: core.w long-jumps to the checkpoint.
int repl_jit_fault_resume(int context, int resume_pc, int stack):
	return 0


void repl_jit_open():
	return;


void repl_jit_commit():
	return;
