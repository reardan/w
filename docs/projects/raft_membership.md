# Learners and serialized membership changes

The supported transition sequence is **add learner → catch up → promote one
voter**, or remove one voter/learner. `raft_propose_add_server` is now an alias
for promotion and refuses an unknown or lagging node. There is no direct
public operation that turns a fresh node into a voter. Demotion and replacing
multiple voters in one entry are unsupported; use distinct serialized
transitions. Never reuse a removed node ID or bootstrap a joining node as a
separate single-voter cluster.

Start the initial voters with the same operator-provisioned configuration.
Start a joining node with `raft_new_learner(id, voters, ...)`, where `voters`
contains the existing voters and excludes the joining node. Restart it with
`raft_wal_recover_learner` using the same initial configuration. These APIs keep
it non-voting even if it crashes before receiving its admission entry. A
service with an initially mixed configuration can construct its exact
`bootstrap_config`, call `raft_use_config`, then use `raft_wal_recover_into`.
Bootstrap information is trusted operator configuration; network packets do
not implicitly admit unknown peers. Provision authenticated peer credentials
before proposing admission, and authorize them against the live replication
peer list. Credentials alone do not change consensus membership.

Enable no-op-on-election or commit a command before changing membership.
`raft_membership_ready` requires leadership, self voting rights, no pending
configuration entry, and a committed entry from the leader's current term.
This last condition is required again after every election: a new leader
cannot propose another configuration merely because its volatile commit index
has not yet learned about an earlier change.

`raft_propose_add_learner` logs admission without increasing quorum sizes. The
new replication peer starts at index 1 and uses ordinary append or snapshot
catch-up. `raft_learner_ready` requires the learner's acknowledged match index
to reach the leader's **entire current log**, not just an old committed index.
`raft_propose_promote_learner` checks readiness again at proposal time and
logs the single-voter addition. A leader change resets match indexes, so stale
acknowledgements from a previous term cannot authorize promotion. Follow the
usual `raft_wal_persist_release` contract: acknowledgements prove persisted
log/snapshot receipt. Snapshot application is independently gated by the
application's durable apply adapter.

`raft_propose_remove_server` removes one member and refuses removal of the
last voter. A self-removing leader immediately stops counting its own vote
and steps down when the removal commits. Learners and removed nodes do not
campaign. Unknown senders are rejected before term changes. Learners may send
replication acknowledgements in the current term, but cannot claim leadership,
raise a voter's term, vote, or supply read quorum acknowledgements. Stale
removed nodes cannot force current members to increase their terms.

Configurations take effect when appended. Only current voters count toward
replication, elections, and strong reads; all current peers, including
learners, receive replication. Every configuration append, rollback, or
snapshot adoption invalidates a pending read barrier. Serialized single-voter
changes retain intersecting adjacent majorities; there is no joint-consensus
or arbitrary multi-voter transition API. Internal `raft_propose_internal` and
replay hooks are trusted implementation interfaces, not application admission
APIs. Historical tests intentionally exercise these hooks with raw config
entries; `raft_learner_test` exercises the public admission sequence.

Configuration entries retain the five-byte payload: opcode 1 promotes,
2 removes, and 3 adds a learner. Snapshot configurations retain the integer-list
layout: a nonnegative token is a voter ID, and `-(id + 1)` is a learner ID.
IDs are restricted to 0 through 2147483646. Decoders reject empty/voterless
configurations, duplicate decoded identities, and invalid IDs. Signed tokens
must use `raft_config_load_token` on both word sizes. Old binaries do not
understand learner tokens or opcode 3: upgrade the whole cluster before using
learners; mixed-version learner operation is unsupported.

Rollback reconstructs membership from the snapshot (or immutable bootstrap
configuration) and surviving log. It handles several configuration records
replayed before volatile commit catches up after a crash. Snapshot creation
uses the exact configuration at `last_applied`, even when a newer
configuration has already committed but has not yet reached the application.
Self membership is explicit, so snapshots taken by a removed node do not
accidentally reinsert that node.

Tests cover partitioned learner catch-up and promotion, checked write histories
while a learner is unavailable, learner exclusion from write/read quorums,
term-spoofing by learners and removed nodes, leader changes with an uncommitted
promotion, read invalidation, exact snapshot membership boundaries, WAL
recovery and multi-entry rollback, and empty-WAL learner restarts. These are
deterministic x86/x64 regressions and the existing election/replication seed
sweeps, not a formal proof of the Raft implementation.
