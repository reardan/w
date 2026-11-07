# wbuild: target=inline_front_end_test tag=tests dep=wv2 dep=wprof input=tests/inline_front_end_fixture.w
# wbuild: step="bin/wv2 --profile-generate tests/inline_front_end_fixture.w -o bin/ife_prof"
# wbuild: step="bin/wprof clear bin/ife.wprofraw"
# wbuild: step="bin/ife_prof" env="W_PROFILE_OUT=bin/ife.wprofraw" expect_stdout="ife 6999504"
# wbuild: step="bin/wprof merge -o bin/ife.wprof bin/ife_prof.wprofmap bin/ife.wprofraw"
# wbuild: step="bin/wv2 --profile-use=bin/ife.wprof --stats tests/inline_front_end_fixture.w -o bin/ife_ast" expect_stderr="inline:   sum_picks: sites 1" reject_stderr="inline:   label:"
# wbuild: step="bin/wv2 --profile-use=bin/ife.wprof --streaming --stats tests/inline_front_end_fixture.w -o bin/ife_streaming" expect_stderr="inline:   sum_picks: sites 1" reject_stderr="inline:   label:"
# wbuild: step="cmp bin/ife_ast bin/ife_streaming"
# wbuild: step="bin/ife_ast" expect_stdout="ife 6999504"
# wbuild: step="bin/wv2 x64 --profile-generate tests/inline_front_end_fixture.w -o bin/ife_prof_64"
# wbuild: step="bin/wprof clear bin/ife_64.wprofraw"
# wbuild: step="bin/ife_prof_64" env="W_PROFILE_OUT=bin/ife_64.wprofraw" expect_stdout="ife 6999504"
# wbuild: step="bin/wprof merge -o bin/ife_64.wprof bin/ife_prof_64.wprofmap bin/ife_64.wprofraw"
# wbuild: step="bin/wv2 x64 --profile-use=bin/ife_64.wprof --stats tests/inline_front_end_fixture.w -o bin/ife_ast_64" expect_stderr="inline:   sum_picks: sites 1" reject_stderr="inline:   label:"
# wbuild: step="bin/wv2 x64 --profile-use=bin/ife_64.wprof --streaming --stats tests/inline_front_end_fixture.w -o bin/ife_streaming_64" expect_stderr="inline:   sum_picks: sites 1" reject_stderr="inline:   label:"
# wbuild: step="cmp bin/ife_ast_64 bin/ife_streaming_64"
# wbuild: step="bin/ife_ast_64" expect_stdout="ife 6999504"
/*
A --profile-use build makes the same inlining decisions under the AST
front end and --streaming (reardan/w#886): the profile marks hot_loop
hot, so every call in it gets the hot budget, which is open to bodies
that call. Those decisions read facts recorded while the callee's own
definition compiled, and the facts must not depend on the front end:

  - sum_picks: its inferred generic calls made the streaming grammar
    re-lex their arguments, so its token_serial delta came out larger
    than the AST front end's (past the hot token cap here) and only the
    AST build inlined it; the count now comes from the body's bytes
    (inline_text_tokens, compiler/inline_table.w);
  - label: an f-string is an inline hazard, but only the streaming
    grammar counted it, so only the AST build inlined it; the AST
    parse (ast_expression_template) counts it too now.

The target compiles this file with --profile-generate, runs it once to
take its profile, and compiles it with that profile under both front
ends, on x86 and x64: the images must be byte-identical, and sum_picks
must have been inlined (--stats).
*/
import lib.lib
import lib.utf8


T pick[T](T a, T b):
	if (a > b): return a
	return b


# Generics with long signatures: each call below instantiates one while
# sum_picks compiles, and the streaming grammar's token_serial counted
# the signature's tokens, re-lexed for the instantiation, as sum_picks'
# own (past the hot token cap of 160, where the body has about 90).
T sum8[T](T a0, T a1, T a2, T a3, T a4, T a5, T a6, T a7):
	return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7


T alt8[T](T a0, T a1, T a2, T a3, T a4, T a5, T a6, T a7):
	return a0 - a1 + a2 - a3 + a4 - a5 + a6 - a7


int sum_picks(int a, int b):
	int s = pick(a, b) + pick(b, a) + pick(a + 1, b) + pick(a, b + 1)
	s = s + sum8(a, b, a, b, a, b, a, s & 7)
	s = s + alt8(a, b, s, b, a, s, a, b & 3)
	return s


char* label(int n):
	return cstr(f"n{n}")


int hot_loop(int n):
	int total = 0
	int i = 0
	while (i < n):
		total = total + sum_picks(i, n - i)
		i = i + 1
	char* l = label(total & 7)
	total = total + strlen(l)
	free(l)
	return total


int main():
	char* n = itoa(hot_loop(1000))
	print(c"ife ")
	print(n)
	print(c"\x0a")
	return 0
