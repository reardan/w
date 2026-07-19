# wbuild: x64
import lib.testing
import lib.format
import lib.ndarray
import lib.safetensors
import lib.stream
import lib.fmath
import structures.string


void assert_feq(float want, float got):
	if (want != got):
		print2(c"Assertion failed: wanted float ")
		print2(ftoa(want))
		print2(c" got ")
		println2(ftoa(got))
		print_stack_trace()
		exit(1)


# Little-endian float32 bytes, matching every W target's host order --
# the same byte-for-byte encoding lib/safetensors.w itself writes.
void put_f32_le(char* p, float v):
	int bits = float_bits(v)
	p[0] = bits & 255
	p[1] = (bits >> 8) & 255
	p[2] = (bits >> 16) & 255
	p[3] = (bits >> 24) & 255


# Writes a raw safetensors-shaped file with independently-controlled
# claimed vs. actual header length, for the malformed-input tests below
# (a real writer's claimed length always matches; a hostile/corrupt file
# need not).
void write_raw_file(char* path, int header_len_claim, char* header_text, int header_actual_len, char* data, int data_len):
	wstream* out = stream_open_write(path)
	assert1(out != 0)
	char[8] len_bytes
	st_write_u64_header_len(len_bytes, header_len_claim)
	stream_write(out, len_bytes, 8)
	if (header_actual_len > 0):
		stream_write(out, header_text, header_actual_len)
	if (data_len > 0):
		stream_write(out, data, data_len)
	stream_close(out)


############################### 1. round trip ###############################


void test_round_trip():
	ndf vec = ndf_new1(3)
	ndf_set1(&vec, 0, 1.5)
	ndf_set1(&vec, 1, -2.25)
	ndf_set1(&vec, 2, 100.0)

	ndf mat = ndf_new2(2, 3)
	ndf_set2(&mat, 0, 0, 1.0)
	ndf_set2(&mat, 0, 1, 2.0)
	ndf_set2(&mat, 0, 2, 3.0)
	ndf_set2(&mat, 1, 0, 4.0)
	ndf_set2(&mat, 1, 1, 5.0)
	ndf_set2(&mat, 1, 2, 6.0)

	ndf cube = ndf_new3(2, 2, 2)
	ndf_set3(&cube, 0, 0, 0, 0.5)
	ndf_set3(&cube, 1, 1, 1, -0.5)
	ndf_set3(&cube, 0, 1, 0, 42.0)
	ndf_set3(&cube, 1, 0, 1, -17.0)

	st_file* out = st_new()
	st_add(out, c"vec", &vec)
	st_add(out, c"mat", &mat)
	st_add(out, c"cube", &cube)
	assert_equal(3, st_count(out))
	assert_equal(1, st_save(c"bin/safetensors_round_trip.safetensors", out))
	st_free(out)

	st_file* loaded = st_load(c"bin/safetensors_round_trip.safetensors")
	assert1(loaded != 0)
	assert_equal(3, st_count(loaded))

	# name listing preserves file/insertion order
	assert_strings_equal(c"vec", st_name_at(loaded, 0))
	assert_strings_equal(c"mat", st_name_at(loaded, 1))
	assert_strings_equal(c"cube", st_name_at(loaded, 2))

	ndf* lvec = st_get(loaded, c"vec")
	assert1(lvec != 0)
	assert_equal(1, lvec.rank)
	assert_equal(3, lvec.n0)
	assert_feq(1.5, ndf_at1(lvec, 0))
	assert_feq(-2.25, ndf_at1(lvec, 1))
	assert_feq(100.0, ndf_at1(lvec, 2))

	ndf* lmat = st_get(loaded, c"mat")
	assert1(lmat != 0)
	assert_equal(2, lmat.rank)
	assert_equal(2, lmat.n0)
	assert_equal(3, lmat.n1)
	assert_feq(1.0, ndf_at2(lmat, 0, 0))
	assert_feq(2.0, ndf_at2(lmat, 0, 1))
	assert_feq(3.0, ndf_at2(lmat, 0, 2))
	assert_feq(4.0, ndf_at2(lmat, 1, 0))
	assert_feq(5.0, ndf_at2(lmat, 1, 1))
	assert_feq(6.0, ndf_at2(lmat, 1, 2))

	ndf* lcube = st_get(loaded, c"cube")
	assert1(lcube != 0)
	assert_equal(3, lcube.rank)
	assert_equal(2, lcube.n0)
	assert_equal(2, lcube.n1)
	assert_equal(2, lcube.n2)
	assert_feq(0.5, ndf_at3(lcube, 0, 0, 0))
	assert_feq(-0.5, ndf_at3(lcube, 1, 1, 1))
	assert_feq(42.0, ndf_at3(lcube, 0, 1, 0))
	assert_feq(-17.0, ndf_at3(lcube, 1, 0, 1))

	assert1(st_get(loaded, c"missing") == 0)
	assert_equal(1, st_has(loaded, c"vec"))
	assert_equal(0, st_has(loaded, c"missing"))

	st_free(loaded)


