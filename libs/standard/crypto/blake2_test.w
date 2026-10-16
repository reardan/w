# wbuild: x64
# wbuild: step="bin/blake2_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
/*
BLAKE2b / BLAKE2s (RFC 7693): the appendix A "abc" vectors, the appendix E
self-test grand hashes (keyed and unkeyed, every digest size and message
length the RFC's selftest covers), plus vectors generated with Python's
hashlib.blake2b / blake2s for digest sizes, keys, salt, personalization,
block boundaries and streaming splits.
*/
import lib.testing
import libs.standard.crypto.blake2
import lib.hex
import lib.mem


void b2t_check(int wide, char* data, int len, int digest_size, char* want_hex):
	char* got = 0
	if (wide): got = blake2b_hex(data, len, digest_size)
	else: got = blake2s_hex(data, len, digest_size)
	assert_strings_equal(want_hex, got)
	free(got)


void b2t_check_params(int wide, int digest_size, char* key, char* salt, char* person, char* data, char* want_hex):
	blake2* h = blake2_new_params(wide, digest_size, key, strlen(key), salt, strlen(salt), person, strlen(person))
	assert1(h != 0)
	blake2_update(h, data, strlen(data))
	char* got = blake2_hexdigest(h)
	assert_strings_equal(want_hex, got)
	free(got)
	blake2_free(h)


char* b2t_fox():
	return c"The quick brown fox jumps over the lazy dog"


