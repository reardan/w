/*
Command-line -> W call translation for the REPL's shell mode (":sh",
issue #335, docs/projects/repl_shell_mode.md Sec 5). Pure: no I/O, no
engine access -- repl.w feeds one shell-mode line in and gets back
either a ready-to-eval W call-statement (a malloc'd string the caller
owns) or 0, meaning every part of the recognition test (Sec 5.2)
failed and the whole line should go to native, unchanged, via
lib/shell.w's sh_interactive.

Recognition test -- all three must hold, or the whole line falls back
to native; never a partial or best-guess translation:
  1. the line contains none of the characters that need real shell
     semantics: | < > ; & $ ` ~ * ? (pipe, redirection, chaining,
     backgrounding, variable/command/glob expansion);
  2. its first word names a tool this file knows (pwd, ls, cat, echo,
     head, tail, wc, mkdir, rm, cp, mv, touch, chmod, du -- design doc
     Sec 11's stage 1 + stage 2 lists plus stage 3's additions);
  3. every flag token (a word starting with '-') is one that tool's
     flag table knows, and the remaining positional count matches what
     the tool expects.

Tokenization (Sec 5.3) is sh-like word splitting, reached only once
rule 1 has already excluded every shell metacharacter: unquoted runs of
non-space bytes are words; '...' is a literal span (no escapes
recognized inside); "..." recognizes \" and \\ and passes other
backslashes through unchanged; a backslash outside quotes escapes the
following character. There is deliberately no $VAR/~/glob handling here
-- rule 1 already routed those lines to native.

Each resolved value becomes a literal in the generated call text
(Sec 5.5): strings become a c"..." literal with backslash/double-quote
escaped, booleans the literal words true/false. This never relies on
the callee's own default parameter values (lib/shell_commands.w's
header explains why one can't exist for a char* parameter today) --
every parameter, including "bare ls"'s documented "." path default, is
resolved to an explicit literal right here.

Stage 2 also adds head/tail's "-n N" -- the design doc's Sec 5.4 called
out "v1 has no valued flags (-n 5); a future head -n 5 would be the
first", and this is that first case: a flag that takes its value from
the following token, rather than a bare boolean.
shell_translate_flag_named/shell_translate_flag_inline_value below are
the small pieces that add, mirroring lib/args.w's
args_name_matches/args_flag_body shape for the same already-split-word
input this file already tokenizes into. Inline "=value" spellings
("-n=5"/"--lines=5") are deliberately NOT accepted: they are lib/args.w
conventions, not head/tail's ("head -n=5" is an error from the real
tool), so those lines fail closed to native, whose own
acceptance/diagnostic then applies verbatim.

Stage 3 adds ls's -l, touch (-c/--no-create), chmod (a leading octal
mode word, no flags -- symbolic modes like "u+x" are not octal, so
they fail closed to the real chmod, whose full mode grammar then
applies), and du (-s/--summarize, one optional path). chmod's mode
word is the first non-flag positional whose spelling is validated
rather than passed through: 1-4 octal digits, translated to a decimal
int literal in the generated call ("chmod 644 f" ->
"shell_commands.chmod_octal(420, c\"f\")").
*/
import lib.lib
import structures.string


# 1 for a byte that needs real shell semantics -- pipe, redirection,
# chaining, backgrounding, or variable/command/glob expansion -- so its
# presence anywhere on the line means "native fallback, unconditionally"
# (Sec 5.2 rule 1). 96 is the backtick.
int shell_translate_is_meta(char c):
	return (c == '|') || (c == '<') || (c == '>') || (c == ';') || (c == '&') ||
		(c == '$') || (c == 96) || (c == '~') || (c == '*') || (c == '?')


