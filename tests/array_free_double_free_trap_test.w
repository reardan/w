# A second array_free through the same view must die on the header
# sanity assert: the first free poisons the block's length word to -1
# before releasing it (free itself never touches the descriptor words),
# so the re-check's length >= 0 arm fails (lib/array.w double-free
# guard; under W_DEBUG_ALLOC the re-read of the PROT_NONE block crashes
# with a stack trace instead).
# wbuild: expect_fail
# wbuild: expect_stderr="array_free: not an unsliced heap array"
import lib.lib
import lib.array


void main():
	float[] a = new float[4]
	array_free[float](a)
	array_free[float](a)
