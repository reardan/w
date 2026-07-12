/*
Replicated-KV state machine glue (docs/projects/distributed.md,
phase 4): encodes client put/delete operations as raft commands and
applies committed raft entries to an lsm store.

raft.w commands are NUL-terminated strings, so the KV operations
ride a tab-separated text encoding:

  put:    "P\t<key>\t<value>"
  delete: "D\t<key>"

Keys and values must be tab-, newline- and CR-free text
(kv_valid_text); keys must additionally be non-empty, values may be
empty. An embedded NUL cannot be expressed at all — it would
terminate the raft command string early — so binary values need a
length-carrying raft entry format: future work, out of scope for
this text-only v1.

The apply side (kv_apply_command) parses DEFENSIVELY: a replicated
log must tolerate garbage without killing the process, so a
malformed command (unknown tag, missing tab, empty key, embedded
newline/CR, extra fields) is rejected with a 0 return — never
asserted. kv_apply_pending keeps draining regardless: malformed
entries count as drained but not applied, and later valid entries
still apply.

Ownership: kv_propose_put/kv_propose_delete hand the freshly
encoded command string to raft_propose, which stores the pointer in
the raft's log (raft.w contract: commands are caller-owned and must
outlive the raft). The proposer must therefore NOT free it; the
string intentionally lives as long as the raft — the same lifetime
raft_wal.w gives the command copies it allocates during recovery.

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

# 1 iff s contains no tab (9), newline (10) or carriage-return (13)
# bytes; the empty string is valid only when allow_empty is set. An
# embedded NUL is unrepresentable in a NUL-terminated command, so
# the scan stopping at the terminator is the whole check.
int kv_valid_text(char* s, int allow_empty):
	int i = 0
	while (s[i] != 0):
		int b = s[i] & 255
		if (b == 9 || b == 10 || b == 13):
			return 0
		i = i + 1
	if (i == 0 && allow_empty == 0):
		return 0
	return 1


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


# Parse one raft command and apply it to the store. Returns 1 when
# applied, 0 when the command is malformed (rejected, never asserted
# — see header) or when the lsm reports an I/O failure. One scan
# collects the field separator and rejects embedded junk: newline or
# CR anywhere, a second tab (a third field), an empty key.
int kv_apply_command(lsm* store, char* command):
	int tag = command[0] & 255
	if (tag != 'P' && tag != 'D'):
		return 0
	if ((command[1] & 255) != 9):
		return 0
	char* rest = command + 2
	int sep = 0 - 1
	int i = 0
	while (rest[i] != 0):
		int b = rest[i] & 255
		if (b == 10 || b == 13):
			return 0
		if (b == 9):
			if (sep >= 0):
				return 0   # a third field: junk
			sep = i
		i = i + 1
	if (tag == 'D'):
		if (sep >= 0 || i == 0):
			return 0   # delete carries exactly one non-empty field
		return lsm_delete(store, rest)
	if (sep <= 0):
		return 0   # put needs a separator and a non-empty key
	char* key = kv_copy_range(rest, sep)
	int ok = lsm_put(store, key, rest + sep + 1, i - sep - 1)
	free(key)
	return ok


# Drain every committed-but-unapplied raft entry into the store.
# Returns the number actually applied; malformed entries are drained
# but not counted, and draining continues past them.
int kv_apply_pending(raft* r, lsm* store):
	int applied = 0
	while (raft_pending_apply(r)):
		raft_entry* e = raft_pop_apply(r)
		if (kv_apply_command(store, e.command)):
			applied = applied + 1
	return applied


# ---- proposing ------------------------------------------------------------------

# Encode a put and hand it to raft_propose. 1 = accepted (leader),
# 0 = not leader or invalid key/value. The encoded command becomes
# part of the raft's log and must NOT be freed by the caller (see
# the ownership note in the header).
int kv_propose_put(raft* r, char* key, char* value, int now_ms, list[raft_msg*] out):
	if (raft_state(r) != raft_leader()):
		return 0
	char* cmd = kv_encode_put(key, value)
	if (cmd == 0):
		return 0
	return raft_propose(r, cmd, now_ms, out)


# Encode a delete and hand it to raft_propose; same contract as
# kv_propose_put.
int kv_propose_delete(raft* r, char* key, int now_ms, list[raft_msg*] out):
	if (raft_state(r) != raft_leader()):
		return 0
	char* cmd = kv_encode_delete(key)
	if (cmd == 0):
		return 0
	return raft_propose(r, cmd, now_ms, out)
