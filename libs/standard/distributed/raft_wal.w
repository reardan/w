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
  tag 2 APPEND:   1 tag byte + 8-byte entry term + 4-byte command
                  length + command bytes (one record per entry, in
                  log order)
  tag 3 TRUNCATE: 1 tag byte + 4-byte keep_count (the log keeps the
                  first keep_count entries above the snapshot base —
                  with no snapshot that is conceptual entries
                  1..keep_count; later entries are discarded)
  tag 4 SNAPSHOT: 1 tag byte + 8-byte snap_last_index + 8-byte
                  snap_last_term + 4-byte blob length + blob bytes
                  (raft.w §7 log compaction; the blob is opaque
                  binary, embedded NULs legal)

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
    the wal (the compaction payoff): wal_reset, then one SNAPSHOT
    record, then one STATE record, then one APPEND per entry still in
    the log; the return value counts the rewrite's records. Syncs
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

Commands are raft.w client commands: NUL-terminated strings (their
length on the wire is strlen). Recovery allocates fresh copies of the
command bytes; those copies intentionally live as long as the raft
itself (raft.w's contract: command pointers are caller-owned and must
outlive the raft), except copies discarded by a TRUNCATE replay, which
are freed on the spot because this module allocated them.

The shadow (term, vote, one u64 term per log entry) is rebuilt from
the wal's valid record prefix at open time, so a sync issued right
after recovery appends nothing. The adapter assumes it is the only
writer of its wal file.
*/
import lib.lib
import lib.memory
import lib.assert
import libs.standard.distributed.u64
import libs.standard.distributed.wal
import libs.standard.distributed.raft


# ---- record tags --------------------------------------------------------------

int raft_wal_tag_state():
	return 1


int raft_wal_tag_append():
	return 2


int raft_wal_tag_truncate():
	return 3


int raft_wal_tag_snapshot():
	return 4


# ---- adapter state --------------------------------------------------------------

struct raft_wal:
	wal* wlog               # the underlying append-only log
	char* path              # owned copy; wlog.path points at it
	u64* term               # shadow: last persisted current_term
	int voted_for           # shadow: last persisted vote (0 - 1 = none)
	list[u64*] entry_terms  # shadow: term of every persisted entry above the base (owned)
	u64* snap_index         # shadow: last persisted snapshot index (0 = none)
	u64* snap_term          # shadow: last persisted snapshot term


# ---- small helpers ---------------------------------------------------------------

# voted_for wire bias (header): none (0 - 1) -> 0, id -> id + 1.
int raft_wal_encode_vote(int voted_for):
	if (voted_for == (0 - 1)):
		return 0
	assert1(voted_for >= 0)
	return voted_for + 1


int raft_wal_decode_vote(int wire):
	assert1(wire >= 0)
	if (wire == 0):
		return 0 - 1
	return wire - 1


char* raft_wal_copy_string(char* s):
	int n = strlen(s)
	char* p = malloc(n + 1)
	int i = 0
	while (i < n):
		p[i] = s[i]
		i = i + 1
	p[n] = 0
	return p


# ---- shadow replay ----------------------------------------------------------------

