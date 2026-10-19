# wbuild: x64
# wbuild: step="bin/zip_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
# libs/standard/archive/zip.w: fixtures written by CPython 3.13's zipfile
# (stored, deflated, a directory, a UTF-8 name, an archive comment;
# force_zip64=True; and ZIP64_LIMIT/ZIP_FILECOUNT_LIMIT lowered so the
# central directory carries zip64 extras and a zip64 end record),
# writer round trips, malformed-archive failures and safe extraction.
import lib.testing
import lib.hex
import lib.path
import lib.file
import libs.standard.archive.zip


# Generated with python3 (zipfile), see the header comment.
char* zip_fx_basic_hex():
	return c"504b0304140000000000af6db158d69b38d60c0000000c0000000900000068656c6c6f2e74787448656c6c6f2c207a6970210a504b030414000000000083182256000000000000000000000000040000006469722f504b03041400000008007dbf9f51b34e50a211000000f4010000100000006469722f6465666c617465642e7478744b4c4a4e494d4bcfc8cc4a1c658d101600504b030414000008080000002100828c8e500e0000000c00000010000000636166c3a92fe697a5e69cac2e7478742bcdcb4cce4f4955783467321700504b01021403140000000000af6db158d69b38d60c0000000c000000090000000000000000000000a4810000000068656c6c6f2e747874504b0102140314000000000083182256000000000000000000000000040000000000000000001000ed41330000006469722f504b010214031400000008007dbf9f51b34e50a211000000f40100001000000000000000000000008001550000006469722f6465666c617465642e747874504b0102140314000008080000002100828c8e500e0000000c000000100000000000000000000000800194000000636166c3a92fe697a5e69cac2e747874504b05060000000004000400e5000000d00000000f006669787475726520636f6d6d656e74"


char* zip_fx_z64force_hex():
	return c"504b03042d000000080000002100fd73b001ffffffffffffffff070014006269672e62696e0100100004010000000000001200000000000000abca2c30335148cb2f4a4e4d51a81a991c00504b01022d032d000000080000002100fd73b00112000000040100000700000000000000000000008001000000006269672e62696e504b05060000000001000100350000004b0000000000"


char* zip_fx_z64limits_hex():
	return c"504b03042d0000000000cab0505d21e804feffffffffffffffff05001400612e747874010010000b000000000000000b00000000000000616c70686120616c706861504b03042d0000000000cab0505d89b89b09ffffffffffffffff05001400622e7478740100100005000000000000000500000000000000627261766f504b01022d032d0000000000cab0505d21e804feffffffffffffffff050014000000000000000000800100000000612e747874010010000b000000000000000b00000000000000504b01022d032d0000000000cab0505d89b89b09ffffffffffffffff05001c0000000000000000008001ffffffff622e74787401001800050000000000000005000000000000004200000000000000504b06062c000000000000002d002d0000000000000000000200000000000000020000000000000096000000000000007e00000000000000504b060700000000140100000000000001000000504b05060000000002000200960000007e0000000000"


# The compression modules build process-lifetime tables lazily (crc32,
# inflate, deflate). Released at the end of each test so the per-test
# leak check sees only what the zip code itself allocated.
void zip_test_release_caches():
	free(crc32_table_cache)
	crc32_table_cache = 0
	free(inf_length_base_cache)
	inf_length_base_cache = 0
	free(inf_length_extra_cache)
	inf_length_extra_cache = 0
	free(inf_dist_base_cache)
	inf_dist_base_cache = 0
	free(inf_dist_extra_cache)
	inf_dist_extra_cache = 0
	free(inf_clc_order_cache)
	inf_clc_order_cache = 0
	if (inf_fixed_litlen_cache != 0): wh_free(inf_fixed_litlen_cache)
	inf_fixed_litlen_cache = 0
	if (inf_fixed_dist_cache != 0): wh_free(inf_fixed_dist_cache)
	inf_fixed_dist_cache = 0
	free(dfl_fixed_litlen_lengths_cache)
	dfl_fixed_litlen_lengths_cache = 0
	free(dfl_fixed_litlen_codes_cache)
	dfl_fixed_litlen_codes_cache = 0
	free(dfl_fixed_dist_lengths_cache)
	dfl_fixed_dist_lengths_cache = 0
	free(dfl_fixed_dist_codes_cache)
	dfl_fixed_dist_codes_cache = 0


