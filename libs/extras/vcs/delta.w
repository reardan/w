/*
Binary deltas: an alternative CAS object encoding (VCS wave 3, issue
#252; design: docs/projects/version_control.md "the performance
structures"). Companion to libs/extras/vcs/cas.w -- study that file's
header comment first, especially the "<type> <len>\0" framing and the
cas_put_raw seam this module builds on.

The identity invariant (git's model, restated because it drives every
decision below): an object's id is always sha256("<type> <len>\0" +
its full logical content), regardless of how the bytes happen to be
stored. Encoding -- full snapshot vs delta -- is a storage detail a
caller never has to know about. cas_put_delta computes the id from the
RECONSTRUCTED content (via cas.w's cas_id_hex, unchanged) before ever
touching disk, then writes the delta payload under that id with
cas_put_raw -- the exact seam cas.w designed in for the build-cache
client (see cas.w's header) turns out to be exactly what a delta store
needs too. No changes to cas.w were necessary; this module is a pure
client of its existing public API (cas_get / cas_put / cas_put_raw /
cas_id_hex / cas_valid_id / cas_valid_tag).

Algorithm: a rolling-hash block match, in the spirit of rsync/xdelta,
simplified because both base and target are fully in memory (unlike
rsync's remote-sync case, there is no need for a second "strong hash"
verification pass -- a weak-checksum hit is confirmed by direct byte
comparison, which is always available here and strictly stronger than
any hash).

  - DELTA_BLOCK_SIZE() = 64 bytes. Fixed, chosen so small test fixtures
    (a few hundred bytes) still span several blocks while staying fast
    and easy to hand-trace. Not tunable per call in this v1.
  - Index the base: for every non-overlapping, block-aligned,
    full-size window of the base (a base shorter than one block gets no
    index entries at all -- see below), compute a two-part rolling
    checksum (Tridgell/rsync's a/b sums, mod 65536, combined into one
    int key) and record the block's offset under that key in
    map[int, list[int]] (collisions -- different offsets sharing a
    checksum -- keep every offset; delta_diff verifies with a real byte
    comparison before ever trusting a hit, so a checksum collision can
    only cost a wasted comparison, never a wrong copy).
  - Scan the target left to right with the SAME rolling checksum over a
    sliding window, updated in O(1) per byte (add the entering byte,
    remove the leaving byte) rather than recomputed from scratch. A
    checksum hit is verified by comparing the full block, and on a
    verified match the run is extended byte-by-byte past the block
    boundary in both buffers to capture the longest possible copy (so
    two adjacent base blocks that also happen to be adjacent in the
    target merge into one COPY op instead of two). Bytes that never
    match anything accumulate into a pending literal run, flushed as an
    INSERT op whenever a copy interrupts it (or at end of input).
  - A base shorter than DELTA_BLOCK_SIZE() indexes no blocks, so
    delta_diff degenerates to a single INSERT covering the whole
    target. This is still a correct delta (round-trips exactly) --
    just not a compact one. Extending the index to also cover a final
    short partial block is a natural follow-up once something needs the
    extra compression on small bases.

Opcode wire format (the "delta" payload's body, after the chain header
below) -- binary, because INSERT literals are arbitrary target bytes
that may contain any byte value including NUL and '\n'. Length-prefixed
raw bytes rather than a delimiter, the same "declare the length, then
don't scan the payload for structure" trick cas.w's own object framing
and tree.w's tree-entry lines use:

	'C' <decimal offset> ' ' <decimal length> '\n'      # copy from base
	'I' <decimal length> '\n' <length raw bytes>          # literal insert

Opcodes run back-to-back with no count prefix and no terminator: the
CAS object's declared payload length (cas.w's own framing) is already
exact, so the decoder just stops when it reaches the end of the buffer.

CAS chain format (the full "delta"-typed object payload stored via
cas_put_raw) -- line-oriented header in the same spirit as commit.w's
format (parseable in one forward pass, field order fixed, blank line
ends the header), then the opcode stream verbatim to EOF:

	base <64-hex id of the base object, at whatever encoding IT uses>
	type <the reconstructed object's real CAS type tag, e.g. "blob">
	depth <decimal, this chain's length: 1 for a delta of a full
	       snapshot, base's depth + 1 otherwise>
	length <decimal, the reconstructed object's exact byte length>

	<opcode stream, verbatim to end of payload>

The "type" field is why cas_get alone cannot transparently resolve a
delta object: a stored delta's own CAS type tag is the constant
DELTA_OBJECT_TYPE() ("delta"), not the logical type (blob/tree/commit)
of the content it reconstructs to -- that real type lives inside the
payload instead. cas_get_resolved is the layered read that knows to
look there.

Bounded-depth chains + periodic snapshots (the revlog lesson,
version_control.md "Wave 3"): DELTA_MAX_CHAIN_DEPTH() = 16. Depth is
tracked per chain (the "depth" header field above) and enforced at
WRITE time by cas_put_delta: it reads the base's own depth (0 for a
plain/full object, its declared depth field for a delta object) and,
if base_depth + 1 would exceed the bound, stores a full snapshot
instead of another delta link -- silently resetting the chain to depth
0. Given every write goes through cas_put_delta, this alone guarantees
the invariant "no chain is longer than 16 hops" without any separate
snapshot scheduler: a period-16 full snapshot falls out of the bound
automatically, exactly like a revlog. cas_get_resolved does NOT trust
the stored depth fields when it reads (a corrupted or hand-crafted
store could claim anything, including a cycle): it walks with its own
hop budget starting at DELTA_MAX_CHAIN_DEPTH() and decrements once per
delta link resolved, independent of what the payload claims, so even a
self-referential or cyclic chain fails cleanly (DELTA_ERR_MALFORMED)
after at most 16 recursive steps instead of looping or overflowing the
stack.

Reserved type tag caveat (the one seam this module leans on cas.w's
existing API for, rather than adding new API surface to cas.w itself):
DELTA_OBJECT_TYPE() ("delta") is reserved by this module. cas_put_delta
refuses to encode an object whose OWN logical type is "delta" (-22),
and cas_get_resolved will try to parse ANY object stored under CAS type
"delta" as a chain -- including one a caller wrote directly with
cas_put(s, "delta", ...) for unrelated reasons -- and report
DELTA_ERR_MALFORMED if it does not parse as one. Callers sharing a
store with this module should avoid the "delta" type tag for anything
else, the same way tree.w/commit.w callers already treat "tree" and
"commit" as reserved by convention.

Error handling follows docs/error_results.txt: wresult[T]* carrying
negative errnos unchanged from cas_get/cas_put/cas_put_raw, -22
(EINVAL) for malformed arguments, and DELTA_ERR_MALFORMED (-74,
EBADMSG -- the same code cas.w's CAS_ERR_CORRUPT and commit.w's
COMMIT_ERR_MALFORMED use for "bytes that read back fine as a CAS object
but do not parse as the format layered on top") for a chain header that
does not match the grammar above, an opcode stream that does not
decode, a COPY op whose [offset, offset+length) range falls outside the
resolved base, or a reconstructed length that does not match the
chain's declared "length" field.

Nothing here enters the seed import graph (a libs/extras/vcs/ leaf,
same as cas.w/diff.w/dag.w/tree.w/commit.w).
*/
import lib.container
import lib.lib
import lib.path
import lib.result
import structures.string
import libs.extras.vcs.cas


