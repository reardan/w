# wbuild: x64
# wbuild: step="bin/cookies_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
import lib.testing
import libs.standard.web.cookies


datetime ck_now():
	return datetime_with_offset(datetime_new(2026, 1, 1, 0, 0, 0, 0), 0)


datetime ck_later(int seconds):
	return datetime_add(ck_now(), duration_from_seconds(seconds))


void ck_assert_null(char* p):
	assert_equal(0, cast(int, p))


# Serializes c (asserting success), compares and frees both.
void ck_expect_serialized(Cookie* c, char* want):
	char* got = cookie_serialize_set_cookie(c)
	assert1(got != 0)
	assert_strings_equal(want, got)
	free(got)
	cookie_free(c)


# ---- Set-Cookie parsing ------------------------------------------------------------

void test_parse_simple():
	Cookie* c = cookie_parse_set_cookie(c"SID=31d4d96e407aad42; Path=/; Domain=example.com")
	assert_strings_equal(c"SID", c.name)
	assert_strings_equal(c"31d4d96e407aad42", c.value)
	assert_strings_equal(c"/", c.path)
	assert_strings_equal(c"example.com", c.domain)
	assert_equal(0, c.secure)
	assert_equal(0, c.http_only)
	assert_equal(0, c.has_expires)
	assert_equal(0, c.has_max_age)
	assert_strings_equal(c"", c.same_site)
	cookie_free(c)


void test_parse_whitespace_and_case():
	Cookie* c = cookie_parse_set_cookie(c"  lang =  en-US \t;  secure ; HTTPONLY;DOMAIN=.Example.COM;  sameSite = lax ")
	assert_strings_equal(c"lang", c.name)
	assert_strings_equal(c"en-US", c.value)
	assert_equal(1, c.secure)
	assert_equal(1, c.http_only)
	assert_strings_equal(c"example.com", c.domain)
	assert_strings_equal(c"Lax", c.same_site)
	cookie_free(c)


void test_parse_value_edge_cases():
	# Value may contain '=' and be empty; quotes are kept.
	Cookie* c = cookie_parse_set_cookie(c"token=a=b==")
	assert_strings_equal(c"a=b==", c.value)
	cookie_free(c)
	c = cookie_parse_set_cookie(c"empty=")
	assert_strings_equal(c"", c.value)
	cookie_free(c)
	c = cookie_parse_set_cookie(c"q=\"quoted\"; Path=/x")
	assert_strings_equal(c"\"quoted\"", c.value)
	assert_strings_equal(c"/x", c.path)
	cookie_free(c)


void test_parse_ignored_headers():
	ck_assert_null(cast(char*, cookie_parse_set_cookie(c"novalue")))
	ck_assert_null(cast(char*, cookie_parse_set_cookie(c"novalue; a=b")))
	ck_assert_null(cast(char*, cookie_parse_set_cookie(c"=value")))
	ck_assert_null(cast(char*, cookie_parse_set_cookie(c"  =value; Path=/")))
	ck_assert_null(cast(char*, cookie_parse_set_cookie(c"")))
	ck_assert_null(cast(char*, cookie_parse_set_cookie(0)))


void test_parse_expires():
	Cookie* c = cookie_parse_set_cookie(c"a=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT")
	assert_equal(1, c.has_expires)
	assert_equal(2015, c.expires.d.year)
	assert_equal(10, c.expires.d.month)
	assert_equal(21, c.expires.d.day)
	assert_equal(7, c.expires.t.hour)
	assert_equal(28, c.expires.t.minute)
	assert_equal(1, c.expires.has_offset)
	assert_equal(0, c.expires.utc_offset)
	cookie_free(c)
	# Netscape dashed form and RFC 850 two-digit years.
	c = cookie_parse_set_cookie(c"a=1; expires=Wed, 09-Jun-2021 10:18:14 GMT")
	assert_equal(1, c.has_expires)
	assert_equal(2021, c.expires.d.year)
	assert_equal(6, c.expires.d.month)
	cookie_free(c)
	c = cookie_parse_set_cookie(c"a=1; expires=Sunday, 06-Nov-94 08:49:37 GMT")
	assert_equal(1994, c.expires.d.year)
	cookie_free(c)
	# Far future works on every word size.
	c = cookie_parse_set_cookie(c"a=1; Expires=Fri, 31 Dec 9999 23:59:59 GMT")
	assert_equal(9999, c.expires.d.year)
	cookie_free(c)


