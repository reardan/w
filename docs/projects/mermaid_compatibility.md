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

Details: [Flow/ER and UML compatibility](mermaid.md#flowchart-and-er-compatibility).
Node styling: [Styles and themes](mermaid_styling.md).

| Family / headers | Implemented core | Important remaining gaps | Example |
| --- | --- | --- | --- |
| Flowchart — `flowchart`, `graph` | Five directions, basic shapes, labelled/chained edges, cycles, nested subgraphs, scoped directions | Additional shapes/edges, click actions, rich text, dense routing and most configuration | [build.mmd](../../examples/mermaid/build.mmd) |
| ER — `erDiagram` | Entities/aliases, typed attributes and keys, all symbolic cardinalities and textual aliases, identifying/non-identifying relationships | Rich text, additional configuration, precise text metrics and crowded relationship routing | [orders.mmd](../../examples/mermaid/orders.mmd) |
| Class — `classDiagram` | Member compartments, annotations, UML endpoints, multiplicities, nested namespaces | Generics, escaped IDs, dotted namespaces, lollipop interfaces, notes and interactive links | [classes.mmd](../../examples/mermaid/classes.mmd) |
| State — `stateDiagram`, `stateDiagram-v2` | Initial/final states, transitions, composite states, choices, forks/joins and scoped directions | Concurrent regions, cross-scope transitions, notes and rich labels | [states.mmd](../../examples/mermaid/states.mmd) |

## Graphs, hierarchy and workflows

Details and exact restrictions: [Graph and workflow families](mermaid_graph_families.md).

| Family / headers | Implemented core | Important remaining gaps | Example |
| --- | --- | --- | --- |
| Requirement — `requirementDiagram` | Six requirement types, elements, validated properties, seven relation kinds, forward-reference validation | Styles/classes, rich Markdown and full configuration | [requirements.mmd](../../examples/mermaid/requirements.mmd) |
| Mindmap — `mindmap` | Single indentation tree, plain/rectangular/rounded/circular nodes, subtree layout | Icons/classes, cloud/bang/hexagon shapes and ambiguous-indentation heuristics | [mindmap.mmd](../../examples/mermaid/mindmap.mmd) |
| Kanban — `kanban` | Columns/cards, generated or explicit IDs, assignment/ticket/priority metadata, column layout | Nested cards, ticket URLs and custom configuration | [kanban.mmd](../../examples/mermaid/kanban.mmd) |
| TreeView — `treeView-beta` | Indented forests, quoted/Unicode labels, source-ordered rows and ancestry connectors | Tree-command prefixes, icons/classes and descriptions | [treeview.mmd](../../examples/mermaid/treeview.mmd) |
| Ishikawa — `ishikawa-beta` | Problem head, alternating fishbone branches, indented causes/subcauses and ancestry | Exact upstream geometry, theme/configuration parity and richer labels | [ishikawa.mmd](../../examples/mermaid/ishikawa.mmd) |
| Cynefin — `cynefin-beta` | Five regions, quoted items, titles, domain transitions and transition legend | Organic boundaries, upstream layout/configuration parity and dense transition routing | [cynefin.mmd](../../examples/mermaid/cynefin.mmd) |
| Wardley — `wardley-beta` | Anchors/components, normalized coordinates, forward dependencies, four evolution stages | Evolution arrows, notes, pipelines, decorators, alternate flows and custom axes | [wardley.mmd](../../examples/mermaid/wardley.mmd) |
| GitGraph — `gitGraph` | Branch heads, commits/types/tags, checkout/switch, merges and commit ancestry | Cherry-pick, branch order/configuration and non-LR layouts | [history.mmd](../../examples/mermaid/history.mmd) |
| Block — `block`, `block-beta` | Grid columns/spans, spaces, nested composites, basic shapes and labelled solid links | Block arrows, additional shapes and custom styles | [blocks.mmd](../../examples/mermaid/blocks.mmd) |
| Architecture — `architecture-beta` | Services/groups/junctions, built-in icons, all source/target port pairs and arrowheads | Icon packs, group-edge modifiers, alignment directives and port-direction placement constraints | [architecture.mmd](../../examples/mermaid/architecture.mmd) |
| Use case — `usecase-beta` | Actors, oval/rectangular cases, one-level boundaries, associations, include/extend and generalization validation | Metadata/stereotypes, JSON nodes, notes, styles and rich labels | [usecase.mmd](../../examples/mermaid/usecase.mmd) |
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
| Sequence — `sequenceDiagram` | Participants/actors, aliases, message variants, notes, activations, numbering and nested interaction fragments | Creation/destruction, participant objects, boxes, rect highlighting, links, numbering ranges and rich labels | [sequence.mmd](../../examples/mermaid/sequence.mmd) |
| Journey — `journey` | Sections, tasks, 1–5 scores, actor lists and source-ordered score plot | Upstream avatar/face rendering, themes and HTML labels | [journey.mmd](../../examples/mermaid/journey.mmd) |
| Timeline — `timeline` | Sections, ordinal period labels, multiple/continued events and chronological columns | Rich labels, configuration and alternative wrapping/layout | [timeline.mmd](../../examples/mermaid/timeline.mmd) |
| Gantt — `gantt` | Validated Gregorian dates, day/week durations, sequential starts, earlier-task dependencies and status/milestone marks | Other date formats/units, exclusions, multiple/forward dependencies, timezones, today settings and links | [gantt.mmd](../../examples/mermaid/gantt.mmd) |
| ZenUML — `zenuml` | Participants/actors, aliases, async/sync/nested calls, returns, alternatives, loops and parallel/optional fragments | Creation, assignment replies, annotations beyond Actor, try/catch/finally, inline bodies and rich comments | [zenuml.mmd](../../examples/mermaid/zenuml.mmd) |

Gantt schedules use their actual calendar semantics rather than generic graph
positions. ZenUML is the separately documented extension included in the native
scope; its parser does not depend on the upstream JavaScript extension package.

## Data diagrams

Details, numeric precision and family-specific budgets: [Data diagrams](mermaid_data.md).

| Family / headers | Implemented core | Important remaining gaps | Example |
| --- | --- | --- | --- |
| Pie — `pie` | Positive values, labels, `showData`, title and proportional slices | Many-small-slice label placement and upstream themes | [pie.mmd](../../examples/mermaid/pie.mmd) |
| Quadrant — `quadrantChart` | Normalized points, title, axis endpoints and quadrant labels | Point styles/classes and unquoted hyphens in axis labels | [quadrant.mmd](../../examples/mermaid/quadrant.mmd) |
| XY — `xychart-beta` | Categorical/numeric/inferred x axes, numeric y range, bars/lines, signed values and horizontal layout | Configuration and styled multi-series legends | [xy.mmd](../../examples/mermaid/xy.mmd) |
| Sankey — `sankey-beta` | Quoted CSV, DAG validation, aggregation and proportional ribbons | Multiline CSV, curved/crossing-optimized routing and configuration | [sankey.mmd](../../examples/mermaid/sankey.mmd) |
| Radar — `radar-beta` | Axes/curves, positional/keyed values, ranges, graticules, ticks and legend | Smooth curves/styles; keyed values require earlier axes | [radar.mmd](../../examples/mermaid/radar.mmd) |
| Treemap — `treemap-beta` | Indented groups/leaves, aggregate weights and proportional subdivision | Squarified layout and styles/classes; tiny cells use a hierarchy key | [treemap.mmd](../../examples/mermaid/treemap.mmd) |
| Venn — `venn-beta` | One to three named sets, declared two/three-set intersections and equal-size geometry | Explicit sizes, text nodes, styles and more than three sets | [venn.mmd](../../examples/mermaid/venn.mmd) |
| Packet — `packet`, `packet-beta` | Absolute/relative bit fields, title, 32-bit wrapping and proportional widths | Other word widths, descending bit order and styles | [packet.mmd](../../examples/mermaid/packet.mmd) |

## Grammar and agent workflows

| Family / headers | Implemented core | Important remaining gaps | Details and examples |
| --- | --- | --- | --- |
| Railroad — `railroad-beta`, `railroad-ebnf-beta`, `railroad-abnf-beta`, `railroad-peg-beta` | Owned grammar trees, terminals/references, sequences/choices, optional/repeated paths, ABNF numeric/repeat semantics, PEG ordered choice/predicates | EBNF exceptions, ABNF incremental rules/%s/%i/name folding, PEG character classes, configuration and exact curved geometry | [Reference](mermaid_railroad.md); [IR](../../examples/mermaid/railroad.mmd), [EBNF](../../examples/mermaid/railroad-ebnf.mmd), [ABNF](../../examples/mermaid/railroad-abnf.mmd), [PEG](../../examples/mermaid/railroad-peg.mmd) |
| Agentflow — `agentflow-beta` | Six roles, scalar node metadata, nested/global flows, connectors, sequence/reference/failure edges and directions | General YAML metadata, edge metadata/IDs, collapsed flows, algorithms, animation/curves and full shape inventory | [Reference](mermaid_agentflow.md); [agentflow.mmd](../../examples/mermaid/agentflow.mmd) |

Railroad rules currently require terminating semicolons in every notation;
references are not expanded. Agentflow metadata describes systems and remains
inspectable in the owned model; loading a diagram does not execute instructions,
connectors or external systems.

## Shared functionality and limits

| Surface | Current behavior | Remaining work |
| --- | --- | --- |
| Read/write | Original UTF-8 bytes retained, including invalid/unsupported syntax, comments, CRLF and Markdown envelope | Formatting and semantic AST-to-source serialization |
| Edit | Immutable UTF-8 byte-range edits, CLI replacement files, desktop source history and live reparsing | Structured model edits, direct diagram manipulation and richer source editing |
| View/export | Deterministic native display lists, SVG export, desktop pan/zoom/fit; failed parses suppress preview | Dense-layout quality, text measurement/wrapping and upstream geometry parity |
| Markdown/frontmatter | One Mermaid fence, surrounding prose preservation, original-source diagnostics, title and bounded themes | Multiple embedded diagrams, general YAML and arbitrary configuration |
| Accessibility | Escaped SVG titles/descriptions in statement parsers; visible frontmatter titles across families | Body directives in indentation families and broader native accessibility interactions |
| Node styling | Documented flow/ER/class/state style/class assignments, colors, transparent fill, stroke width and precedence | Per-family style parity, link styling, CSS, fonts and rich text |
| Themes | Native default/base/dark/forest/neutral palettes; six base color variables; common native/SVG resolution | Upstream CSS/palette derivation, categorical colors, redux/neo and arbitrary theme variables |
| Desktop/platforms | x64 Linux X11/OpenGL editor; x86/x64 library and CLI validation | Desktop qualification on other platforms, external-file change detection and longer editor paths |
| Bounds | 1 MiB source limit plus family-specific node, edge, depth, metadata, data and grammar budgets | Larger workloads require explicit budget/layout work, not removal of checks |

See [Use and library ownership](mermaid.md) for command syntax, UTF-8 edit rules,
atomic save semantics, scene/document lifetimes and the 127-byte editor path
field. See [Styles and themes](mermaid_styling.md) for exact values, precedence
and frontmatter indentation. Supported palettes are native approximations;
accepting a theme name does not imply upstream visual parity.

## Remaining completion criteria

The family-coverage milestone is complete. Compatibility work remains measurable
against the per-family gaps above: expand the pinned conformance corpus, close
syntax/semantic differences, improve routing and text metrics, extend supported
configuration/styling, implement structured/direct editing, and qualify additional
desktop platforms. Passing current tests and examples proves these bounded
subsets; it is not evidence that arbitrary Mermaid input will render unchanged.
