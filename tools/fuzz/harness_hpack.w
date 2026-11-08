# wbuild: target=wfuzz_hpack_smoke tag=tests dep=wfuzz data=tools/fuzz/seeds/hpack/
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_hpack.w -o bin/wfuzz_hpack_harness"
# wbuild: step="rm -rf bin/wfuzz_hpack_smoke"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_hpack_harness --bytes --ext .hpack --corpus tools/fuzz/seeds/hpack --out bin/wfuzz_hpack_smoke --cases 0 --fail-on-findings" expect_stdout="crashes: 0" timeout=300000
# wbuild: target=wfuzz_hpack tag=fuzz_campaign dep=wfuzz
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_hpack.w -o bin/wfuzz_hpack_harness"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_hpack_harness --bytes --ext .hpack --corpus tools/fuzz/seeds/hpack --out bin/wfuzz_hpack" timeout=3600000
# Fuzz harness for libs/standard/web/hpack.w (issue #909). An input is
# one HPACK decoding context: its first byte picks the dynamic table
# size ((byte + 1) * 16, so the RFC 7541 Appendix C response vectors'
# 256 is byte 15 and 4096 is byte 255), then come header blocks, each
# prefixed by its length in one byte (a length running past the end
# takes the rest). The blocks go through one hpack_decoder in order, so
# dynamic-table state carries across them as on a connection; decoding
# stops at the first rejected block. Seeds are the Appendix C sequences
# from hpack_test.w plus its size-update and error cases.
#
# Invariants checked on every accepted block:
#   - each field has a nonempty name, no NUL/CR/LF in name or value,
#     both NUL-terminated at their lengths;
#   - the list respects max_headers and max_list_size (name + value +
#     32 per field), and the dynamic table's size never exceeds its
#     max_size, which never exceeds the SETTINGS ceiling;
#   - re-encoding the fields (with a persistent encoder, Huffman on or
#     off by block parity) and decoding that with a persistent paired
#     decoder gives the same fields, sensitivity included;
#   - every decoded value survives a Huffman encode/decode round trip.
# The whole input is also fed to hpack_huffman_decode: when it decodes,
# re-encoding must give back exactly the input bytes (the code is
# canonical and padding must be EOS bits), and to hpack_decode_int at
# every prefix width, whose value must re-encode and re-decode intact.
import tools.fuzz.harness
import libs.standard.web.hpack


void fh_hpack_check_table(hpack_decoder* d):
	hpack_table* t = d.table
	fh_check(t.size <= t.max_size, c"dynamic table larger than its max_size")
	fh_check(t.max_size <= d.settings_max, c"dynamic table max_size above the SETTINGS ceiling")
	int total = 0
	for i in range(t.entries.length):
		hpack_header* h = t.entries[i]
		total = total + h.name_len + h.value_len + 32
	fh_check(total == t.size, c"dynamic table size does not match its entries")


void fh_hpack_check_fields(hpack_decoder* d, list[hpack_header*] l):
	fh_check(l.length <= d.max_headers, c"more fields than max_headers")
	int size = 0
	for i in range(l.length):
		hpack_header* h = l[i]
		fh_check(h.name_len > 0, c"empty header name accepted")
		fh_check((h.name[h.name_len] == 0) && (h.value[h.value_len] == 0), c"field not NUL-terminated at its length")
		for k in range(h.name_len):
			int c = h.name[k] & 255
			fh_check((c != 0) && (c != 10) && (c != 13), c"NUL/CR/LF in a header name")
		for k in range(h.value_len):
			int c = h.value[k] & 255
			fh_check((c != 0) && (c != 10) && (c != 13), c"NUL/CR/LF in a header value")
		size = size + h.name_len + h.value_len + 32
	fh_check(size <= d.max_list_size, c"header list larger than max_list_size")


