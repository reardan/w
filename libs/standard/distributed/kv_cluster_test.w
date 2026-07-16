# wbuild: x64
import lib.testing
import libs.standard.distributed.kv_state
import libs.standard.distributed.raft_wal
import libs.standard.distributed.raft_tcp


/*
Capstone of the distributed library (docs/projects/distributed.md,
phase 4c): a 3-node replicated key-value cluster in one process. Every
replica runs the full stack — raft consensus, raft_wal persistence,
lsm storage, kv_state application — and the replicas talk to each
other over REAL loopback TCP sockets via raft_tcp.

Time is VIRTUAL: raft ticks consume a vnow counter advanced 10 ms per
round, never the wall clock, so protocol timing (election 150..300 ms,
heartbeat 50 ms, seeded jitter) is deterministic while the bytes
genuinely cross kernel sockets. Loopback delivery is fast but its
arrival timing is not scripted; each round therefore runs THREE
pump+drain settle passes so multi-hop exchanges (request -> reply ->
reaction) usually complete within the round, and every wait loop is
bounded with the convergence itself asserted afterwards — a message
that needs one more round only costs a round.

Round shape (kvc_step):
  1. tick every live node at vnow, raft_wal_sync it, route what it
     emitted (raft_tcp_send does not take ownership: send, then free)
  2. pump every live transport (never blocks)
  3. drain every live inbox: raft_on_msg, free the message, sync the
     wal (persist before the replies hit the wire), route the replies
  4. kv_apply_pending every live node's committed entries into its lsm
  5. vnow advances 10 ms; assert no two live same-term leaders exist

A crash is the real-socket kind: raft_free + raft_wal_close +
lsm_close + raft_tcp_free, so the node's connections genuinely die.
Survivors' transports keep the dead peer's outbound buffer and re-dial
on every pump, so a rebuilt node (raft_wal_recover + lsm_open on the
same paths + raft_tcp_new on the SAME port) receives the backlog as
soon as it listens again — no re-registration on the survivors.

Ports: 21000 + __word_size__ * 100 + 20..40 (offsets 20-49 are
reserved for this test; raft_tcp_test owns 0-13), three consecutive
ports per scenario (offset 21's cluster-membership scenario below
takes four — kvc_add_node's fresh node claims the port right after
its cluster's own three), so the 32- and 64-bit binaries use disjoint
ranges (21420.. vs 21820..) and can run concurrently.

Files: per-target prefixes bin/kvc_t<word>_<test>_<node> for the lsm
(.wal/.manifest/.sst*) plus <prefix>.rlog for the raft wal, truncated
at cluster setup so every run starts fresh.

Cluster membership (issue #319; raft.w's "Cluster membership changes"
header): kvc_add_node wires a genuinely fresh node (empty lsm and raft
wal) into a LIVE cluster's raft_tcp mesh — the pre-registered-peer-id
model raft_tcp already uses (docs/projects/distributed.md's #314
note), done here exactly as an operator would out-of-band, separate
from consensus. Its raft starts with an EMPTY peers list; kvc_add_
server then drives raft_propose_add_server on the leader, and the new
node learns the cluster (and catches up its log) purely through
whatever replicates to it — reusing the existing InstallSnapshot/log-
replay paths (raft_make_peer_msg), never a bespoke bootstrap RPC.
*/


# ---- ports and paths ------------------------------------------------------------

# This test's slice of the loopback port space (see header).
int kvc_port_base():
	return 21000 + __word_size__ * 100 + 20


# Per-target per-node lsm prefix "bin/kvc_t<word>_<name>_<id>".
# Malloc'd; caller frees.
char* kvc_prefix(char* name, int id):
	char* word = itoa(__word_size__)
	char* a = strjoin(c"bin/kvc_t", word)
	char* b = strjoin(a, c"_")
	char* d = strjoin(b, name)
	char* e = strjoin(d, c"_")
	char* ids = itoa(id)
	char* prefix = strjoin(e, ids)
	free(ids)
	free(e)
	free(d)
	free(b)
	free(a)
	free(word)
	return prefix


# Truncate one node's lsm wal + manifest and its raft wal so reruns
# start clean; stale .sst files become unreachable once the manifest
# is empty.
void kvc_clean_node(char* prefix, char* rlog_path):
	char* wpath = strjoin(prefix, c".wal")
	char* mpath = strjoin(prefix, c".manifest")
	int fd = create_file(wpath, 420)
	close(fd)
	fd = create_file(mpath, 420)
	close(fd)
	fd = create_file(rlog_path, 420)
	close(fd)
	free(mpath)
	free(wpath)


# ---- u64 conveniences -------------------------------------------------------------

int kvc_term_int(raft* r):
	u64* t = u64_new()
	raft_term(r, t)
	int v = raft_u64_as_int(t)
	u64_free(t)
	return v


int kvc_commit_int(raft* r):
	u64* ci = u64_new()
	raft_commit_index(r, ci)
	int v = raft_u64_as_int(ci)
	u64_free(ci)
	return v


# The raft's snapshot base as a host int (0 = no snapshot yet).
int kvc_snap_index_int(raft* r):
	u64* si = u64_new()
	raft_snapshot_index(r, si)
	int v = raft_u64_as_int(si)
	u64_free(si)
	return v


list[int] kvc_peers(int n, int id):
	list[int] peers = new list[int]
	int p = 1
	while (p <= n):
		if (p != id):
			peers.push(p)
		p = p + 1
	return peers


# ---- cluster driver ----------------------------------------------------------------

# One replica: the full stack plus its file paths and port, so a
# crashed node can be rebuilt from exactly what it left on disk.
struct kvc_node:
	int id
	raft* r
	raft_wal* rw          # raft persistence adapter; file at rlog_path
	lsm* store            # KV storage; files under prefix
	raft_tcp* tcp         # real loopback transport; listens on port
	int alive             # 0 while crashed (r/rw/store/tcp dangling)
	int port
	char* prefix          # owned lsm path stem
	char* rlog_path       # owned raft wal path


