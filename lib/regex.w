/*
lib.regex: a small POSIX-ish pattern matcher over C strings — the
reusable pattern-matching core that shell-mode grep (issue #335) and
future shell-mode find/sed build on (docs/projects/repl_shell_mode.md
section 6.3). Matching is byte-oriented like lib/str.w: multi-byte
UTF-8 sequences match byte by byte, and class ranges compare raw byte
values 0..255.

Supported syntax (a POSIX-ish subset):
  x        literal character (any byte that is not a metacharacter)
  .        any single byte except newline
  [abc]    character class; [a-z] ranges; [^abc] negation (a negated
           class matches any byte not listed, including newline).
           `]` first in the class body is a literal, `-` first or last
           is a literal, and backslash escapes below work inside
           classes (including as range endpoints).
  \.       backslash before any non-alphanumeric byte matches that
           byte literally (\\ \[ \] \* \+ \? \^ \$ \( \) \- \/ ...);
           \t \n \r match tab, newline, carriage return. Backslash
           before any other alphanumeric (\d, \w, \1, ...) is
           reserved and MALFORMED, not a literal.
  ^        anchor at the very start of the pattern only; a `^`
           anywhere else is a literal.
  $        anchor at the very end of the pattern only; a `$` anywhere
           else is a literal.
  * + ?    greedy quantifiers on the single preceding element.

NOT supported: groups, alternation, backreferences and counted
repetition — `(` `)` `|` `{` `}` are ordinary literals.

Malformed patterns fail cleanly, never trap: an unclosed class
(`[abc`), an out-of-order range (`[z-a]`), a dangling quantifier
(`*a`, `a**`), a trailing backslash or a reserved escape (`\d`) make
regex_valid return 0, regex_match return 0, and regex_search /
regex_match_length return -1.

Matching runs on libs/standard/text/re.w's Pike VM (issue: stdlib
parity plan P1.1c): regex_valid checks the syntax above, rx_translate
rewrites the pattern into re.w syntax (every literal as \xHH, `^`/`$`
as \A/\Z) and the RE_BYTES flag keeps matching byte-oriented. Spans
are the leftmost match with greedy, backtracking-order preference, the
same answers the old backtracker gave. Every call is linear in
len(text) * len(pattern), so pathological patterns (`a*a*a*a*b`
against a long run of `a`s) get the right answer instead of the old
step-budget cut-off, and no step budget is needed. Each call compiles
the pattern and allocates (and frees) its working memory.
*/
import lib.lib
import libs.standard.text.re


int rx_is_quantifier(int c):
	if (c == '*'): return 1
	if (c == '+'): return 1
	return c == '?'


int rx_is_alnum(int c):
	if ((c >= '0') && (c <= '9')): return 1
	if ((c >= 'a') && (c <= 'z')): return 1
	return (c >= 'A') && (c <= 'Z')


# Byte value matched by the escape starting at pattern[pp] (which is
# the backslash), or -1 when the escape is malformed: a trailing
# backslash, or backslash before an alphanumeric other than t/n/r
# (those spellings are reserved for future class shorthands).
int rx_escape_char(char* pattern, int pp):
	int c = pattern[pp + 1] & 255
	switch (c):
		case 0: return -1
		case 't': return 9
		case 'n': return 10
		case 'r': return 13
	if (rx_is_alnum(c)): return -1
	return c


# Index of the `]` closing the class whose `[` is at pattern[pp], or
# -1 when the class is malformed (unclosed, bad escape, or a range
# whose endpoints are out of order). Mirrors rx_class_matches exactly:
# `^` first negates, `]` first in the body is a literal member, `-`
# that is first, last, or an endpoint-less member is a literal.
int rx_class_end(char* pattern, int pp):
	int i = pp + 1
	if (pattern[i] == '^'): i = i + 1
	int first = 1
	while (1):
		if (pattern[i] == 0): return -1
		if ((pattern[i] == ']') && (first == 0)):
			return i
		first = 0
		int lo = 0
		if (pattern[i] == '\\'):
			lo = rx_escape_char(pattern, i)
			if (lo < 0): return -1
			i = i + 2
		else:
			lo = pattern[i] & 255
			i = i + 1
		if ((pattern[i] == '-') && (pattern[i + 1] != ']') && (pattern[i + 1] != 0)):
			i = i + 1
			int hi = 0
			if (pattern[i] == '\\'):
				hi = rx_escape_char(pattern, i)
				if (hi < 0): return -1
				i = i + 2
			else:
				hi = pattern[i] & 255
				i = i + 1
			if (lo > hi): return -1
	return -1


# Length in pattern bytes of the single element starting at
# pattern[pp] (a literal, `.`, an escape, or a whole class), or -1
# when the element is malformed.
int rx_element_length(char* pattern, int pp):
	int c = pattern[pp] & 255
	if (c == '['):
		int end = rx_class_end(pattern, pp)
		if (end < 0): return -1
		return end - pp + 1
	if (c == '\\'):
		if (rx_escape_char(pattern, pp) < 0): return -1
		return 2
	return 1