zip_data* zip_fx(char* hex_text):
	int n = 0
	char* bytes = hex_decode(hex_text, strlen(hex_text), &n)
	asserts(c"fixture hex decodes", bytes != 0)
	return new zip_data(bytes, n)


zip_reader* zip_test_open(zip_data* d):
	wresult[zip_reader*]* res = zip_open_bytes(d.data, d.length)
	if (result_is_error[zip_reader*](res)): println(zip_error_string(result_code[zip_reader*](res)))
	asserts(c"zip opens", result_is_ok[zip_reader*](res))
	zip_reader* r = result_value[zip_reader*](res)
	result_free[zip_reader*](res)
	return r


# The error code of opening d (0 when it opens; the reader is closed).
int zip_test_open_code(zip_data* d):
	wresult[zip_reader*]* res = zip_open_bytes(d.data, d.length)
	int code = 0
	if (result_is_error[zip_reader*](res)): code = result_code[zip_reader*](res)
	else: zip_close(result_value[zip_reader*](res))
	result_free[zip_reader*](res)
	return code


# The error code of reading name from d (0 when the read succeeds).
int zip_test_read_code(zip_data* d, char* name):
	zip_reader* r = zip_test_open(d)
	wresult[zip_data*]* res = zip_read(r, name)
	int code = 0
	if (result_is_error[zip_data*](res)): code = result_code[zip_data*](res)
	else: zip_data_free(result_value[zip_data*](res))
	result_free[zip_data*](res)
	zip_close(r)
	return code


void zip_test_expect_content(zip_reader* r, char* name, char* want, int want_len):
	wresult[zip_data*]* res = zip_read(r, name)
	if (result_is_error[zip_data*](res)): println(zip_error_string(result_code[zip_data*](res)))
	asserts(c"entry reads", result_is_ok[zip_data*](res))
	zip_data* got = result_value[zip_data*](res)
	result_free[zip_data*](res)
	assert_equal(want_len, got.length)
	assert_bytes_equal(want, got.data, want_len)
	assert_equal(0, got.data[want_len])
	zip_data_free(got)


char* zip_test_repeat(char* piece, int times):
	int n = strlen(piece)
	char* out = cast(char*, malloc(n * times + 1))
	for i in range(times):
		for j in range(n): out[i * n + j] = piece[j]
	out[n * times] = 0
	return out


void zip_test_put32(char* p, int v):
	p[0] = v & 255
	p[1] = shr(v, 8) & 255
	p[2] = shr(v, 16) & 255
	p[3] = shr(v, 24) & 255


void test_zip_python_basic_listing():
	zip_data* d = zip_fx(zip_fx_basic_hex())
	zip_reader* r = zip_test_open(d)
	assert_equal(4, zip_count(r))
	assert_equal(0, r.zip64)
	assert_equal(15, r.comment_length)
	assert_strings_equal(c"fixture comment", r.comment)
	list[char*] names = zip_namelist(r)
	assert_equal(4, names.length)
	assert_strings_equal(c"hello.txt", names[0])
	assert_strings_equal(c"dir/", names[1])
	assert_strings_equal(c"dir/deflated.txt", names[2])
	assert_strings_equal(c"café/日本.txt", names[3])
	names.free()

	zip_entry* e = zip_getinfo(r, c"hello.txt")
	assert_equal(ZIP_STORED, e.method)
	assert_equal(12, e.file_size)
	assert_equal(12, e.compressed_size)
	assert_equal(0, e.header_offset)
	assert_equal(crc32_of(c"Hello, zip!\n", 12), e.crc)
	assert_equal(33188, zip_entry_mode(e))   # 0o100644
	assert_equal(0, zip_entry_is_dir(e))
	assert_equal(0, zip_entry_is_utf8(e))
	assert_equal(0, e.too_large)
	int year = 0
	int month = 0
	int day = 0
	int hour = 0
	int minute = 0
	int second = 0
	zip_entry_date_time(e, &year, &month, &day, &hour, &minute, &second)
	assert_equal(2024, year)
	assert_equal(5, month)
	assert_equal(17, day)
	assert_equal(13, hour)
	assert_equal(45, minute)
	assert_equal(30, second)

	e = zip_getinfo(r, c"dir/")
	assert1(zip_entry_is_dir(e))
	assert_equal(16877, zip_entry_mode(e))   # 0o40755
	assert_equal(16, e.external_attr & 16)
	assert_equal(0, e.file_size)
	assert_equal(51, e.header_offset)
	zip_entry_date_time(e, &year, &month, &day, &hour, &minute, &second)
	assert_equal(2023, year)
	assert_equal(6, second)

	e = zip_entry_at(r, 2)
	assert_equal(ZIP_DEFLATED, e.method)
	assert_equal(500, e.file_size)
	assert_equal(17, e.compressed_size)
	assert_equal(85, e.header_offset)

	e = zip_entry_at(r, 3)
	assert1(zip_entry_is_utf8(e))
	assert_equal(ZIP_FLAG_UTF8, e.flags)
	assert_equal(148, e.header_offset)
	assert_equal(14, e.compressed_size)
	zip_entry_date_time(e, &year, &month, &day, &hour, &minute, &second)
	assert_equal(1980, year)
	assert_equal(1, month)
	assert_equal(1, day)
	assert_equal(0, hour)

	asserts(c"index out of range", zip_entry_at(r, 4) == 0)
	asserts(c"negative index", zip_entry_at(r, -1) == 0)
	asserts(c"missing name", zip_getinfo(r, c"nope") == 0)
	zip_close(r)
	zip_data_free(d)
	zip_test_release_caches()