void test_parse_bad_expires_ignored():
	Cookie* c = cookie_parse_set_cookie(c"a=1; Expires=not a date")
	assert_equal(0, c.has_expires)
	cookie_free(c)
	c = cookie_parse_set_cookie(c"a=1; Expires=")
	assert_equal(0, c.has_expires)
	cookie_free(c)
	# RFC 6265 5.1.1: years before 1601 fail.
	c = cookie_parse_set_cookie(c"a=1; Expires=Mon, 01 Jan 1600 00:00:00 GMT")
	assert_equal(0, c.has_expires)
	cookie_free(c)


void test_parse_max_age():
	Cookie* c = cookie_parse_set_cookie(c"a=1; Max-Age=3600")
	assert_equal(1, c.has_max_age)
	assert_equal(3600, c.max_age)
	cookie_free(c)
	c = cookie_parse_set_cookie(c"a=1; max-age=-5")
	assert_equal(1, c.has_max_age)
	assert_equal(0 - 5, c.max_age)
	cookie_free(c)
	c = cookie_parse_set_cookie(c"a=1; Max-Age=0")
	assert_equal(1, c.has_max_age)
	assert_equal(0, c.max_age)
	cookie_free(c)
	# Saturates instead of overflowing.
	c = cookie_parse_set_cookie(c"a=1; Max-Age=99999999999999999999")
	assert_equal(999999999, c.max_age)
	cookie_free(c)
	# Malformed values are ignored; a later good one wins.
	c = cookie_parse_set_cookie(c"a=1; Max-Age=12x; Max-Age=+3; Max-Age=; Max-Age=-")
	assert_equal(0, c.has_max_age)
	cookie_free(c)
	c = cookie_parse_set_cookie(c"a=1; Max-Age=10; Max-Age=20")
	assert_equal(20, c.max_age)
	cookie_free(c)


void test_parse_path_and_domain_rules():
	# A Path not starting with '/' means default-path (stored as "").
	Cookie* c = cookie_parse_set_cookie(c"a=1; Path=/docs; Path=relative")
	assert_strings_equal(c"", c.path)
	cookie_free(c)
	c = cookie_parse_set_cookie(c"a=1; Path=")
	assert_strings_equal(c"", c.path)
	cookie_free(c)
	# An empty Domain is ignored; the earlier one stays.
	c = cookie_parse_set_cookie(c"a=1; Domain=foo.com; Domain=")
	assert_strings_equal(c"foo.com", c.domain)
	cookie_free(c)
	# Unknown attributes are skipped.
	c = cookie_parse_set_cookie(c"a=1; Comment=hi; Version=1; Partitioned; ;;")
	assert_strings_equal(c"a", c.name)
	assert_strings_equal(c"", c.path)
	cookie_free(c)


void test_parse_same_site():
	Cookie* c = cookie_parse_set_cookie(c"a=1; SameSite=STRICT")
	assert_strings_equal(c"Strict", c.same_site)
	cookie_free(c)
	c = cookie_parse_set_cookie(c"a=1; SameSite=none; Secure")
	assert_strings_equal(c"None", c.same_site)
	cookie_free(c)
	c = cookie_parse_set_cookie(c"a=1; SameSite=Lax; SameSite=bogus")
	assert_strings_equal(c"", c.same_site)
	cookie_free(c)


# ---- Set-Cookie serialization ------------------------------------------------------

