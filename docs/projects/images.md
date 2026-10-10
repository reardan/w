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
non-interlaced, 8-bit grayscale, RGB, indexed, grayscale-alpha and RGBA PNGs.
It handles all five row filters, palettes and `tRNS` transparency, validates chunk
CRC/order/lengths, requires IEND and exact scanline lengths, and bounds zlib
inflation by the expected scanline size. IDAT chunks must form one contiguous
zlib stream with no trailing compressed bytes. Unknown critical chunks fail;
ancillary metadata is ignored after CRC validation.

Packed 1/2/4-bit samples, 16-bit samples, Adam7 interlace, animation and color
management are unsupported. The decoder returns `IMAGE_UNSUPPORTED` for
unsupported IHDR encodings; it never silently guesses their pixel format.
Metadata does not affect output color values. Scratch memory includes the
concatenated IDAT stream, filtered scanlines (at most RGBA bytes plus one byte per
row) and the bounded inflater's storage. No external codec or generator is needed.
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
results. EXIF orientation and ICC profiles are ignored, so consumers requiring
color management or orientation must add those steps. Application metadata and
comments are skipped by checked segment lengths; bytes after the first complete
EOI are ignored. Three-component frames use frame-order Y/Cb/Cr unless Adobe
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
