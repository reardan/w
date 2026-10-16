/*
libs.standard.text.re: Python-style regular expressions compiled to a
Pike VM (Thompson NFA with capture slots), so every match runs in
O(len(text) * len(program)) time: no exponential blowup on patterns
like (a*)*b or (a|a)*b. Plan: libs/standard/plans/02_text_processing.md
(phase 2-3); chunk P1.1a of docs/projects/stdlib_python_parity.md.

Semantics follow Python's `re` (leftmost match, Perl-style priority:
alternation prefers the left branch, greedy quantifiers prefer more,
lazy ones fewer), with these documented differences:

  * Text and offsets are UTF-8 bytes. Spans are byte offsets, never
    codepoint indexes. `.`, classes and literals match whole UTF-8
    sequences, so a match never splits a valid multi-byte character;
    invalid UTF-8 bytes in the text are matched only by an explicit
    byte escape that encodes to them (in practice: never by `.`).
  * \d \w \s \b are ASCII-only (Python's re.ASCII behaviour), and
    RE_IGNORECASE folds ASCII letters only.
  * Captures inside a repeated group whose body can match empty follow
    CPython's sre rule (an empty iteration counts, then the loop ends),
    but sre sometimes keeps an earlier iteration's capture instead:
    (|a){1,2} fullmatching "a" gives group 1 (0,1) in Python and (1,1)
    here. Differential fuzzing finds such cases only with nullable
    alternatives inside counted or nested repeats, and the overall
    match span (group 0) always agreed.
  * Not supported (re_compile reports an error): backreferences,
    named groups, lookaround, atomic groups, possessive quantifiers,
    conditionals, \N{...}, the L flag.

Syntax: literals; `.`; classes `[...]` with ranges, negation `[^...]`
and \d \w \s \D \W \S inside; groups `(...)`, `(?:...)`; comments
`(?#...)`; inline flags `(?imsx)` at the start of the pattern and scoped
`(?imsx-imsx:...)`; alternation `|`; quantifiers `* + ? {m} {m,} {,n}
{m,n}` and their lazy `?` forms; anchors `^ $ \A \Z \b \B` anywhere;
escapes \n \t \r \f \v \a \0 \ooo \xhh \uhhhh \Uhhhhhhhh and backslash
before any punctuation. Flags: RE_IGNORECASE, RE_MULTILINE, RE_DOTALL,
RE_VERBOSE (whitespace and # comments ignored outside classes); RE_ASCII
is accepted and changes nothing.

API (ownership: the caller frees what re_compile / re_* return):

  re_pattern* p = re_compile(c"(\\w+)@(\\w+)", 0)
  if (re_error(p) != 0): ... re_error_pos(p) is the byte offset
  re_result* m = re_search(p, text)       # 0 when there is no match
  re_start(m, 1), re_end(m, 1)            # -1 for an unmatched group
  char* user = re_group(m, 1)             # malloc'd copy, 0 if unmatched
  re_result_free(m)
  re_free(p)

re_match anchors at the start (Python re.match), re_search finds the
first match anywhere, re_fullmatch requires the whole text. The _at
variants take an explicit length and start offset and behave like
Python's pattern.search(text, pos): `^`, `\A` and `\b` still see the
whole text, so findall/sub/split loops can resume at a previous end.
A result borrows the text pointer (re_group reads it), so keep the
text alive while using the result.
*/
import lib.lib
import lib.memory


const int RE_IGNORECASE = 2
const int RE_MULTILINE = 8
const int RE_DOTALL = 16
const int RE_VERBOSE = 64
const int RE_ASCII = 256
# Byte patterns (Python's re over bytes): the pattern and text are raw
# bytes, not UTF-8, so `.`, classes and \xhh match single bytes 0..255
# and \u / \U are bad escapes. lib/regex.w compiles with it.
const int RE_BYTES = 4096

# Largest compiled program (instructions); counted repetition expands.
const int RE_MAX_PROGRAM = 200000
const int RE_MAX_REPEAT = 65535
const int RE_MAX_DEPTH = 400
const int RE_MAX_CODEPOINT = 1114111


# ---- growable int vector -----------------------------------------------------

struct re_vec:
	int* data
	int length
	int capacity


re_vec* re_vec_new():
	re_vec* v = new re_vec()
	v.capacity = 16
	v.length = 0
	v.data = cast(int*, malloc(v.capacity * __word_size__))
	return v


void re_vec_push(re_vec* v, int x):
	if (v.length == v.capacity):
		int grown = v.capacity * 2
		v.data = cast(int*, realloc(v.data, v.capacity * __word_size__, grown * __word_size__))
		v.capacity = grown
	v.data[v.length] = x
	v.length = v.length + 1


void re_vec_free(re_vec* v):
	if (v == 0): return
	free(v.data)
	free(v)


# ---- public types ------------------------------------------------------------

struct re_pattern:
	char* error      # static message, 0 when the pattern compiled
	int error_pos    # byte offset into the pattern of the error
	int flags
	int groups       # capturing groups (Python pattern.groups)
	int nslots       # 2 * (groups + 1) capture slots + loop registers
	int nprog        # instructions; 3 ints each in prog
	int* prog
	int* classes     # 8 ints (256 bits) per byte class


struct re_result:
	char* text       # borrowed from the caller
	int groups
	int* spans       # 2 * (groups + 1): start, end per group; -1 unmatched


# ---- parser (pattern -> AST) -------------------------------------------------

# AST node layout: 7 ints per node in re_parser.nodes.
const int RE_NODE_SIZE = 7
const int RE_NF_KIND = 0
const int RE_NF_A = 1
const int RE_NF_B = 2
const int RE_NF_C = 3
const int RE_NF_FIRST = 4
const int RE_NF_LAST = 5
const int RE_NF_NEXT = 6

const int RE_NK_EMPTY = 0
const int RE_NK_SET = 1       # a = offset (pairs) into ranges, b = pair count
const int RE_NK_CAT = 2
const int RE_NK_ALT = 3
const int RE_NK_GROUP = 4     # a = group index; one child
const int RE_NK_REPEAT = 5    # a = min, b = max (-1 = unbounded), c = greedy
const int RE_NK_ASSERT = 6    # a = assertion kind

const int RE_AS_BEGIN = 0     # \A, ^ without MULTILINE
const int RE_AS_BOL = 1       # ^ with MULTILINE
const int RE_AS_END = 2       # \Z
const int RE_AS_DOLLAR = 3    # $ without MULTILINE
const int RE_AS_EOL = 4       # $ with MULTILINE
const int RE_AS_WORDB = 5     # \b
const int RE_AS_NWORDB = 6    # \B

# re_parse_escape results
const int RE_ESC_CP = 0
const int RE_ESC_CLASS = 1
const int RE_ESC_ASSERT = 2


struct re_parser:
	char* pat
	int len
	int pos
	int flags
	int groups
	int depth
	int global_ok
	char* error
	int error_pos
	re_vec* nodes
	re_vec* ranges


int re_fail(re_parser* ps, char* message, int pos):
	if (ps.error == 0):
		ps.error = message
		ps.error_pos = pos
	return -1


int re_node(re_parser* ps, int kind, int a, int b, int c):
	int n = ps.nodes.length / RE_NODE_SIZE
	re_vec_push(ps.nodes, kind)
	re_vec_push(ps.nodes, a)
	re_vec_push(ps.nodes, b)
	re_vec_push(ps.nodes, c)
	re_vec_push(ps.nodes, -1)
	re_vec_push(ps.nodes, -1)
	re_vec_push(ps.nodes, -1)
	return n


