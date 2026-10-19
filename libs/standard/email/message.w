/*
Email message parsing and the MIME transfer codecs
(docs/projects/stdlib_python_parity.md P4.2, area plan
libs/standard/plans/08_networking_web.md phase 7). The behavioral
reference is Python's email package with the compat32 policy:
email.message_from_bytes / FeedParser, email.message.Message,
email.header.decode_header / make_header, quopri / binascii and
email.utils (dates come from libs/standard/time/format.w, P1.6).

  parse        email_message_from_bytes(data, len), email_message_from_string
  headers      email_message_get (first match, case-insensitive),
               email_message_get_all (every match, in order), _has,
               _add_header, _remove_header, _replace_header,
               email_header_unfold, email_header_fold
  MIME         email_message_get_content_type / _maintype / _subtype,
               _get_params, _get_param, _get_boundary, _get_filename,
               _get_content_charset, _get_content_disposition,
               _is_multipart, _part_count, _part, _walk, _attach
  bodies       email_message_get_payload (raw), _get_payload_decoded
               (Content-Transfer-Encoding applied), _set_payload,
               email_message_as_string (compat32 Generator)
  codecs       email_qp_decode / email_qp_encode (binascii.a2b_qp /
               b2a_qp), email_base64_decode (lenient, as get_payload
               decodes bodies), email_base64_encode_body
               (base64.encodebytes), email_a2b_base64 (non-strict)
  RFC 2047     email_decode_header (decode_header chunks),
               email_header_to_utf8 (str(make_header(decode_header(v)))),
               email_header_encode_word, email_header_encode
  dates        email_message_get_date, email_message_set_date

Parsing follows compat32's feed parser line for line: a message never
fails to parse; problems are recorded as defect names (Python's error
class names, e.g. "StartBoundaryNotFoundDefect") on the message they
were found in. Header values are stored as compat32 stores them: the
text after the colon with leading blanks removed, embedded folding
(line break plus whitespace) kept, trailing CR/LF removed.
email_header_unfold removes the line breaks (RFC 5322 2.2.3, which is
what policy.default does before interpreting a value).

Multipart parsing honors RFC 2046: the line break before a boundary
belongs to the boundary, preamble and epilogue are kept (0 = Python's
None), nested multiparts nest their own boundaries, message/* parts
hold one parsed sub-message as their only part (message/delivery-status
holds one header-only part per block), and multipart/digest children
default to message/rfc822.

Ownership: email_message_free frees a message and every part, header
and payload under it. Getters that return char* without saying
"malloc'd" return storage owned by the message. Lists returned by
email_message_get_all, email_message_walk, email_message_get_params and
email_decode_header are new; free them with email_params_free /
email_header_chunks_free or, for the borrowed-element lists, l.free().

Bytes vs text: W strings are bytes. Charset conversion covers utf-8,
us-ascii, iso-8859-1 (and its aliases) and windows-1252, producing
UTF-8; text in any other charset is passed through as raw bytes
(Python would decode it with its codec). Unencoded text around RFC 2047
words is kept as the input bytes. Not ported: RFC 2231 encoding when
writing parameters,
address parsing (email.utils.parseaddr / getaddresses), and the
policy.default header objects.
*/
import lib.lib
import structures.string
import libs.standard.crypto.base64
import libs.standard.time.format


struct email_header:
	char* name
	char* value


# One Content-Type style parameter. name is lowercased for "name=value"
# entries (Python's _parseparam) and kept as written for a bare entry
# (the first entry, the type itself, has value ""). RFC 2231 parameters
# (name*=charset'lang'value, name*0=..., name*1*=...) are reassembled:
# value holds the percent-decoded bytes, extended is 1, and charset /
# language hold the RFC 2231 labels (0 when absent).
struct email_param:
	char* name
	char* value
	char* charset
	char* language
	int extended


# One run of decode_header output: len bytes at data (NUL-terminated),
# and the lowercased charset label of the encoded words it came from,
# or 0 for text outside encoded words.
struct email_header_chunk:
	char* data
	int len
	char* charset


struct email_message:
	char* unixfrom
	list[email_header*] headers
	char* payload
	int payload_len
	list[email_message*] parts
	char* preamble
	char* epilogue
	char* default_type
	list[char*] defects


# ---- small helpers ---------------------------------------------------------------

char* email_copy(char* s, int n):
	char* out = cast(char*, malloc(n + 1))
	for i in range(n): out[i] = s[i]
	out[n] = 0
	return out


char* email_strdup(char* s):
	if (s == 0): return 0
	return email_copy(s, strlen(s))


char* email_finish(string_builder* sb, int* out_len):
	if (out_len != 0): *out_len = sb.length
	char* result = sb.data
	free(sb)
	return result


int email_lower(int c):
	if ((c >= 'A') && (c <= 'Z')): return c + 32
	return c


int email_streq(char* a, char* b):
	int i = 0
	while (a[i] == b[i]):
		if (a[i] == 0): return 1
		i = i + 1
	return 0


int email_ieq(char* a, char* b):
	int i = 0
	while (email_lower(a[i] & 255) == email_lower(b[i] & 255)):
		if (a[i] == 0): return 1
		i = i + 1
	return 0


# Python's str.isspace() for an ASCII byte (\x1c-\x1f count too).
int email_is_space(int c):
	if ((c == ' ') || (c == '\t') || (c == '\n') || (c == '\r') || (c == 11) || (c == 12)): return 1
	if ((c >= 28) && (c <= 31)): return 1
	return 0


int email_is_eol(int c):
	return (c == '\r') || (c == '\n')


# s[start..end) with Python str.strip() whitespace removed, malloc'd.
char* email_strip_copy(char* s, int start, int end):
	while ((start < end) && email_is_space(s[start] & 255)): start = start + 1
	while ((end > start) && email_is_space(s[end - 1] & 255)): end = end - 1
	return email_copy(&s[start], end - start)


char* email_lower_copy(char* s):
	char* out = email_strdup(s)
	int i = 0
	while (out[i] != 0):
		out[i] = email_lower(out[i] & 255)
		i = i + 1
	return out


# Length of one trailing line ending (\r\n, \r or \n) of s[0..n), or 0.
int email_eol_len(char* s, int n):
	if (n <= 0): return 0
	if (s[n - 1] == '\n'):
		if ((n >= 2) && (s[n - 2] == '\r')): return 2
		return 1
	if (s[n - 1] == '\r'): return 1
	return 0


int email_hex_value(int c):
	if ((c >= '0') && (c <= '9')): return c - '0'
	if ((c >= 'a') && (c <= 'f')): return c - 'a' + 10
	if ((c >= 'A') && (c <= 'F')): return c - 'A' + 10
	return -1


void email_append_hex(string_builder* sb, int c):
	char* digits = c"0123456789ABCDEF"
	string_append_char(sb, '=')
	string_append_char(sb, digits[(c >> 4) & 15])
	string_append_char(sb, digits[c & 15])


void email_append_utf8(string_builder* sb, int cp):
	if (cp < 128):
		string_append_char(sb, cp)
	else if (cp < 2048):
		string_append_char(sb, 192 | (cp >> 6))
		string_append_char(sb, 128 | (cp & 63))
	else:
		string_append_char(sb, 224 | (cp >> 12))
		string_append_char(sb, 128 | ((cp >> 6) & 63))
		string_append_char(sb, 128 | (cp & 63))


# Python's email.utils.unquote: strips one level of "..." (undoing \\
# and \" escapes) or <...>. Returns a malloc'd copy.
char* email_unquote(char* s):
	int n = strlen(s)
	if (n > 1):
		if ((s[0] == '"') && (s[n - 1] == '"')):
			# str[1:-1].replace('\\\\', '\\').replace('\\"', '"')
			string_builder* a = string_new()
			int i = 1
			while (i < n - 1):
				if ((s[i] == '\\') && (i + 1 < n - 1) && (s[i + 1] == '\\')):
					string_append_char(a, '\\')
					i = i + 2
				else:
					string_append_char(a, s[i])
					i = i + 1
			string_builder* b = string_new()
			i = 0
			while (i < a.length):
				if ((a.data[i] == '\\') && (i + 1 < a.length) && (a.data[i + 1] == '"')):
					string_append_char(b, '"')
					i = i + 2
				else:
					string_append_char(b, a.data[i])
					i = i + 1
			string_free(a)
			return email_finish(b, 0)
		if ((s[0] == '<') && (s[n - 1] == '>')): return email_copy(&s[1], n - 2)
	return email_copy(s, n)


# ---- charsets --------------------------------------------------------------------

# Python's email.charset aliases that matter here, applied to an
# already-lowercased label. Returns a static name or the input.
char* email_charset_canonical(char* lower):
	if (email_streq(lower, c"ascii")): return c"us-ascii"
	if (email_streq(lower, c"latin-1") || email_streq(lower, c"latin_1") || email_streq(lower, c"latin1") || email_streq(lower, c"l1") || email_streq(lower, c"iso8859-1") || email_streq(lower, c"iso_8859-1") || email_streq(lower, c"cp819")): return c"iso-8859-1"
	if (email_streq(lower, c"cp1252")): return c"windows-1252"
	if (email_streq(lower, c"utf8")): return c"utf-8"
	return lower