/* Tunable constants */


int DELTA_BLOCK_SIZE():
	return 64


int DELTA_MAX_CHAIN_DEPTH():
	return 16


char* DELTA_OBJECT_TYPE():
	return c"delta"


# -74: Linux EBADMSG, shared with cas.w's CAS_ERR_CORRUPT and commit.w's
# COMMIT_ERR_MALFORMED for the same class of problem (see header comment).
int DELTA_ERR_MALFORMED():
	return -74


int DELTA_OP_COPY():
	return 0


int DELTA_OP_INSERT():
	return 1


/* Opcodes */


# One reconstruction step. COPY: `length` bytes from the base starting
# at `offset` (`literal` is 0). INSERT: `length` literal bytes owned by
# this op (`offset` is unused, always 0).
struct delta_op:
	int kind
	int offset
	int length
	char* literal


struct delta_ops:
	list[delta_op*] items


void delta_op_free(delta_op* op):
	if (op.literal != 0):
		free(op.literal)
	free(op)


void delta_ops_free(delta_ops* ops):
	for delta_op* op in ops.items:
		delta_op_free(op)
	list_free[delta_op*](ops.items)
	free(ops)


void delta_ops_push_insert(delta_ops* ops, char* bytes, int length):
	char* literal = malloc(length + 1)
	int i = 0
	while (i < length):
		literal[i] = bytes[i]
		i = i + 1
	literal[length] = 0
	delta_op* op = new delta_op
	op.kind = DELTA_OP_INSERT()
	op.offset = 0
	op.length = length
	op.literal = literal
	ops.items.push(op)


