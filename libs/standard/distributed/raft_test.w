# wbuild: x64
import lib.testing
import libs.standard.distributed.raft


# ---- helpers ----------------------------------------------------------------

# Every test frees every outbound message through here, keeping the
# suite honest about raft_msg ownership.
void raft_test_free_msgs(list[raft_msg*] out):
	while (out.length > 0):
		raft_msg* m = out.pop()
		raft_msg_free(m)


int raft_test_term_int(raft* r):
	u64* t = u64_new()
	raft_term(r, t)
	int v = u64_to_int(t)
	u64_free(t)
	return v


int raft_test_commit_int(raft* r):
	u64* c = u64_new()
	raft_commit_index(r, c)
	int v = u64_to_int(c)
	u64_free(c)
	return v


raft_msg* raft_test_find_to(list[raft_msg*] out, int to):
	int i = 0
	while (i < out.length):
		raft_msg* m = out[i]
		if (m.to == to):
			return m
		i = i + 1
	assert1(0)
	return 0


raft_msg* raft_test_vote_req(int from, int to, int term, int last_index, int last_term):
	u64* t = u64_new_int(term)
	raft_msg* m = raft_msg_new(raft_msg_vote_req(), from, to, t)
	u64_free(t)
	u64_set_int(m.last_log_index, last_index)
	u64_set_int(m.last_log_term, last_term)
	return m


raft_msg* raft_test_vote_reply(int from, int to, int term, int granted):
	u64* t = u64_new_int(term)
	raft_msg* m = raft_msg_new(raft_msg_vote_reply(), from, to, t)
	u64_free(t)
	m.vote_granted = granted
	return m


raft_msg* raft_test_append(int from, int to, int term, int prev_index, int prev_term, int commit):
	u64* t = u64_new_int(term)
	raft_msg* m = raft_msg_new(raft_msg_append(), from, to, t)
	u64_free(t)
	u64_set_int(m.prev_log_index, prev_index)
	u64_set_int(m.prev_log_term, prev_term)
	u64_set_int(m.leader_commit, commit)
	return m


void raft_test_add_entry(raft_msg* m, int term, char* command):
	u64* t = u64_new_int(term)
	m.entries.push(raft_entry_new(t, command))
	u64_free(t)


raft_msg* raft_test_append_reply(int from, int to, int term, int success, int match):
	u64* t = u64_new_int(term)
	raft_msg* m = raft_msg_new(raft_msg_append_reply(), from, to, t)
	u64_free(t)
	m.success = success
	u64_set_int(m.match_index, match)
	return m


# Deterministic 3-node raft: election window collapsed to exactly
# 100 ms (min == max), heartbeat 30 ms, so every deadline is knowable.
raft* raft_test_node(int self_id, int a, int b, int seed):
	list[int] peers = list[int]{a, b}
	return raft_new(self_id, peers, 100, 100, 30, seed)


# Elect node 1 leader of {1, 2, 3} at t=100 (term 1): election fires at
# the deterministic 100 ms deadline, node 2 grants. Heartbeat deadline
# ends up at 130.
raft* raft_test_make_leader():
	raft* r = raft_test_node(1, 2, 3, 5)
	raft_start(r, 0)
	list[raft_msg*] out = new list[raft_msg*]
	raft_tick(r, 100, out)
	raft_test_free_msgs(out)
	raft_msg* reply = raft_test_vote_reply(2, 1, 1, 1)
	raft_on_msg(r, reply, 100, out)
	raft_msg_free(reply)
	raft_test_free_msgs(out)
	return r


# ---- single-node cluster ------------------------------------------------------

void test_single_node_becomes_leader():
	list[int] peers = new list[int]
	raft* r = raft_new(1, peers, 50, 100, 10, 42)
	assert_equal(raft_follower(), raft_state(r))
	assert_equal(0, raft_test_term_int(r))
	assert_equal(0 - 1, raft_leader_hint(r))
	assert_equal(0 - 1, raft_voted_for(r))
	raft_start(r, 0)
	list[raft_msg*] out = new list[raft_msg*]
	# before the randomized deadline (somewhere in [50, 100]) nothing fires
	raft_tick(r, 10, out)
	assert_equal(0, out.length)
	assert_equal(raft_follower(), raft_state(r))
	# at election_max the deadline has certainly passed; no peers, so the
	# election is won on the spot with no messages
	raft_tick(r, 100, out)
	assert_equal(0, out.length)
	assert_equal(raft_leader(), raft_state(r))
	assert_equal(1, raft_test_term_int(r))
	assert_equal(1, raft_leader_hint(r))
	assert_equal(1, raft_voted_for(r))
	raft_free(r)


