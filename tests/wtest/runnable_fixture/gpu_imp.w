# Fixture ROOT for bin/wtest's --runnable-here closure-level needs
# attribution (never executed; selected through
# tests/wtest/manifest_runnable.json): GPU-needing only through its
# import — dep_gpu.w carries the 'import lib.cuda', nothing here does
# — modeling the tensor_gpu_test family's shape (libcuda via
# lib/tensor.w).
import tests.wtest.runnable_fixture.dep_gpu

int main():
	return dep_gpu_probe()