# sh-like word splitting (Sec 5.3): only ever called on a line rule 1
# has already cleared of every shell metacharacter.
list[char*] shell_translate_tokenize(char* line):
	list[char*] words = new list[char*]
	int i = 0
	int n = strlen(line)
	while (i < n):
		while ((i < n) && ((line[i] == ' ') || (line[i] == 9))):
			i = i + 1
		if (i >= n):
			break
		string_builder* word = string_new()
		while ((i < n) && (line[i] != ' ') && (line[i] != 9)):
			if (line[i] == 39): /* ' -- literal span, no escapes inside */
				i = i + 1
				while ((i < n) && (line[i] != 39)):
					string_append_char(word, line[i])
					i = i + 1
				if (i < n):
					i = i + 1
			else if (line[i] == 34): /* " -- \" and \\ recognized */
				i = i + 1
				while ((i < n) && (line[i] != 34)):
					if ((line[i] == 92) && (i + 1 < n) && ((line[i + 1] == 34) || (line[i + 1] == 92))):
						string_append_char(word, line[i + 1])
						i = i + 2
					else:
						string_append_char(word, line[i])
						i = i + 1
				if (i < n):
					i = i + 1
			else if (line[i] == 92): /* backslash outside quotes escapes the next byte */
				i = i + 1
				if (i < n):
					string_append_char(word, line[i])
					i = i + 1
			else:
				string_append_char(word, line[i])
				i = i + 1
		# Ownership-transfer idiom (repl.w's repl_format_echo documents
		# why): take word.data directly and free only the wrapper.
		char* owned = word.data
		free(word)
		words.push(owned)
	return words


# Frees the tokenized words and the list holding them (the list struct
# itself leaked per translated line before).
void shell_translate_free_words(list[char*] words):
	int i = 0
	while (i < words.length):
		free(words[i])
		i = i + 1
	__w_list_free(cast(__w_list*, words))


# raw, as a c"..." literal with backslash and double-quote escaped
# (Sec 5.5) -- a small dedicated escaper, since this is arbitrary
# user-typed text becoming source text, not an already-trusted internal
# path.
char* shell_translate_string_literal(char* raw):
	string_builder* out = string_new()
	string_append(out, c"c\"")
	int i = 0
	while (raw[i] != 0):
		if ((raw[i] == 92) || (raw[i] == 34)):
			string_append_char(out, 92)
		string_append_char(out, raw[i])
		i = i + 1
	string_append_char(out, 34)
	char* s = out.data
	free(out)
	return s


# 1 when body is exactly name, or name followed by '=value' (mirrors
# lib/args.w's args_name_matches for the same tokens-already-split
# shape shell_translate_tokenize hands this file).
int shell_translate_name_matches(char* body, char* name):
	int i = 0
	while (name[i] != 0):
		if (body[i] != name[i]):
			return 0
		i = i + 1
	if (body[i] == 0):
		return 1
	if (body[i] == '='):
		return 1
	return 0


# 1 when w is a flag token spelling short_name (one dash) or long_name
# (two dashes), with or without an inline "=value" -- "-n"/"-n=5"/
# "--lines"/"--lines=5" all match (short_name "n", long_name "lines").
int shell_translate_flag_named(char* w, char* short_name, char* long_name):
	if (w[0] != '-'):
		return 0
	if (w[1] == '-'):
		return shell_translate_name_matches(w + 2, long_name)
	return shell_translate_name_matches(w + 1, short_name)


# Pointer to the text after '=' when w carries an inline value, else 0.
char* shell_translate_flag_inline_value(char* w):
	int i = 0
	while (w[i] != 0):
		if (w[i] == '='):
			return w + i + 1
		i = i + 1
	return 0


# 1 when s is one or more decimal digits (a valued flag's value must be
# exactly this, or the whole line fails closed to native -- never a
# best-guess parse of a partly-numeric value like "5abc").
int shell_translate_all_digits(char* s):
	if (s[0] == 0):
		return 0
	int i = 0
	while (s[i] != 0):
		if ((s[i] < '0') || (s[i] > '9')):
			return 0
		i = i + 1
	return 1


# pwd: zero-arg, no flags -- any extra word (flag or positional) fails
# the recognition test and falls back to native.
char* shell_translate_pwd(list[char*] words):
	if (words.length != 1):
		return 0
	return strclone(c"shell_commands.pwd()")


