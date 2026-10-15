# Shaped text runs

`graphics.ui.shape` is an opt-in Linux x64 HarfBuzz adapter for applications that
need OpenType shaping rather than codepoint drawing. It dynamically loads
`libharfbuzz.so.0`; `ui_shape_available()` reports whether the library and its
required entry points are present. Importing the adapter requires the normal
Linux dynamic loader and `libdl.so.2`. Ordinary UI text has no new HarfBuzz
link dependency. Other platforms must supply a shaping adapter before using this
API; this module is not a portable fallback implementation.

`ui_shape_utf8(text, byte_length, strike, direction, script, language,
max_glyphs)` returns an owned `ui_shaped_run`, including on failure. Check
`run.status` against `UI_SHAPE_OK`, `UI_SHAPE_INVALID`, `UI_SHAPE_UNAVAILABLE`,
`UI_SHAPE_LIMIT`, or `UI_SHAPE_FAILED`; free it with `ui_shaped_run_free`.
Input is validated UTF-8 with an explicit length, including embedded NUL.
Choose an existing font strike, `UI_SHAPE_LTR`, `UI_SHAPE_RTL`, or
`UI_SHAPE_AUTO`, an ISO 15924 script tag packed as a big-endian integer (zero
means guess), and a terminated BCP 47 language name (null means `und`).

The run owns visual-order glyph IDs, UTF-8 byte clusters, signed offsets and
advances in 1/64 pixel units. `advance` is the total horizontal advance.
HarfBuzz applies its default OpenType features, including ligatures,
contextual forms and mark positioning when the selected font supplies them.
`ui_draw_shaped_run(renderer, x, y, run, color)` draws those glyph IDs through
the existing TrueType atlas and renderer's clipping/batching, preserving the
shaper's fractional positions without applying pair kerning again. `x,y`
locates the line box's top-left. The new `ui_font_glyph_id` API lets another
shaping engine use the same rasterizer and cache.

The host must split paragraphs by bidi direction, script and font, choose
fallbacks and line breaks, and assemble the resulting runs into visual order.
The optional paragraph bidi adapter described below supplies directional runs
and their visual order for a paragraph displayed on one unwrapped line.
`AUTO` guesses one run's properties; it is not Unicode paragraph bidi.
Clusters identify source ranges and may combine multiple graphemes in one
ligature. They are not a complete caret or selection model. Shape again after
changing the text, selected face, size, script or language. The ordinary
`ui_draw_text` and widget text paths continue to use codepoint drawing; opt in
explicitly when laying out document runs.

The embedded faces cover Latin, Greek and Cyrillic. Load a TrueType face with
coverage for the required script using `ui_font_face_load_ttf` or
`ui_font_face_load_bytes`, create its strike, and shape that run. This API does
not run codepoint fallback inside an already shaped run: missing coverage
produces the selected face's `.notdef` glyph. Supply an appropriate CJK,
Arabic, Devanagari or Thai face rather than relying on the embedded subset.
CFF/OTTO outlines, color glyphs and hinting remain outside the rasterizer.

Calls accept at most 65536 source bytes and an output budget between zero and
1048576 glyphs. Failure returns no partial glyph array. These bound W-owned
input/output; HarfBuzz owns its temporary shaping allocations and execution,
and this adapter does not provide a native-call timeout or allocation budget.
Font bytes, strikes and atlas caches retain their existing process lifetime;
runs must be freed individually. Use the UI thread, as the shared font/atlas
and lazy adapter initialization are not synchronized.

`./wbuild graphics_ui_shape_test` exercises strict UTF-8, explicit-length NUL,
empty runs, invalid inputs, output limits, mark positioning, Hebrew RTL
clusters, deterministic GSUB ligature substitution, and headless rendering/cache
reuse. It visibly skips the native portion when HarfBuzz is unavailable. The
ligature test replaces the checked-in Liberation Sans fixture's GSUB table in
memory with a known `fi` substitution; it needs no system font or generator.

The adapter uses the published HarfBuzz contracts for
[buffers and clusters](https://harfbuzz.github.io/harfbuzz-hb-buffer.html),
[read-only font blobs](https://harfbuzz.github.io/harfbuzz-hb-blob.html), and
[shaping](https://harfbuzz.github.io/shaping-and-shape-plans.html).

## Paragraph bidi analysis

`graphics.ui.bidi` is a separate opt-in Linux x64 adapter for
`libfribidi.so.0`. `ui_bidi_available()` checks the library and required symbols;
ordinary UI text gains no FriBidi dependency. Importing the module needs the
same Linux loader and `libdl.so.2` as the shaping adapter. It is not a portable
fallback, and its Unicode data version is supplied by the installed FriBidi.

`ui_bidi_utf8(text, byte_length, direction, max_scalars)` analyzes one paragraph
displayed on one unwrapped line. Choose `UI_BIDI_AUTO`, `UI_BIDI_LTR`, or
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
subruns according to the enclosing direction. Line wrapping also remains a
separate layout step: do not independently analyze each wrapped line, because
paragraph context affects bidi resolution. This API does not yet expose
reordering of line ranges from a previously analyzed paragraph. It does not
change default widget rendering or add native IME support.

Inputs and budgets are capped at 65536 bytes/scalars. W-owned arrays are bounded
by that cap, while native temporary allocations and execution remain under
FriBidi's control with no timeout. As with shaping, lazy native initialization
is unsynchronized; use the UI thread.

`./wbuild graphics_ui_bidi_test` covers mixed Hebrew/Latin/numbers, paired
punctuation, isolates, explicit overrides, trailing whitespace, inverse maps
and byte ranges, UTF-8 rejection, NUL, supplementary scalars, the maximum
budget, empty input, unavailable-native behavior and native failure cleanup.
A headless integration case shapes logical slices in visual run order and
keeps a Hebrew combining mark attached to its base. Native tests visibly skip
when their optional library is unavailable. This is regression coverage, not a
claim of complete Unicode bidi conformance qualification.

The adapter uses FriBidi's published
[paragraph and line ABI](https://github.com/fribidi/fribidi/blob/master/lib/fribidi-bidi.h)
and [paired-bracket API](https://github.com/fribidi/fribidi/blob/master/lib/fribidi-brackets.h).
