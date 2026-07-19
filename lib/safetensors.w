/*
lib.safetensors: read/write the safetensors tensor file format
(https://github.com/huggingface/safetensors#format) against lib.ndarray's
ndf (float32, rank 1..4). Pure CPU: this module deliberately does not
import lib.cuda or lib.tensor, so a program that only wants weight I/O
never pays lib.cuda's eager libcuda.so.1 load-time dependency
(docs/projects/torch.md Stage 6). GPU upload is a separate step through
the existing tensor_from_ndf once a tensor has been loaded here as an
ndf.

File layout (little-endian, matching every W target's host byte order,
so the F32 payload is a verbatim byte copy with no per-element
conversion):

    [8 bytes: u64 header length N]
    [N bytes: JSON header, optionally padded with trailing spaces]
    [rest: raw tensor data, contiguous, at the byte offsets the header names]

The header is a JSON object mapping tensor name -> {"dtype", "shape",
"data_offsets"}, plus an optional "__metadata__" string->string entry
that this reader skips per the spec. Reuses structures/json.w for the
header and lib/ndarray.w for the tensor payload.

Only F32 is implemented on either side: st_add takes an ndf* (always
float32 by construction), and st_load rejects every other dtype
(including F16 -- reported as unsupported, not silently reinterpreted).

Ownership: st_add's ndf argument is copied as a struct value, which
aliases the caller's backing buffer (slice semantics, same as
lib.ndarray's ndf_wrapN) -- st_free does not free it, and that buffer
must outlive st_save. st_load allocates a fresh buffer per tensor
(ndf_newN) and st_free does free those. An st_file may mix both kinds of
entries; each remembers whether it owns its buffer.
*/
import lib.lib
import lib.assert
import lib.ndarray
import lib.stream
import lib.container
import structures.string
import structures.json


struct st_tensor:
	char* name
	ndf t
	int owned    # 1: st_free frees t.data.data (loaded by st_load); 0: t.data aliases a caller buffer added via st_add


struct st_file:
	list[st_tensor*] tensors        # file/insertion order -- also the on-disk data_offsets order when saved
	map[char*, st_tensor*] by_name


st_file* st_new():
	st_file* f = new st_file()
	f.tensors = new list[st_tensor*]
	f.by_name = new map[char*, st_tensor*]
	return f


# Shared by st_add and the loader: registers a fully-built entry, fatally
# asserting names stay unique -- a builder or file that repeats a name is
# a programmer/data error the caller is not expected to recover from
# (ndf_assert_same_shape-style precedent in lib/ndarray.w). Takes
# ownership of `name` (must already be a fresh allocation).
void st_insert(st_file* f, char* name, ndf t, int owned):
	asserts(c"safetensors: duplicate tensor name", (name in f.by_name) == 0)
	st_tensor* entry = new st_tensor()
	entry.name = name
	entry.t = t
	entry.owned = owned
	f.tensors.push(entry)
	f.by_name[name] = entry


# Adds an F32 tensor to a file being built for st_save. Copies the ndf
# descriptor (shape/strides/slice header), not the data -- t's backing
# buffer must stay alive until st_save runs.
void st_add(st_file* f, char* name, ndf* t):
	asserts(c"st_add: tensor rank must be 1..4", t.rank >= 1 && t.rank <= 4)
	st_insert(f, strclone(name), *t, 0)


int st_count(st_file* f):
	return f.tensors.length


# Name at file/insertion order index i -- pairs with st_count for
# iteration, matching the json_array_get/json_array_length convention.
char* st_name_at(st_file* f, int i):
	asserts(c"st_name_at: index out of range", i >= 0 && i < f.tensors.length)
	return f.tensors[i].name


int st_has(st_file* f, char* name):
	return name in f.by_name


ndf* st_get(st_file* f, char* name):
	st_tensor* entry = f.by_name.get(name, 0)
	if (entry == 0):
		return 0
	return &entry.t


void st_free(st_file* f):
	int i = 0
	while (i < f.tensors.length):
		st_tensor* entry = f.tensors[i]
		if (entry.owned):
			free(entry.t.data.data)
		free(entry.name)
		free(entry)
		i = i + 1
	list_free[st_tensor*](f.tensors)
	map_free[char*, st_tensor*](f.by_name)
	free(f)


##################################### save #####################################


# Writes the 8-byte little-endian u64 header length. Header sizes never
# approach 2^32, so the high 4 bytes are always 0; the low bytes are
# assembled with masking, matching lib/sha256.w's byte-write precedent.
void st_write_u64_header_len(char* out, int n):
	out[0] = n & 255
	out[1] = (n >> 8) & 255
	out[2] = (n >> 16) & 255
	out[3] = (n >> 24) & 255
	out[4] = 0
	out[5] = 0
	out[6] = 0
	out[7] = 0


int st_shape_dim(ndf* t, int axis):
	if (axis == 0):
		return t.n0
	if (axis == 1):
		return t.n1
	if (axis == 2):
		return t.n2
	return t.n3


