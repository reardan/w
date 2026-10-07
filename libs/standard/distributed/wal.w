/*
Checksummed append-only write-ahead log
(docs/projects/distributed.md, phase 4; durability contracts:
docs/projects/reliable_services.md, stage W1a).

The durability primitive under raft_wal.w and lsm.w: callers append
opaque payload records; on reopen the log replays the prefix of
records that were fully and correctly written.

File layout, all little-endian:
  offset 0: 4-byte magic "WLOG", 4-byte format version (1)
  then records: 4-byte payload length, 4-byte checksum, payload bytes
The checksum is the first 4 bytes of sha256 over (length bytes ||
payload), so a bit-flip in either the length field or the payload
fails validation. (A 2^-32 accidental-checksum-match on garbage is
accepted as negligible.)

Recovery policy (wal_open_policy). The scan from the header stops at
the first record that is short, has an impossible length, or fails its
checksum; that offset is the end of the valid prefix, and the scan
classifies what it found there (wal_recovery):
  WAL_TAIL_CLEAN    the prefix ends exactly at end of file.
  WAL_TAIL_TORN     incomplete trailing data: a short header or short
                    payload running into end of file, a bad-checksum
                    record that ends exactly at end of file, an
                    impossible length with nothing after its header,
                    or a bad record followed only by zero bytes (an
                    extent the filesystem grew but never filled). A
                    crash mid-append (before wal_sync returned) leaves
                    exactly this.
  WAL_TAIL_CORRUPT  corruption inside the prefix: a checksum mismatch
                    or impossible length with further non-zero bytes
                    after the bad record. Bytes past a bad record mean
                    a later write landed beyond it, so this is damage
                    to data that was once complete, not a torn append.
The file library cannot know which records an application has
acknowledged, so what happens next is the caller's policy:
  WAL_RECOVER_PERMISSIVE (the historical behaviour, kept only as an
    explicit choice; plain wal_open uses it): any bad record ends the
    prefix, everything after it is ignored, and appends overwrite it.
  WAL_RECOVER_STRICT: WAL_TAIL_CORRUPT fails the open (status
    WAL_ERR_CORRUPT, bad_offset = the first bad record). A torn tail
    is reported and left on disk untouched; the handle is then
    read-only (appends return 0) so nothing silently overwrites it.
  WAL_RECOVER_STRICT_TRUNCATE: as strict, but a torn tail is cut off
    (ftruncate + fsync) and the handle accepts appends. lsm.w and
    raft_wal.w open their logs this way: every record they ever
    acknowledged was wal_synced first, so only an unacknowledged tail
    can be torn, and dropping it is the documented contract.

Durability boundary: a successful wal_append has issued full write(2)
calls, so the record survives a process crash but sits in the kernel
page cache until wal_sync (fsync(2)) pushes it to stable storage.
A failed wal_sync POISONS the handle (wal_failed): Linux may already
have dropped the dirty pages, so a later fsync returning success would
prove nothing. Every later append and sync fails; reopen to recover.

Replacement (wal_rewrite_begin / wal_rewrite_commit): a compacted or
reset log is built in the sibling file "<path>.next" (fresh header,
then the caller's records), fsynced, renamed over path, and then the
parent directory is fsynced. A crash at any point leaves either the
complete old log or the complete new one at path; a leftover sibling
is an uncommitted rewrite and is deleted by the next open. wal_reset
is a zero-record rewrite. On commit the live handle switches to the
new file. The fs_replace_report (lib/fs.w) says which stage failed
and whether the rename already happened (renamed == 1: path names the
new log but its directory entry may not be durable yet).

Platform: the replacement path uses lib/fs.w's exclusive create and
directory sync, which are real on Linux x86/x86-64 only (the targets
these libraries are built and tested for); elsewhere they report
IO_UNSUPPORTED, so wal_reset and every rewrite fail loudly there
instead of claiming durability they cannot provide.

Record payloads are opaque bytes; wal_read_next returns malloc'd
copies the caller frees.
*/
import lib.lib
import lib.memory
import lib.assert
import lib.framing
import lib.sha256
import lib.bytes
import lib.mem
import lib.io
import lib.fs
import libs.standard.distributed.storage_io


