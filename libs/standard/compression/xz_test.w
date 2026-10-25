# wbuild: x64
# wbuild: step="bin/xz_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
/*
libs/standard/compression/xz.w tests. Every fixture was produced by
python3's lzma module (CPython 3.13, liblzma 5.4) or /usr/bin/xz 5.4.5
and cross-checked there: lzma.decompress gives the plaintext each test
rebuilds, every single-byte corruption and every truncation of
fx_text_crc64 raises LZMAError, and the concatenation cases match
lzma.decompress (except stream padding, see xz.w's header comment).
fx_crafted* are hand-assembled containers around raw LZMA2 chunks
(uncompressed 0x01/0x02 chunks followed by an LZMA chunk with new
properties but no dictionary reset), built by a small Python script.
*/
import lib.testing
import lib.hex
import lib.mem
import lib.sha256
import libs.standard.compression.xz


const int MODE_XZ = 1
const int MODE_ALONE = 2
const int MODE_AUTO = 3


const int FX_TEXT_CRC32_CHECK = 84
const int FX_TEXT_CRC64_CHECK = 84
const int FX_TEXT_SHA256_CHECK = 84


char* fx_empty():
	return c"fd377a585a000004e6d6b446000000001cdf44211fb6f37d010000000004595a"


char* fx_text_none():
	return c"fd377a585a000000ff12d9410200210116000000742fe5a3e0005900335d002a1a08a2032566f14b78c5a205ff2ee6d9d2201aad34f8e21de84136fadc0669bb3ce410342709ebb366e3ec98ec3a5961800000000001475a03d4001406729e7a010000000000595a"


char* fx_text_crc32():
	return c"fd377a585a0000016922de360200210116000000742fe5a3e0005900335d002a1a08a2032566f14b78c5a205ff2ee6d9d2201aad34f8e21de84136fadc0669bb3ce410342709ebb366e3ec98ec3a596180000000c778083400014b5a0f9bb5b89042990d010000000001595a"


char* fx_text_crc64():
	return c"fd377a585a000004e6d6b4460200210116000000742fe5a3e0005900335d002a1a08a2032566f14b78c5a205ff2ee6d9d2201aad34f8e21de84136fadc0669bb3ce410342709ebb366e3ec98ec3a5961800000008c0f4947ead618a300014f5a0b5ed9dc1fb6f37d010000000004595a"


char* fx_text_sha256():
	return c"fd377a585a00000ae1fb0ca10200210116000000742fe5a3e0005900335d002a1a08a2032566f14b78c5a205ff2ee6d9d2201aad34f8e21de84136fadc0669bb3ce410342709ebb366e3ec98ec3a596180000000d243e7ed44c77bbfce9069ddce64b6f5e82b55b7cb329f75d5973481d5178b7d0001675aa1f08481189b4b9a01000000000a595a"


char* fx_bytes256():
	return c"fd377a585a000004e6d6b4460200210116000000742fe5a3e000ff00ea5d00000052500a84f99bb28021a969d627e03e065a5f048d53d404ba39570509c15524de9db871593160a19ff96f4973f2c8ea8cba1a8b29692180fe338366af466dec9e898a0b83f03c0e898e3fed5fe79e90d91cff32f4b2e03951b2d21415b4c571badb06e3799a9fbb38c1b000ac930baa0619031208155b9bc848f0322efe2da087c8f0a4e0d251eb8d675692b24d84c5f18631df6a625bc2792dd9f73c73ba747407d83ca9562224a166f85a845f3067d2f64b492e7f20ebdbf8100e947877c73f6befb4cd95e26ff6446e06cf0b821acbdb7af0578d98ff90c03ee6c1124175ee032896eb09370e1e000000b03adb652f4b417200018602800200002d12a19fb1c467fb020000000004595a"