# Fold one persisted record into the shadow. Payload layouts are
# asserted: the wal's checksum already rejected torn or corrupt
# records, so a malformed payload here means a foreign writer.
void raft_wal_shadow_apply(raft_wal* rw, char* p, int len):
	int tag = p[0] & 255
	if (tag == raft_wal_tag_state()):
		assert1(len == 13)
		u64_load_le(rw.term, p + 1)
		rw.voted_for = raft_wal_decode_vote(wal_get_le32(p + 9))
		return
	if (tag == raft_wal_tag_append()):
		assert1(len >= 13)
		assert1(wal_get_le32(p + 9) == len - 13)
		u64* t = u64_new()
		u64_load_le(t, p + 1)
		rw.entry_terms.push(t)
		return
	if (tag == raft_wal_tag_truncate()):
		assert1(len == 5)
		int keep = wal_get_le32(p + 1)
		assert1(keep >= 0 && keep <= rw.entry_terms.length)
		while (rw.entry_terms.length > keep):
			u64* dropped = rw.entry_terms.pop()
			u64_free(dropped)
		return
	if (tag == raft_wal_tag_snapshot()):
		assert1(len >= 21)
		assert1(wal_get_le32(p + 17) == len - 21)
		u64_load_le(rw.snap_index, p + 1)
		u64_load_le(rw.snap_term, p + 9)
		# the snapshot covers (and a rewrite drops) every prior entry
		while (rw.entry_terms.length > 0):
			u64* gone = rw.entry_terms.pop()
			u64_free(gone)
		return
	assert1(0)


# ---- lifecycle -------------------------------------------------------------------

# Opens (creating if missing) and recovers the wal at path, then
# rebuilds the shadow by replaying the valid record prefix — so a sync
# issued after recovery only appends genuine changes. Returns 0 when
# wal_open fails (unopenable path, foreign or corrupt header).
raft_wal* raft_wal_open(char* path):
	char* own = raft_wal_copy_string(path)
	wal* w = wal_open(own)
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
	wal_reader* rd = wal_reader_open(own)
	assert1(cast(int, rd) != 0)
	int* len_out = cast(int*, malloc(__word_size__))
	char* p = wal_read_next(rd, len_out)
	while (p != 0):
		raft_wal_shadow_apply(rw, p, len_out[0])
		free(p)
		p = wal_read_next(rd, len_out)
	free(len_out)
	wal_reader_close(rd)
	return rw


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
	free(rw.path)
	free(rw)


# ---- diffing ---------------------------------------------------------------------

# Length of the longest prefix on which the shadow's entry terms and
# the raft's log agree (same term at every conceptual index).
int raft_wal_agree_len(raft_wal* rw, raft* r):
	int n = rw.entry_terms.length
	if (r.log.length < n):
		n = r.log.length
	int i = 0
	while (i < n):
		raft_entry* e = r.log[i]
		if (u64_eq(rw.entry_terms[i], e.term) == 0):
			return i
		i = i + 1
	return n


# 1 when a sync would append records — a pure diff check, no writes.
# A snapshot difference is checked FIRST: while the bases differ the
# entry_terms/log comparison below would misalign (both sides count
# entries relative to their own base).
int raft_wal_pending(raft_wal* rw, raft* r):
	if (u64_eq(rw.snap_index, r.snap_last_index) == 0):
		return 1
	if (u64_eq(rw.term, r.current_term) == 0):
		return 1
	if (rw.voted_for != r.voted_for):
		return 1
	int agree = raft_wal_agree_len(rw, r)
	if (rw.entry_terms.length != agree):
		return 1
	if (r.log.length != agree):
		return 1
	return 0


void raft_wal_put_record(raft_wal* rw, char* payload, int len):
	assert1(wal_append(rw.wlog, payload, len) == 1)


# One STATE record carrying the raft's current term and vote; the
# shadow pair is updated to match.
void raft_wal_put_state(raft_wal* rw, raft* r):
	char* srec = malloc(13)
	srec[0] = raft_wal_tag_state()
	u64_save_le(srec + 1, r.current_term)
	wal_put_le32(srec + 9, raft_wal_encode_vote(r.voted_for))
	raft_wal_put_record(rw, srec, 13)
	free(srec)
	u64_copy(rw.term, r.current_term)
	rw.voted_for = r.voted_for


