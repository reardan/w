# cast(T*, x) on an array or slice operand whose decay does not apply
# (mismatched element type or pointer depth) leaves the address of the
# 2-word runtime descriptor header in the result, not the element
# data, so the compiler warns at the cast
# (grammar/unary_expression.w); the warning_test target runs this
# fixture via bin/wfixture. The file:line needles pin one warning to
# the slice-parameter cast, one to the local-array cast and one to
# the pointer-depth mismatch; the reject needles assert the decaying
# spellings -- a decayed pointer, &a[0], the element's own pointer
# type -- stay silent.
# expect_stderr: warning: cast of array to pointer addresses the array header, not its data; index or let it decay instead
# expect_stderr: array_cast_warning_fixture.w:22
# expect_stderr: array_cast_warning_fixture.w:28
# expect_stderr: array_cast_warning_fixture.w:29
# reject_stderr: array_cast_warning_fixture.w:31
# reject_stderr: array_cast_warning_fixture.w:32
# reject_stderr: array_cast_warning_fixture.w:33
import lib.lib


int slice_cast(char[] s):
	return cast(int, cast(int*, s))


int main():
	char[16] slot
	slot[0] = 'x'
	int* header = cast(int*, slot)
	char** depth = cast(char**, slot)
	char* decayed = slot
	int* ok_ptr = cast(int*, decayed)
	int* ok_elem = cast(int*, &slot[0])
	char* ok_decay = cast(char*, slot)
	int total = slice_cast(slot)
	total = total + cast(int, header) + cast(int, depth) + cast(int, ok_ptr)
	total = total + cast(int, ok_elem) + cast(int, ok_decay)
	return total
