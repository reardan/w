# wbuild: name=email_message_test x64
# wbuild: step="bin/email_message_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
# The test_*_table functions after the hand-written tests are generated
# from CPython 3.13 (binascii, base64, email.header, email.message with
# the compat32 policy, policy.default.fold) by the script in the comment
# at the bottom of this file.
import lib.testing
import libs.standard.email.message


# Python's escaping for the dumps: printable ASCII except '\' as is,
# everything else \xNN.
void esc_into(string_builder* sb, char* s, int n):
	char* digits = c"0123456789abcdef"
	if (s == 0):
		string_append_char(sb, '-')
		return
	for i in range(n):
		int c = s[i] & 255
		if ((c >= 32) && (c < 127) && (c != '\\')): string_append_char(sb, c)
		else:
			string_append(sb, c"\\x")
			string_append_char(sb, digits[c >> 4])
			string_append_char(sb, digits[c & 15])


char* esc(char* s, int n):
	string_builder* sb = string_new()
	esc_into(sb, s, n)
	return email_finish(sb, 0)


void esc_cstr(string_builder* sb, char* s):
	if (s == 0): esc_into(sb, 0, 0)
	else: esc_into(sb, s, strlen(s))


# Compares bytes through their escaped form (readable failures); frees got.
void check_bytes(char* want, int want_len, char* got, int got_len):
	char* w = esc(want, want_len)
	char* g = esc(got, got_len)
	assert_strings_equal(w, g)
	free(w)
	free(g)
	free(got)


void check_qp_decode(char* s, int n, int header, char* want, int want_len):
	int got_len = 0
	char* got = email_qp_decode(s, n, header, &got_len)
	check_bytes(want, want_len, got, got_len)


void check_qp_encode(char* s, int n, int quotetabs, int header, char* want, int want_len):
	int got_len = 0
	char* got = email_qp_encode(s, n, quotetabs, header, &got_len)
	check_bytes(want, want_len, got, got_len)
	# Decoding gives the data back (line breaks may change to CRLF).
	for i in range(n):
		if (s[i] == '\r'): return
	int back_len = 0
	char* back = email_qp_decode(want, want_len, header, &back_len)
	check_bytes(s, n, back, back_len)


void check_a2b(char* s, int n, int ok, char* want, int want_len):
	int got_len = 0
	char* got = email_a2b_base64(s, n, &got_len)
	if (!ok):
		assert_equal(0, cast(int, got))
		return
	assert1(got != 0)
	check_bytes(want, want_len, got, got_len)


void check_b64_body(char* s, int n, char* want, int want_len):
	int got_len = 0
	char* got = email_base64_decode(s, n, &got_len)
	check_bytes(want, want_len, got, got_len)


void check_b64_encode(char* data, int n, char* want, int want_len):
	int got_len = 0
	char* got = email_base64_encode_body(data, n, &got_len)
	check_bytes(want, want_len, got, got_len)


void check_decode_header(char* value, char* want):
	list[email_header_chunk*] chunks = email_decode_header(value)
	string_builder* sb = string_new()
	if (chunks == 0): string_append(sb, c"ERROR")
	else:
		for email_header_chunk* c in chunks:
			if (c.charset == 0): string_append_char(sb, '-')
			else: string_append(sb, c.charset)
			string_append_char(sb, '|')
			esc_into(sb, c.data, c.len)
			string_append_char(sb, ';')
		email_header_chunks_free(chunks)
	char* got = email_finish(sb, 0)
	assert_strings_equal(want, got)
	free(got)


void check_header_utf8(char* value, char* want):
	char* got = email_header_to_utf8(value)
	if (want == 0):
		assert_equal(0, cast(int, got))
		return
	assert_strings_equal(want, got)
	free(got)


void check_encode_word(char* data, int n, char* charset, int encoding, char* want):
	char* got = email_header_encode_word(data, n, charset, encoding)
	assert_strings_equal(want, got)
	free(got)


void check_params(char* value, char* want):
	list[email_param*] params = email_parse_params(value)
	string_builder* sb = string_new()
	for email_param* p in params:
		esc_cstr(sb, p.name)
		if (p.extended):
			string_append_char(sb, '*')
			esc_cstr(sb, p.charset)
			string_append_char(sb, '\'')
			esc_cstr(sb, p.language)
			string_append_char(sb, '\'')
		else:
			string_append_char(sb, '=')
		esc_cstr(sb, p.value)
		string_append_char(sb, ';')
	email_params_free(params)
	char* got = email_finish(sb, 0)
	assert_strings_equal(want, got)
	free(got)


void check_fold(char* name, char* value, char* linesep, char* want):
	char* got = email_header_fold(name, value, 0, linesep)
	assert_strings_equal(want, got)
	free(got)
	# Unfolding the folded value gives the value back.
	char* folded_value = email_copy(&want[strlen(name) + 2], strlen(want) - strlen(name) - 2 - strlen(linesep))
	char* back = email_header_unfold(folded_value)
	assert_strings_equal(value, back)
	free(back)
	free(folded_value)


void dump_message(string_builder* sb, email_message* m, int depth):
	char* ctype = email_message_get_content_type(m)
	string_append(sb, c"part ")
	string_append_int(sb, depth)
	string_append(sb, c" type=")
	string_append(sb, ctype)
	string_append(sb, c" default=")
	string_append(sb, email_message_get_default_type(m))
	string_append(sb, c" mp=")
	string_append_int(sb, email_message_is_multipart(m))
	string_append(sb, c"\n unixfrom=")
	esc_cstr(sb, m.unixfrom)
	string_append_char(sb, '\n')
	free(ctype)
	for i in range(email_message_header_count(m)):
		string_append(sb, c" h ")
		esc_cstr(sb, email_message_header_name(m, i))
		string_append_char(sb, '|')
		esc_cstr(sb, email_message_header_value(m, i))
		string_append_char(sb, '\n')
	if (!email_message_is_multipart(m)):
		int n = 0
		char* payload = email_message_get_payload(m, &n)
		string_append(sb, c" payload=")
		esc_into(sb, payload, n)
		string_append_char(sb, '\n')
	string_append(sb, c" preamble=")
	esc_cstr(sb, m.preamble)
	string_append(sb, c" epilogue=")
	esc_cstr(sb, m.epilogue)
	char* boundary = email_message_get_boundary(m)
	char* filename = email_message_get_filename(m)
	char* charset = email_message_get_content_charset(m)
	char* disposition = email_message_get_content_disposition(m)
	string_append(sb, c"\n boundary=")
	esc_cstr(sb, boundary)
	string_append(sb, c" filename=")
	esc_cstr(sb, filename)
	string_append(sb, c" charset=")
	esc_cstr(sb, charset)
	string_append(sb, c" disposition=")
	esc_cstr(sb, disposition)
	string_append(sb, c"\n defects=")
	for i in range(email_message_defect_count(m)):
		if (i > 0): string_append_char(sb, ',')
		string_append(sb, email_message_defect(m, i))
	string_append_char(sb, '\n')
	if (boundary != 0): free(boundary)
	if (filename != 0): free(filename)
	if (charset != 0): free(charset)
	if (disposition != 0): free(disposition)
	if (!email_message_is_multipart(m)):
		int dn = 0
		char* decoded = email_message_get_payload_decoded(m, &dn)
		string_append(sb, c" decoded=")
		esc_into(sb, decoded, dn)
		string_append_char(sb, '\n')
		if (decoded != 0): free(decoded)
	for i in range(email_message_part_count(m)): dump_message(sb, email_message_part(m, i), depth + 1)


void check_message(char* src, int n, char* want):
	email_message* m = email_message_from_bytes(src, n)
	string_builder* sb = string_new()
	dump_message(sb, m, 0)
	char* got = email_finish(sb, 0)
	assert_strings_equal(want, got)
	free(got)
	email_message_free(m)


void check_as_string(char* src, int n, char* linesep, char* want, int want_len):
	email_message* m = email_message_from_bytes(src, n)
	int got_len = 0
	char* got = email_message_as_string(m, linesep, &got_len)
	check_bytes(want, want_len, got, got_len)
	email_message_free(m)


# ---- hand-written tests ----------------------------------------------------------

void test_headers_case_insensitive_and_repeated():
	email_message* m = email_message_from_string(c"Received: one\nTo: a@b\nreceived: two\nRECEIVED: three\n\nbody\n")
	assert_strings_equal(c"one", email_message_get(m, c"RECEIVED"))
	assert1(email_message_has(m, c"to"))
	assert1(!email_message_has(m, c"cc"))
	assert_equal(0, cast(int, email_message_get(m, c"Cc")))
	list[char*] all = email_message_get_all(m, c"received")
	assert_equal(3, all.length)
	assert_strings_equal(c"one", all[0])
	assert_strings_equal(c"two", all[1])
	assert_strings_equal(c"three", all[2])
	all.free()
	list[char*] none = email_message_get_all(m, c"x-missing")
	assert_equal(0, none.length)
	none.free()
	assert_equal(1, email_message_replace_header(m, c"received", c"first"))
	assert_strings_equal(c"Received", email_message_header_name(m, 0))
	assert_strings_equal(c"first", email_message_header_value(m, 0))
	assert_equal(0, email_message_replace_header(m, c"cc", c"x"))
	assert_equal(3, email_message_remove_header(m, c"Received"))
	assert_equal(1, email_message_header_count(m))
	email_message_add_header(m, c"X-New", c"v")
	assert_strings_equal(c"v", email_message_get(m, c"x-new"))
	email_message_free(m)


void test_folding_and_unfolding():
	email_message* m = email_message_from_string(c"Subject: a long\r\n\tfolded\r\n subject\r\n\r\n")
	char* raw = email_message_get(m, c"subject")
	assert_strings_equal(c"a long\r\n\tfolded\r\n subject", raw)
	char* flat = email_header_unfold(raw)
	assert_strings_equal(c"a long\tfolded subject", flat)
	free(flat)
	email_message_free(m)
	char* folded = email_header_fold(c"X", c"aaa bbb ccc", 7, c"\r\n")
	assert_strings_equal(c"X: aaa\r\n bbb\r\n ccc\r\n", folded)
	free(folded)
	# A word longer than the line stays whole.
	folded = email_header_fold(c"X", c"abcdefghij k", 6, c"\n")
	assert_strings_equal(c"X: abcdefghij\n k\n", folded)
	free(folded)


void test_build_and_serialize_multipart():
	email_message* root = email_message_new()
	email_message_add_header(root, c"Subject", c"built")
	email_message_add_header(root, c"Content-Type", c"multipart/mixed")
	email_message* text = email_message_new()
	email_message_add_header(text, c"Content-Type", c"text/plain; charset=utf-8")
	email_message_set_payload(text, c"hello\n", 6)
	email_message* bin = email_message_new()
	email_message_add_header(bin, c"Content-Transfer-Encoding", c"base64")
	char* data = c"\x00\x01\x02binary\xff"
	char* body = email_base64_encode_body(data, 10, 0)
	email_message_set_payload(bin, body, strlen(body))
	free(body)
	email_message_attach(root, text)
	email_message_attach(root, bin)
	int n = 0
	char* out = email_message_as_string(root, c"\r\n", &n)
	char* boundary = email_message_get_boundary(root)
	assert1(boundary != 0)
	email_message* back = email_message_from_bytes(out, n)
	assert_equal(0, email_message_defect_count(back))
	assert_equal(2, email_message_part_count(back))
	char* back_boundary = email_message_get_boundary(back)
	assert_strings_equal(boundary, back_boundary)
	int dn = 0
	char* decoded = email_message_get_payload_decoded(email_message_part(back, 1), &dn)
	check_bytes(data, 10, decoded, dn)
	char* first = email_message_get_payload_decoded(email_message_part(back, 0), &dn)
	check_bytes(c"hello\r\n", 7, first, dn)
	list[email_message*] walked = email_message_walk(back)
	assert_equal(3, walked.length)
	assert1(walked[0] == back)
	walked.free()
	free(boundary)
	free(back_boundary)
	free(out)
	email_message_free(back)
	email_message_free(root)


void test_dates():
	email_message* m = email_message_from_string(c"Date: Fri, 09 Nov 2001\n 01:08:47 -0500\nX-Bad-Date: not a date\n\n")
	datetime dt
	assert_equal(1, email_message_get_date(m, c"date", &dt))
	assert_equal(2001, dt.d.year)
	assert_equal(11, dt.d.month)
	assert_equal(9, dt.d.day)
	assert_equal(1, dt.t.hour)
	assert_equal(8, dt.t.minute)
	assert_equal(47, dt.t.second)
	assert_equal(1, dt.has_offset)
	assert_equal(0 - 18000, dt.utc_offset)
	assert_equal(0, email_message_get_date(m, c"x-bad-date", &dt))
	assert_equal(0, email_message_get_date(m, c"x-missing", &dt))
	email_message_set_date(m, c"Resent-Date", datetime_with_offset(datetime_new(2024, 2, 29, 13, 5, 9, 0), 3600))
	assert_strings_equal(c"Thu, 29 Feb 2024 13:05:09 +0100", email_message_get(m, c"resent-date"))
	email_message_free(m)


void test_header_encode_round_trip():
	char* text = c"Gr\xc3\xbc\xc3\x9fe aus K\xc3\xb6ln, ein ziemlich langer Betreff mit Umlauten \xc3\xa4\xc3\xb6\xc3\xbc und \xe2\x82\xac Zeichen"
	for enc in range(2):
		int encoding = 'b'
		if (enc == 1): encoding = 'q'
		char* words = email_header_encode(text, strlen(text), c"utf-8", encoding)
		# Every encoded word fits RFC 2047's 75 characters.
		int run = 0
		int i = 0
		while (words[i] != 0):
			if (words[i] == ' '): run = 0
			else: run = run + 1
			assert1(run <= 75)
			i = i + 1
		char* back = email_header_to_utf8(words)
		assert_strings_equal(text, back)
		free(back)
		char* folded = email_header_fold(c"Subject", words, 0, c"\r\n")
		email_message* m = email_message_from_string(folded)
		char* decoded = email_header_to_utf8(email_message_get(m, c"subject"))
		assert_strings_equal(text, decoded)
		free(decoded)
		email_message_free(m)
		free(folded)
		free(words)


void test_charset_conversion():
	int n = 0
	char* s = email_charset_to_utf8(c"caf\xe9 \x93q\x94 \x81", 10, c"Windows-1252", &n)
	assert_strings_equal(c"caf\xc3\xa9 \xe2\x80\x9cq\xe2\x80\x9d \xef\xbf\xbd", s)
	free(s)
	s = email_charset_to_utf8(c"caf\xe9", 4, c"latin1", &n)
	assert_strings_equal(c"caf\xc3\xa9", s)
	free(s)
	s = email_charset_to_utf8(c"caf\xe9", 4, c"US-ASCII", &n)
	assert_strings_equal(c"caf\xef\xbf\xbd", s)
	free(s)
	assert_equal(0, cast(int, email_charset_to_utf8(c"x", 1, c"koi8-r", &n)))


void test_get_param():
	email_message* m = email_message_from_string(c"Content-Type: Text/Plain; Charset=\"UTF-8\"; name*=utf-8''na%C3%AFve.txt\n\nx")
	char* cs = email_message_get_param(m, c"charset", c"content-type")
	assert_strings_equal(c"UTF-8", cs)
	free(cs)
	char* name = email_message_get_param(m, c"NAME", c"content-type")
	assert_strings_equal(c"na\xc3\xafve.txt", name)
	free(name)
	assert_equal(0, cast(int, email_message_get_param(m, c"missing", c"content-type")))
	assert_equal(0, cast(int, email_message_get_param(m, c"x", c"content-disposition")))
	char* main = email_message_get_content_maintype(m)
	char* sub = email_message_get_content_subtype(m)
	assert_strings_equal(c"text", main)
	assert_strings_equal(c"plain", sub)
	free(main)
	free(sub)
	email_message_free(m)


void test_qp_decode_table():
	check_qp_decode(c"", 0, 0, c"", 0)
	check_qp_decode(c"", 0, 1, c"", 0)
	check_qp_decode(c"=", 1, 0, c"", 0)
	check_qp_decode(c"=", 1, 1, c"", 0)
	check_qp_decode(c"=4", 2, 0, c"=4", 2)
	check_qp_decode(c"=4", 2, 1, c"=4", 2)
	check_qp_decode(c"=41", 3, 0, c"A", 1)
	check_qp_decode(c"=41", 3, 1, c"A", 1)
	check_qp_decode(c"=4g", 3, 0, c"=4g", 3)
	check_qp_decode(c"=4g", 3, 1, c"=4g", 3)
	check_qp_decode(c"==41", 4, 0, c"=41", 3)
	check_qp_decode(c"==41", 4, 1, c"=41", 3)
	check_qp_decode(c"a=\x0d\x0ab", 5, 0, c"ab", 2)
	check_qp_decode(c"a=\x0d\x0ab", 5, 1, c"ab", 2)
	check_qp_decode(c"a=\x0ab", 4, 0, c"ab", 2)
	check_qp_decode(c"a=\x0ab", 4, 1, c"ab", 2)
	check_qp_decode(c"a=\x0dxyz\x0ab", 8, 0, c"ab", 2)
	check_qp_decode(c"a=\x0dxyz\x0ab", 8, 1, c"ab", 2)
	check_qp_decode(c"a=  \x0ab", 6, 0, c"a=  \x0ab", 6)
	check_qp_decode(c"a=  \x0ab", 6, 1, c"a=  \x0ab", 6)
	check_qp_decode(c"h=E9llo_w=f6rld", 15, 0, c"h\xe9llo_w\xf6rld", 11)
	check_qp_decode(c"h=E9llo_w=f6rld", 15, 1, c"h\xe9llo w\xf6rld", 11)
	check_qp_decode(c"_x_", 3, 0, c"_x_", 3)
	check_qp_decode(c"_x_", 3, 1, c" x ", 3)
	check_qp_decode(c"=\x0d", 2, 0, c"", 0)
	check_qp_decode(c"=\x0d", 2, 1, c"", 0)
	check_qp_decode(c"end=", 4, 0, c"end", 3)
	check_qp_decode(c"end=", 4, 1, c"end", 3)
	check_qp_decode(c"\x0df=\x09\x09_y0=.=.0f\x00.a=f=f0_a0x\x00x", 28, 0, c"\x0df=\x09\x09_y0=.=.0f\x00.a=f\xf0_a0x\x00x", 26)
	check_qp_decode(c"\x0df=\x09\x09_y0=.=.0f\x00.a=f=f0_a0x\x00x", 28, 1, c"\x0df=\x09\x09 y0=.=.0f\x00.a=f\xf0 a0x\x00x", 26)
	check_qp_decode(c"\x0aAy_=_0=_ \x09\x09_z0 \xe9.y\x0aF.y00z.yFa", 30, 0, c"\x0aAy_=_0=_ \x09\x09_z0 \xe9.y\x0aF.y00z.yFa", 30)
	check_qp_decode(c"\x0aAy_=_0=_ \x09\x09_z0 \xe9.y\x0aF.y00z.yFa", 30, 1, c"\x0aAy = 0=  \x09\x09 z0 \xe9.y\x0aF.y00z.yFa", 30)
	check_qp_decode(c"\x09\x0d\x0a.x.xa\x0a\x0d\xe9\x0dxx 9=\x09FzA\xe99a", 24, 0, c"\x09\x0d\x0a.x.xa\x0a\x0d\xe9\x0dxx 9=\x09FzA\xe99a", 24)
	check_qp_decode(c"\x09\x0d\x0a.x.xa\x0a\x0d\xe9\x0dxx 9=\x09FzA\xe99a", 24, 1, c"\x09\x0d\x0a.x.xa\x0a\x0d\xe9\x0dxx 9=\x09FzA\xe99a", 24)
	check_qp_decode(c"==\xe9\x0d\x009y\x0d.9\x0d x0", 14, 0, c"=\xe9\x0d\x009y\x0d.9\x0d x0", 13)
	check_qp_decode(c"==\xe9\x0d\x009y\x0d.9\x0d x0", 14, 1, c"=\xe9\x0d\x009y\x0d.9\x0d x0", 13)
	check_qp_decode(c"\x0d===\x09a.x\x0a za\xe9\xe9f==0A=\x0af9x_ ", 26, 0, c"\x0d==\x09a.x\x0a za\xe9\xe9f=0Af9x_ ", 22)
	check_qp_decode(c"\x0d===\x09a.x\x0a za\xe9\xe9f==0A=\x0af9x_ ", 26, 1, c"\x0d==\x09a.x\x0a za\xe9\xe9f=0Af9x  ", 22)
	check_qp_decode(c"f_a9\x0a\x0a=zyx a0\x00ffFfF\x00 a=\x0a0y", 26, 0, c"f_a9\x0a\x0a=zyx a0\x00ffFfF\x00 a0y", 24)
	check_qp_decode(c"f_a9\x0a\x0a=zyx a0\x00ffFfF\x00 a=\x0a0y", 26, 1, c"f a9\x0a\x0a=zyx a0\x00ffFfF\x00 a0y", 24)
	check_qp_decode(c"9\xe909\xe9\x00\x0a\x09f.aaxy", 14, 0, c"9\xe909\xe9\x00\x0a\x09f.aaxy", 14)
	check_qp_decode(c"9\xe909\xe9\x00\x0a\x09f.aaxy", 14, 1, c"9\xe909\xe9\x00\x0a\x09f.aaxy", 14)
	check_qp_decode(c"\x09Az\x09\x0d0yf=.A_\x0a\xe9\x090f", 17, 0, c"\x09Az\x09\x0d0yf=.A_\x0a\xe9\x090f", 17)
	check_qp_decode(c"\x09Az\x09\x0d0yf=.A_\x0a\xe9\x090f", 17, 1, c"\x09Az\x09\x0d0yf=.A \x0a\xe9\x090f", 17)
	check_qp_decode(c"_\x0dxx ", 5, 0, c"_\x0dxx ", 5)
	check_qp_decode(c"_\x0dxx ", 5, 1, c" \x0dxx ", 5)
	check_qp_decode(c"az=x9yzA0\x0aF\x0a\x0df_F", 16, 0, c"az=x9yzA0\x0aF\x0a\x0df_F", 16)
	check_qp_decode(c"az=x9yzA0\x0aF\x0a\x0df_F", 16, 1, c"az=x9yzA0\x0aF\x0a\x0df F", 16)
	check_qp_decode(c"Ffaxxf=_\x00\x00.=\x0d\x09f\xe9y=A\x00\x0a=\x0aFAf\x0a9zy", 30, 0, c"Ffaxxf=_\x00\x00.FAf\x0a9zy", 18)
	check_qp_decode(c"Ffaxxf=_\x00\x00.=\x0d\x09f\xe9y=A\x00\x0a=\x0aFAf\x0a9zy", 30, 1, c"Ffaxxf= \x00\x00.FAf\x0a9zy", 18)
	check_qp_decode(c"9\x0d\x0dz==xy\x0d", 9, 0, c"9\x0d\x0dz=xy\x0d", 8)
	check_qp_decode(c"9\x0d\x0dz==xy\x0d", 9, 1, c"9\x0d\x0dz=xy\x0d", 8)
	check_qp_decode(c"a\x00.\x0a=_=yyx \x0a\x0aA_. ._f0", 21, 0, c"a\x00.\x0a=_=yyx \x0a\x0aA_. ._f0", 21)
	check_qp_decode(c"a\x00.\x0a=_=yyx \x0a\x0aA_. ._f0", 21, 1, c"a\x00.\x0a= =yyx \x0a\x0aA . . f0", 21)
	check_qp_decode(c"Fy\x00z\x0a==y\x00F\x09a0y=f\x000Fa0y=z=F=..", 29, 0, c"Fy\x00z\x0a=y\x00F\x09a0y=f\x000Fa0y=z=F=..", 28)
	check_qp_decode(c"Fy\x00z\x0a==y\x00F\x09a0y=f\x000Fa0y=z=F=..", 29, 1, c"Fy\x00z\x0a=y\x00F\x09a0y=f\x000Fa0y=z=F=..", 28)
	check_qp_decode(c"\xe9Axx", 4, 0, c"\xe9Axx", 4)
	check_qp_decode(c"\xe9Axx", 4, 1, c"\xe9Axx", 4)
	check_qp_decode(c"x\xe9\x0ay\x09zF=9\xe9ax\x0a9f", 15, 0, c"x\xe9\x0ay\x09zF=9\xe9ax\x0a9f", 15)
	check_qp_decode(c"x\xe9\x0ay\x09zF=9\xe9ax\x0a9f", 15, 1, c"x\xe9\x0ay\x09zF=9\xe9ax\x0a9f", 15)
	check_qp_decode(c" 9 _=\x00y90\x0a.0_\x00_ax\xe9=\x0aF\x0aa", 23, 0, c" 9 _=\x00y90\x0a.0_\x00_ax\xe9F\x0aa", 21)
	check_qp_decode(c" 9 _=\x00y90\x0a.0_\x00_ax\xe9=\x0aF\x0aa", 23, 1, c" 9  =\x00y90\x0a.0 \x00 ax\xe9F\x0aa", 21)
	check_qp_decode(c"= \x0d \xe9=\x0ax_ y\x0dx\x0aafz\x0a.._\x0d\x0aFzF0.\x0d", 29, 0, c"= \x0d \xe9x_ y\x0dx\x0aafz\x0a.._\x0d\x0aFzF0.\x0d", 27)
	check_qp_decode(c"= \x0d \xe9=\x0ax_ y\x0dx\x0aafz\x0a.._\x0d\x0aFzF0.\x0d", 29, 1, c"= \x0d \xe9x  y\x0dx\x0aafz\x0a.. \x0d\x0aFzF0.\x0d", 27)
	check_qp_decode(c"=y\x00A af .x\x0ay\x0d.aay=z\xe9\x09", 21, 0, c"=y\x00A af .x\x0ay\x0d.aay=z\xe9\x09", 21)
	check_qp_decode(c"=y\x00A af .x\x0ay\x0d.aay=z\xe9\x09", 21, 1, c"=y\x00A af .x\x0ay\x0d.aay=z\xe9\x09", 21)
	check_qp_decode(c"yz =.9\xe9\x0aaA\x09=FA", 14, 0, c"yz =.9\xe9\x0aaA\x09\xfa", 12)
	check_qp_decode(c"yz =.9\xe9\x0aaA\x09=FA", 14, 1, c"yz =.9\xe9\x0aaA\x09\xfa", 12)
	check_qp_decode(c"9 x0\x0dFxA0 \x0dy=_=F", 16, 0, c"9 x0\x0dFxA0 \x0dy=_=F", 16)
	check_qp_decode(c"9 x0\x0dFxA0 \x0dy=_=F", 16, 1, c"9 x0\x0dFxA0 \x0dy= =F", 16)
	check_qp_decode(c".x=\x0dAaf  ", 9, 0, c".x", 2)
	check_qp_decode(c".x=\x0dAaf  ", 9, 1, c".x", 2)
	check_qp_decode(c"yyaA 0= \x0d0_=a\x0dx9\x0ayF.AfF.0A\x00\x0dA\xe9", 30, 0, c"yyaA 0= \x0d0_=a\x0dx9\x0ayF.AfF.0A\x00\x0dA\xe9", 30)
	check_qp_decode(c"yyaA 0= \x0d0_=a\x0dx9\x0ayF.AfF.0A\x00\x0dA\xe9", 30, 1, c"yyaA 0= \x0d0 =a\x0dx9\x0ayF.AfF.0A\x00\x0dA\xe9", 30)
	check_qp_decode(c"\x00\x09a=\x0a\xe9_yay\x000z\x0d_.\x09A\x0a ==\x00aa==", 27, 0, c"\x00\x09a\xe9_yay\x000z\x0d_.\x09A\x0a =\x00aa=", 23)
	check_qp_decode(c"\x00\x09a=\x0a\xe9_yay\x000z\x0d_.\x09A\x0a ==\x00aa==", 27, 1, c"\x00\x09a\xe9 yay\x000z\x0d .\x09A\x0a =\x00aa=", 23)
	check_qp_decode(c"ya", 2, 0, c"ya", 2)
	check_qp_decode(c"ya", 2, 1, c"ya", 2)
	check_qp_decode(c"xa\x0d\x0a0xa\x0a\x09", 9, 0, c"xa\x0d\x0a0xa\x0a\x09", 9)
	check_qp_decode(c"xa\x0d\x0a0xa\x0a\x09", 9, 1, c"xa\x0d\x0a0xa\x0a\x09", 9)
	check_qp_decode(c"\x0d=\xe99 =zxf\xe9_", 11, 0, c"\x0d=\xe99 =zxf\xe9_", 11)
	check_qp_decode(c"\x0d=\xe99 =zxf\xe9_", 11, 1, c"\x0d=\xe99 =zxf\xe9 ", 11)
	check_qp_decode(c".=_\xe9xfAzaa=fyy0\x0a\x0azAf.A", 22, 0, c".=_\xe9xfAzaa=fyy0\x0a\x0azAf.A", 22)
	check_qp_decode(c".=_\xe9xfAzaa=fyy0\x0a\x0azAf.A", 22, 1, c".= \xe9xfAzaa=fyy0\x0a\x0azAf.A", 22)
	check_qp_decode(c"fz.ya 0_\x00\x0a=y\x0az=\x0d.= a.\xe9Aa=0", 26, 0, c"fz.ya 0_\x00\x0a=y\x0az", 14)
	check_qp_decode(c"fz.ya 0_\x00\x0a=y\x0az=\x0d.= a.\xe9Aa=0", 26, 1, c"fz.ya 0 \x00\x0a=y\x0az", 14)
	check_qp_decode(c"\x00=F \x00_AaA0F0._Fx_9_ \x0d\x0aazAA_", 27, 0, c"\x00=F \x00_AaA0F0._Fx_9_ \x0d\x0aazAA_", 27)
	check_qp_decode(c"\x00=F \x00_AaA0F0._Fx_9_ \x0d\x0aazAA_", 27, 1, c"\x00=F \x00 AaA0F0. Fx 9  \x0d\x0aazAA ", 27)
	check_qp_decode(c"0\xe9\x00yzA.\x09_x", 10, 0, c"0\xe9\x00yzA.\x09_x", 10)
	check_qp_decode(c"0\xe9\x00yzA.\x09_x", 10, 1, c"0\xe9\x00yzA.\x09 x", 10)
	check_qp_decode(c"9_z\xe9\x00\x0a\xe9Fy \x0a\x09\x00\x0d\x09 yF=a\x00x=F", 24, 0, c"9_z\xe9\x00\x0a\xe9Fy \x0a\x09\x00\x0d\x09 yF=a\x00x=F", 24)
	check_qp_decode(c"9_z\xe9\x00\x0a\xe9Fy \x0a\x09\x00\x0d\x09 yF=a\x00x=F", 24, 1, c"9 z\xe9\x00\x0a\xe9Fy \x0a\x09\x00\x0d\x09 yF=a\x00x=F", 24)
	check_qp_decode(c"aA==.=f=f\xe9=9z", 13, 0, c"aA=.=f=f\xe9=9z", 12)
	check_qp_decode(c"aA==.=f=f\xe9=9z", 13, 1, c"aA=.=f=f\xe9=9z", 12)
	check_qp_decode(c".=\x099=\x0dz\x0d.y", 10, 0, c".=\x099", 4)
	check_qp_decode(c".=\x099=\x0dz\x0d.y", 10, 1, c".=\x099", 4)
	check_qp_decode(c"=_.\xe9x=x\x00 A", 10, 0, c"=_.\xe9x=x\x00 A", 10)
	check_qp_decode(c"=_.\xe9x=x\x00 A", 10, 1, c"= .\xe9x=x\x00 A", 10)
	check_qp_decode(c"\x0axf.A.\x00x\xe9Aff_9", 14, 0, c"\x0axf.A.\x00x\xe9Aff_9", 14)
	check_qp_decode(c"\x0axf.A.\x00x\xe9Aff_9", 14, 1, c"\x0axf.A.\x00x\xe9Aff 9", 14)
	check_qp_decode(c"\xe99=", 3, 0, c"\xe99", 2)
	check_qp_decode(c"\xe99=", 3, 1, c"\xe99", 2)
	check_qp_decode(c"F_\x00zz\x00\x00xx=F90F.F Fa_=A0\x0d_FFAz=", 30, 0, c"F_\x00zz\x00\x00xx\xf90F.F Fa_\xa0\x0d_FFAz", 25)
	check_qp_decode(c"F_\x00zz\x00\x00xx=F90F.F Fa_=A0\x0d_FFAz=", 30, 1, c"F \x00zz\x00\x00xx\xf90F.F Fa \xa0\x0d FFAz", 25)
	check_qp_decode(c"x\x09=", 3, 0, c"x\x09", 2)
	check_qp_decode(c"x\x09=", 3, 1, c"x\x09", 2)
	check_qp_decode(c"=\xe9\x0d0", 4, 0, c"=\xe9\x0d0", 4)
	check_qp_decode(c"=\xe9\x0d0", 4, 1, c"=\xe9\x0d0", 4)

