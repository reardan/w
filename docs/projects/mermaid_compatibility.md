# Native Mermaid compatibility matrix

**Family-level core coverage is implemented; full Mermaid compatibility is not.**
Every authoring family in the pinned Mermaid 12.2.0 inventory has a W-native
parser, semantic representation and renderer for the subset described below.
All supported families use the library/CLI source read/write/edit interfaces,
native desktop preview and SVG exporter. No Mermaid JavaScript engine is loaded.
The examples are runnable inputs, not declarations that every upstream example
or option is supported.

## Inventory baseline

The baseline is the upstream
[`mermaid@12.2.0` diagram registry](https://github.com/mermaid-js/mermaid/blob/mermaid%4012.2.0/packages/mermaid/src/diagram-api/diagram-orchestration.ts)
and its [syntax documentation](https://github.com/mermaid-js/mermaid/tree/mermaid%4012.2.0/packages/mermaid/src/docs/syntax).
The inventory groups the four railroad detectors as one grammar family and the
five C4 headers as one C4 family. That gives **32 authoring family groups** in the
registry. The native engine additionally implements the documented
[ZenUML extension](https://github.com/mermaid-js/mermaid/blob/mermaid%4012.2.0/packages/mermaid/src/docs/syntax/zenuml.md),
for **33 family groups** in this matrix.

Upstream `info`, `error` and malformed-frontmatter handlers are utilities, not
additional authoring families in this count. The ELK flowchart detector is an
alternative rendering backend for flowcharts; W does not run ELK. Header aliases,
C4 levels and railroad notations are listed explicitly rather than inflating the
family count. Future upstream releases need a new inventory and compatibility
review; this document does not promise automatic coverage of new syntax.

“Core” below means semantic parsing and meaningful native geometry. It does not
mean upstream parser parity, pixel-identical output, all configuration options,
or direct graphical editing. The linked family references define more detailed
restrictions and budgets.

## Foundation and UML

Details: [Flow/ER compatibility](mermaid.md#flowchart-and-er-compatibility) and
[UML additions and limits](mermaid_uml.md).
Node styling: [Styles and themes](mermaid_styling.md). Configuration: [Config reference](mermaid_config.md). Labels: [Text layout](mermaid_text.md).

| Family / headers | Implemented core | Important remaining gaps | Example |
| --- | --- | --- | --- |
| Flowchart — `flowchart`, `graph` | Five directions, every classic bracket shape plus the full named-shape inventory through `A@{ shape, label, icon, img, ... }` (cylinders, documents, stacked/lined/divided/tagged rectangles, braces, forks, flags, ...), labelled/chained edges with `&` groups, `<-->`/`o--o`/`x--x`/`~~~`/thick links and extended lengths, edge IDs with `animate`/`curve`, collapsed subgraphs, `click` hrefs/callbacks/tooltips/targets kept in the model and exported as safe SVG links (callbacks never run), cycles, nested subgraphs, scoped directions, link styles, `<br>`/Markdown-string labels with emphasis and wrapping, `nodeSpacing`/`rankSpacing`/`curve` configuration | Icon packs and remote images (drawn as placeholders), Font Awesome text, smooth-curve and animation fidelity (SMIL dash approximation), other rich text, upstream Dagre geometry parity (native layered layout with channel routing instead) and remaining configuration | [build.mmd](../../examples/mermaid/build.mmd) |
| ER — `erDiagram` | Entities/aliases, typed attributes and keys, all symbolic cardinalities and textual aliases, identifying/non-identifying relationships, link styles, optional force layout; channel-routed relationships with ports ordered along entity sides (parallel relationships on distinct ports) and collision-free labels ([layout](mermaid_layout.md)) | Rich attribute text, additional configuration, label placement beside the line rather than along it for very dense hubs | [orders.mmd](../../examples/mermaid/orders.mmd) |
| Class — `classDiagram` | Member compartments, annotations, UML endpoints, multiplicities, nested and comma-separated generic labels, backtick IDs, dotted namespaces, unique lollipop interfaces and notes; `link`/`click`/`callback` statements as safe SVG links and tooltips; member labels with visibility, `~T~` generics, parameter lists, `name(params) : Return` display and `$` static (underlined) / `*` abstract (italic) classifiers; graphical rename/delete/add/link/drag for top-level classes | Graphical editing inside namespaces | [classes.mmd](../../examples/mermaid/classes.mmd) |
| State — `stateDiagram`, `stateDiagram-v2` | Initial/final states, cross-scope transitions, composite states, concurrent `--` regions, choices, forks/joins, notes and scoped directions; graphical rename/delete/add/link/drag for top-level states | Rich labels and graphical editing inside composite states | [states.mmd](../../examples/mermaid/states.mmd) |

## Graphs, hierarchy and workflows

Details and exact restrictions: [Graph and workflow families](mermaid_graph_families.md).

| Family / headers | Implemented core | Important remaining gaps | Example |
| --- | --- | --- | --- |
| Requirement — `requirementDiagram` | Six requirement types, elements, validated properties, seven relation kinds, forward-reference validation | Rich Markdown and full configuration | [requirements.mmd](../../examples/mermaid/requirements.mmd) |
| Mindmap — `mindmap` | Single indentation tree, plain/square/rounded/circle/cloud/bang/hexagon nodes, native icon pictograms (no font download), CSS class names, upstream nearest-shallower-parent indentation, branch/depth colours, subtree layout, labels wrapped at `mindmap.maxNodeWidth` (200px) with measured widths | Class-driven styling and icon-pack glyph fidelity | [mindmap.mmd](../../examples/mermaid/mindmap.mmd) |
| Kanban — `kanban` | Columns/cards, generated or explicit IDs, assignment/ticket/priority metadata, column layout, `ticketBaseUrl` links, nested cards flattened into their column as upstream, column metadata and `label` overrides, repeated IDs, card/column titles wrapped at `kanban.sectionWidth` (200px) | Other kanban configuration | [kanban.mmd](../../examples/mermaid/kanban.mmd) |
| TreeView — `treeView-beta` | Indented forests, quoted/Unicode labels, `tree`-command prefixes, `##` descriptions, source-ordered rows and ancestry connectors, `icon(...)` pictograms, `showIcons` folder/file icons and filename maps, `:::` classes with `highlight`, row/line config and treeView theme colours | Extension icon maps (dotted YAML keys) and icon-pack glyphs | [treeview.mmd](../../examples/mermaid/treeview.mmd) |
| Ishikawa — `ishikawa-beta` | Upstream fishbone geometry: fish-head problem, 82° cause bones sharing a 500px length pool, alternating upper/lower pairs, alternating horizontal/diagonal sub-cause bones, 15-character label wrapping and arrowheads | Theme/configuration parity | [ishikawa.mmd](../../examples/mermaid/ishikawa.mmd) |
| Cynefin — `cynefin-beta` | Upstream 800×600 field: unstroked quadrants, seeded wavy fold/boundary, Clear/Chaotic cliff, central Confusion ellipse (three badges plus "+N more"), domain models/practices, item badges and quadratic transitions with labels (self-loops skipped); dense transitions routed edge-to-edge around each domain's text, reverse/repeated transitions nested apart, curves kept out of other domains' text and labels collision-free | Theme/configuration parity (including `seed`); transitions crossing each other are reduced, not minimized | [cynefin.mmd](../../examples/mermaid/cynefin.mmd) |
| Wardley — `wardley-beta` | Anchors/components, normalized coordinates, forward dependencies, custom evolution stages, `evolve` arrows, notes, pipelines, label offsets, build/buy/outsource/market and inertia decorators, `size`, `@` stage boundaries and two-line stages, flows (`+>`, `+<`, `+<>`, labelled `+'x'>`), dashed and `; label` links, annotations with legend, accelerators/deaccelerators | `limited by`, `(ecosystem)`, `submap`, `evolve` renaming (absent from 12.2.0's grammar) and trend indicators | [wardley.mmd](../../examples/mermaid/wardley.mmd) |
| GitGraph — `gitGraph` | Branch heads, commits/types/tags, checkout/switch, merges, cherry-picks with validated merge parents, branch order, LR/TB/BT layouts, commit spacing from measured label widths | Branch configuration and upstream geometry | [history.mmd](../../examples/mermaid/history.mmd) |
| Block — `block`, `block-beta` | Grid columns/spans, spaces, nested composites, the full block shape set, block arrows, labelled solid links and `style`/`classDef`/`class`/`linkStyle` | Dotted and thick links | [blocks.mmd](../../examples/mermaid/blocks.mmd) |
| Architecture — `architecture-beta` | Services/groups/junctions, built-in icons and `pack:name` icons with a native glyph/unknown-icon fallback (never fetched), all port pairs and arrowheads, `{group}` edge endpoints, `align row`/`align column`, port-pair grid placement with elbow routing | fcose force-directed geometry, edge labels and bundled icon packs | [architecture.mmd](../../examples/mermaid/architecture.mmd) |
| Use case — `usecase-beta` | Actors (normal/hollow/awesome/icon, business), oval/rectangular cases, quoted declarations, one-level rect/package boundaries, `@{}` metadata, `<<stereotypes>>`, notes, JSON tables, Markdown/entity labels, all association operators with lengths, labels and edge IDs, include/extend/generalization validation, classes/styles on nodes and edges | ELK layout, numbered boundary palettes and animated SVG edges | [usecase.mmd](../../examples/mermaid/usecase.mmd) |
| C4 — `C4Context`, `C4Container`, `C4Component`, `C4Dynamic`, `C4Deployment` | Typed cards, positional and `$name=` arguments, nested boundaries/deployment nodes, `Rel`/`BiRel`/`Rel_Back`/`RelIndex` and directional `Rel_U/D/L/R` macros, `UpdateElementStyle`/`UpdateRelStyle`/`UpdateLayoutConfig`, upstream row layout, palette and shapes | Sprites, tags/legends (`AddElementTag`/`AddRelTag`), `Lay_*` and link rendering | [c4.mmd](../../examples/mermaid/c4.mmd) |
| Swimlane — `swimlane-beta` | Responsibility lanes with nested sub-lanes (32 levels), five directions, every flowchart bracket shape and the `@{ shape }` catalogue, `&` groups, inline/pipe labels, thick/dotted links, `x`/`o`/bidirectional heads, `classDef`/`class`/`style`/`linkStyle`, handoffs and cycles; orthogonal links through the free channels between rank columns and clear tracks between lanes (no segment crosses a step or nested-lane title), 8px slots for parallel links, labels placed clear of steps and other labels | Link-link crossings are not minimized (only separated); routing does not reorder steps | [swimlanes.mmd](../../examples/mermaid/swimlanes.mmd), [swimlanes-nested.mmd](../../examples/mermaid/swimlanes-nested.mmd) |
| Event modeling — `eventmodeling` | Timeframes/resetframes (1–3 digit ids), five entity types, namespace lanes, inferred/explicit inputs, `[[ref]]` external data blocks, backtick data types, nested inline `{…}`/quoted payloads, `data`/`note`/`gwt`/`entity` statements and `/* */`/`//` comments; links use the swimlane channel/track router | Rich rendering of `figma`/`salt`/`html`/`md` payloads (shown as text) | [eventmodeling.mmd](../../examples/mermaid/eventmodeling.mmd), [eventmodeling-data.mmd](../../examples/mermaid/eventmodeling-data.mmd) |

C4 is one family with all five headers implemented. Context/container/component
cards retain their type annotations; deployment adds nested deployment nodes;
dynamic relations are numbered in source order. A dedicated C4 renderer follows
the upstream statement-order row layout and fixed palette, and implements the
`UpdateElementStyle`/`UpdateRelStyle`/`UpdateLayoutConfig` macros.

## Ordered narratives and schedules

Details: [Ordered diagrams](mermaid_narratives.md).

| Family / header | Implemented core | Important remaining gaps | Example |
| --- | --- | --- | --- |
| Sequence — `sequenceDiagram` | Participants/actors, `@{ "type": ... }` participant objects (boundary/control/entity/database/collections/queue symbols), aliases, lifecycle, message variants including central `()` connections, entity codes (`#9829;`, `#infin;`), notes, activations, integer numbering ranges, nested interaction fragments, colored participant boxes, `rect` highlights, `link`/`links` menus rendered as SVG link boxes, and `properties`/`details` kept in the model | Half-arrows, property-driven icons/CSS classes and other rich labels | [sequence.mmd](../../examples/mermaid/sequence.mmd) |
| Journey — `journey` | Sections, tasks, 1–5 scores, actor lists, source-ordered score plot with upstream score faces, coloured actor avatars and legend | Theme-driven section colours and HTML labels | [journey.mmd](../../examples/mermaid/journey.mmd) |
| Timeline — `timeline` | Sections, ordinal period labels, multiple/continued events, `<br>` line breaks, chronological columns, `LR`/`TD` layouts, multicolour sections/periods and `disableMulticolor`; LR period/event text wraps inside `timeline.width` columns (a single wider word widens the column) | Other rich labels; TD layout does not wrap | [timeline.mmd](../../examples/mermaid/timeline.mmd) |
| Gantt — `gantt` | Validated dates in moment.js `dateFormat`s (incl. `Z` offsets as UTC, `X`/`x`, `A`, `Do`, `MMM`), ms–year durations (calendar months), `excludes`/`includes`/`weekend`, d3 `axisFormat`, `tickInterval`/`weekday`, `topAxis`, compact `displayMode`, `vert` markers, `inclusiveEndDates`, fixed-date `todayMarker`, `click` hrefs kept in the model, sequential starts, forward/multiple dependencies, until endpoints and status/milestone marks; compact bar labels inside fitting bars or beside them, centered tick labels | Years before 1970, week/era tokens, click callbacks and local-time display (upstream 12.2.0 draws no dependency links either) | [gantt.mmd](../../examples/mermaid/gantt.mmd) |
| ZenUML — `zenuml` | Participants/actors and `@Annotation` kinds with Boundary/Control/Entity/Database/Collections/Queue symbols, `@Starter`, `@return`/`@reply` dashed replies, aliases, `new` creation (with or without arguments), assignment replies, async/sync/nested and inline-bodied calls, returns, alternatives, loops, try/catch/finally and parallel/optional fragments, `//` Markdown comments above messages and fragments | Icons for other annotation kinds and styles | [zenuml.mmd](../../examples/mermaid/zenuml.mmd) |

Gantt schedules use their actual calendar semantics rather than generic graph
positions. ZenUML is the separately documented extension included in the native
scope; its parser does not depend on the upstream JavaScript extension package.

## Data diagrams

Details, numeric precision and family-specific budgets: [Data diagrams](mermaid_data.md).

| Family / headers | Implemented core | Important remaining gaps | Example |
| --- | --- | --- | --- |
| Pie — `pie` | Positive values, labels, `showData`, title, colored proportional slices, legend rows from measured widths, and outside labels with leader lines for wedges too thin for an inside label (cluster-spread per side, never overlapping; the legend moves clear) | Upstream theme parity (`pie1`–`pie12` are configurable) | [pie.mmd](../../examples/mermaid/pie.mmd) |
| Quadrant — `quadrantChart` | Normalized points, title, single/dual axis endpoints, hyphenated labels, point styles and forward classes; wrapped quadrant titles, measured right-aligned axis labels, point labels flipped inside the plot | Broader chart configuration and rich labels | [quadrant.mmd](../../examples/mermaid/quadrant.mmd) |
| XY — `xychart-beta` | Categorical/numeric/inferred x axes, numeric y range, bars/lines, signed values and horizontal layout; measured axis labels (values right-aligned on the axis, categories wrapped to their band) | Additional chart configuration (series follow `cScale*`) | [xy.mmd](../../examples/mermaid/xy.mmd) |
| Sankey — `sankey-beta` | Multiline quoted CSV, DAG validation, aggregation, smooth proportional ribbons, global node ordering (alternating barycenter sweeps keeping the fewest value-weighted crossings, deterministic) and ribbon slots in far-end order | Crossings of ribbons spanning different column pairs are not counted; remaining configuration | [sankey.mmd](../../examples/mermaid/sankey.mmd) |
| Radar — `radar-beta` | Axes/curves, positional/keyed values, ranges, graticules, ticks, legend, and upstream smooth closed curves on circle graticules (`radar.curveTension`, default 0.17) | Remaining radar configuration parity (see the configuration reference) | [radar.mmd](../../examples/mermaid/radar.mmd), [radar-smooth.mmd](../../examples/mermaid/radar-smooth.mmd) |
| Treemap — `treemap-beta` | Indented groups/leaves, aggregate weights, squarified subdivision and `classDef`/`:::class` cells | `style` statements and per-depth palettes; tiny cells use a hierarchy key | [treemap.mmd](../../examples/mermaid/treemap.mmd) |
| Venn — `venn-beta` | One to eight named sets, declared intersections, text nodes and explicit areas; three sized sets and four or more sets use an area-proportional pairwise layout with region-aware labels | Higher-order region areas are labeled but not fitted | [venn.mmd](../../examples/mermaid/venn.mmd), [venn-sizes.mmd](../../examples/mermaid/venn-sizes.mmd) |
| Packet — `packet`, `packet-beta` | Absolute/relative bit fields, title, configurable 1–128-bit rows, ascending/descending order and proportional widths | Custom field styles and other packet configuration | [packet.mmd](../../examples/mermaid/packet.mmd) |

## Grammar and agent workflows

| Family / headers | Implemented core | Important remaining gaps | Details and examples |
| --- | --- | --- | --- |
| Railroad — `railroad-beta`, `railroad-ebnf-beta`, `railroad-abnf-beta`, `railroad-peg-beta` | Owned grammar trees, EBNF exceptions, ABNF incremental rules/case semantics, numeric/repeat semantics, PEG ordered choice/predicates/classes, the upstream escape set per notation, upstream arc-radius geometry, linked rule references and optional semicolons at rule boundaries | `railroad` configuration beyond separations, markers, colors and stroke width; theme parity | [Reference](mermaid_railroad.md); [IR](../../examples/mermaid/railroad.mmd), [EBNF](../../examples/mermaid/railroad-ebnf.mmd), [ABNF](../../examples/mermaid/railroad-abnf.mmd), [PEG](../../examples/mermaid/railroad-peg.mmd), [escapes](../../examples/mermaid/railroad-escapes.mmd) |
| Agentflow — `agentflow-beta` | Six roles, YAML metadata (nested maps, lists, block scalars, JSON-schema typing), nested/global flows, connectors, edge IDs and `id@{…}` edge metadata, collapsed flows, `algorithm`, static `curve` rendering, the full shape inventory with coercion, sequence/reference/failure edges and directions | `animate`/`animation` are kept as metadata only (static renderer); `agentflow.*` configuration keys | [Reference](mermaid_agentflow.md); [agentflow.mmd](../../examples/mermaid/agentflow.mmd), [agentflow-collapsed.mmd](../../examples/mermaid/agentflow-collapsed.mmd) |

Railroad rules may omit their terminating semicolon when the next rule head
starts a new line (upstream requires it; every grammar upstream accepts keeps
its meaning). References to rules of the same diagram link to that rule's row
in SVG; like upstream they are drawn as boxes, never inlined, so recursive
grammars stay finite. Agentflow metadata describes systems and remains
inspectable in the owned model; loading a diagram does not execute instructions,
connectors or external systems.

## Shared functionality and limits

| Surface | Current behavior | Remaining work |
| --- | --- | --- |
| Read/write | Lossless original UTF-8 source; separate canonical flow/ER model serializer | Canonical model serialization for families beyond flow/ER and themed/configured documents |
| Edit | Flow/ER/class/state node and edge selection, label editing, node/edge deletion, creation/connections, top-level dragging, click-to-place and keyboard movement; transactional undo/redo, grouped source typing and stable viewport | Group/nested-node movement, multi-selection, resizing, richer edge/attribute inspectors and graphical editing for the remaining families |
| View/export | Deterministic display lists, SVG export, layered layout with rank promotion, dummy-node chains, barycenter + transposition + sifting crossing reduction, neighbor-aligned coordinates and channel routing between ranks with ordered tracks (drawn crossings equal the order's rank-to-rank crossings; no edge through an unrelated node box, no collinear overlaps of unrelated edges), collision-avoiding edge labels, optional force layout, persisted flow/ER node positions (overriding layout routes), live edge updates and cursor-anchored zoom ([layout](mermaid_layout.md)); family renderers (data charts, sequence/journey/gantt/timeline, gitGraph, block, kanban/mindmap, UML notes, C4) size and wrap text from the shared per-glyph metrics; Sankey crossing relaxation, swimlane/event-model orthogonal routing, Cynefin dense transitions and pie outside labels | Upstream geometry parity, routing for edges into nested subgraph members and same-rank edges, per-glyph metrics beyond Latin-1/CJK/emoji widths |
| Markdown/frontmatter | Selectable Mermaid fences, surrounding prose preservation, original-source diagnostics, title, bounded YAML frontmatter (block/flow lists, block scalars with chomping, anchors/aliases/merge keys, escapes) and `%%{init}%%`/`%%{initialize}%%`/`%%{wrap}%%` directives anywhere with upstream precedence; themes, layout, flowchart, kanban, packet and per-family sequence, gantt, timeline, xyChart, sankey, radar, gitGraph, railroad, requirement and C4 keys ([config reference](mermaid_config.md)); unknown keys ignored deterministically | YAML tags, complex keys and multi-line plain or quoted scalars; font/CSS keys; the per-family keys listed as ignored in the config reference |
| Accessibility | Escaped SVG titles/descriptions, visible titles, visible canvas selection, keyboard navigation/editing and non-drag move controls; the editor canvas as a semantic list of nodes, groups and edges (role, label, "edge from A to B, label x" description, bounds, selected/focused state) published to AT-SPI, UI Automation and opt-in NSAccessibility, with assistive focus/select reaching the selection; qualified with real at-spi2-core 2.52 and headless Orca 46.1 (speech of the canvas, nodes and edges on GrabFocus, SelectChild, Tab and Shift+Tab) and with wine's UI Automation client | Narrator, NVDA and VoiceOver runs on real Windows/macOS (pending; [checklist](mermaid_desktop_qualification.md)); braille; accessible on-canvas label editing, multi-selection and live announcements of edit results; canvas items for families without node-aligned scenes |
| Node styling | `style`/`classDef`/`class`/`:::` across flow, ER, class, state, requirement, use-case, swimlane and block diagrams, mindmap/TreeView classes, treemap/Venn/packet/radar style rules, link styles, dotted/thick block links, C4 style-argument mapping; the CSS subset (fill, stroke, color, stroke-width, stroke-dasharray, opacity, fill-opacity, font-weight/style/size/family, rx/ry) and `.class` `themeCSS`; `fontFamily`/`fontSize` driving metrics; rich labels (line breaks, Markdown, bold/italic, wrapping) in graphs, ER attributes, requirements, sequence, journey, timeline and use case | Selectors beyond `.class`, other CSS properties, native font loading, TreeView icons |
| Themes | Upstream mermaid@12.2.0 values for all eleven themes (default/base/dark/forest/neutral, neo, redux families), the neo look (drop shadow, gradient outlines), theme font size and stroke width, 82 variables with upstream derivation and `darkMode`, including note/actor/signal, Gantt task/grid/section, `git0`–`git7`, `venn1`–`venn8`, ER row and gradient variables | Hand-drawn look, upstream theme font family, redux SVG filters |
| Desktop/platforms | Linux X11 real-event workflows under Xvfb (pointer editing, keyboard-only edit/undo/redo chains in flowchart, ER, class and state, external change, Keep mine, reload and deletion); Windows WGL cross-compile, Wine render smoke and compare-and-swap saves under wine; macOS ARM64 Cocoa cross-compile with and without the accessibility companion; disk polling with Reload from disk / Keep mine; compare-and-swap saves (temp file, claim by rename, no-replace link) that never overwrite a concurrent writer | Native Windows and macOS runs are pending: input, IME, clipboard, DPI/Retina scaling, NTFS/APFS/cloud-folder saves and screen readers ([checklist](mermaid_desktop_qualification.md)) |
| Bounds | 1 MiB source limit plus family-specific node, edge, depth, metadata, data and grammar budgets; flowchart and ER: 4,096 nodes, 8,192 edges and 16,384 ER attributes, measured at 4,000 nodes in under 0.6 s ([layout](mermaid_layout.md)); other graph families 1,024 nodes/edges; force layout 1,024 nodes | Larger budgets for the other families need the same measurement work, not removal of checks |

See [Use and library ownership](mermaid.md) for command syntax, UTF-8 edit rules,
atomic save semantics, scene/document lifetimes and editor conflict handling. See [Styles and themes](mermaid_styling.md) for exact values, precedence
and frontmatter indentation. Supported palettes are native approximations;
accepting a theme name does not imply upstream visual parity.

## Conformance corpus

[`tests/mermaid_corpus/`](../../tests/mermaid_corpus/README.md) vendors every
Mermaid code block of the pinned `mermaid@12.2.0` syntax documentation (the 33
sidebar pages plus `railroad.md`; MIT, attribution in the corpus README) as one
`.mmd` file per example, grouped by detected family. `./wbuild
mermaid_corpus_test` (part of `./wbuild tests`) reads each example through the
same path as `wmermaid` (frontmatter, `%%{init}%%`, fences), renders it and
exports SVG, and compares the outcome with `tests/mermaid_corpus/manifest.txt`:
*supported* parses and renders a non-empty scene and SVG; *partial* parses but
renders nothing, or renders with a known difference recorded as a note;
*unsupported* is rejected with the recorded diagnostic. Regressions and newly
accepted examples both fail the test until `./wbuild mermaid_corpus_update`
rewrites the manifest and the table below (notes are preserved). Counts measure
acceptance, not visual parity: a *supported* example renders, but may still
differ from upstream in layout or detail.

<!-- corpus-counts:begin -->

| Family | Supported | Partial | Unsupported | Total |
| --- | ---: | ---: | ---: | ---: |
| agentflow | 11 | 0 | 1 | 12 |
| architecture | 6 | 0 | 0 | 6 |
| block | 26 | 0 | 4 | 30 |
| c4 | 6 | 0 | 0 | 6 |
| class | 38 | 0 | 0 | 38 |
| cynefin | 3 | 0 | 0 | 3 |
| er | 23 | 0 | 2 | 25 |
| eventmodeling | 13 | 0 | 0 | 13 |
| flowchart | 111 | 4 | 1 | 116 |
| gantt | 10 | 0 | 1 | 11 |
| gitgraph | 34 | 0 | 2 | 36 |
| ishikawa | 1 | 0 | 0 | 1 |
| journey | 1 | 0 | 0 | 1 |
| kanban | 3 | 0 | 0 | 3 |
| mindmap | 15 | 0 | 0 | 15 |
| packet | 4 | 0 | 0 | 4 |
| pie | 4 | 0 | 0 | 4 |
| quadrant | 3 | 0 | 0 | 3 |
| radar | 3 | 0 | 0 | 3 |
| railroad | 14 | 0 | 0 | 14 |
| requirement | 6 | 0 | 3 | 9 |
| sankey | 8 | 0 | 0 | 8 |
| sequence | 42 | 0 | 0 | 42 |
| state | 22 | 0 | 0 | 22 |
| swimlane | 13 | 0 | 0 | 13 |
| timeline | 14 | 0 | 0 | 14 |
| treemap | 8 | 0 | 0 | 8 |
| treeview | 12 | 0 | 1 | 13 |
| usecase | 24 | 0 | 0 | 24 |
| venn | 8 | 0 | 0 | 8 |
| wardley | 19 | 0 | 0 | 19 |
| xychart | 8 | 0 | 0 | 8 |
| zenuml | 16 | 0 | 0 | 16 |
| **All** | **529** | **4** | **15** | **548** |

<!-- corpus-counts:end -->

To review a future upstream bump, re-run `python3 -I
tools/mermaid_corpus_extract.py --tag mermaid@<new>` (after adding any new
syntax pages to its `DOCS` table), then `./wbuild mermaid_corpus_update`, and
review the corpus diff: new and renumbered examples appear in `index.txt`,
their outcomes in `manifest.txt`, and family totals in this table. New
unsupported examples are the inventory of syntax the bump introduced; update the
family rows above and the inventory baseline accordingly.

## Remaining completion criteria

The family-coverage milestone is complete. Compatibility work remains measurable
against the per-family gaps above: expand the pinned conformance corpus, close
syntax/semantic differences, improve routing and text metrics, extend supported
configuration/styling, implement structured/direct editing, and qualify additional
desktop platforms. Passing current tests and examples proves these bounded
subsets; it is not evidence that arbitrary Mermaid input will render unchanged.

## Follow-up implementation status

The first implementation batch for [#706](https://github.com/reardan/w/issues/706)
adds selected Markdown diagrams, flow/ER canonical serialization, structured
flowchart additions, conflict-aware editor saves, force layout, crossing reduction,
expanded graph/UML/grammar/scheduling syntax, and data-chart geometry/styling.
The rows above describe the resulting supported subsets. The tracking issue
remains open: broader per-family semantics, rich labels, themes/configuration,
precise text metrics and native desktop-platform qualification remain.

The graphical-editing workstream adds flow/ER canvas selection, top-level node
dragging, keyboard nudges and click-to-place, label edits, node/edge deletion, ER
creation/connections, grouped typing undo and source-preserving edit transactions.
Manual coordinates survive save/reopen and SVG export. Its real-window workflow
exercises drag/cancel, rename/delete, undo/redo and save/reopen. Windows/macOS
compile targets now run in the suite; Wine rendering is smoke-tested separately.
Graphical editing is still bounded to flow/ER: group/nested-node movement,
multi-selection, resize, rich relationship/attribute inspectors and other-family
editing remain. These are narrower than the original blanket dragging/deletion
gap; they must not be represented as full graphical-editor completion.

The second batch adds comma-separated class generic parameters, concurrent
state regions, mindmap cloud/bang/hexagon shapes with icon and class
decorations, and sequence participant boxes with `rect` highlights. CSS
`rgb()`/`rgba()` colors are accepted where those sequence constructs take a
color; `style`/`classDef` properties still use the documented subset.

The third batch extends graphical editing to class and state diagrams; adds
shared multi-line label layout (`<br>`, multi-line Markdown strings, bold/italic
emphasis, 200px wrapping and per-glyph metrics) for the shared graph renderer;
adds `%%{init}%%` directives, relaxed frontmatter, derived theme variables,
categorical palettes and flowchart spacing/curve configuration; and fills Gantt,
ZenUML, sequence, timeline, Wardley, Kanban, Block, TreeView and Treemap gaps
listed in the rows above. Requirement/use-case editing, editing inside groups,
font configuration and text metrics for families with their own renderers remain.
