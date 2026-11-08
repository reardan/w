# wbuild: target=wfuzz_protobuf_smoke tag=tests dep=wfuzz data=tools/fuzz/seeds/protobuf/
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_protobuf.w -o bin/wfuzz_protobuf_harness"
# wbuild: step="rm -rf bin/wfuzz_protobuf_smoke"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_protobuf_harness --bytes --ext .pb --corpus tools/fuzz/seeds/protobuf --out bin/wfuzz_protobuf_smoke --cases 0 --fail-on-findings" expect_stdout="crashes: 0" timeout=300000
# wbuild: target=wfuzz_protobuf tag=fuzz_campaign dep=wfuzz
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_protobuf.w -o bin/wfuzz_protobuf_harness"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_protobuf_harness --bytes --ext .pb --corpus tools/fuzz/seeds/protobuf --out bin/wfuzz_protobuf" timeout=3600000
# Fuzz harness for libs/extras/protobuf's wire-format decoding (issue
# #909). Every input is decoded with three descriptors:
#   - fzp_node, a compiler-emitted descriptor (the `message` keyword)
#     covering every 32-bit-target kind: int32, uint32, sint32, bool,
#     fixed32, sfixed32, float, enum, string, bytes, a recursive
#     submessage (so nesting reaches PB_MAX_DECODE_DEPTH), and repeated
#     scalars (packed and unpacked), strings, bytes, bools and
#     submessages;
#   - a hand-written descriptor for the 64-bit kinds (int64, uint64,
#     sint64, fixed64, repeated sint64 and a recursive submessage),
#     which message.w stores as two int32 words on every target;
#   - an empty descriptor, so every field is unknown and skipped.
# Invariants:
#   - when a descriptor decodes the input, encoding the result and
#     decoding that again must succeed, and its encoding must equal the
#     first (encode is canonical: the decode/encode cycle reaches a
#     fixpoint after one round);
#   - the empty descriptor accepts the input exactly when walking it
#     with wire.w's wire_tag_decode + wire_skip_field reaches the end;
#   - a failed decode leaves no pointer field set (pb_free_decoded
#     re-zeroes them);
#   - each varint at the start of the input re-encodes (varint.w) to a
#     form that decodes to the same 64-bit value, no longer than the
#     original, and zigzag is its own inverse.
# Seeds are golden vectors from tests/protobuf_test.w and
# protobuf_message_test.w (Google's Encoding-guide messages) plus
# messages covering every field above, nesting, packed and unpacked
# repeats, duplicate fields, unknown fields and the error cases.
import tools.fuzz.harness
import lib.result
import libs.extras.protobuf.message


enum fzp_color:
	fzp_red
	fzp_green
	fzp_blue


message fzp_node:
	int32 i32 = 1
	uint32 u32 = 2
	sint32 s32 = 3
	bool flag = 4
	fixed32 f32 = 5
	string text = 6
	bytes blob = 7
	fzp_node child = 8
	repeated int32 ri = 9
	repeated sint32 rs = 10
	repeated fixed32 rf = 11
	repeated string rstr = 12
	repeated bytes rb = 13
	repeated fzp_node kids = 14
	fzp_color color = 15
	repeated bool rbool = 16
	sfixed32 sf32 = 17
	float fl = 18
	repeated uint32 ru = 19


# The 64-bit kinds, laid out by hand: each scalar is two int32 words
# (low first), the list and submessage fields one pointer word each.
struct fzp_wide:
	int32 i64_lo
	int32 i64_hi
	int32 u64_lo
	int32 u64_hi
	int32 s64_lo
	int32 s64_hi
	int32 f64_lo
	int32 f64_hi
	int rs64
	int child


pb_message_desc* fzp_wide_desc
pb_message_desc* fzp_empty_desc


void fzp_field(pb_field_desc* f, int number, int kind, int offset, int aux):
	f.number = number
	f.kind = kind
	f.offset = offset
	f.aux = aux


