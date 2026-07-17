/*
SWIM membership (Das/Gupta/Motivala 2002) as a pure state machine
(companion to monotime.w; docs/projects/distributed.md).

No sockets and no real clock live here: the caller owns all I/O and
time. It feeds handler functions explicit now_ms timestamps and message
fields, reads the immediate decision from return values, and pulls
dissemination work from an explicit piggyback queue
(swim_next_piggyback). Every timing decision routes through the
wrap-safe monotime helpers; raw timestamps are never compared.

Refutation ordering, for a member with current (state, inc):
  alive(inc2)   overrides alive(inc1)/suspect(inc1)  iff inc2 >  inc1
  suspect(inc2) overrides alive(inc1)                iff inc2 >= inc1
  suspect(inc2) overrides suspect(inc1)              iff inc2 >  inc1
  dead(any inc) overrides everything except an existing dead
Any applied override marks the member pending with a fresh
transmits_left budget, and a suspect override arms
suspect_deadline = mono_deadline(now, suspect_timeout_ms).

v1 choices, documented here because they shape the tests:
  - dead is terminal: later alive/suspect gossip does not resurrect a
    dead member, no matter how high its incarnation. Rejoin-with-new-id
    (or a generation number) is future work.
  - suspect/dead gossip about an unknown id creates the member entry
    (suspect with a fresh deadline, dead as a tombstone) so gossip
    reorderings cannot lose a death.
  - swim_on_ack applies alive(from, current inc), which by the rules
    above never overrides anything: an ack from a suspect does NOT
    clear the suspicion. A real refutation needs the suspect itself to
    bump its incarnation, arriving here as swim_on_alive_msg with a
    higher inc (the swim_on_suspect_msg self-refutation path on the
    suspected node produces exactly that).
  - gossip about self is never applied to the table: alive/dead
    messages naming self_id are ignored; a suspect message naming
    self_id triggers self-refutation instead (incarnation bump).
  - swim_join and unknown-member gossip mark the new entry pending, so
    newly learned members are themselves disseminated.
*/
import lib.lib
import lib.memory
import lib.assert
import libs.standard.distributed.monotime


# ---- member states ----------------------------------------------------------

int swim_alive():
	return 0


int swim_suspect():
	return 1


int swim_dead():
	return 2


# ---- state ------------------------------------------------------------------

struct swim_member:
	int id
	int state              # swim_alive/swim_suspect/swim_dead
	int incarnation
	int suspect_deadline   # monotime deadline; meaningful only while suspect
	int pending            # 1 while an update about this member needs gossiping
	int transmits_left     # piggyback retransmit budget for the current update


struct swim:
	int self_id
	int self_incarnation
	map[int, swim_member*] members
	list[int] member_ids       # insertion order; stable round-robin order
	int probe_cursor           # round-robin index into member_ids
	int suspect_timeout_ms
	int piggyback_transmits    # transmit budget granted per new update


# ---- internal helpers -------------------------------------------------------

swim_member* swim_lookup(swim* s, int id):
	if ((id in s.members) == 0):
		return 0
	return s.members[id]


# A fresh update about m exists: gossip it with a full transmit budget.
void swim_mark_pending(swim* s, swim_member* m):
	m.pending = 1
	m.transmits_left = s.piggyback_transmits


swim_member* swim_add_member(swim* s, int id, int state, int incarnation):
	swim_member* m = new swim_member()
	m.id = id
	m.state = state
	m.incarnation = incarnation
	m.suspect_deadline = 0
	m.pending = 0
	m.transmits_left = 0
	s.members[id] = m
	s.member_ids.push(id)
	return m


# alive(id, incarnation) per the refutation rules. An unknown id joins
# the table as alive(incarnation), pending.
void swim_apply_alive(swim* s, int id, int incarnation, int now_ms):
	swim_member* m = swim_lookup(s, id)
	if (m == 0):
		m = swim_add_member(s, id, swim_alive(), incarnation)
		swim_mark_pending(s, m)
		return
	if (m.state == swim_dead()):
		return
	if (incarnation > m.incarnation):
		m.state = swim_alive()
		m.incarnation = incarnation
		swim_mark_pending(s, m)