struct kvc:
	int n                 # node count; ids are 1..n at nodes[id - 1]
	list[kvc_node*] nodes
	int vnow              # virtual clock, advanced 10 ms per round


# 3 nodes with ids 1..3 on ports base+port_off+0..2, full peer mesh,
# election window 150..300 ms, heartbeat 50 ms, raft seeds
# seed_base + id. All files truncated; everything starts at vnow 0.
kvc* kvc_new(char* name, int port_off, int seed_base):
	int base = kvc_port_base() + port_off
	kvc* c = new kvc()
	c.n = 3
	c.vnow = 0
	c.nodes = new list[kvc_node*]
	int id = 1
	while (id <= c.n):
		kvc_node* nd = new kvc_node()
		nd.id = id
		nd.port = base + id - 1
		nd.alive = 1
		nd.prefix = kvc_prefix(name, id)
		nd.rlog_path = strjoin(nd.prefix, c".rlog")
		kvc_clean_node(nd.prefix, nd.rlog_path)
		nd.rw = raft_wal_open(nd.rlog_path)
		assert1(cast(int, nd.rw) != 0)
		nd.store = lsm_open(nd.prefix, 1 << 20)
		assert1(cast(int, nd.store) != 0)
		nd.r = raft_new(id, kvc_peers(c.n, id), 150, 300, 50, seed_base + id)
		raft_start(nd.r, 0)
		nd.tcp = raft_tcp_new(id, nd.port)
		assert1(cast(int, nd.tcp) != 0)
		int p = 1
		while (p <= c.n):
			if (p != id):
				raft_tcp_add_peer(nd.tcp, p, base + p - 1)
			p = p + 1
		c.nodes.push(nd)
		id = id + 1
	return c


# Put every message node nd emitted on the wire. raft_tcp_send frames
# and buffers immediately without taking ownership, so each message is
# freed right after sending. Every raft peer is registered on the
# mesh, so a send never targets an unknown id.
void kvc_route_out(kvc_node* nd, list[raft_msg*] out):
	int i = 0
	while (i < out.length):
		raft_msg* m = out[i]
		assert_equal(1, raft_tcp_send(nd.tcp, m))
		raft_msg_free(m)
		i = i + 1
	out.clear()


# Never two LIVE leaders in the same term (split brain); different
# terms are a legal transient (a not-yet-deposed stale leader).
void kvc_assert_no_same_term_leaders(kvc* c):
	u64* ti = u64_new()
	u64* tj = u64_new()
	int i = 0
	while (i < c.n):
		kvc_node* a = c.nodes[i]
		if (a.alive == 1 && raft_state(a.r) == raft_leader()):
			int j = i + 1
			while (j < c.n):
				kvc_node* b = c.nodes[j]
				if (b.alive == 1 && raft_state(b.r) == raft_leader()):
					raft_term(a.r, ti)
					raft_term(b.r, tj)
					assert_equal(0, u64_eq(ti, tj))
				j = j + 1
		i = i + 1
	u64_free(ti)
	u64_free(tj)


# One 10 ms virtual round over real sockets — see the header for the
# five-step shape and why the pump+drain settles three times.
void kvc_step(kvc* c):
	list[raft_msg*] out = new list[raft_msg*]
	kvc_node* nd = 0
	int i = 0
	while (i < c.n):
		nd = c.nodes[i]
		if (nd.alive == 1):
			raft_tick(nd.r, c.vnow, out)
			raft_wal_sync(nd.rw, nd.r)
			kvc_route_out(nd, out)
		i = i + 1
	int settle = 0
	while (settle < 3):
		i = 0
		while (i < c.n):
			nd = c.nodes[i]
			if (nd.alive == 1):
				raft_tcp_pump(nd.tcp)
			i = i + 1
		i = 0
		while (i < c.n):
			nd = c.nodes[i]
			if (nd.alive == 1):
				raft_msg* m = raft_tcp_recv(nd.tcp)
				while (cast(int, m) != 0):
					raft_on_msg(nd.r, m, c.vnow, out)
					raft_msg_free(m)
					raft_wal_sync(nd.rw, nd.r)
					kvc_route_out(nd, out)
					m = raft_tcp_recv(nd.tcp)
			i = i + 1
		settle = settle + 1
	i = 0
	while (i < c.n):
		nd = c.nodes[i]
		if (nd.alive == 1):
			kv_apply_pending(nd.r, nd.store)
		i = i + 1
	c.vnow = c.vnow + 10
	kvc_assert_no_same_term_leaders(c)


void kvc_run_steps(kvc* c, int k):
	int i = 0
	while (i < k):
		kvc_step(c)
		i = i + 1


# The id of the unique live leader at the highest term among leaders,
# or 0 - 1 when none leads or that highest term is shared.
int kvc_leader(kvc* c):
	u64* best = u64_new()
	u64* t = u64_new()
	int found = 0
	int dup = 0
	int leader_id = 0 - 1
	int i = 0
	while (i < c.n):
		kvc_node* nd = c.nodes[i]
		if (nd.alive == 1 && raft_state(nd.r) == raft_leader()):
			raft_term(nd.r, t)
			if (found == 0):
				found = 1
				u64_copy(best, t)
				leader_id = i + 1
			else:
				int cmp = u64_cmp(t, best)
				if (cmp > 0):
					u64_copy(best, t)
					leader_id = i + 1
					dup = 0
				if (cmp == 0):
					dup = 1
		i = i + 1
	u64_free(best)
	u64_free(t)
	if (found == 1 && dup == 0):
		return leader_id
	return 0 - 1


