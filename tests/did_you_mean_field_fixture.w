# A misspelled struct field is reported at the member itself -- not at
# the token after it, which is where the tokenizer has moved on to --
# and the struct's closest field is offered as '= help' (#377).
# expect_fail
# expect_stderr: error: struct field 'lenght' not found
# expect_stderr: did_you_mean_field_fixture.w:21:21
# expect_stderr:    | 	                   ^^^^^^
# expect_stderr:    = help: did you mean 'length'?
import lib.lib


struct span:
	int start
	int length


int main():
	span s
	s.start = 0
	s.length = 4
	return s.start + s.lenght
# wbuild: fixture_group=error_caret_test
