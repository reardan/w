# wbuild: x64
# Offline tests for libs/standard/web/urlparse.w (issue #198).
import lib.testing
import libs.standard.web.urlparse


void test_url_parse_basic():
	URL* u = url_parse(c"http://example.com")
	asserts(c"parse failed", u != 0)
	assert_strings_equal(c"http", u.scheme)
	assert_strings_equal(c"example.com", u.host)
	assert_equal(80, u.port)
	assert_strings_equal(c"/", u.path)
	assert_strings_equal(c"", u.query)
	url_free(u)


void test_url_parse_https_default_port():
	URL* u = url_parse(c"https://api.anthropic.com/v1/messages")
	asserts(c"parse failed", u != 0)
	assert_strings_equal(c"https", u.scheme)
	assert_strings_equal(c"api.anthropic.com", u.host)
	assert_equal(443, u.port)
	assert_strings_equal(c"/v1/messages", u.path)
	assert_strings_equal(c"", u.query)
	url_free(u)


void test_url_parse_explicit_port():
	URL* u = url_parse(c"http://localhost:8080/index.html")
	asserts(c"parse failed", u != 0)
	assert_equal(8080, u.port)
	assert_strings_equal(c"localhost", u.host)
	assert_strings_equal(c"/index.html", u.path)
	url_free(u)

	u = url_parse(c"https://example.com:65535")
	asserts(c"parse failed", u != 0)
	assert_equal(65535, u.port)
	assert_strings_equal(c"/", u.path)
	url_free(u)


void test_url_parse_query_and_fragment():
	URL* u = url_parse(c"http://example.com/search?q=hello&lang=en#results")
	asserts(c"parse failed", u != 0)
	assert_strings_equal(c"/search", u.path)
	assert_strings_equal(c"q=hello&lang=en", u.query)
	url_free(u)

	# Query with no path: the path defaults to "/".
	u = url_parse(c"http://example.com?q=1")
	asserts(c"parse failed", u != 0)
	assert_strings_equal(c"/", u.path)
	assert_strings_equal(c"q=1", u.query)
	url_free(u)

	# Fragment stays separate from the request path.
	u = url_parse(c"http://example.com/page#top")
	asserts(c"parse failed", u != 0)
	assert_strings_equal(c"/page", u.path)
	assert_strings_equal(c"", u.query)
	url_free(u)

	# Empty query string stays empty.
	u = url_parse(c"http://example.com/page?")
	asserts(c"parse failed", u != 0)
	assert_strings_equal(c"/page", u.path)
	assert_strings_equal(c"", u.query)
	url_free(u)


void test_url_parse_case_normalization():
	URL* u = url_parse(c"HTTP://EXAMPLE.Com/CaseSensitivePath?Query=Kept")
	asserts(c"parse failed", u != 0)
	assert_strings_equal(c"http", u.scheme)
	assert_strings_equal(c"example.com", u.host)
	assert_strings_equal(c"/CaseSensitivePath", u.path)
	assert_strings_equal(c"Query=Kept", u.query)
	url_free(u)


void test_url_parse_port_with_query():
	URL* u = url_parse(c"https://h.example:8443/a/b?x=1&y=2")
	asserts(c"parse failed", u != 0)
	assert_equal(8443, u.port)
	assert_strings_equal(c"h.example", u.host)
	assert_strings_equal(c"/a/b", u.path)
	assert_strings_equal(c"x=1&y=2", u.query)
	url_free(u)


void test_url_parse_rejects_missing_or_unknown_scheme():
	asserts(c"no scheme accepted", url_parse(c"example.com/path") == 0)
	asserts(c"relative path accepted", url_parse(c"/just/a/path") == 0)
	asserts(c"empty scheme accepted", url_parse(c"://example.com") == 0)
	asserts(c"ftp accepted", url_parse(c"ftp://example.com") == 0)
	asserts(c"missing slashes accepted", url_parse(c"http:example.com") == 0)
	asserts(c"one slash accepted", url_parse(c"http:/example.com") == 0)
	asserts(c"empty string accepted", url_parse(c"") == 0)
	asserts(c"null accepted", url_parse(0) == 0)