void test_zip_python_basic_read():
	zip_data* d = zip_fx(zip_fx_basic_hex())
	zip_reader* r = zip_test_open(d)
	zip_test_expect_content(r, c"hello.txt", c"Hello, zip!\n", 12)
	zip_test_expect_content(r, c"dir/", c"", 0)
	char* expect = zip_test_repeat(c"abcdefghij", 50)
	zip_test_expect_content(r, c"dir/deflated.txt", expect, 500)
	free(expect)
	zip_test_expect_content(r, c"café/日本.txt", c"unicode ✓\n", 12)
	int code = 99
	assert_equal(-1, zip_testzip(r, &code))
	assert_equal(0, code)
	wresult[zip_data*]* missing = zip_read(r, c"absent.txt")
	assert_equal(ZIP_ERR_NOT_FOUND, result_code[zip_data*](missing))
	result_free[zip_data*](missing)
	zip_close(r)
	zip_data_free(d)
	zip_test_release_caches()


void test_zip_python_force_zip64():
	zip_data* d = zip_fx(zip_fx_z64force_hex())
	zip_reader* r = zip_test_open(d)
	assert_equal(1, zip_count(r))
	zip_entry* e = zip_entry_at(r, 0)
	assert_strings_equal(c"big.bin", e.name)
	assert_equal(260, e.file_size)
	assert_equal(18, e.compressed_size)
	assert_equal(45, e.version_needed)
	char* expect = zip_test_repeat(c"zip64 forced ", 20)
	zip_test_expect_content(r, c"big.bin", expect, 260)
	free(expect)
	zip_close(r)
	zip_data_free(d)
	zip_test_release_caches()


void test_zip_python_zip64_central_and_end_records():
	zip_data* d = zip_fx(zip_fx_z64limits_hex())
	zip_reader* r = zip_test_open(d)
	assert_equal(1, r.zip64)
	assert_equal(2, zip_count(r))
	zip_entry* a = zip_entry_at(r, 0)
	zip_entry* b = zip_entry_at(r, 1)
	assert_strings_equal(c"a.txt", a.name)
	assert_equal(1, a.has_zip64)
	assert_equal(11, a.file_size)
	assert_equal(0, a.header_offset)
	assert_equal(1, b.has_zip64)
	assert_equal(5, b.file_size)
	assert_equal(5, b.compressed_size)
	assert_equal(66, b.header_offset)   # from the zip64 extra
	assert_equal(0, b.header_offset_hi)
	assert_equal(66, b.header_offset_lo)
	zip_test_expect_content(r, c"a.txt", c"alpha alpha", 11)
	zip_test_expect_content(r, c"b.txt", c"bravo", 5)
	zip_close(r)

	# The classic end record saturated, as a >65535-entry or >4 GiB
	# writer leaves it: only the zip64 end record has the real values.
	int eocd = d.length - 22
	for i in range(4): d.data[eocd + 8 + i] = 255
	for i in range(8): d.data[eocd + 12 + i] = 255
	r = zip_test_open(d)
	assert_equal(2, zip_count(r))
	zip_test_expect_content(r, c"b.txt", c"bravo", 5)
	zip_close(r)

	# Locator says the zip64 record is on another disk.
	int loc = eocd - 20
	d.data[loc + 4] = 1
	assert_equal(ZIP_ERR_MULTI_DISK, zip_test_open_code(d))
	d.data[loc + 4] = 0
	# Locator present, record signature broken.
	d.data[loc - 56] = 0
	assert_equal(ZIP_ERR_BAD_ZIP64, zip_test_open_code(d))
	zip_data_free(d)
	zip_test_release_caches()