# windows-1252 0x80..0x9f; 0 marks the five undefined bytes.
int email_cp1252_high(int c):
	char* table = c"20ac0000201a0192201e20262020202102c620300160203901520000017d0000000020182019201c201d20222013201402dc21220161203a01530000017e0178"
	int at = (c - 128) * 4
	int cp = 0
	for i in range(4): cp = cp * 16 + email_hex_value(table[at + i] & 255)
	return cp


# Converts len bytes in charset (any case, aliases allowed) to UTF-8.
# Returns a malloc'd NUL-terminated buffer, or 0 when the charset is not
# one this module knows (utf-8, us-ascii, iso-8859-1, windows-1252).
# Bytes a charset cannot represent become U+FFFD (errors='replace').
char* email_charset_to_utf8(char* data, int len, char* charset, int* out_len):
	char* lower = email_lower_copy(charset)
	char* canon = email_charset_canonical(lower)
	int kind = 0
	if (email_streq(canon, c"utf-8")): kind = 1
	else if (email_streq(canon, c"us-ascii")): kind = 2
	else if (email_streq(canon, c"iso-8859-1")): kind = 3
	else if (email_streq(canon, c"windows-1252")): kind = 4
	free(lower)
	if (kind == 0): return 0
	if (kind == 1):
		if (out_len != 0): *out_len = len
		return email_copy(data, len)
	string_builder* sb = string_new_sized(len + 8)
	for i in range(len):
		int c = data[i] & 255
		if (c < 128): string_append_char(sb, c)
		else if (kind == 2): email_append_utf8(sb, 0xfffd)
		else if ((kind == 4) && (c < 160)):
			int cp = email_cp1252_high(c)
			if (cp == 0): cp = 0xfffd
			email_append_utf8(sb, cp)
		else: email_append_utf8(sb, c)
	return email_finish(sb, out_len)


# ---- headers ---------------------------------------------------------------------

email_message* email_message_new():
	email_message* m = new email_message()
	m.unixfrom = 0
	m.headers = new list[email_header*]
	m.payload = 0
	m.payload_len = 0
	m.parts = new list[email_message*]
	m.preamble = 0
	m.epilogue = 0
	m.default_type = c"text/plain"
	m.defects = new list[char*]
	return m


void email_message_free(email_message* m):
	if (m == 0): return
	for email_header* h in m.headers:
		free(h.name)
		free(h.value)
		free(h)
	m.headers.free()
	for email_message* part in m.parts: email_message_free(part)
	m.parts.free()
	m.defects.free()
	if (m.unixfrom != 0): free(m.unixfrom)
	if (m.payload != 0): free(m.payload)
	if (m.preamble != 0): free(m.preamble)
	if (m.epilogue != 0): free(m.epilogue)
	free(m)


email_header* email_header_new(char* name, int name_len, char* value, int value_len):
	email_header* h = new email_header()
	h.name = email_copy(name, name_len)
	h.value = email_copy(value, value_len)
	return h


int email_message_header_count(email_message* m):
	return m.headers.length


char* email_message_header_name(email_message* m, int i):
	return m.headers[i].name


char* email_message_header_value(email_message* m, int i):
	return m.headers[i].value


# Appends a header (Python's msg[name] = value: duplicates are kept).
void email_message_add_header(email_message* m, char* name, char* value):
	m.headers.push(email_header_new(name, strlen(name), value, strlen(value)))


# The first header named name (ASCII case-insensitive), or 0.
char* email_message_get(email_message* m, char* name):
	for email_header* h in m.headers:
		if (email_ieq(h.name, name)): return h.value
	return 0


int email_message_has(email_message* m, char* name):
	return email_message_get(m, name) != 0


# Every value of the headers named name, in message order (a new list
# of borrowed values; empty when there is none).
list[char*] email_message_get_all(email_message* m, char* name):
	list[char*] out = new list[char*]
	for email_header* h in m.headers:
		if (email_ieq(h.name, name)): out.push(h.value)
	return out


# Removes every header named name (Python's del msg[name]); returns how
# many were removed.
int email_message_remove_header(email_message* m, char* name):
	int removed = 0
	int i = 0
	while (i < m.headers.length):
		email_header* h = m.headers[i]
		if (email_ieq(h.name, name)):
			free(h.name)
			free(h.value)
			free(h)
			m.headers.remove(i)
			removed = removed + 1
		else:
			i = i + 1
	return removed


# Replaces the value of the first header named name, keeping its place
# and spelling (Python's replace_header). Returns 0 when there is none.
int email_message_replace_header(email_message* m, char* name, char* value):
	for email_header* h in m.headers:
		if (email_ieq(h.name, name)):
			free(h.value)
			h.value = email_strdup(value)
			return 1
	return 0


# RFC 5322 2.2.3 unfolding: the value with every CR and LF removed (the
# whitespace that followed each break stays). malloc'd.
char* email_header_unfold(char* value):
	string_builder* sb = string_new()
	int i = 0
	while (value[i] != 0):
		if (!email_is_eol(value[i])): string_append_char(sb, value[i])
		i = i + 1
	return email_finish(sb, 0)


# "name: value" folded to lines of at most maxlen characters (78 when
# maxlen <= 0) by breaking before runs of spaces and tabs, each line
# ended by linesep. The whitespace run moves to the start of the
# continuation line, so email_header_unfold gives the value back. A word
# longer than a line stays whole on its own line. The value is unfolded
# first. For plain ASCII text this matches policy.default's fold.
char* email_header_fold(char* name, char* value, int maxlen, char* linesep):
	if (maxlen <= 0): maxlen = 78
	char* flat = email_header_unfold(value)
	string_builder* sb = string_new()
	string_append(sb, name)
	string_append(sb, c": ")
	int line_len = strlen(name) + 2
	int n = strlen(flat)
	int i = 0
	int first = 1
	while (i < n):
		# Next token: a whitespace run (possibly empty) then a word.
		int ws = i
		while ((i < n) && ((flat[i] == ' ') || (flat[i] == '\t'))): i = i + 1
		int word = i
		while ((i < n) && (flat[i] != ' ') && (flat[i] != '\t')): i = i + 1
		int tok_len = i - ws
		if (!first && (word > ws) && (i > word) && (line_len + tok_len > maxlen)):
			string_append(sb, linesep)
			line_len = 0
		string_append_bytes(sb, &flat[ws], tok_len)
		line_len = line_len + tok_len
		first = 0
	string_append(sb, linesep)
	free(flat)
	return email_finish(sb, 0)


# ---- parameters (Content-Type, Content-Disposition) ------------------------------

int email_param_quotes_odd(char* s, int end):
	int quotes = 0
	int escaped = 0
	for i in range(end):
		if (s[i] == '"'): quotes = quotes + 1
		if ((s[i] == '\\') && (i + 1 < end) && (s[i + 1] == '"')): escaped = escaped + 1
	return ((quotes - escaped) % 2) != 0


int email_find_char(char* s, int from, int c):
	int i = from
	while (s[i] != 0):
		if (s[i] == c): return i
		i = i + 1
	return -1


# Python's _parseparam: the ';'-separated pieces of a header value,
# ignoring ';' inside double quotes, each stripped, with "name = value"
# rewritten as "name=value" (name lowercased).
list[char*] email_parseparam(char* value):
	list[char*] out = new list[char*]
	char* s = value
	int first = 1
	while (first || (s[0] == ';')):
		if (!first): s = &s[1]
		first = 0
		int end = email_find_char(s, 0, ';')
		while ((end > 0) && email_param_quotes_odd(s, end)): end = email_find_char(s, end + 1, ';')
		if (end < 0): end = strlen(s)
		int eq = -1
		for i in range(end):
			if ((eq < 0) && (s[i] == '=')): eq = i
		if (eq >= 0):
			char* key = email_strip_copy(s, 0, eq)
			char* lowered = email_lower_copy(key)
			char* rest = email_strip_copy(s, eq + 1, end)
			string_builder* sb = string_new()
			string_append(sb, lowered)
			string_append_char(sb, '=')
			string_append(sb, rest)
			free(key)
			free(lowered)
			free(rest)
			char* piece = email_finish(sb, 0)
			out.push(email_strip_copy(piece, 0, strlen(piece)))
			free(piece)
		else:
			out.push(email_strip_copy(s, 0, end))
		s = &s[end]
	return out


email_param* email_param_new(char* name, char* value):
	email_param* p = new email_param()
	p.name = name
	p.value = value
	p.charset = 0
	p.language = 0
	p.extended = 0
	return p


void email_params_free(list[email_param*] params):
	if (params == 0): return
	for email_param* p in params:
		free(p.name)
		free(p.value)
		if (p.charset != 0): free(p.charset)
		if (p.language != 0): free(p.language)
		free(p)
	params.free()


# RFC 2231 name: "base*" or "base*N" or "base*N*" with base \w+. Returns
# the base length (0 if no match) and the section number in *num (-1 for
# none).
int email_rfc2231_name(char* name, int* num):
	int i = 0
	while (((name[i] >= 'a') && (name[i] <= 'z')) || ((name[i] >= 'A') && (name[i] <= 'Z')) || ((name[i] >= '0') && (name[i] <= '9')) || (name[i] == '_')): i = i + 1
	if ((i == 0) || (name[i] != '*')): return 0
	int base = i
	i = i + 1
	*num = -1
	if (name[i] == 0): return base
	int n = 0
	int digits = 0
	while ((name[i] >= '0') && (name[i] <= '9')):
		n = n * 10 + (name[i] - '0')
		digits = digits + 1
		i = i + 1
	if (digits == 0): return 0
	if (name[i] == '*'): i = i + 1
	if (name[i] != 0): return 0
	*num = n
	return base


