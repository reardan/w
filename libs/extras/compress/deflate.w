/*
libs/extras/compress/deflate.w: stage 2a of docs/projects/compress.md §3
-- a stored-blocks-only DEFLATE compressor. Zero compression ratio, but a
fully spec-conformant stream: `BFINAL=1, BTYPE=00` blocks (chained when
input exceeds 65535 bytes, `LEN`'s field width), which round-trip through
inflate.w and satisfy every consumer's *correctness* bar -- a VCS object
store or an HTTP client doesn't care whether the bytes are smaller, only
that the format is right (§3, stage 2a). Real compression (fixed Huffman
+ LZ77, stage 2b) is deliberately out of scope for this PR; see the
design doc §9's staging.

Stored blocks need no bit-level accumulator at all: BTYPE=00 means both
BTYPE bits are 0, so the entire 3-bit block header (BFINAL, BTYPE, BTYPE)
collapses to a single byte whose only possibly-set bit is bit 0
(BFINAL) -- the general "pack a few bits then pad to a byte boundary"
machinery inflate.w needs for decoding is simply unnecessary for
encoding this one block type.
*/
import lib.memory
import structures.string


int DEFLATE_LEVEL_STORED():
	return 0


# Not yet implemented (stage 2b / stage 3 respectively -- design doc §9);
# deflate() below ignores `level` entirely and always emits stored
# blocks until DEFLATE_LEVEL_FAST lands. The symbols exist now so callers
# can already spell the level they want and get more compression for
# free once it exists, matching DEFLATE_LEVEL_BEST's own "ship the symbol,
# grow the behavior" precedent in the design doc §5.3.
int DEFLATE_LEVEL_FAST():
	return 1


int DEFLATE_LEVEL_BEST():
	return 2


struct deflate_result:
	char* data
	int length


void deflate_result_free(deflate_result* r):
	free(r.data)
	free(r)


# Appends one BTYPE=00 block covering `len` bytes at data+offset.
void deflate_emit_stored_block(string_builder* out, char* data, int offset, int len, int is_final):
	string_append_char(out, is_final & 1)
	string_append_char(out, len & 255)
	string_append_char(out, shr(len, 8) & 255)
	int nlen = (len ^ 65535) & 65535
	string_append_char(out, nlen & 255)
	string_append_char(out, shr(nlen, 8) & 255)
	string_append_bytes(out, data + offset, len)


# Encodes `length` bytes at `data` as one or more stored DEFLATE blocks.
# `level` is accepted for forward API compatibility with stage 2b/3 but
# not yet honored -- see DEFLATE_LEVEL_FAST's comment above. A negative
# length is treated as zero, matching libs/standard/crypto/base64.w's
# convention; encoding trusted, caller-owned bytes cannot otherwise fail
# (docs/projects/compress.md §5.5), so this returns a plain value, never
# a wresult[T]*.
deflate_result* deflate(char* data, int length, int level):
	if (length < 0):
		length = 0
	string_builder* out = string_new()
	int max_chunk = 65535
	if (length == 0):
		# A decoder must see at least one BFINAL=1 block, so the empty
		# input still produces one (empty) stored block.
		deflate_emit_stored_block(out, data, 0, 0, 1)
	int pos = 0
	while (pos < length):
		int remaining = length - pos
		int chunk = remaining
		if (chunk > max_chunk):
			chunk = max_chunk
		int is_final = 0
		if (pos + chunk == length):
			is_final = 1
		deflate_emit_stored_block(out, data, pos, chunk, is_final)
		pos = pos + chunk
	char* out_data = out.data
	int out_length = out.length
	free(out)
	deflate_result* r = new deflate_result
	r.data = out_data
	r.length = out_length
	return r
