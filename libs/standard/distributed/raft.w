/*
Raft consensus (Ongaro & Ousterhout, "In Search of an Understandable
Consensus Algorithm", Figure 2) as a pure state machine
(companion to swim.w; docs/projects/distributed.md).

No sockets and no real clock live here: the caller owns all I/O and
time. It feeds raft_tick/raft_on_msg explicit now_ms timestamps and
raft_msg structs, and collects every outbound message from the `out`
list the caller passes in. Every timing decision routes through the
wrap-safe monotime helpers; election jitter comes from the seeded prng
so runs replay exactly.

Terms and log indexes are u64 (u64.w); every u64 op mutates its first
argument, so values that cross an ownership boundary are cloned.
A raft_msg owns all of its u64 fields and deep copies of its entries
(cloned term, owned copy of the command bytes); raft_msg_free frees
them all.

Commands are opaque, length-carrying byte buffers, not NUL-terminated
strings: every raft_entry carries an explicit command_len, and no code
here (or downstream, e.g. kv_state.w) may assume a command is free of
embedded NUL or any other byte value. raft_entry_new COPIES command_len
bytes out of the buffer it is given (plus a trailing convenience NUL
that is not part of command_len) — entries own their command bytes.
raft_entry_free releases that copy, so a caller's buffer (e.g. the one
raft_propose is given) is never retained past the call: the caller
keeps ownership of what it passed in and may mutate or free it the
instant the call returns.

The log is stored in a 0-based list but is 1-indexed conceptually
(Figure 2 numbering): with no snapshot, conceptual index i lives at
log[i - 1], index 0 means "empty prefix" and never has an entry.
raft_log_at takes the 1-based index. Once a snapshot exists (below),
a compacted prefix is gone and conceptual index i lives at
log[i - snap_base - 1], where snap_base = snap_last_index (0 while no
snapshot exists); raft_last_index is snap_base + log.length and an
empty log's last term is snap_last_term.

v1 choices, documented here because they shape the tests:
  - votes_received counts granted current-term vote replies, one per
    voter: granting peers are tracked in vote_granters (and pre-vote
    granters in prevote_granters), reset wherever the counters reset,
    so a duplicated reply never double-counts (issue #320).
  - raft_propose re-arms the heartbeat deadline, since the appends it
    emits already serve as heartbeats.
  - a failed AppendEntries consistency check still resets the election
    deadline: the sender proved itself the current-term leader.
  - the peers list passed to raft_new is copied; the raft owns its own
    list of peer ids.

Hardening features (Ongaro thesis chapter 6.4 / 9.6), both OFF by
default so the v1 behavior above stays bit-for-bit unchanged; opt in
per node via raft_set_noop_on_win / raft_set_prevote:
  - no-op on election win: a fresh leader immediately appends an entry
    whose command is the EMPTY STRING (the empty command IS the no-op
    marker), so entries from older terms commit through the 5.4.2
    counting rule without waiting for a client proposal. Appliers must
    tolerate empty commands: kv_apply_command (kv_state.w) returns 0
    on them and kv_apply_pending drains them without applying, which
    is exactly the intended treatment.
  - pre-vote: an election timeout first polls the cluster at the
    prospective term current_term + 1 WITHOUT bumping current_term,
    setting voted_for or leaving follower/candidate state; only a
    majority of granted pre-votes starts the real election. A pre-vote
    request never steps its receiver down (its term is a poll, not a
    claim) and is granted only when the candidate's log is at least as
    up-to-date AND the receiver has not heard a valid current-term
    leader append within election_timeout_min_ms (leader stickiness;
    never having heard one counts as no recent contact). Granting a
    pre-vote mutates nothing: no voted_for, no election-timer reset.
    Real (prevote == 0) messages keep the v1 semantics bit-for-bit,
    including step-down on a higher term.

Log compaction / InstallSnapshot (§7):
  - raft_take_snapshot(r, data, len): the state-machine owner declares
    `data` to be its state at exactly last_applied. Raft stores an
    owned copy of the blob (it never interprets it), records
    (last_applied, term at last_applied) as the snapshot meta and
    frees every log entry at or below last_applied. Requires
    last_applied > snap_base, else a 0-returning no-op.
  - a leader whose peer's next_index sits at or below snap_base sends
    an install_snapshot message (type 4) instead of an append — on
    both the heartbeat/tick path and the append_reply-failure backoff
    path. The message REUSES prev_log_index/prev_log_term to carry
    snap_last_index/snap_last_term (no new wire-visible u64 fields),
    carries leader_commit as usual plus an owned copy of the blob,
    and is answered with an ordinary append_reply.
  - receiving a fresh install_snapshot follows the append term rules
    (stale term refused with our term; a valid one proves the leader:
    follow, reset the election timer, record leader contact). A
    snapshot at or below our commit index is STALE: nothing changes
    and the success reply carries match_index = our commit index so
    the leader can advance next_index past the confusion. Otherwise
    the snapshot installs: snap meta adopted, the ENTIRE log discarded
    (the paper permits keeping a matching suffix; whole-log discard is
    the documented simplification — the leader resends the suffix from
    snap index + 1), commit_index = last_applied = snap index, and the
    blob is stored both as our own latest snapshot and in the pending
    slot for the application.
  - pending-snapshot contract: the application's apply loop must check
    raft_has_pending_snapshot FIRST each round and install the blob
    (raft_take_pending_snapshot — ownership of the buffer transfers)
    before applying later entries; raft_pop_apply asserts no snapshot
    is pending, because entries after the snapshot index only make
    sense on top of the snapshot's state.
  - an incoming append whose prev_log_index lies BELOW snap_base is
    the paper's stale-append case: everything at or below the base is
    committed and applied here by construction, so the reply is
    success with match_index = our commit index and the entries are
    not examined. prev_log_index == snap_base matches the snapshot
    boundary and is checked against snap_last_term.

Cluster membership changes (Ongaro thesis §4.1, single-server changes
only -- no joint consensus, matching how etcd ships this):
  - a config change is an ordinary log entry distinguished by
    raft_entry.kind (raft_entry_kind_config vs _normal), NOT by
    sniffing command bytes: raft.w's own peer-set bookkeeping must
    react to these entries regardless of what any higher layer (e.g.
    kv_state.w) happens to choose as its own command tag bytes, so a
    dedicated field is the only collision-proof design. The 5-byte
    command payload (op byte + node id, little-endian u32) is
    otherwise just as opaque/binary-safe as any other command --
    raft_copy_blob, the wire and the wal handle it identically to a
    client command, just carrying a `kind` alongside it.
  - APPLY ON APPEND, not on commit: "a server always uses the latest
    configuration in its log, regardless of whether that entry is
    committed" (§4.1). raft_note_entry_appended runs on every path
    that pushes a new entry onto r.log -- raft_propose_internal
    (leader), raft_handle_append's two append branches (follower) and
    raft_wal_replay_into (crash recovery) -- so live operation and wal
    replay derive byte-identical peer-set history from the same
    sequence of records. It mutates r.peers (add/remove the id),
    reconciles next_index/match_index (raft_sync_index_maps) so a
    brand-new peer is immediately reachable, and records the index as
    config_pending_index (commit not yet reached).
  - SINGLE IN FLIGHT: raft_propose_add_server/raft_propose_remove_
    server refuse a second proposal while config_pending_index > 0
    (§4.1: "the leader will avoid overlapping configuration changes by
    not beginning [a new one] until the prior ... is committed").
    Single-server changes are only safe (no joint consensus needed)
    because they are serialized one at a time this way -- overlapping
    changes could produce two disjoint majorities.
  - ROLLBACK ON TRUNCATION: only one config change can ever be pending,
    so one saved snapshot (config_prev_peers, captured the moment the
    pending entry was itself appended) is always enough to undo it.
    raft_note_truncated_to runs wherever entries at or above a given
    conceptual index are discarded (raft_handle_append's conflict
    path, raft_wal_replay_into's TRUNCATE tag) and restores r.peers
    from config_prev_peers when the truncation reaches back to or past
    config_pending_index.
  - COMMIT: raft_note_commit_advanced runs wherever commit_index
    moves forward (raft_try_advance_commit, raft_handle_append) and
    clears config_pending_index once commit_index reaches it. If the
    committed entry removed this node itself, a LEADER steps down to
    follower right there (§4.1: "[a leader that removes itself] must
    step down and return to follower state as soon as it has committed
    th[e] log entry") -- a follower has nothing to step down from.
  - REMOVAL DISRUPTION (§4.2.1): once removed, a node simply stops
    receiving heartbeats (raft_tick/raft_propose_internal only ever
    iterate the current r.peers) and, left unchecked, would time out
    and solicit votes at ever-higher terms, forcing the live leader to
    step down even though the disruptor no longer matters. This stack's
    existing opt-in pre-vote + leader-stickiness (raft_set_prevote,
    above) is exactly thesis §4.2.1's mitigation -- a receiver that has
    heard a valid current-term leader within election_timeout_min_ms
    refuses to grant even a real vote's PRE-vote poll -- so enabling it
    is sufficient to keep a removed node from disrupting a stable
    leader. What is NOT implemented is thesis §4.2.3's fuller leader-
    lease / check-quorum refinement (a leader tracking per-follower
    recent-contact to safely ignore votes without waiting on pre-vote
    timing at all, and to answer reads without a quorum round-trip);
    this stack has no per-follower contact-tracking plumbing on the
    leader side, so that refinement is deferred as follow-up, not
    silently assumed. raft_handle_vote_req also does not filter
    requests by current r.peers membership -- a removed node's real
    vote solicitation is refused by the SAME pre-vote/stickiness path
    only when pre-vote is enabled; running without it reproduces the
    disruption risk the thesis describes.
  - PERSISTENCE: config-change entries ride the ordinary APPEND/
    TRUNCATE wal records (raft_wal.w) via the same replay hooks as
    live operation (above), so current_term/voted_for/log-derived
    config all survive a restart together. A taken or received
    snapshot ALSO records the config in effect at its index --
    r.snap_config, the FULL member set (self-inclusive, so it is
    receiver-agnostic and can be forwarded verbatim) -- because a
    snapshot may cover a compacted prefix a fresh node never saw as
    individual entries; raft_adopt_snapshot_config derives each
    receiver's own self-exclusive r.peers by subtracting its own id.
    This is a wire (install_snapshot) and wal (SNAPSHOT record) layout
    change from phase 5/6, deliberately: see raft_wire.w/raft_wal.w
    headers and the updated layout-pinning tests.
  - NEW-NODE BOOTSTRAP: a freshly added id gets next_index = 1 (empty
    log assumed) the moment its add-server entry is appended, so it is
    immediately routed through the EXISTING §7 InstallSnapshot path
    (raft_make_peer_msg) once the leader's log has compacted past
    index 1, or ordinary replication otherwise -- no bespoke bootstrap
    RPC. A learner/non-voting catch-up phase (thesis §4.2.1's other
    half, join-as-non-voter-first) is OUT OF SCOPE (issue #319): a
    newly added server is a full voter from the moment its entry is
    appended, which can transiently cost availability if it is far
    behind when added (Figure 4.6's motivation for learners) -- left
    as documented follow-up.
*/
import lib.lib
import lib.memory
import lib.assert
import libs.standard.distributed.u64
import libs.standard.distributed.monotime
import libs.standard.distributed.prng