void test_qp_encode_table():
	check_qp_encode(c"", 0, 0, 0, c"", 0)
	check_qp_encode(c"", 0, 0, 1, c"", 0)
	check_qp_encode(c"", 0, 1, 0, c"", 0)
	check_qp_encode(c"", 0, 1, 1, c"", 0)
	check_qp_encode(c"hello world", 11, 0, 0, c"hello world", 11)
	check_qp_encode(c"hello world", 11, 0, 1, c"hello_world", 11)
	check_qp_encode(c"hello world", 11, 1, 0, c"hello=20world", 13)
	check_qp_encode(c"hello world", 11, 1, 1, c"hello=20world", 13)
	check_qp_encode(c"trailing space ", 15, 0, 0, c"trailing space=20", 17)
	check_qp_encode(c"trailing space ", 15, 0, 1, c"trailing_space=20", 17)
	check_qp_encode(c"trailing space ", 15, 1, 0, c"trailing=20space=20", 19)
	check_qp_encode(c"trailing space ", 15, 1, 1, c"trailing=20space=20", 19)
	check_qp_encode(c"trailing tab\x09", 13, 0, 0, c"trailing tab=09", 15)
	check_qp_encode(c"trailing tab\x09", 13, 0, 1, c"trailing_tab=09", 15)
	check_qp_encode(c"trailing tab\x09", 13, 1, 0, c"trailing=20tab=09", 17)
	check_qp_encode(c"trailing tab\x09", 13, 1, 1, c"trailing=20tab=09", 17)
	check_qp_encode(c"line one \x0aline two\x09\x0a", 20, 0, 0, c"line one=20\x0aline two=09\x0a", 24)
	check_qp_encode(c"line one \x0aline two\x09\x0a", 20, 0, 1, c"line_one_\x0aline_two=09\x0a", 22)
	check_qp_encode(c"line one \x0aline two\x09\x0a", 20, 1, 0, c"line=20one=20\x0aline=20two=09\x0a", 28)
	check_qp_encode(c"line one \x0aline two\x09\x0a", 20, 1, 1, c"line=20one=20\x0aline=20two=09\x0a", 28)
	check_qp_encode(c"crlf line \x0d\x0anext", 16, 0, 0, c"crlf line=20\x0d\x0anext", 18)
	check_qp_encode(c"crlf line \x0d\x0anext", 16, 0, 1, c"crlf_line_\x0d\x0anext", 16)
	check_qp_encode(c"crlf line \x0d\x0anext", 16, 1, 0, c"crlf=20line=20\x0d\x0anext", 20)
	check_qp_encode(c"crlf line \x0d\x0anext", 16, 1, 1, c"crlf=20line=20\x0d\x0anext", 20)
	check_qp_encode(c".", 1, 0, 0, c"=2E", 3)
	check_qp_encode(c".", 1, 0, 1, c"=2E", 3)
	check_qp_encode(c".", 1, 1, 0, c"=2E", 3)
	check_qp_encode(c".", 1, 1, 1, c"=2E", 3)
	check_qp_encode(c".\x0a.x\x0a", 5, 0, 0, c"=2E\x0a.x\x0a", 7)
	check_qp_encode(c".\x0a.x\x0a", 5, 0, 1, c"=2E\x0a.x\x0a", 7)
	check_qp_encode(c".\x0a.x\x0a", 5, 1, 0, c"=2E\x0a.x\x0a", 7)
	check_qp_encode(c".\x0a.x\x0a", 5, 1, 1, c"=2E\x0a.x\x0a", 7)
	check_qp_encode(c"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 200, 0, 0, c"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=\x0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=\x0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 204)
	check_qp_encode(c"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 200, 0, 1, c"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=\x0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=\x0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 204)
	check_qp_encode(c"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 200, 1, 0, c"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=\x0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=\x0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 204)
	check_qp_encode(c"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 200, 1, 1, c"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=\x0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=\x0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 204)
	check_qp_encode(c"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\x0acccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\x0addddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", 230, 0, 0, c"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\x0acccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\x0addddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd=\x0add", 232)
	check_qp_encode(c"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\x0acccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\x0addddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", 230, 0, 1, c"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\x0acccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\x0addddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd=\x0add", 232)
	check_qp_encode(c"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\x0acccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\x0addddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", 230, 1, 0, c"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\x0acccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\x0addddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd=\x0add", 232)
	check_qp_encode(c"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\x0acccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\x0addddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", 230, 1, 1, c"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\x0acccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\x0addddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd=\x0add", 232)
	check_qp_encode(c"========================================", 40, 0, 0, c"=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=\x0a=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D", 122)
	check_qp_encode(c"========================================", 40, 0, 1, c"=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=\x0a=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D", 122)
	check_qp_encode(c"========================================", 40, 1, 0, c"=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=\x0a=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D", 122)
	check_qp_encode(c"========================================", 40, 1, 1, c"=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=\x0a=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D=3D", 122)
	check_qp_encode(c"caf\xe9 = ok", 9, 0, 0, c"caf=E9 =3D ok", 13)
	check_qp_encode(c"caf\xe9 = ok", 9, 0, 1, c"caf=E9_=3D_ok", 13)
	check_qp_encode(c"caf\xe9 = ok", 9, 1, 0, c"caf=E9=20=3D=20ok", 17)
	check_qp_encode(c"caf\xe9 = ok", 9, 1, 1, c"caf=E9=20=3D=20ok", 17)
	check_qp_encode(c"under_score and space", 21, 0, 0, c"under_score and space", 21)
	check_qp_encode(c"under_score and space", 21, 0, 1, c"under=5Fscore_and_space", 23)
	check_qp_encode(c"under_score and space", 21, 1, 0, c"under_score=20and=20space", 25)
	check_qp_encode(c"under_score and space", 21, 1, 1, c"under=5Fscore=20and=20space", 27)
	check_qp_encode(c"x\x0dy", 3, 0, 0, c"x\x0dy", 3)
	check_qp_encode(c"x\x0dy", 3, 0, 1, c"x\x0dy", 3)
	check_qp_encode(c"x\x0dy", 3, 1, 0, c"x\x0dy", 3)
	check_qp_encode(c"x\x0dy", 3, 1, 1, c"x\x0dy", 3)
	check_qp_encode(c"mixed\x0d\x0aand\x0alf\x0a", 14, 0, 0, c"mixed\x0d\x0aand\x0d\x0alf\x0d\x0a", 16)
	check_qp_encode(c"mixed\x0d\x0aand\x0alf\x0a", 14, 0, 1, c"mixed\x0d\x0aand\x0d\x0alf\x0d\x0a", 16)
	check_qp_encode(c"mixed\x0d\x0aand\x0alf\x0a", 14, 1, 0, c"mixed\x0d\x0aand\x0d\x0alf\x0d\x0a", 16)
	check_qp_encode(c"mixed\x0d\x0aand\x0alf\x0a", 14, 1, 1, c"mixed\x0d\x0aand\x0d\x0alf\x0d\x0a", 16)
	check_qp_encode(c"\x0d_.._~c\x09.~c.\xff\x09.c\x0a \xff\x09\x09\x0a~. _\xff\x0d\x0d~b==_\x0ab_~\x0a~==\x0d\xff\x01\x01=_\x0a\x0ac\xff\xff \x01\x01a_c__=ccaa", 66, 0, 0, c"\x0d_.._~c\x09.~c.=FF\x09.c\x0a =FF\x09=09\x0a~. _=FF\x0d\x0d~b=3D=3D_\x0ab_~\x0a~=3D=3D\x0d=FF=01=01=3D_\x0a\x0ac=FF=FF =01=01a_c__=3Dccaa", 100)
	check_qp_encode(c"\x0d_.._~c\x09.~c.\xff\x09.c\x0a \xff\x09\x09\x0a~. _\xff\x0d\x0d~b==_\x0ab_~\x0a~==\x0d\xff\x01\x01=_\x0a\x0ac\xff\xff \x01\x01a_c__=ccaa", 66, 0, 1, c"\x0d=5F..=5F~c\x09.~c.=FF\x09.c\x0a_=FF\x09=09\x0a~._=5F=FF\x0d\x0d~b=3D=3D=5F\x0ab=5F~\x0a~=3D=3D\x0d=FF=01=01=3D=5F\x0a\x0ac=FF=FF_=01=01a=5Fc=5F=5F=3Dccaa", 118)
	check_qp_encode(c"\x0d_.._~c\x09.~c.\xff\x09.c\x0a \xff\x09\x09\x0a~. _\xff\x0d\x0d~b==_\x0ab_~\x0a~==\x0d\xff\x01\x01=_\x0a\x0ac\xff\xff \x01\x01a_c__=ccaa", 66, 1, 0, c"\x0d_.._~c=09.~c.=FF=09.c\x0a=20=FF=09=09\x0a~.=20_=FF\x0d\x0d~b=3D=3D_\x0ab_~\x0a~=3D=3D\x0d=FF=01=01=3D_\x0a\x0ac=FF=FF=20=01=01a_c__=3Dccaa", 112)
	check_qp_encode(c"\x0d_.._~c\x09.~c.\xff\x09.c\x0a \xff\x09\x09\x0a~. _\xff\x0d\x0d~b==_\x0ab_~\x0a~==\x0d\xff\x01\x01=_\x0a\x0ac\xff\xff \x01\x01a_c__=ccaa", 66, 1, 1, c"\x0d=5F..=5F~c=09.~c.=FF=09.c\x0a=20=FF=09=09\x0a~.=20=5F=FF\x0d\x0d~b=3D=3D=5F\x0ab=5F~\x0a~=3D=3D\x0d=FF=01=01=3D=5F\x0a\x0ac=FF=FF=20=01=01a=5Fc=5F=5F=3Dccaa", 130)
	check_qp_encode(c"~ca_\x0dc\x09\x0a.= \xffb =b\x0d\x0aa=.\x09c\x0d= ~bc =\x09\x01~c\x09  c\x01\x0d_a_ \x09\xff\x09\x01\x09 \xff\x09aa...\x0a._\xff \xff=\x09\x0d\x01~_b _\x01\x09.\x0a\x09\x0a=\x0a\x01\x0a_a\x0d=ab=\x09_\x09=~c\x01._\x0a=~", 102, 0, 0, c"~ca_\x0dc=09\x0a.=3D =FFb =3Db\x0aa=3D.\x09c\x0d=3D ~bc =3D\x09=01~c\x09  c=01\x0d_a_ \x09=FF\x09=01\x09 =FF\x09aa...\x0a._=FF =FF=3D\x09\x0d=01~_b _=01\x09.\x0a=09\x0a=3D\x0a=01\x0a_a\x0d=3Dab=3D\x09_\x09=3D~c=01._\x0a=3D~", 151)
	check_qp_encode(c"~ca_\x0dc\x09\x0a.= \xffb =b\x0d\x0aa=.\x09c\x0d= ~bc =\x09\x01~c\x09  c\x01\x0d_a_ \x09\xff\x09\x01\x09 \xff\x09aa...\x0a._\xff \xff=\x09\x0d\x01~_b _\x01\x09.\x0a\x09\x0a=\x0a\x01\x0a_a\x0d=ab=\x09_\x09=~c\x01._\x0a=~", 102, 0, 1, c"~ca=5F\x0dc=09\x0a.=3D_=FFb_=3Db\x0aa=3D.\x09c\x0d=3D_~bc_=3D\x09=01~c\x09__c=01\x0d=5Fa=5F_\x09=FF\x09=01\x09_=FF\x09aa...\x0a.=5F=FF_=FF=3D\x09\x0d=01~=5Fb_=5F=01\x09.\x0a=09\x0a=3D\x0a=01\x0a=5Fa\x0d=3Dab=3D\x09=5F\x09=3D~c=01.=5F\x0a=3D~", 169)
	check_qp_encode(c"~ca_\x0dc\x09\x0a.= \xffb =b\x0d\x0aa=.\x09c\x0d= ~bc =\x09\x01~c\x09  c\x01\x0d_a_ \x09\xff\x09\x01\x09 \xff\x09aa...\x0a._\xff \xff=\x09\x0d\x01~_b _\x01\x09.\x0a\x09\x0a=\x0a\x01\x0a_a\x0d=ab=\x09_\x09=~c\x01._\x0a=~", 102, 1, 0, c"~ca_\x0dc=09\x0a.=3D=20=FFb=20=3Db\x0aa=3D.=09c\x0d=3D=20~bc=20=3D=09=01~c=09=20=20c=01\x0d_a_=20=09=FF=09=01=09=20=FF=\x0a=09aa...\x0a._=FF=20=FF=3D=09\x0d=01~_b=20_=01=09.\x0a=09\x0a=3D\x0a=01\x0a_a\x0d=3Dab=3D=09_=09=3D~c=01._\x0a=3D~", 195)
	check_qp_encode(c"~ca_\x0dc\x09\x0a.= \xffb =b\x0d\x0aa=.\x09c\x0d= ~bc =\x09\x01~c\x09  c\x01\x0d_a_ \x09\xff\x09\x01\x09 \xff\x09aa...\x0a._\xff \xff=\x09\x0d\x01~_b _\x01\x09.\x0a\x09\x0a=\x0a\x01\x0a_a\x0d=ab=\x09_\x09=~c\x01._\x0a=~", 102, 1, 1, c"~ca=5F\x0dc=09\x0a.=3D=20=FFb=20=3Db\x0aa=3D.=09c\x0d=3D=20~bc=20=3D=09=01~c=09=20=20c=01\x0d=5Fa=5F=20=09=FF=09=01=09=20=\x0a=FF=09aa...\x0a.=5F=FF=20=FF=3D=09\x0d=01~=5Fb=20=5F=01=09.\x0a=09\x0a=3D\x0a=01\x0a=5Fa\x0d=3Dab=3D=09=5F=09=3D~c=01.=5F\x0a=3D~", 213)
	check_qp_encode(c"~b=c.\x09c_ccc=a\x01b.\x0d\x01a\xff.b~\xff~.\xff.\x09\xff\x0a~\xff\x01=b=b\x01\x0d\x0a ", 42, 0, 0, c"~b=3Dc.\x09c_ccc=3Da=01b.\x0d=01a=FF.b~=FF~.=FF.\x09=FF\x0a~=FF=01=3Db=3Db=01\x0a=20", 69)
	check_qp_encode(c"~b=c.\x09c_ccc=a\x01b.\x0d\x01a\xff.b~\xff~.\xff.\x09\xff\x0a~\xff\x01=b=b\x01\x0d\x0a ", 42, 0, 1, c"~b=3Dc.\x09c=5Fccc=3Da=01b.\x0d=01a=FF.b~=FF~.=FF.\x09=FF\x0a~=FF=01=3Db=3Db=01\x0a=20", 71)
	check_qp_encode(c"~b=c.\x09c_ccc=a\x01b.\x0d\x01a\xff.b~\xff~.\xff.\x09\xff\x0a~\xff\x01=b=b\x01\x0d\x0a ", 42, 1, 0, c"~b=3Dc.=09c_ccc=3Da=01b.\x0d=01a=FF.b~=FF~.=FF.=09=FF\x0a~=FF=01=3Db=3Db=01\x0a=20", 73)
	check_qp_encode(c"~b=c.\x09c_ccc=a\x01b.\x0d\x01a\xff.b~\xff~.\xff.\x09\xff\x0a~\xff\x01=b=b\x01\x0d\x0a ", 42, 1, 1, c"~b=3Dc.=09c=5Fccc=3Da=01b.\x0d=01a=FF.b~=FF~.=FF.=09=FF\x0a~=FF=01=3Db=3Db=01\x0a=20", 75)
	check_qp_encode(c"=\xff~\x09\xff\x0d_\x09aab_\x09bb\x01\x0dc\x01\x0a b\xff.._=b~ .\x09\x0d\x09~.=\xffca\x0d._a\xffb=\x0a=_\x0d", 51, 0, 0, c"=3D=FF~\x09=FF\x0d_\x09aab_\x09bb=01\x0dc=01\x0a b=FF.._=3Db~ .\x09\x0d\x09~.=3D=FFca\x0d._a=FFb=3D\x0a=3D_\x0d", 75)
	check_qp_encode(c"=\xff~\x09\xff\x0d_\x09aab_\x09bb\x01\x0dc\x01\x0a b\xff.._=b~ .\x09\x0d\x09~.=\xffca\x0d._a\xffb=\x0a=_\x0d", 51, 0, 1, c"=3D=FF~\x09=FF\x0d=5F\x09aab=5F\x09bb=01\x0dc=01\x0a_b=FF..=5F=3Db~_.\x09\x0d\x09~.=3D=FFca\x0d.=5Fa=FFb=3D\x0a=3D=5F\x0d", 85)
	check_qp_encode(c"=\xff~\x09\xff\x0d_\x09aab_\x09bb\x01\x0dc\x01\x0a b\xff.._=b~ .\x09\x0d\x09~.=\xffca\x0d._a\xffb=\x0a=_\x0d", 51, 1, 0, c"=3D=FF~=09=FF\x0d_=09aab_=09bb=01\x0dc=01\x0a=20b=FF.._=3Db~=20.=09\x0d=09~.=3D=FFca\x0d._a=FFb=3D\x0a=3D_\x0d", 89)
	check_qp_encode(c"=\xff~\x09\xff\x0d_\x09aab_\x09bb\x01\x0dc\x01\x0a b\xff.._=b~ .\x09\x0d\x09~.=\xffca\x0d._a\xffb=\x0a=_\x0d", 51, 1, 1, c"=3D=FF~=09=FF\x0d=5F=09aab=5F=09bb=01\x0dc=01\x0a=20b=FF..=5F=3Db~=20.=09\x0d=09~.=3D=FFca\x0d.=5Fa=FFb=3D\x0a=3D=5F\x0d", 99)
	check_qp_encode(c"\x01ba\xff\x0d\x0d  \x0d\x0d\xff_\x0d\x01\x0a_a=b_b", 21, 0, 0, c"=01ba=FF\x0d\x0d  \x0d\x0d=FF_\x0d=01\x0a_a=3Db_b", 31)
	check_qp_encode(c"\x01ba\xff\x0d\x0d  \x0d\x0d\xff_\x0d\x01\x0a_a=b_b", 21, 0, 1, c"=01ba=FF\x0d\x0d__\x0d\x0d=FF=5F\x0d=01\x0a=5Fa=3Db=5Fb", 37)
	check_qp_encode(c"\x01ba\xff\x0d\x0d  \x0d\x0d\xff_\x0d\x01\x0a_a=b_b", 21, 1, 0, c"=01ba=FF\x0d\x0d=20=20\x0d\x0d=FF_\x0d=01\x0a_a=3Db_b", 35)
	check_qp_encode(c"\x01ba\xff\x0d\x0d  \x0d\x0d\xff_\x0d\x01\x0a_a=b_b", 21, 1, 1, c"=01ba=FF\x0d\x0d=20=20\x0d\x0d=FF=5F\x0d=01\x0a=5Fa=3Db=5Fb", 41)
	check_qp_encode(c" \x0da\x0ac.\x0a\x0a~_c .ac\xffc\x0d", 18, 0, 0, c" \x0da\x0ac.\x0a\x0a~_c .ac=FFc\x0d", 20)
	check_qp_encode(c" \x0da\x0ac.\x0a\x0a~_c .ac\xffc\x0d", 18, 0, 1, c"_\x0da\x0ac.\x0a\x0a~=5Fc_.ac=FFc\x0d", 22)
	check_qp_encode(c" \x0da\x0ac.\x0a\x0a~_c .ac\xffc\x0d", 18, 1, 0, c"=20\x0da\x0ac.\x0a\x0a~_c=20.ac=FFc\x0d", 24)
	check_qp_encode(c" \x0da\x0ac.\x0a\x0a~_c .ac\xffc\x0d", 18, 1, 1, c"=20\x0da\x0ac.\x0a\x0a~=5Fc=20.ac=FFc\x0d", 26)
	check_qp_encode(c"\x0d\xffa\x0d\x09\x01 b_\x01~\x01\x01=a\x0a\xffcc=\x0d==\x0d~ a\x01b\x0d_\x09bb\xff.~\x01\x01=\xffa~\x0ac\x01.\x01\x0a \xffbb\xffc~.\x01b _c_a\x0a .\x0a\x01", 69, 0, 0, c"\x0d=FFa\x0d\x09=01 b_=01~=01=01=3Da\x0a=FFcc=3D\x0d=3D=3D\x0d~ a=01b\x0d_\x09bb=FF.~=01=01=3D=FFa~\x0ac=01.=01\x0a =FFbb=FFc~.=01b _c_a\x0a .\x0a=01", 113)
	check_qp_encode(c"\x0d\xffa\x0d\x09\x01 b_\x01~\x01\x01=a\x0a\xffcc=\x0d==\x0d~ a\x01b\x0d_\x09bb\xff.~\x01\x01=\xffa~\x0ac\x01.\x01\x0a \xffbb\xffc~.\x01b _c_a\x0a .\x0a\x01", 69, 0, 1, c"\x0d=FFa\x0d\x09=01_b=5F=01~=01=01=3Da\x0a=FFcc=3D\x0d=3D=3D\x0d~_a=01b\x0d=5F\x09bb=FF.~=01=01=3D=FFa~\x0ac=01.=01\x0a_=FFbb=FFc~.=01b_=5Fc=5Fa\x0a_.\x0a=01", 121)
	check_qp_encode(c"\x0d\xffa\x0d\x09\x01 b_\x01~\x01\x01=a\x0a\xffcc=\x0d==\x0d~ a\x01b\x0d_\x09bb\xff.~\x01\x01=\xffa~\x0ac\x01.\x01\x0a \xffbb\xffc~.\x01b _c_a\x0a .\x0a\x01", 69, 1, 0, c"\x0d=FFa\x0d=09=01=20b_=01~=01=01=3Da\x0a=FFcc=3D\x0d=3D=3D\x0d~=20a=01b\x0d_=09bb=FF.~=01=01=3D=FFa~\x0ac=01.=01\x0a=20=FFbb=FFc~.=01b=20_c_a\x0a=20.\x0a=01", 127)
	check_qp_encode(c"\x0d\xffa\x0d\x09\x01 b_\x01~\x01\x01=a\x0a\xffcc=\x0d==\x0d~ a\x01b\x0d_\x09bb\xff.~\x01\x01=\xffa~\x0ac\x01.\x01\x0a \xffbb\xffc~.\x01b _c_a\x0a .\x0a\x01", 69, 1, 1, c"\x0d=FFa\x0d=09=01=20b=5F=01~=01=01=3Da\x0a=FFcc=3D\x0d=3D=3D\x0d~=20a=01b\x0d=5F=09bb=FF.~=01=01=3D=FFa~\x0ac=01.=01\x0a=20=FFbb=FFc~.=01b=20=5Fc=5Fa\x0a=20.\x0a=01", 135)
	check_qp_encode(c"~c\x0d=\x0ac\x0a.= \x0d\xff=\x0d\x0d\x01ba_\xff~\x01.\x0a\xff\x09\x0d.a.\x0d\x0dc\x0d_ \x0dc\x0d\x0aa bb_\x01\xff. \x0ab", 51, 0, 0, c"~c\x0d=3D\x0ac\x0a.=3D \x0d=FF=3D\x0d\x0d=01ba_=FF~=01.\x0a=FF\x09\x0d.a.\x0d\x0dc\x0d_ \x0dc\x0aa bb_=01=FF.=20\x0ab", 72)
	check_qp_encode(c"~c\x0d=\x0ac\x0a.= \x0d\xff=\x0d\x0d\x01ba_\xff~\x01.\x0a\xff\x09\x0d.a.\x0d\x0dc\x0d_ \x0dc\x0d\x0aa bb_\x01\xff. \x0ab", 51, 0, 1, c"~c\x0d=3D\x0ac\x0a.=3D_\x0d=FF=3D\x0d\x0d=01ba=5F=FF~=01.\x0a=FF\x09\x0d.a.\x0d\x0dc\x0d=5F_\x0dc\x0aa_bb=5F=01=FF._\x0ab", 76)
	check_qp_encode(c"~c\x0d=\x0ac\x0a.= \x0d\xff=\x0d\x0d\x01ba_\xff~\x01.\x0a\xff\x09\x0d.a.\x0d\x0dc\x0d_ \x0dc\x0d\x0aa bb_\x01\xff. \x0ab", 51, 1, 0, c"~c\x0d=3D\x0ac\x0a.=3D=20\x0d=FF=3D\x0d\x0d=01ba_=FF~=01.\x0a=FF=09\x0d.a.\x0d\x0dc\x0d_=20\x0dc\x0aa=20bb_=01=FF.=20\x0ab", 80)
	check_qp_encode(c"~c\x0d=\x0ac\x0a.= \x0d\xff=\x0d\x0d\x01ba_\xff~\x01.\x0a\xff\x09\x0d.a.\x0d\x0dc\x0d_ \x0dc\x0d\x0aa bb_\x01\xff. \x0ab", 51, 1, 1, c"~c\x0d=3D\x0ac\x0a.=3D=20\x0d=FF=3D\x0d\x0d=01ba=5F=FF~=01.\x0a=FF=09\x0d.a.\x0d\x0dc\x0d=5F=20\x0dc\x0aa=20bb=5F=01=FF.=20\x0ab", 86)
	check_qp_encode(c"b_\x01_\x01_\x0aa b\xffc  c=a\x09c~=\x09_=\x0a\xff\xff\x0d~ \x0d=cc.\xff\x0ab\x01\xffc\x0a \xff\x0a__\x01\x0a\x01c~ac\x0d\x09ccc\x01b\xff\xff~a\x09_ .b\x09\x09c\x0daa  \x0a\x0d=\x01\x01==\x0a\x0d", 87, 0, 0, c"b_=01_=01_\x0aa b=FFc  c=3Da\x09c~=3D\x09_=3D\x0a=FF=FF\x0d~ \x0d=3Dcc.=FF\x0ab=01=FFc\x0a =FF\x0a__=01\x0a=01c~ac\x0d\x09ccc=01b=FF=FF~a\x09_ .b\x09\x09c\x0daa =20\x0a\x0d=3D=01=01=3D=3D\x0a\x0d", 135)
	check_qp_encode(c"b_\x01_\x01_\x0aa b\xffc  c=a\x09c~=\x09_=\x0a\xff\xff\x0d~ \x0d=cc.\xff\x0ab\x01\xffc\x0a \xff\x0a__\x01\x0a\x01c~ac\x0d\x09ccc\x01b\xff\xff~a\x09_ .b\x09\x09c\x0daa  \x0a\x0d=\x01\x01==\x0a\x0d", 87, 0, 1, c"b=5F=01=5F=01=5F\x0aa_b=FFc__c=3Da\x09c~=3D\x09=5F=3D\x0a=FF=FF\x0d~_\x0d=3Dcc.=FF\x0ab=01=FFc\x0a_=FF\x0a=5F=5F=01\x0a=01c~ac\x0d\x09ccc=01b=FF=FF~a\x09=5F_.b\x09\x09c\x0daa__\x0a\x0d=3D=01=01=3D=3D\x0a\x0d", 147)
	check_qp_encode(c"b_\x01_\x01_\x0aa b\xffc  c=a\x09c~=\x09_=\x0a\xff\xff\x0d~ \x0d=cc.\xff\x0ab\x01\xffc\x0a \xff\x0a__\x01\x0a\x01c~ac\x0d\x09ccc\x01b\xff\xff~a\x09_ .b\x09\x09c\x0daa  \x0a\x0d=\x01\x01==\x0a\x0d", 87, 1, 0, c"b_=01_=01_\x0aa=20b=FFc=20=20c=3Da=09c~=3D=09_=3D\x0a=FF=FF\x0d~=20\x0d=3Dcc.=FF\x0ab=01=FFc\x0a=20=FF\x0a__=01\x0a=01c~ac\x0d=09ccc=01b=FF=FF~a=09_=20.b=09=09c\x0daa=20=20\x0a\x0d=3D=01=01=3D=3D\x0a\x0d", 161)
	check_qp_encode(c"b_\x01_\x01_\x0aa b\xffc  c=a\x09c~=\x09_=\x0a\xff\xff\x0d~ \x0d=cc.\xff\x0ab\x01\xffc\x0a \xff\x0a__\x01\x0a\x01c~ac\x0d\x09ccc\x01b\xff\xff~a\x09_ .b\x09\x09c\x0daa  \x0a\x0d=\x01\x01==\x0a\x0d", 87, 1, 1, c"b=5F=01=5F=01=5F\x0aa=20b=FFc=20=20c=3Da=09c~=3D=09=5F=3D\x0a=FF=FF\x0d~=20\x0d=3Dcc.=FF\x0ab=01=FFc\x0a=20=FF\x0a=5F=5F=01\x0a=01c~ac\x0d=09ccc=01b=FF=FF~a=09=5F=20.b=09=09c\x0daa=20=20\x0a\x0d=3D=01=01=3D=3D\x0a\x0d", 175)
	check_qp_encode(c"\x09bab_\x0a.\x0acbc\x01\xff~b=.\x0ac.~aa\x09c_b=~\x0da\x0d \x0a c \x09\x0db_\xff \xffa\x0d~\x01 \x0a_\x0a\x0a\x0a\x0dc\xff\xff\xff\x09\x09a\xff\x09~~\xff\x01b_=\x0d _\x09~cb. \x0a_~\x01c=. \xff=\xff\x09.b._ \x01\x0d\x01b\x0aaa\x09 _\x01\x09ac\x0d\x0aab\xff\xff~.", 119, 0, 0, c"\x09bab_\x0a=2E\x0acbc=01=FF~b=3D.\x0ac.~aa\x09c_b=3D~\x0da\x0d=20\x0a c \x09\x0db_=FF =FFa\x0d~=01=20\x0a_\x0a\x0a\x0a\x0dc=FF=FF=FF\x09\x09a=FF\x09~~=FF=01b_=3D\x0d _\x09~cb.=20\x0a_~=01c=3D. =FF=3D=FF\x09.b._ =01\x0d=01b\x0aaa\x09 _=01\x09ac\x0aab=FF=FF~.", 174)
	check_qp_encode(c"\x09bab_\x0a.\x0acbc\x01\xff~b=.\x0ac.~aa\x09c_b=~\x0da\x0d \x0a c \x09\x0db_\xff \xffa\x0d~\x01 \x0a_\x0a\x0a\x0a\x0dc\xff\xff\xff\x09\x09a\xff\x09~~\xff\x01b_=\x0d _\x09~cb. \x0a_~\x01c=. \xff=\xff\x09.b._ \x01\x0d\x01b\x0aaa\x09 _\x01\x09ac\x0d\x0aab\xff\xff~.", 119, 0, 1, c"\x09bab=5F\x0a=2E\x0acbc=01=FF~b=3D.\x0ac.~aa\x09c=5Fb=3D~\x0da\x0d_\x0a_c_\x09\x0db=5F=FF_=FFa\x0d~=01_\x0a=5F\x0a\x0a\x0a\x0dc=FF=FF=FF\x09\x09a=FF\x09~~=FF=01b=5F=3D\x0d_=5F\x09~cb._\x0a=5F~=01c=3D._=FF=3D=FF\x09.b.=5F_=01\x0d=01b\x0aaa\x09_=5F=01\x09ac\x0aab=FF=FF~.", 186)
	check_qp_encode(c"\x09bab_\x0a.\x0acbc\x01\xff~b=.\x0ac.~aa\x09c_b=~\x0da\x0d \x0a c \x09\x0db_\xff \xffa\x0d~\x01 \x0a_\x0a\x0a\x0a\x0dc\xff\xff\xff\x09\x09a\xff\x09~~\xff\x01b_=\x0d _\x09~cb. \x0a_~\x01c=. \xff=\xff\x09.b._ \x01\x0d\x01b\x0aaa\x09 _\x01\x09ac\x0d\x0aab\xff\xff~.", 119, 1, 0, c"=09bab_\x0a=2E\x0acbc=01=FF~b=3D.\x0ac.~aa=09c_b=3D~\x0da\x0d=20\x0a=20c=20=09\x0db_=FF=20=FFa\x0d~=01=20\x0a_\x0a\x0a\x0a\x0dc=FF=FF=FF=09=09a=FF=09~~=FF=01b_=3D\x0d=20_=09~cb.=20\x0a_~=01c=3D.=20=FF=3D=FF=09.b._=20=01\x0d=01b\x0aaa=09=20_=01=09ac\x0aab=FF=FF~.", 208)
	check_qp_encode(c"\x09bab_\x0a.\x0acbc\x01\xff~b=.\x0ac.~aa\x09c_b=~\x0da\x0d \x0a c \x09\x0db_\xff \xffa\x0d~\x01 \x0a_\x0a\x0a\x0a\x0dc\xff\xff\xff\x09\x09a\xff\x09~~\xff\x01b_=\x0d _\x09~cb. \x0a_~\x01c=. \xff=\xff\x09.b._ \x01\x0d\x01b\x0aaa\x09 _\x01\x09ac\x0d\x0aab\xff\xff~.", 119, 1, 1, c"=09bab=5F\x0a=2E\x0acbc=01=FF~b=3D.\x0ac.~aa=09c=5Fb=3D~\x0da\x0d=20\x0a=20c=20=09\x0db=5F=FF=20=FFa\x0d~=01=20\x0a=5F\x0a\x0a\x0a\x0dc=FF=FF=FF=09=09a=FF=09~~=FF=01b=5F=3D\x0d=20=5F=09~cb.=20\x0a=5F~=01c=3D.=20=FF=3D=FF=09.b.=5F=20=01\x0d=01b\x0aaa=09=20=5F=01=09ac\x0aab=FF=FF~.", 226)
	check_qp_encode(c" ~c\x0a\x0a.\x0d._~~\x0a=c\x09~~~.\x0a\x09a\xff\x0dcc", 26, 0, 0, c" ~c\x0a\x0a=2E\x0d._~~\x0a=3Dc\x09~~~.\x0a\x09a=FF\x0dcc", 32)
	check_qp_encode(c" ~c\x0a\x0a.\x0d._~~\x0a=c\x09~~~.\x0a\x09a\xff\x0dcc", 26, 0, 1, c"_~c\x0a\x0a=2E\x0d.=5F~~\x0a=3Dc\x09~~~.\x0a\x09a=FF\x0dcc", 34)
	check_qp_encode(c" ~c\x0a\x0a.\x0d._~~\x0a=c\x09~~~.\x0a\x09a\xff\x0dcc", 26, 1, 0, c"=20~c\x0a\x0a=2E\x0d._~~\x0a=3Dc=09~~~.\x0a=09a=FF\x0dcc", 38)
	check_qp_encode(c" ~c\x0a\x0a.\x0d._~~\x0a=c\x09~~~.\x0a\x09a\xff\x0dcc", 26, 1, 1, c"=20~c\x0a\x0a=2E\x0d.=5F~~\x0a=3Dc=09~~~.\x0a=09a=FF\x0dcc", 40)
	check_qp_encode(c"\xffab=\x09~\x09=.\x0d \x0d.b\xffc\x0ac \x01\x0a\x01\x09\x0ab_c\x01", 28, 0, 0, c"=FFab=3D\x09~\x09=3D.\x0d \x0d.b=FFc\x0ac =01\x0a=01=09\x0ab_c=01", 44)
	check_qp_encode(c"\xffab=\x09~\x09=.\x0d \x0d.b\xffc\x0ac \x01\x0a\x01\x09\x0ab_c\x01", 28, 0, 1, c"=FFab=3D\x09~\x09=3D.\x0d_\x0d.b=FFc\x0ac_=01\x0a=01=09\x0ab=5Fc=01", 46)
	check_qp_encode(c"\xffab=\x09~\x09=.\x0d \x0d.b\xffc\x0ac \x01\x0a\x01\x09\x0ab_c\x01", 28, 1, 0, c"=FFab=3D=09~=09=3D.\x0d=20\x0d.b=FFc\x0ac=20=01\x0a=01=09\x0ab_c=01", 52)
	check_qp_encode(c"\xffab=\x09~\x09=.\x0d \x0d.b\xffc\x0ac \x01\x0a\x01\x09\x0ab_c\x01", 28, 1, 1, c"=FFab=3D=09~=09=3D.\x0d=20\x0d.b=FFc\x0ac=20=01\x0a=01=09\x0ab=5Fc=01", 54)
	check_qp_encode(c"\xff\xffb\x09\x09.\x0d\x0aa_~ \x0a\x01\x09=\x0d=~~_\x0a\x0d\xff ", 25, 0, 0, c"=FF=FFb\x09\x09.\x0d\x0aa_~=20\x0d\x0a=01\x09=3D\x0d=3D~~_\x0d\x0a\x0d=FF=20", 43)
	check_qp_encode(c"\xff\xffb\x09\x09.\x0d\x0aa_~ \x0a\x01\x09=\x0d=~~_\x0a\x0d\xff ", 25, 0, 1, c"=FF=FFb\x09\x09.\x0d\x0aa=5F~_\x0d\x0a=01\x09=3D\x0d=3D~~=5F\x0d\x0a\x0d=FF=20", 45)
	check_qp_encode(c"\xff\xffb\x09\x09.\x0d\x0aa_~ \x0a\x01\x09=\x0d=~~_\x0a\x0d\xff ", 25, 1, 0, c"=FF=FFb=09=09.\x0d\x0aa_~=20\x0d\x0a=01=09=3D\x0d=3D~~_\x0d\x0a\x0d=FF=20", 49)
	check_qp_encode(c"\xff\xffb\x09\x09.\x0d\x0aa_~ \x0a\x01\x09=\x0d=~~_\x0a\x0d\xff ", 25, 1, 1, c"=FF=FFb=09=09.\x0d\x0aa=5F~=20\x0d\x0a=01=09=3D\x0d=3D~~=5F\x0d\x0a\x0d=FF=20", 53)
	check_qp_encode(c"\x09c=\x0d\x01\x0d\x0da .\x09\xffa.\x0da\x01\xff._=c\xff \x0d~\x09\x0d\x01_=\x09a\x09\x01~._\x0a\x09=aa \x0d.bab\x09\x09a.= a_\x0a=a\x0d\x0d=\x0a.b\x09\xffb\xff_\x0dc\x0a_a\xff=a.b\x0a\x01a\x09=~..\x0dcc\x0ac_\x01c\x0dc\x0a", 100, 0, 0, c"\x09c=3D\x0d=01\x0d\x0da .\x09=FFa.\x0da=01=FF._=3Dc=FF \x0d~\x09\x0d=01_=3D\x09a\x09=01~._\x0a\x09=3Daa \x0d.bab\x09\x09a.=3D a_\x0a=3Da\x0d\x0d=3D\x0a.b\x09=FFb=FF_\x0dc\x0a_a=FF=3Da.b\x0a=01a\x09=3D~..\x0dcc\x0ac_=01c\x0dc\x0a", 142)
	check_qp_encode(c"\x09c=\x0d\x01\x0d\x0da .\x09\xffa.\x0da\x01\xff._=c\xff \x0d~\x09\x0d\x01_=\x09a\x09\x01~._\x0a\x09=aa \x0d.bab\x09\x09a.= a_\x0a=a\x0d\x0d=\x0a.b\x09\xffb\xff_\x0dc\x0a_a\xff=a.b\x0a\x01a\x09=~..\x0dcc\x0ac_\x01c\x0dc\x0a", 100, 0, 1, c"\x09c=3D\x0d=01\x0d\x0da_.\x09=FFa.\x0da=01=FF.=5F=3Dc=FF_\x0d~\x09\x0d=01=5F=3D\x09a\x09=01~.=5F\x0a\x09=3Daa_\x0d.bab\x09\x09a.=3D_a=5F\x0a=3Da\x0d\x0d=3D\x0a.b\x09=FFb=FF=5F\x0dc\x0a=5Fa=FF=3Da.b\x0a=01a\x09=3D~..\x0dcc\x0ac=5F=01c\x0dc\x0a", 156)
	check_qp_encode(c"\x09c=\x0d\x01\x0d\x0da .\x09\xffa.\x0da\x01\xff._=c\xff \x0d~\x09\x0d\x01_=\x09a\x09\x01~._\x0a\x09=aa \x0d.bab\x09\x09a.= a_\x0a=a\x0d\x0d=\x0a.b\x09\xffb\xff_\x0dc\x0a_a\xff=a.b\x0a\x01a\x09=~..\x0dcc\x0ac_\x01c\x0dc\x0a", 100, 1, 0, c"=09c=3D\x0d=01\x0d\x0da=20.=09=FFa.\x0da=01=FF._=3Dc=FF=20\x0d~=09\x0d=01_=3D=09a=09=01~._\x0a=09=3Daa=20\x0d.bab=09=09a.=3D=20a_\x0a=3Da\x0d\x0d=3D\x0a.b=09=FFb=FF_\x0dc\x0a_a=FF=3Da.b\x0a=01a=09=3D~..\x0dcc\x0ac_=01c\x0dc\x0a", 170)
	check_qp_encode(c"\x09c=\x0d\x01\x0d\x0da .\x09\xffa.\x0da\x01\xff._=c\xff \x0d~\x09\x0d\x01_=\x09a\x09\x01~._\x0a\x09=aa \x0d.bab\x09\x09a.= a_\x0a=a\x0d\x0d=\x0a.b\x09\xffb\xff_\x0dc\x0a_a\xff=a.b\x0a\x01a\x09=~..\x0dcc\x0ac_\x01c\x0dc\x0a", 100, 1, 1, c"=09c=3D\x0d=01\x0d\x0da=20.=09=FFa.\x0da=01=FF.=5F=3Dc=FF=20\x0d~=09\x0d=01=5F=3D=09a=09=01~.=\x0a=5F\x0a=09=3Daa=20\x0d.bab=09=09a.=3D=20a=5F\x0a=3Da\x0d\x0d=3D\x0a.b=09=FFb=FF=5F\x0dc\x0a=5Fa=FF=3Da.b\x0a=01a=09=3D~..\x0dcc\x0ac=5F=01c\x0dc\x0a", 186)
	check_qp_encode(c" \x09\x0ac\x0da \x09\xff\x0a\x0d_==c\x0a \x0a= c\x09\x0d~\x0da\xffc\x09\x0a\x01~ac.\x09 \xff\xff\x01~=\x0a\x0d ==", 47, 0, 0, c" =09\x0ac\x0da \x09=FF\x0a\x0d_=3D=3Dc\x0a=20\x0a=3D c\x09\x0d~\x0da=FFc=09\x0a=01~ac.\x09 =FF=FF=01~=3D\x0a\x0d =3D=3D", 77)
	check_qp_encode(c" \x09\x0ac\x0da \x09\xff\x0a\x0d_==c\x0a \x0a= c\x09\x0d~\x0da\xffc\x09\x0a\x01~ac.\x09 \xff\xff\x01~=\x0a\x0d ==", 47, 0, 1, c"_=09\x0ac\x0da_\x09=FF\x0a\x0d=5F=3D=3Dc\x0a_\x0a=3D_c\x09\x0d~\x0da=FFc=09\x0a=01~ac.\x09_=FF=FF=01~=3D\x0a\x0d_=3D=3D", 77)
	check_qp_encode(c" \x09\x0ac\x0da \x09\xff\x0a\x0d_==c\x0a \x0a= c\x09\x0d~\x0da\xffc\x09\x0a\x01~ac.\x09 \xff\xff\x01~=\x0a\x0d ==", 47, 1, 0, c"=20=09\x0ac\x0da=20=09=FF\x0a\x0d_=3D=3Dc\x0a=20\x0a=3D=20c=09\x0d~\x0da=FFc=09\x0a=01~ac.=09=20=FF=FF=01~=3D\x0a\x0d=20=3D=3D", 93)
	check_qp_encode(c" \x09\x0ac\x0da \x09\xff\x0a\x0d_==c\x0a \x0a= c\x09\x0d~\x0da\xffc\x09\x0a\x01~ac.\x09 \xff\xff\x01~=\x0a\x0d ==", 47, 1, 1, c"=20=09\x0ac\x0da=20=09=FF\x0a\x0d=5F=3D=3Dc\x0a=20\x0a=3D=20c=09\x0d~\x0da=FFc=09\x0a=01~ac.=09=20=FF=FF=01~=3D\x0a\x0d=20=3D=3D", 95)
	check_qp_encode(c"\xff.cb\xff  \x01.\x09a\x09\x0a\x09ca~\x0ac\xff_~\x0d\x0a\x09~\x09c  c\x09aa__ac.ca\xffc\x01\x0d~~~.\x0d\x09\x0a.\x01~\x0d~\x09 \x0a=_.\xff_a\x0ab\x01ca\x09c\x09=\x01\x0dcc_ \xff~\xff\x0d\x09=\x09c ~\x09~.c_\xff b\x0a.._=\x09\x0d\x0a_=cb.bb_c~\x01\x0d\xff", 120, 0, 0, c"=FF.cb=FF  =01.\x09a=09\x0a\x09ca~\x0ac=FF_~\x0a\x09~\x09c  c\x09aa__ac.ca=FFc=01\x0d~~~.\x0d=09\x0a.=01~\x0d~\x09=20\x0a=3D_.=FF_a\x0ab=01ca\x09c\x09=3D=01\x0dcc_ =FF~=FF\x0d\x09=3D\x09c ~\x09~.c_=FF b\x0a.._=3D=09\x0a_=3Dcb.bb_c~=01\x0d=FF", 166)
	check_qp_encode(c"\xff.cb\xff  \x01.\x09a\x09\x0a\x09ca~\x0ac\xff_~\x0d\x0a\x09~\x09c  c\x09aa__ac.ca\xffc\x01\x0d~~~.\x0d\x09\x0a.\x01~\x0d~\x09 \x0a=_.\xff_a\x0ab\x01ca\x09c\x09=\x01\x0dcc_ \xff~\xff\x0d\x09=\x09c ~\x09~.c_\xff b\x0a.._=\x09\x0d\x0a_=cb.bb_c~\x01\x0d\xff", 120, 0, 1, c"=FF.cb=FF__=01.\x09a=09\x0a\x09ca~\x0ac=FF=5F~\x0a\x09~\x09c__c\x09aa=5F=5Fac.ca=FFc=01\x0d~~~.\x0d=09\x0a.=01~\x0d~\x09_\x0a=3D=5F.=FF=5Fa\x0ab=01ca\x09c\x09=3D=01\x0dcc=5F_=FF~=FF\x0d\x09=3D\x09c_~\x09~.c=5F=FF_b\x0a..=5F=3D=09\x0a=5F=3Dcb.bb=5Fc~=01\x0d=FF", 184)
	check_qp_encode(c"\xff.cb\xff  \x01.\x09a\x09\x0a\x09ca~\x0ac\xff_~\x0d\x0a\x09~\x09c  c\x09aa__ac.ca\xffc\x01\x0d~~~.\x0d\x09\x0a.\x01~\x0d~\x09 \x0a=_.\xff_a\x0ab\x01ca\x09c\x09=\x01\x0dcc_ \xff~\xff\x0d\x09=\x09c ~\x09~.c_\xff b\x0a.._=\x09\x0d\x0a_=cb.bb_c~\x01\x0d\xff", 120, 1, 0, c"=FF.cb=FF=20=20=01.=09a=09\x0a=09ca~\x0ac=FF_~\x0a=09~=09c=20=20c=09aa__ac.ca=FFc=01\x0d~~~.\x0d=09\x0a.=01~\x0d~=09=20\x0a=3D_.=FF_a\x0ab=01ca=09c=09=3D=01\x0dcc_=20=FF~=FF\x0d=09=3D=09c=20~=09~.c_=FF=20b\x0a.._=3D=09\x0a_=3Dcb.bb_c~=01\x0d=FF", 202)
	check_qp_encode(c"\xff.cb\xff  \x01.\x09a\x09\x0a\x09ca~\x0ac\xff_~\x0d\x0a\x09~\x09c  c\x09aa__ac.ca\xffc\x01\x0d~~~.\x0d\x09\x0a.\x01~\x0d~\x09 \x0a=_.\xff_a\x0ab\x01ca\x09c\x09=\x01\x0dcc_ \xff~\xff\x0d\x09=\x09c ~\x09~.c_\xff b\x0a.._=\x09\x0d\x0a_=cb.bb_c~\x01\x0d\xff", 120, 1, 1, c"=FF.cb=FF=20=20=01.=09a=09\x0a=09ca~\x0ac=FF=5F~\x0a=09~=09c=20=20c=09aa=5F=5Fac.ca=FFc=01\x0d~~~.\x0d=09\x0a.=01~\x0d~=09=20\x0a=3D=5F.=FF=5Fa\x0ab=01ca=09c=09=3D=01\x0dcc=5F=20=FF~=FF\x0d=09=3D=09c=20~=09~.c=5F=FF=20b\x0a..=5F=3D=09\x0a=5F=3Dcb.bb=5Fc~=01\x0d=FF", 222)
	check_qp_encode(c"\xffcc \x09_.\xff.ba\xffc. \x0a~\x0d\x0a\x0acab \x0a\x0da~\x09a.=\xff.\xffbacc ~c\x01\x09\x0d= a\x0d\x09\xff.\xffb~\xff=a.\x0a=b\x01\xff\xff\x09", 66, 0, 0, c"=FFcc \x09_.=FF.ba=FFc.=20\x0a~\x0a\x0acab=20\x0a\x0da~\x09a.=3D=FF.=FFbacc ~c=01\x09\x0d=3D a\x0d\x09=FF.=FFb~=FF=3Da.\x0a=3Db=01=FF=FF=09", 103)
	check_qp_encode(c"\xffcc \x09_.\xff.ba\xffc. \x0a~\x0d\x0a\x0acab \x0a\x0da~\x09a.=\xff.\xffbacc ~c\x01\x09\x0d= a\x0d\x09\xff.\xffb~\xff=a.\x0a=b\x01\xff\xff\x09", 66, 0, 1, c"=FFcc_\x09=5F.=FF.ba=FFc._\x0a~\x0a\x0acab_\x0a\x0da~\x09a.=3D=FF.=FFbacc_~c=01\x09\x0d=3D_a\x0d\x09=FF.=FFb~=FF=3Da.\x0a=3Db=01=FF=FF=09", 101)
	check_qp_encode(c"\xffcc \x09_.\xff.ba\xffc. \x0a~\x0d\x0a\x0acab \x0a\x0da~\x09a.=\xff.\xffbacc ~c\x01\x09\x0d= a\x0d\x09\xff.\xffb~\xff=a.\x0a=b\x01\xff\xff\x09", 66, 1, 0, c"=FFcc=20=09_.=FF.ba=FFc.=20\x0a~\x0a\x0acab=20\x0a\x0da~=09a.=3D=FF.=FFbacc=20~c=01=09\x0d=3D=20a\x0d=09=FF.=FFb~=FF=3Da.\x0a=3Db=01=FF=FF=09", 117)
	check_qp_encode(c"\xffcc \x09_.\xff.ba\xffc. \x0a~\x0d\x0a\x0acab \x0a\x0da~\x09a.=\xff.\xffbacc ~c\x01\x09\x0d= a\x0d\x09\xff.\xffb~\xff=a.\x0a=b\x01\xff\xff\x09", 66, 1, 1, c"=FFcc=20=09=5F.=FF.ba=FFc.=20\x0a~\x0a\x0acab=20\x0a\x0da~=09a.=3D=FF.=FFbacc=20~c=01=09\x0d=3D=20a\x0d=09=FF.=FFb~=FF=3Da.\x0a=3Db=01=FF=FF=09", 119)
	check_qp_encode(c"b=\x0d_c\x09 =\x01~.\x0d\x01c.ba\x0a~.a.\x01\x09~\x09a.\x0a\xff\x0ab~\xff\xff~.\x0dc_ \xff\x01\x01\x0d =.\x0a\x0a _=ca=_.c\x01\x0d=.~_.\xff\x0aa\x01a\x0a\x0a._\x0d=\x0a~\x0a=\x0a~a  .c\x01==\x0d=\x0a.~~\x01\x09", 99, 0, 0, c"b=3D\x0d_c\x09 =3D=01~.\x0d=01c.ba\x0a~.a.=01\x09~\x09a.\x0a=FF\x0ab~=FF=FF~.\x0dc_ =FF=01=01\x0d =3D.\x0a\x0a _=3Dca=3D_.c=01\x0d=3D.~_.=FF\x0aa=01a\x0a\x0a._\x0d=3D\x0a~\x0a=3D\x0a~a  .c=01=3D=3D\x0d=3D\x0a.~~=01=09", 151)
	check_qp_encode(c"b=\x0d_c\x09 =\x01~.\x0d\x01c.ba\x0a~.a.\x01\x09~\x09a.\x0a\xff\x0ab~\xff\xff~.\x0dc_ \xff\x01\x01\x0d =.\x0a\x0a _=ca=_.c\x01\x0d=.~_.\xff\x0aa\x01a\x0a\x0a._\x0d=\x0a~\x0a=\x0a~a  .c\x01==\x0d=\x0a.~~\x01\x09", 99, 0, 1, c"b=3D\x0d=5Fc\x09_=3D=01~.\x0d=01c.ba\x0a~.a.=01\x09~\x09a.\x0a=FF\x0ab~=FF=FF~.\x0dc=5F_=FF=01=01\x0d_=3D.\x0a\x0a_=5F=3Dca=3D=5F.c=01\x0d=3D.~=5F.=FF\x0aa=01a\x0a\x0a.=5F\x0d=3D\x0a~\x0a=3D\x0a~a__.c=01=3D=3D\x0d=3D\x0a.~~=01=09", 163)
	check_qp_encode(c"b=\x0d_c\x09 =\x01~.\x0d\x01c.ba\x0a~.a.\x01\x09~\x09a.\x0a\xff\x0ab~\xff\xff~.\x0dc_ \xff\x01\x01\x0d =.\x0a\x0a _=ca=_.c\x01\x0d=.~_.\xff\x0aa\x01a\x0a\x0a._\x0d=\x0a~\x0a=\x0a~a  .c\x01==\x0d=\x0a.~~\x01\x09", 99, 1, 0, c"b=3D\x0d_c=09=20=3D=01~.\x0d=01c.ba\x0a~.a.=01=09~=09a.\x0a=FF\x0ab~=FF=FF~.\x0dc_=20=FF=01=01\x0d=20=3D.\x0a\x0a=20_=3Dca=3D_.c=01\x0d=3D.~_.=FF\x0aa=01a\x0a\x0a._\x0d=3D\x0a~\x0a=3D\x0a~a=20=20.c=01=3D=3D\x0d=3D\x0a.~~=01=09", 169)
	check_qp_encode(c"b=\x0d_c\x09 =\x01~.\x0d\x01c.ba\x0a~.a.\x01\x09~\x09a.\x0a\xff\x0ab~\xff\xff~.\x0dc_ \xff\x01\x01\x0d =.\x0a\x0a _=ca=_.c\x01\x0d=.~_.\xff\x0aa\x01a\x0a\x0a._\x0d=\x0a~\x0a=\x0a~a  .c\x01==\x0d=\x0a.~~\x01\x09", 99, 1, 1, c"b=3D\x0d=5Fc=09=20=3D=01~.\x0d=01c.ba\x0a~.a.=01=09~=09a.\x0a=FF\x0ab~=FF=FF~.\x0dc=5F=20=FF=01=01\x0d=20=3D.\x0a\x0a=20=5F=3Dca=3D=5F.c=01\x0d=3D.~=5F.=FF\x0aa=01a\x0a\x0a.=5F\x0d=3D\x0a~\x0a=3D\x0a~a=20=20.c=01=3D=3D\x0d=3D\x0a.~~=01=09", 181)
	check_qp_encode(c".bc=cb \x0ab\x0da=.=\x09= =\x01~_c\x09 \x09\x09=\x09~\x0da\x09bb=~.\x0a_\x0a.= \x0a\xff=.\x09.\x0a.\x0d\x0a\x09b\x0a\xff\x01\x0ac~=~c\x01ab  c\x0ac_.ba= \x01\xff\xffc", 82, 0, 0, c".bc=3Dcb=20\x0ab\x0da=3D.=3D\x09=3D =3D=01~_c\x09 \x09\x09=3D\x09~\x0da\x09bb=3D~.\x0a_\x0a.=3D=20\x0a=FF=3D.\x09.\x0a=2E\x0a\x09b\x0a=FF=01\x0ac~=3D~c=01ab  c\x0ac_.ba=3D =01=FF=FFc", 125)
	check_qp_encode(c".bc=cb \x0ab\x0da=.=\x09= =\x01~_c\x09 \x09\x09=\x09~\x0da\x09bb=~.\x0a_\x0a.= \x0a\xff=.\x09.\x0a.\x0d\x0a\x09b\x0a\xff\x01\x0ac~=~c\x01ab  c\x0ac_.ba= \x01\xff\xffc", 82, 0, 1, c".bc=3Dcb_\x0ab\x0da=3D.=3D\x09=3D_=3D=01~=5Fc\x09_\x09\x09=3D\x09~\x0da\x09bb=3D~.\x0a=5F\x0a.=3D_\x0a=FF=3D.\x09.\x0a=2E\x0a\x09b\x0a=FF=01\x0ac~=3D~c=01ab__c\x0ac=5F.ba=3D_=01=FF=FFc", 127)
	check_qp_encode(c".bc=cb \x0ab\x0da=.=\x09= =\x01~_c\x09 \x09\x09=\x09~\x0da\x09bb=~.\x0a_\x0a.= \x0a\xff=.\x09.\x0a.\x0d\x0a\x09b\x0a\xff\x01\x0ac~=~c\x01ab  c\x0ac_.ba= \x01\xff\xffc", 82, 1, 0, c".bc=3Dcb=20\x0ab\x0da=3D.=3D=09=3D=20=3D=01~_c=09=20=09=09=3D=09~\x0da=09bb=3D~.\x0a_\x0a.=3D=20\x0a=FF=3D.=09.\x0a=2E\x0a=09b\x0a=FF=01\x0ac~=3D~c=01ab=20=20c\x0ac_.ba=3D=20=01=FF=FFc", 151)
	check_qp_encode(c".bc=cb \x0ab\x0da=.=\x09= =\x01~_c\x09 \x09\x09=\x09~\x0da\x09bb=~.\x0a_\x0a.= \x0a\xff=.\x09.\x0a.\x0d\x0a\x09b\x0a\xff\x01\x0ac~=~c\x01ab  c\x0ac_.ba= \x01\xff\xffc", 82, 1, 1, c".bc=3Dcb=20\x0ab\x0da=3D.=3D=09=3D=20=3D=01~=5Fc=09=20=09=09=3D=09~\x0da=09bb=3D~.\x0a=5F\x0a.=3D=20\x0a=FF=3D.=09.\x0a=2E\x0a=09b\x0a=FF=01\x0ac~=3D~c=01ab=20=20c\x0ac=5F.ba=3D=20=01=FF=FFc", 157)
	check_qp_encode(c"\x01 .a\x0db=\xff .a _", 13, 0, 0, c"=01 .a\x0db=3D=FF .a _", 19)
	check_qp_encode(c"\x01 .a\x0db=\xff .a _", 13, 0, 1, c"=01_.a\x0db=3D=FF_.a_=5F", 21)
	check_qp_encode(c"\x01 .a\x0db=\xff .a _", 13, 1, 0, c"=01=20.a\x0db=3D=FF=20.a=20_", 25)
	check_qp_encode(c"\x01 .a\x0db=\xff .a _", 13, 1, 1, c"=01=20.a\x0db=3D=FF=20.a=20=5F", 27)
	check_qp_encode(c"\x0d__.~cca\x0d\xff\x0d=_\x0da\x0d=", 17, 0, 0, c"\x0d__.~cca\x0d=FF\x0d=3D_\x0da\x0d=3D", 23)
	check_qp_encode(c"\x0d__.~cca\x0d\xff\x0d=_\x0da\x0d=", 17, 0, 1, c"\x0d=5F=5F.~cca\x0d=FF\x0d=3D=5F\x0da\x0d=3D", 29)
	check_qp_encode(c"\x0d__.~cca\x0d\xff\x0d=_\x0da\x0d=", 17, 1, 0, c"\x0d__.~cca\x0d=FF\x0d=3D_\x0da\x0d=3D", 23)
	check_qp_encode(c"\x0d__.~cca\x0d\xff\x0d=_\x0da\x0d=", 17, 1, 1, c"\x0d=5F=5F.~cca\x0d=FF\x0d=3D=5F\x0da\x0d=3D", 29)
	check_qp_encode(c"\x09 ~aca\x09\x0abb\x09\x09\x0a\x0a aab= a_. a\x0aab_\x0a=.aa~\x0d=b\xff_ca\x09~\x01_", 46, 0, 0, c"\x09 ~aca=09\x0abb\x09=09\x0a\x0a aab=3D a_. a\x0aab_\x0a=3D.aa~\x0d=3Db=FF_ca\x09~=01_", 60)
	check_qp_encode(c"\x09 ~aca\x09\x0abb\x09\x09\x0a\x0a aab= a_. a\x0aab_\x0a=.aa~\x0d=b\xff_ca\x09~\x01_", 46, 0, 1, c"\x09_~aca=09\x0abb\x09=09\x0a\x0a_aab=3D_a=5F._a\x0aab=5F\x0a=3D.aa~\x0d=3Db=FF=5Fca\x09~=01=5F", 68)
	check_qp_encode(c"\x09 ~aca\x09\x0abb\x09\x09\x0a\x0a aab= a_. a\x0aab_\x0a=.aa~\x0d=b\xff_ca\x09~\x01_", 46, 1, 0, c"=09=20~aca=09\x0abb=09=09\x0a\x0a=20aab=3D=20a_.=20a\x0aab_\x0a=3D.aa~\x0d=3Db=FF_ca=09~=01_", 74)
	check_qp_encode(c"\x09 ~aca\x09\x0abb\x09\x09\x0a\x0a aab= a_. a\x0aab_\x0a=.aa~\x0d=b\xff_ca\x09~\x01_", 46, 1, 1, c"=09=20~aca=09\x0abb=09=09\x0a\x0a=20aab=3D=20a=5F.=20a\x0aab=5F\x0a=3D.aa~\x0d=3Db=FF=5Fca=09~=01=5F", 82)
	check_qp_encode(c"\x0db_\x0a=a=\x09\x0aba\xff \x0d\x0ac \x0d =~bc\x09\x0aa_ \x09b\x01\x0d\x0da\x09\x09=\x01a_=c\x09 a_.cc\x0a", 50, 0, 0, c"\x0db_\x0a=3Da=3D=09\x0aba=FF=20\x0ac \x0d =3D~bc=09\x0aa_ \x09b=01\x0d\x0da\x09\x09=3D=01a_=3Dc\x09 a_.cc\x0a", 71)
	check_qp_encode(c"\x0db_\x0a=a=\x09\x0aba\xff \x0d\x0ac \x0d =~bc\x09\x0aa_ \x09b\x01\x0d\x0da\x09\x09=\x01a_=c\x09 a_.cc\x0a", 50, 0, 1, c"\x0db=5F\x0a=3Da=3D=09\x0aba=FF_\x0ac_\x0d_=3D~bc=09\x0aa=5F_\x09b=01\x0d\x0da\x09\x09=3D=01a=5F=3Dc\x09_a=5F.cc\x0a", 77)
	check_qp_encode(c"\x0db_\x0a=a=\x09\x0aba\xff \x0d\x0ac \x0d =~bc\x09\x0aa_ \x09b\x01\x0d\x0da\x09\x09=\x01a_=c\x09 a_.cc\x0a", 50, 1, 0, c"\x0db_\x0a=3Da=3D=09\x0aba=FF=20\x0ac=20\x0d=20=3D~bc=09\x0aa_=20=09b=01\x0d\x0da=09=09=3D=01a_=3Dc=09=20a_.cc\x0a", 87)
	check_qp_encode(c"\x0db_\x0a=a=\x09\x0aba\xff \x0d\x0ac \x0d =~bc\x09\x0aa_ \x09b\x01\x0d\x0da\x09\x09=\x01a_=c\x09 a_.cc\x0a", 50, 1, 1, c"\x0db=5F\x0a=3Da=3D=09\x0aba=FF=20\x0ac=20\x0d=20=3D~bc=09\x0aa=5F=20=09b=01\x0d\x0da=09=09=3D=01a=5F=3Dc=09=20a=5F.cc\x0a", 95)
	check_qp_encode(c"\x0a\x01~.~ c\x0db a\x01 __\xff_\x0d_=\x01\x0a cb\x0a.\x0a =.\x0daa..=a _\xff\x0a~a\x09\x01=_a\x0d\xffb_b\x0d\x01=\x0d=\x0a\x01caa\x0a\x01\x09b\x09a\x0d=\x01cb_\x09ca\x0dcc.\x0db\x01._b\x01\x0a\x09._c .a\xffca\x09=~\x0a._c", 108, 0, 0, c"\x0a=01~.~ c\x0db a=01 __=FF_\x0d_=3D=01\x0a cb\x0a=2E\x0a =3D.\x0daa..=3Da _=FF\x0a~a\x09=01=3D_a\x0d=FFb_b\x0d=01=3D\x0d=3D\x0a=01caa\x0a=01\x09b\x09a\x0d=3D=01cb_\x09ca\x0dcc.\x0db=01._b=01\x0a\x09._c .a=FFca\x09=3D~\x0a._c", 154)
	check_qp_encode(c"\x0a\x01~.~ c\x0db a\x01 __\xff_\x0d_=\x01\x0a cb\x0a.\x0a =.\x0daa..=a _\xff\x0a~a\x09\x01=_a\x0d\xffb_b\x0d\x01=\x0d=\x0a\x01caa\x0a\x01\x09b\x09a\x0d=\x01cb_\x09ca\x0dcc.\x0db\x01._b\x01\x0a\x09._c .a\xffca\x09=~\x0a._c", 108, 0, 1, c"\x0a=01~.~_c\x0db_a=01_=5F=5F=FF=5F\x0d=5F=3D=01\x0a_cb\x0a=2E\x0a_=3D.\x0daa..=3Da_=5F=FF\x0a~a\x09=01=3D=5Fa\x0d=FFb=5Fb\x0d=01=3D\x0d=3D\x0a=01caa\x0a=01\x09b\x09a\x0d=3D=01cb=5F\x09ca\x0dcc.\x0db=01.=5Fb=01\x0a\x09.=5Fc_.a=FFca\x09=3D~\x0a.=5Fc", 176)
	check_qp_encode(c"\x0a\x01~.~ c\x0db a\x01 __\xff_\x0d_=\x01\x0a cb\x0a.\x0a =.\x0daa..=a _\xff\x0a~a\x09\x01=_a\x0d\xffb_b\x0d\x01=\x0d=\x0a\x01caa\x0a\x01\x09b\x09a\x0d=\x01cb_\x09ca\x0dcc.\x0db\x01._b\x01\x0a\x09._c .a\xffca\x09=~\x0a._c", 108, 1, 0, c"\x0a=01~.~=20c\x0db=20a=01=20__=FF_\x0d_=3D=01\x0a=20cb\x0a=2E\x0a=20=3D.\x0daa..=3Da=20_=FF\x0a~a=09=01=3D_a\x0d=FFb_b\x0d=01=3D\x0d=3D\x0a=01caa\x0a=01=09b=09a\x0d=3D=01cb_=09ca\x0dcc.\x0db=01._b=01\x0a=09._c=20.a=FFca=09=3D~\x0a._c", 180)
	check_qp_encode(c"\x0a\x01~.~ c\x0db a\x01 __\xff_\x0d_=\x01\x0a cb\x0a.\x0a =.\x0daa..=a _\xff\x0a~a\x09\x01=_a\x0d\xffb_b\x0d\x01=\x0d=\x0a\x01caa\x0a\x01\x09b\x09a\x0d=\x01cb_\x09ca\x0dcc.\x0db\x01._b\x01\x0a\x09._c .a\xffca\x09=~\x0a._c", 108, 1, 1, c"\x0a=01~.~=20c\x0db=20a=01=20=5F=5F=FF=5F\x0d=5F=3D=01\x0a=20cb\x0a=2E\x0a=20=3D.\x0daa..=3Da=20=5F=FF\x0a~a=09=01=3D=5Fa\x0d=FFb=5Fb\x0d=01=3D\x0d=3D\x0a=01caa\x0a=01=09b=09a\x0d=3D=01cb=5F=09ca\x0dcc.\x0db=01.=5Fb=01\x0a=09.=5Fc=20.a=FFca=09=3D~\x0a.=5Fc", 202)
	check_qp_encode(c".=\xff=\x0d\x0a=~.\x01\xff  \x0a\x01\x01~c\x01 ba\x01a\x01._.\x0d\x0d\x09bc", 33, 0, 0, c".=3D=FF=3D\x0d\x0a=3D~.=01=FF =20\x0d\x0a=01=01~c=01 ba=01a=01._.\x0d\x0d\x09bc", 58)
	check_qp_encode(c".=\xff=\x0d\x0a=~.\x01\xff  \x0a\x01\x01~c\x01 ba\x01a\x01._.\x0d\x0d\x09bc", 33, 0, 1, c".=3D=FF=3D\x0d\x0a=3D~.=01=FF__\x0d\x0a=01=01~c=01_ba=01a=01.=5F.\x0d\x0d\x09bc", 58)
	check_qp_encode(c".=\xff=\x0d\x0a=~.\x01\xff  \x0a\x01\x01~c\x01 ba\x01a\x01._.\x0d\x0d\x09bc", 33, 1, 0, c".=3D=FF=3D\x0d\x0a=3D~.=01=FF=20=20\x0d\x0a=01=01~c=01=20ba=01a=01._.\x0d\x0d=09bc", 64)
	check_qp_encode(c".=\xff=\x0d\x0a=~.\x01\xff  \x0a\x01\x01~c\x01 ba\x01a\x01._.\x0d\x0d\x09bc", 33, 1, 1, c".=3D=FF=3D\x0d\x0a=3D~.=01=FF=20=20\x0d\x0a=01=01~c=01=20ba=01a=01.=5F.\x0d\x0d=09bc", 66)
	check_qp_encode(c"\x01~a~c\xff\x09\xff\x0a=\x09 bcb\x0abb\x0db_", 21, 0, 0, c"=01~a~c=FF\x09=FF\x0a=3D\x09 bcb\x0abb\x0db_", 29)
	check_qp_encode(c"\x01~a~c\xff\x09\xff\x0a=\x09 bcb\x0abb\x0db_", 21, 0, 1, c"=01~a~c=FF\x09=FF\x0a=3D\x09_bcb\x0abb\x0db=5F", 31)
	check_qp_encode(c"\x01~a~c\xff\x09\xff\x0a=\x09 bcb\x0abb\x0db_", 21, 1, 0, c"=01~a~c=FF=09=FF\x0a=3D=09=20bcb\x0abb\x0db_", 35)
	check_qp_encode(c"\x01~a~c\xff\x09\xff\x0a=\x09 bcb\x0abb\x0db_", 21, 1, 1, c"=01~a~c=FF=09=FF\x0a=3D=09=20bcb\x0abb\x0db=5F", 37)
	check_qp_encode(c"\xffb\x01 .\x09b\x01c\x09=.\x09.~c.~\xff\x0d= \x09\x0a_\xffac\x09a~\x0a\x0d", 33, 0, 0, c"=FFb=01 .\x09b=01c\x09=3D.\x09.~c.~=FF\x0d=3D =09\x0a_=FFac\x09a~\x0a\x0d", 49)
	check_qp_encode(c"\xffb\x01 .\x09b\x01c\x09=.\x09.~c.~\xff\x0d= \x09\x0a_\xffac\x09a~\x0a\x0d", 33, 0, 1, c"=FFb=01_.\x09b=01c\x09=3D.\x09.~c.~=FF\x0d=3D_=09\x0a=5F=FFac\x09a~\x0a\x0d", 51)
	check_qp_encode(c"\xffb\x01 .\x09b\x01c\x09=.\x09.~c.~\xff\x0d= \x09\x0a_\xffac\x09a~\x0a\x0d", 33, 1, 0, c"=FFb=01=20.=09b=01c=09=3D.=09.~c.~=FF\x0d=3D=20=09\x0a_=FFac=09a~\x0a\x0d", 61)
	check_qp_encode(c"\xffb\x01 .\x09b\x01c\x09=.\x09.~c.~\xff\x0d= \x09\x0a_\xffac\x09a~\x0a\x0d", 33, 1, 1, c"=FFb=01=20.=09b=01c=09=3D.=09.~c.~=FF\x0d=3D=20=09\x0a=5F=FFac=09a~\x0a\x0d", 63)
	check_qp_encode(c"~\x0d. \x0a\x0d c\x0d\x09bc\x0a ~b~_\x0d\x0a\x0d~\x0d\x0a= =\x0d\x09~\x01c.b\xff_a\x09\x0a_\xff\x0d\xffcb\xff ~ \x0a\xff\x0d\x09~c_\x0aaa=\x0ab=c\x09  \xff__= \x01c\x09\x0d\x09.~\x01\x01 c\x0a=~\x01_aab cc\x01\xffa\x0a\x0a.\x0da \xff.~ _", 108, 0, 0, c"~\x0d.=20\x0a\x0d c\x0d\x09bc\x0a ~b~_\x0a\x0d~\x0a=3D =3D\x0d\x09~=01c.b=FF_a=09\x0a_=FF\x0d=FFcb=FF ~=20\x0a=FF\x0d\x09~c_\x0aaa=3D\x0ab=3Dc\x09  =FF__=3D =01c\x09\x0d\x09.~=01=01 c\x0a=3D~=01_aab cc=01=FFa\x0a\x0a=2E\x0da =FF.~ _", 154)
	check_qp_encode(c"~\x0d. \x0a\x0d c\x0d\x09bc\x0a ~b~_\x0d\x0a\x0d~\x0d\x0a= =\x0d\x09~\x01c.b\xff_a\x09\x0a_\xff\x0d\xffcb\xff ~ \x0a\xff\x0d\x09~c_\x0aaa=\x0ab=c\x09  \xff__= \x01c\x09\x0d\x09.~\x01\x01 c\x0a=~\x01_aab cc\x01\xffa\x0a\x0a.\x0da \xff.~ _", 108, 0, 1, c"~\x0d._\x0a\x0d_c\x0d\x09bc\x0a_~b~=5F\x0a\x0d~\x0a=3D_=3D\x0d\x09~=01c.b=FF=5Fa=09\x0a=5F=FF\x0d=FFcb=FF_~_\x0a=FF\x0d\x09~c=5F\x0aaa=3D\x0ab=3Dc\x09__=FF=5F=5F=3D_=01c\x09\x0d\x09.~=01=01_c\x0a=3D~=01=5Faab_cc=01=FFa\x0a\x0a=2E\x0da_=FF.~_=5F", 166)
	check_qp_encode(c"~\x0d. \x0a\x0d c\x0d\x09bc\x0a ~b~_\x0d\x0a\x0d~\x0d\x0a= =\x0d\x09~\x01c.b\xff_a\x09\x0a_\xff\x0d\xffcb\xff ~ \x0a\xff\x0d\x09~c_\x0aaa=\x0ab=c\x09  \xff__= \x01c\x09\x0d\x09.~\x01\x01 c\x0a=~\x01_aab cc\x01\xffa\x0a\x0a.\x0da \xff.~ _", 108, 1, 0, c"~\x0d.=20\x0a\x0d=20c\x0d=09bc\x0a=20~b~_\x0a\x0d~\x0a=3D=20=3D\x0d=09~=01c.b=FF_a=09\x0a_=FF\x0d=FFcb=FF=20~=20\x0a=FF\x0d=09~c_\x0aaa=3D\x0ab=3Dc=09=20=20=FF__=3D=20=01c=09\x0d=09.~=01=01=20c\x0a=3D~=01_aab=20cc=01=FFa\x0a\x0a=2E\x0da=20=FF.~=20_", 188)
	check_qp_encode(c"~\x0d. \x0a\x0d c\x0d\x09bc\x0a ~b~_\x0d\x0a\x0d~\x0d\x0a= =\x0d\x09~\x01c.b\xff_a\x09\x0a_\xff\x0d\xffcb\xff ~ \x0a\xff\x0d\x09~c_\x0aaa=\x0ab=c\x09  \xff__= \x01c\x09\x0d\x09.~\x01\x01 c\x0a=~\x01_aab cc\x01\xffa\x0a\x0a.\x0da \xff.~ _", 108, 1, 1, c"~\x0d.=20\x0a\x0d=20c\x0d=09bc\x0a=20~b~=5F\x0a\x0d~\x0a=3D=20=3D\x0d=09~=01c.b=FF=5Fa=09\x0a=5F=FF\x0d=FFcb=FF=20~=20\x0a=FF\x0d=09~c=5F\x0aaa=3D\x0ab=3Dc=09=20=20=FF=5F=5F=3D=20=01c=09\x0d=09.~=01=01=20c\x0a=3D~=01=5Faab=20cc=01=FFa\x0a\x0a=2E\x0da=20=FF.~=20=5F", 204)
	check_qp_encode(c" \x0aa\x09\x01\x09\xff__ = a\xff\x09.ba\x01ac\x0a_\x01.\xff \xff.\x09_\x0d=. _bb__c.~   \x01\x0a\x01b\x0a\x0a\x0a=cca_~\x09~b\x0a_b\x0d~\x0a\x0da\x0d=.\x09b\x0d\x0d\x09\x09a._ba\x01b \xff\xff\x0d_~~_\xffa~\x01~\xffb\x0d.b a", 106, 0, 0, c"=20\x0aa\x09=01\x09=FF__ =3D a=FF\x09.ba=01ac\x0a_=01.=FF =FF.\x09_\x0d=3D. _bb__c.~   =01\x0a=01b\x0a\x0a\x0a=3Dcca_~\x09~b\x0a_b\x0d~\x0a\x0da\x0d=3D.\x09b\x0d\x0d\x09\x09a._ba=01b =FF=FF\x0d_~~_=FFa~=01~=FFb\x0d.b a", 146)
	check_qp_encode(c" \x0aa\x09\x01\x09\xff__ = a\xff\x09.ba\x01ac\x0a_\x01.\xff \xff.\x09_\x0d=. _bb__c.~   \x01\x0a\x01b\x0a\x0a\x0a=cca_~\x09~b\x0a_b\x0d~\x0a\x0da\x0d=.\x09b\x0d\x0d\x09\x09a._ba\x01b \xff\xff\x0d_~~_\xffa~\x01~\xffb\x0d.b a", 106, 0, 1, c"_\x0aa\x09=01\x09=FF=5F=5F_=3D_a=FF\x09.ba=01ac\x0a=5F=01.=FF_=FF.\x09=5F\x0d=3D._=5Fbb=5F=5Fc.~___=01\x0a=01b\x0a\x0a\x0a=3Dcca=5F~\x09~b\x0a=5Fb\x0d~\x0a\x0da\x0d=3D.\x09b\x0d\x0d\x09\x09a.=5Fba=01b_=FF=FF\x0d=5F~~=5F=FFa~=01~=FFb\x0d.b_a", 168)
	check_qp_encode(c" \x0aa\x09\x01\x09\xff__ = a\xff\x09.ba\x01ac\x0a_\x01.\xff \xff.\x09_\x0d=. _bb__c.~   \x01\x0a\x01b\x0a\x0a\x0a=cca_~\x09~b\x0a_b\x0d~\x0a\x0da\x0d=.\x09b\x0d\x0d\x09\x09a._ba\x01b \xff\xff\x0d_~~_\xffa~\x01~\xffb\x0d.b a", 106, 1, 0, c"=20\x0aa=09=01=09=FF__=20=3D=20a=FF=09.ba=01ac\x0a_=01.=FF=20=FF.=09_\x0d=3D.=20_bb__c.~=20=20=20=01\x0a=01b\x0a\x0a\x0a=3Dcca_~=09~b\x0a_b\x0d~\x0a\x0da\x0d=3D.=09b\x0d\x0d=09=09a._ba=01b=20=FF=FF\x0d_~~_=FFa~=01~=FFb\x0d.b=20a", 180)
	check_qp_encode(c" \x0aa\x09\x01\x09\xff__ = a\xff\x09.ba\x01ac\x0a_\x01.\xff \xff.\x09_\x0d=. _bb__c.~   \x01\x0a\x01b\x0a\x0a\x0a=cca_~\x09~b\x0a_b\x0d~\x0a\x0da\x0d=.\x09b\x0d\x0d\x09\x09a._ba\x01b \xff\xff\x0d_~~_\xffa~\x01~\xffb\x0d.b a", 106, 1, 1, c"=20\x0aa=09=01=09=FF=5F=5F=20=3D=20a=FF=09.ba=01ac\x0a=5F=01.=FF=20=FF.=09=5F\x0d=3D.=20=5Fbb=5F=5Fc.~=20=20=20=01\x0a=01b\x0a\x0a\x0a=3Dcca=5F~=09~b\x0a=5Fb\x0d~\x0a\x0da\x0d=3D.=09b\x0d\x0d=09=09a.=5Fba=01b=20=FF=FF\x0d=5F~~=5F=FFa~=01~=FFb\x0d.b=20a", 204)
	check_qp_encode(c"\x0a~b~\x0d\xff\xff  .c\xff _~ca \xff=~b\x0d.\xffc\x0a\x0da\x0d\x0d_\x09\xff\x01b\x0a.\x01\x01 .\x0d\x0db_\x0dab=~.", 52, 0, 0, c"\x0a~b~\x0d=FF=FF  .c=FF _~ca =FF=3D~b\x0d.=FFc\x0a\x0da\x0d\x0d_\x09=FF=01b\x0a.=01=01 .\x0d\x0db_\x0dab=3D~.", 74)
	check_qp_encode(c"\x0a~b~\x0d\xff\xff  .c\xff _~ca \xff=~b\x0d.\xffc\x0a\x0da\x0d\x0d_\x09\xff\x01b\x0a.\x01\x01 .\x0d\x0db_\x0dab=~.", 52, 0, 1, c"\x0a~b~\x0d=FF=FF__.c=FF_=5F~ca_=FF=3D~b\x0d.=FFc\x0a\x0da\x0d\x0d=5F\x09=FF=01b\x0a.=01=01_.\x0d\x0db=5F\x0dab=3D~.", 80)
	check_qp_encode(c"\x0a~b~\x0d\xff\xff  .c\xff _~ca \xff=~b\x0d.\xffc\x0a\x0da\x0d\x0d_\x09\xff\x01b\x0a.\x01\x01 .\x0d\x0db_\x0dab=~.", 52, 1, 0, c"\x0a~b~\x0d=FF=FF=20=20.c=FF=20_~ca=20=FF=3D~b\x0d.=FFc\x0a\x0da\x0d\x0d_=09=FF=01b\x0a.=01=01=20.\x0d\x0db_\x0dab=3D~.", 86)
	check_qp_encode(c"\x0a~b~\x0d\xff\xff  .c\xff _~ca \xff=~b\x0d.\xffc\x0a\x0da\x0d\x0d_\x09\xff\x01b\x0a.\x01\x01 .\x0d\x0db_\x0dab=~.", 52, 1, 1, c"\x0a~b~\x0d=FF=FF=20=20.c=FF=20=5F~ca=20=FF=3D~b\x0d.=FFc\x0a\x0da\x0d\x0d=5F=09=FF=01b\x0a.=01=01=20.\x0d\x0db=5F\x0dab=3D~.", 92)