void test_serialize_set_cookie():
	ck_expect_serialized(cookie_new(c"a", c"b"), c"a=b")
	Cookie* c = cookie_new(c"SID", c"31d4")
	cookie_set_path(c, c"/")
	cookie_set_domain(c, c".Example.com")
	cookie_set_expires(c, datetime_with_offset(datetime_new(2015, 10, 21, 9, 28, 0, 0), 7200))
	cookie_set_max_age(c, 60)
	c.secure = 1
	c.http_only = 1
	cookie_set_same_site(c, c"Strict")
	ck_expect_serialized(c, c"SID=31d4; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Path=/; Domain=example.com; Max-Age=60; Secure; HttpOnly; SameSite=Strict")


void test_serialize_round_trip():
	char* text = c"id=a3fWa; Expires=Thu, 31 Oct 2030 07:28:00 GMT; Path=/app; Domain=w.example; Max-Age=0; Secure; HttpOnly; SameSite=Lax"
	Cookie* c = cookie_parse_set_cookie(text)
	ck_expect_serialized(c, text)
	ck_expect_serialized(cookie_new(c"e", c""), c"e=")
	ck_expect_serialized(cookie_new(c"q", c"\"xy\""), c"q=\"xy\"")


void test_serialize_rejects_invalid():
	list[char*] bad_names = list[char*]{c"", c"a b", c"a;b", c"a=b", c"a\tb", c"(x)"}
	for i in range(bad_names.length):
		Cookie* c = cookie_new(bad_names[i], c"v")
		ck_assert_null(cookie_serialize_set_cookie(c))
		cookie_free(c)
	list[char*] bad_values = list[char*]{c"a b", c"a;b", c"a,b", c"a\\b", c"\"open", c"x\"y"}
	for i in range(bad_values.length):
		Cookie* c = cookie_new(c"n", bad_values[i])
		ck_assert_null(cookie_serialize_set_cookie(c))
		cookie_free(c)
	list_free[char*](bad_names)
	list_free[char*](bad_values)
	Cookie* c = cookie_new(c"n", c"v")
	cookie_set_path(c, c"/a;b")
	ck_assert_null(cookie_serialize_set_cookie(c))
	cookie_free(c)
	assert_equal(1, cookie_name_is_valid(c"__Host-id"))
	assert_equal(1, cookie_value_is_valid(c"\"\""))
	assert_equal(0, cookie_value_is_valid(c"\""))


# ---- Cookie request header -----------------------------------------------------------

void test_parse_cookie_header():
	list[Cookie*] l = cookie_parse_header(c"SID=31d4d96e407aad42; lang=en-US;  x = y ;;novalue; =bad; q=\"v\"")
	assert_equal(4, l.length)
	assert_strings_equal(c"SID", l[0].name)
	assert_strings_equal(c"31d4d96e407aad42", l[0].value)
	assert_strings_equal(c"lang", l[1].name)
	assert_strings_equal(c"en-US", l[1].value)
	assert_strings_equal(c"x", l[2].name)
	assert_strings_equal(c"y", l[2].value)
	assert_strings_equal(c"\"v\"", cookie_list_get(l, c"q"))
	ck_assert_null(cookie_list_get(l, c"novalue"))
	cookie_list_free(l)
	l = cookie_parse_header(c"")
	assert_equal(0, l.length)
	cookie_list_free(l)


void test_serialize_cookie_header():
	list[Cookie*] l = new list[Cookie*]
	char* empty = cookie_serialize_header(l)
	assert_strings_equal(c"", empty)
	free(empty)
	l.push(cookie_new(c"a", c"1"))
	l.push(cookie_new(c"b", c""))
	char* h = cookie_serialize_header(l)
	assert_strings_equal(c"a=1; b=", h)
	free(h)
	l.push(cookie_new(c"bad name", c"x"))
	ck_assert_null(cookie_serialize_header(l))
	cookie_list_free(l)
	# Round trip.
	l = cookie_parse_header(c"a=1; b=2; c=3")
	h = cookie_serialize_header(l)
	assert_strings_equal(c"a=1; b=2; c=3", h)
	free(h)
	cookie_list_free(l)


