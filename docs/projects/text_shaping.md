# Shaped text runs

`graphics.ui.shape` shapes OpenType text runs for applications that need more
than codepoint drawing. It has two engines behind one API:

- **Portable** (`lib.ttf_shape` over `lib.ttf_layout`, wrapped by
  `graphics.ui.shape_ot`): pure W, every target. Import `graphics.ui.shape_ot`
  alone where no shared library may be loaded (static x86, wasm, macOS,
  Windows).
- **Native**: the Linux x64 HarfBuzz adapter, which dynamically loads
  `libharfbuzz.so.0` (needs the Linux loader and `libdl.so.2`).
  `ui_shape_available()` reports whether it loaded.

`ui_shape_set_engine(UI_SHAPE_ENGINE_AUTO | _NATIVE | _PORTABLE)` selects the
engine: AUTO (the default) uses HarfBuzz when present and the portable engine
otherwise, NATIVE returns `UI_SHAPE_UNAVAILABLE` without HarfBuzz, and PORTABLE
never loads it. `run.engine` records which one produced a run. Ordinary UI text
has no HarfBuzz link dependency.

`ui_shape_utf8(text, byte_length, strike, direction, script, language,
max_glyphs)` returns an owned `ui_shaped_run`, including on failure. Check
`run.status` against `UI_SHAPE_OK`, `UI_SHAPE_INVALID`, `UI_SHAPE_UNAVAILABLE`,
`UI_SHAPE_LIMIT`, or `UI_SHAPE_FAILED`; free it with `ui_shaped_run_free`.
Input is validated UTF-8 with an explicit length, including embedded NUL.
Choose an existing font strike, `UI_SHAPE_LTR`, `UI_SHAPE_RTL`, or
`UI_SHAPE_AUTO`, an ISO 15924 script tag packed as a big-endian integer (zero
means guess), and a terminated BCP 47 language name (null means `und`; the
portable engine accepts it for parity and uses the font's default language
system).

The run owns visual-order glyph IDs, UTF-8 byte clusters, signed offsets and
advances in 1/64 pixel units. `advance` is the total horizontal advance.
`ui_draw_shaped_run(renderer, x, y, run, color)` draws those glyph IDs through
the existing TrueType atlas and renderer's clipping/batching, preserving the
shaper's fractional positions without applying pair kerning again. `x,y`
locates the line box's top-left. `ui_font_glyph_id` lets any shaping engine use
the same rasterizer and cache.

## The portable engine

`ttf_shape(font, cps, clusters, count, rtl, script, language, flags)` returns an
`otl_buffer` of positioned glyphs in visual order, in font units. It follows
HarfBuzz's default, Arabic, Hebrew, Indic (Devanagari) and Thai/Lao shapers:

- **Normalization** against the font's cmap (decompose, reorder by modified
  combining class, recompose), with default ignorables hidden and RTL mirroring.
- **GSUB** types 1-8 (`lib.ttf_layout`) with GDEF classes, mark attachment
  classes and mark filtering sets, lookup flags, and script/language/feature
  selection: `ccmp`/`locl`, Arabic `isol`/`fina`/`medi`/`init` from Unicode
  joining types, `rlig`/`rclt`/`calt`/`liga`/`clig`, and for Devanagari the
  `nukt`/`akhn`/`rphf`/`rkrf`/`blwf`/`half`/`vatu`/`cjct` basic and
  `pres`/`abvs`/`blws`/`psts`/`haln` presentation features with syllable
  analysis and reph and pre-base matra reordering.
- **GPOS** types 1-9: `kern`, mark-to-base, mark-to-ligature, mark-to-mark,
  cursive attachment, `dist`, `abvm`/`blwm`.
- **Fallbacks** for fonts without the tables: Arabic presentation forms
  (including lam-alef and shadda ligatures) from the font's cmap, Hebrew
  presentation compositions, legacy `kern` table pairs, and HarfBuzz's
  combining-class mark placement.

`ttf_shape_no_liga` and `ttf_shape_no_kern` flags turn off ligatures and
kerning. Other complex scripts (Bengali and the other Indic scripts,
Myanmar, Khmer, the Universal Shaping Engine scripts) shape through the default
shaper: their GSUB/GPOS features apply, but without script-specific reordering.

`tools/shape_dump.w` prints a run in `hb-shape` format and
`tools/shape_compare_hb.py` diffs it against HarfBuzz 15 (uharfbuzz). Across 62
system TrueType fonts, nine Noto fonts and the installed CFF fonts over a
multi-script corpus, with GSUB/GPOS/GDEF/kern hidden in turn to reach every
fallback, the remaining differences are a fallback Greek mark offset in
OpenSymbol, a one-unit double-width mark rounding in FreeSans without GPOS, and
Unifont's Arabic presentation ligatures.

