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
(cloned term, shared command pointer); raft_msg_free frees them all.
Command pointers are caller-owned and must outlive the raft.

The log is stored in a 0-based list but is 1-indexed conceptually
(Figure 2 numbering): conceptual index i lives at log[i - 1], index 0
means "empty prefix" and never has an entry. raft_log_at takes the
1-based index.

v1 choices, documented here because they shape the tests:
  - votes_received counts granted current-term vote replies without
    deduplicating voters; the caller (test or simulation) must not
    deliver the same reply twice in one election.
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


# ---- log entries -------------------------------------------------------------

struct raft_entry:
	u64* term      # entry owns this
	char* command  # caller-owned; must outlive the raft


# Clones term; the command pointer is shared, not copied.
raft_entry* raft_entry_new(u64* term, char* command):
	raft_entry* e = new raft_entry()
	e.term = u64_clone(term)
	e.command = command
	return e


void raft_entry_free(raft_entry* e):
	u64_free(e.term)
	free(e)


# ---- messages ----------------------------------------------------------------

# One struct for all four message types, tagged by `type`. A message
# owns every u64 field and deep copies of its entries; raft_msg_free
# releases all of it. Fields not used by a type stay zero/empty.
struct raft_msg:
	int type              # raft_msg_vote_req/vote_reply/append/append_reply
	int from
	int to
	u64* term             # sender's term, always set
	u64* last_log_index   # vote_req
	u64* last_log_term    # vote_req
	int vote_granted      # vote_reply
	u64* prev_log_index   # append
	u64* prev_log_term    # append
	u64* leader_commit    # append
	list[raft_entry*] entries   # append; empty = heartbeat; deep copies
	int success           # append_reply
	u64* match_index      # append_reply
	int prevote           # vote_req/vote_reply: pre-vote round flag


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
	return m


# Deep free: all u64 fields plus every owned entry. The entries list
# storage itself is runtime-managed (matching swim_free in swim.w).
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
	# hardening (both opt-in; see header)
	int noop_on_win            # 1: append an empty no-op command on winning
	int prevote_enabled        # 1: poll a pre-vote round before real elections
	int prevotes_received      # granted pre-votes in the pending round (self counts)
	int last_leader_contact    # timestamp of the last valid current-term leader append
	int has_leader_contact     # 0 until the first such append ("never heard")


# ---- small helpers -------------------------------------------------------------

# The u64 as a host int; logs stay small enough that every index the
# protocol touches fits (asserted).
int raft_u64_as_int(u64* v):
	assert1(u64_fits_int(v))
	return u64_to_int(v)


# Last log index (1-based conceptual; 0 = empty log).
int raft_last_index(raft* r):
	return r.log.length


# Term of the last log entry into out; zero for an empty log.
void raft_last_term(raft* r, u64* out):
	if (r.log.length == 0):
		u64_set_zero(out)
		return
	raft_entry* last = r.log[r.log.length - 1]
	u64_copy(out, last.term)


# Smallest majority of the full cluster (peers plus self).
int raft_majority(raft* r):
	return (r.peers.length + 1) / 2 + 1


void raft_reset_election_deadline(raft* r, int now_ms):
	int timeout = prng_between(r.rng, r.election_timeout_min_ms, r.election_timeout_max_ms)
	r.election_deadline = mono_deadline(now_ms, timeout)


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
	r.noop_on_win = 0
	r.prevote_enabled = 0
	r.prevotes_received = 0
	r.last_leader_contact = 0
	r.has_leader_contact = 0
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


# ---- outbound message construction ----------------------------------------------

# AppendEntries to peer from its next_index: prev fields describe the
# entry just before next_index, entries carries deep copies of
# everything from next_index to the end of the log (empty = heartbeat).
raft_msg* raft_make_append(raft* r, int peer):
	raft_msg* m = raft_msg_new(raft_msg_append(), r.self_id, peer, r.current_term)
	int next_i = raft_u64_as_int(r.next_index[peer])
	assert1(next_i >= 1 && next_i <= r.log.length + 1)
	int prev_i = next_i - 1
	u64_set_int(m.prev_log_index, prev_i)
	if (prev_i > 0):
		raft_entry* prev_e = r.log[prev_i - 1]
		u64_copy(m.prev_log_term, prev_e.term)
	int k = next_i
	while (k <= r.log.length):
		raft_entry* e = r.log[k - 1]
		m.entries.push(raft_entry_new(e.term, e.command))
		k = k + 1
	u64_copy(m.leader_commit, r.commit_index)
	return m


# ---- commit rule (leader) --------------------------------------------------------