void delta_ops_push_copy(delta_ops* ops, int offset, int length):
	delta_op* op = new delta_op
	op.kind = DELTA_OP_COPY()
	op.offset = offset
	op.length = length
	op.literal = 0
	ops.items.push(op)


/* Rolling checksum (Tridgell/rsync a/b sums, mod 65536) */


int delta_window_sum_a(char* data, int start, int length):
	int a = 0
	int i = 0
	while (i < length):
		a = a + (data[start + i] & 255)
		i = i + 1
	return a & 65535


int delta_window_sum_b(char* data, int start, int length):
	int b = 0
	int i = 0
	while (i < length):
		b = b + ((length - i) * (data[start + i] & 255))
		i = i + 1
	return b & 65535


int delta_combine(int a, int b):
	return a | (b << 16)


int delta_bytes_equal(char* base, int base_off, char* target, int target_off, int length):
	int i = 0
	while (i < length):
		if (base[base_off + i] != target[target_off + i]):
			return 0
		i = i + 1
	return 1


/* Diff: base + target -> ops (pure, no CAS involvement) */


# Builds the block index: base-block-aligned checksum -> list of base
# offsets sharing it. Empty (no entries) when base_length < block size.
map[int, list[int]] delta_build_index(char* base, int base_length, int block):
	map[int, list[int]] table = new map[int, list[int]]
	if (base_length < block):
		return table
	int off = 0
	while ((off + block) <= base_length):
		int a = delta_window_sum_a(base, off, block)
		int b = delta_window_sum_b(base, off, block)
		int cs = delta_combine(a, b)
		if ((cs in table) == 0):
			table[cs] = new list[int]
		table[cs].push(off)
		off = off + block
	return table


void delta_free_index(map[int, list[int]] table):
	for int key in table:
		list_free[int](table[key])
	map_free[int, list[int]](table)


