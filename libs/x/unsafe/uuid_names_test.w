# wbuild: x64
/*
Name-based UUIDs (libs/standard/formats/uuid.w uuid3 / uuid5) with the
application-supplied MD5 and SHA-1 this quarantine namespace provides.
uuid.w lives under libs/standard and so may not import libs/x/unsafe
(unsafe_import_test); it reaches the digests through the whash registry
after the application opts in with uuid_use_md5(WHASH_MD5()) and
uuid_use_sha1(WHASH_SHA1()) -- the seam websocket_sha1_test.w uses.
Expected values come from python3's uuid.uuid3 / uuid.uuid5.
*/
import lib.testing
import libs.standard.formats.uuid
import libs.x.unsafe.md5
import libs.x.unsafe.sha1


void opt_in():
	assert_equal(1, uuid_use_md5(WHASH_MD5()))
	assert_equal(1, uuid_use_sha1(WHASH_SHA1()))


void expect_v3(uuid* ns, char* name, int len, char* want):
	uuid u
	assert_equal(1, uuid3(&u, ns, name, len))
	assert_equal(3, uuid_version(&u))
	assert_equal(UUID_RFC_4122, uuid_variant(&u))
	char* got = uuid_format(&u)
	assert_strings_equal(want, got)
	free(got)


void expect_v5(uuid* ns, char* name, int len, char* want):
	uuid u
	assert_equal(1, uuid5(&u, ns, name, len))
	assert_equal(5, uuid_version(&u))
	assert_equal(UUID_RFC_4122, uuid_variant(&u))
	char* got = uuid_format(&u)
	assert_strings_equal(want, got)
	free(got)


void test_python_namespace_vectors():
	opt_in()
	uuid ns
	uuid_namespace_dns(&ns)
	expect_v3(&ns, c"python.org", 10, c"6fa459ea-ee8a-3ca4-894e-db77e160355e")
	expect_v5(&ns, c"python.org", 10, c"886313e1-3b8a-5372-9b90-0c9aee199e5d")
	expect_v3(&ns, c"www.example.com", 15, c"5df41881-3aed-3515-88a7-2f4a814cf09e")
	expect_v5(&ns, c"www.example.com", 15, c"2ed6657d-e927-568b-95e1-2665a8aea6a2")
	expect_v3(&ns, c"", 0, c"c87ee674-4ddc-3efe-a74e-dfe25da5d7b3")
	expect_v5(&ns, c"", 0, c"4ebd0208-8328-5d69-8c44-ec50939c0967")
	expect_v3(&ns, c"\x00", 1, c"219205a0-4037-3119-838c-7fc7529640de")
	expect_v5(&ns, c"\x00", 1, c"d73aaa6c-907e-57b0-8739-29487068eee4")
	# UTF-8 text: python's uuid3/5 encode str names as UTF-8 ("héllo").
	expect_v3(&ns, c"h\xc3\xa9llo", 6, c"125291b7-31ce-3f96-8db2-cbbaaca21645")
	uuid_namespace_url(&ns)
	expect_v3(&ns, c"http://python.org/", 18, c"9fe8e8c4-aaa8-32a9-a55c-4535a88b748d")
	expect_v5(&ns, c"http://python.org/", 18, c"4c565f0d-3f5a-5890-b41b-20cf47701c5e")
	uuid_namespace_oid(&ns)
	expect_v3(&ns, c"1.3.6.1", 7, c"dd1a1cef-13d5-368a-ad82-eca71acd4cd1")
	expect_v5(&ns, c"1.3.6.1", 7, c"1447fa61-5277-5fef-a9b3-fbc6e44f4af3")
	uuid_namespace_x500(&ns)
	expect_v3(&ns, c"c=ca", 4, c"658d3002-db6b-3040-a1d1-8ddd7d189a4d")
	expect_v5(&ns, c"c=ca", 4, c"cc957dd1-a972-5349-98cd-874190002798")


void test_custom_namespace_and_long_name():
	opt_in()
	uuid ns
	uuid_parse(c"12345678-1234-5678-1234-567812345678", &ns)
	expect_v3(&ns, c"name", 4, c"6088beb1-a400-3297-97de-92f365995507")
	expect_v5(&ns, c"name", 4, c"cb443bf2-f211-513f-b4be-ef73694775e9")
	# a 116-byte input spans two hash blocks.
	char* long_name = cast(char*, malloc(101))
	for i in range(100): long_name[i] = 'x'
	long_name[100] = 0
	uuid_namespace_url(&ns)
	expect_v3(&ns, long_name, 100, c"f6d9fe2b-4526-30d6-909a-2470157ba435")
	expect_v5(&ns, long_name, 100, c"c4956a8f-abe3-5d39-8dfa-4bf25e22e84b")
	free(long_name)


void test_opt_in_refusals():
	opt_in()
	# wrong digest sizes.
	assert_equal(0, uuid_use_md5(WHASH_SHA1()))
	assert_equal(0, uuid_use_sha1(WHASH_MD5()))
	# right size, wrong answer: SHA-1 truncated to a 16-byte digest.
	whash_register(150, 16, 64, 5, 0, sha1_block, sha1_load_iv)
	assert_equal(0, uuid_use_md5(150))
	# refusals keep the accepted algorithms.
	uuid ns
	uuid_namespace_dns(&ns)
	expect_v3(&ns, c"a", 1, c"4c104dd0-4821-30d5-9ce3-0e7a1f8b7c0d")
	expect_v5(&ns, c"a", 1, c"4f3f2898-69e3-5a0d-820a-c4e87987dbce")
	uuid u
	assert_equal(0, uuid3(&u, &ns, c"a", -1))
	assert_equal(0, uuid5(&u, &ns, c"a", -1))