void test_base64_table():
	check_a2b(c"", 0, 1, c"", 0)
	check_b64_body(c"", 0, c"", 0)
	check_a2b(c"QQ==", 4, 1, c"A", 1)
	check_b64_body(c"QQ==", 4, c"A", 1)
	check_a2b(c"QQ", 2, 0, c"", 0)
	check_b64_body(c"QQ", 2, c"A", 1)
	check_a2b(c"QUI", 3, 0, c"", 0)
	check_b64_body(c"QUI", 3, c"AB", 2)
	check_a2b(c"QUJD", 4, 1, c"ABC", 3)
	check_b64_body(c"QUJD", 4, c"ABC", 3)
	check_a2b(c"Q", 1, 0, c"", 0)
	check_b64_body(c"Q", 1, c"Q", 1)
	check_a2b(c"QUJDR", 5, 0, c"", 0)
	check_b64_body(c"QUJDR", 5, c"QUJDR", 5)
	check_a2b(c"QQ==QUJD", 8, 0, c"", 0)
	check_b64_body(c"QQ==QUJD", 8, c"A\x04\x14$", 4)
	check_a2b(c"Q===", 4, 0, c"", 0)
	check_b64_body(c"Q===", 4, c"Q===", 4)
	check_a2b(c"QQ=", 3, 0, c"", 0)
	check_b64_body(c"QQ=", 3, c"A", 1)
	check_a2b(c"Q Q = =", 7, 1, c"A", 1)
	check_b64_body(c"Q Q = =", 7, c"A", 1)
	check_a2b(c"*QUJD*", 6, 1, c"ABC", 3)
	check_b64_body(c"*QUJD*", 6, c"ABC", 3)
	check_a2b(c"QUJ\x0aD", 5, 1, c"ABC", 3)
	check_b64_body(c"QUJ\x0aD", 5, c"ABC", 3)
	check_a2b(c"QU\x0d\x0aJD\x0d\x0a", 8, 1, c"ABC", 3)
	check_b64_body(c"QU\x0d\x0aJD\x0d\x0a", 8, c"ABC", 3)
	check_a2b(c"=QQ==", 5, 1, c"A", 1)
	check_b64_body(c"=QQ==", 5, c"A", 1)
	check_a2b(c"QR==", 4, 1, c"A", 1)
	check_b64_body(c"QR==", 4, c"A", 1)
	check_a2b(c"QUJ=QUJD", 8, 0, c"", 0)
	check_b64_body(c"QUJ=QUJD", 8, c"ABPP\x90", 5)
	check_a2b(c"YS1EV/UUYtRR JRFRSS", 19, 0, c"", 0)
	check_b64_body(c"YS1EV/UUYtRR JRFRSS", 19, c"a-DW\xf5\x14b\xd4Q%\x11QI", 13)
	check_a2b(c"JDVWFFVJdd*", 11, 0, c"", 0)
	check_b64_body(c"JDVWFFVJdd*", 11, c"$5V\x14UIu", 7)
	check_a2b(c"d\x0aMRFFYlU", 9, 1, c"t\xc4E\x15\x89T", 6)
	check_b64_body(c"d\x0aMRFFYlU", 9, c"t\xc4E\x15\x89T", 6)
	check_a2b(c"h ", 2, 0, c"", 0)
	check_b64_body(c"h ", 2, c"h ", 2)
	check_a2b(c"l*JQJJ5JR", 9, 1, c"\x94\x94\x09'\x92Q", 6)
	check_b64_body(c"l*JQJJ5JR", 9, c"\x94\x94\x09'\x92Q", 6)
	check_a2b(c"+//V*RF*1QU0UoUJVUSV", 20, 0, c"", 0)
	check_b64_body(c"+//V*RF*1QU0UoUJVUSV", 20, c"\xfb\xff\xd5D]PSE(P\x95TI", 13)
	check_a2b(c" SWFR!WFoVJ\x0dPYVMV\x0dE\x0d", 20, 0, c"", 0)
	check_b64_body(c" SWFR!WFoVJ\x0dPYVMV\x0dE\x0d", 20, c"IaQXZ\x15$\xf6\x151Q", 11)
	check_a2b(c"VVUD", 4, 1, c"UU\x03", 3)
	check_b64_body(c"VVUD", 4, c"UU\x03", 3)
	check_a2b(c"RW\x0aDFJlTYFVMU=VURUR", 19, 0, c"", 0)
	check_b64_body(c"RW\x0aDFJlTYFVMU=VURUR", 19, c"RWDFJlTYFVMU=VURUR", 18)
	check_a2b(c"*dYdTJ\x0dRF1UlR", 13, 0, c"", 0)
	check_b64_body(c"*dYdTJ\x0dRF1UlR", 13, c"u\x87S%\x11uRT", 8)
	check_a2b(c"DJVUkkJP0WP1YDtW*JR*", 20, 0, c"", 0)
	check_b64_body(c"DJVUkkJP0WP1YDtW*JR*", 20, c"\x0c\x95T\x92BO\xd1c\xf5`;V%", 13)
	check_a2b(c"V1JkYdR\x0a!GQ", 11, 0, c"", 0)
	check_b64_body(c"V1JkYdR\x0a!GQ", 11, c"V1JkYdR!GQ", 10)
	check_a2b(c"VPQ\x0aUTVYW 1", 11, 0, c"", 0)
	check_b64_body(c"VPQ\x0aUTVYW 1", 11, c"VPQUTVYW 1", 10)
	check_a2b(c"PUoT", 4, 1, c"=J\x13", 3)
	check_b64_body(c"PUoT", 4, c"=J\x13", 3)
	check_a2b(c"SDU+5YF+l/5VV+Jk5", 17, 0, c"", 0)
	check_b64_body(c"SDU+5YF+l/5VV+Jk5", 17, c"SDU+5YF+l/5VV+Jk5", 17)
	check_a2b(c"1WR PttVUdVWT00hT5", 18, 0, c"", 0)
	check_b64_body(c"1WR PttVUdVWT00hT5", 18, c"1WR PttVUdVWT00hT5", 18)
	check_a2b(c"Pd0U5V\x0d=DRVS0oVRDQUU", 20, 0, c"", 0)
	check_b64_body(c"Pd0U5V\x0d=DRVS0oVRDQUU", 20, c"=\xdd\x14\xe5P\xd1U-(U\x10\xd0Q", 13)
	check_a2b(c"VRVlVoU ShV!WU", 14, 1, c"U\x15eV\x85\x12\x85U\x94", 9)
	check_b64_body(c"VRVlVoU ShV!WU", 14, c"U\x15eV\x85\x12\x85U\x94", 9)
	check_a2b(c"!", 1, 1, c"", 0)
	check_b64_body(c"!", 1, c"", 0)
	check_a2b(c"YQS", 3, 0, c"", 0)
	check_b64_body(c"YQS", 3, c"a\x04", 2)
	check_a2b(c"FF\x0aUSU", 6, 0, c"", 0)
	check_b64_body(c"FF\x0aUSU", 6, c"FFUSU", 5)
	check_a2b(c"5U!+", 4, 0, c"", 0)
	check_b64_body(c"5U!+", 4, c"\xe5O", 2)
	check_a2b(c"*oTJU\x0aFM=QE!U!UR\x0aQ=YUVU", 23, 1, c"\xa12T\x14\xc4\x04QDPaET", 12)
	check_b64_body(c"*oTJU\x0aFM=QE!U!UR\x0aQ=YUVU", 23, c"\xa12T\x14\xc4\x04QDPaET", 12)
	check_a2b(c"T\x0dVRV+DWU d", 11, 0, c"", 0)
	check_b64_body(c"T\x0dVRV+DWU d", 11, c"TVRV+DWU d", 10)
	check_a2b(c"FRJGW", 5, 0, c"", 0)
	check_b64_body(c"FRJGW", 5, c"FRJGW", 5)
	check_a2b(c"GRWQJSVEQ!RWloYToU=UR", 21, 0, c"", 0)
	check_b64_body(c"GRWQJSVEQ!RWloYToU=UR", 21, c"\x19\x15\x90%%DA\x15\xa5\xa1\x84\xe8QD", 14)
	check_a2b(c"l!SWTVJJ5UVFd*+Y dl", 19, 1, c"\x95%\x93T\x92yQQ]\xf9\x87e", 12)
	check_b64_body(c"l!SWTVJJ5UVFd*+Y dl", 19, c"\x95%\x93T\x92yQQ]\xf9\x87e", 12)
	check_a2b(c"\x0d*QJJJ=VRV", 10, 0, c"", 0)
	check_b64_body(c"\x0d*QJJJ=VRV", 10, c"@\x92IU\x15", 5)
	check_a2b(c"RUJ\x0dJ0RYkRVtSPV 5* ", 19, 0, c"", 0)
	check_b64_body(c"RUJ\x0dJ0RYkRVtSPV 5* ", 19, c"EBI\xd1\x16$E[R=^", 11)
	check_a2b(c"\x0dRYGGFFTFJRS+k", 14, 0, c"", 0)
	check_b64_body(c"\x0dRYGGFFTFJRS+k", 14, c"RYGGFFTFJRS+k", 13)
	check_a2b(c"VDJW5VhVUkT\x0dRE/WRWF=d", 21, 0, c"", 0)
	check_b64_body(c"VDJW5VhVUkT\x0dRE/WRWF=d", 21, c"T2V\xe5XURD\xd1\x13\xf5\x91XW", 14)
	check_a2b(c"F PRS5/0MhdFQEl", 15, 0, c"", 0)
	check_b64_body(c"F PRS5/0MhdFQEl", 15, c"\x14\xf4R\xe7\xfd\x0c\x85\xd1P\x12", 10)
	check_a2b(c"/TU", 3, 0, c"", 0)
	check_b64_body(c"/TU", 3, c"\xfd5", 2)
	check_a2b(c"*tVlYVtUTUUV\x0d1V/ VF", 19, 1, c"\xb5YXV\xd5\x13QEuW\xf5E", 12)
	check_b64_body(c"*tVlYVtUTUUV\x0d1V/ VF", 19, c"\xb5YXV\xd5\x13QEuW\xf5E", 12)
	check_a2b(c"WVV", 3, 0, c"", 0)
	check_b64_body(c"WVV", 3, c"YU", 2)
	check_a2b(c"t0WWoU=FhVkU ", 13, 0, c"", 0)
	check_b64_body(c"t0WWoU=FhVkU ", 13, c"\xb7E\x96\xa1AaVE", 8)
	check_a2b(c"UM\x0aQESQEodhhJV", 14, 0, c"", 0)
	check_b64_body(c"UM\x0aQESQEodhhJV", 14, c"UMQESQEodhhJV", 13)
	check_a2b(c"VMTWQU", 6, 0, c"", 0)
	check_b64_body(c"VMTWQU", 6, c"T\xc4\xd6A", 4)
	check_a2b(c"UlD\x0dDRVRMTP", 11, 0, c"", 0)
	check_b64_body(c"UlD\x0dDRVRMTP", 11, c"RP\xc3ETLL", 7)
	check_a2b(c"MSWP\x0adVMM0hWTP\x0d*dV", 18, 0, c"", 0)
	check_b64_body(c"MSWP\x0adVMM0hWTP\x0d*dV", 18, c"1%\x8fuS\x0c\xd2\x15\x93=\xd5", 11)
	check_b64_encode(c"", 0, c"", 0)
	check_b64_encode(c"\x0b", 1, c"Cw==\x0a", 5)
	check_b64_encode(c"\x0b0", 2, c"CzA=\x0a", 5)
	check_b64_encode(c"\x0b0U", 3, c"CzBV\x0a", 5)
	check_b64_encode(c"\x0b0Uz\x9f\xc4\xe9\x0e3X}\xa2\xc7\xec\x116[\x80\xa5\xca\xef\x149^\x83\xa8\xcd\xf2\x17<a\x86\xab\xd0\xf5\x1a?d\x89\xae\xd3\xf8\x1dBg\x8c\xb1\xd6\xfb Ej\x8f\xb4\xd9\xfe", 56, c"CzBVep/E6Q4zWH2ix+wRNluApcrvFDleg6jN8hc8YYar0PUaP2SJrtP4HUJnjLHW+yBFao+02f4=\x0a", 77)
	check_b64_encode(c"\x0b0Uz\x9f\xc4\xe9\x0e3X}\xa2\xc7\xec\x116[\x80\xa5\xca\xef\x149^\x83\xa8\xcd\xf2\x17<a\x86\xab\xd0\xf5\x1a?d\x89\xae\xd3\xf8\x1dBg\x8c\xb1\xd6\xfb Ej\x8f\xb4\xd9\xfe#", 57, c"CzBVep/E6Q4zWH2ix+wRNluApcrvFDleg6jN8hc8YYar0PUaP2SJrtP4HUJnjLHW+yBFao+02f4j\x0a", 77)
	check_b64_encode(c"\x0b0Uz\x9f\xc4\xe9\x0e3X}\xa2\xc7\xec\x116[\x80\xa5\xca\xef\x149^\x83\xa8\xcd\xf2\x17<a\x86\xab\xd0\xf5\x1a?d\x89\xae\xd3\xf8\x1dBg\x8c\xb1\xd6\xfb Ej\x8f\xb4\xd9\xfe#H", 58, c"CzBVep/E6Q4zWH2ix+wRNluApcrvFDleg6jN8hc8YYar0PUaP2SJrtP4HUJnjLHW+yBFao+02f4j\x0aSA==\x0a", 82)
	check_b64_encode(c"\x0b0Uz\x9f\xc4\xe9\x0e3X}\xa2\xc7\xec\x116[\x80\xa5\xca\xef\x149^\x83\xa8\xcd\xf2\x17<a\x86\xab\xd0\xf5\x1a?d\x89\xae\xd3\xf8\x1dBg\x8c\xb1\xd6\xfb Ej\x8f\xb4\xd9\xfe#Hm\x92\xb7\xdc\x01&Kp\x95\xba\xdf\x04)Ns\x98\xbd\xe2\x07,Qv\x9b\xc0\xe5\x0a/Ty\x9e\xc3\xe8\x0d2W|\xa1\xc6\xeb\x105Z\x7f\xa4\xc9\xee\x138]\x82\xa7\xcc\xf1\x16;`", 114, c"CzBVep/E6Q4zWH2ix+wRNluApcrvFDleg6jN8hc8YYar0PUaP2SJrtP4HUJnjLHW+yBFao+02f4j\x0aSG2St9wBJktwlbrfBClOc5i94gcsUXabwOUKL1R5nsPoDTJXfKHG6xA1Wn+kye4TOF2Cp8zxFjtg\x0a", 154)
	check_b64_encode(c"\x0b0Uz\x9f\xc4\xe9\x0e3X}\xa2\xc7\xec\x116[\x80\xa5\xca\xef\x149^\x83\xa8\xcd\xf2\x17<a\x86\xab\xd0\xf5\x1a?d\x89\xae\xd3\xf8\x1dBg\x8c\xb1\xd6\xfb Ej\x8f\xb4\xd9\xfe#Hm\x92\xb7\xdc\x01&Kp\x95\xba\xdf\x04)Ns\x98\xbd\xe2\x07,Qv\x9b\xc0\xe5\x0a/Ty\x9e\xc3\xe8\x0d2W|\xa1\xc6\xeb\x105Z\x7f\xa4\xc9\xee\x138]\x82\xa7\xcc\xf1\x16;`\x85\xaa\xcf\xf4\x19>c\x88\xad\xd2\xf7\x1cAf\x8b\xb0\xd5\xfa\x1fDi\x8e\xb3\xd8\xfd\"Gl\x91\xb6\xdb\x00%Jo\x94\xb9\xde\x03(Mr\x97\xbc\xe1\x06+Pu\x9a\xbf\xe4\x09.Sx\x9d\xc2\xe7\x0c1V{\xa0\xc5\xea\x0f4Y~\xa3\xc8\xed\x127\\\x81\xa6\xcb\xf0\x15:_\x84\xa9\xce", 200, c"CzBVep/E6Q4zWH2ix+wRNluApcrvFDleg6jN8hc8YYar0PUaP2SJrtP4HUJnjLHW+yBFao+02f4j\x0aSG2St9wBJktwlbrfBClOc5i94gcsUXabwOUKL1R5nsPoDTJXfKHG6xA1Wn+kye4TOF2Cp8zxFjtg\x0aharP9Bk+Y4it0vccQWaLsNX6H0RpjrPY/SJHbJG22wAlSm+Uud4DKE1yl7zhBitQdZq/5AkuU3id\x0awucMMVZ7oMXqDzRZfqPI7RI3XIGmy/AVOl+Eqc4=\x0a", 272)