# ls: bare or one path positional; -a/--all and -l (long listing,
# stage 3 -- short form only, matching the real tool) are the known
# flags. A short cluster like "-la" splits into '-l' '-a'; per Sec
# 5.4's "no partial credit" rule, any other letter in the cluster
# fails the whole line (so "ls -lah" falls back to the real ls, not a
# half-translated call).
char* shell_translate_ls(list[char*] words):
	char* path = 0
	int all = 0
	int long_format = 0
	int i = 1
	while (i < words.length):
		char* w = words[i]
		if (w[0] == '-'):
			if (strcmp(w, c"--all") == 0):
				all = 1
			else if ((w[1] == '-') || (w[1] == 0)):
				return 0 /* unknown long flag, or a bare "-" */
			else:
				int j = 1
				while (w[j] != 0):
					if (w[j] == 'a'):
						all = 1
					else if (w[j] == 'l'):
						long_format = 1
					else:
						return 0 /* unknown letter in the cluster */
					j = j + 1
		else:
			if (path != 0):
				return 0 /* ls takes at most one path in v1 */
			path = w
		i = i + 1
	if (path == 0):
		path = c"." /* the documented default for a bare "ls" */
	char* path_lit = shell_translate_string_literal(path)
	string_builder* out = string_new()
	string_append(out, c"shell_commands.ls(")
	string_append(out, path_lit)
	if (all):
		string_append(out, c", true")
	else:
		string_append(out, c", false")
	if (long_format):
		string_append(out, c", true)")
	else:
		string_append(out, c", false)")
	free(path_lit)
	char* s = out.data
	free(out)
	return s


# cat: one or more path positionals, no flags in v1 -- any '-' word
# fails the recognition test.
char* shell_translate_cat(list[char*] words):
	if (words.length < 2):
		return 0
	int i = 1
	while (i < words.length):
		if (words[i][0] == '-'):
			return 0
		i = i + 1
	string_builder* out = string_new()
	string_append(out, c"shell_commands.cat(")
	i = 1
	while (i < words.length):
		if (i > 1):
			string_append(out, c", ")
		char* lit = shell_translate_string_literal(words[i])
		string_append(out, lit)
		free(lit)
		i = i + 1
	string_append(out, c")")
	char* s = out.data
	free(out)
	return s


# echo: any number of word positionals (0 or more), "-n" is the only
# known flag (suppress the trailing newline -- no long form, matching
# real echo). Like the real tool, "-n" only counts as a flag while it
# leads the argument list: after the first ordinary word, a later "-n"
# is plain text to print ("echo a -n" prints "a -n"), never a flag. Any
# other '-' word is unknown and fails the whole line closed to native
# (which prints it literally too, so the output matches either way).
char* shell_translate_echo(list[char*] words):
	int no_newline = 0
	int first_word = 1
	while (first_word < words.length):
		if (strcmp(words[first_word], c"-n") != 0):
			break
		no_newline = 1
		first_word = first_word + 1
	int i = first_word
	while (i < words.length):
		if ((words[i][0] == '-') && (strcmp(words[i], c"-n") != 0)):
			return 0
		i = i + 1
	string_builder* out = string_new()
	string_append(out, c"shell_commands.echo(")
	if (no_newline):
		string_append(out, c"true")
	else:
		string_append(out, c"false")
	i = first_word
	while (i < words.length):
		string_append(out, c", ")
		char* lit = shell_translate_string_literal(words[i])
		string_append(out, lit)
		free(lit)
		i = i + 1
	string_append(out, c")")
	char* s = out.data
	free(out)
	return s


