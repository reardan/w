# HPACK: header compression for HTTP/2 (RFC 7541), part of issue #436
# ("Protocols"). Pure W, no dependencies beyond lib/ and structures/;
# libs/standard/web/http2.w is the consumer.
#
# Public API (headers):
#   hpack_header* hpack_header_new(char* name, int name_len, char* value, int value_len)
#   void hpack_header_free(hpack_header* h)
#   list[hpack_header*] hpack_headers_new()
#   void hpack_headers_add(list[hpack_header*] l, char* name, char* value)
#   void hpack_headers_add_sensitive(list[hpack_header*] l, char* name, char* value)
#   char* hpack_headers_get(list[hpack_header*] l, char* name)   first match, or 0
#   void hpack_headers_free(list[hpack_header*] l)
#
# Public API (codec):
#   hpack_decoder* hpack_decoder_new(int max_table_size)
#   int  hpack_decode(hpack_decoder* d, char* block, int len, list[hpack_header*] out)
#   void hpack_decoder_set_max_table_size(hpack_decoder* d, int n)  (our SETTINGS value)
#   void hpack_decoder_free(hpack_decoder* d)
#   hpack_encoder* hpack_encoder_new(int max_table_size)
#   void hpack_encoder_set_max_table_size(hpack_encoder* e, int n)  (peer SETTINGS value)
#   void hpack_encode(hpack_encoder* e, list[hpack_header*] headers, string_builder* out)
#   void hpack_encoder_free(hpack_encoder* e)
#   int  hpack_huffman_encode(char* s, int len, string_builder* out)
#   char* hpack_huffman_decode(char* p, int len, int max_out, int* out_len)  0 on error
#   int  hpack_encode_int(string_builder* out, int first_bits, int prefix, int value)
#   int  hpack_decode_int(char* p, int len, int* pos, int prefix, int* out)
#   int  hpack_error_*()  /  char* hpack_error_string(int code)
#
# Representations (RFC 7541 section 6): indexed (1xxxxxxx), literal
# with incremental indexing (01xxxxxx), literal without indexing
# (0000xxxx), literal never indexed (0001xxxx), and dynamic table size
# update (001xxxxx), all decoded. The encoder emits: indexed for a full
# static/dynamic match, otherwise a literal whose name is indexed when
# any table has it (static preferred, lowest index first), with
# incremental indexing by default (hpack_encoder.indexing = 0 switches to
# "without indexing"), never-indexed for headers added with
# hpack_headers_add_sensitive, and Huffman for any string literal the
# code does not make longer (hpack_encoder.huffman = 0 disables it).
# That policy reproduces the RFC 7541 Appendix C vectors byte for byte.
#
# Huffman (Appendix B): the code is canonical, so only the 257 code
# lengths are stored (hpack_huffman_lengths); codes are rebuilt in
# (length, symbol) order at first use. The decoder rejects EOS in the
# stream, padding longer than 7 bits, and padding that is not the EOS
# prefix (all ones), per section 5.2.
#
# Hard caps (all fail closed with an hpack_error_* code; a decode error
# leaves the decoder's dynamic table undefined, so HTTP/2 must treat it
# as a connection-level COMPRESSION_ERROR):
#   - integers: at most 4 continuation bytes (value < 2^28);
#   - one string literal: hpack_decoder.max_string bytes (decoded);
#   - the decoded header list: hpack_decoder.max_list_size bytes counted
#     as RFC 9113 SETTINGS_MAX_HEADER_LIST_SIZE does (name + value + 32
#     per field) and hpack_decoder.max_headers fields;
#   - a size update above the decoder's settings limit, a size update
#     after the first field of a block, and index 0 / out-of-range
#     indexes are errors.
#
# Header names and values are stored NUL-terminated with explicit
# lengths; HTTP/2 forbids NUL in field values, and a decoded field
# containing NUL, CR or LF is rejected (hpack_error_bad_field).
import lib.lib
import lib.container
import structures.string
import lib.mem


