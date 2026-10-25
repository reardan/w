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
  quadratic curves between domain centres bowed by 15% of their length, with
  the label at the control point; self-loops are skipped as upstream. Dense
  transition routing and the `seed`/theme configuration remain open.
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

- **Architecture:** services, nested groups, junctions, the five built-in icon
  names, all sixteen source/target port pairs, arrowheads at either end, and
  explicit containment/reference validation. Native icon geometry and port
  routing share the graph scene backend. Icon packs, group-edge modifiers and
  alignment directives remain unsupported. Placement currently uses the native
  graph hierarchy; it does not solve upstream port-direction placement
  constraints.
- **Use case:** actors, oval/rectangular use cases, one-level system boundaries,
  direction, directed/reversed/undirected associations, include/extend and
  generalization. Endpoint types are validated after declarations. Metadata,
  stereotypes, notes, JSON nodes and rich labels remain unsupported. Node
  styles/classes and link styles are supported, including filled oval cases.
- **C4:** all five headers, typed person/system/container/component cards,
  external/database/queue type annotations, nested boundaries and deployment
  nodes, descriptions/technology, Rel/BiRel/Rel_Back, and source-ordered numbered
  interactions in C4Dynamic. Native cards preserve semantic type annotations;
  custom styling, directional relationship macros, named configuration
  arguments and upstream exact geometry remain unsupported.

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
