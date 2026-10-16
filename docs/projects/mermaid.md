# Native Mermaid diagrams

The native engine provides a W parser, owned document model, lossless source writer,
source-edit API, deterministic layout, SVG exporter, CLI, and native Linux
desktop source editor with live preview. It has no Mermaid JavaScript, Node,
browser, network, or external layout dependency. The desktop uses the existing
`graphics.ui` / X11 / OpenGL stack. The library and CLI run on x86 and x64;
the desktop target is x64 Linux. Other desktop platforms are not yet qualified.

The goal is native support for **all Mermaid diagram types**, delivered in
stages. This implementation supports defined subsets of **flowcharts, ER, class and
state diagrams**, not full Mermaid compatibility. Unsupported syntax/type diagnostics
prevent partial diagrams from appearing as successful renders. Unsupported
documents remain readable, editable as source, and saveable without data loss.

## Use

```sh
./wbuild wmermaid wmermaid_editor
bin/wmermaid check examples/mermaid/orders.mmd
bin/wmermaid read examples/mermaid/orders.mmd
bin/wmermaid write examples/mermaid/orders.mmd bin/orders.mmd
bin/wmermaid svg bin/orders.mmd bin/orders.svg
bin/wmermaid_editor bin/orders.mmd
bin/wmermaid_editor examples/mermaid/classes.mmd
bin/wmermaid_editor examples/mermaid/states.mmd
```

`write` preserves the original bytes, including comments and CRLF. It is not a
formatter. `edit INPUT START END REPLACEMENT_FILE OUTPUT` replaces the half-open
UTF-8 byte range `[START, END)` and writes the result; replacement text is read
literally from the file. Invalid intermediate syntax is allowed in source edits
and writes. Run `check` to validate, or `svg` to validate and export. Neither
command accepts an invalid document as a successful diagram. Diagnostics go to
stderr with one-based line/byte-column positions; failed commands exit nonzero.
SVG export validates before touching its destination.

The desktop opens the named source. Edit text on the left to update the preview.
The path field and **Open** load another file; **Save** saves the current file,
and **Save as** uses the path field. **Undo/Redo** retain 32 source snapshots.
**Export SVG** writes `CURRENT_FILE.svg`. **Fit**, zoom buttons, and dragging in
the preview control the view. The editor asks to save/discard/cancel on close
with unsaved changes. Opening a different file requires saving the current
changes first. Errors clear the preview and appear below the source; the text
remains editable and saveable. This is source editing, not drag-to-change-model
editing. The path field is limited to 127 UTF-8 bytes.

The core file layer uses `lib.fs` atomic durable replacement, including when
input and output paths are identical. Save failure preserves editor dirty
state. Filesystem changes made by another program are not currently detected;
reload before editing a file shared with another editor. The existing filesystem
module's post-publication directory-sync failure semantics also apply.

For a reproducible native preview on a headless Linux host with Xvfb:

```sh
xvfb-run -a bin/wmermaid_editor examples/mermaid/orders.mmd \
  --frames 3 --screenshot bin/mermaid.ppm
python3 tools/ppm_to_png.py bin/mermaid.ppm bin/mermaid.png
```

## Flowchart and ER compatibility