# One header field. name/value are owned, NUL-terminated copies.
# sensitive = 1 makes the encoder use the never-indexed representation.
struct hpack_header:
	char* name
	int name_len
	char* value
	int value_len
	int sensitive


# The dynamic table: entries[entries.length - 1] is the newest entry
# (dynamic index 1). size counts name_len + value_len + 32 per entry.
struct hpack_table:
	list[hpack_header*] entries
	int size
	int max_size


struct hpack_decoder:
	hpack_table* table
	int settings_max
	int max_list_size
	int max_string
	int max_headers


struct hpack_encoder:
	hpack_table* table
	int cap
	int pending_min
	int pending_final
	int huffman
	int indexing


/* Error codes */

const int hpack_error_none = 0


# Truncated or malformed integer / string / representation.
const int hpack_error_malformed = 1


# Index 0 or beyond the static + dynamic tables.
const int hpack_error_bad_index = 2


# Invalid Huffman data (EOS, bad padding).
const int hpack_error_huffman = 3


# A string, the header list, or the field count exceeded a cap.
const int hpack_error_too_large = 4


# Dynamic table size update above the limit, or not at block start.
const int hpack_error_table_size = 5


# A field name/value containing NUL, CR or LF, or an empty name.
const int hpack_error_bad_field = 6


char* hpack_error_string(int code):
	switch (code):
		case 0: return c"ok"
		case 1: return c"malformed header block"
		case 2: return c"invalid header index"
		case 3: return c"invalid huffman data"
		case 4: return c"header block exceeds limits"
		case 5: return c"invalid dynamic table size update"
		case 6: return c"invalid header field"
		default: return c"unknown hpack error"


/* Defaults */

const int hpack_default_table_size = 4096
const int hpack_default_max_string = 65536
const int hpack_default_max_list_size = 65536
const int hpack_default_max_headers = 256


/* Header fields and lists */

hpack_header* hpack_header_new(char* name, int name_len, char* value, int value_len):
	hpack_header* h = new hpack_header()
	h.name = mem_dup(name, name_len)
	h.name_len = name_len
	h.value = mem_dup(value, value_len)
	h.value_len = value_len
	h.sensitive = 0
	return h


void hpack_header_free(hpack_header* h):
	if (h == 0):
		return
	free(h.name)
	free(h.value)
	free(h)


list[hpack_header*] hpack_headers_new():
	return new list[hpack_header*]


void hpack_headers_add(list[hpack_header*] l, char* name, char* value):
	l.push(hpack_header_new(name, strlen(name), value, strlen(value)))


void hpack_headers_add_sensitive(list[hpack_header*] l, char* name, char* value):
	hpack_header* h = hpack_header_new(name, strlen(name), value, strlen(value))
	h.sensitive = 1
	l.push(h)


int hpack_bytes_equal(char* a, int alen, char* b, int blen):
	return (alen == blen) && mem_eq(a, b, alen)


# First header whose name equals name exactly (HTTP/2 names are
# lowercase on the wire), or 0.
char* hpack_headers_get(list[hpack_header*] l, char* name):
	if (l == 0):
		return 0
	int n = strlen(name)
	for i in range(l.length):
		hpack_header* h = l[i]
		if (hpack_bytes_equal(h.name, h.name_len, name, n) != 0):
			return h.value
	return 0


void hpack_headers_free(list[hpack_header*] l):
	if (l == 0):
		return
	int i = 0
	while (i < l.length):
		hpack_header_free(l[i])
		i = i + 1
	list_free[hpack_header*](l)


/* Static table (RFC 7541 Appendix A) */

char** hpack_static_names_g
char** hpack_static_values_g


const int hpack_static_count = 61