# Step until kvc_leader finds one; rounds taken, or 0 - 1 on timeout.
int kvc_run_until_leader(kvc* c, int max_rounds):
	int rounds = 0
	while (rounds < max_rounds):
		if (kvc_leader(c) != (0 - 1)):
			return rounds
		kvc_step(c)
		rounds = rounds + 1
	if (kvc_leader(c) != (0 - 1)):
		return rounds
	return 0 - 1


# 1 iff every LIVE node's lsm currently serves key -> want; want == 0
# means the key must be absent (or tombstoned) on every live node.
int kvc_agree(kvc* c, char* key, char* want):
	int ok = 1
	int i = 0
	while (i < c.n):
		kvc_node* nd = c.nodes[i]
		if (nd.alive == 1):
			int* n = cast(int*, malloc(__word_size__))
			char* got = lsm_get(nd.store, key, n)
			if (cast(int, want) == 0):
				if (cast(int, got) != 0):
					ok = 0
			else:
				if (cast(int, got) == 0):
					ok = 0
				else:
					if (strcmp(want, got) != 0):
						ok = 0
			if (cast(int, got) != 0):
				free(got)
			free(cast(char*, n))
		i = i + 1
	return ok


# Step until every live node's lsm agrees on key; rounds taken, or
# 0 - 1 on timeout. Callers assert the return, so a cap running out
# fails the test rather than silently passing.
int kvc_run_until_agree(kvc* c, char* key, char* want, int max_rounds):
	int rounds = 0
	while (rounds < max_rounds):
		if (kvc_agree(c, key, want)):
			return rounds
		kvc_step(c)
		rounds = rounds + 1
	if (kvc_agree(c, key, want)):
		return rounds
	return 0 - 1


# Byte-length variant of kvc_agree (issue #315): compares want_len raw
# bytes rather than strcmp, so a value with an embedded NUL never
# reads as a short match. want == 0 still means "absent everywhere".
int kvc_agree_bytes(kvc* c, char* key, char* want, int want_len):
	int ok = 1
	int i = 0
	while (i < c.n):
		kvc_node* nd = c.nodes[i]
		if (nd.alive == 1):
			int* n = cast(int*, malloc(__word_size__))
			char* got = lsm_get(nd.store, key, n)
			if (cast(int, want) == 0):
				if (cast(int, got) != 0):
					ok = 0
			else:
				if (cast(int, got) == 0 || n[0] != want_len):
					ok = 0
				else:
					int k = 0
					while (k < want_len):
						if ((got[k] & 255) != (want[k] & 255)):
							ok = 0
						k = k + 1
			if (cast(int, got) != 0):
				free(got)
			free(cast(char*, n))
		i = i + 1
	return ok


# Byte-length variant of kvc_run_until_agree.
int kvc_run_until_agree_bytes(kvc* c, char* key, char* want, int want_len, int max_rounds):
	int rounds = 0
	while (rounds < max_rounds):
		if (kvc_agree_bytes(c, key, want, want_len)):
			return rounds
		kvc_step(c)
		rounds = rounds + 1
	if (kvc_agree_bytes(c, key, want, want_len)):
		return rounds
	return 0 - 1


# ---- store assertions ----------------------------------------------------------------

# Assert lsm_get(key) returns exactly want (text value).
void kvc_expect(lsm* store, char* key, char* want):
	int* n = cast(int*, malloc(__word_size__))
	char* got = lsm_get(store, key, n)
	assert1(cast(int, got) != 0)
	assert_equal(strlen(want), n[0])
	assert_strings_equal(want, got)
	free(got)
	free(cast(char*, n))


# Byte-length variant of kvc_expect (issue #315): compares want_len
# raw bytes, so a value with an embedded NUL is checked in full rather
# than truncated at the first zero.
void kvc_expect_bytes(lsm* store, char* key, char* want, int want_len):
	int* n = cast(int*, malloc(__word_size__))
	char* got = lsm_get(store, key, n)
	assert1(cast(int, got) != 0)
	assert_equal(want_len, n[0])
	int i = 0
	while (i < want_len):
		assert_equal(want[i] & 255, got[i] & 255)
		i = i + 1
	free(got)
	free(cast(char*, n))


# Assert lsm_get(key) answers absent/deleted: 0 pointer, len 0.
void kvc_expect_gone(lsm* store, char* key):
	int* n = cast(int*, malloc(__word_size__))
	n[0] = 99
	assert_equal(0, cast(int, lsm_get(store, key, n)))
	assert_equal(0, n[0])
	free(cast(char*, n))


void kvc_assert_kv(kvc* c, char* key, char* want):
	int i = 0
	while (i < c.n):
		kvc_node* nd = c.nodes[i]
		if (nd.alive == 1):
			kvc_expect(nd.store, key, want)
		i = i + 1


void kvc_assert_gone(kvc* c, char* key):
	int i = 0
	while (i < c.n):
		kvc_node* nd = c.nodes[i]
		if (nd.alive == 1):
			kvc_expect_gone(nd.store, key)
		i = i + 1


# Every live node's log identical to the first live node's, entry by
# entry (same terms, same commands).
void kvc_assert_logs_identical(kvc* c):
	int ref = 0 - 1
	int i = 0
	while (i < c.n):
		kvc_node* nd = c.nodes[i]
		if (nd.alive == 1 && ref < 0):
			ref = i
		i = i + 1
	assert1(ref >= 0)
	kvc_node* first = c.nodes[ref]
	i = ref + 1
	while (i < c.n):
		kvc_node* other = c.nodes[i]
		if (other.alive == 1):
			assert_equal(raft_log_length(first.r), raft_log_length(other.r))
			int k = 1
			while (k <= raft_log_length(first.r)):
				raft_entry* mine = raft_log_at(first.r, k)
				raft_entry* theirs = raft_log_at(other.r, k)
				assert_equal(1, u64_eq(mine.term, theirs.term))
				assert_strings_equal(mine.command, theirs.command)
				k = k + 1
		i = i + 1


