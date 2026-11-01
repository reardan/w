# wbuild: x64 arch=arm64_darwin
# wbuild: target=repl_codec_cache_darwin_test tag=tests_darwin dep=repl_codec_cache_test_darwin
# wbuild: step="bin/repl_codec_cache_test_darwin" expect_stdout="All tests passed"
# Descriptor caches outlive individual entries. Rollback must discard
# released code and types, compact survivors, and preserve full host
# addresses. Exercise the cache APIs without mapping or executing JIT
# code, so both host word sizes run in compiler coverage too.
import lib.testing
import repl.core


int codec_test_begin():
	if (cast(int, type_records) == 0):
		word_size = __word_size__
		push_basic_types()
	json_codec_count = 0
	protobuf_desc_count = 0
	int saved_offset = code_offset
	code_offset = 0x10000000
	if (__word_size__ == 8): code_offset = (0x12345 << 16) << 16
	return saved_offset


void codec_test_store(int type, int address):
	json_codec_cache_store(type, address)
	protobuf_desc_store(type, address)


void codec_test_expect(int type, int address):
	assert_equal(address, json_codec_cache_lookup(type))
	assert_equal(address, protobuf_desc_lookup(type))


void codec_test_end(int saved_offset):
	json_codec_count = 0
	protobuf_desc_count = 0
	code_offset = saved_offset


void test_codec_rollback_compacts_only_live_descriptors():
	int saved_offset = codec_test_begin()
	int truncated_type = type_count() + 1
	codec_test_store(1, code_offset + 8)
	codec_test_store(2, code_offset + 64)
	codec_test_store(truncated_type, code_offset + 16)
	codec_test_store(3, code_offset + 32)
	# The boundary itself is released. A descriptor below it is also
	# stale when its type was truncated, while the last entry must move
	# across both removed slots without truncating its address.
	repl_codec_drop_if(-1, 64)
	assert_equal(2, json_codec_count)
	assert_equal(2, protobuf_desc_count)
	codec_test_expect(1, code_offset + 8)
	codec_test_expect(2, 0)
	codec_test_expect(truncated_type, 0)
	codec_test_expect(3, code_offset + 32)
	# Reusing the released type/address must resolve to the new entry.
	codec_test_store(2, code_offset + 48)
	codec_test_expect(2, code_offset + 48)
	repl_codec_drop_if(-1, 0)
	assert_equal(0, json_codec_count)
	assert_equal(0, protobuf_desc_count)
	codec_test_end(saved_offset)


void test_codec_redefinition_invalidates_only_named_type():
	int saved_offset = codec_test_begin()
	codec_test_store(1, code_offset + 8)
	codec_test_store(2, code_offset + 128)
	codec_test_store(3, code_offset + 256)
	# A negative release boundary means type invalidation only; later
	# descriptors belonging to unrelated types remain usable.
	repl_codec_drop_if(2, -1)
	assert_equal(2, json_codec_count)
	assert_equal(2, protobuf_desc_count)
	codec_test_expect(1, code_offset + 8)
	codec_test_expect(2, 0)
	codec_test_expect(3, code_offset + 256)
	codec_test_store(2, code_offset + 512)
	codec_test_expect(2, code_offset + 512)
	codec_test_end(saved_offset)
