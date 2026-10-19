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
and `destroy`; participant menus via `link A: Label @ url` and
`links A: {"Label": "url", ...}` (a JSON object of strings with `\"`/`\\`
escapes), stored in source order on the participant's metadata (at most 64 per
participant; the participant must already exist); nested `loop`, `alt`,
`opt`, `par`, `critical` and `break` fragments, their appropriate `else`, `and`
and `option` branches, and `end`.

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
configuration after creation, boxes, rect highlighting, rendering link menus
(they are kept in the model; the SVG has no interactive menus), `properties`/
`details`, half-arrows, multiline/rich labels or browser styling. Upstream
`autonumber` takes integers only, so fractional numbering is not offered. Arbitrary control
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
events and continuation lines starting with a colon. `<br>`, `<br/>` and
`<br />` (any case) in period or event text break the label into display lines;
the model keeps the source text, boxes grow per line and all period headers share
the tallest header's height. Period labels are ordinal
text, not parsed dates. Each period owns a chronological column on a horizontal
axis, with its events stacked below it. Empty event labels and an event without
a preceding period are errors.

Other rich labels, configurable colors/themes (`disableMulticolor` is moot: the
native timeline is single-colored) and alternative wrapping/layout choices remain
unsupported.

Example: [timeline.mmd](../../examples/mermaid/timeline.mmd).

## Gantt charts

Reference: <https://mermaid.js.org/syntax/gantt.html>.

Supported: `gantt`, title, sections, task IDs, explicit
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

`dateFormat` accepts any arrangement of `YYYY`, `MM`, `DD` and optionally
`HH` with `mm`, separated by non-alphanumeric literals (`DD-MM-YYYY`,
`YYYY/MM/DD`, `MM.DD.YYYY`, `YYYY-MM-DD HH:mm`, ...). It applies to every later
date and must precede tasks, exclusions and a fixed today marker. A format with
a time of day switches the chart to minute units: durations then also accept
`h` and `m` (`90m`, `2h`) and dates are limited to years 1970–4000 so every
moment fits a 32-bit integer; minute durations are capped at 3,660 days.

`excludes` takes `weekends`, weekday names and dates (space or comma separated,
dates in the active format or `YYYY-MM-DD`); `includes` takes dates that override
exclusions, and `weekend friday|saturday` picks the two-day weekend. Duration
ends count only working time: a task starting on an excluded day accrues no work
until the next working day (its bar still starts on the given date), and explicit
end dates and `until` ends are not moved.
Excluded days within the chart are shaded (charts longer than 1,000 days skip the
shading). Scheduling uses whole-week arithmetic plus a binary search, so long
chains over exclusion calendars stay bounded.

`axisFormat` uses strftime tokens `%Y %y %m %d %e %b %B %a %A %H %I %M %p %j %%`;
the default is `%Y-%m-%d` (`%Y-%m-%d %H:%M` for minute charts). Minute-chart
ticks snap to clock intervals (minutes, hours, days, weeks) and tick spacing grows
with the label width. `todayMarker off` and style-only `todayMarker` lines are
accepted; the native renderer never reads the wall clock, so a red marker is
drawn only for a fixed date (`todayMarker 2026-10-08`, a native extension) inside
the charted range. `click ID href "url"` stores the URL as `href` metadata on
the task's node (the SVG writer has no link primitive, so it is not yet emitted
as `<a>`); the ID must name a task, and `call` callbacks are rejected.

Not yet supported: timezones, `inclusiveEndDates`, `topAxis`, `tickInterval`,
`weekday`, month/year/second duration units, other moment.js tokens, click
callbacks, rendered links or configurable styles. Unsupported scheduling
directives fail rather than producing an incorrect chart.

Example: [gantt.mmd](../../examples/mermaid/gantt.mmd).

## ZenUML

Reference: <https://mermaid.js.org/syntax/zenuml.html>.

Supported: `zenuml`, title, bare participants, `as` aliases, `@Actor` and
any other `@Annotation` participant kind (`@Boundary`, `@Database`, `@Control`,
`@Entity`, `@Queue`, ... shown as a `<<Annotation>>` stereotype line), async
`A->B: message`, sync `B.method` and `B.method(args)`, explicit-caller
`A->B.method(args)`, multiline nested call bodies in braces, inline bodies on one
line (`A.m() { B.n(); C.o() }`, `if(x) { ... } else { ... }`), `return text`,
assignment replies `x = A.m()` / `Type x = A.m()` (a dashed reply labelled `x`;
for a call with a body the reply follows the body), creation `new A(args)`
(also assigned and with a body: the participant's header starts at its creation
when it was not used before), `if`/`} else {` alternatives, `try {` with
`} catch(...) {` and `} finally {` branches, `while`/`for` loops, `loop`
fragments, `opt` and `par`. Nested synchronous calls use the enclosing receiver as their caller;
a top-level call without an explicit caller uses an `External` participant.
Balanced method arguments are required. Calls and returns become native
lifeline messages with activation bars; control constructs become frames.

Not yet supported: `@return`/`@reply`, `@Starter`, participant icons for
annotations (they render as stereotype text), every loop spelling, rich
comments or styles. Braces inside quoted arguments or after an async message's
colon stay label text.
`//` comments are retained in source but not displayed above messages. Quoted
arguments do not currently process backslash escapes. Statements outside the
listed subset fail explicitly.

Example: [zenuml.mmd](../../examples/mermaid/zenuml.mmd).

## Validation

`./wbuild narrative_followup_test narrative_followup_64_test` covers Gantt
exclusions/includes/weekends, date formats and minute units, axis tokens, the
fixed today marker, click links, ZenUML creation/assignment/annotations/try and
inline bodies, sequence link menus and timeline line breaks, including their
diagnostics and every source prefix. `./wbuild narrative_test narrative_64_test` checks message arrows, actor aliases,
fragments, activation validation, journey score geometry, timeline event grouping,
Gregorian dates/dependencies/status, nested ZenUML calls and returns, lossless
edits, malformed/truncated input, ownership and source/item/layout bounds.
The same display list drives SVG and native desktop rendering; examples are
also exercised through CLI check/export and native screenshot smoke checks.