# "name value" pairs separated by '|', one entry per ';'. Entry 1 first.
char* hpack_static_text():
	return c":authority|;:method|GET;:method|POST;:path|/;:path|/index.html;:scheme|http;:scheme|https;:status|200;:status|204;:status|206;:status|304;:status|400;:status|404;:status|500;accept-charset|;accept-encoding|gzip, deflate;accept-language|;accept-ranges|;accept|;access-control-allow-origin|;age|;allow|;authorization|;cache-control|;content-disposition|;content-encoding|;content-language|;content-length|;content-location|;content-range|;content-type|;cookie|;date|;etag|;expect|;expires|;from|;host|;if-match|;if-modified-since|;if-none-match|;if-range|;if-unmodified-since|;last-modified|;link|;location|;max-forwards|;proxy-authenticate|;proxy-authorization|;range|;referer|;refresh|;retry-after|;server|;set-cookie|;strict-transport-security|;transfer-encoding|;user-agent|;vary|;via|;www-authenticate|;"


void hpack_static_init():
	if (hpack_static_names_g != 0):
		return
	int n = hpack_static_count + 1
	char** names = cast(char**, malloc(n * __word_size__))
	char** values = cast(char**, malloc(n * __word_size__))
	char* text = hpack_static_text()
	int pos = 0
	for idx in range(1, n):
		int start = pos
		while (text[pos] != '|'):
			pos = pos + 1
		names[idx] = mem_dup(text + start, pos - start)
		pos = pos + 1
		start = pos
		while (text[pos] != ';'):
			pos = pos + 1
		values[idx] = mem_dup(text + start, pos - start)
		pos = pos + 1
	names[0] = 0
	values[0] = 0
	hpack_static_values_g = values
	hpack_static_names_g = names


char* hpack_static_name(int index):
	hpack_static_init()
	return hpack_static_names_g[index]


char* hpack_static_value(int index):
	hpack_static_init()
	return hpack_static_values_g[index]


/* Dynamic table */

hpack_table* hpack_table_new(int max_size):
	hpack_table* t = new hpack_table(new list[hpack_header*], 0, max_size)
	return t


int hpack_entry_size(hpack_header* h):
	return h.name_len + h.value_len + 32


void hpack_table_evict_to(hpack_table* t, int limit):
	while ((t.size > limit) && (t.entries.length > 0)):
		hpack_header* old = t.entries[0]
		t.entries.remove(0)
		t.size = t.size - hpack_entry_size(old)
		hpack_header_free(old)


void hpack_table_set_max(hpack_table* t, int max_size):
	t.max_size = max_size
	hpack_table_evict_to(t, max_size)


# Section 4.4: evict until the new entry fits; an entry larger than the
# whole table empties it and is not added (not an error).
void hpack_table_add(hpack_table* t, char* name, int name_len, char* value, int value_len):
	int esize = name_len + value_len + 32
	if (esize > t.max_size):
		hpack_table_evict_to(t, 0)
		return
	hpack_table_evict_to(t, t.max_size - esize)
	t.entries.push(hpack_header_new(name, name_len, value, value_len))
	t.size = t.size + esize


int hpack_table_count(hpack_table* t):
	return t.entries.length


# Dynamic index 1 = newest.
hpack_header* hpack_table_get(hpack_table* t, int dyn_index):
	return t.entries[t.entries.length - dyn_index]


void hpack_table_free(hpack_table* t):
	hpack_headers_free(t.entries)
	free(t)


/* Integer representation (section 5.1) */

# Appends value with an N-bit prefix; first_bits carries the pattern
# bits above the prefix (e.g. 0x80 for an indexed field).
int hpack_encode_int(string_builder* out, int first_bits, int prefix, int value):
	int max_prefix = (1 << prefix) - 1
	if (value < max_prefix):
		string_append_char(out, first_bits | value)
		return 1
	string_append_char(out, first_bits | max_prefix)
	value = value - max_prefix
	while (value >= 128):
		string_append_char(out, (value & 127) | 128)
		value = value >> 7
	string_append_char(out, value)
	return 1