# ---- matching primitives -------------------------------------------------------

void test_domain_match():
	assert_equal(1, cookie_domain_match(c"example.com", c"example.com"))
	assert_equal(1, cookie_domain_match(c"www.example.com", c"example.com"))
	assert_equal(1, cookie_domain_match(c"a.b.example.com", c"example.com"))
	assert_equal(0, cookie_domain_match(c"badexample.com", c"example.com"))
	assert_equal(0, cookie_domain_match(c"example.com", c"www.example.com"))
	assert_equal(0, cookie_domain_match(c"example.com", c""))
	# IP addresses only match themselves.
	assert_equal(1, cookie_domain_match(c"192.168.0.1", c"192.168.0.1"))
	assert_equal(0, cookie_domain_match(c"10.0.0.1", c"0.0.1"))


void test_path_match():
	assert_equal(1, cookie_path_match(c"/", c"/"))
	assert_equal(1, cookie_path_match(c"/docs", c"/docs"))
	assert_equal(1, cookie_path_match(c"/docs/", c"/docs"))
	assert_equal(1, cookie_path_match(c"/docs/web", c"/docs"))
	assert_equal(1, cookie_path_match(c"/docs/web", c"/docs/"))
	assert_equal(1, cookie_path_match(c"/anything", c"/"))
	assert_equal(0, cookie_path_match(c"/docsets", c"/docs"))
	assert_equal(0, cookie_path_match(c"/doc", c"/docs"))
	assert_equal(0, cookie_path_match(c"/", c"/docs"))


void ck_expect_default_path(char* request_path, char* want):
	char* got = cookie_default_path(request_path)
	assert_strings_equal(want, got)
	free(got)


void test_default_path():
	ck_expect_default_path(c"", c"/")
	ck_expect_default_path(c"relative", c"/")
	ck_expect_default_path(c"/", c"/")
	ck_expect_default_path(c"/index.html", c"/")
	ck_expect_default_path(c"/docs/index.html", c"/docs")
	ck_expect_default_path(c"/docs/", c"/docs")
	ck_expect_default_path(c"/a/b/c", c"/a/b")
	ck_expect_default_path(c"/a/b?x=/y/z", c"/a")


# ---- the jar ---------------------------------------------------------------------

# Asserts the Cookie header the jar builds for a request, and frees it.
void ck_expect_header(CookieJar* jar, char* host, char* path, int secure, datetime now, char* want):
	char* got = cookie_jar_header(jar, host, path, secure, now)
	if (want == 0):
		ck_assert_null(got)
		return
	assert1(got != 0)
	assert_strings_equal(want, got)
	free(got)


void test_jar_host_only():
	CookieJar* jar = cookie_jar_new()
	assert_equal(1, cookie_jar_set_cookie(jar, c"Example.COM", c"/", 0, c"a=1", ck_now()))
	assert_equal(1, cookie_jar_count(jar))
	Cookie* c = jar.cookies[0]
	assert_equal(1, c.host_only)
	assert_strings_equal(c"example.com", c.domain)
	assert_equal(0, c.persistent)
	ck_expect_header(jar, c"example.com", c"/", 0, ck_now(), c"a=1")
	ck_expect_header(jar, c"EXAMPLE.com", c"/x/y", 0, ck_now(), c"a=1")
	ck_expect_header(jar, c"www.example.com", c"/", 0, ck_now(), 0)
	ck_expect_header(jar, c"other.com", c"/", 0, ck_now(), 0)
	cookie_jar_free(jar)


void test_jar_domain_cookie():
	CookieJar* jar = cookie_jar_new()
	assert_equal(1, cookie_jar_set_cookie(jar, c"www.example.com", c"/", 0, c"a=1; Domain=.example.com", ck_now()))
	Cookie* c = jar.cookies[0]
	assert_equal(0, c.host_only)
	assert_strings_equal(c"example.com", c.domain)
	ck_expect_header(jar, c"example.com", c"/", 0, ck_now(), c"a=1")
	ck_expect_header(jar, c"www.example.com", c"/", 0, ck_now(), c"a=1")
	ck_expect_header(jar, c"deep.sub.example.com", c"/", 0, ck_now(), c"a=1")
	ck_expect_header(jar, c"notexample.com", c"/", 0, ck_now(), 0)
	cookie_jar_free(jar)


