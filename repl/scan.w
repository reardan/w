/*
Continuation scanner for REPL entries.

A pure, line-at-a-time scanner with no I/O: the front end feeds every
line of an entry through repl_scan_line() and reads the resulting state
to decide whether the entry is complete. repl_scan_open() reports the
half of that decision that is scanner state -- unbalanced brackets, an
open block comment or an open string literal keep an entry going
regardless of blank lines. Block continuation (a line whose last
significant character is ':' opens a block that ends at the next blank
line) is read from repl_scan_last_char by the front end, which owns the
blank-line and auto-indent policy around it.
*/


int repl_scan_depth      /* ( [ { nesting */
int repl_scan_comment    /* inside a block comment */
int repl_scan_string     /* 0, or the open quote character */
int repl_scan_last_char  /* last significant character of the last line */


# Reset the scanner state for a fresh entry.
void repl_scan_reset():
	repl_scan_depth = 0
	repl_scan_comment = 0
	repl_scan_string = 0
	repl_scan_last_char = 0


# Scan one line of an entry, updating bracket depth, block-comment and
# string-literal state, and the line's last significant character.
# Comment text never counts as significant; quotes and their contents do.
void repl_scan_line(char* s):
	int i = 0
	repl_scan_last_char = 0
	while (s[i]):
		char c = s[i]
		if (repl_scan_comment):
			if ((c == '*') && (s[i + 1] == '/')):
				repl_scan_comment = 0
				i = i + 1
		else if (repl_scan_string):
			if (c == 92):
				# A backslash escapes the next character (if any)
				if (s[i + 1]):
					i = i + 1
			else if (c == repl_scan_string):
				repl_scan_string = 0
			repl_scan_last_char = c
		else if (c == '#'):
			return;
		else if ((c == '/') && (s[i + 1] == '*')):
			repl_scan_comment = 1
			i = i + 1
		else if ((c == '"') || (c == 39)):
			repl_scan_string = c
			repl_scan_last_char = c
		else:
			if ((c == '(') || (c == '[') || (c == '{')):
				repl_scan_depth = repl_scan_depth + 1
			if ((c == ')') || (c == ']') || (c == '}')):
				repl_scan_depth = repl_scan_depth - 1
			if ((c != ' ') && (c != 9)):
				repl_scan_last_char = c
		i = i + 1


# 1 while the scanner state alone keeps the entry open: unbalanced
# brackets, an open block comment or an open string literal continue an
# entry regardless of blank lines.
int repl_scan_open():
	return (repl_scan_depth > 0) | repl_scan_comment | (repl_scan_string != 0)
