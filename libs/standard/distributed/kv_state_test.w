# wbuild: x64
import lib.testing
import libs.standard.distributed.kv_state
import libs.standard.distributed.raft_wal


/*
End-to-end unit tests for the replicated-KV glue: command encoding,
defensive apply against an lsm, the single-node raft loop, and the
phase-4 payoff — a full durability restart (raft_wal recovery + lsm
reopen) proving the re-applied log is idempotent.
*/


# Distinct file prefixes per target so the 32- and 64-bit test
# binaries can run concurrently under wbuild without clobbering each
# other. Malloc'd; caller frees.
char* kvs_prefix(char* name):
	char* word = itoa(__word_size__)
	char* stem = strjoin(c"bin/kvs_t", word)
	char* mid = strjoin(stem, c"_")
	char* prefix = strjoin(mid, name)
	free(mid)
	free(stem)
	free(word)
	return prefix


# Truncate the lsm prefix's wal and manifest so reruns start clean;
# stale .sst files become unreachable once the manifest is empty.
void kvs_clean_store(char* prefix):
	char* wpath = strjoin(prefix, c".wal")
	char* mpath = strjoin(prefix, c".manifest")
	int fd = create_file(wpath, 420)
	close(fd)
	fd = create_file(mpath, 420)
	close(fd)
	free(mpath)
	free(wpath)


# Truncate one file (the raft_wal log) so reruns start clean.
void kvs_clean_file(char* path):
	int fd = create_file(path, 420)
	close(fd)


int* kvs_len_out():
	return cast(int*, malloc(__word_size__))


# Assert lsm_get(key) returns exactly `want` (text value).
void kvs_expect(lsm* l, char* key, char* want):
	int* n = kvs_len_out()
	char* got = lsm_get(l, key, n)
	assert1(cast(int, got) != 0)
	assert_equal(strlen(want), n[0])
	assert_strings_equal(want, got)
	free(got)
	free(cast(char*, n))


# Assert lsm_get(key) answers absent/deleted: 0 pointer, len 0.
void kvs_expect_gone(lsm* l, char* key):
	int* n = kvs_len_out()
	n[0] = 99
	assert_equal(0, cast(int, lsm_get(l, key, n)))
	assert_equal(0, n[0])
	free(cast(char*, n))


void kvs_free_msgs(list[raft_msg*] out):
	while (out.length > 0):
		raft_msg* m = out.pop()
		raft_msg_free(m)


# Single-node raft ticked past election_max: leader on the spot with
# no outbound messages.
raft* kvs_leader(int seed):
	list[int] peers = new list[int]
	raft* r = raft_new(1, peers, 150, 300, 50, seed)
	raft_start(r, 0)
	list[raft_msg*] out = new list[raft_msg*]
	raft_tick(r, 300, out)
	assert_equal(0, out.length)
	assert_equal(raft_leader(), raft_state(r))
	return r


# ---- encoding -------------------------------------------------------------------

void test_encode_put():
	char* cmd = kv_encode_put(c"k", c"v")
	assert_strings_equal(c"P\tk\tv", cmd)
	free(cmd)
	cmd = kv_encode_put(c"name", c"alpha beta")
	assert_strings_equal(c"P\tname\talpha beta", cmd)
	free(cmd)
	# empty VALUE is legal
	cmd = kv_encode_put(c"k", c"")
	assert_strings_equal(c"P\tk\t", cmd)
	free(cmd)


void test_encode_delete():
	char* cmd = kv_encode_delete(c"k")
	assert_strings_equal(c"D\tk", cmd)
	free(cmd)
	cmd = kv_encode_delete(c"some-key")
	assert_strings_equal(c"D\tsome-key", cmd)
	free(cmd)


void test_encode_rejects_invalid():
	# tab in key, empty key, newline in key
	assert_equal(0, cast(int, kv_encode_put(c"a\tb", c"v")))
	assert_equal(0, cast(int, kv_encode_put(c"", c"v")))
	assert_equal(0, cast(int, kv_encode_put(c"a\nb", c"v")))
	# newline / CR / tab in value
	assert_equal(0, cast(int, kv_encode_put(c"k", c"line1\nline2")))
	assert_equal(0, cast(int, kv_encode_put(c"k", c"line1\rline2")))
	assert_equal(0, cast(int, kv_encode_put(c"k", c"a\tb")))
	# delete: empty key, tab in key
	assert_equal(0, cast(int, kv_encode_delete(c"")))
	assert_equal(0, cast(int, kv_encode_delete(c"a\tb")))