void test_decode_header_table():
	check_decode_header(c"plain text, no words", c"-|plain text, no words;")
	check_header_utf8(c"plain text, no words", c"plain text, no words")
	check_decode_header(c"=?utf-8?q?caf=C3=A9?=", c"utf-8|caf\\xc3\\xa9;")
	check_header_utf8(c"=?utf-8?q?caf=C3=A9?=", c"caf\xc3\xa9")
	check_decode_header(c"=?UTF-8?B?Y2Fmw6k=?=", c"utf-8|caf\\xc3\\xa9;")
	check_header_utf8(c"=?UTF-8?B?Y2Fmw6k=?=", c"caf\xc3\xa9")
	check_decode_header(c"=?utf-8?b?Y2Fmw6k?=", c"utf-8|caf\\xc3\\xa9;")
	check_header_utf8(c"=?utf-8?b?Y2Fmw6k?=", c"caf\xc3\xa9")
	check_decode_header(c"=?iso-8859-1?q?h=E9llo?= world", c"iso-8859-1|h\\xe9llo;-| world;")
	check_header_utf8(c"=?iso-8859-1?q?h=E9llo?= world", c"h\xc3\xa9llo world")
	check_decode_header(c"Re: =?iso-8859-1?q?h=E9llo?=", c"-|Re: ;iso-8859-1|h\\xe9llo;")
	check_header_utf8(c"Re: =?iso-8859-1?q?h=E9llo?=", c"Re: h\xc3\xa9llo")
	check_decode_header(c"=?utf-8?q?a?= =?utf-8?q?b?=", c"utf-8|ab;")
	check_header_utf8(c"=?utf-8?q?a?= =?utf-8?q?b?=", c"ab")
	check_decode_header(c"=?utf-8?q?a?=   \x09 =?utf-8?q?b?=", c"utf-8|ab;")
	check_header_utf8(c"=?utf-8?q?a?=   \x09 =?utf-8?q?b?=", c"ab")
	check_decode_header(c"=?utf-8?q?a?=\x0a =?utf-8?q?b?=", c"utf-8|ab;")
	check_header_utf8(c"=?utf-8?q?a?=\x0a =?utf-8?q?b?=", c"ab")
	check_decode_header(c"=?utf-8?q?a?= x =?utf-8?q?b?=", c"utf-8|a;-| x ;utf-8|b;")
	check_header_utf8(c"=?utf-8?q?a?= x =?utf-8?q?b?=", c"a x b")
	check_decode_header(c"=?utf-8?q?a?= =?iso-8859-1?q?b?=", c"utf-8|a;iso-8859-1|b;")
	check_header_utf8(c"=?utf-8?q?a?= =?iso-8859-1?q?b?=", c"ab")
	check_decode_header(c"=?utf-8?q?a_b?=", c"utf-8|a b;")
	check_header_utf8(c"=?utf-8?q?a_b?=", c"a b")
	check_decode_header(c"=?utf-8?q?a=5Fb=3d?=", c"utf-8|a_b=;")
	check_header_utf8(c"=?utf-8?q?a=5Fb=3d?=", c"a_b=")
	check_decode_header(c"=?utf-8?q?bad=ZZ?=", c"utf-8|bad=ZZ;")
	check_header_utf8(c"=?utf-8?q?bad=ZZ?=", c"bad=ZZ")
	check_decode_header(c"pre=?utf-8?q?x?=post", c"-|pre;utf-8|x;-|post;")
	check_header_utf8(c"pre=?utf-8?q?x?=post", c"pre x post")
	check_decode_header(c"=?utf-8?q??=", c"utf-8|;")
	check_header_utf8(c"=?utf-8?q??=", c"")
	check_decode_header(c"=??q?abc?=", c"|abc;")
	check_decode_header(c"=?utf-8?x?abc?=", c"-|=?utf-8?x?abc?=;")
	check_header_utf8(c"=?utf-8?x?abc?=", c"=?utf-8?x?abc?=")
	check_decode_header(c"=?utf-8?q?unterminated", c"-|=?utf-8?q?unterminated;")
	check_header_utf8(c"=?utf-8?q?unterminated", c"=?utf-8?q?unterminated")
	check_decode_header(c"line one\x0a line two", c"-|line one\\x0a line two;")
	check_header_utf8(c"line one\x0a line two", c"line one\x0a line two")
	check_decode_header(c"a =?utf-8?q?x?=\x0a b\x0a c", c"-|a ;utf-8|x;-|b c;")
	check_header_utf8(c"a =?utf-8?q?x?=\x0a b\x0a c", c"a x b c")
	check_decode_header(c"   leading =?us-ascii?q?ascii?= trailing  ", c"-|leading ;us-ascii|ascii;-| trailing  ;")
	check_header_utf8(c"   leading =?us-ascii?q?ascii?= trailing  ", c"leading  ascii  trailing  ")
	check_decode_header(c"=?us-ascii?q?a?= b", c"us-ascii|a;-| b;")
	check_header_utf8(c"=?us-ascii?q?a?= b", c"a  b")
	check_decode_header(c"=?ascii?q?a?=b", c"ascii|a;-|b;")
	check_header_utf8(c"=?ascii?q?a?=b", c"a b")
	check_decode_header(c"=?utf-8?q?x?=(comment)", c"utf-8|x;-|(comment);")
	check_header_utf8(c"=?utf-8?q?x?=(comment)", c"x(comment)")
	check_decode_header(c"(c)=?utf-8?q?x?=", c"-|(c);utf-8|x;")
	check_header_utf8(c"(c)=?utf-8?q?x?=", c"(c)x")
	check_decode_header(c"=?utf-8?b?QUJD?==?utf-8?b?REVG?=", c"utf-8|ABCDEF;")
	check_header_utf8(c"=?utf-8?b?QUJD?==?utf-8?b?REVG?=", c"ABCDEF")
	check_decode_header(c"=?utf-8?b?Q?=", c"ERROR")
	check_header_utf8(c"=?utf-8?b?Q?=", 0)
	check_decode_header(c"=?utf-8?b?QUJ?=", c"utf-8|AB;")
	check_header_utf8(c"=?utf-8?b?QUJ?=", c"AB")
	check_decode_header(c"=?utf-8?b?Q*Q?=", c"ERROR")
	check_header_utf8(c"=?utf-8?b?Q*Q?=", 0)
	check_decode_header(c"=?utf-8*en?q?lang?=", c"utf-8*en|lang;")
	check_decode_header(c"=?WINDOWS-1252?q?=93quoted=94?=", c"windows-1252|\\x93quoted\\x94;")
	check_header_utf8(c"=?WINDOWS-1252?q?=93quoted=94?=", c"\xe2\x80\x9cquoted\xe2\x80\x9d")
	check_decode_header(c"=?iso-8859-1?b?6Q==?= =?utf-8?b?w6k=?=", c"iso-8859-1|\\xe9;utf-8|\\xc3\\xa9;")
	check_header_utf8(c"=?iso-8859-1?b?6Q==?= =?utf-8?b?w6k=?=", c"\xc3\xa9\xc3\xa9")
	check_decode_header(c"=?utf-8?q?=E2=82=AC?= 100", c"utf-8|\\xe2\\x82\\xac;-| 100;")
	check_header_utf8(c"=?utf-8?q?=E2=82=AC?= 100", c"\xe2\x82\xac 100")
	check_decode_header(c"x =?utf-8?q?a?=\x09y", c"-|x ;utf-8|a;-|\\x09y;")
	check_header_utf8(c"x =?utf-8?q?a?=\x09y", c"x a\x09y")
	check_decode_header(c"=?utf-8?q?one?=\x0d\x0a =?utf-8?q?two?=", c"utf-8|onetwo;")
	check_header_utf8(c"=?utf-8?q?one?=\x0d\x0a =?utf-8?q?two?=", c"onetwo")
	check_decode_header(c"=?utf-8?q?a?= \x0b =?utf-8?q?b?=", c"utf-8|ab;")
	check_header_utf8(c"=?utf-8?q?a?= \x0b =?utf-8?q?b?=", c"ab")
	check_decode_header(c"Subject: =?koi8-r?b?8NLJ18XU?=", c"-|Subject: ;koi8-r|\\xf0\\xd2\\xc9\\xd7\\xc5\\xd4;")

