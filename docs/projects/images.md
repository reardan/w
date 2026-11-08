# Bounded image decoding and UI painting

`graphics.image.image` defines the shared owned `rgba_image` result: positive
width/height, tightly packed top-to-bottom straight-alpha RGBA bytes, and explicit
byte length. `rgba_image_free` releases pixels and the image. Decoder result
wrappers use `wresult[rgba_image*]`; free the wrapper separately from its successful
payload. Failed results have no image payload. Input and configuration are
borrowed for the duration of the call; no input pointers escape.

`image_default_limits()` returns a caller-owned configuration with a 16 MiB
compressed input cap, 8192-pixel width/height caps and 64 MiB RGBA output cap.
Decoders check positive dimensions and divisions before multiplying allocation
sizes. `image_error_string` describes stable `IMAGE_*` codes. Limits apply to
input, dimensions and decoded pixel bytes; decoder scratch storage is additional
and bounded by those limits.

## PNG

Import `graphics.image.png` and call
`png_decode_n(bytes, length, limits)`; pass `0` for defaults. The decoder supports
every color type and bit depth the PNG specification allows: grayscale at 1, 2,
4, 8 and 16 bits, indexed at 1, 2, 4 and 8 bits, and RGB, grayscale-alpha and RGBA
at 8 and 16 bits, either non-interlaced or Adam7-interlaced. Output is always
8-bit straight RGBA: packed grayscale samples are replicated to 8 bits (`v * 255 /
(2^depth - 1)`), and 16-bit samples keep their most significant byte. A 16-bit
`tRNS` key is compared against the full 16-bit sample, and a packed grayscale key
against the sample at its own depth. It handles all five row filters (per Adam7
pass, each starting with a zero prior row), palettes and `tRNS` transparency,
validates chunk CRC/order/lengths, requires IEND and exact scanline lengths
(the sum over the non-empty passes), and bounds zlib inflation by that expected
size. IDAT chunks must form one contiguous zlib stream with no trailing
compressed bytes. Palette indexes past the PLTE entries fail at every depth.
Unknown critical chunks fail; ancillary metadata is ignored after CRC validation.

