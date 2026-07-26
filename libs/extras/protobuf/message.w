/*
libs/extras/protobuf/message.w: generic proto3 message encode/decode
driven by a hand-written field descriptor (docs/projects/protobuf.md
§6.3 -- stage 1's "hand-written descriptors, golden-vector tests").

Structurally parallel to structures/json_codec.w's descriptor-driven
walk (docs/projects/protobuf.md §1.1-§1.2), but with two deliberate
divergences the design doc calls out:

- No intermediate tree value. JSON needs json_value* because JSON is
  self-describing text; protobuf's wire format is binary and this file
  goes directly between struct bytes and wire bytes.
- Permissive decode, not strict. A missing field leaves the struct's
  zero-initialized default (proto3's implicit field presence); an
  unrecognized field number is skipped via wire_skip_field, never an
  error. This is the opposite of json_codec's "every named field must be
  present" contract -- protobuf's entire schema-evolution story depends
  on it (docs/projects/protobuf.md §1.2, §2).
- Symmetrically, encode omits any scalar field still at its zero value
  and any absent (null pointer / empty list) message, string, bytes, or
  repeated field -- proto3's own wire-size rule, and the reason a
  correct encoder's output is comparable byte-for-byte against a real
  protobuf implementation's (docs/projects/protobuf.md §8's test
  strategy: vectors may be cross-checked against real protoc/protobuf
  output).

Field kinds are deliberately split by width (PB_KIND_INT32 vs
PB_KIND_INT64, etc.) rather than json_codec's kind+size pair, since the
descriptor sketch in the design doc has no size field -- kind alone
determines wire handling.

64-bit kinds (INT64/UINT64/SINT64/FIXED64) are implemented without ever
naming the int64/uint64 types (which are x64-only, README.md's Language
snapshot): a field's raw 8 bytes are read/written as two adjacent int32
words (offset+0 low, offset+4 high, little-endian -- matching every
target this compiler emits for), so this file compiles unchanged on the
default 32-bit target. Only x64-compiled programs can actually declare a
struct field of a type wide enough to exercise those kinds (see
tests/protobuf_test.w's companion x64-only supplementary target).

Hardening invariants for untrusted input (the stage-1 backlog in
docs/projects/ai_tooling_next_steps.md):

- Submessage recursion is capped at PB_MAX_DECODE_DEPTH() nesting
  levels (PB_ERR_DEPTH_EXCEEDED past it), so crafted input nesting one
  length-delimited field per few bytes cannot overflow the stack.
- Duplicate occurrences of the same singular field follow proto3
  semantics: scalars and strings/bytes are last-one-wins (the earlier
  string/bytes copy is freed, never leaked), submessages MERGE into
  the already-decoded struct (recursively; repeated fields inside the
  merge concatenate).
- A decode error frees every allocation the partial decode already
  stored into `out` and re-zeroes the pointer-bearing fields
  (pb_free_decoded), so a failed pb_decode/pb_decode_into never leaks
  and hands the caller back a clean, reusable buffer.
*/
import lib.memory
import lib.result
import structures.string
import structures.w_list
import libs.extras.protobuf.varint
import libs.extras.protobuf.wire


# ---- field kinds ------------------------------------------------------

int PB_KIND_INT32():
	return 1


int PB_KIND_INT64():
	return 2


int PB_KIND_UINT32():
	return 3


int PB_KIND_UINT64():
	return 4


int PB_KIND_SINT32():
	return 5


int PB_KIND_SINT64():
	return 6


int PB_KIND_BOOL():
	return 7


int PB_KIND_FIXED32():
	return 8


int PB_KIND_FIXED64():
	return 9


int PB_KIND_STRING():
	return 10


int PB_KIND_BYTES():
	return 11


int PB_KIND_MESSAGE():
	return 12


int PB_KIND_REPEATED():
	return 13


# ---- error codes --------------------------------------------------------

int PB_ERR_TRUNCATED():
	return 1


int PB_ERR_BAD_WIRE_TYPE():
	return 2


int PB_ERR_BAD_VARINT():
	return 3


int PB_ERR_LENGTH_OVERRUN():
	return 4


int PB_ERR_DEPTH_EXCEEDED():
	return 5


# Maximum submessage nesting depth pb_decode accepts, matching protoc's
# own default recursion limit (100). Without a cap, crafted input
# nesting one length-delimited field per few bytes drives
# pb_decode_message_field's recursion arbitrarily deep and overflows
# the stack long before the buffer runs out.
int PB_MAX_DECODE_DEPTH():
	return 100