# head/tail share a shape: one required path positional and a single
# valued flag ("-n N"/"--lines N", Sec 5.4's "future work: valued flags"
# case, now in v1) selecting the line count. The inline "=value"
# spellings ("-n=5"/"--lines=5") are rejected -- fail closed to native
# so the real tool's own handling (an "invalid number of lines: '=5'"
# error for "-n=5") applies, instead of this translator accepting a form
# the native tool would not (see the module header). callee names which
# lib/shell_commands.w function to call; default_n is that tool's
# default count (10, matching real head/tail).
char* shell_translate_head_tail(list[char*] words, char* callee, int default_n):
	char* path = 0
	int n = default_n
	int i = 1
	while (i < words.length):
		char* w = words[i]
		if (w[0] == '-'):
			if (shell_translate_flag_named(w, c"n", c"lines") == 0):
				return 0 /* unknown flag */
			if (shell_translate_flag_inline_value(w) != 0):
				return 0 /* "-n=5"/"--lines=5": not the real tools' forms */
			i = i + 1
			if (i >= words.length):
				return 0 /* "-n" with nothing after it */
			char* value = words[i]
			if (shell_translate_all_digits(value) == 0):
				return 0 /* never guess a partly-numeric value */
			n = atoi(value)
		else:
			if (path != 0):
				return 0 /* head/tail take exactly one path in v1 */
			path = w
		i = i + 1
	if (path == 0):
		return 0 /* a required path, unlike ls's optional one */
	char* path_lit = shell_translate_string_literal(path)
	char* n_str = itoa(n)
	string_builder* out = string_new()
	string_append(out, c"shell_commands.")
	string_append(out, callee)
	string_append(out, c"(")
	string_append(out, path_lit)
	string_append(out, c", ")
	string_append(out, n_str)
	string_append(out, c")")
	free(path_lit)
	free(n_str)
	char* s = out.data
	free(out)
	return s


char* shell_translate_head(list[char*] words):
	return shell_translate_head_tail(words, c"head", 10)


char* shell_translate_tail(list[char*] words):
	return shell_translate_head_tail(words, c"tail", 10)


# wc: one path positional; -l/-w/-c select which counts print (any
# combination). A short cluster like "-lw" splits into '-l' '-w', same
# "no partial credit" rule as ls's -a clustering: an unknown letter
# fails the whole line. No long forms in v1 (the plan's own "wc -l/-w/
# -c" scope).
char* shell_translate_wc(list[char*] words):
	char* path = 0
	int count_lines = 0
	int count_words = 0
	int count_bytes = 0
	int i = 1
	while (i < words.length):
		char* w = words[i]
		if (w[0] == '-'):
			if ((w[1] == '-') || (w[1] == 0)):
				return 0 /* no long flags yet, or a bare "-" */
			int j = 1
			while (w[j] != 0):
				if (w[j] == 'l'):
					count_lines = 1
				else if (w[j] == 'w'):
					count_words = 1
				else if (w[j] == 'c'):
					count_bytes = 1
				else:
					return 0 /* unknown letter in the cluster */
				j = j + 1
		else:
			if (path != 0):
				return 0 /* wc takes exactly one path in v1 */
			path = w
		i = i + 1
	if (path == 0):
		return 0
	char* path_lit = shell_translate_string_literal(path)
	string_builder* out = string_new()
	string_append(out, c"shell_commands.wc(")
	string_append(out, path_lit)
	if (count_lines):
		string_append(out, c", true")
	else:
		string_append(out, c", false")
	if (count_words):
		string_append(out, c", true")
	else:
		string_append(out, c", false")
	if (count_bytes):
		string_append(out, c", true")
	else:
		string_append(out, c", false")
	string_append(out, c")")
	free(path_lit)
	char* s = out.data
	free(out)
	return s


