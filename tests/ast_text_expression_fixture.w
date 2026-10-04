import lib.lib

int ast_text_equal(char* a, char* b): return strcmp(a, b) == 0
string ast_text_identity(string text): return text

int main():
	if (('a' + '\n') != 107): return 1
	if (('é') != 233): return 2
	if (('\U0001F600') != 128512): return 3
	if ((ast_text_equal(c"hello", c"hello")) != 1): return 4
	if ((strcmp(c"a", c"b") < 0) != true): return 5
	if ((strlen(c"a\tb\n")) != 4): return 6
	char* embedded = (c"a\0b")
	if ((embedded[0] != 97 || embedded[1] != 0 || embedded[2] != 98)): return 7
	string first = (s"héllo\n")
	string second = ("héllo\n")
	if ((first == second) != true): return 8
	if ((first != s"different") != true): return 9
	if ((ast_text_identity(first) == s"héllo\n") != true): return 10
	if ((true ? first : second) != s"héllo\n"): return 11
	first = (s"changed")
	if ((first == s"changed") != true): return 12
	if ((ast_text_equal(c"\\\"", c"\\\"")) != 1): return 13
	if ((ast_text_equal(c"\q", c"q")) != 1): return 14
	if ((strlen(c"operators ( ) [ ] && || ; : ? # /* */")) != 37): return 15
	if (("" == s"") != true): return 16
	if ((ast_text_identity(s"") == "") != true): return 17
	if ((strlen(c"")) != 0): return 18
	if ((str_from_cstr(c"") == "") != true): return 19
	return 0
