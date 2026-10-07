/*
Persistence adapter binding raft.w's persistent state (current_term,
voted_for, log — the Figure 2 trio) to the checksummed append-only log
in wal.w (docs/projects/distributed.md, phase 4).

raft.w is a pure state machine and never calls out, so the adapter
OBSERVES instead of hooking: after every raft_tick / raft_on_msg /
raft_propose burst the caller invokes raft_wal_sync(rw, r), which
diffs the raft's persistent trio against the adapter's shadow copy,
appends one record per change, and wal_syncs (fsync) the log whenever
it wrote — a returned sync is durable to stable storage, the property
Raft's correctness argument assumes. Crash recovery replays the records into
a fresh raft (raft_wal_recover); volatile state (commit_index,
last_applied, role, timers) intentionally stays at its raft_new zero —
it re-derives from the leader, which is correct per the paper.

Record encoding, one record per wal payload (little-endian; u64 via
u64_save_le/u64_load_le):
  tag 1 STATE:    1 tag byte + 8-byte term + 4-byte voted_for
  tag 2 APPEND:   1 tag byte + 1-byte entry kind (raft_entry_kind_
                  normal/config, issue #319) + 8-byte entry term +
                  4-byte command length + command bytes (one record
                  per entry, in log order; command is opaque, embedded
                  NULs legal — the length field, raft_entry.
                  command_len, is authoritative, never strlen)
  tag 3 TRUNCATE: 1 tag byte + 4-byte keep_count (the log keeps the
                  first keep_count entries above the snapshot base —
                  with no snapshot that is conceptual entries
                  1..keep_count; later entries are discarded)
  tag 4 SNAPSHOT: 1 tag byte + 8-byte snap_last_index + 8-byte
                  snap_last_term + 4-byte config_count + 4-byte config
                  ids (the FULL member set at the snapshot, self-
                  inclusive — raft.w's §4.1 membership header, new
                  since phase 6/issue #319) + 4-byte blob length +
                  blob bytes (raft.w §7 log compaction; the blob is
                  opaque binary, embedded NULs legal)

voted_for encoding: raft's "none" sentinel is 0 - 1, which has no
clean unsigned wire form, so the field is stored biased — none is
written as 0 and a real node id as id + 1. The wire value is always
non-negative and the decoder subtracts the bias back off.

Diff rules in raft_wal_sync:
  - term or voted_for changed -> one STATE record carrying BOTH (the
    term is always rewritten with the vote, so a record never leaves
    the pair split across a crash).
  - log: find the first conceptual index where the shadow's entry
    terms and the raft log disagree, or where one side ends. Shadow
    entries past that agreement point -> TRUNCATE(agreement length)
    first; then one APPEND per raft entry from agreement + 1 to the
    end. Term-only comparison is sound for a genuine raft: an entry is
    only ever replaced (raft_handle_append's conflict path) by an
    entry of a DIFFERENT term at the same index.
  - ORDER: STATE is persisted before any log record in the same sync —
    term/vote safety dominates (a vote must never be forgotten while
    log entries acknowledging it survive).
  - snapshot: a raft snap_last_index ahead of the shadow's REWRITES
    the wal (the compaction payoff): one SNAPSHOT record, then one
    STATE record, then one APPEND per entry still in the log, built
    in the sibling "<path>.next" and published by wal_rewrite_commit
    (fsync sibling, rename over the live log, fsync the directory) --
    a crash at any stage leaves the complete old log or the complete
    new one, never a reset-but-unwritten log. The return value counts
    the rewrite's records. Syncs
    with unchanged snapshot meta behave exactly as before. All entry
    bookkeeping (shadow entry_terms, TRUNCATE keep counts, APPEND
    order) is relative to the current snapshot base on both sides, so
    the diff rules above carry over unchanged.

Snapshot recovery: replaying a SNAPSHOT record resets the replay
state — accumulated entries are discarded, the raft's snapshot meta
is installed, commit_index and last_applied jump to the snapshot
index (the snapshot's state is by definition committed and applied),
and the blob lands in BOTH the raft's own snap_data and its PENDING
slot. After raft_wal_recover the application must therefore
raft_take_pending_snapshot (re-installing its state-machine state)
BEFORE any raft_pop_apply, exactly mirroring the network install
path. Entries recorded after the snapshot replay as before.

Commands are raft.w client commands: opaque, length-carrying byte
buffers (raft_entry.command_len is authoritative, never strlen — see
raft.w). raft_entry_new COPIES cmd_len bytes straight out of the
replayed wal record, so replay reads the record buffer directly with
no intermediate malloc'd copy. Entries own their command bytes
(raft_entry_free releases them), so a TRUNCATE or SNAPSHOT replay that
pops entries needs nothing beyond raft_entry_free — no separate
command free, and no leak-by-design.

The shadow (term, vote, one u64 term per log entry) is rebuilt from
the wal's valid record prefix at open time, so a sync issued right
after recovery appends nothing. The adapter assumes it is the only
writer of its wal file.

Cluster membership replay (issue #319; raft.w's §4.1 membership
header): raft_wal_replay_into's APPEND/TRUNCATE handling calls the
SAME raft.w hooks (raft_note_entry_appended, raft_note_truncated_to)
that live raft_propose_internal/raft_handle_append use, so replaying
the persisted record sequence reconstructs byte-identical peer-set
history to what was live before the crash — the peer set is never
recomputed from scratch, only replayed. A SNAPSHOT record's config_
count/ids (new field, this issue) are adopted via raft_adopt_
snapshot_config exactly as a network InstallSnapshot would be.

Checked failures and reply gating (docs/projects/reliable_services.md,
stage W1a): raft_wal_persist is the checked form of the sync -- it
returns an IO_* status instead of asserting. Any failure (a short
append, a failed fsync, a failed rewrite) POISONS the adapter
(raft_wal_failed): the on-disk state relative to the shadow is no
longer known, so every later persist fails until the node reopens and
recovers. raft_wal_persist_release is the reply-side contract: the
messages a raft burst emitted are held in the adapter's durable_gate
and handed to the transport only after the burst's state is durable;
on failure they are freed undelivered -- a failed sync can never
release a buffered success. raft_wal_sync keeps its historical
count-returning signature as a fail-stop wrapper (asserts success).

Recovery policy: raft_wal_open opens the log WAL_RECOVER_STRICT_
TRUNCATE (wal.w): a torn tail (never acknowledged -- every
acknowledged record was fsynced before its reply left) is cut off,
while corruption inside the durable prefix fails the open instead of
silently forgetting votes or entries that were acknowledged.
raft_wal_open_policy takes another policy and reports the scan. A
malformed record payload (a foreign writer) also fails the open.
*/
import lib.lib
import lib.memory
import lib.assert
import libs.standard.distributed.u64
import libs.standard.distributed.wal
import libs.standard.distributed.raft
import libs.standard.distributed.durable_gate
import lib.bytes
import lib.io
import lib.fs