char* fx_rep_p0():
	return c"fd377a585a000004e6d6b446020021010c0000008f98419cffff1e017c5d002b88098613a49e0451b7539f41d42b48d00407b118403491c07cd7d3a54d6d8be6d650d9c4be3b75157b4064c03a4a66db079a18ac8c2efa87f8f00e12e14be603096b274f89074c55891f9d79e534601379ac32b1f1cbd16941af0c0aded29ad8df679af39c4b324f1e9fbeae7c311a9fb78d316e709ea7235fec28cb85d195988a7e2a91f22775f719c006984d98fdd8afd5900fc42553f8f591363105a5b0ee6fc1704d470cd19111aaad601dbaceb127185c5986e9665258bee976ac59e4e55b0508f9c7daadfcfb522b74cd1e5b2042f9dd533df82964093b80cb2a6cdfb53bf0c4bd2e5faa0f3e4b664290130eff1093f8717859f80bcdff9528460fa9fc7cdefb9a302e56c08f85f38381c065c42553f8f591363105a5b0ee6fc1704d470cd19111aaad601dbaceb127185c5986e9665258bee976ac59e4e55b0508f9c7daadfcfb522b74cd1e5b2042f9dd533df82964093b80cb2a6cdfb53bf0c4bd2e5faa0f3e4b664290130eff1093f8717859f80bcdff9527833748189fff10012b00ec7353a7fdbeae7c311a9fb78d316e709ea7235fec28cb85d195988a7e2a91f22775f719c006984d98fdd8afd5900fc42553f8f591363105a5b0ee6fc1704d470cd19111aaad601dbaceb127185c5986e9665258bee976ac59e4e55b0508f9c7daadfcfb522b74cd1e5b2042f9dd533df82964093b80cb2a6cdfb53bf0c4bd2e5faa0f3e4b664290130eff1093f8717859f80bcdff9528460fa9fc7cdefb9a302e56c08f85f38381c065c42553f8f591363105a5b0ee6fc1704d470cd19111aaad601dbaceb127185c5986e9665258bee976ac59e4e55b0508f9c7daadfcfb522b74cd1e5b2042f9dd533df82964093b80cb2a6cdfb53bf0c4bd2e5faa0f3e4b664290130eff1093f8717859f80bcdff9528460fa9fc7cdefb9a302e56c08f85f38381c065c425510f3fb280180f000600ea806580000000000000f01994ba424186ac0001d505c0ac80025465e43ab1c467fb020000000004595a"


char* fx_rep_p9():
	return c"fd377a585a000004e6d6b446020021011c00000010cf58ccffff1e017c5d002b88098613a49e0451b7539f41d42b48d00407b118403491c07cd7d3a54d6d8be6d650d9c4be3b75157b4064c03a4a66db079a18ac8c2efa87f8f00e12e14be603096b274f89074c55891f9d79e534601379ac32b1f1cbd16941af0c0aded29ad8df679af39c4b324f1e9fbeae7c311a9fb78d316e709ea7235fec28cb85d195988a7e2a91f22775f719c006984d98fdd8afd5900fc42553f8f591363105a5b0ee6fc1704d470cd19111aaad601dbaceb127185c5986e9665258bee976ac59e4e55b0508f9c7daadfcfb522b74cd1e5b2042f9dd533df82964093b80cb2a6cdfb53bf0c4bd2e5faa0f3e4b664290130eff1093f8717859f80bcdff9528460fa9fc7cdefb9a302e56c08f85f38381c065c42553f8f591363105a5b0ee6fc1704d470cd19111aaad601dbaceb127185c5986e9665258bee976ac59e4e55b0508f9c7daadfcfb522b74cd1e5b2042f9dd533df82964093b80cb2a6cdfb53bf0c4bd2e5faa0f3e4b664290130eff1093f8717859f80bcdff9527833748189fff10012b00ec7353a7fdbeae7c311a9fb78d316e709ea7235fec28cb85d195988a7e2a91f22775f719c006984d98fdd8afd5900fc42553f8f591363105a5b0ee6fc1704d470cd19111aaad601dbaceb127185c5986e9665258bee976ac59e4e55b0508f9c7daadfcfb522b74cd1e5b2042f9dd533df82964093b80cb2a6cdfb53bf0c4bd2e5faa0f3e4b664290130eff1093f8717859f80bcdff9528460fa9fc7cdefb9a302e56c08f85f38381c065c42553f8f591363105a5b0ee6fc1704d470cd19111aaad601dbaceb127185c5986e9665258bee976ac59e4e55b0508f9c7daadfcfb522b74cd1e5b2042f9dd533df82964093b80cb2a6cdfb53bf0c4bd2e5faa0f3e4b664290130eff1093f8717859f80bcdff9528460fa9fc7cdefb9a302e56c08f85f38381c065c425510f3fb280180f000600ea806580000000000000f01994ba424186ac0001d505c0ac80025465e43ab1c467fb020000000004595a"


