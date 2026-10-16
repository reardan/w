# wbuild: x64
# wbuild: step="bin/uuid_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
/*
libs/standard/formats/uuid.w: parse/format round trips against CPython's
UUID(hex) behaviour, bytes / bytes_le, the field accessors, ordering,
v4 and v7 version/variant bits and v7 monotonicity with a scripted clock.
v3/v5 known answers need the quarantined MD5/SHA-1 and live in
libs/x/unsafe/uuid_names_test.w; here only their fail-closed refusal is
covered. Expected values come from python3's uuid module.
*/
import lib.testing
import libs.standard.formats.uuid


void expect_str(char* want, uuid* u):
	char* got = uuid_format(u)
	assert_strings_equal(want, got)
	free(got)


void expect_parse(char* text, char* want):
	uuid u
	asserts(text, uuid_parse(text, &u) == 1)
	expect_str(want, &u)


# hi:lo as one 64-bit word (x64 only; literals are 32-bit).
int wide(int hi, int lo):
	int sh = 32
	int mask32 = ((1 << 30) - 1) * 4 + 3
	return (hi << sh) | (lo & mask32)


void expect_str_prefix_nil_ts(uuid* u):
	for i in range(6): assert_equal(0, u.b[i])


void expect_reject(char* text):
	uuid u
	asserts(text, uuid_parse(text, &u) == 0)


void test_parse_python_forms():
	char* want = c"12345678-1234-5678-1234-567812345678"
	expect_parse(c"12345678-1234-5678-1234-567812345678", want)
	expect_parse(c"{12345678-1234-5678-1234-567812345678}", want)
	expect_parse(c"12345678123456781234567812345678", want)
	expect_parse(c"urn:uuid:12345678-1234-5678-1234-567812345678", want)
	expect_parse(c"{12345678123456781234567812345678}", want)
	expect_parse(c"urn:uuid:{12345678-1234-5678-1234-567812345678}", want)
	# Python's looser spellings: hyphens anywhere, unbalanced braces,
	# either prefix alone, prefixes that only appear after deletion.
	expect_parse(c"1234-5678123456781234567812345678", want)
	expect_parse(c"----12345678123456781234567812345678", want)
	expect_parse(c"{{12345678-1234-5678-1234-567812345678}", want)
	expect_parse(c"12345678123456781234567812345678}{", want)
	expect_parse(c"uuid:12345678123456781234567812345678", want)
	expect_parse(c"urn:12345678123456781234567812345678", want)
	expect_parse(c"uuurn:id:12345678123456781234567812345678", want)
	expect_parse(c"ABCDEF00-1234-5678-1234-567812345678", c"abcdef00-1234-5678-1234-567812345678")


void test_parse_rejects():
	expect_reject(c"")
	expect_reject(c"12345678-1234-5678-1234-56781234567")
	expect_reject(c"12345678-1234-5678-1234-5678123456789")
	expect_reject(c"1234567g-1234-5678-1234-567812345678")
	expect_reject(c"URN:UUID:12345678-1234-5678-1234-567812345678")
	expect_reject(c"{1234567812345678}1234567812345678")
	# int(x, 16) quirks that Python tolerates but uuid_parse does not.
	expect_reject(c" 2345678123456781234567812345678")
	expect_reject(c"0x345678123456781234567812345678")
	expect_reject(c"1234_678123456781234567812345678")
	uuid u
	assert_equal(0, uuid_parse(cast(char*, 0), &u))


void test_parse_canonical():
	uuid u
	assert_equal(1, uuid_parse_canonical(c"A8098C1A-F86E-11DA-BD1A-00112444BE1E", &u))
	expect_str(c"a8098c1a-f86e-11da-bd1a-00112444be1e", &u)
	assert_equal(0, uuid_parse_canonical(c"a8098c1af86e11dabd1a00112444be1e", &u))
	assert_equal(0, uuid_parse_canonical(c"{a8098c1a-f86e-11da-bd1a-00112444be1e}", &u))
	assert_equal(0, uuid_parse_canonical(c"a8098c1a-f86e-11da-bd1a-00112444be1", &u))
	assert_equal(0, uuid_parse_canonical(c"a8098c1a-f86e-11da-bd1a-00112444be1e0", &u))
	assert_equal(0, uuid_parse_canonical(c"a8098c1af-86e-11da-bd1a-00112444be1e", &u))
	assert_equal(0, uuid_parse_canonical(c"a8098c1a-f86e-11da-bd1a-00112444bexe", &u))
	assert_equal(0, uuid_parse_canonical(cast(char*, 0), &u))


