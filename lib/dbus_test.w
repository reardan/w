# lib/dbus: wire encoding (alignment, arrays, structs, variants, the
# integer-to-double writer), signature walking, address parsing, and a
# live round trip of calls, replies, errors and signals between two
# connections on a private dbus-daemon (skipped when none is installed).
# wbuild: name=dbus_test x64
import lib.testing
import lib.ci_skip
import lib.net
import lib.dbus
import lib.dbus_test_bus


void assert_bytes(char* want, int n, char* got):
	for i in range(n): assert_equal(want[i] & 255, got[i] & 255)


void test_writers_align_relative_to_the_body():
	dbus_buf b
	dbus_buf_init(&b)
	dbus_put_byte(&b, 7)
	dbus_put_u32(&b, 258)
	assert_equal(8, b.length)
	assert_equal(2, b.data[4] & 255)
	assert_equal(1, b.data[5] & 255)
	dbus_put_string(&b, c"hi")
	assert_equal(15, b.length)
	# An array of (iy) structs: the length excludes the pad before the
	# first 8-aligned element.
	int mark = dbus_array_begin(&b, 8)
	dbus_put_struct(&b)
	dbus_put_i32(&b, 0 - 2)
	dbus_put_byte(&b, 9)
	dbus_array_end(&b, mark, 8)
	assert_equal(20, mark)
	assert_equal(24, b.length - 5)
	assert_equal(5, load_le32(&b.data[16]))
	dbus_put_sig(&b, c"ai")
	dbus_buf_free(&b)


void test_doubles_from_integers():
	dbus_buf b
	dbus_buf_init(&b)
	dbus_put_double_int(&b, 0)
	dbus_put_double_int(&b, 1)
	dbus_put_double_int(&b, 50)
	dbus_put_double_int(&b, 100)
	dbus_put_double_int(&b, 0 - 3)
	dbus_put_double_int(&b, 3000000)
	assert_equal(48, b.length)
	assert_bytes(c"\x00\x00\x00\x00\x00\x00\x00\x00", 8, &b.data[0])
	assert_bytes(c"\x00\x00\x00\x00\x00\x00\xf0\x3f", 8, &b.data[8])
	assert_bytes(c"\x00\x00\x00\x00\x00\x00\x49\x40", 8, &b.data[16])
	assert_bytes(c"\x00\x00\x00\x00\x00\x00\x59\x40", 8, &b.data[24])
	assert_bytes(c"\x00\x00\x00\x00\x00\x00\x08\xc0", 8, &b.data[32])
	# 3e6 = 0x4146E36000000000.
	assert_bytes(c"\x00\x00\x00\x00\x60\xe3\x46\x41", 8, &b.data[40])
	dbus_buf_free(&b)


void test_signatures_and_skipping():
	assert_equal(5, dbus_sig_next(c"a{sv}i", 0))
	assert_equal(9, dbus_sig_next(c"(so(ii)s)", 0))
	assert_equal(0 - 1, dbus_sig_next(c"(si", 0))
	dbus_buf b
	dbus_buf_init(&b)
	int mark = dbus_array_begin(&b, 8)
	dbus_put_struct(&b)
	dbus_put_string(&b, c"key")
	dbus_put_sig(&b, c"ai")
	int inner = dbus_array_begin(&b, 4)
	dbus_put_i32(&b, 1)
	dbus_put_i32(&b, 2)
	dbus_array_end(&b, inner, 4)
	dbus_array_end(&b, mark, 8)
	dbus_put_u32(&b, 77)
	dbus_reader r
	dbus_reader_init(&r, b.data, b.length)
	assert_equal(5, dbus_skip(&r, c"a{sv}u", 0))
	assert_equal(77, dbus_read_u32(&r))
	assert_equal(0, r.failed)
	assert_equal(b.length, r.pos)
	# A length past the end fails instead of reading out of bounds.
	dbus_reader_init(&r, b.data, 6)
	dbus_skip(&r, c"a{sv}", 0)
	assert_equal(1, r.failed)
	dbus_buf_free(&b)


