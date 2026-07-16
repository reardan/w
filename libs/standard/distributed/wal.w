/*
Checksummed append-only write-ahead log
(docs/projects/distributed.md, phase 4).

The durability primitive under raft_wal.w (and, later, the LSM
memtable): callers append opaque payload records; on reopen the log
replays exactly the prefix of records that were fully and correctly
written, silently discarding a torn tail from a crash mid-append.

File layout, all little-endian:
  offset 0: 4-byte magic "WLOG", 4-byte format version (1)
  then records: 4-byte payload length, 4-byte checksum, payload bytes
The checksum is the first 4 bytes of sha256 over (length bytes ||
payload), so a bit-flip in either the length field or the payload
fails validation. Recovery scans from the header: the first record
that is short, oversized, or checksum-mismatched ends the valid
prefix; appends then resume at that offset, overwriting torn bytes.
(A 2^-32 accidental-checksum-match on garbage is accepted as
negligible.)

Durability boundary: a successful wal_append has issued full
write(2) calls, so the record survives a process crash but sits in
the kernel page cache until wal_sync (fsync(2); F_FULLFSYNC on
Darwin) pushes it to stable storage. Callers with real durability
needs (raft_wal_sync) call wal_sync once per record burst rather
than per append.

Record payloads are opaque bytes; wal_read_next returns malloc'd
copies the caller frees.
*/
import lib.lib
import lib.memory
import lib.assert
import lib.framing
import lib.sha256


int wal_version():
	return 1


# Records larger than this are treated as corruption on scan and
# rejected (assert) on append.
int wal_max_record():
	return 1 << 24


struct wal:
	int fd
	char* path         # caller-owned; must outlive the wal (wal_reset reopens it)
	int append_off     # end of the valid prefix; next record goes here
	int record_count   # valid records in the prefix


struct wal_reader:
	int fd
	int off
	int done


# ---- record encoding --------------------------------------------------------

void wal_put_le32(char* p, int v):
	p[0] = v
	p[1] = v >> 8
	p[2] = v >> 16
	p[3] = v >> 24


int wal_get_le32(char* p):
	return (p[0] & 255) | ((p[1] & 255) << 8) | ((p[2] & 255) << 16) | ((p[3] & 255) << 24)


# Checksum of (length bytes || payload): first 4 bytes of sha256, raw.
void wal_checksum(char* len_bytes, char* payload, int len, char* out4):
	char* buf = malloc(4 + len)
	int i = 0
	while (i < 4):
		buf[i] = len_bytes[i]
		i = i + 1
	i = 0
	while (i < len):
		buf[4 + i] = payload[i]
		i = i + 1
	char* digest = malloc(32)
	sha256(buf, 4 + len, digest)
	out4[0] = digest[0]
	out4[1] = digest[1]
	out4[2] = digest[2]
	out4[3] = digest[3]
	free(digest)
	free(buf)


# Reads and validates the record at off. Returns the malloc'd payload
# (len in len_out) or 0 when the bytes at off are not a complete valid
# record — the end of the valid prefix.
char* wal_scan_record(int fd, int off, int* len_out):
	char* hdr = malloc(8)
	seek(fd, off, 0)
	if (read_exact(fd, hdr, 8) != 8):
		free(hdr)
		return 0
	int len = wal_get_le32(hdr)
	if (len < 0 || len > wal_max_record()):
		free(hdr)
		return 0
	char* payload = malloc(len + 1)
	if (read_exact(fd, payload, len) != len):
		free(payload)
		free(hdr)
		return 0
	char* sum = malloc(4)
	wal_checksum(hdr, payload, len, sum)
	int ok = 1
	int i = 0
	while (i < 4):
		if ((sum[i] & 255) != (hdr[4 + i] & 255)):
			ok = 0
		i = i + 1
	free(sum)
	free(hdr)
	if (ok == 0):
		free(payload)
		return 0
	payload[len] = 0   # convenience NUL for text payloads; not counted
	len_out[0] = len
	return payload


# ---- log lifecycle ----------------------------------------------------------

int wal_write_header(int fd):
	char* hdr = malloc(8)
	hdr[0] = 87    # W
	hdr[1] = 76    # L
	hdr[2] = 79    # O
	hdr[3] = 71    # G
	wal_put_le32(hdr + 4, wal_version())
	seek(fd, 0, 0)
	int n = write_all(fd, hdr, 8)
	free(hdr)
	if (n != 8):
		return 0
	return 1