# ---- record tags --------------------------------------------------------------

const int raft_wal_tag_state = 1
const int raft_wal_tag_append = 2
const int raft_wal_tag_truncate = 3
const int raft_wal_tag_snapshot = 4
const int raft_wal_tag_stream_begin = 5
const int raft_wal_tag_stream_chunk = 6
const int raft_wal_tag_stream_end = 7


# ---- adapter state --------------------------------------------------------------

struct raft_wal:
	int stream_total
	int stream_offset
	wal* wlog               # the underlying append-only log
	char* path              # owned copy; wlog.path points at it
	u64* term               # shadow: last persisted current_term
	int voted_for           # shadow: last persisted vote (0 - 1 = none)
	list[u64*] entry_terms  # shadow: term of every persisted entry above the base (owned)
	u64* snap_index         # shadow: last persisted snapshot index (0 = none)
	u64* snap_term          # shadow: last persisted snapshot term
	int failed              # sticky: a persist failed (header); reopen to recover
	durable_gate* gate      # replies waiting for their burst to be durable
	int persist_seq         # sequence of the last persist_release burst


# ---- small helpers ---------------------------------------------------------------

# voted_for wire bias (header): none (0 - 1) -> 0, id -> id + 1.
int raft_wal_encode_vote(int voted_for):
	if (voted_for == (0 - 1)): return 0
	assert1(voted_for >= 0)
	return voted_for + 1


int raft_wal_decode_vote(int wire):
	assert1(wire >= 0)
	if (wire == 0): return 0 - 1
	return wire - 1


# ---- shadow replay ----------------------------------------------------------------

