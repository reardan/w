/*
libs/extras/compress/crc32c.w: CRC-32C (Castagnoli), the reflected
polynomial 0x82F63B78 -- the checksum of iSCSI (RFC 3720 appendix B.4),
SCTP, ext4/btrfs metadata, LevelDB/RocksDB blocks and many WAL formats.

This is NOT the CRC-32 of libs/extras/compress/crc32.w (IEEE/zlib/gzip,
reflected 0xEDB88320): the two produce different values for the same
bytes, so a persisted format must name which one it uses (crc32c_name()
and crc32c_poly() here; crc32.w's crc32_poly()). Check values for
"123456789": CRC-32C 0xE3069283, CRC-32 0xCBF43926. Neither is
authentication: both detect accidental corruption only; anyone can
recompute them over altered bytes.

Constants with bit 31 set are built at runtime (0x82F63B78 from two
16-bit halves, the all-ones mask via crc32c_mask32), never written as
literal tokens -- the same discipline as crc32.w's header explains.
Right shifts use the shr() intrinsic, so values follow the masked
32-bit-word convention: a result with bit 31 set is negative on the
32-bit target and positive on x64; compare against a constant built the
same way, or mask both sides.

TABLE INITIALIZATION (concurrency rule): the 256-entry table is built
on first use and cached for the life of the process. That lazy build is
NOT synchronized. Call crc32c_init_tables() once before starting any
worker thread (task_spawn_blocking pools, native threads) that may
checksum; after that every call only reads the table and is safe from
any number of threads. Single-threaded programs may skip it.
*/
import lib.memory


# 0xFFFFFFFF without a bit-31 literal: -1 on 32-bit ints, 4294967295 on x64.
int crc32c_mask32():
	int h = 1 << 16
	return h * h - 1


# The reflected Castagnoli polynomial 0x82F63B78 (normal form 0x1EDC6F41).
int crc32c_poly():
	int high = 0x82f6
	int low = 0x3b78
	return ((high << 16) | low) & crc32c_mask32()


char* crc32c_name():
	return c"crc32c-castagnoli"


int* crc32c_table_cache


int* crc32c_build_table():
	int* table = cast(int*, malloc(256 * __word_size__))
	int poly = crc32c_poly()
	int mask = crc32c_mask32()
	for n in range(256):
		int word = n
		for k in range(8):
			if ((word & 1) != 0): word = shr(word, 1) ^ poly
			else: word = shr(word, 1)
		table[n] = word & mask
	return table


# Builds the table if needed. Call before starting workers (see header).
void crc32c_init_tables():
	if (crc32c_table_cache == 0): crc32c_table_cache = crc32c_build_table()


int* crc32c_table():
	crc32c_init_tables()
	return crc32c_table_cache


# Continues a checksum: crc = 0 starts a fresh one, so
# crc32c_update(crc32c_update(0, a, na), b, nb) == crc32c_of(a ++ b)
# (the same convention as crc32_update). A negative length is treated as
# zero. The result is a masked 32-bit word.
int crc32c_update(int crc, char* data, int length):
	if (length < 0): length = 0
	int* table = crc32c_table()
	int mask = crc32c_mask32()
	int c = (crc ^ mask) & mask
	for i in range(length):
		int idx = (c ^ (data[i] & 255)) & 255
		c = shr(c, 8) ^ table[idx]
	return (c ^ mask) & mask


int crc32c_of(char* data, int length):
	return crc32c_update(0, data, length)
