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