const int wal_version = 1


# Recovery policies (header).
const int WAL_RECOVER_PERMISSIVE = 0
const int WAL_RECOVER_STRICT = 1
const int WAL_RECOVER_STRICT_TRUNCATE = 3

# Policy bit: cut a torn tail (only meaningful together with STRICT).
const int WAL_RECOVER_TRUNCATE_BIT = 2

# wal_recovery.status
const int WAL_OK = 0
const int WAL_ERR_OPEN = 1      # path could not be opened or created
const int WAL_ERR_HEADER = 2    # foreign or corrupt file header
const int WAL_ERR_CORRUPT = 3   # strict: corruption inside the prefix
const int WAL_ERR_IO = 4        # header write, truncate or sync failed

# wal_recovery.tail
const int WAL_TAIL_CLEAN = 0
const int WAL_TAIL_TORN = 1
const int WAL_TAIL_CORRUPT = 2

# wal_recovery.reason: what was wrong with the first bad record.
const int WAL_BAD_IO = 5
const int WAL_BAD_NONE = 0
const int WAL_BAD_SHORT_HEADER = 1
const int WAL_BAD_SHORT_PAYLOAD = 2
const int WAL_BAD_LENGTH = 3
const int WAL_BAD_CHECKSUM = 4


# Records larger than this are treated as corruption on scan and
# refused (return 0) on append.
int wal_max_record():
	return 1 << 24


struct wal:
	file_ops* ops
	int fd
	char* path         # caller-owned unless owned_path; must outlive the wal
	int append_off     # end of the valid prefix; next record goes here
	int record_count   # valid records in the prefix
	int readonly       # a strict open left a torn tail in place: no appends
	int failed         # sticky: a write or sync failed (header)
	char* owned_path   # freed by wal_close (rewrite siblings), else 0
	int inject_sync_failures   # test hook: fail this many upcoming syncs


struct wal_reader:
	file_ops* ops
	int failed
	int fd
	int off
	int done


struct wal_recovery:
	int status         # WAL_OK or WAL_ERR_*
	int policy         # the policy the open ran with
	int records        # records in the accepted prefix
	int valid_end      # end of the accepted prefix (header included)
	int bad_offset     # offset of the first bad record; -1 when clean
	int file_size      # size found at open
	int tail           # WAL_TAIL_*
	int reason         # WAL_BAD_*
	int truncated      # 1 when a torn tail was cut off
	int stale_sibling  # 1 when a leftover "<path>.next" was removed
	int native_error   # errno of a failing WAL_ERR_IO step, when known


# Test hooks for the replacement path (wal_rewrite_commit): when
# wal_test_crash_stage is an FS_STAGE_* value, the commit after
# wal_test_crash_skip further commits stops right BEFORE that stage as
# a crash would -- nothing cleaned up, nothing more written -- and
# returns IO_INTERRUPTED. FS_STAGE_SYNC_DIR stops after the rename (the
# live handle has switched). The hook disarms itself when it fires.
int wal_test_crash_stage
int wal_test_crash_skip


char* wal_tail_name(int tail):
	if (tail == WAL_TAIL_CLEAN): return c"clean"
	if (tail == WAL_TAIL_TORN): return c"torn"
	return c"corrupt"


# ---- record encoding --------------------------------------------------------

# Checksum of (length bytes || payload): first 4 bytes of sha256, raw.
void wal_checksum(char* len_bytes, char* payload, int len, char* out4):
	char* buf = cast(char*, malloc(4 + len))
	mem_copy(buf, len_bytes, 4)
	for i in range(len): buf[4 + i] = payload[i]
	char* digest = cast(char*, malloc(32))
	sha256(buf, 4 + len, digest)
	out4[0] = digest[0]
	out4[1] = digest[1]
	out4[2] = digest[2]
	out4[3] = digest[3]
	free(digest)
	free(buf)