# Opens (creating if missing) and recovers the log at path: validates
# the header, scans the valid record prefix, and positions appends to
# overwrite any torn tail. Returns 0 on open failure or a foreign /
# corrupt header.
wal* wal_open(char* path):
	int fd = open_or_create(path, 2, 420)
	if (fd < 0):
		return 0
	int size = file_size(fd)
	if (size == 0):
		if (wal_write_header(fd) == 0):
			close(fd)
			return 0
	else:
		char* hdr = malloc(8)
		seek(fd, 0, 0)
		int got = read_exact(fd, hdr, 8)
		int ok = 0
		if (got == 8 && (hdr[0] & 255) == 87 && (hdr[1] & 255) == 76 && (hdr[2] & 255) == 79 && (hdr[3] & 255) == 71):
			if (wal_get_le32(hdr + 4) == wal_version()):
				ok = 1
		free(hdr)
		if (ok == 0):
			close(fd)
			return 0
	wal* w = new wal()
	w.fd = fd
	w.path = path
	w.append_off = 8
	w.record_count = 0
	int* len_out = cast(int*, malloc(__word_size__))
	int scanning = 1
	while (scanning):
		char* payload = wal_scan_record(fd, w.append_off, len_out)
		if (payload == 0):
			scanning = 0
		else:
			free(payload)
			w.append_off = w.append_off + 8 + len_out[0]
			w.record_count = w.record_count + 1
	free(len_out)
	return w


void wal_close(wal* w):
	close(w.fd)
	free(w)


int wal_record_count(wal* w):
	return w.record_count


# Bytes in the valid prefix, header included.
int wal_size(wal* w):
	return w.append_off


# Appends one record. Returns 1 on success, 0 on a short write (the
# log object is then unusable for further appends; reopen to recover).
int wal_append(wal* w, char* payload, int len):
	assert1(len >= 0)
	assert1(len <= wal_max_record())
	char* rec = malloc(8 + len)
	wal_put_le32(rec, len)
	wal_checksum(rec, payload, len, rec + 4)
	int i = 0
	while (i < len):
		rec[8 + i] = payload[i]
		i = i + 1
	seek(w.fd, w.append_off, 0)
	int n = write_all(w.fd, rec, 8 + len)
	free(rec)
	if (n != 8 + len):
		return 0
	w.append_off = w.append_off + 8 + len
	w.record_count = w.record_count + 1
	return 1


# Flushes every appended record to stable storage (the header's
# durability boundary): fsync(2), which the Darwin wrapper upgrades
# to fcntl F_FULLFSYNC. Returns 1 on success, 0 when the kernel
# reports the flush failed.
int wal_sync(wal* w):
	if (fsync(w.fd) < 0):
		return 0
	return 1


# Truncates the log to empty (fresh header). For snapshot support:
# callers rewrite compacted state after a reset.
int wal_reset(wal* w):
	close(w.fd)
	int fd = create_file(w.path, 420)   # creat(2): truncates, write-only
	if (fd < 0):
		return 0
	int ok = wal_write_header(fd)
	close(fd)
	if (ok == 0):
		return 0
	w.fd = open(w.path, 2, 0)
	if (w.fd < 0):
		return 0
	w.append_off = 8
	w.record_count = 0
	return 1


# ---- replay -----------------------------------------------------------------

# Independent read cursor over the valid prefix of the log at path.
# Iteration ends at the first invalid record, mirroring recovery.
wal_reader* wal_reader_open(char* path):
	int fd = open(path, 0, 0)
	if (fd < 0):
		return 0
	wal_reader* rd = new wal_reader()
	rd.fd = fd
	rd.off = 8
	rd.done = 0
	char* hdr = malloc(8)
	int got = read_exact(fd, hdr, 8)
	if (got != 8 || (hdr[0] & 255) != 87 || (hdr[1] & 255) != 76 || (hdr[2] & 255) != 79 || (hdr[3] & 255) != 71):
		rd.done = 1
	free(hdr)
	return rd


# Next payload as a malloc'd buffer (NUL-terminated for convenience;
# length via len_out), or 0 at the end of the valid prefix.
char* wal_read_next(wal_reader* rd, int* len_out):
	if (rd.done):
		return 0
	char* payload = wal_scan_record(rd.fd, rd.off, len_out)
	if (payload == 0):
		rd.done = 1
		return 0
	rd.off = rd.off + 8 + len_out[0]
	return payload


void wal_reader_close(wal_reader* rd):
	close(rd.fd)
	free(rd)