int re_nf(re_parser* ps, int n, int field):
	return ps.nodes.data[n * RE_NODE_SIZE + field]


void re_nf_set(re_parser* ps, int n, int field, int value):
	ps.nodes.data[n * RE_NODE_SIZE + field] = value


void re_node_add(re_parser* ps, int parent, int child):
	int last = re_nf(ps, parent, RE_NF_LAST)
	if (last < 0): re_nf_set(ps, parent, RE_NF_FIRST, child)
	else: re_nf_set(ps, last, RE_NF_NEXT, child)
	re_nf_set(ps, parent, RE_NF_LAST, child)


int re_peek(re_parser* ps, int offset):
	int i = ps.pos + offset
	if ((i < 0) || (i >= ps.len)): return -1
	return ps.pat[i] & 255


int re_is_digit(int c):
	return (c >= '0') && (c <= '9')


int re_is_word(int c):
	if ((c >= 'a') && (c <= 'z')): return 1
	if ((c >= 'A') && (c <= 'Z')): return 1
	if ((c >= '0') && (c <= '9')): return 1
	return c == '_'


int re_hex_value(int c):
	if ((c >= '0') && (c <= '9')): return c - '0'
	if ((c >= 'a') && (c <= 'f')): return c - 'a' + 10
	if ((c >= 'A') && (c <= 'F')): return c - 'A' + 10
	return -1


# Decodes one UTF-8 codepoint of the pattern at ps.pos and advances.
# Returns -1 (and records an error) for invalid UTF-8.
int re_next_codepoint(re_parser* ps):
	int start = ps.pos
	int c = re_peek(ps, 0)
	if ((c < 128) || (ps.flags & RE_BYTES)):
		ps.pos = ps.pos + 1
		return c
	int need = 0
	int cp = 0
	int min = 0
	if ((c >= 194) && (c <= 223)):
		need = 1
		cp = c & 31
		min = 128
	else if ((c >= 224) && (c <= 239)):
		need = 2
		cp = c & 15
		min = 2048
	else if ((c >= 240) && (c <= 244)):
		need = 3
		cp = c & 7
		min = 65536
	else:
		return re_fail(ps, c"invalid UTF-8 in pattern", start)
	for i in range(need):
		int d = re_peek(ps, i + 1)
		if ((d < 128) || (d > 191)): return re_fail(ps, c"invalid UTF-8 in pattern", start)
		cp = (cp << 6) | (d & 63)
	if ((cp < min) || (cp > RE_MAX_CODEPOINT)): return re_fail(ps, c"invalid UTF-8 in pattern", start)
	ps.pos = ps.pos + need + 1
	return cp


# Reads exactly count hex digits; -1 (error recorded) when short.
int re_read_hex(re_parser* ps, int count, int esc_start):
	int v = 0
	for i in range(count):
		int h = re_hex_value(re_peek(ps, 0))
		if (h < 0): return re_fail(ps, c"incomplete escape", esc_start)
		v = v * 16 + h
		ps.pos = ps.pos + 1
	return v


# Reads up to max_more further octal digits after an initial value.
int re_read_octal(re_parser* ps, int value, int max_more, int esc_start):
	int v = value
	int k = 0
	while ((k < max_more) && (re_peek(ps, 0) >= '0') && (re_peek(ps, 0) <= '7')):
		v = v * 8 + re_peek(ps, 0) - '0'
		ps.pos = ps.pos + 1
		k = k + 1
	if (v > 255): return re_fail(ps, c"octal escape value outside of range 0-0o377", esc_start)
	return v