# Reads and validates the record at off. Returns the malloc'd payload
# (len in len_out) or 0 when the bytes at off are not a complete valid
# record, with reason_out[0] set to the WAL_BAD_* kind and len_out[0]
# to the declared length (meaningful for WAL_BAD_CHECKSUM).
char* wal_scan_record_reason_with_ops(file_ops* ops, int fd, int off, int* len_out, int* reason_out):
	reason_out[0] = WAL_BAD_NONE
	char* hdr = cast(char*, malloc(8))
	int got = -1
	if (storage_seek(ops, fd, off, 0) >= 0): got = storage_read(ops, fd, hdr, 8)
	if (got != 8):
		free(hdr)
		reason_out[0] = WAL_BAD_SHORT_HEADER
		if (got < 0): reason_out[0] = WAL_BAD_IO
		return 0
	int len = load_le32(hdr)
	if (len < 0 || len > wal_max_record()):
		free(hdr)
		reason_out[0] = WAL_BAD_LENGTH
		return 0
	len_out[0] = len
	char* payload = cast(char*, malloc(len + 1))
	got = storage_read(ops, fd, payload, len)
	if (got != len):
		free(payload)
		free(hdr)
		reason_out[0] = WAL_BAD_SHORT_PAYLOAD
		if (got < 0): reason_out[0] = WAL_BAD_IO
		return 0
	char* sum = cast(char*, malloc(4))
	wal_checksum(hdr, payload, len, sum)
	int ok = 1
	for i in range(4):
		if ((sum[i] & 255) != (hdr[4 + i] & 255)): ok = 0
	free(sum)
	free(hdr)
	if (ok == 0):
		free(payload)
		reason_out[0] = WAL_BAD_CHECKSUM
		return 0
	payload[len] = 0   # convenience NUL for text payloads; not counted
	return payload


char* wal_scan_record_with_ops(file_ops* ops, int fd, int off, int* len_out):
	int reason = 0
	return wal_scan_record_reason_with_ops(ops, fd, off, len_out, &reason)


# 1 when every byte of [off, end) reads as zero.
int wal_all_zero_with_ops(file_ops* ops, int fd, int off, int end):
	char* buf = cast(char*, malloc(4096))
	int pos = off
	int zero = 1
	while (pos < end && zero == 1):
		int want = end - pos
		if (want > 4096): want = 4096
		int got = -1
		if (storage_seek(ops, fd, pos, 0) >= 0): got = storage_read(ops, fd, buf, want)
		if (got != want): zero = 0
		else:
			for i in range(want):
				if (buf[i] != 0): zero = 0
		pos = pos + want
	free(buf)
	return zero


# WAL_TAIL_TORN or WAL_TAIL_CORRUPT for a bad record at off (header).
int wal_classify_bad_with_ops(file_ops* ops, int fd, int off, int size, int reason, int declared_len):
	if (reason == WAL_BAD_SHORT_HEADER || reason == WAL_BAD_SHORT_PAYLOAD): return WAL_TAIL_TORN
	int extent_end = off + 8
	if (reason == WAL_BAD_CHECKSUM): extent_end = off + 8 + declared_len
	if (extent_end >= size): return WAL_TAIL_TORN
	if (wal_all_zero_with_ops(ops, fd, off, size)): return WAL_TAIL_TORN
	return WAL_TAIL_CORRUPT


# ---- log lifecycle ----------------------------------------------------------

