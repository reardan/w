# Layered layout and routing

The generic graph renderer (flowchart, ER, class, state, requirement, use
case, agentflow) places nodes with a native layered (Sugiyama-style) layout in
`libs/extras/mermaid/layout.w` and draws edges along the channels it reserves
(`libs/extras/mermaid/routing.w`, `mm_render_edge` in `render.w`). Architecture,
C4, block and the narrative/data families keep their own layouts.

## Pipeline

1. **Ranks.** Longest-path ranks from Kahn's traversal with a ready queue;
   a cycle is broken at the lowest-index remaining node, so results are the
   same as the earlier quadratic scan. Extra-dash links keep their minimum
   lengths.
2. **Dummy chains.** Every edge spanning more than one rank (forward or back
   edge) becomes a chain of dummy nodes, one per intermediate rank. Real and
   dummy nodes together are capped at `MM_LAYOUT_VIRTUAL_LIMIT` (32,768); an
   edge that would exceed it keeps a direct route.
3. **Ordering.** Alternating barycenter sweeps (down by upper neighbors, up by
   lower neighbors, stable merge sort) each followed by adjacent-transposition
   passes that swap neighbors while that strictly removes crossings. The
   crossing count between adjacent ranks is computed exactly with a Fenwick
   tree after every round and the best order is kept (12 rounds, 6 above 2,048
   virtual nodes). Transpositions share a fixed budget of 2,000,000 neighbor
   comparisons per layout.
4. **Coordinates.** Ranks are packed, then eight alternating passes pull each
   node toward the mean center of its neighbors in the rank just placed. Each
   rank is solved as a weighted isotonic regression (pool adjacent violators)
   under the order and minimum spacing (`nodeSpacing` between nodes, half of
   it beside a dummy channel), so a pass is linear in the rank size. Dummies
   weigh 8x, which straightens long edges into vertical (or horizontal) lanes.
5. **Channel routing between ranks.** Each routed edge stores, on its source
   node's bounds (`mm_edge_route` in `scene.w`), its dummy lanes, the rank
   bands it crosses and the free gaps between ranks. In each gap the jogs of
   different edges whose spans overlap get distinct tracks (bends); jogs
   leaving the same point or reaching the same point share a trunk and may
   share a track. Rightward jogs take tracks from the rightmost start,
   leftward ones from the leftmost, so two jogs going the same way do not
   cross. A gap with one track keeps the default bend (the 45px approach leg
   before the target), so simple diagrams are drawn as before.
6. **Drawing.** `flowchart.curve` keeps selecting the connector inside each
   gap: `step`/`stepBefore`/`stepAfter` (orthogonal, the default), `linear`
   or `basis`; inside a channel the edge runs straight along the rank axis.
   Every style therefore stays out of unrelated node boxes.
7. **Ports.** ER relationship ends on one entity side are ordered by the
   cross-axis position of their far end (first/last channel when routed), so
   neighboring relationships do not cross at the entity and parallel
   relationships take adjacent, distinct ports. In other families a side is
   only spread when edges both leave and arrive there (a back edge beside a
   forward edge), and parallel edges between one pair shift apart by 16px.
8. **Labels.** Edge labels start at the family default spot and move to the
   first of 18 candidates (other side of the leg, then steps along it) that is
   clear of every leaf node box and earlier label, using a uniform-grid index
   (cells of at least 256px, at most 257 x 257 cells). Edge-only redraws
   (canvas hit tests and highlights) reuse the chosen spot.

Routes are validated at draw time: when both endpoints moved by the same
amount since layout (title gutter, group offsets) the route is translated;
when one endpoint moved alone (a persisted `%% @w-position` record or a drag
preview) the edge falls back to the direct connector. Manual positions
therefore always override layout. Force layout (`config.layout: force`) keeps
direct connectors.