char* pb_error_string(int code):
	if (code == PB_ERR_TRUNCATED()):
		return c"protobuf: input ended mid-field"
	if (code == PB_ERR_BAD_WIRE_TYPE()):
		return c"protobuf: unsupported wire type"
	if (code == PB_ERR_BAD_VARINT()):
		return c"protobuf: varint exceeds 10 bytes"
	if (code == PB_ERR_LENGTH_OVERRUN()):
		return c"protobuf: length-delimited field overruns the buffer"
	if (code == PB_ERR_DEPTH_EXCEEDED()):
		return c"protobuf: message nesting exceeds depth limit"
	return c"protobuf: unknown error"


# ---- descriptor and storage shapes -------------------------------------

# Explicit-length byte storage for STRING/BYTES fields (embedded inline
# in the parent struct by value): a NUL-terminated char* cannot carry an
# embedded NUL byte, which proto3 `bytes` fields must (docs/projects/
# protobuf.md §8's golden-vector list explicitly covers this case).
struct pb_bytes:
	char* data
	int length


# Element kind for a repeated field (mirrors json_codec.w's list
# value-descriptor: kind + aux, no size -- kind alone determines width
# here too).
struct pb_value_desc:
	int kind
	int aux


struct pb_field_desc:
	int number    # wire field number
	int kind      # PB_KIND_*
	int offset    # byte offset into the struct (see tests/protobuf_test.w
	              # for the cast(int, &s.field) - cast(int, &s) idiom
	              # used to compute this without hand-counting field
	              # widths, which differ by target)
	int aux       # PB_KIND_MESSAGE: nested pb_message_desc*
	              # PB_KIND_REPEATED: pb_value_desc*
	              # otherwise: unused (0)


struct pb_message_desc:
	int field_count
	pb_field_desc* fields
	int struct_size


# ---- small shared helpers ------------------------------------------------

int pb_load_ptr(char* addr):
	int* p = cast(int*, addr)
	return p[0]


void pb_store_ptr(char* addr, int value):
	int* p = cast(int*, addr)
	p[0] = value


int pb_kind_wire_type(int kind):
	if ((kind == PB_KIND_INT32()) || (kind == PB_KIND_INT64()) || (kind == PB_KIND_UINT32()) || (kind == PB_KIND_UINT64()) || (kind == PB_KIND_SINT32()) || (kind == PB_KIND_SINT64()) || (kind == PB_KIND_BOOL())):
		return PB_WIRE_VARINT()
	if (kind == PB_KIND_FIXED32()):
		return PB_WIRE_FIXED32()
	if (kind == PB_KIND_FIXED64()):
		return PB_WIRE_FIXED64()
	return PB_WIRE_LENGTH_DELIMITED()


# Only scalar numeric/fixed wire types 0/1/5 may be packed (proto3's
# default for `repeated`); length-delimited kinds (message/string/bytes)
# already carry their own delimiter and can't be (docs/projects/
# protobuf.md §2).
int pb_kind_is_packable(int kind):
	if ((kind == PB_KIND_STRING()) || (kind == PB_KIND_BYTES()) || (kind == PB_KIND_MESSAGE()) || (kind == PB_KIND_REPEATED())):
		return 0
	return 1


# Wire types 3/4 (deprecated "groups") and anything else outside 0/1/2/5
# are unsupported (docs/projects/protobuf.md §2); distinguishing this
# from a merely truncated buffer is PB_ERR_BAD_WIRE_TYPE's whole reason
# to exist as its own code.
int pb_wire_type_valid(int wire_type):
	if (wire_type == PB_WIRE_VARINT()):
		return 1
	if (wire_type == PB_WIRE_FIXED64()):
		return 1
	if (wire_type == PB_WIRE_LENGTH_DELIMITED()):
		return 1
	if (wire_type == PB_WIRE_FIXED32()):
		return 1
	return 0


