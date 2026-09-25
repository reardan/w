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
     head, tail, wc, mkdir, rm, cp, mv, touch, chmod, du, ln, df, ps,
     grep -- design doc Sec 11's stage 1-4 lists);
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
"shell_commands_chmod_octal(420, c\"f\")").

Stage 4 adds ln (-s/--symbolic REQUIRED -- a bare "ln" is a hard
link, which stays native), df (no flags, any number of paths), ps
(bare only), and grep (-n/--line-number, then a pattern and one or
more files) -- grep landing now that lib/regex.w exists as the
reusable pattern core the design doc's Sec 6.3 deferred on. grep's
pattern is the second positional-shaped word whose SPELLING is
validated (chmod's octal-mode precedent): a pattern lib/regex.w's
regex_valid rejects (\d, a**, an unclosed class) fails the whole line
closed to native, where the real grep's own syntax applies verbatim.

Stage 4 also makes rule 1's metacharacter scan QUOTE-AWARE
(shell_translate_has_meta below): a metacharacter only forces native
fallback where /bin/sh itself would treat it specially. Inside '...'
nothing is special; inside "..." only $ and backtick still expand (so
those two keep forcing native there); a backslash escapes exactly
what the tokenizer's own rules say it escapes. Grep patterns are why
position-blind scanning finally hurt: "grep 'a.*b' f" is precisely a
quoted '*' the tokenizer already handles the way sh does, and the old
scan sent every such line to native, bypassing the engine entirely.
The refinement is strictly consistency-preserving for the other
tools too: a quoted metacharacter was always passed through literally
by both sh and this tokenizer ("echo '$HOME'" prints the same five
bytes either way); it just no longer forces the native detour.
*/
import lib.lib
import lib.regex
import structures.string


# 1 for a byte that needs real shell semantics -- pipe, redirection,
# chaining, backgrounding, or variable/command/glob expansion -- so its
# presence anywhere on the line means "native fallback, unconditionally"
# (Sec 5.2 rule 1). 96 is the backtick.
int shell_translate_is_meta(char c):
	return (c == '|') || (c == '<') || (c == '>') || (c == ';') || (c == '&') ||
		(c == '$') || (c == 96) || (c == '~') || (c == '*') || (c == '?')


# Quote-aware rule-1 scan (module header, stage 4): 1 when the line
# carries a metacharacter in a position where sh would give it special
# meaning. The quote and escape structure walked here is exactly the
# tokenizer's (shell_translate_tokenize below), so a line this scan
# clears is one the tokenizer splits the same way sh would: '...' is a
# literal span; inside "..." only $ and backtick stay active, and only
# \" and \\ are escapes (a backslash before anything else -- \$
# included -- passes through as data here AND in sh, so a "\$" still
# reads as an active $ and correctly forces native); outside quotes a
# backslash escapes any following byte. An unterminated quote runs to
# end of line, matching the tokenizer.
int shell_translate_has_meta(char* line):
	int i = 0
	while (line[i] != 0):
		if (line[i] == 39): /* '...': nothing is special inside */
			i = i + 1
			while ((line[i] != 0) && (line[i] != 39)):
				i = i + 1
			if (line[i] != 0):
				i = i + 1
		else if (line[i] == 34): /* "...": $ and backtick still expand */
			i = i + 1
			while ((line[i] != 0) && (line[i] != 34)):
				if ((line[i] == 92) && ((line[i + 1] == 34) || (line[i + 1] == 92))):
					i = i + 2
				else:
					if ((line[i] == '$') || (line[i] == 96)):
						return 1
					i = i + 1
			if (line[i] != 0):
				i = i + 1
		else if (line[i] == 92): /* escape outside quotes covers any byte */
			i = i + 1
			if (line[i] != 0):
				i = i + 1
		else:
			if (shell_translate_is_meta(line[i])):
				return 1
			i = i + 1
	return 0


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


# Emission: "shell_commands_<name>(" + comma-separated arguments + ")".
string_builder* shell_call_open(char* name):
	string_builder* out = string_new()
	string_append(out, c"shell_commands_")
	string_append(out, name)
	string_append(out, c"(")
	return out


# Appends one argument's source text.
void shell_call_arg(string_builder* out, char* text):
	if (out.data[out.length - 1] != '('): string_append(out, c", ")
	string_append(out, text)


# Appends a word as a c"..." literal argument.
void shell_call_lit(string_builder* out, char* w):
	char* lit = shell_translate_string_literal(w)
	shell_call_arg(out, lit)
	free(lit)


void shell_call_bool(string_builder* out, int on):
	shell_call_arg(out, on ? c"true" : c"false")


char* shell_call_close(string_builder* out):
	string_append(out, c")")
	char* s = out.data
	free(out)
	return s


# Index of w among the space-separated spellings in longs, or -1.
int shell_long_index(char* longs, char* w):
	int index = 0
	int i = 0
	while (longs[i] != 0):
		int j = 0
		while ((w[j] != 0) && (longs[i + j] == w[j])): j++
		if ((w[j] == 0) && ((longs[i + j] == ' ') || (longs[i + j] == 0))): return index
		while ((longs[i] != 0) && (longs[i] != ' ')): i++
		if (longs[i] == ' '): i++
		index++
	return -1


# Splits words[1..] into flags and positionals (pushed onto pos, still
# borrowing words' strings). letters holds a tool's known short flags;
# a cluster like "-rf" sets each letter it names, and any other letter
# fails the whole line (Sec 5.4's "no partial credit": "ls -lah" falls
# back to the real ls, not a half-translated call). longs holds exact
# spellings, space separated ("--recursive --force"). Flag i -- letter
# i or long spelling i -- sets bit i of the result; an unknown long
# flag or a bare "-" returns -1.
int shell_parse(list[char*] words, char* letters, char* longs, list[char*] pos):
	int flags = 0
	for i in range(1, words.length):
		char* w = words[i]
		if (w[0] != '-'):
			pos.push(w)
			continue
		int bit = shell_long_index(longs, w)
		if (bit >= 0): flags = flags | (1 << bit)
		elif ((w[1] == '-') || (w[1] == 0)): return -1
		else:
			for j in range(1, strlen(w)):
				int k = 0
				while ((letters[k] != 0) && (letters[k] != w[j])): k++
				if (letters[k] == 0): return -1
				flags = flags | (1 << k)
	return flags


# One table-driven tool (shell_translate_line's table): the flags
# shell_parse knows become true/false arguments in letter order, then
# from min_pos to max_pos (-1: any number) positionals become c"..."
# literals -- ahead of the flags instead when paths_first. dflt stands
# in for a missing optional positional (ls/du's documented "."); every
# parameter is resolved to an explicit literal here, never left to the
# callee's defaults.
char* shell_tool(list[char*] words, char* name, char* letters, char* longs, int min_pos, int max_pos, char* dflt, int paths_first):
	list[char*] pos = new list[char*]
	int flags = shell_parse(words, letters, longs, pos)
	char* s = 0
	if ((flags >= 0) && (pos.length >= min_pos) && ((max_pos < 0) || (pos.length <= max_pos))):
		if ((pos.length == 0) && (dflt != 0)): pos.push(dflt)
		string_builder* out = shell_call_open(name)
		if (paths_first):
			for p in pos: shell_call_lit(out, p)
		for i in range(strlen(letters)): shell_call_bool(out, (flags >> i) & 1)
		if (paths_first == 0):
			for p in pos: shell_call_lit(out, p)
		s = shell_call_close(out)
	__w_list_free(cast(__w_list*, pos))
	return s


# echo: "-n" (suppress the trailing newline -- no long form, matching
# real echo) only counts as a flag while it leads the argument list:
# after the first ordinary word a later "-n" is plain text to print
# ("echo a -n" prints "a -n"). Any other '-' word is unknown and fails
# the whole line closed to native (which prints it literally too, so
# the output matches either way).
char* shell_translate_echo(list[char*] words):
	int first_word = 1
	while ((first_word < words.length) && (strcmp(words[first_word], c"-n") == 0)): first_word++
	for i in range(first_word, words.length):
		if ((words[i][0] == '-') && (strcmp(words[i], c"-n") != 0)): return 0
	string_builder* out = shell_call_open(c"echo")
	shell_call_bool(out, first_word > 1)
	for i in range(first_word, words.length): shell_call_lit(out, words[i])
	return shell_call_close(out)


# head/tail: one required path and the valued flag "-n N"/"--lines N"
# (Sec 5.4's first valued flag) selecting the line count, default 10
# like the real tools. The inline "=value" spellings ("-n=5") are
# rejected -- they fail closed to native so the real tool's own
# handling applies (see the module header).
char* shell_translate_head_tail(list[char*] words, char* callee):
	char* path = 0
	int n = 10
	int i = 1
	while (i < words.length):
		char* w = words[i]
		if (w[0] == '-'):
			if (shell_translate_flag_named(w, c"n", c"lines") == 0): return 0
			if (shell_translate_flag_inline_value(w) != 0): return 0
			i++
			# "-n" with nothing after it, or a partly-numeric value: never guess
			if ((i >= words.length) || (shell_translate_all_digits(words[i]) == 0)): return 0
			n = atoi(words[i])
		else:
			if (path != 0): return 0 /* exactly one path in v1 */
			path = w
		i++
	if (path == 0): return 0
	string_builder* out = shell_call_open(callee)
	shell_call_lit(out, path)
	char* n_str = itoa(n)
	shell_call_arg(out, n_str)
	free(n_str)
	return shell_call_close(out)


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


# The tools whose positionals need more than pass-through: chmod's
# leading octal mode word, ln's required -s (a bare "ln" is a hard
# link, left to the real tool; the flag itself is not an argument of
# shell_commands_ln_s), and grep's pattern, which lib/regex.w's
# regex_valid must accept (\d, a**, an unclosed class fail closed to
# native, where the real grep's own syntax applies). No clustering for
# grep: "-n" and "--line-number" are its only spellings.
char* shell_translate_checked(list[char*] words, char* tool):
	list[char*] pos = new list[char*]
	char* s = 0
	int flags = -1
	int mode = -1
	if (strcmp(tool, c"chmod") == 0):
		flags = shell_parse(words, c"", c"", pos)
		if (pos.length >= 2): mode = shell_translate_octal_value(pos[0])
		if ((flags >= 0) && (mode >= 0)):
			string_builder* out = shell_call_open(c"chmod_octal")
			char* mode_str = itoa(mode)
			shell_call_arg(out, mode_str)
			free(mode_str)
			for i in range(1, pos.length): shell_call_lit(out, pos[i])
			s = shell_call_close(out)
	elif (strcmp(tool, c"ln") == 0):
		flags = shell_parse(words, c"s", c"--symbolic", pos)
		if ((flags == 1) && (pos.length == 2)):
			string_builder* out = shell_call_open(c"ln_s")
			for p in pos: shell_call_lit(out, p)
			s = shell_call_close(out)
	else:
		flags = shell_parse(words, c"", c"-n --line-number", pos)
		if ((flags >= 0) && (pos.length >= 2) && regex_valid(pos[0])):
			string_builder* out = shell_call_open(c"grep")
			shell_call_bool(out, flags != 0)
			for p in pos: shell_call_lit(out, p)
			s = shell_call_close(out)
	__w_list_free(cast(__w_list*, pos))
	return s


# Translate one shell-mode line to a ready-to-eval "shell_commands_...."
# W call, or 0 when any part of the recognition test failed -- the
# caller's cue (repl.w) to hand the whole line, untouched, to native
# (Sec 5.2/Sec 7).
#
# The table: every flag not listed (and "-" alone) fails the line, and
# so does a positional count outside the range. The real tools' other
# forms (ls -h, cp -a, du --max-depth, df -h, ps aux, ln -f, mkdir -m,
# rm -i, touch -t, wc --lines, ...) all stay native.
#   pwd, ps    bare only
#   ls         [-a|--all] [-l] [path=.]
#   cat, df    path... (cat needs one or more, df zero or more)
#   echo, head, tail, chmod, ln, grep: see the functions above
#   wc         -l -w -c (any combination) path
#   mkdir      [-p|--parents] dir...
#   rm         [-r|--recursive] [-f|--force] path...
#   cp         [-r|--recursive] src dst
#   mv         src dst
#   touch      [-c|--no-create] path...
#   du         [-s|--summarize] [path=.]
char* shell_translate_line(char* line):
	if (shell_translate_has_meta(line)):
		return 0
	list[char*] words = shell_translate_tokenize(line)
	char* result = 0
	char* cmd = c""
	if (words.length > 0): cmd = words[0]
	if (strcmp(cmd, c"pwd") == 0): result = shell_tool(words, cmd, c"", c"", 0, 0, 0, 0)
	elif (strcmp(cmd, c"ps") == 0): result = shell_tool(words, cmd, c"", c"", 0, 0, 0, 0)
	elif (strcmp(cmd, c"ls") == 0): result = shell_tool(words, cmd, c"al", c"--all", 0, 1, c".", 1)
	elif (strcmp(cmd, c"cat") == 0): result = shell_tool(words, cmd, c"", c"", 1, -1, 0, 0)
	elif (strcmp(cmd, c"df") == 0): result = shell_tool(words, cmd, c"", c"", 0, -1, 0, 0)
	elif (strcmp(cmd, c"wc") == 0): result = shell_tool(words, cmd, c"lwc", c"", 1, 1, 0, 1)
	elif (strcmp(cmd, c"mkdir") == 0): result = shell_tool(words, cmd, c"p", c"--parents", 1, -1, 0, 0)
	elif (strcmp(cmd, c"rm") == 0): result = shell_tool(words, cmd, c"rf", c"--recursive --force", 1, -1, 0, 0)
	elif (strcmp(cmd, c"cp") == 0): result = shell_tool(words, cmd, c"r", c"--recursive", 2, 2, 0, 0)
	elif (strcmp(cmd, c"mv") == 0): result = shell_tool(words, cmd, c"", c"", 2, 2, 0, 0)
	elif (strcmp(cmd, c"touch") == 0): result = shell_tool(words, cmd, c"c", c"--no-create", 1, -1, 0, 0)
	elif (strcmp(cmd, c"du") == 0): result = shell_tool(words, cmd, c"s", c"--summarize", 0, 1, c".", 0)
	elif (strcmp(cmd, c"echo") == 0): result = shell_translate_echo(words)
	elif ((strcmp(cmd, c"head") == 0) || (strcmp(cmd, c"tail") == 0)): result = shell_translate_head_tail(words, cmd)
	elif ((strcmp(cmd, c"chmod") == 0) || (strcmp(cmd, c"ln") == 0) || (strcmp(cmd, c"grep") == 0)): result = shell_translate_checked(words, cmd)
	shell_translate_free_words(words)
	return result


# ---------------------------------------------------------------------------
# Session-function calls (issue #335, design doc Sec 12 "Naming
# collisions"): in shell mode a function the user defined in this
# session wins over a same-named native tool and over the real binary,
# so "greet world" calls the session's greet(c"world"). repl.w owns the
# symbol-table side (which name is a session function, and each
# parameter's kind); this file only turns the typed words into call
# text, staying pure like the rest of the translator.

# How one typed word becomes a W argument for a parameter of that
# kind: char* takes the word as a c"..." literal, an integer type needs
# [-]digits, bool takes true/false/1/0.
enum shell_arg_kind:
	shell_arg_string
	shell_arg_int
	shell_arg_bool


# 1 when w is an optional '-' followed by one or more decimal digits.
int shell_translate_int_word(char* w):
	if (w[0] == '-'):
		return shell_translate_all_digits(w + 1)
	return shell_translate_all_digits(w)


# One word rendered as an argument of the given shell_arg_kind kind,
# appended to out; 0 when the word does not fit the kind (a non-number
# for an integer parameter), else 1.
int shell_translate_append_arg(string_builder* out, char* w, int kind):
	if (kind == shell_arg_int):
		if (shell_translate_int_word(w) == 0):
			return 0
		string_append(out, w)
		return 1
	if (kind == shell_arg_bool):
		if ((strcmp(w, c"true") == 0) || (strcmp(w, c"1") == 0)):
			string_append(out, c"true")
			return 1
		if ((strcmp(w, c"false") == 0) || (strcmp(w, c"0") == 0)):
			string_append(out, c"false")
			return 1
		return 0
	char* lit = shell_translate_string_literal(w)
	string_append(out, lit)
	free(lit)
	return 1


# Call text for session function words[0] with words[1..] as its
# arguments, or 0 when they do not fit its signature. kinds holds one
# shell_arg_kind per fixed parameter; the first `required` of them must be
# supplied, the rest have declared defaults and may be left off.
# variadic_kind is the element kind of a trailing "T... rest"
# parameter, which takes every remaining word, or -1 when there is
# none. Every word is passed positionally and literally: a word
# starting with '-' is just a string argument here, since only the
# function itself knows what its flags mean.
char* shell_translate_session_call(list[char*] words, list[int] kinds, int required, int variadic_kind):
	int given = words.length - 1
	if (given < required):
		return 0
	if ((given > kinds.length) && (variadic_kind < 0)):
		return 0
	string_builder* out = string_new()
	string_append(out, words[0])
	string_append(out, c"(")
	int i = 0
	while (i < given):
		if (i > 0):
			string_append(out, c", ")
		int kind = variadic_kind
		if (i < kinds.length):
			kind = kinds[i]
		if (shell_translate_append_arg(out, words[i + 1], kind) == 0):
			string_free(out)
			return 0
		i = i + 1
	string_append(out, c")")
	char* s = out.data
	free(out)
	return s