void test_jar_domain_rejections():
	CookieJar* jar = cookie_jar_new()
	# Domain must domain-match the request host.
	assert_equal(0, cookie_jar_set_cookie(jar, c"www.example.com", c"/", 0, c"a=1; Domain=other.com", ck_now()))
	assert_equal(0, cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"a=1; Domain=www.example.com", ck_now()))
	assert_equal(0, cookie_jar_set_cookie(jar, c"badexample.com", c"/", 0, c"a=1; Domain=example.com", ck_now()))
	# Dotless (public-suffix-like) domains.
	assert_equal(0, cookie_jar_set_cookie(jar, c"www.example.com", c"/", 0, c"a=1; Domain=com", ck_now()))
	assert_equal(0, cookie_jar_set_cookie(jar, c"www.example.com", c"/", 0, c"a=1; Domain=.com", ck_now()))
	# An IP host only takes its own address.
	assert_equal(0, cookie_jar_set_cookie(jar, c"10.0.0.1", c"/", 0, c"a=1; Domain=0.0.1", ck_now()))
	# Unparsable headers.
	assert_equal(0, cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"garbage", ck_now()))
	assert_equal(0, cookie_jar_count(jar))
	# Accepted variants.
	assert_equal(1, cookie_jar_set_cookie(jar, c"localhost", c"/", 0, c"b=2; Domain=localhost", ck_now()))
	assert_equal(1, jar.cookies[0].host_only)
	assert_equal(1, cookie_jar_set_cookie(jar, c"10.0.0.1", c"/", 0, c"c=3; Domain=10.0.0.1", ck_now()))
	assert_equal(2, cookie_jar_count(jar))
	ck_expect_header(jar, c"localhost", c"/", 0, ck_now(), c"b=2")
	ck_expect_header(jar, c"10.0.0.1", c"/", 0, ck_now(), c"c=3")
	cookie_jar_free(jar)


void test_jar_paths_and_order():
	CookieJar* jar = cookie_jar_new()
	cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"root=1; Path=/", ck_now())
	cookie_jar_set_cookie(jar, c"example.com", c"/docs/page.html", 0, c"dflt=2", ck_now())
	cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"deep=3; Path=/docs/web", ck_now())
	cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"early=4; Path=/", ck_now())
	assert_strings_equal(c"/docs", jar.cookies[1].path)
	# Longest path first, then creation order.
	ck_expect_header(jar, c"example.com", c"/docs/web/x", 0, ck_now(), c"deep=3; dflt=2; root=1; early=4")
	ck_expect_header(jar, c"example.com", c"/docs", 0, ck_now(), c"dflt=2; root=1; early=4")
	ck_expect_header(jar, c"example.com", c"/docsets", 0, ck_now(), c"root=1; early=4")
	ck_expect_header(jar, c"example.com", c"/docs?q=1", 0, ck_now(), c"dflt=2; root=1; early=4")
	ck_expect_header(jar, c"example.com", c"", 0, ck_now(), c"root=1; early=4")
	list[Cookie*] hits = cookie_jar_matching(jar, c"example.com", c"/docs/web", 0, ck_later(5))
	assert_equal(4, hits.length)
	assert_equal(5, hits[0].last_access.t.second)
	assert_equal(0, hits[0].creation.t.second)
	list_free[Cookie*](hits)
	cookie_jar_free(jar)