# ---- client operations ------------------------------------------------------------------

# Put via node id (asserting it accepts, i.e. leads), persist, route.
# kv_propose_put encodes, hands the command to raft_propose (which
# copies it into the log entry) and frees its own encode buffer —
# nothing to free here.
void kvc_put(kvc* c, int id, char* key, char* value):
	kvc_node* nd = c.nodes[id - 1]
	assert_equal(1, nd.alive)
	list[raft_msg*] out = new list[raft_msg*]
	assert_equal(1, kv_propose_put(nd.r, key, value, c.vnow, out))
	raft_wal_sync(nd.rw, nd.r)
	kvc_route_out(nd, out)


# Byte-length variant of kvc_put (issue #315): value_len is explicit,
# so a value with an embedded NUL rides through kv_propose_put_len
# unchanged instead of the NUL-terminated-text kv_propose_put.
void kvc_put_len(kvc* c, int id, char* key, char* value, int value_len):
	kvc_node* nd = c.nodes[id - 1]
	assert_equal(1, nd.alive)
	list[raft_msg*] out = new list[raft_msg*]
	assert_equal(1, kv_propose_put_len(nd.r, key, value, value_len, c.vnow, out))
	raft_wal_sync(nd.rw, nd.r)
	kvc_route_out(nd, out)


void kvc_delete(kvc* c, int id, char* key):
	kvc_node* nd = c.nodes[id - 1]
	assert_equal(1, nd.alive)
	list[raft_msg*] out = new list[raft_msg*]
	assert_equal(1, kv_propose_delete(nd.r, key, c.vnow, out))
	raft_wal_sync(nd.rw, nd.r)
	kvc_route_out(nd, out)


# ---- crash and rebuild --------------------------------------------------------------------

# Crash node id the real-socket way: one last wal sync (usually a
# no-op — the step loop already synced), then the whole stack dies,
# raft_tcp_free included, so its TCP connections genuinely drop. The
# wal and lsm FILES survive on disk.
void kvc_crash(kvc* c, int id):
	kvc_node* nd = c.nodes[id - 1]
	assert_equal(1, nd.alive)
	raft_wal_sync(nd.rw, nd.r)
	raft_free(nd.r)
	raft_wal_close(nd.rw)
	lsm_close(nd.store)
	raft_tcp_free(nd.tcp)
	nd.alive = 0


# Rebuild node id from exactly what it left on disk: recover the raft
# from its wal, reopen the lsm (its data wal replays the applied
# state), listen again on the SAME port and re-register the peers.
# The survivors need no re-registration: their transports kept the
# dead peer's outbound buffer and re-dial it on every pump, so the
# backlog lands here as soon as the listen socket is back.
void kvc_rebuild(kvc* c, int id, int seed):
	kvc_node* nd = c.nodes[id - 1]
	assert_equal(0, nd.alive)
	raft_wal* rw = raft_wal_open(nd.rlog_path)
	assert1(cast(int, rw) != 0)
	raft* r = raft_wal_recover(rw, id, kvc_peers(c.n, id), 150, 300, 50, seed)
	raft_start(r, c.vnow)
	lsm* store = lsm_open(nd.prefix, 1 << 20)
	assert1(cast(int, store) != 0)
	raft_tcp* tcp = raft_tcp_new(id, nd.port)
	assert1(cast(int, tcp) != 0)
	int p = 1
	while (p <= c.n):
		if (p != id):
			kvc_node* peer = c.nodes[p - 1]
			raft_tcp_add_peer(tcp, p, peer.port)
		p = p + 1
	nd.r = r
	nd.rw = rw
	nd.store = store
	nd.tcp = tcp
	nd.alive = 1
	# recovery replays exactly what was persisted: nothing to sync
	assert_equal(0, raft_wal_sync(nd.rw, nd.r))


# ---- cluster membership: adding a fresh node over real TCP (issue #319) -------------------

# Appends a genuinely fresh node (empty lsm, empty raft wal, id = c.n +
# 1) at the next port in this scenario's range and wires it
# bidirectionally into every CURRENTLY LIVE node's raft_tcp mesh —
# raft_tcp's pre-registered-peer-id/address model (header), exactly
# what an operator would configure out-of-band, separate from raft's
# own consensus log. The new node's raft starts with an EMPTY peers
# list (raft_new): it knows nothing about the cluster until whatever
# raft_propose_add_server (kvc_add_server, below) replicates to it.
# port_off must be the SAME offset the cluster itself was created
# with (kvc_new), since ports are computed relative to it.
kvc_node* kvc_add_node(kvc* c, char* name, int port_off):
	int base = kvc_port_base() + port_off
	int id = c.n + 1
	kvc_node* nd = new kvc_node()
	nd.id = id
	nd.port = base + id - 1
	nd.alive = 1
	nd.prefix = kvc_prefix(name, id)
	nd.rlog_path = strjoin(nd.prefix, c".rlog")
	kvc_clean_node(nd.prefix, nd.rlog_path)
	nd.rw = raft_wal_open(nd.rlog_path)
	assert1(cast(int, nd.rw) != 0)
	nd.store = lsm_open(nd.prefix, 1 << 20)
	assert1(cast(int, nd.store) != 0)
	list[int] empty_peers = new list[int]
	nd.r = raft_new(id, empty_peers, 150, 300, 50, 9000 + id)
	raft_start(nd.r, c.vnow)
	nd.tcp = raft_tcp_new(id, nd.port)
	assert1(cast(int, nd.tcp) != 0)
	int i = 0
	while (i < c.n):
		kvc_node* existing = c.nodes[i]
		raft_tcp_add_peer(nd.tcp, existing.id, existing.port)
		raft_tcp_add_peer(existing.tcp, id, nd.port)
		i = i + 1
	c.nodes.push(nd)
	c.n = c.n + 1
	return nd


