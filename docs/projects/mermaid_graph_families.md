# Native graph and hierarchy Mermaid families

The parser syntax reference is Mermaid **12.2.0**, pinned to the upstream
[`mermaid@12.2.0`](https://github.com/mermaid-js/mermaid/tree/mermaid%4012.2.0)
tag. These are native W models and layouts and use the existing lossless source,
CLI, source editor, preview, and SVG interfaces. Unsupported syntax produces a
positioned diagnostic and suppresses the preview.

## Delivered subsets

- **Requirement diagrams:** all six SysML requirement types and elements;
  validated property names, risk and verification method enums; all seven
  relationship kinds in either arrow direction; forward references validated
  against declarations. Requirement fields render in compartments with type
  annotations. Containment uses a circle-plus endpoint and other relationships
  use labelled dashed dependency arrows. Node styles/classes and link styles are
  supported; rich Markdown and broader configuration remain incomplete.
- **Mindmaps:** a single indentation-based tree with plain text, `[square]`,
  `(rounded)`, `((circle))`, `)cloud(`, `))bang((` and `{{hexagon}}` labels. A
  dedicated subtree-height layout keeps sibling branches separate. Nesting is
  bounded to 64 levels. A `::icon(name)` line attaches one icon name to the
  previous node; icon fonts are not bundled, so the name renders as a badge row.
  `:::a b` classes, trailing a node or on their own line, attach to the previous
  node and are kept in the owned model as external CSS class names (mindmaps
  have no `classDef`, so they do not change native colours). Indentation must
  return to an existing level; the upstream ambiguous-indentation heuristic is
  not applied.
- **Kanban:** indentation-based columns and cards, explicit or generated IDs,
  assigned/ticket/priority metadata, validated priorities. Columns contain their
  cards and metadata in a dedicated column layout. Frontmatter
  `config: kanban: ticketBaseUrl: 'https://…/#TICKET#'` turns each card's
  `ticket:` line into an SVG `<a href>` link: the first `#TICKET#` is
  replaced by the percent-encoded ticket (a base without the marker is used
  as is), and only `http://`/`https://` bases are accepted. Deeper indented
  lines are cards of the enclosing column, as upstream `getSection` flattens
  them; there are no subcards. Metadata on columns, other `kanban` settings
  (`sectionWidth`, …) and rendering cards without their metadata are not yet
  supported; unknown `kanban` settings are diagnosed.

Tests cover semantic structures, geometry, lossless writing, forward references,
errors, and every byte-prefix of representative inputs. Tests run on x86 and
x64, including the guard allocator's leak checks.

- **TreeView:** indentation-based forests, quoted or plain Unicode labels,
  source-order rows and orthogonal ancestry connectors. Lines pasted from the
  `tree` command (`├── `, `└── `, `│   `, with plain or NBSP padding, mixed
  freely with indented lines) take their depth from the branch glyph's column
  plus four; bare `│` lines are ignored and a glyph prefix without a branch
  marker is diagnosed. `label ## description` attaches a description that
  renders muted after the label. Icons and `:::` classes remain unsupported
  and produce diagnostics.
- **Ishikawa:** problem head, first-level cause branches alternating around a
  spine, indented subcauses with ancestry connectors. Physical indentation
  carries hierarchy; input and nesting are bounded.
- **Cynefin:** all five domain regions, quoted items, optional title and labelled
  domain transitions. Confusion occupies the centre between quadrant rows.
  Native regions use rectangular boundaries instead of upstream organic curves.
- **Wardley:** anchors/components at validated visibility/evolution coordinates,
  a title, forward-resolved dependencies and four labelled evolution stages.
  Coordinates use bounded thousandths. `evolution A -> B -> C -> D` renames
  the four stages (exactly four). After a component's `[visibility,
  evolution]`, any order of `label [dx, dy]` (integers within ±999),
  `(build)`/`(buy)`/`(outsource)` (a shaded halo) and `inertia`/`(inertia)`
  (a bar on the evolution side) is accepted; repeats are diagnosed.
  `evolve Name 0.8` draws a red dashed arrow to a red ghost of the component
  at the new evolution. `note "text" [v, e]` (or unquoted text) places a free
  label. `pipeline Name [low, high]` and/or a following `{ component Child
  [evolution] … }` block (brace on the same or next line) draws a band under
  the component and places sub-components at its visibility; a range is
  inferred from the children when omitted and children outside an explicit
  range fail. Pipelines must belong to a top-level component. `evolve A->B`
  renaming, OnlineWardleyMaps flows (`+>`, `+<>`, `limited by`), `market`/
  `ecosystem`/`submap` types, annotations, `size` and `accelerator` remain
  unsupported and produce diagnostics.

- **GitGraph:** commit IDs, normal/reverse/highlight shapes, tags, branch
  creation, checkout/switch and merge commits with two parents. Branch heads
  determine commit ancestry; a dedicated time/lane layout shows history.
  Duplicate IDs/branches, unknown checkouts, empty/self/same-head merges fail.
  The layout supports LR, TB and BT. `branch name order: N` sorts explicitly
  ordered branches after unspecified branches, with stable ties. `cherry-pick
  id: "source"` creates a new commit on the current branch and retains source
  metadata without introducing false merge ancestry. Merge picks require an
  immediate `parent: "id"`; tags are supported. Missing/same-branch source
  commits and invalid merge parents are diagnosed. Custom branch configuration
  remains unsupported.
- **Block:** source-ordered grids, up to 64 columns, column spans, empty spaces,
  nested composites (up to 32 levels) and labelled solid links. Node shapes:
  rectangle `[ ]`, rounded `( )`, stadium `([ ])`, subroutine `[[ ]]`,
  cylinder `[( )]`, circle `(( ))`, double circle `((( )))`, asymmetric
  `> ]`, rhombus `{ }`, hexagon `{{ }}`, parallelograms `[/ /]`/`[\ \]` and
  trapezoids `[/ \]`/`[\ /]`. Block arrows `id<["label"]>(dir)` accept
  `right`, `left`, `up`, `down`, `x` (both horizontal) and `y` (both
  vertical) and take spans like other blocks. `style`, `classDef`, `class`
  and inline `:::class` use the shared style subset (fill, stroke, color,
  stroke-width) on blocks and composites, and `linkStyle` on links; styling
  an undeclared block fails. Span overflow and malformed blocks fail
  explicitly. Column widths grow by actual content, so one large label does
  not multiply across every column. Dotted/thick links and block-arrow
  geometry beyond the six directions remain unsupported.

- **Architecture:** services, nested groups, junctions, all sixteen
  source/target port pairs, arrowheads at either end, and explicit
  containment/reference validation (`architecture.w`).
  - *Icons:* the five built-in names plus iconify-style `pack:name`
    references (`logos:aws-lambda`). Icon packs are never fetched or
    bundled. The native fallback draws the closest built-in glyph when the
    icon name contains a recognisable word (`aurora`, `db`, `sql`, `rds` ->
    database; `s3`, `glacier`, `bucket`, `storage` -> disk; `ec2`, `lambda`,
    `compute`, `container` -> server; `gateway`, `cdn`, `network` ->
    internet; `cloud`), otherwise a rounded unknown-icon tile marked `?`.
    Group titles keep the icon name as a `[pack:name]` prefix. Any other
    icon text is diagnosed.
  - *`{group}` endpoints:* `server{group}:B --> T:subnet{group}` attaches
    the edge to the side of the service's parent group, aligned with the
    service. The modifier is only accepted on services inside a group.
  - *Placement:* each port pair places its endpoints relative to each other
    on a grid per group (`a:R -- L:b` puts `b` right of `a`, `a:T -- B:b`
    above, `a:T -- L:b` above-right), groups are laid out as one cell of
    their parent's grid, and edges route straight, with one 90-degree elbow
    for orthogonal port pairs, or with a midway jog for offset facing ports.
    A crowded cell pushes the later node further along the same direction.
  - *Alignment:* `align row|column id id ...` (at least two declared
    services or junctions, no repeats) pins members to one row or column in
    declared order, taking priority over edge-derived placement. When
    consecutive members sit in different groups, the later group is shifted
    so the members line up, unless that would overlap a sibling.
  - *Configuration:* `architecture.nodeSeparation` sets the grid gap;
    `randomize`, `idealEdgeLengthMultiplier`, `edgeElasticity`, `numIter`,
    `seed`, `iconSize`, `padding` and `fontSize` are validated but the
    native layout is deterministic and keeps its own spacing.
  - Not supported: fcose force-directed geometry, edge labels and
    registered (bundled) icon packs.
- **Use case:** (`usecase.w`)
  - *Elements:* actors, ellipse `( )` and rectangular `[ ]` use cases,
    quoted declarations (`"Reset password"` -> ID `Reset_password`),
    identifiers starting with digits, forward references (undeclared
    endpoints are ellipse use cases), one-level `systemBoundary` blocks with
    `id`, `id[title]`, `id(title)` or `"quoted title"` headers.
  - *Metadata and stereotypes:* `@{ ... }` inline or as a later `id@{ ... }`
    statement (a later key wins). Actors take `type: normal|hollow|awesome`,
    `icon: "pack:name"` and `business: true|false`; ellipse use cases take
    `business`; boundaries take `type: rect|package` (package draws a title
    tab). Icons combined with a type or business, business awesome actors or
    rectangular use cases and any other key are diagnosed. Icon actors use
    the architecture icon fallback (there is no icon registry).
    `<<stereotype>>` (after metadata, before `:::`) renders as a guillemet
    stereotype above the label.
  - *Notes and JSON tables:* `note for TARGET "text"` adds a note node
    joined to its actor or use case by a dotted line; notes may come before
    their target and cannot target boundaries, JSON tables or notes.
    `json ID@{ ... }` parses a strict JSON object (escapes, `\u` surrogate
    pairs, numbers, literals) into a path/value table (`address.city`,
    `items[0].name`, `{}`/`[]` for empty containers, last duplicate value
    wins at the first position), bounded to 512 rows and 32 levels.
  - *Labels:* unquoted, plain-string and Markdown-string labels (Markdown
    strings may span lines) on actors, use cases, boundaries, relationships
    and notes; Mermaid entity codes (`#quot;`, `#40;`, `#NNN;` ...) are
    decoded.
  - *Relationships:* `-->`, `<--`, `--`, `--o`, `o--`, `--x`, `x--`,
    `--|>` generalization and `..> : include|extend`; extra dashes on
    point/reversed/markerless associations raise the minimum rank distance;
    labelled associations `A -- label --> B` / `A -- "label" ---> B`;
    explicit edge IDs `A id@--> B` that `class`, `style` and
    `id@{ animate|animation }` statements target (animated edges render
    dashed). JSON nodes accept only point, reversed-point and markerless
    associations; include/extend and generalization endpoint kinds are
    validated.
  - *Styling:* `classDef`, `class`, `style`, `:::class` and `linkStyle` on
    actors, use cases, boundaries, JSON tables and explicit edges; a class
    without a `classDef` stays a plain class name, as upstream.
  - *Configuration:* `usecase.nodeSpacing`/`rankSpacing` set the native
    gaps and `colorScheme: rotate` gives actors, then use cases, their own
    palette slot under colour themes; font keys, `diagramPadding` and
    `useMaxWidth` are validated only (native metrics are fixed).
  - Not supported: ELK layout, numbered per-boundary palette colours and
    real (animated) SVG edge animation.
