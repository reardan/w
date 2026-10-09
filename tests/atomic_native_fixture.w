# Native concurrent qualification independent of lib.thread. Forked workers
# access the SAME normal MAP_SHARED pages, not private copy-on-write globals.
import lib.assert

struct native_atomic_state:
	int ready
	int payload
	int round
	int left
	int right
	int left_seen
	int right_seen
	int left_done
	int right_done

void native_wait(int pid):
	int status = 0
	assert_equal(pid, wait4(pid, &status, 0, 0))
	assert_equal(0, status)

int main():
	assert_equal(8, __word_size__)
	int mapping = mmap(0, 16384, 3, 33)
	assert1(mapping > 0)
	assert_equal(0, mapping % 8)
	native_atomic_state* s = cast(native_atomic_state*, mapping)
	# Every field is an aligned, full-width word, including values > 2^32.
	assert_equal(0, cast(int, &s.right_done) % 8)
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