char* fx_prose_p0():
	return c"fd377a585a000004e6d6b446020021010c0000008f98419ce0046f01295d00249d000773438519c1bc619e16433f49a52715b4f5101854bfcae4a6ec1c23a564dc708fc4862f3edde5ece1c44ac3a9eac470565703112c95625f96789770fbe33f759b45788c7a478d305494241007e51a8f7af9725f34e271b64c2c0bab11a0b4fd6250f179c3e0b169e746a476d14f7a21ad09ace465f94c9560f90cf58ec4f373e76ba06ac3b508f1b3200eb1131a506a5ac7bb6459e6b35d0bb7e51ce1c1fe78f022014d9c2671d83ae7360d4399c118e3ede88e61d5ea73834e8d9e6a9148c5724b8606dbcd5d23a0ab4d432cf5e3444d3e2a65528b5338677902aaa648905716f969d7347721c59f4110164b521810d0be0eee2fbd0d021a875bd808fc05732d09256ee32232e236fd26b607cbb4884009e8e02beb354a6ed57b1390365f7d01310d3428e200000000badb6bb638b670d10001c502f0080000a54fc570b1c467fb020000000004595a"


char* fx_prose_p9():
	return c"fd377a585a000004e6d6b446020021011c00000010cf58cce0046f01275d00249d000773438519c1bc619e16433f49a52715b4f5101854bfcd91383b338b527d4ae772d2b1d84a2a510044b2e1699f1241f550c017d2ce0df06bf039935f4e3e72b50f52119cc051d1f8564735a0d02171ad03e5f82fbb0fc3ce94f873fd523fe47f1464232938963f53e6bad626545178b381bcbe8d6d7d3fa7fd5b9c7094c153e4aceaf2edfbfb402ed85ce88dd2085c3d9c7c09bd86392f44f06b177b20cdcd27d916a16ffcbb83b948f9ac11c09bfb6c10739970dd6a798554a0b1da90abb7b21f0c962f73a9c5bd801c92327e1b7ed3186d7c34c006805b186cb2eb67f710fe46b95bbb041415649587ac5303f38fbbae0d20fc1e49ba74d4ab26fab10eaf6316c9b59a00f940fb332f21726228dca5e2bc95cbff41545b8ede06d1f8ff41e6be308cae0000badb6bb638b670d10001c302f0080000b8ac9ca6b1c467fb020000000004595a"


char* fx_random():
	return c"fd377a585a000004e6d6b4460200210116000000742fe5a3010063dc0465aa1fad1d5adae5ac1b1e5f1370796cfd10ff19af601d04acb41d022b4678733af2df5faeb70859d1ee3910cb4895b5cc892911ff06b6622edf3cf935fd4b9428ca097c44b3025e965fb3ea6dacd42d816e69afe0e6874c9c04e7d2365d2c60c9ea00a0982b1aa148939300017c649026d3e91fb6f37d010000000004595a"