void test_url_parse_rejects_bad_host():
	asserts(c"empty host accepted", url_parse(c"http://") == 0)
	asserts(c"empty host with path accepted", url_parse(c"http:///path") == 0)
	asserts(c"empty host with port accepted", url_parse(c"http://:80/") == 0)
	asserts(c"userinfo accepted", url_parse(c"http://user@example.com/") == 0)
	asserts(c"invalid ipv6 literal accepted", url_parse(c"http://[:::1]/") == 0)


void test_url_parse_rejects_bad_port():
	asserts(c"empty port accepted", url_parse(c"http://example.com:/") == 0)
	asserts(c"empty port at end accepted", url_parse(c"http://example.com:") == 0)
	asserts(c"port zero accepted", url_parse(c"http://example.com:0/") == 0)
	asserts(c"port 65536 accepted", url_parse(c"http://example.com:65536/") == 0)
	asserts(c"huge port accepted", url_parse(c"http://example.com:99999999/") == 0)
	asserts(c"letter port accepted", url_parse(c"http://example.com:8a/") == 0)
	asserts(c"two colons accepted", url_parse(c"http://example.com:80:81/") == 0)


void test_url_unparse_round_trip():
	URL* u = url_parse(c"http://example.com/x?q=1")
	char* text = url_unparse(u)
	assert_strings_equal(c"http://example.com/x?q=1", text)
	free(text)
	url_free(u)

	# Non-default port is kept.
	u = url_parse(c"https://example.com:8443/x")
	text = url_unparse(u)
	assert_strings_equal(c"https://example.com:8443/x", text)
	free(text)
	url_free(u)

	# Explicit default port and missing path normalize away.
	u = url_parse(c"http://example.com:80?a=b")
	text = url_unparse(u)
	assert_strings_equal(c"http://example.com/?a=b", text)
	free(text)
	url_free(u)


void test_url_default_port():
	assert_equal(80, url_default_port(c"http"))
	assert_equal(443, url_default_port(c"https"))
	assert_equal(0, url_default_port(c"gopher"))


void test_url_quote():
	char* quoted = url_quote(c"hello world")
	assert_strings_equal(c"hello%20world", quoted)
	free(quoted)

	# Unreserved characters and '/' pass through untouched.
	quoted = url_quote(c"/a/b/c-d._~0Z")
	assert_strings_equal(c"/a/b/c-d._~0Z", quoted)
	free(quoted)

	quoted = url_quote(c"a=b&c=d")
	assert_strings_equal(c"a%3Db%26c%3Dd", quoted)
	free(quoted)

	# Raw UTF-8 bytes are escaped per byte (0xC3 0xA9).
	quoted = url_quote(c"caf\xc3\xa9")
	assert_strings_equal(c"caf%C3%A9", quoted)
	free(quoted)

	quoted = url_quote(c"")
	assert_strings_equal(c"", quoted)
	free(quoted)


void test_url_unquote():
	char* text = url_unquote(c"hello%20world")
	assert_strings_equal(c"hello world", text)
	free(text)

	# Hex digits are case-insensitive.
	text = url_unquote(c"%4a%4B")
	assert_strings_equal(c"JK", text)
	free(text)

	# '+' is not a space in unquote.
	text = url_unquote(c"a+b")
	assert_strings_equal(c"a+b", text)
	free(text)

	text = url_unquote(c"caf%C3%A9")
	assert_strings_equal(c"caf\xc3\xa9", text)
	free(text)

	text = url_unquote(c"plain")
	assert_strings_equal(c"plain", text)
	free(text)


void test_url_unquote_rejects_invalid_escapes():
	asserts(c"bare percent accepted", url_unquote(c"100%") == 0)
	asserts(c"one hex digit accepted", url_unquote(c"%2") == 0)
	asserts(c"non-hex escape accepted", url_unquote(c"%zz") == 0)
	asserts(c"half hex escape accepted", url_unquote(c"%2x") == 0)
	asserts(c"escaped NUL accepted", url_unquote(c"a%00b") == 0)


