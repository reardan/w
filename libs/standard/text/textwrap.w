# Python's textwrap module (docs/projects/stdlib_python_parity.md P1.3,
# libs/standard/plans/02_text_processing.md): wrap, fill, shorten,
# dedent and indent, following CPython 3.14's Lib/textwrap.py.
#
# Every result is a fresh malloc'd C string (or a list of them) owned by
# the caller; free a wrap result with textwrap_free_lines. Inputs are
# UTF-8 C strings and are never modified. Widths, columns and the
# long-word cut points count code points, never bytes, so a multi-byte
# character is never split.
#
# Known differences from Python (all confined to non-ASCII text):
# - The hyphen-splitting rules (break_on_hyphens) look at the letters
#   and punctuation around each '-'. Here every non-ASCII code point
#   counts as a letter, where Python's Unicode \w would class non-ASCII
#   punctuation and digits differently. ASCII text splits identically.
# - fix_sentence_endings, like Python's, only recognises ASCII a-z.
# Whitespace tests (blank chunks, blank lines in dedent, the indent
# predicate) use Python's full str.isspace set, ASCII and Unicode.
import lib.lib
import lib.str


# TextWrapper's knobs. Fill one in with textwrap_options_init and then
# change the fields you need. max_lines <= 0 means no limit (Python's
# None). The strings are borrowed, never freed.
struct textwrap_options:
	int width
	char* initial_indent
	char* subsequent_indent
	int expand_tabs
	int tabsize
	int replace_whitespace
	int fix_sentence_endings
	int break_long_words
	int break_on_hyphens
	int drop_whitespace
	int max_lines
	char* placeholder


# The predicate textwrap_indent_with calls on each line (line ending
# included); a non-zero result prefixes the line.
type textwrap_line_predicate = fn(char*) -> int


# Python's TextWrapper defaults with the given width.
void textwrap_options_init(textwrap_options* o, int width = 70):
	o.width = width
	o.initial_indent = c""
	o.subsequent_indent = c""
	o.expand_tabs = 1
	o.tabsize = 8
	o.replace_whitespace = 1
	o.fix_sentence_endings = 0
	o.break_long_words = 1
	o.break_on_hyphens = 1
	o.drop_whitespace = 1
	o.max_lines = 0
	o.placeholder = c" [...]"


# Python's ValueError text for options that wrapping rejects, or 0 when
# they are usable. The wrap functions return no lines (fill and shorten
# an empty string) for rejected options.
char* textwrap_options_error(textwrap_options* o):
	if (o.width <= 0): return c"invalid width (must be > 0)"
	if (o.max_lines > 0):
		char* indent = o.initial_indent
		if (o.max_lines > 1): indent = o.subsequent_indent
		char* bare = lstrip(o.placeholder)
		int need = str_codepoints(indent) + str_codepoints(bare)
		free(bare)
		if (need > o.width): return c"placeholder too large for max width"
	return 0


# ---- character classes ---------------------------------------------

# Byte length of the Python str.isspace() character at s[i], or 0 when
# s[i] does not start one: ASCII \t \n \v \f \r, \x1c-\x1f and space,
# and U+0085, U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029, U+202F,
# U+205F and U+3000.
int textwrap_space_width(char* s, int i):
	int b0 = s[i] & 255
	if (b0 == 32 || (b0 >= 9 && b0 <= 13) || (b0 >= 0x1c && b0 <= 0x1f)): return 1
	if (b0 == 0xc2):
		int b1 = s[i + 1] & 255
		if (b1 == 0x85 || b1 == 0xa0): return 2
		return 0
	if (b0 != 0xe1 && b0 != 0xe2 && b0 != 0xe3): return 0
	int c1 = s[i + 1] & 255
	if ((c1 & 0xc0) != 0x80): return 0
	int c2 = s[i + 2] & 255
	if ((c2 & 0xc0) != 0x80): return 0
	int cp = ((b0 & 15) << 12) | ((c1 & 63) << 6) | (c2 & 63)
	if (cp == 0x1680 || (cp >= 0x2000 && cp <= 0x200a)): return 3
	if (cp == 0x2028 || cp == 0x2029 || cp == 0x202f || cp == 0x205f || cp == 0x3000): return 3
	return 0


