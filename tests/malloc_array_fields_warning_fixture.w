# A struct with a fixed-size array field keeps a runtime descriptor for
# the array inside the record, and only 'new' (and locals) initialize
# it, so cast(T*, malloc(...)) of such a record leaves
# indexing and len() reading garbage (issue #459). The compiler warns at
# the cast (grammar/type_check.w); the warning_test target runs this
# fixture via bin/wfixture. The file:line needles pin the warning to the
# malloc casts, a nested array field included; the reject needles
# keep 'new', a struct without arrays and a non-record cast silent.
# expect_stderr: warning: cast of malloc() memory to a struct with fixed-size array fields leaves their descriptors unset; allocate it with 'new' [malloc-array-fields]
# expect_stderr: malloc_array_fields_warning_fixture.w:32
# expect_stderr: malloc_array_fields_warning_fixture.w:33
# reject_stderr: malloc_array_fields_warning_fixture.w:34
# reject_stderr: malloc_array_fields_warning_fixture.w:35
# reject_stderr: malloc_array_fields_warning_fixture.w:36
import lib.lib


struct with_array:
	int[4] values
	int count


struct plain_record:
	int count


struct holds_array:
	with_array inner


int main():
	with_array* a = cast(with_array*, malloc(sizeof(with_array)))
	holds_array* h = cast(holds_array*, malloc(sizeof(holds_array)))
	with_array* b = new with_array()
	plain_record* p = cast(plain_record*, malloc(sizeof(plain_record)))
	int* raw = cast(int*, malloc(16))
	return cast(int, a) + cast(int, h) + b.count + cast(int, p) + cast(int, raw)
# wbuild: fixture_group=warning_test
