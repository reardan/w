# Native Mermaid diagrams

The native engine provides a W parser, owned document model, lossless source writer,
source-edit API, deterministic layout, SVG exporter, CLI, and native Linux
desktop source editor with live preview. It has no Mermaid JavaScript, Node,
browser, network, or external layout dependency. The desktop uses the existing
`graphics.ui` / X11 / OpenGL stack. The library and CLI run on x86 and x64;
the desktop target is x64 Linux. Other desktop platforms are not yet qualified.

The family-coverage milestone is implemented: every authoring family in the
pinned Mermaid **12.2.0** registry has a bounded native core, including all five
C4 headers, all four railroad notations and agentflow. ZenUML is also supported.
The [compatibility matrix](mermaid_compatibility.md) lists every family, runnable
examples, implemented semantics and remaining gaps. This is **not full Mermaid
compatibility**: syntax, configuration, styling, layout and editing depth remain
incomplete.

Supported documents share read/write, source editing, native preview and SVG
export. Unsupported syntax produces a diagnostic and suppresses the preview;
the original document remains readable, editable as source, and saveable without
data loss. Markdown or HTML inside accepted plain labels is displayed literally.

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
| Input | Raw UTF-8 `.mmd` source or one Mermaid Markdown fence, BOM, LF/CRLF, `%%` comments, semicolon separators |
| Flow header | `flowchart` or `graph`, followed by `TB`, `TD`, `BT`, `LR`, or `RL` |
| Flow nodes | Bare IDs, rectangle `[label]`, rounded `(label)`, circle `((label))`, diamond `{label}`; quoted labels |
| Flow edges | `-->`, `---`, `-.->`, optional `|label|`, chains, cycles, self edges |
| ER entities | Bare/quoted names, standalone entities, `[alias]`, attribute blocks |
| ER attributes | `type name`, `PK`/`FK`/`UK` and comma-separated combinations, quoted comments, array/parenthesized/nullable types, `*` primary-key name spelling |
| ER relationships | All 16 symbolic cardinality combinations plus textual aliases (`only one`, `zero or many`, etc.); `--` / `to` identifying and `..` / `optionally to` non-identifying; required `: label` |
| Grouping | Nested `subgraph ID[label] ... end` in flowcharts and ER; scoped directions and compound bounds |
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

Node styles/classes and a bounded frontmatter theme subset are implemented;
see [Styles and themes](mermaid_styling.md). Remaining gaps include link styling,
most configuration options, click actions, additional node/edge shapes and rich
text. Class and state coverage is listed below; other families are listed in the
[compatibility matrix](mermaid_compatibility.md).

## Class and state compatibility

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
state regions, click actions, configuration beyond the documented theme subset,
and rich text. Node styles/classes and accessibility statements are supported.
Signatures and annotations display literally; static
or abstract suffixes do not add font styling. Unsupported structures fail parsing
and clear the preview while preserving editable source. Automatic routing can
still overlap connectors or labels, particularly across namespace boundaries.

## Markdown, titles and accessibility

A source document can contain one backtick or tilde Mermaid fence. The parser
ignores fences in other languages and preserves all surrounding prose and original
line endings. Multiple Mermaid fences are diagnosed rather than displaying only
part of the document. Parse diagnostics and byte-range edits refer to the original
complete source. See `examples/mermaid/document.md`.

Plain `title:` frontmatter is supported inside or outside a fence. Quoted scalar
titles are accepted. The frontmatter parser also accepts the bounded `config`
theme subset described in [Styles and themes](mermaid_styling.md); it is not a
general YAML parser. Other structured values, YAML escapes and unsupported
configuration fields produce diagnostics.

`accTitle:` and `accDescr:` (including brace-delimited multiline descriptions)
provide escaped SVG title/description metadata across families, including the
indentation-based mindmap, Kanban, TreeView and Ishikawa parsers. Metadata does
not alter hierarchy indentation. Frontmatter titles are visible in native preview
across families. Source edits preserve metadata.

## Styles and themes