void test_single_node_propose_commit_apply():
	list[int] peers = new list[int]
	raft* r = raft_new(1, peers, 50, 100, 10, 42)
	raft_start(r, 0)
	list[raft_msg*] out = new list[raft_msg*]
	raft_tick(r, 100, out)
	assert_equal(raft_leader(), raft_state(r))
	assert_equal(1, raft_propose(r, c"set x", 100, out))
	assert_equal(0, out.length)
	assert_equal(1, raft_test_commit_int(r))
	assert_equal(1, raft_propose(r, c"set y", 101, out))
	assert_equal(0, out.length)
	assert_equal(2, raft_test_commit_int(r))
	assert_equal(2, raft_log_length(r))
	# committed entries apply in order
	assert_equal(1, raft_pending_apply(r))
	raft_entry* first = raft_pop_apply(r)
	assert_strings_equal(c"set x", first.command)
	assert_equal(1, u64_to_int(first.term))
	assert_equal(1, raft_pending_apply(r))
	raft_entry* second = raft_pop_apply(r)
	assert_strings_equal(c"set y", second.command)
	assert_equal(0, raft_pending_apply(r))
	raft_free(r)


# ---- elections ----------------------------------------------------------------

void test_three_node_election_and_win():
	raft* r = raft_test_node(1, 2, 3, 7)
	raft_start(r, 0)
	list[raft_msg*] out = new list[raft_msg*]
	raft_tick(r, 99, out)
	assert_equal(0, out.length)
	raft_tick(r, 100, out)
	assert_equal(raft_candidate(), raft_state(r))
	assert_equal(1, raft_test_term_int(r))
	assert_equal(1, raft_voted_for(r))
	assert_equal(0 - 1, raft_leader_hint(r))
	assert_equal(2, out.length)
	raft_msg* v2 = raft_test_find_to(out, 2)
	assert_equal(raft_msg_vote_req(), v2.type)
	assert_equal(1, v2.from)
	assert_equal(1, u64_to_int(v2.term))
	assert_equal(0, u64_to_int(v2.last_log_index))
	assert_equal(0, u64_to_int(v2.last_log_term))
	raft_msg* v3 = raft_test_find_to(out, 3)
	assert_equal(raft_msg_vote_req(), v3.type)
	raft_test_free_msgs(out)
	# one granted vote plus self is a majority of 3: leader, and the
	# initial empty heartbeats go out in the same call
	raft_msg* reply = raft_test_vote_reply(2, 1, 1, 1)
	raft_on_msg(r, reply, 105, out)
	raft_msg_free(reply)
	assert_equal(raft_leader(), raft_state(r))
	assert_equal(1, raft_leader_hint(r))
	assert_equal(2, out.length)
	raft_msg* h2 = raft_test_find_to(out, 2)
	assert_equal(raft_msg_append(), h2.type)
	assert_equal(0, h2.entries.length)
	assert_equal(0, u64_to_int(h2.prev_log_index))
	raft_msg* h3 = raft_test_find_to(out, 3)
	assert_equal(raft_msg_append(), h3.type)
	raft_test_free_msgs(out)
	raft_free(r)


void test_vote_grant_and_deny_same_term():
	raft* r = raft_test_node(1, 2, 3, 3)
	raft_start(r, 0)
	list[raft_msg*] out = new list[raft_msg*]
	# fresh follower grants the first request it sees
	raft_msg* req = raft_test_vote_req(2, 1, 1, 0, 0)
	raft_on_msg(r, req, 10, out)
	raft_msg_free(req)
	assert_equal(1, out.length)
	raft_msg* reply = out[0]
	assert_equal(raft_msg_vote_reply(), reply.type)
	assert_equal(2, reply.to)
	assert_equal(1, reply.vote_granted)
	assert_equal(1, u64_to_int(reply.term))
	assert_equal(2, raft_voted_for(r))
	assert_equal(1, raft_test_term_int(r))
	raft_test_free_msgs(out)
	# a different candidate in the same term is denied
	raft_msg* rival = raft_test_vote_req(3, 1, 1, 0, 0)
	raft_on_msg(r, rival, 20, out)
	raft_msg_free(rival)
	assert_equal(1, out.length)
	reply = out[0]
	assert_equal(0, reply.vote_granted)
	assert_equal(2, raft_voted_for(r))
	raft_test_free_msgs(out)
	# the same candidate asking again is granted (idempotent)
	raft_msg* again = raft_test_vote_req(2, 1, 1, 0, 0)
	raft_on_msg(r, again, 30, out)
	raft_msg_free(again)
	reply = out[0]
	assert_equal(1, reply.vote_granted)
	assert_equal(2, raft_voted_for(r))
	raft_test_free_msgs(out)
	raft_free(r)


