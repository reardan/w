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
Node styling: [Styles and themes](mermaid_styling.md). Labels: [Text layout](mermaid_text.md).

| Family / headers | Implemented core | Important remaining gaps | Example |
| --- | --- | --- | --- |
| Flowchart — `flowchart`, `graph` | Five directions, basic/stadium/subroutine/hexagonal/slanted shapes, labelled/chained edges, cycles, nested subgraphs, scoped directions, link styles, `<br>`/Markdown-string labels with emphasis and wrapping, `nodeSpacing`/`rankSpacing`/`curve` configuration | Additional shapes/edges, click actions, other rich text, dense routing and remaining configuration | [build.mmd](../../examples/mermaid/build.mmd) |
| ER — `erDiagram` | Entities/aliases, typed attributes and keys, all symbolic cardinalities and textual aliases, identifying/non-identifying relationships, link styles and optional force layout | Rich attribute text, additional configuration and crowded relationship routing | [orders.mmd](../../examples/mermaid/orders.mmd) |
| Class — `classDiagram` | Member compartments, annotations, UML endpoints, multiplicities, nested and comma-separated generic labels, backtick IDs, dotted namespaces, unique lollipop interfaces and notes; graphical rename/delete/add/link/drag for top-level classes | Interactive links, richer member labels and graphical editing inside namespaces | [classes.mmd](../../examples/mermaid/classes.mmd) |
| State — `stateDiagram`, `stateDiagram-v2` | Initial/final states, cross-scope transitions, composite states, concurrent `--` regions, choices, forks/joins, notes and scoped directions; graphical rename/delete/add/link/drag for top-level states | Per-state styling, rich labels and graphical editing inside composite states | [states.mmd](../../examples/mermaid/states.mmd) |

## Graphs, hierarchy and workflows

Details and exact restrictions: [Graph and workflow families](mermaid_graph_families.md).

| Family / headers | Implemented core | Important remaining gaps | Example |
| --- | --- | --- | --- |
| Requirement — `requirementDiagram` | Six requirement types, elements, validated properties, seven relation kinds, forward-reference validation | Rich Markdown and full configuration | [requirements.mmd](../../examples/mermaid/requirements.mmd) |
| Mindmap — `mindmap` | Single indentation tree, plain/square/rounded/circle/cloud/bang/hexagon nodes, icon names, CSS class names, subtree layout | Icon fonts, class-driven styling and ambiguous-indentation heuristics | [mindmap.mmd](../../examples/mermaid/mindmap.mmd) |
| Kanban — `kanban` | Columns/cards, generated or explicit IDs, assignment/ticket/priority metadata, column layout, `ticketBaseUrl` links, nested cards flattened into their column as upstream | Column metadata and other kanban configuration | [kanban.mmd](../../examples/mermaid/kanban.mmd) |
| TreeView — `treeView-beta` | Indented forests, quoted/Unicode labels, `tree`-command prefixes, `##` descriptions, source-ordered rows and ancestry connectors | Icons and classes | [treeview.mmd](../../examples/mermaid/treeview.mmd) |
| Ishikawa — `ishikawa-beta` | Problem head, alternating fishbone branches, indented causes/subcauses and ancestry | Exact upstream geometry, theme/configuration parity and richer labels | [ishikawa.mmd](../../examples/mermaid/ishikawa.mmd) |
| Cynefin — `cynefin-beta` | Five regions, quoted items, titles, domain transitions and transition legend | Organic boundaries, upstream layout/configuration parity and dense transition routing | [cynefin.mmd](../../examples/mermaid/cynefin.mmd) |
| Wardley — `wardley-beta` | Anchors/components, normalized coordinates, forward dependencies, custom evolution stages, `evolve` arrows, notes, pipelines, label offsets, build/buy/outsource and inertia decorators | Flows (`+>`, `limited by`), market/ecosystem/submap, annotations, accelerators and `evolve` renaming | [wardley.mmd](../../examples/mermaid/wardley.mmd) |
| GitGraph — `gitGraph` | Branch heads, commits/types/tags, checkout/switch, merges, cherry-picks with validated merge parents, branch order, LR/TB/BT layouts | Branch configuration and upstream geometry | [history.mmd](../../examples/mermaid/history.mmd) |
| Block — `block`, `block-beta` | Grid columns/spans, spaces, nested composites, the full block shape set, block arrows, labelled solid links and `style`/`classDef`/`class`/`linkStyle` | Dotted and thick links | [blocks.mmd](../../examples/mermaid/blocks.mmd) |
| Architecture — `architecture-beta` | Services/groups/junctions, built-in icons, all source/target port pairs and arrowheads | Icon packs, group-edge modifiers, alignment directives and port-direction placement constraints | [architecture.mmd](../../examples/mermaid/architecture.mmd) |
| Use case — `usecase-beta` | Actors, oval/rectangular cases, one-level boundaries, associations, include/extend and generalization validation | Metadata/stereotypes, JSON nodes, notes and rich labels | [usecase.mmd](../../examples/mermaid/usecase.mmd) |
| C4 — `C4Context`, `C4Container`, `C4Component`, `C4Dynamic`, `C4Deployment` | Typed cards and technology/descriptions, nested boundaries/deployment nodes, relations and numbered dynamic interactions | Named configuration arguments, directional relation macros, custom styling and upstream geometry | [c4.mmd](../../examples/mermaid/c4.mmd) |
| Swimlane — `swimlane-beta` | Responsibility lanes, five directions, basic flow shapes, labelled chains, handoffs and cycles | Nested lanes, additional shapes, styles and complex routing | [swimlanes.mmd](../../examples/mermaid/swimlanes.mmd) |
| Event modeling — `eventmodeling` | Timeframes/resetframes, five entity types, namespace lanes, inferred/explicit inputs and simple inline data | External data blocks, typed/nested payloads and richer annotations | [eventmodeling.mmd](../../examples/mermaid/eventmodeling.mmd) |

