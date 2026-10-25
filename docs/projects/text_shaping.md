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
HarfBuzz's default, Arabic, Hebrew, Indic and Thai/Lao shapers:

- **Normalization** against the font's cmap (decompose, reorder by modified
  combining class, recompose), with default ignorables hidden and RTL mirroring.
- **GSUB** types 1-8 (`lib.ttf_layout`) with GDEF classes, mark attachment
  classes and mark filtering sets, lookup flags, and script/language/feature
  selection: `ccmp`/`locl`, Arabic `isol`/`fina`/`medi`/`init` from Unicode
  joining types, `rlig`/`rclt`/`calt`/`liga`/`clig`, and for the nine Indic
  scripts (Devanagari, Bengali, Gurmukhi, Gujarati, Oriya, Tamil, Telugu,
  Kannada, Malayalam; `lib.ttf_indic`, new `dev2`-style and old `deva`-style
  tags) HarfBuzz's Indic shaper: its syllable machine and per-script
  configuration (virama, base position, reph position and mode, `blwf` mode),
  Indic normalization and split matras, vowel-constraint and broken-cluster
  dotted circles, initial reordering, the `nukt`/`akhn`/`rphf`/`rkrf`/`pref`/
  `blwf`/`abvf`/`half`/`pstf`/`vatu`/`cjct` stages with their masks and
  joiner rules, final reordering (reph, pre-base matras, pre-base-reordering
  `pref` consonants), and the `init`/`pres`/`abvs`/`blws`/`psts`/`haln`
  presentation features.
- **GPOS** types 1-9: `kern`, mark-to-base, mark-to-ligature, mark-to-mark,
  cursive attachment, `dist`, `abvm`/`blwm`.
- **Fallbacks** for fonts without the tables: Arabic presentation forms
  (including lam-alef and shadda ligatures) from the font's cmap, Hebrew
  presentation compositions, legacy `kern` table pairs, and HarfBuzz's
  combining-class mark placement.

`ttf_shape_no_liga` and `ttf_shape_no_kern` flags turn off ligatures and
kerning. Other complex scripts (Sinhala, Myanmar, Khmer, the Universal Shaping
Engine scripts, and Indic text in fonts with only `dev3`-style USE tags) shape
through the default shaper: their GSUB/GPOS features apply, but without
script-specific reordering. Against the full Noto Sans fonts the Indic shaper
matches HarfBuzz 15 on a word-and-conjunct corpus (about 2,000-2,600 lines per
script) and on random mark/joiner stress text; the known differences are a
syllable longer than HarfBuzz's buffer window and a precomposed letter that a
mixed Latin run sends through the default shaper's normalizer.

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

## Paragraph itemization

`graphics.ui.itemize` turns one UTF-8 paragraph into shaped runs, each with one
bidi level, script and face, using only the portable engines, so it works on
every target. `ui_paragraph_shape(text, length, strike, direction)` returns an
owned `ui_paragraph` (check `status` as for a run; free it with
`ui_paragraph_free`). Its `items` are in logical order, each with a byte
range, level, script, face, strike, shaped run and `x`, and `visual_items`
lists them left to right. `advance` is the total width and `ascent`/`descent`
are the line's extent over every face used.

- **Bidi**: the levels come from the portable UAX #9 engine for the unwrapped
  paragraph (`AUTO` direction takes the first strong character).