void test_vote_denied_stale_log_despite_higher_term():
	raft* r = raft_test_node(1, 2, 3, 3)
	raft_start(r, 0)
	list[raft_msg*] out = new list[raft_msg*]
	# give the follower one entry at term 2 via an append from leader 2
	raft_msg* seed_a = raft_test_append(2, 1, 2, 0, 0, 0)
	raft_test_add_entry(seed_a, 2, c"a")
	raft_on_msg(r, seed_a, 10, out)
	raft_msg_free(seed_a)
	raft_test_free_msgs(out)
	assert_equal(2, raft_test_term_int(r))
	assert_equal(1, raft_log_length(r))
	# candidate 3 brings a higher term but a staler log (last term 1)
	raft_msg* req = raft_test_vote_req(3, 1, 3, 5, 1)
	raft_on_msg(r, req, 20, out)
	raft_msg_free(req)
	# the higher term is adopted (step-down rule)...
	assert_equal(3, raft_test_term_int(r))
	assert_equal(raft_follower(), raft_state(r))
	# ...but the vote is still denied on log freshness, so voted_for
	# stays cleared from the step-down
	assert_equal(0 - 1, raft_voted_for(r))
	assert_equal(1, out.length)
	raft_msg* reply = out[0]
	assert_equal(0, reply.vote_granted)
	assert_equal(3, u64_to_int(reply.term))
	raft_test_free_msgs(out)
	raft_free(r)


void test_leader_steps_down_on_higher_term():
	raft* r = raft_test_make_leader()
	assert_equal(raft_leader(), raft_state(r))
	assert_equal(1, raft_test_term_int(r))
	list[raft_msg*] out = new list[raft_msg*]
	raft_msg* a = raft_test_append(2, 1, 2, 0, 0, 0)
	raft_on_msg(r, a, 150, out)
	raft_msg_free(a)
	assert_equal(raft_follower(), raft_state(r))
	assert_equal(2, raft_test_term_int(r))
	assert_equal(2, raft_leader_hint(r))
	assert_equal(1, out.length)
	raft_msg* reply = out[0]
	assert_equal(raft_msg_append_reply(), reply.type)
	assert_equal(1, reply.success)
	assert_equal(2, u64_to_int(reply.term))
	raft_test_free_msgs(out)
	raft_free(r)


# ---- log replication ------------------------------------------------------------

