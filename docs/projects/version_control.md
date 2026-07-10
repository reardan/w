# Version control internals: survey, fundamentals, and a W Extras roadmap

Design survey, 2026-07-10. Companion to
`docs/projects/build_system_next.md`, whose grammar+VCS build direction
(4b) is explicitly blocked on W growing versioning support. This doc is
the unblocking plan: survey what real version control systems do, distill
the fundamental algorithms and data structures, inventory what W already
has, and stage a set of `libs/extras/` packages that build the missing
pieces bottom-up — each shippable and useful on its own, and several
dual-use with the build system work (the content-addressed store *is*
the shared build cache).

## Survey: how the major systems actually work

### Git — snapshots in a content-addressed Merkle DAG

Git's entire model is four object types in one content-addressed store:

- **blob** (file bytes), **tree** (sorted list of name/mode/child-hash
  entries — a directory snapshot), **commit** (root tree hash + parent
  commit hashes + author/message), **tag**. Every object is stored under
  the hash of `"<type> <size>\0" + payload` (SHA-1 historically; the
  SHA-256 transition is in progress). Identity, deduplication, and
  integrity checking all fall out of the addressing scheme.
- Because trees hash their children, the store is a **Merkle DAG**:
  equal subtrees have equal hashes, so comparing two commits descends
  only into directories whose hashes differ — diff cost is
  O(changed), not O(tree). This one property is what the
  grammar+VCS build idea wants at definition granularity.
- **History is a DAG of commits**, not diffs: every commit is a full
  snapshot; deltas exist only as a storage encoding. This inversion
  (snapshot semantics, delta storage) is git's core design win —
  correctness reasoning never involves patch application.
- **Packfiles** are the storage layer: objects heuristically sorted
  (type, path suffix, size), delta-compressed against similar
  neighbors within a sliding window, zlib-deflated, with bounded delta
  chain depth. The `.idx` sidecar has a 256-way fanout table over
  sorted hashes for binary search; commit-graph files add **generation
  numbers** (topological levels) so ancestry queries can prune without
  walking; **EWAH reachability bitmaps** make "what does this ref
  reach" near-O(1); **changed-path Bloom filters** accelerate
  `git log -- path` by skipping commits that provably didn't touch it.
- The **index** (staging area / dirstate) is a sorted path table with
  cached stat data (size, mtime, inode). `git status` compares stat
  fields and re-hashes only suspicious entries (including the
  racy-mtime case where a file's mtime equals the index's own), so
  status is O(changed files), not O(repository).
- **Diff** is Myers' O(ND) shortest-edit-script algorithm, with
  patience/histogram variants that anchor on unique lines for more
  human-readable hunks. **Merge** is three-way from the merge base
  (LCA in the commit DAG); criss-cross histories get a recursively
  merged *virtual* base (merge-recursive, now merge-ort). Renames are
  not recorded — they're *detected* at diff/merge time by content
  similarity scoring.
- **Refs** are just names → hashes, with an append-only reflog;
  transfer is the have/want negotiation: peers exchange which commits
  they have until the sender can build a minimal packfile.

### Mercurial — append-only revlogs and per-file history

- The **revlog** is the universal storage structure: an append-only
  file of revisions where each entry is either a delta against a prior
  revision or a periodic full snapshot (bounding delta-chain read
  cost), plus an index mapping revision number → offset. A node's id
  is the hash of its parents plus content — same Merkle integrity as
  git, different layout.
