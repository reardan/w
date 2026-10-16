# wbuild: x64
# wbuild: step="bin/sha3_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
/*
SHA-3 / SHAKE vectors from FIPS 202 and the NIST CSRC example values:
the empty message, "abc", the 448-bit "abcdbcdecdef..." message and the
1600-bit message of 200 0xa3 bytes for all six functions (SHAKE at the
nominal 32 / 64-byte lengths and at the 4096-bit NIST example length).
Messages straddling each sponge rate (72/104/136/144/168 bytes) and the
streaming splits at odd boundaries were cross-checked against Python's
hashlib. Also covers non-destructive final, clone, reset, incremental
SHAKE squeezing and unknown-algorithm handling.
*/
import lib.testing
import libs.standard.crypto.sha3
import lib.hex
import lib.mem


void sha3t_check(int alg, char* data, int len, char* want_hex):
	char* got = cast(char*, 0)
	if (sha3_is_xof(alg)): got = shake_hexdigest(alg, data, len, sha3_digest_size(alg))
	else: got = sha3_hexdigest(alg, data, len)
	assert_strings_equal(want_hex, got)
	free(got)


# Feed len bytes in slices of step (the last one shorter) and compare
# the streaming digest against want_hex.
void sha3t_check_streaming(int alg, char* data, int len, int step, char* want_hex):
	sha3_ctx* h = sha3_new(alg)
	int pos = 0
	while (pos < len):
		int take = step
		if (pos + take > len): take = len - pos
		sha3_update(h, &data[pos], take)
		pos = pos + take
	int ds = sha3_digest_size(alg)
	char* digest = cast(char*, malloc(ds))
	sha3_final(h, digest)
	char* got = hex_encode(digest, ds)
	assert_strings_equal(want_hex, got)
	free(got)
	free(digest)
	sha3_free(h)


# 200 bytes of 0xa3: the FIPS 202 1600-bit example message.
char* sha3t_a3():
	char* m = cast(char*, malloc(200))
	mem_fill(m, cast(char, 163), 200)
	return m


# n bytes of (i * 7 + 3) & 255.
char* sha3t_pattern(int n):
	char* m = cast(char*, malloc(n + 1))
	for i in range(n): m[i] = cast(char, (i * 7 + 3) & 255)
	return m



void test_empty_message():
	sha3t_check(SHA3_224, c"", 0, c"6b4e03423667dbb73b6e15454f0eb1abd4597f9a1b078e3f5b5a6bc7")
	sha3t_check(SHA3_256, c"", 0, c"a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a")
	sha3t_check(SHA3_384, c"", 0, c"0c63a75b845e4f7d01107d852e4c2485c51a50aaaa94fc61995e71bbee983a2ac3713831264adb47fb6bd1e058d5f004")
	sha3t_check(SHA3_512, c"", 0, c"a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a615b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26")
	sha3t_check(SHAKE_128, c"", 0, c"7f9c2ba4e88f827d616045507605853ed73b8093f6efbc88eb1a6eacfa66ef26")
	sha3t_check(SHAKE_256, c"", 0, c"46b9dd2b0ba88d13233b3feb743eeb243fcd52ea62b81b82b50c27646ed5762fd75dc4ddd8c0f200cb05019d67b592f6fc821c49479ab48640292eacb3b7c4be")


void test_abc():
	sha3t_check(SHA3_224, c"abc", 3, c"e642824c3f8cf24ad09234ee7d3c766fc9a3a5168d0c94ad73b46fdf")
	sha3t_check(SHA3_256, c"abc", 3, c"3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532")
	sha3t_check(SHA3_384, c"abc", 3, c"ec01498288516fc926459f58e2c6ad8df9b473cb0fc08c2596da7cf0e49be4b298d88cea927ac7f539f1edf228376d25")
	sha3t_check(SHA3_512, c"abc", 3, c"b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0")
	sha3t_check(SHAKE_128, c"abc", 3, c"5881092dd818bf5cf8a3ddb793fbcba74097d5c526a6d35f97b83351940f2cc8")
	sha3t_check(SHAKE_256, c"abc", 3, c"483366601360a8771c6863080cc4114d8db44530f8f1e1ee4f94ea37e78b5739d5a15bef186a5386c75744c0527e1faa9f8726e462a12a4feb06bd8801e751e4")