void test_zip_prepended_data_is_rebased():
	zip_data* d = zip_fx(zip_fx_basic_hex())
	int pad = 100
	char* buf = cast(char*, malloc(d.length + pad))
	for i in range(pad): buf[i] = 'S'
	for i in range(d.length): buf[pad + i] = d.data[i]
	zip_data* shifted = new zip_data(buf, d.length + pad)
	zip_reader* r = zip_test_open(shifted)
	assert_equal(pad + 85, zip_entry_at(r, 2).header_offset)
	char* expect = zip_test_repeat(c"abcdefghij", 50)
	zip_test_expect_content(r, c"dir/deflated.txt", expect, 500)
	free(expect)
	zip_close(r)
	zip_data_free(shifted)
	zip_data_free(d)
	zip_test_release_caches()


void test_zip_not_a_zip():
	zip_data* d = new zip_data(c"", 0)
	assert_equal(ZIP_ERR_NO_EOCD, zip_test_open_code(d))
	d.data = c"this is definitely not a zip archive, just some text"
	d.length = strlen(d.data)
	assert_equal(ZIP_ERR_NO_EOCD, zip_test_open_code(d))
	free(d)
	wresult[zip_reader*]* res = zip_open_read(c"bin/zip_test_no_such_file.zip")
	assert_equal(ZIP_ERR_IO, result_code[zip_reader*](res))
	result_free[zip_reader*](res)
	zip_test_release_caches()