# Advance commit_index to the largest N in (commit_index, last log
# index] replicated on a majority (self counts) whose entry is from the
# current term (§5.4.2: never count replicas to commit an older-term
# entry directly).
void raft_try_advance_commit(raft* r):
	int best = 0
	u64* n_val = u64_new()
	int n = raft_u64_as_int(r.commit_index) + 1
	while (n <= r.log.length):
		u64_set_int(n_val, n)
		int count = 1
		int i = 0
		while (i < r.peers.length):
			if (u64_cmp(r.match_index[r.peers[i]], n_val) >= 0):
				count = count + 1
			i = i + 1
		if (count >= raft_majority(r)):
			raft_entry* e = r.log[n - 1]
			if (u64_eq(e.term, r.current_term)):
				best = n
		n = n + 1
	u64_free(n_val)
	if (best > 0):
		u64_set_int(r.commit_index, best)


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
		u64_set_int(r.next_index[p], r.log.length + 1)
		u64_set_int(r.match_index[p], 0)
		i = i + 1
	if (r.noop_on_win == 1):
		r.log.push(raft_entry_new(r.current_term, c""))
	i = 0
	while (i < r.peers.length):
		out.push(raft_make_append(r, r.peers[i]))
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
				out.push(raft_make_append(r, r.peers[i]))
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
# Like votes_received (header note), voters are not deduplicated.
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
	r.prevotes_received = r.prevotes_received + 1
	if (r.prevotes_received >= raft_majority(r)):
		raft_start_election(r, now_ms, out)


# RequestVote reply. Only a granted current-term reply while still a
# candidate counts; reaching a majority wins the election.
void raft_handle_vote_reply(raft* r, raft_msg* m, int now_ms, list[raft_msg*] out):
	if (r.state != raft_candidate()):
		return
	if (u64_eq(m.term, r.current_term) == 0):
		return
	if (m.vote_granted == 0):
		return
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
	int prev_i = raft_u64_as_int(m.prev_log_index)
	int ok = 0
	if (prev_i == 0):
		ok = 1
	if (prev_i >= 1 && prev_i <= r.log.length):
		raft_entry* prev_e = r.log[prev_i - 1]
		if (u64_eq(prev_e.term, m.prev_log_term)):
			ok = 1
	if (ok == 0):
		out.push(reply)
		return
	int k = 0
	while (k < m.entries.length):
		raft_entry* incoming = m.entries[k]
		int idx = prev_i + 1 + k
		if (idx <= r.log.length):
			raft_entry* mine = r.log[idx - 1]
			if (u64_eq(mine.term, incoming.term) == 0):
				# conflict: truncate from idx, then take the new entry
				while (r.log.length >= idx):
					raft_entry* removed = r.log.pop()
					raft_entry_free(removed)
				r.log.push(raft_entry_new(incoming.term, incoming.command))
		else:
			r.log.push(raft_entry_new(incoming.term, incoming.command))
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
	u64_free(target)
	u64_free(match_u)
	out.push(reply)


# AppendEntries reply (leader only, current term only). Success moves
# the peer's next/match indexes forward and tries to advance the
# commit; failure backs next_index up by one (floor 1) and immediately
# retries from there.
void raft_handle_append_reply(raft* r, raft_msg* m, int now_ms, list[raft_msg*] out):
	if (r.state != raft_leader()):
		return
	if (u64_eq(m.term, r.current_term) == 0):
		return
	if ((m.from in r.next_index) == 0):
		return
	if (m.success == 1):
		u64* ni = r.next_index[m.from]
		u64_copy(ni, m.match_index)
		u64_inc(ni)
		u64_copy(r.match_index[m.from], m.match_index)
		raft_try_advance_commit(r)
		return
	u64* backed = r.next_index[m.from]
	int v = raft_u64_as_int(backed) - 1
	if (v < 1):
		v = 1
	u64_set_int(backed, v)
	out.push(raft_make_append(r, m.from))


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


# ---- client interface ---------------------------------------------------------

# Leader only: append (current_term, command) to the local log, fan an
# AppendEntries out to every peer immediately (re-arming the heartbeat
# timer, since these double as heartbeats) and try to advance the
# commit — a single-node cluster commits right here. Returns 1 when
# accepted, 0 on a non-leader.
int raft_propose(raft* r, char* command, int now_ms, list[raft_msg*] out):
	if (r.state != raft_leader()):
		return 0
	r.log.push(raft_entry_new(r.current_term, command))
	int i = 0
	while (i < r.peers.length):
		out.push(raft_make_append(r, r.peers[i]))
		i = i + 1
	r.heartbeat_deadline = mono_deadline(now_ms, r.heartbeat_ms)
	raft_try_advance_commit(r)
	return 1


# ---- applying committed entries --------------------------------------------------

int raft_pending_apply(raft* r):
	if (u64_cmp(r.last_applied, r.commit_index) < 0):
		return 1
	return 0


# Advance last_applied by one and return the entry at that index. The
# pointer is borrowed — the log still owns the entry. Asserts something
# is pending.
raft_entry* raft_pop_apply(raft* r):
	assert1(raft_pending_apply(r))
	u64_inc(r.last_applied)
	int idx = raft_u64_as_int(r.last_applied)
	assert1(idx >= 1 && idx <= r.log.length)
	return r.log[idx - 1]


# ---- queries -----------------------------------------------------------------

int raft_state(raft* r):
	return r.state


void raft_term(raft* r, u64* out):
	u64_copy(out, r.current_term)


int raft_leader_hint(raft* r):
	return r.leader_hint


int raft_log_length(raft* r):
	return r.log.length


void raft_commit_index(raft* r, u64* out):
	u64_copy(out, r.commit_index)


# 1-based conceptual index; the returned pointer is borrowed.
raft_entry* raft_log_at(raft* r, int i):
	assert1(i >= 1 && i <= r.log.length)
	return r.log[i - 1]


int raft_voted_for(raft* r):
	return r.voted_for
