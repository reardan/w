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
- **Context**: each item shapes with the text around it as context
  (`ui_shape_portable_item`, below), so contextual forms see across item
  boundaries: an Arabic word split between two faces (one of its letters
  missing from the first) still joins across the split.

`ui_paragraph_caret_x` and `ui_paragraph_offset_from_x` map byte offsets to x
across the whole paragraph. An offset at a run boundary belongs to the run
that starts there. `ui_paragraph_draw` draws every run on one baseline.
`ui_paragraph_fit(p, text, max_width)` is the older width-fit helper: it
returns the last break after a space whose prefix fits, measured from the
shaped glyphs without reshaping. Wrap with `ui_paragraph_layout` instead.

### Shaping context

`ui_shape_portable_item(text, text_length, item_start, item_length, strike,
direction, script, language, max_glyphs)` shapes the item
`text[item_start, item_start + item_length)` like `ui_shape_portable_utf8`, with
the text around it as context, as HarfBuzz's `hb_buffer_add_utf8` item offsets
do. Clusters are relative to `item_start`. Up to five scalars on each side are
read; only the item has to be valid UTF-8, and the context stops at an invalid
sequence. In `lib.ttf_shape` the context is `ttf_shape_context(font, cps,
clusters, count, pre, pre_count, post, post_count, ...)` (or
`ttf_shape_set_context` around `ttf_shape`): the pre-context is the text before
the run in logical order, the post-context the text after it. As in HarfBuzz's
Arabic shaper it feeds the joining state machine, skipping transparent
characters, so the run's first letter takes its final or medial form after a
joining letter and its last letter its initial or medial form before one. The
context never produces glyphs.

### Line layout

