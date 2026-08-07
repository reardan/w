# Pins the Python-style source context block under human-readable
# compile diagnostics (#377): after the frozen '<message> in
# <file>:<line>' header line, stderr carries the offending source line
# verbatim and a caret line underneath, for warnings and errors alike.
# The caret pad replays the line's own leading tabs (so terminal tab
# stops keep the caret under the token) and advances one column per
# CODEPOINT, not per byte: the error needle's pad counts the two-byte
# UTF-8 'e-acute' in the string literal as a single column, and the
# reject needle below is that same pad one space wider -- exactly what
# a byte-counting pad would emit (the pads' leading tab keeps the
# narrower needle from matching inside the wider caret line, so the
# pair really does pin the width). The '&' warning goes through
# warn_bool_bitwise_at's diagnostic-position save/restore
# (grammar/binary_op.w), pinning context for repositioned diagnostics
# too; the compile continues past it to the missing-symbol error, so a
# broken position restore in the context reader (compiler/tokenizer.w's
# diag_context_collect) would derail the later diagnostics and fail
# the needles below. Both diagnostics are semantic: the file stays
# syntactically valid W, as parser_generator_w_test requires of every
# tracked source.
# expect_fail
# expect_stderr: warning: bitwise '&' on bool operands in a condition does not short-circuit; did you mean '&&'?
# expect_stderr: 	if (a == 1 & b == 2):
# expect_stderr: 	           ^
# expect_stderr: Cannot find symbol: 'caret_probe_undefined'
# expect_stderr: 	return caret_error_probe("héllo", caret_probe_undefined)
# expect_stderr: 	                                  ^
# reject_stderr: 	                                   ^
import lib.lib


int caret_warning_probe(int a, int b):
	if (a == 1 & b == 2):
		return 1
	return 0


int caret_error_probe(string s, int n):
	return n


int main():
	return caret_error_probe("héllo", caret_probe_undefined)
