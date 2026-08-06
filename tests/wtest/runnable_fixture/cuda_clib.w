# Fixture root for bin/wtest's --runnable-here soname probe (never
# executed; selected through tests/wtest/manifest_runnable.json): a
# column-0 c_lib naming libcuda must keep its GPU-bit behavior —
# probed via the NVIDIA driver evidence (/dev/nvidiactl, /dev/nvidia0,
# nvidia-smi), never via the standard-lib-dir soname probe, because
# libcuda.so.1 lives wherever the driver installer put it
# (tools/test_map.w header comment, wtest_soname_retained).
c_lib "libcuda.so.1"

extern int cuInit(int flags)

int main():
	return cuInit(0)
