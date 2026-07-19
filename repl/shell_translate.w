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
  2. its first word names a tool this file knows (pwd, ls, cat);
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


void shell_translate_free_words(list[char*] words):
	int i = 0
	while (i < words.length):
		free(words[i])
		i = i + 1


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


# pwd: zero-arg, no flags -- any extra word (flag or positional) fails
# the recognition test and falls back to native.
char* shell_translate_pwd(list[char*] words):
	if (words.length != 1):
		return 0
	return strclone(c"shell_commands.pwd()")


# ls: bare or one path positional; -a/--all is the only known flag in
# v1 (no "-l" -- lib/shell_commands.w's header explains the missing
# stat-wrapper gap). A short cluster like "-la" splits into '-l' '-a';
# per Sec 5.4's "no partial credit" rule, any letter in the cluster that
# isn't 'a' fails the whole line (so "ls -la" falls back to the real ls,
# not a half-translated call).
char* shell_translate_ls(list[char*] words):
	char* path = 0
	int all = 0
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
	shell_translate_free_words(words)
	return result