void test_jar_replace_keeps_creation():
	CookieJar* jar = cookie_jar_new()
	cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"a=1", ck_now())
	cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"b=2", ck_now())
	cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"a=3", ck_later(10))
	assert_equal(2, cookie_jar_count(jar))
	# a kept its creation order, so it still sorts first.
	ck_expect_header(jar, c"example.com", c"/", 0, ck_later(20), c"a=3; b=2")
	Cookie* a = jar.cookies[1]
	assert_strings_equal(c"a", a.name)
	assert_equal(0, a.creation.t.second)
	# A different path or domain is a different cookie.
	cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"a=4; Path=/x", ck_now())
	cookie_jar_set_cookie(jar, c"www.example.com", c"/", 0, c"a=5", ck_now())
	assert_equal(4, cookie_jar_count(jar))
	# RFC 6265 compares the domain string only, so a domain cookie for
	# example.com replaces the host-only one (Python would keep both).
	cookie_jar_set_cookie(jar, c"www.example.com", c"/", 0, c"a=6; Domain=example.com", ck_now())
	assert_equal(4, cookie_jar_count(jar))
	ck_expect_header(jar, c"sub.example.com", c"/", 0, ck_later(20), c"a=6")
	cookie_jar_free(jar)


void test_jar_max_age_and_expires():
	CookieJar* jar = cookie_jar_new()
	cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"m=1; Max-Age=60", ck_now())
	Cookie* m = jar.cookies[0]
	assert_equal(1, m.persistent)
	assert_equal(1, m.expiry.t.minute)
	ck_expect_header(jar, c"example.com", c"/", 0, ck_later(59), c"m=1")
	ck_expect_header(jar, c"example.com", c"/", 0, ck_later(60), 0)
	assert_equal(0, cookie_jar_count(jar))
	# Max-Age wins over Expires, both ways.
	cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"x=1; Expires=Thu, 01 Jan 2099 00:00:00 GMT; Max-Age=10", ck_now())
	cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"y=1; Max-Age=100000; Expires=Thu, 01 Jan 2026 00:00:05 GMT", ck_now())
	ck_expect_header(jar, c"example.com", c"/", 0, ck_later(9), c"x=1; y=1")
	ck_expect_header(jar, c"example.com", c"/", 0, ck_later(11), c"y=1")
	cookie_jar_clear(jar, 0, 0, 0)
	# Expires alone.
	cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"e=1; Expires=Thu, 01 Jan 2026 01:00:00 GMT", ck_now())
	ck_expect_header(jar, c"example.com", c"/", 0, ck_later(3599), c"e=1")
	ck_expect_header(jar, c"example.com", c"/", 0, ck_later(3600), 0)
	# Far-future expiry and a huge Max-Age clamp instead of failing.
	cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"f=1; Expires=Fri, 31 Dec 9999 23:59:59 GMT", ck_now())
	cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"g=1; Max-Age=999999999999", ck_now())
	ck_expect_header(jar, c"example.com", c"/", 0, ck_later(86400 * 365), c"f=1; g=1")
	cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"h=1; Max-Age=86400", datetime_with_offset(datetime_new(9999, 12, 31, 12, 0, 0, 0), 0))
	assert_equal(9999, jar.cookies[2].expiry.d.year)
	cookie_jar_free(jar)


void test_jar_deletion():
	CookieJar* jar = cookie_jar_new()
	cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"a=1; Max-Age=3600", ck_now())
	cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"b=1", ck_now())
	cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"c=1", ck_now())
	# Max-Age=0, a negative Max-Age and a past Expires all delete.
	assert_equal(1, cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"a=; Max-Age=0", ck_now()))
	assert_equal(1, cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"b=; Max-Age=-1", ck_now()))
	assert_equal(1, cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"c=; Expires=Thu, 01 Jan 1970 00:00:00 GMT", ck_now()))
	assert_equal(0, cookie_jar_count(jar))
	# Deleting something absent is still accepted and stores nothing.
	assert_equal(1, cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"z=; Max-Age=0", ck_now()))
	assert_equal(0, cookie_jar_count(jar))
	cookie_jar_free(jar)