# ---- states -----------------------------------------------------------------

int raft_follower():
	return 0


int raft_candidate():
	return 1


int raft_leader():
	return 2


# ---- message types ----------------------------------------------------------

int raft_msg_vote_req():
	return 0


int raft_msg_vote_reply():
	return 1


int raft_msg_append():
	return 2


int raft_msg_append_reply():
	return 3


int raft_msg_install_snapshot():
	return 4


# ---- log entries -------------------------------------------------------------

# Malloc'd copy of len blob bytes (binary-safe; a trailing NUL is
# added for convenience but is not part of the blob).
char* raft_copy_blob(char* data, int len):
	char* p = malloc(len + 1)
	int i = 0
	while (i < len):
		p[i] = data[i]
		i = i + 1
	p[len] = 0
	return p


struct raft_entry:
	u64* term         # entry owns this
	char* command     # entry-owned copy; opaque bytes, may contain NUL
	int command_len   # authoritative length of command in bytes
	int kind          # raft_entry_kind_normal/config (see header)


# Normal (kind = raft_entry_kind_normal) client command; see
# raft_entry_kind_config() and raft_entry_new_kind for config-change
# entries.
int raft_entry_kind_normal():
	return 0


# A membership-change entry (header, "Cluster membership changes"):
# command is a 5-byte payload (op byte + node id, little-endian u32 --
# raft_config_encode/raft_config_decode) that raft.w itself interprets
# via raft_note_entry_appended, in addition to riding opaquely through
# the wire and wal like any other entry.
int raft_entry_kind_config():
	return 1


# Clones term and COPIES command_len bytes out of command into a fresh
# entry-owned buffer (plus one trailing convenience NUL not counted in
# command_len, matching raft_copy_blob's snapshot-blob convention) —
# the caller's buffer is untouched and may be freed or reused the
# instant this returns. command bytes are opaque: no NUL assumptions.
raft_entry* raft_entry_new_kind(u64* term, char* command, int command_len, int kind):
	assert1(command_len >= 0)
	raft_entry* e = new raft_entry()
	e.term = u64_clone(term)
	e.command = raft_copy_blob(command, command_len)
	e.command_len = command_len
	e.kind = kind
	return e


# Convenience wrapper for the overwhelmingly common case (a normal
# client command); see raft_entry_new_kind for the kind-carrying form
# config entries and entry-preserving copies need.
raft_entry* raft_entry_new(u64* term, char* command, int command_len):
	return raft_entry_new_kind(term, command, command_len, raft_entry_kind_normal())


void raft_entry_free(raft_entry* e):
	u64_free(e.term)
	free(e.command)
	free(e)


# ---- messages ----------------------------------------------------------------

# One struct for all five message types, tagged by `type`. A message
# owns every u64 field, deep copies of its entries and its snapshot
# blob; raft_msg_free releases all of it. Fields not used by a type
# stay zero/empty. install_snapshot REUSES prev_log_index /
# prev_log_term for the snapshot's last included index and term, and
# leader_commit as usual (see header).
struct raft_msg:
	int type              # raft_msg_vote_req/vote_reply/append/append_reply/install_snapshot
	int from
	int to
	u64* term             # sender's term, always set
	u64* last_log_index   # vote_req
	u64* last_log_term    # vote_req
	int vote_granted      # vote_reply
	u64* prev_log_index   # append; install_snapshot: snapshot last index
	u64* prev_log_term    # append; install_snapshot: snapshot last term
	u64* leader_commit    # append/install_snapshot
	list[raft_entry*] entries   # append; empty = heartbeat; deep copies
	int success           # append_reply
	u64* match_index      # append_reply
	int prevote           # vote_req/vote_reply: pre-vote round flag
	char* snap_data       # install_snapshot: blob bytes (owned; 0 = none)
	int snap_len          # install_snapshot: blob length
	list[int] snap_config # install_snapshot: FULL member set at the snapshot (self-inclusive; see raft.w's membership header)


# Clones term; every other u64 field is allocated as zero so
# raft_msg_free is uniform.
raft_msg* raft_msg_new(int type, int from, int to, u64* term):
	raft_msg* m = new raft_msg()
	m.type = type
	m.from = from
	m.to = to
	m.term = u64_clone(term)
	m.last_log_index = u64_new()
	m.last_log_term = u64_new()
	m.vote_granted = 0
	m.prev_log_index = u64_new()
	m.prev_log_term = u64_new()
	m.leader_commit = u64_new()
	m.entries = new list[raft_entry*]
	m.success = 0
	m.match_index = u64_new()
	m.prevote = 0
	m.snap_data = 0
	m.snap_len = 0
	m.snap_config = new list[int]
	return m