void test_valid_text():
	assert_equal(1, kv_valid_text(c"hello world", 0))
	assert_equal(0, kv_valid_text(c"has\ttab", 0))
	assert_equal(0, kv_valid_text(c"has\nnewline", 0))
	assert_equal(0, kv_valid_text(c"has\rcr", 0))
	assert_equal(0, kv_valid_text(c"", 0))
	assert_equal(1, kv_valid_text(c"", 1))


# ---- direct apply ---------------------------------------------------------------

void test_apply_put_overwrite_delete():
	char* prefix = kvs_prefix(c"apply")
	kvs_clean_store(prefix)
	lsm* store = lsm_open(prefix, 1 << 20)
	assert1(cast(int, store) != 0)
	assert_equal(1, kv_apply_command(store, c"P\tname\tone"))
	kvs_expect(store, c"name", c"one")
	# second put overwrites
	assert_equal(1, kv_apply_command(store, c"P\tname\ttwo"))
	kvs_expect(store, c"name", c"two")
	# delete removes
	assert_equal(1, kv_apply_command(store, c"D\tname"))
	kvs_expect_gone(store, c"name")
	lsm_close(store)
	free(prefix)


void test_apply_empty_value_roundtrip():
	char* prefix = kvs_prefix(c"emptyv")
	kvs_clean_store(prefix)
	lsm* store = lsm_open(prefix, 1 << 20)
	assert1(cast(int, store) != 0)
	char* cmd = kv_encode_put(c"blank", c"")
	assert1(cast(int, cmd) != 0)
	assert_equal(1, kv_apply_command(store, cmd))
	free(cmd)
	# present, with a zero-length value
	kvs_expect(store, c"blank", c"")
	lsm_close(store)
	free(prefix)


void test_apply_rejects_malformed():
	char* prefix = kvs_prefix(c"mal")
	kvs_clean_store(prefix)
	lsm* store = lsm_open(prefix, 1 << 20)
	assert1(cast(int, store) != 0)
	assert_equal(1, kv_apply_command(store, c"P\tkeep\tsafe"))
	# unknown tag, missing tabs, empty command, bare tag
	assert_equal(0, kv_apply_command(store, c"X\tk"))
	assert_equal(0, kv_apply_command(store, c"P\tonly-key"))
	assert_equal(0, kv_apply_command(store, c""))
	assert_equal(0, kv_apply_command(store, c"P"))
	# empty key, junk third field, delete with extra field / empty key
	assert_equal(0, kv_apply_command(store, c"P\t\tv"))
	assert_equal(0, kv_apply_command(store, c"P\tk\tv\tw"))
	assert_equal(0, kv_apply_command(store, c"D\tk\tv"))
	assert_equal(0, kv_apply_command(store, c"D\t"))
	# embedded newline / CR
	assert_equal(0, kv_apply_command(store, c"P\tk\tv1\nv2"))
	assert_equal(0, kv_apply_command(store, c"D\tk\rk"))
	# the store is untouched: keep is intact, nothing else appeared
	kvs_expect(store, c"keep", c"safe")
	kvs_expect_gone(store, c"k")
	kvs_expect_gone(store, c"only-key")
	assert_equal(1, lsm_memtable_count(store))
	lsm_close(store)
	free(prefix)


# ---- single-node raft loop --------------------------------------------------------

void test_propose_apply_loop():
	char* prefix = kvs_prefix(c"loop")
	kvs_clean_store(prefix)
	lsm* store = lsm_open(prefix, 1 << 20)
	assert1(cast(int, store) != 0)
	raft* r = kvs_leader(42)
	list[raft_msg*] out = new list[raft_msg*]
	assert_equal(1, kv_propose_put(r, c"name", c"alpha", 300, out))
	assert_equal(0, out.length)
	raft_tick(r, 350, out)
	kvs_free_msgs(out)
	assert_equal(1, kv_apply_pending(r, store))
	kvs_expect(store, c"name", c"alpha")
	# delete goes through the same replicated pipe
	assert_equal(1, kv_propose_delete(r, c"name", 400, out))
	assert_equal(0, out.length)
	assert_equal(1, kv_apply_pending(r, store))
	kvs_expect_gone(store, c"name")
	assert_equal(0, kv_apply_pending(r, store))
	raft_free(r)
	lsm_close(store)
	free(prefix)