# urllib.parse.unquote(s, encoding="latin-1"): %XX to the byte.
void email_append_percent_decoded(string_builder* sb, char* s):
	int i = 0
	while (s[i] != 0):
		if ((s[i] == '%') && (email_hex_value(s[i + 1] & 255) >= 0) && (email_hex_value(s[i + 2] & 255) >= 0)):
			string_append_char(sb, email_hex_value(s[i + 1] & 255) * 16 + email_hex_value(s[i + 2] & 255))
			i = i + 3
		else:
			string_append_char(sb, s[i])
			i = i + 1


# Parses a parameterized header value into its parameters, as Python's
# Message._get_params_preserve + utils.decode_params do. The first entry
# is the leading value (the content type). Values are unquoted.
list[email_param*] email_parse_params(char* value):
	list[char*] pieces = email_parseparam(value)
	list[email_param*] out = new list[email_param*]
	# RFC 2231 sections, gathered per base name in first-seen order.
	list[char*] rfc_names = new list[char*]
	list[int] sec_owner = new list[int]
	list[int] sec_num = new list[int]
	list[char*] sec_value = new list[char*]
	list[int] sec_encoded = new list[int]
	int index = 0
	for char* piece in pieces:
		int eq = email_find_char(piece, 0, '=')
		char* name = 0
		char* raw = 0
		if (eq >= 0):
			name = email_strip_copy(piece, 0, eq)
			raw = email_strip_copy(piece, eq + 1, strlen(piece))
		else:
			name = email_strip_copy(piece, 0, strlen(piece))
			raw = email_copy(c"", 0)
		if (index == 0):
			out.push(email_param_new(name, raw))
		else:
			int nlen = strlen(name)
			int encoded = (nlen > 0) && (name[nlen - 1] == '*')
			char* unq = email_unquote(raw)
			free(raw)
			int num = -1
			int base = email_rfc2231_name(name, &num)
			if (base > 0):
				char* base_name = email_copy(name, base)
				free(name)
				int owner = -1
				for k in range(rfc_names.length):
					if ((owner < 0) && email_streq(rfc_names[k], base_name)): owner = k
				if (owner < 0):
					owner = rfc_names.length
					rfc_names.push(base_name)
				else:
					free(base_name)
				sec_owner.push(owner)
				sec_num.push(num)
				sec_value.push(unq)
				sec_encoded.push(encoded)
			else:
				out.push(email_param_new(name, unq))
		index = index + 1
	for k in range(rfc_names.length):
		int has_zero = 0
		for j in range(sec_owner.length):
			if ((sec_owner[j] == k) && (sec_num[j] == 0)): has_zero = 1
		# Stable selection sort by section number over this name's sections.
		list[int] order = new list[int]
		for j in range(sec_owner.length):
			if (sec_owner[j] == k):
				if (!(has_zero && (sec_num[j] < 0))): order.push(j)
		for a in range(order.length):
			int best = a
			for b in range(a + 1, order.length):
				int nb = sec_num[order[b]]
				int nbest = sec_num[order[best]]
				if (nb < 0): nb = 0
				if (nbest < 0): nbest = 0
				if (nb < nbest): best = b
			if (best != a):
				int moved = order[best]
				order.remove(best)
				order.insert(a, moved)
		string_builder* joined = string_new()
		int extended = 0
		for j in order:
			if (sec_encoded[j]):
				email_append_percent_decoded(joined, sec_value[j])
				extended = 1
			else:
				string_append(joined, sec_value[j])
		order.free()
		char* text = email_finish(joined, 0)
		email_param* p = email_param_new(email_strdup(rfc_names[k]), text)
		p.extended = extended
		if (extended):
			int t1 = email_find_char(text, 0, '\'')
			int t2 = -1
			if (t1 >= 0): t2 = email_find_char(text, t1 + 1, '\'')
			if (t2 >= 0):
				p.charset = email_copy(text, t1)
				p.language = email_copy(&text[t1 + 1], t2 - t1 - 1)
				p.value = email_strdup(&text[t2 + 1])
				free(text)
		out.push(p)
	for char* n in rfc_names: free(n)
	for char* v in sec_value: free(v)
	for char* piece in pieces: free(piece)
	rfc_names.free()
	sec_owner.free()
	sec_num.free()
	sec_value.free()
	sec_encoded.free()
	pieces.free()
	return out


# The parameters of header (e.g. "content-type"), or 0 when the message
# has no such header. Free with email_params_free.
list[email_param*] email_message_get_params(email_message* m, char* header):
	char* value = email_message_get(m, header)
	if (value == 0): return 0
	return email_parse_params(value)


# utils.collapse_rfc2231_value: an RFC 2231 value converted from its
# charset to UTF-8 (us-ascii when unlabeled); other values unquoted.
char* email_param_collapse(email_param* p):
	char* raw = email_unquote(p.value)
	if (!p.extended): return raw
	char* cs = c"us-ascii"
	if ((p.charset != 0) && (p.charset[0] != 0)): cs = p.charset
	char* text = email_charset_to_utf8(raw, strlen(raw), cs, 0)
	if (text == 0): return raw
	free(raw)
	return text


email_param* email_find_param(list[email_param*] params, char* name):
	for email_param* p in params:
		if (email_ieq(p.name, name)): return p
	return 0


# collapse_rfc2231_value(msg.get_param(param, header=header)): the
# parameter's value as UTF-8 text, malloc'd, or 0 when the header or the
# parameter is missing.
char* email_message_get_param(email_message* m, char* param, char* header):
	list[email_param*] params = email_message_get_params(m, header)
	if (params == 0): return 0
	char* result = 0
	email_param* p = email_find_param(params, param)
	if (p != 0):
		if (p.extended): result = email_param_collapse(p)
		else: result = email_strdup(p.value)
	email_params_free(params)
	return result


# The value of param collapsed again (Python's collapse_rfc2231_value on
# get_param's result), or 0.
char* email_message_param_collapsed(email_message* m, char* param, char* header):
	list[email_param*] params = email_message_get_params(m, header)
	if (params == 0): return 0
	char* result = 0
	email_param* p = email_find_param(params, param)
	if (p != 0):
		if (p.extended): result = email_param_collapse(p)
		else: result = email_unquote(p.value)
	email_params_free(params)
	return result


# The Content-Type boundary parameter with trailing whitespace removed
# (malloc'd), or 0.
char* email_message_get_boundary(email_message* m):
	char* b = email_message_param_collapsed(m, c"boundary", c"content-type")
	if (b == 0): return 0
	int n = strlen(b)
	while ((n > 0) && email_is_space(b[n - 1] & 255)): n = n - 1
	b[n] = 0
	return b


# Content-Disposition's filename, else Content-Type's name, stripped
# (malloc'd), or 0.
char* email_message_get_filename(email_message* m):
	char* f = email_message_param_collapsed(m, c"filename", c"content-disposition")
	if (f == 0): f = email_message_param_collapsed(m, c"name", c"content-type")
	if (f == 0): return 0
	char* out = email_strip_copy(f, 0, strlen(f))
	free(f)
	return out


# The lowercased Content-Type charset parameter (malloc'd), or 0 when it
# is missing or not ASCII.
char* email_message_get_content_charset(email_message* m):
	list[email_param*] params = email_message_get_params(m, c"content-type")
	if (params == 0): return 0
	email_param* p = email_find_param(params, c"charset")
	char* cs = 0
	if (p != 0):
		if (p.extended):
			char* label = c"us-ascii"
			if ((p.charset != 0) && (p.charset[0] != 0)): label = p.charset
			cs = email_charset_to_utf8(p.value, strlen(p.value), label, 0)
			if (cs == 0): cs = email_strdup(p.value)
		else:
			cs = email_strdup(p.value)
	email_params_free(params)
	if (cs == 0): return 0
	int i = 0
	while (cs[i] != 0):
		if ((cs[i] & 255) >= 128):
			free(cs)
			return 0
		cs[i] = email_lower(cs[i] & 255)
		i = i + 1
	return cs


# Python's _splitparam(value)[0]: the text before the first ';',
# stripped. malloc'd.
char* email_value_main(char* value):
	int semi = email_find_char(value, 0, ';')
	if (semi < 0): semi = strlen(value)
	return email_strip_copy(value, 0, semi)


# Lowercased "maintype/subtype" (malloc'd): the default type when there
# is no Content-Type, "text/plain" when the value is not one type/subtype.
char* email_message_get_content_type(email_message* m):
	char* value = email_message_get(m, c"content-type")
	if (value == 0): return email_strdup(m.default_type)
	char* main = email_value_main(value)
	char* ctype = email_lower_copy(main)
	free(main)
	int slashes = 0
	int i = 0
	while (ctype[i] != 0):
		if (ctype[i] == '/'): slashes = slashes + 1
		i = i + 1
	if (slashes != 1):
		free(ctype)
		return email_strdup(c"text/plain")
	return ctype


char* email_message_get_content_maintype(email_message* m):
	char* ctype = email_message_get_content_type(m)
	int slash = email_find_char(ctype, 0, '/')
	char* out = email_copy(ctype, slash)
	free(ctype)
	return out