- **Script**: resolved the way HarfBuzz and ICU itemize (UAX #24 practice).
  Common, Inherited and Unknown characters take the script before them, and a
  leading run of them takes the first real script after it. A closing paired
  bracket takes its opener's script, which then resumes. A run of only shared
  characters shapes with a guessed script.
- **Face**: chosen per grapheme. A grapheme keeps the previous grapheme's face
  when that face covers all of it. Otherwise it takes the first face that does,
  out of the strike's face, the `ui_font_add_fallback` chain and the default
  Regular. If none does, it takes the face that supplies its base character in
  codepoint text. Controls and default-ignorables count as covered, so a
  combining mark stays with its base whenever that face has the mark, and
  faces change only at grapheme boundaries. Every face shapes at the strike's
  ppem.

`ui_paragraph_caret_x` and `ui_paragraph_offset_from_x` map byte offsets to x
across the whole paragraph. An offset at a run boundary belongs to the run
that starts there. `ui_paragraph_draw` draws every run on one baseline.
`ui_paragraph_fit(p, text, max_width)` is a width-fit helper for simple
wrapping: it returns the last break after a space whose prefix fits, measured
from the shaped glyphs without reshaping. Real line breaking (UAX #14), per-line
bidi reordering of wrapped lines (`ui_bidi_reorder_line` below) and reshaping
each line stay with the host, as do contextual forms across a run boundary: an
Arabic word split between two faces does not join across the split.

The embedded faces cover Latin, Greek and Cyrillic, and no larger fallback face
is bundled: a Noto set covering the world's scripts is tens of megabytes, which
the compiler tree and wasm builds should not carry. Load a face with coverage
for the required script using `ui_font_face_load_ttf` or
`ui_font_face_load_bytes` (TrueType `glyf` or CFF `OTTO` outlines, including
CID-keyed CJK fonts), register it with `ui_font_add_fallback` for codepoint
text, create its strike, and shape that run (or let `graphics.ui.itemize` pick
faces per grapheme). A single shaped run does not fall back inside itself:
missing coverage produces the selected face's `.notdef` glyph.
Color glyphs remain outside the rasterizer. Hinting is an opt-in strike
option (see Hinting below); CFF hint operators are read and skipped either way.

Calls accept at most 65536 source bytes and an output budget between zero and
1048576 glyphs. Failure returns no partial glyph array. HarfBuzz owns its
temporary shaping allocations and execution, and the native adapter provides
no native-call timeout or allocation budget. Font bytes, strikes and atlas
caches retain their existing process lifetime; runs must be freed
individually. Use the UI thread, as the shared font/atlas and lazy adapter
initialization are not synchronized.

## Hinting

`lib.ttf_hint` fits glyph outlines to the pixel grid for small UI text
(issue #824). It is a vertical-only light autohinter in the style of
FreeType's light mode, and it handles TrueType (`glyf`) and CFF (`OTTO`)
outlines the same way. It does not run the TrueType bytecode (`fpgm`,
`prep`, `cvt `, glyph instructions) or read CFF stem hints and hint masks;
it measures the outline itself. We chose this over a bytecode interpreter
for three reasons. It covers both outline formats and unhinted fonts with a
few hundred lines instead of a full TrueType VM. Vertical-only fitting
fixes the problem the issue describes (soft, unevenly placed horizontal
stems, baselines and x-heights at 9-14 px). It also leaves every
horizontal metric alone, so there is nothing to reconcile with shaped
advances. A bytecode interpreter could still be added later as another
mode.

Opt in per strike. `ui_font_strike_hinted(face, ppem, UI_HINT_LIGHT)` finds
or creates a hinted strike. It is separate from the unhinted
`ui_font_strike(face, ppem)` (`UI_HINT_NONE`), so existing golden rasters
and `ui_draw_text` output change only where a program asks for hinting.
`ui_font_strike_hinting` reads a strike's mode, and
`ui_font_strike_with_hinting` switches it. The companions a strike finds
for itself keep its mode: the resized and true-italic strikes, the device
strike `graphics.ui.render` draws at a pixel scale, and the per-face item
strikes of a paragraph (`ui_font_strike_sibling`). At the `lib.ttf` level,
`ttf_rasterize_hinted(font, gid, ppem, skew, TTF_HINT_LIGHT, &bitmap)` is
the entry point. `TTF_HINT_NONE` is exactly `ttf_rasterize_skewed`.

Hinting never moves anything horizontally. Advances, kerning, bitmap
widths and left bearings are identical in both modes, and shaped runs keep
their unhinted 1/64-pixel advances and offsets. Carets, line widths and
paragraph layout are therefore the same whether a strike is hinted or not.

The algorithm follows FreeType's Latin autohinter:

- **Blue zones**, measured once per face from FreeType's Latin reference
  letters. These are the capital top and bottom (`THEZOCQS`, `HEZLOCUS`),
  the ascender (`fijkdbh`), the x-height and small-letter bottom
  (`xzroesc`) and the descender (`pqgjy`). Each letter's extreme point is
  flat or round depending on its neighbours. A zone's reference is the
  flat mean and its overshoot the round mean. A face with none of a
  zone's letters has no such zone, and a face with no Latin letters
  only has its stems fitted.
- **Scale**: the vertical scale grows (or shrinks) slightly so that the
  x-height overshoot lands on a whole pixel. It rounds up from 0.375 px
  unless that would move anything by two pixels. Zones snap to whole
  pixels, and a zone is active only while its overshoot is under 3/4
  pixel. Below 1/2 pixel the overshoot is suppressed, and from 1/2 to
  3/4 it becomes half a pixel. These comparisons use FreeType's 26.6
  rounding.
- **Edges and stems**: runs of near-horizontal outline segments become
  edges. An edge is round when it passes through an off-curve point.
  Edges merge when they are within 1/4 pixel. Bottom and top edges pair
  into stems when the choice is mutual and the stem is under upem/4.
  Edges in an active zone snap to its reference or overshoot and carry
  their stem partner with them. Every other stem moves whole. A thin stem
  is centred on a pixel, and a thicker one goes to whichever rounded edge
  is closer to its original centre. As in FreeType's light mode, stem
  widths keep their scaled size; only positions change.
- **Map**: the fitted edges define a monotonic piecewise-linear map of y.
  The map is applied to the flattened outline. Points between fitted
  edges are interpolated, points beyond them move with the nearest one,
  and a synthetic oblique is sheared after the move.

Against FreeType 2.13's light autohinter (`FT_LOAD_TARGET_LIGHT |
FT_LOAD_FORCE_AUTOHINT`) at 9-16 px over ASCII letters and digits, the
ink rows (rows carrying at least half a pixel of coverage) are the same
for 92-100% of glyphs. The fonts compared are Liberation, DejaVu, Noto,
Roboto and URW, in both TrueType and CFF. Unhinted outlines match for
62-76%. The row-profile distance (summed per-row coverage differences,
relative to FreeType's total ink) drops from 0.14-0.18 to 0.04-0.06.
Most remaining differences are sloped serif tops in the URW serif faces
and the dots of `i` and `j`.

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
- `./wbuild ttf_hint_test` (and `ttf_hint_64_test`) checks the hinter
  against golden bitmaps for a TrueType and a CFF Noto subset at 9-14 px
  (`tests/data/ttf_hint_golden.txt`, regenerated by `bin/ttf_hint_dump
  --golden` from `tools/ttf_hint_dump.w`, after reviewing the change).
  It also checks agreement with FreeType's light autohinter over the
  same set (`tests/data/ttf_hint_freetype.txt`, from
  `tools/ttf_hint_ref.py`, which needs freetype-py offline only), the
  measured blue zones and x-height scaling, and that `TTF_HINT_NONE` is
  the unhinted rasterizer byte for byte with unchanged advances.
  `./wbuild graphics_ui_font_hint_test` covers hinted strikes, the
  companions that inherit the mode, unchanged widths and shaped advances,
  and paragraph items.
- `./wbuild graphics_ui_shape_test` runs strict UTF-8, explicit-length NUL,
  empty runs, invalid inputs, output limits, mark positioning, Hebrew RTL
  clusters, an in-memory GSUB `fi` ligature, Arabic and Devanagari runs, engine
  selection, carets and headless rendering through both engines, skipping the
  native one visibly when HarfBuzz is unavailable.
- `./wbuild graphics_ui_itemize_test` itemizes Latin, Hebrew, Arabic, digits and
  Devanagari over the embedded face with the Noto subsets as fallbacks. It checks
  run splits, visual order, face choice, marks staying with their base, bracket
  and leading-punctuation scripts, carets across runs, drawing, fitting, and
  empty, invalid and oversized input.

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
