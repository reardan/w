/*
SHA-384/SHA-512 vectors from FIPS 180-4 / NIST CAVP (the classic empty,
"abc", 448-bit, 896-bit and million-'a' messages), plus streaming,
snapshot (non-destructive final), clone and reset coverage for the whash
interface, and the SHA-256 delegation to lib/sha256.w. The block-boundary
digests (111/112/127/128/129 bytes) were cross-checked against Python's
hashlib. Issue #195, plan 11 phase 4.
*/
import lib.testing
import libs.standard.crypto.sha2


# Format len digest bytes as a lowercase hex string (malloc'd).
char* sha2t_hex(char* digest, int len):
	char* out = malloc(len * 2 + 1)
	char* digits = c"0123456789abcdef"
	int i = 0
	while (i < len):
		int b = digest[i] & 255
		out[i * 2] = digits[(b >> 4) & 15]
		out[i * 2 + 1] = digits[b & 15]
		i = i + 1
	out[len * 2] = 0
	return out


# One-shot digest of data as hex.
char* sha2t_digest_hex(int alg, char* data, int len):
	int ds = whash_digest_size(alg)
	char* digest = malloc(ds)
	whash_oneshot(alg, data, len, digest)
	char* hex = sha2t_hex(digest, ds)
	free(digest)
	return hex


void sha2t_check(int alg, char* data, int len, char* want_hex):
	char* got = sha2t_digest_hex(alg, data, len)
	assert_strings_equal(want_hex, got)
	free(got)