C4 is one family with all five headers implemented. Context/container/component
cards retain their type annotations; deployment adds nested deployment nodes;
dynamic relations are numbered in source order. The shared native card layout
is not an implementation of upstream C4 styling macros.

## Ordered narratives and schedules

Details: [Ordered diagrams](mermaid_narratives.md).

| Family / header | Implemented core | Important remaining gaps | Example |
| --- | --- | --- | --- |
| Sequence — `sequenceDiagram` | Participants/actors, aliases, lifecycle, message variants, notes, activations, integer numbering ranges, nested interaction fragments, colored participant boxes, `rect` highlights and `link`/`links` menus kept in the model | Participant objects, rendered link menus, `properties`/`details` and rich labels | [sequence.mmd](../../examples/mermaid/sequence.mmd) |
| Journey — `journey` | Sections, tasks, 1–5 scores, actor lists and source-ordered score plot | Upstream avatar/face rendering, themes and HTML labels | [journey.mmd](../../examples/mermaid/journey.mmd) |
| Timeline — `timeline` | Sections, ordinal period labels, multiple/continued events, `<br>` line breaks and chronological columns | Other rich labels, configuration and alternative layouts | [timeline.mmd](../../examples/mermaid/timeline.mmd) |
| Gantt — `gantt` | Validated dates in `YYYY`/`MM`/`DD`/`HH:mm` `dateFormat`s, minute/hour/day/week durations, `excludes`/`includes`/`weekend`, strftime `axisFormat`, fixed-date `todayMarker`, `click` hrefs kept in the model, sequential starts, forward/multiple dependencies, until endpoints and status/milestone marks | Timezones, month/year units, other moment.js tokens, `tickInterval`/`topAxis` and drawn links | [gantt.mmd](../../examples/mermaid/gantt.mmd) |
| ZenUML — `zenuml` | Participants/actors and `@Annotation` kinds, aliases, `new` creation, assignment replies, async/sync/nested and inline-bodied calls, returns, alternatives, loops, try/catch/finally and parallel/optional fragments | `@return`/`@Starter`, annotation icons, rich comments and styles | [zenuml.mmd](../../examples/mermaid/zenuml.mmd) |