# Computes the copy/insert opcode stream that reconstructs `target` from
# `base` (delta_apply_ops(base, base_length, result) == target). Always
# succeeds and always round-trips, even when base_length or
# target_length is 0 -- an unindexable base just yields one big INSERT.
delta_ops* delta_diff(char* base, int base_length, char* target, int target_length):
	delta_ops* result = new delta_ops
	result.items = new list[delta_op*]

	int block = DELTA_BLOCK_SIZE()
	map[int, list[int]] table = delta_build_index(base, base_length, block)

	string_builder* pending = string_new()
	int i = 0
	int window_valid = 0
	int a = 0
	int b = 0

	while (i < target_length):
		if ((window_valid == 0) && ((i + block) <= target_length)):
			a = delta_window_sum_a(target, i, block)
			b = delta_window_sum_b(target, i, block)
			window_valid = 1

		int matched = 0
		int match_offset = 0
		int match_length = 0
		if (window_valid):
			int cs = delta_combine(a, b)
			if (cs in table):
				for int cand in table[cs]:
					if (delta_bytes_equal(base, cand, target, i, block)):
						int ext = block
						while (((cand + ext) < base_length) && ((i + ext) < target_length) && (base[cand + ext] == target[i + ext])):
							ext = ext + 1
						if (ext > match_length):
							match_length = ext
							match_offset = cand
							matched = 1

		if (matched):
			if (pending.length > 0):
				delta_ops_push_insert(result, pending.data, pending.length)
				string_clear(pending)
			delta_ops_push_copy(result, match_offset, match_length)
			i = i + match_length
			window_valid = 0
		else:
			int cur = target[i] & 255
			string_append_char(pending, cur)
			int next_valid = window_valid && ((i + 1 + block) <= target_length)
			if (next_valid):
				int leaving = cur
				int entering = target[i + block] & 255
				a = (a - leaving + entering) & 65535
				b = (b - (block * leaving) + a) & 65535
			window_valid = next_valid
			i = i + 1

	if (pending.length > 0):
		delta_ops_push_insert(result, pending.data, pending.length)
	string_free(pending)
	delta_free_index(table)
	return result


/* Opcode stream encode/decode */


string_builder* delta_encode_ops(delta_ops* ops):
	string_builder* s = string_new()
	for delta_op* op in ops.items:
		if (op.kind == DELTA_OP_COPY()):
			string_append_char(s, 'C')
			string_append_int(s, op.offset)
			string_append_char(s, ' ')
			string_append_int(s, op.length)
			string_append_char(s, 10)
		else:
			string_append_char(s, 'I')
			string_append_int(s, op.length)
			string_append_char(s, 10)
			string_append_bytes(s, op.literal, op.length)
	return s


int delta_find_char(char* data, int end, int start, int ch):
	int i = start
	while ((i < end) && (data[i] != ch)):
		i = i + 1
	return i


# True when data[start,end) is one or more decimal digits (no sign --
# every numeric field in this module's formats is a non-negative count).
int delta_valid_nonneg_integer(char* data, int start, int end):
	if (start >= end):
		return 0
	int i = start
	while (i < end):
		int c = data[i] & 255
		if ((c < '0') || (c > '9')):
			return 0
		i = i + 1
	return 1


# Parses the opcode stream (the CAS chain payload's body, after its
# header) back into a delta_ops list. DELTA_ERR_MALFORMED on any
# structural problem: unknown tag byte, a numeric field that is not
# pure decimal digits, a missing separator/newline before EOF, or an
# INSERT claiming more literal bytes than remain in the buffer.
wresult[delta_ops*]* delta_decode_ops(char* data, int length):
	delta_ops* ops = new delta_ops
	ops.items = new list[delta_op*]
	int i = 0
	while (i < length):
		int tag = data[i] & 255
		i = i + 1
		if (tag == 'C'):
			int off_start = i
			int off_end = delta_find_char(data, length, i, ' ')
			if ((off_end >= length) || (delta_valid_nonneg_integer(data, off_start, off_end) == 0)):
				delta_ops_free(ops)
				return result_new_error[delta_ops*](DELTA_ERR_MALFORMED())
			i = off_end + 1
			int len_start = i
			int len_end = delta_find_char(data, length, i, 10)
			if ((len_end >= length) || (delta_valid_nonneg_integer(data, len_start, len_end) == 0)):
				delta_ops_free(ops)
				return result_new_error[delta_ops*](DELTA_ERR_MALFORMED())
			char* off_str = path_clone_range(data + off_start, off_end - off_start)
			int offset = atoi(off_str)
			free(off_str)
			char* len_str = path_clone_range(data + len_start, len_end - len_start)
			int oplen = atoi(len_str)
			free(len_str)
			i = len_end + 1
			delta_ops_push_copy(ops, offset, oplen)
		else if (tag == 'I'):
			int len_start = i
			int len_end = delta_find_char(data, length, i, 10)
			if ((len_end >= length) || (delta_valid_nonneg_integer(data, len_start, len_end) == 0)):
				delta_ops_free(ops)
				return result_new_error[delta_ops*](DELTA_ERR_MALFORMED())
			char* len_str = path_clone_range(data + len_start, len_end - len_start)
			int oplen = atoi(len_str)
			free(len_str)
			i = len_end + 1
			if ((length - i) < oplen):
				delta_ops_free(ops)
				return result_new_error[delta_ops*](DELTA_ERR_MALFORMED())
			delta_ops_push_insert(ops, data + i, oplen)
			i = i + oplen
		else:
			delta_ops_free(ops)
			return result_new_error[delta_ops*](DELTA_ERR_MALFORMED())
	return result_new_ok[delta_ops*](ops)