# Deep free: all u64 fields, every owned entry and the snapshot blob.
# The entries list storage itself is runtime-managed (matching
# swim_free in swim.w).
void raft_msg_free(raft_msg* m):
	u64_free(m.term)
	u64_free(m.last_log_index)
	u64_free(m.last_log_term)
	u64_free(m.prev_log_index)
	u64_free(m.prev_log_term)
	u64_free(m.leader_commit)
	int i = 0
	while (i < m.entries.length):
		raft_entry_free(m.entries[i])
		i = i + 1
	u64_free(m.match_index)
	if (m.snap_data != 0):
		free(m.snap_data)
	free(m)


# ---- node state ---------------------------------------------------------------

struct raft:
	int self_id
	list[int] peers            # other node ids, never including self
	# persistent state (Figure 2)
	u64* current_term
	int voted_for              # node id, 0 - 1 = none
	list[raft_entry*] log      # 0-based storage, 1-based conceptual index
	# volatile state
	int state                  # raft_follower/raft_candidate/raft_leader
	u64* commit_index
	u64* last_applied
	int leader_hint            # last known leader id, 0 - 1 = unknown
	# leader state, meaningful only while state == raft_leader
	map[int, u64*] next_index
	map[int, u64*] match_index
	# timers (monotime timestamps)
	int election_deadline
	int heartbeat_deadline
	# config
	int election_timeout_min_ms
	int election_timeout_max_ms
	int heartbeat_ms
	prng* rng
	int votes_received         # granted votes in the current election
	set[int] vote_granters     # peers already counted in votes_received (#320)
	# hardening (both opt-in; see header)
	int noop_on_win            # 1: append an empty no-op command on winning
	int prevote_enabled        # 1: poll a pre-vote round before real elections
	int prevotes_received      # granted pre-votes in the pending round (self counts)
	set[int] prevote_granters  # peers already counted in prevotes_received (#320)
	int last_leader_contact    # timestamp of the last valid current-term leader append
	int has_leader_contact     # 0 until the first such append ("never heard")
	# snapshot state (§7 log compaction; index 0/term 0 = no snapshot)
	u64* snap_last_index       # last log index covered by the snapshot
	u64* snap_last_term        # term of the entry at snap_last_index
	char* snap_data            # latest snapshot blob (owned; 0 = none)
	int snap_len
	list[int] snap_config      # FULL member set (self-inclusive) at snap_last_index; see membership header
	# inbound snapshot awaiting the state-machine owner (see header)
	char* pending_snap_data    # owned; 0 = none pending
	int pending_snap_len
	u64* pending_snap_index    # last included index of the pending blob
	# cluster membership changes (§4.1, single-server changes; see header)
	int config_pending_index      # conceptual log index of the not-yet-committed config-change entry; 0 = none in flight
	int config_pending_removes_self  # 1 iff the pending entry removes self_id (drives the leader step-down on commit)
	list[int] config_prev_peers   # r.peers as of just before the pending entry was appended (rollback source)


# ---- small helpers -------------------------------------------------------------

# The u64 as a host int; logs stay small enough that every index the
# protocol touches fits (asserted).
int raft_u64_as_int(u64* v):
	assert1(u64_fits_int(v))
	return u64_to_int(v)


# The snapshot base as a host int: the last conceptual index covered
# by the compacted prefix (0 = no snapshot). Conceptual index i lives
# at log[i - base - 1] for every i above the base.
int raft_snap_base(raft* r):
	return raft_u64_as_int(r.snap_last_index)


# Last log index (1-based conceptual; 0 = empty log and no snapshot).
int raft_last_index(raft* r):
	return raft_snap_base(r) + r.log.length


# Term of the last log entry into out; the snapshot's last term when
# the log is empty (zero when there is no snapshot either).
void raft_last_term(raft* r, u64* out):
	if (r.log.length == 0):
		u64_copy(out, r.snap_last_term)
		return
	raft_entry* last = r.log[r.log.length - 1]
	u64_copy(out, last.term)


# Smallest majority of the full cluster (peers plus self).
int raft_majority(raft* r):
	return (r.peers.length + 1) / 2 + 1


# Index of id in r.peers, or -1 when id is not a current peer.
int raft_peer_index(raft* r, int id):
	int i = 0
	while (i < r.peers.length):
		if (r.peers[i] == id):
			return i
		i = i + 1
	return 0 - 1


int raft_is_peer(raft* r, int id):
	if (raft_peer_index(r, id) >= 0):
		return 1
	return 0


# Fresh owned copy of src, element by element (list[int] has no
# built-in clone).
list[int] raft_clone_int_list(list[int] src):
	list[int] out = new list[int]
	int i = 0
	while (i < src.length):
		out.push(src[i])
		i = i + 1
	return out


void raft_reset_election_deadline(raft* r, int now_ms):
	int timeout = prng_between(r.rng, r.election_timeout_min_ms, r.election_timeout_max_ms)
	r.election_deadline = mono_deadline(now_ms, timeout)


# Forget the recorded vote granters (issue #320 dedup); called wherever
# votes_received resets. Reassigning only when non-empty keeps the
# common already-empty case allocation-free; the replaced storage is
# runtime-managed like every other container here.
void raft_clear_vote_granters(raft* r):
	if (r.vote_granters.length > 0):
		r.vote_granters = new set[int]


# Same for the pre-vote granters; called wherever prevotes_received
# resets — including the hot path where every valid current-term leader
# append cancels a pending pre-vote round.
void raft_clear_prevote_granters(raft* r):
	if (r.prevote_granters.length > 0):
		r.prevote_granters = new set[int]


# A term strictly greater than ours was observed: adopt it and fall
# back to follower with no vote and no known leader. Does NOT touch the
# election deadline (stale-message rule: only vote grants, valid
# appends and election starts reset it).
void raft_step_down(raft* r, u64* term):
	u64_copy(r.current_term, term)
	r.state = raft_follower()
	r.voted_for = 0 - 1
	r.leader_hint = 0 - 1
	r.votes_received = 0
	r.prevotes_received = 0
	raft_clear_vote_granters(r)
	raft_clear_prevote_granters(r)


# ---- lifecycle -----------------------------------------------------------------

raft* raft_new(int self_id, list[int] peers, int election_min_ms, int election_max_ms, int heartbeat_ms, int seed):
	assert1(heartbeat_ms > 0)
	assert1(heartbeat_ms < election_min_ms)
	assert1(election_min_ms <= election_max_ms)
	raft* r = new raft()
	r.self_id = self_id
	r.peers = new list[int]
	int i = 0
	while (i < peers.length):
		assert1(peers[i] != self_id)
		r.peers.push(peers[i])
		i = i + 1
	r.current_term = u64_new()
	r.voted_for = 0 - 1
	r.log = new list[raft_entry*]
	r.state = raft_follower()
	r.commit_index = u64_new()
	r.last_applied = u64_new()
	r.leader_hint = 0 - 1
	r.next_index = new map[int, u64*]
	r.match_index = new map[int, u64*]
	i = 0
	while (i < r.peers.length):
		r.next_index[r.peers[i]] = u64_new_int(1)
		r.match_index[r.peers[i]] = u64_new()
		i = i + 1
	r.election_deadline = 0
	r.heartbeat_deadline = 0
	r.election_timeout_min_ms = election_min_ms
	r.election_timeout_max_ms = election_max_ms
	r.heartbeat_ms = heartbeat_ms
	r.rng = prng_new(seed)
	r.votes_received = 0
	r.vote_granters = new set[int]
	r.noop_on_win = 0
	r.prevote_enabled = 0
	r.prevotes_received = 0
	r.prevote_granters = new set[int]
	r.last_leader_contact = 0
	r.has_leader_contact = 0
	r.snap_last_index = u64_new()
	r.snap_last_term = u64_new()
	r.snap_data = 0
	r.snap_len = 0
	r.snap_config = new list[int]
	r.pending_snap_data = 0
	r.pending_snap_len = 0
	r.pending_snap_index = u64_new()
	r.config_pending_index = 0
	r.config_pending_removes_self = 0
	r.config_prev_peers = new list[int]
	return r


