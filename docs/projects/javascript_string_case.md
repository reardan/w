# Unicode String casing

String values expose shared non-enumerable `toLowerCase()` and `toUpperCase()`
methods. Default full casing is pinned to **Unicode 12.1.0**, matching this
runtime's identifier data version. Mappings preserve UTF-16 lone surrogates and
NUL, decode supplementary pairs, expand characters such as sharp-s and ligatures,
and apply the context-sensitive final-sigma rule to the original input. No
normalization or locale-specific Turkic/Lithuanian tailoring is performed.

The methods reject null/undefined receivers and otherwise use the existing
bounded primitive/ordinary `String` conversion, with observable conversion
method order and abrupt completion. Exotic wrappers and Symbol coercion remain
outside that conversion subset. `String.prototype` exposes the shared ordinary
prototype used by primitive property access; full boxed String exotic semantics
remain unsupported. Locale casing methods are not installed.

Each input/context code point consumes shared execution fuel. Output expansion
is checked against the runtime's string/property limit before append, and all
transient UTF-16 buffers are released on success and terminal failure. Original
strings remain unchanged. The case-ignorable context scans have linear aggregate
work because sigma is itself a non-ignorable boundary.

Sources are the [Unicode 12.1 UCD](https://www.unicode.org/Public/12.1.0/ucd/)
UnicodeData, SpecialCasing and DerivedCoreProperties files. Their SHA-256 pins
and regeneration procedure are in `tools/javascript_unicode_case.py`; the
compact vendored records retain provenance and use `UNICODE-LICENSE.txt`.
`python3 tools/javascript_unicode_case.py --check` validates deterministic table
regeneration without network access and runs in the focused manifest target.

Tests cover primitive and ordinary conversion, abrupt completion, Unicode
expansion/context/supplementary behavior, UTF-16 preservation, metadata and
execution/output/allocation exhaustion. Narrow guard-allocator groups check
cleanup independently of the full-suite allocation footprint.

The same manifest target also checks 5,682 native lower/upper results against
the configured Node engine for all 2,841 code points with a pinned 12.1 mapping.
The implementation checkpoint matches Node 20.19.3; this does not expand the
claimed Unicode version to that engine's newer character database.
