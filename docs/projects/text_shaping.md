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