## Carets, clusters and fonts

Clusters identify source ranges and may combine several graphemes in one
ligature. `ui_shaped_caret_x(run, text, offset)` maps a grapheme boundary to x
over a run, dividing a ligature evenly among the graphemes it covers and
running right to left in an RTL run; `ui_shaped_offset_from_x` is its inverse.
Shape again after changing the text, selected face, size, script or language.
The ordinary `ui_draw_text` and widget text paths continue to use codepoint
drawing, where a nonspacing mark now takes no advance and sits on its base
(centred on it when it comes from a fallback face); opt in to shaping
explicitly when laying out document runs.

The host must split paragraphs by bidi direction, script and font, choose
fallbacks and line breaks, and assemble the resulting runs into visual order.
The paragraph bidi API described below supplies directional runs and their
visual order for either an unwrapped paragraph or caller-selected wrapped
lines. `AUTO` direction guesses one run's direction from its first strong
character; it is not paragraph bidi.

The embedded faces cover Latin, Greek and Cyrillic, and no larger fallback face
is bundled: a Noto set covering the world's scripts is tens of megabytes, which
the compiler tree and wasm builds should not carry. Load a face with coverage
for the required script using `ui_font_face_load_ttf` or
`ui_font_face_load_bytes` (TrueType `glyf` or CFF `OTTO` outlines, including
CID-keyed CJK fonts), register it with `ui_font_add_fallback` for codepoint
text, create its strike, and shape that run. A shaped run does not fall back
inside itself: missing coverage produces the selected face's `.notdef` glyph.
Color glyphs and hinting remain outside the rasterizer; CFF hint operators are
read and skipped, as the rasterizer draws unhinted outlines at every size.

Calls accept at most 65536 source bytes and an output budget between zero and
1048576 glyphs. Failure returns no partial glyph array. HarfBuzz owns its
temporary shaping allocations and execution, and the native adapter provides
no native-call timeout or allocation budget. Font bytes, strikes and atlas
caches retain their existing process lifetime; runs must be freed
individually. Use the UI thread, as the shared font/atlas and lazy adapter
initialization are not synchronized.

## Tests

- `./wbuild ttf_shape_test` (and `ttf_shape_64_test`) checks the portable
  engine against 46 lines of recorded HarfBuzz 15 output
  (`tests/data/shape_golden.txt`, regenerated by `tools/shape_golden_hb.py`)
  over Liberation Sans and the small OFL Noto subsets in `tests/data/fonts/`,
  including fonts with tables hidden, plus joining forms, normalization
  tables, script selection, options and RTL mirroring.
- `./wbuild ttf_cff_test` compares CFF paths with fontTools output
  (`tests/data/cff_paths.txt`, from `tools/cff_paths_ref.py`) for a name-keyed
  and a CID-keyed font, and rasterizes and shapes them.
- `./wbuild graphics_ui_shape_test` runs strict UTF-8, explicit-length NUL,
  empty runs, invalid inputs, output limits, mark positioning, Hebrew RTL
  clusters, an in-memory GSUB `fi` ligature, Arabic and Devanagari runs, engine
  selection, carets and headless rendering through both engines, skipping the
  native one visibly when HarfBuzz is unavailable.

