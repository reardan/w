# Win browser foundations

This is the library integration map for [#637](https://github.com/reardan/w/issues/637).
Win's tabs, mutable DOM, selector matching, cascade/layout, event scheduling,
cookies/cache and content isolation remain in the application repository.

| Foundation | Import / documentation | Delivered boundary |
| --- | --- | --- |
| HTML | `libs.extras.html.html`; [HTML](html.md) | Owned explicit-length tokens and static trees, spans, diagnostics, budgets, raw/RCDATA/script content, initial implied-element and malformed-markup recovery |
| CSS | `libs.extras.css.css`; [CSS](css.md) | Owned tokens, selectors as component groups, stylesheet/at-rule/declaration nodes, escapes, balanced blocks and local recovery |
| JavaScript AST | `libs.extras.javascript.parser`, `.lower`, `.text`; [JavaScript](javascript.md) | Loops, functions, try/catch/finally, UTF-16 values preserving NUL and lone surrogates, caller parser limits, explicit unsupported lowerings |
| JavaScript execution | `libs.extras.javascript.runtime`; [embedding](javascript.md#embed-the-interpreter) | Binary64 subset interpreter on 64-bit targets, lexical closures, values/objects/arrays, completion results, host callbacks, isolated heaps, roots/cyclic collection and terminal budgets |
| URLs / loading | `libs.standard.web.urlparse`, `.http_client`; [networking](browser_network.md) | References/fragments, dot segments, IPv6 syntax, origin tuples, owned clients, checked total-deadline transport, task cancellation, redirect approval/final URL, bounded delivery |
| Content decoding | `libs.standard.web.content_decode`; [decoding](browser_network.md#content-decoding) | Bounded chunk collection and explicit completion, identity and registered gzip/deflate, separate input/output caps |
| Images | `graphics.image.png`, `.jpeg`, `graphics.ui.render`; [images](images.md) | Bounded PNG and baseline JPEG into owned RGBA; texture updates, alpha, scaling, clipping, queued lifetime and native readback probes |
| Accessibility | `graphics.ui.accessibility`; [UI dependencies](browser_ui.md) | Bounded semantic snapshots, explicit-length UTF-8 metadata, stable IDs, validated host actions and focus proposals |

The support contracts are intentionally specific. HTML does not implement every
WHATWG tree algorithm or entity; CSS does not validate every selector/property
or apply cascade; the interpreter is a documented semantic subset rather than
complete ECMAScript. It returns control on a budget failure but cannot resume an
aborted evaluation. HTTP transport remains IPv4, with explicit clients serialized
individually. Content decoding collects compressed input before decoding, and
inherits the existing gzip single-member/trailing-data behavior. PNG excludes
interlace and packed/16-bit samples; JPEG excludes progressive and unsupported
scan/color modes. Consult each linked document before accepting a wider input
contract.

Text shaping, bidi, grapheme-aware editing and broader native IME remain
[#459](https://github.com/reardan/w/issues/459). Native accessibility bridges and
automatic widget metadata remain [#465](https://github.com/reardan/w/issues/465).
This change exposes the reusable semantic boundary for page content and controls;
it does not claim those platform projects are complete. Broader JavaScript
syntax/early-error compatibility remains [#492](https://github.com/reardan/w/issues/492).

## Consumers and reproducibility

`examples/web/browser_resource.w` combines checked resource loading, bounded
content decoding and HTML/CSS parsing. It restricts redirects to the same origin
for demonstration. `examples/javascript/embed.w` demonstrates a host callback;
`examples/web/html_document.w`, `css_inspect.w` and `png_inspect.w` demonstrate
independent consumers. None implements application DOM/layout policy.

Use `--import-root /path/to/pinned/w` when compiling outside the dependency
checkout. HTML, CSS and image decoders need no generator or external library at
build/run time. The maintained HTML/CSS token specifications record their scope
and provenance. JavaScript consumers first run `./wbuild javascript_parser` in
the dependency checkout. UI consumers retain the existing reproducible
`ui_font_data`/`generated` build targets and checked-in font inputs. JPEG fixture
generation is separate from normal builds; its provenance and reproduction
instructions accompany the checked-in fixture bytes.

Tests are conventional `_test.w` targets discovered by `wbuild`. The full
`./wbuild tests` suite includes the new parser, runtime, networking, codec, image
and accessibility fixtures. The explicit JavaScript compatibility gate remains
`./wbuild javascript_compatibility` and requires its pinned Node oracle. Native
image probes require a display and report a skip when none is available.