######################## 2. byte-level golden check ########################
#
# Hand-assembled per the spec (not via st_save), so this pins the file
# format itself rather than round-tripping against our own writer.


void test_golden_file_matches_spec():
	char* header = c"{\"w\":{\"dtype\":\"F32\",\"shape\":[2],\"data_offsets\":[0,8]}}"
	int n = strlen(header)
	int rem = (8 + n) % 8
	int pad = 0
	if (rem != 0):
		pad = 8 - rem

	string_builder* padded = string_new()
	string_append(padded, header)
	int i = 0
	while (i < pad):
		string_append_char(padded, ' ')
		i = i + 1

	char[8] data
	char* data_p = data
	put_f32_le(data_p, 1.5)
	put_f32_le(data_p + 4, -3.5)

	write_raw_file(c"bin/safetensors_golden.safetensors", padded.length, padded.data, padded.length, data, 8)
	string_free(padded)

	st_file* loaded = st_load(c"bin/safetensors_golden.safetensors")
	assert1(loaded != 0)
	assert_equal(1, st_count(loaded))
	assert_strings_equal(c"w", st_name_at(loaded, 0))

	ndf* t = st_get(loaded, c"w")
	assert1(t != 0)
	assert_equal(1, t.rank)
	assert_equal(2, t.n0)
	assert_feq(1.5, ndf_at1(t, 0))
	assert_feq(-3.5, ndf_at1(t, 1))

	st_free(loaded)


# "__metadata__" is a string->string sidecar that must be skipped, not
# treated as a tensor -- whatever shape its value takes.
void test_golden_file_skips_metadata():
	char* header = c"{\"__metadata__\":{\"framework\":\"w\"},\"w\":{\"dtype\":\"F32\",\"shape\":[1],\"data_offsets\":[0,4]}}"
	int n = strlen(header)

	char[4] data
	put_f32_le(data, 7.25)

	write_raw_file(c"bin/safetensors_golden_metadata.safetensors", n, header, n, data, 4)

	st_file* loaded = st_load(c"bin/safetensors_golden_metadata.safetensors")
	assert1(loaded != 0)
	assert_equal(1, st_count(loaded))
	assert1(st_get(loaded, c"__metadata__") == 0)
	ndf* t = st_get(loaded, c"w")
	assert1(t != 0)
	assert_feq(7.25, ndf_at1(t, 0))

	st_free(loaded)


############################### 3. alignment ###############################


void test_saved_header_is_8_byte_aligned():
	ndf a = ndf_new1(1)
	ndf_set1(&a, 0, 3.0)
	st_file* out = st_new()
	st_add(out, c"x", &a)
	assert_equal(1, st_save(c"bin/safetensors_alignment.safetensors", out))
	st_free(out)

	wstream* in = stream_open_read(c"bin/safetensors_alignment.safetensors")
	assert1(in != 0)
	char[8] len_bytes
	assert_equal(8, stream_read(in, len_bytes, 8))
	stream_close(in)

	int n = st_read_header_len(len_bytes)
	assert1(n >= 0)
	assert_equal(0, (8 + n) % 8)


############################### 4. error paths ###############################


void test_rejects_bad_dtype():
	char* header = c"{\"w\":{\"dtype\":\"I64\",\"shape\":[1],\"data_offsets\":[0,8]}}"
	int n = strlen(header)
	write_raw_file(c"bin/safetensors_bad_dtype.safetensors", n, header, n, 0, 0)
	st_file* loaded = st_load(c"bin/safetensors_bad_dtype.safetensors")
	assert1(loaded == 0)


void test_rejects_f16_dtype():
	char* header = c"{\"w\":{\"dtype\":\"F16\",\"shape\":[1],\"data_offsets\":[0,2]}}"
	int n = strlen(header)
	write_raw_file(c"bin/safetensors_f16.safetensors", n, header, n, 0, 0)
	st_file* loaded = st_load(c"bin/safetensors_f16.safetensors")
	assert1(loaded == 0)