void test_addresses():
	char* a = c"tcp:host=x;unix:abstract=/tmp/dbus-a%2cb,guid=00;unix:path=/run/bus"
	char* v = dbus_address_value(&a[11], 34, c"abstract")
	assert_strings_equal(c"/tmp/dbus-a,b", v)
	free(v)
	assert_equal(0, cast(int, dbus_address_value(&a[11], 34, c"path")))
	assert_equal(0 - 1, dbus_connect_address(c"tcp:host=localhost,port=1"))


# One frame over a socketpair: what dbus_send writes, dbus_next parses.
void test_messages_round_trip_through_a_socket_pair():
	int[2] fds
	assert_equal(0, socket_pair(&fds[0]))
	dbus_conn a
	a.fd = fds[0]
	a.serial = 41
	a.failed = 0
	dbus_buf_init(&a.in)
	dbus_buf_init(&a.head)
	dbus_buf_init(&a.body)
	dbus_conn b
	b.fd = fds[1]
	b.serial = 0
	b.failed = 0
	dbus_buf_init(&b.in)
	dbus_buf_init(&b.head)
	dbus_buf_init(&b.body)
	socket_set_nonblocking(b.fd)

	dbus_buf* body = dbus_body(&a)
	dbus_put_string(body, c"caf\xc3\xa9")
	dbus_put_struct(body)
	dbus_put_i32(body, 0 - 5)
	dbus_put_sig(body, c"u")
	dbus_put_u32(body, 9)
	assert_equal(42, dbus_call(&a, c":1.7", c"/org/w/x", c"org.w.Test", c"Ping", c"s(iv)"))
	dbus_message m
	assert_equal(1, dbus_next(&b, &m))
	assert_equal(DBUS_METHOD_CALL, m.type)
	assert_equal(42, m.serial)
	assert_strings_equal(c"/org/w/x", m.path)
	assert_strings_equal(c"org.w.Test", m.interface)
	assert_strings_equal(c"Ping", m.member)
	assert_strings_equal(c":1.7", m.destination)
	assert_strings_equal(c"s(iv)", m.signature)
	dbus_reader r
	dbus_message_reader(&m, &r)
	int n = 0
	assert_strings_equal(c"caf\xc3\xa9", dbus_read_string(&r, &n))
	assert_equal(5, n)
	dbus_read_align(&r, 8)
	assert_equal(0 - 5, dbus_read_i32(&r))
	assert_strings_equal(c"u", dbus_read_sig(&r))
	assert_equal(9, dbus_read_u32(&r))
	assert_equal(0, r.failed)
	assert_equal(0, dbus_next(&b, &m) == 1)

	# An error reply carries the error name and a reply serial.
	m.sender = c":1.9"
	assert_equal(1, dbus_error_reply(&a, &m, c"org.w.Error.Nope", c"no"))
	dbus_message e
	assert_equal(1, dbus_next(&b, &e))
	assert_equal(DBUS_ERROR, e.type)
	assert_equal(42, e.reply_serial)
	assert_strings_equal(c"org.w.Error.Nope", e.error_name)
	assert_strings_equal(c":1.9", e.destination)
	dbus_message_free(&e)
	dbus_message_free(&m)

	# A truncated stream waits; garbage fails the connection.
	write(a.fd, c"l\x01\x00\x01", 4)
	assert_equal(0, dbus_next(&b, &m))
	write(a.fd, c"\xff\xff\xff\x7f\x01\x00\x00\x00\x00\x00\x00\x00", 12)
	assert_equal(0 - 1, dbus_next(&b, &m))
	close(a.fd)
	close(b.fd)
	dbus_buf_free(&a.in)
	dbus_buf_free(&a.head)
	dbus_buf_free(&a.body)
	dbus_buf_free(&b.in)
	dbus_buf_free(&b.head)
	dbus_buf_free(&b.body)