void fzp_init():
	fzp_wide w
	int base = cast(int, &w)
	pb_field_desc* fields = cast(pb_field_desc*, malloc(6 * 4 * __word_size__))
	pb_value_desc* elem = new pb_value_desc(PB_KIND_SINT64, 0)
	fzp_wide_desc = new pb_message_desc(6, fields, 8 * 4 + 2 * __word_size__)
	fzp_field(&fields[0], 1, PB_KIND_INT64(), cast(int, &w.i64_lo) - base, 0)
	fzp_field(&fields[1], 2, PB_KIND_UINT64, cast(int, &w.u64_lo) - base, 0)
	fzp_field(&fields[2], 3, PB_KIND_SINT64, cast(int, &w.s64_lo) - base, 0)
	fzp_field(&fields[3], 4, PB_KIND_FIXED64, cast(int, &w.f64_lo) - base, 0)
	fzp_field(&fields[4], 5, PB_KIND_REPEATED, cast(int, &w.rs64) - base, cast(int, elem))
	fzp_field(&fields[5], 8, PB_KIND_MESSAGE, cast(int, &w.child) - base, cast(int, fzp_wide_desc))
	fzp_empty_desc = new pb_message_desc(0, 0, __word_size__)


# 1 when every byte of the struct's pointer-bearing fields is zero.
int fzp_pointers_clear(pb_message_desc* desc, char* out):
	for i in range(desc.field_count):
		pb_field_desc* f = &desc.fields[i]
		int kind = f.kind
		if ((kind == PB_KIND_STRING) || (kind == PB_KIND_BYTES) || (kind == PB_KIND_MESSAGE) || (kind == PB_KIND_REPEATED)):
			if (pb_load_ptr(out + f.offset) != 0): return 0
	return 1


int fzp_round_trip(pb_message_desc* desc, char* data, int length):
	char* out = pb_message_new(desc)
	int code = pb_decode_into(desc, data, length, out)
	if (code != 0):
		fh_check(fzp_pointers_clear(desc, out), c"a failed decode left a pointer field set")
		free(out)
		return 0
	int len1 = 0
	char* enc1 = pb_encode(desc, out, &len1)
	char* again = pb_message_new(desc)
	fh_check(pb_decode_into(desc, enc1, len1, again) == 0, c"pb_encode output does not decode")
	int len2 = 0
	char* enc2 = pb_encode(desc, again, &len2)
	fh_check((len1 == len2) && fh_bytes_equal(enc1, enc2, len1), c"decode/encode did not reach a fixpoint")
	free(enc1)
	free(enc2)
	pb_free_message(desc, again)
	pb_free_message(desc, out)
	return 1


int fzp_wire_walk(char* data, int length):
	int pos = 0
	while (pos < length):
		int number = 0
		int wire_type = 0
		int tn = wire_tag_decode(data + pos, length - pos, &number, &wire_type)
		if (tn == 0): return 0
		pos = pos + tn
		int skipped = wire_skip_field(data + pos, length - pos, wire_type)
		if (skipped == 0): return 0
		pos = pos + skipped
	return 1


void fzp_varints(char* data, int length):
	int lo = 0
	int hi = 0
	int n = varint_decode_parts(data, length, &lo, &hi)
	if (n <= 0): return
	char[10] buf
	int m = varint_encode_parts(lo, hi, &buf[0])
	fh_check((m >= 1) && (m <= n), c"varint re-encoding is longer than the input")
	int lo2 = 0
	int hi2 = 0
	fh_check(varint_decode_parts(&buf[0], m, &lo2, &hi2) == m, c"re-encoded varint does not decode")
	int mask = varint_mask32()
	fh_check(((lo & mask) == (lo2 & mask)) && ((hi & mask) == (hi2 & mask)), c"varint round trip changed the value")
	int zlo = 0
	int zhi = 0
	zigzag_encode64_parts(lo, hi, &zlo, &zhi)
	int back_lo = 0
	int back_hi = 0
	zigzag_decode64_parts(zlo, zhi, &back_lo, &back_hi)
	fh_check(((back_lo & mask) == (lo & mask)) && ((back_hi & mask) == (hi & mask)), c"zigzag64 is not its own inverse")
	fh_check((zigzag_decode32(zigzag_encode32(lo)) & mask) == (lo & mask), c"zigzag32 is not its own inverse")


int main(int argc, int argv):
	int length = 0
	char* data = fh_input(argc, argv, &length)
	fzp_init()
	fzp_varints(data, length)
	int accepted = fzp_round_trip(proto_descriptor(fzp_node), data, length)
	if (fzp_round_trip(fzp_wide_desc, data, length)): accepted = 1
	int walked = fzp_wire_walk(data, length)
	int empty = fzp_round_trip(fzp_empty_desc, data, length)
	fh_check(walked == empty, c"empty-descriptor decode disagrees with the wire.w walk")
	if (accepted || empty): return 0
	return 1