# Shared by every "this occurrence doesn't match what we expected, treat
# it as if the field number were unknown" fallback path: validates the
# wire type before skipping so a genuinely unsupported wire type (group
# start/end) reports PB_ERR_BAD_WIRE_TYPE rather than being folded into
# PB_ERR_TRUNCATED. The skip itself is performed inline rather than via
# wire_skip_field: that primitive's tolerant contract collapses every
# failure to 0, and this is the layer that must tell a genuinely
# truncated buffer (PB_ERR_TRUNCATED) from an over-long varint
# (PB_ERR_BAD_VARINT -- e.g. an unknown field carrying an 11-byte
# varint) or an overrunning declared length (PB_ERR_LENGTH_OVERRUN) --
# the distinction wire.w's wire_tag_decode comment defers to here.
int pb_skip_or_error(char* data, int length, int wire_type, int* consumed_out):
	if (pb_wire_type_valid(wire_type) == 0):
		return PB_ERR_BAD_WIRE_TYPE()
	if (wire_type == PB_WIRE_VARINT()):
		int lo = 0
		int hi = 0
		int n = varint_decode_parts(data, length, &lo, &hi)
		if (n < 0):
			return PB_ERR_TRUNCATED()
		if (n == 0):
			return PB_ERR_BAD_VARINT()
		consumed_out[0] = n
		return 0
	if (wire_type == PB_WIRE_FIXED64()):
		if (length < 8):
			return PB_ERR_TRUNCATED()
		consumed_out[0] = 8
		return 0
	if (wire_type == PB_WIRE_FIXED32()):
		if (length < 4):
			return PB_ERR_TRUNCATED()
		consumed_out[0] = 4
		return 0
	# PB_WIRE_LENGTH_DELIMITED -- the only remaining valid wire type.
	int blen = 0
	int n = varint_decode_u32(data, length, &blen)
	if (n < 0):
		return PB_ERR_TRUNCATED()
	if (n == 0):
		return PB_ERR_BAD_VARINT()
	if (blen < 0):
		return PB_ERR_LENGTH_OVERRUN()
	if ((length - n) < blen):
		return PB_ERR_LENGTH_OVERRUN()
	consumed_out[0] = n + blen
	return 0


int pb_element_size(pb_value_desc* elem):
	int kind = elem.kind
	if ((kind == PB_KIND_FIXED64()) || (kind == PB_KIND_INT64()) || (kind == PB_KIND_UINT64()) || (kind == PB_KIND_SINT64())):
		return 8
	if ((kind == PB_KIND_STRING()) || (kind == PB_KIND_BYTES())):
		return 2 * __word_size__
	if (kind == PB_KIND_MESSAGE()):
		pb_message_desc* nested = cast(pb_message_desc*, elem.aux)
		return nested.struct_size
	return 4


int pb_is_zero_scalar(int kind, char* addr):
	if (kind == PB_KIND_BOOL()):
		return (addr[0] & 1) == 0
	int width = 4
	if ((kind == PB_KIND_FIXED64()) || (kind == PB_KIND_INT64()) || (kind == PB_KIND_UINT64()) || (kind == PB_KIND_SINT64())):
		width = 8
	int i = 0
	while (i < width):
		if ((addr[i] & 255) != 0):
			return 0
		i = i + 1
	return 1


# ---- encode: one scalar payload (no tag) ---------------------------------

void pb_encode_scalar(int kind, char* addr, string_builder* out):
	char[10] buf
	if (kind == PB_KIND_INT32()):
		int32* p = cast(int32*, addr)
		int n = varint_encode_i32(p[0], buf)
		string_append_bytes(out, buf, n)
	else if (kind == PB_KIND_UINT32()):
		uint32* p = cast(uint32*, addr)
		int n = varint_encode_u32(p[0], buf)
		string_append_bytes(out, buf, n)
	else if (kind == PB_KIND_SINT32()):
		int32* p = cast(int32*, addr)
		int n = varint_encode_u32(zigzag_encode32(p[0]), buf)
		string_append_bytes(out, buf, n)
	else if (kind == PB_KIND_BOOL()):
		int v = addr[0] & 1
		int n = varint_encode_u32(v, buf)
		string_append_bytes(out, buf, n)
	else if (kind == PB_KIND_FIXED32()):
		string_append_bytes(out, addr, 4)
	else if (kind == PB_KIND_FIXED64()):
		string_append_bytes(out, addr, 8)
	else if ((kind == PB_KIND_INT64()) || (kind == PB_KIND_UINT64())):
		int32* lo_p = cast(int32*, addr)
		int32* hi_p = cast(int32*, addr + 4)
		int n = varint_encode_parts(lo_p[0], hi_p[0], buf)
		string_append_bytes(out, buf, n)
	else if (kind == PB_KIND_SINT64()):
		int32* lo_p = cast(int32*, addr)
		int32* hi_p = cast(int32*, addr + 4)
		int zlo = 0
		int zhi = 0
		zigzag_encode64_parts(lo_p[0], hi_p[0], &zlo, &zhi)
		int n = varint_encode_parts(zlo, zhi, buf)
		string_append_bytes(out, buf, n)


