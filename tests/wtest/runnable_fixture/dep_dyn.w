# Fixture MODULE for bin/wtest's --runnable-here closure-level needs
# attribution (tools/test_map.w; never executed, reached only through
# tests/wtest/manifest_runnable.json roots): the column-0 c_lib
# directive lives HERE, not in the roots that import this module
# (dyn_imp.w, broken_imp.w), so only a closure-level scan can see it.
c_lib "libc.so.6"

extern int getppid()

int dep_dyn_probe():
	return getppid()