# One APPEND record for the log entry at storage index i; its term is
# cloned onto the shadow.
void raft_wal_put_append(raft_wal* rw, raft* r, int i):
	raft_entry* e = r.log[i]
	int cmd_len = strlen(e.command)
	char* arec = malloc(13 + cmd_len)
	arec[0] = raft_wal_tag_append()
	u64_save_le(arec + 1, e.term)
	wal_put_le32(arec + 9, cmd_len)
	int k = 0
	while (k < cmd_len):
		arec[13 + k] = e.command[k]
		k = k + 1
	raft_wal_put_record(rw, arec, 13 + cmd_len)
	free(arec)
	rw.entry_terms.push(u64_clone(e.term))


# The raft's snapshot advanced past the shadow's: compact the wal
# itself (header). wal_reset truncates the file, then the complete
# compacted state is rewritten — one SNAPSHOT record (meta + blob),
# one STATE record, one APPEND per retained entry — and the shadow is
# rebuilt to match. Returns the number of records written.
int raft_wal_rewrite(raft_wal* rw, raft* r):
	assert1(wal_reset(rw.wlog) == 1)
	int blob_len = r.snap_len
	char* nrec = malloc(21 + blob_len)
	nrec[0] = raft_wal_tag_snapshot()
	u64_save_le(nrec + 1, r.snap_last_index)
	u64_save_le(nrec + 9, r.snap_last_term)
	wal_put_le32(nrec + 17, blob_len)
	int b = 0
	while (b < blob_len):
		nrec[21 + b] = r.snap_data[b]
		b = b + 1
	raft_wal_put_record(rw, nrec, 21 + blob_len)
	free(nrec)
	u64_copy(rw.snap_index, r.snap_last_index)
	u64_copy(rw.snap_term, r.snap_last_term)
	raft_wal_put_state(rw, r)
	while (rw.entry_terms.length > 0):
		u64* dropped = rw.entry_terms.pop()
		u64_free(dropped)
	int wrote = 2
	int i = 0
	while (i < r.log.length):
		raft_wal_put_append(rw, r, i)
		wrote = wrote + 1
		i = i + 1
	return wrote


# Diff the raft's persistent trio against the shadow and append a
# record per change (STATE first, then TRUNCATE, then APPENDs — see
# header). A snapshot ahead of the shadow's instead rewrites the wal
# from scratch (raft_wal_rewrite). Whenever records were written the
# wal is fsynced before returning (wal_sync) — the durability point
# raft correctness rests on. Updates the shadow to match and returns
# the number of records written (0 = already clean).
int raft_wal_sync(raft_wal* rw, raft* r):
	if (u64_cmp(r.snap_last_index, rw.snap_index) > 0):
		int rewrote = raft_wal_rewrite(rw, r)
		assert1(wal_sync(rw.wlog) == 1)
		return rewrote
	# a shadow base AHEAD of the raft's would mean a second writer or
	# a raft rebuilt from elsewhere; the adapter owns its wal
	assert1(u64_eq(rw.snap_index, r.snap_last_index))
	int wrote = 0
	if (u64_eq(rw.term, r.current_term) == 0 || rw.voted_for != r.voted_for):
		raft_wal_put_state(rw, r)
		wrote = wrote + 1
	int agree = raft_wal_agree_len(rw, r)
	if (rw.entry_terms.length > agree):
		char* trec = malloc(5)
		trec[0] = raft_wal_tag_truncate()
		wal_put_le32(trec + 1, agree)
		raft_wal_put_record(rw, trec, 5)
		free(trec)
		while (rw.entry_terms.length > agree):
			u64* dropped = rw.entry_terms.pop()
			u64_free(dropped)
		wrote = wrote + 1
	int i = agree
	while (i < r.log.length):
		raft_wal_put_append(rw, r, i)
		wrote = wrote + 1
		i = i + 1
	if (wrote > 0):
		assert1(wal_sync(rw.wlog) == 1)
	return wrote


# ---- recovery --------------------------------------------------------------------