void test_append_walkback_converges():
	# n1 gets a 2-entry term-1 log as a follower, then wins term 2
	raft* n1 = raft_test_node(1, 2, 3, 5)
	raft_start(n1, 0)
	list[raft_msg*] out = new list[raft_msg*]
	raft_msg* seed_a = raft_test_append(3, 1, 1, 0, 0, 0)
	raft_test_add_entry(seed_a, 1, c"a")
	raft_test_add_entry(seed_a, 1, c"b")
	raft_on_msg(n1, seed_a, 10, out)
	raft_msg_free(seed_a)
	raft_test_free_msgs(out)
	assert_equal(2, raft_log_length(n1))
	# the valid append pushed the deadline to 110; election fires there
	raft_tick(n1, 110, out)
	assert_equal(raft_candidate(), raft_state(n1))
	assert_equal(2, raft_test_term_int(n1))
	raft_test_free_msgs(out)
	raft_msg* vote = raft_test_vote_reply(3, 1, 2, 1)
	raft_on_msg(n1, vote, 110, out)
	raft_msg_free(vote)
	assert_equal(raft_leader(), raft_state(n1))
	# the initial heartbeat to peer 2 assumes prev=2, which n2 lacks
	raft_msg* hb = raft_test_find_to(out, 2)
	assert_equal(2, u64_to_int(hb.prev_log_index))
	assert_equal(0, hb.entries.length)
	raft* n2 = raft_test_node(2, 1, 3, 6)
	raft_start(n2, 0)
	list[raft_msg*] n2_out = new list[raft_msg*]
	raft_on_msg(n2, hb, 10, n2_out)
	raft_test_free_msgs(out)
	assert_equal(1, n2_out.length)
	raft_msg* nack1 = n2_out[0]
	assert_equal(0, nack1.success)
	# the leader backs next_index up to 2 and immediately retries
	raft_on_msg(n1, nack1, 120, out)
	raft_test_free_msgs(n2_out)
	assert_equal(1, out.length)
	raft_msg* retry1 = out[0]
	assert_equal(1, u64_to_int(retry1.prev_log_index))
	assert_equal(1, retry1.entries.length)
	raft_on_msg(n2, retry1, 20, n2_out)
	raft_test_free_msgs(out)
	raft_msg* nack2 = n2_out[0]
	assert_equal(0, nack2.success)
	# next_index reaches 1: the full replay from index 1 succeeds
	raft_on_msg(n1, nack2, 130, out)
	raft_test_free_msgs(n2_out)
	raft_msg* retry2 = out[0]
	assert_equal(0, u64_to_int(retry2.prev_log_index))
	assert_equal(2, retry2.entries.length)
	raft_on_msg(n2, retry2, 30, n2_out)
	raft_test_free_msgs(out)
	raft_msg* ack = n2_out[0]
	assert_equal(1, ack.success)
	assert_equal(2, u64_to_int(ack.match_index))
	raft_on_msg(n1, ack, 140, out)
	raft_test_free_msgs(n2_out)
	assert_equal(0, out.length)
	# the logs converged entry by entry
	assert_equal(2, raft_log_length(n2))
	int i = 1
	while (i <= 2):
		raft_entry* mine = raft_log_at(n1, i)
		raft_entry* theirs = raft_log_at(n2, i)
		assert_equal(1, u64_eq(mine.term, theirs.term))
		assert_strings_equal(mine.command, theirs.command)
		i = i + 1
	# term-1 entries alone must not commit under the term-2 leader
	assert_equal(0, raft_test_commit_int(n1))
	raft_free(n1)
	raft_free(n2)


void test_conflict_truncation():
	raft* n2 = raft_test_node(2, 1, 3, 6)
	raft_start(n2, 0)
	list[raft_msg*] out = new list[raft_msg*]
	# an old leader (term 1) replicated [t1 "x", t1 "y"]
	raft_msg* old = raft_test_append(3, 2, 1, 0, 0, 0)
	raft_test_add_entry(old, 1, c"x")
	raft_test_add_entry(old, 1, c"y")
	raft_on_msg(n2, old, 10, out)
	raft_msg_free(old)
	raft_test_free_msgs(out)
	assert_equal(2, raft_log_length(n2))
	# the new leader (term 2) sends [t1 "x", t2 "z"] from the empty prefix
	raft_msg* fresh = raft_test_append(1, 2, 2, 0, 0, 0)
	raft_test_add_entry(fresh, 1, c"x")
	raft_test_add_entry(fresh, 2, c"z")
	raft_on_msg(n2, fresh, 20, out)
	raft_msg_free(fresh)
	assert_equal(1, out.length)
	raft_msg* reply = out[0]
	assert_equal(1, reply.success)
	assert_equal(2, u64_to_int(reply.match_index))
	raft_test_free_msgs(out)
	# index 1 matched and was kept; index 2 conflicted, was truncated
	# and replaced
	assert_equal(2, raft_log_length(n2))
	raft_entry* first = raft_log_at(n2, 1)
	assert_equal(1, u64_to_int(first.term))
	assert_strings_equal(c"x", first.command)
	raft_entry* second = raft_log_at(n2, 2)
	assert_equal(2, u64_to_int(second.term))
	assert_strings_equal(c"z", second.command)
	raft_free(n2)


# ---- commit rules ----------------------------------------------------------------

