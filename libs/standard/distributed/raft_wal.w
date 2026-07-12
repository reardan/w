/*
Persistence adapter binding raft.w's persistent state (current_term,
voted_for, log — the Figure 2 trio) to the checksummed append-only log
in wal.w (docs/projects/distributed.md, phase 4).

raft.w is a pure state machine and never calls out, so the adapter
OBSERVES instead of hooking: after every raft_tick / raft_on_msg /
raft_propose burst the caller invokes raft_wal_sync(rw, r), which
diffs the raft's persistent trio against the adapter's shadow copy and
appends one record per change. Crash recovery replays the records into
a fresh raft (raft_wal_recover); volatile state (commit_index,
last_applied, role, timers) intentionally stays at its raft_new zero —
it re-derives from the leader, which is correct per the paper.

Record encoding, one record per wal payload (little-endian; u64 via
u64_save_le/u64_load_le):
  tag 1 STATE:    1 tag byte + 8-byte term + 4-byte voted_for
  tag 2 APPEND:   1 tag byte + 8-byte entry term + 4-byte command
                  length + command bytes (one record per entry, in
                  log order)
  tag 3 TRUNCATE: 1 tag byte + 4-byte keep_count (the log keeps
                  conceptual entries 1..keep_count; later entries are
                  discarded)

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


# ---- adapter state --------------------------------------------------------------

struct raft_wal:
	wal* wlog               # the underlying append-only log
	char* path              # owned copy; wlog.path points at it
	u64* term               # shadow: last persisted current_term
	int voted_for           # shadow: last persisted vote (0 - 1 = none)
	list[u64*] entry_terms  # shadow: term of every persisted log entry (owned)


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
int raft_wal_pending(raft_wal* rw, raft* r):
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


# Diff the raft's persistent trio against the shadow and append a
# record per change (STATE first, then TRUNCATE, then APPENDs — see
# header). Updates the shadow to match and returns the number of
# records appended (0 = already clean).
int raft_wal_sync(raft_wal* rw, raft* r):
	int wrote = 0
	if (u64_eq(rw.term, r.current_term) == 0 || rw.voted_for != r.voted_for):
		char* srec = malloc(13)
		srec[0] = raft_wal_tag_state()
		u64_save_le(srec + 1, r.current_term)
		wal_put_le32(srec + 9, raft_wal_encode_vote(r.voted_for))
		raft_wal_put_record(rw, srec, 13)
		free(srec)
		u64_copy(rw.term, r.current_term)
		rw.voted_for = r.voted_for
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
		wrote = wrote + 1
		i = i + 1
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
	assert1(0)


# raft_new(...) then replay the wal's records into it: current_term,
# voted_for and the rebuilt log come back exactly as last synced.
# Volatile state stays zero (commit re-derives via the leader). The
# caller must raft_start() the recovered raft as usual. The replay is
# a rescan of the file, and is asserted to land exactly on the shadow:
# both are pure folds of the same record prefix.
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
