/*
Durable completion gate: protocol messages that acknowledge persisted
state are held until the write they depend on is durable
(docs/projects/reliable_services.md, stage W1a).

An asynchronous persistence adapter (group commit, a background fsync,
a raft_wal sync that may fail) must never let a reply escape before
the state it acknowledges is on stable storage, and a FAILED sync must
never release the replies buffered behind it. This gate is that rule
and nothing else -- independent of Raft or any replication policy:

  durable_gate_hold(g, msg, seq)        msg needs every write up to and
                                        including sequence seq durable
  durable_gate_complete(g, seq, out)    writes up to seq are durable:
                                        held messages with sequence
                                        <= seq move to out, in hold order
  durable_gate_fail(g, out)             a sync failed: EVERY held
                                        message moves to out for the
                                        caller to discard (or turn into
                                        error replies), and the gate is
                                        failed for good

After a failure the gate is sticky: durable_gate_hold refuses (returns
0, the caller keeps the message) and durable_gate_complete releases
nothing. A sync that failed may have lost data the kernel already
dropped, so no later success can vouch for earlier writes; the owner
must recover from its log and build a new gate.

Sequence numbers are the caller's (monotonic write ids, log offsets,
...). Messages are opaque char* the gate never inspects or frees.
*/
import lib.lib
import lib.assert


struct durable_gate:
	list[char*] held       # in hold order
	list[int] held_seq     # parallel to held
	int durable_seq        # highest sequence reported durable
	int failed             # sticky after durable_gate_fail
	int released           # lifetime count of released messages
	int dropped            # lifetime count of messages handed back by a failure


durable_gate* durable_gate_new():
	durable_gate* g = new durable_gate()
	g.held = new list[char*]
	g.held_seq = new list[int]
	g.durable_seq = 0
	g.failed = 0
	g.released = 0
	g.dropped = 0
	return g


# Frees the gate. Held messages are the caller's: drain them first
# (durable_gate_complete / durable_gate_fail); freeing a gate that
# still holds messages is a programming error.
void durable_gate_free(durable_gate* g):
	assert1(g.held.length == 0)
	free(g)


# Holds msg until sequence seq is durable. Returns 1, or 0 when the gate
# has failed (msg is NOT held; the caller still owns it).
int durable_gate_hold(durable_gate* g, char* msg, int seq):
	if (g.failed): return 0
	g.held.push(msg)
	g.held_seq.push(seq)
	return 1


# Every write up to and including seq is durable: moves each held
# message whose sequence is <= seq onto out (hold order kept) and
# returns how many moved. A failed gate releases nothing (returns 0).
int durable_gate_complete(durable_gate* g, int seq, list[char*] out):
	if (g.failed): return 0
	if (seq > g.durable_seq): g.durable_seq = seq
	list[char*] keep = new list[char*]
	list[int] keep_seq = new list[int]
	int moved = 0
	int i = 0
	while (i < g.held.length):
		if (g.held_seq[i] <= g.durable_seq):
			out.push(g.held[i])
			moved = moved + 1
		else:
			keep.push(g.held[i])
			keep_seq.push(g.held_seq[i])
		i = i + 1
	g.held = keep
	g.held_seq = keep_seq
	g.released = g.released + moved
	return moved


# A required sync failed: marks the gate failed and moves EVERY held
# message onto out for the caller to discard -- none of them may be
# sent as a success. Returns how many moved.
int durable_gate_fail(durable_gate* g, list[char*] out):
	g.failed = 1
	int n = g.held.length
	int i = 0
	while (i < n):
		out.push(g.held[i])
		i = i + 1
	g.held = new list[char*]
	g.held_seq = new list[int]
	g.dropped = g.dropped + n
	return n


int durable_gate_pending(durable_gate* g):
	return g.held.length


int durable_gate_failed(durable_gate* g):
	return g.failed


int durable_gate_durable_seq(durable_gate* g):
	return g.durable_seq