# Decodes an N-bit-prefix integer at *pos. Returns 1 and advances *pos,
# or 0 when truncated or longer than 4 continuation bytes.
int hpack_decode_int(char* p, int len, int* pos, int prefix, int* out):
	int i = *pos
	if (i >= len):
		return 0
	int max_prefix = (1 << prefix) - 1
	int value = (p[i] & 255) & max_prefix
	i = i + 1
	if (value < max_prefix):
		*out = value
		*pos = i
		return 1
	int shift = 0
	while (1):
		if (i >= len):
			return 0
		if (shift > 21):
			return 0
		int b = p[i] & 255
		i = i + 1
		value = value + ((b & 127) << shift)
		shift = shift + 7
		if ((b & 128) == 0):
			break
	*out = value
	*pos = i
	return 1


/* Huffman code (Appendix B) */

# Code length per symbol 0..256, as 'A' + (length - 5).
char* hpack_huffman_lengths():
	return c"ISXXXXXXXTZXXZXXXXXXXXZXXXXXXXXXBFFHIBDGFFDGDBBBAAABBBBBBBCDKBHFIBCCCCCCCCCCCCCCCCCCCCCCDCDIOIJBKABABABBBACCBBBABCBAABCCCCCKGJIXPRPPRRRSRSSSSSTSTTRSTSSSSQRSRSSTRQPRRSSQSRRTQRSSQQRQSRSSPRRRSRRSVVPORSRUVVVWWVTUOQVWWVWTQQVVXWWWPTPQRQQSRRUUTTVSVWVVWWWWWXWWWWWVZ"


int* hpack_huff_code_g
int* hpack_huff_len_g
int* hpack_huff_sorted_g
int* hpack_huff_first_code_g
int* hpack_huff_first_index_g
int* hpack_huff_count_g


# Rebuilds the canonical code: symbols sorted by (length, symbol) get
# consecutive codes, shifting left at each length step.
void hpack_huffman_init():
	if (hpack_huff_code_g != 0):
		return
	char* lens = hpack_huffman_lengths()
	int* code = cast(int*, malloc(257 * __word_size__))
	int* len = cast(int*, malloc(257 * __word_size__))
	int* sorted = cast(int*, malloc(257 * __word_size__))
	int* first_code = cast(int*, malloc(32 * __word_size__))
	int* first_index = cast(int*, malloc(32 * __word_size__))
	int* count = cast(int*, malloc(32 * __word_size__))
	int i = 0
	while (i < 32):
		first_code[i] = 0
		first_index[i] = 0
		count[i] = 0
		i = i + 1
	i = 0
	while (i < 257):
		len[i] = (lens[i] - 'A') + 5
		count[len[i]] = count[len[i]] + 1
		i = i + 1
	int next = 0
	int n = 0
	for L in range(1, 32):
		first_code[L] = next
		first_index[L] = n
		for s in range(257):
			if (len[s] == L):
				code[s] = next
				sorted[n] = s
				next = next + 1
				n = n + 1
		next = next << 1
	hpack_huff_len_g = len
	hpack_huff_sorted_g = sorted
	hpack_huff_first_code_g = first_code
	hpack_huff_first_index_g = first_index
	hpack_huff_count_g = count
	hpack_huff_code_g = code


int hpack_huffman_code(int sym):
	hpack_huffman_init()
	return hpack_huff_code_g[sym]


int hpack_huffman_code_length(int sym):
	hpack_huffman_init()
	return hpack_huff_len_g[sym]


# Encoded byte length of s under the Huffman code.
int hpack_huffman_length(char* s, int len):
	hpack_huffman_init()
	int bits = 0
	for i in range(len):
		bits = bits + hpack_huff_len_g[s[i] & 255]
	return (bits + 7) / 8


# Appends the Huffman encoding of s, padded with the EOS prefix (ones).
# Returns the number of bytes appended.
int hpack_huffman_encode(char* s, int len, string_builder* out):
	hpack_huffman_init()
	int start = out.length
	int cur = 0
	int nbits = 0
	for i in range(len):
		int sym = s[i] & 255
		int c = hpack_huff_code_g[sym]
		int b = hpack_huff_len_g[sym] - 1
		while (b >= 0):
			cur = (cur << 1) | ((c >> b) & 1)
			nbits = nbits + 1
			if (nbits == 8):
				string_append_char(out, cur)
				cur = 0
				nbits = 0
			b = b - 1
	if (nbits > 0):
		cur = (cur << (8 - nbits)) | ((1 << (8 - nbits)) - 1)
		string_append_char(out, cur)
	return out.length - start