# Frees every owned u64, log entry and the prng; the list/map storage
# is runtime-managed (matching swim_free in swim.w).
void raft_free(raft* r):
	u64_free(r.current_term)
	u64_free(r.commit_index)
	u64_free(r.last_applied)
	int i = 0
	while (i < r.log.length):
		raft_entry_free(r.log[i])
		i = i + 1
	i = 0
	while (i < r.peers.length):
		u64_free(r.next_index[r.peers[i]])
		u64_free(r.match_index[r.peers[i]])
		i = i + 1
	prng_free(r.rng)
	u64_free(r.snap_last_index)
	u64_free(r.snap_last_term)
	if (r.snap_data != 0):
		free(r.snap_data)
	if (r.pending_snap_data != 0):
		free(r.pending_snap_data)
	u64_free(r.pending_snap_index)
	free(r)


# Arms the first randomized election deadline. Call once before the
# first raft_tick.
void raft_start(raft* r, int now_ms):
	raft_reset_election_deadline(r, now_ms)


# ---- hardening config (both default off; see header) ----------------------------

void raft_set_noop_on_win(raft* r, int enabled):
	r.noop_on_win = enabled


void raft_set_prevote(raft* r, int enabled):
	r.prevote_enabled = enabled


# ---- cluster membership changes (§4.1, single-server changes; see header) -------

int raft_config_op_add():
	return 1


int raft_config_op_remove():
	return 2


# 5-byte config-entry command: op byte + node id (little-endian u32).
# Malloc'd; caller frees (matching raft_copy_blob's plain-buffer
# convention — command_len is always exactly 5 for these).
char* raft_config_encode(int op, int id):
	char* cmd = malloc(5)
	cmd[0] = op
	cmd[1] = id
	cmd[2] = id >> 8
	cmd[3] = id >> 16
	cmd[4] = id >> 24
	return cmd


void raft_config_decode(char* command, int command_len, int* op_out, int* id_out):
	assert1(command_len == 5)
	op_out[0] = command[0] & 255
	id_out[0] = (command[1] & 255) | ((command[2] & 255) << 8) | ((command[3] & 255) << 16) | ((command[4] & 255) << 24)


# Reconcile next_index/match_index against the CURRENT r.peers: insert
# fresh entries (next_index 1, match_index 0) for any peer missing one
# and drop (freeing the u64s) any map entry for an id no longer in
# r.peers. Called after every r.peers mutation (add/remove/rollback/
# snapshot-adopt) so raft_become_leader's direct pointer dereference
# (r.next_index[p] etc, which assumes the key exists) and raft_free's
# cleanup loop (which only visits ids currently in r.peers) both stay
# correct no matter how r.peers got here.
void raft_sync_index_maps(raft* r):
	int i = 0
	while (i < r.peers.length):
		int p = r.peers[i]
		if ((p in r.next_index) == 0):
			r.next_index[p] = u64_new_int(1)
		if ((p in r.match_index) == 0):
			r.match_index[p] = u64_new()
		i = i + 1
	list[int] keys = r.next_index.keys()
	i = 0
	while (i < keys.length):
		int k = keys[i]
		if (raft_peer_index(r, k) < 0):
			u64_free(r.next_index[k])
			u64_free(r.match_index[k])
			r.next_index.remove(k)
			r.match_index.remove(k)
		i = i + 1


# APPLY ON APPEND (§4.1 — see header): called on every path that
# pushes a NEW entry onto r.log (raft_propose_internal, both of
# raft_handle_append's append branches, raft_wal_replay_into) with the
# entry's own conceptual index. A no-op for a normal entry. For a
# config entry: snapshots the pre-change r.peers into config_prev_peers
# (the rollback source if this very entry later gets truncated away),
# records config_pending_index = idx, and — unless the target is this
# node itself, which is never a member of its own r.peers — mutates
# r.peers (push for add, remove for remove) and reconciles the
# next_index/match_index maps so a brand-new peer is immediately
# reachable on the very next send. A remove targeting self_id touches
# no list (see raft_propose_remove_server) but is remembered via
# config_pending_removes_self for raft_note_commit_advanced.
void raft_note_entry_appended(raft* r, int idx, raft_entry* e):
	if (e.kind != raft_entry_kind_config()):
		return
	int op = 0
	int id = 0
	raft_config_decode(e.command, e.command_len, &op, &id)
	r.config_prev_peers = raft_clone_int_list(r.peers)
	r.config_pending_index = idx
	r.config_pending_removes_self = 0
	if (op == raft_config_op_add()):
		if (id != r.self_id && raft_is_peer(r, id) == 0):
			r.peers.push(id)
	if (op == raft_config_op_remove()):
		if (id == r.self_id):
			r.config_pending_removes_self = 1
		else:
			int pi = raft_peer_index(r, id)
			if (pi >= 0):
				r.peers.remove(pi)
	raft_sync_index_maps(r)


# ROLLBACK ON TRUNCATION (§4.1 — see header): keep is the largest
# conceptual index that SURVIVES a truncation (raft_handle_append's
# conflict path truncates from a conceptual idx onward, so keep =
# idx - 1; raft_wal_replay_into's TRUNCATE tag keeps a COUNT above the
# snapshot base, so keep = snap_base + that count). When the still-
# pending config entry's index falls at or above the truncated range,
# its effect never happened as far as the surviving log is concerned:
# restore r.peers from config_prev_peers (captured the moment that
# entry was itself appended — see raft_note_entry_appended) and clear
# the pending bookkeeping. Only one config change can ever be pending
# at a time (the single-in-flight rule), so one saved snapshot is
# always enough — there is never a stack of in-flight changes to
# unwind.
void raft_note_truncated_to(raft* r, int keep):
	if (r.config_pending_index > 0 && r.config_pending_index > keep):
		r.peers = r.config_prev_peers
		r.config_prev_peers = new list[int]
		raft_sync_index_maps(r)
		r.config_pending_index = 0
		r.config_pending_removes_self = 0


# Called wherever commit_index moves forward (raft_try_advance_commit,
# raft_handle_append). Once commit_index reaches the pending config
# entry's index, that config is durable: clear the pending bookkeeping,
# and if the just-committed entry removed THIS node and it is still
# leader, step down to follower right here — thesis §4.1: "[a leader
# that removes itself] must step down and return to follower state as
# soon as it has committed th[e] log entry". A follower has nothing to
# step down from, so config_pending_removes_self is otherwise inert
# (see the header's REMOVAL DISRUPTION note for what happens next).
void raft_note_commit_advanced(raft* r):
	if (r.config_pending_index > 0 && raft_u64_as_int(r.commit_index) >= r.config_pending_index):
		if (r.config_pending_removes_self == 1 && r.state == raft_leader()):
			r.state = raft_follower()
			r.leader_hint = 0 - 1
		r.config_pending_index = 0
		r.config_pending_removes_self = 0
		r.config_prev_peers = new list[int]


# The FULL member set (self-inclusive) in effect at exactly
# last_applied, for a snapshot's own metadata (raft_take_snapshot).
# last_applied <= commit_index always (only committed entries are ever
# applied), and config_pending_index (when set) is always strictly
# ABOVE commit_index (an uncommitted entry cannot have been applied
# yet) — so whenever a config change is pending, r.peers already
# reflects it prematurely for last_applied's purposes, and the correct
# answer is the pre-change snapshot instead (config_prev_peers); with
# nothing pending, r.peers already IS the config at last_applied.
list[int] raft_full_config_at_last_applied(raft* r):
	list[int] base = r.peers
	if (r.config_pending_index > 0):
		base = r.config_prev_peers
	list[int] full = raft_clone_int_list(base)
	full.push(r.self_id)
	return full


list[int] raft_config_exclude_self(raft* r, list[int] cfg):
	list[int] out = new list[int]
	int i = 0
	while (i < cfg.length):
		if (cfg[i] != r.self_id):
			out.push(cfg[i])
		i = i + 1
	return out


# Adopt an externally-supplied FULL member set (self-inclusive — a
# received or wal-replayed snapshot's recorded config, header) as the
# definitive config: r.snap_config keeps the full set unchanged (so it
# can be forwarded verbatim to a future InstallSnapshot recipient
# without re-deriving anything), while r.peers becomes this node's own
# self-exclusive view (raft_config_exclude_self). A snapshot's config
# is committed-and-applied by definition, so any pending in-flight
# config change is discarded, not rolled back to — the snapshot
# supersedes it outright.
void raft_adopt_snapshot_config(raft* r, list[int] cfg):
	r.snap_config = raft_clone_int_list(cfg)
	r.peers = raft_config_exclude_self(r, cfg)
	raft_sync_index_maps(r)
	r.config_pending_index = 0
	r.config_pending_removes_self = 0
	r.config_prev_peers = new list[int]


