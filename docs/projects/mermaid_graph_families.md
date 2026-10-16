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
  use labelled dashed dependency arrows. Styles and rich Markdown are not yet
  supported.
- **Mindmaps:** a single indentation-based tree with plain text, rectangular,
  rounded, and circular labels. A dedicated subtree-height layout keeps sibling
  branches separate. Nesting is bounded to 64 levels. Icons, classes, cloud,
  bang and hexagon shapes are not yet supported. Indentation must return to an
  existing level; the upstream ambiguous-indentation heuristic is not applied.
- **Kanban:** indentation-based columns and cards, explicit or generated IDs,
  assigned/ticket/priority metadata, validated priorities. Columns contain their
  cards and metadata in a dedicated column layout. Nested cards, metadata on
  columns, ticket links and custom configuration are not yet supported.

Tests cover semantic structures, geometry, lossless writing, forward references,
errors, and every byte-prefix of representative inputs. Tests run on x86 and
x64, including the guard allocator's leak checks.

- **TreeView:** indentation-based forests, quoted or plain Unicode labels,
  source-order rows and orthogonal ancestry connectors. Tree-command prefixes,
  icons, classes and description annotations remain unsupported.
- **Ishikawa:** problem head, first-level cause branches alternating around a
  spine, indented subcauses with ancestry connectors. Physical indentation
  carries hierarchy; input and nesting are bounded.
- **Cynefin:** all five domain regions, quoted items, optional title and labelled
  domain transitions. Confusion occupies the centre between quadrant rows.
  Native regions use rectangular boundaries instead of upstream organic curves.
- **Wardley:** anchors/components at validated visibility/evolution coordinates,
  a title, forward-resolved dependencies and four labelled evolution stages.
  Coordinates use bounded thousandths. Decorators, evolution arrows, notes,
  pipelines, alternative flow syntax and custom axis configuration remain
  unsupported and produce diagnostics.

- **GitGraph:** commit IDs, normal/reverse/highlight shapes, tags, branch
  creation, checkout/switch and merge commits with two parents. Branch heads
  determine commit ancestry; a dedicated time/lane layout shows history.
  Duplicate IDs/branches, unknown checkouts, empty/self/same-head merges fail.
  The current layout supports LR; cherry-pick, branch order and custom branch
  configuration are not yet supported.
- **Block:** source-ordered grids, up to 64 columns, column spans, empty spaces,
  rectangle/rounded/circle nodes, nested composites (up to 32 levels) and
  labelled solid links. Span overflow and malformed blocks fail explicitly.
  Column widths grow by actual content, so one large label does not multiply
  across every column. Custom styles, block arrows and other shapes remain
  unsupported.

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
  stereotypes, notes, styles, JSON nodes and rich labels remain unsupported.
- **C4:** all five headers, typed person/system/container/component cards,
  external/database/queue type annotations, nested boundaries and deployment
  nodes, descriptions/technology, Rel/BiRel/Rel_Back, and source-ordered numbered
  interactions in C4Dynamic. Native cards preserve semantic type annotations;
  custom styling, directional relationship macros, named configuration
  arguments and upstream exact geometry remain unsupported.