json_value* st_shape_json(ndf* t):
	json_value* shape = json_array()
	int i = 0
	while (i < t.rank):
		json_array_push(shape, json_int(st_shape_dim(t, i)))
		i = i + 1
	return shape


json_value* st_meta_json(ndf* t, int begin, int end):
	json_value* meta = json_object()
	json_object_set(meta, c"dtype", json_string(c"F32"))
	json_object_set(meta, c"shape", st_shape_json(t))
	json_value* offsets = json_array()
	json_array_push(offsets, json_int(begin))
	json_array_push(offsets, json_int(end))
	json_object_set(meta, c"data_offsets", offsets)
	return meta


# Writes a safetensors file for every tensor in f, in insertion order,
# packed contiguously starting at byte 0 (matching each tensor's
# advertised data_offsets). Returns 1 on success, 0 when the file cannot
# be opened for writing.
int st_save(char* path, st_file* f):
	json_value* header = json_object()
	int offset = 0
	int i = 0
	while (i < f.tensors.length):
		st_tensor* entry = f.tensors[i]
		ndf* t = &entry.t
		int nbytes = t.data.length * 4
		json_object_set(header, entry.name, st_meta_json(t, offset, offset + nbytes))
		offset = offset + nbytes
		i = i + 1

	char* header_json = json_stringify(header)
	json_free(header)

	int n = strlen(header_json)
	int rem = (8 + n) % 8
	int pad = 0
	if (rem != 0):
		pad = 8 - rem

	wstream* out = stream_open_write(path)
	if (out == 0):
		free(header_json)
		return 0

	char[8] len_bytes
	st_write_u64_header_len(len_bytes, n + pad)
	stream_write(out, len_bytes, 8)
	stream_write(out, header_json, n)
	i = 0
	while (i < pad):
		stream_write_byte(out, ' ')
		i = i + 1
	free(header_json)

	i = 0
	while (i < f.tensors.length):
		st_tensor* entry = f.tensors[i]
		ndf* t = &entry.t
		stream_write(out, cast(char*, t.data.data), t.data.length * 4)
		i = i + 1

	stream_close(out)
	return 1


##################################### load #####################################


void st_copy_bytes(char* dst, char* src, int n):
	int i = 0
	while (i < n):
		dst[i] = src[i]
		i = i + 1


# Assembles the little-endian u64 header length from raw bytes, masking
# each byte per lib/sha256.w precedent. Returns -1 (never a valid
# length) when the value does not fit: bytes 4..7 nonzero means the
# header claims to be > 4 GiB, which no real file approaches; on a
# 32-bit target (int is 32 bits, __word_size__ == 4) a low32 value in
# 2^31..2^32-1 additionally can't be represented as a native (signed)
# int, so that range is rejected there too instead of silently wrapping
# negative. On a 64-bit target the same low32 bit pattern is always a
# small positive int64, so no equivalent check is needed there.
int st_read_header_len(char* b):
	if (((b[4] & 255) != 0) || ((b[5] & 255) != 0) || ((b[6] & 255) != 0) || ((b[7] & 255) != 0)):
		return -1
	int lo = (b[0] & 255) | ((b[1] & 255) << 8) | ((b[2] & 255) << 16) | ((b[3] & 255) << 24)
	if ((__word_size__ == 4) && (lo < 0)):
		return -1
	return lo


int st_ranges_overlap(int a0, int a1, int b0, int b1):
	return (a0 < b1) && (b0 < a1)


# A generous cap well beyond any real header (thousands of tensors'
# names/shapes/offsets still fit in low single-digit MiB of JSON) --
# guards the header malloc below against a corrupt or hostile file that
# passes st_read_header_len's platform-width check (so is < 2^31, or
# < 2^32 on x64) but names a multi-GiB header the actual file could
# never truncate-detect its way out of cheaply.
int st_max_header_len():
	return 64 * 1024 * 1024


ndf st_ndf_new(int rank, int n0, int n1, int n2, int n3):
	if (rank == 1):
		return ndf_new1(n0)
	if (rank == 2):
		return ndf_new2(n0, n1)
	if (rank == 3):
		return ndf_new3(n0, n1, n2)
	return ndf_new4(n0, n1, n2, n3)