# mkdir: one or more directory positionals; -p/--parents is the only
# known flag, generating a call to lib/shell_commands.w's mkdir_p (the
# module header explains the name -- "mkdir" itself collides with the
# raw mkdir(2) syscall wrapper this file's own import closure already
# brings in).
char* shell_translate_mkdir(list[char*] words):
	int parents = 0
	# dirs borrows words' strings, so only the list struct itself needs
	# freeing -- on the fallback paths too, which used to leak it.
	list[char*] dirs = new list[char*]
	int fail = 0
	int i = 1
	while ((i < words.length) && (fail == 0)):
		char* w = words[i]
		if (w[0] == '-'):
			if (strcmp(w, c"--parents") == 0):
				parents = 1
			else if ((w[1] == '-') || (w[1] == 0)):
				fail = 1
			else:
				int j = 1
				while ((w[j] != 0) && (fail == 0)):
					if (w[j] == 'p'):
						parents = 1
					else:
						fail = 1 /* unknown letter in the cluster */
					j = j + 1
		else:
			dirs.push(w)
		i = i + 1
	if (dirs.length == 0):
		fail = 1 /* mkdir requires at least one directory */
	if (fail):
		__w_list_free(cast(__w_list*, dirs))
		return 0
	string_builder* out = string_new()
	string_append(out, c"shell_commands.mkdir_p(")
	if (parents):
		string_append(out, c"true")
	else:
		string_append(out, c"false")
	i = 0
	while (i < dirs.length):
		string_append(out, c", ")
		char* lit = shell_translate_string_literal(dirs[i])
		string_append(out, lit)
		free(lit)
		i = i + 1
	string_append(out, c")")
	__w_list_free(cast(__w_list*, dirs))
	char* s = out.data
	free(out)
	return s


# rm: one or more path positionals; -r/--recursive and -f/--force are
# the known flags, clustering the same way ls's -a does ("-rf" splits
# into '-r' '-f').
char* shell_translate_rm(list[char*] words):
	int recursive = 0
	int force = 0
	# paths borrows words' strings, so only the list struct itself needs
	# freeing -- on the fallback paths too, which used to leak it.
	list[char*] paths = new list[char*]
	int fail = 0
	int i = 1
	while ((i < words.length) && (fail == 0)):
		char* w = words[i]
		if (w[0] == '-'):
			if (strcmp(w, c"--recursive") == 0):
				recursive = 1
			else if (strcmp(w, c"--force") == 0):
				force = 1
			else if ((w[1] == '-') || (w[1] == 0)):
				fail = 1
			else:
				int j = 1
				while ((w[j] != 0) && (fail == 0)):
					if (w[j] == 'r'):
						recursive = 1
					else if (w[j] == 'f'):
						force = 1
					else:
						fail = 1 /* unknown letter in the cluster */
					j = j + 1
		else:
			paths.push(w)
		i = i + 1
	if (paths.length == 0):
		fail = 1 /* rm requires at least one path */
	if (fail):
		__w_list_free(cast(__w_list*, paths))
		return 0
	string_builder* out = string_new()
	string_append(out, c"shell_commands.rm(")
	if (recursive):
		string_append(out, c"true, ")
	else:
		string_append(out, c"false, ")
	if (force):
		string_append(out, c"true")
	else:
		string_append(out, c"false")
	i = 0
	while (i < paths.length):
		string_append(out, c", ")
		char* lit = shell_translate_string_literal(paths[i])
		string_append(out, lit)
		free(lit)
		i = i + 1
	string_append(out, c")")
	__w_list_free(cast(__w_list*, paths))
	char* s = out.data
	free(out)
	return s


# cp: exactly two path positionals (src, dst); -r/--recursive is the
# only known flag.
char* shell_translate_cp(list[char*] words):
	int recursive = 0
	char* src = 0
	char* dst = 0
	int i = 1
	while (i < words.length):
		char* w = words[i]
		if (w[0] == '-'):
			if (strcmp(w, c"--recursive") == 0):
				recursive = 1
			else if ((w[1] == '-') || (w[1] == 0)):
				return 0
			else:
				int j = 1
				while (w[j] != 0):
					if (w[j] == 'r'):
						recursive = 1
					else:
						return 0 /* unknown letter in the cluster */
					j = j + 1
		else:
			if (src == 0):
				src = w
			else if (dst == 0):
				dst = w
			else:
				return 0 /* cp takes exactly two paths in v1 */
		i = i + 1
	if ((src == 0) || (dst == 0)):
		return 0
	char* src_lit = shell_translate_string_literal(src)
	char* dst_lit = shell_translate_string_literal(dst)
	string_builder* out = string_new()
	string_append(out, c"shell_commands.cp(")
	if (recursive):
		string_append(out, c"true, ")
	else:
		string_append(out, c"false, ")
	string_append(out, src_lit)
	string_append(out, c", ")
	string_append(out, dst_lit)
	string_append(out, c")")
	free(src_lit)
	free(dst_lit)
	char* s = out.data
	free(out)
	return s


