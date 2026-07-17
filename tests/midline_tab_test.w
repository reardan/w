# Mid-line tabs are plain whitespace to the compiler and hidden
# whitespace to the parser-generator grammar (skip INLINE_TAB in
# tests/parser_generator/w.pg). This file keeps literal mid-line tabs so
# both surfaces stay honest: it must compile and run, and
# parser_generator_w_test must parse it.
import lib.lib
import lib.assert	# a tab before a trailing comment on an import line

int main():
	int x = 1	# a tab between code and a trailing comment
	x = x + 1		# two tabs before this comment
	if (x == 2):	# a tab after the colon that opens a block
		assert1(x == 2)
	assert1(x == 2)
	println2(c"midline tab test passed")
	return 0
