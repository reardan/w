import lib.testing
import libs.standard.net.ipaddress
import libs.standard.net.socket
import libs.standard.net.uuid
import libs.standard.web.urlparse


void test_ipv4_parse_format_and_network():
	int address = 0
	assert_equal(1, ipv4_parse(c"127.0.0.1", &address))
	assert_equal_hex(2130706433, address)
	char* formatted = ipv4_format(address)
	assert_strings_equal(c"127.0.0.1", formatted)
	free(formatted)

	assert_equal(1, ipv4_parse(c"192.168.1.10", &address))
	int network = 0
	assert_equal(1, ipv4_parse(c"192.168.1.0", &network))
	assert_equal(1, ipv4_in_network(address, network, 24))
	assert_equal(1, ipv4_parse(c"192.168.2.0", &network))
	assert_equal(0, ipv4_in_network(address, network, 24))
	assert_equal(1, ipv4_in_network(address, 0, 0))


void test_ipv4_rejects_invalid_text():
	int address = 0
	assert_equal(0, ipv4_parse(c"", &address))
	assert_equal(0, ipv4_parse(c"127.0.0", &address))
	assert_equal(0, ipv4_parse(c"127.0.0.1.2", &address))
	assert_equal(0, ipv4_parse(c"256.0.0.1", &address))
	assert_equal(0, ipv4_parse(c"01.2.3.4", &address))
	assert_equal(0, ipv4_parse(c"1..2.3", &address))


void test_uuid_parse_format_and_uuid4_shape():
	uuid id
	assert_equal(1, uuid_parse(c"550E8400-E29B-41D4-A716-446655440000", &id))
	char* formatted = uuid_format(id)
	assert_strings_equal(c"550e8400-e29b-41d4-a716-446655440000", formatted)
	free(formatted)

	assert_equal(0, uuid_parse(c"550e8400-e29b-41d4-a716-44665544000z", &id))
	uuid random_id = uuid4()
	formatted = uuid_format(random_id)
	assert_equal(36, strlen(formatted))
	assert_equal('-', formatted[8])
	assert_equal('-', formatted[13])
	assert_equal('-', formatted[18])
	assert_equal('-', formatted[23])
	assert_equal('4', formatted[14])
	int variant = formatted[19]
	asserts(c"uuid4 variant must be RFC 4122", (variant == '8') | (variant == '9') | (variant == 'a') | (variant == 'b'))
	free(formatted)


void test_url_parse_unparse_and_params():
	url* parsed = url_parse(c"http://user@example.com:80/path/to/page;v=1?x=1&y=two#frag")
	assert_strings_equal(c"http", parsed.scheme)
	assert_strings_equal(c"user@example.com:80", parsed.netloc)
	assert_strings_equal(c"/path/to/page", parsed.path)
	assert_strings_equal(c"v=1", parsed.params)
	assert_strings_equal(c"x=1&y=two", parsed.query)
	assert_strings_equal(c"frag", parsed.fragment)
	char* rebuilt = url_unparse(parsed)
	assert_strings_equal(c"http://user@example.com:80/path/to/page;v=1?x=1&y=two#frag", rebuilt)
	free(rebuilt)

	parsed = url_parse(c"//example.com/a/b?debug=1")
	assert_strings_equal(c"", parsed.scheme)
	assert_strings_equal(c"example.com", parsed.netloc)
	assert_strings_equal(c"/a/b", parsed.path)
	assert_strings_equal(c"debug=1", parsed.query)


void test_url_quote_and_unquote():
	char* quoted = url_quote(c"a path/with?query=1&x=two")
	assert_strings_equal(c"a%20path/with%3Fquery%3D1%26x%3Dtwo", quoted)
	char* unquoted = url_unquote(quoted)
	assert_strings_equal(c"a path/with?query=1&x=two", unquoted)
	free(quoted)
	free(unquoted)
	assert_equal(0, cast(int, url_unquote(c"bad%zz")))
	assert_equal(0, cast(int, url_unquote(c"bad%2")))


void test_socket_facade_bind_listen_close():
	socket* server = std_socket_create_tcp4()
	asserts(c"socket_create_tcp4 failed", server != 0)
	assert_equal(0, std_socket_bind(server, c"127.0.0.1", 0))
	assert_equal(0, std_socket_listen(server, 1))
	std_socket_close(server)
	assert_equal(1, server.closed)