# Fold one persisted record into the shadow. Returns 1, or 0 when the
# payload is malformed: the wal's checksum already rejected torn or
# corrupt records, so a malformed payload here means a foreign writer
# and raft_wal_open refuses the log.
int raft_wal_shadow_apply(raft_wal* rw, char* p, int len):
	if (len < 1): return 0
	int tag = p[0] & 255
	if (tag == raft_wal_tag_stream_begin):
		if (rw.stream_total != 0 || len < 29): return 0
		int count = load_le32(p + 17)
		if (count < 0 || count > RAFT_SNAPSHOT_MEMBERS || len != 29 + 4 * count): return 0
		int total = load_le32(p + 21 + 4 * count)
		if (total <= 0 || total > SNAPSHOT_FILE_LIMIT): return 0
		list[int] cfg = new list[int]
		for i in range(count): cfg.push(raft_config_load_token(p + 21 + 4 * i))
		int valid = raft_config_valid(cfg)
		cfg.free()
		if (valid == 0): return 0
		u64_load_le(rw.snap_index, p + 1)
		u64_load_le(rw.snap_term, p + 9)
		while (rw.entry_terms.length > 0): u64_free(rw.entry_terms.pop())
		rw.stream_total = total
		rw.stream_offset = 0
		return 1
	if (tag == raft_wal_tag_stream_chunk):
		if (rw.stream_total == 0 || len < 6 || len > SNAPSHOT_FILE_CHUNK + 5 || load_le32(p + 1) != rw.stream_offset || len - 5 > rw.stream_total - rw.stream_offset): return 0
		rw.stream_offset = rw.stream_offset + len - 5
		return 1
	if (tag == raft_wal_tag_stream_end):
		if (len != 1 || rw.stream_total == 0 || rw.stream_offset != rw.stream_total): return 0
		rw.stream_total = 0
		rw.stream_offset = 0
		return 1
	if (rw.stream_total != 0): return 0
	if (tag == raft_wal_tag_state):
		if (len != 13): return 0
		int wire = load_le32(p + 9)
		if (wire < 0): return 0
		u64_load_le(rw.term, p + 1)
		rw.voted_for = raft_wal_decode_vote(wire)
		return 1
	if (tag == raft_wal_tag_append):
		if (len < 14): return 0
		if (load_le32(p + 10) != len - 14): return 0
		int kind = p[1] & 255
		if (kind != raft_entry_kind_normal() && kind != raft_entry_kind_config()): return 0
		if (kind == raft_entry_kind_config() && raft_config_command_valid(p + 14, len - 14) == 0): return 0
		u64* t = u64_new()
		u64_load_le(t, p + 2)
		rw.entry_terms.push(t)
		return 1
	if (tag == raft_wal_tag_truncate):
		if (len != 5): return 0
		int keep = load_le32(p + 1)
		if (keep < 0 || keep > rw.entry_terms.length): return 0
		while (rw.entry_terms.length > keep):
			u64* dropped = rw.entry_terms.pop()
			u64_free(dropped)
		return 1
	if (tag == raft_wal_tag_snapshot):
		if (len < 25): return 0
		int ccount = load_le32(p + 17)
		if (ccount < 0 || ccount > RAFT_SNAPSHOT_MEMBERS || ccount > (len - 25) / 4): return 0
		int coff = 21 + 4 * ccount
		if (len < coff + 4): return 0
		if (load_le32(p + coff) != len - coff - 4): return 0
		list[int] cfg = new list[int]
		for i in range(ccount): cfg.push(raft_config_load_token(p + 21 + 4 * i))
		int valid = raft_config_valid(cfg)
		cfg.free()
		if (valid == 0): return 0
		u64_load_le(rw.snap_index, p + 1)
		u64_load_le(rw.snap_term, p + 9)
		# the snapshot covers (and a rewrite drops) every prior entry
		while (rw.entry_terms.length > 0):
			u64* gone = rw.entry_terms.pop()
			u64_free(gone)
		return 1
	return 0


# ---- lifecycle -------------------------------------------------------------------

# Closes the wal and frees the shadow. The list storage itself is
# runtime-managed (matching raft_free in raft.w).
void raft_wal_close(raft_wal* rw):
	wal_close(rw.wlog)
	while (rw.entry_terms.length > 0):
		u64* t = rw.entry_terms.pop()
		u64_free(t)
	u64_free(rw.term)
	u64_free(rw.snap_index)
	u64_free(rw.snap_term)
	durable_gate_free(rw.gate)
	free(rw.path)
	free(rw)