# Python's s.isspace(): 1 when s is non-empty and all whitespace.
int textwrap_isspace(char* s):
	if (s[0] == 0): return 0
	int i = 0
	while (s[i] != 0):
		int w = textwrap_space_width(s, i)
		if (w == 0): return 0
		i = i + w
	return 1


# Python's s.strip() == "": empty or all whitespace.
int textwrap_blank(char* s):
	return (s[0] == 0) || textwrap_isspace(s)


# The whitespace TextWrapper splits on (_whitespace): \t \n \v \f \r and
# space. Unlike str.isspace this set is ASCII only.
int textwrap_split_space(int c):
	return c == 32 || (c >= 9 && c <= 13)


# Python's \w for one character class value (see textwrap_class): ASCII
# letters, digits and '_', and every non-ASCII code point.
int textwrap_word(int c):
	if (c >= 128): return 1
	return isalnum(cast(char, c)) || c == '_'


# Python's [^\d\W]: a word character that is not a digit.
int textwrap_letter(int c):
	return textwrap_word(c) && !(c >= '0' && c <= '9')


# TextWrapper.word_punct: [\w!"'&.,?].
int textwrap_word_punct(int c):
	if (textwrap_word(c)): return 1
	return c == '!' || c == '"' || c == 39 || c == '&' || c == '.' || c == ',' || c == '?'


# ---- code point helpers ----------------------------------------------

# Byte offset of code point n of s (strlen(s) when s has fewer).
int textwrap_cp_offset(char* s, int n):
	int i = 0
	while (n > 0 && s[i] != 0):
		i = i + str_char_width(s, i)
		n = n - 1
	return i


# a followed by b, as a new string.
char* textwrap_concat(char* a, char* b):
	int la = strlen(a)
	int lb = strlen(b)
	char* out = cast(char*, malloc(la + lb + 1))
	for i in range(la):
		out[i] = a[i]
	for j in range(lb):
		out[la + j] = b[j]
	out[la + lb] = 0
	return out


# Frees every line and then the list (any list[char*] result here).
void textwrap_free_lines(list[char*] lines):
	for line in lines:
		free(line)
	lines.free()


# ---- splitting into chunks -------------------------------------------

# The text as characters: starts[k] is the byte offset of character k
# and classes[k] its class value, the ASCII byte or 128 for any
# multi-byte character. One extra start marks the end.
struct textwrap_chars:
	char* text
	list[int] starts
	list[int] classes


# Class value of character k, or -1 outside the text (so lookbehind and
# lookahead tests past either end fail, like \Z-bounded regex tests).
int textwrap_chars_class(textwrap_chars* t, int k):
	if (k < 0 || k >= t.classes.length): return -1
	return t.classes[k]


# Length of the run of '-' starting at character k.
int textwrap_hyphen_run(textwrap_chars* t, int k):
	int r = 0
	while (textwrap_chars_class(t, k + r) == '-'): r = r + 1
	return r


# Characters in the chunk that starts at character p, mirroring one
# match of TextWrapper.wordsep_re (break_on_hyphens) or of
# wordsep_simple_re.
int textwrap_chunk_end(textwrap_chars* t, int p, int on_hyphens):
	int n = t.classes.length
	int e = p
	if (textwrap_split_space(t.classes[p])):
		while (e < n && textwrap_split_space(t.classes[e])): e = e + 1
		return e
	while (e < n && !textwrap_split_space(t.classes[e])): e = e + 1
	if (!on_hyphens): return e
	# em-dash between words: (?<=word_punct) -{2,} (?=\w)
	if (t.classes[p] == '-' && textwrap_word_punct(textwrap_chars_class(t, p - 1))):
		int r = textwrap_hyphen_run(t, p)
		if (r >= 2 && textwrap_word(textwrap_chars_class(t, p + r))): return p + r
	# a word, matched lazily: the first q where it may end
	int q = p + 1
	while (q < e):
		if (t.classes[q] == '-'):
			# hyphenated word: -(?: (?<=lt{2}-) | (?<=lt-lt-)) (?= lt -? lt)
			int a1 = textwrap_chars_class(t, q - 1)
			int a2 = textwrap_chars_class(t, q - 2)
			int a3 = textwrap_chars_class(t, q - 3)
			int behind = textwrap_letter(a1) && (textwrap_letter(a2) || (a2 == '-' && textwrap_letter(a3)))
			int b1 = textwrap_chars_class(t, q + 1)
			int b2 = textwrap_chars_class(t, q + 2)
			int b3 = textwrap_chars_class(t, q + 3)
			int ahead = textwrap_letter(b1) && (textwrap_letter(b2) || (b2 == '-' && textwrap_letter(b3)))
			if (behind && ahead): return q + 1
			# em-dash follows: (?<=word_punct) (?=-{2,}\w)
			if (textwrap_word_punct(a1)):
				int r2 = textwrap_hyphen_run(t, q)
				if (r2 >= 2 && textwrap_word(textwrap_chars_class(t, q + r2))): return q
		q = q + 1
	return e