void test_commit_rule_old_term_entries():
	# §5.4.2: a leader never commits an older-term entry by counting
	# replicas; it commits only once a current-term entry is replicated
	# on a majority, which commits everything before it too.
	raft* n1 = raft_test_node(1, 2, 3, 5)
	raft_start(n1, 0)
	list[raft_msg*] out = new list[raft_msg*]
	raft_msg* seed_a = raft_test_append(2, 1, 1, 0, 0, 0)
	raft_test_add_entry(seed_a, 1, c"old")
	raft_on_msg(n1, seed_a, 10, out)
	raft_msg_free(seed_a)
	raft_test_free_msgs(out)
	raft_tick(n1, 110, out)
	raft_test_free_msgs(out)
	raft_msg* vote = raft_test_vote_reply(2, 1, 2, 1)
	raft_on_msg(n1, vote, 110, out)
	raft_msg_free(vote)
	raft_test_free_msgs(out)
	assert_equal(raft_leader(), raft_state(n1))
	assert_equal(2, raft_test_term_int(n1))
	# the term-1 entry now sits on a majority (self + node 2): no commit
	raft_msg* ack1 = raft_test_append_reply(2, 1, 2, 1, 1)
	raft_on_msg(n1, ack1, 120, out)
	raft_msg_free(ack1)
	raft_test_free_msgs(out)
	assert_equal(0, raft_test_commit_int(n1))
	# a term-2 entry reaching the same majority commits both
	assert_equal(1, raft_propose(n1, c"new", 130, out))
	raft_test_free_msgs(out)
	raft_msg* ack2 = raft_test_append_reply(2, 1, 2, 1, 2)
	raft_on_msg(n1, ack2, 140, out)
	raft_msg_free(ack2)
	raft_test_free_msgs(out)
	assert_equal(2, raft_test_commit_int(n1))
	raft_free(n1)


void test_commit_propagation_via_heartbeat():
	raft* n1 = raft_test_make_leader()
	raft* n2 = raft_test_node(2, 1, 3, 8)
	raft_start(n2, 0)
	list[raft_msg*] out = new list[raft_msg*]
	list[raft_msg*] n2_out = new list[raft_msg*]
	assert_equal(1, raft_propose(n1, c"a", 110, out))
	raft_msg* ap = raft_test_find_to(out, 2)
	assert_equal(1, ap.entries.length)
	assert_equal(0, u64_to_int(ap.leader_commit))
	raft_on_msg(n2, ap, 115, n2_out)
	raft_test_free_msgs(out)
	raft_msg* ack = n2_out[0]
	assert_equal(1, ack.success)
	# the follower stored the entry but has not learned the commit
	assert_equal(1, raft_log_length(n2))
	assert_equal(0, raft_pending_apply(n2))
	raft_on_msg(n1, ack, 120, out)
	raft_test_free_msgs(n2_out)
	assert_equal(0, out.length)
	assert_equal(1, raft_test_commit_int(n1))
	# the next heartbeat carries leader_commit = 1
	raft_tick(n1, 140, out)
	assert_equal(2, out.length)
	raft_msg* hb = raft_test_find_to(out, 2)
	assert_equal(0, hb.entries.length)
	assert_equal(1, u64_to_int(hb.prev_log_index))
	assert_equal(1, u64_to_int(hb.leader_commit))
	raft_on_msg(n2, hb, 145, n2_out)
	raft_test_free_msgs(out)
	raft_test_free_msgs(n2_out)
	assert_equal(1, raft_pending_apply(n2))
	raft_entry* applied = raft_pop_apply(n2)
	assert_strings_equal(c"a", applied.command)
	assert_equal(0, raft_pending_apply(n2))
	raft_free(n1)
	raft_free(n2)


# ---- timers ------------------------------------------------------------------

void test_leader_heartbeat_interval():
	# elected at t=100; the heartbeat deadline is 130
	raft* r = raft_test_make_leader()
	list[raft_msg*] out = new list[raft_msg*]
	raft_tick(r, 115, out)
	assert_equal(0, out.length)
	raft_tick(r, 130, out)
	assert_equal(2, out.length)
	raft_msg* h2 = raft_test_find_to(out, 2)
	assert_equal(raft_msg_append(), h2.type)
	assert_equal(0, h2.entries.length)
	raft_msg* h3 = raft_test_find_to(out, 3)
	assert_equal(raft_msg_append(), h3.type)
	raft_test_free_msgs(out)
	# and again one interval later
	raft_tick(r, 145, out)
	assert_equal(0, out.length)
	raft_tick(r, 160, out)
	assert_equal(2, out.length)
	raft_test_free_msgs(out)
	raft_free(r)


