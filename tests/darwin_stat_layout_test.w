# wbuild: x64
import lib.testing
import lib.bytes
import lib.stat
import lib.darwin.stat_layout

void test_darwin_metadata_layout():
	char[144] native
	for i in range(144): native[i] = 0
	store_le32(&native[0], 0x03000007)
	store_le16(&native[4], FILE_S_IFREG | 493)
	store_le16(&native[6], 2)
	store_le64(&native[8], 1234567)
	store_le32(&native[16], 501)
	store_le32(&native[20], 20)
	store_le32(&native[24], 0x04010203)
	store_le64(&native[32], 1700000001)
	store_le64(&native[40], 123)
	store_le64(&native[48], 1700000002)
	store_le64(&native[56], 456)
	store_le64(&native[64], 1700000003)
	store_le64(&native[72], 789)
	store_le64(&native[96], 8193)
	store_le64(&native[104], 24)
	store_le32(&native[112], 4096)
	char[256] out
	for i in range(256): out[i] = 127
	darwin_stat_to_statx(&native[0], &out[0])
	file_stat st
	file_stat_from_statx(&out[0], &st)
	assert_equal(FILE_S_IFREG | 493, st.mode)
	assert_equal(2, st.nlink)
	assert_equal(1234567, st.ino)
	assert_equal(501, st.uid)
	assert_equal(20, st.gid)
	assert_equal(8193, st.size)
	assert_equal(24, st.blocks)
	assert_equal(1700000001, st.atime)
	assert_equal(1700000002, st.mtime)
	assert_equal(1700000003, st.ctime)
	assert_equal(file_stat_makedev(3, 7), st.dev)
	assert_equal(2047, load_le32(&out[0]))
	assert_equal(4096, load_le32(&out[4]))
	assert_equal(123, load_le32(&out[72]))
	assert_equal(456, load_le32(&out[120]))
	assert_equal(789, load_le32(&out[104]))
	assert_equal(4, load_le32(&out[128]))
	assert_equal(0x010203, load_le32(&out[132]))
	assert_equal(0, load_le32(&out[252]))