void pb_append_tag(int number, int wire_type, string_builder* out):
	char[10] buf
	int n = wire_tag_encode(number, wire_type, buf)
	string_append_bytes(out, buf, n)


void pb_append_length(int length, string_builder* out):
	char[10] buf
	int n = varint_encode_u32(length, buf)
	string_append_bytes(out, buf, n)


char* pb_encode(pb_message_desc* desc, char* addr, int* out_length);


void pb_encode_message_value(pb_message_desc* nested, char* addr, int number, string_builder* out):
	pb_append_tag(number, PB_WIRE_LENGTH_DELIMITED(), out)
	int sub_len = 0
	char* sub = pb_encode(nested, addr, &sub_len)
	pb_append_length(sub_len, out)
	string_append_bytes(out, sub, sub_len)
	free(sub)


void pb_encode_bytes_value(pb_bytes* b, int number, string_builder* out):
	pb_append_tag(number, PB_WIRE_LENGTH_DELIMITED(), out)
	pb_append_length(b.length, out)
	string_append_bytes(out, b.data, b.length)


void pb_encode_repeated(pb_field_desc* f, char* addr, string_builder* out):
	int raw = pb_load_ptr(addr)
	if (raw == 0):
		return
	__w_list* list = cast(__w_list*, raw)
	if (list.length == 0):
		return
	pb_value_desc* elem = cast(pb_value_desc*, f.aux)
	int ekind = elem.kind
	if (pb_kind_is_packable(ekind)):
		string_builder* payload = string_new()
		int i = 0
		while (i < list.length):
			pb_encode_scalar(ekind, list.items + i * list.element_size, payload)
			i = i + 1
		pb_append_tag(f.number, PB_WIRE_LENGTH_DELIMITED(), out)
		pb_append_length(payload.length, out)
		string_append_bytes(out, payload.data, payload.length)
		string_free(payload)
	else if (ekind == PB_KIND_MESSAGE()):
		pb_message_desc* nested = cast(pb_message_desc*, elem.aux)
		int i = 0
		while (i < list.length):
			pb_encode_message_value(nested, list.items + i * list.element_size, f.number, out)
			i = i + 1
	else:
		int i = 0
		while (i < list.length):
			pb_bytes* b = cast(pb_bytes*, list.items + i * list.element_size)
			pb_encode_bytes_value(b, f.number, out)
			i = i + 1


void pb_encode_field(pb_field_desc* f, char* addr, string_builder* out):
	int kind = f.kind
	if (kind == PB_KIND_REPEATED()):
		pb_encode_repeated(f, addr, out)
		return
	if (kind == PB_KIND_MESSAGE()):
		int raw = pb_load_ptr(addr)
		if (raw == 0):
			return
		pb_encode_message_value(cast(pb_message_desc*, f.aux), cast(char*, raw), f.number, out)
		return
	if ((kind == PB_KIND_STRING()) || (kind == PB_KIND_BYTES())):
		pb_bytes* b = cast(pb_bytes*, addr)
		if (b.length == 0):
			return
		pb_encode_bytes_value(b, f.number, out)
		return
	if (pb_is_zero_scalar(kind, addr)):
		return
	pb_append_tag(f.number, pb_kind_wire_type(kind), out)
	pb_encode_scalar(kind, addr, out)


# Never fails on a well-formed descriptor/struct pair -- plain return, no
# wresult, same reasoning libs/extras/compress/deflate.w's deflate() uses
# (docs/projects/protobuf.md §6.3).
char* pb_encode(pb_message_desc* desc, char* addr, int* out_length):
	string_builder* out = string_new()
	int i = 0
	while (i < desc.field_count):
		pb_field_desc* f = &desc.fields[i]
		pb_encode_field(f, addr + f.offset, out)
		i = i + 1
	char* data = out.data
	int length = out.length
	free(out)
	out_length[0] = length
	return data


# ---- decode ---------------------------------------------------------------

