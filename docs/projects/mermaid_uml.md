# Native Mermaid class and state compatibility

The native parser follows the bounded class/state subset documented in the
[compatibility matrix](mermaid_compatibility.md), using Mermaid 12.2.0 as the
syntax reference. Source preservation, diagnostics and the shared native/SVG
scene apply to these additions.

Class identifiers can use backticks for spaces or punctuation. Generic class
suffixes retain the base identifier for relationships and display angle-bracket
parameters: `class Box~List~T~~` displays `Box<List<T>>`, and relationships refer
to `Box`. Comma-separated parameters are accepted at every level:
`class Map~K, List~V~~` displays `Map<K, List<V>>`. Nesting depth and the
parameters in one list are each limited to 32; an empty parameter or a missing
closing `~` is diagnosed. Existing class member text retains its source spelling.

Dotted namespaces create intermediate groups. `namespace Company.Backend` and a
nested `namespace Backend` within `Company` use the same qualified namespace
identity. Reopening a namespace adds to that group; an explicit
`namespace Company.Backend["Backend services"]` label survives later reopenings.
Classes keep global identifiers, matching Mermaid. Namespace paths and syntactic
nesting together are limited to 32 levels.

Class `()--` and `--()` relationships create unique lollipop interface endpoints.
Repeated interface names do not share an interface vertex or overwrite an
ordinary class with that name. Interfaces render as circles with their labels;
relationship endpoints attach to the circles.

State transitions can cross composite boundaries and reference states before
their declarations. Explicit declarations determine ownership, while edge routing
uses the nearest common containing group. Conflicting declarations and cyclic
containment are errors. Scoped initial/final states remain distinct.

A `--` line inside a composite state splits it into concurrent regions. Each
region is an anonymous group (identifier `@region:N`) inside the composite, so
`[*]` start/end states are scoped per region and transitions may still cross
regions. The first separator moves the statements already seen into region zero.
Regions render as unlabelled dashed partitions. A separator outside a composite,
and an empty leading, middle or trailing region, are errors.

Class notes support `note for Class "text"` and standalone `note "text"`.
State notes support `note left of State : text`, `note right of State : text`,
and multiline bodies ending in `end note`. Notes are owned annotations, not
layout vertices. They render in side gutters with dashed attachments, or below
the chart for standalone notes, without covering graph groups. Actual newlines
and `\n` split note text into visible lines. At most 1,024 notes are accepted.

These changes do not add class click handlers, browser interactions,
rich HTML labels or upstream layout parity. States take `style`, `classDef`,
`class` and `:::` (see [styling](mermaid_styling.md)). Notes use deterministic gutter placement rather than upstream placement.

`./wbuild uml_test uml_64_test` verifies generic identity and comma parameter lists, namespaces and labels,
concurrent state regions, unique interfaces, cross-scope transitions, note ownership, and truncated note
input alongside the existing relationship, group and member tests.