void test_rfc7693_appendix_a():
	b2t_check(1, c"abc", 3, 64, c"ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
	b2t_check(0, c"abc", 3, 32, c"508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982")


void test_empty_message():
	b2t_check(1, c"", 0, 64, c"786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce")
	b2t_check(0, c"", 0, 32, c"69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9")


# RFC 7693 appendix E's deterministic input generator (a Fibonacci-style
# 32-bit sequence seeded by 0xDEAD4BAD * seed).
void b2t_selftest_seq(char* out, int len, int seed):
	int mask = blake2_mask32()
	int a = (blake2_hex32(c"dead4bad") * seed) & mask
	int b = 1
	for i in range(len):
		int t = (a + b) & mask
		a = b
		b = t
		out[i] = blake2_shr(t, 24) & 255


char* b2t_selftest(int wide, int* outlens, int* inlens):
	blake2* grand = blake2_new_params(wide, 32, 0, 0, 0, 0, 0, 0)
	char* input = cast(char*, malloc(1024))
	char* key = cast(char*, malloc(64))
	for i in range(4):
		int outlen = outlens[i]
		for j in range(6):
			int inlen = inlens[j]
			b2t_selftest_seq(input, inlen, inlen)
			char* md = 0
			if (wide): md = blake2b(input, inlen, outlen)
			else: md = blake2s(input, inlen, outlen)
			blake2_update(grand, md, outlen)
			free(md)
			b2t_selftest_seq(key, outlen, outlen)
			if (wide): md = blake2b_keyed(key, outlen, input, inlen, outlen)
			else: md = blake2s_keyed(key, outlen, input, inlen, outlen)
			blake2_update(grand, md, outlen)
			free(md)
	char* hex = blake2_hexdigest(grand)
	blake2_free(grand)
	free(input)
	free(key)
	return hex


void test_rfc7693_appendix_e_selftest_b():
	int* outlens = cast(int*, malloc(4 * __word_size__))
	int* inlens = cast(int*, malloc(6 * __word_size__))
	outlens[0] = 20
	outlens[1] = 32
	outlens[2] = 48
	outlens[3] = 64
	inlens[0] = 0
	inlens[1] = 3
	inlens[2] = 128
	inlens[3] = 129
	inlens[4] = 255
	inlens[5] = 1024
	char* got = b2t_selftest(1, outlens, inlens)
	assert_strings_equal(c"c23a7800d98123bd10f506c61e29da5603d763b8bbad2e737f5e765a7bccd475", got)
	free(got)
	free(outlens)
	free(inlens)


void test_rfc7693_appendix_e_selftest_s():
	int* outlens = cast(int*, malloc(4 * __word_size__))
	int* inlens = cast(int*, malloc(6 * __word_size__))
	outlens[0] = 16
	outlens[1] = 20
	outlens[2] = 28
	outlens[3] = 32
	inlens[0] = 0
	inlens[1] = 3
	inlens[2] = 64
	inlens[3] = 65
	inlens[4] = 255
	inlens[5] = 1024
	char* got = b2t_selftest(0, outlens, inlens)
	assert_strings_equal(c"6a411f08ce25adcdfb02aba641451cec53c598b24f4fc787fbdc88797f4c1dfe", got)
	free(got)
	free(outlens)
	free(inlens)


void test_digest_sizes_b():
	char* fox = b2t_fox()
	int n = strlen(fox)
	b2t_check(1, fox, n, 1, c"b5")
	b2t_check(1, fox, n, 16, c"249df9a49f517ddcd37f5c897620ec73")
	b2t_check(1, fox, n, 20, c"3c523ed102ab45a37d54f5610d5a983162fde84f")
	b2t_check(1, fox, n, 32, c"01718cec35cd3d796dd00020e0bfecb473ad23457d063b75eff29c0ffa2e58a9")
	b2t_check(1, fox, n, 48, c"b7c81b228b6bd912930e8f0b5387989691c1cee1e65aade4da3b86a3c9f678fc8018f6ed9e2906720c8d2a3aeda9c03d")
	b2t_check(1, fox, n, 63, c"549fb130c7c7c830e402b873706b678ef839a648dca98b3d17b82716ab8409d72b74d3a2e4767fbdd58b9d9fabcdcf4d58f472b59835fa30a5362f3429bccd")


void test_digest_sizes_s():
	char* fox = b2t_fox()
	int n = strlen(fox)
	b2t_check(0, fox, n, 1, c"ba")
	b2t_check(0, fox, n, 16, c"96fd07258925748a0d2fb1c8a1167a73")
	b2t_check(0, fox, n, 20, c"5a604fec9713c369e84b0ed68daed7d7504ef240")
	b2t_check(0, fox, n, 28, c"e4e5cb6c7cae41982b397bf7b7d2d9d1949823ae78435326e8db4912")
	b2t_check(0, fox, n, 31, c"d02c79180f114f1c18755c9baf5fdbae36588c85316f3c9d8be224285570aa")


void test_keyed():
	char* fox = b2t_fox()
	char* got = blake2b_keyed_hex(c"secret key", 10, fox, strlen(fox), 64)
	assert_strings_equal(c"ffeb325c5f4ba9d7ded241511e725468e591a273f17ed92f5f6d2893274b2a824cc388c9e2a33771d716b4424f78a62de060647fcd4720fa09496ffae3ed5e57", got)
	free(got)
	got = blake2s_keyed_hex(c"secret key", 10, fox, strlen(fox), 32)
	assert_strings_equal(c"8d1f17d2983a711bc4389bac99a8cd788b64efa99edc776191ef4d32cb447f84", got)
	free(got)


void test_keyed_max_key():
	# Key = bytes(range(64)) / bytes(range(32)); data empty and
	# bytes(range(255)) — the empty case exercises the key-only block.
	char* kb = cast(char*, malloc(255))
	for i in range(255): kb[i] = i
	char* got = blake2b_keyed_hex(kb, 64, kb, 0, 64)
	assert_strings_equal(c"10ebb67700b1868efb4417987acf4690ae9d972fb7a590c2f02871799aaa4786b5e996e8f0f4eb981fc214b005f42d2ff4233499391653df7aefcbc13fc51568", got)
	free(got)
	got = blake2s_keyed_hex(kb, 32, kb, 0, 32)
	assert_strings_equal(c"48a8997da407876b3d79c0d92325ad3b89cbb754d86ab71aee047ad345fd2c49", got)
	free(got)
	got = blake2b_keyed_hex(kb, 64, kb, 255, 64)
	assert_strings_equal(c"142709d62e28fcccd0af97fad0f8465b971e82201dc51070faa0372aa43e92484be1c1e73ba10906d5d1853db6a4106e0a7bf9800d373d6dee2d46d62ef2a461", got)
	free(got)
	got = blake2s_keyed_hex(kb, 32, kb, 255, 32)
	assert_strings_equal(c"3fb735061abc519dfe979e54c1ee5bfad0a9d858b3315bad34bde999efd724dd", got)
	free(got)
	free(kb)


void test_salt_and_person():
	char* fox = b2t_fox()
	b2t_check_params(1, 64, c"", c"0123456789abcdef", c"", fox, c"f36b454be1341c2ea66185b1cdbb81024f9ad817d830f6dbdc837b4c3ae00de88e191cfef50a3c7b4451664bb894d91564eae84c07c2179ca42035615d2d301f")
	# A short salt is zero-padded, as in hashlib.
	b2t_check_params(1, 64, c"", c"salt", c"", fox, c"f2c13ed832949fcf4420cee7429add5d8183c0db0238e512d180881b14b8c2fed7ed7c3e5b52f8646b2f0899b9127da0e165b12b4e68d9c85eeb1f18bc334011")
	b2t_check_params(0, 32, c"", c"saltsalt", c"", fox, c"cf654bf8640b2748c56ffdfa15cf3de06d3afd496d451ba32ac51433323d3d50")
	b2t_check_params(1, 64, c"", c"", c"my-app-v1", fox, c"aa451091a172107564ecf451a3234df24e2ccdf9f1f0a9aa5199564939d8b520c5ffb56d48bc2755ebf7be176228351d9192d928f8d3a694d07c776bb427b248")
	b2t_check_params(0, 32, c"", c"", c"app", fox, c"fab944119d1897d9cf792e2594b02630547cf276bf8f402578e46f0b91a58903")


void test_all_params_combined():
	char* fox = b2t_fox()
	b2t_check_params(1, 32, c"k3y", c"NaCl", c"MyApp 2026", fox, c"740eee8221938cdb7e8307960564f52c51bb7d28a7b0abf539a1b02c48905273")
	b2t_check_params(0, 16, c"k3y", c"NaCl", c"MyApp", fox, c"a7198d74423d6490c12cfad3b948f36f")


void test_block_boundaries_b():
	char* a = cast(char*, malloc(257))
	mem_fill(a, 'a', 257)
	b2t_check(1, a, 127, 64, c"94596b9d6199c807c40ae1a935f3633ba5a8dd5655f7f1bd44f5285b1ce8dbb0054771eba409539df85a963296d28788807105153c90fa3ec3d761228e90f8b8")
	b2t_check(1, a, 128, 64, c"fc6c71f688f43ea7d60817478808f3cac753e61571865c95adbc2d9122c943a76b92c2cb1047ef3fe7bf6e436ec1d0a99a9e5b216780bf7fed9d7ca91d3a8f3b")
	b2t_check(1, a, 129, 64, c"55e6e0eb418149a8af92fd9ddc99254781b2f522a131b4f4d984404b71a00e1167b8124d5dcddd4c6977b299392335d6edd303da6d344d74bbef2d38101b232b")
	b2t_check(1, a, 256, 64, c"0eee13d0c73a2710c5015a8b4be0a16120bb88f826b662951ffe4b3b81441cfdce1f712c58e237dba72a0dad7f9c86b9745ea0b4b3b850ff3a260fb7df9d3e81")
	b2t_check(1, a, 257, 64, c"0d686cbcff66401ab36b8a8e7fcf4085319eb296eaa55c4470c36bccaff2ecd4b3572c32ed48e8bb97cc5d08302a79b3a26e751feb7f565b19fa0d8f65247dd1")
	free(a)


void test_block_boundaries_s():
	char* a = cast(char*, malloc(129))
	mem_fill(a, 'a', 129)
	b2t_check(0, a, 63, 32, c"9a4267618070af968ff2a0fdaecc62b5c15ab91cb4a56424ba9fcad20aab417c")
	b2t_check(0, a, 64, 32, c"651d2f5f20952eacaea2fba2f2af2bcd633e511ea2d2e4c9ae2ac0d9ffb7b252")
	b2t_check(0, a, 65, 32, c"045f8ae18932119bd051ac7ba5c73db59892055fad5c32f82d79a6543d92a497")
	b2t_check(0, a, 128, 32, c"3ac477e27353f9019b81694afe60c8049403784f91a58288428ea318bfa82809")
	b2t_check(0, a, 129, 32, c"94f03f8feba7e07dd91153d178bb2d254e8cfd445024a77071f9329200d9517c")
	free(a)


# bytes((i*7+3) & 255 for i in range(1000))
char* b2t_long_data():
	char* d = cast(char*, malloc(1000))
	for i in range(1000): d[i] = (i * 7 + 3) & 255
	return d


# Feed 1000 bytes in fixed-size slices and compare with the one-shot hash.
void b2t_streaming(int wide, int chunk, char* want_hex):
	char* d = b2t_long_data()
	blake2* h = blake2_new_params(wide, 64 - 32 * (1 - wide), 0, 0, 0, 0, 0, 0)
	int pos = 0
	while (pos < 1000):
		int take = chunk
		if (take > 1000 - pos): take = 1000 - pos
		blake2_update(h, &d[pos], take)
		pos = pos + take
	char* got = blake2_hexdigest(h)
	assert_strings_equal(want_hex, got)
	free(got)
	blake2_free(h)
	free(d)


void test_streaming_splits():
	char* want_b = c"4bdd2c9cf31d797a81d245c989ffb7515143ca345c66f73087dd5c58bf642bf083ba16894eab79e3b08d5126404d833e7510271b50be36a7b7cbbb46f5c89fac"
	char* want_s = c"02a016193469710efadf8fb005ca19b509331cb847df5598cc0794bded669681"
	char* d = b2t_long_data()
	b2t_check(1, d, 1000, 64, want_b)
	b2t_check(0, d, 1000, 32, want_s)
	free(d)
	b2t_streaming(1, 1, want_b)
	b2t_streaming(1, 7, want_b)
	b2t_streaming(1, 127, want_b)
	b2t_streaming(1, 128, want_b)
	b2t_streaming(1, 129, want_b)
	b2t_streaming(1, 500, want_b)
	b2t_streaming(1, 1000, want_b)
	b2t_streaming(0, 1, want_s)
	b2t_streaming(0, 13, want_s)
	b2t_streaming(0, 63, want_s)
	b2t_streaming(0, 64, want_s)
	b2t_streaming(0, 65, want_s)
	b2t_streaming(0, 999, want_s)


void test_two_part_splits_keyed():
	# Every split point of a keyed 300-byte message (and empty updates)
	# agrees with the one-shot keyed digest.
	char* d = b2t_long_data()
	char* want = blake2b_keyed_hex(c"key", 3, d, 300, 40)
	char* want_s = blake2s_keyed_hex(c"key", 3, d, 300, 24)
	for cut in range(301):
		blake2* h = blake2b_new_keyed(40, c"key", 3)
		blake2_update(h, d, cut)
		blake2_update(h, d, 0)
		blake2_update(h, &d[cut], 300 - cut)
		char* got = blake2_hexdigest(h)
		assert_strings_equal(want, got)
		free(got)
		blake2_free(h)
		h = blake2s_new_keyed(24, c"key", 3)
		blake2_update(h, d, cut)
		blake2_update(h, &d[cut], 300 - cut)
		got = blake2_hexdigest(h)
		assert_strings_equal(want_s, got)
		free(got)
		blake2_free(h)
	free(want)
	free(want_s)
	free(d)


void test_digest_is_non_destructive_and_copy():
	blake2* h = blake2b_new(64)
	blake2_update(h, c"ab", 2)
	blake2* c = blake2_copy(h)
	char* mid = blake2_hexdigest(h)
	char* mid_again = blake2_hexdigest(h)
	assert_strings_equal(mid, mid_again)
	blake2_update(h, c"c", 1)
	char* got = blake2_hexdigest(h)
	assert_strings_equal(c"ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923", got)
	free(got)
	# The copy forked before "c" and is unaffected by h's later input.
	char* forked = blake2_hexdigest(c)
	assert_strings_equal(mid, forked)
	free(forked)
	blake2_update(c, c"c", 1)
	forked = blake2_hexdigest(c)
	assert_strings_equal(c"ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923", forked)
	free(forked)
	free(mid)
	free(mid_again)
	blake2_free(c)
	blake2_free(h)


void test_digest_bytes_match_hex():
	char* d = blake2s(c"abc", 3, 32)
	char* hex = hex_encode(d, 32)
	assert_strings_equal(c"508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982", hex)
	free(hex)
	free(d)
	blake2* h = blake2s_new(20)
	assert_equal(20, blake2_digest_size(h))
	assert_equal(64, blake2_block_size(h))
	blake2_free(h)
	h = blake2b_new(33)
	assert_equal(33, blake2_digest_size(h))
	assert_equal(128, blake2_block_size(h))
	blake2_free(h)


void test_invalid_parameters():
	assert1(blake2b_new(0) == 0)
	assert1(blake2b_new(65) == 0)
	assert1(blake2s_new(0) == 0)
	assert1(blake2s_new(33) == 0)
	char* k = cast(char*, malloc(65))
	mem_fill(k, 'k', 65)
	assert1(blake2b_new_keyed(64, k, 65) == 0)
	assert1(blake2s_new_keyed(32, k, 33) == 0)
	assert1(blake2_new_params(1, 64, 0, 0, k, 17, 0, 0) == 0)
	assert1(blake2_new_params(1, 64, 0, 0, 0, 0, k, 17) == 0)
	assert1(blake2_new_params(0, 32, 0, 0, k, 9, 0, 0) == 0)
	assert1(blake2_new_params(0, 32, 0, 0, 0, 0, k, 9) == 0)
	assert1(blake2b(c"x", 1, 0) == 0)
	assert1(blake2s_hex(c"x", 1, 40) == 0)
	# Maximum-length key, salt and person are accepted.
	blake2* h = blake2_new_params(1, 64, k, 64, k, 16, k, 16)
	assert1(h != 0)
	blake2_free(h)
	h = blake2_new_params(0, 32, k, 32, k, 8, k, 8)
	assert1(h != 0)
	blake2_free(h)
	free(k)


void test_million_a():
	int chunk = 100000
	char* big = cast(char*, malloc(chunk))
	mem_fill(big, 'a', chunk)
	blake2* b = blake2b_new(64)
	blake2* s = blake2s_new(32)
	for i in range(10):
		blake2_update(b, big, chunk)
		blake2_update(s, big, chunk)
	char* got = blake2_hexdigest(b)
	assert_strings_equal(c"98fb3efb7206fd19ebf69b6f312cf7b64e3b94dbe1a17107913975a793f177e1d077609d7fba363cbba00d05f7aa4e4fa8715d6428104c0a75643b0ff3fd3eaf", got)
	free(got)
	got = blake2_hexdigest(s)
	assert_strings_equal(c"bec0c0e6cde5b67acb73b81f79a67a4079ae1c60dac9d2661af18e9f8b50dfa5", got)
	free(got)
	blake2_free(b)
	blake2_free(s)
	free(big)
