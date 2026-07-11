/*
Time-bounded exclusive leases with fencing epochs
(docs/projects/distributed.md; Chubby's coarse-grained locks, §2.4).

A lease grants one holder exclusive use of a resource id until a
monotime deadline. Expiry is passive: nothing fires when the deadline
passes — the next acquire/renew/check observes it through mono_expired,
so the module needs no timer plumbing, and every timing decision goes
through the wrap-safe monotime helpers (never raw timestamp compares).

Fencing (Chubby §2.4's sequencers; Kleppmann's fencing-token argument):
every successful acquire issues an epoch strictly greater than every
epoch this table has ever issued, drawn from one global u64 counter. A
downstream resource protects itself by calling lease_check with the
holder+epoch a client presents: a paused or partitioned old holder
still carries its old epoch, so its late writes are rejected even
though it never learned that it lost the lease. Epochs are u64 because
a 31-bit int counter could wrap over the life of a busy table; a u64
never will in practice.

A re-acquire by the current holder also issues a fresh, strictly
higher epoch (and extends the deadline). The invariant is deliberately
simple: an epoch identifies one grant, not a holder's whole tenure, so
"is this epoch the live grant?" is a single u64_eq and a superseded
token can never be revived.

The Memcache fill lease (Nishtala et al., NSDI 2013, §3.2.1) is this
same primitive pointed at a cache: on a miss, clients race
lease_acquire on the missing key's id. The first one gets the token
and fills from the database; the rest get 0 and wait or retry instead
of stampeding the backing store — and the winner's later
set-with-token is validated by lease_check.
*/
import lib.lib
import lib.memory
import lib.assert
import libs.standard.distributed.u64
import libs.standard.distributed.monotime


# ---- state ------------------------------------------------------------------

# One resource's lease record. A record is created on first acquire and
# reused forever after: holder/epoch/expires_at always describe the most
# recent grant, and held drops to 0 on release. Expiry writes nothing —
# it is observed by testing expires_at against the caller's now.
struct lease:
	int resource     # resource id this record guards
	int holder       # holder id of the most recent grant
	u64* epoch       # fencing epoch of the most recent grant
	int expires_at   # monotime deadline of the most recent grant
	int held         # 1 while granted, 0 after release


struct lease_table:
	map[int, lease*] leases   # resource id -> lease record
	u64* next_epoch           # next epoch to issue; global across resources
	int ttl_ms                # duration of every grant and renewal


lease_table* lease_table_new(int ttl_ms):
	assert1(ttl_ms >= 1)
	lease_table* t = new lease_table()
	t.leases = new map[int, lease*]
	t.next_epoch = u64_new_int(1)
	t.ttl_ms = ttl_ms
	return t


void lease_table_free(lease_table* t):
	for int resource in t.leases:
		lease* l = t.leases[resource]
		u64_free(l.epoch)
		free(l)
	u64_free(t.next_epoch)
	free(t)


# ---- internal helpers -------------------------------------------------------

# The record for resource, or 0 when it has never been acquired.
lease* lease_find(lease_table* t, int resource):
	if (resource in t.leases):
		return t.leases[resource]
	return 0


# 1 when l is a live grant at now_ms: exists, not released, not expired.
int lease_live(lease* l, int now_ms):
	if (l == 0):
		return 0
	if (l.held == 0):
		return 0
	if (mono_expired(now_ms, l.expires_at)):
		return 0
	return 1


# ---- operations -------------------------------------------------------------

# Try to grant resource to holder at now_ms. Grants when the resource is
# unheld, expired, or already held by this same holder (a re-acquire).
# On grant: epoch_out receives a copy of the issued epoch, the global
# counter is bumped, expires_at becomes now + ttl, and the result is 1.
# On refusal the result is 0 and epoch_out is left untouched.
#
# Even a same-holder re-acquire issues a fresh, strictly higher epoch —
# an epoch identifies a grant, not a holder tenure (see header), so the
# holder's previous token stops passing lease_check the moment the new
# grant lands.
#
# This is also the Memcache anti-thundering-herd fill lease (§3.2.1):
# acquire on a missing cache key's id — the winner fills from the
# database, the losers get 0 and wait/retry instead of stampeding.
int lease_acquire(lease_table* t, int resource, int holder, int now_ms, u64* epoch_out):
	lease* l = lease_find(t, resource)
	if (lease_live(l, now_ms)):
		if (l.holder != holder):
			return 0
	if (l == 0):
		l = new lease()
		l.resource = resource
		l.holder = holder
		l.epoch = u64_new()
		l.expires_at = now_ms
		l.held = 0
		t.leases[resource] = l
	l.holder = holder
	u64_copy(l.epoch, t.next_epoch)
	u64_copy(epoch_out, t.next_epoch)
	u64_inc(t.next_epoch)
	l.expires_at = mono_deadline(now_ms, t.ttl_ms)
	l.held = 1
	return 1


# Extend a live grant: 1 only when this exact holder+epoch currently
# holds an unexpired lease, in which case expires_at moves to
# now + ttl. 0 for a wrong holder, a stale epoch, an expired or
# released lease, or an unknown resource — the caller must go back
# through lease_acquire (and accept a new epoch).
int lease_renew(lease_table* t, int resource, int holder, u64* epoch, int now_ms):
	lease* l = lease_find(t, resource)
	if (lease_live(l, now_ms) == 0):
		return 0
	if (l.holder != holder):
		return 0
	if (u64_eq(l.epoch, epoch) == 0):
		return 0
	l.expires_at = mono_deadline(now_ms, t.ttl_ms)
	return 1


# Voluntarily give the lease up early: 1 when holder+epoch match the
# current grant (the record is marked unheld and the resource becomes
# immediately acquirable), 0 otherwise. A stale epoch can never release
# a newer holder's grant.
int lease_release(lease_table* t, int resource, int holder, u64* epoch):
	lease* l = lease_find(t, resource)
	if (l == 0):
		return 0
	if (l.held == 0):
		return 0
	if (l.holder != holder):
		return 0
	if (u64_eq(l.epoch, epoch) == 0):
		return 0
	l.held = 0
	return 1


# The fencing gate. A downstream resource calls this with the
# holder+epoch attached to an incoming action before honoring it:
# 1 iff that pair is the currently live, unexpired grant. 0 for a
# stale epoch (the lease was re-granted), a wrong holder, an expired
# or released lease, or an unknown resource.
int lease_check(lease_table* t, int resource, int holder, u64* epoch, int now_ms):
	lease* l = lease_find(t, resource)
	if (lease_live(l, now_ms) == 0):
		return 0
	if (l.holder != holder):
		return 0
	if (u64_eq(l.epoch, epoch) == 0):
		return 0
	return 1


# The holder id of the live grant at now_ms, or 0 - 1 when the resource
# is unheld, expired, or unknown.
int lease_holder(lease_table* t, int resource, int now_ms):
	lease* l = lease_find(t, resource)
	if (lease_live(l, now_ms) == 0):
		return 0 - 1
	return l.holder


# Milliseconds the live grant still has to run at now_ms; 0 when the
# resource is unheld, expired, or unknown.
int lease_remaining_ms(lease_table* t, int resource, int now_ms):
	lease* l = lease_find(t, resource)
	if (lease_live(l, now_ms) == 0):
		return 0
	return mono_remaining_ms(now_ms, l.expires_at)
