/*
Replicated-KV state machine glue (docs/projects/distributed.md,
phase 4): encodes client put/delete operations as raft commands and
applies committed raft entries to an lsm store.

raft.w commands are opaque, length-carrying byte buffers
(raft_entry.command_len is authoritative, never strlen — see raft.w),
so the KV operations ride a tab-separated encoding that is bounded by
an explicit length end to end rather than by NUL termination:

  put:    "P\t<key>\t<value>"
  delete: "D\t<key>"

Keys must be non-empty, tab-, newline- and CR-free TEXT (kv_valid_text,
still NUL-terminated: keys are not required to carry embedded NUL).
Values may be empty and may contain embedded NUL — kv_valid_bytes only
rejects tab/newline/CR, never NUL — so kv_encode_put_len/
kv_propose_put_len take an explicit value_len and carry binary values
through unchanged. The plain kv_encode_put/kv_propose_put stay
NUL-terminated-text convenience wrappers (value_len = strlen(value))
for callers that never need embedded NUL.

The apply side (kv_apply_command) takes the entry's command_len and
parses DEFENSIVELY, scanning exactly that many bytes rather than
stopping at a NUL: a replicated log must tolerate garbage without
killing the process, so a malformed command (unknown tag, missing
tab, empty key, embedded newline/CR, extra fields) is rejected with a
0 return — never asserted. kv_apply_pending keeps draining regardless:
malformed entries count as drained but not applied, and later valid
entries still apply.

Ownership: kv_propose_put/kv_propose_delete hand the freshly encoded
command buffer to raft_propose, which now COPIES command_len bytes
into its own log entry (raft.w's ownership contract — see raft.w's
header). The proposer therefore MUST free its buffer once raft_propose
returns, and does: no command buffer here outlives the call that
encoded it.

Idempotency: applying the same put or delete twice lands the lsm in
the same state, so a recovering node may (and does) re-apply its
whole committed prefix from zero.

Snapshot integration (issue #314): kv_take_snapshot wraps lsm.w's
full-scan lsm_export as the blob raft_take_snapshot compacts the log
around; kv_install_snapshot is the receiver-side rebuild (lsm_import,
which clears the store first) for a blob raft handed the state
machine, whether over the wire (InstallSnapshot) or replayed from a
node's own wal-rewritten snapshot record (raft_wal.w). kv_apply_pending
is the single place both raft.w and raft_wal.w document as "the
application's apply loop" (raft.w's header), so that is where the
pending-snapshot check and install now live: every existing caller
(raft never has a pending snapshot until raft_take_snapshot or an
InstallSnapshot/wal-replay puts one there) is unaffected.

Frame cap: an encoded InstallSnapshot must fit raft_tcp's 1 MiB
rt_max_frame (raft_tcp.w) to ride that transport at all — kv_take_
snapshot asserts the blob leaves room for the wire envelope
(kv_snapshot_max_bytes) and fails loudly instead of producing a
snapshot raft_tcp would silently refuse to send later. Splitting one
logical snapshot across several InstallSnapshot frames (chunking) is
the documented follow-up (docs/projects/distributed.md); not
implemented here.
*/
import lib.lib
import lib.memory
import lib.assert
import libs.standard.distributed.raft
import libs.standard.distributed.lsm
import libs.standard.distributed.raft_tcp


# ---- validity -----------------------------------------------------------------

# 1 iff s[0..len) contains no tab (9), newline (10) or carriage-return
# (13) byte; the empty range is valid only when allow_empty is set.
# Embedded NUL (0) is a legal byte here — only the three separator/
# line-structure bytes are rejected — so this is safe to use on binary
# values, unlike a NUL-terminated scan.
int kv_valid_bytes(char* s, int len, int allow_empty):
	int i = 0
	while (i < len):
		int b = s[i] & 255
		if (b == 9 || b == 10 || b == 13):
			return 0
		i = i + 1
	if (len == 0 && allow_empty == 0):
		return 0
	return 1


# 1 iff the NUL-terminated string s contains no tab (9), newline (10)
# or carriage-return (13) byte; the empty string is valid only when
# allow_empty is set. A thin strlen wrapper over kv_valid_bytes for
# NUL-terminated-text callers (keys, and values with no embedded NUL).
int kv_valid_text(char* s, int allow_empty):
	return kv_valid_bytes(s, strlen(s), allow_empty)


# ---- encoding -----------------------------------------------------------------