# Decodes len bytes of Huffman data. Returns a malloc'd NUL-terminated
# buffer and sets *out_len, or 0 on invalid data or when the decoded
# length would exceed max_out.
char* hpack_huffman_decode(char* p, int len, int max_out, int* out_len):
	hpack_huffman_init()
	string_builder* out = string_new()
	int code = 0
	int clen = 0
	for i in range(len):
		int v = p[i] & 255
		int b = 7
		while (b >= 0):
			code = (code << 1) | ((v >> b) & 1)
			clen = clen + 1
			if (clen > 30):
				string_free(out)
				return 0
			int cnt = hpack_huff_count_g[clen]
			if (cnt > 0):
				int off = code - hpack_huff_first_code_g[clen]
				if ((off >= 0) && (off < cnt)):
					int sym = hpack_huff_sorted_g[hpack_huff_first_index_g[clen] + off]
					if (sym == 256):
						string_free(out)
						return 0
					if (out.length >= max_out):
						string_free(out)
						return 0
					string_append_char(out, sym)
					code = 0
					clen = 0
			b = b - 1
	# Padding: at most 7 bits, all ones (a prefix of EOS).
	if (clen > 7):
		string_free(out)
		return 0
	if (code != ((1 << clen) - 1)):
		string_free(out)
		return 0
	*out_len = out.length
	char* data = out.data
	free(out)
	return data


/* String literals (section 5.2) */

void hpack_encode_string(string_builder* out, char* s, int len, int huffman):
	if (huffman != 0):
		int hlen = hpack_huffman_length(s, len)
		if (hlen <= len):
			hpack_encode_int(out, 128, 7, hlen)
			hpack_huffman_encode(s, len, out)
			return
	hpack_encode_int(out, 0, 7, len)
	string_append_bytes(out, s, len)


# Decodes a string literal at *pos. Returns a malloc'd NUL-terminated
# copy (length in *out_len) or 0 with *err set.
char* hpack_decode_string(hpack_decoder* d, char* p, int len, int* pos, int* out_len, int* err):
	if (*pos >= len):
		*err = hpack_error_malformed
		return 0
	int huff = p[*pos] & 128
	int slen = 0
	if (hpack_decode_int(p, len, pos, 7, &slen) == 0):
		*err = hpack_error_malformed
		return 0
	if (slen > len - *pos):
		*err = hpack_error_malformed
		return 0
	char* result = 0
	if (huff != 0):
		# Huffman never expands a byte to fewer than 5 bits, so the
		# decoded length is bounded by slen * 8 / 5 before decoding.
		result = hpack_huffman_decode(p + *pos, slen, d.max_string, out_len)
		if (result == 0):
			if ((slen * 8) / 5 > d.max_string):
				*err = hpack_error_too_large
			else:
				*err = hpack_error_huffman
			return 0
	else:
		if (slen > d.max_string):
			*err = hpack_error_too_large
			return 0
		result = mem_dup(p + *pos, slen)
		*out_len = slen
	*pos = *pos + slen
	return result


/* Decoder */

hpack_decoder* hpack_decoder_new(int max_table_size):
	hpack_decoder* d = new hpack_decoder()
	d.table = hpack_table_new(max_table_size)
	d.settings_max = max_table_size
	d.max_list_size = hpack_default_max_list_size
	d.max_string = hpack_default_max_string
	d.max_headers = hpack_default_max_headers
	return d


