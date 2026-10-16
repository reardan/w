# Native Mermaid data diagrams

This stage adds W-native parsers and family-specific display lists for eight
Mermaid diagram families. The library, CLI source read/write/edit commands,
native editor preview, and SVG export share the same document and geometry.
No JavaScript, browser layout, or external charting library is used.

Syntax reference: Mermaid **12.2.0**, pinned source documentation under
[packages/mermaid/src/docs/syntax](https://github.com/mermaid-js/mermaid/tree/mermaid%4012.2.0/packages/mermaid/src/docs/syntax).
This is a bounded core implementation, not a claim of complete Mermaid parity.
Unsupported syntax fails with a source diagnostic and suppresses the preview;
the original source remains available for lossless writing and editing.

| Family | Implemented syntax and semantics | Remaining compatibility |
| --- | --- | --- |
| `pie` | Quoted labels, positive decimal values, `showData`, title; angular proportions and percentage labels | Themes, collision avoidance for many small slices |
| `quadrantChart` | Title, two-ended x/y labels, four quadrant names, labeled points in `[0,1]²` | Point styles, classes, axis labels with unquoted hyphens |
| `xychart-beta` | Categorical, numeric-range or inferred x axis, numeric y range, bar and line series with point annotations, horizontal layout; signed values and zero baseline | Configuration, styled multi-series legends |
| `sankey-beta` | CSV source/target/value records, quoted commas and doubled quotes; DAG validation, node aggregation, proportional ribbon widths and longest-path columns | Multiline CSV fields, configuration, curved/crossing-optimized routing |
| `radar-beta` | Named axes and curves, positional and keyed curve values, min/max, circle/polygon graticule, bounded ticks, legend | Styles and smooth curves; keyed values require previously declared axes |
| `treemap-beta` | Indented quoted groups and positive valued leaves; recursive aggregate weights and alternating proportional rectangle subdivision | Styling/classes, squarified layout; labels in tiny cells use the accompanying hierarchy key |
| `venn-beta` | One to three named/labeled sets and labeled two/three-set `union` intersections; equal-size circle geometry with only declared overlaps | Explicit sizes, text nodes, styles and more than three sets |
| `packet` / `packet-beta` | Absolute inclusive bit ranges, individual bits, relative `+count`, title; 32-bit row wrapping and width proportional to bit count | Configurable word width, descending bit order and styles |

Standalone title statements work in all families except raw-CSV Sankey. Source comments and CRLF
formatting are retained. The data engine uses decimal thousandths, supports
values from -1,000,000 to 1,000,000 and at most three fractional digits, and
rejects exponent notation, NaN and infinity. Pie, treemap and Sankey values must
be strictly positive. Explicit chart ranges must contain their values.

Each document permits 256 data entries; each series permits 256 points. Radar
requires 3–32 axes and 1–20 ticks. Treemaps permit 16 nested groups. Packets permit
bits 0–4095 with disjoint fields in ascending order. These bounds supplement the
shared 1 MiB source limit and prevent unbounded rendering allocations.

Public modules are `libs.extras.mermaid.data_parse` and
`libs.extras.mermaid.data_render`. `mm_document.data` owns a `mm_data_chart`, whose
entries describe actual chart values, series, hierarchy, bit ranges or flow
endpoints; they are not converted into generic flowchart nodes. Coordinates are
deterministic and independent of the output backend. Display lists own their
strings and remain valid after their source document is freed.

Examples live in `examples/mermaid/{pie,quadrant,xy,sankey,radar,treemap,venn,packet}.mmd`.
For example:

```sh
./wbuild wmermaid wmermaid_editor
bin/wmermaid check examples/mermaid/radar.mmd
bin/wmermaid svg examples/mermaid/radar.mmd bin/radar.svg
bin/wmermaid_editor examples/mermaid/radar.mmd
./wbuild data_test data_64_test
```

Tests cover numeric validation, proportion geometry, axis matching, hierarchy,
CSV quoting, cycles, overlapping bit fields, XML escaping, lossless source,
source edits and every byte-prefix truncation of each family. Both word sizes
are exercised, including guard allocator leak checks. Full repository tests are
run on the integrated branch before publishing the PR.