char* fx_multiblock():
	return c"fd377a585a000004e6d6b44604c0b002ac02210116000000000000005096afdc01012bdc0465aa1fad1d5adae5ac1b1e5f1370796cfd10ff19af601d04acb41d022b4678733af2df5faeb70859d1ee3910cb4895b5cc892911ff06b6622edf3cf935fd4b9428ca097c44b3025e965fb3ea6dacd42d816e69afe0e6874c9c04e7d2365d2c60c9eaf479f686a0eb9326e46212d50dcbb377156a6a3a68ba8edb7408469ef3ceb30af8d0dd68bbf85ffa24f2d2fc1887fb5c87bab43832a59b1b3d107cf778d67fe26df81191297e9395cb12c557ce5af1d41618d719bc045b7e9965f1a29471c42aac6aa938c475c7ad3238021f053b2c991afceb15decf68bae07cbcd61e971b9a0b9dbe9763d392fcafdfa28c97234562ebdd076570ff58896acff7caee3f1ce9e40a68e5de938d389c7dbdd75b09d4e7e233443f4a8cc4a190d6b8b8dc615fd18e28be590eaa501b00ae1ce7cf6d5417bc04c07be0a71221011600000000000000699ffc40e493df00735d00309888ad4b3712a33185ddfa5304edebdf42b812f31fea98ae810116ef64c4d600c64de9e45d4c2ac0e84c3b1f529d4e092fc9547bcaef91164b6340d4e936ecacb5d23e89ffde7d4a0446e711e6f1d17ca27ff5994959f64868bab17e7146710823016d1357344f1e9fbeae7c31080aea47000000dc033009f074885b04c0b002ac02210116000000000000005096afdc01012b6c4e74921325222e31a1cd13be12ed426966ce24fc23d7da8d2097616a06956ec28ad403136828d4571e3c5dee6e5ec04a91115f5d3b513ec253a416ad6ee5389411d0289aa34cf5c0347c59caf08495f3611b0b5068d59804f92eb7299955577999be78c01066870299e57f6cd235bcfb8f449deee23be1eccc8cbff5bfbec20bdbf86b9ce54f85b607cf46e94a4b2afbd4e58f4fe15c11128218a32b18f772df8fd57a475bdee4743493265c919dd98be654598a9d0f1f0ed42adde0dcd85e906ead1cd9abea9ed3da8898dbe003c1427eeb72b84d2c03777b18e52f43397fb42ed9ca6a0b4dab6caf06137f6d55d9b9540152f12b8bb6e52d3c322e85f3cce488b0fb11b4df02d66c65105f716c198820ef724c6e042ff2a3ec3cf6d9dc3eb8348927e7de769babc9fd06007d6ee901f10149dc0003cc02ac029701e0a712cc02ac020014ba434fac273e2d040000000004595a"


char* fx_crafted():
	return c"fd377a585a0000016922de360200210110000000a8708e86010002616263020002646566c0001d00130000341a7261720455e72daa304b00818880fd00000000fa55a0ca00013724cef1828c9042990d010000000001595a"


char* fx_crafted2():
	return c"fd377a585a000000ff12d9410200210110000000a8708e86010002616263020002646566c0001d00130000341a7261720455e72daa304b00818880fd000000000200210110000000a8708e8601000478797a7a79000000000002332415050000c1571e25a8000afc020000000000595a"


char* fx_delta():
	return c"fd377a585a000004e6d6b4460201030103210116978f71fce003e700145d000000ea84e2152589c8116d964d5d1c8aedbf9e0000a17fa6dffd039291000130e807000000d7675c42b1c467fb020000000004595a"


char* fx_x86():
	return c"fd377a585a000004e6d6b44602010400210116000d86351fe0005900335d002a1a08a2032566f14b78c5a205ff2ee6d9d2201aad34f8e21de84136fadc0669bb3ce410342709ebb366e3ec98ec3a5961800000008c0f4947ead618a300014f5a0b5ed9dc1fb6f37d010000000004595a"


char* fx_alone():
	return c"5d00008000ffffffffffffffff002a1a08a2032566f14b78c5a205ff2ee6d9d2201aad34f8e21de84136fadc0669bb3ce410342709ebb366e3ec98ec3a64906bfffffa954000"


char* fx_alone_known():
	return c"5d000080005a00000000000000002a1a08a2032566f14b78c5a205ff2ee6d9d2201aad34f8e21de84136fadc0669bb3ce410342709ebb366e3ec98ec3a64906bfffffa954000"