# Leader-only: propose adding new_id (an already-wired-in kvc_add_node
# result), asserting acceptance, persist and route — mirrors kvc_put's
# shape but at the raft layer directly (no kv_state.w command
# involved; membership is raft.w's own concern).
void kvc_add_server(kvc* c, int leader_id, int new_id):
	kvc_node* nd = c.nodes[leader_id - 1]
	assert_equal(1, nd.alive)
	list[raft_msg*] out = new list[raft_msg*]
	assert_equal(1, raft_propose_add_server(nd.r, new_id, c.vnow, out))
	raft_wal_sync(nd.rw, nd.r)
	kvc_route_out(nd, out)


# Tear the cluster down: free live stacks (crashed nodes already freed
# theirs at crash time) and the owned paths. raft_tcp_free closes all
# sockets and frees buffered frames and undelivered inbox messages.
void kvc_free(kvc* c):
	int i = 0
	while (i < c.n):
		kvc_node* nd = c.nodes[i]
		if (nd.alive == 1):
			raft_free(nd.r)
			raft_wal_close(nd.rw)
			lsm_close(nd.store)
			raft_tcp_free(nd.tcp)
		free(nd.prefix)
		free(nd.rlog_path)
		free(nd)
		i = i + 1
	free(c)


# ---- scenarios ---------------------------------------------------------------------------


# Elect a leader over real sockets, replicate two puts and a delete,
# and converge every node's lsm to the same state with equal logs and
# commit indexes.
void test_cluster_elects_and_replicates():
	kvc* c = kvc_new(c"rep", 0, 100)
	int rounds = kvc_run_until_leader(c, 500)
	assert1(rounds >= 0)
	int lid = kvc_leader(c)
	assert1(lid >= 1 && lid <= 3)
	kvc_put(c, lid, c"name", c"spanner")
	kvc_put(c, lid, c"paper", c"raft")
	kvc_delete(c, lid, c"name")
	# paper == raft everywhere forces entry 2 applied on every node;
	# name absent everywhere then forces the delete (entry 3) too —
	# entry 1 put name=spanner, so a lagging node still shows it
	assert1(kvc_run_until_agree(c, c"paper", c"raft", 500) >= 0)
	assert1(kvc_run_until_agree(c, c"name", 0, 500) >= 0)
	kvc_assert_kv(c, c"paper", c"raft")
	kvc_assert_gone(c, c"name")
	# 2 puts + 1 delete = 3 entries, fully committed on all three
	int i = 0
	while (i < 3):
		kvc_node* nd = c.nodes[i]
		assert_equal(3, raft_log_length(nd.r))
		assert_equal(3, kvc_commit_int(nd.r))
		i = i + 1
	kvc_assert_logs_identical(c)
	assert_equal(lid, kvc_leader(c))
	kvc_free(c)


# A follower crashes (its sockets die), the surviving majority keeps
# committing, and the rebuilt follower — recovered from its own wal
# and lsm files, re-listening on the same port — catches up to serve
# all three keys. The survivors' transports re-dial it on their own.
void test_follower_crash_recover_over_tcp():
	kvc* c = kvc_new(c"frec", 3, 200)
	int rounds = kvc_run_until_leader(c, 500)
	assert1(rounds >= 0)
	int lid = kvc_leader(c)
	kvc_put(c, lid, c"paper", c"raft")
	kvc_put(c, lid, c"lang", c"w")
	assert1(kvc_run_until_agree(c, c"paper", c"raft", 500) >= 0)
	assert1(kvc_run_until_agree(c, c"lang", c"w", 500) >= 0)
	int victim = 1
	if (victim == lid):
		victim = 2
	kvc_crash(c, victim)
	# the surviving pair is still a majority: a third key commits
	kvc_put(c, lid, c"third", c"key")
	assert1(kvc_run_until_agree(c, c"third", c"key", 500) >= 0)
	kvc_node* ldr = c.nodes[lid - 1]
	assert_equal(3, kvc_commit_int(ldr.r))
	# rebuild from disk on the SAME port; the persisted 2-entry prefix
	# is back, commit is volatile and re-derives from the leader
	kvc_rebuild(c, victim, 900 + victim)
	kvc_node* vic = c.nodes[victim - 1]
	assert_equal(2, raft_log_length(vic.r))
	assert_equal(0, kvc_commit_int(vic.r))
	# its reopened lsm already serves the applied prefix
	kvc_expect(vic.store, c"paper", c"raft")
	kvc_expect(vic.store, c"lang", c"w")
	# rejoin: the leader's buffered/re-dialed appends land, the third
	# key replicates, and the whole cluster agrees on everything
	assert1(kvc_run_until_agree(c, c"third", c"key", 500) >= 0)
	kvc_assert_kv(c, c"paper", c"raft")
	kvc_assert_kv(c, c"lang", c"w")
	kvc_assert_kv(c, c"third", c"key")
	int i = 0
	while (i < 3):
		kvc_node* nd = c.nodes[i]
		assert_equal(3, raft_log_length(nd.r))
		assert_equal(3, kvc_commit_int(nd.r))
		i = i + 1
	kvc_assert_logs_identical(c)
	assert1(kvc_leader(c) >= 1)
	kvc_free(c)