# Opens (creating if missing) and recovers the wal at path under the
# wal.w recovery policy, filling rep (may be 0) with the scan report,
# then rebuilds the shadow by replaying the valid record prefix -- so a
# sync issued after recovery only appends genuine changes. Returns 0
# when wal_open_policy fails (unopenable path, foreign or corrupt
# header, strict-mode corruption inside the prefix) or a record
# payload is malformed.
raft_wal* raft_wal_open_policy_with_ops(file_ops* ops, char* path, int policy, wal_recovery* rep):
	char* own = strclone(path)
	wal* w = wal_open_policy_with_ops(ops, own, policy, rep)
	if (cast(int, w) == 0):
		free(own)
		return 0
	raft_wal* rw = new raft_wal()
	rw.wlog = w
	rw.path = own
	rw.term = u64_new()
	rw.voted_for = 0 - 1
	rw.entry_terms = new list[u64*]
	rw.snap_index = u64_new()
	rw.snap_term = u64_new()
	rw.failed = 0
	rw.gate = durable_gate_new()
	rw.persist_seq = 0
	wal_reader* rd = wal_reader_open_with_ops(ops, own)
	if (cast(int, rd) == 0):
		raft_wal_close(rw)
		return 0
	int ok = 1
	int len = 0
	char* p = wal_read_next(rd, &len)
	while (p != 0):
		if (ok == 1 && raft_wal_shadow_apply(rw, p, len) == 0): ok = 0
		free(p)
		p = wal_read_next(rd, &len)
	if (rd.failed || rw.stream_total != 0): ok = 0
	wal_reader_close(rd)
	if (ok == 0):
		raft_wal_close(rw)
		return 0
	return rw


# Native convenience wrapper; injected constructors borrow their ops.
raft_wal* raft_wal_open_policy(char* path, int policy, wal_recovery* rep):
	return raft_wal_open_policy_with_ops(cast(file_ops*, 0), path, policy, rep)


raft_wal* raft_wal_open(char* path):
	return raft_wal_open_policy(path, WAL_RECOVER_STRICT_TRUNCATE, cast(wal_recovery*, 0))


# 1 once a persist failed; the adapter then refuses every write.
int raft_wal_failed(raft_wal* rw):
	return rw.failed


# ---- diffing ---------------------------------------------------------------------

# Length of the longest prefix on which the shadow's entry terms and
# the raft's log agree (same term at every conceptual index).
int raft_wal_agree_len(raft_wal* rw, raft* r):
	int n = rw.entry_terms.length
	if (r.log.length < n): n = r.log.length
	for i in range(n):
		raft_entry* e = r.log[i]
		if (u64_eq(rw.entry_terms[i], e.term) == 0):
			return i
	return n


# 1 when a sync would append records — a pure diff check, no writes.
# A snapshot difference is checked FIRST: while the bases differ the
# entry_terms/log comparison below would misalign (both sides count
# entries relative to their own base).
int raft_wal_pending(raft_wal* rw, raft* r):
	if (u64_eq(rw.snap_index, r.snap_last_index) == 0): return 1
	if (u64_eq(rw.term, r.current_term) == 0): return 1
	if (rw.voted_for != r.voted_for): return 1
	int agree = raft_wal_agree_len(rw, r)
	if (rw.entry_terms.length != agree): return 1
	if (r.log.length != agree): return 1
	return 0


# ---- record writers (target is the live wal or a rewrite sibling) ---------------

# One STATE record carrying the raft's current term and vote.
# Returns wal_append's result (1 ok, 0 failed).
int raft_wal_write_state(wal* target, raft* r):
	char* srec = cast(char*, malloc(13))
	srec[0] = raft_wal_tag_state
	u64_save_le(srec + 1, r.current_term)
	store_le32(srec + 9, raft_wal_encode_vote(r.voted_for))
	int ok = wal_append(target, srec, 13)
	free(srec)
	return ok


# One APPEND record for the log entry at storage index i, carrying the
# entry's kind (raft_entry_kind_normal/config, issue #319) so replay
# reconstructs it exactly.
int raft_wal_write_append(wal* target, raft* r, int i):
	raft_entry* e = r.log[i]
	int cmd_len = e.command_len
	char* arec = cast(char*, malloc(14 + cmd_len))
	arec[0] = raft_wal_tag_append
	arec[1] = e.kind
	u64_save_le(arec + 2, e.term)
	store_le32(arec + 10, cmd_len)
	for k in range(cmd_len): arec[14 + k] = e.command[k]
	int ok = wal_append(target, arec, 14 + cmd_len)
	free(arec)
	return ok


