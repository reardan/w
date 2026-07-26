# The single-pass compiler registers a function only once its
# definition (or a C-style prototype) has been parsed, so the call below
# to a function defined further down this same file must fail -- and
# because the definition IS visibly later in the file, the diagnostic
# must carry the forward-declaration hint (compiler/symbol_table.w's
# sym_not_found_error; docs/projects/ai_tooling.md).
# expect_fail
# expect_stderr: Cannot find symbol: 'forward_hint_callee': declared later in this file -- forward-declare it with a prototype ('type forward_hint_callee(params);') before this point
int main(int argc, int argv):
	return forward_hint_callee(3)


int forward_hint_callee(int x):
	return x + 1