int pb_decode_scalar_field(int kind, char* data, int length, char* out_addr, int* consumed_out):
	if (kind == PB_KIND_INT32()):
		int v = 0
		int n = varint_decode_i32(data, length, &v)
		if (n < 0):
			return PB_ERR_TRUNCATED()
		if (n == 0):
			return PB_ERR_BAD_VARINT()
		int32* p = cast(int32*, out_addr)
		p[0] = v
		consumed_out[0] = n
		return 0
	if (kind == PB_KIND_UINT32()):
		int v = 0
		int n = varint_decode_u32(data, length, &v)
		if (n < 0):
			return PB_ERR_TRUNCATED()
		if (n == 0):
			return PB_ERR_BAD_VARINT()
		uint32* p = cast(uint32*, out_addr)
		p[0] = v
		consumed_out[0] = n
		return 0
	if (kind == PB_KIND_SINT32()):
		int v = 0
		int n = varint_decode_u32(data, length, &v)
		if (n < 0):
			return PB_ERR_TRUNCATED()
		if (n == 0):
			return PB_ERR_BAD_VARINT()
		int32* p = cast(int32*, out_addr)
		p[0] = zigzag_decode32(v)
		consumed_out[0] = n
		return 0
	if (kind == PB_KIND_BOOL()):
		int v = 0
		int n = varint_decode_u32(data, length, &v)
		if (n < 0):
			return PB_ERR_TRUNCATED()
		if (n == 0):
			return PB_ERR_BAD_VARINT()
		# Write the element's full 4-byte width like the other 4-byte
		# kinds: repeated decode stages elements in a reused stack slot,
		# so a byte-0-only write would copy the slot's stale bytes 1-3
		# into the list element.
		out_addr[0] = v & 1
		out_addr[1] = 0
		out_addr[2] = 0
		out_addr[3] = 0
		consumed_out[0] = n
		return 0
	if (kind == PB_KIND_FIXED32()):
		if (length < 4):
			return PB_ERR_TRUNCATED()
		int i = 0
		while (i < 4):
			out_addr[i] = data[i]
			i = i + 1
		consumed_out[0] = 4
		return 0
	if (kind == PB_KIND_FIXED64()):
		if (length < 8):
			return PB_ERR_TRUNCATED()
		int i = 0
		while (i < 8):
			out_addr[i] = data[i]
			i = i + 1
		consumed_out[0] = 8
		return 0
	if ((kind == PB_KIND_INT64()) || (kind == PB_KIND_UINT64())):
		int lo = 0
		int hi = 0
		int n = varint_decode_parts(data, length, &lo, &hi)
		if (n < 0):
			return PB_ERR_TRUNCATED()
		if (n == 0):
			return PB_ERR_BAD_VARINT()
		int32* lo_p = cast(int32*, out_addr)
		int32* hi_p = cast(int32*, out_addr + 4)
		lo_p[0] = lo
		hi_p[0] = hi
		consumed_out[0] = n
		return 0
	if (kind == PB_KIND_SINT64()):
		int lo = 0
		int hi = 0
		int n = varint_decode_parts(data, length, &lo, &hi)
		if (n < 0):
			return PB_ERR_TRUNCATED()
		if (n == 0):
			return PB_ERR_BAD_VARINT()
		int dlo = 0
		int dhi = 0
		zigzag_decode64_parts(lo, hi, &dlo, &dhi)
		int32* lo_p = cast(int32*, out_addr)
		int32* hi_p = cast(int32*, out_addr + 4)
		lo_p[0] = dlo
		hi_p[0] = dhi
		consumed_out[0] = n
		return 0
	return PB_ERR_BAD_WIRE_TYPE()


int pb_decode_bytes_field(char* data, int length, char* out_addr, int* consumed_out):
	int blen = 0
	int n = varint_decode_u32(data, length, &blen)
	if (n < 0):
		return PB_ERR_TRUNCATED()
	if (n == 0):
		return PB_ERR_BAD_VARINT()
	if (blen < 0):
		return PB_ERR_LENGTH_OVERRUN()
	if ((length - n) < blen):
		return PB_ERR_LENGTH_OVERRUN()
	# Allocate one extra byte and NUL-terminate (mirrors structures/
	# json_codec.w's __w_json_encode_string): b.length is always the
	# true byte count, so a BYTES field with an embedded NUL still
	# round-trips correctly (the caller must use b.data/b.length, not
	# strlen); a STRING field with no embedded NUL additionally becomes
	# safe to pass to ordinary C-string helpers.
	char* copy = malloc(blen + 1)
	int i = 0
	while (i < blen):
		copy[i] = data[n + i]
		i = i + 1
	copy[blen] = 0
	# proto3 last-one-wins for duplicate string/bytes occurrences: free
	# the copy an earlier occurrence of this field stored before
	# replacing it. b.data here is only ever null (first occurrence into
	# a zeroed struct, or the zeroed staging slot pb_decode_repeated
	# passes) or a previous pb_decode_bytes_field allocation.
	pb_bytes* b = cast(pb_bytes*, out_addr)
	if (cast(int, b.data) != 0):
		free(b.data)
	b.data = copy
	b.length = blen
	consumed_out[0] = n + blen
	return 0