void test_propose_non_leader_and_invalid():
	char* prefix = kvs_prefix(c"nolead")
	kvs_clean_store(prefix)
	lsm* store = lsm_open(prefix, 1 << 20)
	assert1(cast(int, store) != 0)
	# a fresh follower rejects proposals outright
	list[int] peers = new list[int]
	raft* f = raft_new(1, peers, 150, 300, 50, 7)
	raft_start(f, 0)
	list[raft_msg*] out = new list[raft_msg*]
	assert_equal(0, kv_propose_put(f, c"k", c"v", 10, out))
	assert_equal(0, kv_propose_delete(f, c"k", 10, out))
	assert_equal(0, out.length)
	assert_equal(0, raft_log_length(f))
	raft_free(f)
	# a leader still rejects invalid input, leaving its log untouched
	raft* r = kvs_leader(8)
	assert_equal(0, kv_propose_put(r, c"a\tb", c"v", 300, out))
	assert_equal(0, kv_propose_put(r, c"", c"v", 300, out))
	assert_equal(0, kv_propose_delete(r, c"a\nb", 300, out))
	assert_equal(0, out.length)
	assert_equal(0, raft_log_length(r))
	assert_equal(0, kv_apply_pending(r, store))
	raft_free(r)
	lsm_close(store)
	free(prefix)


# ---- apply resilience ---------------------------------------------------------------

void test_apply_resilience_garbage_entry():
	char* prefix = kvs_prefix(c"garb")
	kvs_clean_store(prefix)
	lsm* store = lsm_open(prefix, 1 << 20)
	assert1(cast(int, store) != 0)
	raft* r = kvs_leader(9)
	list[raft_msg*] out = new list[raft_msg*]
	# a raft-valid but KV-malformed command lands in the log directly
	assert_equal(1, raft_propose(r, c"garbage-no-tabs", 300, out))
	assert_equal(1, kv_propose_put(r, c"real", c"value", 310, out))
	assert_equal(0, out.length)
	# both entries drain; only the valid one applies
	assert_equal(1, kv_apply_pending(r, store))
	assert_equal(0, raft_pending_apply(r))
	kvs_expect(store, c"real", c"value")
	kvs_expect_gone(store, c"garbage-no-tabs")
	assert_equal(1, lsm_memtable_count(store))
	# later valid commands still apply
	assert_equal(1, kv_propose_put(r, c"after", c"fine", 320, out))
	assert_equal(1, kv_apply_pending(r, store))
	kvs_expect(store, c"after", c"fine")
	raft_free(r)
	lsm_close(store)
	free(prefix)


# ---- full durability loop (phase 4) ----------------------------------------------

void test_restart_recovery_idempotent():
	char* prefix = kvs_prefix(c"dur")
	kvs_clean_store(prefix)
	char* rpath = strjoin(prefix, c".rlog")
	kvs_clean_file(rpath)
	# first life: single-node leader with raft_wal + lsm, syncing
	# after every step
	raft_wal* rw = raft_wal_open(rpath)
	assert1(cast(int, rw) != 0)
	lsm* store = lsm_open(prefix, 1 << 20)
	assert1(cast(int, store) != 0)
	raft* r = kvs_leader(11)
	assert_equal(1, raft_wal_sync(rw, r))   # STATE: term 1, vote 1
	list[raft_msg*] out = new list[raft_msg*]
	assert_equal(1, kv_propose_put(r, c"alpha", c"1", 300, out))
	assert_equal(1, raft_wal_sync(rw, r))
	assert_equal(1, kv_propose_put(r, c"beta", c"2", 310, out))
	assert_equal(1, raft_wal_sync(rw, r))
	assert_equal(1, kv_propose_put(r, c"gamma", c"3", 320, out))
	assert_equal(1, raft_wal_sync(rw, r))
	assert_equal(1, kv_propose_delete(r, c"beta", 330, out))
	assert_equal(1, raft_wal_sync(rw, r))
	assert_equal(0, out.length)
	assert_equal(4, kv_apply_pending(r, store))
	kvs_expect(store, c"alpha", c"1")
	kvs_expect_gone(store, c"beta")
	kvs_expect(store, c"gamma", c"3")
	assert_equal(1, lsm_flush(store))
	# crash: close everything
	raft_free(r)
	raft_wal_close(rw)
	lsm_close(store)
	# second life: recover the raft from its wal, reopen the store
	raft_wal* rw2 = raft_wal_open(rpath)
	assert1(cast(int, rw2) != 0)
	assert_equal(4, raft_wal_shadow_log_length(rw2))
	list[int] peers = new list[int]
	raft* r2 = raft_wal_recover(rw2, 1, peers, 150, 300, 50, 12)
	assert_equal(4, raft_log_length(r2))
	lsm* store2 = lsm_open(prefix, 1 << 20)
	assert1(cast(int, store2) != 0)
	# the flushed state already serves reads before any re-apply
	kvs_expect(store2, c"alpha", c"1")
	kvs_expect_gone(store2, c"beta")
	kvs_expect(store2, c"gamma", c"3")
	# commit is volatile and recovered as zero: nothing pending until
	# a fresh command commits under the new term (section 5.4.2 — a
	# restarted single-node leader cannot re-commit old-term entries
	# by ticking alone)
	assert_equal(0, raft_pending_apply(r2))
	raft_start(r2, 1000)
	raft_tick(r2, 1300, out)
	assert_equal(0, out.length)
	assert_equal(raft_leader(), raft_state(r2))
	assert_equal(1, kv_propose_put(r2, c"pin", c"held", 1300, out))
	assert_equal(0, out.length)
	# the whole log re-applies from commit 0: 4 recovered entries
	# plus the pin, and re-applying every put/delete is idempotent —
	# the store lands in exactly the same final state
	assert_equal(5, kv_apply_pending(r2, store2))
	kvs_expect(store2, c"alpha", c"1")
	kvs_expect_gone(store2, c"beta")
	kvs_expect(store2, c"gamma", c"3")
	kvs_expect(store2, c"pin", c"held")
	# persist the re-election and the pin, then verify a clean shadow
	assert_equal(2, raft_wal_sync(rw2, r2))   # STATE + APPEND(pin)
	assert_equal(0, raft_wal_pending(rw2, r2))
	raft_free(r2)
	raft_wal_close(rw2)
	lsm_close(store2)
	free(rpath)
	free(prefix)