char* fx_alone_rep():
	return c"5d00008000ffffffffffffffff002b88098613a49e0451b7539f41d42b48d00407b118403491c07cd7d3a54d6d8be6d650d9c4be3b75157b4064c03a4a66db079a18ac8c2efa87f8f00e12e14be603096b274f89074c55891f9d79e534601379ab72cf8f18efffffec2d0000"


char* fx_cat():
	return c"fd377a585a000004e6d6b4460200210116000000742fe5a301000568656c6c6f200000000ab0af04ba05ef1800011e06c12fa41d1fb6f37d010000000004595afd377a585a0000016922de360200210116000000742fe5a3010004776f726c64000000004311773a00011905bce8eccb9042990d010000000001595a"


char* fx_cat_pad():
	return c"fd377a585a000004e6d6b4460200210116000000742fe5a301000568656c6c6f200000000ab0af04ba05ef1800011e06c12fa41d1fb6f37d010000000004595a0000000000000000fd377a585a0000016922de360200210116000000742fe5a3010004776f726c64000000004311773a00011905bce8eccb9042990d010000000001595a"


char* fx_cat_badpad():
	return c"fd377a585a000004e6d6b4460200210116000000742fe5a301000568656c6c6f200000000ab0af04ba05ef1800011e06c12fa41d1fb6f37d010000000004595a000000fd377a585a0000016922de360200210116000000742fe5a3010004776f726c64000000004311773a00011905bce8eccb9042990d010000000001595a"


char* fx_cat_garbage():
	return c"fd377a585a000004e6d6b4460200210116000000742fe5a301000568656c6c6f200000000ab0af04ba05ef1800011e06c12fa41d1fb6f37d010000000004595a6761726261676521"


char* fx_cat_trunc():
	return c"fd377a585a000004e6d6b4460200210116000000742fe5a301000568656c6c6f200000000ab0af04ba05ef1800011e06c12fa41d1fb6f37d010000000004595afd377a585a0000016922de360200210116000000742fe5a3010004776f726c64000000004311773a00011905bce8eccb9042990d0100000000"


char* fx_cat_alone():
	return c"5d00008000ffffffffffffffff00379b88de5823fffff73c40005d00008000ffffffffffffffff003a1dca2c7763fffff7800000"


char* fx_cat_mixed():
	return c"fd377a585a000004e6d6b4460200210116000000742fe5a301000568656c6c6f200000000ab0af04ba05ef1800011e06c12fa41d1fb6f37d010000000004595a5d00008000ffffffffffffffff003a1dca2c7763fffff7800000"


char* decode_bytes(char* data, int n, int mode, int cap, int* out_len, int* err):
	if (mode == MODE_XZ): return xz_decompress(data, n, cap, out_len, err)
	if (mode == MODE_ALONE): return lzma_alone_decompress(data, n, cap, out_len, err)
	return lzma_decompress(data, n, cap, out_len, err)


char* decode_hex(char* hexs, int mode, int cap, int* out_len, int* err):
	int n = 0
	char* data = hex_decode(hexs, strlen(hexs), &n)
	char* out = decode_bytes(data, n, mode, cap, out_len, err)
	free(data)
	return out


# Decodes hexs and checks the output equals want (wlen bytes).
void expect_output(char* hexs, int mode, char* want, int wlen):
	int n = -1
	int err = -1
	char* out = decode_hex(hexs, mode, 0, &n, &err)
	if (out == 0): println(xz_error_string(err))
	assert1(out != 0)
	assert_equal(XZ_OK, err)
	assert_equal(wlen, n)
	assert_equal(1, mem_eq[char](want, out, wlen))
	assert_equal(0, out[n])
	free(out)


void expect_error(char* hexs, int mode, int want_err):
	int n = -1
	int err = -1
	char* out = decode_hex(hexs, mode, 0, &n, &err)
	assert_equal(0, cast(int, out))
	assert_equal(0, n)
	assert_equal(want_err, err)