int wal_write_header_with_ops(file_ops* ops, int fd):
	char* hdr = cast(char*, malloc(8))
	hdr[0] = 87    # W
	hdr[1] = 76    # L
	hdr[2] = 79    # O
	hdr[3] = 71    # G
	store_le32(hdr + 4, wal_version)
	if (storage_seek(ops, fd, 0, 0) < 0):
		free(hdr)
		return 0
	int n = storage_write(ops, fd, hdr, 8)
	free(hdr)
	if (n != 8): return 0
	return 1


wal* wal_new_handle_with_ops(file_ops* ops, int fd, char* path):
	wal* w = new wal()
	w.ops = ops
	w.fd = fd
	w.path = path
	w.append_off = 8
	w.record_count = 0
	w.readonly = 0
	w.failed = 0
	w.owned_path = 0
	w.inject_sync_failures = 0
	return w


# The rewrite sibling "<path>.next", malloc'd.
char* wal_sibling_path(char* path):
	return strjoin(path, c".next")


void wal_recovery_init(wal_recovery* rep, int policy):
	rep.status = WAL_OK
	rep.policy = policy
	rep.records = 0
	rep.valid_end = 0
	rep.bad_offset = 0 - 1
	rep.file_size = 0
	rep.tail = WAL_TAIL_CLEAN
	rep.reason = WAL_BAD_NONE
	rep.truncated = 0
	rep.stale_sibling = 0
	rep.native_error = 0


wal* wal_open_fail_with_ops(file_ops* ops, wal_recovery* rep, int fd, int status):
	if (fd >= 0): storage_close(ops, fd)
	rep.status = status
	return 0


# Opens (creating if missing) and recovers the log at path under
# policy (header), filling rep (which may be 0). A leftover rewrite
# sibling is deleted first. Returns the handle, or 0 with rep.status
# saying why: unopenable path, foreign/corrupt header, strict-mode
# corruption inside the prefix (rep.bad_offset), or a failed torn-tail
# truncate.
wal* wal_open_policy_with_ops(file_ops* ops, char* path, int policy, wal_recovery* rep):
	wal_recovery local
	if (cast(int, rep) == 0): rep = &local
	wal_recovery_init(rep, policy)
	char* sibling = wal_sibling_path(path)
	if (storage_unlink(ops, sibling) == 0): rep.stale_sibling = 1
	free(sibling)
	int fd = storage_open(ops, path, FILE_OPS_READ_WRITE | FILE_OPS_CREATE, 420)
	if (fd < 0): return wal_open_fail_with_ops(ops, rep, 0 - 1, WAL_ERR_OPEN)
	int size = storage_size(ops, fd)
	if (size < 0): return wal_open_fail_with_ops(ops, rep, fd, WAL_ERR_IO)
	rep.file_size = size
	if (size == 0):
		if (wal_write_header_with_ops(ops, fd) == 0): return wal_open_fail_with_ops(ops, rep, fd, WAL_ERR_IO)
		size = 8
	else:
		char* hdr = cast(char*, malloc(8))
		int got = -1
		if (storage_seek(ops, fd, 0, 0) >= 0): got = storage_read(ops, fd, hdr, 8)
		int ok = 0
		if (got == 8 && (hdr[0] & 255) == 87 && (hdr[1] & 255) == 76 && (hdr[2] & 255) == 79 && (hdr[3] & 255) == 71):
			if (load_le32(hdr + 4) == wal_version): ok = 1
		free(hdr)
		if (ok == 0): return wal_open_fail_with_ops(ops, rep, fd, WAL_ERR_HEADER)
	wal* w = wal_new_handle_with_ops(ops, fd, path)
	int len = 0
	int reason = 0
	int scanning = 1
	while (scanning):
		char* payload = wal_scan_record_reason_with_ops(ops, fd, w.append_off, &len, &reason)
		if (payload == 0): scanning = 0
		else:
			free(payload)
			w.append_off = w.append_off + 8 + len
			w.record_count = w.record_count + 1
	if (reason == WAL_BAD_IO):
		free(w)
		return wal_open_fail_with_ops(ops, rep, fd, WAL_ERR_IO)
	rep.records = w.record_count
	rep.valid_end = w.append_off
	if (w.append_off < size):
		rep.bad_offset = w.append_off
		rep.reason = reason
		rep.tail = wal_classify_bad_with_ops(ops, fd, w.append_off, size, reason, len)
	if ((policy & WAL_RECOVER_STRICT) == 0): return w
	if (rep.tail == WAL_TAIL_CORRUPT):
		free(w)
		return wal_open_fail_with_ops(ops, rep, fd, WAL_ERR_CORRUPT)
	if (rep.tail == WAL_TAIL_TORN):
		if ((policy & WAL_RECOVER_TRUNCATE_BIT) == 0):
			w.readonly = 1
			return w
		io_result r
		int status = storage_truncate(ops, fd, w.append_off, &r)
		if (status == IO_OK): status = storage_sync(ops, fd, &r)
		if (status != IO_OK):
			rep.native_error = r.native_error
			free(w)
			return wal_open_fail_with_ops(ops, rep, fd, WAL_ERR_IO)
		rep.truncated = 1
	return w