char* email_message_get_content_subtype(email_message* m):
	char* ctype = email_message_get_content_type(m)
	int slash = email_find_char(ctype, 0, '/')
	char* out = email_strdup(&ctype[slash + 1])
	free(ctype)
	return out


int email_message_maintype_is(email_message* m, char* maintype):
	char* main = email_message_get_content_maintype(m)
	int same = email_streq(main, maintype)
	free(main)
	return same


int email_message_type_is(email_message* m, char* ctype):
	char* t = email_message_get_content_type(m)
	int same = email_streq(t, ctype)
	free(t)
	return same


# The type a part without Content-Type has: "text/plain", or
# "message/rfc822" inside multipart/digest. The string is static or the
# caller's (set_default_type stores the pointer).
char* email_message_get_default_type(email_message* m):
	return m.default_type


void email_message_set_default_type(email_message* m, char* ctype):
	m.default_type = ctype


# The lowercased Content-Disposition value ("inline", "attachment"),
# malloc'd, or 0 without that header.
char* email_message_get_content_disposition(email_message* m):
	char* value = email_message_get(m, c"content-disposition")
	if (value == 0): return 0
	char* main = email_value_main(value)
	char* out = email_lower_copy(main)
	free(main)
	return out


# ---- structure -------------------------------------------------------------------

# Whether the payload is a list of parts (multipart/*, or a message/*
# part holding its sub-message), as Python's is_multipart.
int email_message_is_multipart(email_message* m):
	return m.parts.length > 0


int email_message_part_count(email_message* m):
	return m.parts.length


email_message* email_message_part(email_message* m, int i):
	return m.parts[i]


# Adds part (ownership moves to m) to m's list of parts.
void email_message_attach(email_message* m, email_message* part):
	m.parts.push(part)


void email_walk_into(email_message* m, list[email_message*] out):
	out.push(m)
	for email_message* part in m.parts: email_walk_into(part, out)


# m and every part below it, depth first, m first (Python's walk()). A
# new list of borrowed messages.
list[email_message*] email_message_walk(email_message* m):
	list[email_message*] out = new list[email_message*]
	email_walk_into(m, out)
	return out


int email_message_defect_count(email_message* m):
	return m.defects.length


char* email_message_defect(email_message* m, int i):
	return m.defects[i]


int email_message_has_defect(email_message* m, char* name):
	for char* d in m.defects:
		if (email_streq(d, name)): return 1
	return 0


# The undecoded body (owned by m) and its length, or 0 when the payload
# is a list of parts or was never set.
char* email_message_get_payload(email_message* m, int* out_len):
	if (out_len != 0): *out_len = 0
	if ((m.parts.length > 0) || (m.payload == 0)): return 0
	if (out_len != 0): *out_len = m.payload_len
	return m.payload


# Replaces the body with a copy of len bytes at data.
void email_message_set_payload(email_message* m, char* data, int len):
	if (m.payload != 0): free(m.payload)
	m.payload = email_copy(data, len)
	m.payload_len = len


# ---- transfer encodings ----------------------------------------------------------

# binascii.a2b_qp (quopri.decodestring): =XX escapes (either case), soft
# line breaks "=\n" / "=\r\n", a malformed '=' kept literally. header=1
# also turns '_' into a space (RFC 2047 Q). malloc'd.
char* email_qp_decode(char* s, int len, int header, int* out_len):
	string_builder* sb = string_new_sized(len + 1)
	int i = 0
	while (i < len):
		int c = s[i] & 255
		if (c == '='):
			i = i + 1
			if (i >= len): break
			int d = s[i] & 255
			if ((d == '\n') || (d == '\r')):
				if (d != '\n'):
					while ((i < len) && (s[i] != '\n')): i = i + 1
				if (i < len): i = i + 1
			else if (d == '='):
				string_append_char(sb, '=')
				i = i + 1
			else if ((i + 1 < len) && (email_hex_value(d) >= 0) && (email_hex_value(s[i + 1] & 255) >= 0)):
				string_append_char(sb, email_hex_value(d) * 16 + email_hex_value(s[i + 1] & 255))
				i = i + 2
			else:
				string_append_char(sb, '=')
		else if (header && (c == '_')):
			string_append_char(sb, ' ')
			i = i + 1
		else:
			string_append_char(sb, c)
			i = i + 1
	return email_finish(sb, out_len)


int email_qp_needs_quote(char* s, int len, int i, int line_len, int quotetabs, int header):
	int c = s[i] & 255
	if ((c > 126) || (c == '=')): return 1
	if (header && (c == '_')): return 1
	if ((c == '.') && (line_len == 0)):
		if ((i + 1 == len) || (s[i + 1] == '\n') || (s[i + 1] == '\r') || (s[i + 1] == 0)): return 1
	if (((c == '\t') || (c == ' ')) && (i + 1 == len)): return 1
	if ((c < 33) && (c != '\r') && (c != '\n')):
		if (quotetabs || ((c != '\t') && (c != ' '))): return 1
	return 0


# binascii.b2a_qp(data, quotetabs, istext=True, header): quoted-printable
# with 76-column lines and '=' soft breaks; line breaks are kept (CRLF
# output when the data's first line break is CRLF). quopri.encodestring
# is quotetabs=0, header=0. malloc'd.
char* email_qp_encode(char* s, int len, int quotetabs, int header, int* out_len):
	int crlf = 0
	for i in range(len):
		if ((s[i] == '\n') && !crlf):
			if ((i > 0) && (s[i - 1] == '\r')): crlf = 1
			break
	string_builder* sb = string_new_sized(len + 16)
	int line_len = 0
	int i = 0
	while (i < len):
		int c = s[i] & 255
		if (email_qp_needs_quote(s, len, i, line_len, quotetabs, header)):
			if (line_len + 3 >= 76):
				string_append_char(sb, '=')
				if (crlf): string_append_char(sb, '\r')
				string_append_char(sb, '\n')
				line_len = 0
			email_append_hex(sb, c)
			i = i + 1
			line_len = line_len + 3
		else if ((c == '\n') || ((i + 1 < len) && (c == '\r') && (s[i + 1] == '\n'))):
			line_len = 0
			if (sb.length > 0):
				int last = sb.data[sb.length - 1] & 255
				if ((last == ' ') || (last == '\t')):
					sb.length = sb.length - 1
					email_append_hex(sb, last)
			if (crlf): string_append_char(sb, '\r')
			string_append_char(sb, '\n')
			if (c == '\r'): i = i + 2
			else: i = i + 1
		else:
			if ((i + 1 != len) && (s[i + 1] != '\n') && (line_len + 1 >= 76)):
				string_append_char(sb, '=')
				if (crlf): string_append_char(sb, '\r')
				string_append_char(sb, '\n')
				line_len = 0
			line_len = line_len + 1
			if (header && (c == ' ')): string_append_char(sb, '_')
			else: string_append_char(sb, c)
			i = i + 1
	return email_finish(sb, out_len)


# binascii.a2b_base64(text, strict_mode=False) as of CPython 3.13:
# characters outside the alphabet are skipped and '=' only counts as
# padding (decoding carries on after it). Returns malloc'd bytes, or 0
# when the data ends inside a quad that its padding does not complete
# (Python's binascii.Error).
char* email_a2b_base64(char* s, int len, int* out_len):
	*out_len = 0
	char* out = cast(char*, malloc((len / 4) * 3 + 4))
	int o = 0
	int quad = 0
	int left = 0
	int pads = 0
	for i in range(len):
		int c = s[i] & 255
		if (c == '='):
			if (quad >= 2): pads = pads + 1
			continue
		int v = base64_decode_char(c)
		if (v < 0): continue
		pads = 0
		if (quad == 0):
			left = v
			quad = 1
		else if (quad == 1):
			out[o] = (left << 2) | (v >> 4)
			o = o + 1
			left = v & 15
			quad = 2
		else if (quad == 2):
			out[o] = (left << 4) | (v >> 2)
			o = o + 1
			left = v & 3
			quad = 3
		else:
			out[o] = (left << 6) | v
			o = o + 1
			left = 0
			quad = 0
	if ((quad == 1) || ((quad > 1) && (quad + pads < 4))):
		free(out)
		return 0
	out[o] = 0
	*out_len = o
	return out


# Body base64 as get_payload(decode=True) decodes it (_encoded_words.
# decode_b over the lines joined): invalid characters are skipped and
# missing padding is tolerated. When the data cannot be decoded (one
# character past a whole quad) the line-joined text itself is returned,
# like Python. malloc'd.
char* email_base64_decode(char* s, int len, int* out_len):
	string_builder* joined = string_new_sized(len + 1)
	for i in range(len):
		if (!email_is_eol(s[i])): string_append_char(joined, s[i])
	int n = joined.length
	# Decoding non-strictly with "==" appended accepts every ending that
	# decode_b's three attempts accept.
	string_append(joined, c"==")
	char* out = email_a2b_base64(joined.data, joined.length, out_len)
	if (out != 0):
		string_free(joined)
		return out
	joined.length = n
	joined.data[n] = 0
	return email_finish(joined, out_len)


int email_line_end(char* text, int len, int start);