char* text_plain():
	return c"The quick brown fox jumps over the lazy dog.\nThe quick brown fox jumps over the lazy dog.\n"


char* repeat_text(char* unit, int times):
	int u = strlen(unit)
	char* out = cast(char*, malloc(u * times + 1))
	for i in range(times): mem_copy[char](&out[i * u], unit, u)
	out[u * times] = 0
	return out


# The generator's LCG byte stream (lcg(n, seed) in the fixture script).
void lcg_fill(char* out, int n, int seed):
	int x = seed
	for i in range(n):
		x = (x * 1103515245 + 12345) & 2147483647
		out[i] = (x >> 16) & 255


# lib/sha256.w caches its round constants on first use; drop the cache
# so a test that reached the SHA-256 check returns with no live blocks.
void drop_sha256_cache():
	if (sha256_k_words != 0):
		free(sha256_k_words)
		sha256_k_words = 0


void test_empty_stream():
	expect_output(fx_empty(), MODE_XZ, c"", 0)
	expect_output(fx_empty(), MODE_AUTO, c"", 0)


void test_check_types():
	char* t = text_plain()
	expect_output(fx_text_none(), MODE_XZ, t, strlen(t))
	expect_output(fx_text_crc32(), MODE_XZ, t, strlen(t))
	expect_output(fx_text_crc64(), MODE_XZ, t, strlen(t))
	expect_output(fx_text_sha256(), MODE_AUTO, t, strlen(t))
	drop_sha256_cache()


void expect_check_mismatch(char* hexs, int offset):
	int n = 0
	char* data = hex_decode(hexs, strlen(hexs), &n)
	data[offset] = data[offset] ^ 1
	int len = -1
	int err = -1
	char* out = xz_decompress(data, n, 0, &len, &err)
	assert_equal(0, cast(int, out))
	assert_equal(XZ_ERR_CHECK, err)
	free(data)


void test_check_mismatch():
	expect_check_mismatch(fx_text_crc32(), FX_TEXT_CRC32_CHECK)
	expect_check_mismatch(fx_text_crc64(), FX_TEXT_CRC64_CHECK)
	expect_check_mismatch(fx_text_sha256(), FX_TEXT_SHA256_CHECK + 31)
	drop_sha256_cache()


void test_all_byte_values():
	char* want = cast(char*, malloc(256))
	for i in range(256): want[i] = i
	expect_output(fx_bytes256(), MODE_XZ, want, 256)
	free(want)


void test_repetitive_multi_chunk_presets():
	# 4.2 MB: three LZMA2 chunks (the 2 MiB uncompressed chunk limit)
	char* want = repeat_text(c"W language xz ", 300000)
	expect_output(fx_rep_p0(), MODE_XZ, want, 4200000)
	expect_output(fx_rep_p9(), MODE_AUTO, want, 4200000)
	char* digest = cast(char*, malloc(32))
	sha256(want, 4200000, digest)
	char* hexd = hex_encode(digest, 32)
	assert_strings_equal(c"fb1f20608841abb666afd44735b958aee4691ba61ff5c7377a22bd14bb8300ee", hexd)
	free(hexd)
	free(digest)
	free(want)
	drop_sha256_cache()


void test_presets_on_prose():
	char* prose = repeat_text(c"It was the best of times, it was the worst of times, it was the age of wisdom, it was the age of foolishness, ", 8)
	int plen = strlen(prose)
	char* want = cast(char*, malloc(plen + 256))
	mem_copy[char](want, prose, plen)
	for i in range(256): want[plen + i] = i
	expect_output(fx_prose_p0(), MODE_XZ, want, plen + 256)
	expect_output(fx_prose_p9(), MODE_XZ, want, plen + 256)
	free(want)
	free(prose)


void test_uncompressed_chunk():
	char* want = cast(char*, malloc(100))
	lcg_fill(want, 100, 12345)
	expect_output(fx_random(), MODE_XZ, want, 100)
	free(want)