void test_rejects_truncated_data():
	char* header = c"{\"w\":{\"dtype\":\"F32\",\"shape\":[2],\"data_offsets\":[0,8]}}"
	int n = strlen(header)
	char[4] short_data
	short_data[0] = 0
	short_data[1] = 0
	short_data[2] = 0
	short_data[3] = 0
	# declares 8 bytes of tensor data but only 4 are actually present
	write_raw_file(c"bin/safetensors_truncated_data.safetensors", n, header, n, short_data, 4)
	st_file* loaded = st_load(c"bin/safetensors_truncated_data.safetensors")
	assert1(loaded == 0)


void test_rejects_lying_header_length():
	char* header = c"{\"w\":{\"dtype\":\"F32\",\"shape\":[1],\"data_offsets\":[0,4]}}"
	int n = strlen(header)
	# claims the header is 1000 bytes longer than what is actually written
	write_raw_file(c"bin/safetensors_lying_header.safetensors", n + 1000, header, n, 0, 0)
	st_file* loaded = st_load(c"bin/safetensors_lying_header.safetensors")
	assert1(loaded == 0)


# A claimed header length that is plausible on its own terms (well under
# the 2^31/2^32 platform-width cutoff st_read_header_len enforces) but
# absurdly large for any real safetensors file must be rejected up
# front, before a multi-hundred-MB malloc is attempted for a file that
# is actually a few dozen bytes long.
void test_rejects_implausibly_large_header_length():
	char* header = c"{\"w\":{\"dtype\":\"F32\",\"shape\":[1],\"data_offsets\":[0,4]}}"
	int n = strlen(header)
	write_raw_file(c"bin/safetensors_huge_header.safetensors", 200 * 1024 * 1024, header, n, 0, 0)
	st_file* loaded = st_load(c"bin/safetensors_huge_header.safetensors")
	assert1(loaded == 0)


void test_rejects_short_file():
	wstream* out = stream_open_write(c"bin/safetensors_short.safetensors")
	assert1(out != 0)
	stream_write(out, c"\x01\x02\x03", 3)
	stream_close(out)
	st_file* loaded = st_load(c"bin/safetensors_short.safetensors")
	assert1(loaded == 0)


void test_rejects_missing_file():
	st_file* loaded = st_load(c"bin/safetensors_does_not_exist_11aa.safetensors")
	assert1(loaded == 0)


void test_rejects_invalid_json_header():
	char* header = c"{not json}"
	int n = strlen(header)
	write_raw_file(c"bin/safetensors_bad_json.safetensors", n, header, n, 0, 0)
	st_file* loaded = st_load(c"bin/safetensors_bad_json.safetensors")
	assert1(loaded == 0)


void test_rejects_overlapping_offsets():
	char* header = c"{\"a\":{\"dtype\":\"F32\",\"shape\":[1],\"data_offsets\":[0,4]},\"b\":{\"dtype\":\"F32\",\"shape\":[1],\"data_offsets\":[2,6]}}"
	int n = strlen(header)
	char[6] data
	int i = 0
	while (i < 6):
		data[i] = 0
		i = i + 1
	write_raw_file(c"bin/safetensors_overlap.safetensors", n, header, n, data, 6)
	st_file* loaded = st_load(c"bin/safetensors_overlap.safetensors")
	assert1(loaded == 0)


void test_rejects_rank_zero_shape():
	char* header = c"{\"w\":{\"dtype\":\"F32\",\"shape\":[],\"data_offsets\":[0,4]}}"
	int n = strlen(header)
	char[4] data
	data[0] = 0
	data[1] = 0
	data[2] = 0
	data[3] = 0
	write_raw_file(c"bin/safetensors_rank0.safetensors", n, header, n, data, 4)
	st_file* loaded = st_load(c"bin/safetensors_rank0.safetensors")
	assert1(loaded == 0)


void test_rejects_rank_too_high():
	char* header = c"{\"w\":{\"dtype\":\"F32\",\"shape\":[1,1,1,1,1],\"data_offsets\":[0,4]}}"
	int n = strlen(header)
	char[4] data
	data[0] = 0
	data[1] = 0
	data[2] = 0
	data[3] = 0
	write_raw_file(c"bin/safetensors_rank5.safetensors", n, header, n, data, 4)
	st_file* loaded = st_load(c"bin/safetensors_rank5.safetensors")
	assert1(loaded == 0)
