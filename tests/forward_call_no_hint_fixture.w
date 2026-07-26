# Companion to forward_call_hint_fixture.w: a call to a name that never
# appears again anywhere in the file (a typo, or a genuinely missing
# import) must keep the bare message -- the forward-declaration hint
# only fires when the lookahead scan actually finds a later top-level
# definition of the name (compiler/symbol_table.w's
# sym_defined_later_in_file).
# expect_fail
# expect_stderr: Cannot find symbol: 'forward_hint_missing'
# reject_stderr: declared later in this file
int main(int argc, int argv):
	return forward_hint_missing(3)
