# wbuild: x64
# wbuild: step="bin/wv2 x64 --pie tests/incomplete_global_test.w -o bin/incomplete_global_pie_test"
# wbuild: step="bin/incomplete_global_pie_test" expect_stdout="incomplete globals OK"
# Globals whose record type completes later in the file (C's
# 'static struct s x;' ahead of the struct body) and globals of an
# empty record (grammar/program.w, incomplete_global_complete and
# global_storage_size): the completed record gets storage of its full
# size, the code and pointer cells that took its address before the
# body follow it, and no global shares its address with the next one.
import lib.lib
import lib.assert

struct late:

late early_record
late* early_pointer = &early_record
int guard_after = 77


late* early_address():
	return &early_record


struct empty:

struct holds_empty:
	empty raw

holds_empty lock_a
holds_empty lock_b
int guard_lock = 5

struct late:
	int first
	int second
	int third


int main():
	late* p = early_address()
	p.first = 1
	p.second = 2
	p.third = 3
	assert_equal(77, guard_after)
	assert1(p == &early_record)
	assert1(early_pointer == &early_record)
	assert_equal(6, early_record.first + early_record.second + early_record.third)
	assert1(cast(int, &lock_a) != cast(int, &lock_b))
	assert1(cast(int, &lock_b) != cast(int, &guard_lock))
	assert_equal(5, guard_lock)
	println(c"incomplete globals OK")
	return 0