# Field corruptions in the Python fixture, each with its specific error.
void test_zip_corrupted_fields():
	zip_data* d = zip_fx(zip_fx_basic_hex())
	int cd = 208
	int c_deflated = 313
	int eocd = d.length - 22 - 15

	d.data[39] = d.data[39] ^ 1          # stored payload byte
	assert_equal(ZIP_ERR_BAD_CRC, zip_test_read_code(d, c"hello.txt"))
	d.data[39] = d.data[39] ^ 1

	d.data[30] = 'j'                       # local name differs from central
	assert_equal(ZIP_ERR_BAD_LOCAL_HEADER, zip_test_read_code(d, c"hello.txt"))
	d.data[30] = 'h'

	d.data[0] = 0                          # local signature
	assert_equal(ZIP_ERR_BAD_LOCAL_HEADER, zip_test_read_code(d, c"hello.txt"))
	d.data[0] = 'P'

	d.data[cd + 8] = 1                     # encrypted flag
	assert_equal(ZIP_ERR_ENCRYPTED, zip_test_read_code(d, c"hello.txt"))
	d.data[cd + 8] = 0

	d.data[cd + 10] = 99                   # unknown method
	assert_equal(ZIP_ERR_UNSUPPORTED_METHOD, zip_test_read_code(d, c"hello.txt"))
	d.data[cd + 10] = 0

	d.data[cd + 20] = 11                   # stored csize != usize
	assert_equal(ZIP_ERR_BAD_SIZE, zip_test_read_code(d, c"hello.txt"))
	d.data[cd + 20] = 12

	zip_test_put32(d.data + cd + 42, 0x7fff0000)   # local header offset past the end
	assert_equal(ZIP_ERR_TRUNCATED, zip_test_read_code(d, c"hello.txt"))
	zip_test_put32(d.data + cd + 42, 0)

	zip_test_put32(d.data + cd + 20, 0x7fff0000)   # payload past the end
	zip_test_put32(d.data + cd + 24, 0x7fff0000)
	if (__word_size__ == 8): assert_equal(ZIP_ERR_TRUNCATED, zip_test_read_code(d, c"hello.txt"))
	zip_test_put32(d.data + cd + 20, 12)
	zip_test_put32(d.data + cd + 24, 12)

	zip_test_put32(d.data + c_deflated + 24, 100)  # declared size too small
	assert_equal(ZIP_ERR_BAD_SIZE, zip_test_read_code(d, c"dir/deflated.txt"))
	zip_test_put32(d.data + c_deflated + 24, 600)  # declared size too large
	assert_equal(ZIP_ERR_BAD_SIZE, zip_test_read_code(d, c"dir/deflated.txt"))
	zip_test_put32(d.data + c_deflated + 24, 500)

	d.data[c_deflated + 16] = d.data[c_deflated + 16] ^ 255   # CRC
	assert_equal(ZIP_ERR_BAD_CRC, zip_test_read_code(d, c"dir/deflated.txt"))
	d.data[c_deflated + 16] = d.data[c_deflated + 16] ^ 255

	d.data[85 + 30 + 16] = 255                # deflate block type 3
	assert_equal(INFLATE_ERR_BAD_BTYPE, zip_test_read_code(d, c"dir/deflated.txt"))
	d.data[85 + 30 + 16] = 0x4b

	d.data[cd + 30] = 200                     # extra field runs past the directory
	assert_equal(ZIP_ERR_BAD_CENTRAL_DIR, zip_test_open_code(d))
	d.data[cd + 30] = 0

	d.data[cd + 34] = 1                       # entry starts on another disk
	assert_equal(ZIP_ERR_MULTI_DISK, zip_test_open_code(d))
	d.data[cd + 34] = 0

	d.data[cd + 1] = 0                        # central signature
	assert_equal(ZIP_ERR_BAD_CENTRAL_DIR, zip_test_open_code(d))
	d.data[cd + 1] = 'K'

	d.data[eocd + 4] = 1                      # disk number
	assert_equal(ZIP_ERR_MULTI_DISK, zip_test_open_code(d))
	d.data[eocd + 4] = 0

	d.data[eocd + 12] = 255                   # central directory size too big
	assert_equal(ZIP_ERR_BAD_CENTRAL_DIR, zip_test_open_code(d))
	d.data[eocd + 12] = 0xe5

	d.data[eocd + 16] = 0xd1                  # offset one past the real start
	assert_equal(ZIP_ERR_BAD_CENTRAL_DIR, zip_test_open_code(d))
	d.data[eocd + 16] = 0xd0

	zip_test_put32(d.data + eocd + 16, 0x7fff0000)
	assert1(zip_test_open_code(d) != 0)
	zip_test_put32(d.data + eocd + 16, 0xd0)

	d.data[eocd + 20] = 16                    # comment longer than the file
	assert_equal(ZIP_ERR_NO_EOCD, zip_test_open_code(d))
	d.data[eocd + 20] = 15

	assert_equal(0, zip_test_open_code(d))
	zip_data_free(d)
	zip_test_release_caches()


# Reads every entry of a possibly-damaged archive; returns 1 when the
# open or any read reported an error.
int zip_test_try_all(char* data, int length):
	wresult[zip_reader*]* res = zip_open_bytes(data, length)
	if (result_is_error[zip_reader*](res)):
		result_free[zip_reader*](res)
		return 1
	zip_reader* r = result_value[zip_reader*](res)
	result_free[zip_reader*](res)
	int code = 0
	int bad = zip_testzip(r, &code)
	zip_close(r)
	return bad >= 0


# Every truncation (from either end) and every single-byte corruption
# fails cleanly or still decodes: no crash, no leak.
void test_zip_truncation_and_byte_flip_sweep():
	zip_data* d = zip_fx(zip_fx_basic_hex())
	for n in range(d.length):
		assert1(zip_test_try_all(d.data, n))
	int front_failures = 0
	for k in range(1, d.length):
		front_failures = front_failures + zip_test_try_all(d.data + k, d.length - k)
	assert_equal(d.length - 1, front_failures)
	int flagged = 0
	for i in range(d.length):
		int saved = d.data[i]
		d.data[i] = saved ^ 255
		flagged = flagged + zip_test_try_all(d.data, d.length)
		d.data[i] = saved
	asserts(c"most corruptions are detected", flagged > d.length / 2)
	assert_equal(0, zip_test_try_all(d.data, d.length))
	zip_data_free(d)

	d = zip_fx(zip_fx_z64limits_hex())
	for n in range(d.length):
		assert1(zip_test_try_all(d.data, n))
	for i in range(d.length):
		int saved = d.data[i]
		d.data[i] = saved ^ 255
		zip_test_try_all(d.data, d.length)
		d.data[i] = saved
	zip_data_free(d)
	zip_test_release_caches()