Gantt schedules use their actual calendar semantics rather than generic graph
positions. ZenUML is the separately documented extension included in the native
scope; its parser does not depend on the upstream JavaScript extension package.

## Data diagrams

Details, numeric precision and family-specific budgets: [Data diagrams](mermaid_data.md).

| Family / headers | Implemented core | Important remaining gaps | Example |
| --- | --- | --- | --- |
| Pie — `pie` | Positive values, labels, `showData`, title, colored proportional slices and separated legend rows | Upstream theme parity (`pie1`–`pie12` are configurable) | [pie.mmd](../../examples/mermaid/pie.mmd) |
| Quadrant — `quadrantChart` | Normalized points, title, single/dual axis endpoints, hyphenated labels, point styles and forward classes | Broader chart configuration and rich labels | [quadrant.mmd](../../examples/mermaid/quadrant.mmd) |
| XY — `xychart-beta` | Categorical/numeric/inferred x axes, numeric y range, bars/lines, signed values and horizontal layout | Additional chart configuration (series follow `cScale*`) | [xy.mmd](../../examples/mermaid/xy.mmd) |
| Sankey — `sankey-beta` | Multiline quoted CSV, DAG validation, aggregation, smooth proportional ribbons and weighted ordering | Global crossing optimization and configuration | [sankey.mmd](../../examples/mermaid/sankey.mmd) |
| Radar — `radar-beta` | Axes/curves, positional/keyed values, ranges, graticules, ticks and legend | Smooth curves and custom per-series styles (series follow `cScale*`) | [radar.mmd](../../examples/mermaid/radar.mmd) |
| Treemap — `treemap-beta` | Indented groups/leaves, aggregate weights, squarified subdivision and `classDef`/`:::class` cells | `style` statements and per-depth palettes; tiny cells use a hierarchy key | [treemap.mmd](../../examples/mermaid/treemap.mmd) |
| Venn — `venn-beta` | One to three named sets, declared intersections, text nodes and explicit areas for one/two sets | Explicit sizes for three sets, styles and more than three sets | [venn.mmd](../../examples/mermaid/venn.mmd) |
| Packet — `packet`, `packet-beta` | Absolute/relative bit fields, title, configurable 1–128-bit rows, ascending/descending order and proportional widths | Custom field styles and other packet configuration | [packet.mmd](../../examples/mermaid/packet.mmd) |

## Grammar and agent workflows

| Family / headers | Implemented core | Important remaining gaps | Details and examples |
| --- | --- | --- | --- |
| Railroad — `railroad-beta`, `railroad-ebnf-beta`, `railroad-abnf-beta`, `railroad-peg-beta` | Owned grammar trees, EBNF exceptions, ABNF incremental rules/case semantics, numeric/repeat semantics, PEG ordered choice/predicates/classes | Extended escapes, configuration and exact curved geometry | [Reference](mermaid_railroad.md); [IR](../../examples/mermaid/railroad.mmd), [EBNF](../../examples/mermaid/railroad-ebnf.mmd), [ABNF](../../examples/mermaid/railroad-abnf.mmd), [PEG](../../examples/mermaid/railroad-peg.mmd) |
| Agentflow — `agentflow-beta` | Six roles, scalar node metadata, nested/global flows, connectors, sequence/reference/failure edges and directions | General YAML metadata, edge metadata/IDs, collapsed flows, algorithms, animation/curves and full shape inventory | [Reference](mermaid_agentflow.md); [agentflow.mmd](../../examples/mermaid/agentflow.mmd) |

Railroad rules currently require terminating semicolons in every notation;
references are not expanded. Agentflow metadata describes systems and remains
inspectable in the owned model; loading a diagram does not execute instructions,
connectors or external systems.

## Shared functionality and limits