# Our advertised SETTINGS_HEADER_TABLE_SIZE: the ceiling for the size
# updates the peer's encoder may send. Lowering it takes effect for the
# peer only once acknowledged; we shrink the table right away as well.
void hpack_decoder_set_max_table_size(hpack_decoder* d, int n):
	d.settings_max = n
	if (d.table.max_size > n):
		hpack_table_set_max(d.table, n)


void hpack_decoder_free(hpack_decoder* d):
	hpack_table_free(d.table)
	free(d)


int hpack_field_ok(char* p, int n, int is_name):
	if ((is_name != 0) && (n == 0)):
		return 0
	for i in range(n):
		int c = p[i] & 255
		if ((c == 0) || (c == 10) || (c == 13)):
			return 0
	return 1


# Resolves a 1-based index over static + dynamic tables. Returns 0 when
# out of range.
hpack_header* hpack_lookup(hpack_decoder* d, int index, hpack_header* scratch):
	if (index <= 0):
		return 0
	if (index <= hpack_static_count):
		scratch.name = hpack_static_name(index)
		scratch.name_len = strlen(scratch.name)
		scratch.value = hpack_static_value(index)
		scratch.value_len = strlen(scratch.value)
		return scratch
	int dyn = index - hpack_static_count
	if (dyn > hpack_table_count(d.table)):
		return 0
	return hpack_table_get(d.table, dyn)


# Appends a decoded field to out after the field/list caps. Takes
# ownership of name and value. Returns an error code.
int hpack_emit(hpack_decoder* d, list[hpack_header*] out, int* list_size, char* name, int name_len, char* value, int value_len, int sensitive):
	if ((hpack_field_ok(name, name_len, 1) == 0) || (hpack_field_ok(value, value_len, 0) == 0)):
		free(name)
		free(value)
		return hpack_error_bad_field
	*list_size = *list_size + name_len + value_len + 32
	if ((*list_size > d.max_list_size) || (out.length >= d.max_headers)):
		free(name)
		free(value)
		return hpack_error_too_large
	hpack_header* h = new hpack_header(name, name_len, value, value_len, sensitive)
	out.push(h)
	return 0


# Decodes one complete header block into out (fields appended in order).
# Returns hpack_error_none() or an error code; on error, out may hold a
# prefix of the fields and the decoder's table state is undefined.
int hpack_decode(hpack_decoder* d, char* block, int len, list[hpack_header*] out):
	int pos = 0
	int list_size = 0
	int seen_field = 0
	hpack_header scratch
	while (pos < len):
		int b = block[pos] & 255
		if ((b & 128) != 0):
			int index = 0
			if (hpack_decode_int(block, len, &pos, 7, &index) == 0):
				return hpack_error_malformed
			hpack_header* h = hpack_lookup(d, index, &scratch)
			if (h == 0):
				return hpack_error_bad_index
			int rc = hpack_emit(d, out, &list_size, mem_dup(h.name, h.name_len), h.name_len, mem_dup(h.value, h.value_len), h.value_len, 0)
			if (rc != 0):
				return rc
			seen_field = 1
		else if ((b & 224) == 32):
			# Dynamic table size update: only before the first field.
			if (seen_field != 0):
				return hpack_error_table_size
			int size = 0
			if (hpack_decode_int(block, len, &pos, 5, &size) == 0):
				return hpack_error_malformed
			if (size > d.settings_max):
				return hpack_error_table_size
			hpack_table_set_max(d.table, size)
		else:
			int prefix = 4
			int add = 0
			int sensitive = 0
			if ((b & 192) == 64):
				prefix = 6
				add = 1
			else if ((b & 240) == 16):
				sensitive = 1
			else if ((b & 240) != 0):
				return hpack_error_malformed
			int name_index = 0
			if (hpack_decode_int(block, len, &pos, prefix, &name_index) == 0):
				return hpack_error_malformed
			char* name = 0
			int name_len = 0
			int err = 0
			if (name_index != 0):
				hpack_header* nh = hpack_lookup(d, name_index, &scratch)
				if (nh == 0):
					return hpack_error_bad_index
				name = mem_dup(nh.name, nh.name_len)
				name_len = nh.name_len
			else:
				name = hpack_decode_string(d, block, len, &pos, &name_len, &err)
				if (name == 0):
					return err
			int value_len = 0
			char* value = hpack_decode_string(d, block, len, &pos, &value_len, &err)
			if (value == 0):
				free(name)
				return err
			if (add != 0):
				hpack_table_add(d.table, name, name_len, value, value_len)
			int rc2 = hpack_emit(d, out, &list_size, name, name_len, value, value_len, sensitive)
			if (rc2 != 0):
				return rc2
			seen_field = 1
	return 0