# TextWrapper._munge_whitespace: tabs expanded, then each other
# whitespace byte turned into a space.
char* textwrap_munge(char* text, textwrap_options* o):
	char* s = 0
	if (o.expand_tabs): s = expandtabs(text, o.tabsize)
	else: s = strclone(text)
	if (o.replace_whitespace):
		int i = 0
		while (s[i] != 0):
			if (textwrap_split_space(s[i])): s[i] = ' '
			i = i + 1
	return s


# TextWrapper.sentence_end_re: [a-z][.!?]["']?\Z
int textwrap_sentence_end(char* s):
	int n = strlen(s)
	if (n >= 1 && (s[n - 1] == '"' || s[n - 1] == 39)): n = n - 1
	if (n < 2): return 0
	char p = s[n - 1]
	if (p != '.' && p != '!' && p != '?'): return 0
	return s[n - 2] >= 'a' && s[n - 2] <= 'z'


# TextWrapper._split_chunks (plus _fix_sentence_endings): the munged
# text as indivisible chunks, with their code point lengths in lens.
list[char*] textwrap_split(char* text, textwrap_options* o, list[int] lens):
	char* s = textwrap_munge(text, o)
	textwrap_chars t
	t.text = s
	t.starts = new list[int]
	t.classes = new list[int]
	int i = 0
	while (s[i] != 0):
		int w = str_char_width(s, i)
		t.starts.push(i)
		if (w == 1): t.classes.push(s[i] & 255)
		else: t.classes.push(128)
		i = i + w
	t.starts.push(i)
	list[char*] chunks = new list[char*]
	int p = 0
	while (p < t.classes.length):
		int e = textwrap_chunk_end(&t, p, o.break_on_hyphens)
		chunks.push(str_copy_range(s, t.starts[p], t.starts[e]))
		lens.push(e - p)
		p = e
	if (o.fix_sentence_endings):
		int k = 0
		while (k < chunks.length - 1):
			if (strcmp(chunks[k + 1], c" ") == 0 && textwrap_sentence_end(chunks[k])):
				free(chunks[k + 1])
				chunks[k + 1] = strclone(c"  ")
				lens[k + 1] = 2
				k = k + 2
			else: k = k + 1
	t.starts.free()
	t.classes.free()
	free(s)
	return chunks


# ---- wrapping ----------------------------------------------------------

# The wrapping state: the chunks still to place start at index next.
# cur and cur_lens are the line being built; its strings are borrowed
# from chunks, the options or owned (long-word heads, freed at the end).
struct textwrap_state:
	textwrap_options* o
	list[char*] chunks
	list[int] lens
	int next
	list[char*] cur
	list[int] cur_lens
	list[char*] owned


void textwrap_state_take(textwrap_state* st, char* piece, int length):
	st.cur.push(piece)
	st.cur_lens.push(length)


int textwrap_state_cur_len(textwrap_state* st):
	int total = 0
	for l in st.cur_lens:
		total = total + l
	return total


void textwrap_state_drop_last(textwrap_state* st):
	st.cur.pop()
	st.cur_lens.pop()