# ---- outbound message construction ----------------------------------------------

# AppendEntries to peer from its next_index: prev fields describe the
# entry just before next_index, entries carries deep copies of
# everything from next_index to the end of the log (empty = heartbeat).
# next_index must sit above the snapshot base (raft_make_peer_msg
# routes lower next_index values to InstallSnapshot); a prev exactly
# at the base takes the snapshot's last term.
raft_msg* raft_make_append(raft* r, int peer):
	raft_msg* m = raft_msg_new(raft_msg_append(), r.self_id, peer, r.current_term)
	int base = raft_snap_base(r)
	int next_i = raft_u64_as_int(r.next_index[peer])
	assert1(next_i >= base + 1 && next_i <= base + r.log.length + 1)
	int prev_i = next_i - 1
	u64_set_int(m.prev_log_index, prev_i)
	if (prev_i == base):
		u64_copy(m.prev_log_term, r.snap_last_term)
	if (prev_i > base):
		raft_entry* prev_e = r.log[prev_i - base - 1]
		u64_copy(m.prev_log_term, prev_e.term)
	int k = next_i
	while (k <= base + r.log.length):
		raft_entry* e = r.log[k - base - 1]
		m.entries.push(raft_entry_new_kind(e.term, e.command, e.command_len, e.kind))
		k = k + 1
	u64_copy(m.leader_commit, r.commit_index)
	return m


# InstallSnapshot to peer: prev_log_index/prev_log_term are REUSED to
# carry the snapshot's last included index and term (header), the
# blob rides as an owned deep copy and leader_commit as usual. The
# reply is an ordinary append_reply.
raft_msg* raft_make_install_snapshot(raft* r, int peer):
	raft_msg* m = raft_msg_new(raft_msg_install_snapshot(), r.self_id, peer, r.current_term)
	u64_copy(m.prev_log_index, r.snap_last_index)
	u64_copy(m.prev_log_term, r.snap_last_term)
	u64_copy(m.leader_commit, r.commit_index)
	m.snap_data = raft_copy_blob(r.snap_data, r.snap_len)
	m.snap_len = r.snap_len
	m.snap_config = raft_clone_int_list(r.snap_config)
	return m


# The append-or-snapshot decision for peer: a next_index at or below
# the snapshot base points into the compacted prefix, which can no
# longer be shipped entry by entry — ship the snapshot instead (§7).
# Every leader send path (initial heartbeats, tick heartbeats, propose
# fan-out, reply-failure backoff) routes through here.
raft_msg* raft_make_peer_msg(raft* r, int peer):
	if (raft_u64_as_int(r.next_index[peer]) <= raft_snap_base(r)):
		return raft_make_install_snapshot(r, peer)
	return raft_make_append(r, peer)


# ---- commit rule (leader) --------------------------------------------------------

# Advance commit_index to the largest N in (commit_index, last log
# index] replicated on a majority (self counts) whose entry is from the
# current term (§5.4.2: never count replicas to commit an older-term
# entry directly).
void raft_try_advance_commit(raft* r):
	int best = 0
	u64* n_val = u64_new()
	int base = raft_snap_base(r)
	int n = raft_u64_as_int(r.commit_index) + 1
	if (n <= base):
		n = base + 1   # everything at or below the base is committed
	while (n <= base + r.log.length):
		u64_set_int(n_val, n)
		int count = 1
		int i = 0
		while (i < r.peers.length):
			if (u64_cmp(r.match_index[r.peers[i]], n_val) >= 0):
				count = count + 1
			i = i + 1
		if (count >= raft_majority(r)):
			raft_entry* e = r.log[n - base - 1]
			if (u64_eq(e.term, r.current_term)):
				best = n
		n = n + 1
	u64_free(n_val)
	if (best > 0):
		u64_set_int(r.commit_index, best)
		raft_note_commit_advanced(r)


# ---- role transitions -------------------------------------------------------------

# Won the election: initialize leader bookkeeping (next = last log
# index + 1, match = 0 for every peer), emit initial empty heartbeats
# right away, and arm the heartbeat timer. Nothing is committed here —
# entries from older terms only commit via the current-term counting
# rule (§5.4.2).
#
# With noop_on_win set, the empty no-op command is appended AFTER
# next_index was initialized, so the initial appends below carry it —
# the same slot a raft_propose entry would get — and the bookkeeping
# mirrors raft_propose exactly, including raft_try_advance_commit: a
# single-node cluster commits the no-op (and everything before it,
# closing the §5.4.2 gap) right here.
void raft_become_leader(raft* r, int now_ms, list[raft_msg*] out):
	r.state = raft_leader()
	r.leader_hint = r.self_id
	int i = 0
	while (i < r.peers.length):
		int p = r.peers[i]
		u64_set_int(r.next_index[p], raft_last_index(r) + 1)
		u64_set_int(r.match_index[p], 0)
		i = i + 1
	if (r.noop_on_win == 1):
		r.log.push(raft_entry_new(r.current_term, c"", 0))
	i = 0
	while (i < r.peers.length):
		out.push(raft_make_peer_msg(r, r.peers[i]))
		i = i + 1
	r.heartbeat_deadline = mono_deadline(now_ms, r.heartbeat_ms)
	if (r.noop_on_win == 1):
		raft_try_advance_commit(r)


# Election timeout fired (as follower, or as a candidate whose election
# split): bump the term, vote for self, re-arm a fresh randomized
# deadline and solicit votes. A single-node cluster wins immediately.
void raft_start_election(raft* r, int now_ms, list[raft_msg*] out):
	r.state = raft_candidate()
	u64_inc(r.current_term)
	r.voted_for = r.self_id
	r.leader_hint = 0 - 1
	r.votes_received = 1
	r.prevotes_received = 0
	raft_clear_vote_granters(r)
	raft_clear_prevote_granters(r)
	raft_reset_election_deadline(r, now_ms)
	u64* last_term = u64_new()
	raft_last_term(r, last_term)
	int i = 0
	while (i < r.peers.length):
		raft_msg* m = raft_msg_new(raft_msg_vote_req(), r.self_id, r.peers[i], r.current_term)
		u64_set_int(m.last_log_index, raft_last_index(r))
		u64_copy(m.last_log_term, last_term)
		out.push(m)
		i = i + 1
	u64_free(last_term)
	if (r.votes_received >= raft_majority(r)):
		raft_become_leader(r, now_ms, out)


# Election timeout with pre-vote enabled (§9.6): poll the cluster at
# the prospective term current_term + 1 without touching current_term,
# voted_for or state. Counts itself, re-arms the randomized deadline
# like a real election start, and sends vote_reqs flagged prevote = 1
# carrying the usual last-log credentials. A single-node cluster is
# its own majority and proceeds straight to the real election.
void raft_start_prevote(raft* r, int now_ms, list[raft_msg*] out):
	r.prevotes_received = 1
	raft_clear_prevote_granters(r)
	raft_reset_election_deadline(r, now_ms)
	u64* prospective = u64_clone(r.current_term)
	u64_inc(prospective)
	u64* last_term = u64_new()
	raft_last_term(r, last_term)
	int i = 0
	while (i < r.peers.length):
		raft_msg* m = raft_msg_new(raft_msg_vote_req(), r.self_id, r.peers[i], prospective)
		m.prevote = 1
		u64_set_int(m.last_log_index, raft_last_index(r))
		u64_copy(m.last_log_term, last_term)
		out.push(m)
		i = i + 1
	u64_free(last_term)
	u64_free(prospective)
	if (r.prevotes_received >= raft_majority(r)):
		raft_start_election(r, now_ms, out)


# ---- timers --------------------------------------------------------------------