- Three revlog families: the **changelog** (commits), the **manifest**
  (flat file-list snapshot, hg's "tree"), and one **filelog per file**.
  Filelog entries carry a *linkrev* back to the changelog, so per-file
  history and annotate/blame are direct index reads — the query git
  answers by walking and Bloom-filtering, hg answers by construction.
  The lesson: **if a query matters, give it its own append-only log**
  — directly relevant to the definition-history index in the
  grammar+VCS plan.
- **Phases** (public/draft/secret) and **obsolescence markers** record
  history *rewriting* as data instead of destruction: a rebased commit
  is marked "superseded by X", so collaborators' tools can reconcile
  instead of duplicating. Changeset evolution remains the most
  principled answer to safe shared rebasing.

### Google Piper + CitC — centralized, lazy, build-integrated

(Per the 2016 CACM paper "Why Google Stores Billions of Lines of Code
in a Single Repository".)

- One monorepo, **trunk-based**, with Perforce-lineage semantics:
  atomic **changelists** with a single linear number sequence rather
  than a DAG — ordering, not topology, is the primary structure.
  Storage rides on Google's distributed database infrastructure rather
  than local packfiles.
- **CitC (Clients in the Cloud)**: a workspace is a cloud-backed FUSE
  filesystem. Only files you edit materialize; everything else is
  served on demand from the repo at your chosen changelist. Every save
  is snapshotted, so workspaces are lightweight, shareable, and
  reviewable before commit.
- The deep lesson for W: **the VCS store and the build system's
  content-addressed store are the same thing**. Blaze/Forge's remote
  execution addresses source files by digest served straight out of
  the VCS layer (SrcFS), and outputs land in a CAS (ObjFS). Piper
  demonstrates at extreme scale exactly the convergence
  `build_system_next.md` direction 3 proposes: one CAS, two clients
  (build cache, version history).

### The rest of the design space, briefly

- **SVN / Perforce** — centralized linear revisions; SVN's cheap O(1)
  branch-as-copy (a new directory node sharing children) and
  skip-deltas for O(log n) reconstruction; Perforce's per-file
  revisions + changelists are Piper's direct ancestor.
- **Monotone** — originated the content-addressed Merkle-DAG design
  (plus hash-signed certs) that git and hg both adopted.
- **Fossil** — everything (code, tickets, wiki) as content-addressed
  artifacts inside SQLite; history queries are SQL. A reminder that
  "VCS as database with a relational query surface" is viable and
  pleasant at small scale.
- **Darcs / Pijul** — **patch theory**: the repository is a set of
  changes with commutation rules rather than a snapshot DAG. Pijul
  makes it sound (files as graphs of lines; merges associative;
  conflicts are first-class repository states, not text markers).
  Closest prior art in spirit to "maintain structured diffs as the
  primary artifact"; also a caution — Darcs' exponential merge cases
  took a decade to fix, and the model resists mainstream tooling.
- **Jujutsu (jj)** — the modern synthesis: the working copy *is* a
  commit (continuously amended), every repo mutation goes through an
  **operation log** (universal undo), conflicts are first-class
  objects that can be committed and resolved later, and the storage
  backend is pluggable (git-compatible locally; a cloud backend at
  Google). Backend-agnostic porcelain over a CAS is exactly the
  right posture for W: `wvc` semantics shouldn't care whether objects
  live in loose files or a future server.

## The fundamentals, distilled

The recurring algorithms and data structures, roughly ordered by how
much of the field depends on them:

1. **Content addressing** — hash(typed payload) as identity. Gives
   dedup, integrity, and O(1) equality everywhere.
2. **Merkle trees / DAGs** — recursive hashing of containers; diff and
   sync costs proportional to what changed.
3. **Commit-DAG algorithms** — LCA/merge-base, generation numbers,
   topological iteration, reachability bitmaps, changed-path Bloom
   filters.
4. **Text diff** — Myers O(ND) shortest edit script; patience/
   histogram refinements for hunk quality.
5. **Binary delta + rolling hash** — Rabin-Karp/adler-style rolling
   window to find shared blocks, copy/insert opcode streams, bounded
   delta chains with periodic snapshots (revlog/packfile).
6. **Compression** — zlib deflate historically, zstd in modern
   systems. Always an encoding layer, never semantics.
7. **Three-way merge** — diff(base→ours) ⊕ diff(base→theirs) over a
   common base, conflicts where hunks overlap; rename *detection* by
   similarity rather than recorded renames.
8. **Stat-cached working-tree index** — sorted path table + cached
   stat data; O(changed) status. (The same trick as wexec's cache
   stamps, applied per-file.)
9. **Append-only logs with indexes** — revlog, reflog, jj's op log;
   crash safety by append + atomic rename; history queries by
   construction.
10. **Set-reconciliation transfer** — have/want negotiation to ship a
    minimal object set.
11. **Patch theory / commutation** — the research tier; powerful,
    niche.

## What W already has, and the gaps

**In the tree today**: streaming SHA-256/384/512 behind the `whash`
interface (`libs/standard/crypto/sha2.w`, wrapping the seed-safe
`lib/sha256.w` core — the right layer for VCS hashing); base64;
`structures/` hash tables, array lists, strings, JSON;
`lib/file.w`/`lib/path.w`/`lib/process.w`/`lib/stream.w`/`lib/time.w`;
a full HTTP(S)+TLS stack for an eventual sync protocol; the test
conventions (`*_test.w` + `./wbuild manifest`) so every module lands
with coverage; and `package.wmeta` version metadata (stages 1–4 of
`docs/package_metadata.txt`).

**Missing entirely**: compression (no deflate/crc32 anywhere in the
tree), any diff algorithm, binary delta, DAG algorithms as a library,
a stat-cached index structure, and append-only log storage.

None of the proposed code enters `w.w`'s import closure (unlike
`libs/extras/c_import` etc.), so **nothing here is seed-constrained**
— current language syntax is fine throughout.

## Proposed Extras: `libs/extras/vcs/` in four waves

Each wave is independently landable, tested by convention, and useful
before the next begins. Modules are ordered so the build-system work
(`build_system_next.md`) can consume the early pieces immediately.

### Wave 1 — foundations (dual-use with the build system from day one)

- **`libs/extras/vcs/cas.w`** — content-addressed object store.
  `cas_open(root)`, `cas_put(type, bytes) → id`, `cas_get(id)`,
  `cas_has(id)`. Git-style `"<type> <len>\0"` header hashed with the
  payload via `whash` SHA-256; loose-object layout
  `objects/<2-hex>/<62-hex>` with write-to-temp + rename for atomicity
  (dedup is free: existing id ⇒ skip write). **Uncompressed
  initially** — compression is an encoding slot to fill later, not a
  semantic requirement. This module *is* direction 3's build cache
  store; `wcache.w` and `wvc` become two clients of one library.
- **`libs/extras/vcs/diff.w`** — Myers line diff producing a hunk
  list, plus a unified-format renderer. Immediate dogfood: a `wdiff`
  build target, and eventually richer `lib/testing.w` failure output.
  Histogram/patience variants can come later behind the same API.
- **`libs/extras/vcs/dag.w`** — DAG over 32-byte ids: parent map,
  topological iteration, LCA/merge-base with generation numbers,
  reachability. In-memory over `structures/hash_table.w` first; a
  serialized index only when history sizes demand it.

### Wave 2 — snapshots and history (a working `wvc`)

- **`libs/extras/vcs/tree.w`** — Merkle tree objects: sorted
  (name, mode, id) entries serialized canonically; snapshot a
  directory (with an ignore list — `bin/` etc.) to a tree id;
  tree-diff by parallel descent that skips equal ids.
- **`libs/extras/vcs/commit.w`** — commit objects (tree id, parents,
  author, timestamp, message) in a line-oriented text format
  (`package.wmeta`'s philosophy: parseable without a general parser);
  refs as files plus an append-only reflog.
- **`tools/wvc.w`** — porcelain and end-to-end test:
  `init / snapshot / log / diff / status` (status via full hash
  compare in this wave — slow path only). A hand-written
  `build.base.json` target like the other tool binaries.

### Wave 3 — the performance structures

- **`libs/extras/vcs/index.w`** — dirstate: sorted path table with
  (size, mtime) stat cache in a binary format; O(changed) `wvc
  status`, with git's racy-mtime guard (re-hash entries whose mtime
  equals the index's own write time).
- **`libs/extras/vcs/delta.w`** — binary delta: rolling-hash block
  table over the base, copy/insert opcode stream, bounded-depth delta
  chains with periodic snapshots (the revlog lesson). Lands as an
  alternative CAS object encoding, so history storage shrinks without
  touching any caller.
- **`libs/extras/compress/`** — CRC32 plus DEFLATE (inflate first,
  deflate second). Its own package, deliberately outside `vcs/`:
  the web stack wants gzip anyway, and inflate+SHA-1 would be the
  only extra pieces needed if git-format interop ever becomes a goal.
  This is the largest single chunk of code in the plan (~1–2k lines);
  it should be its own project doc when picked up.

### Wave 4 — merge and sync

- **`libs/extras/vcs/merge3.w`** — three-way merge over `diff.w`
  hunks with conflict markers; merge-base from `dag.w`. Rename
  detection deferred until something needs it.
- **Sync** — have/want set reconciliation over the existing HTTP/TLS
  stack. At this repo's scale the MVP is: exchange ref heads, walk the
  DAG for the missing closure, ship objects. This endpoint and the
  shared build cache server converge on the same CAS-over-HTTP
  surface — one server, two routes.

## How this feeds the grammar+VCS build (the payoff)

- **Wave 1's `cas.w` unblocks build direction 3** (shared cache)
  immediately — before any porcelain exists.
- **`defhash` objects become CAS objects**: a file's definition list
  is itself a Merkle node, giving a *semantic tree* alongside the file
  tree. Commit-to-commit definition diff is then the same O(changed)
  Merkle descent as file diff — the "tree diffs maintained across
  versions" half of the original idea, built from the same primitives.
- **`dag.w`'s merge-base gives `wtest changed A..B`** exact,
  commit-ranged semantics once commits exist (build direction 4b,
  currently deferred on exactly this).
- **`index.w` is the realtime half**: the same stat-cache trick that
  makes `wvc status` O(changed) makes the save-time definition index
  (build direction 4c) cheap to keep warm.

## Design decisions

- **SHA-256, not SHA-1**: already in-tree behind `whash`, no legacy
  compatibility to honor. 32-byte binary ids internally, hex for
  display and object paths.
- **Snapshot-first (git model), not delta-first (hg)**: snapshots keep
  correctness reasoning trivial and W's files are small; deltas arrive
  in wave 3 purely as storage encoding. But the *definition index*
  should steal hg's append-only revlog shape — per-definition history
  is exactly the "give the query its own log" case.
- **Git interop is a non-goal for now**: it would force zlib + SHA-1 +
  exact pack formats from day one. Revisit after `compress/` lands;
  jj demonstrates that porcelain over a pluggable backend keeps that
  door open.
- **Conflicts and history-rewriting policy** (phases, obsolescence,
  op logs) are porcelain-tier concerns deferred until `wvc` has real
  users; the storage layer just needs to make them possible (immutable
  objects + movable refs already do).
- **Testing**: every module ships `<name>_test.w` (plus `# wbuild:
  x64` twins where meaningful), registered via `./wbuild manifest`;
  `bin/wtest` picks them up through import closures with no
  `test_map.w` residue rules needed.

## Suggested sequencing

1. Wave 1, in order `cas.w` → `diff.w` → `dag.w` (cas unblocks the
   build cache; diff is immediately dogfoodable; dag is small).
2. Wave 2 for a demo-able `wvc` and the semantic-tree experiments.
3. Wave 3 when history size or `status` latency actually hurts —
   `compress/` is the one to schedule as its own project.
4. Wave 4 when collaboration or sync becomes real.