`ui_paragraph_layout(p, text, max_width, flags)` wraps a shaped paragraph into
lines at most `max_width` (26.6 pixels) wide and returns `UI_SHAPE_OK` (or
`UI_SHAPE_INVALID` / `UI_SHAPE_FAILED` with no lines). `flags` are the
`lib.linebreak` tailorings below (`lb_tailor_default` for plain UAX #14). It
replaces any earlier layout, so call it again for a new width; the paragraph
retains its bidi analysis for this (`p.bidi`).

1. **Breaks**: UAX #14 break opportunities (`lib.linebreak`), chosen greedily
   by the unwrapped paragraph's shaped advances: the last opportunity whose
   line, without its trailing whitespace, fits. Trailing whitespace (bidi WS
   and S, the characters rule L1 resets) hangs past the width. A word wider
   than `max_width` on its own line breaks between graphemes at the last one
   that fits (at least one per line).
2. **Reorder**: each line goes through `ui_bidi_portable_reorder_line` (the
   portable `ui_bidi_reorder_line`), so its levels include the L1 resets and
   its runs come out in the line's visual order. The paragraph's items are cut
   to the line and to its bidi runs, keeping their script and face.
3. **Reshape**: every line item is shaped again with the line as its context,
   because ligatures, kerning and contextual forms change at a break (an Arabic
   word broken between graphemes ends and starts in unjoined forms on its two
   lines). If the reshaped line is wider than `max_width`, the line ends at
   the previous opportunity instead.

The result is `p.lines[0, p.line_count)`, top to bottom, with `p.height` (pixels)
their total height and `p.line_width` the width used. A `ui_text_line` has:

| Field | Meaning |
| --- | --- |
| `byte_start`, `byte_length` | Logical paragraph byte range, trailing whitespace included |
| `scalar_start`, `scalar_count` | The same range in paragraph scalars |
| `items[item_count]` | Reshaped runs in logical order (level, script, face, strike, run), `x` from the line's left edge |
| `visual_items` | Item indices, left to right |
| `advance`, `trailing` | 26.6 width of the line, and of its trailing whitespace within that |
| `x` | 26.6 left edge within `max_width`, start-aligned: 0 for a left-to-right paragraph, `max_width - advance` for a right-to-left one (its trailing whitespace hangs at the left) |
| `top`, `ascent`, `descent` | Pixels: the line box's top below the paragraph's top, and its extent over every face on the line (at least the paragraph strike's) |

Lines tile the text: an offset at a break belongs to the line that starts
there (`ui_paragraph_line_at`), and the end of the text to the last line.
`ui_paragraph_line_caret_x(p, text, offset, &line)` gives the caret's x from
the layout's left edge and its line, whose `top`, `ascent` and `descent` make
the caret box. `ui_paragraph_hit_test(p, text, x, y)` (x in 26.6, y in pixels
from the paragraph's top, clamped to the first and last lines) returns the
grapheme boundary on that line whose caret is nearest x; on a wrapped line that
excludes its end offset, which is the next line's start.
`ui_paragraph_draw_lines(renderer, x, y, p, color)` draws each line at its `x`
and `top` on its own baseline. A paragraph has no hard breaks (the bidi API
rejects line and paragraph separators), so split a document into paragraphs
first; empty text lays out as one empty line.

The embedded faces cover Latin, Greek and Cyrillic, and no larger fallback face
is bundled: a Noto set covering the world's scripts is tens of megabytes, which
the compiler tree and wasm builds should not carry. Load a face with coverage
for the required script using `ui_font_face_load_ttf` or
`ui_font_face_load_bytes` (TrueType `glyf` or CFF `OTTO` outlines, including
CID-keyed CJK fonts), register it with `ui_font_add_fallback` for codepoint
text, create its strike, and shape that run (or let `graphics.ui.itemize` pick
faces per grapheme). A single shaped run does not fall back inside itself:
missing coverage produces the selected face's `.notdef` glyph.
Color glyphs draw through `graphics.ui.font_color` (next section). Hinting
remains outside the rasterizer; CFF hint operators are read and skipped, as the
rasterizer draws unhinted outlines at every size.

Calls accept at most 65536 source bytes and an output budget between zero and
1048576 glyphs. Failure returns no partial glyph array. HarfBuzz owns its
temporary shaping allocations and execution, and the native adapter provides
no native-call timeout or allocation budget. Font bytes, strikes and atlas
caches retain their existing process lifetime; runs must be freed
individually. Use the UI thread, as the shared font/atlas and lazy adapter
initialization are not synchronized.

## Color glyphs

`graphics.ui.font_color` reads a face's color tables, in the order HarfBuzz
prefers them, and renders a glyph into a list of parts in paint order
(`ttf_color_render`); pure W on every target.

- **COLR version 1**: the whole paint graph. PaintColrLayers, PaintSolid,
  linear, radial (two-point conical) and sweep gradients with pad, repeat and
  reflect color lines (interpolated in premultiplied space), PaintGlyph,
  PaintColrGlyph, every transform (affine, translate, scale, rotate and skew,
  with and without a center), PaintComposite with all 28 composite modes
  (Porter-Duff, the separable blend modes and the HSL ones), and the ClipList.
  The canvas covers the clip box, else the transformed boxes of the glyphs the
  graph paints. The variable formats read their default values: there is no
  font-variation support, so deltas are ignored. A depth limit (64) and a node
  budget stop cycles and paint bombs; a glyph whose graph fails falls back to
  its bitmap, then its outline.
- **COLR version 0** with CPAL: layers, each a glyph and a palette entry.
- **CBDT/CBLC** (Noto Color Emoji): PNG image formats 17, 18 and 19 through
  index subtable formats 1 to 5.
- **sbix**: PNG and JPEG images, and `dupe` records.

Bitmaps come from the strike nearest the size (the smallest at least as large,
else the largest), decoded by `graphics.image.png` (or `jpeg`) and resampled to
the strike's ppem: area-averaged when shrinking, bilinear when growing, in
premultiplied space. Advances come from `hmtx`, so bitmap-only fonts (which
`lib.ttf` now loads although they have no `glyf` or `CFF `) lay out like any
other. Palette 0 is used.

A part is either RGBA (straight alpha), drawn untinted, or a foreground
coverage mask drawn in the text color: palette index `0xFFFF` on a version 0
layer, or a top-level PaintGlyph of a solid fill in version 1. Consecutive
non-foreground layers composite into one RGBA part. A foreground reference
elsewhere in a version 1 graph (a gradient stop, a nested layer) cannot be
split out of the composite and paints opaque black.

`graphics.ui.font` rasterizes color glyphs into a second, RGBA atlas
(`ui_font_color_atlas_*`, 512 texels wide, growing like the coverage rows) and
foreground parts into the R8 atlas; a color glyph's `ui_glyph.color` names its
parts (`ui_font_color_part`). `graphics.ui.render` draws them through a
renderer-owned image (`color_image`) with the RGBA shader path, tinted only by
the text color's alpha, and the foreground parts from the atlas in the text
color, interleaved in paint order, so `ui_draw_text`, `ui_draw_shaped_run` and
`ui_paragraph_draw` all draw color glyphs. The device-pixel path rasterizes
color glyphs at the device size too. `ui_font_face_has_color` and
`ui_font_face_glyph_has_color` report color faces and glyphs.

**Emoji presentation** (UTS #51, `lib.emoji`, Unicode 15.0's
Emoji_Presentation property): the itemizer gives a grapheme presented as emoji
(VS16, or any character with Emoji_Presentation: a base emoji, a skin-tone
modifier, a regional indicator) the first color face that covers it, and one
presented as text (VS15) the first face without color, before the ordinary
face choice. Codepoint text (`ui_draw_text`) prefers a color fallback for
Emoji_Presentation characters; it has no lookahead for VS16, so a text-default
character such as U+2764 followed by VS16 needs shaped text to switch faces.
Codepoint text now draws default-ignorables (ZWJ, variation selectors) as
nothing. Emoji ZWJ sequences and skin-tone modifiers form through the face's
GSUB: the portable shaper's default rules now let an input sequence match the
ZWJ and variation selectors it names (they were always skipped), and a font
with no space glyph drops hidden default-ignorables, as HarfBuzz does.

`tools/color_glyph_dump.w` writes rendered glyphs as PNGs and
`tools/color_glyph_compare_hb.py` compares them with HarfBuzz's hb-raster
(COLR) or with the PNG and metrics fontTools reads (CBDT, sbix, at a strike's
size). Every glyph of the COLR test fonts matches HarfBuzz within
antialiasing at 23 and 64 ppem (mean channel difference under 3 of 255), as do
115 glyphs sampled across the COLRv1 Noto Color Emoji at 40 ppem (mean
difference at most 4.5, at most 2% of pixels off by more than 32, the largest
on thin lines such as a bridge's cables): the rasterizer's 4x4 subsampling
against HarfBuzz's exact area coverage. CBDT and sbix glyphs match exactly at
their strike sizes.

Not yet supported: `SVG ` glyphs, palette selection (`CPAL` palettes other than
0, light/dark flags), font variations for `COLR` version 1 (`Var*` paints draw
their defaults), EBDT/EBLC monochrome and grayscale bitmaps, and CBDT image
formats other than PNG.

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
- `./wbuild graphics_ui_itemize_test` itemizes Latin, Hebrew, Arabic, digits and
  Devanagari over the embedded face with the Noto subsets as fallbacks. It checks
  run splits, visual order, face choice, marks staying with their base, bracket
  and leading-punctuation scripts, carets across runs, drawing, fitting, and
  empty, invalid and oversized input. It also checks the shaping context
  (medial, initial and final forms from context, transparent marks, spaces and
  invalid UTF-8 in it) and an Arabic word split between faces that still joins,
  and line layout: Latin words with hanging spaces, a Hebrew word in a
  left-to-right paragraph whose line-final space is reset to the paragraph
  level, right-to-left start alignment, per-line reshaping of a word broken
  between graphemes, kinsoku with ideographs, carets and hit-testing for every
  grapheme boundary across lines, drawing, relayout, and empty and invalid
  paragraphs.
- `./wbuild linebreak_test` (and `linebreak_64_test`) runs `lib.linebreak`
  against a 1,462-line sample of `LineBreakTest.txt`
  (`tests/data/linebreak_sample.txt`) and checks the property table, its
  defaults and flags, the UTF-8 helper, and the CJK, East Asian and Southeast
  Asian tailorings.
- `./wbuild graphics_ui_font_color_test` (and `_64_test`) renders the color
  test fonts from `tools/make_color_test_fonts.py` (COLR version 0, a COLR
  version 1 graph exercising every paint type, sbix) and a Noto Color Emoji
  subset (CBDT), checking parts, pixel colors, strike choice and resampling,
  every composite mode, emoji presentation, a paint cycle falling back, and
  scrambled COLR, CPAL, sbix and CBLC tables rendering without a crash.
- `./wbuild graphics_ui_color_glyph_test` draws those fonts through
  `ui_draw_text` and the itemizer (Latin, an emoji, a skin-tone ligature, a ZWJ
  family and a VS16 heart) into a headless renderer, rasterizes the batch on
  the CPU (`graphics.ui.render_soft`) and compares golden PNGs in
  `tests/data/color_glyphs/` (`W_UPDATE_GOLDENS=1` rewrites them). It also
  checks foreground layers take the text color while color layers ignore it
  (but for alpha), the itemizer's color-face choice for VS16/VS15, the color
  atlas growing mid-frame, and the device-pixel path.

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
subruns according to the enclosing direction (`graphics.ui.itemize` does this,
and wraps lines too: see "Line layout" above). Line wrapping is a separate
layout step: do not independently analyze each wrapped line, because paragraph
context affects bidi resolution. Use the retained analysis as described below.
Neither API changes default widget rendering or adds native IME support.

### Wrapped lines and reflow

`ui_bidi_reorder_line(paragraph, scalar_start, scalar_count)` returns an owned
`ui_bidi_line` for a contiguous logical scalar range of a successful paragraph.
The caller selects line breaks from measured/shaped text. Arguments are scalar
indices, not UTF-8 byte offsets; a range cannot split a UTF-8 scalar. The caller
must also avoid breaking graphemes or shaping clusters and implement its own
line-break policy. This API does not measure widths or choose break positions;
`ui_paragraph_layout` (above) does, with UAX #14 breaks from `lib.linebreak`
and this API for each line.

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

## Line breaking

`lib.linebreak` is a W implementation of the Unicode Line Breaking Algorithm
([UAX #14](https://www.unicode.org/reports/tr14/), Unicode 15.0.0, to match
`lib.bidi`) with no native dependency. `lb_breaks(cps, count, flags, breaks)`
writes `count + 1` actions: `breaks[i]` is `lb_break_none`, `lb_break_allowed`
or `lb_break_mandatory` between `cps[i - 1]` and `cps[i]`, with no break at the
start (LB2) and a mandatory one at the end (LB3). `lb_breaks_utf8(text, length,
flags, breaks)` does the same per byte offset of valid UTF-8 (no break inside a
character). `lb_class(cp)` reads the Line_Break property.

It implements rules LB1-LB31, including the 15.0 aksara rule LB28a, the East
Asian width exception of LB30 and the unassigned-pictographic case of LB30b.
Numbers use the regular-expression form of LB25 from section 8.2, Example 7,
as `LineBreakTest.txt` does. It passes all 7,654 lines of the Unicode 15.0.0
`LineBreakTest.txt` (`./wbuild linebreak_conformance`, then
`bin/linebreak_conformance path/to/LineBreakTest.txt`); `linebreak_test` runs a
committed sample.

The property table is generated, not committed: `tools/generate_linebreak_data.w`
(the `linebreak_data` target, in the `generated` umbrella every `./wbuild` run
builds first) writes `lib/linebreak_data.w` from the unmodified Unicode 15.0.0
`LineBreak.txt`, `EastAsianWidth.txt`, `emoji-data.txt` and `UnicodeData.txt`
under `tools/unicode/`. It applies the defaults `LineBreak.txt` documents for
unlisted code points (ID in the CJK and Plane 1-3 ranges, PR among the currency
symbols, XX elsewhere), resolves Southeast Asian marks (SA with Mn or Mc) to CM
as LB1 does, and flags wide OP/CP and unassigned Extended_Pictographic code
points for LB30 and LB30b. The table is about 3,600 ranges (14 KB).

Tailorings are `flags`, combined with `|`:

- `lb_tailor_cjk_normal`: CJ (small kana, the prolonged sound mark) resolves to
  ID instead of NS, so lines may start with them (CSS `line-break: normal`).
  The default is strict kinsoku: closing punctuation, iteration marks, small
  kana and the other NS, CL, CP, EX and IS characters never start a line, and
  opening brackets never end one.
- `lb_tailor_cjk_loose`: also resolves NS to ID, allowing breaks before
  iteration marks and the katakana middle dot (CSS `line-break: loose`).
- `lb_tailor_east_asian`: AI (ambiguous width) resolves to ID instead of AL,
  for text in an East Asian context.
- `lb_tailor_sa_clusters`: the fallback for Southeast Asian scripts. Thai, Lao,
  Khmer, Myanmar and the other SA scripts write words without spaces and need a
  dictionary to find word boundaries. None is shipped (a usable Thai or Khmer
  dictionary is hundreds of kilobytes per language), so by default SA text is
  AL (rule LB1) and breaks only at its spaces and punctuation, keeping words
  whole. With this flag a break is also allowed between any two SA letters,
  but never inside a cluster: not before a combining mark (SA Mn/Mc are CM),
  a Thai or Lao SARA AM or repetition mark, not after a stacking virama or
  coeng (Khmer U+17D2, Myanmar U+1039, Tai Tham U+1A60), and not after a
  prepended vowel (the Thai, Lao, Tai Viet and New Tai Lue logical-order
  exceptions). That is grapheme-cluster breaking, which keeps text inside the
  line width at the cost of breaking inside words. A dictionary engine could
  replace this flag later by marking word boundaries inside SA runs.