# "P\t<key>\t<value>", malloc'd; 0 when the key is not non-empty
# valid text or the value is not valid text (empty value is legal).
char* kv_encode_put(char* key, char* value):
	if (kv_valid_text(key, 0) == 0):
		return 0
	if (kv_valid_text(value, 1) == 0):
		return 0
	int klen = strlen(key)
	int vlen = strlen(value)
	char* cmd = malloc(klen + vlen + 4)
	cmd[0] = 'P'
	cmd[1] = 9
	int i = 0
	while (i < klen):
		cmd[2 + i] = key[i]
		i = i + 1
	cmd[2 + klen] = 9
	i = 0
	while (i < vlen):
		cmd[3 + klen + i] = value[i]
		i = i + 1
	cmd[3 + klen + vlen] = 0
	return cmd


# "P\t<key>\t<value>" for a value of explicit length value_len (embedded
# NUL legal — kv_valid_bytes, not kv_valid_text, checks it), malloc'd;
# 0 when the key is not non-empty valid text or the value bytes contain
# a tab/newline/CR. len_out[0] receives the encoded command's length —
# the caller must use it (not strlen) as command_len when proposing,
# since the command may itself contain embedded NUL.
char* kv_encode_put_len(char* key, char* value, int value_len, int* len_out):
	if (kv_valid_text(key, 0) == 0):
		return 0
	if (kv_valid_bytes(value, value_len, 1) == 0):
		return 0
	int klen = strlen(key)
	char* cmd = malloc(klen + value_len + 3)
	cmd[0] = 'P'
	cmd[1] = 9
	int i = 0
	while (i < klen):
		cmd[2 + i] = key[i]
		i = i + 1
	cmd[2 + klen] = 9
	i = 0
	while (i < value_len):
		cmd[3 + klen + i] = value[i]
		i = i + 1
	len_out[0] = 3 + klen + value_len
	return cmd


# "D\t<key>", malloc'd; 0 when the key is not non-empty valid text.
char* kv_encode_delete(char* key):
	if (kv_valid_text(key, 0) == 0):
		return 0
	int klen = strlen(key)
	char* cmd = malloc(klen + 3)
	cmd[0] = 'D'
	cmd[1] = 9
	int i = 0
	while (i < klen):
		cmd[2 + i] = key[i]
		i = i + 1
	cmd[2 + klen] = 0
	return cmd


# ---- applying -------------------------------------------------------------------

# Malloc'd NUL-terminated copy of len bytes starting at src.
char* kv_copy_range(char* src, int len):
	char* dst = malloc(len + 1)
	int i = 0
	while (i < len):
		dst[i] = src[i]
		i = i + 1
	dst[len] = 0
	return dst


# Parse one raft command (exactly command_len bytes — never NUL-scanned,
# so a value with an embedded NUL is examined in full) and apply it to
# the store. Returns 1 when applied, 0 when the command is malformed
# (rejected, never asserted — see header) or when the lsm reports an
# I/O failure. One scan collects the field separator and rejects
# embedded junk: newline or CR anywhere, a second tab (a third field),
# an empty key. A command shorter than the tag+separator is malformed.
int kv_apply_command(lsm* store, char* command, int command_len):
	if (command_len < 2):
		return 0
	int tag = command[0] & 255
	if (tag != 'P' && tag != 'D'):
		return 0
	if ((command[1] & 255) != 9):
		return 0
	char* rest = command + 2
	int rest_len = command_len - 2
	int sep = 0 - 1
	int i = 0
	while (i < rest_len):
		int b = rest[i] & 255
		if (b == 10 || b == 13):
			return 0
		if (b == 9):
			if (sep >= 0):
				return 0   # a third field: junk
			sep = i
		i = i + 1
	if (tag == 'D'):
		if (sep >= 0 || rest_len == 0):
			return 0   # delete carries exactly one non-empty field
		char* key = kv_copy_range(rest, rest_len)
		int ok = lsm_delete(store, key)
		free(key)
		return ok
	if (sep <= 0):
		return 0   # put needs a separator and a non-empty key
	char* key = kv_copy_range(rest, sep)
	int ok = lsm_put(store, key, rest + sep + 1, rest_len - sep - 1)
	free(key)
	return ok


# ---- snapshotting (issue #314) ---------------------------------------------------

# Largest snapshot blob kv_take_snapshot may hand to raft_take_snapshot
# and still have it ride raft_tcp: the InstallSnapshot wire envelope
# around the blob is type(1) + from(4) + to(4) + term(8) +
# prev_log_index(8) + prev_log_term(8) + leader_commit(8) + snap_len(4)
# = 45 bytes (raft_wire.w's raft_wire_size for raft_msg_install_
# snapshot()), so the blob itself must leave that much headroom inside
# rt_max_frame()'s 1 MiB cap. A bigger tree cannot snapshot until
# chunked InstallSnapshot lands (documented follow-up, not this PR).
int kv_snapshot_max_bytes():
	return rt_max_frame() - 45