# binascii.a2b_uu on line[0..n): appends the decoded bytes; 0 on an
# illegal character or trailing garbage.
int email_a2b_uu_line(string_builder* sb, char* line, int n):
	if (n <= 0): return 1
	int want = ((line[0] & 255) - 32) & 63
	int i = 1
	int left = 0
	int bits = 0
	while (want > 0):
		int c = 0
		if (i < n): c = line[i] & 255
		if ((i >= n) || (c == '\n') || (c == '\r')):
			c = 0
		else:
			if ((c < 32) || (c > 96)): return 0
			c = (c - 32) & 63
		left = (left << 6) | c
		bits = bits + 6
		if (bits >= 8):
			bits = bits - 8
			string_append_char(sb, (left >> bits) & 255)
			left = left & ((1 << bits) - 1)
			want = want - 1
		i = i + 1
	while (i < n):
		int c = line[i] & 255
		if ((c != ' ') && (c != 96) && (c != '\n') && (c != '\r')): return 0
		i = i + 1
	return 1


int email_is_octal_mode(char* s, int n):
	int i = 0
	if ((n > 0) && ((s[0] == '+') || (s[0] == '-'))): i = 1
	if ((i + 1 < n) && (s[i] == '0') && ((s[i + 1] == 'o') || (s[i + 1] == 'O'))): i = i + 2
	if (i >= n): return 0
	while (i < n):
		if ((s[i] < '0') || (s[i] > '7')): return 0
		i = i + 1
	return 1


# The body of a uuencoded payload (email.message._decode_uu): the lines
# after "begin <octal mode> ..." up to "end". malloc'd, or 0 when there
# is no begin line or a line does not decode (Python then returns the
# payload as is).
char* email_uu_decode(char* s, int len, int* out_len):
	*out_len = 0
	int pos = 0
	int started = 0
	string_builder* sb = string_new()
	while (pos < len):
		int next = email_line_end(s, len, pos)
		char* line = &s[pos]
		int n = next - pos
		n = n - email_eol_len(line, n)
		pos = next
		if (!started):
			if ((n >= 6) && (line[0] == 'b') && (line[1] == 'e') && (line[2] == 'g') && (line[3] == 'i') && (line[4] == 'n') && (line[5] == ' ')):
				int m = 6
				while ((m < n) && (line[m] != ' ')): m = m + 1
				if (email_is_octal_mode(&line[6], m - 6)): started = 1
			continue
		if (n == 0):
			string_free(sb)
			return 0
		int a = 0
		int b = n
		while ((a < b) && ((line[a] == ' ') || (line[a] == '\t') || (line[a] == 12))): a = a + 1
		while ((b > a) && ((line[b - 1] == ' ') || (line[b - 1] == '\t') || (line[b - 1] == 12))): b = b - 1
		if ((b - a == 3) && (line[a] == 'e') && (line[a + 1] == 'n') && (line[a + 2] == 'd')): break
		int mark = sb.length
		if (!email_a2b_uu_line(sb, line, n)):
			# Broken encoders: retry on the length the count byte implies.
			sb.length = mark
			int nbytes = ((((line[0] & 255) - 32) & 63) * 4 + 5) / 3
			if (nbytes > n): nbytes = n
			if (!email_a2b_uu_line(sb, line, nbytes)):
				string_free(sb)
				return 0
	if (!started):
		string_free(sb)
		return 0
	sb.data[sb.length] = 0
	return email_finish(sb, out_len)


# base64.encodebytes: 76-character lines, each ended by "\n". malloc'd.
char* email_base64_encode_body(char* data, int len, int* out_len):
	char* flat = base64_encode(data, len)
	int n = strlen(flat)
	string_builder* sb = string_new_sized(n + n / 76 + 2)
	int i = 0
	while (i < n):
		int chunk = n - i
		if (chunk > 76): chunk = 76
		string_append_bytes(sb, &flat[i], chunk)
		string_append_char(sb, '\n')
		i = i + chunk
	free(flat)
	return email_finish(sb, out_len)


# The body with its Content-Transfer-Encoding (quoted-printable, base64)
# or x-uuencode undone, as get_payload(decode=True); other encodings
# (7bit, 8bit, binary, unknown) and undecodable uuencode give the bytes
# unchanged. malloc'd; 0 for a list payload or a payload never set.
char* email_message_get_payload_decoded(email_message* m, int* out_len):
	*out_len = 0
	if ((m.parts.length > 0) || (m.payload == 0)): return 0
	char* cte = c""
	char* header = email_message_get(m, c"content-transfer-encoding")
	if (header != 0): cte = header
	char* stripped = email_strip_copy(cte, 0, strlen(cte))
	char* lower = email_lower_copy(stripped)
	free(stripped)
	char* out = 0
	if (email_streq(lower, c"quoted-printable")): out = email_qp_decode(m.payload, m.payload_len, 0, out_len)
	else if (email_streq(lower, c"base64")): out = email_base64_decode(m.payload, m.payload_len, out_len)
	else if (email_streq(lower, c"x-uuencode") || email_streq(lower, c"uuencode") || email_streq(lower, c"uue") || email_streq(lower, c"x-uue")):
		out = email_uu_decode(m.payload, m.payload_len, out_len)
	if (out == 0):
		out = email_copy(m.payload, m.payload_len)
		*out_len = m.payload_len
	free(lower)
	return out


# ---- RFC 2047 encoded words ------------------------------------------------------

# Python's email.header ecre on line[0..n) from pos: the next
# "=?charset?q|b?text?=" match. Fills the four group bounds and returns
# the match start, or -1.
int email_find_encoded_word(char* line, int n, int pos, int* g):
	int i = pos
	while (i + 1 < n):
		if ((line[i] == '=') && (line[i + 1] == '?')):
			int j = i + 2
			while ((j < n) && (line[j] != '?')): j = j + 1
			if ((j + 2 < n) && ((line[j + 1] == 'q') || (line[j + 1] == 'Q') || (line[j + 1] == 'b') || (line[j + 1] == 'B')) && (line[j + 2] == '?')):
				int k = j + 3
				# '.' in ecre stops at a newline.
				while ((k + 1 < n) && (line[k] != '\n') && !((line[k] == '?') && (line[k + 1] == '='))): k = k + 1
				if ((k + 1 < n) && (line[k] == '?')):
					g[0] = i + 2
					g[1] = j
					g[2] = j + 1
					g[3] = k
					return i
		i = i + 1
	return -1


# A word of decode_header's first pass.
struct email_word:
	char* text
	int len
	int encoding     # 0 unencoded, 'q' or 'b'
	char* charset    # lowercased, 0 when unencoded


email_word* email_word_new(char* text, int len, int encoding, char* charset):
	email_word* w = new email_word()
	w.text = email_copy(text, len)
	w.len = len
	w.encoding = encoding
	w.charset = charset
	return w


void email_word_free(email_word* w):
	free(w.text)
	if (w.charset != 0): free(w.charset)
	free(w)


int email_word_is_space(email_word* w):
	if (w.len == 0): return 0
	for i in range(w.len):
		if (!email_is_space(w.text[i] & 255)): return 0
	return 1


# Python's str.splitlines boundaries in ASCII: \r\n, \r, \n, \v, \f,
# \x1c, \x1d, \x1e. Returns the line end; *next gets where the next line
# starts.
int email_split_line(char* s, int n, int start, int* next):
	int i = start
	while (i < n):
		int c = s[i] & 255
		if ((c == '\n') || (c == 11) || (c == 12) || (c == 28) || (c == 29) || (c == 30)):
			*next = i + 1
			return i
		if (c == '\r'):
			if ((i + 1 < n) && (s[i + 1] == '\n')): *next = i + 2
			else: *next = i + 1
			return i
		i = i + 1
	*next = n
	return n


email_header_chunk* email_chunk_new(char* data, int len, char* charset):
	email_header_chunk* c = new email_header_chunk()
	c.data = email_copy(data, len)
	c.len = len
	c.charset = email_strdup(charset)
	return c


void email_header_chunks_free(list[email_header_chunk*] chunks):
	if (chunks == 0): return
	for email_header_chunk* c in chunks:
		free(c.data)
		if (c.charset != 0): free(c.charset)
		free(c)
	chunks.free()


# RFC 2047 Q decoding as quoprimime.header_decode: '_' is a space and
# =XX (hex) a byte; anything else is kept.
char* email_q_decode(char* s, int len, int* out_len):
	string_builder* sb = string_new_sized(len + 1)
	int i = 0
	while (i < len):
		int c = s[i] & 255
		if ((c == '=') && (i + 2 < len) && (email_hex_value(s[i + 1] & 255) >= 0) && (email_hex_value(s[i + 2] & 255) >= 0)):
			string_append_char(sb, email_hex_value(s[i + 1] & 255) * 16 + email_hex_value(s[i + 2] & 255))
			i = i + 3
		else if (c == '_'):
			string_append_char(sb, ' ')
			i = i + 1
		else:
			string_append_char(sb, c)
			i = i + 1
	return email_finish(sb, out_len)