# TextWrapper._handle_long_word: the next chunk does not fit on any
# line, so cut it (break_long_words) or place it whole on an empty line.
void textwrap_long_word(textwrap_state* st, int cur_len, int width):
	textwrap_options* o = st.o
	int space_left = width - cur_len
	if (width < 1): space_left = 1
	if (o.break_long_words && space_left > 0):
		int end = space_left
		char* chunk = st.chunks[st.next]
		int length = st.lens[st.next]
		if (o.break_on_hyphens && length > space_left):
			# chunk.rfind('-', 0, space_left), in code points
			int hyphen = -1
			int only_hyphens = 1
			int before_non_hyphen = 0
			int k = 0
			int i = 0
			while (k < space_left && chunk[i] != 0):
				if (chunk[i] == '-'):
					hyphen = k
					before_non_hyphen = !only_hyphens
				else: only_hyphens = 0
				i = i + str_char_width(chunk, i)
				k = k + 1
			if (hyphen > 0 && before_non_hyphen): end = hyphen + 1
		if (end > length): end = length
		int cut = textwrap_cp_offset(chunk, end)
		char* head = str_copy_range(chunk, 0, cut)
		st.owned.push(head)
		textwrap_state_take(st, head, end)
		st.chunks[st.next] = str_copy_range(chunk, cut, strlen(chunk))
		st.lens[st.next] = length - end
		free(chunk)
	elif (st.cur.length == 0):
		textwrap_state_take(st, st.chunks[st.next], st.lens[st.next])
		st.next = st.next + 1


# indent followed by the pieces of the current line, as a new string.
char* textwrap_state_line(textwrap_state* st, char* indent):
	char* body = join(st.cur, c"")
	char* line = textwrap_concat(indent, body)
	free(body)
	return line


# TextWrapper._wrap_chunks.
list[char*] textwrap_wrap_chunks(textwrap_state* st):
	textwrap_options* o = st.o
	list[char*] lines = new list[char*]
	int n = st.chunks.length
	int placeholder_len = str_codepoints(o.placeholder)
	while (st.next < n):
		st.cur.clear()
		st.cur_lens.clear()
		int cur_len = 0
		char* indent = o.initial_indent
		if (lines.length > 0): indent = o.subsequent_indent
		int width = o.width - str_codepoints(indent)
		if (o.drop_whitespace && lines.length > 0 && textwrap_blank(st.chunks[st.next])):
			st.next = st.next + 1
		while (st.next < n && cur_len + st.lens[st.next] <= width):
			textwrap_state_take(st, st.chunks[st.next], st.lens[st.next])
			cur_len = cur_len + st.lens[st.next]
			st.next = st.next + 1
		if (st.next < n && st.lens[st.next] > width):
			textwrap_long_word(st, cur_len, width)
			cur_len = textwrap_state_cur_len(st)
		if (o.drop_whitespace && st.cur.length > 0 && textwrap_blank(st.cur[-1])):
			cur_len = cur_len - st.cur_lens[-1]
			textwrap_state_drop_last(st)
		if (st.cur.length == 0): continue
		int rest_blank = (st.next == n) || (o.drop_whitespace && st.next == n - 1 && textwrap_blank(st.chunks[st.next]))
		if (o.max_lines <= 0 || lines.length + 1 < o.max_lines || (rest_blank && cur_len <= width)):
			lines.push(textwrap_state_line(st, indent))
			continue
		# Out of lines: end this one with the placeholder.
		while (st.cur.length > 0):
			if (!textwrap_blank(st.cur[-1]) && cur_len + placeholder_len <= width):
				textwrap_state_take(st, o.placeholder, placeholder_len)
				lines.push(textwrap_state_line(st, indent))
				return lines
			cur_len = cur_len - st.cur_lens[-1]
			textwrap_state_drop_last(st)
		if (lines.length > 0):
			char* prev = rstrip(lines[-1])
			if (str_codepoints(prev) + placeholder_len <= o.width):
				free(lines[-1])
				lines[-1] = textwrap_concat(prev, o.placeholder)
				free(prev)
				return lines
			free(prev)
		char* bare = lstrip(o.placeholder)
		lines.push(textwrap_concat(indent, bare))
		free(bare)
		return lines
	return lines


