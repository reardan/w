# The prefixed string-literal scanner (s"..." / c"...") had no EOF
# check, unlike the plain "..." literal a few lines above it in
# get_token() (compiler/tokenizer.w): reaching end of file inside an
# unterminated c"..." literal spun the tokenizer forever instead of
# reporting the truncation, since nextc stays pinned at -1 and never
# equals the closing '"'. Now it reports the same "unterminated string
# literal" text the plain string form already used.
# expect_fail
# expect_stderr: unterminated string literal
void _main():
	char* x = c"unterminated
