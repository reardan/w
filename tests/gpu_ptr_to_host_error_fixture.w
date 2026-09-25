# A 'gpu T*' (device memory) cannot silently become a host pointer:
# the qualifier partitions pointers into host and device domains and a
# crossing needs an explicit cast() (docs/projects/cuda.md "Execution
# notes (gpu pointer qualifier)"). An error, not the usual mismatch
# warning. Asserted by bin/wfixture in the cuda_diagnostics_test target.
# expect_fail
# expect_stderr: initialization mixes gpu and host pointers: expected 'float32*', got 'gpu float32*'; use cast() to cross the host/device boundary
import lib.lib


int main(int argc, int argv):
	gpu float32* d = cast(gpu float32*, malloc(16))
	float32* h = d
	return cast(int, h)