# mv: exactly two path positionals (src, dst), no flags in v1.
char* shell_translate_mv(list[char*] words):
	if (words.length != 3):
		return 0
	if ((words[1][0] == '-') || (words[2][0] == '-')):
		return 0
	char* src_lit = shell_translate_string_literal(words[1])
	char* dst_lit = shell_translate_string_literal(words[2])
	string_builder* out = string_new()
	string_append(out, c"shell_commands.mv(")
	string_append(out, src_lit)
	string_append(out, c", ")
	string_append(out, dst_lit)
	string_append(out, c")")
	free(src_lit)
	free(dst_lit)
	char* s = out.data
	free(out)
	return s


# touch: one or more path positionals; -c/--no-create is the only
# known flag (real touch's do-not-create). Valued forms (-t STAMP,
# -d DATE, -r FILE) are unknown letters and fail the whole line closed
# to native.
char* shell_translate_touch(list[char*] words):
	int no_create = 0
	# paths borrows words' strings, so only the list struct itself
	# needs freeing -- on the fallback paths too (mkdir/rm's pattern).
	list[char*] paths = new list[char*]
	int fail = 0
	int i = 1
	while ((i < words.length) && (fail == 0)):
		char* w = words[i]
		if (w[0] == '-'):
			if (strcmp(w, c"--no-create") == 0):
				no_create = 1
			else if ((w[1] == '-') || (w[1] == 0)):
				fail = 1
			else:
				int j = 1
				while ((w[j] != 0) && (fail == 0)):
					if (w[j] == 'c'):
						no_create = 1
					else:
						fail = 1 /* unknown letter in the cluster */
					j = j + 1
		else:
			paths.push(w)
		i = i + 1
	if (paths.length == 0):
		fail = 1 /* touch requires at least one path */
	if (fail):
		__w_list_free(cast(__w_list*, paths))
		return 0
	string_builder* out = string_new()
	string_append(out, c"shell_commands.touch(")
	if (no_create):
		string_append(out, c"true")
	else:
		string_append(out, c"false")
	i = 0
	while (i < paths.length):
		string_append(out, c", ")
		char* lit = shell_translate_string_literal(paths[i])
		string_append(out, lit)
		free(lit)
		i = i + 1
	string_append(out, c")")
	__w_list_free(cast(__w_list*, paths))
	char* s = out.data
	free(out)
	return s


# s as an octal mode value: 1-4 digits of [0-7] ("644", "0755"), else
# -1. Anything else -- a symbolic mode like "u+x", "a=r" -- is not
# octal and makes the whole chmod line fail closed to native, where
# the real chmod's full mode grammar applies.
int shell_translate_octal_value(char* s):
	if (s[0] == 0):
		return -1
	int value = 0
	int i = 0
	while (s[i] != 0):
		if ((s[i] < '0') || (s[i] > '7')):
			return -1
		value = value * 8 + (s[i] - '0')
		i = i + 1
	if (i > 4):
		return -1
	return value