# File snapshots use bounded WAL records; atomic rewrite makes BEGIN..END
# visible together. No external filename is a dependency of durable recovery.
int raft_wal_write_snapshot_file(wal* target, raft* r):
	int count = r.snap_config.length
	int size = 29 + 4 * count
	char* header = malloc(size)
	header[0] = raft_wal_tag_stream_begin
	u64_save_le(header + 1, r.snap_last_index)
	u64_save_le(header + 9, r.snap_last_term)
	store_le32(header + 17, count)
	for i in range(count): store_le32(header + 21 + i * 4, r.snap_config[i])
	store_le32(header + 21 + 4 * count, r.snap_len)
	store_le32(header + 25 + 4 * count, r.snap_hash)
	int ok = wal_append(target, header, size)
	free(header)
	char* chunk = malloc(SNAPSHOT_FILE_CHUNK + 5)
	chunk[0] = raft_wal_tag_stream_chunk
	int offset = 0
	while (ok && offset < r.snap_len):
		int take = r.snap_len - offset
		if (take > SNAPSHOT_FILE_CHUNK): take = SNAPSHOT_FILE_CHUNK
		store_le32(chunk + 1, offset)
		ok = snapshot_file_read(r.snap_file, offset, chunk + 5, take)
		if (ok): ok = wal_append(target, chunk, take + 5)
		offset = offset + take
	chunk[0] = raft_wal_tag_stream_end
	if (ok): ok = wal_append(target, chunk, 1)
	free(chunk)
	return ok


# One SNAPSHOT record: meta + config + blob.
int raft_wal_write_snapshot(wal* target, raft* r):
	if (cast(int, r.snap_file) != 0): return raft_wal_write_snapshot_file(target, r)
	int blob_len = r.snap_len
	int ccount = r.snap_config.length
	int coff = 21 + 4 * ccount
	char* nrec = cast(char*, malloc(coff + 4 + blob_len))
	nrec[0] = raft_wal_tag_snapshot
	u64_save_le(nrec + 1, r.snap_last_index)
	u64_save_le(nrec + 9, r.snap_last_term)
	store_le32(nrec + 17, ccount)
	for ci in range(ccount): store_le32(nrec + 21 + 4 * ci, r.snap_config[ci])
	store_le32(nrec + coff, blob_len)
	for b in range(blob_len): nrec[coff + 4 + b] = r.snap_data[b]
	int ok = wal_append(target, nrec, coff + 4 + blob_len)
	free(nrec)
	return ok


# The shadow now mirrors r exactly (after a rewrite was published).
void raft_wal_shadow_reset_to(raft_wal* rw, raft* r):
	u64_copy(rw.snap_index, r.snap_last_index)
	u64_copy(rw.snap_term, r.snap_last_term)
	u64_copy(rw.term, r.current_term)
	rw.voted_for = r.voted_for
	while (rw.entry_terms.length > 0):
		u64* dropped = rw.entry_terms.pop()
		u64_free(dropped)
	int i = 0
	while (i < r.log.length):
		raft_entry* e = r.log[i]
		rw.entry_terms.push(u64_clone(e.term))
		i = i + 1


# The raft's snapshot advanced past the shadow's: compact the wal
# itself (header). The complete compacted state -- one SNAPSHOT record
# (meta + config + blob), one STATE record, one APPEND per retained
# entry -- is written to the sibling log and published with
# wal_rewrite_commit (fsync, rename, directory fsync). Returns IO_OK
# with wrote_out[0] = records written, or the failing status with rep
# filled (lib/fs.w's fs_replace_report): rep.renamed == 0 leaves the old
# log and the shadow untouched; rep.renamed == 1 means the live log
# (and the shadow) already hold the new contents but their durability
# is unknown.
int raft_wal_rewrite_checked(raft_wal* rw, raft* r, int* wrote_out, fs_replace_report* rep):
	wrote_out[0] = 0
	rep.status = IO_OK
	rep.native_error = 0
	rep.stage = FS_STAGE_NONE
	rep.renamed = 0
	rep.transferred = 0
	wal* next = wal_rewrite_begin(rw.wlog)
	if (cast(int, next) == 0):
		rep.stage = FS_STAGE_OPEN_TEMP
		rep.status = IO_IO_ERROR
		return IO_IO_ERROR
	int ok = raft_wal_write_snapshot(next, r)
	if (ok == 1): ok = raft_wal_write_state(next, r)
	int i = 0
	while (ok == 1 && i < r.log.length):
		ok = raft_wal_write_append(next, r, i)
		i = i + 1
	if (ok == 0):
		wal_rewrite_abort(next)
		rep.stage = FS_STAGE_WRITE
		rep.status = IO_IO_ERROR
		return IO_IO_ERROR
	int status = wal_rewrite_commit(rw.wlog, next, rep)
	if (rep.renamed == 1): raft_wal_shadow_reset_to(rw, r)
	if (status == IO_OK): wrote_out[0] = 2 + r.log.length
	return status


