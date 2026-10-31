# The in-process engine's AArch64 hooks, empty on this target
# (docs/projects/scripting.md Phase A): repl/core.w calls the repl_a64_*
# functions only when __target_isa__ is 1 and repl_jit_open/commit
# around every write into the code buffer, which needs no cache
# maintenance here. The arm64 targets bind repl/jit_arm64.w instead.
import lib.lib


void repl_a64_configure():
	return;


int repl_a64_map_code(int size):
	return -12 /* -ENOMEM */


int repl_a64_data_init(int buffer, int size):
	return size


void repl_a64_align_global():
	return;


void repl_a64_install(int signum, int handler, int flags):
	return;


void repl_a64_fault_resume(int context, int resume_pc, int stack):
	return;


void repl_jit_open():
	return;


void repl_jit_commit():
	return;
