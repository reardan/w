# libs/standard/distributed: distributed-systems building blocks

Pure-W implementations of the core ideas from the classic industry
papers (Dynamo, Spanner, Bigtable, Chubby, Scaling Memcache, Raft),
built as libraries on the existing stack: `lib/task.w` cooperative
tasks, `lib/net.w` sockets, `lib/framing.w`/`lib/json_rpc.w` wire
plumbing, `libs/standard/crypto/` hashing.

## Design rules

1. **Word-size portability.** W's `int` is word-sized — 32 bits on the
   x86 target. Protocol quantities that conceptually need 64 bits
   (Raft terms/indexes, HLC timestamps) use `u64.w`: four 16-bit limbs
   per value (bignum.w's headroom rule), identical observable behavior
   and wire format on every target. Quantities where 31 bits genuinely
   suffice (vector-clock counters, ring positions) stay `int` with the
   limit documented at the declaration.
2. **Wrap-safe time.** `monotonic_ms` wraps a 32-bit int after ~24.8
   days on x86 (`lib/time.w`). Timing decisions (failure detectors,
   election timers, lease expiry) go through `monotime.w`, which only
   ever subtracts timestamps (serial-number arithmetic), never compares
   them directly.
3. **Simulation-first protocols.** Protocol modules are pure state
   machines: inputs are events (message arrived, timer fired), outputs
   are effect descriptions (send this, persist that). Sockets, clocks,
   and randomness stay outside, injected by the caller — so tests drive
   protocols through deterministic simulated schedules (drops, delays,
   partitions) with no real network, on every target including wasm.
4. Guard-heavy protocol code must use `&&`/`||`, never `&`/`|`, for
   conditions — the bitwise forms do not short-circuit.

## Phase 1 (this PR)

- `u64.w` — portable unsigned 64-bit values: arithmetic, comparison,
  shifts, 8-byte little-endian wire format, hex/decimal formatting.
- `monotime.w` — wrap-safe deltas, deadlines, and remaining-time math
  over monotonic millisecond timestamps.
- `clock.w` — Lamport clocks, vector clocks (compare/merge, the Dynamo
  version-tracking primitive), and hybrid logical clocks (packed
  48-bit ms + 16-bit logical counter in a u64 — the library-shaped
  version of Spanner's TrueTime commit ordering).
- `ring.w` — consistent hashing with virtual nodes (Dynamo/Memcache
  request routing): deterministic placement, preference lists.
- `quorum.w` — N/R/W overlap math and per-operation quorum tallies
  (Dynamo-style replicated reads/writes), plus read-repair planning
  from vector-clock comparisons.

## Later phases

- Phase 2: failure detector (heartbeat bookkeeping + phi-accrual with
  the exponential-CDF simplification, since lib/fmath.w has no
  exp/log), SWIM-style membership as a pure state machine, leases with
  fencing epochs (Chubby; Memcache leases), bloom filters (on
  `structures/bitset.w`), and the canonical vclock wire format
  (4-byte count + sorted node/counter entries, 8-byte u64 counters).
  Merkle trees for anti-entropy are NOT here: a Merkle implementation
  is landing with the VCS work (libs/extras/vcs); anti-entropy should
  reuse or adapt that one rather than grow a twin.
- Phase 3 (landed): `prng.w` seeded xorshift32, `sim.w` deterministic
  network harness (virtual clock, seeded delay/drop/reorder,
  delivery-time partitions), `raft.w` — Raft as a pure state machine
  over `u64` terms/indexes — and `raft_sim_test.w`, multi-node
  clusters replayed deterministically through the simulator
  (elections under loss, partition/heal convergence, minority
  lockout, seeded replay equality).
- Phase 4: checksummed write-ahead log, SSTable/memtable/compaction
  (Bigtable lineage), and a demo replicated KV store wiring raft +
  wal + rpc together over `lib/framing.w`.
