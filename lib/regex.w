/*
lib.regex: a small backtracking pattern matcher over C strings — the
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

Pathological backtracking (`a*a*a*a*b` against a long run of `a`s) is
bounded by a fixed step budget per public call (RX_STEP_BUDGET
below). When the budget runs out the call gives up and reports
no-match (0 / -1) instead of running for exponential time; realistic
patterns never come near the limit. Backtracking is iterative per
quantifier, so recursion depth is bounded by the pattern length —
adversarial input cannot blow the stack. No allocation anywhere.
*/
import lib.lib


# Step budget shared by one public call (see the header): every
# matcher step and every backtracking retry spends one unit.
int RX_STEP_BUDGET():
	return 1048576


int rx_is_quantifier(int c):
	if (c == '*'):
		return 1
	if (c == '+'):
		return 1
	return c == '?'


int rx_is_alnum(int c):
	if ((c >= '0') && (c <= '9')):
		return 1
	if ((c >= 'a') && (c <= 'z')):
		return 1
	return (c >= 'A') && (c <= 'Z')


# Byte value matched by the escape starting at pattern[pp] (which is
# the backslash), or -1 when the escape is malformed: a trailing
# backslash, or backslash before an alphanumeric other than t/n/r
# (those spellings are reserved for future class shorthands).
int rx_escape_char(char* pattern, int pp):
	int c = pattern[pp + 1] & 255
	if (c == 0):
		return -1
	if (c == 't'):
		return 9
	if (c == 'n'):
		return 10
	if (c == 'r'):
		return 13
	if (rx_is_alnum(c)):
		return -1
	return c


# Index of the `]` closing the class whose `[` is at pattern[pp], or
# -1 when the class is malformed (unclosed, bad escape, or a range
# whose endpoints are out of order). Mirrors rx_class_matches exactly:
# `^` first negates, `]` first in the body is a literal member, `-`
# that is first, last, or an endpoint-less member is a literal.
int rx_class_end(char* pattern, int pp):
	int i = pp + 1
	if (pattern[i] == '^'):
		i = i + 1
	int first = 1
	while (1):
		if (pattern[i] == 0):
			return -1
		if ((pattern[i] == ']') && (first == 0)):
			return i
		first = 0
		int lo = 0
		if (pattern[i] == '\\'):
			lo = rx_escape_char(pattern, i)
			if (lo < 0):
				return -1
			i = i + 2
		else:
			lo = pattern[i] & 255
			i = i + 1
		if ((pattern[i] == '-') && (pattern[i + 1] != ']') && (pattern[i + 1] != 0)):
			i = i + 1
			int hi = 0
			if (pattern[i] == '\\'):
				hi = rx_escape_char(pattern, i)
				if (hi < 0):
					return -1
				i = i + 2
			else:
				hi = pattern[i] & 255
				i = i + 1
			if (lo > hi):
				return -1
	return -1


# Does the (already validated) class whose `[` is at pattern[pp]
# match byte c? Walks the same member/range structure as
# rx_class_end.
int rx_class_matches(char* pattern, int pp, int c):
	int i = pp + 1
	int negate = 0
	if (pattern[i] == '^'):
		negate = 1
		i = i + 1
	int found = 0
	int first = 1
	while (1):
		if ((pattern[i] == 0) || ((pattern[i] == ']') && (first == 0))):
			if (negate):
				return 1 - found
			return found
		first = 0
		int lo = 0
		if (pattern[i] == '\\'):
			lo = rx_escape_char(pattern, i)
			i = i + 2
		else:
			lo = pattern[i] & 255
			i = i + 1
		int hi = lo
		if ((pattern[i] == '-') && (pattern[i + 1] != ']') && (pattern[i + 1] != 0)):
			i = i + 1
			if (pattern[i] == '\\'):
				hi = rx_escape_char(pattern, i)
				i = i + 2
			else:
				hi = pattern[i] & 255
				i = i + 1
		if ((c >= lo) && (c <= hi)):
			found = 1
	return 0


# Length in pattern bytes of the single element starting at
# pattern[pp] (a literal, `.`, an escape, or a whole class), or -1
# when the element is malformed.
int rx_element_length(char* pattern, int pp):
	int c = pattern[pp] & 255
	if (c == '['):
		int end = rx_class_end(pattern, pp)
		if (end < 0):
			return -1
		return end - pp + 1
	if (c == '\\'):
		if (rx_escape_char(pattern, pp) < 0):
			return -1
		return 2
	return 1


# Does the single element at pattern[pp] match byte c (1..255)?
int rx_element_matches(char* pattern, int pp, int c):
	int pc = pattern[pp] & 255
	if (pc == '['):
		return rx_class_matches(pattern, pp, c)
	if (pc == '\\'):
		return c == rx_escape_char(pattern, pp)
	if (pc == '.'):
		return c != 10
	return c == pc