Flowchart, ER, class and state diagrams support node `style`, `classDef` and class
assignment, with fill, border/text colors and integer stroke widths. Styles
resolve consistently into native and SVG primitives, including transparent fills.
The five frontmatter theme names `default`, `base`, `dark`, `forest` and `neutral`
select native palettes. With `base`, six quoted-hex `themeVariables` are supported.
[The styling reference](mermaid_styling.md) defines precedence, accepted names,
limits and exact indentation. This does not provide general CSS, upstream theme
parity, `linkStyle`, font overrides or arbitrary diagram configuration.

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
- `source`: lossless Markdown/frontmatter envelopes and original-document offsets.
- `scene`: owned backend-independent primitives and escaped SVG metadata.
- `parse_common` / `uml`: bounded lexical helpers and class/state parsers.
- Family modules: graph/workflow parsers and layouts, `data_parse` / `data_render`,
  narrative parsers/renderers, `railroad_parse` / `railroad_render`, and `agentflow`.
  Their owned models preserve family-specific semantics.
- `style` / `style_render`: bounded style parsing, resolution and scene palettes.
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

The shared source limit is 1 MiB. Graph documents permit at most 1,024 nodes and
1,024 edges; graph attributes/members have 1,024-per-node and 4,096-document
budgets. Common graph/container nesting is capped at 32 levels. Some families
have different limits: hierarchy depth, data values/entries, railroad expressions
and metadata budgets are specified in their linked references. Parsing rejects
invalid UTF-8, embedded NUL and non-whitespace ASCII controls. Source bytes remain
available on syntax failure. A scene owns its strings and geometry independently
of the document. Callers own every returned object/string and must free them.

## Delivered stages and remaining work

Native core coverage is delivered for the foundation/UML families, fourteen
additional graph and workflow families, five ordered narrative families, eight
data families, railroad's four notations and agentflow. Markdown source envelopes,
titles, accessibility metadata and bounded styles/themes are also delivered.
See the [pinned inventory and per-family matrix](mermaid_compatibility.md) for the
precise boundary of each implementation.

Remaining compatibility and editing work:

1. Close the syntax and semantic gaps listed for each family, including advanced
   scheduling, grammar operators, compound graph constructs and richer metadata.
2. Expand theme/configuration compatibility, style coverage across families,
   links, fonts and rich labels without losing the native engine constraint.
3. Improve text measurement, wrapping, edge routing, port placement and dense
   chart layout. Native geometry does not reproduce Dagre/ELK or browser layout.
4. Add structured model-to-source edits and direct diagram manipulation. The
   current editor edits source with a live preview; mutating the AST does not
   update the lossless writer.
5. Qualify desktop platforms beyond x64 Linux and address external file-change
   detection, path limits and broader accessibility interactions.
6. Expand the pinned upstream conformance corpus, malformed-input fuzzing and
   cross-family integration tests before claiming syntax or rendering parity.

## Validation

`mermaid_test` and `mermaid_64_test` exercise parsing, every ER cardinality pair,
source round trips, immutable edits, failures, bounds, XML escaping, direction,
cycles and shared-child ranking. `mermaid_editor_test` covers undo/redo, dirty
state, failed saves, history bounds and clipped native drawing without a display.
`mermaid_cli_test` exercises executable exit codes, lossless and in-place file
writes, edits, invalid source preservation and well-formed XML.
`uml_test` and `uml_64_test` cover endpoint combinations, member compartments,
namespace ownership, compound bounds, scoped initial/final states, directions,
source edits, unsupported syntax and nesting/member limits. The native editor
tests also verify clipping for UML polygons and compound diagrams.
`compatibility_test` and `compatibility_64_test` cover compound flow/ER layouts,
all textual ER alias combinations, source envelopes, diagnostic offsets, source
edits and accessible SVG metadata.
Family targets include `graph_families_test`, `framework_test`, `gitgraph_test`,
`blocks_test`, `systems_test`, `c4_test`, `workflows_test`, `data_test`,
`narrative_test`, `railroad_test` and `agentflow_test`, with their x64 twins.
`style_test`, `style_64_test` and `mermaid_style_native_test` verify palette/style
resolution, transparent fills and native/SVG parity. Tests cover family semantics,
layout bounds, source ownership, byte-prefix truncations and malformed edits.
The examples support CLI check/export and headless native preview checks.
These source-owned targets join `./wbuild tests` automatically. Passing these
checks establishes the documented subsets, not full upstream conformance.