void raft_tick(raft* r, int now_ms, list[raft_msg*] out):
	if (r.state == raft_leader()):
		if (mono_expired(now_ms, r.heartbeat_deadline)):
			int i = 0
			while (i < r.peers.length):
				out.push(raft_make_peer_msg(r, r.peers[i]))
				i = i + 1
			r.heartbeat_deadline = mono_deadline(now_ms, r.heartbeat_ms)
		return
	if (mono_expired(now_ms, r.election_deadline)):
		if (r.prevote_enabled == 1):
			raft_start_prevote(r, now_ms, out)
			return
		raft_start_election(r, now_ms, out)


# ---- message handlers -------------------------------------------------------------

# RequestVote. By the time this runs a higher term has already been
# adopted, so m.term <= current_term. Grant iff same term, no
# conflicting vote this term, and the candidate's log is at least as
# up-to-date (§5.4.1). Granting resets the election deadline.
void raft_handle_vote_req(raft* r, raft_msg* m, int now_ms, list[raft_msg*] out):
	raft_msg* reply = raft_msg_new(raft_msg_vote_reply(), r.self_id, m.from, r.current_term)
	reply.vote_granted = 0
	if (u64_cmp(m.term, r.current_term) < 0):
		out.push(reply)
		return
	int can_vote = 0
	if (r.voted_for == (0 - 1) || r.voted_for == m.from):
		can_vote = 1
	int up_to_date = 0
	u64* my_last_term = u64_new()
	raft_last_term(r, my_last_term)
	int cmp_t = u64_cmp(m.last_log_term, my_last_term)
	if (cmp_t > 0):
		up_to_date = 1
	if (cmp_t == 0):
		u64* my_last_index = u64_new_int(raft_last_index(r))
		if (u64_cmp(m.last_log_index, my_last_index) >= 0):
			up_to_date = 1
		u64_free(my_last_index)
	u64_free(my_last_term)
	if (can_vote == 1 && up_to_date == 1):
		reply.vote_granted = 1
		r.voted_for = m.from
		raft_reset_election_deadline(r, now_ms)
	out.push(reply)


# Pre-vote RequestVote (m.prevote == 1), dispatched BEFORE the
# step-down rule: its prospective term is a poll, never a claim, so it
# must not bump anyone (§9.6). Grant iff the request is not from a
# stale term, the candidate's log is at least as up-to-date (the same
# §5.4.1 rule real votes use), and this node has NOT heard a valid
# current-term leader append within election_timeout_min_ms (leader
# stickiness; never having heard one counts as no recent contact).
# Granting mutates nothing: no voted_for, no election-deadline reset.
# The reply echoes the prospective term with prevote = 1.
void raft_handle_prevote_req(raft* r, raft_msg* m, int now_ms, list[raft_msg*] out):
	raft_msg* reply = raft_msg_new(raft_msg_vote_reply(), r.self_id, m.from, m.term)
	reply.prevote = 1
	reply.vote_granted = 0
	if (u64_cmp(m.term, r.current_term) < 0):
		out.push(reply)
		return
	int up_to_date = 0
	u64* my_last_term = u64_new()
	raft_last_term(r, my_last_term)
	int cmp_t = u64_cmp(m.last_log_term, my_last_term)
	if (cmp_t > 0):
		up_to_date = 1
	if (cmp_t == 0):
		u64* my_last_index = u64_new_int(raft_last_index(r))
		if (u64_cmp(m.last_log_index, my_last_index) >= 0):
			up_to_date = 1
		u64_free(my_last_index)
	u64_free(my_last_term)
	int recent_leader = 0
	if (r.has_leader_contact == 1 && mono_delta_ms(now_ms, r.last_leader_contact) < r.election_timeout_min_ms):
		recent_leader = 1
	if (up_to_date == 1 && recent_leader == 0):
		reply.vote_granted = 1
	out.push(reply)


# Pre-vote RequestVote reply (m.prevote == 1), also dispatched before
# the step-down rule (the echoed prospective term must not bump the
# candidate that coined it). THE GUARD against stale/duplicate replies
# once the real election has started: a reply only counts while
# (a) prevotes_received >= 1 — a pre-vote round is pending; the counter
# is zeroed by raft_start_election, by raft_step_down and by any valid
# current-term leader append — and (b) the echoed term equals
# current_term + 1, this round's prospective term; the real election
# bumps current_term, so the finished round's replies (now carrying
# term == current_term) fail this check. Leaders never count pre-votes.
# Each granter counts once per round (prevote_granters, issue #320).
void raft_handle_prevote_reply(raft* r, raft_msg* m, int now_ms, list[raft_msg*] out):
	if (r.state == raft_leader()):
		return
	if (r.prevotes_received < 1):
		return
	if (m.vote_granted == 0):
		return
	u64* prospective = u64_clone(r.current_term)
	u64_inc(prospective)
	int round_match = u64_eq(m.term, prospective)
	u64_free(prospective)
	if (round_match == 0):
		return
	if (m.from in r.prevote_granters):
		return
	r.prevote_granters.add(m.from)
	r.prevotes_received = r.prevotes_received + 1
	if (r.prevotes_received >= raft_majority(r)):
		raft_start_election(r, now_ms, out)


# RequestVote reply. Only a granted current-term reply while still a
# candidate counts, and each voter counts once per election
# (vote_granters, issue #320); reaching a majority wins the election.
void raft_handle_vote_reply(raft* r, raft_msg* m, int now_ms, list[raft_msg*] out):
	if (r.state != raft_candidate()):
		return
	if (u64_eq(m.term, r.current_term) == 0):
		return
	if (m.vote_granted == 0):
		return
	if (m.from in r.vote_granters):
		return
	r.vote_granters.add(m.from)
	r.votes_received = r.votes_received + 1
	if (r.votes_received >= raft_majority(r)):
		raft_become_leader(r, now_ms, out)


# AppendEntries. A current-term append proves a legitimate leader:
# follow it and reset the election deadline even when the consistency
# check fails. On success, conflicting suffixes are truncated (freed)
# and missing entries appended as deep copies; commit_index advances to
# min(leader_commit, index of the last entry known to match).
void raft_handle_append(raft* r, raft_msg* m, int now_ms, list[raft_msg*] out):
	raft_msg* reply = raft_msg_new(raft_msg_append_reply(), r.self_id, m.from, r.current_term)
	reply.success = 0
	if (u64_cmp(m.term, r.current_term) < 0):
		out.push(reply)
		return
	r.state = raft_follower()
	r.leader_hint = m.from
	raft_reset_election_deadline(r, now_ms)
	# leader stickiness bookkeeping: this proves a live current-term
	# leader, so remember the contact and cancel any pending pre-vote
	# round (its replies must no longer count)
	r.last_leader_contact = now_ms
	r.has_leader_contact = 1
	r.prevotes_received = 0
	raft_clear_prevote_granters(r)
	int base = raft_snap_base(r)
	int prev_i = raft_u64_as_int(m.prev_log_index)
	if (prev_i < base):
		# stale append into our compacted prefix (§7): everything at or
		# below the base is committed and applied here by construction,
		# so answer success with match_index = our commit index — the
		# leader then walks next_index forward past the confusion. The
		# entries are not examined; nothing below the base can conflict.
		reply.success = 1
		u64_copy(reply.match_index, r.commit_index)
		out.push(reply)
		return
	int ok = 0
	if (prev_i == 0):
		ok = 1
	if (prev_i == base && base > 0):
		# the snapshot boundary: its term must match the snapshot's
		if (u64_eq(m.prev_log_term, r.snap_last_term)):
			ok = 1
	if (prev_i > base && prev_i <= base + r.log.length):
		raft_entry* prev_e = r.log[prev_i - base - 1]
		if (u64_eq(prev_e.term, m.prev_log_term)):
			ok = 1
	if (ok == 0):
		out.push(reply)
		return
	int k = 0
	while (k < m.entries.length):
		raft_entry* incoming = m.entries[k]
		int idx = prev_i + 1 + k
		if (idx <= base + r.log.length):
			raft_entry* mine = r.log[idx - base - 1]
			if (u64_eq(mine.term, incoming.term) == 0):
				# conflict: truncate from idx, then take the new entry.
				# §4.1 membership rollback: idx - 1 is the largest
				# conceptual index that survives — if our still-pending
				# config entry sits at or above idx, its effect never
				# happened as far as the surviving log is concerned
				# (raft_note_truncated_to, header).
				raft_note_truncated_to(r, idx - 1)
				while (base + r.log.length >= idx):
					raft_entry* removed = r.log.pop()
					raft_entry_free(removed)
				raft_entry* pushed = raft_entry_new_kind(incoming.term, incoming.command, incoming.command_len, incoming.kind)
				r.log.push(pushed)
				raft_note_entry_appended(r, raft_last_index(r), pushed)
		else:
			raft_entry* pushed = raft_entry_new_kind(incoming.term, incoming.command, incoming.command_len, incoming.kind)
			r.log.push(pushed)
			raft_note_entry_appended(r, raft_last_index(r), pushed)
		k = k + 1
	int match_i = prev_i + m.entries.length
	reply.success = 1
	u64_set_int(reply.match_index, match_i)
	u64* target = u64_clone(m.leader_commit)
	u64* match_u = u64_new_int(match_i)
	if (u64_cmp(target, match_u) > 0):
		u64_copy(target, match_u)
	if (u64_cmp(target, r.commit_index) > 0):
		u64_copy(r.commit_index, target)
		raft_note_commit_advanced(r)
	u64_free(target)
	u64_free(match_u)
	out.push(reply)