void test_multiple_blocks_with_sizes():
	int total = 300 + 300000 + 300
	char* want = cast(char*, malloc(total))
	lcg_fill(want, 300, 12345)
	for i in range(300000): want[300 + i] = 97 + i % 3
	lcg_fill(&want[300300], 300, 7)
	expect_output(fx_multiblock(), MODE_XZ, want, total)
	free(want)


void test_crafted_chunks_without_dict_reset():
	char* one = c"abcdefhello world hello world hello!"
	expect_output(fx_crafted(), MODE_XZ, one, strlen(one))
	char* two = c"abcdefhello world hello world hello!xyzzy"
	expect_output(fx_crafted2(), MODE_XZ, two, strlen(two))


void test_delta_filter():
	char* want = cast(char*, malloc(1000))
	for i in range(1000): want[i] = (i * 3 + i / 7) & 255
	expect_output(fx_delta(), MODE_XZ, want, 1000)
	free(want)


void test_unsupported_filter():
	expect_error(fx_x86(), MODE_XZ, XZ_ERR_OPTIONS)


void test_lzma_alone():
	char* t = text_plain()
	expect_output(fx_alone(), MODE_ALONE, t, strlen(t))
	expect_output(fx_alone(), MODE_AUTO, t, strlen(t))
	expect_output(fx_alone_known(), MODE_ALONE, t, strlen(t))
	char* rep = repeat_text(c"W language xz ", 300000)
	expect_output(fx_alone_rep(), MODE_AUTO, rep, 50000)
	free(rep)
	# formats are not interchangeable
	expect_error(fx_alone(), MODE_XZ, XZ_ERR_FORMAT)
	expect_error(fx_text_crc64(), MODE_ALONE, XZ_ERR_FORMAT)


void test_concatenated_streams():
	expect_output(fx_cat(), MODE_XZ, c"hello world", 11)
	expect_output(fx_cat_pad(), MODE_XZ, c"hello world", 11)
	expect_error(fx_cat_badpad(), MODE_XZ, XZ_ERR_DATA)
	expect_output(fx_cat_alone(), MODE_ALONE, c"onetwo", 6)
	expect_output(fx_cat_alone(), MODE_AUTO, c"onetwo", 6)
	expect_output(fx_cat_mixed(), MODE_AUTO, c"hello two", 9)
	# Python parity: trailing data that is not a stream is dropped ...
	expect_output(fx_cat_garbage(), MODE_XZ, c"hello ", 6)
	expect_output(fx_cat_mixed(), MODE_XZ, c"hello ", 6)
	# ... but a truncated further stream fails
	expect_error(fx_cat_trunc(), MODE_XZ, XZ_ERR_TRUNCATED)


void test_bad_magic_and_empty_input():
	int n = -1
	int err = -1
	char* out = xz_decompress(c"", 0, 0, &n, &err)
	assert_equal(0, cast(int, out))
	assert_equal(XZ_ERR_TRUNCATED, err)
	out = xz_decompress(c"hello world, not xz", 19, 0, &n, &err)
	assert_equal(0, cast(int, out))
	assert_equal(XZ_ERR_FORMAT, err)
	out = lzma_decompress(c"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff", 14, 0, &n, &err)
	assert_equal(0, cast(int, out))
	assert_equal(XZ_ERR_FORMAT, err)
	assert_strings_equal(c"xz: input format not recognized", xz_error_string(XZ_ERR_FORMAT))


void test_every_truncation_fails():
	int n = 0
	char* data = hex_decode(fx_text_crc64(), strlen(fx_text_crc64()), &n)
	for i in range(n):
		int len = -1
		int err = -1
		char* out = xz_decompress(data, i, 0, &len, &err)
		assert_equal(0, cast(int, out))
		assert_equal(XZ_ERR_TRUNCATED, err)
	free(data)
	# .lzma with an unknown size needs its end marker
	data = hex_decode(fx_alone(), strlen(fx_alone()), &n)
	for i in range(n):
		int len = -1
		int err = -1
		char* out = lzma_alone_decompress(data, i, 0, &len, &err)
		assert_equal(0, cast(int, out))
		assert1(err != XZ_OK)
	free(data)


