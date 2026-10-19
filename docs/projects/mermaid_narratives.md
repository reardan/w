# Native Mermaid ordered diagrams

The W Mermaid library, `wmermaid` CLI and `wmermaid_editor` desktop preview now
share native parsers and layouts for sequence, journey, timeline, Gantt and
ZenUML documents. They do not load Mermaid JavaScript or another rendering
engine. The compatibility reference is the official Mermaid **12.2.0** syntax
site; this implements the explicitly listed subsets, not full upstream parity.

All five families retain the original UTF-8 source, including whitespace and
comments. Existing `read`, `write`, byte-range `edit`, SVG export, editor history,
atomic save and live diagnostic behavior apply unchanged. Invalid or unsupported
input remains readable and saveable, and suppresses the preview. Scene text owns
its storage and survives document destruction. The existing 1 MiB source and
1,024-item budgets apply; sequence/ZenUML nesting is capped at 32 levels.

## Sequence diagrams

Reference: <https://mermaid.js.org/syntax/sequenceDiagram.html>.

Supported: `sequenceDiagram`, `title`, `participant` and `actor`, external `as`
aliases, implicit participants, solid/dashed messages with `->`, `-->`, `->>`,
`-->>`, `-x`, `--x`, `-)`, `--)`, `<<->>` and `<<-->>`; self messages; `Note`
(or `note`) over one/two participants or left/right of one; `activate`,
`deactivate` and message `+`/`-` shorthand; `autonumber`, integer start/increment ranges, `autonumber off` and bare
`autonumber` to resume; `create participant`/`create actor` (including aliases)
and `destroy`; nested `loop`, `alt`,
`opt`, `par`, `critical` and `break` fragments, their appropriate `else`, `and`
and `option` branches, and `end`; `rect <color>` highlight regions; and
`box [color] [label]` participant groups.

`box` must be top-level and may contain only `participant`/`actor` declarations,
each of which must be that participant's first appearance, so a box always
covers contiguous lanes. The first word is the box fill when it parses as a
supported color (a case-insensitive name, `#RGB`/`#RRGGBB`, `rgb()`, `rgba()` or
`transparent`); otherwise the whole text is the label. `rect` requires such a
color and nests with fragments like any other block, but takes no branches.
`rgba()` alpha is composited over the white background, because native
primitives carry opaque colors. Boxes draw behind the lanes with a centred
label; rect highlights draw as filled, borderless bands behind their messages.

The layout has ordered participant headers, actor figures, dashed lifelines,
message arrowheads/crosses, activation bars, note boxes, numbered messages and
nested fragment frames. Plaintext label width affects lane spacing. Unclosed
activations extend to the diagram bottom or participant destruction; unmatched
deactivation is an error. Created participants enter at their creation message,
and destroyed lifelines end with a cross. Lifecycle directives require the next
event to be their message; creation targets the new participant, destruction
involves the named participant, and later messages/notes/activations using a
destroyed participant are errors. Numbering continues while hidden; restarting
with an explicit integer sets a new range. Starts are 0–1,000,000 and increments
are 1–1,000,000.

Not yet supported: participant configuration objects/stereotypes, participant
configuration after creation, `links`/`link` menus, fractional numbering,
half-arrows, multiline/rich labels or browser styling. Arbitrary control
keywords do not silently become participants.

Example: [sequence.mmd](../../examples/mermaid/sequence.mmd).

## User journeys

Reference: <https://mermaid.js.org/syntax/userJourney.html>.

Supported: `journey`, title, sections and `Task: score: Actor, Other actor`.
Scores must be integers 1–5; actor lists are optional. Tasks remain in source
order. The preview shows section labels, task cards, actor labels and a connected
score plot with numbered points on a 1–5 vertical scale.

This uses the scores and actor metadata natively; it does not reproduce Mermaid's
colored avatar legend, face icons, theme configuration or HTML labels.

Example: [journey.mmd](../../examples/mermaid/journey.mmd).

## Timelines

Reference: <https://mermaid.js.org/syntax/timeline.html>.

Supported: `timeline`, title, sections, period labels, multiple colon-separated
events and continuation lines starting with a colon. Period labels are ordinal
text, not parsed dates. Each period owns a chronological column on a horizontal
axis, with its events stacked below it. Empty event labels and an event without
a preceding period are errors.

Rich labels, configurable colors/themes and alternative wrapping/layout choices
remain unsupported.

Example: [timeline.mmd](../../examples/mermaid/timeline.mmd).

## Gantt charts

Reference: <https://mermaid.js.org/syntax/gantt.html>.

Supported: `gantt`, title, `dateFormat YYYY-MM-DD`, sections, task IDs, explicit
start/end dates, positive integer day/week durations (`3d`, `2w`), sequential
starts after the previous task, and `after taskID` dependencies, including forward references and multiple
space-separated IDs (the latest dependency end wins). `until taskID` ends at
the referenced task start. The first task needs an explicit date or dependency. Calendar dates validate Gregorian leap
years and accept years 1970–9999. `done`, `active`, `crit` and `milestone` tags
are represented using completion lines, an active label, a double border and a
diamond respectively; milestones can use `0d`.

The preview uses a common calendar axis and proportional start positions/bar
lengths. Date ticks maintain enough spacing to stay readable. Dependencies
resolve after parsing the complete chart; unknown references, dependency cycles,
ends before starts, and schedules beyond year 9999 fail.

Not yet supported: alternative date formats or sub-day time units,
exclusions/weekends, timezone/today settings,
axis formatting, interactive links, click handlers or configurable styles.
Unsupported scheduling directives fail rather than producing an incorrect chart.

Example: [gantt.mmd](../../examples/mermaid/gantt.mmd).

## ZenUML

Reference: <https://mermaid.js.org/syntax/zenuml.html>.

Supported: `zenuml`, title, bare participants, `as` aliases, `@Actor`, async
`A->B: message`, sync `B.method` and `B.method(args)`, explicit-caller
`A->B.method(args)`, multiline nested call bodies in braces, `return text`,
`if`/`} else {` alternatives, `while`/`for` loops, `loop` fragments, `opt` and
`par`. Nested synchronous calls use the enclosing receiver as their caller;
a top-level call without an explicit caller uses an `External` participant.
Balanced method arguments are required. Calls and returns become native
lifeline messages with activation bars; control constructs become frames.

Not yet supported: creation messages, assignment-form replies, `@return`/
`@reply`, other participant annotations, try/catch/finally, every loop spelling,
multiple statements on a line, inline brace bodies, rich comments or styles.
`//` comments are retained in source but not displayed above messages. Quoted
arguments do not currently process backslash escapes. Statements outside the
listed subset fail explicitly.

Example: [zenuml.mmd](../../examples/mermaid/zenuml.mmd).

## Validation

`./wbuild narrative_test narrative_64_test` checks message arrows, actor aliases,
fragments, activation validation, journey score geometry, timeline event grouping,
Gregorian dates/dependencies/status, nested ZenUML calls and returns, lossless
edits, malformed/truncated input, ownership and source/item/layout bounds.
The same display list drives SVG and native desktop rendering; examples are
also exercised through CLI check/export and native screenshot smoke checks.