void test_format_hex_urn():
	uuid u
	uuid_parse(c"{A8098C1A-F86E-11DA-BD1A-00112444BE1E}", &u)
	char* s = uuid_hex(&u)
	assert_strings_equal(c"a8098c1af86e11dabd1a00112444be1e", s)
	free(s)
	s = uuid_urn(&u)
	assert_strings_equal(c"urn:uuid:a8098c1a-f86e-11da-bd1a-00112444be1e", s)
	free(s)
	char[37] buf
	uuid_format_into(&u, &buf[0])
	assert_strings_equal(c"a8098c1a-f86e-11da-bd1a-00112444be1e", &buf[0])
	assert_equal(36, UUID_STR_LEN)


void test_round_trip_all_byte_values():
	char[16] raw
	for round in range(16):
		for i in range(16): raw[i] = (round * 16 + i * 17) & 255
		uuid a
		uuid_from_bytes(&a, &raw[0])
		char* text = uuid_format(&a)
		uuid b
		assert_equal(1, uuid_parse(text, &b))
		assert_equal(1, uuid_equal(&a, &b))
		free(text)
		text = uuid_hex(&a)
		assert_equal(1, uuid_parse(text, &b))
		assert_equal(1, uuid_equal(&a, &b))
		free(text)
		text = uuid_urn(&a)
		assert_equal(1, uuid_parse(text, &b))
		assert_equal(1, uuid_equal(&a, &b))
		free(text)


void test_bytes_and_bytes_le():
	uuid u
	uuid_parse(c"12345678-1234-5678-1234-567812345678", &u)
	char[16] out
	uuid_to_bytes(&u, &out[0])
	assert_bytes_equal(c"\x12\x34\x56\x78\x12\x34\x56\x78\x12\x34\x56\x78\x12\x34\x56\x78", &out[0], 16)
	uuid_to_bytes_le(&u, &out[0])
	# python: u.bytes_le.hex() == 78563412341278561234567812345678
	assert_bytes_equal(c"\x78\x56\x34\x12\x34\x12\x78\x56\x12\x34\x56\x78\x12\x34\x56\x78", &out[0], 16)
	uuid back
	uuid_from_bytes_le(&back, &out[0])
	assert_equal(1, uuid_equal(&u, &back))
	uuid_from_bytes(&back, &out[0])
	expect_str(c"78563412-3412-7856-1234-567812345678", &back)
	uuid_copy(&back, &u)
	assert_equal(0, uuid_compare(&u, &back))


void test_fields_v1():
	# python: UUID('a8098c1a-f86e-11da-bd1a-00112444be1e').fields ==
	# (2819197978, 63598, 4570, 189, 26, 73622928926), version 1,
	# RFC 4122, time 133692293110139930, clock_seq 15642, node 0x112444be1e.
	uuid u
	uuid_parse(c"a8098c1a-f86e-11da-bd1a-00112444be1e", &u)
	int mask32 = ((1 << 30) - 1) * 4 + 3
	if (__word_size__ == 8): assert_equal(wide(0, cast(int, 0xa8098c1a)), uuid_time_low(&u))
	assert_equal_hex(cast(int, 0xa8098c1a) & mask32, uuid_time_low(&u) & mask32)
	assert_equal(63598, uuid_time_mid(&u))
	assert_equal(4570, uuid_time_hi_version(&u))
	assert_equal(189, uuid_clock_seq_hi_variant(&u))
	assert_equal(26, uuid_clock_seq_low(&u))
	assert_equal(15642, uuid_clock_seq(&u))
	assert_equal(1, uuid_version(&u))
	assert_equal(UUID_RFC_4122, uuid_variant(&u))
	char[6] node
	uuid_node_bytes(&u, &node[0])
	assert_bytes_equal(c"\x00\x11\x24\x44\xbe\x1e", &node[0], 6)
	if (__word_size__ == 8):
		assert_equal(wide(17, 0x2444be1e), uuid_node(&u))
		assert_equal(wide(0x1daf86e, cast(int, 0xa8098c1a)), uuid_time(&u))
	else:
		assert_equal(-1, uuid_node(&u))
		assert_equal(-1, uuid_time(&u))