void fh_hpack_huffman_value(hpack_header* h):
	string_builder* sb = string_new()
	hpack_huffman_encode(h.value, h.value_len, sb)
	int back_len = 0
	char* back = hpack_huffman_decode(sb.data, sb.length, h.value_len + 1, &back_len)
	fh_check(back != 0, c"Huffman encoding of a value does not decode")
	fh_check((back_len == h.value_len) && fh_bytes_equal(back, h.value, back_len), c"Huffman round trip changed a value")
	free(back)
	string_free(sb)


void fh_hpack_round_trip(hpack_encoder* e, hpack_decoder* d2, list[hpack_header*] l, int huffman):
	e.huffman = huffman
	string_builder* sb = string_new()
	hpack_encode(e, l, sb)
	list[hpack_header*] back = hpack_headers_new()
	int rc = hpack_decode(d2, sb.data, sb.length, back)
	fh_check(rc == 0, c"hpack_encode output does not decode")
	fh_check(back.length == l.length, c"round trip changed the field count")
	for i in range(l.length):
		hpack_header* a = l[i]
		hpack_header* b = back[i]
		fh_check(hpack_bytes_equal(a.name, a.name_len, b.name, b.name_len), c"round trip changed a name")
		fh_check(hpack_bytes_equal(a.value, a.value_len, b.value, b.value_len), c"round trip changed a value")
		fh_check(a.sensitive == b.sensitive, c"round trip changed never-indexed")
	hpack_headers_free(back)
	string_free(sb)


int fh_hpack_blocks(char* data, int length):
	if (length < 1): return 1
	int table_size = ((data[0] & 255) + 1) * 16
	hpack_decoder* d = hpack_decoder_new(table_size)
	hpack_encoder* e = hpack_encoder_new(table_size)
	hpack_decoder* d2 = hpack_decoder_new(table_size)
	int pos = 1
	int accepted = 0
	int index = 0
	int failed = 0
	while ((pos < length) && (failed == 0)):
		int n = data[pos] & 255
		pos = pos + 1
		if (n > length - pos): n = length - pos
		list[hpack_header*] l = hpack_headers_new()
		if (hpack_decode(d, data + pos, n, l) == 0):
			accepted = accepted + 1
			fh_hpack_check_fields(d, l)
			fh_hpack_check_table(d)
			fh_hpack_round_trip(e, d2, l, (index & 1) == 0)
			fh_hpack_check_table(d2)
			for i in range(l.length): fh_hpack_huffman_value(l[i])
		else: failed = 1
		hpack_headers_free(l)
		pos = pos + n
		index = index + 1
	hpack_encoder_free(e)
	hpack_decoder_free(d2)
	hpack_decoder_free(d)
	return accepted


void fh_hpack_huffman_raw(char* data, int length):
	int out_len = 0
	char* plain = hpack_huffman_decode(data, length, 1 << 20, &out_len)
	if (plain == 0): return
	fh_check(plain[out_len] == 0, c"Huffman output not NUL-terminated")
	string_builder* sb = string_new()
	hpack_huffman_encode(plain, out_len, sb)
	fh_check((sb.length == length) && fh_bytes_equal(sb.data, data, length), c"Huffman decode then encode changed the bytes")
	string_free(sb)
	free(plain)


void fh_hpack_ints(char* data, int length):
	for prefix in range(1, 9):
		int pos = 0
		int value = 0
		if (hpack_decode_int(data, length, &pos, prefix, &value)):
			fh_check((value >= 0) && (pos >= 1) && (pos <= length), c"hpack_decode_int out of range")
			string_builder* sb = string_new()
			hpack_encode_int(sb, 0, prefix, value)
			int pos2 = 0
			int value2 = 0
			fh_check(hpack_decode_int(sb.data, sb.length, &pos2, prefix, &value2) && (value2 == value) && (pos2 == sb.length), c"hpack integer round trip failed")
			fh_check(sb.length <= pos, c"hpack_encode_int not minimal")
			string_free(sb)


int main(int argc, int argv):
	int length = 0
	char* data = fh_input(argc, argv, &length)
	fh_hpack_huffman_raw(data, length)
	fh_hpack_ints(data, length)
	if (fh_hpack_blocks(data, length) > 0): return 0
	return 1