- **C4:** all five headers (`c4.w`, `c4_render.w`).
  - *Calls:* positional and `$name=value` arguments bound to the upstream
    signatures (`Person(alias, label, ?descr, ?sprite, ?tags, $link)`,
    `Container(alias, label, ?techn, ?descr, ...)`, `Boundary(alias, label,
    ?type, ...)`, `Deployment_Node`/`Node`/`Node_L`/`Node_R(alias, label,
    ?type, ?descr, ...)`, `Rel(from, to, label, ?techn, ...)`,
    `RelIndex(index, from, to, label, ...)`). Unknown, duplicate or excess
    arguments and bare `name=value` are diagnosed. Semantic fields are kept
    as node metadata (`techn`, `descr`, `type`, `sprite`, `tags`, `link`).
  - *Relations:* `Rel`, `BiRel`, `Rel_Back`, `RelIndex` (index ignored,
    numbering by statement order in C4Dynamic) and the directional macros
    `Rel_U/Up`, `Rel_D/Down`, `Rel_L/Left`, `Rel_R/Right` (plus `BiRel_*`).
    Directional relations attach to the named sides when the target lies in
    that direction; otherwise they draw like `Rel`.
  - *Styling:* `UpdateElementStyle(element, ?bgColor, ?fontColor,
    ?borderColor, ...)` recolours one element (`techn` updates its
    technology; shadowing, shape, sprite and legend arguments are accepted
    and ignored), `UpdateRelStyle(from, to, ?textColor, ?lineColor,
    ?offsetX, ?offsetY)` recolours a relation and moves its label, and
    `UpdateLayoutConfig(?c4ShapeInRow, ?c4BoundaryInRow)` (or the
    `c4.c4ShapeInRow`/`c4BoundaryInRow` configuration) sets the row sizes.
  - *Geometry:* the upstream statement-order layout: the shapes of each
    boundary fill rows of `c4ShapeInRow` (default 4), nested boundaries
    follow in rows of `c4BoundaryInRow` (default 2), cards are 240px wide
    with the fixed upstream palette, `<<type>>` stereotype, person icon,
    bold name, `[technology]` and wrapped description; databases and queues
    are vertical and horizontal cylinders; boundaries are dashed with a
    `[type]` line (`[system]`, `[enterprise]`, `[container]`, `[boundary]`)
    and deployment nodes solid; relations are straight border-to-border
    lines labelled at their midpoint.
  - Not supported: sprites, tags/legends (`AddElementTag`, `AddRelTag`),
    `Lay_*` statements (rejected; upstream does not plan them), link
    rendering and `c4.wrap: false` (validated only).

- **Swimlanes:** named responsibility lanes, five flow directions, rectangular,
  rounded/stadium, circular and decision nodes; labelled solid/dashed edges and
  chains, including handoffs and cycles. The layout aligns graph ranks across
  full-length lanes rather than treating lanes as ordinary clustered graphs.
  Nested lanes, styles and additional shapes remain unsupported.
- **Event modeling:** compact/relaxed timeframe and resetframe declarations,
  all five entity types, namespace-derived lanes, inferred predecessor links,
  explicit `->>` inputs, unique numeric frame identifiers and simple inline
  data. A dedicated source-order timeline spans typed responsibility lanes.
  External data blocks, typed/nested data payloads, and other data annotations
  remain unsupported.