void test_variants_and_version_none():
	# python: UUID('12345678-1234-5678-1234-567812345678') is NCS, version None.
	uuid u
	uuid_parse(c"12345678-1234-5678-1234-567812345678", &u)
	assert_equal(UUID_RESERVED_NCS, uuid_variant(&u))
	assert_equal(-1, uuid_version(&u))
	u.b[8] = 192
	assert_equal(UUID_RESERVED_MICROSOFT, uuid_variant(&u))
	assert_equal(-1, uuid_version(&u))
	u.b[8] = 224
	assert_equal(UUID_RESERVED_FUTURE, uuid_variant(&u))
	u.b[8] = 128
	assert_equal(UUID_RFC_4122, uuid_variant(&u))
	assert_equal(5, uuid_version(&u))
	uuid_set_version(&u, 8)
	expect_str(c"12345678-1234-8678-8034-567812345678", &u)
	uuid_set_version(&u, 0)
	assert_equal(0, uuid_version(&u))
	uuid_max(&u)
	assert_equal(UUID_RESERVED_FUTURE, uuid_variant(&u))


void test_nil_max_compare():
	uuid lo
	uuid hi
	uuid_nil(&lo)
	uuid_max(&hi)
	expect_str(c"00000000-0000-0000-0000-000000000000", &lo)
	expect_str(c"ffffffff-ffff-ffff-ffff-ffffffffffff", &hi)
	assert_equal(1, uuid_is_nil(&lo))
	assert_equal(0, uuid_is_nil(&hi))
	assert_equal(-1, uuid_compare(&lo, &hi))
	assert_equal(1, uuid_compare(&hi, &lo))
	assert_equal(0, uuid_compare(&hi, &hi))
	uuid a
	uuid b
	# unsigned bytewise: 0x80 sorts after 0x7f.
	uuid_parse(c"7fffffff-ffff-ffff-ffff-ffffffffffff", &a)
	uuid_parse(c"80000000-0000-0000-0000-000000000000", &b)
	assert_equal(-1, uuid_compare(&a, &b))
	uuid_parse(c"00000000-0000-0000-0000-000000000001", &a)
	uuid_parse(c"00000000-0000-0000-0000-000000000002", &b)
	assert_equal(-1, uuid_compare(&a, &b))
	assert_equal(0, uuid_equal(&a, &b))


void test_namespaces():
	uuid u
	uuid_namespace_dns(&u)
	expect_str(c"6ba7b810-9dad-11d1-80b4-00c04fd430c8", &u)
	uuid_namespace_url(&u)
	expect_str(c"6ba7b811-9dad-11d1-80b4-00c04fd430c8", &u)
	uuid_namespace_oid(&u)
	expect_str(c"6ba7b812-9dad-11d1-80b4-00c04fd430c8", &u)
	uuid_namespace_x500(&u)
	expect_str(c"6ba7b814-9dad-11d1-80b4-00c04fd430c8", &u)
	assert_equal(1, uuid_version(&u))


void test_v3_v5_fail_closed_without_opt_in():
	uuid ns
	uuid out
	uuid_namespace_dns(&ns)
	assert_equal(0, uuid3(&out, &ns, c"python.org", 10))
	assert_equal(0, uuid5(&out, &ns, c"python.org", 10))
	# built-in SHA-2 ids and unregistered ids are refused.
	assert_equal(0, uuid_use_md5(WHASH_SHA256))
	assert_equal(0, uuid_use_sha1(WHASH_SHA256))
	assert_equal(0, uuid_use_md5(4242))
	assert_equal(0, uuid_use_sha1(4242))
	assert_equal(0, uuid5(&out, &ns, c"python.org", 10))


void test_uuid4_bits_and_uniqueness():
	uuid a
	uuid b
	for i in range(64):
		assert_equal(1, uuid4(&a))
		assert_equal(4, uuid_version(&a))
		assert_equal(UUID_RFC_4122, uuid_variant(&a))
		assert_equal(1, uuid4(&b))
		assert_equal(0, uuid_equal(&a, &b))
		char* s = uuid_format(&a)
		assert_equal('4', s[14])
		asserts(c"v4 variant digit", (s[19] == '8') || (s[19] == '9') || (s[19] == 'a') || (s[19] == 'b'))
		free(s)


