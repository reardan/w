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
  supported, including `name:::class` on a definition or as its own
  statement. `direction TB|BT|LR|RL` sets the layout direction. Keywords are
  case-insensitive as in upstream's lexer (`docRef`, `verifyMethod: Test`,
  `Satisfies`); members keep their written spelling. Rich Markdown and
  broader configuration remain incomplete.
- **Mindmaps:** a single indentation-based tree with plain text, `[square]`,
  `(rounded)`, `((circle))`, `)cloud(`, `))bang((` and `{{hexagon}}` labels. A
  dedicated subtree-height layout keeps sibling branches separate. Nesting is
  bounded to 64 levels. A `::icon(name)` line attaches one icon to the
  previous node, drawn above the label as a native pictogram (see *Icons*
  below; no icon font is downloaded). `:::a b` classes, trailing a node or on
  their own line, attach to the previous node and are kept in the owned model
  as external CSS class names (mindmaps have no `classDef`). A node's parent is
  the nearest earlier node indented less than it, as upstream's
  `mindmapDb.getParent`, so a line indented between two levels becomes a child
  of the shallower one; a second unindented node is still a second root and
  fails. Nodes are filled per branch (the root's child they descend from) as
  upstream's section colours, or per depth with `config: mindmap: colorBy:
  depth`; themes repaint them from `cScale0`–`cScale11`. Labels wrap at
  `mindmap.maxNodeWidth` (default 200px, measured per glyph) and nodes grow
  by the extra lines. `padding` is ignored and recorded.
- **Kanban:** indentation-based columns and cards, explicit or generated IDs,
  assigned/ticket/priority metadata, validated priorities. Columns contain their
  cards and metadata in a dedicated column layout. Frontmatter
  `config: kanban: ticketBaseUrl: 'https://…/#TICKET#'` turns each card's
  `ticket:` line into an SVG `<a href>` link: the first `#TICKET#` is
  replaced by the percent-encoded ticket (a base without the marker is used
  as is), and only `http://`/`https://` bases are accepted. Deeper indented
  lines are cards of the enclosing column, as upstream `getSection` flattens
  them; there are no subcards. `@{ ... }` metadata is accepted on columns too
  (upstream kanbanDb applies node data to any item): its lines render under
  the column title, above the header rule. A `label:` key replaces the
  bracket title on columns and cards. A repeated ID (upstream's own example
  reuses `id3`) keeps both items: the repeat gets a generated internal ID and
  records the written one as its `id` property. Column and card titles
  wrap at `kanban.sectionWidth` (default 200px, measured per glyph), and
  boxes grow by the extra lines. Other `kanban` settings and rendering cards
  without their metadata are not yet supported; unknown `kanban` settings
  and metadata keys are diagnosed.

Tests cover semantic structures, geometry, lossless writing, forward references,
errors, and every byte-prefix of representative inputs. Tests run on x86 and
x64, including the guard allocator's leak checks.

- **TreeView:** indentation-based forests, quoted or plain Unicode labels,
  source-order rows and orthogonal ancestry connectors. Lines pasted from the
  `tree` command (`├── `, `└── `, `│   `, with plain or NBSP padding, mixed
  freely with indented lines) take their depth from the branch glyph's column
  plus four; bare `│` lines are ignored and a glyph prefix without a branch
  marker is diagnosed. `label ## description` attaches a description that
  renders in italic after the label. Before the description, `icon(pack:name)`
  draws a native pictogram (see *Icons*) even when icons are off and
  `icon(none)`/`icon()` hides one (an icon token may come before or after
  the classes); `:::a b` assigns space-separated CSS classes that
  `classDef`/themeCSS rules style, and the built-in `highlight` tints the row
  (`highlightBg` / `highlightStroke`). `config: treeView: showIcons: true` adds folder icons
  for directories (a trailing `/` or children) and file icons otherwise;
  `filenameIcons: { Dockerfile: docker }` maps whole names (extension maps
  are dotted YAML keys such as `.ts:`, or `ts:`; the longest suffix wins).
  `rowIndent` and `lineThickness` change the row indent and connector width,
  and `themeVariables: treeView:` `labelColor`, `lineColor`,
  `descriptionColor`, `iconColor`, `highlightBg` and `highlightStroke`
  recolour them (`highlightBg` takes any CSS value, such as upstream's
  `rgba(...)` default, and falls back to the native tint when it is not a
  plain colour); other keys (`labelFontSize`, `paddingX`/`paddingY`,
  `iconSize`) are ignored and recorded. `defaultIconPack` is kept but packs
  are never fetched.
- **Ishikawa:** the upstream `ishikawaRenderer` geometry. The problem sits in
  a fish head at the right end of a 2px spine; first-level causes alternate
  above and below in pairs, each on a bone at 82° whose length comes from a
  shared 500px pool in proportion to descendants (at least 75px, and at least
  32px per descendant). Sub-causes alternate between horizontal bones (even
  depths, 30px or 60px + 5px per child) and diagonal bones parallel to the
  cause (odd depths), every bone ends in an arrowhead, cause labels are boxed
  and sub-cause labels wrap at 15 characters (the head at 13). Each pair
  starts left of the previous pair's labels. Physical indentation carries
  hierarchy; input and nesting are bounded.
- **Cynefin:** the upstream `cynefinRenderer` geometry on its 800×600 field with
  40px padding: four unstroked quadrants, the wavy vertical fold and horizontal
  boundary (seven cubic segments with seeded jitter; the native renderer uses
  a fixed seed so output is reproducible), the thicker Clear/Chaotic cliff and
  the central Confusion ellipse (15% of the field). Each domain shows its bold
  name, decision model and practice, then its quoted items as pill badges;
  Confusion shows at most three badges plus "+N more". Transitions are
  quadratic curves bowed by 15% of their chord, as upstream, but routed for
  dense diagrams (issue #817): each domain's name, model, practice and badges
  form a keep-out block; a transition runs on a line offset 8px left of its
  direction (16px further per earlier transition between the same domains
  in the same direction) from where that line leaves the source block to
  where it enters the target's, bowing to the same side (+15% per repeat),
  so reverse and repeated transitions nest instead of coinciding and arrows
  never land on domain text. A curve that would enter a third domain's block
  or run alongside an earlier transition tries 30%/60% larger and then a
  smaller opposite bow. Labels sit beside the curve's midpoint and move
  along/across it until they overlap no block and no other label. Self-loops
  are skipped as upstream. Link-link crossings are reduced, not minimized;
  the `seed`/theme configuration remains open.
- **Wardley:** anchors/components at validated visibility/evolution
  coordinates, a title, forward-resolved links and labelled evolution stages.
  Coordinates use bounded thousandths. `size [width, height]` (100–4000
  pixels) scales the plot to that canvas. `evolution A -> B -> ...` takes two
  to eight stages; `Stage@0.25` gives each stage's right edge on the evolution
  axis (used only when every stage has one, strictly increasing, as upstream)
  and `Stage / Second line` adds a second label line. After a component's
  `[visibility, evolution]`, any order of `label [dx, dy]` (integers within
  ±999), `(build)`/`(buy)`/`(outsource)` (a shaded halo), `(market)` (a white
  disc with three linked dots replacing the component circle) and
  `inertia`/`(inertia)` (a bar on the evolution side) is accepted; repeats are
  diagnosed. Links follow upstream's grammar `A [port] [arrow] B [port]
  [; label]`: `->`, `-->` and `>` are plain dependencies, `-.->` is dashed,
  the flow ports `+>`, `+<` and `+<>` draw arrowheads at the target, the
  source or both, `+'label'>` (`<`, `<>`) is a labelled flow, and `; label`
  labels any link. `evolve Name 0.8` draws a red dashed arrow to a red ghost
  of the component at the new evolution. `note "text" [v, e]` (or unquoted
  text) places a free label. `annotation N,[v, e] "text"` places numbered
  marker N (repeating a number marks more points, joined by dashed lines) and
  `annotations [v, e]` positions the legend box that lists them by number
  (top-right by default). `accelerator "name" [v, e]` and `deaccelerator`
  draw upstream's 60 × 30 block arrows pointing right or left with a bold
  label. `pipeline Name [low, high]` and/or a following `{ component Child
  [evolution] … }` block (brace on the same or next line) draws a band under
  the component and places sub-components at its visibility; a range is
  inferred from the children when omitted and children outside an explicit
  range fail. Pipelines must belong to a top-level component. Mermaid 12.2.0
  has no `evolve A->B` renaming, `limited by` links, `(ecosystem)` or `submap`
  (OnlineWardleyMaps syntax its grammar rejects), so those stay diagnosed;
  trend indicators (`-.-`) are not supported either.

- **Icons (`icons.w`, mindmap and treeView):** an icon reference's last name
  segment (after any `pack:` prefix and a short `fa-`/`mdi-`-style tag) is
  matched against a fixed keyword table and drawn as a 20-pixel vector
  pictogram from scene primitives, so it renders the same in SVG and native
  previews: folder/directory → folder, book → open book, file/document →
  page, user/person/people/account → person, cog/gear/setting → gear, cloud,
  database/server → cylinder, star, heart, home/house, check, close/times/
  xmark → cross, info, warn/exclamation/alert → warning triangle,
  search/magnif → magnifier, code/terminal → `</>`, bulb/idea → bulb,
  link/chain, envelope/mail, calendar, lock/key, globe/earth/web, brain,
  flag, ban, spinner, camera, truck, twitter/bird, phone/mobile, trash,
  pencil/edit, plus, minus, play, bell. Flowchart labels use the same table
  for Font Awesome prefixes (`fa:fa-ban`, `fab:`/`fas:`/`far:`/`fal:`/`fak:`,
  matched as upstream's `fa[bklrs]?:fa-[\w-]+`): each reference becomes a
  pictogram in its place in the line instead of text. Any other name draws a round badge with its first letter
  (`logos:react` → `R`). No icon font or pack is downloaded or bundled.

- **GitGraph:** commit IDs, normal/reverse/highlight shapes, tags, branch
  creation, checkout/switch and merge commits with two parents. Branch heads
  determine commit ancestry; a dedicated time/lane layout shows history.
  `commit "text"` and `commit msg: "text"` keep the message as `msg`
  metadata (upstream does not draw it either). A repeated commit id is
  accepted as upstream's commit map does: the id is rebound to the newer
  commit, so later cherry-picks resolve to it, and the older commit keeps
  its label under an internal `<id>~N` id. Upstream then stops drawing the
  older commit; it stays drawn here. A merge with an existing custom id,
  duplicate branches, unknown checkouts and empty/self/same-head merges fail.
  The layout supports LR, TB and BT. `branch name order: N` sorts explicitly
  ordered branches after unspecified branches, with stable ties. `cherry-pick
  id: "source"` creates a new commit on the current branch and retains source
  metadata without introducing false merge ancestry. Merge picks require an
  immediate `parent: "id"`; tags are supported. Missing/same-branch source
  commits and invalid merge parents are diagnosed. Commit spacing and lane
  sizes come from measured label widths. Custom branch configuration
  remains unsupported.
- **Block:** source-ordered grids, up to 64 columns, column spans, empty spaces,
  nested composites (up to 32 levels) and labelled solid links. Node shapes:
  rectangle `[ ]`, rounded `( )`, stadium `([ ])`, subroutine `[[ ]]`,
  cylinder `[( )]`, circle `(( ))`, double circle `((( )))`, asymmetric
  `> ]`, rhombus `{ }`, hexagon `{{ }}`, parallelograms `[/ /]`/`[\ \]` and
  trapezoids `[/ \]`/`[\ /]`. Block arrows `id<["label"]>(dir)` accept
  `right`, `left`, `up`, `down`, `x` (both horizontal) and `y` (both
  vertical) and take spans like other blocks; a comma-separated list such
  as `(x, down)` draws one arrow with a head per listed direction around a
  central square. `block:id:2` spans a composite over two parent columns.
  `A-- "X" -->B` (also `==` and `-.` openings) labels a link like
  `A-->|X|B`. `style`, `classDef`, `class`
  and inline `:::class` use the shared style subset (fill, stroke, color,
  stroke-width) on blocks and composites, and `linkStyle` on links; styling
  an undeclared block fails. Span overflow and malformed blocks fail
  explicitly. Column widths grow by actual content, so one large label does
  not multiply across every column. Dotted/thick links and block-arrow
  geometry other than the six directions and their combinations remain
  unsupported.

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

- **Swimlanes:** named responsibility lanes (`subgraph id[Label]`,
  `id [Label]`, quoted or bare titles) and nested sub-lanes up to 32 levels,
  drawn as rounded clusters inside their lane; five flow directions. Nodes use
  every flowchart bracket form (rectangle, rounded, stadium, subroutine,
  cylinder, circle, double circle, asymmetric, rhombus, hexagon, the four
  slanted forms) and `id@{ shape: …, label: … }` with the expanded shape
  catalogue (`shape_catalog.w`/`shapes.w`: documents, cylinders, braces,
  forks, hourglass, bolt, delay, card, flag, cloud, bang, folder, data store,
  console, browser, person, bucket, …). Links cover `-->`, `---`, `-.->`,
  `-.-`, `==>`, `===` and longer forms, `x`/`o` heads, `<` bidirectional heads,
  pipe and inline (`-- text -->`, `-. text .->`) labels, chains and `&`
  groups. `classDef`, `class`, `:::class`, `style` and `linkStyle` apply. A
  step stays in the lane that first declares it; naming it inside a nested
  sub-lane of that lane moves it there. The layout aligns graph ranks across
  full-length lanes rather than treating lanes as ordinary clustered graphs.
  Links are routed orthogonally (issue #817): rank columns never overlap, so
  the gap after each column is a free channel. A link leaves its step's far
  side into the channel after the source column, runs along a clear track
  (the target's or source's centre line when nothing lies between the two
  channels, else the nearest line just past a blocking step or a nested
  lane's title band) to the channel before the target column and enters
  the target's near side; backward links and same-rank links use the same
  scheme, so no link segment crosses a step box in any direction.
  Unrelated links sharing a channel or track are offset in 8px slots, and a
  label takes the first position along its segment that overlaps no step
  and no earlier label. Link-link crossings are not minimized and steps are
  not reordered to avoid them.
- **Event modeling:** compact/relaxed timeframe and resetframe declarations with
  1–3 digit identifiers, all five entity types, namespace-derived lanes
  (ordered UI/automation, command/read model, events as upstream), inferred
  predecessor links and explicit `->>` inputs. Payloads come from inline
  `{ … }` (nested braces allowed; it runs to the last closer on the line) or
  quoted text, or from `[[Name]]` references to `data Name `type` { … }`
  blocks declared anywhere in the file. Backtick data types (`json`,
  `jsobj`, `figma`, `salt`, `uri`, `md`, `html`, `text`) appear in the frame
  heading; payloads render as text. `note FID { … }` and
  `gwt FID given … when … then …` annotate a frame below a dashed rule,
  `entity Name` declares an entity, and `/* … */` and `//` comments are
  accepted. Frames hold at most 256 data lines and a diagram 4096.
