/*
Dynamo-style quorum bookkeeping for replicated reads and writes
(Dynamo §4.5; companion to the logical clocks in clock.w).

Three layers, all target-independent int math:

  quorum_config       the static N/R/W triple. A strict configuration
                      needs 1 <= R <= N, 1 <= W <= N and R + W > N, so
                      every read quorum overlaps the latest write
                      quorum and a read sees at least one up-to-date
                      version.
  quorum_tally        ack/nak counting for one replicated fan-out. The
                      success and failure edges each fire exactly once,
                      so a coordinator can complete its request on the
                      edge without double-firing.
  quorum_read_repair  given the vclock* versions a read quorum
                      returned, pick the winning version (or flag
                      concurrent siblings) and list the stale replica
                      indexes to repair. Consumes the frozen
                      vclock_compare contract: -1 before, 0 equal,
                      1 after, 2 concurrent.

Replica identity in read repair is positional: versions[i] is replica
i's version, and repair_plan holds those indexes.
*/
import lib.lib
import lib.memory
import lib.assert
import libs.standard.distributed.clock


# ---- configuration ----------------------------------------------------------

struct quorum_config:
	int n   # replicas holding each key
	int r   # replicas that must answer a read
	int w   # replicas that must confirm a write


quorum_config* quorum_config_new(int n, int r, int w):
	quorum_config* cfg = new quorum_config()
	cfg.n = n
	cfg.r = r
	cfg.w = w
	return cfg


void quorum_config_free(quorum_config* cfg):
	free(cfg)


# 1 when the configuration guarantees read/write overlap: 1 <= r <= n,
# 1 <= w <= n and r + w > n, so a read quorum always intersects the
# latest write quorum (Dynamo §4.5). n < 1 is never strict.
int quorum_config_strict(quorum_config* cfg):
	if (cfg.n < 1):
		return 0
	if (cfg.r < 1 || cfg.r > cfg.n):
		return 0
	if (cfg.w < 1 || cfg.w > cfg.n):
		return 0
	if (cfg.r + cfg.w > cfg.n):
		return 1
	return 0


# Smallest majority of n voters.
int quorum_majority(int n):
	assert1(n >= 1)
	return n / 2 + 1


# ---- per-operation tally ----------------------------------------------------

# Bookkeeping for one replicated read or write fan-out: total replicas
# were asked, needed successes decide the operation.
struct quorum_tally:
	int needed   # acks required for success (R or W)
	int total    # replicas the request went to
	int acks     # successes recorded so far
	int naks     # failures recorded so far


quorum_tally* quorum_tally_new(int needed, int total):
	assert1(needed >= 1 && needed <= total)
	quorum_tally* t = new quorum_tally()
	t.needed = needed
	t.total = total
	t.acks = 0
	t.naks = 0
	return t


void quorum_tally_free(quorum_tally* t):
	free(t)


# Record one replica success. Returns 1 exactly when this ack is the
# one that reaches needed — the success edge fires once; later acks
# return 0.
int quorum_tally_ack(quorum_tally* t):
	assert1(t.acks + t.naks < t.total)
	t.acks = t.acks + 1
	if (t.acks == t.needed):
		return 1
	return 0


# Record one replica failure. Returns 1 exactly when this nak makes
# success impossible — once total - needed + 1 replicas have failed,
# fewer than needed can still ack. The failure edge fires once.
int quorum_tally_nak(quorum_tally* t):
	assert1(t.acks + t.naks < t.total)
	t.naks = t.naks + 1
	if (t.naks == t.total - t.needed + 1):
		return 1
	return 0


int quorum_tally_succeeded(quorum_tally* t):
	if (t.acks >= t.needed):
		return 1
	return 0


int quorum_tally_failed(quorum_tally* t):
	if (t.naks > t.total - t.needed):
		return 1
	return 0


# 1 once the outcome is decided or every replica has answered.
int quorum_tally_settled(quorum_tally* t):
	if (quorum_tally_succeeded(t) || quorum_tally_failed(t)):
		return 1
	if (t.acks + t.naks == t.total):
		return 1
	return 0


# ---- read repair (Dynamo §4.5) ----------------------------------------------

struct repair_plan:
	int winner_index   # 0-based index of the winning version; 0 - 1 on conflict
	int conflict       # 1 when the maximal versions are mutually concurrent
	list[int] stale    # ascending indexes whose version must be repaired


# Decide what a coordinator does with the versions a read quorum
# returned. versions[i] is replica i's vclock; the input must be
# non-empty (asserted).
#
# A version is maximal when no other version strictly dominates it. If
# some maximal version descends-or-equals every other, it wins:
# winner_index is its first index, conflict is 0, and stale lists every
# index the winner strictly dominates (equal copies are not stale). If
# two maximal versions are mutually concurrent there is no winner:
# conflict is 1, winner_index is 0 - 1, and stale lists every version
# strictly dominated by at least one maximal — the siblings themselves
# are kept for semantic reconciliation.
repair_plan* quorum_read_repair(list[vclock*] versions):
	int count = versions.length
	assert1(count >= 1)
	repair_plan* plan = new repair_plan()
	plan.winner_index = 0 - 1
	plan.conflict = 0
	plan.stale = new list[int]
	# maximal[i] = 1 when no other version strictly dominates versions[i]
	list[int] maximal = new list[int]
	int i = 0
	int j = 0
	while (i < count):
		int is_max = 1
		j = 0
		while (j < count):
			if (j != i && vclock_compare(versions[j], versions[i]) == 1):
				is_max = 0
			j = j + 1
		maximal.push(is_max)
		i = i + 1
	# a maximal version that descends-or-equals every other version wins
	int winner = 0 - 1
	i = 0
	while (i < count && winner < 0):
		if (maximal[i]):
			int dominates_all = 1
			j = 0
			while (j < count):
				if (vclock_descends(versions[i], versions[j]) == 0):
					dominates_all = 0
				j = j + 1
			if (dominates_all):
				winner = i
		i = i + 1
	if (winner >= 0):
		plan.winner_index = winner
		j = 0
		while (j < count):
			if (vclock_compare(versions[winner], versions[j]) == 1):
				plan.stale.push(j)
			j = j + 1
		return plan
	# concurrent siblings: no winner; a replica is stale when some
	# maximal version strictly dominates it
	plan.conflict = 1
	j = 0
	while (j < count):
		int dominated = 0
		i = 0
		while (i < count):
			if (maximal[i] && vclock_compare(versions[i], versions[j]) == 1):
				dominated = 1
			i = i + 1
		if (dominated):
			plan.stale.push(j)
		j = j + 1
	return plan


# Frees the plan struct itself; the stale list storage is runtime-
# managed (matching vclock_free).
void repair_plan_free(repair_plan* p):
	free(p)