void test_zip_writer_round_trip():
	zip_writer* w = zip_writer_new()
	char* big = zip_test_repeat(c"The quick brown fox jumps over the lazy dog. ", 40)
	int big_len = strlen(big)
	assert_equal(0, zip_writer_add(w, c"stored.txt", c"plain bytes\n", 12, ZIP_STORED))
	assert_equal(0, zip_writer_add_dir(w, c"sub"))
	assert_equal(0, zip_writer_add(w, c"sub/fox.txt", big, big_len, ZIP_DEFLATED))
	assert_equal(0, zip_writer_add(w, c"empty.bin", c"", 0, ZIP_DEFLATED))
	assert_equal(0, zip_writer_add(w, c"naïve.txt", c"x", 1, ZIP_STORED))
	int date = zip_dos_date(2031, 7, 4)
	int time = zip_dos_time(9, 30, 59)
	assert_equal(0, zip_writer_add_ex(w, c"exec.sh", c"#!/bin/sh\n", 10, ZIP_DEFLATED, date, time, 493 << 16))
	zip_writer_set_comment(w, c"made by W", 9)
	assert_equal(ZIP_ERR_BAD_NAME, zip_writer_add(w, c"", c"x", 1, ZIP_STORED))
	assert_equal(ZIP_ERR_UNSUPPORTED_METHOD, zip_writer_add(w, c"bz.txt", c"x", 1, 12))
	assert_equal(ZIP_ERR_BAD_NAME, zip_writer_add_dir(w, c""))
	zip_data* archive = zip_writer_finish(w)

	zip_reader* r = zip_test_open(archive)
	assert_equal(6, zip_count(r))
	assert_equal(0, r.zip64)
	assert_strings_equal(c"made by W", r.comment)
	zip_test_expect_content(r, c"stored.txt", c"plain bytes\n", 12)
	zip_test_expect_content(r, c"sub/fox.txt", big, big_len)
	zip_test_expect_content(r, c"empty.bin", c"", 0)
	zip_test_expect_content(r, c"naïve.txt", c"x", 1)
	zip_test_expect_content(r, c"exec.sh", c"#!/bin/sh\n", 10)
	zip_entry* e = zip_getinfo(r, c"sub/")
	assert1(zip_entry_is_dir(e))
	assert_equal(16877, zip_entry_mode(e))
	e = zip_getinfo(r, c"sub/fox.txt")
	assert_equal(ZIP_DEFLATED, e.method)
	asserts(c"deflate shrinks repetitive text", e.compressed_size < big_len / 4)
	assert_equal(384, zip_entry_mode(e))
	assert_equal(0, zip_entry_is_utf8(e))
	assert1(zip_entry_is_utf8(zip_getinfo(r, c"naïve.txt")))
	e = zip_getinfo(r, c"exec.sh")
	assert_equal(493, zip_entry_mode(e))
	int year = 0
	int month = 0
	int day = 0
	int hour = 0
	int minute = 0
	int second = 0
	zip_entry_date_time(e, &year, &month, &day, &hour, &minute, &second)
	assert_equal(2031, year)
	assert_equal(7, month)
	assert_equal(4, day)
	assert_equal(9, hour)
	assert_equal(30, minute)
	assert_equal(58, second)
	int code = 0
	assert_equal(-1, zip_testzip(r, &code))
	zip_close(r)
	zip_data_free(archive)
	free(big)
	zip_test_release_caches()