/* Apply: base + ops -> reconstructed bytes (pure, no CAS involvement) */


struct delta_apply_result:
	char* data
	int length


void delta_apply_result_free(delta_apply_result* r):
	free(r.data)
	free(r)


# Reconstructs the target bytes from `base` and a decoded op list.
# DELTA_ERR_MALFORMED (not a crash) for a COPY op whose [offset,
# offset+length) range is not fully inside [0, base_length) -- the
# guard against a corrupted or adversarial delta referencing bytes that
# were never part of the base.
wresult[delta_apply_result*]* delta_apply_ops(char* base, int base_length, delta_ops* ops):
	string_builder* out = string_new()
	for delta_op* op in ops.items:
		if (op.kind == DELTA_OP_COPY()):
			int in_bounds = (op.offset >= 0) && (op.length >= 0) && (op.offset <= base_length) && (op.length <= (base_length - op.offset))
			if (in_bounds == 0):
				string_free(out)
				return result_new_error[delta_apply_result*](DELTA_ERR_MALFORMED())
			string_append_bytes(out, base + op.offset, op.length)
		else if (op.kind == DELTA_OP_INSERT()):
			int valid = (op.length >= 0) && ((op.length == 0) || (op.literal != 0))
			if (valid == 0):
				string_free(out)
				return result_new_error[delta_apply_result*](DELTA_ERR_MALFORMED())
			string_append_bytes(out, op.literal, op.length)
		else:
			string_free(out)
			return result_new_error[delta_apply_result*](DELTA_ERR_MALFORMED())
	delta_apply_result* r = new delta_apply_result
	r.data = out.data
	r.length = out.length
	free(out)
	return result_new_ok[delta_apply_result*](r)


# Convenience entry point matching the design doc's "an apply function
# reconstructing the target from base+delta": decodes an encoded opcode
# stream (delta_encode_ops's output, e.g. from delta_diff) and applies
# it in one call.
wresult[delta_apply_result*]* delta_apply(char* base, int base_length, char* delta_data, int delta_length):
	wresult[delta_ops*]* decoded = delta_decode_ops(delta_data, delta_length)
	if (result_is_error[delta_ops*](decoded)):
		int code = result_code[delta_ops*](decoded)
		result_free[delta_ops*](decoded)
		return result_new_error[delta_apply_result*](code)
	delta_ops* ops = result_value[delta_ops*](decoded)
	result_free[delta_ops*](decoded)
	wresult[delta_apply_result*]* applied = delta_apply_ops(base, base_length, ops)
	delta_ops_free(ops)
	return applied


/* CAS chain format: base id + logical type + depth + length + opcode stream */


struct delta_chain:
	char* base_id
	char* logical_type
	int depth
	int target_length
	delta_ops* ops


void delta_chain_free(delta_chain* c):
	free(c.base_id)
	free(c.logical_type)
	delta_ops_free(c.ops)
	free(c)


