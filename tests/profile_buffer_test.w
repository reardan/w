# wbuild: x64
# Exercise several flush boundaries, zero counters, full uint64 formatting,
# idempotence, and simultaneous appenders sharing one output file.
import lib.testing
import lib.file
import lib.profile
import tools.wcoverage_lines


void test_profile_buffer_concurrent_records():
	char* path = f"bin/profile_buffer_{__word_size__}_{getpid()}.raw"
	assert_equal(1, file_write_text(path, c""))
	int count = 1800
	char* counters = cast(char*, malloc(count * 8))
	for i in range(count):
		int value = i + 1
		if (i % 11 == 0): value = 0
		save_int32(counters + i * 8, value)
		save_int32(counters + i * 8 + 4, 0)
	# The final record also proves the last partial buffer is flushed.
	save_int32(counters + (count - 1) * 8, 0 - 1)
	save_int32(counters + (count - 1) * 8 + 4, 0 - 1)
	list[int] children = new list[int]
	for worker in range(4):
		int pid = fork()
		asserts(c"fork profile writer", pid >= 0)
		if (pid == 0):
			environ_ptr = cast(int, env_copy_with(env_current(), c"W_PROFILE_OUT", path))
			__w_profile_counters = counters
			__w_profile_count = count
			__w_profile_flushed = 0
			__w_profile_flush()
			__w_profile_flush()
			exit(0)
		children.push(pid)
	for int pid in children:
		int status = 0
		assert_equal(pid, wait4(pid, &status, 0, 0))
		assert_equal(0, status)
	list[char*] lines = file_read_lines(path)
	asserts(c"read counter output", lines != 0)
	map[int, int] seen = new map[int, int]
	for char* line in lines:
		list[char*] fields = split(line, ' ')
		assert_equal(2, fields.length)
		int index = wcov_small_decimal(fields[0])
		asserts(c"counter index in range", index < count)
		if (index == count - 1): assert_equal(0, strcmp(c"18446744073709551615", fields[1]))
		else:
			asserts(c"zero counters omitted", index % 11 != 0)
			assert_equal(index + 1, wcov_small_decimal(fields[1]))
		int n = 0
		if (index in seen): n = seen[index]
		seen[index] = n + 1
	for i in range(count):
		if (i % 11 == 0): asserts(c"zero counter absent", !(i in seen))
		else:
			asserts(c"nonzero counter present", i in seen)
			assert_equal(4, seen[i])
	unlink(path)
	free(counters)