# Python's email.header.decode_header: the value split into runs of
# decoded encoded-word bytes (with their charset) and plain text (charset
# 0). Whitespace between two adjacent encoded words is dropped,
# consecutive encoded words in the same charset are concatenated, and
# plain runs from different lines are joined with a space. A value with
# no encoded word comes back whole as one chunk. Returns 0 when a B word
# cannot be decoded (Python's HeaderParseError).
list[email_header_chunk*] email_decode_header(char* value):
	int n = strlen(value)
	list[email_header_chunk*] out = new list[email_header_chunk*]
	int[4] g
	if (email_find_encoded_word(value, n, 0, &g[0]) < 0):
		out.push(email_chunk_new(value, n, 0))
		return out
	list[email_word*] words = new list[email_word*]
	int start = 0
	while (start < n):
		int next = 0
		int end = email_split_line(value, n, start, &next)
		char* line = &value[start]
		int ln = end - start
		int pos = 0
		int first = 1
		while (pos <= ln):
			int m = email_find_encoded_word(line, ln, pos, &g[0])
			int un_end = ln
			if (m >= 0): un_end = m
			int un_start = pos
			if (first):
				while ((un_start < un_end) && email_is_space(line[un_start] & 255)): un_start = un_start + 1
				first = 0
			if (un_end > un_start): words.push(email_word_new(&line[un_start], un_end - un_start, 0, 0))
			if (m < 0): break
			char* cs_raw = email_copy(&line[g[0]], g[1] - g[0])
			char* cs = email_lower_copy(cs_raw)
			free(cs_raw)
			words.push(email_word_new(&line[g[2] + 2], g[3] - g[2] - 2, email_lower(line[g[2]] & 255), cs))
			pos = g[3] + 2
		start = next
	# Drop whitespace-only words between two encoded words (indexes are
	# chosen on the full list first, as Python's droplist is).
	list[int] drop = new list[int]
	for k in range(2, words.length):
		if ((words[k].encoding != 0) && (words[k - 2].encoding != 0) && email_word_is_space(words[k - 1])): drop.push(k - 1)
	while (drop.length > 0):
		int d = drop.pop()
		email_word_free(words[d])
		words.remove(d)
	drop.free()
	# Decode and collapse runs that share a charset.
	string_builder* run = 0
	char* run_cs = 0
	int failed = 0
	for email_word* w in words:
		char* bytes = 0
		int blen = 0
		if (w.encoding == 'q'):
			bytes = email_q_decode(w.text, w.len, &blen)
		else if (w.encoding == 'b'):
			string_builder* padded = string_new()
			string_append_bytes(padded, w.text, w.len)
			int pad = w.len % 4
			if (pad != 0):
				for p in range(4 - pad):
					if (p < 3): string_append_char(padded, '=')
			bytes = email_a2b_base64(padded.data, padded.length, &blen)
			string_free(padded)
			if (bytes == 0):
				failed = 1
				break
		else:
			bytes = email_copy(w.text, w.len)
			blen = w.len
		int same = 0
		if (run != 0):
			if ((run_cs == 0) && (w.charset == 0)): same = 1
			if ((run_cs != 0) && (w.charset != 0) && email_streq(run_cs, w.charset)): same = 1
		if ((run != 0) && same):
			if (run_cs == 0): string_append_char(run, ' ')
			string_append_bytes(run, bytes, blen)
		else:
			if (run != 0):
				out.push(email_chunk_new(run.data, run.length, run_cs))
				string_free(run)
			run = string_new()
			string_append_bytes(run, bytes, blen)
			run_cs = w.charset
		free(bytes)
	if (run != 0):
		if (!failed): out.push(email_chunk_new(run.data, run.length, run_cs))
		string_free(run)
	for email_word* w in words: email_word_free(w)
	words.free()
	if (failed):
		email_header_chunks_free(out)
		return 0
	return out


int email_nonctext(int c):
	return email_is_space(c) || (c == '(') || (c == ')') || (c == '\\')


# str(make_header(decode_header(value))): the value with its encoded
# words decoded to UTF-8 and joined by Header's spacing rules (a space is
# inserted between an encoded run and plain text unless the plain text
# already has one there). Charsets this module cannot convert are copied
# through as bytes. malloc'd; 0 on a B decoding error.
char* email_header_to_utf8(char* value):
	list[email_header_chunk*] chunks = email_decode_header(value)
	if (chunks == 0): return 0
	# make_header: None means us-ascii; aliases are normalized and equal
	# neighbors are merged with a space (Header._normalize).
	list[char*] cs_list = new list[char*]
	list[char*] text_list = new list[char*]
	list[int] len_list = new list[int]
	for email_header_chunk* c in chunks:
		char* cs = 0
		if (c.charset == 0): cs = email_strdup(c"us-ascii")
		else:
			char* lower = email_lower_copy(c.charset)
			cs = email_strdup(email_charset_canonical(lower))
			free(lower)
		int tlen = 0
		char* text = 0
		if (c.charset != 0): text = email_charset_to_utf8(c.data, c.len, cs, &tlen)
		if (text == 0):
			text = email_copy(c.data, c.len)
			tlen = c.len
		int last = cs_list.length - 1
		if ((last >= 0) && email_streq(cs_list[last], cs)):
			string_builder* sb = string_new()
			string_append_bytes(sb, text_list[last], len_list[last])
			string_append_char(sb, ' ')
			string_append_bytes(sb, text, tlen)
			free(text_list[last])
			free(text)
			free(cs)
			int merged_len = 0
			text_list[last] = email_finish(sb, &merged_len)
			len_list[last] = merged_len
		else:
			cs_list.push(cs)
			text_list.push(text)
			len_list.push(tlen)
	email_header_chunks_free(chunks)
	# Header.__str__.
	string_builder* out = string_new()
	int lastcs_plain = 1
	int lastspace = 0
	for i in range(cs_list.length):
		char* text = text_list[i]
		int tlen = len_list[i]
		int nextcs_plain = email_streq(cs_list[i], c"us-ascii")
		if (i > 0):
			int hasspace = (tlen > 0) && email_nonctext(text[0] & 255)
			if (!lastcs_plain):
				if (nextcs_plain && !hasspace): string_append_char(out, ' ')
			else if (!nextcs_plain && !lastspace):
				string_append_char(out, ' ')
		lastspace = (tlen > 0) && email_nonctext(text[tlen - 1] & 255)
		lastcs_plain = nextcs_plain
		string_append_bytes(out, text, tlen)
	for i in range(cs_list.length):
		free(cs_list[i])
		free(text_list[i])
	cs_list.free()
	text_list.free()
	len_list.free()
	return email_finish(out, 0)