int pb_decode_into_depth(pb_message_desc* desc, char* data, int length, char* out, int depth);


# depth: nesting level of the message CONTAINING this field (0 for the
# root), checked against PB_MAX_DECODE_DEPTH() before recursing.
int pb_decode_message_field(pb_message_desc* nested, char* data, int length, char* out_addr, int* consumed_out, int depth):
	int mlen = 0
	int n = varint_decode_u32(data, length, &mlen)
	if (n < 0):
		return PB_ERR_TRUNCATED()
	if (n == 0):
		return PB_ERR_BAD_VARINT()
	if (mlen < 0):
		return PB_ERR_LENGTH_OVERRUN()
	if ((length - n) < mlen):
		return PB_ERR_LENGTH_OVERRUN()
	if (depth >= PB_MAX_DECODE_DEPTH()):
		return PB_ERR_DEPTH_EXCEEDED()
	# proto3 duplicate-message semantics: a later occurrence of the same
	# singular message field MERGES into the earlier one, not replaces
	# it -- scalars last-one-wins, strings/bytes freed and replaced,
	# repeated fields concatenated, nested submessages merged
	# recursively. Decoding into the existing struct (instead of a
	# fresh zeroed one, which also leaked the first allocation) gives
	# exactly those semantics, since every field decode already
	# overwrites, replaces, or appends in place.
	int existing = pb_load_ptr(out_addr)
	char* buf
	if (existing != 0):
		buf = cast(char*, existing)
	else:
		buf = malloc(nested.struct_size)
		int i = 0
		while (i < nested.struct_size):
			buf[i] = 0
			i = i + 1
		# Attach before decoding: if the nested decode fails midway,
		# the partially-filled submessage stays reachable from the
		# caller's struct, so pb_decode_into's error-path
		# pb_free_decoded sweep reclaims it (and everything it stored)
		# instead of leaking it.
		pb_store_ptr(out_addr, cast(int, buf))
	int code = pb_decode_into_depth(nested, data + n, mlen, buf, depth + 1)
	if (code != 0):
		return code
	consumed_out[0] = n + mlen
	return 0


pb_field_desc* pb_find_field(pb_message_desc* desc, int number):
	int i = 0
	while (i < desc.field_count):
		if (desc.fields[i].number == number):
			return &desc.fields[i]
		i = i + 1
	return cast(pb_field_desc*, 0)


# Frees every heap allocation a decode stored into a struct's fields --
# string/bytes copies, submessage structs (recursively), repeated-field
# lists and their elements' own allocations -- and resets those fields
# to zero, leaving `out` as if freshly zeroed. Serves two callers: the
# owner of a successfully decoded message tearing it down, and
# pb_decode_into's error path, where it reclaims whatever a failed
# decode had already stored (partial submessages included -- see
# pb_decode_message_field's attach-before-decode note). Scalar fields
# are left untouched; they own no memory.
void pb_free_decoded(pb_message_desc* desc, char* out):
	int i = 0
	while (i < desc.field_count):
		pb_field_desc* f = &desc.fields[i]
		char* addr = out + f.offset
		int kind = f.kind
		if ((kind == PB_KIND_STRING()) || (kind == PB_KIND_BYTES())):
			pb_bytes* b = cast(pb_bytes*, addr)
			if (cast(int, b.data) != 0):
				free(b.data)
			b.data = cast(char*, 0)
			b.length = 0
		else if (kind == PB_KIND_MESSAGE()):
			int raw = pb_load_ptr(addr)
			if (raw != 0):
				pb_free_decoded(cast(pb_message_desc*, f.aux), cast(char*, raw))
				free(cast(char*, raw))
				pb_store_ptr(addr, 0)
		else if (kind == PB_KIND_REPEATED()):
			int raw = pb_load_ptr(addr)
			if (raw != 0):
				__w_list* list = cast(__w_list*, raw)
				pb_value_desc* elem = cast(pb_value_desc*, f.aux)
				int ekind = elem.kind
				int j = 0
				while (j < list.length):
					char* eaddr = list.items + j * list.element_size
					if ((ekind == PB_KIND_STRING()) || (ekind == PB_KIND_BYTES())):
						pb_bytes* eb = cast(pb_bytes*, eaddr)
						if (cast(int, eb.data) != 0):
							free(eb.data)
					else if (ekind == PB_KIND_MESSAGE()):
						# Message elements are stored by value inside
						# list.items -- free their internals only, not
						# the element storage itself.
						pb_free_decoded(cast(pb_message_desc*, elem.aux), eaddr)
					j = j + 1
				__w_list_free(list)
				pb_store_ptr(addr, 0)
		i = i + 1