# chmod: an octal mode word then one or more path positionals; no
# flags in v1 (no -R -- a '-' word anywhere fails the line, so
# "chmod -R 755 d" runs the real chmod). Generates a call to
# lib/shell_commands.w's chmod_octal (the module header there explains
# the name -- "chmod" itself collides with the raw chmod(2) syscall
# wrapper, the same collision mkdir_p documents).
char* shell_translate_chmod(list[char*] words):
	if (words.length < 3):
		return 0 /* a mode and at least one path */
	int mode = shell_translate_octal_value(words[1])
	if (mode < 0):
		return 0 /* not an octal mode (symbolic, or a flag) */
	int i = 2
	while (i < words.length):
		if (words[i][0] == '-'):
			return 0 /* no flags in v1 */
		i = i + 1
	char* mode_str = itoa(mode)
	string_builder* out = string_new()
	string_append(out, c"shell_commands.chmod_octal(")
	string_append(out, mode_str)
	free(mode_str)
	i = 2
	while (i < words.length):
		string_append(out, c", ")
		char* lit = shell_translate_string_literal(words[i])
		string_append(out, lit)
		free(lit)
		i = i + 1
	string_append(out, c")")
	char* s = out.data
	free(out)
	return s


# du: at most one optional path (default ".", like ls's);
# -s/--summarize is the only known flag. Everything else real du
# accepts (-h, -a, -b, --max-depth, multiple paths) is unknown here
# and fails the line closed to native.
char* shell_translate_du(list[char*] words):
	int summarize = 0
	char* path = 0
	int i = 1
	while (i < words.length):
		char* w = words[i]
		if (w[0] == '-'):
			if (strcmp(w, c"--summarize") == 0):
				summarize = 1
			else if ((w[1] == '-') || (w[1] == 0)):
				return 0 /* unknown long flag, or a bare "-" */
			else:
				int j = 1
				while (w[j] != 0):
					if (w[j] == 's'):
						summarize = 1
					else:
						return 0 /* unknown letter in the cluster */
					j = j + 1
		else:
			if (path != 0):
				return 0 /* du takes at most one path in v1 */
			path = w
		i = i + 1
	if (path == 0):
		path = c"."
	char* path_lit = shell_translate_string_literal(path)
	string_builder* out = string_new()
	string_append(out, c"shell_commands.du(")
	if (summarize):
		string_append(out, c"true, ")
	else:
		string_append(out, c"false, ")
	string_append(out, path_lit)
	string_append(out, c")")
	free(path_lit)
	char* s = out.data
	free(out)
	return s


# Translate one shell-mode line to a ready-to-eval "shell_commands...."
# W call, or 0 when any part of the recognition test failed -- the
# caller's cue (repl.w) to hand the whole line, untouched, to native
# (Sec 5.2/Sec 7).
char* shell_translate_line(char* line):
	int i = 0
	while (line[i] != 0):
		if (shell_translate_is_meta(line[i])):
			return 0
		i = i + 1
	list[char*] words = shell_translate_tokenize(line)
	char* result = 0
	if (words.length > 0):
		if (strcmp(words[0], c"pwd") == 0):
			result = shell_translate_pwd(words)
		else if (strcmp(words[0], c"ls") == 0):
			result = shell_translate_ls(words)
		else if (strcmp(words[0], c"cat") == 0):
			result = shell_translate_cat(words)
		else if (strcmp(words[0], c"echo") == 0):
			result = shell_translate_echo(words)
		else if (strcmp(words[0], c"head") == 0):
			result = shell_translate_head(words)
		else if (strcmp(words[0], c"tail") == 0):
			result = shell_translate_tail(words)
		else if (strcmp(words[0], c"wc") == 0):
			result = shell_translate_wc(words)
		else if (strcmp(words[0], c"mkdir") == 0):
			result = shell_translate_mkdir(words)
		else if (strcmp(words[0], c"rm") == 0):
			result = shell_translate_rm(words)
		else if (strcmp(words[0], c"cp") == 0):
			result = shell_translate_cp(words)
		else if (strcmp(words[0], c"mv") == 0):
			result = shell_translate_mv(words)
		else if (strcmp(words[0], c"touch") == 0):
			result = shell_translate_touch(words)
		else if (strcmp(words[0], c"chmod") == 0):
			result = shell_translate_chmod(words)
		else if (strcmp(words[0], c"du") == 0):
			result = shell_translate_du(words)
	shell_translate_free_words(words)
	return result