# suspect(id, incarnation) per the refutation rules. An unknown id
# joins the table as suspect(incarnation) with a fresh deadline.
void swim_apply_suspect(swim* s, int id, int incarnation, int now_ms):
	swim_member* m = swim_lookup(s, id)
	if (m == 0):
		m = swim_add_member(s, id, swim_suspect(), incarnation)
		m.suspect_deadline = mono_deadline(now_ms, s.suspect_timeout_ms)
		swim_mark_pending(s, m)
		return
	if (m.state == swim_dead()):
		return
	int overrides = 0
	if (m.state == swim_alive() && incarnation >= m.incarnation):
		overrides = 1
	if (m.state == swim_suspect() && incarnation > m.incarnation):
		overrides = 1
	if (overrides == 1):
		m.state = swim_suspect()
		m.incarnation = incarnation
		m.suspect_deadline = mono_deadline(now_ms, s.suspect_timeout_ms)
		swim_mark_pending(s, m)


# dead(id): overrides everything except an existing dead. An unknown id
# is recorded as a tombstone so reordered gossip cannot lose the death.
void swim_apply_dead(swim* s, int id, int now_ms):
	swim_member* m = swim_lookup(s, id)
	if (m == 0):
		m = swim_add_member(s, id, swim_dead(), 0)
		swim_mark_pending(s, m)
		return
	if (m.state == swim_dead()):
		return
	m.state = swim_dead()
	swim_mark_pending(s, m)


# ---- lifecycle --------------------------------------------------------------

swim* swim_new(int self_id, int suspect_timeout_ms, int piggyback_transmits):
	assert1(suspect_timeout_ms >= 1)
	assert1(piggyback_transmits >= 1)
	swim* s = new swim()
	s.self_id = self_id
	s.self_incarnation = 0
	s.members = new map[int, swim_member*]
	s.member_ids = new list[int]
	s.probe_cursor = 0
	s.suspect_timeout_ms = suspect_timeout_ms
	s.piggyback_transmits = piggyback_transmits
	swim_add_member(s, self_id, swim_alive(), 0)
	return s


# Frees the member records and the swim struct itself; the map/list
# storage is runtime-managed (matching vclock_free in clock.w).
void swim_free(swim* s):
	int i = 0
	while (i < s.member_ids.length):
		int id = s.member_ids[i]
		free(s.members[id])
		i = i + 1
	free(s)


# Locally learn about a peer (bootstrap/join): added as alive inc 0 and
# pending. Returns 1 when added, 0 when the id was already known.
int swim_join(swim* s, int id, int now_ms):
	if (id in s.members):
		return 0
	swim_member* m = swim_add_member(s, id, swim_alive(), 0)
	swim_mark_pending(s, m)
	return 1


# ---- probing ----------------------------------------------------------------

# Next round-robin probe target: skips self and dead members, advances
# the cursor. 0 - 1 when no live or suspect peer exists.
int swim_probe_target(swim* s):
	int n = s.member_ids.length
	int scanned = 0
	while (scanned < n):
		if (s.probe_cursor >= n):
			s.probe_cursor = 0
		int id = s.member_ids[s.probe_cursor]
		s.probe_cursor = s.probe_cursor + 1
		scanned = scanned + 1
		if (id != s.self_id):
			swim_member* m = s.members[id]
			if (m.state != swim_dead()):
				return id
	return 0 - 1


# The direct probe of target got no ack in time: suspect it at its
# current incarnation (a no-op when it is already suspect or dead).
void swim_on_probe_timeout(swim* s, int target, int now_ms):
	if (target == s.self_id):
		return
	swim_member* m = swim_lookup(s, target)
	if (m == 0):
		return
	swim_apply_suspect(s, target, m.incarnation, now_ms)


# Up to k distinct helper ids for an indirect probe of target — never
# self, target, or a dead member — taken in round-robin order starting
# at the probe cursor (which is not advanced). Writes ids to out,
# returns the count.
int swim_indirect_candidates(swim* s, int target, int k, int* out):
	int n = s.member_ids.length
	int count = 0
	int scanned = 0
	int pos = s.probe_cursor
	while (scanned < n && count < k):
		if (pos >= n):
			pos = 0
		int id = s.member_ids[pos]
		pos = pos + 1
		scanned = scanned + 1
		if (id != s.self_id && id != target):
			swim_member* m = s.members[id]
			if (m.state != swim_dead()):
				out[count] = id
				count = count + 1
	return count


# ---- message handlers -------------------------------------------------------