# Malloc'd full-scan export of store (lsm_export) — the KV snapshot
# blob for raft_take_snapshot to compact the log around. Asserts the
# result fits raft_tcp's InstallSnapshot frame cap (kv_snapshot_max_
# bytes) — fails loudly here rather than producing a blob raft_tcp
# would silently refuse to send later.
char* kv_take_snapshot(lsm* store, int* len_out):
	char* blob = lsm_export(store, len_out)
	asserts(c"kv_take_snapshot: snapshot blob exceeds raft_tcp's InstallSnapshot frame cap (rt_max_frame); chunked InstallSnapshot is the documented follow-up, not yet implemented", len_out[0] <= kv_snapshot_max_bytes())
	return blob


# Rebuild store from an installed snapshot blob (raft_take_pending_
# snapshot's buffer, or one replayed from a node's own wal-rewritten
# snapshot record): lsm_clear + lsm_import. Returns 1 on success, 0 on
# a malformed blob (lsm_import's contract) — should never happen from
# a well-behaved peer or a node's own wal, but the state machine never
# trusts wire/wal bytes blindly.
int kv_install_snapshot(lsm* store, char* blob, int len):
	return lsm_import(store, blob, len)


# Drain every committed-but-unapplied raft entry into the store. A
# pending snapshot (InstallSnapshot landed over the wire, or one
# replayed from this node's own wal-rewritten record — raft.w's and
# raft_wal.w's headers) is installed FIRST via kv_install_snapshot:
# raft_pop_apply asserts none is pending, since entries after the
# snapshot index only make sense on top of its state. Returns the
# number of ordinary entries actually applied; the snapshot install
# itself is not counted, and a malformed entry is drained but not
# counted either (see kv_apply_command).
int kv_apply_pending(raft* r, lsm* store):
	if (raft_has_pending_snapshot(r)):
		int* blen = cast(int*, malloc(__word_size__))
		u64* bidx = u64_new()
		char* blob = raft_take_pending_snapshot(r, blen, bidx)
		assert1(kv_install_snapshot(store, blob, blen[0]))
		free(blob)
		u64_free(bidx)
		free(cast(char*, blen))
	int applied = 0
	while (raft_pending_apply(r)):
		raft_entry* e = raft_pop_apply(r)
		if (kv_apply_command(store, e.command, e.command_len)):
			applied = applied + 1
	return applied


# ---- proposing ------------------------------------------------------------------

# Encode a put and hand it to raft_propose. 1 = accepted (leader),
# 0 = not leader or invalid key/value. raft_propose COPIES the command
# into its own log entry, so cmd is freed here once it returns — never
# retained (see the ownership note in the header).
int kv_propose_put(raft* r, char* key, char* value, int now_ms, list[raft_msg*] out):
	if (raft_state(r) != raft_leader()):
		return 0
	char* cmd = kv_encode_put(key, value)
	if (cmd == 0):
		return 0
	int ok = raft_propose(r, cmd, strlen(cmd), now_ms, out)
	free(cmd)
	return ok


# Same as kv_propose_put, but value is an explicit-length byte range
# that may contain embedded NUL (kv_encode_put_len). Use this for
# binary values; kv_propose_put remains the NUL-terminated-text
# convenience form.
int kv_propose_put_len(raft* r, char* key, char* value, int value_len, int now_ms, list[raft_msg*] out):
	if (raft_state(r) != raft_leader()):
		return 0
	int* len_out = cast(int*, malloc(__word_size__))
	char* cmd = kv_encode_put_len(key, value, value_len, len_out)
	if (cmd == 0):
		free(cast(char*, len_out))
		return 0
	int cmd_len = len_out[0]
	free(cast(char*, len_out))
	int ok = raft_propose(r, cmd, cmd_len, now_ms, out)
	free(cmd)
	return ok


# Encode a delete and hand it to raft_propose; same contract as
# kv_propose_put.
int kv_propose_delete(raft* r, char* key, int now_ms, list[raft_msg*] out):
	if (raft_state(r) != raft_leader()):
		return 0
	char* cmd = kv_encode_delete(key)
	if (cmd == 0):
		return 0
	int ok = raft_propose(r, cmd, strlen(cmd), now_ms, out)
	free(cmd)
	return ok
