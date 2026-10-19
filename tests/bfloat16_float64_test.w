# wbuild: arch_only=x64
import lib.testing


bfloat16 brain64_identity(bfloat16 value):
	return value


void test_bfloat16_float64_conversions():
	float64 source = 1.5
	bfloat16 compact = source
	float64 widened = brain64_identity(compact)
	assert_equal(1, source == widened)
	float64 sum = brain64_identity(compact) + source
	assert_equal(1, sum == 3.0)
	bfloat16 negative = cast(float64, -2.5)
	float64 neg_wide = negative
	assert_equal(1, neg_wide == -2.5)
