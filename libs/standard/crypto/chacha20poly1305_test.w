# wbuild: x64
/*
Tests for libs/standard/crypto/chacha20poly1305.w: RFC 8439 Poly1305 key
generation (section 2.6.2, appendix A.4), the AEAD seal vector (section
2.8.2), the AEAD decryption vector (appendix A.5), fail-closed negative
cases (tampered ciphertext / AAD / tag, truncated ciphertext), and the
checked-in Wycheproof subset. Part of issue #155 phase 4 (#194).
*/
import lib.lib
import lib.memory
import lib.testing
import libs.standard.crypto.chacha20poly1305
import libs.standard.crypto.chacha20poly1305_wycheproof_fixture


# --- test-local hex helpers (vectors are embedded as lowercase hex) ---


int cp_nibble(int ch):
	if (ch >= '0' && ch <= '9'):
		return ch - '0'
	return ch - 'a' + 10


# Decode a lowercase hex string into malloc'd bytes (length = strlen/2).
char* cp_decode(char* hex):
	int n = strlen(hex) / 2
	char* out = malloc(n + 1)
	int i = 0
	while (i < n):
		out[i] = cp_nibble(hex[i * 2] & 255) * 16 + cp_nibble(hex[i * 2 + 1] & 255)
		i = i + 1
	out[n] = 0
	return out


# Encode bytes as a lowercase hex string (malloc'd, NUL-terminated).
char* cp_hex(char* data, int len):
	char* digits = c"0123456789abcdef"
	char* out = malloc(len * 2 + 1)
	int i = 0
	while (i < len):
		int b = data[i] & 255
		out[i * 2] = digits[(b >> 4) & 15]
		out[i * 2 + 1] = digits[b & 15]
		i = i + 1
	out[len * 2] = 0
	return out


# poly1305_key_gen(key, nonce) must yield the 32-byte one-time key.
void cp_check_keygen(char* key_hex, char* nonce_hex, char* want_hex):
	char* key = cp_decode(key_hex)
	char* nonce = cp_decode(nonce_hex)
	char* out = malloc(32)
	poly1305_key_gen(key, nonce, out)
	char* got = cp_hex(out, 32)
	assert_strings_equal(want_hex, got)
	free(got)
	free(out)
	free(nonce)
	free(key)


# RFC 8439 section 2.6.2 and appendix A.4: Poly1305 key generation.
void test_rfc8439_poly1305_key_gen():
	cp_check_keygen(c"808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f", c"000000000001020304050607", c"8ad5a08b905f81cc815040274ab29471a833b637e3fd0da508dbb8e2fdd1a646")
	cp_check_keygen(c"0000000000000000000000000000000000000000000000000000000000000000", c"000000000000000000000000", c"76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7")
	cp_check_keygen(c"0000000000000000000000000000000000000000000000000000000000000001", c"000000000000000000000002", c"ecfa254f845f647473d3cb140da9e87606cb33066c447b87bc2666dde3fbb739")
	cp_check_keygen(c"1c9240a5eb55d38af333888604f6b5f0473917c1402b80099dca5cbc207075c0", c"000000000000000000000002", c"965e3bc6f9ec7ed9560808f4d229f94b137ff275ca9b3fcbdd59deaad23310ae")