# Match the pattern from element position pp against text from byte
# tp. Returns the number of text bytes matched (>= 0) or -1 for no
# match. must_end requires the match to reach the end of the text
# (regex_match semantics). steps is the shared backtracking budget;
# once it hits 0 every frame reports no-match and the whole call
# unwinds quickly.
int rx_here(char* pattern, int pp, char* text, int tp, int must_end, int* steps):
	if (steps[0] <= 0):
		return -1
	steps[0] = steps[0] - 1
	if (pattern[pp] == 0):
		if ((must_end != 0) && (text[tp] != 0)):
			return -1
		return 0
	if ((pattern[pp] == '$') && (pattern[pp + 1] == 0)):
		if (text[tp] == 0):
			return 0
		return -1
	int el = rx_element_length(pattern, pp)
	int q = pattern[pp + el] & 255
	if (rx_is_quantifier(q)):
		# Greedy: count how many repetitions fit, then try the rest
		# of the pattern after each count from longest to shortest.
		int max_count = 0
		while ((text[tp + max_count] != 0) && rx_element_matches(pattern, pp, text[tp + max_count] & 255)):
			max_count = max_count + 1
			steps[0] = steps[0] - 1
			if ((steps[0] <= 0) || ((q == '?') && (max_count == 1))):
				break
		if (steps[0] <= 0):
			return -1
		int min_count = 0
		if (q == '+'):
			min_count = 1
		int count = max_count
		while (count >= min_count):
			int rest = rx_here(pattern, pp + el + 1, text, tp + count, must_end, steps)
			if (rest >= 0):
				return count + rest
			if (steps[0] <= 0):
				return -1
			count = count - 1
		return -1
	if ((text[tp] != 0) && rx_element_matches(pattern, pp, text[tp] & 255)):
		int rest = rx_here(pattern, pp + el, text, tp + 1, must_end, steps)
		if (rest >= 0):
			return rest + 1
	return -1


# Is the pattern well-formed under the syntax in the header? 1/0.
# The matching entry points below all validate first, so callers only
# need regex_valid to distinguish "malformed pattern" from "no
# match".
int regex_valid(char* pattern):
	int i = 0
	if (pattern[i] == '^'):
		i = i + 1
	# Does a quantifier have a preceding element to bind to?
	int prev_element = 0
	while (pattern[i] != 0):
		int c = pattern[i] & 255
		if (rx_is_quantifier(c)):
			if (prev_element == 0):
				return 0
			# `a**` is malformed, not "quantified quantifier".
			prev_element = 0
			i = i + 1
		else if ((c == '$') && (pattern[i + 1] == 0)):
			i = i + 1
		else:
			int el = rx_element_length(pattern, i)
			if (el < 0):
				return 0
			prev_element = 1
			i = i + el
	return 1


# Does the pattern match the ENTIRE text? 1/0. A malformed pattern
# (or an exhausted step budget) reports 0.
int regex_match(char* pattern, char* text):
	if (regex_valid(pattern) == 0):
		return 0
	int pp = 0
	if (pattern[0] == '^'):
		pp = 1
	int steps = RX_STEP_BUDGET()
	int length = rx_here(pattern, pp, text, 0, 1, &steps)
	if (length < 0):
		return 0
	return 1


# Byte index of the leftmost match of the pattern anywhere in the
# text, or -1 when there is none (or the pattern is malformed, or the
# budget ran out). An empty or empty-matching pattern matches at 0.
# Combine with regex_match_length to recover the full span.
int regex_search(char* pattern, char* text):
	if (regex_valid(pattern) == 0):
		return -1
	int anchored = 0
	int pp = 0
	if (pattern[0] == '^'):
		anchored = 1
		pp = 1
	int steps = RX_STEP_BUDGET()
	int tp = 0
	while (1):
		int length = rx_here(pattern, pp, text, tp, 0, &steps)
		if (length >= 0):
			return tp
		if (steps <= 0):
			return -1
		if (anchored):
			return -1
		if (text[tp] == 0):
			return -1
		tp = tp + 1
	return -1


# Number of text bytes the pattern matches starting exactly at byte
# `start` (greedy, so the span a grep would print), or -1 when it
# does not match there — also for a malformed pattern, an
# out-of-range start, or an exhausted budget. A `^` pattern only
# matches at start 0. regex_search + regex_match_length together
# yield the leftmost matching span.
int regex_match_length(char* pattern, char* text, int start):
	if (start < 0):
		return -1
	if (regex_valid(pattern) == 0):
		return -1
	int pp = 0
	if (pattern[0] == '^'):
		if (start != 0):
			return -1
		pp = 1
	# Bounds-check start without assuming it is <= strlen(text).
	int i = 0
	while ((i < start) && (text[i] != 0)):
		i = i + 1
	if (i < start):
		return -1
	int steps = RX_STEP_BUDGET()
	return rx_here(pattern, pp, text, start, 0, &steps)