void test_zip_writer_force_zip64_round_trip():
	zip_writer* w = zip_writer_new()
	zip_writer_force_zip64(w, 1)
	zip_writer_set_level(w, DEFLATE_LEVEL_BEST())
	assert_equal(0, zip_writer_add(w, c"a", c"x", 1, ZIP_STORED))
	assert_equal(0, zip_writer_add(w, c"b/c.txt", c"hello hello hello hello", 23, ZIP_DEFLATED))
	zip_data* archive = zip_writer_finish(w)
	zip_reader* r = zip_test_open(archive)
	assert_equal(1, r.zip64)
	assert_equal(2, zip_count(r))
	zip_entry* e = zip_entry_at(r, 1)
	assert_equal(1, e.has_zip64)
	assert_equal(45, e.version_needed)
	assert_equal(23, e.file_size)
	assert_equal(52, e.header_offset)
	zip_test_expect_content(r, c"a", c"x", 1)
	zip_test_expect_content(r, c"b/c.txt", c"hello hello hello hello", 23)
	zip_close(r)

	# Entry "a": local header 30 + name 1 + extra 20 + data 1 = 52, then
	# the second one; its central record's zip64 extra starts 46 + 1
	# bytes into the central directory, size field 2 bytes later.
	int cd = 0
	r = zip_test_open(archive)
	cd = zip_entry_at(r, 1).header_offset + 30 + 7 + 20 + zip_entry_at(r, 1).compressed_size
	zip_close(r)
	int size_field = cd + 46 + 1 + 2
	assert_equal(24, load_le16(archive.data + size_field))
	archive.data[size_field] = 8              # too short for the three values
	assert_equal(ZIP_ERR_BAD_ZIP64, zip_test_open_code(archive))
	archive.data[size_field] = 24
	assert_equal(0, zip_test_open_code(archive))
	zip_data_free(archive)
	zip_test_release_caches()


void test_zip_many_entries_use_zip64_end_record():
	zip_writer* w = zip_writer_new()
	char* name = cast(char*, malloc(16))
	int n = 65537
	for i in range(n):
		hex_put_byte(name, shr(i, 16) & 255)
		hex_put_byte(name + 2, shr(i, 8) & 255)
		hex_put_byte(name + 4, i & 255)
		name[6] = 0
		assert_equal(0, zip_writer_add(w, name, c"", 0, ZIP_STORED))
	free(name)
	zip_data* archive = zip_writer_finish(w)
	int eocd = archive.length - 22
	assert_equal(65535, load_le16(archive.data + eocd + 10))
	# Not parsed back here: 65537 entries are ~200k blocks, more than the
	# leak-checking debug allocator can guard-page. The zip64 end-record
	# reader path is covered by the Python fixtures above.
	assert_equal(ZIP_SIG_LOCATOR64, load_le32(archive.data + eocd - 20))
	int rec = eocd - 20 - 56
	assert_equal(ZIP_SIG_EOCD64, load_le32(archive.data + rec))
	assert_equal(n, load_le32(archive.data + rec + 32))
	assert_equal(0, load_le32(archive.data + rec + 36))
	assert_equal(rec, load_le32(archive.data + eocd - 20 + 8))
	int cd_size = load_le32(archive.data + rec + 40)
	int cd_off = load_le32(archive.data + rec + 48)
	assert_equal(rec, cd_off + cd_size)
	assert_equal(ZIP_SIG_CENTRAL, load_le32(archive.data + cd_off))
	zip_data_free(archive)
	zip_test_release_caches()


void test_zip_member_name_safety():
	assert1(zip_member_name_is_safe(c"a.txt", 5))
	assert1(zip_member_name_is_safe(c"dir/sub/a.txt", 13))
	assert1(zip_member_name_is_safe(c"..foo/bar..", 11))
	assert1(zip_member_name_is_safe(c"./a", 3))
	assert_equal(0, zip_member_name_is_safe(c"", 0))
	assert_equal(0, zip_member_name_is_safe(c"/etc/passwd", 11))
	assert_equal(0, zip_member_name_is_safe(c"\\evil", 5))
	assert_equal(0, zip_member_name_is_safe(c"..", 2))
	assert_equal(0, zip_member_name_is_safe(c"../x", 4))
	assert_equal(0, zip_member_name_is_safe(c"a/../../x", 9))
	assert_equal(0, zip_member_name_is_safe(c"a/..", 4))
	assert_equal(0, zip_member_name_is_safe(c"a\\..\\b", 6))
	assert_equal(0, zip_member_name_is_safe(c"C:x", 3))
	assert_equal(0, zip_member_name_is_safe(c"a", 3))      # embedded NUL