# Permissive open (WAL_RECOVER_PERMISSIVE; the historical contract):
# any bad record silently ends the prefix and appends overwrite it.
# Returns 0 on open failure or a foreign / corrupt header.
wal* wal_open_policy(char* path, int policy, wal_recovery* rep):
	return wal_open_policy_with_ops(cast(file_ops*, 0), path, policy, rep)


wal* wal_open(char* path):
	return wal_open_policy_with_ops(cast(file_ops*, 0), path, WAL_RECOVER_PERMISSIVE, cast(wal_recovery*, 0))


void wal_close(wal* w):
	storage_close(w.ops, w.fd)
	if (w.owned_path != 0): free(w.owned_path)
	free(w)


int wal_record_count(wal* w):
	return w.record_count


# Bytes in the valid prefix, header included.
int wal_size(wal* w):
	return w.append_off


# 1 once a write or sync failed (the handle refuses further work).
int wal_failed(wal* w):
	return w.failed


# Test hook: the next n wal_sync calls on w fail as a failed fsync
# would (and so poison w).
void wal_inject_sync_failures(wal* w, int n):
	w.inject_sync_failures = n


# Appends one record. Returns 1 on success, 0 when refused (a negative
# or oversized length, a read-only or failed handle) or on a short
# write (which poisons the handle; reopen to recover).
int wal_append(wal* w, char* payload, int len):
	if (len < 0 || len > wal_max_record()): return 0
	if (w.readonly || w.failed): return 0
	char* rec = cast(char*, malloc(8 + len))
	store_le32(rec, len)
	wal_checksum(rec, payload, len, rec + 4)
	for i in range(len): rec[8 + i] = payload[i]
	if (storage_seek(w.ops, w.fd, w.append_off, 0) < 0):
		free(rec)
		w.failed = 1
		return 0
	int n = storage_write(w.ops, w.fd, rec, 8 + len)
	free(rec)
	if (n != 8 + len):
		w.failed = 1
		return 0
	w.append_off = w.append_off + 8 + len
	w.record_count = w.record_count + 1
	return 1


# Flushes every appended record to stable storage (the header's
# durability boundary): fsync(2). Returns 1 on success, 0 when the
# kernel reports the flush failed -- which poisons the handle (header).
int wal_sync(wal* w):
	if (w.failed): return 0
	if (w.inject_sync_failures > 0):
		w.inject_sync_failures = w.inject_sync_failures - 1
		w.failed = 1
		return 0
	io_result r
	if (storage_sync(w.ops, w.fd, &r) != IO_OK || storage_sync_parent(w.ops, w.path, &r) != IO_OK):
		w.failed = 1
		return 0
	return 1


# ---- replacement (header) ---------------------------------------------------

