# Native ready RAM pool acceptance and timings. Pass the arm64 guest path.
import lib.vmm.darwin_pool
import lib.assert
import lib.process

c_lib "/usr/lib/libSystem.B.dylib"
extern int mach_absolute_time()
extern int pool_timebase_raw(int* info) = "mach_timebase_info"

int pool_clock_numerator
int pool_clock_denominator


int pool_now_ns():
	int ticks = mach_absolute_time()
	return (ticks / pool_clock_denominator) * pool_clock_numerator + ((ticks % pool_clock_denominator) * pool_clock_numerator) / pool_clock_denominator


void pool_sample(char* phase, int sample, int elapsed):
	string_builder* record = string_from(c"{\"phase\":\"")
	string_append(record, phase)
	string_append(record, c"\",\"sample\":")
	string_append_int(record, sample)
	string_append(record, c",\"elapsed_ns\":")
	string_append_int(record, elapsed)
	string_append(record, c"}\n")
	assert_equal(record.length, write(1, record.data, record.length))
	string_free(record)


void pool_guest(darwin_cell* cell):
	asserts(c"acquired ready cell", cell != 0)
	assert_equal(0, cell.started)
	assert_equal(0, cell.output.length)
	asserts(c"run acquired allocator guest", darwin_cell_run(cell, 3000))
	assert_equal(0, cell.status)
	assert_strings_equal(c"cell allocator containers FP OK\n", cell.output.data)


int main(int argc, int argv):
	char** args = cast(char**, argv)
	assert_equal(2, argc)
	int info = 0
	assert_equal(0, darwin_snapshot_c_int(pool_timebase_raw(&info)))
	pool_clock_numerator = info & ((1 << 32) - 1)
	pool_clock_denominator = info >> 32
	asserts(c"monotonic native timebase", pool_clock_numerator > 0 && pool_clock_denominator > 0)
	darwin_cell* source = darwin_cell_new()
	asserts(c"pool source", source != 0)
	asserts(c"pool load", darwin_cell_load(source, args[1]))
	char** guest_args = strv_new(3)
	guest_args[0] = c"pool-guest"
	guest_args[1] = c"alloc"
	guest_args[2] = 0
	asserts(c"pool source stack", darwin_cell_stack(source, 2, guest_args))
	free(cast(void*, guest_args))
	darwin_backing* backing = darwin_cell_snapshot_create(source)
	asserts(c"pool capture", backing != 0)
	asserts(c"zero capacity rejected", darwin_pool_new(backing, 0) == 0)
	asserts(c"excess capacity rejected", darwin_pool_new(backing, 33) == 0)
	int start = pool_now_ns()
	darwin_pool* pool = darwin_pool_new(backing, 2)
	asserts(c"create two ready RAM entries", pool != 0)
	pool_sample(c"pool-create-two", 0, pool_now_ns() - start)
	darwin_cell_free(source)
	darwin_backing_free(backing)
	darwin_cell* first = darwin_pool_acquire(pool)
	darwin_cell* second = darwin_pool_acquire(pool)
	asserts(c"bounded pool exhaustion", darwin_pool_acquire(pool) == 0)
	pool_guest(first)
	pool_guest(second)
	darwin_cell_free(first)
	darwin_cell_free(second)
	asserts(c"replenish after source/template destruction", darwin_pool_replenish(pool))
	# Each iteration measures an actual ready-cell transfer and replacing
	# exactly one removed cell. Creation/execution are separate samples.
	for sample in range(21):
		start = pool_now_ns()
		darwin_cell* lease = darwin_pool_acquire(pool)
		int acquire = pool_now_ns() - start
		asserts(c"ready pool acquire", lease != 0)
		pool_sample(c"ready-acquire", sample, acquire)
		start = pool_now_ns()
		pool_guest(lease)
		pool_sample(c"first-command", sample, pool_now_ns() - start)
		darwin_cell_free(lease)
		start = pool_now_ns()
		asserts(c"replace consumed ready entry", darwin_pool_replenish(pool))
		pool_sample(c"ready-replacement", sample, pool_now_ns() - start)
		assert_equal(2, pool.available)
	# A failed replacement preserves the other ready entry and can retry.
	first = darwin_pool_acquire(pool)
	int backup = sys_fcntl(pool.fd, 0, 0)
	asserts(c"save pool backing for failure injection", backup >= 0)
	assert_equal(0, close(pool.fd))
	asserts(c"failed replacement reported", darwin_pool_replenish(pool) == 0)
	assert_equal(1, pool.available)
	assert_equal(pool.fd, dup2(backup, pool.fd))
	close(backup)
	asserts(c"replacement retry recovers", darwin_pool_replenish(pool))
	assert_equal(2, pool.available)
	darwin_cell_free(first)
	# Acquired ownership remains valid when the pool itself is destroyed.
	first = darwin_pool_acquire(pool)
	darwin_pool_free(pool)
	pool_guest(first)
	darwin_cell_free(first)
	println(c"PASS Darwin bounded ready RAM pool and independent acquired lifetime")
	return 0
