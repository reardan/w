# Pins the rustc-style layout of human-readable diagnostics and the
# did-you-mean help line (#377): the severity leads the header, the
# location follows as 'file:line:col', the source line sits behind a
# line-number gutter, the whole misspelled token is underlined, and the
# closest in-scope name (compiler/diagnostics.w's suggester) is offered
# as '= help'. The reject needle pins the underline's width: one more
# caret than the token has would also match the expect needle's prefix.
# expect_fail
# expect_stderr: error: Cannot find symbol: 'countr'
# expect_stderr: did_you_mean_symbol_fixture.w:21:9
# expect_stderr: 21 | 	return countr + 1
# expect_stderr:    | 	       ^^^^^^
# reject_stderr: ^^^^^^^
# expect_stderr:    = help: did you mean 'counter'?
import lib.lib


int main():
	int counter = 3
	counter = counter + 1
	return countr + 1
# wbuild: fixture_group=error_caret_test