# Starts a replacement for live: a fresh, empty log at the sibling
# "<live.path>.next" (a stale sibling is removed first; the create is
# exclusive). Append the new contents to the returned handle, then
# wal_rewrite_commit or wal_rewrite_abort it. Returns 0 when the
# sibling cannot be created or its header written.
wal* wal_rewrite_begin(wal* live):
	char* npath = wal_sibling_path(live.path)
	storage_unlink(live.ops, npath)
	int fd = storage_open(live.ops, npath, FILE_OPS_READ_WRITE | FILE_OPS_CREATE | FILE_OPS_EXCLUSIVE, 420)
	if (fd < 0):
		free(npath)
		return 0
	if (wal_write_header_with_ops(live.ops, fd) == 0):
		storage_close(live.ops, fd)
		storage_unlink(live.ops, npath)
		free(npath)
		return 0
	wal* n = wal_new_handle_with_ops(live.ops, fd, npath)
	n.owned_path = npath
	return n


# Discards an uncommitted replacement: closes and deletes the sibling.
void wal_rewrite_abort(wal* next):
	storage_close(next.ops, next.fd)
	storage_unlink(next.ops, next.path)
	free(next.owned_path)
	free(next)


int wal_rewrite_fail(fs_replace_report* rep, int stage, int status, int native_error):
	rep.stage = stage
	rep.status = status
	rep.native_error = native_error
	return status


# Consumes the test crash hook for this commit: the FS_STAGE_* to stop
# before, or FS_STAGE_NONE.
int wal_rewrite_crash_point():
	if (wal_test_crash_stage == FS_STAGE_NONE): return FS_STAGE_NONE
	if (wal_test_crash_skip > 0):
		wal_test_crash_skip = wal_test_crash_skip - 1
		return FS_STAGE_NONE
	int stage = wal_test_crash_stage
	wal_test_crash_stage = FS_STAGE_NONE
	return stage


# Simulated crash before stage: the sibling stays on disk as written.
int wal_rewrite_crash(wal* next, fs_replace_report* rep, int stage):
	storage_close(next.ops, next.fd)
	free(next.owned_path)
	free(next)
	return wal_rewrite_fail(rep, stage, IO_INTERRUPTED, 0)


# Publishes next as live's contents: fsync the sibling, rename it over
# live.path, switch live's handle to it, fsync the parent directory.
# Consumes next either way. Returns IO_OK once the new log is durable
# at live.path; otherwise the failing status with rep filled
# (lib/fs.w's fs_replace_report). rep.renamed == 0: live and its file
# are untouched and the sibling is gone. rep.renamed == 1: live
# already reads and appends the new log, but the rename's durability
# is unknown -- treat it as a failure to make the new contents durable.
int wal_rewrite_commit(wal* live, wal* next, fs_replace_report* rep):
	rep.status = IO_OK
	rep.native_error = 0
	rep.stage = FS_STAGE_NONE
	rep.renamed = 0
	rep.transferred = next.append_off
	int crash = wal_rewrite_crash_point()
	if (next.failed):
		wal_rewrite_abort(next)
		return wal_rewrite_fail(rep, FS_STAGE_WRITE, IO_IO_ERROR, 0)
	if (crash == FS_STAGE_SYNC_FILE): return wal_rewrite_crash(next, rep, crash)
	io_result synced
	io_result_set(&synced, 0, IO_IO_ERROR, 0)
	if (next.inject_sync_failures > 0 || storage_sync(next.ops, next.fd, &synced) != IO_OK):
		wal_rewrite_abort(next)
		return wal_rewrite_fail(rep, FS_STAGE_SYNC_FILE, synced.status, synced.native_error)
	if (crash == FS_STAGE_RENAME): return wal_rewrite_crash(next, rep, crash)
	io_result r
	if (storage_rename(live.ops, next.path, live.path, &r) != IO_OK):
		wal_rewrite_abort(next)
		return wal_rewrite_fail(rep, FS_STAGE_RENAME, r.status, r.native_error)
	rep.renamed = 1
	storage_close(live.ops, live.fd)
	live.fd = next.fd
	live.append_off = next.append_off
	live.record_count = next.record_count
	live.readonly = 0
	live.failed = 0
	free(next.owned_path)
	free(next)
	if (crash == FS_STAGE_SYNC_DIR): return wal_rewrite_fail(rep, FS_STAGE_SYNC_DIR, IO_INTERRUPTED, 0)
	int status = storage_sync_parent(live.ops, live.path, &r)
	if (status != IO_OK):
		live.failed = 1
		return wal_rewrite_fail(rep, FS_STAGE_SYNC_DIR, status, r.native_error)
	return IO_OK