The native adapter uses the published HarfBuzz contracts for
[buffers and clusters](https://harfbuzz.github.io/harfbuzz-hb-buffer.html),
[read-only font blobs](https://harfbuzz.github.io/harfbuzz-hb-blob.html), and
[shaping](https://harfbuzz.github.io/shaping-and-shape-plans.html).

## Paragraph bidi analysis

`graphics.ui.bidi` analyzes paragraphs with two engines, like shaping. The
portable one is `lib.bidi`, a W implementation of UAX #9 (Unicode 15.0.0) that
passes all 91,707 lines of the Unicode `BidiCharacterTest.txt`
(`bin/bidi_conformance path/to/BidiCharacterTest.txt`; `./wbuild bidi_test`
checks a committed sample). `graphics.ui.bidi_portable` wraps it with no native
dependency. The native one is the Linux x64 adapter for `libfribidi.so.0`;
`ui_bidi_available()` checks the library and required symbols, and its Unicode
data version is supplied by the installed FriBidi.
`ui_bidi_set_engine(UI_BIDI_ENGINE_AUTO | _NATIVE | _PORTABLE)` selects the
engine as `ui_shape_set_engine` does. Ordinary UI text gains no FriBidi
dependency.

`ui_bidi_utf8(text, byte_length, direction, max_scalars)` analyzes one paragraph
and supplies its unwrapped layout. Choose `UI_BIDI_AUTO`, `UI_BIDI_LTR`, or
`UI_BIDI_RTL`. AUTO uses the first strong direction outside isolates, falling
back to LTR. UTF-8 must be valid; embedded NUL and supplementary scalars are
accepted. Hard line/paragraph separators (LF, CR, VT, FF, U+001C–U+001E, NEL,
U+2028 and U+2029) are rejected. Split these at the document layer. Tabs are
accepted, but this API does not calculate tab-stop positions.

The result is always an owned `ui_bidi_paragraph`, including on failure; release
it with `ui_bidi_paragraph_free`. Check `status` for `UI_BIDI_OK`,
`UI_BIDI_INVALID`, `UI_BIDI_UNAVAILABLE`, `UI_BIDI_LIMIT`, or `UI_BIDI_FAILED`.
Failures have no partial arrays. Empty input succeeds without the native
library, has no runs, and retains the requested explicit direction (AUTO uses
LTR). The result owns:

- `count` Unicode scalars, `source_bytes`, and the resolved paragraph `direction`.
- `byte_offsets[count + 1]`, including the final byte-length sentinel.
- `levels[count]` in logical source order, including the trailing-whitespace
  reset for this single line.
- Inverse `logical_to_visual` and `visual_to_logical` scalar-index maps.
- `runs[run_count]` in logical order, each with `byte_start`, `byte_length`,
  `scalar_start`, `scalar_count`, `level`, and `direction`.
- `visual_runs[run_count]`, indexing `runs` from the leftmost run to the rightmost.

The paragraph also owns `bidi_types` and `resolved_levels`, retaining native
analysis before line-specific resets. Treat all output fields as read-only;
use the line API below to lay out a different width. The input text is not
retained or borrowed and may be released after analysis.

The maps represent bidi reordering of scalars. They are not glyph arrays,
grapheme boundaries, or a caret/selection model. Controls retain their source
indices. No source text is reordered, mirrored, or converted to Arabic
presentation forms. Shape each run's original logical UTF-8 slice; the shaper
handles combining marks, mirroring and glyph order. For a paragraph whose
directional runs already have one script and a suitable font, the integration
looks like this (direction constants match the shaping API):

```w
ui_bidi_paragraph* paragraph = ui_bidi_utf8(text, length, UI_BIDI_AUTO, 65536)
if (paragraph.status == UI_BIDI_OK):
	int advance = 0
	for i in range(paragraph.run_count):
		ui_bidi_run* item = &paragraph.runs[paragraph.visual_runs[i]]
		ui_shaped_run* run = ui_shape_utf8(text + item.byte_start, item.byte_length, strike, item.direction, 0, 0, 65536)
		if (run.status == UI_SHAPE_OK):
			ui_draw_shaped_run(renderer, x + cast(float32, advance) / 64.0, y, run, color)
			advance = advance + run.advance
		ui_shaped_run_free(run)
ui_bidi_paragraph_free(paragraph)
```

Shaped cluster offsets are relative to the slice: add `item.byte_start` to map
them back into the document. Directional runs may still contain several scripts
or require font fallback. The host must subdivide them further and order those
subruns according to the enclosing direction. Line wrapping remains a separate
layout step: do not independently analyze each wrapped line, because paragraph
context affects bidi resolution. Use the retained analysis as described below.
Neither API changes default widget rendering or adds native IME support.

### Wrapped lines and reflow

`ui_bidi_reorder_line(paragraph, scalar_start, scalar_count)` returns an owned
`ui_bidi_line` for a contiguous logical scalar range of a successful paragraph.
The caller selects line breaks from measured/shaped text. Arguments are scalar
indices, not UTF-8 byte offsets; a range cannot split a UTF-8 scalar. The caller
must also avoid breaking graphemes or shaping clusters and implement its own
line-break policy. This API does not measure widths or choose break positions.

Each call copies the selected resolved levels, applies line-ending whitespace
resets and produces new visual ordering. It retains the paragraph's base
direction, paired-bracket resolution, numeric context, isolates and overrides,
even when their establishing text is outside the line. The trailing reset
includes isolate controls and intervening whitespace, including on FriBidi
versions whose native line reset omits isolates. Retained explicit controls and
boundary neutrals follow the same trailing reset convention. Native scalar
mark reordering stays disabled: shape original logical slices to position marks.

Check `line.status`, then consume:

| Field | Coordinate system |
| --- | --- |
| `direction` | Resolved paragraph direction |
| `scalar_start`, `count` | Paragraph scalar start and line scalar count |
| `byte_start`, `byte_length` | Line range in the original paragraph's UTF-8 |
| `byte_offsets[count + 1]` | Original paragraph byte offsets, including the line-end sentinel |
| `levels[count]` | Logical line-local indices, after line-specific resets |
| `logical_to_visual`, `visual_to_logical` | Inverse scalar maps; both indices and values are line-local |
| `runs[run_count]` | Logical order; each run's byte/scalar starts are paragraph-relative |
| `visual_runs[run_count]` | Indices into this line's `runs`, leftmost to rightmost |

For example, a visual scalar index `v` maps to paragraph scalar
`line.scalar_start + line.visual_to_logical[v]` and paragraph byte offset
`line.byte_offsets[line.visual_to_logical[v]]`. These remain scalar positions,
not caret or glyph positions. As for an unwrapped paragraph, add a run's
`byte_start` to its shaped cluster offsets to obtain paragraph byte offsets.

```w
# paragraph is successful; the application has selected a legal scalar range.
ui_bidi_line* line = ui_bidi_reorder_line(paragraph, first_scalar, scalar_count)
if (line.status == UI_BIDI_OK):
	int advance = 0
	for i in range(line.run_count):
		ui_bidi_run* item = &line.runs[line.visual_runs[i]]
		# Each directional run must still be segmented by script/font as needed.
		ui_shaped_run* run = ui_shape_utf8(text + item.byte_start, item.byte_length, strike, item.direction, 0, 0, 65536)
		if (run.status == UI_SHAPE_OK):
			ui_draw_shaped_run(renderer, x + cast(float32, advance) / 64.0, y, run, color)
			advance = advance + run.advance
		ui_shaped_run_free(run)
ui_bidi_line_free(line)
```

Lines own every output array and survive paragraph disposal. Reordering a line
does not mutate the paragraph or earlier lines; overlapping ranges, different
widths and out-of-order calls are supported. Free each line, including failed
results, with `ui_bidi_line_free`; freeing null is a no-op. The original text
must remain available separately if the application will shape it later.

Null/failed paragraphs and negative or out-of-range scalar ranges return
`UI_BIDI_INVALID`, checked without addition overflow. An empty range at any
valid boundary (including paragraph end) succeeds without a native call; it
owns one byte-offset sentinel and has no runs/maps/levels. Nonempty lines can
return `UI_BIDI_UNAVAILABLE` or `UI_BIDI_FAILED`; failures own no partial arrays.
Each line is bounded by its validated paragraph (at most 65536 scalars), with
storage proportional to the selected range, not the whole paragraph. The caller
bounds the number of simultaneously retained lines. Whole-paragraph line output
matches the unwrapped layout.

Inputs and budgets are capped at 65536 bytes/scalars. W-owned arrays are bounded
by that cap, while the native engine's temporary allocations and execution remain under
FriBidi's control with no timeout. As with shaping, lazy native initialization
is unsynchronized; use the UI thread.

`./wbuild graphics_ui_bidi_test` covers mixed Hebrew/Latin/numbers, paired
punctuation, isolates, explicit overrides, trailing whitespace, inverse maps
and byte ranges, UTF-8 rejection, NUL, supplementary scalars, the maximum
budget, empty input, unavailable-native behavior and native failure cleanup.
A headless integration case shapes logical slices in visual run order and
keeps a Hebrew combining mark attached to its base. Wrapped-line tests cover
LTR/RTL whitespace resets, digits and paired brackets retaining context,
cross-line isolates/overrides, trailing isolate controls, independent reflow,
paragraph disposal, empty and invalid ranges, NUL/supplementary offsets, maximum
ranges, native failure cleanup, and shaped marks at nonzero document offsets.
Native tests visibly skip
when their optional library is unavailable; the portable engine runs every
case.

The adapter uses FriBidi's published
[paragraph and line ABI](https://github.com/fribidi/fribidi/blob/master/lib/fribidi-bidi.h)
and [paired-bracket API](https://github.com/fribidi/fribidi/blob/master/lib/fribidi-brackets.h).
The line suffix reset follows [Unicode bidi rule L1](https://www.unicode.org/reports/tr9/#L1)
and the [retained-control convention](https://www.unicode.org/reports/tr9/#Retaining_Explicit_Formatting_Characters),
using the published [FriBidi type masks](https://github.com/fribidi/fribidi/blob/master/lib/fribidi-bidi-types.h).