void test_uuid7_layout_known_time():
	# RFC 9562 appendix A.6: 2022-02-22 19:22:22 UTC = 0x017F22E2_79B0 ms.
	uuid7_state st
	uuid7_state_init(&st)
	uuid u
	assert_equal(1, uuid7_next(&st, 1645557742, 0, &u))
	assert_equal(7, uuid_version(&u))
	assert_equal(UUID_RFC_4122, uuid_variant(&u))
	char* s = uuid_format(&u)
	s[13] = 0
	assert_strings_equal(c"017f22e2-79b0", s)
	free(s)
	# the 42-bit counter starts with its top bit clear.
	assert_equal(0, u.b[6] & 8)
	if (__word_size__ == 8): assert_equal(wide(0x17f, 0x22e279b0), uuid_time(&u))
	assert_equal(1, uuid7_next(&st, 1645557742, 999, &u))
	s = uuid_format(&u)
	s[13] = 0
	assert_strings_equal(c"017f22e2-7d97", s)
	free(s)


void test_uuid7_rejects_bad_time():
	uuid7_state st
	uuid7_state_init(&st)
	uuid u
	assert_equal(0, uuid7_next(&st, -1, 0, &u))
	assert_equal(0, uuid7_next(&st, 0, 1000, &u))
	assert_equal(0, uuid7_next(&st, 0, -1, &u))
	assert_equal(1, uuid7_next(&st, 0, 0, &u))
	expect_str_prefix_nil_ts(&u)


void test_uuid7_monotonic_same_ms_and_backwards():
	uuid7_state st
	uuid7_state_init(&st)
	uuid prev
	uuid cur
	assert_equal(1, uuid7_next(&st, 1700000000, 5, &prev))
	for i in range(200):
		# same millisecond, then the clock stepping backwards: still increasing.
		int ms = 5
		if (i >= 100): ms = 1
		assert_equal(1, uuid7_next(&st, 1700000000, ms, &cur))
		assert_equal(-1, uuid_compare(&prev, &cur))
		for k in range(6): assert_equal(prev.b[k], cur.b[k])
		assert_equal(7, uuid_version(&cur))
		assert_equal(UUID_RFC_4122, uuid_variant(&cur))
		uuid_copy(&prev, &cur)
	# a later millisecond moves the timestamp forward.
	assert_equal(1, uuid7_next(&st, 1700000000, 6, &cur))
	assert_equal(-1, uuid_compare(&prev, &cur))
	assert_equal(1, cur.b[5] - prev.b[5])


void test_uuid7_counter_carry_and_overflow():
	uuid7_state st
	uuid7_state_init(&st)
	uuid a
	uuid b
	assert_equal(1, uuid7_next(&st, 1700000000, 5, &a))
	# carry from the 30-bit low part into the 12-bit high part.
	st.counter_hi = 5
	st.counter_lo = (1 << 30) - 1
	assert_equal(1, uuid7_next(&st, 1700000000, 5, &b))
	assert_equal(6, st.counter_hi)
	assert_equal(0, st.counter_lo)
	assert_equal(6, ((b.b[6] & 15) << 8) | b.b[7])
	assert_equal(128, b.b[8])
	assert_equal(0, b.b[9] | b.b[10] | b.b[11])
	# full 42-bit overflow: the timestamp advances by 1 ms, counter reseeds.
	st.counter_hi = 4095
	st.counter_lo = (1 << 30) - 1
	assert_equal(1, uuid7_next(&st, 1700000000, 5, &a))
	assert_equal(-1, uuid_compare(&b, &a))
	assert_equal(1, a.b[5] - b.b[5])
	assert_equal(0, st.counter_hi & 2048)
	assert_equal(7, uuid_version(&a))


void test_uuid7_timestamp_wraps_48_bits():
	uuid7_state st
	uuid7_state_init(&st)
	for i in range(6): st.last_ms[i] = 255
	st.started = 1
	st.counter_hi = 4095
	st.counter_lo = (1 << 30) - 1
	uuid u
	assert_equal(1, uuid7_next(&st, 0, 0, &u))
	expect_str_prefix_nil_ts(&u)


void test_uuid7_wall_clock():
	uuid a
	uuid b
	assert_equal(1, uuid7(&a))
	for i in range(50):
		assert_equal(1, uuid7(&b))
		assert_equal(-1, uuid_compare(&a, &b))
		uuid_copy(&a, &b)
	assert_equal(7, uuid_version(&b))
	# after 2020-01-01 (0x016f5e66e800 ms): first byte 0x01, second >= 0x6f.
	assert_equal(1, b.b[0])
	asserts(c"uuid7 wall time after 2020", b.b[1] >= 111)