# Atomically and durably replaces the log with an empty one (a
# zero-record wal_rewrite_commit). Returns 1 on success, 0 on failure
# (rep semantics as wal_rewrite_commit: the log is either still the
# old one or already the empty one).
int wal_reset(wal* w):
	wal* next = wal_rewrite_begin(w)
	if (cast(int, next) == 0): return 0
	fs_replace_report rep
	if (wal_rewrite_commit(w, next, &rep) != IO_OK): return 0
	return 1


# ---- replay -----------------------------------------------------------------

# Independent read cursor over the valid prefix of the log at path.
# Iteration ends at the first invalid record, mirroring recovery (a
# strict open has already refused or reported anything past it).
wal_reader* wal_reader_open_with_ops(file_ops* ops, char* path):
	int fd = storage_open(ops, path, 0, 0)
	if (fd < 0): return 0
	wal_reader* rd = new wal_reader(ops, 0, fd, 8, 0)
	char* hdr = cast(char*, malloc(8))
	int got = storage_read(ops, fd, hdr, 8)
	if (got != 8 || (hdr[0] & 255) != 87 || (hdr[1] & 255) != 76 || (hdr[2] & 255) != 79 || (hdr[3] & 255) != 71):
		rd.done = 1
		rd.failed = 1
	free(hdr)
	return rd


# Next payload as a malloc'd buffer (NUL-terminated for convenience;
# length via len_out), or 0 at the end of the valid prefix.
char* wal_read_next(wal_reader* rd, int* len_out):
	if (rd.done): return 0
	int reason = 0
	char* payload = wal_scan_record_reason_with_ops(rd.ops, rd.fd, rd.off, len_out, &reason)
	if (reason == WAL_BAD_IO): rd.failed = 1
	if (payload == 0):
		rd.done = 1
		return 0
	rd.off = rd.off + 8 + len_out[0]
	return payload


void wal_reader_close(wal_reader* rd):
	storage_close(rd.ops, rd.fd)
	free(rd)


char* wal_scan_record_reason(int fd, int off, int* len_out, int* reason_out):
	return wal_scan_record_reason_with_ops(cast(file_ops*, 0), fd, off, len_out, reason_out)


char* wal_scan_record(int fd, int off, int* len_out):
	return wal_scan_record_with_ops(cast(file_ops*, 0), fd, off, len_out)


int wal_all_zero(int fd, int off, int end):
	return wal_all_zero_with_ops(cast(file_ops*, 0), fd, off, end)


int wal_classify_bad(int fd, int off, int size, int reason, int declared_len):
	return wal_classify_bad_with_ops(cast(file_ops*, 0), fd, off, size, reason, declared_len)


int wal_write_header(int fd):
	return wal_write_header_with_ops(cast(file_ops*, 0), fd)


wal* wal_new_handle(int fd, char* path):
	return wal_new_handle_with_ops(cast(file_ops*, 0), fd, path)


wal* wal_open_fail(wal_recovery* rep, int fd, int status):
	return wal_open_fail_with_ops(cast(file_ops*, 0), rep, fd, status)



wal_reader* wal_reader_open(char* path):
	return wal_reader_open_with_ops(cast(file_ops*, 0), path)