void test_encode_word_table():
	check_encode_word(c"hello", 5, c"utf-8", 0, c"=?utf-8?q?hello?=")
	check_encode_word(c"\xe2\x82\xac\xe2\x82\xac\xe2\x82\xac", 9, c"utf-8", 0, c"=?utf-8?b?4oKs4oKs4oKs?=")
	check_encode_word(c"h\xc3\xa9llo w\xc3\xb6rld", 13, c"utf-8", 0, c"=?utf-8?b?aMOpbGxvIHfDtnJsZA==?=")
	check_encode_word(c"h\xe9llo w\xf6rld", 11, c"iso-8859-1", 'q', c"=?iso-8859-1?q?h=E9llo_w=F6rld?=")
	check_encode_word(c"abc", 3, c"utf-8", 'q', c"=?utf-8?q?abc?=")
	check_encode_word(c"a b_c=d?e", 9, c"iso-8859-1", 'q', c"=?iso-8859-1?q?a_b=5Fc=3Dd=3Fe?=")
	check_encode_word(c"-!*+/ ok", 8, c"iso-8859-1", 'q', c"=?iso-8859-1?q?-!*+/_ok?=")
	check_encode_word(c"", 0, c"utf-8", 0, c"=?utf-8?q??=")

void test_params_table():
	check_params(c"text/plain", c"text/plain=;")
	check_params(c"text/plain; charset=\"us-ascii\"", c"text/plain=;charset=us-ascii;")
	check_params(c"TEXT/HTML ; CharSet = UTF-8 ; format=flowed", c"TEXT/HTML=;charset=UTF-8;format=flowed;")
	check_params(c"multipart/mixed; boundary=\"a;b\"; x=1", c"multipart/mixed=;boundary=a;b;x=1;")
	check_params(c"multipart/mixed; boundary=\"quoted \\\"inner\\\" \\\\ back\"", c"multipart/mixed=;boundary=quoted \"inner\" \\x5c back;")
	check_params(c"application/x; name=<angle>", c"application/x=;name=angle;")
	check_params(c"a; flag; b=", c"a=;flag=;b=;")
	check_params(c"a;; b=c", c"a=;=;b=c;")
	check_params(c"a; title*=us-ascii'en'This%20is%20%2A%2A%2Afun%2A%2A%2A", c"a=;title*us-ascii'en'This is ***fun***;")
	check_params(c"a; title*0*=us-ascii'en'This%20is%20even%20more%20; title*1*=%2A%2A%2Afun%2A%2A%2A%20; title*2=\"isn't it!\"", c"a=;title*us-ascii'en'This is even more ***fun*** isn't it!;")
	check_params(c"a; name*1=\"world\"; name*0=\"hello \"", c"a=;name=hello world;")
	check_params(c"a; name*=\"noticks%41\"", c"a=;name*-'-'noticksA;")
	check_params(c"a; filename*=UTF-8''na%C3%AFve.txt", c"a=;filename*UTF-8''na\\xc3\\xafve.txt;")
	check_params(c"a; x*2=c; x*0=a; x*1=b; y=1", c"a=;y=1;x=abc;")
	check_params(c"a; x*=zero; x*1=one", c"a=;x*-'-'zeroone;")
	check_params(c"a; x*0=zero; x*=dropped; x*1=one", c"a=;x=zeroone;")
	check_params(c"a; key=\"semi;colon\"; other=2", c"a=;key=semi;colon;other=2;")
	check_params(c"a; key=\"unbalanced; other=2", c"a=;key=\"unbalanced; other=2;")
	check_params(c"a; k = \"spaced value\" ; j=  v  ", c"a=;k=spaced value;j=v;")
	check_params(c"; leading", c"=;leading=;")
	check_params(c"a=b; c=d", c"a=b;c=d;")

