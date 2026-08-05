# Fixture MODULE for bin/wtest's --runnable-here closure-level needs
# attribution (tools/test_map.w; never executed, reached only through
# tests/wtest/manifest_runnable.json roots): the column-0
# 'import lib.cuda' lives HERE, not in the root that imports this
# module (gpu_imp.w), so only a closure-level scan can see it —
# modeling lib/tensor.w's shape.
import lib.cuda

int dep_gpu_probe():
	return 0