# Fail-stop form of raft_wal_rewrite_checked (asserts success);
# returns the number of records written.
int raft_wal_rewrite(raft_wal* rw, raft* r):
	int wrote = 0
	fs_replace_report rep
	int status = raft_wal_rewrite_checked(rw, r, &wrote, &rep)
	asserts(c"raft_wal_rewrite: compacted log could not be published durably", status == IO_OK)
	return wrote


# Checked sync (header): diff the raft's persistent trio against the
# shadow and append a record per change (STATE first, then TRUNCATE,
# then APPENDs — see header), or rewrite the wal when the raft's
# snapshot is ahead of the shadow's. Whenever records were written the
# wal is fsynced before returning — the durability point raft
# correctness rests on. Returns IO_OK with wrote_out[0] = records
# written (0 = already clean), or a failure status, after which the
# adapter is poisoned (raft_wal_failed) and every later call fails.
int raft_wal_persist(raft_wal* rw, raft* r, int* wrote_out):
	if (r.snapshot_failed):
		rw.failed = 1
		wrote_out[0] = 0
		return IO_IO_ERROR
	wrote_out[0] = 0
	if (rw.failed): return IO_IO_ERROR
	if (u64_cmp(r.snap_last_index, rw.snap_index) > 0):
		fs_replace_report rep
		int status = raft_wal_rewrite_checked(rw, r, wrote_out, &rep)
		if (status != IO_OK): rw.failed = 1
		return status
	# a shadow base AHEAD of the raft's would mean a second writer or
	# a raft rebuilt from elsewhere; the adapter owns its wal
	assert1(u64_eq(rw.snap_index, r.snap_last_index))
	int wrote = 0
	if (u64_eq(rw.term, r.current_term) == 0 || rw.voted_for != r.voted_for):
		if (raft_wal_write_state(rw.wlog, r) == 0):
			rw.failed = 1
			return IO_IO_ERROR
		u64_copy(rw.term, r.current_term)
		rw.voted_for = r.voted_for
		wrote = wrote + 1
	int agree = raft_wal_agree_len(rw, r)
	if (rw.entry_terms.length > agree):
		char* trec = cast(char*, malloc(5))
		trec[0] = raft_wal_tag_truncate
		store_le32(trec + 1, agree)
		int tok = wal_append(rw.wlog, trec, 5)
		free(trec)
		if (tok == 0):
			rw.failed = 1
			return IO_IO_ERROR
		while (rw.entry_terms.length > agree):
			u64* dropped = rw.entry_terms.pop()
			u64_free(dropped)
		wrote = wrote + 1
	int i = agree
	while (i < r.log.length):
		if (raft_wal_write_append(rw.wlog, r, i) == 0):
			rw.failed = 1
			return IO_IO_ERROR
		raft_entry* e = r.log[i]
		rw.entry_terms.push(u64_clone(e.term))
		wrote = wrote + 1
		i = i + 1
	if (wrote > 0 && wal_sync(rw.wlog) == 0):
		rw.failed = 1
		return IO_IO_ERROR
	wrote_out[0] = wrote
	return IO_OK


# Fail-stop sync with the historical signature: raft_wal_persist,
# asserting success, returning the number of records written.
int raft_wal_sync(raft_wal* rw, raft* r):
	int wrote = 0
	asserts(c"raft_wal_sync: persisting raft state failed", raft_wal_persist(rw, r, &wrote) == IO_OK)
	return wrote


# Persists r and gates the burst's replies on it (header): every
# message in staged (what the raft calls since the last persist
# emitted) is held in the adapter's durable_gate, the state is
# persisted, and only on success are the messages moved onto out, in
# order, for the transport. On failure they are freed undelivered and
# the adapter is poisoned. staged is emptied either way. Returns the
# raft_wal_persist status.
int raft_wal_persist_release(raft_wal* rw, raft* r, list[raft_msg*] staged, list[raft_msg*] out):
	rw.persist_seq = rw.persist_seq + 1
	int seq = rw.persist_seq
	list[char*] moved = new list[char*]
	int i = 0
	while (i < staged.length):
		raft_msg* m = staged[i]
		if (durable_gate_hold(rw.gate, cast(char*, m), seq) == 0): moved.push(cast(char*, m))
		i = i + 1
	staged.clear()
	int wrote = 0
	int status = raft_wal_persist(rw, r, &wrote)
	if (status == IO_OK):
		durable_gate_complete(rw.gate, seq, moved)
		i = 0
		while (i < moved.length):
			out.push(cast(raft_msg*, moved[i]))
			i = i + 1
		return status
	# moved may already hold messages a failed gate refused; add the
	# held ones and drop them all
	durable_gate_fail(rw.gate, moved)
	i = 0
	while (i < moved.length):
		raft_msg_free(cast(raft_msg*, moved[i]))
		i = i + 1
	return status