# Parses the escape at ps.pos (which is the backslash). Returns one of
# RE_ESC_CP (*out = codepoint), RE_ESC_CLASS (*out = 'd' 'D' 'w' 'W'
# 's' 'S'), RE_ESC_ASSERT (*out = RE_AS_*), or -1 on error.
int re_parse_escape(re_parser* ps, int in_class, int* out):
	int start = ps.pos
	ps.pos = ps.pos + 1
	int c = re_peek(ps, 0)
	if (c < 0): return re_fail(ps, c"bad escape (end of pattern)", start)
	if ((c == 'd') || (c == 'D') || (c == 'w') || (c == 'W') || (c == 's') || (c == 'S')):
		ps.pos = ps.pos + 1
		out[0] = c
		return RE_ESC_CLASS
	ps.pos = ps.pos + 1
	if (c == 'n'):
		out[0] = 10
		return RE_ESC_CP
	if (c == 't'):
		out[0] = 9
		return RE_ESC_CP
	if (c == 'r'):
		out[0] = 13
		return RE_ESC_CP
	if (c == 'f'):
		out[0] = 12
		return RE_ESC_CP
	if (c == 'v'):
		out[0] = 11
		return RE_ESC_CP
	if (c == 'a'):
		out[0] = 7
		return RE_ESC_CP
	if ((c == 'x') || (c == 'u') || (c == 'U')):
		# Python byte patterns have \xhh but no \u / \U.
		if ((c != 'x') && (ps.flags & RE_BYTES)): return re_fail(ps, c"bad escape", start)
		int count = 2
		if (c == 'u'): count = 4
		if (c == 'U'): count = 8
		int v = re_read_hex(ps, count, start)
		if (v < 0): return -1
		if (v > RE_MAX_CODEPOINT): return re_fail(ps, c"bad escape (codepoint out of range)", start)
		out[0] = v
		return RE_ESC_CP
	if (c == 'b'):
		if (in_class):
			out[0] = 8
			return RE_ESC_CP
		out[0] = RE_AS_WORDB
		return RE_ESC_ASSERT
	if ((c == 'B') && (in_class == 0)):
		out[0] = RE_AS_NWORDB
		return RE_ESC_ASSERT
	if ((c == 'A') && (in_class == 0)):
		out[0] = RE_AS_BEGIN
		return RE_ESC_ASSERT
	if ((c == 'Z') && (in_class == 0)):
		out[0] = RE_AS_END
		return RE_ESC_ASSERT
	if (c == 'N'): return re_fail(ps, c"named unicode escapes are not supported", start)
	if (c == '0'):
		int v = re_read_octal(ps, 0, 2, start)
		if (v < 0): return -1
		out[0] = v
		return RE_ESC_CP
	if (re_is_digit(c)):
		if (in_class):
			if (c > '7'): return re_fail(ps, c"bad escape", start)
			int v = re_read_octal(ps, c - '0', 2, start)
			if (v < 0): return -1
			out[0] = v
			return RE_ESC_CP
		int d1 = re_peek(ps, 0)
		int d2 = re_peek(ps, 1)
		if ((c <= '7') && (d1 >= '0') && (d1 <= '7') && (d2 >= '0') && (d2 <= '7')):
			int v = re_read_octal(ps, c - '0', 2, start)
			if (v < 0): return -1
			out[0] = v
			return RE_ESC_CP
		return re_fail(ps, c"backreferences are not supported", start)
	if (((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z'))):
		return re_fail(ps, c"bad escape", start)
	ps.pos = ps.pos - 1
	int cp = re_next_codepoint(ps)
	if (cp < 0): return -1
	out[0] = cp
	return RE_ESC_CP


# ---- codepoint range sets ----------------------------------------------------

void re_push_range(re_vec* v, int lo, int hi):
	re_vec_push(v, lo)
	re_vec_push(v, hi)


# Appends the ranges of \d \w \s (lowercase kind) to v.
void re_class_ranges(re_vec* v, int kind):
	if (kind == 'd'):
		re_push_range(v, '0', '9')
	else if (kind == 'w'):
		re_push_range(v, '0', '9')
		re_push_range(v, 'A', 'Z')
		re_push_range(v, '_', '_')
		re_push_range(v, 'a', 'z')
	else:
		re_push_range(v, 9, 13)
		re_push_range(v, 32, 32)


# Sorts v's (lo, hi) pairs by lo and merges overlapping or adjacent ones.
void re_ranges_normalize(re_vec* v):
	int n = v.length / 2
	int* d = v.data
	int i = 1
	while (i < n):
		int lo = d[2 * i]
		int hi = d[2 * i + 1]
		int j = i - 1
		while ((j >= 0) && (d[2 * j] > lo)):
			d[2 * j + 2] = d[2 * j]
			d[2 * j + 3] = d[2 * j + 1]
			j = j - 1
		d[2 * j + 2] = lo
		d[2 * j + 3] = hi
		i = i + 1
	int out = 0
	for k in range(n):
		int lo = d[2 * k]
		int hi = d[2 * k + 1]
		if ((out > 0) && (lo <= d[2 * out - 1] + 1)):
			if (hi > d[2 * out - 1]): d[2 * out - 1] = hi
		else:
			d[2 * out] = lo
			d[2 * out + 1] = hi
			out = out + 1
	v.length = out * 2


# Appends the complement (within 0..RE_MAX_CODEPOINT) of the normalized
# ranges src to dst.
void re_ranges_complement(re_vec* src, re_vec* dst):
	int next = 0
	int n = src.length / 2
	for k in range(n):
		int lo = src.data[2 * k]
		if (lo > next): re_push_range(dst, next, lo - 1)
		next = src.data[2 * k + 1] + 1
	if (next <= RE_MAX_CODEPOINT): re_push_range(dst, next, RE_MAX_CODEPOINT)


# Adds the other ASCII case of every letter in v.
void re_ranges_fold(re_vec* v):
	int n = v.length / 2
	for k in range(n):
		int lo = v.data[2 * k]
		int hi = v.data[2 * k + 1]
		int a = lo
		int b = hi
		if (a < 'a'): a = 'a'
		if (b > 'z'): b = 'z'
		if (a <= b): re_push_range(v, a - 32, b - 32)
		a = lo
		b = hi
		if (a < 'A'): a = 'A'
		if (b > 'Z'): b = 'Z'
		if (a <= b): re_push_range(v, a + 32, b + 32)


# Turns raw ranges into a SET node (applying case folding and negation)
# and frees raw.
int re_set_node(re_parser* ps, re_vec* raw, int negate):
	if (ps.flags & RE_IGNORECASE): re_ranges_fold(raw)
	re_ranges_normalize(raw)
	re_vec* final = raw
	if (negate):
		final = re_vec_new()
		re_ranges_complement(raw, final)
		re_vec_free(raw)
	if (ps.flags & RE_BYTES):
		# Byte patterns: clip every range to 0..255.
		int kept = 0
		for k in range(final.length / 2):
			if (final.data[2 * k] <= 255):
				final.data[2 * kept] = final.data[2 * k]
				final.data[2 * kept + 1] = final.data[2 * k + 1]
				if (final.data[2 * kept + 1] > 255): final.data[2 * kept + 1] = 255
				kept = kept + 1
		final.length = kept * 2
	int offset = ps.ranges.length / 2
	for k in range(final.length): re_vec_push(ps.ranges, final.data[k])
	int n = re_node(ps, RE_NK_SET, offset, final.length / 2, 0)
	re_vec_free(final)
	return n


int re_literal_node(re_parser* ps, int cp):
	re_vec* raw = re_vec_new()
	re_push_range(raw, cp, cp)
	return re_set_node(ps, raw, 0)


# \d \D \w \W \s \S outside a class.
int re_escape_class_node(re_parser* ps, int kind):
	re_vec* raw = re_vec_new()
	int negate = 0
	if ((kind >= 'A') && (kind <= 'Z')):
		negate = 1
		kind = kind + 32
	re_class_ranges(raw, kind)
	# Folding cannot change \d \w \s (already case-closed), so fold
	# before negating like re_set_node does.
	return re_set_node(ps, raw, negate)


int re_dot_node(re_parser* ps):
	re_vec* raw = re_vec_new()
	if (ps.flags & RE_DOTALL):
		re_push_range(raw, 0, RE_MAX_CODEPOINT)
		return re_set_node(ps, raw, 0)
	re_push_range(raw, 10, 10)
	return re_set_node(ps, raw, 1)


# Parses one class item: returns RE_ESC_CP (*out codepoint), RE_ESC_CLASS
# (*out kind) or -1.
int re_class_item(re_parser* ps, int* out):
	if (re_peek(ps, 0) == 92): return re_parse_escape(ps, 1, out)
	int cp = re_next_codepoint(ps)
	if (cp < 0): return -1
	out[0] = cp
	return RE_ESC_CP


# Parses `[...]` with ps.pos at '['.
int re_parse_class(re_parser* ps):
	int start = ps.pos
	ps.pos = ps.pos + 1
	int negate = 0
	if (re_peek(ps, 0) == '^'):
		negate = 1
		ps.pos = ps.pos + 1
	re_vec* raw = re_vec_new()
	int first = 1
	int item = 0
	while (1):
		if (ps.pos >= ps.len):
			re_vec_free(raw)
			return re_fail(ps, c"unterminated character set", start)
		if ((re_peek(ps, 0) == ']') && (first == 0)):
			ps.pos = ps.pos + 1
			break
		first = 0
		int item_start = ps.pos
		int kind = re_class_item(ps, &item)
		if (kind < 0):
			re_vec_free(raw)
			return -1
		if (kind == RE_ESC_CLASS):
			if ((re_peek(ps, 0) == '-') && (re_peek(ps, 1) >= 0) && (re_peek(ps, 1) != ']')):
				re_vec_free(raw)
				return re_fail(ps, c"bad character range", item_start)
			if ((item >= 'A') && (item <= 'Z')):
				re_vec* tmp = re_vec_new()
				re_class_ranges(tmp, item + 32)
				re_ranges_complement(tmp, raw)
				re_vec_free(tmp)
			else:
				re_class_ranges(raw, item)
			continue
		int lo = item
		int hi = item
		if ((re_peek(ps, 0) == '-') && (re_peek(ps, 1) >= 0) && (re_peek(ps, 1) != ']')):
			ps.pos = ps.pos + 1
			int kind2 = re_class_item(ps, &item)
			if (kind2 < 0):
				re_vec_free(raw)
				return -1
			if ((kind2 != RE_ESC_CP) || (item < lo)):
				re_vec_free(raw)
				return re_fail(ps, c"bad character range", item_start)
			hi = item
		re_push_range(raw, lo, hi)
	return re_set_node(ps, raw, negate)


# Tries to parse `{m}`, `{m,}`, `{,n}`, `{m,n}` at ps.pos ('{'). On
# success advances past '}' and returns 1 with *min / *max (-1 =
# unbounded); returns 0 (pos unchanged) when the brace is a literal, -1
# on error.
int re_parse_braces(re_parser* ps, int* min, int* max):
	int start = ps.pos
	int i = 1
	if (re_peek(ps, 1) == '}'): return 0
	int lo = -1
	int hi = -1
	while (re_is_digit(re_peek(ps, i))):
		if (lo < 0): lo = 0
		lo = lo * 10 + re_peek(ps, i) - '0'
		if (lo > RE_MAX_REPEAT): lo = RE_MAX_REPEAT + 1
		i = i + 1
	int comma = 0
	if (re_peek(ps, i) == ','):
		comma = 1
		i = i + 1
		while (re_is_digit(re_peek(ps, i))):
			if (hi < 0): hi = 0
			hi = hi * 10 + re_peek(ps, i) - '0'
			if (hi > RE_MAX_REPEAT): hi = RE_MAX_REPEAT + 1
			i = i + 1
	else:
		hi = lo
	if (re_peek(ps, i) != '}'): return 0
	if ((comma == 0) && (lo < 0)): return 0
	ps.pos = ps.pos + i + 1
	if (lo < 0): lo = 0
	if ((lo > RE_MAX_REPEAT) || (hi > RE_MAX_REPEAT)): return re_fail(ps, c"the repetition number is too large", start)
	if ((hi >= 0) && (hi < lo)): return re_fail(ps, c"min repeat greater than max repeat", start)
	min[0] = lo
	max[0] = hi
	return 1


int re_is_quantifier_at(re_parser* ps):
	int c = re_peek(ps, 0)
	if ((c == '*') || (c == '+') || (c == '?')): return 1
	if (c != '{'): return 0
	int lo = 0
	int hi = 0
	int saved = ps.pos
	int r = re_parse_braces(ps, &lo, &hi)
	ps.pos = saved
	return r != 0


# Skips whitespace and # comments when RE_VERBOSE is on.
void re_skip_verbose(re_parser* ps):
	if ((ps.flags & RE_VERBOSE) == 0): return
	while (ps.pos < ps.len):
		int c = re_peek(ps, 0)
		if ((c == ' ') || (c == 9) || (c == 10) || (c == 11) || (c == 12) || (c == 13)):
			ps.pos = ps.pos + 1
		else if (c == '#'):
			while ((ps.pos < ps.len) && (re_peek(ps, 0) != 10)): ps.pos = ps.pos + 1
		else:
			return


int re_parse_alt(re_parser* ps);


# Flag letter -> RE_* bit; 0 for a no-op letter, -1 for unknown.
int re_flag_bit(int c):
	if (c == 'i'): return RE_IGNORECASE
	if (c == 'm'): return RE_MULTILINE
	if (c == 's'): return RE_DOTALL
	if (c == 'x'): return RE_VERBOSE
	if ((c == 'a') || (c == 'u')): return 0
	return -1


# Parses `(?...` with ps.pos just past "(?". group_start is the '('.
# Returns a node, -1 on error, or -2 for a global flag group / comment
# that produces no node.
int re_parse_extension(re_parser* ps, int group_start):
	int c = re_peek(ps, 0)
	if (c == ':'):
		ps.pos = ps.pos + 1
		int inner = re_parse_alt(ps)
		if (inner < 0): return -1
		if (re_peek(ps, 0) != ')'): return re_fail(ps, c"missing ), unterminated subpattern", group_start)
		ps.pos = ps.pos + 1
		return inner
	if (c == '#'):
		while ((ps.pos < ps.len) && (re_peek(ps, 0) != ')')): ps.pos = ps.pos + 1
		if (ps.pos >= ps.len): return re_fail(ps, c"missing ), unterminated comment", group_start)
		ps.pos = ps.pos + 1
		return -2
	if ((c == '=') || (c == '!')): return re_fail(ps, c"lookahead assertions are not supported", group_start)
	if (c == '<'):
		int d = re_peek(ps, 1)
		if ((d == '=') || (d == '!')): return re_fail(ps, c"lookbehind assertions are not supported", group_start)
		return re_fail(ps, c"named groups are not supported", group_start)
	if (c == 'P'): return re_fail(ps, c"named groups are not supported", group_start)
	if (c == '>'): return re_fail(ps, c"atomic groups are not supported", group_start)
	if (c == '('): return re_fail(ps, c"conditional groups are not supported", group_start)
	int on = 0
	int off = 0
	int any = 0
	while (re_flag_bit(re_peek(ps, 0)) >= 0):
		on = on | re_flag_bit(re_peek(ps, 0))
		ps.pos = ps.pos + 1
		any = 1
	if (re_peek(ps, 0) == '-'):
		ps.pos = ps.pos + 1
		int any_off = 0
		while (re_flag_bit(re_peek(ps, 0)) >= 0):
			off = off | re_flag_bit(re_peek(ps, 0))
			ps.pos = ps.pos + 1
			any_off = 1
		if (any_off == 0): return re_fail(ps, c"missing flag", ps.pos)
		if (re_peek(ps, 0) != ':'): return re_fail(ps, c"missing :", ps.pos)
		any = 1
	if (any == 0):
		if (re_peek(ps, 0) == 'L'): return re_fail(ps, c"the L flag is not supported", ps.pos)
		return re_fail(ps, c"unknown extension", group_start)
	if (re_peek(ps, 0) == ')'):
		if (ps.global_ok == 0): return re_fail(ps, c"global flags not at the start of the expression", group_start)
		ps.pos = ps.pos + 1
		ps.flags = ps.flags | on
		return -2
	if (re_peek(ps, 0) != ':'):
		if (re_peek(ps, 0) == 'L'): return re_fail(ps, c"the L flag is not supported", ps.pos)
		return re_fail(ps, c"missing -, : or )", ps.pos)
	ps.pos = ps.pos + 1
	int saved = ps.flags
	ps.flags = (ps.flags | on) & (-1 - off)
	int inner = re_parse_alt(ps)
	ps.flags = saved
	if (inner < 0): return -1
	if (re_peek(ps, 0) != ')'): return re_fail(ps, c"missing ), unterminated subpattern", group_start)
	ps.pos = ps.pos + 1
	return inner


# Parses one atom. Returns a node, -1 on error, -2 for "nothing here"
# (a flag group or comment). *is_assert is set for anchors.
int re_parse_atom(re_parser* ps, int* is_assert):
	is_assert[0] = 0
	int start = ps.pos
	int c = re_peek(ps, 0)
	if (c == '('):
		ps.pos = ps.pos + 1
		ps.depth = ps.depth + 1
		if (ps.depth > RE_MAX_DEPTH): return re_fail(ps, c"pattern nested too deeply", start)
		int result = 0
		if (re_peek(ps, 0) == '?'):
			ps.pos = ps.pos + 1
			result = re_parse_extension(ps, start)
		else:
			ps.global_ok = 0
			ps.groups = ps.groups + 1
			int index = ps.groups
			int inner = re_parse_alt(ps)
			if (inner < 0): return -1
			if (re_peek(ps, 0) != ')'): return re_fail(ps, c"missing ), unterminated subpattern", start)
			ps.pos = ps.pos + 1
			int g = re_node(ps, RE_NK_GROUP, index, 0, 0)
			re_node_add(ps, g, inner)
			result = g
		ps.depth = ps.depth - 1
		return result
	ps.global_ok = 0
	if (c == '['): return re_parse_class(ps)
	if (c == '.'):
		ps.pos = ps.pos + 1
		return re_dot_node(ps)
	if (c == '^'):
		ps.pos = ps.pos + 1
		is_assert[0] = 1
		if (ps.flags & RE_MULTILINE): return re_node(ps, RE_NK_ASSERT, RE_AS_BOL, 0, 0)
		return re_node(ps, RE_NK_ASSERT, RE_AS_BEGIN, 0, 0)
	if (c == '$'):
		ps.pos = ps.pos + 1
		is_assert[0] = 1
		if (ps.flags & RE_MULTILINE): return re_node(ps, RE_NK_ASSERT, RE_AS_EOL, 0, 0)
		return re_node(ps, RE_NK_ASSERT, RE_AS_DOLLAR, 0, 0)
	if (re_is_quantifier_at(ps)): return re_fail(ps, c"nothing to repeat", start)
	if (c == 92):
		int value = 0
		int kind = re_parse_escape(ps, 0, &value)
		if (kind < 0): return -1
		if (kind == RE_ESC_CLASS): return re_escape_class_node(ps, value)
		if (kind == RE_ESC_ASSERT):
			is_assert[0] = 1
			return re_node(ps, RE_NK_ASSERT, value, 0, 0)
		return re_literal_node(ps, value)
	int cp = re_next_codepoint(ps)
	if (cp < 0): return -1
	return re_literal_node(ps, cp)


# Parses a concatenation up to '|', ')' or the end.
int re_parse_cat(re_parser* ps):
	int cat = re_node(ps, RE_NK_CAT, 0, 0, 0)
	while (1):
		re_skip_verbose(ps)
		int c = re_peek(ps, 0)
		if ((c < 0) || (c == '|') || (c == ')')): return cat
		int atom_start = ps.pos
		int is_assert = 0
		int atom = re_parse_atom(ps, &is_assert)
		if (atom == -2): continue
		if (atom < 0): return -1
		while (1):
			re_skip_verbose(ps)
			int q = re_peek(ps, 0)
			int min = 0
			int max = -1
			int qstart = ps.pos
			if (q == '*'):
				ps.pos = ps.pos + 1
			else if (q == '+'):
				min = 1
				ps.pos = ps.pos + 1
			else if (q == '?'):
				max = 1
				ps.pos = ps.pos + 1
			else if (q == '{'):
				int r = re_parse_braces(ps, &min, &max)
				if (r < 0): return -1
				if (r == 0): break
			else:
				break
			if (is_assert): return re_fail(ps, c"nothing to repeat", atom_start)
			int greedy = 1
			if (re_peek(ps, 0) == '?'):
				greedy = 0
				ps.pos = ps.pos + 1
			else if (re_peek(ps, 0) == '+'):
				return re_fail(ps, c"possessive quantifiers are not supported", qstart)
			int rep = re_node(ps, RE_NK_REPEAT, min, max, greedy)
			re_node_add(ps, rep, atom)
			atom = rep
			re_skip_verbose(ps)
			if (re_is_quantifier_at(ps)): return re_fail(ps, c"multiple repeat", ps.pos)
			break
		re_node_add(ps, cat, atom)


int re_parse_alt(re_parser* ps):
	int first = re_parse_cat(ps)
	if (first < 0): return -1
	if (re_peek(ps, 0) != '|'): return first
	int alt = re_node(ps, RE_NK_ALT, 0, 0, 0)
	re_node_add(ps, alt, first)
	while (re_peek(ps, 0) == '|'):
		ps.pos = ps.pos + 1
		int next = re_parse_cat(ps)
		if (next < 0): return -1
		re_node_add(ps, alt, next)
	return alt


# ---- compiler (AST -> Pike VM program) ---------------------------------------

const int RE_OP_CHAR = 0       # x = byte
const int RE_OP_CLASS = 1      # x = class index (256-bit map)
const int RE_OP_RANGE = 2      # x..y byte range
const int RE_OP_MATCH = 3
const int RE_OP_JMP = 4        # x = target
const int RE_OP_SPLIT = 5      # x = preferred target, y = other
const int RE_OP_SAVE = 6       # x = slot
const int RE_OP_ASSERT = 7     # x = RE_AS_*
const int RE_OP_MARK = 8       # x = register; stores the position
const int RE_OP_PROGRESS = 9   # x = register, y = loop head: jump if moved
const int RE_OP_FAIL = 10


struct re_compiler:
	re_parser* ps
	re_vec* prog
	re_vec* classes
	int nregs
	int first_reg


int re_emit(re_compiler* cc, int op, int x, int y):
	int pc = cc.prog.length / 3
	if (pc >= RE_MAX_PROGRAM):
		re_fail(cc.ps, c"pattern too large", 0)
		return pc
	re_vec_push(cc.prog, op)
	re_vec_push(cc.prog, x)
	re_vec_push(cc.prog, y)
	return pc


int re_pc(re_compiler* cc):
	return cc.prog.length / 3


void re_patch(re_compiler* cc, int pc, int field, int value):
	if (pc * 3 + field < cc.prog.length): cc.prog.data[pc * 3 + field] = value


int re_utf8_length(int cp):
	if (cp < 128): return 1
	if (cp < 2048): return 2
	if (cp < 65536): return 3
	return 4


void re_utf8_encode(int cp, int* out):
	int n = re_utf8_length(cp)
	if (n == 1):
		out[0] = cp
	else if (n == 2):
		out[0] = 192 | (cp >> 6)
		out[1] = 128 | (cp & 63)
	else if (n == 3):
		out[0] = 224 | (cp >> 12)
		out[1] = 128 | ((cp >> 6) & 63)
		out[2] = 128 | (cp & 63)
	else:
		out[0] = 240 | (cp >> 18)
		out[1] = 128 | ((cp >> 12) & 63)
		out[2] = 128 | ((cp >> 6) & 63)
		out[3] = 128 | (cp & 63)


# Splits the non-ASCII codepoint range lo..hi into UTF-8 byte-range
# sequences (Russ Cox's utf8ranges), appending [n, lo1, hi1, ...] per
# sequence to out.
void re_utf8_split(re_vec* out, int lo, int hi):
	if (lo > hi): return
	if ((lo <= 2047) && (hi > 2047)):
		re_utf8_split(out, lo, 2047)
		re_utf8_split(out, 2048, hi)
		return
	if ((lo <= 65535) && (hi > 65535)):
		re_utf8_split(out, lo, 65535)
		re_utf8_split(out, 65536, hi)
		return
	int n = re_utf8_length(lo)
	for i in range(1, n):
		int m = (1 << (6 * i)) - 1
		if ((lo - (lo & m)) != (hi - (hi & m))):
			if ((lo & m) != 0):
				re_utf8_split(out, lo, lo | m)
				re_utf8_split(out, (lo | m) + 1, hi)
				return
			if ((hi & m) != m):
				re_utf8_split(out, lo, (hi - (hi & m)) - 1)
				re_utf8_split(out, hi - (hi & m), hi)
				return
	int[4] a
	int[4] b
	re_utf8_encode(lo, &a[0])
	re_utf8_encode(hi, &b[0])
	re_vec_push(out, n)
	for k in range(n):
		re_vec_push(out, a[k])
		re_vec_push(out, b[k])


void re_compile_node(re_compiler* cc, int n);


# Emits one instruction matching the bytes 0..top of the ranges r: CHAR
# for a single byte, else CLASS with a 256-bit map. top is 127 (the
# ASCII part) or 255 (RE_BYTES).
void re_emit_ascii(re_compiler* cc, int* r, int count, int ascii_count, int single, int top):
	if (ascii_count == 1):
		re_emit(cc, RE_OP_CHAR, single, 0)
		return
	int index = cc.classes.length / 8
	for w in range(8): re_vec_push(cc.classes, 0)
	for k in range(count):
		int lo = r[2 * k]
		int hi = r[2 * k + 1]
		if (hi > top): hi = top
		int ch = lo
		while (ch <= hi):
			int slot = index * 8 + (ch >> 5)
			cc.classes.data[slot] = cc.classes.data[slot] | (1 << (ch & 31))
			ch = ch + 1
	re_emit(cc, RE_OP_CLASS, index, 0)


void re_compile_set(re_compiler* cc, int offset, int count):
	int* r = &cc.ps.ranges.data[offset * 2]
	if (cc.ps.flags & RE_BYTES):
		# Ranges are already clipped to 0..255: one byte instruction.
		int total = 0
		for k in range(count): total = total + r[2 * k + 1] - r[2 * k] + 1
		if (total == 0): re_emit(cc, RE_OP_FAIL, 0, 0)
		else: re_emit_ascii(cc, r, count, total, r[0], 255)
		return
	int ascii_count = 0
	int single = -1
	for k in range(count):
		int lo = r[2 * k]
		int hi = r[2 * k + 1]
		if (lo < 128):
			if (hi > 127): hi = 127
			ascii_count = ascii_count + hi - lo + 1
			single = lo
	# Ranges are sorted, so the last one says whether any is non-ASCII.
	if ((ascii_count > 0) && (r[2 * count - 1] < 128)):
		re_emit_ascii(cc, r, count, ascii_count, single, 127)
		return
	re_vec* seqs = re_vec_new()
	int nseq = 0
	for k in range(count):
		int lo = r[2 * k]
		int hi = r[2 * k + 1]
		if (hi >= 128):
			if (lo < 128): lo = 128
			int before = seqs.length
			re_utf8_split(seqs, lo, hi)
			int at = before
			while (at < seqs.length):
				nseq = nseq + 1
				at = at + 1 + 2 * seqs.data[at]
	int alternatives = nseq
	if (ascii_count > 0): alternatives = alternatives + 1
	if (alternatives == 0):
		re_emit(cc, RE_OP_FAIL, 0, 0)
		re_vec_free(seqs)
		return
	re_vec* jumps = re_vec_new()
	int done = 0
	if (ascii_count > 0):
		int split = -1
		if (alternatives > 1): split = re_emit(cc, RE_OP_SPLIT, re_pc(cc) + 1, 0)
		re_emit_ascii(cc, r, count, ascii_count, single, 127)
		done = done + 1
		if (split >= 0):
			re_vec_push(jumps, re_emit(cc, RE_OP_JMP, 0, 0))
			re_patch(cc, split, 2, re_pc(cc))
	int at = 0
	while (at < seqs.length):
		int len = seqs.data[at]
		int split = -1
		if (done < alternatives - 1): split = re_emit(cc, RE_OP_SPLIT, re_pc(cc) + 1, 0)
		for k in range(len):
			int lo = seqs.data[at + 1 + 2 * k]
			int hi = seqs.data[at + 2 + 2 * k]
			if (lo == hi): re_emit(cc, RE_OP_CHAR, lo, 0)
			else: re_emit(cc, RE_OP_RANGE, lo, hi)
		done = done + 1
		if (split >= 0):
			re_vec_push(jumps, re_emit(cc, RE_OP_JMP, 0, 0))
			re_patch(cc, split, 2, re_pc(cc))
		at = at + 1 + 2 * len
	int end = re_pc(cc)
	for k in range(jumps.length): re_patch(cc, jumps.data[k], 1, end)
	re_vec_free(jumps)
	re_vec_free(seqs)


int re_nullable(re_parser* ps, int n):
	int kind = re_nf(ps, n, RE_NF_KIND)
	if (kind == RE_NK_SET): return 0
	if ((kind == RE_NK_EMPTY) || (kind == RE_NK_ASSERT)): return 1
	if (kind == RE_NK_REPEAT):
		if (re_nf(ps, n, RE_NF_A) == 0): return 1
		return re_nullable(ps, re_nf(ps, n, RE_NF_FIRST))
	if (kind == RE_NK_GROUP): return re_nullable(ps, re_nf(ps, n, RE_NF_FIRST))
	int child = re_nf(ps, n, RE_NF_FIRST)
	if (kind == RE_NK_ALT):
		while (child >= 0):
			if (re_nullable(ps, child)): return 1
			child = re_nf(ps, child, RE_NF_NEXT)
		return 0
	while (child >= 0):
		if (re_nullable(ps, child) == 0): return 0
		child = re_nf(ps, child, RE_NF_NEXT)
	return 1


# Points loop head SPLIT at body (preferred when greedy) and out.
void re_patch_loop(re_compiler* cc, int head, int body, int out, int greedy):
	if (greedy):
		re_patch(cc, head, 1, body)
		re_patch(cc, head, 2, out)
	else:
		re_patch(cc, head, 1, out)
		re_patch(cc, head, 2, body)


# Emits "continue only if the iteration that started at register reg
# consumed something"; returns the JMP to patch with the loop exit.
int re_emit_progress_guard(re_compiler* cc, int reg):
	int pc = re_pc(cc)
	re_emit(cc, RE_OP_PROGRESS, reg, pc + 2)
	return re_emit(cc, RE_OP_JMP, 0, 0)


# Repetition of child, min..max times (max -1 = unbounded).
#
# A body that can match empty follows CPython's sre rule: once at least
# min iterations ran, another iteration starts only if the previous one
# consumed something; an empty iteration still counts (its captures
# stick), so (a*)*b on "aab" leaves group 1 at (2,2). A MARK register
# holds where the current iteration started and PROGRESS tests it.
#
# The Pike VM keeps one thread per (pc, position), so an unbounded loop
# that re-entered the same body code at the position where the previous
# iteration ended would collide with that iteration's own states and be
# dropped. Two copies of the body that alternate (A, B, A, ...) keep each
# re-entry on fresh pcs.
void re_compile_repeat(re_compiler* cc, int n):
	int min = re_nf(cc.ps, n, RE_NF_A)
	int max = re_nf(cc.ps, n, RE_NF_B)
	int greedy = re_nf(cc.ps, n, RE_NF_C)
	int child = re_nf(cc.ps, n, RE_NF_FIRST)
	int nullable = re_nullable(cc.ps, child)
	int reg = -1
	if (nullable):
		reg = cc.first_reg + cc.nregs
		cc.nregs = cc.nregs + 1
	for i in range(min):
		if (cc.ps.error != 0): return
		if (nullable): re_emit(cc, RE_OP_MARK, reg, 0)
		re_compile_node(cc, child)
	re_vec* exits = re_vec_new()
	if ((nullable) && (min > 0) && (max != min)): re_vec_push(exits, re_emit_progress_guard(cc, reg))
	if ((max < 0) && (nullable == 0)):
		int head = re_emit(cc, RE_OP_SPLIT, 0, 0)
		re_compile_node(cc, child)
		re_emit(cc, RE_OP_JMP, head, 0)
		re_patch_loop(cc, head, head + 1, re_pc(cc), greedy)
	else if (max < 0):
		int head_a = re_emit(cc, RE_OP_SPLIT, 0, 0)
		re_emit(cc, RE_OP_MARK, reg, 0)
		re_compile_node(cc, child)
		int progress_a = re_emit(cc, RE_OP_PROGRESS, reg, 0)
		re_vec_push(exits, re_emit(cc, RE_OP_JMP, 0, 0))
		int head_b = re_emit(cc, RE_OP_SPLIT, 0, 0)
		re_emit(cc, RE_OP_MARK, reg, 0)
		re_compile_node(cc, child)
		re_emit(cc, RE_OP_PROGRESS, reg, head_a)
		re_patch(cc, progress_a, 2, head_b)
		re_vec_push(exits, -1 - head_a)
		re_vec_push(exits, -1 - head_b)
	else:
		int i = min
		while ((i < max) && (cc.ps.error == 0)):
			if ((nullable) && (i > min)): re_vec_push(exits, re_emit_progress_guard(cc, reg))
			int split = re_emit(cc, RE_OP_SPLIT, 0, 0)
			re_vec_push(exits, -1 - split)
			if (nullable): re_emit(cc, RE_OP_MARK, reg, 0)
			re_compile_node(cc, child)
			i = i + 1
	int out = re_pc(cc)
	# Entries >= 0 are JMPs to the exit; -1 - pc marks a loop SPLIT.
	for k in range(exits.length):
		int e = exits.data[k]
		if (e >= 0): re_patch(cc, e, 1, out)
		else: re_patch_loop(cc, -1 - e, -e, out, greedy)
	re_vec_free(exits)


void re_compile_node(re_compiler* cc, int n):
	if (cc.ps.error != 0): return
	re_parser* ps = cc.ps
	int kind = re_nf(ps, n, RE_NF_KIND)
	if (kind == RE_NK_SET):
		re_compile_set(cc, re_nf(ps, n, RE_NF_A), re_nf(ps, n, RE_NF_B))
	else if (kind == RE_NK_CAT):
		int child = re_nf(ps, n, RE_NF_FIRST)
		while (child >= 0):
			re_compile_node(cc, child)
			child = re_nf(ps, child, RE_NF_NEXT)
	else if (kind == RE_NK_ALT):
		re_vec* jumps = re_vec_new()
		int child = re_nf(ps, n, RE_NF_FIRST)
		while (child >= 0):
			int next = re_nf(ps, child, RE_NF_NEXT)
			if (next >= 0):
				int split = re_emit(cc, RE_OP_SPLIT, 0, 0)
				re_patch(cc, split, 1, split + 1)
				re_compile_node(cc, child)
				re_vec_push(jumps, re_emit(cc, RE_OP_JMP, 0, 0))
				re_patch(cc, split, 2, re_pc(cc))
			else:
				re_compile_node(cc, child)
			child = next
		int end = re_pc(cc)
		for k in range(jumps.length): re_patch(cc, jumps.data[k], 1, end)
		re_vec_free(jumps)
	else if (kind == RE_NK_GROUP):
		int g = re_nf(ps, n, RE_NF_A)
		re_emit(cc, RE_OP_SAVE, 2 * g, 0)
		re_compile_node(cc, re_nf(ps, n, RE_NF_FIRST))
		re_emit(cc, RE_OP_SAVE, 2 * g + 1, 0)
	else if (kind == RE_NK_REPEAT):
		re_compile_repeat(cc, n)
	else if (kind == RE_NK_ASSERT):
		re_emit(cc, RE_OP_ASSERT, re_nf(ps, n, RE_NF_A), 0)


int* re_vec_take(re_vec* v):
	int count = v.length
	if (count == 0): count = 1
	int* out = cast(int*, malloc(count * __word_size__))
	for k in range(v.length): out[k] = v.data[k]
	re_vec_free(v)
	return out


# ---- public compile API ------------------------------------------------------

# Compiles len bytes of pattern. Always returns a pattern (0 only when
# memory runs out); check re_error() before matching. Matching with a
# pattern that failed to compile returns no match.
re_pattern* re_compile_n(char* pattern, int len, int flags):
	re_pattern* p = new re_pattern()
	p.error = 0
	p.error_pos = 0
	p.flags = flags
	p.groups = 0
	p.nslots = 2
	p.nprog = 0
	p.prog = cast(int*, 0)
	p.classes = cast(int*, 0)
	re_parser* ps = new re_parser()
	ps.pat = pattern
	ps.len = len
	ps.pos = 0
	ps.flags = flags
	ps.groups = 0
	ps.depth = 0
	ps.global_ok = 1
	ps.error = 0
	ps.error_pos = 0
	ps.nodes = re_vec_new()
	ps.ranges = re_vec_new()
	int root = re_parse_alt(ps)
	if ((ps.error == 0) && (ps.pos < ps.len)): re_fail(ps, c"unbalanced parenthesis", ps.pos)
	re_compiler* cc = new re_compiler()
	cc.ps = ps
	cc.prog = re_vec_new()
	cc.classes = re_vec_new()
	cc.nregs = 0
	cc.first_reg = 2 * (ps.groups + 1)
	if (ps.error == 0):
		re_emit(cc, RE_OP_SAVE, 0, 0)
		re_compile_node(cc, root)
		re_emit(cc, RE_OP_SAVE, 1, 0)
		re_emit(cc, RE_OP_MATCH, 0, 0)
	if (ps.error != 0):
		p.error = ps.error
		p.error_pos = ps.error_pos
		re_vec_free(cc.prog)
		re_vec_free(cc.classes)
	else:
		p.flags = ps.flags
		p.groups = ps.groups
		p.nslots = cc.first_reg + cc.nregs
		p.nprog = cc.prog.length / 3
		p.prog = re_vec_take(cc.prog)
		p.classes = re_vec_take(cc.classes)
	free(cc)
	re_vec_free(ps.nodes)
	re_vec_free(ps.ranges)
	free(ps)
	return p


re_pattern* re_compile(char* pattern, int flags):
	return re_compile_n(pattern, strlen(pattern), flags)


void re_free(re_pattern* p):
	if (p == 0): return
	if (p.prog != 0): free(p.prog)
	if (p.classes != 0): free(p.classes)
	free(p)


# The static error message, or 0 when the pattern compiled.
char* re_error(re_pattern* p):
	return p.error


# Byte offset in the pattern where the error was detected.
int re_error_pos(re_pattern* p):
	return p.error_pos


# Number of capturing groups (Python's pattern.groups).
int re_group_count(re_pattern* p):
	return p.groups


# ---- Pike VM -----------------------------------------------------------------

struct re_vm:
	re_pattern* p
	char* text
	int len
	int nslots
	int* mark        # per pc: position + 1 of the last step that added it
	int* stack       # (pc, -1) or (slot, old value) restore entries
	int* cap         # working capture registers
	int* pcs0
	int* caps0
	int count0
	int* pcs1
	int* caps1
	int count1


int re_word_at(re_vm* vm, int i):
	if ((i < 0) || (i >= vm.len)): return 0
	return re_is_word(vm.text[i] & 255)


int re_assert(re_vm* vm, int kind, int pos):
	if (kind == RE_AS_BEGIN): return pos == 0
	if (kind == RE_AS_BOL): return (pos == 0) || ((vm.text[pos - 1] & 255) == 10)
	if (kind == RE_AS_END): return pos == vm.len
	if (kind == RE_AS_DOLLAR):
		if (pos == vm.len): return 1
		return (pos == vm.len - 1) && ((vm.text[pos] & 255) == 10)
	if (kind == RE_AS_EOL): return (pos == vm.len) || ((vm.text[pos] & 255) == 10)
	int boundary = re_word_at(vm, pos - 1) != re_word_at(vm, pos)
	if (kind == RE_AS_WORDB): return boundary
	# Like CPython's sre, \B never matches in an empty text.
	return (boundary == 0) && (vm.len > 0)


# Adds the thread (pc, caps) to list which (0 or 1) at position pos,
# following every empty-width instruction in priority order.
void re_add_thread(re_vm* vm, int which, int pc0, int* caps, int pos):
	int* prog = vm.p.prog
	int nslots = vm.nslots
	if (caps != vm.cap):
		for k in range(nslots): vm.cap[k] = caps[k]
	int* cap = vm.cap
	int* stack = vm.stack
	int gen = pos + 1
	int sp = 0
	stack[0] = pc0
	stack[1] = -1
	sp = 1
	while (sp > 0):
		sp = sp - 1
		if (stack[2 * sp + 1] != -1):
			cap[stack[2 * sp]] = stack[2 * sp + 1] - 1
			continue
		int pc = stack[2 * sp]
		while (1):
			if (vm.mark[pc] == gen): break
			vm.mark[pc] = gen
			int op = prog[3 * pc]
			if (op == RE_OP_JMP):
				pc = prog[3 * pc + 1]
			else if (op == RE_OP_SPLIT):
				stack[2 * sp] = prog[3 * pc + 2]
				stack[2 * sp + 1] = -1
				sp = sp + 1
				pc = prog[3 * pc + 1]
			else if ((op == RE_OP_SAVE) || (op == RE_OP_MARK)):
				int slot = prog[3 * pc + 1]
				stack[2 * sp] = slot
				stack[2 * sp + 1] = cap[slot] + 1
				sp = sp + 1
				cap[slot] = pos
				pc = pc + 1
			else if (op == RE_OP_PROGRESS):
				if (cap[prog[3 * pc + 1]] != pos): pc = prog[3 * pc + 2]
				else: pc = pc + 1
			else if (op == RE_OP_ASSERT):
				if (re_assert(vm, prog[3 * pc + 1], pos) == 0): break
				pc = pc + 1
			else if (op == RE_OP_FAIL):
				break
			else:
				int* pcs = vm.pcs0
				int* lcaps = vm.caps0
				int n = vm.count0
				if (which == 1):
					pcs = vm.pcs1
					lcaps = vm.caps1
					n = vm.count1
				pcs[n] = pc
				int base = n * nslots
				for k in range(nslots): lcaps[base + k] = cap[k]
				if (which == 1): vm.count1 = n + 1
				else: vm.count0 = n + 1
				break


int re_class_has(re_pattern* p, int index, int c):
	return (p.classes[index * 8 + (c >> 5)] >> (c & 31)) & 1


# mode: 0 search, 1 match (anchored at start), 2 fullmatch.
re_result* re_exec(re_pattern* p, char* text, int len, int start, int mode):
	if ((p == 0) || (p.error != 0)): return cast(re_result*, 0)
	if (len < 0): len = 0
	if (start < 0): start = 0
	if (start > len): start = len
	int nprog = p.nprog
	int nslots = p.nslots
	re_vm* vm = new re_vm()
	vm.p = p
	vm.text = text
	vm.len = len
	vm.nslots = nslots
	vm.mark = cast(int*, malloc(nprog * __word_size__))
	for k in range(nprog): vm.mark[k] = 0
	vm.stack = cast(int*, malloc((4 * nprog + 4) * __word_size__))
	vm.cap = cast(int*, malloc(nslots * __word_size__))
	vm.pcs0 = cast(int*, malloc(nprog * __word_size__))
	vm.pcs1 = cast(int*, malloc(nprog * __word_size__))
	vm.caps0 = cast(int*, malloc(nprog * nslots * __word_size__))
	vm.caps1 = cast(int*, malloc(nprog * nslots * __word_size__))
	vm.count0 = 0
	vm.count1 = 0
	int* best = cast(int*, malloc(nslots * __word_size__))
	int matched = 0
	int* prog = p.prog
	int pos = start
	while (1):
		if ((matched == 0) && ((mode == 0) || (pos == start))):
			for k in range(nslots): vm.cap[k] = -1
			re_add_thread(vm, 0, 0, vm.cap, pos)
		if (vm.count0 == 0):
			if (matched || (mode != 0) || (pos >= len)): break
		vm.count1 = 0
		int c = -1
		if (pos < len): c = text[pos] & 255
		for i in range(vm.count0):
			int pc = vm.pcs0[i]
			int* caps = &vm.caps0[i * nslots]
			int op = prog[3 * pc]
			if (op == RE_OP_MATCH):
				if ((mode == 2) && (pos != len)): continue
				for k in range(nslots): best[k] = caps[k]
				matched = 1
				break
			if (c < 0): continue
			int ok = 0
			if (op == RE_OP_CHAR): ok = c == prog[3 * pc + 1]
			else if (op == RE_OP_CLASS): ok = re_class_has(p, prog[3 * pc + 1], c)
			else if (op == RE_OP_RANGE): ok = (c >= prog[3 * pc + 1]) && (c <= prog[3 * pc + 2])
			if (ok): re_add_thread(vm, 1, pc + 1, caps, pos + 1)
		if (pos >= len): break
		# swap lists
		int* tp = vm.pcs0
		vm.pcs0 = vm.pcs1
		vm.pcs1 = tp
		int* tc = vm.caps0
		vm.caps0 = vm.caps1
		vm.caps1 = tc
		vm.count0 = vm.count1
		pos = pos + 1
	free(vm.mark)
	free(vm.stack)
	free(vm.cap)
	free(vm.pcs0)
	free(vm.pcs1)
	free(vm.caps0)
	free(vm.caps1)
	free(vm)
	if (matched == 0):
		free(best)
		return cast(re_result*, 0)
	re_result* m = new re_result()
	m.text = text
	m.groups = p.groups
	int nspans = 2 * (p.groups + 1)
	m.spans = cast(int*, malloc(nspans * __word_size__))
	for k in range(nspans): m.spans[k] = best[k]
	free(best)
	return m


# ---- public match API --------------------------------------------------------

# First match starting at or after pos in text[0..len) (Python
# pattern.search(text, pos)); 0 when none. Anchors and \b see the whole
# text, so this is the building block for findall/sub/split.
re_result* re_search_at(re_pattern* p, char* text, int len, int pos):
	return re_exec(p, text, len, pos, 0)


# Match anchored exactly at pos (Python pattern.match(text, pos)).
re_result* re_match_at(re_pattern* p, char* text, int len, int pos):
	return re_exec(p, text, len, pos, 1)


# Match from pos that must end at len (Python pattern.fullmatch(text, pos)).
re_result* re_fullmatch_at(re_pattern* p, char* text, int len, int pos):
	return re_exec(p, text, len, pos, 2)


re_result* re_search(re_pattern* p, char* text):
	return re_exec(p, text, strlen(text), 0, 0)


re_result* re_match(re_pattern* p, char* text):
	return re_exec(p, text, strlen(text), 0, 1)


re_result* re_fullmatch(re_pattern* p, char* text):
	return re_exec(p, text, strlen(text), 0, 2)


void re_result_free(re_result* m):
	if (m == 0): return
	free(m.spans)
	free(m)


# Number of capturing groups in the pattern that produced m.
int re_groups(re_result* m):
	return m.groups


# Byte offset where group g (0 = whole match) starts; -1 if it did not
# participate or g is out of range.
int re_start(re_result* m, int g):
	if ((g < 0) || (g > m.groups)): return -1
	return m.spans[2 * g]


int re_end(re_result* m, int g):
	if ((g < 0) || (g > m.groups)): return -1
	return m.spans[2 * g + 1]


# Group g's text as a new NUL-terminated string (caller frees), or 0
# when the group did not participate.
char* re_group(re_result* m, int g):
	int s = re_start(m, g)
	int e = re_end(m, g)
	if ((s < 0) || (e < 0)): return cast(char*, 0)
	char* out = cast(char*, malloc(e - s + 1))
	for k in range(e - s): out[k] = m.text[s + k]
	out[e - s] = 0
	return out