string_builder* delta_encode_chain(char* base_id, char* logical_type, int depth, int target_length, delta_ops* ops):
	string_builder* s = string_new()
	string_append(s, c"base ")
	string_append(s, base_id)
	string_append_char(s, 10)
	string_append(s, c"type ")
	string_append(s, logical_type)
	string_append_char(s, 10)
	string_append(s, c"depth ")
	string_append_int(s, depth)
	string_append_char(s, 10)
	string_append(s, c"length ")
	string_append_int(s, target_length)
	string_append_char(s, 10)
	string_append_char(s, 10)
	string_builder* opcodes = delta_encode_ops(ops)
	string_append_bytes(s, opcodes.data, opcodes.length)
	string_free(opcodes)
	return s


# True when data[offset .. offset+strlen(prefix)) equals prefix, without
# reading past `length` (mirrors commit.w's commit_starts_with).
int delta_starts_with(char* data, int length, int offset, char* prefix):
	int n = strlen(prefix)
	if ((offset + n) > length):
		return 0
	int i = 0
	while (i < n):
		if (data[offset + i] != prefix[i]):
			return 0
		i = i + 1
	return 1


int delta_valid_hex_slice(char* data, int start, int end):
	if ((end - start) != 64):
		return 0
	char* slice = path_clone_range(data + start, end - start)
	int ok = cas_valid_id(slice)
	free(slice)
	return ok


struct delta_chain_layout:
	int valid
	int base_start
	int base_end
	int type_start
	int type_end
	int depth_start
	int depth_end
	int length_start
	int length_end
	int body_start


# One forward pass locating every header field, exactly commit.w's
# commit_scan/commit_parse split: nothing is extracted or allocated
# until the whole header is already known to be well-formed.
delta_chain_layout* delta_scan_chain(char* data, int length):
	delta_chain_layout* lay = new delta_chain_layout
	lay.valid = 0

	int pos = 0
	if (delta_starts_with(data, length, pos, c"base ") == 0):
		return lay
	pos = pos + strlen(c"base ")
	int base_end = delta_find_char(data, length, pos, 10)
	if ((base_end >= length) || (delta_valid_hex_slice(data, pos, base_end) == 0)):
		return lay
	lay.base_start = pos
	lay.base_end = base_end
	pos = base_end + 1

	if (delta_starts_with(data, length, pos, c"type ") == 0):
		return lay
	pos = pos + strlen(c"type ")
	int type_end = delta_find_char(data, length, pos, 10)
	if (type_end >= length):
		return lay
	lay.type_start = pos
	lay.type_end = type_end
	pos = type_end + 1

	if (delta_starts_with(data, length, pos, c"depth ") == 0):
		return lay
	pos = pos + strlen(c"depth ")
	int depth_end = delta_find_char(data, length, pos, 10)
	if ((depth_end >= length) || (delta_valid_nonneg_integer(data, pos, depth_end) == 0)):
		return lay
	lay.depth_start = pos
	lay.depth_end = depth_end
	pos = depth_end + 1

	if (delta_starts_with(data, length, pos, c"length ") == 0):
		return lay
	pos = pos + strlen(c"length ")
	int length_end = delta_find_char(data, length, pos, 10)
	if ((length_end >= length) || (delta_valid_nonneg_integer(data, pos, length_end) == 0)):
		return lay
	lay.length_start = pos
	lay.length_end = length_end
	pos = length_end + 1

	if ((pos >= length) || (data[pos] != 10)):
		return lay
	pos = pos + 1

	lay.body_start = pos
	lay.valid = 1
	return lay


