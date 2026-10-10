# Native concurrent qualification independent of lib.thread. Forked workers
# access the SAME normal MAP_SHARED pages, not private copy-on-write globals.
import lib.assert

struct native_atomic_state:
	# Isolate the tested locations from each other and the control flags.
	# Apple Silicon has 128-byte cache lines; sharing a line can mask the
	# weak-memory outcomes this litmus is intended to exercise.
	# Fixed arrays include a two-word header: (1 + 2 + 13) * 8 = 128.
	int ready
	int[13] ready_padding
	int payload
	int[13] payload_padding
	int round
	int[13] round_padding
	int left
	int[13] left_padding
	int right
	int[13] right_padding
	int left_seen
	int[13] left_seen_padding
	int right_seen
	int[13] right_seen_padding
	int left_done
	int[13] left_done_padding
	int right_done

void native_wait(int pid):
	int status = 0
	assert_equal(pid, wait4(pid, &status, 0, 0))
	assert_equal(0, status)

int main():
	assert_equal(8, __word_size__)
	int mapping = mmap(0, 16384, 3, 33)
	assert1(mapping > 0)
	assert_equal(0, mapping % 128)
	native_atomic_state* s = cast(native_atomic_state*, mapping)
	# Every field is an aligned, full-width word, including values > 2^32.
	assert_equal(mapping + 128, cast(int, &s.payload))
	assert_equal(mapping + 256, cast(int, &s.round))
	assert_equal(mapping + 384, cast(int, &s.left))
	assert_equal(mapping + 512, cast(int, &s.right))
	assert_equal(mapping + 640, cast(int, &s.left_seen))
	assert_equal(mapping + 768, cast(int, &s.right_seen))
	assert_equal(mapping + 896, cast(int, &s.left_done))
	assert_equal(mapping + 1024, cast(int, &s.right_done))
	int high = (1 << 40) + 17
	atomic_store_relaxed(&s.payload, high)
	assert_equal(high, atomic_load_relaxed(&s.payload))
	atomic_store(&s.payload, high + 1)
	assert_equal(high + 1, atomic_load(&s.payload))
	int count = 100000
	int child = fork()
	assert1(child >= 0)
	if (child == 0):
		for i in range(1, count + 1):
			while (atomic_load(&s.ready) == 0): pass
			if (s.payload != high + i): exit(1)
			atomic_store(&s.ready, 0)
		exit(0)
	for i in range(1, count + 1):
		while (atomic_load(&s.ready) != 0): pass
		s.payload = high + i
		atomic_store(&s.ready, 1)
	native_wait(child)
	int left = fork()
	assert1(left >= 0)
	if (left == 0):
		for i in range(1, count + 1):
			while (atomic_load(&s.round) != i): pass
			atomic_store_relaxed(&s.left, 1)
			atomic_fence()
			s.left_seen = atomic_load_relaxed(&s.right)
			atomic_store(&s.left_done, i)
		exit(0)
	int right = fork()
	assert1(right >= 0)
	if (right == 0):
		for i in range(1, count + 1):
			while (atomic_load(&s.round) != i): pass
			atomic_store_relaxed(&s.right, 1)
			atomic_fence()
			s.right_seen = atomic_load_relaxed(&s.left)
			atomic_store(&s.right_done, i)
		exit(0)
	for i in range(1, count + 1):
		atomic_store_relaxed(&s.left, 0)
		atomic_store_relaxed(&s.right, 0)
		atomic_store(&s.round, i)
		while (atomic_load(&s.left_done) != i): pass
		while (atomic_load(&s.right_done) != i): pass
		assert1(s.left_seen != 0 || s.right_seen != 0)
	native_wait(left)
	native_wait(right)
	assert_equal(0, munmap(mapping, 16384))
	return 0