# TextWrapper(...).wrap(text): text as one paragraph of lines at most
# o.width code points wide (wider only when break_long_words is off).
# Tabs are expanded and, with replace_whitespace, newlines and other
# whitespace become spaces. No lines for empty or all-whitespace text,
# or for options textwrap_options_error rejects.
list[char*] textwrap_wrap_with(char* text, textwrap_options* o):
	if (textwrap_options_error(o) != 0): return new list[char*]
	textwrap_state st
	st.o = o
	st.lens = new list[int]
	st.chunks = textwrap_split(text, o, st.lens)
	st.next = 0
	st.cur = new list[char*]
	st.cur_lens = new list[int]
	st.owned = new list[char*]
	list[char*] lines = textwrap_wrap_chunks(&st)
	textwrap_free_lines(st.chunks)
	textwrap_free_lines(st.owned)
	st.lens.free()
	st.cur.free()
	st.cur_lens.free()
	return lines


# textwrap.wrap(text, width) with the default options.
list[char*] textwrap_wrap(char* text, int width = 70):
	textwrap_options o
	textwrap_options_init(&o, width)
	return textwrap_wrap_with(text, &o)


# TextWrapper(...).fill(text): the wrapped lines joined with "\n".
char* textwrap_fill_with(char* text, textwrap_options* o):
	list[char*] lines = textwrap_wrap_with(text, o)
	char* out = join(lines, c"\n")
	textwrap_free_lines(lines)
	return out


# textwrap.fill(text, width) with the default options.
char* textwrap_fill(char* text, int width = 70):
	textwrap_options o
	textwrap_options_init(&o, width)
	return textwrap_fill_with(text, &o)


# textwrap.shorten(text, width, **options): whitespace runs collapsed to
# single spaces, then cut to one line ending in o.placeholder when it
# does not fit. o.max_lines is ignored (always one line).
char* textwrap_shorten_with(char* text, textwrap_options* o):
	textwrap_options one = *o
	one.max_lines = 1
	list[char*] words = split(text)
	char* collapsed = join(words, c" ")
	textwrap_free_lines(words)
	char* out = textwrap_fill_with(collapsed, &one)
	free(collapsed)
	return out


# textwrap.shorten(text, width, placeholder=placeholder); a null
# placeholder means Python's default " [...]".
char* textwrap_shorten(char* text, int width, char* placeholder = 0):
	textwrap_options o
	textwrap_options_init(&o, width)
	if (placeholder != 0): o.placeholder = placeholder
	return textwrap_shorten_with(text, &o)


# ---- dedent and indent -------------------------------------------------

# textwrap.dedent(text) (Python 3.14): the longest run of leading spaces
# and tabs common to every non-blank line is removed from each line, and
# lines that are all whitespace become empty. "  x" and "\tx" share no
# margin. Lines are split at "\n" only.
char* textwrap_dedent(char* text):
	list[char*] lines = split(text, 10)
	char* first = 0
	int margin = 0
	for line in lines:
		if (textwrap_blank(line)): continue
		if (first == 0):
			first = line
			while (first[margin] == ' ' || first[margin] == 9): margin = margin + 1
		else:
			int m = 0
			while (m < margin && line[m] == first[m]): m = m + 1
			margin = m
	list[char*] out = new list[char*]
	for line in lines:
		if (textwrap_isspace(line)): out.push(c"")
		elif (line[0] == 0): out.push(line)
		else: out.push(&line[margin])
	char* result = join(out, c"\n")
	out.free()
	textwrap_free_lines(lines)
	return result


# textwrap.indent(text, prefix, predicate): prefix added to each line
# (split at any Python line boundary, endings kept) for which predicate
# returns non-zero; with no predicate, to every line that is not all
# whitespace.
char* textwrap_indent(char* text, char* prefix, textwrap_line_predicate* predicate = 0):
	list[char*] lines = splitlines(text, 1)
	list[char*] out = new list[char*]
	list[char*] made = new list[char*]
	for line in lines:
		int add = 0
		if (predicate != 0): add = predicate(line) != 0
		else: add = !textwrap_isspace(line)
		if (add):
			char* joined = textwrap_concat(prefix, line)
			made.push(joined)
			out.push(joined)
		else: out.push(line)
	char* result = join(out, c"")
	out.free()
	textwrap_free_lines(made)
	textwrap_free_lines(lines)
	return result