void test_fold_table():
	check_fold(c"Subject", c"short", c"\x0a", c"Subject: short\x0a")
	check_fold(c"Subject", c"short", c"\x0d\x0a", c"Subject: short\x0d\x0a")
	check_fold(c"Subject", c"word word word word word word word word word word word word word word word word word word word word ", c"\x0a", c"Subject: word word word word word word word word word word word word word word\x0a word word word word word word \x0a")
	check_fold(c"Subject", c"word word word word word word word word word word word word word word word word word word word word ", c"\x0d\x0a", c"Subject: word word word word word word word word word word word word word word\x0d\x0a word word word word word word \x0d\x0a")
	check_fold(c"Subject", c"tab\x09here  two  spaces q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q ", c"\x0a", c"Subject: tab\x09here  two  spaces q q q q q q q q q q q q q q q q q q q q q q q q\x0a q q q q q q q q q q q q q q q q \x0a")
	check_fold(c"Subject", c"tab\x09here  two  spaces q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q q ", c"\x0d\x0a", c"Subject: tab\x09here  two  spaces q q q q q q q q q q q q q q q q q q q q q q q q\x0d\x0a q q q q q q q q q q q q q q q q \x0d\x0a")
	check_fold(c"Subject", c"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", c"\x0a", c"Subject: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\x0a")
	check_fold(c"Subject", c"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", c"\x0d\x0a", c"Subject: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\x0d\x0a")
	check_fold(c"Subject", c"one two three four five six seven eight nine ten eleven twelve thirteen fourteen", c"\x0a", c"Subject: one two three four five six seven eight nine ten eleven twelve\x0a thirteen fourteen\x0a")
	check_fold(c"Subject", c"one two three four five six seven eight nine ten eleven twelve thirteen fourteen", c"\x0d\x0a", c"Subject: one two three four five six seven eight nine ten eleven twelve\x0d\x0a thirteen fourteen\x0d\x0a")