# Replay one persisted record into a recovering raft. APPEND allocates
# a fresh command copy (header: it lives as long as the raft); a
# TRUNCATE replay frees the copies it discards, since they are ours.
void raft_wal_replay_into(raft* r, char* p, int len):
	int tag = p[0] & 255
	if (tag == raft_wal_tag_state()):
		assert1(len == 13)
		u64_load_le(r.current_term, p + 1)
		r.voted_for = raft_wal_decode_vote(wal_get_le32(p + 9))
		return
	if (tag == raft_wal_tag_append()):
		assert1(len >= 13)
		int cmd_len = wal_get_le32(p + 9)
		assert1(cmd_len == len - 13)
		u64* t = u64_new()
		u64_load_le(t, p + 1)
		char* cmd = malloc(cmd_len + 1)
		int k = 0
		while (k < cmd_len):
			cmd[k] = p[13 + k]
			k = k + 1
		cmd[cmd_len] = 0
		r.log.push(raft_entry_new(t, cmd))
		u64_free(t)
		return
	if (tag == raft_wal_tag_truncate()):
		assert1(len == 5)
		int keep = wal_get_le32(p + 1)
		assert1(keep >= 0 && keep <= r.log.length)
		while (r.log.length > keep):
			raft_entry* removed = r.log.pop()
			free(removed.command)
			raft_entry_free(removed)
		return
	if (tag == raft_wal_tag_snapshot()):
		# resets the replay state (header): the replayed prefix is
		# covered by the snapshot (a rewrite starts the wal with this
		# record, so the log is normally empty here), commit and
		# last_applied jump to the snapshot index, and the blob lands
		# in both the raft's own snapshot slot and the pending slot —
		# the application re-installs it before applying anything.
		assert1(len >= 21)
		int blob_len = wal_get_le32(p + 17)
		assert1(blob_len == len - 21)
		while (r.log.length > 0):
			raft_entry* covered = r.log.pop()
			free(covered.command)
			raft_entry_free(covered)
		u64_load_le(r.snap_last_index, p + 1)
		u64_load_le(r.snap_last_term, p + 9)
		u64_copy(r.commit_index, r.snap_last_index)
		u64_copy(r.last_applied, r.snap_last_index)
		if (r.snap_data != 0):
			free(r.snap_data)
		r.snap_data = raft_copy_blob(p + 21, blob_len)
		r.snap_len = blob_len
		if (r.pending_snap_data != 0):
			free(r.pending_snap_data)
		r.pending_snap_data = raft_copy_blob(p + 21, blob_len)
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
raft* raft_wal_recover(raft_wal* rw, int self_id, list[int] peers, int election_min_ms, int election_max_ms, int heartbeat_ms, int seed):
	raft* r = raft_new(self_id, peers, election_min_ms, election_max_ms, heartbeat_ms, seed)
	wal_reader* rd = wal_reader_open(rw.path)
	assert1(cast(int, rd) != 0)
	int* len_out = cast(int*, malloc(__word_size__))
	char* p = wal_read_next(rd, len_out)
	while (p != 0):
		raft_wal_replay_into(r, p, len_out[0])
		free(p)
		p = wal_read_next(rd, len_out)
	free(len_out)
	wal_reader_close(rd)
	assert1(u64_eq(rw.term, r.current_term))
	assert1(rw.voted_for == r.voted_for)
	assert1(u64_eq(rw.snap_index, r.snap_last_index))
	assert1(u64_eq(rw.snap_term, r.snap_last_term))
	assert1(rw.entry_terms.length == r.log.length)
	int i = 0
	while (i < r.log.length):
		raft_entry* e = r.log[i]
		assert1(u64_eq(rw.entry_terms[i], e.term))
		i = i + 1
	return r


# ---- shadow queries --------------------------------------------------------------

int raft_wal_shadow_log_length(raft_wal* rw):
	return rw.entry_terms.length


void raft_wal_shadow_term(raft_wal* rw, u64* out):
	u64_copy(out, rw.term)


int raft_wal_shadow_voted_for(raft_wal* rw):
	return rw.voted_for
