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
   lengths. A promotion pass then moves each node with more forward
   successors than predecessors down to just above its nearest successor
   (bottom ranks first), shortening long edges.
2. **Dummy chains.** Every edge spanning more than one rank (forward or back
   edge) becomes a chain of dummy nodes, one per intermediate rank. Real and
   dummy nodes together are capped at `MM_LAYOUT_VIRTUAL_LIMIT` (32,768); an
   edge that would exceed it keeps a direct route.
3. **Ordering.** Alternating barycenter sweeps (down by upper neighbors, up by
   lower neighbors, stable merge sort) each followed by adjacent-transposition
   passes that swap neighbors while that strictly removes crossings, and a
   sifting pass that moves each node to the slot of its rank where it crosses
   least. The crossing count between adjacent ranks is computed exactly with a Fenwick
   tree after every round and the best order is kept (12 rounds, 6 above 2,048
   virtual nodes). Transpositions and sifting share a fixed budget of
   2,000,000 neighbor comparisons per layout.
4. **Coordinates.** Ranks are packed, then eight alternating passes pull each
   node toward the mean center of its neighbors in the rank just placed. Each
   rank is solved as a weighted isotonic regression (pool adjacent violators)
   under the order and minimum spacing (`nodeSpacing` between nodes, half of
   it beside a dummy channel), so a pass is linear in the rank size. Dummies
   weigh 8x, which straightens long edges into vertical (or horizontal) lanes.
5. **Channel routing between ranks.** Each routed edge stores, on its source
   node's bounds (`mm_edge_route` in `scene.w`), its dummy lanes, the rank
   bands it crosses and the free gaps between ranks. In each gap the jogs of
   different edges whose spans overlap get distinct tracks (bends). Jogs are
   ranked rightward first by descending start, then leftward by ascending
   start (from a shared start, the longer jog first), and each jog takes the
   track just below every earlier jog it overlaps (longest path over the
   overlaps; a jog sharing a trunk with an earlier one may share its track
   but never rise above it). For jogs going the same way this yields no
   crossing unless their ends are inverted, and an inverted pair crosses
   once, so the drawn crossings equal the rank-to-rank crossings of the
   order. The jog ends use the ports the renderer will draw (step 7). A gap with one track keeps the default bend (the 45px approach leg
   before the target), so simple diagrams are drawn as before.
6. **Drawing.** `flowchart.curve` keeps selecting the connector inside each
   gap: `step`/`stepBefore`/`stepAfter` (orthogonal, the default), `linear`
   or `basis`; inside a channel the edge runs straight along the rank axis.
   Every style therefore stays out of unrelated node boxes.
7. **Ports.** ER relationship ends on one entity side are ordered by the
   cross-axis position of their far end (first/last channel when routed), so
   neighboring relationships do not cross at the entity and parallel
   relationships take adjacent, distinct ports. In other families a side is
   only spread when it holds parallel edges or edges that both leave and
   arrive (a back edge beside a forward edge); its ports then sit 16px apart
   around the center in the same far-end order. `mm_place` mirrors this
   assignment so channel tracks are ordered by the drawn ports.
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

### Obstacle routing for edges outside the channels