wresult[delta_chain*]* delta_decode_chain(char* data, int length):
	delta_chain_layout* lay = delta_scan_chain(data, length)
	if (lay.valid == 0):
		free(lay)
		return result_new_error[delta_chain*](DELTA_ERR_MALFORMED())

	char* type_str = path_clone_range(data + lay.type_start, lay.type_end - lay.type_start)
	if (cas_valid_tag(type_str) == 0):
		free(type_str)
		free(lay)
		return result_new_error[delta_chain*](DELTA_ERR_MALFORMED())

	wresult[delta_ops*]* ops_r = delta_decode_ops(data + lay.body_start, length - lay.body_start)
	if (result_is_error[delta_ops*](ops_r)):
		int code = result_code[delta_ops*](ops_r)
		result_free[delta_ops*](ops_r)
		free(type_str)
		free(lay)
		return result_new_error[delta_chain*](code)

	delta_chain* chain = new delta_chain
	chain.base_id = path_clone_range(data + lay.base_start, lay.base_end - lay.base_start)
	chain.logical_type = type_str
	char* depth_str = path_clone_range(data + lay.depth_start, lay.depth_end - lay.depth_start)
	chain.depth = atoi(depth_str)
	free(depth_str)
	char* len_str = path_clone_range(data + lay.length_start, lay.length_end - lay.length_start)
	chain.target_length = atoi(len_str)
	free(len_str)
	chain.ops = result_value[delta_ops*](ops_r)
	result_free[delta_ops*](ops_r)
	free(lay)
	return result_new_ok[delta_chain*](chain)


/* CAS integration: cas_get_resolved / cas_put_delta */


# Recursive walk with an explicit hop budget, decremented once per delta
# link actually resolved -- independent of any depth field the payload
# claims, so a corrupted or cyclic chain (including a self-referential
# base id) fails cleanly with DELTA_ERR_MALFORMED after at most
# DELTA_MAX_CHAIN_DEPTH() steps rather than recursing without bound.
wresult[wcas_object*]* delta_resolve(wcas* s, char* id, int hops_remaining):
	wresult[wcas_object*]* got = cas_get(s, id)
	if (result_is_error[wcas_object*](got)):
		return got
	wcas_object* obj = result_value[wcas_object*](got)
	if (strcmp(obj.object_type, DELTA_OBJECT_TYPE()) != 0):
		return got

	if (hops_remaining <= 0):
		cas_object_free(obj)
		result_free[wcas_object*](got)
		return result_new_error[wcas_object*](DELTA_ERR_MALFORMED())
	result_free[wcas_object*](got)

	wresult[delta_chain*]* chain_r = delta_decode_chain(obj.data, obj.length)
	cas_object_free(obj)
	if (result_is_error[delta_chain*](chain_r)):
		int code = result_code[delta_chain*](chain_r)
		result_free[delta_chain*](chain_r)
		return result_new_error[wcas_object*](code)
	delta_chain* chain = result_value[delta_chain*](chain_r)
	result_free[delta_chain*](chain_r)

	wresult[wcas_object*]* base_r = delta_resolve(s, chain.base_id, hops_remaining - 1)
	if (result_is_error[wcas_object*](base_r)):
		delta_chain_free(chain)
		return base_r
	wcas_object* base_obj = result_value[wcas_object*](base_r)
	result_free[wcas_object*](base_r)

	wresult[delta_apply_result*]* applied = delta_apply_ops(base_obj.data, base_obj.length, chain.ops)
	cas_object_free(base_obj)
	if (result_is_error[delta_apply_result*](applied)):
		int code = result_code[delta_apply_result*](applied)
		result_free[delta_apply_result*](applied)
		delta_chain_free(chain)
		return result_new_error[wcas_object*](code)
	delta_apply_result* ar = result_value[delta_apply_result*](applied)
	result_free[delta_apply_result*](applied)

	int mismatch = ar.length != chain.target_length
	wcas_object* resolved = 0
	if (mismatch):
		delta_apply_result_free(ar)
	else:
		resolved = new wcas_object
		resolved.object_type = strclone(chain.logical_type)
		resolved.data = ar.data
		resolved.length = ar.length
		free(ar)
	delta_chain_free(chain)
	if (mismatch):
		return result_new_error[wcas_object*](DELTA_ERR_MALFORMED())
	return result_new_ok[wcas_object*](resolved)