# ---- recovery --------------------------------------------------------------------

# Replay one persisted record into a recovering raft. APPEND copies
# the command bytes straight out of the wal record into a fresh
# entry-owned buffer (raft_entry_new); a TRUNCATE replay frees the
# whole entry (raft_entry_free, which now also frees its command
# copy) for every entry it discards.
void raft_wal_replay_stream(raft* r, char* p, int len):
	int tag = p[0] & 255
	if (tag == raft_wal_tag_stream_begin):
		int count = load_le32(p + 17)
		raft_msg* m = raft_msg_new(raft_msg_install_snapshot, r.self_id, r.self_id, r.current_term)
		u64_load_le(m.prev_log_index, p + 1)
		u64_load_le(m.prev_log_term, p + 9)
		for i in range(count): m.snap_config.push(raft_config_load_token(p + 21 + i * 4))
		m.snap_len = load_le32(p + 21 + count * 4)
		m.chunk_hash = load_le32(p + 25 + count * 4)
		r.incoming_snapshot = m
		r.incoming_file = snapshot_file_new(r.snapshot_ops, r.snapshot_prefix)
		if (cast(int, r.incoming_file) == 0): r.snapshot_failed = 1
		return
	if (r.snapshot_failed): return
	if (tag == raft_wal_tag_stream_chunk):
		if (snapshot_file_append(r.incoming_file, p + 5, len - 5) == 0): r.snapshot_failed = 1
		return
	raft_msg* m = r.incoming_snapshot
	if (snapshot_file_seal(r.incoming_file) == 0 || r.incoming_file.hash != m.chunk_hash || r.incoming_file.length != m.snap_len):
		r.snapshot_failed = 1
		return
	while (r.log.length > 0): raft_entry_free(r.log.pop())
	u64_copy(r.snap_last_index, m.prev_log_index)
	u64_copy(r.snap_last_term, m.prev_log_term)
	raft_adopt_snapshot_config(r, m.snap_config)
	u64_copy(r.commit_index, r.snap_last_index)
	u64_copy(r.last_applied, r.snap_last_index)
	if (r.snap_data != 0): free(r.snap_data)
	if (r.pending_snap_data != 0): free(r.pending_snap_data)
	r.snap_data = 0
	r.pending_snap_data = 0
	snapshot_file_free(r.snap_file)
	snapshot_file_free(r.pending_snap_file)
	r.snap_file = r.incoming_file
	r.pending_snap_file = snapshot_file_retain(r.snap_file)
	r.incoming_file = 0
	r.snap_len = m.snap_len
	r.pending_snap_len = m.snap_len
	r.snap_hash = m.chunk_hash
	u64_copy(r.pending_snap_index, r.snap_last_index)
	raft_msg_free(m)
	r.incoming_snapshot = 0


