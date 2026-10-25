# Win browser foundations

This is the library integration map for [#637](https://github.com/reardan/w/issues/637).
Win's tabs, mutable DOM, selector matching, cascade/layout, event scheduling,
cookies/cache and content isolation remain in the application repository.

| Foundation | Import / documentation | Delivered boundary |
| --- | --- | --- |
| HTML | `libs.extras.html.html`; [HTML](html.md) | Owned explicit-length tokens and static trees, spans, diagnostics, budgets, full named references and numeric repair, raw/RCDATA/script content, escaped/double-escaped script states, initial implied-element and malformed-markup recovery |
| CSS | `libs.extras.css.css`; [CSS](css.md) | Owned tokens, selectors as component groups, stylesheet/at-rule/declaration nodes, escapes, URL/bad-URL tokens, balanced blocks, hash/numeric metadata and EOF recovery |
| JavaScript AST | `libs.extras.javascript.parser`, `.lower`, `.text`; [JavaScript](javascript.md) | Loops including lexical for-of, labelled statements and jumps, functions/arrows, try/catch/finally, UTF-16 values preserving NUL and lone surrogates, caller parser limits, explicit unsupported lowerings |
| JavaScript execution | `libs.extras.javascript.runtime`; [embedding](javascript.md#embed-the-interpreter) | Binary64 subset interpreter on 64-bit targets, lexical closures/arrows, templates, for-of, values/objects/arrays, statement completions, var environments, typed errors, descriptors/prototypes, synchronous host property hooks and receiver-aware invocation, isolated heaps, roots/cyclic collection and terminal budgets |
| URLs / loading | `libs.standard.web.urlparse`, `.http_client`; [networking](browser_network.md) | References/fragments, dot segments, canonical IPv6 hosts including dotted tails, origin tuples, owned clients, checked total-deadline transport, task cancellation, redirect approval/final URL, bounded delivery |
| Content decoding | `libs.standard.web.content_decode`; [decoding](browser_network.md#content-decoding) | Bounded chunk collection and explicit completion, identity and registered gzip/deflate, separate input/output caps, validated concatenated gzip members |
| Images | `graphics.image.png`, `.jpeg`, `graphics.ui.render`; [images](images.md) | Bounded PNG and baseline JPEG into owned RGBA; texture updates, alpha, scaling, clipping, queued lifetime and native readback probes |
| Text / input | `graphics.ui.bidi`, `graphics.ui.shape`, `graphics.ui.grapheme`, `graphics.event`; [UI dependencies](browser_ui.md) | Portable UAX #9 paragraph bidi (FriBidi optional) with independent wrapped-line reordering, portable OpenType run shaping (HarfBuzz optional) with grapheme carets, TrueType and CFF outlines, grapheme-safe editing, X11 Unicode commits, Windows Unicode/IMM, web preedit and an opt-in macOS NSTextInputClient bridge |
| Accessibility | `graphics.ui.accessibility`, `.accessibility_web`; [UI dependencies](browser_ui.md) | Bounded semantic snapshots, explicit-length UTF-8 metadata, stable IDs, validated host actions/focus traversal, opt-in web ARIA, macOS NSAccessibility and Linux AT-SPI bridges, automatic widget semantics and keyboard focus routing, and default-theme contrast checks |

The support contracts are intentionally specific. HTML does not implement every
WHATWG tree algorithm; CSS does not validate every selector/property
or apply cascade; the interpreter is a documented semantic subset rather than
complete ECMAScript. It returns control on a budget failure but cannot resume an
aborted evaluation. HTTP transport remains IPv4, with explicit clients serialized
individually. Content decoding collects compressed input before decoding, with
strict full-input validation for registered gzip/deflate and a shared expanded-byte
budget across gzip members. PNG excludes interlace and packed/16-bit samples; JPEG excludes progressive and unsupported
scan/color modes. Consult each linked document before accepting a wider input
contract.

These issue tracks remain broader than the delivered APIs. Paragraph
line breaking, hinting and Indic reordering beyond Devanagari remain
open text work after [#459](https://github.com/reardan/w/issues/459). Windows UI Automation and
screen-reader qualification remain
[#465](https://github.com/reardan/w/issues/465). Broader JavaScript syntax,
standard built-ins and full early-error/runtime conformance remain
[#492](https://github.com/reardan/w/issues/492). The macOS accessibility helper
requires native Mac compilation and qualification; Linux cross-compilation is
only the W ABI/build check. The web bridge also needs browser and assistive
technology qualification; DOM/wasm contract tests do not establish screen-reader
behavior. These are unfinished dependency projects, not missing implementations
of the eight bounded browser-library milestones above. Closing the library
milestone must not mark those dependency projects complete.

## Acceptance audit and closeout

The original issue checklist predates the implementation. The eight direct
library deliverables landed in [#639](https://github.com/reardan/w/pull/639),
[#640](https://github.com/reardan/w/pull/640), and subsequent extensions including
[#641](https://github.com/reardan/w/pull/641),
[#650](https://github.com/reardan/w/pull/650),
[#652](https://github.com/reardan/w/pull/652), and
[#656](https://github.com/reardan/w/pull/656). Evaluate them against their
documented initial subsets, not full browser or ECMAScript conformance:

| Direct deliverable | Acceptance evidence in the normal test suite |
| --- | --- |
| HTML tokenizer and tree | `html_test`, `html_entities_test` and x64 twins: deterministic recovery trees, embedded languages, references, spans, ownership, EOF and budgets; entity generation is verified offline |
| CSS syntax APIs | `css_test` and x64 twin: semantic tokens/selectors/declarations, malformed-declaration recovery, balanced and nested blocks, EOF, spans and budgets; the maintained handwritten specification records provenance |
| JavaScript AST boundary | `javascript_roundtrip_test`, `javascript_browser_language_test`, `javascript_labels_test`, `javascript_text_test`: lower/print/parse, control flow, explicit unsupported shapes, UTF-16 NUL/surrogates and source spans |
| URL references | `urlparse_test` and x64 twin: base/reference tables, escaped delimiters, queries/fragments, IPv6, serialization and origin tuples; `file:` behavior is explicitly rejected/documented |
| Owned HTTP client | `http_browser_test` and x64 twin: cancellation, total deadlines/slow trickles, TLS failures, partial bodies, redirect approval/loops, simultaneous clients and shutdown |
| Bounded decoding | `content_decode_test` and x64 twin: input/output limits, chunk feeds and explicit completion, truncated/corrupt streams, unsupported encodings and concatenated gzip validation |
| Embeddable JavaScript | `javascript_runtime_test`, `javascript_browser_runtime_test`, `javascript_runtime_invoke_test`, `javascript_embed_example`: closures, completions, isolated instances, host callbacks, roots/cycles and terminal execution budgets |
| Images and painting | `png_test`, `graphics_image_jpeg_test` and x64 twins; `graphics_ui_image_test` and `graphics_ui_image_smoke_test`: malformed/truncated images, dimensions, transparency, clipping/scaling, updates/release and native readback (requires a display) |

`browser_resource_consumer_test` closes the integration-test gap: it compiles
the combined example for x86 and x64 both in the checkout and from a separate
temporary directory with an explicit import root. A controlled loopback server
exercises identity/gzip/deflate loading, relative redirects with retained
fragments, rejection of cross-origin redirects, corrupt/truncated responses,
unsupported encodings, expansion limits, and propagation of an HTML depth-limit
failure to the process exit status. It needs no public network service.

Closeout validation on 2026-10-19 against main `7cf0c447` plus this integration
fix: `./wbuild --keep-going -j 8 tests javascript_compatibility` passed all
1,561 targets, with `NO_COLOR` unset, pinned Node v20.19.3 on `PATH`, and an Xvfb
display. The native image readback probe passed. The compatibility gate passed
34/34 syntax cases, 3/3 growth cases, 3/3 execution examples, 9/9 runtime
comparisons and 2/2 consumers. Structured checks passed for x86 and x64.

Issue #637 is the **reusable library milestone** and closes when
[#799](https://github.com/reardan/w/pull/799) merges the validated integration
fix and acceptance audit. Remaining work continues in its existing tracks:

- [#459](https://github.com/reardan/w/issues/459): portable shaping/bidi,
  script/font segmentation, shaped carets, Cocoa IME and native input qualification.
- [#465](https://github.com/reardan/w/issues/465): Windows UI Automation and
  native assistive-technology qualification. The snapshot API, web/macOS/AT-SPI
  bridges, automatic widget semantics and keyboard routing are delivered.
- [#492](https://github.com/reardan/w/issues/492): broader JavaScript syntax,
  standard-library and runtime conformance beyond the embedding subset.
- The application repository: dependency-pin upgrades, DOM/layout integration,
  navigation/event scheduling and browser policy, as excluded by #637 itself.

The eight direct deliverables complete this milestone. The dependency tickets
remain open for their broader scope; #637 does not duplicate their tracking or
claim full browser, text/input, accessibility, or ECMAScript conformance.

## Consumers and reproducibility

`examples/web/browser_resource.w` combines checked resource loading, bounded
content decoding and HTML/CSS parsing. It restricts redirects to the same origin
for demonstration. `examples/javascript/embed.w` demonstrates a host callback;
`examples/javascript/events.w` demonstrates retained script callbacks;
`examples/web/html_document.w`, `css_inspect.w` and `png_inspect.w` demonstrate
independent consumers. None implements application DOM/layout policy.

Use `--import-root /path/to/pinned/w` when compiling outside the dependency
checkout. HTML, CSS and image decoders need no generator or external library at
build/run time. The maintained HTML/CSS token specifications record their scope
and provenance. HTML's complete named-reference table is checked in with its
pinned WHATWG source; `bin/html_entities --check` verifies offline
reproduction. JavaScript consumers first run `./wbuild javascript_parser` in
the dependency checkout. UI consumers retain the existing reproducible
`ui_font_data`/`generated` build targets and checked-in font inputs. Shaped runs optionally require system HarfBuzz
on Linux x64; paragraph bidi additionally requires system FriBidi. The macOS accessibility adapter ships a separately built AppKit
companion beside the application. JPEG fixture
generation is separate from normal builds; its provenance and reproduction
instructions accompany the checked-in fixture bytes.

Tests are conventional `_test.w` targets discovered by `wbuild`. The full
`./wbuild tests` suite includes the new parser, runtime, networking, codec, image
and accessibility fixtures. The explicit JavaScript compatibility gate remains
`./wbuild javascript_compatibility` and requires its pinned Node oracle. Native
image probes require a display and report a skip when none is available.