# Wait for the next method call addressed to c (other traffic, such as
# NameAcquired signals, is dropped).
int next_call(dbus_conn* c, dbus_message* m):
	for i in range(100):
		if (dbus_wait(c, m, 50) == 1):
			if (m.type == DBUS_METHOD_CALL): return 1
			dbus_message_free(m)
	return 0


void check_live_bus(char* address):
	dbus_conn* a = dbus_open(address)
	dbus_conn* b = dbus_open(address)
	asserts(c"client a connects", a != 0)
	asserts(c"client b connects", b != 0)
	asserts(c"unique names", (a.unique_name[0] == ':') && (strcmp(a.unique_name, b.unique_name) != 0))

	dbus_buf* body = dbus_body(a)
	dbus_put_string(body, c"hello")
	int serial = dbus_call(a, b.unique_name, c"/w", c"org.w.Echo", c"Say", c"s")
	asserts(c"sent", serial != 0)
	dbus_message call
	assert_equal(1, next_call(b, &call))
	assert_strings_equal(a.unique_name, call.sender)
	assert_strings_equal(c"Say", call.member)
	dbus_reader r
	dbus_message_reader(&call, &r)
	char* said = dbus_read_string(&r, 0)
	body = dbus_body(b)
	int mark = dbus_array_begin(body, 4)
	dbus_put_string(body, said)
	dbus_put_string(body, said)
	dbus_array_end(body, mark, 4)
	assert_equal(1, dbus_reply(b, &call, c"as"))
	dbus_message_free(&call)

	dbus_message reply
	int got = 0
	for i in range(100):
		if ((got == 0) && (dbus_wait(a, &reply, 50) == 1)):
			if ((reply.type == DBUS_METHOD_RETURN) && (reply.reply_serial == serial)): got = 1
			else: dbus_message_free(&reply)
	assert_equal(1, got)
	assert_strings_equal(c"as", reply.signature)
	dbus_message_reader(&reply, &r)
	assert_equal(22, dbus_read_u32(&r))
	assert_strings_equal(c"hello", dbus_read_string(&r, 0))
	assert_strings_equal(c"hello", dbus_read_string(&r, 0))
	dbus_message_free(&reply)

	# The bus itself answers synchronous calls; a bad one is an error.
	body = dbus_body(a)
	dbus_put_string(body, b.unique_name)
	assert_equal(1, dbus_call_sync(a, &reply, 2000, c"org.freedesktop.DBus", c"/org/freedesktop/DBus", c"org.freedesktop.DBus", c"GetNameOwner", c"s"))
	dbus_message_reader(&reply, &r)
	assert_strings_equal(b.unique_name, dbus_read_string(&r, 0))
	dbus_message_free(&reply)
	body = dbus_body(a)
	dbus_put_string(body, c"org.w.Nobody")
	assert_equal(0 - 1, dbus_call_sync(a, &reply, 2000, c"org.freedesktop.DBus", c"/org/freedesktop/DBus", c"org.freedesktop.DBus", c"GetNameOwner", c"s"))
	assert_strings_equal(c"org.freedesktop.DBus.Error.NameHasNoOwner", reply.error_name)
	dbus_message_free(&reply)
	dbus_close(a)
	dbus_close(b)


void test_a_private_bus():
	dbus_test_bus bus
	if (!dbus_test_bus_start(&bus)):
		test_skip(c"SKIP: dbus-daemon not available")
		return
	check_live_bus(bus.address)
	dbus_test_bus_stop(&bus)


void test_an_abstract_socket_bus():
	dbus_test_bus bus
	if (!dbus_test_bus_start_at(&bus, c"unix:abstract=/tmp/w-dbus-test-abstract")):
		test_skip(c"SKIP: dbus-daemon not available")
		return
	asserts(c"abstract address", starts_with(bus.address, c"unix:abstract="))
	check_live_bus(bus.address)
	dbus_test_bus_stop(&bus)