| Surface | Current behavior | Remaining work |
| --- | --- | --- |
| Read/write | Lossless original UTF-8 source; separate canonical flow/ER model serializer | Canonical model serialization for families beyond flow/ER and themed/configured documents |
| Edit | Flow/ER/class/state node and edge selection, label editing, node/edge deletion, creation/connections, top-level dragging, click-to-place and keyboard movement; transactional undo/redo, grouped source typing and stable viewport | Group/nested-node movement, multi-selection, resizing, richer edge/attribute inspectors and graphical editing for the remaining families |
| View/export | Deterministic display lists, SVG export, layered crossing reduction, optional force layout, persisted flow/ER node positions, live edge updates and cursor-anchored zoom | Dense-layout quality, text metrics for families with their own renderers and upstream geometry parity |
| Markdown/frontmatter | Selectable Mermaid fences, surrounding prose preservation, original-source diagnostics, title, relaxed YAML frontmatter and `%%{init}%%` directives with themes, layout, flowchart, kanban and packet configuration | YAML lists/block scalars/anchors, directives after the header and arbitrary configuration |
| Accessibility | Escaped SVG titles/descriptions, visible titles, visible canvas selection, keyboard navigation/editing and non-drag move controls | Screen-reader integration and broader native accessibility interactions |
| Node styling | Flow/ER/class/state/requirement/use-case/block node classes and link styles, quadrant point and treemap cell classes, colors, transparent fill and precedence; graph labels with line breaks, bold/italic and wrapping | Per-family style parity, CSS, font configuration and other rich text |
| Themes | Native default/base/dark/forest/neutral palettes plus neo/redux approximations, primary/secondary/tertiary/cluster/edge-label/title variables with upstream-style derivation, `darkMode`, `pie1`–`pie12` and `cScale0`–`cScale11` | Upstream base palettes and CSS, the neo look, and remaining theme variables |
| Desktop/platforms | Linux X11 real-event editor workflow; Windows WGL cross-compile and Wine render smoke; macOS ARM64 Cocoa cross-compile; dynamic paths and guarded saves | Native Windows/macOS input/DPI/filesystem qualification, assistive technology testing and atomic concurrent-write conflict handling |
| Bounds | 1 MiB source limit plus family-specific node, edge, depth, metadata, data and grammar budgets | Larger workloads require explicit budget/layout work, not removal of checks |

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
| agentflow | 9 | 0 | 3 | 12 |
| architecture | 2 | 0 | 4 | 6 |
| block | 24 | 0 | 6 | 30 |
| c4 | 0 | 0 | 6 | 6 |
| class | 31 | 0 | 7 | 38 |
| cynefin | 3 | 0 | 0 | 3 |
| er | 22 | 0 | 3 | 25 |
| eventmodeling | 11 | 0 | 2 | 13 |
| flowchart | 35 | 2 | 79 | 116 |
| gantt | 3 | 0 | 8 | 11 |
| gitgraph | 13 | 0 | 23 | 36 |
| ishikawa | 1 | 0 | 0 | 1 |
| journey | 1 | 0 | 0 | 1 |
| kanban | 2 | 0 | 1 | 3 |
| mindmap | 10 | 2 | 3 | 15 |
| packet | 2 | 0 | 2 | 4 |
| pie | 3 | 0 | 1 | 4 |
| quadrant | 2 | 0 | 1 | 3 |
| radar | 2 | 0 | 1 | 3 |
| railroad | 14 | 0 | 0 | 14 |
| requirement | 6 | 0 | 3 | 9 |
| sankey | 4 | 0 | 4 | 8 |
| sequence | 29 | 2 | 11 | 42 |
| state | 19 | 0 | 3 | 22 |
| swimlane | 12 | 0 | 1 | 13 |
| timeline | 6 | 0 | 8 | 14 |
| treemap | 5 | 0 | 3 | 8 |
| treeview | 5 | 0 | 8 | 13 |
| usecase | 9 | 0 | 15 | 24 |
| venn | 7 | 0 | 1 | 8 |
| wardley | 12 | 0 | 7 | 19 |
| xychart | 4 | 0 | 4 | 8 |
| zenuml | 13 | 0 | 3 | 16 |
| **All** | **321** | **6** | **221** | **548** |

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