void test_nist_448_bit_message():
	sha3t_check(SHA3_224, c"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56, c"8a24108b154ada21c9fd5574494479ba5c7e7ab76ef264ead0fcce33")
	sha3t_check(SHA3_256, c"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56, c"41c0dba2a9d6240849100376a8235e2c82e1b9998a999e21db32dd97496d3376")
	sha3t_check(SHA3_384, c"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56, c"991c665755eb3a4b6bbdfb75c78a492e8c56a22c5c4d7e429bfdbc32b9d4ad5aa04a1f076e62fea19eef51acd0657c22")
	sha3t_check(SHA3_512, c"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56, c"04a371e84ecfb5b8b77cb48610fca8182dd457ce6f326a0fd3d7ec2f1e91636dee691fbe0c985302ba1b0d8dc78c086346b533b49c030d99a27daf1139d6e75e")
	sha3t_check(SHAKE_128, c"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56, c"1a96182b50fb8c7e74e0a707788f55e98209b8d91fade8f32f8dd5cff7bf21f5")
	sha3t_check(SHAKE_256, c"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56, c"4d8c2dd2435a0128eefbb8c36f6f87133a7911e18d979ee1ae6be5d4fd2e332940d8688a4e6a59aa8060f1f9bc996c05aca3c696a8b66279dc672c740bb224ec")


void test_a3_1600_bit_message():
	char* m = sha3t_a3()
	sha3t_check(SHA3_224, m, 200, c"9376816aba503f72f96ce7eb65ac095deee3be4bf9bbc2a1cb7e11e0")
	sha3t_check(SHA3_256, m, 200, c"79f38adec5c20307a98ef76e8324afbfd46cfd81b22e3973c65fa1bd9de31787")
	sha3t_check(SHA3_384, m, 200, c"1881de2ca7e41ef95dc4732b8f5f002b189cc1e42b74168ed1732649ce1dbcdd76197a31fd55ee989f2d7050dd473e8f")
	sha3t_check(SHA3_512, m, 200, c"e76dfad22084a8b1467fcf2ffa58361bec7628edf5f3fdc0e4805dc48caeeca81b7c13c30adf52a3659584739a2df46be589c51ca1a4a8416df6545a1ce8ba00")
	sha3t_check(SHAKE_128, m, 200, c"131ab8d2b594946b9c81333f9bb6e0ce75c3b93104fa3469d3917457385da037")
	sha3t_check(SHAKE_256, m, 200, c"cd8a920ed141aa0407a22d59288652e9d9f1a7ee0c1e7c1ca699424da84a904d2d700caae7396ece96604440577da4f3aa22aeb8857f961c4cd8e06f0ae6610b")
	free(m)


void test_shake_4096_bit_output():
	# NIST's SHAKE examples squeeze 4096 bits: several rate-sized blocks.
	char* m = sha3t_a3()
	char* got = shake_hexdigest(SHAKE_128, m, 200, 512)
	assert_strings_equal(c"131ab8d2b594946b9c81333f9bb6e0ce75c3b93104fa3469d3917457385da037cf232ef7164a6d1eb448c8908186ad852d3f85a5cf28da1ab6fe3438171978467f1c05d58c7ef38c284c41f6c2221a76f12ab1c04082660250802294fb87180213fdef5b0ecb7df50ca1f8555be14d32e10f6edcde892c09424b29f597afc270c904556bfcb47a7d40778d390923642b3cbd0579e60908d5a000c1d08b98ef933f806445bf87f8b009ba9e94f7266122ed7ac24e5e266c42a82fa1bbefb7b8db0066e16a85e0493f07df4809aec084a593748ac3dde5a6d7aae1e8b6e5352b2d71efbb47d4caeed5e6d633805d2d323e6fd81b4684b93a2677d45e7421c2c6aea259b855a698fd7d13477a1fe53e5a4a6197dbec5ce95f505b520bcd9570c4a8265a7e01f89c0c002c59bfec6cd4a5c109258953ee5ee70cd577ee217af21fa70178f0946c9bf6ca8751793479f6b537737e40b6ed28511d8a2d7e73eb75f8daac912ff906e0ab955b083bac45a8e5e9b744c8506f37e9b4e749a184b30f43eb188d855f1b70d71ff3e50c537ac1b0f8974f0fe1a6ad295ba42f6aec74d123a7abedde6e2c0711cab36be5acb1a5a11a4b1db08ba6982efccd716929a7741cfc63aa4435e0b69a9063e880795c3dc5ef3272e11c497a91acf699fefee206227a44c9fb359fd56ac0a9a75a743cff6862f17d7259ab075216c0699511643b6439", got)
	free(got)
	got = shake_hexdigest(SHAKE_256, m, 200, 512)
	assert_strings_equal(c"cd8a920ed141aa0407a22d59288652e9d9f1a7ee0c1e7c1ca699424da84a904d2d700caae7396ece96604440577da4f3aa22aeb8857f961c4cd8e06f0ae6610b1048a7f64e1074cd629e85ad7566048efc4fb500b486a3309a8f26724c0ed628001a1099422468de726f1061d99eb9e93604d5aa7467d4b1bd6484582a384317d7f47d750b8f5499512bb85a226c4243556e696f6bd072c5aa2d9b69730244b56853d16970ad817e213e470618178001c9fb56c54fefa5fee67d2da524bb3b0b61ef0e9114a92cdbb6cccb98615cfe76e3510dd88d1cc28ff99287512f24bfafa1a76877b6f37198e3a641c68a7c42d45fa7acc10dae5f3cefb7b735f12d4e589f7a456e78c0f5e4c4471fffa5e4fa0514ae974d8c2648513b5db494cea847156d277ad0e141c24c7839064cd08851bc2e7ca109fd4e251c35bb0a04fb05b364ff8c4d8b59bc303e25328c09a882e952518e1a8ae0ff265d61c465896973d7490499dc639fb8502b39456791b1b6ec5bcc5d9ac36a6df622a070d43fed781f5f149f7b62675e7d1a4d6dec48c1c7164586eae06a51208c0b791244d307726505c3ad4b26b6822377257aa152037560a739714a3ca79bd605547c9b78dd1f596f2d4f1791bc689a0e9b799a37339c04275733740143ef5d2b58b96a363d4e08076a1a9d7846436e4dca5728b6f760eef0ca92bf0be5615e96959d767197a0beeb", got)
	free(got)
	free(m)


void test_streaming_odd_splits():
	# The a3 message fed in slices that never line up with a rate.
	char* m = sha3t_a3()
	sha3t_check_streaming(SHA3_224, m, 200, 1, c"9376816aba503f72f96ce7eb65ac095deee3be4bf9bbc2a1cb7e11e0")
	sha3t_check_streaming(SHA3_224, m, 200, 3, c"9376816aba503f72f96ce7eb65ac095deee3be4bf9bbc2a1cb7e11e0")
	sha3t_check_streaming(SHA3_224, m, 200, 7, c"9376816aba503f72f96ce7eb65ac095deee3be4bf9bbc2a1cb7e11e0")
	sha3t_check_streaming(SHA3_224, m, 200, 13, c"9376816aba503f72f96ce7eb65ac095deee3be4bf9bbc2a1cb7e11e0")
	sha3t_check_streaming(SHA3_224, m, 200, 71, c"9376816aba503f72f96ce7eb65ac095deee3be4bf9bbc2a1cb7e11e0")
	sha3t_check_streaming(SHA3_224, m, 200, 137, c"9376816aba503f72f96ce7eb65ac095deee3be4bf9bbc2a1cb7e11e0")
	sha3t_check_streaming(SHA3_224, m, 200, 199, c"9376816aba503f72f96ce7eb65ac095deee3be4bf9bbc2a1cb7e11e0")
	sha3t_check_streaming(SHA3_256, m, 200, 1, c"79f38adec5c20307a98ef76e8324afbfd46cfd81b22e3973c65fa1bd9de31787")
	sha3t_check_streaming(SHA3_256, m, 200, 3, c"79f38adec5c20307a98ef76e8324afbfd46cfd81b22e3973c65fa1bd9de31787")
	sha3t_check_streaming(SHA3_256, m, 200, 7, c"79f38adec5c20307a98ef76e8324afbfd46cfd81b22e3973c65fa1bd9de31787")
	sha3t_check_streaming(SHA3_256, m, 200, 13, c"79f38adec5c20307a98ef76e8324afbfd46cfd81b22e3973c65fa1bd9de31787")
	sha3t_check_streaming(SHA3_256, m, 200, 71, c"79f38adec5c20307a98ef76e8324afbfd46cfd81b22e3973c65fa1bd9de31787")
	sha3t_check_streaming(SHA3_256, m, 200, 137, c"79f38adec5c20307a98ef76e8324afbfd46cfd81b22e3973c65fa1bd9de31787")
	sha3t_check_streaming(SHA3_256, m, 200, 199, c"79f38adec5c20307a98ef76e8324afbfd46cfd81b22e3973c65fa1bd9de31787")
	sha3t_check_streaming(SHA3_384, m, 200, 1, c"1881de2ca7e41ef95dc4732b8f5f002b189cc1e42b74168ed1732649ce1dbcdd76197a31fd55ee989f2d7050dd473e8f")
	sha3t_check_streaming(SHA3_384, m, 200, 3, c"1881de2ca7e41ef95dc4732b8f5f002b189cc1e42b74168ed1732649ce1dbcdd76197a31fd55ee989f2d7050dd473e8f")
	sha3t_check_streaming(SHA3_384, m, 200, 7, c"1881de2ca7e41ef95dc4732b8f5f002b189cc1e42b74168ed1732649ce1dbcdd76197a31fd55ee989f2d7050dd473e8f")
	sha3t_check_streaming(SHA3_384, m, 200, 13, c"1881de2ca7e41ef95dc4732b8f5f002b189cc1e42b74168ed1732649ce1dbcdd76197a31fd55ee989f2d7050dd473e8f")
	sha3t_check_streaming(SHA3_384, m, 200, 71, c"1881de2ca7e41ef95dc4732b8f5f002b189cc1e42b74168ed1732649ce1dbcdd76197a31fd55ee989f2d7050dd473e8f")
	sha3t_check_streaming(SHA3_384, m, 200, 137, c"1881de2ca7e41ef95dc4732b8f5f002b189cc1e42b74168ed1732649ce1dbcdd76197a31fd55ee989f2d7050dd473e8f")
	sha3t_check_streaming(SHA3_384, m, 200, 199, c"1881de2ca7e41ef95dc4732b8f5f002b189cc1e42b74168ed1732649ce1dbcdd76197a31fd55ee989f2d7050dd473e8f")
	sha3t_check_streaming(SHA3_512, m, 200, 1, c"e76dfad22084a8b1467fcf2ffa58361bec7628edf5f3fdc0e4805dc48caeeca81b7c13c30adf52a3659584739a2df46be589c51ca1a4a8416df6545a1ce8ba00")
	sha3t_check_streaming(SHA3_512, m, 200, 3, c"e76dfad22084a8b1467fcf2ffa58361bec7628edf5f3fdc0e4805dc48caeeca81b7c13c30adf52a3659584739a2df46be589c51ca1a4a8416df6545a1ce8ba00")
	sha3t_check_streaming(SHA3_512, m, 200, 7, c"e76dfad22084a8b1467fcf2ffa58361bec7628edf5f3fdc0e4805dc48caeeca81b7c13c30adf52a3659584739a2df46be589c51ca1a4a8416df6545a1ce8ba00")
	sha3t_check_streaming(SHA3_512, m, 200, 13, c"e76dfad22084a8b1467fcf2ffa58361bec7628edf5f3fdc0e4805dc48caeeca81b7c13c30adf52a3659584739a2df46be589c51ca1a4a8416df6545a1ce8ba00")
	sha3t_check_streaming(SHA3_512, m, 200, 71, c"e76dfad22084a8b1467fcf2ffa58361bec7628edf5f3fdc0e4805dc48caeeca81b7c13c30adf52a3659584739a2df46be589c51ca1a4a8416df6545a1ce8ba00")
	sha3t_check_streaming(SHA3_512, m, 200, 137, c"e76dfad22084a8b1467fcf2ffa58361bec7628edf5f3fdc0e4805dc48caeeca81b7c13c30adf52a3659584739a2df46be589c51ca1a4a8416df6545a1ce8ba00")
	sha3t_check_streaming(SHA3_512, m, 200, 199, c"e76dfad22084a8b1467fcf2ffa58361bec7628edf5f3fdc0e4805dc48caeeca81b7c13c30adf52a3659584739a2df46be589c51ca1a4a8416df6545a1ce8ba00")
	sha3t_check_streaming(SHAKE_128, m, 200, 1, c"131ab8d2b594946b9c81333f9bb6e0ce75c3b93104fa3469d3917457385da037")
	sha3t_check_streaming(SHAKE_128, m, 200, 3, c"131ab8d2b594946b9c81333f9bb6e0ce75c3b93104fa3469d3917457385da037")
	sha3t_check_streaming(SHAKE_128, m, 200, 7, c"131ab8d2b594946b9c81333f9bb6e0ce75c3b93104fa3469d3917457385da037")
	sha3t_check_streaming(SHAKE_128, m, 200, 13, c"131ab8d2b594946b9c81333f9bb6e0ce75c3b93104fa3469d3917457385da037")
	sha3t_check_streaming(SHAKE_128, m, 200, 71, c"131ab8d2b594946b9c81333f9bb6e0ce75c3b93104fa3469d3917457385da037")
	sha3t_check_streaming(SHAKE_128, m, 200, 137, c"131ab8d2b594946b9c81333f9bb6e0ce75c3b93104fa3469d3917457385da037")
	sha3t_check_streaming(SHAKE_128, m, 200, 199, c"131ab8d2b594946b9c81333f9bb6e0ce75c3b93104fa3469d3917457385da037")
	sha3t_check_streaming(SHAKE_256, m, 200, 1, c"cd8a920ed141aa0407a22d59288652e9d9f1a7ee0c1e7c1ca699424da84a904d2d700caae7396ece96604440577da4f3aa22aeb8857f961c4cd8e06f0ae6610b")
	sha3t_check_streaming(SHAKE_256, m, 200, 3, c"cd8a920ed141aa0407a22d59288652e9d9f1a7ee0c1e7c1ca699424da84a904d2d700caae7396ece96604440577da4f3aa22aeb8857f961c4cd8e06f0ae6610b")
	sha3t_check_streaming(SHAKE_256, m, 200, 7, c"cd8a920ed141aa0407a22d59288652e9d9f1a7ee0c1e7c1ca699424da84a904d2d700caae7396ece96604440577da4f3aa22aeb8857f961c4cd8e06f0ae6610b")
	sha3t_check_streaming(SHAKE_256, m, 200, 13, c"cd8a920ed141aa0407a22d59288652e9d9f1a7ee0c1e7c1ca699424da84a904d2d700caae7396ece96604440577da4f3aa22aeb8857f961c4cd8e06f0ae6610b")
	sha3t_check_streaming(SHAKE_256, m, 200, 71, c"cd8a920ed141aa0407a22d59288652e9d9f1a7ee0c1e7c1ca699424da84a904d2d700caae7396ece96604440577da4f3aa22aeb8857f961c4cd8e06f0ae6610b")
	sha3t_check_streaming(SHAKE_256, m, 200, 137, c"cd8a920ed141aa0407a22d59288652e9d9f1a7ee0c1e7c1ca699424da84a904d2d700caae7396ece96604440577da4f3aa22aeb8857f961c4cd8e06f0ae6610b")
	sha3t_check_streaming(SHAKE_256, m, 200, 199, c"cd8a920ed141aa0407a22d59288652e9d9f1a7ee0c1e7c1ca699424da84a904d2d700caae7396ece96604440577da4f3aa22aeb8857f961c4cd8e06f0ae6610b")
	free(m)


void test_streaming_uneven_pieces():
	# A 272-byte message split 1 + 70 + 66 + 0 + 135 bytes, so pieces end
	# just before, at and after several block boundaries.
	char* m = sha3t_pattern(272)
	char* digest = cast(char*, malloc(64))
	sha3_ctx* hsha3_224 = sha3_new(SHA3_224)
	sha3_update(hsha3_224, m, 1)
	sha3_update(hsha3_224, &m[1], 70)
	sha3_update(hsha3_224, &m[71], 66)
	sha3_update(hsha3_224, &m[137], 0)
	sha3_update(hsha3_224, &m[137], 135)
	sha3_final(hsha3_224, digest)
	char* gsha3_224 = hex_encode(digest, sha3_digest_size(SHA3_224))
	assert_strings_equal(c"2c2b66afe3a04132cc595d18ae6b6feb591bfcbb57cb4c0acffe11a0", gsha3_224)
	free(gsha3_224)
	sha3_free(hsha3_224)
	sha3_ctx* hsha3_256 = sha3_new(SHA3_256)
	sha3_update(hsha3_256, m, 1)
	sha3_update(hsha3_256, &m[1], 70)
	sha3_update(hsha3_256, &m[71], 66)
	sha3_update(hsha3_256, &m[137], 0)
	sha3_update(hsha3_256, &m[137], 135)
	sha3_final(hsha3_256, digest)
	char* gsha3_256 = hex_encode(digest, sha3_digest_size(SHA3_256))
	assert_strings_equal(c"ddeb5151c079739970e780e6257d0c4d52d83bf82c6aa8d47d5195530b5d5f4b", gsha3_256)
	free(gsha3_256)
	sha3_free(hsha3_256)
	sha3_ctx* hsha3_384 = sha3_new(SHA3_384)
	sha3_update(hsha3_384, m, 1)
	sha3_update(hsha3_384, &m[1], 70)
	sha3_update(hsha3_384, &m[71], 66)
	sha3_update(hsha3_384, &m[137], 0)
	sha3_update(hsha3_384, &m[137], 135)
	sha3_final(hsha3_384, digest)
	char* gsha3_384 = hex_encode(digest, sha3_digest_size(SHA3_384))
	assert_strings_equal(c"ed965b9a1c8b86eab6c1bfbab5d1c790e708b006ff464bf22d50e00b42aae22f5b1939ba274711a6364327f6b2cccc3a", gsha3_384)
	free(gsha3_384)
	sha3_free(hsha3_384)
	sha3_ctx* hsha3_512 = sha3_new(SHA3_512)
	sha3_update(hsha3_512, m, 1)
	sha3_update(hsha3_512, &m[1], 70)
	sha3_update(hsha3_512, &m[71], 66)
	sha3_update(hsha3_512, &m[137], 0)
	sha3_update(hsha3_512, &m[137], 135)
	sha3_final(hsha3_512, digest)
	char* gsha3_512 = hex_encode(digest, sha3_digest_size(SHA3_512))
	assert_strings_equal(c"441ecd94cc25b54465108dd7dcd86e26d59089d9abd85d7c6d1ba0f8007ff2a4b91ec2cc51ed7fa43a312af704a04e09b07782a0ca1798f4e9c45e6360008483", gsha3_512)
	free(gsha3_512)
	sha3_free(hsha3_512)
	sha3_ctx* hshake_128 = sha3_new(SHAKE_128)
	sha3_update(hshake_128, m, 1)
	sha3_update(hshake_128, &m[1], 70)
	sha3_update(hshake_128, &m[71], 66)
	sha3_update(hshake_128, &m[137], 0)
	sha3_update(hshake_128, &m[137], 135)
	sha3_final(hshake_128, digest)
	char* gshake_128 = hex_encode(digest, sha3_digest_size(SHAKE_128))
	assert_strings_equal(c"227c2d5657571be5962e47d968f741a9cca2be4b4853491c9f007110d7460dd6", gshake_128)
	free(gshake_128)
	sha3_free(hshake_128)
	sha3_ctx* hshake_256 = sha3_new(SHAKE_256)
	sha3_update(hshake_256, m, 1)
	sha3_update(hshake_256, &m[1], 70)
	sha3_update(hshake_256, &m[71], 66)
	sha3_update(hshake_256, &m[137], 0)
	sha3_update(hshake_256, &m[137], 135)
	sha3_final(hshake_256, digest)
	char* gshake_256 = hex_encode(digest, sha3_digest_size(SHAKE_256))
	assert_strings_equal(c"fbb7df100461f5db3224c3b715603b5a52f92bd0f761d9361d4aa0613d47033bc8d8f05b01b30fe0cb993f1d67031226e657bcd1ac47b91c40cbbe31818a1f0d", gshake_256)
	free(gshake_256)
	sha3_free(hshake_256)
	free(digest)
	free(m)


void test_rate_boundaries():
	# Lengths at rate - 1, rate and rate + 1 for every rate in use, so the
	# pad byte lands at the end of a block, at the start of a fresh one,
	# and the 0x06/0x1f and 0x80 pad bits share or split bytes.
	char* m = sha3t_pattern(272)
	sha3t_check(SHA3_224, m, 71, c"a3e5308e10d6ee809f8536760bbf52469dab5169eb2a7b8ab4d0a63b")
	sha3t_check(SHA3_256, m, 71, c"254f2ac1df8eae4233c0c2fe74a03331b856518800936943cdbe57d7d224f224")
	sha3t_check(SHA3_384, m, 71, c"3d3fc62c8617f0400959372bad3c9a7037180a41030fdb222155f4cac81358d8c981b15673461d000f9c714492c7c3bd")
	sha3t_check(SHA3_512, m, 71, c"a02d5795bffd44cb0ac3cc3401ae89056b8017242eaf7e802033e974672ce7945811760c3b0d9578bc51bf90c364636ac87cda9b4f3e45620ea9c030421e9d86")
	sha3t_check(SHAKE_128, m, 71, c"4a7cb3f7fb0004e031fb6317d81da96993227b8e514f19a7e037e7541e5b1511")
	sha3t_check(SHAKE_256, m, 71, c"c5492c4e150f073fa316ab32f6752abf52914ee2a4207f09e35586b7205948df80ce444e94a78fb65907e0a741c2b1a6d1ab798de0b1afad83a9bee1b8c8f76e")
	sha3t_check(SHA3_224, m, 72, c"a84dd5afcf2cadf543c08edeb1b8ca9f2a39a32a84009cde3110aaaf")
	sha3t_check(SHA3_256, m, 72, c"f4bb95e698a2c13bd27f089f3762076daa40b629dc5d7ec53dbe163fca4a4bf3")
	sha3t_check(SHA3_384, m, 72, c"9dbaa8e9380eb37b56147db9c374d4b67845756731aaafa31d6637715e32d7a5405d1b51cabe0df44b6a847476684999")
	sha3t_check(SHA3_512, m, 72, c"2ec0da5ff440c192d33033c4257eb39dcbd27edd7e41b5ac8db9daf13db501a2ef938151aaddd82f600335654f77512cbcc926ec5abb05b79282ec716d685618")
	sha3t_check(SHAKE_128, m, 72, c"4bbb1d27936a26de9c41ef1a7014be106ab9ad8f10dd68e8d693d00dbdb89f2b")
	sha3t_check(SHAKE_256, m, 72, c"f4771493e402a8aa4fc0251ee80b3f142481417b3dd942dcf72d96e26f75ad6a08db744812ddc576111fe99dc5bda94fa058af1cb5991da49bef07a4c5522ff7")
	sha3t_check(SHA3_224, m, 73, c"672493b75a3310746e5afbfbcddc05454ed6b4be530b62f35ee2ca53")
	sha3t_check(SHA3_256, m, 73, c"c610c3522f9423c2c706b1e26e532b121b67eb06c897d478ac6bb80ddbc8ae1f")
	sha3t_check(SHA3_384, m, 73, c"f155926106b264866c4a8ef41786610fe04efae9878e26a7a058aeba1ffe4e7b16ee6c8c6f26d5d4b9a490cf1e285c8e")
	sha3t_check(SHA3_512, m, 73, c"d26d1f9fc91b1d6c31405cc4a546f246fa7777f698d956c26a15170bccdd696aab3ee2e0597ee6f33bc7ac0336b1e4bfa0cc4355ab9faf8111cf27312640fd65")
	sha3t_check(SHAKE_128, m, 73, c"d639407b276ee21fdcefe0e178d35b4901e19a0283879943e085d3a05c38f757")
	sha3t_check(SHAKE_256, m, 73, c"8bae34cf4fcbba9c49fd2245431d94598e5596243104c0ec61ea3000cec0720882b8072183b1e65b2222cddca59757eabc6313d1d7a73bc110e4a5cee0106e9f")
	sha3t_check(SHA3_224, m, 103, c"5ce32ebca716936296d5883903d9736a8f7c8ee28751cbc7cbca2668")
	sha3t_check(SHA3_256, m, 103, c"03b9845b5ca8eff8cc1f5adfe5d326774db062f0bb80383bcec6e4e634d94fe7")
	sha3t_check(SHA3_384, m, 103, c"278a05f99eb8cce92583ed5cc7f0f1db39e15c6fe7eec3470d8faac66606dd9415eff75920fd39e03e08452c74aa3d76")
	sha3t_check(SHA3_512, m, 103, c"3b9f0d6ecbddcc8ed50cae0ca6fa94b8ee81ed767dd5e338c810606286b45498273c21b43fb785ff4d2a485a6c08fa01f72f5699ff148e5ccdca6dcfa9550913")
	sha3t_check(SHAKE_128, m, 103, c"66c06b98dc8aa96f61e33d8e8e993e78996d90252c739740b72f5b5b09f83f74")
	sha3t_check(SHAKE_256, m, 103, c"200daf87729961dbcc08ed1f6819eec84ce172ca38bc916bcff1523a425719b9a425c35d9d29ce9e49ea57fee621909ed78433f5c200464d8602d624f955edd6")
	sha3t_check(SHA3_224, m, 104, c"2cf6f6c5a46fb9af8eb5cbd32e094bc7a09f0b33fd1c87cbfdaa99c0")
	sha3t_check(SHA3_256, m, 104, c"69c910be9440424b1111a088e7f9f4f5716e6678c8a8e566e053d6cb65d31293")
	sha3t_check(SHA3_384, m, 104, c"f89b2364b91de0445508314c65afc20664d0a3e01544d4e13e87d798ec341b07f146a3e71a5c1919e8061f733a8ffe4a")
	sha3t_check(SHA3_512, m, 104, c"9207a64941efcaa4f122ac167de4cf484171f1fdae6023796e922f01e36080e8aeb50cc3942c1b76c5ebd392a85736cd8c3a761054036075978bebb5c67ef257")
	sha3t_check(SHAKE_128, m, 104, c"6f7b603189a1bf820068f0ccf8f5e88b7f0878ed291d3141d945acc9f319f225")
	sha3t_check(SHAKE_256, m, 104, c"5839b5ebef4d0d940f78a2d4f186d0ca02482614c2ea9952a77efc1efb9080fccad41c811e8fc39f446deffe7a4c472c05b72d67f8ad8ddc4efa391598072f04")
	sha3t_check(SHA3_224, m, 105, c"5906c8b4b700f7446e6dea546d6dc1e0e671b864cf645614483059fa")
	sha3t_check(SHA3_256, m, 105, c"ec4a284c4d6df4270b2c381c64133dc1990157d140613cfcfffdab239f6e2d0f")
	sha3t_check(SHA3_384, m, 105, c"aa637e2b76610e009335ce271afd9348f499e85239d86c220077827ab29d9975a0479d7a0ffa95bded7c3446b5bcd0b0")
	sha3t_check(SHA3_512, m, 105, c"7892a09787eabe264ad515496e788d0dec37bd5d97163beeeca6df5cf628f7159377738a15051ed9c7c980cb81e06e688b6104631cbd2eed6ccb94ad138f78e2")
	sha3t_check(SHAKE_128, m, 105, c"d4dc3693c2b131704a380890184daed7673ae748052faa57bc24bee6b2d19ca4")
	sha3t_check(SHAKE_256, m, 105, c"3825db3c720d316e783d71a21651cdc781593a39fc443098d2c487356f94c238ff6f5f9b05639d4f1c3ad79a795928105e3a0034deeee4df1e595d6cb5476152")
	sha3t_check(SHA3_224, m, 135, c"1020297b2062e4a80055cb9c8a8ca9645fe854fafa2c4aba3a5ca66b")
	sha3t_check(SHA3_256, m, 135, c"d9dcf1f98e49a79b0643a9e68fef48079ff8777c5e7e7f93469ded65f192ac71")
	sha3t_check(SHA3_384, m, 135, c"4143a14ba7c5973d9e9bc20b7b53bde5cef330c8bfcd795bfc72fde07309175beaf2f390ed1d66312ce47633e4ceb234")
	sha3t_check(SHA3_512, m, 135, c"9e9d81e346cf9a62dc4bda518e4096db553188368da1535eaa441982b98d399c0c8f0136f987886b94d1770387e07b276660317ccb66884cc7427550b7780cd4")
	sha3t_check(SHAKE_128, m, 135, c"c46af4f9a43a25a3f21d90f6a131ff3ed6944306e8c29a7c03f7e237e42c7e0c")
	sha3t_check(SHAKE_256, m, 135, c"0213fc98352f009fafdf8ee1ea36391485a85aa6f6c07a5cd81266d21eb17f9af3e3a6aa4a5e03793be3a4da4ba01c438b689164fc6bebb290eb372bfecd569d")
	sha3t_check(SHA3_224, m, 136, c"f3ed6ce9b05b8497549ffb0653305e08a1eee9f0b643db6991ffa264")
	sha3t_check(SHA3_256, m, 136, c"743bd32e775ac7387a57d4d574c89ddef5ebcb08bb5cc6b88c55a27b5035cc45")
	sha3t_check(SHA3_384, m, 136, c"b78775c23ceb19ee61274146b8e83a7768c7d4e4872417b146e569d1c4507668c148196fb799ae1d97d312f41e140e69")
	sha3t_check(SHA3_512, m, 136, c"62c81b78426786e5a5d431082d98857c7e6b1988fd721478386233be5c19731cea3944dc24e192fb976e422d8bd31524c35026e615ab54c31a58ab772abfe6d7")
	sha3t_check(SHAKE_128, m, 136, c"c9b065cf999862c0c15d02ffa9450e5bf9b57d8457e3a366700de35043f450b4")
	sha3t_check(SHAKE_256, m, 136, c"c00f43811e5b4a38e14e3c06d8a5ce34115a19cd604ce5bac6c3823b76046d5c6b149f173bef3089dbfe66774f9723bc344ecbaa7e9674df4ceb8558811423c5")
	sha3t_check(SHA3_224, m, 137, c"2deca7a9f2f78765132defcb91e4c58cc4182c2d9308ba28e4ee38bc")
	sha3t_check(SHA3_256, m, 137, c"01d47e8d6dce6e3dcbf1baa6f845b6ace4ef74bd17da8176ecc49bc35dbe5d21")
	sha3t_check(SHA3_384, m, 137, c"623dff354350f43641bb491ad1f159a667bad50d33f65e1e2d7ca9397b84263b5e391e6e194668b39b395116c044cda3")
	sha3t_check(SHA3_512, m, 137, c"3fd9dc45a7cdc291153d7b714ad68d824184c4166d2c980d41d5eaf9266e03892f965346361f62cb34404cfea6ea165dcdd8c34be99abdc9c500a1fedc315402")
	sha3t_check(SHAKE_128, m, 137, c"4bd0a672017e58746a1d4c98e2474ce03edf72679bb40f9613070cff215ae1b7")
	sha3t_check(SHAKE_256, m, 137, c"3c983983487bcbe74feba53b35bb1e05812379cb4116d9761f78d2ce3177866edc88e750bfaf43bd31ccd052078d97406fbfca21145c09c8d9bd1e81cd443e31")
	sha3t_check(SHA3_224, m, 143, c"173f9a33363959f396f98143846cdcf196c4b53b790ab7e87896dbef")
	sha3t_check(SHA3_256, m, 143, c"fdf4813e7d7045d99327366cb028e81d3d422d013aa39cea622e8b16bdb13513")
	sha3t_check(SHA3_384, m, 143, c"a67979c36ceffc58dd22b7fd9810fbe61b31510accb70928db6e212e85d4e3dde05a3eed102e38784075ad31395f6e4f")
	sha3t_check(SHA3_512, m, 143, c"d610c9973ce4c1f18ce6f7358279f05c02f0aec6dc704cc4fd4957dec3276950c55d59a9ce25025692ecdeb0ff6d7d527fe3a2614c52279fcf61fb39ade15ec7")
	sha3t_check(SHAKE_128, m, 143, c"8e962716ccaab673c2b5c4513c2d3155fb8cb8d030d5e2d3f67c71f9265d5b9b")
	sha3t_check(SHAKE_256, m, 143, c"2bdf446911e1d81a5445625e79a65306e3969bf67989bb4a94b37f27a282ac075d29025e12e4d6fc70b61e6a56ac96f95a801241334bbad48cf11ffa234cd240")
	sha3t_check(SHA3_224, m, 144, c"9f86e9419fb4b658c051ca35aaa2dca71c64797be6af09cbb466ae5d")
	sha3t_check(SHA3_256, m, 144, c"461199c2ec9cbef1469a587fb4c05c1fb9d4b5bbac259817e0c87331bda30c5a")
	sha3t_check(SHA3_384, m, 144, c"82268278d6a922fa5bae5ca2097c33d41a0beb87c396880c9633695e56bbafc23b47be66263a39bedfc1fbf23dc15fcf")
	sha3t_check(SHA3_512, m, 144, c"c6b8908e7b60f09ed38ffaf0ff9d6f3edd53ce3140076fc947bd3962c79c64d845d80b48f63b076dd7f4f0c360eb952dc940c99ed09a6fbdeabb51035b18e41d")
	sha3t_check(SHAKE_128, m, 144, c"b0af917b3e5f1bfa3a0d874425dc9dfc99560ed3a5da9d3c2f08cc061b7fa39e")
	sha3t_check(SHAKE_256, m, 144, c"0980f48e47183e24a65512b369ccde5979995871ee1eebc1f512a487e36b673a31c15d399d05f285a76f09af3a612b68a5de109c722306b2b2c5d67061d27aea")
	sha3t_check(SHA3_224, m, 145, c"a147c15d032f4f45c3b2dbb44e7a886e6826834cfc78d9310d592e19")
	sha3t_check(SHA3_256, m, 145, c"7709bde914b0084e9e4d757a19915b19d442adbb2f4cc24d75af5f0f5b4f73cd")
	sha3t_check(SHA3_384, m, 145, c"78aff68298ac3dfc086d7b75d4420db9f5d9db62a76e57ab3ac24c66e63eb9c7662c3a8e513b403ecb067d10819c52aa")
	sha3t_check(SHA3_512, m, 145, c"690001d79106dc9e4b2475e454689a0ee87d454084911cbf2db4135beedc67db48637cecfd492f570e2f6ef61223c76b6d59e93d0e0d8935ea22936c2f17a09c")
	sha3t_check(SHAKE_128, m, 145, c"0a7753f788b2e40db69efeceb1327a1d215a838fce879517b258c5fb2f06a888")
	sha3t_check(SHAKE_256, m, 145, c"125ebb7a58106c868810b7e03109cb1a89d148323792b3fef560197014bc0a5a33592281e4fbacc40ccae302dd8ef0ef914942f57afaadfd465ef70de0d49f1d")
	sha3t_check(SHA3_224, m, 167, c"def4168a18c0d537cd88aeba001de75d5712bb38afc18294317fd0d0")
	sha3t_check(SHA3_256, m, 167, c"684bf83317ea400f033de352516c168261086092de3a12b6478a20f870a18096")
	sha3t_check(SHA3_384, m, 167, c"7bad87d3c19f8c60a55a586817efb773199eb93475b5368fc89cd45ee7b2d09b5635eefbdb4ce5d87db58d522416439c")
	sha3t_check(SHA3_512, m, 167, c"f630f6e4fb09197b8d2503268c3fa8c5e637d7c991b7ee79d7e12ba5cc6e53f27f62f643df5fd6d254f515bcbe687b6ab9e442ffbad82288f026d6cf0645ffc6")
	sha3t_check(SHAKE_128, m, 167, c"bb961bb015521037905f9baf69ce60dd3ba73f6ead09a559c8d8a85e10753bca")
	sha3t_check(SHAKE_256, m, 167, c"89a2450c9785e8a01d1baca6b7023479d3a0de33c757a9a584ec84714894c3b774b2960a6ae3a2f5f6e277b9b01f5b1a3ec0499d93b7d76d0b856e0d53fc1ad0")
	sha3t_check(SHA3_224, m, 168, c"439bd998facc325cfc6b6c5d4be3e8852f6ddaa1ae96739699bdb733")
	sha3t_check(SHA3_256, m, 168, c"a5a267be792383677005e1628c1c16a64e0c4e2c9ce096287d389c58706a86d1")
	sha3t_check(SHA3_384, m, 168, c"9408f3e509342452484d26fa1bc941470d3c3754748c8f317dd5a385d004321e34c7847a7f952682cb46808c4b862c59")
	sha3t_check(SHA3_512, m, 168, c"460d5cc545a8c466031bb9002635167603da38b2496544508b5af2f123c33feb690a5b4c442ed89191687f0f1b9dddc7ff343f148f306f85c68e1ce3c8a68b8c")
	sha3t_check(SHAKE_128, m, 168, c"d4f73f3b6c4b72d05f45ed1f80b5774409f9cf336fc202bffa42ac38a6d3fbee")
	sha3t_check(SHAKE_256, m, 168, c"8e824d0df5f99be40bd0c4ee530e2b409a7c7713aba1ee96c56fb7f35729504e05dc6f8adb84b7e89d9b7de9c8e87f491c4c35e7d16173e4a986d26992d9c196")
	sha3t_check(SHA3_224, m, 169, c"c1f8ac7d37dc7526f68b8a1b4bdc91fc2ec9544c19e77ae76a734d03")
	sha3t_check(SHA3_256, m, 169, c"f7a2c4983e6cf26809daea869b625a0748da650270acad5d223be730bb700954")
	sha3t_check(SHA3_384, m, 169, c"1988f5d21adad470ccfc735dd57bfe5a6e2a5469853aa878b42fcd1a5f1dbd9134ef8a0cf0260a14bec70ffc7ba8e265")
	sha3t_check(SHA3_512, m, 169, c"6168dfb98a5dc4257914b2af383012d4202cbcd77afa316c62e5495b394496bd2ff411fab81c081d8f41de1c7e0273fbb3cf9a38d0892235ac60e5090c4d5904")
	sha3t_check(SHAKE_128, m, 169, c"30454dd0f630ab1bb8fada554060d54012efdbb8e782d013f83a16af1282ca81")
	sha3t_check(SHAKE_256, m, 169, c"e76eaecce9983b4be8a8b9cd8b5a457e9b6995449ad142af68a83a0e171e52bb638feadda7d5732e1596f07e6a05e58b8668c23733ebf58ae88f783f6bbef4eb")
	free(m)


void test_shake_squeeze_incremental():
	# Reading the XOF stream in odd pieces (crossing the 168- and 136-byte
	# output blocks) yields the same bytes as one shake_final call.
	char* m = sha3t_a3()
	char* whole = cast(char*, malloc(512))
	char* parts = cast(char*, malloc(512))
	int* sizes = cast(int*, malloc(7 * __word_size__))
	sizes[0] = 1
	sizes[1] = 7
	sizes[2] = 0
	sizes[3] = 160
	sizes[4] = 168
	sizes[5] = 169
	sizes[6] = 7
	for alg in range(SHAKE_128, SHAKE_256 + 1):
		sha3_ctx* h = sha3_new(alg)
		sha3_update(h, m, 200)
		shake_final(h, whole, 512)
		int off = 0
		for i in range(7):
			shake_squeeze(h, &parts[off], sizes[i])
			off = off + sizes[i]
		assert_equal(512, off)
		assert_bytes_equal(whole, parts, 512)
		# Input after squeezing has started is ignored.
		sha3_update(h, m, 10)
		sha3_free(h)
	free(sizes)
	free(parts)
	free(whole)
	free(m)


void test_shake_prefix_property():
	# Shorter SHAKE outputs are prefixes of longer ones; n == 0 is empty.
	char* longer = shake_hexdigest(SHAKE_256, c"abc", 3, 300)
	char* shorter = shake_hexdigest(SHAKE_256, c"abc", 3, 17)
	assert_bytes_equal(longer, shorter, 34)
	char* empty = shake_hexdigest(SHAKE_128, c"abc", 3, 0)
	assert_strings_equal(c"", empty)
	free(empty)
	free(shorter)
	free(longer)


void test_final_is_nondestructive():
	sha3_ctx* h = sha3_new(SHA3_256)
	sha3_update(h, c"ab", 2)
	char* digest = cast(char*, malloc(32))
	sha3_final(h, digest)
	char* got = hex_encode(digest, 32)
	assert_strings_equal(c"5c828b33397f4762922e39a60c35699d2550466a52dd15ed44da37eb0bdc61e6", got)
	free(got)
	sha3_update(h, c"c", 1)
	sha3_final(h, digest)
	got = hex_encode(digest, 32)
	assert_strings_equal(c"3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532", got)
	free(got)
	free(digest)
	sha3_free(h)


void test_clone_and_reset():
	sha3_ctx* h = sha3_new(SHA3_512)
	sha3_update(h, c"ab", 2)
	sha3_ctx* c = sha3_clone(h)
	sha3_update(c, c"c", 1)
	char* digest = cast(char*, malloc(64))
	sha3_final(c, digest)
	char* got = hex_encode(digest, 64)
	assert_strings_equal(c"b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0", got)
	free(got)
	sha3_free(c)
	sha3_final(h, digest)
	got = hex_encode(digest, 64)
	assert_strings_equal(c"01c87b5e8f094d8725ed47be35430de40f6ab6bd7c6641a4ecf0d046c55cb468453796bb61724306a5fb3d90fbe3726a970e5630ae6a9cf9f30d2aa062a0175e", got)
	free(got)
	sha3_reset(h)
	sha3_final(h, digest)
	got = hex_encode(digest, 64)
	assert_strings_equal(c"a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a615b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26", got)
	free(got)
	free(digest)
	sha3_free(h)


void test_raw_oneshot_helpers():
	char* out = cast(char*, malloc(64))
	sha3_224(c"abc", 3, out)
	char* got = hex_encode(out, 28)
	assert_strings_equal(c"e642824c3f8cf24ad09234ee7d3c766fc9a3a5168d0c94ad73b46fdf", got)
	free(got)
	sha3_256(c"abc", 3, out)
	got = hex_encode(out, 32)
	assert_strings_equal(c"3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532", got)
	free(got)
	sha3_384(c"abc", 3, out)
	got = hex_encode(out, 48)
	assert_strings_equal(c"ec01498288516fc926459f58e2c6ad8df9b473cb0fc08c2596da7cf0e49be4b298d88cea927ac7f539f1edf228376d25", got)
	free(got)
	sha3_512(c"abc", 3, out)
	got = hex_encode(out, 64)
	assert_strings_equal(c"b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0", got)
	free(got)
	shake128(c"abc", 3, out, 5)
	got = hex_encode(out, 5)
	assert_strings_equal(c"5881092dd8", got)
	free(got)
	shake256(c"abc", 3, out, 5)
	got = hex_encode(out, 5)
	assert_strings_equal(c"4833666013", got)
	free(got)
	free(out)
	char* raw = sha3_digest(SHA3_256, c"abc", 3)
	got = hex_encode(raw, 32)
	assert_strings_equal(c"3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532", got)
	free(got)
	free(raw)
	raw = shake_digest(SHAKE_128, c"abc", 3, 3)
	got = hex_encode(raw, 3)
	assert_strings_equal(c"588109", got)
	free(got)
	free(raw)


void test_sizes_and_unknown_algorithms():
	assert_equal(28, sha3_digest_size(SHA3_224))
	assert_equal(32, sha3_digest_size(SHA3_256))
	assert_equal(48, sha3_digest_size(SHA3_384))
	assert_equal(64, sha3_digest_size(SHA3_512))
	assert_equal(144, sha3_block_size(SHA3_224))
	assert_equal(136, sha3_block_size(SHA3_256))
	assert_equal(104, sha3_block_size(SHA3_384))
	assert_equal(72, sha3_block_size(SHA3_512))
	assert_equal(168, sha3_block_size(SHAKE_128))
	assert_equal(136, sha3_block_size(SHAKE_256))
	assert_equal(0, sha3_digest_size(0))
	assert_equal(0, sha3_block_size(99))
	assert1(sha3_new(0) == 0)
	assert1(sha3_new(7) == 0)
	assert1(sha3_digest(42, c"abc", 3) == 0)
	assert1(sha3_hexdigest(42, c"abc", 3) == 0)
	assert1(shake_digest(SHA3_256, c"abc", 3, 8) == 0)
	assert1(shake_hexdigest(SHAKE_128, c"abc", 3, -1) == 0)
	char* out = cast(char*, malloc(8))
	assert_equal(-1, sha3_oneshot(0, c"abc", 3, out))
	assert_equal(-1, shake_oneshot(SHA3_512, c"abc", 3, out, 8))
	assert_equal(0, shake_oneshot(SHAKE_256, c"abc", 3, out, 8))
	free(out)