void test_message_table():
	check_message(c"Subject: hello\x0aFrom: a@example.com\x0a\x0abody line\x0asecond\x0a", 53, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Subject|hello\x0a h From|a@example.com\x0a payload=body line\\x0asecond\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=body line\\x0asecond\\x0a\x0a")
	check_message(c"Subject: folded\x0a  across\x09lines\x0a\x09and tabs\x0aX-Long: a\x0a b\x0a c\x0a\x0abody", 62, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Subject|folded\\x0a  across\\x09lines\\x0a\\x09and tabs\x0a h X-Long|a\\x0a b\\x0a c\x0a payload=body\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=body\x0a")
	check_message(c"Received: one\x0areceived: two\x0aRECEIVED: three\x0aTo: x\x0a\x0a", 51, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Received|one\x0a h received|two\x0a h RECEIVED|three\x0a h To|x\x0a payload=\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=\x0a")
	check_message(c"Subject: crlf\x0d\x0aX-Fold: a\x0d\x0a b\x0d\x0a\x0d\x0aline1\x0d\x0aline2\x0d\x0a", 46, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Subject|crlf\x0a h X-Fold|a\\x0d\\x0a b\x0a payload=line1\\x0d\\x0aline2\\x0d\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=line1\\x0d\\x0aline2\\x0d\\x0a\x0a")
	check_message(c"Subject: cr only\x0dX: y\x0d\x0dbody\x0d", 28, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Subject|cr only\x0a h X|y\x0a payload=body\\x0d\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=body\\x0d\x0a")
	check_message(c" continuation first\x0aSubject: s\x0a\x0abody\x0a", 37, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Subject|s\x0a payload=body\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=FirstHeaderLineIsContinuationDefect\x0a decoded=body\\x0a\x0a")
	check_message(c"From sender@example.com Mon Jan  1 00:00:00 2024\x0aSubject: envelope\x0a\x0ab\x0a", 70, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=From sender@example.com Mon Jan  1 00:00:00 2024\x0a h Subject|envelope\x0a payload=b\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=b\\x0a\x0a")
	check_message(c"Subject: s\x0aFrom bad envelope\x0aTo: t\x0a\x0ab\x0a", 38, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Subject|s\x0a h To|t\x0a payload=b\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=MisplacedEnvelopeHeaderDefect\x0a decoded=b\\x0a\x0a")
	check_message(c"Subject: s\x0aFrom looks like body\x0a\x0arest\x0a", 38, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Subject|s\x0a payload=From looks like body\\x0arest\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=From looks like body\\x0arest\\x0a\x0a")
	check_message(c"Subject: s\x0anot a header line\x0amore\x0a", 34, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Subject|s\x0a payload=not a header line\\x0amore\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=MissingHeaderBodySeparatorDefect\x0a decoded=not a header line\\x0amore\\x0a\x0a")
	check_message(c"Subject: s\x0a: no name\x0aX: y\x0a\x0ab\x0a", 29, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Subject|s\x0a h X|y\x0a payload=b\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=InvalidHeaderDefect\x0a decoded=b\\x0a\x0a")
	check_message(c"Subject: no body", 16, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Subject|no body\x0a payload=\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=\x0a")
	check_message(c"", 0, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a payload=\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=\x0a")
	check_message(c"\x0abody only\x0a", 11, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a payload=body only\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=body only\\x0a\x0a")
	check_message(c"Subject: value:with:colons\x0aX-Empty:\x0aX-Spaces:    \x09 lead\x0a\x0a", 57, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Subject|value:with:colons\x0a h X-Empty|\x0a h X-Spaces|lead\x0a payload=\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=\x0a")
	check_message(c"Content-Type: text/plain; charset=\"ISO-8859-1\"\x0aContent-Transfer-Encoding: quoted-printable\x0a\x0ah=E9llo =\x0aworld=\x0a", 109, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Content-Type|text/plain; charset=\"ISO-8859-1\"\x0a h Content-Transfer-Encoding|quoted-printable\x0a payload=h=E9llo =\\x0aworld=\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=iso-8859-1 disposition=-\x0a defects=\x0a decoded=h\\xe9llo world\x0a")
	check_message(c"Content-Type: application/octet-stream\x0aContent-Transfer-Encoding: base64\x0aContent-Disposition: attachment; filename=\"data.bin\"\x0a\x0aAAECAwQF\x0aBgcICQ==\x0a", 145, c"part 0 type=application/octet-stream default=text/plain mp=0\x0a unixfrom=-\x0a h Content-Type|application/octet-stream\x0a h Content-Transfer-Encoding|base64\x0a h Content-Disposition|attachment; filename=\"data.bin\"\x0a payload=AAECAwQF\\x0aBgcICQ==\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=data.bin charset=- disposition=attachment\x0a defects=\x0a decoded=\\x00\\x01\\x02\\x03\\x04\\x05\\x06\\x07\\x08\\x09\x0a")
	check_message(c"Content-Transfer-Encoding:  Base64 \x0a\x0aaGVsbG8\x0a", 45, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Content-Transfer-Encoding|Base64 \x0a payload=aGVsbG8\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=hello\x0a")
	check_message(c"Content-Transfer-Encoding: base64\x0a\x0aQ\x0a", 37, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Content-Transfer-Encoding|base64\x0a payload=Q\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=Q\x0a")
	check_message(c"Content-Transfer-Encoding: x-uuencode\x0a\x0abegin 644 f\x0a#86)C\x0a`\x0aend\x0a", 63, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Content-Transfer-Encoding|x-uuencode\x0a payload=begin 644 f\\x0a#86)C\\x0a`\\x0aend\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=abc\x0a")
	check_message(c"Content-Type: multipart/mixed; boundary=\"XYZ\"\x0aMIME-Version: 1.0\x0a\x0apreamble line\x0a--XYZ\x0aContent-Type: text/plain\x0a\x0afirst part\x0a--XYZ\x0aContent-Type: text/html; charset=utf-8\x0a\x0a<p>second</p>\x0a\x0a--XYZ--\x0aepilogue text\x0a", 205, c"part 0 type=multipart/mixed default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|multipart/mixed; boundary=\"XYZ\"\x0a h MIME-Version|1.0\x0a preamble=preamble line epilogue=epilogue text\\x0a\x0a boundary=XYZ filename=- charset=- disposition=-\x0a defects=\x0apart 1 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Content-Type|text/plain\x0a payload=first part\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=first part\x0apart 1 type=text/html default=text/plain mp=0\x0a unixfrom=-\x0a h Content-Type|text/html; charset=utf-8\x0a payload=<p>second</p>\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=utf-8 disposition=-\x0a defects=\x0a decoded=<p>second</p>\\x0a\x0a")
	check_message(c"Content-Type: multipart/mixed; boundary=XYZ\x0a\x0a--XYZ\x0a\x0aonly\x0a--XYZ--", 64, c"part 0 type=multipart/mixed default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|multipart/mixed; boundary=XYZ\x0a preamble=- epilogue=\x0a boundary=XYZ filename=- charset=- disposition=-\x0a defects=\x0apart 1 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a payload=only\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=only\x0a")
	check_message(c"Content-Type: multipart/mixed; boundary=XYZ\x0a\x0a--XYZ\x0a\x0aonly\x0a--XYZ--\x0a", 65, c"part 0 type=multipart/mixed default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|multipart/mixed; boundary=XYZ\x0a preamble=- epilogue=\x0a boundary=XYZ filename=- charset=- disposition=-\x0a defects=\x0apart 1 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a payload=only\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=only\x0a")
	check_message(c"Content-Type: multipart/mixed; boundary=XYZ\x0d\x0a\x0d\x0a--XYZ\x0d\x0a\x0d\x0acrlf part\x0d\x0a--XYZ--\x0d\x0a\x0d\x0aepi\x0d\x0a", 83, c"part 0 type=multipart/mixed default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|multipart/mixed; boundary=XYZ\x0a preamble=- epilogue=\\x0d\\x0aepi\\x0d\\x0a\x0a boundary=XYZ filename=- charset=- disposition=-\x0a defects=\x0apart 1 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a payload=crlf part\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=crlf part\x0a")
	check_message(c"Content-Type: multipart/mixed; boundary=\"outer\"\x0a\x0a--outer\x0aContent-Type: multipart/alternative; boundary=\"inner\"\x0a\x0a--inner\x0aContent-Type: text/plain\x0a\x0aplain\x0a--inner\x0aContent-Type: text/html\x0a\x0ahtml\x0a--inner--\x0ainner epilogue\x0a--outer\x0aContent-Type: application/pdf; name=\"report.pdf\"\x0aContent-Transfer-Encoding: base64\x0a\x0aJVBERi0=\x0a--outer--\x0a", 326, c"part 0 type=multipart/mixed default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|multipart/mixed; boundary=\"outer\"\x0a preamble=- epilogue=\x0a boundary=outer filename=- charset=- disposition=-\x0a defects=\x0apart 1 type=multipart/alternative default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|multipart/alternative; boundary=\"inner\"\x0a preamble=- epilogue=inner epilogue\x0a boundary=inner filename=- charset=- disposition=-\x0a defects=\x0apart 2 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Content-Type|text/plain\x0a payload=plain\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=plain\x0apart 2 type=text/html default=text/plain mp=0\x0a unixfrom=-\x0a h Content-Type|text/html\x0a payload=html\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=html\x0apart 1 type=application/pdf default=text/plain mp=0\x0a unixfrom=-\x0a h Content-Type|application/pdf; name=\"report.pdf\"\x0a h Content-Transfer-Encoding|base64\x0a payload=JVBERi0=\x0a preamble=- epilogue=-\x0a boundary=- filename=report.pdf charset=- disposition=-\x0a defects=\x0a decoded=%PDF-\x0a")
	check_message(c"Content-Type: multipart/mixed; boundary=\"outer\"\x0a\x0a--outer\x0aContent-Type: multipart/alternative; boundary=\"inner\"\x0a\x0a--inner\x0a\x0aunclosed inner\x0a--outer\x0a\x0aafter\x0a--outer--\x0a", 161, c"part 0 type=multipart/mixed default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|multipart/mixed; boundary=\"outer\"\x0a preamble=- epilogue=\x0a boundary=outer filename=- charset=- disposition=-\x0a defects=\x0apart 1 type=multipart/alternative default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|multipart/alternative; boundary=\"inner\"\x0a preamble=- epilogue=-\x0a boundary=inner filename=- charset=- disposition=-\x0a defects=CloseBoundaryNotFoundDefect\x0apart 2 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a payload=unclosed inner\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=unclosed inner\x0apart 1 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a payload=after\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=after\x0a")
	check_message(c"Content-Type: multipart/mixed; boundary=b\x0a\x0ano boundary lines at all\x0a", 68, c"part 0 type=multipart/mixed default=text/plain mp=0\x0a unixfrom=-\x0a h Content-Type|multipart/mixed; boundary=b\x0a payload=no boundary lines at all\\x0a\x0a preamble=- epilogue=\x0a boundary=b filename=- charset=- disposition=-\x0a defects=StartBoundaryNotFoundDefect,MultipartInvariantViolationDefect\x0a decoded=no boundary lines at all\\x0a\x0a")
	check_message(c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0a\x0anever closed\x0a", 61, c"part 0 type=multipart/mixed default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|multipart/mixed; boundary=b\x0a preamble=- epilogue=-\x0a boundary=b filename=- charset=- disposition=-\x0a defects=CloseBoundaryNotFoundDefect\x0apart 1 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a payload=never closed\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=never closed\x0a")
	check_message(c"Content-Type: multipart/mixed\x0a\x0amissing boundary param\x0a", 54, c"part 0 type=multipart/mixed default=text/plain mp=0\x0a unixfrom=-\x0a h Content-Type|multipart/mixed\x0a payload=missing boundary param\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=NoBoundaryInMultipartDefect,MultipartInvariantViolationDefect\x0a decoded=missing boundary param\\x0a\x0a")
	check_message(c"Content-Type: multipart/mixed; boundary=b\x0aContent-Transfer-Encoding: base64\x0a\x0a--b\x0a\x0ax\x0a--b--\x0a", 90, c"part 0 type=multipart/mixed default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|multipart/mixed; boundary=b\x0a h Content-Transfer-Encoding|base64\x0a preamble=- epilogue=\x0a boundary=b filename=- charset=- disposition=-\x0a defects=InvalidMultipartContentTransferEncodingDefect\x0apart 1 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a payload=x\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=x\x0a")
	check_message(c"Content-Type: multipart/mixed; boundary=\"b  \"\x0a\x0a--b  \x0a\x0atrailing ws boundary\x0a--b--  \x0a", 83, c"part 0 type=multipart/mixed default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|multipart/mixed; boundary=\"b  \"\x0a preamble=- epilogue=\x0a boundary=b filename=- charset=- disposition=-\x0a defects=\x0apart 1 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a payload=trailing ws boundary\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=trailing ws boundary\x0a")
	check_message(c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0a--b\x0a\x0adoubled boundary\x0a--b--\x0a", 75, c"part 0 type=multipart/mixed default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|multipart/mixed; boundary=b\x0a preamble=- epilogue=\x0a boundary=b filename=- charset=- disposition=-\x0a defects=\x0apart 1 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a payload=doubled boundary\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=doubled boundary\x0a")
	check_message(c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0a--b--\x0a\x0aafter close\x0a", 66, c"part 0 type=multipart/mixed default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|multipart/mixed; boundary=b\x0a preamble=- epilogue=-\x0a boundary=b filename=- charset=- disposition=-\x0a defects=CloseBoundaryNotFoundDefect\x0apart 1 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a payload=after close\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=after close\x0a")
	check_message(c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--bx\x0a--b\x0aX: 1\x0a\x0a--b \x0a--b--\x0a", 69, c"part 0 type=multipart/mixed default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|multipart/mixed; boundary=b\x0a preamble=--bx epilogue=-\x0a boundary=b filename=- charset=- disposition=-\x0a defects=CloseBoundaryNotFoundDefect\x0apart 1 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h X|1\x0a payload=\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=\x0apart 1 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a payload=\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=\x0a")
	check_message(c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0aContent-Type: message/rfc822\x0a\x0aSubject: inner\x0aContent-Type: text/plain\x0a\x0ainner body\x0a--b--\x0a", 135, c"part 0 type=multipart/mixed default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|multipart/mixed; boundary=b\x0a preamble=- epilogue=\x0a boundary=b filename=- charset=- disposition=-\x0a defects=\x0apart 1 type=message/rfc822 default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|message/rfc822\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0apart 2 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Subject|inner\x0a h Content-Type|text/plain\x0a payload=inner body\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=inner body\x0a")
	check_message(c"Content-Type: message/rfc822\x0a\x0aSubject: wrapped\x0a\x0awrapped body\x0a", 61, c"part 0 type=message/rfc822 default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|message/rfc822\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0apart 1 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Subject|wrapped\x0a payload=wrapped body\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=wrapped body\\x0a\x0a")
	check_message(c"Content-Type: multipart/digest; boundary=d\x0a\x0a--d\x0a\x0aSubject: digest one\x0a\x0abody one\x0a--d\x0aContent-Type: text/plain\x0a\x0anot a message\x0a--d--\x0a", 129, c"part 0 type=multipart/digest default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|multipart/digest; boundary=d\x0a preamble=- epilogue=\x0a boundary=d filename=- charset=- disposition=-\x0a defects=\x0apart 1 type=message/rfc822 default=message/rfc822 mp=1\x0a unixfrom=-\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0apart 2 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Subject|digest one\x0a payload=body one\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=body one\x0apart 1 type=text/plain default=message/rfc822 mp=0\x0a unixfrom=-\x0a h Content-Type|text/plain\x0a payload=not a message\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=not a message\x0a")
	check_message(c"Content-Type: multipart/report; boundary=r\x0a\x0a--r\x0aContent-Type: message/delivery-status\x0a\x0aReporting-MTA: dns; mx.example\x0a\x0aFinal-Recipient: rfc822; a@b\x0aAction: failed\x0a\x0a--r--\x0a", 170, c"part 0 type=multipart/report default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|multipart/report; boundary=r\x0a preamble=- epilogue=\x0a boundary=r filename=- charset=- disposition=-\x0a defects=\x0apart 1 type=message/delivery-status default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|message/delivery-status\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0apart 2 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Reporting-MTA|dns; mx.example\x0a payload=\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=\x0apart 2 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Final-Recipient|rfc822; a@b\x0a h Action|failed\x0a payload=\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=\x0a")
	check_message(c"Content-Type: message/delivery-status\x0a\x0aA: 1\x0a\x0aB: 2\x0aC: 3\x0a", 55, c"part 0 type=message/delivery-status default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|message/delivery-status\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0apart 1 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h A|1\x0a payload=\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=\x0apart 1 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h B|2\x0a h C|3\x0a payload=\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=\x0a")
	check_message(c"Content-Type: text/plain; title*0*=us-ascii'en'This%20is%20; title*1*=%2A%2Afun%2A%2A; name*=utf-8''na%C3%AFve.txt; charset*=us-ascii''UTF-8\x0a\x0ax\x0a", 144, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Content-Type|text/plain; title*0*=us-ascii'en'This%20is%20; title*1*=%2A%2Afun%2A%2A; name*=utf-8''na%C3%AFve.txt; charset*=us-ascii''UTF-8\x0a payload=x\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=na\\xc3\\xafve.txt charset=utf-8 disposition=-\x0a defects=\x0a decoded=x\\x0a\x0a")
	check_message(c"Content-Type: text/plain; name=\"a.txt\"\x0aContent-Disposition: INLINE; filename*=iso-8859-1''caf%E9.txt\x0a\x0ax\x0a", 104, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Content-Type|text/plain; name=\"a.txt\"\x0a h Content-Disposition|INLINE; filename*=iso-8859-1''caf%E9.txt\x0a payload=x\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=caf\\xc3\\xa9.txt charset=- disposition=inline\x0a defects=\x0a decoded=x\\x0a\x0a")
	check_message(c"Content-Type: text\x0aContent-Disposition: attachment\x0a\x0abad type\x0a", 61, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Content-Type|text\x0a h Content-Disposition|attachment\x0a payload=bad type\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=attachment\x0a defects=\x0a decoded=bad type\\x0a\x0a")
	check_message(c"Content-Type: a/b/c; charset=\xe9\x0a\x0abad type 2\x0a", 43, c"part 0 type=text/plain default=text/plain mp=0\x0a unixfrom=-\x0a h Content-Type|a/b/c; charset=\\xe9\x0a payload=bad type 2\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=\x0a decoded=bad type 2\\x0a\x0a")
	check_message(c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0aContent-Type: multipart/mixed\x0a\x0anested no boundary\x0a--b--\x0a", 103, c"part 0 type=multipart/mixed default=text/plain mp=1\x0a unixfrom=-\x0a h Content-Type|multipart/mixed; boundary=b\x0a preamble=- epilogue=\x0a boundary=b filename=- charset=- disposition=-\x0a defects=\x0apart 1 type=multipart/mixed default=text/plain mp=0\x0a unixfrom=-\x0a h Content-Type|multipart/mixed\x0a payload=nested no boundary\\x0a\x0a preamble=- epilogue=-\x0a boundary=- filename=- charset=- disposition=-\x0a defects=NoBoundaryInMultipartDefect\x0a decoded=nested no boundary\\x0a\x0a")

void test_as_string_table():
	check_as_string(c"Subject: hello\x0aFrom: a@example.com\x0a\x0abody line\x0asecond\x0a", 53, c"\n", c"Subject: hello\x0aFrom: a@example.com\x0a\x0abody line\x0asecond\x0a", 53)
	check_as_string(c"Subject: hello\x0aFrom: a@example.com\x0a\x0abody line\x0asecond\x0a", 53, c"\r\n", c"Subject: hello\x0d\x0aFrom: a@example.com\x0d\x0a\x0d\x0abody line\x0d\x0asecond\x0d\x0a", 58)
	check_as_string(c"Subject: folded\x0a  across\x09lines\x0a\x09and tabs\x0aX-Long: a\x0a b\x0a c\x0a\x0abody", 62, c"\n", c"Subject: folded\x0a  across\x09lines\x0a\x09and tabs\x0aX-Long: a\x0a b\x0a c\x0a\x0abody", 62)
	check_as_string(c"Subject: folded\x0a  across\x09lines\x0a\x09and tabs\x0aX-Long: a\x0a b\x0a c\x0a\x0abody", 62, c"\r\n", c"Subject: folded\x0d\x0a  across\x09lines\x0d\x0a\x09and tabs\x0d\x0aX-Long: a\x0d\x0a b\x0d\x0a c\x0d\x0a\x0d\x0abody", 69)
	check_as_string(c"Received: one\x0areceived: two\x0aRECEIVED: three\x0aTo: x\x0a\x0a", 51, c"\n", c"Received: one\x0areceived: two\x0aRECEIVED: three\x0aTo: x\x0a\x0a", 51)
	check_as_string(c"Received: one\x0areceived: two\x0aRECEIVED: three\x0aTo: x\x0a\x0a", 51, c"\r\n", c"Received: one\x0d\x0areceived: two\x0d\x0aRECEIVED: three\x0d\x0aTo: x\x0d\x0a\x0d\x0a", 56)
	check_as_string(c"Subject: crlf\x0d\x0aX-Fold: a\x0d\x0a b\x0d\x0a\x0d\x0aline1\x0d\x0aline2\x0d\x0a", 46, c"\n", c"Subject: crlf\x0aX-Fold: a\x0a b\x0a\x0aline1\x0aline2\x0a", 40)
	check_as_string(c"Subject: crlf\x0d\x0aX-Fold: a\x0d\x0a b\x0d\x0a\x0d\x0aline1\x0d\x0aline2\x0d\x0a", 46, c"\r\n", c"Subject: crlf\x0d\x0aX-Fold: a\x0d\x0a b\x0d\x0a\x0d\x0aline1\x0d\x0aline2\x0d\x0a", 46)
	check_as_string(c" continuation first\x0aSubject: s\x0a\x0abody\x0a", 37, c"\n", c"Subject: s\x0a\x0abody\x0a", 17)
	check_as_string(c" continuation first\x0aSubject: s\x0a\x0abody\x0a", 37, c"\r\n", c"Subject: s\x0d\x0a\x0d\x0abody\x0d\x0a", 20)
	check_as_string(c"From sender@example.com Mon Jan  1 00:00:00 2024\x0aSubject: envelope\x0a\x0ab\x0a", 70, c"\n", c"Subject: envelope\x0a\x0ab\x0a", 21)
	check_as_string(c"From sender@example.com Mon Jan  1 00:00:00 2024\x0aSubject: envelope\x0a\x0ab\x0a", 70, c"\r\n", c"Subject: envelope\x0d\x0a\x0d\x0ab\x0d\x0a", 24)
	check_as_string(c"Subject: s\x0aFrom bad envelope\x0aTo: t\x0a\x0ab\x0a", 38, c"\n", c"Subject: s\x0aTo: t\x0a\x0ab\x0a", 20)
	check_as_string(c"Subject: s\x0aFrom bad envelope\x0aTo: t\x0a\x0ab\x0a", 38, c"\r\n", c"Subject: s\x0d\x0aTo: t\x0d\x0a\x0d\x0ab\x0d\x0a", 24)
	check_as_string(c"Subject: s\x0aFrom looks like body\x0a\x0arest\x0a", 38, c"\n", c"Subject: s\x0a\x0aFrom looks like body\x0arest\x0a", 38)
	check_as_string(c"Subject: s\x0aFrom looks like body\x0a\x0arest\x0a", 38, c"\r\n", c"Subject: s\x0d\x0a\x0d\x0aFrom looks like body\x0d\x0arest\x0d\x0a", 42)
	check_as_string(c"Subject: s\x0anot a header line\x0amore\x0a", 34, c"\n", c"Subject: s\x0a\x0anot a header line\x0amore\x0a", 35)
	check_as_string(c"Subject: s\x0anot a header line\x0amore\x0a", 34, c"\r\n", c"Subject: s\x0d\x0a\x0d\x0anot a header line\x0d\x0amore\x0d\x0a", 39)
	check_as_string(c"Subject: s\x0a: no name\x0aX: y\x0a\x0ab\x0a", 29, c"\n", c"Subject: s\x0aX: y\x0a\x0ab\x0a", 19)
	check_as_string(c"Subject: s\x0a: no name\x0aX: y\x0a\x0ab\x0a", 29, c"\r\n", c"Subject: s\x0d\x0aX: y\x0d\x0a\x0d\x0ab\x0d\x0a", 23)
	check_as_string(c"Subject: no body", 16, c"\n", c"Subject: no body\x0a\x0a", 18)
	check_as_string(c"Subject: no body", 16, c"\r\n", c"Subject: no body\x0d\x0a\x0d\x0a", 20)
	check_as_string(c"", 0, c"\n", c"\x0a", 1)
	check_as_string(c"", 0, c"\r\n", c"\x0d\x0a", 2)
	check_as_string(c"\x0abody only\x0a", 11, c"\n", c"\x0abody only\x0a", 11)
	check_as_string(c"\x0abody only\x0a", 11, c"\r\n", c"\x0d\x0abody only\x0d\x0a", 13)
	check_as_string(c"Subject: value:with:colons\x0aX-Empty:\x0aX-Spaces:    \x09 lead\x0a\x0a", 57, c"\n", c"Subject: value:with:colons\x0aX-Empty: \x0aX-Spaces: lead\x0a\x0a", 53)
	check_as_string(c"Subject: value:with:colons\x0aX-Empty:\x0aX-Spaces:    \x09 lead\x0a\x0a", 57, c"\r\n", c"Subject: value:with:colons\x0d\x0aX-Empty: \x0d\x0aX-Spaces: lead\x0d\x0a\x0d\x0a", 57)
	check_as_string(c"Content-Type: text/plain; charset=\"ISO-8859-1\"\x0aContent-Transfer-Encoding: quoted-printable\x0a\x0ah=E9llo =\x0aworld=\x0a", 109, c"\n", c"Content-Type: text/plain; charset=\"ISO-8859-1\"\x0aContent-Transfer-Encoding: quoted-printable\x0a\x0ah=E9llo =\x0aworld=\x0a", 109)
	check_as_string(c"Content-Type: text/plain; charset=\"ISO-8859-1\"\x0aContent-Transfer-Encoding: quoted-printable\x0a\x0ah=E9llo =\x0aworld=\x0a", 109, c"\r\n", c"Content-Type: text/plain; charset=\"ISO-8859-1\"\x0d\x0aContent-Transfer-Encoding: quoted-printable\x0d\x0a\x0d\x0ah=E9llo =\x0d\x0aworld=\x0d\x0a", 114)
	check_as_string(c"Content-Type: application/octet-stream\x0aContent-Transfer-Encoding: base64\x0aContent-Disposition: attachment; filename=\"data.bin\"\x0a\x0aAAECAwQF\x0aBgcICQ==\x0a", 145, c"\n", c"Content-Type: application/octet-stream\x0aContent-Transfer-Encoding: base64\x0aContent-Disposition: attachment; filename=\"data.bin\"\x0a\x0aAAECAwQF\x0aBgcICQ==\x0a", 145)
	check_as_string(c"Content-Type: application/octet-stream\x0aContent-Transfer-Encoding: base64\x0aContent-Disposition: attachment; filename=\"data.bin\"\x0a\x0aAAECAwQF\x0aBgcICQ==\x0a", 145, c"\r\n", c"Content-Type: application/octet-stream\x0d\x0aContent-Transfer-Encoding: base64\x0d\x0aContent-Disposition: attachment; filename=\"data.bin\"\x0d\x0a\x0d\x0aAAECAwQF\x0d\x0aBgcICQ==\x0d\x0a", 151)
	check_as_string(c"Content-Transfer-Encoding:  Base64 \x0a\x0aaGVsbG8\x0a", 45, c"\n", c"Content-Transfer-Encoding: Base64 \x0a\x0aaGVsbG8\x0a", 44)
	check_as_string(c"Content-Transfer-Encoding:  Base64 \x0a\x0aaGVsbG8\x0a", 45, c"\r\n", c"Content-Transfer-Encoding: Base64 \x0d\x0a\x0d\x0aaGVsbG8\x0d\x0a", 47)
	check_as_string(c"Content-Transfer-Encoding: base64\x0a\x0aQ\x0a", 37, c"\n", c"Content-Transfer-Encoding: base64\x0a\x0aQ\x0a", 37)
	check_as_string(c"Content-Transfer-Encoding: base64\x0a\x0aQ\x0a", 37, c"\r\n", c"Content-Transfer-Encoding: base64\x0d\x0a\x0d\x0aQ\x0d\x0a", 40)
	check_as_string(c"Content-Transfer-Encoding: x-uuencode\x0a\x0abegin 644 f\x0a#86)C\x0a`\x0aend\x0a", 63, c"\n", c"Content-Transfer-Encoding: x-uuencode\x0a\x0abegin 644 f\x0a#86)C\x0a`\x0aend\x0a", 63)
	check_as_string(c"Content-Transfer-Encoding: x-uuencode\x0a\x0abegin 644 f\x0a#86)C\x0a`\x0aend\x0a", 63, c"\r\n", c"Content-Transfer-Encoding: x-uuencode\x0d\x0a\x0d\x0abegin 644 f\x0d\x0a#86)C\x0d\x0a`\x0d\x0aend\x0d\x0a", 69)
	check_as_string(c"Content-Type: multipart/mixed; boundary=\"XYZ\"\x0aMIME-Version: 1.0\x0a\x0apreamble line\x0a--XYZ\x0aContent-Type: text/plain\x0a\x0afirst part\x0a--XYZ\x0aContent-Type: text/html; charset=utf-8\x0a\x0a<p>second</p>\x0a\x0a--XYZ--\x0aepilogue text\x0a", 205, c"\n", c"Content-Type: multipart/mixed; boundary=\"XYZ\"\x0aMIME-Version: 1.0\x0a\x0apreamble line\x0a--XYZ\x0aContent-Type: text/plain\x0a\x0afirst part\x0a--XYZ\x0aContent-Type: text/html; charset=utf-8\x0a\x0a<p>second</p>\x0a\x0a--XYZ--\x0aepilogue text\x0a", 205)
	check_as_string(c"Content-Type: multipart/mixed; boundary=\"XYZ\"\x0aMIME-Version: 1.0\x0a\x0apreamble line\x0a--XYZ\x0aContent-Type: text/plain\x0a\x0afirst part\x0a--XYZ\x0aContent-Type: text/html; charset=utf-8\x0a\x0a<p>second</p>\x0a\x0a--XYZ--\x0aepilogue text\x0a", 205, c"\r\n", c"Content-Type: multipart/mixed; boundary=\"XYZ\"\x0d\x0aMIME-Version: 1.0\x0d\x0a\x0d\x0apreamble line\x0d\x0a--XYZ\x0d\x0aContent-Type: text/plain\x0d\x0a\x0d\x0afirst part\x0d\x0a--XYZ\x0d\x0aContent-Type: text/html; charset=utf-8\x0d\x0a\x0d\x0a<p>second</p>\x0d\x0a\x0d\x0a--XYZ--\x0d\x0aepilogue text\x0d\x0a", 220)
	check_as_string(c"Content-Type: multipart/mixed; boundary=XYZ\x0a\x0a--XYZ\x0a\x0aonly\x0a--XYZ--", 64, c"\n", c"Content-Type: multipart/mixed; boundary=XYZ\x0a\x0a--XYZ\x0a\x0aonly\x0a--XYZ--\x0a", 65)
	check_as_string(c"Content-Type: multipart/mixed; boundary=XYZ\x0a\x0a--XYZ\x0a\x0aonly\x0a--XYZ--", 64, c"\r\n", c"Content-Type: multipart/mixed; boundary=XYZ\x0d\x0a\x0d\x0a--XYZ\x0d\x0a\x0d\x0aonly\x0d\x0a--XYZ--\x0d\x0a", 71)
	check_as_string(c"Content-Type: multipart/mixed; boundary=XYZ\x0a\x0a--XYZ\x0a\x0aonly\x0a--XYZ--\x0a", 65, c"\n", c"Content-Type: multipart/mixed; boundary=XYZ\x0a\x0a--XYZ\x0a\x0aonly\x0a--XYZ--\x0a", 65)
	check_as_string(c"Content-Type: multipart/mixed; boundary=XYZ\x0a\x0a--XYZ\x0a\x0aonly\x0a--XYZ--\x0a", 65, c"\r\n", c"Content-Type: multipart/mixed; boundary=XYZ\x0d\x0a\x0d\x0a--XYZ\x0d\x0a\x0d\x0aonly\x0d\x0a--XYZ--\x0d\x0a", 71)
	check_as_string(c"Content-Type: multipart/mixed; boundary=XYZ\x0d\x0a\x0d\x0a--XYZ\x0d\x0a\x0d\x0acrlf part\x0d\x0a--XYZ--\x0d\x0a\x0d\x0aepi\x0d\x0a", 83, c"\n", c"Content-Type: multipart/mixed; boundary=XYZ\x0a\x0a--XYZ\x0a\x0acrlf part\x0a--XYZ--\x0a\x0aepi\x0a", 75)
	check_as_string(c"Content-Type: multipart/mixed; boundary=XYZ\x0d\x0a\x0d\x0a--XYZ\x0d\x0a\x0d\x0acrlf part\x0d\x0a--XYZ--\x0d\x0a\x0d\x0aepi\x0d\x0a", 83, c"\r\n", c"Content-Type: multipart/mixed; boundary=XYZ\x0d\x0a\x0d\x0a--XYZ\x0d\x0a\x0d\x0acrlf part\x0d\x0a--XYZ--\x0d\x0a\x0d\x0aepi\x0d\x0a", 83)
	check_as_string(c"Content-Type: multipart/mixed; boundary=\"outer\"\x0a\x0a--outer\x0aContent-Type: multipart/alternative; boundary=\"inner\"\x0a\x0a--inner\x0aContent-Type: text/plain\x0a\x0aplain\x0a--inner\x0aContent-Type: text/html\x0a\x0ahtml\x0a--inner--\x0ainner epilogue\x0a--outer\x0aContent-Type: application/pdf; name=\"report.pdf\"\x0aContent-Transfer-Encoding: base64\x0a\x0aJVBERi0=\x0a--outer--\x0a", 326, c"\n", c"Content-Type: multipart/mixed; boundary=\"outer\"\x0a\x0a--outer\x0aContent-Type: multipart/alternative; boundary=\"inner\"\x0a\x0a--inner\x0aContent-Type: text/plain\x0a\x0aplain\x0a--inner\x0aContent-Type: text/html\x0a\x0ahtml\x0a--inner--\x0ainner epilogue\x0a--outer\x0aContent-Type: application/pdf; name=\"report.pdf\"\x0aContent-Transfer-Encoding: base64\x0a\x0aJVBERi0=\x0a--outer--\x0a", 326)
	check_as_string(c"Content-Type: multipart/mixed; boundary=\"outer\"\x0a\x0a--outer\x0aContent-Type: multipart/alternative; boundary=\"inner\"\x0a\x0a--inner\x0aContent-Type: text/plain\x0a\x0aplain\x0a--inner\x0aContent-Type: text/html\x0a\x0ahtml\x0a--inner--\x0ainner epilogue\x0a--outer\x0aContent-Type: application/pdf; name=\"report.pdf\"\x0aContent-Transfer-Encoding: base64\x0a\x0aJVBERi0=\x0a--outer--\x0a", 326, c"\r\n", c"Content-Type: multipart/mixed; boundary=\"outer\"\x0d\x0a\x0d\x0a--outer\x0d\x0aContent-Type: multipart/alternative; boundary=\"inner\"\x0d\x0a\x0d\x0a--inner\x0d\x0aContent-Type: text/plain\x0d\x0a\x0d\x0aplain\x0d\x0a--inner\x0d\x0aContent-Type: text/html\x0d\x0a\x0d\x0ahtml\x0d\x0a--inner--\x0d\x0ainner epilogue\x0d\x0a--outer\x0d\x0aContent-Type: application/pdf; name=\"report.pdf\"\x0d\x0aContent-Transfer-Encoding: base64\x0d\x0a\x0d\x0aJVBERi0=\x0d\x0a--outer--\x0d\x0a", 347)
	check_as_string(c"Content-Type: multipart/mixed; boundary=\"outer\"\x0a\x0a--outer\x0aContent-Type: multipart/alternative; boundary=\"inner\"\x0a\x0a--inner\x0a\x0aunclosed inner\x0a--outer\x0a\x0aafter\x0a--outer--\x0a", 161, c"\n", c"Content-Type: multipart/mixed; boundary=\"outer\"\x0a\x0a--outer\x0aContent-Type: multipart/alternative; boundary=\"inner\"\x0a\x0a--inner\x0a\x0aunclosed inner\x0a--inner--\x0a\x0a--outer\x0a\x0aafter\x0a--outer--\x0a", 172)
	check_as_string(c"Content-Type: multipart/mixed; boundary=\"outer\"\x0a\x0a--outer\x0aContent-Type: multipart/alternative; boundary=\"inner\"\x0a\x0a--inner\x0a\x0aunclosed inner\x0a--outer\x0a\x0aafter\x0a--outer--\x0a", 161, c"\r\n", c"Content-Type: multipart/mixed; boundary=\"outer\"\x0d\x0a\x0d\x0a--outer\x0d\x0aContent-Type: multipart/alternative; boundary=\"inner\"\x0d\x0a\x0d\x0a--inner\x0d\x0a\x0d\x0aunclosed inner\x0d\x0a--inner--\x0d\x0a\x0d\x0a--outer\x0d\x0a\x0d\x0aafter\x0d\x0a--outer--\x0d\x0a", 186)
	check_as_string(c"Content-Type: multipart/mixed; boundary=b\x0a\x0ano boundary lines at all\x0a", 68, c"\n", c"Content-Type: multipart/mixed; boundary=b\x0a\x0ano boundary lines at all\x0a", 68)
	check_as_string(c"Content-Type: multipart/mixed; boundary=b\x0a\x0ano boundary lines at all\x0a", 68, c"\r\n", c"Content-Type: multipart/mixed; boundary=b\x0d\x0a\x0d\x0ano boundary lines at all\x0a", 70)
	check_as_string(c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0a\x0anever closed\x0a", 61, c"\n", c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0a\x0anever closed\x0a--b--\x0a", 67)
	check_as_string(c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0a\x0anever closed\x0a", 61, c"\r\n", c"Content-Type: multipart/mixed; boundary=b\x0d\x0a\x0d\x0a--b\x0d\x0a\x0d\x0anever closed\x0d\x0a--b--\x0d\x0a", 73)
	check_as_string(c"Content-Type: multipart/mixed\x0a\x0amissing boundary param\x0a", 54, c"\n", c"Content-Type: multipart/mixed\x0a\x0amissing boundary param\x0a", 54)
	check_as_string(c"Content-Type: multipart/mixed\x0a\x0amissing boundary param\x0a", 54, c"\r\n", c"Content-Type: multipart/mixed\x0d\x0a\x0d\x0amissing boundary param\x0a", 56)
	check_as_string(c"Content-Type: multipart/mixed; boundary=b\x0aContent-Transfer-Encoding: base64\x0a\x0a--b\x0a\x0ax\x0a--b--\x0a", 90, c"\n", c"Content-Type: multipart/mixed; boundary=b\x0aContent-Transfer-Encoding: base64\x0a\x0a--b\x0a\x0ax\x0a--b--\x0a", 90)
	check_as_string(c"Content-Type: multipart/mixed; boundary=b\x0aContent-Transfer-Encoding: base64\x0a\x0a--b\x0a\x0ax\x0a--b--\x0a", 90, c"\r\n", c"Content-Type: multipart/mixed; boundary=b\x0d\x0aContent-Transfer-Encoding: base64\x0d\x0a\x0d\x0a--b\x0d\x0a\x0d\x0ax\x0d\x0a--b--\x0d\x0a", 97)
	check_as_string(c"Content-Type: multipart/mixed; boundary=\"b  \"\x0a\x0a--b  \x0a\x0atrailing ws boundary\x0a--b--  \x0a", 83, c"\n", c"Content-Type: multipart/mixed; boundary=\"b  \"\x0a\x0a--b\x0a\x0atrailing ws boundary\x0a--b--\x0a", 79)
	check_as_string(c"Content-Type: multipart/mixed; boundary=\"b  \"\x0a\x0a--b  \x0a\x0atrailing ws boundary\x0a--b--  \x0a", 83, c"\r\n", c"Content-Type: multipart/mixed; boundary=\"b  \"\x0d\x0a\x0d\x0a--b\x0d\x0a\x0d\x0atrailing ws boundary\x0d\x0a--b--\x0d\x0a", 85)
	check_as_string(c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0a--b\x0a\x0adoubled boundary\x0a--b--\x0a", 75, c"\n", c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0a\x0adoubled boundary\x0a--b--\x0a", 71)
	check_as_string(c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0a--b\x0a\x0adoubled boundary\x0a--b--\x0a", 75, c"\r\n", c"Content-Type: multipart/mixed; boundary=b\x0d\x0a\x0d\x0a--b\x0d\x0a\x0d\x0adoubled boundary\x0d\x0a--b--\x0d\x0a", 77)
	check_as_string(c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0a--b--\x0a\x0aafter close\x0a", 66, c"\n", c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0a\x0aafter close\x0a--b--\x0a", 66)
	check_as_string(c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0a--b--\x0a\x0aafter close\x0a", 66, c"\r\n", c"Content-Type: multipart/mixed; boundary=b\x0d\x0a\x0d\x0a--b\x0d\x0a\x0d\x0aafter close\x0d\x0a--b--\x0d\x0a", 72)
	check_as_string(c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--bx\x0a--b\x0aX: 1\x0a\x0a--b \x0a--b--\x0a", 69, c"\n", c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--bx\x0a--b\x0aX: 1\x0a\x0a\x0a--b\x0a\x0a\x0a--b--\x0a", 71)
	check_as_string(c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--bx\x0a--b\x0aX: 1\x0a\x0a--b \x0a--b--\x0a", 69, c"\r\n", c"Content-Type: multipart/mixed; boundary=b\x0d\x0a\x0d\x0a--bx\x0d\x0a--b\x0d\x0aX: 1\x0d\x0a\x0d\x0a\x0d\x0a--b\x0d\x0a\x0d\x0a\x0d\x0a--b--\x0d\x0a", 82)
	check_as_string(c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0aContent-Type: message/rfc822\x0a\x0aSubject: inner\x0aContent-Type: text/plain\x0a\x0ainner body\x0a--b--\x0a", 135, c"\n", c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0aContent-Type: message/rfc822\x0a\x0aSubject: inner\x0aContent-Type: text/plain\x0a\x0ainner body\x0a--b--\x0a", 135)
	check_as_string(c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0aContent-Type: message/rfc822\x0a\x0aSubject: inner\x0aContent-Type: text/plain\x0a\x0ainner body\x0a--b--\x0a", 135, c"\r\n", c"Content-Type: multipart/mixed; boundary=b\x0d\x0a\x0d\x0a--b\x0d\x0aContent-Type: message/rfc822\x0d\x0a\x0d\x0aSubject: inner\x0d\x0aContent-Type: text/plain\x0d\x0a\x0d\x0ainner body\x0d\x0a--b--\x0d\x0a", 145)
	check_as_string(c"Content-Type: message/rfc822\x0a\x0aSubject: wrapped\x0a\x0awrapped body\x0a", 61, c"\n", c"Content-Type: message/rfc822\x0a\x0aSubject: wrapped\x0a\x0awrapped body\x0a", 61)
	check_as_string(c"Content-Type: message/rfc822\x0a\x0aSubject: wrapped\x0a\x0awrapped body\x0a", 61, c"\r\n", c"Content-Type: message/rfc822\x0d\x0a\x0d\x0aSubject: wrapped\x0d\x0a\x0d\x0awrapped body\x0d\x0a", 66)
	check_as_string(c"Content-Type: multipart/digest; boundary=d\x0a\x0a--d\x0a\x0aSubject: digest one\x0a\x0abody one\x0a--d\x0aContent-Type: text/plain\x0a\x0anot a message\x0a--d--\x0a", 129, c"\n", c"Content-Type: multipart/digest; boundary=d\x0a\x0a--d\x0a\x0aSubject: digest one\x0a\x0abody one\x0a--d\x0aContent-Type: text/plain\x0a\x0anot a message\x0a--d--\x0a", 129)
	check_as_string(c"Content-Type: multipart/digest; boundary=d\x0a\x0a--d\x0a\x0aSubject: digest one\x0a\x0abody one\x0a--d\x0aContent-Type: text/plain\x0a\x0anot a message\x0a--d--\x0a", 129, c"\r\n", c"Content-Type: multipart/digest; boundary=d\x0d\x0a\x0d\x0a--d\x0d\x0a\x0d\x0aSubject: digest one\x0d\x0a\x0d\x0abody one\x0d\x0a--d\x0d\x0aContent-Type: text/plain\x0d\x0a\x0d\x0anot a message\x0d\x0a--d--\x0d\x0a", 141)
	check_as_string(c"Content-Type: multipart/report; boundary=r\x0a\x0a--r\x0aContent-Type: message/delivery-status\x0a\x0aReporting-MTA: dns; mx.example\x0a\x0aFinal-Recipient: rfc822; a@b\x0aAction: failed\x0a\x0a--r--\x0a", 170, c"\n", c"Content-Type: multipart/report; boundary=r\x0a\x0a--r\x0aContent-Type: message/delivery-status\x0a\x0aReporting-MTA: dns; mx.example\x0a\x0aFinal-Recipient: rfc822; a@b\x0aAction: failed\x0a\x0a--r--\x0a", 170)
	check_as_string(c"Content-Type: multipart/report; boundary=r\x0a\x0a--r\x0aContent-Type: message/delivery-status\x0a\x0aReporting-MTA: dns; mx.example\x0a\x0aFinal-Recipient: rfc822; a@b\x0aAction: failed\x0a\x0a--r--\x0a", 170, c"\r\n", c"Content-Type: multipart/report; boundary=r\x0d\x0a\x0d\x0a--r\x0d\x0aContent-Type: message/delivery-status\x0d\x0a\x0d\x0aReporting-MTA: dns; mx.example\x0d\x0a\x0d\x0aFinal-Recipient: rfc822; a@b\x0d\x0aAction: failed\x0d\x0a\x0d\x0a--r--\x0d\x0a", 181)
	check_as_string(c"Content-Type: message/delivery-status\x0a\x0aA: 1\x0a\x0aB: 2\x0aC: 3\x0a", 55, c"\n", c"Content-Type: message/delivery-status\x0a\x0aA: 1\x0a\x0aB: 2\x0aC: 3\x0a", 55)
	check_as_string(c"Content-Type: message/delivery-status\x0a\x0aA: 1\x0a\x0aB: 2\x0aC: 3\x0a", 55, c"\r\n", c"Content-Type: message/delivery-status\x0d\x0a\x0d\x0aA: 1\x0d\x0a\x0d\x0aB: 2\x0d\x0aC: 3\x0d\x0a", 61)
	check_as_string(c"Content-Type: text/plain; title*0*=us-ascii'en'This%20is%20; title*1*=%2A%2Afun%2A%2A; name*=utf-8''na%C3%AFve.txt; charset*=us-ascii''UTF-8\x0a\x0ax\x0a", 144, c"\n", c"Content-Type: text/plain; title*0*=us-ascii'en'This%20is%20; title*1*=%2A%2Afun%2A%2A; name*=utf-8''na%C3%AFve.txt; charset*=us-ascii''UTF-8\x0a\x0ax\x0a", 144)
	check_as_string(c"Content-Type: text/plain; title*0*=us-ascii'en'This%20is%20; title*1*=%2A%2Afun%2A%2A; name*=utf-8''na%C3%AFve.txt; charset*=us-ascii''UTF-8\x0a\x0ax\x0a", 144, c"\r\n", c"Content-Type: text/plain; title*0*=us-ascii'en'This%20is%20; title*1*=%2A%2Afun%2A%2A; name*=utf-8''na%C3%AFve.txt; charset*=us-ascii''UTF-8\x0d\x0a\x0d\x0ax\x0d\x0a", 147)
	check_as_string(c"Content-Type: text/plain; name=\"a.txt\"\x0aContent-Disposition: INLINE; filename*=iso-8859-1''caf%E9.txt\x0a\x0ax\x0a", 104, c"\n", c"Content-Type: text/plain; name=\"a.txt\"\x0aContent-Disposition: INLINE; filename*=iso-8859-1''caf%E9.txt\x0a\x0ax\x0a", 104)
	check_as_string(c"Content-Type: text/plain; name=\"a.txt\"\x0aContent-Disposition: INLINE; filename*=iso-8859-1''caf%E9.txt\x0a\x0ax\x0a", 104, c"\r\n", c"Content-Type: text/plain; name=\"a.txt\"\x0d\x0aContent-Disposition: INLINE; filename*=iso-8859-1''caf%E9.txt\x0d\x0a\x0d\x0ax\x0d\x0a", 108)
	check_as_string(c"Content-Type: text\x0aContent-Disposition: attachment\x0a\x0abad type\x0a", 61, c"\n", c"Content-Type: text\x0aContent-Disposition: attachment\x0a\x0abad type\x0a", 61)
	check_as_string(c"Content-Type: text\x0aContent-Disposition: attachment\x0a\x0abad type\x0a", 61, c"\r\n", c"Content-Type: text\x0d\x0aContent-Disposition: attachment\x0d\x0a\x0d\x0abad type\x0d\x0a", 65)
	check_as_string(c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0aContent-Type: multipart/mixed\x0a\x0anested no boundary\x0a--b--\x0a", 103, c"\n", c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0aContent-Type: multipart/mixed\x0a\x0anested no boundary\x0a\x0a--b--\x0a", 104)
	check_as_string(c"Content-Type: multipart/mixed; boundary=b\x0a\x0a--b\x0aContent-Type: multipart/mixed\x0a\x0anested no boundary\x0a--b--\x0a", 103, c"\r\n", c"Content-Type: multipart/mixed; boundary=b\x0d\x0a\x0d\x0a--b\x0d\x0aContent-Type: multipart/mixed\x0d\x0a\x0d\x0anested no boundary\x0a\x0d\x0a--b--\x0d\x0a", 111)

/*
Generator (python3 -I gen.py > table.w; CPython 3.13):

import binascii, random, base64, email, quopri
from email import policy
from email.header import decode_header, make_header, Header, HeaderParseError
from email._encoded_words import decode_b
from email.message import Message

random.seed(4242)


def lit(b):
    if isinstance(b, str):
        b = b.encode('utf-8', 'surrogateescape')
    out = []
    for c in b:
        if c == 0x22: out.append('\\"')
        elif c == 0x5c: out.append('\\\\')
        elif 32 <= c < 127: out.append(chr(c))
        else: out.append('\\x%02x' % c)
    return 'c"' + ''.join(out) + '"'


def blen(b):
    if isinstance(b, str):
        b = b.encode('utf-8', 'surrogateescape')
    return len(b)


def esc(b):
    if b is None: return '-'
    if isinstance(b, str):
        b = b.encode('utf-8', 'surrogateescape')
    return ''.join(chr(c) if 32 <= c < 127 and c != 92 else '\\x%02x' % c for c in b)


def rnd(alphabet, n):
    return bytes(random.choice(alphabet) for _ in range(n))


QP_ALPHA = b'=AFaf09xyz_ \t\r\n.=\xe9\x00'
qp_inputs = [b'', b'=', b'=4', b'=41', b'=4g', b'==41', b'a=\r\nb', b'a=\nb', b'a=\rxyz\nb', b'a=  \nb', b'h=E9llo_w=f6rld', b'_x_', b'=\r', b'end=']
for _ in range(40):
    qp_inputs.append(rnd(QP_ALPHA, random.randint(1, 30)))
print('void test_qp_decode_table():')
for s in qp_inputs:
    for header in (0, 1):
        want = binascii.a2b_qp(s, header=bool(header))
        print(f'\tcheck_qp_decode({lit(s)}, {len(s)}, {header}, {lit(want)}, {len(want)})')
print()

ENC_ALPHA = b'abc .\t\r\n=_\xff\x01~'
enc_inputs = [b'', b'hello world', b'trailing space ', b'trailing tab\t', b'line one \nline two\t\n', b'crlf line \r\nnext', b'.', b'.\n.x\n', b'a' * 200, b'b' * 75 + b'\n' + b'c' * 76 + b'\n' + b'd' * 77, b'=' * 40, b'caf\xe9 = ok', b'under_score and space', b'x\ry', b'mixed\r\nand\nlf\n']
for _ in range(30):
    enc_inputs.append(rnd(ENC_ALPHA, random.randint(1, 120)))
print('void test_qp_encode_table():')
for s in enc_inputs:
    for qt in (0, 1):
        for header in (0, 1):
            want = binascii.b2a_qp(s, quotetabs=bool(qt), istext=True, header=bool(header))
            print(f'\tcheck_qp_encode({lit(s)}, {len(s)}, {qt}, {header}, {lit(want)}, {len(want)})')
print()

B64_ALPHA = b'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo+/=\n\r !*'
b64_inputs = [b'', b'QQ==', b'QQ', b'QUI', b'QUJD', b'Q', b'QUJDR', b'QQ==QUJD', b'Q===', b'QQ=', b'Q Q = =', b'*QUJD*', b'QUJ\nD', b'QU\r\nJD\r\n', b'=QQ==', b'QR==', b'QUJ=QUJD']
for _ in range(40):
    b64_inputs.append(rnd(B64_ALPHA, random.randint(1, 24)))
print('void test_base64_table():')
for s in b64_inputs:
    try:
        want = binascii.a2b_base64(s)
        print(f'\tcheck_a2b({lit(s)}, {len(s)}, 1, {lit(want)}, {len(want)})')
    except binascii.Error:
        print(f'\tcheck_a2b({lit(s)}, {len(s)}, 0, c"", 0)')
    body, _ = decode_b(b''.join(s.splitlines()))
    print(f'\tcheck_b64_body({lit(s)}, {len(s)}, {lit(body)}, {len(body)})')
for n in (0, 1, 2, 3, 56, 57, 58, 114, 200):
    data = bytes((i * 37 + 11) & 255 for i in range(n))
    want = base64.encodebytes(data)
    print(f'\tcheck_b64_encode({lit(data)}, {n}, {lit(want)}, {len(want)})')
print()

headers = [
    'plain text, no words',
    '=?utf-8?q?caf=C3=A9?=',
    '=?UTF-8?B?Y2Fmw6k=?=',
    '=?utf-8?b?Y2Fmw6k?=',
    '=?iso-8859-1?q?h=E9llo?= world',
    'Re: =?iso-8859-1?q?h=E9llo?=',
    '=?utf-8?q?a?= =?utf-8?q?b?=',
    '=?utf-8?q?a?=   \t =?utf-8?q?b?=',
    '=?utf-8?q?a?=\n =?utf-8?q?b?=',
    '=?utf-8?q?a?= x =?utf-8?q?b?=',
    '=?utf-8?q?a?= =?iso-8859-1?q?b?=',
    '=?utf-8?q?a_b?=',
    '=?utf-8?q?a=5Fb=3d?=',
    '=?utf-8?q?bad=ZZ?=',
    'pre=?utf-8?q?x?=post',
    '=?utf-8?q??=',
    '=??q?abc?=',
    '=?utf-8?x?abc?=',
    '=?utf-8?q?unterminated',
    'line one\n line two',
    'a =?utf-8?q?x?=\n b\n c',
    '   leading =?us-ascii?q?ascii?= trailing  ',
    '=?us-ascii?q?a?= b',
    '=?ascii?q?a?=b',
    '=?utf-8?q?x?=(comment)',
    '(c)=?utf-8?q?x?=',
    '=?utf-8?b?QUJD?==?utf-8?b?REVG?=',
    '=?utf-8?b?Q?=',
    '=?utf-8?b?QUJ?=',
    '=?utf-8?b?Q*Q?=',
    '=?utf-8*en?q?lang?=',
    '=?WINDOWS-1252?q?=93quoted=94?=',
    '=?iso-8859-1?b?6Q==?= =?utf-8?b?w6k=?=',
    '=?utf-8?q?=E2=82=AC?= 100',
    'x =?utf-8?q?a?=\ty',
    '=?utf-8?q?one?=\r\n =?utf-8?q?two?=',
    '=?utf-8?q?a?= \x0b =?utf-8?q?b?=',
    'Subject: =?koi8-r?b?8NLJ18XU?=',
]
print('void test_decode_header_table():')
for h in headers:
    try:
        chunks = decode_header(h)
        parts = []
        for data, cs in chunks:
            if isinstance(data, str): data = data.encode('utf-8')
            parts.append(f'{cs if cs is not None else "-"}|{esc(data)};')
        want = ''.join(parts)
    except HeaderParseError:
        want = 'ERROR'
    try:
        u = str(make_header(decode_header(h))).encode('utf-8')
        uwant = lit(u)
    except HeaderParseError:
        uwant = '0'
    except (UnicodeDecodeError, LookupError):
        uwant = None
    print(f'\tcheck_decode_header({lit(h)}, {lit(want)})')
    # Only charsets the module converts (others pass through as bytes).
    known = ('utf-8', 'us-ascii', 'ascii', 'iso-8859-1', 'windows-1252', None)
    if uwant is not None and want != 'ERROR' and all(cs in known for _, cs in decode_header(h)):
        print(f'\tcheck_header_utf8({lit(h)}, {uwant})')
    elif uwant == '0':
        print(f'\tcheck_header_utf8({lit(h)}, 0)')
print()

words = [('hello', 'utf-8', 'b'), ('\u20ac\u20ac\u20ac', 'utf-8', 'b'), ('h\xe9llo w\xf6rld', 'utf-8', 'b'), ('h\xe9llo w\xf6rld', 'iso-8859-1', 'q'), ('abc', 'utf-8', 'q'), ('a b_c=d?e', 'iso-8859-1', 'q'), ('-!*+/ ok', 'iso-8859-1', 'q'), ('', 'utf-8', 'b')]
print('void test_encode_word_table():')
for text, cs, enc in words:
    if cs == 'utf-8' and enc == 'q':
        from email.charset import Charset, QP
        c = Charset('utf-8'); c.header_encoding = QP
        want = Header(text, c).encode()
    else:
        want = Header(text, cs).encode()
    data = text.encode(cs)
    if text == '':
        want = '=?utf-8?q??='
    # Header's utf-8 charset picks the shorter of B and Q (encoding 0).
    code = '0' if (cs == 'utf-8' and enc == 'b') else f"'{enc}'"
    print(f'\tcheck_encode_word({lit(data)}, {len(data)}, c"{cs}", {code}, {lit(want)})')
print()

param_values = [
    'text/plain',
    'text/plain; charset="us-ascii"',
    'TEXT/HTML ; CharSet = UTF-8 ; format=flowed',
    'multipart/mixed; boundary="a;b"; x=1',
    'multipart/mixed; boundary="quoted \\"inner\\" \\\\ back"',
    'application/x; name=<angle>',
    'a; flag; b=',
    'a;; b=c',
    'a; title*=us-ascii\'en\'This%20is%20%2A%2A%2Afun%2A%2A%2A',
    'a; title*0*=us-ascii\'en\'This%20is%20even%20more%20; title*1*=%2A%2A%2Afun%2A%2A%2A%20; title*2="isn\'t it!"',
    'a; name*1="world"; name*0="hello "',
    'a; name*="noticks%41"',
    'a; filename*=UTF-8\'\'na%C3%AFve.txt',
    'a; x*2=c; x*0=a; x*1=b; y=1',
    'a; x*=zero; x*1=one',
    'a; x*0=zero; x*=dropped; x*1=one',
    'a; key="semi;colon"; other=2',
    'a; key="unbalanced; other=2',
    'a; k = "spaced value" ; j=  v  ',
    '; leading',
    'a=b; c=d',
]
print('void test_params_table():')
for v in param_values:
    m = Message()
    m['Content-Type'] = v
    parts = []
    for k, val in m.get_params():
        if isinstance(val, tuple):
            cs, lang, value = val
            parts.append(f'{esc(k)}*{esc(cs)}\'{esc(lang)}\'{esc(value.encode("latin-1"))};')
        else:
            parts.append(f'{esc(k)}={esc(val)};')
    print(f'\tcheck_params({lit(v)}, {lit("".join(parts))})')
print()

fold_values = ['short', 'word ' * 20, 'tab\there  two  spaces ' + 'q ' * 40, 'x' * 60, 'one two three four five six seven eight nine ten eleven twelve thirteen fourteen']
print('void test_fold_table():')
for v in fold_values:
    for ls in ('\n', '\r\n'):
        want = policy.default.clone(linesep=ls).fold('Subject', v)
        print(f'\tcheck_fold(c"Subject", {lit(v)}, {lit(ls)}, {lit(want)})')
print()


def dump(m, depth, out):
    out.append(f'part {depth} type={m.get_content_type()} default={m.get_default_type()} mp={int(m.is_multipart())}\n')
    out.append(f' unixfrom={esc(m.get_unixfrom())}\n')
    for name, value in m._headers:
        out.append(f' h {esc(name)}|{esc(value)}\n')
    if not m.is_multipart():
        out.append(f' payload={esc(m.get_payload())}\n')
    out.append(f' preamble={esc(m.preamble)} epilogue={esc(m.epilogue)}\n')
    out.append(f' boundary={esc(m.get_boundary())} filename={esc(m.get_filename())} charset={esc(m.get_content_charset())} disposition={esc(m.get_content_disposition())}\n')
    out.append(' defects=' + ','.join(type(d).__name__ for d in m.defects) + '\n')
    if not m.is_multipart():
        out.append(f' decoded={esc(m.get_payload(decode=True))}\n')
    if m.is_multipart():
        for p in m.get_payload():
            dump(p, depth + 1, out)


messages = [
    b'Subject: hello\nFrom: a@example.com\n\nbody line\nsecond\n',
    b'Subject: folded\n  across\tlines\n\tand tabs\nX-Long: a\n b\n c\n\nbody',
    b'Received: one\nreceived: two\nRECEIVED: three\nTo: x\n\n',
    b'Subject: crlf\r\nX-Fold: a\r\n b\r\n\r\nline1\r\nline2\r\n',
    b'Subject: cr only\rX: y\r\rbody\r',
    b' continuation first\nSubject: s\n\nbody\n',
    b'From sender@example.com Mon Jan  1 00:00:00 2024\nSubject: envelope\n\nb\n',
    b'Subject: s\nFrom bad envelope\nTo: t\n\nb\n',
    b'Subject: s\nFrom looks like body\n\nrest\n',
    b'Subject: s\nnot a header line\nmore\n',
    b'Subject: s\n: no name\nX: y\n\nb\n',
    b'Subject: no body',
    b'',
    b'\nbody only\n',
    b'Subject: value:with:colons\nX-Empty:\nX-Spaces:    \t lead\n\n',
    b'Content-Type: text/plain; charset="ISO-8859-1"\nContent-Transfer-Encoding: quoted-printable\n\nh=E9llo =\nworld=\n',
    b'Content-Type: application/octet-stream\nContent-Transfer-Encoding: base64\nContent-Disposition: attachment; filename="data.bin"\n\nAAECAwQF\nBgcICQ==\n',
    b'Content-Transfer-Encoding:  Base64 \n\naGVsbG8\n',
    b'Content-Transfer-Encoding: base64\n\nQ\n',
    b'Content-Transfer-Encoding: x-uuencode\n\nbegin 644 f\n#86)C\n`\nend\n',
    b'Content-Type: multipart/mixed; boundary="XYZ"\nMIME-Version: 1.0\n\npreamble line\n--XYZ\nContent-Type: text/plain\n\nfirst part\n--XYZ\nContent-Type: text/html; charset=utf-8\n\n<p>second</p>\n\n--XYZ--\nepilogue text\n',
    b'Content-Type: multipart/mixed; boundary=XYZ\n\n--XYZ\n\nonly\n--XYZ--',
    b'Content-Type: multipart/mixed; boundary=XYZ\n\n--XYZ\n\nonly\n--XYZ--\n',
    b'Content-Type: multipart/mixed; boundary=XYZ\r\n\r\n--XYZ\r\n\r\ncrlf part\r\n--XYZ--\r\n\r\nepi\r\n',
    b'Content-Type: multipart/mixed; boundary="outer"\n\n--outer\nContent-Type: multipart/alternative; boundary="inner"\n\n--inner\nContent-Type: text/plain\n\nplain\n--inner\nContent-Type: text/html\n\nhtml\n--inner--\ninner epilogue\n--outer\nContent-Type: application/pdf; name="report.pdf"\nContent-Transfer-Encoding: base64\n\nJVBERi0=\n--outer--\n',
    b'Content-Type: multipart/mixed; boundary="outer"\n\n--outer\nContent-Type: multipart/alternative; boundary="inner"\n\n--inner\n\nunclosed inner\n--outer\n\nafter\n--outer--\n',
    b'Content-Type: multipart/mixed; boundary=b\n\nno boundary lines at all\n',
    b'Content-Type: multipart/mixed; boundary=b\n\n--b\n\nnever closed\n',
    b'Content-Type: multipart/mixed\n\nmissing boundary param\n',
    b'Content-Type: multipart/mixed; boundary=b\nContent-Transfer-Encoding: base64\n\n--b\n\nx\n--b--\n',
    b'Content-Type: multipart/mixed; boundary="b  "\n\n--b  \n\ntrailing ws boundary\n--b--  \n',
    b'Content-Type: multipart/mixed; boundary=b\n\n--b\n--b\n\ndoubled boundary\n--b--\n',
    b'Content-Type: multipart/mixed; boundary=b\n\n--b\n--b--\n\nafter close\n',
    b'Content-Type: multipart/mixed; boundary=b\n\n--bx\n--b\nX: 1\n\n--b \n--b--\n',
    b'Content-Type: multipart/mixed; boundary=b\n\n--b\nContent-Type: message/rfc822\n\nSubject: inner\nContent-Type: text/plain\n\ninner body\n--b--\n',
    b'Content-Type: message/rfc822\n\nSubject: wrapped\n\nwrapped body\n',
    b'Content-Type: multipart/digest; boundary=d\n\n--d\n\nSubject: digest one\n\nbody one\n--d\nContent-Type: text/plain\n\nnot a message\n--d--\n',
    b'Content-Type: multipart/report; boundary=r\n\n--r\nContent-Type: message/delivery-status\n\nReporting-MTA: dns; mx.example\n\nFinal-Recipient: rfc822; a@b\nAction: failed\n\n--r--\n',
    b'Content-Type: message/delivery-status\n\nA: 1\n\nB: 2\nC: 3\n',
    b'Content-Type: text/plain; title*0*=us-ascii\'en\'This%20is%20; title*1*=%2A%2Afun%2A%2A; name*=utf-8\'\'na%C3%AFve.txt; charset*=us-ascii\'\'UTF-8\n\nx\n',
    b'Content-Type: text/plain; name="a.txt"\nContent-Disposition: INLINE; filename*=iso-8859-1\'\'caf%E9.txt\n\nx\n',
    b'Content-Type: text\nContent-Disposition: attachment\n\nbad type\n',
    b'Content-Type: a/b/c; charset=\xe9\n\nbad type 2\n',
    b'Content-Type: multipart/mixed; boundary=b\n\n--b\nContent-Type: multipart/mixed\n\nnested no boundary\n--b--\n',
]
print('void test_message_table():')
for i, src in enumerate(messages):
    m = email.message_from_bytes(src)
    out = []
    dump(m, 0, out)
    print(f'\tcheck_message({lit(src)}, {len(src)}, {lit("".join(out))})')
print()

print('void test_as_string_table():')
for src in messages:
    m = email.message_from_bytes(src)
    if any(c >= 128 for c in src) or b'\r' in src.replace(b'\r\n', b''):
        continue
    text = m.as_string(policy=m.policy.clone(linesep='\n')).encode('utf-8', 'surrogateescape')
    text2 = m.as_string(policy=m.policy.clone(linesep='\r\n')).encode('utf-8', 'surrogateescape')
    print(f'\tcheck_as_string({lit(src)}, {len(src)}, c"\\n", {lit(text)}, {len(text)})')
    print(f'\tcheck_as_string({lit(src)}, {len(src)}, c"\\r\\n", {lit(text2)}, {len(text2)})')
*/
