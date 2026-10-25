# Mermaid label text layout

Node, group and edge labels in the graph families (flowchart, ER, class,
state, requirement, C4, agentflow, architecture and every other family drawn
by `mm_render_graph`) go through one shared layout in
`libs/extras/mermaid/text.w`, measured by `libs/extras/mermaid/text_metrics.w`.
Tests: `./wbuild text_layout_test` (and `text_layout_64_test`).

## Accepted syntax

| Form | Meaning |
|---|---|
| `<br>`, `<br/>`, `<br />` (any letter case, spaces before `/`) | Line break, in plain labels and markdown strings |
| `"` + `` ` `` ... `` ` `` + `"` | Markdown string; may span source lines, and each newline is a line break |
| `**text**` | Bold run (markdown strings only) |
| `*text*`, `_text_` | Italic run (markdown strings only); `_` must not touch a word character outside the pair, so `snake_case` stays literal |
| `***text***`, `**a *b* c**` | Nested bold italic |

In plain labels the emphasis markers are literal text, as upstream. A marker
only opens when a matching closer follows on the same line; unmatched markers
stay literal, and a line break ends any open emphasis. Runs of whitespace
collapse to one space and lines are trimmed, as HTML labels are. Other HTML
tags, Mermaid entity codes (`#quot;`), links, lists and headings are not
interpreted. A markdown string with no closing `` `" `` falls back to the
single-line quoted rule, so it reports `unterminated quoted text` as before.

## Wrapping rule

Lines wrap greedily at spaces so that no line is wider than 200px (upstream's
default `wrappingWidth`): a word moves to the next line only when the line
already holds something and the word plus the separating space would overflow.
A single word wider than 200px stays whole on its own line and widens the
node. Styled runs wrap word by word and keep their style on the next line.

Wrapping applies to every edge label and to the other node labels
(flowchart, state, agentflow, architecture, use case, ...). Compartment titles (ER entities, classes, requirements, C4 elements)
and group/subgraph titles are names: they honour explicit breaks only.

Nodes grow to fit the block: width is the widest line plus 40px (180px
minimum), and each extra line adds 20px to the shape's height (twice that for
the diamond). ER attribute rows, class compartments and subgraph children move
down below a multi-line title. Rank gaps grow with the edge labels drawn in
them: `widest line + 70px` across horizontal layouts, `block height + 64px`
down vertical ones (140px minimum either way).

## Metrics and backends

Widths are the native preview's own integer advances for Liberation Sans
Regular and Bold at 16px (italic faces share the upright advances), so the
preview, layout and SVG agree; `test_metrics_match_native_font` compares the
table with `graphics/ui/font.w` glyph by glyph. Non-ASCII code points measure
per code point: East Asian wide and emoji blocks take 16px, combining marks
0px, everything else 9px (10px bold). Pair kerning is ignored, which only
overestimates. Lines are 16px tall at a 20px pitch.

The display list carries one `MM_TEXT` primitive per styled run with
`text_style` bits (`MM_TEXT_BOLD`, `MM_TEXT_ITALIC`). SVG text uses
`font-family="Liberation Sans, Arial, Helvetica, sans-serif"` at
`font-size="16"` (Arial and Helvetica are metric-compatible), with
`font-weight="bold"` / `font-style="italic"` per run; every run is
XML-escaped. The native preview draws bold runs with the bold face at 16px
and italic runs with the italic face.

The parsed label keeps the source text verbatim (markers, `<br>` tags and
newlines included); only the rendered runs are rewritten, so editing stays
lossless. Canonical serialization (`mm_serialize`) refuses a label holding a
raw newline rather than emitting an approximation.

## Limits

- Family renderers outside `mm_render_graph` measure with the same
  per-glyph tables (issue #817): sequence participants, messages and notes,
  journey tasks, gantt labels (compact bar labels centre inside bars they
  fit, else sit just past the bar; tick labels centre on their tick),
  timeline columns, gitGraph commit spacing, block labels, kanban/mindmap
  boxes, UML notes, Cynefin badges, the data charts (pie legend columns,
  quadrant/xychart/radar/treemap/packet/Venn/Sankey labels) and C4 cards.
  Wrapping follows upstream where it wraps: LR timeline period and event
  text inside the `timeline.width` column (a single wider word widens it),
  kanban titles at `kanban.sectionWidth` and mindmap labels at
  `mindmap.maxNodeWidth` (both 200px), xychart category labels at their
  band width when the widest would collide, quadrant titles inside their
  quadrant, sequence text under `wrap`, and C4 names/descriptions.
  TD timeline text wraps like LR, and journey task labels wrap inside the
  task box (every box takes the tallest wrapped height).
  `family_text_test` pins each from the scene. GitGraph commit labels do
  not wrap. Sequence messages and
  notes, journey tasks and timeline entries use the rich layout when the
  label is a Markdown string or holds `<br>`; ER attribute comments and
  requirement text (Markdown emphasis) do too.
- UML notes and plain class members are single-line.
- In vertical layouts an edge label sits to the right of its connector and
  lane spacing does not yet widen for it, so a wide label can reach a
  neighbouring node in the same rank.