# The LEADER crashes; the two survivors elect a successor at a higher
# term and keep committing; the deposed leader rebuilds from disk and
# rejoins as a follower on the merged history.
void test_leader_crash_failover():
	kvc* c = kvc_new(c"fail", 6, 300)
	int rounds = kvc_run_until_leader(c, 500)
	assert1(rounds >= 0)
	int old_lid = kvc_leader(c)
	kvc_node* old_ldr = c.nodes[old_lid - 1]
	int old_term = kvc_term_int(old_ldr.r)
	kvc_put(c, old_lid, c"cfg", c"one")
	assert1(kvc_run_until_agree(c, c"cfg", c"one", 500) >= 0)
	kvc_crash(c, old_lid)
	# the survivors' election timers fire without heartbeats: a new
	# leader emerges at a strictly higher term
	int k = 0
	int new_lid = 0 - 1
	while (k < 500 && new_lid < 0):
		kvc_step(c)
		int cand = kvc_leader(c)
		if (cand != (0 - 1)):
			new_lid = cand
		k = k + 1
	assert1(new_lid >= 1)
	assert1(new_lid != old_lid)
	kvc_node* new_ldr = c.nodes[new_lid - 1]
	assert1(kvc_term_int(new_ldr.r) > old_term)
	# committing a fresh-term entry also seals the old-term prefix
	kvc_put(c, new_lid, c"cfg2", c"two")
	assert1(kvc_run_until_agree(c, c"cfg2", c"two", 500) >= 0)
	assert_equal(2, kvc_commit_int(new_ldr.r))
	# rebuild the deposed leader: it recovered on its stale term with
	# its 1-entry log and must fall in line as a follower
	kvc_rebuild(c, old_lid, 700 + old_lid)
	assert_equal(1, raft_log_length(old_ldr.r))
	assert1(kvc_run_until_agree(c, c"cfg2", c"two", 500) >= 0)
	kvc_assert_kv(c, c"cfg", c"one")
	kvc_assert_kv(c, c"cfg2", c"two")
	assert_equal(raft_follower(), raft_state(old_ldr.r))
	# exactly one leader at the highest term; every node shares that
	# term and the same fully committed 2-entry log
	int final_lid = kvc_leader(c)
	assert1(final_lid >= 1)
	assert1(final_lid != old_lid)
	kvc_node* fin = c.nodes[final_lid - 1]
	int t_final = kvc_term_int(fin.r)
	int i = 0
	while (i < 3):
		kvc_node* nd = c.nodes[i]
		assert_equal(t_final, kvc_term_int(nd.r))
		assert_equal(2, raft_log_length(nd.r))
		assert_equal(2, kvc_commit_int(nd.r))
		i = i + 1
	kvc_assert_logs_identical(c)
	kvc_free(c)


# Client redirect semantics on a settled cluster: a follower refuses a
# proposal (returns 0, log untouched) but names the actual leader via
# raft_leader_hint, and the same put on the leader goes through.
void test_client_semantics_on_followers():
	kvc* c = kvc_new(c"redir", 9, 400)
	int rounds = kvc_run_until_leader(c, 500)
	assert1(rounds >= 0)
	int lid = kvc_leader(c)
	# settle: heartbeats set every follower's leader hint
	kvc_run_steps(c, 20)
	assert_equal(lid, kvc_leader(c))
	int fid = 1
	if (fid == lid):
		fid = 2
	kvc_node* fol = c.nodes[fid - 1]
	assert_equal(raft_follower(), raft_state(fol.r))
	list[raft_msg*] out = new list[raft_msg*]
	assert_equal(0, kv_propose_put(fol.r, c"k", c"v", c.vnow, out))
	assert_equal(0, kv_propose_delete(fol.r, c"k", c.vnow, out))
	assert_equal(0, out.length)
	assert_equal(0, raft_log_length(fol.r))
	# a real client would redirect here
	assert_equal(lid, raft_leader_hint(fol.r))
	# the same put on the leader succeeds and converges everywhere
	kvc_put(c, lid, c"k", c"v")
	assert1(kvc_run_until_agree(c, c"k", c"v", 500) >= 0)
	kvc_assert_kv(c, c"k", c"v")
	kvc_free(c)


# A kv value containing an embedded NUL byte must replicate unchanged
# across all three real-socket nodes (issue #315): raft_entry.
# command_len -- carried end to end through raft_propose, the wire and
# the wal, never strlen -- is what makes this possible; kv_propose_put
# and kv_apply_command thread it through kv_state.w's tab-separated
# encoding too.
void test_cluster_binary_value_roundtrip():
	kvc* c = kvc_new(c"binval", 12, 500)
	int rounds = kvc_run_until_leader(c, 500)
	assert1(rounds >= 0)
	int lid = kvc_leader(c)
	char* value = malloc(5)
	value[0] = 'x'
	value[1] = 0
	value[2] = 'y'
	value[3] = 255
	value[4] = 'z'
	kvc_put_len(c, lid, c"binkey", value, 5)
	assert1(kvc_run_until_agree_bytes(c, c"binkey", value, 5, 500) >= 0)
	int i = 0
	while (i < 3):
		kvc_node* nd = c.nodes[i]
		if (nd.alive == 1):
			kvc_expect_bytes(nd.store, c"binkey", value, 5)
		i = i + 1
	free(value)
	kvc_free(c)


# ---- snapshot integration (issue #314) ----------------------------------------------


