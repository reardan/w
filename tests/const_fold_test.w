# wbuild: x64
# Constant-folding semantics, pinning the contract in code_generator/x86.w
# (docs/projects/optimization.md's v0 window): when both operands of an
# integer binary operator are literals the compiler rolls back the
# materialization and emits the result directly, and when a constant index
# is scaled for an array access the scale folds into it. None of that may
# change what a program computes -- including at the overflow edges, where
# the fold must decline and leave the runtime instruction in place, and
# around operands with side effects, which must still happen.
import lib.assert

int side_calls

int side(int v):
	side_calls = side_calls + 1
	return v

int identity(int v):
	return v


void test_literal_arithmetic():
	assert_equal(872, 218 * 4)
	assert_equal(123, 100 + 23)
	assert_equal(77, 100 - 23)
	assert_equal(8, 12 & 9)
	assert_equal(13, 12 | 9)
	assert_equal(5, 12 ^ 9)
	# Negative literals: int_literal folds the sign in itself, so these are
	# single immediates on both sides.
	assert_equal(-872, -218 * 4)
	assert_equal(872, -218 * -4)
	assert_equal(-123, -100 + -23)
	assert_equal(0, 0 * 12345)
	assert_equal(0, 12345 * 0)
	# -1 operands are declined by the fold (the overflow probe would have
	# to divide by -1); the answer must still be right.
	assert_equal(-7, 7 * -1)
	assert_equal(-7, -1 * 7)


void test_word_size_operand():
	# The motivating case: both operands compile-time constants.
	assert_equal(218 * __word_size__, 218 * __word_size__)
	assert_equal(__word_size__ * 2, __word_size__ + __word_size__)
	int slots = 221 * __word_size__
	if (__word_size__ == 8):
		assert_equal(1768, slots)
	else:
		assert_equal(884, slots)


void test_constant_index_scaling():
	# The index scale folds into a constant index. Element widths differ so
	# the scaled offsets differ; every read must still land on its own slot.
	int[8] words
	int i = 0
	while (i < 8):
		words[i] = 100 + i
		i = i + 1
	assert_equal(100, words[0])
	assert_equal(103, words[3])
	assert_equal(107, words[7])
	char[8] bytes
	int j = 0
	while (j < 8):
		bytes[j] = 65 + j
		j = j + 1
	assert_equal(65, bytes[0])
	assert_equal(70, bytes[5])


void test_pointer_slot_indexing():
	# The type-table access shape: a word-strided record read through an
	# int*, where the constant index scales by the word size.
	int* rec = cast(int*, malloc(16 * __word_size__))
	int i = 0
	while (i < 16):
		rec[i] = i * 11
		i = i + 1
	assert_equal(0, rec[0])
	assert_equal(55, rec[5])
	assert_equal(165, rec[15])
	rec[9] = 4242
	assert_equal(4242, rec[9])
	assert_equal(88, rec[8])
	free(cast(char*, rec))


void test_overflow_declines():
	# Products that do not fit the compiler's own word must not be folded
	# to a wrapped constant; the runtime imul defines the answer. Spelled
	# through a variable so the expected value is computed the same way the
	# unfolded path would compute it.
	int big = 65536
	assert_equal(big * big, 65536 * 65536)
	int huge = 1000000
	assert_equal(huge * huge, 1000000 * 1000000)
	int m = 2147483647
	assert_equal(m + identity(1), 2147483647 + 1)
	assert_equal(m * identity(2), 2147483647 * 2)


void test_side_effects_preserved():
	# A call on either side means the operand is not a bare literal: the
	# call must still happen exactly once and the arithmetic must be right.
	side_calls = 0
	assert_equal(14, side(7) * 2)
	assert_equal(1, side_calls)
	side_calls = 0
	assert_equal(14, 2 * side(7))
	assert_equal(1, side_calls)
	side_calls = 0
	assert_equal(9, side(4) + 5)
	assert_equal(1, side_calls)
	side_calls = 0
	assert_equal(20, side(2) * side(10))
	assert_equal(2, side_calls)


void test_mixed_and_nested():
	int a = 3
	assert_equal(30, a * (2 * 5))
	assert_equal(30, (2 * 5) * a)
	assert_equal(26, 2 * 10 + 2 * 3)
	assert_equal(1000, 10 * 10 * 10)
	assert_equal(11, 2 * 3 + 5)
	assert_equal(16, 2 + 7 * 2)
	# Division and modulo pop their own operand and are not folded; they
	# must keep working next to the folded operators.
	assert_equal(5, 10 / 2)
	assert_equal(1, 10 % 3)
	assert_equal(7, 20 / 4 + 2)


int main():
	test_literal_arithmetic()
	test_word_size_operand()
	test_constant_index_scaling()
	test_pointer_slot_indexing()
	test_overflow_declines()
	test_side_effects_preserved()
	test_mixed_and_nested()
	println2(c"const_fold_test OK")
	return 0
