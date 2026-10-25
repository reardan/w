# The streaming front end (--streaming, grammar/unary_expression.w)
# gives the same malloc-array-fields warning as the AST front end; see
# tests/malloc_array_fields_warning_fixture.w, which this mirrors line
# for line.
# The streaming rules stay until that front end is retired
# (docs/projects/ast_completion_plan.md P1.5), so both paths keep a
# fixture.
# wfixture: --streaming
# expect_stderr: warning: cast of malloc() memory to a struct with fixed-size array fields leaves their descriptors unset; allocate it with 'new' [malloc-array-fields]
# expect_stderr: malloc_array_fields_streaming_warning_fixture.w:32
# expect_stderr: malloc_array_fields_streaming_warning_fixture.w:33
# reject_stderr: malloc_array_fields_streaming_warning_fixture.w:34
# reject_stderr: malloc_array_fields_streaming_warning_fixture.w:35
# reject_stderr: malloc_array_fields_streaming_warning_fixture.w:36
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
