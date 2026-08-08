/*
skills_check: keep the compiler's --help output and the docs in sync.

The agent docs (AGENTS.md, README.md, .cursor/skills/) document compiler
flags as hand-verified snapshots; nothing asserted them until the
compiler grew a real --help (issue #377). This tool closes the loop:

	skills_check <help-output.txt> <doc>...

<help-output.txt> is the concatenated stdout of 'w --help' and every
'w <subcommand> --help' (the skills_test target in build.base.json
produces it). Each <doc> is scanned line by line; a line that mentions
the compiler binary (any of the anchors below) has its dash-prefixed
flag tokens extracted, and every extracted flag must appear in the help
text as a standalone token. A documented-but-unlisted flag fails the
run with a doc:line: message, so docs and the binary cannot drift.

Anchors — a line is about the compiler when it contains one of:
	"wv2", "w check", "w deps", "w symbols", "w defhash",
	"w --debug", "w --version", "w --help"
(other tools' lines — wbuild, wtest, wdbg, git — are not scanned, so
their flags are not falsely required of the compiler's help).

Flag extraction: a '-' at a token boundary starts a flag; the token is
the maximal run of [A-Za-z0-9_-] and is truncated at '=' ('--bounds=off'
must match the help's '--bounds=on|off|trap' by its '--bounds' stem).
Tokens without a letter ('-', '->', '--') are ignored.

A hardcoded core list (every flag, selector and subcommand word the
compiler actually accepts) is also asserted against the help text, so
gutting a help paragraph fails even when no doc happens to mention the
flag.

Prints "skills_check: OK" and exits 0 on success; prints one line per
missing flag and "skills_check: FAIL" to stderr and exits 1 otherwise.
*/
import lib.lib
import lib.file
import lib.str


char* skills_help_text
int skills_failures


# Token characters for flags, selector words and subcommand words.
int skills_is_token_char(int ch):
	if (('a' <= ch) && (ch <= 'z')):
		return 1
	if (('A' <= ch) && (ch <= 'Z')):
		return 1
	if (('0' <= ch) && (ch <= '9')):
		return 1
	if (ch == '_'):
		return 1
	if (ch == '-'):
		return 1
	return 0


# 1 when token appears in the help text at token boundaries (so '-o'
# inside '--bool-ops' or 'arm64' inside 'arm64_darwin' do not count).
int skills_help_has_token(char* token):
	int n = strlen(token)
	int i = 0
	while (skills_help_text[i] != 0):
		int j = 0
		while ((j < n) && (skills_help_text[i + j] == token[j])):
			j = j + 1
		if (j == n):
			int before_ok = 1
			if (i > 0):
				if (skills_is_token_char(skills_help_text[i - 1] & 255)):
					before_ok = 0
			int after = skills_help_text[i + n] & 255
			# '=' after a flag stem is a boundary ('--bounds=on');
			# a token char is not ('arm64' vs 'arm64_darwin').
			if (before_ok && (skills_is_token_char(after) == 0)):
				return 1
		i = i + 1
	return 0


void skills_missing(char* where, int line_no, char* token):
	print_error(c"skills_check: ")
	print_error(where)
	if (line_no > 0):
		print_error(c":")
		print_error(itoa(line_no))
	print_error(c": '")
	print_error(token)
	print_error(c"' is not in the --help output\x0a")
	skills_failures = skills_failures + 1


# One line's worth of doc text (NUL-terminated scratch copy).
int skills_line_is_compiler(char* line):
	if (index_of(line, c"wv2") >= 0):
		return 1
	if (index_of(line, c"w check") >= 0):
		return 1
	if (index_of(line, c"w deps") >= 0):
		return 1
	if (index_of(line, c"w symbols") >= 0):
		return 1
	if (index_of(line, c"w defhash") >= 0):
		return 1
	if (index_of(line, c"w --debug") >= 0):
		return 1
	if (index_of(line, c"w --version") >= 0):
		return 1
	if (index_of(line, c"w --help") >= 0):
		return 1
	return 0


void skills_scan_line(char* doc, int line_no, char* line):
	if (skills_line_is_compiler(line) == 0):
		return
	int i = 0
	while (line[i] != 0):
		int ch = line[i] & 255
		int at_boundary = 1
		if (i > 0):
			if (skills_is_token_char(line[i - 1] & 255)):
				at_boundary = 0
		if ((ch == '-') && at_boundary):
			# Collect the dashes, then the stem up to '=' or a
			# non-token character.
			int start = i
			int has_letter = 0
			while (skills_is_token_char(line[i] & 255)):
				int tc = line[i] & 255
				if ((('a' <= tc) && (tc <= 'z')) || (('A' <= tc) && (tc <= 'Z'))):
					has_letter = 1
				i = i + 1
			if (has_letter):
				int len = i - start
				char* token = malloc(len + 1)
				int k = 0
				while (k < len):
					token[k] = line[start + k]
					k = k + 1
				token[len] = 0
				if (skills_help_has_token(token) == 0):
					skills_missing(doc, line_no, token)
				free(token)
		else:
			i = i + 1


void skills_scan_doc(char* doc):
	char* text = file_read_text(doc)
	if (text == 0):
		print_error(c"skills_check: cannot read '")
		print_error(doc)
		print_error(c"'\x0a")
		skills_failures = skills_failures + 1
		return
	int line_no = 1
	int start = 0
	int i = 0
	int scanning = 1
	while (scanning):
		int ch = text[i] & 255
		if ((ch == 10) || (ch == 0)):
			int len = i - start
			char* line = malloc(len + 1)
			int k = 0
			while (k < len):
				line[k] = text[start + k]
				k = k + 1
			line[len] = 0
			skills_scan_line(doc, line_no, line)
			free(line)
			line_no = line_no + 1
			start = i + 1
			if (ch == 0):
				scanning = 0
		i = i + 1
	free(text)


# Every flag, target selector and subcommand word the compiler accepts;
# asserted unconditionally so a gutted help paragraph fails even when no
# doc line happens to mention the flag. Grow this list with the flag
# surface (compiler/compiler.w's help_* functions).
void skills_check_core():
	char* core = c"-o -v -h --help --version --strict --quiet --stats --verbose --bounds --pac --ptx --json --imports --bool-ops --closure --debug x64 arm64 arm64_darwin win64 wasm check deps symbols defhash"
	int i = 0
	while (core[i] != 0):
		int start = i
		while ((core[i] != 0) && (core[i] != ' ')):
			i = i + 1
		int len = i - start
		char* token = malloc(len + 1)
		int k = 0
		while (k < len):
			token[k] = core[start + k]
			k = k + 1
		token[len] = 0
		if (skills_help_has_token(token) == 0):
			skills_missing(c"<core flag list>", 0, token)
		free(token)
		while (core[i] == ' '):
			i = i + 1


int main(int argc, int argv):
	if (argc < 3):
		println2(c"usage: skills_check <help-output.txt> <doc>...")
		return 1
	char** help_arg = argv + __word_size__
	skills_help_text = file_read_text(*help_arg)
	if (skills_help_text == 0):
		print_error(c"skills_check: cannot read '")
		print_error(*help_arg)
		print_error(c"'\x0a")
		return 1
	skills_check_core()
	int a = 2
	while (a < argc):
		char** doc_arg = argv + a * __word_size__
		skills_scan_doc(*doc_arg)
		a = a + 1
	if (skills_failures > 0):
		print_error(c"skills_check: FAIL (")
		print_error(itoa(skills_failures))
		print_error(c" missing)\x0a")
		return 1
	println(c"skills_check: OK")
	return 0