void test_restart_recovery_noop_closes_gap():
	# the durability recipe again, but the recovered node opts into
	# noop-on-win instead of proposing a "pin": the election's own no-op
	# is the current-term entry that re-commits the recovered old-term
	# prefix (§5.4.2 closure, no client proposal), kv_apply_pending
	# re-applies the recovered commands, and the no-op drains unapplied
	# (kv_apply_command rejects the empty command by design)
	char* prefix = kvs_prefix(c"noopdur")
	kvs_clean_store(prefix)
	char* rpath = strjoin(prefix, c".rlog")
	kvs_clean_file(rpath)
	# first life: single-node leader, synced after every step
	raft_wal* rw = raft_wal_open(rpath)
	assert1(cast(int, rw) != 0)
	lsm* store = lsm_open(prefix, 1 << 20)
	assert1(cast(int, store) != 0)
	raft* r = kvs_leader(21)
	assert_equal(1, raft_wal_sync(rw, r))   # STATE: term 1, vote 1
	list[raft_msg*] out = new list[raft_msg*]
	assert_equal(1, kv_propose_put(r, c"alpha", c"1", 300, out))
	assert_equal(1, raft_wal_sync(rw, r))
	assert_equal(1, kv_propose_put(r, c"beta", c"2", 310, out))
	assert_equal(1, raft_wal_sync(rw, r))
	assert_equal(1, kv_propose_delete(r, c"beta", 320, out))
	assert_equal(1, raft_wal_sync(rw, r))
	assert_equal(0, out.length)
	assert_equal(3, kv_apply_pending(r, store))
	kvs_expect(store, c"alpha", c"1")
	kvs_expect_gone(store, c"beta")
	assert_equal(1, lsm_flush(store))
	# crash: close everything
	raft_free(r)
	raft_wal_close(rw)
	lsm_close(store)
	# second life: recover, then opt in BEFORE ticking to leader
	raft_wal* rw2 = raft_wal_open(rpath)
	assert1(cast(int, rw2) != 0)
	assert_equal(3, raft_wal_shadow_log_length(rw2))
	list[int] peers = new list[int]
	raft* r2 = raft_wal_recover(rw2, 1, peers, 150, 300, 50, 22)
	raft_set_noop_on_win(r2, 1)
	assert_equal(3, raft_log_length(r2))
	lsm* store2 = lsm_open(prefix, 1 << 20)
	assert1(cast(int, store2) != 0)
	# commit recovered as zero: nothing pending yet
	assert_equal(0, raft_pending_apply(r2))
	raft_start(r2, 1000)
	raft_tick(r2, 1300, out)
	assert_equal(0, out.length)
	assert_equal(raft_leader(), raft_state(r2))
	# the win appended the term-2 no-op and, single-node, committed the
	# whole log on the spot — the commit advanced over the recovered
	# entries WITHOUT any c"pin" proposal
	assert_equal(4, raft_log_length(r2))
	assert_equal(3, kv_apply_pending(r2, store2))
	assert_equal(0, raft_pending_apply(r2))
	kvs_expect(store2, c"alpha", c"1")
	kvs_expect_gone(store2, c"beta")
	# the no-op persists as a zero-length APPEND record
	assert_equal(2, raft_wal_sync(rw2, r2))   # STATE + APPEND(no-op)
	assert_equal(0, raft_wal_pending(rw2, r2))
	raft_free(r2)
	raft_wal_close(rw2)
	lsm_close(store2)
	free(rpath)
	free(prefix)