# An ack (direct or via a helper) from `from`: apply alive at its
# current incarnation. By the refutation rules this never overrides, so
# an ack alone does not clear suspicion — see the v1 notes up top.
void swim_on_ack(swim* s, int from, int now_ms):
	swim_member* m = swim_lookup(s, from)
	if (m == 0):
		return
	swim_apply_alive(s, from, m.incarnation, now_ms)


# Suspect gossip. Naming self triggers self-refutation: bump
# self_incarnation above the gossiped incarnation, mark self pending
# (an alive update at the new incarnation), and return the new
# incarnation; a stale suspicion (below the current incarnation) is
# already refuted and bumps nothing. For any other id the refutation
# rules apply; returns that member's current incarnation.
int swim_on_suspect_msg(swim* s, int id, int incarnation, int now_ms):
	if (id == s.self_id):
		if (incarnation >= s.self_incarnation):
			s.self_incarnation = incarnation + 1
			swim_member* self_m = s.members[s.self_id]
			self_m.state = swim_alive()
			self_m.incarnation = s.self_incarnation
			swim_mark_pending(s, self_m)
		return s.self_incarnation
	swim_apply_suspect(s, id, incarnation, now_ms)
	swim_member* m = s.members[id]
	return m.incarnation


# Alive gossip. Self is authoritative for its own state, so gossip
# naming self is ignored; unknown ids join the table (see apply_alive).
void swim_on_alive_msg(swim* s, int id, int incarnation, int now_ms):
	if (id == s.self_id):
		return
	swim_apply_alive(s, id, incarnation, now_ms)


# Dead gossip. A node never marks itself dead in v1.
void swim_on_dead_msg(swim* s, int id, int now_ms):
	if (id == s.self_id):
		return
	swim_apply_dead(s, id, now_ms)


# ---- timers -----------------------------------------------------------------

# Expire suspicions: every suspect whose deadline has passed becomes
# dead, pending. Call with the current time whenever the caller's timer
# fires.
void swim_tick(swim* s, int now_ms):
	int i = 0
	while (i < s.member_ids.length):
		int id = s.member_ids[i]
		swim_member* m = s.members[id]
		if (m.state == swim_suspect() && mono_expired(now_ms, m.suspect_deadline)):
			m.state = swim_dead()
			swim_mark_pending(s, m)
		i = i + 1


# ---- piggyback dissemination ------------------------------------------------

# Pull up to max member ids with pending updates for gossiping on the
# next outgoing message, freshest first (most transmits_left; ties go
# to table order). Each returned id's budget is decremented; at 0 the
# member stops pending. Each id appears at most once per call. The
# caller reads state/incarnation via the queries to build its payload.
int swim_next_piggyback(swim* s, int max, int* out_ids):
	int count = 0
	while (count < max):
		int best_id = 0
		int best_left = 0
		int found = 0
		int i = 0
		while (i < s.member_ids.length):
			int id = s.member_ids[i]
			swim_member* m = s.members[id]
			if (m.pending == 1 && m.transmits_left > best_left):
				int emitted = 0
				int j = 0
				while (j < count):
					if (out_ids[j] == id):
						emitted = 1
					j = j + 1
				if (emitted == 0):
					best_id = id
					best_left = m.transmits_left
					found = 1
			i = i + 1
		if (found == 0):
			return count
		swim_member* chosen = s.members[best_id]
		chosen.transmits_left = chosen.transmits_left - 1
		if (chosen.transmits_left <= 0):
			chosen.pending = 0
		out_ids[count] = best_id
		count = count + 1
	return count


# ---- queries ----------------------------------------------------------------

# Member state, or 0 - 1 for an unknown id.
int swim_state(swim* s, int id):
	swim_member* m = swim_lookup(s, id)
	if (m == 0):
		return 0 - 1
	return m.state


# Member incarnation, or 0 - 1 for an unknown id.
int swim_incarnation(swim* s, int id):
	swim_member* m = swim_lookup(s, id)
	if (m == 0):
		return 0 - 1
	return m.incarnation


# Every member ever seen, including self and the dead.
int swim_member_count(swim* s):
	return s.member_ids.length


int swim_alive_count(swim* s):
	int count = 0
	int i = 0
	while (i < s.member_ids.length):
		int id = s.member_ids[i]
		swim_member* m = s.members[id]
		if (m.state == swim_alive()):
			count = count + 1
		i = i + 1
	return count


int swim_self_incarnation(swim* s):
	return s.self_incarnation