# AppendEntries reply (leader only, current term only). Success moves
# the peer's next/match indexes MONOTONICALLY forward (issue #320:
# replies can be reordered, and a delayed staler success — a smaller
# match_index — must not walk the peer's recorded progress backwards,
# so both updates clamp with max; Figure 2's "update nextIndex and
# matchIndex" means fresher acks only) and tries to advance the commit;
# failure backs next_index up by one (floor 1; the only legitimate
# next_index retreat) and immediately retries from there — as an
# InstallSnapshot when the backoff lands at or below the snapshot base
# (raft_make_peer_msg).
void raft_handle_append_reply(raft* r, raft_msg* m, int now_ms, list[raft_msg*] out):
	if (r.state != raft_leader()):
		return
	if (u64_eq(m.term, r.current_term) == 0):
		return
	if ((m.from in r.next_index) == 0):
		return
	if (m.success == 1):
		u64* mi = r.match_index[m.from]
		if (u64_cmp(m.match_index, mi) > 0):
			u64_copy(mi, m.match_index)
		u64* ni = r.next_index[m.from]
		u64* acked_next = u64_clone(m.match_index)
		u64_inc(acked_next)
		if (u64_cmp(acked_next, ni) > 0):
			u64_copy(ni, acked_next)
		u64_free(acked_next)
		raft_try_advance_commit(r)
		return
	u64* backed = r.next_index[m.from]
	int v = raft_u64_as_int(backed) - 1
	if (v < 1):
		v = 1
	u64_set_int(backed, v)
	out.push(raft_make_peer_msg(r, m.from))


# InstallSnapshot (§7). Term rules mirror AppendEntries exactly: a
# stale term is refused with our current term (a higher term already
# stepped us down before dispatch); a valid message proves the
# current-term leader — follow it, reset the election deadline and
# record the leader contact. Replies are append_reply messages, so
# the leader's existing reply path advances next/match.
#
# A snapshot whose last index is at or below our commit index is
# STALE: everything it covers is already committed here, so nothing
# changes and the success reply's match_index = our commit index lets
# the leader advance next_index past the confusion. Otherwise the
# snapshot installs: snap meta adopted (including the FULL config
# recorded at the snapshot, raft_adopt_snapshot_config — §4.1
# membership header — which supersedes any of our own uncommitted
# in-flight config change rather than rolling back to it), the ENTIRE
# log discarded (documented simplification, header), commit_index and
# last_applied jump to the snapshot index, and the blob is stored both
# as our own latest snapshot (snap_data) and in the pending slot for
# the state-machine owner (raft_take_pending_snapshot).
void raft_handle_install_snapshot(raft* r, raft_msg* m, int now_ms, list[raft_msg*] out):
	raft_msg* reply = raft_msg_new(raft_msg_append_reply(), r.self_id, m.from, r.current_term)
	reply.success = 0
	if (u64_cmp(m.term, r.current_term) < 0):
		out.push(reply)
		return
	r.state = raft_follower()
	r.leader_hint = m.from
	raft_reset_election_deadline(r, now_ms)
	r.last_leader_contact = now_ms
	r.has_leader_contact = 1
	r.prevotes_received = 0
	raft_clear_prevote_granters(r)
	if (u64_cmp(m.prev_log_index, r.commit_index) <= 0):
		reply.success = 1
		u64_copy(reply.match_index, r.commit_index)
		out.push(reply)
		return
	u64_copy(r.snap_last_index, m.prev_log_index)
	u64_copy(r.snap_last_term, m.prev_log_term)
	raft_adopt_snapshot_config(r, m.snap_config)
	int i = 0
	while (i < r.log.length):
		raft_entry_free(r.log[i])
		i = i + 1
	r.log.clear()
	u64_copy(r.commit_index, m.prev_log_index)
	u64_copy(r.last_applied, m.prev_log_index)
	if (r.snap_data != 0):
		free(r.snap_data)
	r.snap_data = raft_copy_blob(m.snap_data, m.snap_len)
	r.snap_len = m.snap_len
	if (r.pending_snap_data != 0):
		free(r.pending_snap_data)
	r.pending_snap_data = raft_copy_blob(m.snap_data, m.snap_len)
	r.pending_snap_len = m.snap_len
	u64_copy(r.pending_snap_index, m.prev_log_index)
	reply.success = 1
	u64_copy(reply.match_index, m.prev_log_index)
	out.push(reply)


# Dispatch one inbound message. Does NOT free m; the caller keeps
# ownership. Any message carrying a term above ours forces a step-down
# before type dispatch (Figure 2 "all servers" rule) — EXCEPT pre-vote
# traffic, whose prospective terms are polls, not term claims: it
# short-circuits before the step-down check (§9.6). A prevote flag on
# an append/append_reply is malformed and the message is dropped.
void raft_on_msg(raft* r, raft_msg* m, int now_ms, list[raft_msg*] out):
	if (m.prevote == 1):
		if (m.type == raft_msg_vote_req()):
			raft_handle_prevote_req(r, m, now_ms, out)
		if (m.type == raft_msg_vote_reply()):
			raft_handle_prevote_reply(r, m, now_ms, out)
		return
	if (u64_cmp(m.term, r.current_term) > 0):
		raft_step_down(r, m.term)
	if (m.type == raft_msg_vote_req()):
		raft_handle_vote_req(r, m, now_ms, out)
		return
	if (m.type == raft_msg_vote_reply()):
		raft_handle_vote_reply(r, m, now_ms, out)
		return
	if (m.type == raft_msg_append()):
		raft_handle_append(r, m, now_ms, out)
		return
	if (m.type == raft_msg_append_reply()):
		raft_handle_append_reply(r, m, now_ms, out)
		return
	if (m.type == raft_msg_install_snapshot()):
		raft_handle_install_snapshot(r, m, now_ms, out)
		return


# ---- client interface ---------------------------------------------------------

# Leader only: append (current_term, command, kind) to the local log,
# fan an AppendEntries out to every CURRENT peer (raft_note_entry_
# appended runs first, so a config entry's peer-set effect is already
# live and the fan-out reaches a just-added peer / skips a just-
# removed one — re-arming the heartbeat timer, since these double as
# heartbeats) and try to advance the commit — a single-node cluster
# commits right here. Returns 1 when accepted, 0 on a non-leader.
# command_len bytes are COPIED into the new log entry (raft_entry_new_
# kind); the caller keeps ownership of `command` and may free or reuse
# it as soon as this returns. command is opaque — embedded NUL and any
# other byte value are legal, and command_len (not strlen) is
# authoritative everywhere downstream. Shared by raft_propose (kind
# normal) and raft_propose_add_server/raft_propose_remove_server
# (kind config) below.
int raft_propose_internal(raft* r, char* command, int command_len, int kind, int now_ms, list[raft_msg*] out):
	if (r.state != raft_leader()):
		return 0
	raft_entry* e = raft_entry_new_kind(r.current_term, command, command_len, kind)
	r.log.push(e)
	raft_note_entry_appended(r, raft_last_index(r), e)
	int i = 0
	while (i < r.peers.length):
		out.push(raft_make_peer_msg(r, r.peers[i]))
		i = i + 1
	r.heartbeat_deadline = mono_deadline(now_ms, r.heartbeat_ms)
	raft_try_advance_commit(r)
	return 1