# Is the pattern well-formed under the syntax in the header? 1/0.
# The matching entry points below all validate first, so callers only
# need regex_valid to distinguish "malformed pattern" from "no
# match".
int regex_valid(char* pattern):
	int i = 0
	if (pattern[i] == '^'): i = i + 1
	# Does a quantifier have a preceding element to bind to?
	int prev_element = 0
	while (pattern[i] != 0):
		int c = pattern[i] & 255
		if (rx_is_quantifier(c)):
			if (prev_element == 0): return 0
			# `a**` is malformed, not "quantified quantifier".
			prev_element = 0
			i = i + 1
		else if ((c == '$') && (pattern[i + 1] == 0)): i = i + 1
		else:
			int el = rx_element_length(pattern, i)
			if (el < 0): return 0
			prev_element = 1
			i = i + el
	return 1


# Appends byte value v to out[at] as the escape \xHH; returns the new
# length.
int rx_put_byte(char* out, int at, int v):
	char* digits = c"0123456789abcdef"
	out[at] = 92
	out[at + 1] = 'x'
	out[at + 2] = digits[(v >> 4) & 15]
	out[at + 3] = digits[v & 15]
	return at + 4


# Value of one class endpoint at pattern[i] (a byte or an escape) and
# its length, via *len.
int rx_class_endpoint(char* pattern, int i, int* len):
	if (pattern[i] == 92):
		len[0] = 2
		return rx_escape_char(pattern, i)
	len[0] = 1
	return pattern[i] & 255


# Translates a VALID lib/regex.w pattern into the equivalent
# libs/standard/text/re.w RE_BYTES pattern (malloc'd, caller frees).
# Every literal, escape and class endpoint becomes \xHH, so the old
# syntax's ordinary `( ) | { }` can never turn into groups, braces or
# alternation; `^` / `$` at the pattern's ends become \A / \Z (the old
# `$` never matched before a trailing newline, unlike Python's).
char* rx_translate(char* pattern):
	char* out = cast(char*, malloc(4 * strlen(pattern) + 8))
	int at = 0
	int i = 0
	if (pattern[0] == '^'):
		out[0] = 92
		out[1] = 'A'
		at = 2
		i = 1
	while (pattern[i] != 0):
		int c = pattern[i] & 255
		if (rx_is_quantifier(c)):
			out[at] = c
			at = at + 1
			i = i + 1
		else if ((c == '$') && (pattern[i + 1] == 0)):
			out[at] = 92
			out[at + 1] = 'Z'
			at = at + 2
			i = i + 1
		else if (c == '.'):
			out[at] = '.'
			at = at + 1
			i = i + 1
		else if (c == '['):
			int end = rx_class_end(pattern, i)
			out[at] = '['
			at = at + 1
			int j = i + 1
			if (pattern[j] == '^'):
				out[at] = '^'
				at = at + 1
				j = j + 1
			int len = 0
			while (j < end):
				at = rx_put_byte(out, at, rx_class_endpoint(pattern, j, &len))
				j = j + len
				if ((pattern[j] == '-') && (j + 1 < end)):
					out[at] = '-'
					at = at + 1
					at = rx_put_byte(out, at, rx_class_endpoint(pattern, j + 1, &len))
					j = j + 1 + len
			out[at] = ']'
			at = at + 1
			i = end + 1
		else if (c == 92):
			at = rx_put_byte(out, at, rx_escape_char(pattern, i))
			i = i + 2
		else:
			at = rx_put_byte(out, at, c)
			i = i + 1
	out[at] = 0
	return out


# Compiles a lib/regex.w pattern for the re.w engine, or 0 when it is
# malformed. Caller frees with re_free.
re_pattern* rx_compile(char* pattern):
	if (regex_valid(pattern) == 0): return cast(re_pattern*, 0)
	char* translated = rx_translate(pattern)
	re_pattern* p = re_compile(translated, RE_BYTES)
	free(translated)
	if (re_error(p) != 0):
		re_free(p)
		return cast(re_pattern*, 0)
	return p


# Does the pattern match the ENTIRE text? 1/0. A malformed pattern
# reports 0.
int regex_match(char* pattern, char* text):
	re_pattern* p = rx_compile(pattern)
	if (p == 0): return 0
	re_result* m = re_fullmatch(p, text)
	re_free(p)
	if (m == 0): return 0
	re_result_free(m)
	return 1


# Byte index of the leftmost match of the pattern anywhere in the
# text, or -1 when there is none (or the pattern is malformed). An
# empty or empty-matching pattern matches at 0. Combine with
# regex_match_length to recover the full span.
int regex_search(char* pattern, char* text):
	re_pattern* p = rx_compile(pattern)
	if (p == 0): return -1
	re_result* m = re_search(p, text)
	re_free(p)
	if (m == 0): return -1
	int at = re_start(m, 0)
	re_result_free(m)
	return at


# Number of text bytes the pattern matches starting exactly at byte
# `start` (greedy, so the span a grep would print), or -1 when it
# does not match there — also for a malformed pattern or an
# out-of-range start. A `^` pattern only matches at start 0.
# regex_search + regex_match_length together yield the leftmost
# matching span.
int regex_match_length(char* pattern, char* text, int start):
	if (start < 0): return -1
	# Bounds-check start without assuming it is <= strlen(text).
	int i = 0
	while ((i < start) && (text[i] != 0)): i = i + 1
	if (i < start): return -1
	re_pattern* p = rx_compile(pattern)
	if (p == 0): return -1
	re_result* m = re_match_at(p, text, strlen(text), start)
	re_free(p)
	if (m == 0): return -1
	int length = re_end(m, 0) - start
	re_result_free(m)
	return length