void test_url_quote_unquote_round_trip():
	char* original = c"path segment/with?query=values&more \xc3\xa9"
	char* quoted = url_quote(original)
	char* back = url_unquote(quoted)
	assert_strings_equal(original, back)
	free(quoted)
	free(back)


void test_url_reference_resolution():
	URL* base = url_parse(c"http://a/b/c/d;p?q#old")
	list[char*] refs = list[char*]{}
	refs.push(c"g")
	refs.push(c"./g")
	refs.push(c"g/")
	refs.push(c"/g")
	refs.push(c"//g")
	refs.push(c"?y")
	refs.push(c"g?y")
	refs.push(c"#s")
	refs.push(c"g#s")
	refs.push(c"g?y#s")
	refs.push(c"")
	refs.push(c".")
	refs.push(c"./")
	refs.push(c"..")
	refs.push(c"../")
	refs.push(c"../g")
	refs.push(c"../..")
	refs.push(c"../../")
	refs.push(c"../../g")
	refs.push(c"../../../g")
	refs.push(c"/./g")
	refs.push(c"/../g")
	refs.push(c"g/./h")
	refs.push(c"g/../h")
	refs.push(c"g?y/../x")
	refs.push(c"%2e%2e/g")
	refs.push(c"?")
	refs.push(c"#")
	list[char*] expected = list[char*]{}
	expected.push(c"http://a/b/c/g")
	expected.push(c"http://a/b/c/g")
	expected.push(c"http://a/b/c/g/")
	expected.push(c"http://a/g")
	expected.push(c"http://g/")
	expected.push(c"http://a/b/c/d;p?y")
	expected.push(c"http://a/b/c/g?y")
	expected.push(c"http://a/b/c/d;p?q#s")
	expected.push(c"http://a/b/c/g#s")
	expected.push(c"http://a/b/c/g?y#s")
	expected.push(c"http://a/b/c/d;p?q")
	expected.push(c"http://a/b/c/")
	expected.push(c"http://a/b/c/")
	expected.push(c"http://a/b/")
	expected.push(c"http://a/b/")
	expected.push(c"http://a/b/g")
	expected.push(c"http://a/")
	expected.push(c"http://a/")
	expected.push(c"http://a/g")
	expected.push(c"http://a/g")
	expected.push(c"http://a/g")
	expected.push(c"http://a/g")
	expected.push(c"http://a/b/c/g/h")
	expected.push(c"http://a/b/c/h")
	expected.push(c"http://a/b/c/g?y/../x")
	expected.push(c"http://a/b/c/%2e%2e/g")
	expected.push(c"http://a/b/c/d;p?")
	expected.push(c"http://a/b/c/d;p?q#")
	for i in range(refs.length):
		URL* u = url_resolve(base, refs[i])
		asserts(refs[i], u != 0)
		char* text = url_unparse(u)
		assert_strings_equal(expected[i], text)
		free(text)
		url_free(u)
	asserts(c"file reference accepted", url_resolve(base, c"file:///tmp/a") == 0)
	asserts(c"unsupported absolute scheme", url_resolve(base, c"g:h") == 0)
	url_free(base)


void test_url_ipv6_fragments_and_origin():
	URL* a = url_parse(c"HTTPS://[2001:DB8::1]:443/a%2Fb?#")
	asserts(c"IPv6 parse", a != 0)
	char* text = url_unparse(a)
	assert_strings_equal(c"https://[2001:db8::1]/a%2Fb?#", text)
	URL* b = url_parse(text)
	assert_equal(1, url_same_origin(a, b))
	assert_equal(1, b.has_query)
	assert_equal(1, b.has_fragment)
	free(text)
	url_free(b)
	b = url_parse(c"https://[2001:db8::1]:8443/")
	assert_equal(0, url_same_origin(a, b))
	url_free(a)
	url_free(b)
	asserts(c"missing bracket", url_parse(c"http://[::1/") == 0)
	asserts(c"too few groups", url_parse(c"http://[1:2:3]/") == 0)
	asserts(c"double compression", url_parse(c"http://[1::2::3]/") == 0)
	asserts(c"bad escape", url_parse(c"http://example/a%2") == 0)
	asserts(c"space", url_parse(c"http://example/a b") == 0)