# RFC 8439 section 2.8.2: seal the "sunscreen" plaintext and check both
# ciphertext and tag, then open our own output.
void test_rfc8439_seal_282():
	char* key = cp_decode(c"808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
	char* nonce = cp_decode(c"070000004041424344454647")
	char* aad = cp_decode(c"50515253c0c1c2c3c4c5c6c7")
	char* pt = cp_decode(c"4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73637265656e20776f756c642062652069742e")
	int aad_len = strlen(c"50515253c0c1c2c3c4c5c6c7") / 2
	int n = strlen(c"4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73637265656e20776f756c642062652069742e") / 2
	char* ct = malloc(n + 1)
	char* tag = malloc(16)
	chacha20poly1305_seal(key, nonce, aad, aad_len, pt, n, ct, tag)
	char* got = cp_hex(ct, n)
	assert_strings_equal(c"d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b6116", got)
	free(got)
	got = cp_hex(tag, 16)
	assert_strings_equal(c"1ae10b594f09e26a7e902ecbd0600691", got)
	free(got)
	char* back = malloc(n + 1)
	assert_equal(1, chacha20poly1305_open(key, nonce, aad, aad_len, ct, n, tag, back))
	got = cp_hex(back, n)
	assert_strings_equal(c"4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73637265656e20776f756c642062652069742e", got)
	free(got)
	free(back)
	free(tag)
	free(ct)
	free(pt)
	free(aad)
	free(nonce)
	free(key)


# RFC 8439 appendix A.5: open a received ciphertext with the given tag.
void test_rfc8439_open_a5():
	char* key = cp_decode(c"1c9240a5eb55d38af333888604f6b5f0473917c1402b80099dca5cbc207075c0")
	char* nonce = cp_decode(c"000000000102030405060708")
	char* aad = cp_decode(c"f33388860000000000004e91")
	char* ct = cp_decode(c"64a0861575861af460f062c79be643bd5e805cfd345cf389f108670ac76c8cb24c6cfc18755d43eea09ee94e382d26b0bdb7b73c321b0100d4f03b7f355894cf332f830e710b97ce98c8a84abd0b948114ad176e008d33bd60f982b1ff37c8559797a06ef4f0ef61c186324e2b3506383606907b6a7c02b0f9f6157b53c867e4b9166c767b804d46a59b5216cde7a4e99040c5a40433225ee282a1b0a06c523eaf4534d7f83fa1155b0047718cbc546a0d072b04b3564eea1b422273f548271a0bb2316053fa76991955ebd63159434ecebb4e466dae5a1073a6727627097a1049e617d91d361094fa68f0ff77987130305beaba2eda04df997b714d6c6f2c29a6ad5cb4022b02709b")
	char* tag = cp_decode(c"eead9d67890cbb22392336fea1851f38")
	int aad_len = strlen(c"f33388860000000000004e91") / 2
	int n = strlen(c"64a0861575861af460f062c79be643bd5e805cfd345cf389f108670ac76c8cb24c6cfc18755d43eea09ee94e382d26b0bdb7b73c321b0100d4f03b7f355894cf332f830e710b97ce98c8a84abd0b948114ad176e008d33bd60f982b1ff37c8559797a06ef4f0ef61c186324e2b3506383606907b6a7c02b0f9f6157b53c867e4b9166c767b804d46a59b5216cde7a4e99040c5a40433225ee282a1b0a06c523eaf4534d7f83fa1155b0047718cbc546a0d072b04b3564eea1b422273f548271a0bb2316053fa76991955ebd63159434ecebb4e466dae5a1073a6727627097a1049e617d91d361094fa68f0ff77987130305beaba2eda04df997b714d6c6f2c29a6ad5cb4022b02709b") / 2
	char* pt = malloc(n + 1)
	assert_equal(1, chacha20poly1305_open(key, nonce, aad, aad_len, ct, n, tag, pt))
	char* got = cp_hex(pt, n)
	assert_strings_equal(c"496e7465726e65742d4472616674732061726520647261667420646f63756d656e74732076616c696420666f722061206d6178696d756d206f6620736978206d6f6e74687320616e64206d617920626520757064617465642c207265706c616365642c206f72206f62736f6c65746564206279206f7468657220646f63756d656e747320617420616e792074696d652e20497420697320696e617070726f70726961746520746f2075736520496e7465726e65742d447261667473206173207265666572656e6365206d6174657269616c206f7220746f2063697465207468656d206f74686572207468616e206173202fe2809c776f726b20696e2070726f67726573732e2fe2809d", got)
	free(got)
	free(pt)
	free(tag)
	free(ct)
	free(aad)
	free(nonce)
	free(key)


# Fill a buffer with a sentinel, run an open() that must fail, and check
# both the return code and that not one plaintext byte was released.
void cp_check_open_fails(char* key, char* nonce, char* aad, int aad_len, char* ct, int n, char* tag):
	char* pt = malloc(n + 1)
	int i = 0
	while (i < n):
		pt[i] = 0x5a
		i = i + 1
	assert_equal(0, chacha20poly1305_open(key, nonce, aad, aad_len, ct, n, tag, pt))
	i = 0
	while (i < n):
		assert_equal(0x5a, pt[i] & 255)
		i = i + 1
	free(pt)


# Negative cases built from the valid section 2.8.2 message: flipping any
# bit of ciphertext, AAD, or tag must fail closed, as must truncation.
void test_open_fail_closed():
	char* key = cp_decode(c"808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
	char* nonce = cp_decode(c"070000004041424344454647")
	char* aad = cp_decode(c"50515253c0c1c2c3c4c5c6c7")
	char* ct = cp_decode(c"d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b6116")
	char* tag = cp_decode(c"1ae10b594f09e26a7e902ecbd0600691")
	int aad_len = strlen(c"50515253c0c1c2c3c4c5c6c7") / 2
	int n = strlen(c"d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b6116") / 2

	# tampered ciphertext: first byte, last byte
	ct[0] = ct[0] ^ 1
	cp_check_open_fails(key, nonce, aad, aad_len, ct, n, tag)
	ct[0] = ct[0] ^ 1
	ct[n - 1] = ct[n - 1] ^ 128
	cp_check_open_fails(key, nonce, aad, aad_len, ct, n, tag)
	ct[n - 1] = ct[n - 1] ^ 128

	# tampered AAD
	aad[0] = aad[0] ^ 1
	cp_check_open_fails(key, nonce, aad, aad_len, ct, n, tag)
	aad[0] = aad[0] ^ 1

	# tampered tag: each byte flipped in turn
	int i = 0
	while (i < 16):
		tag[i] = tag[i] ^ 255
		cp_check_open_fails(key, nonce, aad, aad_len, ct, n, tag)
		tag[i] = tag[i] ^ 255
		i = i + 1

	# truncated ciphertext (tag no longer matches the shorter data)
	cp_check_open_fails(key, nonce, aad, aad_len, ct, n - 1, tag)
	cp_check_open_fails(key, nonce, aad, aad_len, ct, 0, tag)

	# untampered input still opens (the flips above were reverted)
	char* pt = malloc(n + 1)
	assert_equal(1, chacha20poly1305_open(key, nonce, aad, aad_len, ct, n, tag, pt))
	free(pt)
	free(tag)
	free(ct)
	free(aad)
	free(nonce)
	free(key)


# Wycheproof subset: valid vectors must seal to the exact ciphertext+tag
# and open back to the message; invalid (forged-tag) vectors must fail
# closed without releasing plaintext.
void test_wycheproof_vectors():
	list[wp_aead*] vectors = wp_aead_vectors()
	int checked = 0
	for wp_aead* v in vectors:
		char* key = cp_decode(v.key)
		char* nonce = cp_decode(v.nonce)
		char* aad = cp_decode(v.aad)
		char* msg = cp_decode(v.msg)
		char* ct = cp_decode(v.ct)
		char* tag = cp_decode(v.tag)
		int aad_len = strlen(v.aad) / 2
		int msg_len = strlen(v.msg) / 2
		if (v.valid == 1):
			char* got_ct = malloc(msg_len + 1)
			char* got_tag = malloc(16)
			chacha20poly1305_seal(key, nonce, aad, aad_len, msg, msg_len, got_ct, got_tag)
			char* got = cp_hex(got_ct, msg_len)
			assert_strings_equal(v.ct, got)
			free(got)
			got = cp_hex(got_tag, 16)
			assert_strings_equal(v.tag, got)
			free(got)
			free(got_tag)
			free(got_ct)
			char* back = malloc(msg_len + 1)
			assert_equal(1, chacha20poly1305_open(key, nonce, aad, aad_len, ct, msg_len, tag, back))
			got = cp_hex(back, msg_len)
			assert_strings_equal(v.msg, got)
			free(got)
			free(back)
		else:
			cp_check_open_fails(key, nonce, aad, aad_len, ct, msg_len, tag)
		free(tag)
		free(ct)
		free(msg)
		free(aad)
		free(nonce)
		free(key)
		checked = checked + 1
	assert_equal(51, checked)
