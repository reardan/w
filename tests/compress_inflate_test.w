# wbuild: x64
/*
libs/extras/compress/inflate.w conformance tests: hand-crafted DEFLATE
fixtures covering all three block types (docs/projects/compress.md §8)
plus every INFLATE_ERR_* error path.

Every fixture below was constructed and cross-checked against an
independent, from-scratch Python reference bit-reader/canonical-Huffman
decoder (not derived from this file's implementation, not committed to
this repo) before being embedded here, following the design doc's own
suggestion to check block-level semantics against independent prior art
(§2.2's puff.c reference) rather than only against this package's own
code. The fixed-Huffman and dynamic-Huffman byte sequences that are not
trivial to hand-verify bit-by-bit (docs/projects/compress.md §8: "you can
compute expected bytes by hand") were produced by real python3 zlib
(zlib.compressobj(wbits=-15, strategy=zlib.Z_FIXED or
Z_DEFAULT_STRATEGY)) -- a genuine external producer, exactly the "gateway
to interop" conformance bar §3 calls for -- and round-tripped through
zlib.decompress before being embedded; the stored-block and malformed
fixtures are simple enough to derive directly from RFC 1951's field
layout. See tests/compress_corpus_test.w for broader round-trip coverage
via tests/compress/deflate_corpus.txt.
*/
import lib.testing
import lib.result
import libs.extras.compress.inflate


void ct_expect_ok(char* label, char* data, int len, char* want, int want_len):
	wresult[inflate_result*]* r = inflate(data, len, 0)
	if (result_is_error[inflate_result*](r)):
		print2(label)
		print2(c": expected ok, got error ")
		println2(inflate_error_string(result_code[inflate_result*](r)))
		result_free[inflate_result*](r)
		exit(1)
	inflate_result* o = result_value[inflate_result*](r)
	result_free[inflate_result*](r)
	if (o.length != want_len):
		print2(label)
		print2(c": length mismatch, want ")
		print2(itoa(want_len))
		print2(c" got ")
		println2(itoa(o.length))
		exit(1)
	int i = 0
	while (i < want_len):
		if ((o.data[i] & 255) != (want[i] & 255)):
			print2(label)
			print2(c": byte mismatch at offset ")
			println2(itoa(i))
			exit(1)
		i = i + 1
	inflate_result_free(o)


void ct_expect_err(char* label, char* data, int len, int max_output, int want_code):
	wresult[inflate_result*]* r = inflate(data, len, max_output)
	if (result_is_ok[inflate_result*](r)):
		print2(label)
		println2(c": expected error, got ok")
		inflate_result_free(result_value[inflate_result*](r))
		result_free[inflate_result*](r)
		exit(1)
	int code = result_code[inflate_result*](r)
	result_free[inflate_result*](r)
	if (code != want_code):
		print2(label)
		print2(c": wrong error code, want ")
		print2(itoa(want_code))
		print2(c" got ")
		println2(itoa(code))
		exit(1)


/* Stored blocks (BTYPE=00) */


void test_inflate_stored_empty():
	# BFINAL=1,BTYPE=00; LEN=0, NLEN=~0.
	ct_expect_ok(c"empty stored", c"\x01\x00\x00\xff\xff", 5, c"", 0)


void test_inflate_stored_one_byte():
	ct_expect_ok(c"one-byte stored", c"\x01\x01\x00\xfe\xff\x41", 6, c"A", 1)


void test_inflate_stored_chained_blocks():
	# BFINAL=0 block ("foo") followed by a BFINAL=1 block ("bar"): tests
	# that a non-final stored block correctly continues into the next
	# block header instead of stopping.
	ct_expect_ok(c"chained stored", c"\x00\x03\x00\xfc\xff\x66\x6f\x6f\x01\x03\x00\xfc\xff\x62\x61\x72", 16, c"foobar", 6)


void test_inflate_stored_bad_nlen():
	# LEN=5, NLEN=0 (not ~5) -- the self-check must reject this before
	# ever looking at payload bytes.
	ct_expect_err(c"bad stored NLEN", c"\x01\x05\x00\x00\x00", 5, 0, INFLATE_ERR_BAD_STORED_LEN())


void test_inflate_stored_truncated():
	# Declares LEN=10 but only 3 payload bytes follow.
	ct_expect_err(c"truncated stored", c"\x01\x0a\x00\xf5\xff\x41\x42\x43", 8, 0, INFLATE_ERR_TRUNCATED())


/* Fixed Huffman blocks (BTYPE=01) */


void test_inflate_fixed_literal_run():
	# python3 zlib, Z_FIXED strategy: "hello world hello world!"
	ct_expect_ok(c"fixed literal run", c"\xcb\x48\xcd\xc9\xc9\x57\x28\xcf\x2f\xca\x49\x51\xc8\x40\xb0\x15\x01", 17, c"hello world hello world!", 24)