void raft_wal_replay_into(raft* r, char* p, int len):
	int tag = p[0] & 255
	if (tag == raft_wal_tag_stream_begin || tag == raft_wal_tag_stream_chunk || tag == raft_wal_tag_stream_end):
		raft_wal_replay_stream(r, p, len)
		return
	if (tag == raft_wal_tag_state):
		assert1(len == 13)
		u64_load_le(r.current_term, p + 1)
		r.voted_for = raft_wal_decode_vote(load_le32(p + 9))
		return
	if (tag == raft_wal_tag_append):
		assert1(len >= 14)
		int kind = p[1] & 255
		int cmd_len = load_le32(p + 10)
		assert1(cmd_len == len - 14)
		u64* t = u64_new()
		u64_load_le(t, p + 2)
		raft_entry* e = raft_entry_new_kind(t, p + 14, cmd_len, kind)
		r.log.push(e)
		# §4.1 membership header: replay reuses the SAME apply-on-append
		# hook live operation uses, so a config entry's peer-set effect
		# reconstructs exactly rather than being recomputed from scratch.
		raft_note_entry_appended(r, raft_last_index(r), e)
		u64_free(t)
		return
	if (tag == raft_wal_tag_truncate):
		assert1(len == 5)
		int keep = load_le32(p + 1)
		assert1(keep >= 0 && keep <= r.log.length)
		# §4.1 membership rollback (raft.w header): keep is a count above
		# the snapshot base, so the conceptual index bound truncation
		# survives up to is snap_base + keep.
		raft_note_truncated_to(r, raft_snap_base(r) + keep)
		while (r.log.length > keep):
			raft_entry* removed = r.log.pop()
			raft_entry_free(removed)
		return
	if (tag == raft_wal_tag_snapshot):
		# resets the replay state (header): the replayed prefix is
		# covered by the snapshot (a rewrite starts the wal with this
		# record, so the log is normally empty here), commit and
		# last_applied jump to the snapshot index, the FULL config
		# recorded at the snapshot is adopted (raft_adopt_snapshot_
		# config, superseding rather than rolling back to any pending
		# in-flight change — §4.1 membership header), and the blob lands
		# in both the raft's own snapshot slot and the pending slot —
		# the application re-installs it before applying anything.
		assert1(len >= 25)
		int ccount = load_le32(p + 17)
		assert1(ccount >= 0)
		int coff = 21 + 4 * ccount
		assert1(len >= coff + 4)
		int blob_len = load_le32(p + coff)
		assert1(blob_len == len - coff - 4)
		while (r.log.length > 0):
			raft_entry* covered = r.log.pop()
			raft_entry_free(covered)
		u64_load_le(r.snap_last_index, p + 1)
		u64_load_le(r.snap_last_term, p + 9)
		list[int] cfg = new list[int]
		for ci in range(ccount): cfg.push(raft_config_load_token(p + 21 + 4 * ci))
		raft_adopt_snapshot_config(r, cfg)
		u64_copy(r.commit_index, r.snap_last_index)
		u64_copy(r.last_applied, r.snap_last_index)
		if (r.snap_data != 0): free(r.snap_data)
		r.snap_data = mem_dup(p + coff + 4, blob_len)
		r.snap_len = blob_len
		r.snap_hash = raft_snapshot_checksum(r.snap_data, blob_len)
		if (r.pending_snap_data != 0): free(r.pending_snap_data)
		r.pending_snap_data = mem_dup(p + coff + 4, blob_len)
		r.pending_snap_len = blob_len
		u64_copy(r.pending_snap_index, r.snap_last_index)
		return
	assert1(0)


# raft_new(...) then replay the wal's records into it: current_term,
# voted_for, snapshot meta/blob and the rebuilt log suffix come back
# exactly as last synced. Without a snapshot, volatile state stays
# zero (commit re-derives via the leader); with one, commit_index and
# last_applied start at the snapshot index and the blob is PENDING —
# the application must raft_take_pending_snapshot before any
# raft_pop_apply (header). The caller must raft_start() the recovered
# raft as usual. The replay is a rescan of the file, and is asserted
# to land exactly on the shadow: both are pure folds of the same
# record prefix.
raft* raft_wal_recover_into(raft_wal* rw, raft* r):
	raft_enable_snapshot_files(r, rw.wlog.ops, rw.path)
	wal_reader* rd = wal_reader_open_with_ops(rw.wlog.ops, rw.path)
	assert1(cast(int, rd) != 0)
	int* len_out = cast(int*, malloc(__word_size__))
	char* p = wal_read_next(rd, len_out)
	while (p != 0):
		raft_wal_replay_into(r, p, len_out[0])
		free(p)
		p = wal_read_next(rd, len_out)
	free(len_out)
	int read_failed = rd.failed
	wal_reader_close(rd)
	if (read_failed || r.snapshot_failed):
		raft_free(r)
		return 0
	assert1(u64_eq(rw.term, r.current_term))
	assert1(rw.voted_for == r.voted_for)
	assert1(u64_eq(rw.snap_index, r.snap_last_index))
	assert1(u64_eq(rw.snap_term, r.snap_last_term))
	assert1(rw.entry_terms.length == r.log.length)
	for i in range(r.log.length):
		raft_entry* e = r.log[i]
		assert1(u64_eq(rw.entry_terms[i], e.term))
	return r


raft* raft_wal_recover(raft_wal* rw, int self_id, list[int] peers, int election_min_ms, int election_max_ms, int heartbeat_ms, int seed):
	return raft_wal_recover_into(rw, raft_new(self_id, peers, election_min_ms, election_max_ms, heartbeat_ms, seed))


raft* raft_wal_recover_learner(raft_wal* rw, int self_id, list[int] voters, int election_min_ms, int election_max_ms, int heartbeat_ms, int seed):
	return raft_wal_recover_into(rw, raft_new_learner(self_id, voters, election_min_ms, election_max_ms, heartbeat_ms, seed))


# ---- shadow queries --------------------------------------------------------------

int raft_wal_shadow_log_length(raft_wal* rw):
	return rw.entry_terms.length


void raft_wal_shadow_term(raft_wal* rw, u64* out):
	u64_copy(out, rw.term)


int raft_wal_shadow_voted_for(raft_wal* rw):
	return rw.voted_for