Animation and color management are unsupported. The decoder returns
`IMAGE_UNSUPPORTED` for depth/color pairs the specification forbids (16-bit
indexed, packed RGB, ...), nonzero compression/filter methods and interlace
methods other than 0 and 1; it never silently guesses their pixel format.
Metadata does not affect output color values. Scratch memory includes the
concatenated IDAT stream, filtered scanlines (one byte per row plus the packed
samples, at most twice the RGBA bytes for 16-bit RGBA) and the bounded
inflater's storage. No external codec or generator is needed.
The implementation follows the [PNG specification](https://www.w3.org/TR/png-3/)
and reuses the repository's CRC32 and zlib/DEFLATE code.

The CRC32 implementation has a lazy process-wide table: initialize it once with
`crc32_of(c"", 0)` before starting concurrent decoder workers, as documented by
`libs.extras.compress.crc32`. Image results and other decoder state are independent.

## UI images

Import `graphics.ui.render`:

- `ui_image_create(renderer, width, height, pixels, length)` copies RGBA pixels
  and creates a GL texture when the renderer has a GL context. It returns `0` for
  invalid dimensions/lengths (8192 per side and 64 MiB pixels maximum).
- `ui_image_update(image, pixels, length)` copies a complete same-size update;
  queued draws observe the latest pixels at submission time. Returns 0/1.
- `ui_draw_image(renderer, image, rectangle, opacity)` paints with linear scaling,
  existing CPU clipping and straight alpha. Opacity clamps to 0–1.
- `ui_image_release(image)` releases caller ownership. Each queued texture range
  retains a reference until the next `ui_render_begin` or renderer destruction,
  so releasing an image after issuing its final draw is safe.

Use an image with the renderer/GL context that created it. Image creation,
updates, drawing and final release must run on that context's thread while the
context is current. Release application-owned images and destroy renderers before
destroying the context. Headless images need no GL context. Reference counts are
not atomic; transfer work from decoding workers to the rendering thread explicitly.

Ordered command ranges preserve painting order within each existing UI layer,
including alternating text, images and solid fills. Each layer still uploads its
vertex buffer once. Glyph atlas resizing rescales only atlas UVs, preserving image
UVs. Renderer destruction now also releases its atlas texture, buffer and shader.

Tests are conventional targets: `png_test`, `png_64_test`,
`graphics_ui_image_test` (headless geometry/lifetime/updates/atlas resize) and
`graphics_ui_image_smoke_test` (native readback of alpha, clipping, paint order,
updates and release). The native probe reports SKIP when no display is available;
on Linux with a display it exercises the actual GL shader and texture path.

`examples/web/png_inspect.w` is a standalone consumer with bounded file loading:

```sh
bin/wv2 examples/web/png_inspect.w -o bin/png_inspect
bin/png_inspect image.png
```

The decoder uses `zlib_decompress_ex(..., &consumed)`, a backward-compatible
extension that reports the bytes in one zlib stream including its wrapper and
checksum. The original `zlib_decompress` convenience function retains its behavior
of accepting bytes after the stream; protocols can use the explicit count when
exact framing is required.

## Baseline JPEG

`import graphics.image.jpeg` adds
`jpeg_decode_n(data, length, limits_or_zero) -> wresult[rgba_image*]*`, using the
same image limits, owned RGBA output, error codes, and texture upload API as PNG.
Input is borrowed during the synchronous call; successful pixels do not retain
it. Free the result wrapper separately from its successful `rgba_image` value.
The implementation follows the baseline coding and marker procedures in
[ITU-T T.81, Annexes B/F](https://www.w3.org/Graphics/JPEG/itu-t81.pdf), with no
imported decoder source or external codec dependency at runtime.

Supported: 8-bit SOF0 sequential Huffman grayscale, YCbCr, and Adobe/RGB images;
one complete scan; 8-bit quantization; canonical Huffman tables; entropy byte
stuffing; restart intervals and ordered restart markers; integer sampling ratios
including 4:4:4, 4:2:2, and 4:2:0. Output is opaque RGBA. Chroma upsampling uses
nearest neighbor. The separable floating-point IDCT can differ by rounding from
optimized integer decoders. Quantization/Huffman tables, component counts,
coefficient categories/runs, predictors, marker/segment lengths, and dimensions
are validated before they drive indexing or allocation. Output is discarded on
any decode failure. Fixed decoder tables and one MCU's component samples are
additional bounded working memory; full decoded component planes are not
allocated. No mutable global tables are used.

Progressive, arithmetic, lossless, hierarchical, multi-scan, 12-bit, CMYK/YCCK,
non-integer sampling ratios, and deferred-height DNL are explicit unsupported
results. ICC profiles are ignored, so consumers requiring color management must
add that step. `jpeg_decode_n` returns pixels in stored orientation; see EXIF
orientation below. Application metadata and comments are skipped by checked
segment lengths; bytes after the first complete EOI are ignored. Three-component frames use frame-order Y/Cb/Cr unless Adobe
transform zero or `R/G/B` component IDs select RGB. This initial decoder does not
claim complete JPEG interchange/profile support.

`graphics_image_jpeg_test` and `graphics_image_jpeg_64_test` compare independently
decoded grayscale/color pixels (including subsampling and restart markers),
exercise every truncated prefix of a JPEG, dimension/input/output limits,
progressive rejection, invalid restart sequence, and every one-byte mutation of
a minimal restart fixture. Guard-page allocator runs also pass. Synthetic
fixtures and independent expected pixels are checked in as
`tests/images/jpeg_fixtures.w`; normal builds need no Python/Pillow. The optional
`tests/images/generate_jpeg_fixtures.py` recreates these original fixtures with
Pillow 10.2.0 and libjpeg-turbo 2.1.5; other encoder versions may produce different
valid compressed bytes. The W decoder itself and its cosine basis are built
entirely from repository source on every target.

### EXIF orientation

`jpeg_decode_orientation(data, length)` returns the EXIF orientation (1..8) from
the IFD0 orientation tag (0x0112, one SHORT) of the first APP1 `Exif\0\0`
segment before the scan that carries a valid tag. Both TIFF byte orders are
read; every IFD offset and entry is bounds-checked against the segment, and a
missing, malformed or out-of-range tag (or malformed markers) yields 1. Input
is borrowed. `rgba_image_apply_orientation(image, orientation)` in
`graphics.image.image` rewrites an owned image in place into display
orientation: 2 mirrors left-right, 3 rotates 180°, 4 mirrors top-bottom, 5
transposes, 6 rotates 90° clockwise, 7 transverses and 8 rotates 90°
counter-clockwise; 5..8 swap width and height. It returns 0 and leaves the image
unchanged for orientations outside 1..8. `jpeg_decode_oriented_n(data, length,
limits)` is `jpeg_decode_n` followed by both steps.

## Baseline JPEG encoding

`import graphics.image.jpeg_encode` adds
`jpeg_encode_rgba(width, height, rgba, quality) -> string_builder*` (4:2:0) and
`jpeg_encode_rgba_ex(width, height, rgba, quality, subsampling)` with
`JPEG_SUBSAMPLE_420` or `JPEG_SUBSAMPLE_444`, mirroring `png_encode_rgba`: input
is tightly packed straight RGBA rows, alpha is ignored, and the caller frees the
returned builder. Output is a baseline sequential (SOF0) JFIF 1.01 file: SOI,
APP0, one DQT with both tables, SOF0, one DHT with the four Annex K.3 Huffman
tables, one interleaved scan and EOI. Quality clamps to 1..100 and scales the
Annex K.1 luminance/chrominance tables with the IJG rule (`5000 / q` below 50,
`200 - 2q` above, entries clamped to 1..255). Color conversion (JFIF YCbCr),
the forward DCT and quantization use integer fixed point only, so output bytes
are identical on every target. Images of any size from 1 to 65535 pixels per
side are padded to whole MCUs by replicating the last column and row; 4:2:0
chroma is a 2x2 box average. Entropy bytes of 0xFF are stuffed with 0x00 and the
final byte is padded with 1 bits. Invalid dimensions, a null buffer or an
unknown subsampling mode return 0. No restart intervals, progressive scans,
optimized Huffman tables or metadata other than APP0 are written. Scratch memory
is three padded 8-bit planes plus the output.

Tests: `graphics_image_jpeg_encode_test` (and its x64 twin) round-trips smooth
patterns at sizes 1x1 through 40x9 (including non-multiples of 8 and 16) through
the decoder in both sampling modes, bounding mean squared error (q90: MSE <= 5,
PSNR >= 41 dB at 4:4:4; MSE <= 16, PSNR >= 36 dB at 4:2:0), checks that error
and size are monotonic in quality, quality clamping, flat gamut corners at q100,
high-contrast noise at several qualities, SOI/JFIF APP0/EOI framing and byte
stuffing, argument validation, and that each AC table codes every run/size
symbol exactly once. `graphics_image_jpeg_test` covers EXIF parsing (both byte
orders, every orientation, wrong type/count/value, corrupt TIFF headers, every
prefix) and all eight orientation transforms; `png_test` covers 16-bit,
packed and Adam7 PNGs with in-test packing and independently computed pixels.