int raft_propose(raft* r, char* command, int command_len, int now_ms, list[raft_msg*] out):
	return raft_propose_internal(r, command, command_len, raft_entry_kind_normal(), now_ms, out)


# ---- cluster membership: propose API (§4.1; see the file header) ----------------

# Leader only: propose adding id as a new voting member. Rejected (0)
# when not leader, id is already the leader itself or an existing
# peer, or a previous config change is still uncommitted (thesis
# §4.1's single-in-flight safety rule — raft_config_pending). id takes
# effect for voting-set/majority purposes the MOMENT this entry is
# appended (raft_note_entry_appended), not when it commits. The new
# peer's next_index starts at 1 (an empty log is assumed): it catches
# up through ordinary replication, or through the existing §7
# InstallSnapshot path the instant next_index backs onto a compacted
# prefix (raft_make_peer_msg) — no bespoke bootstrap RPC (issue #319
# scope note: no learner/non-voting phase).
int raft_propose_add_server(raft* r, int id, int now_ms, list[raft_msg*] out):
	if (r.state != raft_leader()):
		return 0
	if (r.config_pending_index > 0):
		return 0
	if (id == r.self_id || raft_is_peer(r, id)):
		return 0
	char* cmd = raft_config_encode(raft_config_op_add(), id)
	int ok = raft_propose_internal(r, cmd, 5, raft_entry_kind_config(), now_ms, out)
	free(cmd)
	return ok


# Leader only: propose removing id, which MAY be the leader's own
# self_id (thesis §4.1 explicitly allows a leader to remove itself).
# Rejected (0) when not leader, id is neither a current peer nor self,
# or a previous config change is still uncommitted (same single-in-
# flight rule as add). Removing self does not touch r.peers (self is
# never a member of its own peers list); raft_note_commit_advanced
# steps a leader down to follower once the removal commits (§4.1).
# See the file header's REMOVAL DISRUPTION note for what governs a
# removed PEER's continued (non-)disruption of the cluster.
int raft_propose_remove_server(raft* r, int id, int now_ms, list[raft_msg*] out):
	if (r.state != raft_leader()):
		return 0
	if (r.config_pending_index > 0):
		return 0
	if (id != r.self_id && raft_is_peer(r, id) == 0):
		return 0
	char* cmd = raft_config_encode(raft_config_op_remove(), id)
	int ok = raft_propose_internal(r, cmd, 5, raft_entry_kind_config(), now_ms, out)
	free(cmd)
	return ok


# ---- cluster membership: queries -------------------------------------------------

# 1 iff a config change has been appended but not yet committed
# (thesis §4.1's single-in-flight rule — raft_propose_add_server/
# raft_propose_remove_server refuse a new proposal while this holds).
int raft_config_pending(raft* r):
	if (r.config_pending_index > 0):
		return 1
	return 0


# Current config size (peers only, self excluded — matching r.peers'
# own convention); see raft_peer_at for the ids themselves.
int raft_peer_count(raft* r):
	return r.peers.length


# The peer id at position i (0-based, insertion order); asserts i is
# in range.
int raft_peer_at(raft* r, int i):
	assert1(i >= 0 && i < r.peers.length)
	return r.peers[i]


# ---- log compaction (§7) --------------------------------------------------------

# The state-machine owner declares `data` (len bytes, copied) to be
# its state at exactly last_applied. Requires last_applied above the
# current snapshot base — returns 0 as a no-op otherwise. On success:
# the snapshot meta becomes (last_applied, term at last_applied, and
# the FULL config in effect at last_applied — raft_full_config_at_
# last_applied, §4.1 membership header), the blob copy replaces any
# previous one, every log entry at or below last_applied is freed
# (raft_entry_free: term, owned command copy and the struct) and 1 is
# returned. Peers whose next_index is at or below the new base are
# brought up by InstallSnapshot from the usual send paths.
int raft_take_snapshot(raft* r, char* data, int len):
	int base = raft_snap_base(r)
	int applied = raft_u64_as_int(r.last_applied)
	if (applied <= base):
		return 0
	raft_entry* boundary = r.log[applied - base - 1]
	u64_copy(r.snap_last_term, boundary.term)
	u64_copy(r.snap_last_index, r.last_applied)
	r.snap_config = raft_full_config_at_last_applied(r)
	if (r.snap_data != 0):
		free(r.snap_data)
	r.snap_data = raft_copy_blob(data, len)
	r.snap_len = len
	int drop = applied - base
	list[raft_entry*] kept = new list[raft_entry*]
	int i = 0
	while (i < r.log.length):
		if (i < drop):
			raft_entry_free(r.log[i])
		else:
			kept.push(r.log[i])
		i = i + 1
	r.log = kept
	return 1


# ---- pending inbound snapshot ------------------------------------------------------

# 1 while a received (or wal-recovered) snapshot awaits installation
# by the state-machine owner. The application's apply loop must check
# this FIRST each round: raft_pop_apply asserts no snapshot is
# pending, because entries after the snapshot index only make sense
# on top of the snapshot's state.
int raft_has_pending_snapshot(raft* r):
	if (r.pending_snap_data != 0):
		return 1
	return 0


# Hand the pending blob to the application: ownership of the returned
# buffer transfers to the caller (free it when done), len_out[0] gets
# its length and index_out the snapshot's last included index. The
# pending slot is cleared; the raft keeps its own snap_data copy for
# later InstallSnapshot sends. Asserts a snapshot is pending.
char* raft_take_pending_snapshot(raft* r, int* len_out, u64* index_out):
	assert1(r.pending_snap_data != 0)
	char* data = r.pending_snap_data
	len_out[0] = r.pending_snap_len
	u64_copy(index_out, r.pending_snap_index)
	r.pending_snap_data = 0
	r.pending_snap_len = 0
	u64_set_zero(r.pending_snap_index)
	return data


# ---- applying committed entries --------------------------------------------------

int raft_pending_apply(raft* r):
	if (u64_cmp(r.last_applied, r.commit_index) < 0):
		return 1
	return 0


# Advance last_applied by one and return the entry at that index. The
# pointer is borrowed — the log still owns the entry. Asserts something
# is pending — and that NO snapshot is pending: the application must
# install a pending snapshot (raft_take_pending_snapshot) before
# applying entries past it. Entries at or below the snapshot base are
# gone and can never be popped; last_applied never sits below the
# base, so the popped index is always in the retained suffix.
raft_entry* raft_pop_apply(raft* r):
	assert1(raft_has_pending_snapshot(r) == 0)
	assert1(raft_pending_apply(r))
	u64_inc(r.last_applied)
	int idx = raft_u64_as_int(r.last_applied)
	int base = raft_snap_base(r)
	assert1(idx > base && idx <= base + r.log.length)
	return r.log[idx - base - 1]


# ---- queries -----------------------------------------------------------------

int raft_state(raft* r):
	return r.state


void raft_term(raft* r, u64* out):
	u64_copy(out, r.current_term)


int raft_leader_hint(raft* r):
	return r.leader_hint


# Retained (post-snapshot-base) entry count, NOT the conceptual last
# index — see raft_last_index for that.
int raft_log_length(raft* r):
	return r.log.length


void raft_commit_index(raft* r, u64* out):
	u64_copy(out, r.commit_index)


# 1-based conceptual index; the returned pointer is borrowed. Asserts
# the index is above the snapshot base (compacted entries are gone)
# and at most the last index.
raft_entry* raft_log_at(raft* r, int i):
	int base = raft_snap_base(r)
	assert1(i > base && i <= base + r.log.length)
	return r.log[i - base - 1]


int raft_voted_for(raft* r):
	return r.voted_for


# The snapshot's last included index into out (zero = no snapshot).
void raft_snapshot_index(raft* r, u64* out):
	u64_copy(out, r.snap_last_index)


# The snapshot's last included term into out (zero = no snapshot).
void raft_snapshot_term(raft* r, u64* out):
	u64_copy(out, r.snap_last_term)