void test_inflate_fixed_backreference():
	# Hand-packed: literal 'a' then a length/distance back-reference
	# (length 7, distance 1) -> "aaaaaaaa", exercising the length/
	# distance extra-bit path and a self-overlapping copy.
	ct_expect_ok(c"fixed backreference", c"\x4b\x84\x02\x00", 4, c"aaaaaaaa", 8)


void test_inflate_fixed_single_literal():
	ct_expect_ok(c"fixed single literal", c"\x73\x04\x00", 3, c"A", 1)


void test_inflate_fixed_invalid_distance_symbol():
	# A length symbol followed by distance-alphabet symbol 30: assigned a
	# code by the complete fixed table but never valid (RFC 1951 §3.2.5).
	ct_expect_err(c"invalid distance symbol", c"\x03\x3e", 2, 0, INFLATE_ERR_BAD_HUFFMAN())


void test_inflate_fixed_backreference_before_output_start():
	# A length/distance pair as the very first symbols: distance 1 with
	# zero bytes of output produced so far.
	ct_expect_err(c"backref before output start", c"\x03\x02", 2, 0, INFLATE_ERR_BAD_DISTANCE())


void test_inflate_reserved_btype():
	ct_expect_err(c"reserved btype", c"\x07", 1, 0, INFLATE_ERR_BAD_BTYPE())


void test_inflate_truncated_fixed_huffman():
	ct_expect_err(c"truncated fixed huffman", c"\xcb\x48\xcd\xc9\xc9", 5, 0, INFLATE_ERR_TRUNCATED())


void test_inflate_max_output_cap():
	ct_expect_err(c"max_output exceeded", c"\xcb\x48\xcd\xc9\xc9\x57\x28\xcf\x2f\xca\x49\x51\xc8\x40\xb0\x15\x01", 17, 5, INFLATE_ERR_TOO_LARGE())


/* Dynamic Huffman blocks (BTYPE=10) */


void test_inflate_dynamic_small_alphabet():
	# python3 zlib, default strategy, chosen to be just large enough to
	# make zlib prefer a dynamic Huffman header over a fixed one:
	# "jumps fox length brown literal gzip quick the". Pure literals, no
	# back-reference (HLIT is the minimum 257 -- see the sibling test
	# below for a dynamic block that does use one).
	ct_expect_ok(c"dynamic small alphabet", c"\x05\xc1\x8b\x0d\x00\x10\x0c\x05\xc0\x55\xde\x6a\x48\x51\xea\x5f\x21\xa6\x77\x97\x76\xe9\x0b\xbe\x5d\x08\xd5\xa0\x11\x76\xb6\x53\x21\xac\x34\x8d\x20\x3c\xee\x18\x9b\x5d\x86\x46\xfa", 45, c"jumps fox length brown literal gzip quick the", 45)


void test_inflate_dynamic_with_backreference():
	# Regression test: a dynamic block whose distance table has exactly
	# two used symbols that are NOT adjacent (distance-alphabet symbols 0
	# and 6, both length 1) caught a real bug during development --
	# `wh_build(c, dist_huff, lengths + hlit, hdist)` added `hlit` BYTES
	# to the `int*` pointer instead of `hlit` ints (pointer arithmetic on
	# a typed pointer is a raw byte offset in this language, matching
	# lib/sha256.w's own char*-plus-manual-stride convention -- see
	# inf_dynamic_block's comment), so the distance table silently built
	# from the wrong slice of the lengths array and any dynamic block
	# using a real back-reference decoded garbage or failed with
	# INFLATE_ERR_BAD_HUFFMAN. python3 zlib, default strategy:
	# "length brown lazy w over compiler literal distance huffman deflate"
	# (HLIT=258 here, i.e. one length code beyond the pure-literal
	# minimum of 257 -- confirmed by an independent Python reference
	# decoder during debugging, not just this package's own code).
	ct_expect_ok(c"dynamic with backreference", c"\x0d\xc6\xd1\x0d\x80\x30\x08\x05\xc0\x55\xde\x6a\xd8\x82\x25\xa1\x60\x10\x6d\x74\x7a\xbd\xaf\x33\xf6\xbd\x06\xb6\x8c\xe5\x30\x7a\x1f\x2c\xc4\xcd\x89\x16\xf3\x50\xfb\x63\x5a\x9c\x64\xe8\x7a\x16\x79\x63\x8c\x4b\x64\x92\xa3\xb3\x18\x15\x7f", 59, c"length brown lazy w over compiler literal distance huffman deflate", 66)