void test_url_ipv6_canonical_hosts():
	list[char*] inputs = list[char*]{
		c"[0:0:0:0:0:0:0:0]", c"[0:0:0:0:0:0:0:1]",
		c"[2001:0DB8:0:0:1:0:0:1]", c"[2001:db8:0:1:0:0:0:1]",
		c"[2001:db8:0:1:1:1:1:1]", c"[2001:db8:1:1:0:0:0:0]",
		c"[::FFFF:192.0.2.128]", c"[0:0:0:0:0:ffff:c000:0280]",
		c"[1:2:3:4:5:6:192.0.2.1]", c"[1:2:3:4:5:6::8]"
	}
	list[char*] expected = list[char*]{
		c"[::]", c"[::1]", c"[2001:db8::1:0:0:1]", c"[2001:db8:0:1::1]",
		c"[2001:db8:0:1:1:1:1:1]", c"[2001:db8:1:1::]",
		c"[::ffff:c000:280]", c"[::ffff:c000:280]",
		c"[1:2:3:4:5:6:c000:201]", c"[1:2:3:4:5:6:0:8]"
	}
	for i in range(inputs.length):
		char* input = strjoin(c"http://", inputs[i])
		URL* u = url_parse(input)
		asserts(input, u != 0)
		assert_strings_equal(expected[i], u.host)
		char* serialized = url_unparse(u)
		URL* again = url_parse(serialized)
		assert_equal(1, url_same_origin(u, again))
		assert_strings_equal(expected[i], again.host)
		url_free(again)
		url_free(u)
		free(serialized)
		free(input)
	inputs.free()
	expected.free()


void test_url_ipv6_origin_equivalence():
	URL* base = url_parse(c"https://[2001:0db8:0000:0000:0001:0:0:1]:443/a")
	URL* next = url_resolve(base, c"//[2001:db8:0:0:1::1]/b")
	assert_equal(1, url_same_origin(base, next))
	url_free(next)
	next = url_resolve(base, c"//[2001:db8::2]/b")
	assert_equal(0, url_same_origin(base, next))
	url_free(next)
	next = url_resolve(base, c"//[2001:db8::1:0:0:1]:444/b")
	assert_equal(0, url_same_origin(base, next))
	url_free(next)
	url_free(base)
	base = url_parse(c"http://[::ffff:192.0.2.128]/")
	next = url_parse(c"http://[::ffff:c000:280]/")
	assert_equal(1, url_same_origin(base, next))
	url_free(next)
	next = url_parse(c"http://192.0.2.128/")
	assert_equal(0, url_same_origin(base, next))
	url_free(next)
	url_free(base)


void test_url_ipv6_invalid_tails():
	list[char*] hosts = list[char*]{
		c"[::ffff:192.0.2]", c"[::ffff:192.0.2.256]", c"[::ffff:192.00.2.1]",
		c"[::ffff:192.0.2.1.]", c"[::ffff:192.0.2.1:1]", c"[1:2:3:4:5:192.0.2.1]",
		c"[1:2:3:4:5:6::192.0.2.1]", c"[::ffff:192..2.1]", c"[::ffff:-1.0.2.1]",
		c"[::ffff:1234567890.0.2.1]", c"[::ffff:0x7f.0.0.1]", c"[::%25eth0]",
		c"[1:2:3:4:5:6:7:8::]", c"[1:2:3:4:5:6:7:8:]", c"[:::]",
		c"[::1]:65536", c"[::1]suffix", c"[v1.example]"
	}
	for host in hosts:
		char* text = strjoin(c"http://", host)
		asserts(text, url_parse(text) == 0)
		free(text)
	hosts.free()