void test_sha384_nist_vectors():
	sha2t_check(WHASH_SHA384(), c"", 0, c"38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b")
	sha2t_check(WHASH_SHA384(), c"abc", 3, c"cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7")
	# The 448-bit message.
	sha2t_check(WHASH_SHA384(), c"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56, c"3391fdddfc8dc7393707a65b1b4709397cf8b1d162af05abfe8f450de5f36bc6b0455a8520bc4e6f5fe95b1fe3c8452b")
	# The 896-bit two-block message.
	sha2t_check(WHASH_SHA384(), c"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu", 112, c"09330c33f71147e83d192fc782cd1b4753111b173b3b05d22fa08086e3b0f712fcc7c71a557e2db966c3e9fa91746039")


void test_sha384_block_boundaries():
	# 111..129 'a's straddle the 128-byte block and the 16-byte length
	# field: 111 fits one padded block, 112 forces a second, 128 is an
	# exact block, 129 spills into a new one.
	char* a129 = malloc(129)
	int i = 0
	while (i < 129):
		a129[i] = 'a'
		i = i + 1
	sha2t_check(WHASH_SHA384(), a129, 111, c"3c37955051cb5c3026f94d551d5b5e2ac38d572ae4e07172085fed81f8466b8f90dc23a8ffcdea0b8d8e58e8fdacc80a")
	sha2t_check(WHASH_SHA384(), a129, 112, c"187d4e07cb306103c69967bf544d0dfbe9042577599c73c330abc0cb64c61236d5ed565ee19119d8c31779a38f791fcd")
	sha2t_check(WHASH_SHA384(), a129, 127, c"9bd06b1763c2cf7aef40e795dc65bc96d59c41b537f3ad72ebdefd485476b5717c1aeb37c327fe9c1831b12b9efd08ae")
	sha2t_check(WHASH_SHA384(), a129, 128, c"edb12730a366098b3b2beac75a3bef1b0969b15c48e2163c23d96994f8d1bef760c7e27f3c464d3829f56c0d53808b0b")
	sha2t_check(WHASH_SHA384(), a129, 129, c"39b6f5a7b0e781dbc419f72e49b30eaac10f2c98c4403bc610da31067fd1b48f324138c8615d2b496d08d73d5e865326")
	free(a129)


void test_sha384_million_a():
	# The classic long-message NIST vector: 1,000,000 x 'a', fed through
	# the streaming interface in 100k slices.
	int n = 1000000
	int chunk = 100000
	char* big = malloc(chunk)
	int i = 0
	while (i < chunk):
		big[i] = 'a'
		i = i + 1
	whash* h = whash_new(WHASH_SHA384())
	int fed = 0
	while (fed < n):
		whash_update(h, big, chunk)
		fed = fed + chunk
	char* digest = malloc(48)
	whash_final(h, digest)
	char* got = sha2t_hex(digest, 48)
	assert_strings_equal(c"9d0e1809716474cb086e834e310a4a1ced149e9c00f248527972cec5704c2a5b07b8b3dc38ecc4ebae97ddd87f3d8985", got)
	free(got)
	free(digest)
	whash_free(h)
	free(big)


void test_sha512_vectors():
	sha2t_check(WHASH_SHA512(), c"", 0, c"cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")
	sha2t_check(WHASH_SHA512(), c"abc", 3, c"ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
	sha2t_check(WHASH_SHA512(), c"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu", 112, c"8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909")


void test_sha256_delegation():
	# whash must agree with lib/sha256.w's published vectors.
	sha2t_check(WHASH_SHA256(), c"", 0, c"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
	sha2t_check(WHASH_SHA256(), c"abc", 3, c"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	assert_equal(32, whash_digest_size(WHASH_SHA256()))
	assert_equal(64, whash_block_size(WHASH_SHA256()))
	assert_equal(48, whash_digest_size(WHASH_SHA384()))
	assert_equal(128, whash_block_size(WHASH_SHA384()))


# Feeding input in ragged slices must match the one-shot digest.
void sha2t_check_streaming(int alg, char* data, int len, int step):
	whash* h = whash_new(alg)
	int pos = 0
	while (pos < len):
		int take = step
		if (pos + take > len):
			take = len - pos
		whash_update(h, data + pos, take)
		pos = pos + take
	int ds = whash_digest_size(alg)
	char* digest = malloc(ds)
	whash_final(h, digest)
	char* got = sha2t_hex(digest, ds)
	char* want = sha2t_digest_hex(alg, data, len)
	assert_strings_equal(want, got)
	free(want)
	free(got)
	free(digest)
	whash_free(h)


void test_streaming_matches_oneshot():
	char* msg = c"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
	sha2t_check_streaming(WHASH_SHA384(), msg, 112, 1)
	sha2t_check_streaming(WHASH_SHA384(), msg, 112, 7)
	sha2t_check_streaming(WHASH_SHA384(), msg, 112, 64)
	sha2t_check_streaming(WHASH_SHA256(), msg, 112, 1)
	sha2t_check_streaming(WHASH_SHA256(), msg, 112, 13)
	sha2t_check_streaming(WHASH_SHA512(), msg, 112, 9)


void test_final_is_nondestructive():
	# TLS transcript-hash pattern: snapshot a digest mid-stream, keep
	# absorbing, snapshot again.
	whash* h = whash_new(WHASH_SHA384())
	whash_update(h, c"abc", 3)
	char* digest = malloc(48)
	whash_final(h, digest)
	char* got = sha2t_hex(digest, 48)
	assert_strings_equal(c"cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7", got)
	free(got)
	whash_update(h, c"def", 3)
	whash_final(h, digest)
	got = sha2t_hex(digest, 48)
	assert_strings_equal(c"c6a4c65b227e7387b9c3e839d44869c4cfca3ef583dea64117859b808c1e3d8ae689e1e314eeef52a6ffe22681aa11f5", got)
	free(got)
	free(digest)
	whash_free(h)


void test_clone_and_reset():
	whash* h = whash_new(WHASH_SHA384())
	whash_update(h, c"abc", 3)
	# The clone diverges from the original after the split point.
	whash* c = whash_clone(h)
	whash_update(c, c"def", 3)
	char* digest = malloc(48)
	whash_final(c, digest)
	char* got = sha2t_hex(digest, 48)
	assert_strings_equal(c"c6a4c65b227e7387b9c3e839d44869c4cfca3ef583dea64117859b808c1e3d8ae689e1e314eeef52a6ffe22681aa11f5", got)
	free(got)
	whash_free(c)
	# The original still holds only "abc".
	whash_final(h, digest)
	got = sha2t_hex(digest, 48)
	assert_strings_equal(c"cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7", got)
	free(got)
	# Reset rewinds to the empty message.
	whash_reset(h)
	whash_final(h, digest)
	got = sha2t_hex(digest, 48)
	assert_strings_equal(c"38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b", got)
	free(got)
	free(digest)
	whash_free(h)