/* Encoder */

hpack_encoder* hpack_encoder_new(int max_table_size):
	hpack_encoder* e = new hpack_encoder(hpack_table_new(max_table_size), max_table_size, (-1), (-1), 1, 1)
	return e


# The peer's SETTINGS_HEADER_TABLE_SIZE changed to n. The encoder uses
# min(n, its own cap) and signals the change (the smallest size seen,
# then the final one) at the start of the next block (section 4.2).
void hpack_encoder_set_max_table_size(hpack_encoder* e, int n):
	if (n > e.cap):
		n = e.cap
	if ((e.pending_min < 0) || (n < e.pending_min)):
		e.pending_min = n
	e.pending_final = n
	if (n < e.table.max_size):
		hpack_table_set_max(e.table, n)


void hpack_encoder_free(hpack_encoder* e):
	hpack_table_free(e.table)
	free(e)


int hpack_cstr_equal(char* a, char* b, int blen):
	return hpack_bytes_equal(a, strlen(a), b, blen)


# Finds a header in the tables: returns the index of a full match in
# *full (0 when none) and of the first name match in *name_only.
void hpack_find(hpack_encoder* e, hpack_header* h, int* full, int* name_only):
	*full = 0
	*name_only = 0
	int i = 1
	while (i <= hpack_static_count):
		if (hpack_cstr_equal(hpack_static_name(i), h.name, h.name_len) != 0):
			if (*name_only == 0):
				*name_only = i
			if (hpack_cstr_equal(hpack_static_value(i), h.value, h.value_len) != 0):
				*full = i
				return
		i = i + 1
	int n = hpack_table_count(e.table)
	for j in range(1, n + 1):
		hpack_header* t = hpack_table_get(e.table, j)
		if (hpack_bytes_equal(t.name, t.name_len, h.name, h.name_len) != 0):
			if (*name_only == 0):
				*name_only = hpack_static_count + j
			if (hpack_bytes_equal(t.value, t.value_len, h.value, h.value_len) != 0):
				*full = hpack_static_count + j
				return


# Appends one encoded header block for headers to out.
void hpack_encode(hpack_encoder* e, list[hpack_header*] headers, string_builder* out):
	if (e.pending_final >= 0):
		if (e.pending_min < e.pending_final):
			hpack_encode_int(out, 32, 5, e.pending_min)
		hpack_encode_int(out, 32, 5, e.pending_final)
		hpack_table_set_max(e.table, e.pending_final)
		e.pending_min = (-1)
		e.pending_final = (-1)
	for i in range(headers.length):
		hpack_header* h = headers[i]
		int full = 0
		int name_only = 0
		hpack_find(e, h, &full, &name_only)
		if ((full != 0) && (h.sensitive == 0)):
			hpack_encode_int(out, 128, 7, full)
		else:
			if (h.sensitive != 0):
				hpack_encode_int(out, 16, 4, name_only)
			else if (e.indexing != 0):
				hpack_encode_int(out, 64, 6, name_only)
			else:
				hpack_encode_int(out, 0, 4, name_only)
			if (name_only == 0):
				hpack_encode_string(out, h.name, h.name_len, e.huffman)
			hpack_encode_string(out, h.value, h.value_len, e.huffman)
			if ((h.sensitive == 0) && (e.indexing != 0)):
				hpack_table_add(e.table, h.name, h.name_len, h.value, h.value_len)
