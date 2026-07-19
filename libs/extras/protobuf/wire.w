/*
libs/extras/protobuf/wire.w: tags, wire-type constants, and the
skip-unknown-field primitive (docs/projects/protobuf.md §2, §6.2).

A protobuf message is a flat sequence of (tag, value) pairs with no
envelope: tag = (field_number << 3) | wire_type, itself just an unsigned
varint. Wire types 3/4 (deprecated "groups") are not supported -- no
producer this repo would realistically talk to still emits them, per the
design doc.
*/
import lib.memory
import libs.extras.protobuf.varint


int PB_WIRE_VARINT():
	return 0


int PB_WIRE_FIXED64():
	return 1


int PB_WIRE_LENGTH_DELIMITED():
	return 2


int PB_WIRE_FIXED32():
	return 5


int wire_tag_encode(int field_number, int wire_type, char* out):
	int tag = (field_number << 3) | wire_type
	return varint_encode_u32(tag, out)


# Bytes consumed, or 0 on truncated/malformed input. varint_decode_u32
# can return -1 (ran out of input) or 0 (exceeded 10 bytes) -- this
# function's own contract only needs "did it work", so both collapse to
# 0 here (message.w's pb_skip_or_error is where the two are told apart).
int wire_tag_decode(char* data, int length, int* field_number, int* wire_type):
	int tag = 0
	int n = varint_decode_u32(data, length, &tag)
	if (n <= 0):
		return 0
	field_number[0] = shr(tag, 3)
	wire_type[0] = tag & 7
	return n


# Skips exactly one field's payload for the given wire_type -- the
# unknown-field-tolerance primitive every consumer needs (docs/projects/
# protobuf.md §2's "unknown-field preservation": a decoder that sees a
# field number it doesn't recognize must skip precisely the right number
# of bytes and continue, never error). Returns bytes skipped, 0 on
# truncated/malformed/unsupported (group) wire types.
int wire_skip_field(char* data, int length, int wire_type):
	if (wire_type == PB_WIRE_VARINT()):
		int lo = 0
		int hi = 0
		int n = varint_decode_parts(data, length, &lo, &hi)
		if (n <= 0):
			return 0
		return n
	if (wire_type == PB_WIRE_FIXED64()):
		if (length < 8):
			return 0
		return 8
	if (wire_type == PB_WIRE_FIXED32()):
		if (length < 4):
			return 0
		return 4
	if (wire_type == PB_WIRE_LENGTH_DELIMITED()):
		int len = 0
		int n = varint_decode_u32(data, length, &len)
		if (n <= 0):
			return 0
		if (len < 0):
			return 0
		if ((length - n) < len):
			return 0
		return n + len
	return 0
