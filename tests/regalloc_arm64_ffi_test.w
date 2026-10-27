# Register promotion across C calls (issue #801): loops whose counters
# and accumulators live in callee-saved registers (x19-x23 on arm64
# Linux, esi/edi on x86, r12-r15 on x64) call libc in their bodies.
# The C callees save and restore those registers by the platform ABI,
# so the W values survive every call; a W frame that promoted nothing
# around the same calls is the reference. Runs on x86, x64 and arm64
# (regalloc_arm64_ffi_test_arm64, under qemu with the aarch64 libc).
# wbuild: x64 arch=arm64 expect_stdout="regalloc ffi OK"
import lib.lib
import lib.assert

c_lib "libc.so.6"

# strnlen/strtol rather than strlen/atoi: lib.lib defines those names.
extern int strnlen(char* s, int limit)
extern int strtol(char* s, int end, int base)
extern int memcmp(char* a, char* b, int n)
extern int snprintf(char* buffer, int size, char* format, ...)
extern int puts(char* s)
extern int fflush(int stream)


char** numbers():
	char** words = cast(char**, malloc(6 * __word_size__))
	words[0] = c"17"
	words[1] = c"-4"
	words[2] = c"250"
	words[3] = c"0"
	words[4] = c"9999"
	words[5] = c"31"
	return words


# Every local but the buffer is a promotion candidate; each iteration
# makes four C calls between the reads and writes of the registers.
int promoted_c_loop(int rounds):
	char** words = numbers()
	char* buffer = cast(char*, malloc(64))
	int total = 0
	int lengths = 0
	int same = 0
	int k = 0
	while (k < rounds):
		char* word = words[k % 6]
		total = total + strtol(word, 0, 10) * (k + 1)
		lengths = lengths + strnlen(word, 64)
		int written = snprintf(buffer, 64, c"%d:%s", k, word)
		lengths = lengths + written
		if (memcmp(buffer + written - strnlen(word, 64), word, strnlen(word, 64)) == 0): same = same + 1
		k = k + 1
	free(buffer)
	return total * 1000 + lengths * 10 + same


# The same computation with every local in memory (an address-taken
# array), as the reference.
int stack_c_loop(int rounds):
	char** words = numbers()
	char* buffer = cast(char*, malloc(64))
	int[4] v
	v[0] = 0
	v[1] = 0
	v[2] = 0
	for k in range(rounds):
		char* word = words[k % 6]
		v[0] = v[0] + strtol(word, 0, 10) * (k + 1)
		v[1] = v[1] + strnlen(word, 64)
		int written = snprintf(buffer, 64, c"%d:%s", k, word)
		v[1] = v[1] + written
		if (memcmp(buffer + written - strnlen(word, 64), word, strnlen(word, 64)) == 0): v[2] = v[2] + 1
	free(buffer)
	return v[0] * 1000 + v[1] * 10 + v[2]


# Recursion through C calls: every frame's registers survive its
# callee's frames and the C calls in between.
int nested(int depth, char* word):
	if (depth == 0): return strnlen(word, 64)
	int s = 0
	int i = 0
	while (i < 2):
		s = s + nested(depth - 1, word) + strtol(word, 0, 10) + i
		i = i + 1
	return s


int main():
	for rounds in range(0, 40, 7): assert_equal(stack_c_loop(rounds), promoted_c_loop(rounds))
	# nested(d) = 2 * nested(d - 1) + 2 * 12 + 1, nested(0) = 2
	int expect = 2
	for d in range(4): expect = 2 * expect + 25
	assert_equal(expect, nested(4, c"12"))
	puts(c"regalloc ffi OK")
	fflush(0)
	return 0