# A follower crashes BEFORE any writes happen (so the leader's
# next_index for it is frozen at 1 — raft only advances a peer's
# next_index on a reply, and a dead peer never sends one), then the
# leader commits and compacts a run of puts entirely while the
# follower is down. kv_take_snapshot exports the lsm; raft_take_
# snapshot hands the blob to raft and discards the covered log prefix.
# More writes land only on the surviving majority, past the compacted
# horizon. The rejoining node's frozen next_index (1) now sits at or
# below the leader's snapshot base, so raft_make_peer_msg must route
# it an InstallSnapshot (raft.w's §7 path) before the post-snapshot
# suffix can replicate; kv_state.w's kv_apply_pending installs that
# blob into the rejoiner's lsm (lsm_clear + lsm_import) the moment
# raft hands it a pending snapshot. Covers a binary value (issue #315)
# riding through the snapshot blob unchanged.
void test_cluster_snapshot_laggard_catchup():
	kvc* c = kvc_new(c"snap", 15, 600)
	int rounds = kvc_run_until_leader(c, 500)
	assert1(rounds >= 0)
	int lid = kvc_leader(c)
	kvc_node* ldr = c.nodes[lid - 1]
	# crash a follower before it ever sees a single entry
	int victim = 1
	if (victim == lid):
		victim = 2
	kvc_crash(c, victim)
	# shrink the leader's per-peer outbound cap to the smallest raft_tcp
	# allows (4096 bytes, the floor raft_tcp_set_max_pending enforces):
	# raft_tcp's bounded buffer drops the OLDEST whole frame once full
	# (raft_tcp.w's header), so while the victim is unreachable every
	# heartbeat/append attempt still gets built and queued -- with the
	# default 256 KiB cap those STALE pre-compaction AppendEntries
	# frames (built back when next_index still pointed below the
	# not-yet-compacted log) would survive long enough to replay the
	# whole history into the rejoining node once it reconnects, letting
	# it "time travel" past the compaction without ever needing
	# InstallSnapshot. With the floor cap, the settle rounds run after
	# the post-snapshot puts below push enough fresh (already
	# post-compaction) frames to evict every stale one before rebuild.
	raft_tcp_set_max_pending(ldr.tcp, 4096)
	kvc_put(c, lid, c"k1", c"v1")
	kvc_put(c, lid, c"k2", c"v2")
	char* binval = malloc(4)
	binval[0] = 0
	binval[1] = 'Z'
	binval[2] = 255
	binval[3] = 0
	kvc_put_len(c, lid, c"bkey", binval, 4)
	assert1(kvc_run_until_agree(c, c"k1", c"v1", 500) >= 0)
	assert1(kvc_run_until_agree(c, c"k2", c"v2", 500) >= 0)
	assert1(kvc_run_until_agree_bytes(c, c"bkey", binval, 4, 500) >= 0)
	# the leader compacts its own log around the state already applied
	assert_equal(3, kvc_commit_int(ldr.r))
	int* blen = cast(int*, malloc(__word_size__))
	char* blob = kv_take_snapshot(ldr.store, blen)
	assert_equal(1, raft_take_snapshot(ldr.r, blob, blen[0]))
	free(blob)
	free(cast(char*, blen))
	assert_equal(0, raft_log_length(ldr.r))
	assert_equal(3, kvc_snap_index_int(ldr.r))
	# more writes land only on the surviving majority, entirely past
	# the snapshot the rejoining victim will need
	kvc_put(c, lid, c"k3", c"v3")
	kvc_delete(c, lid, c"k1")
	assert1(kvc_run_until_agree(c, c"k3", c"v3", 500) >= 0)
	assert1(kvc_run_until_agree(c, c"k1", 0, 500) >= 0)
	# extra settle rounds: every one of these ticks/heartbeats builds a
	# FRESH post-compaction frame for the still-unreachable victim,
	# which raft_tcp's drop-oldest cap enforcement uses to evict
	# whatever pre-compaction frames might still be queued (see the cap
	# comment above) well before the victim ever reconnects
	kvc_run_steps(c, 300)
	# rejoin: catches up via InstallSnapshot plus the post-snapshot
	# suffix (k3, and the k1 delete)
	kvc_rebuild(c, victim, 1000 + victim)
	assert1(kvc_run_until_agree(c, c"k3", c"v3", 500) >= 0)
	assert1(kvc_run_until_agree(c, c"k1", 0, 500) >= 0)
	assert1(kvc_run_until_agree_bytes(c, c"bkey", binval, 4, 500) >= 0)
	assert1(kvc_run_until_agree(c, c"k2", c"v2", 500) >= 0)
	# proof the laggard actually installed a snapshot rather than being
	# fed the compacted entries individually: raft only ever sets a
	# follower's own snapshot base from raft_handle_install_snapshot,
	# never from ordinary AppendEntries, so a matching nonzero base
	# here is conclusive
	kvc_node* vic = c.nodes[victim - 1]
	assert1(kvc_snap_index_int(ldr.r) > 0)
	assert_equal(kvc_snap_index_int(ldr.r), kvc_snap_index_int(vic.r))
	kvc_expect(vic.store, c"k2", c"v2")
	kvc_expect_gone(vic.store, c"k1")
	kvc_expect(vic.store, c"k3", c"v3")
	kvc_expect_bytes(vic.store, c"bkey", binval, 4)
	free(binval)
	kvc_free(c)


