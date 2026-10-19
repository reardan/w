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
| `pie` | Quoted labels, positive decimal values, `showData`, title; colored sectors and matching legend keys, angular proportions, collision-safe legend rows with percentages and optional values; interior percentages only for sufficiently wide slices | Custom slice palettes |
| `quadrantChart` | Title, one- or two-ended x/y labels, four quadrant names, hyphenated unquoted axis labels, labeled points in `[0,1]²`, direct point styles and forward `classDef` references with direct-over-class precedence | Chart configuration and typography |
| `xychart-beta` | Categorical, numeric-range or inferred x axis, numeric y range, bar and line series with point annotations and matching colored legend keys, horizontal layout; signed values and zero baseline | Configuration and custom plot palettes |
| `sankey-beta` | CSV source/target/value records, quoted commas, doubled quotes and multiline fields (LF or CRLF); DAG validation, node aggregation, proportional smooth ribbons, longest-path columns and weighted predecessor ordering to reduce crossings; multiline label layout | Configuration and global crossing optimization |
| `radar-beta` | Named axes and curves, positional and keyed curve values with axes declared before or after curves, min/max, circle/polygon graticule, bounded ticks, colored curves and matching legend keys | Custom curve palettes and smooth curves |
| `treemap-beta` | Indented quoted groups and positive valued leaves; recursive aggregate weights and stable weight-sorted squarified rectangle subdivision; labels in tiny cells use the accompanying hierarchy key; `classDef` (fill, stroke, color, stroke-width) assigned with `:::class` on groups or leaves, outranking the theme | `style` statements and per-depth palettes |
| `venn-beta` | One to three named/labeled sets and labeled two/three-set `union` intersections; only declared overlaps; explicit set/intersection sizes for one or two sets; text nodes attached to the preceding set or union | Explicit sizes with three sets, styles and more than three sets |
| `packet` / `packet-beta` | Absolute inclusive bit ranges, individual bits, relative `+count`, title; configurable word width, ascending or descending bit order, row wrapping and width proportional to bit count | Styles |

Standalone title statements work in all families except raw-CSV Sankey. Source comments and CRLF
formatting are retained. The data engine uses decimal thousandths, supports
values from -1,000,000 to 1,000,000 and at most three fractional digits, and
rejects exponent notation, NaN and infinity. Pie, treemap, Sankey and explicit Venn sizes must
be strictly positive. Explicit chart ranges must contain their values.

Each document permits 256 data entries; each series permits 256 points. Radar
requires 3–32 axes and 1–20 ticks. Treemaps permit 16 nested groups. Packets permit
bits 0–4095 with disjoint fields declared in ascending order. Frontmatter
`config.packet.bitsPerRow` accepts 1–128 (default 32), and
`config.packet.bitOrder` accepts `ascending` (default) or `descending`.
Descending order mirrors each complete word independently, including padding on
the left of a partially filled word; it does not change source range ordering.
These bounds supplement the shared 1 MiB source limit and prevent unbounded
rendering allocations.

Quadrant point styles support `color`, `radius`, `stroke-color` and
`stroke-width`, either after point coordinates or in `classDef name ...`.
Attach a class as `Point:::name: [0.5,0.5]`. Radius is an integer in 1–64;
stroke width is 1–16, optionally followed by `px`. Colors use the shared native
CSS subset (hex, named colors, `none`/`transparent`). Unknown properties,
classes, invalid values and duplicate class definitions produce diagnostics.

Pie, XY and radar use a fixed twelve-color sequence with matching legend keys.
These series colors take precedence over the global theme's generic fill and
stroke; background and ordinary text still follow the theme. Custom chart
palettes are not yet accepted. Very small pie slices keep their percentages in
the legend so interior text cannot crowd adjacent slices.

Explicit Venn sizes scale circle areas, and a bounded binary search solves the
two-circle intersection distance. Geometry is rounded to pixels, with a minimum
one-pixel radius; extremely small sets and long text can still crowd labels.
Duplicate intersections (including a reversed set list) are rejected, and a union
cannot exceed either member's size. The scene expands and translates to keep
long centered labels inside its viewport. Unsized sets default to 10 and
unsized unions to 10 divided by the square of their arity. Three-set size
constraints are rejected instead of drawing an approximate constraint solution.
Sankey ordering is a stable, weighted predecessor heuristic, not a global
crossing minimizer; its smooth ribbon boundaries are sampled into polygons.
Treemap dimensions are rounded to whole pixels. At extreme weight ratios a
subpixel leaf may have no visible rectangle; the hierarchy key always retains
every entry and its exact value. The renderer does not force every leaf to have a visible rectangle at the cost
of distorting those extreme proportions.

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
CSV quoting and multiline truncation, forward radar references, treemap area and
non-overlap, dense pie labels, series-to-legend color matching, curved Sankey
ribbons and weighted node ordering, quadrant class/style precedence, explicit
Venn circle/intersection areas and text nodes, cycles, overlapping bit fields, configurable packet
word wrapping and mirrored partial rows, XML escaping, lossless source,
source edits and every byte-prefix truncation of each family. Both word sizes
are exercised, including guard allocator leak checks. Full repository tests are
run on the integrated branch before publishing the PR.