# Decodes one occurrence of a repeated field: a packed blob (proto3's
# default for packable scalar kinds), an unpacked single occurrence
# (accepted regardless of dialect per docs/projects/protobuf.md §2 --
# "a decoder must accept both packed and unpacked encodings"), or one
# length-delimited message/string/bytes element. Any wire type matching
# none of those shapes is treated as if the field number were unknown
# (skipped, not an error) rather than risking a misinterpreted decode.
int pb_decode_repeated(pb_field_desc* f, int wire_type, char* data, int length, char* out_addr, int* consumed_out, int depth):
	pb_value_desc* elem = cast(pb_value_desc*, f.aux)
	int ekind = elem.kind
	int packable = pb_kind_is_packable(ekind)
	int natural_wire = pb_kind_wire_type(ekind)

	int is_packed_form = 0
	if (packable && (wire_type == PB_WIRE_LENGTH_DELIMITED()) && (natural_wire != PB_WIRE_LENGTH_DELIMITED())):
		is_packed_form = 1
	int is_unpacked_scalar = 0
	if (packable && (wire_type == natural_wire)):
		is_unpacked_scalar = 1
	int is_delimited_element = 0
	if ((packable == 0) && (wire_type == PB_WIRE_LENGTH_DELIMITED())):
		is_delimited_element = 1

	if ((is_packed_form == 0) && (is_unpacked_scalar == 0) && (is_delimited_element == 0)):
		return pb_skip_or_error(data, length, wire_type, consumed_out)

	int raw = pb_load_ptr(out_addr)
	__w_list* list
	if (raw == 0):
		list = __w_list_new(pb_element_size(elem))
		pb_store_ptr(out_addr, cast(int, list))
	else:
		list = cast(__w_list*, raw)

	if (is_packed_form):
		int blen = 0
		int n = varint_decode_u32(data, length, &blen)
		if (n < 0):
			return PB_ERR_TRUNCATED()
		if (n == 0):
			return PB_ERR_BAD_VARINT()
		if (blen < 0):
			return PB_ERR_LENGTH_OVERRUN()
		if ((length - n) < blen):
			return PB_ERR_LENGTH_OVERRUN()
		int pos = 0
		char[8] slot
		while (pos < blen):
			int consumed = 0
			int code = pb_decode_scalar_field(ekind, data + n + pos, blen - pos, slot, &consumed)
			if (code != 0):
				return code
			__w_list_push_bytes(list, slot)
			pos = pos + consumed
		consumed_out[0] = n + blen
		return 0

	if (ekind == PB_KIND_MESSAGE()):
		pb_message_desc* nested = cast(pb_message_desc*, elem.aux)
		int mlen = 0
		int n = varint_decode_u32(data, length, &mlen)
		if (n < 0):
			return PB_ERR_TRUNCATED()
		if (n == 0):
			return PB_ERR_BAD_VARINT()
		if (mlen < 0):
			return PB_ERR_LENGTH_OVERRUN()
		if ((length - n) < mlen):
			return PB_ERR_LENGTH_OVERRUN()
		if (depth >= PB_MAX_DECODE_DEPTH()):
			return PB_ERR_DEPTH_EXCEEDED()
		char* buf = malloc(nested.struct_size)
		int i = 0
		while (i < nested.struct_size):
			buf[i] = 0
			i = i + 1
		int code = pb_decode_into_depth(nested, data + n, mlen, buf, depth + 1)
		if (code != 0):
			# The staging buffer is not yet reachable from `out`, so the
			# top-level error sweep cannot find it -- release whatever
			# the failed element decode stored into it here.
			pb_free_decoded(nested, buf)
			free(buf)
			return code
		__w_list_push_bytes(list, buf)
		free(buf)
		consumed_out[0] = n + mlen
		return 0

	if ((ekind == PB_KIND_STRING()) || (ekind == PB_KIND_BYTES())):
		# Zero the staging slot: pb_decode_bytes_field frees a non-null
		# previous b.data (proto3 last-one-wins), which must never see
		# this stack slot's stale bytes. Zeroed via indexed byte writes
		# -- casting a T[N] local to a pointer type (cast(pb_bytes*,
		# slot)) addresses the array's runtime header, NOT its data
		# (only indexing and argument decay reach the data), so a
		# struct-view write here would clobber the header instead.
		char[16] slot
		int zi = 0
		while (zi < 16):
			slot[zi] = 0
			zi = zi + 1
		int consumed = 0
		int code = pb_decode_bytes_field(data, length, slot, &consumed)
		if (code != 0):
			return code
		__w_list_push_bytes(list, slot)
		consumed_out[0] = consumed
		return 0

	char[8] slot
	int consumed = 0
	int code = pb_decode_scalar_field(ekind, data, length, slot, &consumed)
	if (code != 0):
		return code
	__w_list_push_bytes(list, slot)
	consumed_out[0] = consumed
	return 0