# A node that compacted its OWN log (raft_take_snapshot) then crashes
# and rebuilds must replay a SNAPSHOT record from its own raft_wal
# (raft_wal.w's wal-rewrite compaction), not an InstallSnapshot over
# the wire — proving kv_apply_pending's pending-snapshot install
# (lsm_clear + lsm_import) also covers the restart path, and that
# reinstalling a node's own prior snapshot over its already-durable lsm
# converges cleanly rather than corrupting it.
void test_cluster_restart_from_compacted_wal():
	kvc* c = kvc_new(c"snaprst", 18, 700)
	int rounds = kvc_run_until_leader(c, 500)
	assert1(rounds >= 0)
	int lid = kvc_leader(c)
	kvc_put(c, lid, c"a", c"1")
	kvc_put(c, lid, c"b", c"2")
	assert1(kvc_run_until_agree(c, c"a", c"1", 500) >= 0)
	assert1(kvc_run_until_agree(c, c"b", c"2", 500) >= 0)
	kvc_node* ldr = c.nodes[lid - 1]
	int* blen = cast(int*, malloc(__word_size__))
	char* blob = kv_take_snapshot(ldr.store, blen)
	assert_equal(1, raft_take_snapshot(ldr.r, blob, blen[0]))
	free(blob)
	free(cast(char*, blen))
	# a few rounds persist the compaction into the leader's OWN
	# raft_wal: raft_wal_sync notices snap_last_index ahead of the
	# shadow and rewrites the file (raft_wal.w's header)
	kvc_run_steps(c, 3)
	kvc_put(c, lid, c"c", c"3")
	assert1(kvc_run_until_agree(c, c"c", c"3", 500) >= 0)
	# crash and rebuild the leader itself: its own wal now replays a
	# SNAPSHOT record, so the rebuilt raft carries a pending snapshot
	kvc_crash(c, lid)
	kvc_rebuild(c, lid, 2000 + lid)
	kvc_node* rb = c.nodes[lid - 1]
	# the lsm's own durability is independent of raft's snapshot
	# bookkeeping: everything applied before the crash is still on disk
	kvc_expect(rb.store, c"a", c"1")
	kvc_expect(rb.store, c"b", c"2")
	kvc_expect(rb.store, c"c", c"3")
	assert_equal(1, raft_has_pending_snapshot(rb.r))
	assert_equal(2, kvc_snap_index_int(rb.r))
	# force actual rounds: a/b/c are already correct on rb's DURABLE lsm
	# (independent of raft, as just shown), so kvc_run_until_agree below
	# would short-circuit on its very first check without ever calling
	# kvc_step -- which would never give kv_apply_pending a chance to
	# drain the pending snapshot at all. Step explicitly first.
	kvc_run_steps(c, 30)
	assert_equal(0, raft_has_pending_snapshot(rb.r))
	# the rebuilt node rejoins (as a follower — the surviving pair
	# elected a successor while it was down) and every live node
	# reconverges on the full a/b/c state, proving the pending-snapshot
	# install did not corrupt the already-durable "c"
	assert1(kvc_run_until_agree(c, c"a", c"1", 500) >= 0)
	assert1(kvc_run_until_agree(c, c"b", c"2", 500) >= 0)
	assert1(kvc_run_until_agree(c, c"c", c"3", 500) >= 0)
	kvc_assert_kv(c, c"a", c"1")
	kvc_assert_kv(c, c"b", c"2")
	kvc_assert_kv(c, c"c", c"3")
	kvc_free(c)


# ---- cluster membership over real TCP (issue #319) ----------------------------------------

# A genuinely fresh 4th node (empty lsm, empty raft wal, never having
# seen a single byte of this cluster's history) joins a live 3-node
# cluster whose log has ALREADY been compacted past everything the
# node would otherwise need replayed individually. raft_propose_add_
# server on the leader replicates the membership change over real
# loopback TCP; the new node's frozen next_index (1, raft_new's
# default — kvc_add_node hands it an EMPTY peers list) sits at or
# below the leader's snapshot base the instant it is wired in, so
# raft_make_peer_msg routes it an InstallSnapshot (raft.w's §7 path)
# before it can ever catch up any other way, and kv_state.w's
# kv_apply_pending installs that blob into its lsm exactly as any
# lagging peer's would (test_cluster_snapshot_laggard_catchup, above)
# -- reused, not rebuilt, per the issue #319 scope note. Once caught
# up it serves reads for every key, proving it is not merely present
# but genuinely usable.
void test_cluster_add_fresh_node_catches_up_via_snapshot():
	kvc* c = kvc_new(c"addnode", 21, 900)
	int rounds = kvc_run_until_leader(c, 500)
	assert1(rounds >= 0)
	int lid = kvc_leader(c)
	kvc_node* ldr = c.nodes[lid - 1]
	kvc_put(c, lid, c"k1", c"v1")
	kvc_put(c, lid, c"k2", c"v2")
	assert1(kvc_run_until_agree(c, c"k1", c"v1", 500) >= 0)
	assert1(kvc_run_until_agree(c, c"k2", c"v2", 500) >= 0)
	# compact the leader's log around the state already applied
	int* blen = cast(int*, malloc(__word_size__))
	char* blob = kv_take_snapshot(ldr.store, blen)
	assert_equal(1, raft_take_snapshot(ldr.r, blob, blen[0]))
	free(blob)
	free(cast(char*, blen))
	assert_equal(0, raft_log_length(ldr.r))
	assert_equal(2, kvc_snap_index_int(ldr.r))
	# one more write lands only after compaction, so the fresh node's
	# catch-up must cover InstallSnapshot AND the post-snapshot suffix
	kvc_put(c, lid, c"k3", c"v3")
	assert1(kvc_run_until_agree(c, c"k3", c"v3", 500) >= 0)

	kvc_node* fresh = kvc_add_node(c, c"addnode", 21)
	kvc_add_server(c, lid, fresh.id)
	# kvc_run_until_agree/kvc_agree iterate every LIVE node up to c.n,
	# which kvc_add_node already bumped, so these three checks only
	# pass once the fresh node itself serves each key too
	assert1(kvc_run_until_agree(c, c"k1", c"v1", 500) >= 0)
	assert1(kvc_run_until_agree(c, c"k2", c"v2", 500) >= 0)
	assert1(kvc_run_until_agree(c, c"k3", c"v3", 500) >= 0)
	# proof it actually installed a snapshot rather than replaying the
	# compacted entries individually: raft only ever sets a follower's
	# own snapshot base from raft_handle_install_snapshot, never from
	# ordinary AppendEntries, so a matching nonzero base is conclusive
	assert1(kvc_snap_index_int(fresh.r) > 0)
	assert_equal(kvc_snap_index_int(ldr.r), kvc_snap_index_int(fresh.r))
	kvc_expect(fresh.store, c"k1", c"v1")
	kvc_expect(fresh.store, c"k2", c"v2")
	kvc_expect(fresh.store, c"k3", c"v3")
	# a genuine voting member now, config settled everywhere
	assert_equal(0, raft_config_pending(ldr.r))
	assert_equal(3, raft_peer_count(ldr.r))
	assert_equal(3, raft_peer_count(fresh.r))
	kvc_free(c)