Not routed through channels: edges between nodes in the same rank, self
loops, edges whose endpoints are nested inside different subgraphs (laid out
against their scope's group box), and agentflow edges with an explicit
`curve`.

## Measured quality

`libs/extras/mermaid/route_metrics.w` measures a rendered scene by redrawing
each edge alone into a scene that borrows the laid-out bounds:

- **crossings**: proper intersections between path segments of two edges;
- **node hits**: (edge, node) pairs where a path enters an unrelated leaf box;
- **overlaps**: collinear overlaps over 4px between segments of two edges that
  share no endpoint (drawn on top of each other, they cannot be told apart);
- **label overlaps** / **label-node overlaps**: edge label boxes overlapping
  each other or a leaf node box;
- **shared ports**: two edges starting or ending on the same point.

The fixtures are the generators in `routing_test.w` (`routing_dense_flow`,
`routing_crowded_er`). "Before" is the previous renderer (left-packed ranks,
four barycenter sweeps without dummy nodes, direct connectors, index-order ER
ports, fixed label spots), measured with the same metric.

| Fixture | Crossings | Node hits | Overlaps | Label overlaps | Label-node | Shared ports |
| --- | --- | --- | --- | --- | --- | --- |
| Dense flowchart TB, 24 nodes / 41 edges, before | 20 | 17 | 99 | 4 | 0 | 112 |
| Dense flowchart TB, after | 76 | 0 | 0 | 0 | 0 | 52 |
| Dense flowchart LR, before | 20 | 17 | 99 | 5 | 2 | 112 |
| Dense flowchart LR, after | 69 | 0 | 0 | 0 | 0 | 52 |
| Crowded ER, 7 entities / 17 relationships, before | 12 | 22 | 16 | 0 | 0 | 1 |
| Crowded ER, after | 5 | 0 | 0 | 0 | 0 | 0 |

Rank-to-rank crossings of the layered graph (`mm_layered_first_crossings`
in source order, `mm_layered_last_crossings` after ordering) drop from 248 to
39 on the dense flowchart and from 31 to 3 on the crowded ER fixture.

The drawn segment-crossing count of the flowchart fixtures rises: before,
long edges ran straight through intermediate nodes and edges with a common
bend height were drawn on top of each other (99 collinear overlaps), which
hides crossings instead of removing them. After routing every edge is
traceable; the remaining crossings are where distinct tracks meet, roughly two
per layered crossing. Shared ports that remain in flowcharts are the intended
fan-in/fan-out at a node's side center.

## Alternatives evaluated

- **Orthogonal routing** is the default connector style and stays so; with
  channel routing all three curve styles avoid nodes
  (`test_every_curve_style_avoids_unrelated_nodes`), so no separate opt-in
  was needed.
- **Force layout** remains an opt-in for organic ER/graph pictures. It has no
  rank structure to route through, each round is quadratic, and its final
  collision pass can restart, so it keeps the 1,024-node budget and direct
  connectors.
- **Left-packed ranks** (the previous coordinates) were measured with the new
  ordering and channels first: long edges then jogged across the whole
  drawing (63 crossings on a similar generated 24-node, 41-edge TB fixture against 34 once coordinates
  follow neighbors, before tracks separated the shared bends).
- **Median ordering** and **Brandes-Kopf** coordinates were not tried: the
  transposition pass plus best-order tracking already removes most avoidable
  layered crossings on the fixtures, and the isotonic regression gives
  straight dummy chains with one linear pass per rank.

## Large workloads

Generated layered graphs (random edges between bands, ~1.5 edges per node for
flowcharts and 1.2 per entity for ER), timings in milliseconds on a shared
4-core Linux host (32-bit x86 build, then x64), including parse, layout and
render, and SVG export:

| Graph | Parse | Render | SVG |
| --- | --- | --- | --- |
| Flowchart 500 nodes / 703 edges | 3 / 4 | 62 / 48 | 5 / 5 |
| Flowchart 1,000 / 1,463 | 6 / 6 | 79 / 61 | 11 / 11 |
| Flowchart 2,000 / 2,957 | 11 / 12 | 126 / 113 | 22 / 24 |
| Flowchart 4,000 / 5,953 | 24 / 25 | 265 / 211 | 53 / 50 |
| ER 500 / 600 | 3 / 4 | 62 / 68 | 13 / 13 |
| ER 1,000 / 1,198 | 8 / 8 | 251 / 140 | 25 / 27 |
| ER 2,000 / 2,400 | 11 / 22 | 361 / 303 | 57 / 66 |
| ER 4,000 / 4,798 | 26 / 22 | 636 / 493 | 183 / 146 |

Before this work the 1,024-edge budget rejected all but the smallest of
these; at 1,000 nodes and 1,000 edges the previous renderer took 89 ms
(flowchart) and 92 ms (ER) to render, and parsing grew quadratically (861 ms
for 4,000 nodes) because node lookup scanned every node. Lookups now use an
id index (`mm_document.node_ids`, flowchart and ER, whose ids never change).

Hot paths are now O((V + S) log V) per ordering round for V real plus dummy
nodes and S segments: ranking, CSR adjacency, merge-sort sweeps, Fenwick
crossing counts, per-rank regression and track assignment (bounded to 512
jogs per gap), the sorted port assignment and the grid label index. The
quadratic parts left are bounded: transpositions by their work budget, track
assignment by its per-gap limit, and subgraph layout scans all nodes once per
group.

Budgets raised accordingly (all still checked):

| Budget | Before | Now |
| --- | --- | --- |
| Flowchart / ER nodes | 1,024 | 4,096 (`MM_MAX_GRAPH_NODES`) |
| Flowchart / ER edges | 1,024 | 8,192 (`MM_MAX_GRAPH_EDGES`) |
| ER attributes per document | 4,096 | 16,384 (`MM_MAX_GRAPH_ATTRIBUTES`) |
| Force layout nodes | 1,024 (all graphs) | 1,024 (`force layout node limit exceeded`) |
| Other graph families | 1,024 nodes / edges | unchanged (`MM_MAX_ITEMS`) |
| Layered virtual nodes | none | 32,768 real + dummy nodes |