void test_follower_deadline_reset_on_append():
	raft* n2 = raft_test_node(2, 1, 3, 9)
	raft_start(n2, 0)
	# the collapsed window makes the first deadline exactly 100
	list[raft_msg*] out = new list[raft_msg*]
	raft_msg* hb = raft_test_append(1, 2, 1, 0, 0, 0)
	raft_on_msg(n2, hb, 90, out)
	raft_msg_free(hb)
	raft_test_free_msgs(out)
	assert_equal(1, raft_leader_hint(n2))
	# past the original deadline: the valid append pushed it to 190
	raft_tick(n2, 150, out)
	assert_equal(0, out.length)
	assert_equal(raft_follower(), raft_state(n2))
	assert_equal(1, raft_test_term_int(n2))
	# at the pushed-back deadline the election fires
	raft_tick(n2, 190, out)
	assert_equal(raft_candidate(), raft_state(n2))
	assert_equal(2, raft_test_term_int(n2))
	raft_test_free_msgs(out)
	raft_free(n2)


void test_vote_grant_resets_deadline():
	raft* n1 = raft_test_node(1, 2, 3, 4)
	raft_start(n1, 0)
	list[raft_msg*] out = new list[raft_msg*]
	raft_msg* req = raft_test_vote_req(2, 1, 1, 0, 0)
	raft_on_msg(n1, req, 90, out)
	raft_msg_free(req)
	raft_msg* reply = out[0]
	assert_equal(1, reply.vote_granted)
	raft_test_free_msgs(out)
	# granting at t=90 pushed the deadline from 100 to 190
	raft_tick(n1, 150, out)
	assert_equal(0, out.length)
	assert_equal(raft_follower(), raft_state(n1))
	raft_tick(n1, 190, out)
	assert_equal(raft_candidate(), raft_state(n1))
	# adopted term 1 with the vote, then bumped to 2 for the election
	assert_equal(2, raft_test_term_int(n1))
	raft_test_free_msgs(out)
	raft_free(n1)


# ---- stale messages -------------------------------------------------------------

void test_stale_append_rejected_no_reset():
	raft* n2 = raft_test_node(2, 1, 3, 9)
	raft_start(n2, 0)
	list[raft_msg*] out = new list[raft_msg*]
	# a valid append from leader 3 at term 2 (t=10 → deadline 110)
	raft_msg* good = raft_test_append(3, 2, 2, 0, 0, 0)
	raft_on_msg(n2, good, 10, out)
	raft_msg_free(good)
	raft_test_free_msgs(out)
	assert_equal(2, raft_test_term_int(n2))
	assert_equal(3, raft_leader_hint(n2))
	# a stale term-1 append: rejected with our term, nothing changes
	raft_msg* stale = raft_test_append(1, 2, 1, 0, 0, 0)
	raft_on_msg(n2, stale, 50, out)
	raft_msg_free(stale)
	assert_equal(1, out.length)
	raft_msg* reply = out[0]
	assert_equal(0, reply.success)
	assert_equal(2, u64_to_int(reply.term))
	assert_equal(3, raft_leader_hint(n2))
	assert_equal(2, raft_test_term_int(n2))
	raft_test_free_msgs(out)
	# the stale append did not reset the deadline: election still at 110
	raft_tick(n2, 110, out)
	assert_equal(raft_candidate(), raft_state(n2))
	raft_test_free_msgs(out)
	raft_free(n2)


void test_stale_vote_reply_ignored():
	raft* n1 = raft_test_node(1, 2, 3, 7)
	raft_start(n1, 0)
	list[raft_msg*] out = new list[raft_msg*]
	raft_tick(n1, 100, out)
	raft_test_free_msgs(out)
	assert_equal(raft_candidate(), raft_state(n1))
	# a granted reply from an older term changes nothing
	raft_msg* stale = raft_test_vote_reply(2, 1, 0, 1)
	raft_on_msg(n1, stale, 105, out)
	raft_msg_free(stale)
	assert_equal(0, out.length)
	assert_equal(raft_candidate(), raft_state(n1))
	assert_equal(1, raft_test_term_int(n1))
	# the current-term reply still wins the election
	raft_msg* good = raft_test_vote_reply(3, 1, 1, 1)
	raft_on_msg(n1, good, 106, out)
	raft_msg_free(good)
	assert_equal(raft_leader(), raft_state(n1))
	raft_test_free_msgs(out)
	raft_free(n1)