char* zip_test_dir():
	if (__word_size__ == 8): return c"bin/zip_test_64_extract"
	return c"bin/zip_test_32_extract"


char* zip_test_file(char* rel):
	return path_join(zip_test_dir(), rel)


void zip_test_remove(char* rel, int is_dir):
	char* p = zip_test_file(rel)
	if (is_dir): rmdir(p)
	else: unlink(p)
	free(p)


void zip_test_expect_file(char* rel, char* want, int want_len):
	char* p = zip_test_file(rel)
	wstream* in = stream_open_read(p)
	asserts(c"extracted file exists", in != 0)
	string_builder* buf = string_new()
	io_result ior
	assert_equal(IO_OK, stream_read_all_checked(in, buf, &ior))
	stream_close(in)
	assert_equal(want_len, buf.length)
	assert_bytes_equal(want, buf.data, want_len)
	string_free(buf)
	free(p)


void zip_test_cleanup_extract():
	zip_test_remove(c"hello.txt", 0)
	zip_test_remove(c"dir/deflated.txt", 0)
	zip_test_remove(c"café/日本.txt", 0)
	zip_test_remove(c"dir", 1)
	zip_test_remove(c"café", 1)
	zip_test_remove(c"archive.zip", 0)
	rmdir(zip_test_dir())


void test_zip_extract_all_safe_and_open_read():
	zip_test_cleanup_extract()
	zip_data* d = zip_fx(zip_fx_basic_hex())
	zip_reader* r = zip_test_open(d)
	assert_equal(0, zip_extract_all_safe(r, zip_test_dir()))
	zip_test_expect_file(c"hello.txt", c"Hello, zip!\n", 12)
	char* expect = zip_test_repeat(c"abcdefghij", 50)
	zip_test_expect_file(c"dir/deflated.txt", expect, 500)
	free(expect)
	zip_test_expect_file(c"café/日本.txt", c"unicode ✓\n", 12)
	zip_close(r)

	# The same archive from disk through zip_open_read (owns its bytes).
	char* path = zip_test_file(c"archive.zip")
	io_result wr
	assert_equal(IO_OK, file_write_text_checked(path, d.data, d.length, &wr))
	wresult[zip_reader*]* res = zip_open_read(path)
	asserts(c"zip_open_read", result_is_ok[zip_reader*](res))
	r = result_value[zip_reader*](res)
	result_free[zip_reader*](res)
	assert_equal(1, r.owns_data)
	zip_test_expect_content(r, c"hello.txt", c"Hello, zip!\n", 12)
	zip_close(r)
	free(path)
	zip_data_free(d)
	zip_test_cleanup_extract()
	zip_test_release_caches()


void test_zip_extract_refuses_traversal():
	zip_test_cleanup_extract()
	char* bad_names = c"../escape.txt"
	for k in range(3):
		zip_writer* w = zip_writer_new()
		assert_equal(0, zip_writer_add(w, c"hello.txt", c"fine", 4, ZIP_STORED))
		if (k == 1): bad_names = c"/tmp/zip_test_abs.txt"
		if (k == 2): bad_names = c"ok/../../escape.txt"
		assert_equal(0, zip_writer_add(w, bad_names, c"evil", 4, ZIP_STORED))
		zip_data* archive = zip_writer_finish(w)
		zip_reader* r = zip_test_open(archive)
		assert_equal(ZIP_ERR_UNSAFE_PATH, zip_extract_all_safe(r, zip_test_dir()))
		# Validation happens before any write: not even the safe entry.
		assert_equal(0, path_exists(zip_test_dir()))
		assert_equal(ZIP_ERR_UNSAFE_PATH, zip_extract_safe(r, zip_entry_at(r, 1), zip_test_dir()))
		zip_close(r)
		zip_data_free(archive)
	assert_equal(0, path_exists(c"bin/escape.txt"))
	zip_test_release_caches()


void test_zip_error_strings():
	for code in range(301, 316):
		assert1(starts_with(zip_error_string(code), c"zip: "))
	assert1(starts_with(zip_error_string(INFLATE_ERR_BAD_BTYPE), c"inflate: "))
