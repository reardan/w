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
*/
import lib.lib
import lib.memory
import lib.assert
import libs.standard.distributed.raft
import libs.standard.distributed.lsm


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


# Drain every committed-but-unapplied raft entry into the store.
# Returns the number actually applied; malformed entries are drained
# but not counted, and draining continues past them.
int kv_apply_pending(raft* r, lsm* store):
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