int email_q_safe(int c):
	if (((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || ((c >= '0') && (c <= '9'))): return 1
	return (c == '-') || (c == '!') || (c == '*') || (c == '+') || (c == '/')


# 'q' or 'b' for an encoding argument: 0 picks the shorter result, Q on
# a tie (Python's SHORTEST, used by the utf-8 charset).
int email_pick_encoding(char* data, int len, int encoding):
	if ((encoding == 'q') || (encoding == 'Q')): return 'q'
	if ((encoding == 'b') || (encoding == 'B')): return 'b'
	int qlen = 0
	for i in range(len):
		int c = data[i] & 255
		if ((c == ' ') || email_q_safe(c)): qlen = qlen + 1
		else: qlen = qlen + 3
	if (base64_encoded_length(len) < qlen): return 'b'
	return 'q'


int email_encoded_len(char* data, int len, int encoding):
	encoding = email_pick_encoding(data, len, encoding)
	if (encoding == 'q'):
		int n = 0
		for i in range(len):
			int c = data[i] & 255
			if ((c == ' ') || email_q_safe(c)): n = n + 1
			else: n = n + 3
		return n
	return base64_encoded_length(len)


void email_append_encoded_word(string_builder* sb, char* data, int len, char* charset, int encoding):
	string_append(sb, c"=?")
	string_append(sb, charset)
	if (email_pick_encoding(data, len, encoding) == 'q'):
		string_append(sb, c"?q?")
		for i in range(len):
			int c = data[i] & 255
			if (c == ' '): string_append_char(sb, '_')
			else if (email_q_safe(c)): string_append_char(sb, c)
			else: email_append_hex(sb, c)
	else:
		string_append(sb, c"?b?")
		char* b = base64_encode(data, len)
		string_append(sb, b)
		free(b)
	string_append(sb, c"?=")


# One RFC 2047 encoded word for len bytes of data: "=?charset?b?...?="
# (encoding 'b') or "=?charset?q?...?=" (encoding 'q', with Python's
# header-safe set -!*+/ and alphanumerics left as is and space as '_');
# encoding 0 picks the shorter. This is what Header(text,
# charset).encode() writes for a short value (utf-8 uses 0, iso-8859-*
# use 'q').
# malloc'd.
char* email_header_encode_word(char* data, int len, char* charset, int encoding):
	string_builder* sb = string_new()
	email_append_encoded_word(sb, data, len, charset, encoding)
	return email_finish(sb, 0)


# data as space-separated encoded words of at most 75 characters each
# (RFC 2047 section 2), split between whole UTF-8 characters when the
# charset is utf-8. Decoding drops the spaces between adjacent encoded
# words, so email_header_to_utf8 returns the text; email_header_fold can
# then fold at the spaces. malloc'd.
char* email_header_encode(char* data, int len, char* charset, int encoding):
	char* lower = email_lower_copy(charset)
	int utf8 = email_streq(email_charset_canonical(lower), c"utf-8")
	free(lower)
	int room = 75 - (strlen(charset) + 7)
	string_builder* sb = string_new()
	int i = 0
	int first = 1
	while ((i < len) || first):
		int end = i
		while (end < len):
			int step = 1
			if (utf8):
				while ((end + step < len) && (((data[end + step] & 255) & 192) == 128)): step = step + 1
			if ((end > i) && (email_encoded_len(&data[i], end + step - i, encoding) > room)): break
			end = end + step
		if (!first): string_append_char(sb, ' ')
		email_append_encoded_word(sb, &data[i], end - i, charset, encoding)
		i = end
		first = 0
	return email_finish(sb, 0)


# ---- dates -----------------------------------------------------------------------

# Parses the header (e.g. "Date") with datetime_parse_rfc2822 (Python's
# parsedate_to_datetime). Returns 0 when the header is missing or does
# not parse.
int email_message_get_date(email_message* m, char* name, datetime* out):
	char* value = email_message_get(m, name)
	if (value == 0): return 0
	char* flat = email_header_unfold(value)
	int ok = datetime_parse_rfc2822(flat, out)
	free(flat)
	return ok


# Appends "name: <format_datetime(dt)>".
void email_message_set_date(email_message* m, char* name, datetime dt):
	char* text = datetime_format_rfc2822(dt)
	email_message_add_header(m, name, text)
	free(text)


# ---- the feed parser -------------------------------------------------------------

struct email_parser:
	char* text
	int len
	int pos
	list[int] back            # pushed-back lines as (start, end) pairs, last = next
	list[char*] matchers      # "--boundary" separators; 0 = blank-line matcher
	list[email_message*] stack
	email_message* cur
	email_message* last


int email_line_end(char* text, int len, int start):
	int i = start
	while (i < len):
		int c = text[i]
		if (c == '\n'): return i + 1
		if (c == '\r'):
			if ((i + 1 < len) && (text[i + 1] == '\n')): return i + 2
			return i + 1
		i = i + 1
	return len


# boundaryendRE after "--boundary": 0 no match, 1 separator, 2 close.
int email_boundary_match(char* text, int s, int e, char* sep):
	int n = strlen(sep)
	if (e - s < n): return 0
	for i in range(n):
		if (text[s + i] != sep[i]): return 0
	int i = s + n
	int close = 0
	if ((i + 1 < e) && (text[i] == '-') && (text[i + 1] == '-')):
		close = 1
		i = i + 2
	while ((i < e) && ((text[i] == ' ') || (text[i] == '\t'))): i = i + 1
	if (i == e): return 1 + close
	if ((text[i] == '\r') && (i + 2 == e) && (text[i + 1] == '\n')): return 1 + close
	if (email_is_eol(text[i]) && (i + 1 == e)): return 1 + close
	return 0


int email_parser_at_eof(email_parser* p, int s, int e):
	for char* sep in p.matchers:
		if (sep == 0):
			if (email_is_eol(p.text[s])): return 1
		else if (email_boundary_match(p.text, s, e, sep) != 0):
			return 1
	return 0


int email_parser_readline(email_parser* p, int* ls, int* le):
	int s = 0
	int e = 0
	int from_back = p.back.length > 0
	if (from_back):
		s = p.back[p.back.length - 2]
		e = p.back[p.back.length - 1]
	else:
		if (p.pos >= p.len): return 0
		s = p.pos
		e = email_line_end(p.text, p.len, s)
	if (email_parser_at_eof(p, s, e)): return 0
	if (from_back):
		p.back.pop()
		p.back.pop()
	else:
		p.pos = e
	*ls = s
	*le = e
	return 1


void email_parser_unreadline(email_parser* p, int s, int e):
	p.back.push(s)
	p.back.push(e)


# The rest of the current (sub)file, as a string_builder.
string_builder* email_parser_rest(email_parser* p):
	string_builder* sb = string_new()
	int s = 0
	int e = 0
	while (email_parser_readline(p, &s, &e)): string_append_bytes(sb, &p.text[s], e - s)
	return sb


void email_set_payload_owned(email_message* m, string_builder* sb):
	if (m.payload != 0): free(m.payload)
	m.payload_len = sb.length
	m.payload = email_finish(sb, 0)


void email_add_defect(email_message* m, char* name):
	m.defects.push(name)


void email_parser_new_message(email_parser* p):
	email_message* msg = email_message_new()
	if ((p.cur != 0) && email_message_type_is(p.cur, c"multipart/digest")): msg.default_type = c"message/rfc822"
	if (p.stack.length > 0):
		email_message* top = p.stack[p.stack.length - 1]
		top.parts.push(msg)
	p.stack.push(msg)
	p.cur = msg
	p.last = msg


email_message* email_parser_pop(email_parser* p):
	email_message* r = p.stack.pop()
	if (p.stack.length > 0): p.cur = p.stack[p.stack.length - 1]
	else: p.cur = 0
	return r


int email_is_header_line(char* t, int s, int e):
	if ((e - s >= 5) && (t[s] == 'F') && (t[s + 1] == 'r') && (t[s + 2] == 'o') && (t[s + 3] == 'm') && (t[s + 4] == ' ')): return 1
	if ((t[s] == ' ') || (t[s] == '\t')): return 1
	int i = s
	while (i < e):
		int c = t[i] & 255
		if (c == ':'): return 1
		if ((c < 33) || (c > 126)): return 0
		i = i + 1
	return 0


# policy.header_source_parse over header lines lines[from..to) (pairs).
void email_parser_store_header(email_parser* p, list[int] lines, int from, int to):
	char* t = p.text
	int s = lines[from * 2]
	int e = lines[from * 2 + 1]
	int colon = s
	while (t[colon] != ':'): colon = colon + 1
	string_builder* v = string_new()
	int i = colon + 1
	while ((i < e) && ((t[i] == ' ') || (t[i] == '\t'))): i = i + 1
	string_append_bytes(v, &t[i], e - i)
	for k in range(from + 1, to): string_append_bytes(v, &t[lines[k * 2]], lines[k * 2 + 1] - lines[k * 2])
	while ((v.length > 0) && email_is_eol(v.data[v.length - 1])): v.length = v.length - 1
	v.data[v.length] = 0
	email_header* h = new email_header()
	h.name = email_copy(&t[s], colon - s)
	h.value = email_finish(v, 0)
	p.cur.headers.push(h)


# FeedParser._parse_headers.
void email_parser_parse_headers(email_parser* p, list[int] lines):
	char* t = p.text
	int count = lines.length / 2
	int pending = -1
	for lineno in range(count):
		int s = lines[lineno * 2]
		int e = lines[lineno * 2 + 1]
		if ((t[s] == ' ') || (t[s] == '\t')):
			if (pending < 0): email_add_defect(p.cur, c"FirstHeaderLineIsContinuationDefect")
			continue
		if (pending >= 0):
			email_parser_store_header(p, lines, pending, lineno)
			pending = -1
		if ((e - s >= 5) && (t[s] == 'F') && (t[s + 1] == 'r') && (t[s + 2] == 'o') && (t[s + 3] == 'm') && (t[s + 4] == ' ')):
			if (lineno == 0):
				int n = e - s
				n = n - email_eol_len(&t[s], n)
				p.cur.unixfrom = email_copy(&t[s], n)
				continue
			else if (lineno == count - 1):
				email_parser_unreadline(p, s, e)
				return
			else:
				email_add_defect(p.cur, c"MisplacedEnvelopeHeaderDefect")
				continue
		if (t[s] == ':'):
			email_add_defect(p.cur, c"InvalidHeaderDefect")
			continue
		pending = lineno
	if (pending >= 0): email_parser_store_header(p, lines, pending, count)


char* email_strip_eol_owned(char* s):
	int n = strlen(s)
	s[n - email_eol_len(s, n)] = 0
	return s


void email_parser_parsegen(email_parser* p);


void email_parser_multipart(email_parser* p, email_message* cur, char* boundary):
	char* cte = email_message_get(cur, c"content-transfer-encoding")
	if (cte != 0):
		char* lower = email_lower_copy(cte)
		if (!email_streq(lower, c"7bit") && !email_streq(lower, c"8bit") && !email_streq(lower, c"binary")): email_add_defect(cur, c"InvalidMultipartContentTransferEncodingDefect")
		free(lower)
	string_builder* sep_sb = string_new()
	string_append(sep_sb, c"--")
	string_append(sep_sb, boundary)
	char* sep = email_finish(sep_sb, 0)
	int capturing = 1
	string_builder* preamble = string_new()
	int preamble_lines = 0
	int close_seen = 0
	int linesep = 0
	int s = 0
	int e = 0
	while (email_parser_readline(p, &s, &e)):
		int mo = email_boundary_match(p.text, s, e, sep)
		if (mo == 2):
			close_seen = 1
			linesep = email_is_eol(p.text[e - 1])
			break
		if (mo == 0):
			string_append_bytes(preamble, &p.text[s], e - s)
			preamble_lines = preamble_lines + 1
			continue
		if (capturing):
			if (preamble_lines > 0):
				preamble.length = preamble.length - email_eol_len(preamble.data, preamble.length)
				cur.preamble = email_copy(preamble.data, preamble.length)
			capturing = 0
			email_parser_unreadline(p, s, e)
			continue
		# Swallow repeated boundary lines, then parse one part.
		while (email_parser_readline(p, &s, &e)):
			if (email_boundary_match(p.text, s, e, sep) == 0):
				email_parser_unreadline(p, s, e)
				break
		p.matchers.push(sep)
		email_parser_parsegen(p)
		email_message* last = p.last
		if (email_message_maintype_is(last, c"multipart")):
			if (last.epilogue != 0):
				if (last.epilogue[0] == 0):
					free(last.epilogue)
					last.epilogue = 0
				else:
					email_strip_eol_owned(last.epilogue)
		else if ((last.payload != 0) && (last.parts.length == 0)):
			last.payload_len = last.payload_len - email_eol_len(last.payload, last.payload_len)
			last.payload[last.payload_len] = 0
		p.matchers.pop()
		email_parser_pop(p)
		p.last = p.cur
	if (capturing):
		email_add_defect(cur, c"StartBoundaryNotFoundDefect")
		email_set_payload_owned(cur, preamble)
		string_free(email_parser_rest(p))
		cur.epilogue = email_copy(c"", 0)
		free(sep)
		return
	string_free(preamble)
	free(sep)
	if (!close_seen):
		email_add_defect(cur, c"CloseBoundaryNotFoundDefect")
		return
	string_builder* epilogue = email_parser_rest(p)
	if (!linesep):
		# NLCRE_bol: a line break opening the epilogue is not part of it.
		int strip = 0
		if ((epilogue.length > 0) && (epilogue.data[0] == '\r')):
			strip = 1
			if ((epilogue.length > 1) && (epilogue.data[1] == '\n')): strip = 2
		else if ((epilogue.length > 0) && (epilogue.data[0] == '\n')):
			strip = 1
		if (strip > 0):
			char* rest = email_copy(&epilogue.data[strip], epilogue.length - strip)
			string_free(epilogue)
			cur.epilogue = rest
			return
	cur.epilogue = email_finish(epilogue, 0)


# FeedParser._parsegen: one message (headers, then a body shaped by its
# content type) up to the current end of input.
void email_parser_parsegen(email_parser* p):
	email_parser_new_message(p)
	email_message* cur = p.cur
	list[int] lines = new list[int]
	int s = 0
	int e = 0
	while (email_parser_readline(p, &s, &e)):
		if (!email_is_header_line(p.text, s, e)):
			if (!email_is_eol(p.text[s])):
				email_add_defect(cur, c"MissingHeaderBodySeparatorDefect")
				email_parser_unreadline(p, s, e)
			break
		lines.push(s)
		lines.push(e)
	email_parser_parse_headers(p, lines)
	lines.free()
	if (email_message_type_is(cur, c"message/delivery-status")):
		while (true):
			p.matchers.push(0)
			email_parser_parsegen(p)
			email_parser_pop(p)
			p.matchers.pop()
			email_parser_readline(p, &s, &e)
			if (!email_parser_readline(p, &s, &e)): break
			email_parser_unreadline(p, s, e)
		return
	if (email_message_maintype_is(cur, c"message")):
		email_parser_parsegen(p)
		email_parser_pop(p)
		return
	if (email_message_maintype_is(cur, c"multipart")):
		char* boundary = email_message_get_boundary(cur)
		if (boundary == 0):
			email_add_defect(cur, c"NoBoundaryInMultipartDefect")
			email_set_payload_owned(cur, email_parser_rest(p))
			return
		email_parser_multipart(p, cur, boundary)
		free(boundary)
		return
	email_set_payload_owned(cur, email_parser_rest(p))


# Parses len bytes of an RFC 5322 message (email.message_from_bytes with
# the compat32 policy). Never fails; see the defects on each part.
email_message* email_message_from_bytes(char* data, int len):
	email_parser* p = new email_parser()
	p.text = data
	p.len = len
	p.pos = 0
	p.back = new list[int]
	p.matchers = new list[char*]
	p.stack = new list[email_message*]
	p.cur = 0
	p.last = 0
	email_parser_parsegen(p)
	email_message* root = email_parser_pop(p)
	if (email_message_maintype_is(root, c"multipart") && (root.parts.length == 0)): email_add_defect(root, c"MultipartInvariantViolationDefect")
	p.back.free()
	p.matchers.free()
	p.stack.free()
	free(p)
	return root


email_message* email_message_from_string(char* text):
	return email_message_from_bytes(text, strlen(text))


# ---- generator -------------------------------------------------------------------

# Writes s[0..n) with every line break (\r\n, \r, \n) replaced by linesep.
void email_write_lines(string_builder* sb, char* s, int n, char* linesep):
	int i = 0
	while (i < n):
		int c = s[i]
		if (c == '\r'):
			string_append(sb, linesep)
			if ((i + 1 < n) && (s[i + 1] == '\n')): i = i + 1
		else if (c == '\n'):
			string_append(sb, linesep)
		else:
			string_append_char(sb, c)
		i = i + 1


int email_contains(char* hay, int n, char* needle):
	int m = strlen(needle)
	for i in range(n - m + 1):
		int same = 1
		for j in range(m):
			if (same && (hay[i + j] != needle[j])): same = 0
		if (same): return 1
	return 0


void email_flatten(string_builder* sb, email_message* m, char* linesep);


void email_flatten_multipart(string_builder* sb, email_message* m, char* linesep):
	list[char*] texts = new list[char*]
	list[int] lens = new list[int]
	string_builder* all = string_new()
	for email_message* part in m.parts:
		string_builder* one = string_new()
		email_flatten(one, part, linesep)
		string_append_bytes(all, one.data, one.length)
		lens.push(one.length)
		texts.push(email_finish(one, 0))
	char* boundary = email_message_get_boundary(m)
	if ((boundary == 0) || (boundary[0] == 0)):
		if (boundary != 0): free(boundary)
		# A boundary that does not occur in any part (Generator._make_boundary).
		int counter = 0
		while (true):
			string_builder* b = string_new()
			string_append(b, c"===============")
			string_append_int(b, 1000000007 + counter)
			string_append(b, c"==")
			boundary = email_finish(b, 0)
			if (!email_contains(all.data, all.length, boundary)): break
			free(boundary)
			counter = counter + 1
		char* ct = email_message_get(m, c"content-type")
		string_builder* v = string_new()
		if (ct == 0): string_append(v, c"multipart/mixed")
		else: string_append(v, ct)
		string_append(v, c"; boundary=\"")
		string_append(v, boundary)
		string_append(v, c"\"")
		char* value = email_finish(v, 0)
		if (!email_message_replace_header(m, c"content-type", value)): email_message_add_header(m, c"Content-Type", value)
		free(value)
	string_free(all)
	if (m.preamble != 0):
		email_write_lines(sb, m.preamble, strlen(m.preamble), linesep)
		string_append(sb, linesep)
	string_append(sb, c"--")
	string_append(sb, boundary)
	string_append(sb, linesep)
	for i in range(texts.length):
		if (i > 0):
			string_append(sb, linesep)
			string_append(sb, c"--")
			string_append(sb, boundary)
			string_append(sb, linesep)
		string_append_bytes(sb, texts[i], lens[i])
	string_append(sb, linesep)
	string_append(sb, c"--")
	string_append(sb, boundary)
	string_append(sb, c"--")
	string_append(sb, linesep)
	if (m.epilogue != 0): email_write_lines(sb, m.epilogue, strlen(m.epilogue), linesep)
	for char* t in texts: free(t)
	texts.free()
	lens.free()
	free(boundary)


void email_flatten_body(string_builder* sb, email_message* m, char* linesep):
	if (m.parts.length == 0):
		if (m.payload == 0): return
		if (email_message_maintype_is(m, c"multipart") || email_message_maintype_is(m, c"message")): string_append_bytes(sb, m.payload, m.payload_len)
		else: email_write_lines(sb, m.payload, m.payload_len, linesep)
		return
	if (email_message_type_is(m, c"message/delivery-status")):
		int ll = strlen(linesep)
		for i in range(m.parts.length):
			if (i > 0): string_append(sb, linesep)
			string_builder* one = string_new()
			email_flatten(one, m.parts[i], linesep)
			int n = one.length
			# Drop the empty last line each block's flattening ends with.
			if ((n >= ll) && email_contains(&one.data[n - ll], ll, linesep)): n = n - ll
			string_append_bytes(sb, one.data, n)
			string_free(one)
		return
	if (email_message_maintype_is(m, c"message")):
		email_flatten(sb, m.parts[0], linesep)
		return
	email_flatten_multipart(sb, m, linesep)


void email_flatten(string_builder* sb, email_message* m, char* linesep):
	# The body goes first into its own buffer: flattening a multipart
	# without a boundary adds one to the Content-Type header.
	string_builder* body = string_new()
	email_flatten_body(body, m, linesep)
	for email_header* h in m.headers:
		string_append(sb, h.name)
		string_append(sb, c": ")
		email_write_lines(sb, h.value, strlen(h.value), linesep)
		string_append(sb, linesep)
	string_append(sb, linesep)
	string_append_bytes(sb, body.data, body.length)
	string_free(body)


# The message as text, compat32's msg.as_string() (linesep "\n") or
# as_bytes with policy linesep "\r\n": headers as stored, line breaks in
# header values and text bodies normalized to linesep, multiparts
# rebuilt from their boundary, preamble, parts and epilogue. A multipart
# without a boundary gets one (added to its Content-Type header).
# The unix-from line is not written. malloc'd.
char* email_message_as_string(email_message* m, char* linesep, int* out_len):
	string_builder* sb = string_new()
	email_flatten(sb, m, linesep)
	return email_finish(sb, out_len)