void test_stale_vote_req_denied():
	raft* n1 = raft_test_node(1, 2, 3, 4)
	raft_start(n1, 0)
	list[raft_msg*] out = new list[raft_msg*]
	raft_msg* first = raft_test_vote_req(2, 1, 2, 0, 0)
	raft_on_msg(n1, first, 10, out)
	raft_msg_free(first)
	raft_test_free_msgs(out)
	assert_equal(2, raft_test_term_int(n1))
	assert_equal(2, raft_voted_for(n1))
	# an older-term request is denied and answered with our term
	raft_msg* old = raft_test_vote_req(3, 1, 1, 0, 0)
	raft_on_msg(n1, old, 20, out)
	raft_msg_free(old)
	assert_equal(1, out.length)
	raft_msg* reply = out[0]
	assert_equal(0, reply.vote_granted)
	assert_equal(2, u64_to_int(reply.term))
	assert_equal(2, raft_voted_for(n1))
	raft_test_free_msgs(out)
	raft_free(n1)


void test_append_reply_ignored_when_not_leader():
	raft* r = raft_test_node(1, 2, 3, 3)
	raft_start(r, 0)
	list[raft_msg*] out = new list[raft_msg*]
	raft_msg* stray = raft_test_append_reply(2, 1, 0, 1, 5)
	raft_on_msg(r, stray, 10, out)
	raft_msg_free(stray)
	assert_equal(0, out.length)
	assert_equal(raft_follower(), raft_state(r))
	assert_equal(0, raft_test_term_int(r))
	assert_equal(0, raft_test_commit_int(r))
	raft_free(r)


# ---- client interface -------------------------------------------------------------

void test_propose_non_leader_rejected():
	raft* r = raft_test_node(1, 2, 3, 3)
	raft_start(r, 0)
	list[raft_msg*] out = new list[raft_msg*]
	assert_equal(0, raft_propose(r, c"nope", 10, out))
	assert_equal(0, out.length)
	assert_equal(0, raft_log_length(r))
	raft_free(r)


# ---- randomized timeouts ------------------------------------------------------------

void test_randomized_timeouts_differ():
	# same window, different seeds: driven over a 1 ms tick grid the two
	# nodes reach candidate at different times
	list[int] peers_a = list[int]{2, 3}
	raft* a = raft_new(1, peers_a, 100, 200, 30, 1)
	list[int] peers_b = list[int]{1, 3}
	raft* b = raft_new(2, peers_b, 100, 200, 30, 2)
	raft_start(a, 0)
	raft_start(b, 0)
	list[raft_msg*] out = new list[raft_msg*]
	int fire_a = 0 - 1
	int fire_b = 0 - 1
	int t = 0
	while (t <= 250):
		raft_tick(a, t, out)
		raft_test_free_msgs(out)
		if (fire_a < 0 && raft_state(a) == raft_candidate()):
			fire_a = t
		raft_tick(b, t, out)
		raft_test_free_msgs(out)
		if (fire_b < 0 && raft_state(b) == raft_candidate()):
			fire_b = t
		t = t + 1
	assert1(fire_a >= 100 && fire_a <= 200)
	assert1(fire_b >= 100 && fire_b <= 200)
	assert1(fire_a != fire_b)
	raft_free(a)
	raft_free(b)


# ---- ownership ---------------------------------------------------------------

void test_message_deep_copy_ownership():
	raft* n1 = raft_test_make_leader()
	list[raft_msg*] out = new list[raft_msg*]
	assert_equal(1, raft_propose(n1, c"payload", 110, out))
	assert_equal(2, out.length)
	raft_msg* ap = raft_test_find_to(out, 2)
	assert_equal(1, ap.entries.length)
	raft_entry* copy = ap.entries[0]
	assert_strings_equal(c"payload", copy.command)
	raft_entry* original = raft_log_at(n1, 1)
	# the message owns a distinct entry with its own term u64; only the
	# command pointer is shared
	assert1(cast(int, original) != cast(int, copy))
	assert1(cast(int, original.term) != cast(int, copy.term))
	assert1(cast(int, original.command) == cast(int, copy.command))
	# freeing every message leaves the leader's log intact
	raft_test_free_msgs(out)
	raft_entry* still = raft_log_at(n1, 1)
	assert_strings_equal(c"payload", still.command)
	assert_equal(1, u64_to_int(still.term))
	raft_free(n1)