Syntax references: [Mermaid flowcharts](https://mermaid.js.org/syntax/flowchart.html)
and [Mermaid ER diagrams](https://mermaid.js.org/syntax/entityRelationshipDiagram.html).
These describe upstream syntax; the table below defines the implemented subset.

| Area | Implemented |
| --- | --- |
| Input | Raw UTF-8 `.mmd` source, BOM, LF/CRLF, `%%` comments, semicolon separators |
| Flow header | `flowchart` or `graph`, followed by `TB`, `TD`, `BT`, `LR`, or `RL` |
| Flow nodes | Bare IDs, rectangle `[label]`, rounded `(label)`, circle `((label))`, diamond `{label}`; quoted labels |
| Flow edges | `-->`, `---`, `-.->`, optional `|label|`, chains, cycles, self edges |
| ER entities | Bare/quoted names, standalone entities, `[alias]`, attribute blocks |
| ER attributes | `type name`, `PK`/`FK`/`UK` and comma-separated combinations, quoted comments, array/parenthesized/nullable types, `*` primary-key name spelling |
| ER relationships | All 16 combinations of symbolic cardinalities, `--` identifying and `..` non-identifying, required `: label` |
| ER direction | `direction TB`, `BT`, `LR`, or `RL` |
| Rendering | Entity attribute rows, relationship text, crow's feet, optional circles, one bars, dashed/solid edges; shared scene for native and SVG output |

Attributes occupy separate lines (or one attribute before a closing brace).
Quoted text is displayed as literal text: Markdown/HTML, Mermaid entity escape
codes and rich labels are not interpreted. Native glyph coverage follows the
UI font system; SVG uses the viewer's monospace font. Label sizing uses an
8-pixel-per-UTF-8-byte estimate, so multilingual text can reserve extra width.
ER attributes show type, name, keys and comment in each row rather than separate
resizable columns. Layout uses longest-path ranks with deterministic cycle
breaking and orthogonal connectors. It is not Dagre/ELK: complex cycles,
parallel edges and long labels may overlap and need future routing work.

Not yet supported: subgraphs, styling/classes, frontmatter/configuration,
click actions, additional node/edge shapes, textual cardinality aliases,
Markdown fences and rich text. Class and state coverage is listed below;
other diagram families are not yet implemented. Most unsupported syntax
is an explicit diagnostic; text inside accepted labels is always literal.

## Class and state compatibility (stage 2)

The UML syntax baseline is pinned to Mermaid **12.2.0**:
[class syntax](https://github.com/mermaid-js/mermaid/blob/mermaid%4012.2.0/packages/mermaid/src/docs/syntax/classDiagram.md),
[state syntax](https://github.com/mermaid-js/mermaid/blob/mermaid%4012.2.0/packages/mermaid/src/docs/syntax/stateDiagram.md).
This is subset coverage, not a claim of upstream rendering or syntax parity.

| Family | Implemented |
| --- | --- |
| Class declarations | `classDiagram`, `class ID`, `class ID["label"]`, member blocks, `ID : member`, `<<annotation>>` in blocks, before IDs, or after declarations |
| Class members | Literal visibility/type/signature text, separated into attribute and operation compartments by the presence of `(`; input order is retained within each compartment |
| Class relationships | Solid `--` and dashed `..`; optional open arrow, hollow triangle, filled composition diamond or hollow aggregation diamond at either end; quoted multiplicities and `: label` |
| Class grouping | Nested `namespace Name { ... }`, globally unique class IDs, relations across namespaces, declarations that assign previously referenced classes to their namespace |
| State declarations | `stateDiagram` / `stateDiagram-v2`, bare IDs, `state "label" as ID`, `ID : description` |
| State transitions | `-->`, optional `: label`, cycles/self transitions, scope-local `[*]` initial and final nodes |
| State structures | Nested `state ID { ... }`, transitions to/from composites, `<<choice>>`, `<<fork>>`, `<<join>>` |
| Direction | Top-level and group-local `direction TB`, `TD`, `BT`, `LR`, `RL`; children inherit their containing group's direction |
| Output and editing | Shared native/SVG geometry, lossless read/write and source edits, editor preview/history/save for both families |

Groups reserve space for their children before the containing graph is laid out.
Namespaces render as labeled containers; composite states render with their own
initial/final nodes. Class relationships retain separate endpoint types and
multiplicity labels. Names are globally unique; state transitions across scopes
are rejected. A group may contain at most 32 nested group levels. Class members
share the 4,096-document / 1,024-node attribute budget.

Not yet supported in UML: generic class declarations, escaped class identifiers,
namespace display labels/dotted shorthand, lollipop interfaces, notes, concurrent
state regions, styling/classes, click actions, configuration, accessibility
statements and rich text. Signatures and annotations display literally; static
or abstract suffixes do not add font styling. Unsupported structures fail parsing
and clear the preview while preserving editable source. Automatic routing can
still overlap connectors or labels, particularly across namespace boundaries.

## W library

```w
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

char* source = c"erDiagram\nCUSTOMER ||--o{ ORDER : places\n"
mm_document* doc = mm_parse(source, strlen(source))
if (doc.error == 0):
	mm_scene* scene = mm_render(doc)
	char* svg = mm_svg(scene)
	# Consume svg here; it is owned by the caller.
	free(svg)
	mm_scene_free(scene)
mm_document_free(doc)
```

- `model`: `mm_document`, nodes, attributes and edges; `mm_write(doc)` returns
  owned source text; `mm_document_free` frees the complete document.
- `parse_common` / `uml`: bounded lexical helpers and class/state parsers.
- `parser`: `mm_parse(bytes, length)` copies input and returns an owned result,
  including failures. `error == 0` means successful subset parsing.
  `mm_edit(doc, start, end, replacement, length)` returns an independent reparsed
  document; null means invalid range/budget or a split UTF-8 codepoint. The old
  document is unchanged. Fields are inspectable; edit source and reparse to keep
  the model and lossless writer consistent. Direct AST mutation is not serialized.
- `render`: `mm_render(doc)` returns an owned display list, or null for a failed
  parse; `mm_svg(scene)` returns owned escaped XML. `mm_scene_free` releases it.
- `io`: `mm_read(path)` returns an owned document, or null for I/O/budget failure;
  `mm_save(doc, path, io_result*)` returns an `IO_*` status. `mm_diagnostic` returns
  an owned location/message string.
- `editor`: UI-independent source history, dirty state, preview and save state.
- `graphics.mermaid`: `mm_ui_render` draws a scene into a clipped viewport with
  zoom and pan using an existing `ui_renderer`.

The source limit is 1 MiB, with at most 1,024 nodes, 1,024 edges, 1,024
attributes/members per node and 4,096 attributes/members overall, with at most
32 group levels. Parsing rejects invalid
UTF-8, embedded NUL and non-whitespace ASCII controls. Source bytes remain
available on syntax failure. A scene owns its strings and geometry independently
of the document. Callers own every returned object/string and must free them.

## Stages toward all types

Each stage needs parsing/diagnostics, a semantic model, source-preserving editing,
layout, native preview, SVG export, and positive/negative fixtures before it can
be marked supported. Recognizing a header alone does not count as support.

1. **Delivered foundation:** flowchart and ER core, document/scene lifetimes,
   file I/O, source editing, CLI and desktop preview. Close their syntax gaps
   above before claiming parity for either family; add routing and text metrics.
2. **Related graph families (in progress):** class and state core, UML markers,
   namespaces and composite layout are delivered. Remaining: their syntax gaps,
   requirement, use-case, block, architecture, C4, GitGraph and swimlanes; expand
   routing, ports and compound layout for these families.
3. **Ordered narratives:** sequence, user journey, Gantt, timeline and ZenUML.
   Add lifelines, time scales, nested interactions and scheduling semantics.
4. **Data diagrams:** pie, quadrant, XY, Sankey, radar, treemap, Venn and packet.
   Add axes, numeric/date validation, area/flow layouts and legends.
5. **Hierarchical/workflow families:** mindmap, Kanban, event modeling,
   Ishikawa, Wardley, Cynefin and tree view. Maintain the inventory against a
   pinned upstream release and explicitly register new families.
6. **Compatibility and editing depth:** frontmatter/themes/styles, rich labels,
   accessibility, Markdown embedding, structured model edits and direct diagram
   manipulation, cross-platform desktop qualification, upstream conformance
   corpus and fuzzing. Pin/version syntax expectations rather than silently
   following changes to upstream Mermaid.

## Validation

`mermaid_test` and `mermaid_64_test` exercise parsing, every ER cardinality pair,
source round trips, immutable edits, failures, bounds, XML escaping, direction,
cycles and shared-child ranking. `mermaid_editor_test` covers undo/redo, dirty
state, failed saves, history bounds and clipped native drawing without a display.
`mermaid_cli_test` exercises executable exit codes, lossless and in-place file
writes, edits, invalid source preservation, both examples and well-formed XML.
`uml_test` and `uml_64_test` cover endpoint combinations, member compartments,
namespace ownership, compound bounds, scoped initial/final states, directions,
source edits, unsupported syntax and nesting/member limits. The native editor
tests also verify clipping for UML polygons and compound diagrams.
These source-owned targets join `./wbuild tests` automatically.