void test_every_byte_flip_fails():
	int n = 0
	char* data = hex_decode(fx_text_crc64(), strlen(fx_text_crc64()), &n)
	for i in range(n):
		data[i] = data[i] ^ 65
		int len = -1
		int err = -1
		char* out = xz_decompress(data, n, 0, &len, &err)
		if (out != 0): println(itoa(i))
		assert_equal(0, cast(int, out))
		assert1(err != XZ_OK)
		data[i] = data[i] ^ 65
	free(data)


# No check to catch corruption in a .lzma stream: decoding must still
# stay in bounds, whatever it returns.
void test_alone_corruption_stays_in_bounds():
	int n = 0
	char* data = hex_decode(fx_alone_rep(), strlen(fx_alone_rep()), &n)
	for i in range(13, n):
		for bit in range(8):
			data[i] = data[i] ^ (1 << bit)
			int len = -1
			int err = -1
			char* out = lzma_alone_decompress(data, n, 100000, &len, &err)
			if (out != 0):
				assert1(len <= 100000)
				free(out)
			else:
				assert1(err != XZ_OK)
			data[i] = data[i] ^ (1 << bit)
	free(data)


void test_max_output_cap():
	int n = -1
	int err = -1
	char* out = decode_hex(fx_rep_p0(), MODE_XZ, 1000, &n, &err)
	assert_equal(0, cast(int, out))
	assert_equal(XZ_ERR_TOO_LARGE, err)
	out = decode_hex(fx_alone_rep(), MODE_ALONE, 1000, &n, &err)
	assert_equal(0, cast(int, out))
	assert_equal(XZ_ERR_TOO_LARGE, err)
	# exactly enough is fine
	out = decode_hex(fx_alone_rep(), MODE_ALONE, 50000, &n, &err)
	assert1(out != 0)
	assert_equal(50000, n)
	free(out)
	out = decode_hex(fx_multiblock(), MODE_XZ, 300600, &n, &err)
	assert1(out != 0)
	free(out)
	out = decode_hex(fx_multiblock(), MODE_XZ, 300599, &n, &err)
	assert_equal(0, cast(int, out))
	assert_equal(XZ_ERR_TOO_LARGE, err)


int fuzz_seed


int fuzz_next(int n):
	fuzz_seed = (fuzz_seed * 1103515245 + 12345) & 2147483647
	return (fuzz_seed >> 8) % n


# Deterministic random corruption (1-4 bytes replaced, sometimes also
# truncated) of LZMA2 data: the decoder must stay in bounds and either
# fail or return a result.
void test_random_corruption_stays_in_bounds():
	fuzz_seed = 99
	int n = 0
	char* data = hex_decode(fx_rep_p9(), strlen(fx_rep_p9()), &n)
	char* copy = cast(char*, malloc(n))
	for it in range(400):
		mem_copy[char](copy, data, n)
		int flips = 1 + fuzz_next(4)
		for k in range(flips):
			int i = fuzz_next(n)
			copy[i] = copy[i] ^ (1 + fuzz_next(255))
		int len = n
		if (fuzz_next(4) == 0): len = fuzz_next(n)
		int out_len = 0
		int err = 0
		char* out = xz_decompress(copy, len, 10000000, &out_len, &err)
		if (out != 0): free(out)
		else: assert1(err != XZ_OK)
	free(copy)
	free(data)


# Regression (found by the fuzz loop above at a later seed): this
# corruption decodes a match distance >= 2^31, negative in a 32-bit
# int, which a matched literal then read out of bounds on x86.
void test_huge_distance_rejected():
	int n = 0
	char* data = hex_decode(fx_rep_p9(), strlen(fx_rep_p9()), &n)
	data[398] = data[398] ^ 95
	data[279] = data[279] ^ 144
	int out_len = -1
	int err = -1
	char* out = xz_decompress(data, n, 0, &out_len, &err)
	assert_equal(0, cast(int, out))
	assert_equal(XZ_ERR_DATA, err)
	free(data)