Edges the rank channels cannot carry are routed by an obstacle-aware
orthogonal router (`mm_obstacle_route` in `routing.w`, driven by
`mm_render_obstacle_routes` in `render.w`): edges between nodes in the same
rank, self loops, and edges whose endpoints sit in different subgraphs
(laid out against their scope's group box). The router runs after ports are
assigned and before edges are drawn, for each such edge whose direct
connector enters a node box or group title band or runs collinear with an
unrelated edge (a clear direct connector is kept), and for every same-rank
edge:

- **Obstacles** are every leaf node box and every group title band (the
  label strip at the top of a subgraph), padded by 12px; the edge's own
  endpoints are obstacles too except for their port stubs.
- **Ports** are candidates on all four sides: the side facing the other
  endpoint costs nothing, a perpendicular side half a bend, the opposite side
  two bends; repeated use of a side spreads ports 16px apart. Same-rank
  edges use the facing sides. Each port leaves its box by a 24px stub.
- **Search** is Dijkstra over (grid point, axis) states on the Hanan grid of
  obstacle edges, port stubs and the region around them (at most 256 grid
  lines per axis). A step costs its length plus 48 per bend, 4000 per
  collinear overlap with an already routed edge and 120 per crossing; a
  step into an obstacle is not allowed. The chosen polyline is validated
  against every obstacle again; an edge with no valid route keeps its
  previous path. At most 512 edges per render are routed this way.
- **Drawing** keeps the route's points in the edge's route record
  (`mm_edge_route.points`), so the SVG, the native preview and edge-only
  redraws draw the same path; arrowheads and end markers follow the last
  segment's direction. Routes translate with their endpoints like channel
  routes and fall back to direct connectors when one endpoint moved alone.

Agentflow edges with an explicit `curve` (`step`, `linear`, `basis`, ...)
are routed the same way first and then drawn along the route with that
curve (rounded corners for the smooth curves), so a curved edge no longer
cuts through the steps between its endpoints. Architecture diagrams, force
layout, invisible flowchart links (`~~~`) and class lollipop endpoints keep
their own connectors.

Stress fixtures in `routing_test.w`, measured with `route_metrics.w` before
(the direct connector) and after:

| Fixture | Before | After |
| --- | --- | --- |
| Self loops beside neighbours (`nodeSpacing: 20`) | 2 node hits | 0 node hits |
| Same-rank edges (persisted positions) | 4 edges through their own endpoint boxes | 0 endpoint or node hits, 0 overlaps, 0 shared ports, 4 crossings |
| Edges between nested subgraphs, TB | 12 node hits, 3 title hits, 8 overlaps, 9 shared ports | 0, 0, 0, 0 (2 crossings) |
| Edges between nested subgraphs, LR | 7 node hits, 3 title hits, 8 overlaps, 9 shared ports | 0, 0, 0, 2 |
| Agentflow `step` / `linear` / `basis` curves | edges through steps | 0 node hits, 0 title hits |

`route_metrics.w` gained two counts for these fixtures: **title hits**
(a path entering an unrelated group title band) and **end hits** (a path
entering its own endpoint's box past the port).

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
| Dense flowchart TB, after | 39 | 0 | 0 | 0 | 0 | 37 |
| Dense flowchart LR, before | 20 | 17 | 99 | 5 | 2 | 112 |
| Dense flowchart LR, after | 39 | 0 | 0 | 0 | 0 | 37 |
| Crowded ER, 7 entities / 17 relationships, before | 12 | 22 | 16 | 0 | 0 | 1 |
| Crowded ER, after | 1 | 0 | 0 | 0 | 0 | 0 |

Rank-to-rank crossings of the layered graph (`mm_layered_first_crossings`
in source order, `mm_layered_last_crossings` after ordering) drop from 226 to
39 on the dense flowchart and from 23 to 0 on the crowded ER fixture. The
flowchart's drawn crossings now equal its layered ones
(`test_dense_flowchart_stress` asserts that and pins 39); the ER fixture has
one crossing at entity ports spread across the whole side.

The old drawing's 20 visible crossings are not a reachable target: long
edges ran straight through intermediate nodes (17) and edges shared bend
heights (99 collinear overlaps), which hides crossings rather than removing
them. Any layered drawing of these ranks has at least as many crossings as its
order has rank-to-rank crossings, and a 300-restart randomized barycenter
search over ranks and dummy chains built by the same rules (scratch script, not in the tree)
found 36 at best, so 39 is within 3 of the best order found.
On two further generated fixtures (24 nodes / 41-42 edges) drawn crossings
are 34 and 25, again equal to the layered counts. Shared ports that remain in
flowcharts are the intended fan-in/fan-out at a node's side center.

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
  drawing (63 crossings on a similar generated 24-node, 41-edge TB fixture
  against 34 once coordinates follow neighbors).
- **Track assignment**: first-fit tracks (the lowest free track) gave 76
  drawn crossings on the dense TB fixture; longest-path tracks in the order
  above gave 60; drawing parallel edges with fixed +/-8px offsets that the
  tracks did not know about added inversions with sibling edges (57); ports
  ordered by far end and mirrored into the jogs brought it to 39, the layered
  count.
- **More ordering rounds** (40 instead of 12) and sifting did not lower the
  layered count on the fixtures (39); promotion lowered the ER fixture from 3
  to 0 and the source-order count from 248 to 226.
- **Median ordering**, **Brandes-Kopf** coordinates and choosing a direct
  connector over a routed one per edge were not adopted: drawn crossings
  already equal the layered count, a direct connector can only add crossings
  and node hits relative to its channel, and the isotonic regression gives
  straight dummy chains with one linear pass per rank.

## Large workloads

Generated layered graphs (random edges between bands, ~1.5 edges per node for
flowcharts and 1.2 per entity for ER), timings in milliseconds on a shared
4-core Linux host (32-bit x86 build, then x64), including parse, layout and
render, and SVG export:

| Graph | Parse | Render | SVG |
| --- | --- | --- | --- |
| Flowchart 500 nodes / 703 edges | 3 / 3 | 76 / 59 | 5 / 5 |
| Flowchart 1,000 / 1,463 | 6 / 5 | 85 / 71 | 10 / 10 |
| Flowchart 2,000 / 2,957 | 13 / 11 | 128 / 120 | 21 / 21 |
| Flowchart 4,000 / 5,953 | 24 / 23 | 219 / 188 | 49 / 44 |
| ER 500 / 600 | 3 / 3 | 88 / 68 | 12 / 12 |
| ER 1,000 / 1,198 | 6 / 5 | 118 / 116 | 20 / 20 |
| ER 2,000 / 2,400 | 11 / 11 | 238 / 207 | 51 / 54 |
| ER 4,000 / 4,798 | 24 / 35 | 496 / 473 | 133 / 191 |

Before this work the 1,024-edge budget rejected all but the smallest of
these; at 1,000 nodes and 1,000 edges the previous renderer took 89 ms
(flowchart) and 92 ms (ER) to render, and parsing grew quadratically (861 ms
for 4,000 nodes) because node lookup scanned every node. Lookups now use an
id index (`mm_document.node_ids`, flowchart and ER, whose ids never change).

Hot paths are now O((V + S) log V) per ordering round for V real plus dummy
nodes and S segments: ranking, CSR adjacency, merge-sort sweeps, Fenwick
crossing counts, per-rank regression and track assignment (bounded to 512
jogs per gap), the sorted port assignment and the grid label index. The
quadratic parts left are bounded: transpositions and sifting by their shared
work budget, track assignment by its per-gap limit, and subgraph layout scans all nodes once per
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

## Sankey ordering

Sankey charts do not use the layered pipeline: `data_render.w` keeps
longest-path (or `sankey.nodeAlignment`) columns and orders each column by
weighted predecessor centers, alternating barycenter sweeps and adjacent
transpositions. Candidates are compared by a global, geometric crossing count
over every pair of ribbons whose x spans overlap, not only ribbons between the
same column pair, computed as merge-sort weighted inversions per stretch
between column edges. The whole relaxation runs under one work budget
(`MM_DATA_SANKEY_WORK_BUDGET`) that shortens the schedule for large charts
instead of skipping it. Details and measured results are in
[mermaid_data.md](mermaid_data.md).