int pb_decode_one(pb_field_desc* f, int wire_type, char* data, int length, char* out_addr, int* consumed_out, int depth):
	int kind = f.kind
	if (kind == PB_KIND_REPEATED()):
		return pb_decode_repeated(f, wire_type, data, length, out_addr, consumed_out, depth)
	if (kind == PB_KIND_MESSAGE()):
		if (wire_type != PB_WIRE_LENGTH_DELIMITED()):
			return pb_skip_or_error(data, length, wire_type, consumed_out)
		return pb_decode_message_field(cast(pb_message_desc*, f.aux), data, length, out_addr, consumed_out, depth)
	if ((kind == PB_KIND_STRING()) || (kind == PB_KIND_BYTES())):
		if (wire_type != PB_WIRE_LENGTH_DELIMITED()):
			return pb_skip_or_error(data, length, wire_type, consumed_out)
		return pb_decode_bytes_field(data, length, out_addr, consumed_out)
	if (wire_type != pb_kind_wire_type(kind)):
		return pb_skip_or_error(data, length, wire_type, consumed_out)
	return pb_decode_scalar_field(kind, data, length, out_addr, consumed_out)


# The generic decode loop: reads (tag, value) pairs until the buffer is
# consumed, skipping any field number absent from the descriptor
# (docs/projects/protobuf.md §2's unknown-field preservation contract).
# `out` must already be a zeroed buffer of desc.struct_size bytes (the
# caller's responsibility -- see pb_decode below), so any field this
# message never mentions keeps its zero default (proto3 implicit
# presence). depth is this message's own nesting level (0 at the root);
# each submessage recursion adds one, bounded by PB_MAX_DECODE_DEPTH().
int pb_decode_into_depth(pb_message_desc* desc, char* data, int length, char* out, int depth):
	int pos = 0
	while (pos < length):
		int field_number = 0
		int wire_type = 0
		int tn = wire_tag_decode(data + pos, length - pos, &field_number, &wire_type)
		if (tn == 0):
			# wire_tag_decode collapses "ran out of input" and "no
			# terminator within 10 bytes" to 0; re-classify so an
			# over-long tag varint reports PB_ERR_BAD_VARINT rather
			# than masquerading as truncation.
			int tlo = 0
			int thi = 0
			if (varint_decode_parts(data + pos, length - pos, &tlo, &thi) == 0):
				return PB_ERR_BAD_VARINT()
			return PB_ERR_TRUNCATED()
		pos = pos + tn
		pb_field_desc* f = pb_find_field(desc, field_number)
		if (cast(int, f) == 0):
			int consumed = 0
			int code = pb_skip_or_error(data + pos, length - pos, wire_type, &consumed)
			if (code != 0):
				return code
			pos = pos + consumed
		else:
			int consumed = 0
			int code = pb_decode_one(f, wire_type, data + pos, length - pos, out + f.offset, &consumed, depth)
			if (code != 0):
				return code
			pos = pos + consumed
	return 0


# Public whole-message decode into a caller-provided zeroed buffer. On
# any decode error, every allocation the partial decode already stored
# into `out` is freed and the pointer-bearing fields re-zeroed
# (pb_free_decoded), so a failed decode never leaks and `out` comes
# back as clean as the caller handed it in.
int pb_decode_into(pb_message_desc* desc, char* data, int length, char* out):
	int code = pb_decode_into_depth(desc, data, length, out, 0)
	if (code != 0):
		pb_free_decoded(desc, out)
	return code


# out: a pre-sized, zero-initialized buffer of desc.struct_size bytes
# (mirrors __w_json_decode's own "malloc + zero before decode" step).
# Unlike json_codec's strict all-or-nothing decode, a missing field here
# is never an error -- the wresult only reports genuine malformation
# (truncated varint, a length that overruns the buffer, an unsupported
# wire type).
wresult[char*]* pb_decode(pb_message_desc* desc, char* data, int length, char* out):
	int code = pb_decode_into(desc, data, length, out)
	if (code != 0):
		return result_new_error[char*](code)
	return result_new_ok[char*](out)