void test_jar_secure():
	CookieJar* jar = cookie_jar_new()
	# RFC 6265 lets an insecure channel set a Secure cookie.
	assert_equal(1, cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"s=1; Secure; HttpOnly; SameSite=Strict", ck_now()))
	cookie_jar_set_cookie(jar, c"example.com", c"/", 1, c"p=2", ck_now())
	ck_expect_header(jar, c"example.com", c"/", 0, ck_now(), c"p=2")
	ck_expect_header(jar, c"example.com", c"/", 1, ck_now(), c"s=1; p=2")
	Cookie* s = jar.cookies[0]
	assert_equal(1, s.http_only)
	assert_strings_equal(c"Strict", s.same_site)
	cookie_jar_free(jar)


void test_jar_clear_helpers():
	CookieJar* jar = cookie_jar_new()
	cookie_jar_set_cookie(jar, c"a.com", c"/", 0, c"s1=1", ck_now())
	cookie_jar_set_cookie(jar, c"a.com", c"/", 0, c"p1=1; Max-Age=100", ck_now())
	cookie_jar_set_cookie(jar, c"b.com", c"/", 0, c"p2=1; Max-Age=10", ck_now())
	cookie_jar_set_cookie(jar, c"b.com", c"/", 0, c"p3=1; Max-Age=1000; Path=/x", ck_now())
	cookie_jar_set_cookie(jar, c"b.com", c"/", 0, c"s2=1", ck_now())
	assert_equal(5, cookie_jar_count(jar))
	cookie_jar_clear_expired(jar, ck_later(50))
	assert_equal(4, cookie_jar_count(jar))
	cookie_jar_clear_session(jar)
	assert_equal(2, cookie_jar_count(jar))
	cookie_jar_clear(jar, c"b.com", c"/y", 0)
	assert_equal(2, cookie_jar_count(jar))
	cookie_jar_clear(jar, c"b.com", c"/x", c"p3")
	assert_equal(1, cookie_jar_count(jar))
	cookie_jar_clear(jar, c"a.com", 0, 0)
	assert_equal(0, cookie_jar_count(jar))
	cookie_jar_free(jar)


void test_jar_naive_and_offset_now():
	CookieJar* jar = cookie_jar_new()
	# A naive now is UTC; an aware one is converted.
	cookie_jar_set_cookie(jar, c"example.com", c"/", 0, c"a=1; Max-Age=60", datetime_new(2026, 1, 1, 0, 0, 0, 0))
	datetime plus2 = datetime_with_offset(datetime_new(2026, 1, 1, 2, 0, 30, 0), 7200)
	ck_expect_header(jar, c"example.com", c"/", 0, plus2, c"a=1")
	datetime later = datetime_with_offset(datetime_new(2026, 1, 1, 2, 1, 0, 0), 7200)
	ck_expect_header(jar, c"example.com", c"/", 0, later, 0)
	cookie_jar_free(jar)


void test_jar_url_api():
	CookieJar* jar = cookie_jar_new()
	URL* u = url_parse(c"https://www.Example.com/shop/cart?item=3")
	assert_equal(1, cookie_jar_set_cookie_url(jar, u, c"cart=7; Secure", ck_now()))
	assert_strings_equal(c"/shop", jar.cookies[0].path)
	char* h = cookie_jar_header_url(jar, u, ck_now())
	assert_strings_equal(c"cart=7", h)
	free(h)
	url_free(u)
	u = url_parse(c"http://www.example.com/shop/list")
	ck_assert_null(cookie_jar_header_url(jar, u, ck_now()))
	url_free(u)
	cookie_jar_free(jar)


void test_jar_add_parsed():
	CookieJar* jar = cookie_jar_new()
	Cookie* c = cookie_new(c"k", c"v")
	cookie_set_domain(c, c"example.org")
	cookie_set_path(c, c"/api")
	assert_equal(1, cookie_jar_add(jar, c, c"api.example.org", c"/", 1, ck_now()))
	ck_expect_header(jar, c"example.org", c"/api/v1", 0, ck_now(), c"k=v")
	assert_equal(0, cookie_jar_add(jar, 0, c"x", c"/", 0, ck_now()))
	cookie_jar_free(jar)