# Validates and materializes one tensor entry from the parsed header,
# inserting it into f on success. Returns 1 on success, 0 on any spec
# violation -- each check reports its own distinct message naming the
# offending tensor, per the format's data_offsets/shape/dtype fields.
int st_load_tensor(st_file* f, char* name, json_value* meta, string_builder* data, list[int] used_begin, list[int] used_end):
	if (meta.type != json_type_object()):
		println2(f"safetensors: tensor '{name}' metadata must be a JSON object")
		return 0

	json_value* dtype_v = json_object_get(meta, c"dtype")
	if ((dtype_v == 0) || (dtype_v.type != json_type_string())):
		println2(f"safetensors: tensor '{name}' missing or invalid 'dtype'")
		return 0
	if (strcmp(dtype_v.string_value, c"F32") != 0):
		println2(f"safetensors: tensor '{name}' has unsupported dtype '{dtype_v.string_value}' (only F32 is supported)")
		return 0

	json_value* shape_v = json_object_get(meta, c"shape")
	if ((shape_v == 0) || (shape_v.type != json_type_array())):
		println2(f"safetensors: tensor '{name}' missing or invalid 'shape'")
		return 0
	int rank = json_array_length(shape_v)
	if (rank == 0):
		println2(f"safetensors: tensor '{name}' has rank 0, unsupported (ndf requires rank 1..4)")
		return 0
	if (rank > 4):
		println2(f"safetensors: tensor '{name}' has rank {rank}, unsupported (ndf limit is 4)")
		return 0

	int n0 = 1
	int n1 = 1
	int n2 = 1
	int n3 = 1
	int elements = 1
	int j = 0
	while (j < rank):
		json_value* d = json_array_get(shape_v, j)
		if ((d.type != json_type_int()) || (d.int_value <= 0)):
			println2(f"safetensors: tensor '{name}' has a non-positive or non-integer shape dimension")
			return 0
		elements = elements * d.int_value
		if (j == 0):
			n0 = d.int_value
		else if (j == 1):
			n1 = d.int_value
		else if (j == 2):
			n2 = d.int_value
		else:
			n3 = d.int_value
		j = j + 1

	json_value* offsets_v = json_object_get(meta, c"data_offsets")
	if ((offsets_v == 0) || (offsets_v.type != json_type_array()) || (json_array_length(offsets_v) != 2)):
		println2(f"safetensors: tensor '{name}' missing or invalid 'data_offsets'")
		return 0
	json_value* begin_v = json_array_get(offsets_v, 0)
	json_value* end_v = json_array_get(offsets_v, 1)
	if ((begin_v.type != json_type_int()) || (end_v.type != json_type_int())):
		println2(f"safetensors: tensor '{name}' data_offsets must be integers")
		return 0
	int begin = begin_v.int_value
	int end = end_v.int_value
	if ((begin < 0) || (end < begin) || (end > data.length)):
		println2(f"safetensors: tensor '{name}' data_offsets out of range of the data buffer")
		return 0
	if ((end - begin) != (elements * 4)):
		println2(f"safetensors: tensor '{name}' data_offsets size does not match its shape")
		return 0

	int k = 0
	while (k < used_begin.length):
		if (st_ranges_overlap(begin, end, used_begin[k], used_end[k])):
			println2(f"safetensors: tensor '{name}' data_offsets overlaps another tensor's data")
			return 0
		k = k + 1
	used_begin.push(begin)
	used_end.push(end)

	ndf t = st_ndf_new(rank, n0, n1, n2, n3)
	st_copy_bytes(cast(char*, t.data.data), data.data + begin, end - begin)
	st_insert(f, strclone(name), t, 1)
	return 1


# Reads a safetensors file. Returns 0 (after printing a message on
# stderr naming the specific violation) for anything malformed: too
# short, a header length that overruns the file or does not fit a
# native int, invalid or non-object JSON, a non-F32 dtype, an
# out-of-range rank, or data_offsets inconsistent with the shape or the
# data buffer (including overlaps between tensors). "__metadata__" is
# skipped per the spec, whatever shape its value takes.
st_file* st_load(char* path):
	wstream* in = stream_open_read(path)
	if (in == 0):
		println2(f"safetensors: cannot open '{path}'")
		return 0

	char[8] len_bytes
	if (stream_read(in, len_bytes, 8) < 8):
		println2(c"safetensors: file too short to contain a header length")
		stream_close(in)
		return 0

	int header_len = st_read_header_len(len_bytes)
	if (header_len < 0):
		println2(c"safetensors: header length is too large to be a valid safetensors file")
		stream_close(in)
		return 0
	if (header_len > st_max_header_len()):
		println2(c"safetensors: header length exceeds the supported maximum (64 MiB)")
		stream_close(in)
		return 0

	char* header_buf = malloc(header_len + 1)
	if (stream_read(in, header_buf, header_len) < header_len):
		println2(c"safetensors: file truncated before the end of the header")
		free(header_buf)
		stream_close(in)
		return 0
	header_buf[header_len] = 0

	json_value* header = json_parse(header_buf)
	free(header_buf)
	if (header == 0):
		println2(c"safetensors: header is not valid JSON")
		stream_close(in)
		return 0
	if (header.type != json_type_object()):
		println2(c"safetensors: header must be a JSON object")
		json_free(header)
		stream_close(in)
		return 0

	string_builder* data = string_new()
	stream_read_all(in, data)
	stream_close(in)

	st_file* f = st_new()
	list[int] used_begin = new list[int]
	list[int] used_end = new list[int]
	int ok = 1
	for char* name, json_value* meta in header.object_values:
		if (ok):
			if (strcmp(name, c"__metadata__") != 0):
				if (st_load_tensor(f, name, meta, data, used_begin, used_end) == 0):
					ok = 0

	list_free[int](used_begin)
	list_free[int](used_end)
	json_free(header)
	string_free(data)

	if (ok == 0):
		st_free(f)
		return 0
	return f