# Layered read: like cas_get, but transparently walks and reconstructs a
# delta-encoded object (or any chain of them) into the same shape a full
# cas_put would have produced -- object_type is the reconstructed
# object's real logical type, data/length are its full content. A plain
# (non-delta) object passes through with no extra cost beyond the one
# cas_get needed to discover that. Errors: cas_get's (-22 malformed id,
# the open errno for a missing object, CAS_ERR_CORRUPT for broken CAS
# framing at any point in the chain) pass through unchanged;
# DELTA_ERR_MALFORMED additionally covers a malformed chain header, an
# opcode stream that does not decode, an out-of-bounds COPY, a
# reconstructed-length mismatch, or a chain deeper than
# DELTA_MAX_CHAIN_DEPTH() hops (including cycles).
wresult[wcas_object*]* cas_get_resolved(wcas* s, char* id):
	return delta_resolve(s, id, DELTA_MAX_CHAIN_DEPTH())


# Stores `data` (of CAS type `logical_type`) as a delta against the
# object already stored under `base_id`, OR as a full snapshot when
# that would make the chain exceed DELTA_MAX_CHAIN_DEPTH() -- the
# "periodic full snapshot" half of the design, enforced automatically
# rather than scheduled separately (see header comment). Either way the
# returned id is exactly cas_id_hex(logical_type, data, length): the
# same id cas_put(s, logical_type, data, length) would have produced,
# so storage encoding never changes an object's identity.
#
# Errors: -22 for an invalid base_id/logical_type/length, or for
# logical_type == DELTA_OBJECT_TYPE() (reserved -- see header comment);
# otherwise whatever cas_get/cas_get_resolved/cas_put/cas_put_raw report
# for the base lookup or the final write.
wresult[char*]* cas_put_delta(wcas* s, char* base_id, char* logical_type, char* data, int length):
	if ((cas_valid_id(base_id) == 0) || (cas_valid_tag(logical_type) == 0) || (length < 0)):
		return result_new_error[char*](-22)
	if ((data == 0) && (length != 0)):
		return result_new_error[char*](-22)
	if (strcmp(logical_type, DELTA_OBJECT_TYPE()) == 0):
		return result_new_error[char*](-22)

	wresult[wcas_object*]* braw = cas_get(s, base_id)
	if (result_is_error[wcas_object*](braw)):
		int code = result_code[wcas_object*](braw)
		result_free[wcas_object*](braw)
		return result_new_error[char*](code)
	wcas_object* braw_obj = result_value[wcas_object*](braw)
	result_free[wcas_object*](braw)

	int base_depth = 0
	if (strcmp(braw_obj.object_type, DELTA_OBJECT_TYPE()) == 0):
		wresult[delta_chain*]* peek = delta_decode_chain(braw_obj.data, braw_obj.length)
		if (result_is_error[delta_chain*](peek)):
			int code = result_code[delta_chain*](peek)
			result_free[delta_chain*](peek)
			cas_object_free(braw_obj)
			return result_new_error[char*](code)
		delta_chain* pc = result_value[delta_chain*](peek)
		result_free[delta_chain*](peek)
		base_depth = pc.depth
		delta_chain_free(pc)
	cas_object_free(braw_obj)

	int new_depth = base_depth + 1
	if (new_depth > DELTA_MAX_CHAIN_DEPTH()):
		return cas_put(s, logical_type, data, length)

	wresult[wcas_object*]* bres = cas_get_resolved(s, base_id)
	if (result_is_error[wcas_object*](bres)):
		int code = result_code[wcas_object*](bres)
		result_free[wcas_object*](bres)
		return result_new_error[char*](code)
	wcas_object* base_obj = result_value[wcas_object*](bres)
	result_free[wcas_object*](bres)

	delta_ops* ops = delta_diff(base_obj.data, base_obj.length, data, length)
	cas_object_free(base_obj)

	string_builder* payload = delta_encode_chain(base_id, logical_type, new_depth, length, ops)
	delta_ops_free(ops)

	char* id = cas_id_hex(logical_type, data, length)
	if (id == 0):
		string_free(payload)
		return result_new_error[char*](-22)

	wresult[char*]* put = cas_put_raw(s, id, DELTA_OBJECT_TYPE(), payload.data, payload.length)
	string_free(payload)
	free(id)
	return put
