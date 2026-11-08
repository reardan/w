# wbuild: x64
# W has no 'volatile' qualifier because it needs none: the code generator
# performs every memory access the source names, once, in source order,
# at the declared width (docs/projects/object_files.md, "Memory
# accesses"). C translations rely on that for volatile objects,
# READ_ONCE/WRITE_ONCE and device registers. These tests pin the
# observable halves of it:
#
# - a loop condition re-reads a global and a pointer target on every
#   iteration: another thread's store ends the spin;
# - narrow stores stay narrow: the neighbouring bytes survive.
#
# A read whose value is discarded ('*p' as a statement) is performed
# under --kernel-codegen; tests/kernel_codegen_test.w checks that.
import lib.testing
import lib.thread
import lib.time


int mao_flag
int* mao_shared


void mao_set_flag(void* arg):
	sleep_ms(20)
	mao_flag = 1
	sleep_ms(20)
	*mao_shared = 7


void test_spin_loops_reread():
	mao_flag = 0
	mao_shared = cast(int*, malloc(__word_size__))
	*mao_shared = 0
	wthread* t = thread_spawn(mao_set_flag, cast(void*, 0))
	assert1(t != 0)
	int spins = 0
	while (mao_flag == 0): spins = spins + 1
	int* p = mao_shared
	while (*p == 0): pass
	assert_equal(7, *p)
	thread_join(t)
	assert1(spins > 0)
	free(cast(void*, mao_shared))


void test_narrow_stores_stay_narrow():
	char* bytes = cast(char*, malloc(16))
	for i in range(16): bytes[i] = cast(char, 0xee)
	bytes[3] = cast(char, 1)
	int16* halves = cast(int16*, bytes + 6)
	halves[0] = cast(int16, 0x0202)
	int32* words = cast(int32*, bytes + 10)
	words[0] = cast(int32, 0x03030303)
	assert_equal(0xee, bytes[2] & 255)
	assert_equal(1, bytes[3])
	assert_equal(0xee, bytes[4] & 255)
	assert_equal(0xee, bytes[5] & 255)
	assert_equal(2, bytes[6])
	assert_equal(2, bytes[7])
	assert_equal(0xee, bytes[8] & 255)
	assert_equal(0xee, bytes[9] & 255)
	assert_equal(3, bytes[13])
	assert_equal(0xee, bytes[14] & 255)
	free(bytes)
