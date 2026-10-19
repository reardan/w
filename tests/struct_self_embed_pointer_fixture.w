/*
The legal shape the recursive-struct rejection must keep compiling: a
pointer back-link is finite layout, and so is any *-qualified or
container field (tests/struct_self_embed_crash_fixture.w is the
rejected counterpart; see the wfuzz fixture chain there).
*/
struct ScalarPair:
	ScalarPair* r

int main():
	return 0
