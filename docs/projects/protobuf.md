# Protobuf support (issue #16)

Design pass for issue #16, "Protobuf Support: align with struct - or
create a new keyword?" The issue's own text: "Add Protobuf support
directly to the language - similar to how JSON is supported. Protobuf
v2 or v3? Not sure but then have an adapter to convert between the
chosen format and the other format. Or could use a combined approach.
TBD - needs more research and thought." This is a **design-only**
document: it surveys the existing JSON precedent in detail (the issue's
own stated bar), weighs the surface options the issue names plus a
third one, recommends proto3-first with a staged plan, and lists open
questions. No implementation lands here, and nothing in this doc
touches `build.json` or any `.w` file.

## Tracker note

`docs/projects/sonnet_wave_plan_2026_07b.md` flags an issue-tracker
anomaly: issue #110, titled "Optimization," was found with a body that
duplicated this protobuf proposal, and asked whether #110's body had
been pasted over #16's by mistake. Re-checked while writing this doc
(2026-07-17): #110's body currently reads "Optimization pass - either
from the generated code (v0), or additional passes of the AST (v2)" —
a real, distinct optimization-pass proposal, not a protobuf duplicate.
Whether that reflects the maintainer already having cleaned it up, or
the wave-plan snapshot having caught it mid-edit, is not visible from
the issue history (no comments on either #16 or #110 as of this
writing). Either way: **#16 is the canonical protobuf issue** this doc
targets, and #110 should be treated as unrelated (an optimization-pass
proposal) unless a maintainer says otherwise. Nothing here depends on
#110's resolution.

## 0. Scope and where this work would live

Like `docs/projects/compress.md` before it, this doc's recommended
stage-1 deliverable is a leaf library: `libs/extras/protobuf/` (not
`libs/standard/`), because nothing in the compiler needs to depend on
it and it should not enter `w.w`'s seed import closure (CLAUDE.md's
"Seed constraint": `w.w`, `grammar.w`, `compiler/`, `grammar/`,
`code_generator/`, `debugger/`, the auto-imported container runtime,
and the `c_import`/`c_preprocessor`/`parser_generator` extras — nothing
else). Current language syntax is fine throughout stage 1 and no
`SEEDS` bump is implicated by it. That changes only at stage 3
(language integration), discussed in §9 — the one place this project
does touch the seed graph, the same way JSON's `grammar/json_builtin.w`
does today.

Three questions the issue asks, addressed in order below: §1 answers
"what does 'similar to JSON' actually mean today" by reading the JSON
implementation closely; §4 answers "align with struct, or a new
keyword" with a recommendation; §5 answers "v2 or v3, or an adapter."

## 1. The JSON precedent, read closely

The issue's bar is "similar to how JSON is supported," so the existing
implementation is the load-bearing prior art. It is not runtime
reflection — W has none — it is a **compile-time descriptor walk**
that runs once per struct type at its first use site.

### 1.1 Compiler side: `grammar/json_builtin.w`

`to_json(expr)` and `from_json(T, expr)` are grammar-level builtins
(`json_to_json_expr()` / `json_from_json_expr()`,
`grammar/json_builtin.w:274-335`). The first time either is used on a
given struct type, `json_codec_descriptor()`
(`grammar/json_builtin.w:145-209`) walks the type table
(`type_num_args`, `type_get_field_name_at`, `type_get_field_offset_at`,
`type_get_field_type_at`) and emits a small binary blob directly into
the instruction stream, behind an unconditional jump so it never
executes as code:

```
struct descriptor:
    word 0: field count
    word 1: struct size in bytes
    5 words per field: name, offset, kind, size, aux
```

(`structures/json_codec.w:11-29` documents this layout exactly.)
Repeat uses of the same struct type reuse the cached blob
(`json_codec_cache_lookup`/`_store`, `grammar/json_builtin.w:41-58`).
The builtin then lowers to a call into a runtime function
(`__w_json_encode(desc, addr)` / `__w_json_decode(desc, value)`) that
interprets the descriptor generically at run time. **No per-struct
code is generated** — one shared runtime walks every struct's
descriptor. This is the key mechanical idea to reuse: it sidesteps
both "true generics" (token-range re-parse monomorphization, ruled out
for containers generally in `docs/projects/typed_containers.md`'s
"Decision" section, for the same single-pass-no-AST reasons that would
apply here) and full runtime reflection (which W's type table does not
expose at run time at all — it exists only at compile time).

`json_codec_kind()` (`grammar/json_builtin.w:73-100`) enumerates what a
field type is allowed to be: int/fixed-width ints, bool, `char*`,
`string`, nested structs (kind 5), and `list[T]` of the above (kind 6).
It explicitly rejects maps and sets
(`grammar/json_builtin.w:82-83`: `if (type_is_map(t) | type_is_set(t)):
json_codec_unsupported(t)`), floats, arrays/slices, unions, and pointer
fields. This is a useful, already-precedented scoping choice: a
protobuf codec can start from the same restricted field-type set and
grow it later, rather than needing to solve every field-type shape on
day one.

### 1.2 Runtime side: `structures/json_codec.w`

`__w_json_encode`/`__w_json_decode` (`structures/json_codec.w:70-243`)
are the generic interpreters: they read the descriptor blob word by
word and dispatch on `kind`. Encoding produces a `json_value*` tree
(`structures/json.w`'s generic parse/serialize target); decoding walks
a parsed `json_value*` tree back into a freshly allocated, zeroed
struct buffer. Two things matter for a protobuf design:

- **JSON needs an intermediate tree; protobuf's wire format does
  not.** `structures/json.w`'s `json_value*` graph exists because JSON
  is a self-describing *text* format that `json.w` must be able to
  parse and print independent of any struct (`json_parse_value`,
  `json_append_value`). Protobuf's wire format is not self-describing
  text — it is binary, and encode/decode can go directly between
  struct bytes and wire bytes with no generic intermediate value type.
  This is a genuine simplification versus the JSON codec, not an
  extra step to design.
- **JSON decode is strict; protobuf decode must not be.** `structures/
  json_codec.w:139-176`'s decode is documented as "strict: a missing
  member or a type mismatch fails the whole decode" — every field
  named in the descriptor must be present in the JSON object or
  `__w_json_decode_into` returns 0. Protobuf's entire schema-evolution
  model is the opposite: a decoder MUST silently accept an absent
  field (leaves the struct's zero-initialized default) and MUST
  silently skip any field number it doesn't recognize (by wire type,
  see §2). A protobuf codec cannot reuse json_codec's strict decode
  loop verbatim; it needs its own, permissive-by-default semantics.
  This is flagged again as an explicit open question in §10, because
  it is a real, visible divergence from this codebase's only existing
  wire-codec precedent.

### 1.3 On-demand import, and what that means for the seed

`json_codec_finish_import()` (`grammar/json_builtin.w:343-351`) is
called by the driver at a top-level boundary after user files compile;
it imports `structures.json_codec` only `if (json_codec_needed)` —
i.e., only when some compiled program actually used `to_json`/
`from_json`. Confirmed by grep: no file in `compiler/`, `grammar/`,
`code_generator/`, `w.w`, or `codegen.w` calls `to_json`/`from_json`
anywhere, so `json_codec_needed` never flips to 1 while the seed
compiles itself — `structures/json.w` and `structures/json_codec.w`
are never actually compiled during `./wbuild build`'s bootstrap chain,
even though `bin/wv2 deps grammar.w` lists them (`deps` conservatively
reports the whole compiler-injected closure, per CLAUDE.md's "auto-
imported runtime" wording, not just what a given self-compile touches).
**Only `grammar/json_builtin.w` itself is unconditionally seed-
compiled** — it's statically imported by root `grammar.w`
(`import grammar.json_builtin`), so it must stay seed-era syntax
forever; the runtime codec (`structures/json_codec.w`) and the value
type (`structures/json.w`) do not need to, because they are compiled
by whatever compiler binary is building the *user's* program, which by
the time any real program uses `to_json` is already `bin/wv2` or
later, not the seed.

The same split would apply to protobuf: a future `grammar/
protobuf_builtin.w` (stage 3, §9) joins the mandatory seed-compiled set
the day it's statically imported by `grammar.w`, but the wire-format
runtime library (stage 1) never has to, regardless of how large it
grows, as long as the compiler's own sources never call its builtins.

## 2. Wire-format fundamentals, distilled

A protobuf message is a flat sequence of `(tag, value)` pairs, no
envelope, no length prefix at the message level (an embedded message
*field* is length-delimited, but the top-level message is exactly its
concatenated fields — this is why protobuf messages compose: a
serialized submessage's bytes are byte-identical whether standalone or
embedded).

**Tag**: a single varint, `(field_number << 3) | wire_type`. Field
numbers run 1 to 2^29-1 (19000-19999 reserved for implementation use);
numbers 1-15 fit in a one-byte tag, which is why the format spec
explicitly recommends reserving low numbers for frequently-set fields.

**Wire types** (3 bits): `0` varint, `1` 64-bit fixed, `2` length-
delimited, `5` 32-bit fixed. (`3`/`4`, start/end group, are a
deprecated legacy feature predating nested messages — skip them
entirely, no producer this repo would realistically talk to still
emits groups.)

- **Varint** (wire type 0): 7 payload bits per byte, high bit is a
  continuation flag, least-significant group first (the same shape as
  DWARF's ULEB128/LEB128, which `code_generator/`'s existing DWARF
  emission already produces — worth checking that code for a
  varint-encoder precedent before writing a new one from scratch,
  though DWARF's LEB128 helpers are compiler-internal and not a public
  library today). Used for `int32`/`int64`/`uint32`/`uint64`/`bool`/
  `enum`, and for `sint32`/`sint64` after zigzag transform.
- **Zigzag** (`sint32`/`sint64` only): maps signed values to unsigned
  so small-magnitude negatives stay small: `(n << 1) ^ (n >> 31)` for
  32-bit (arithmetic right shift produces all-1s or all-0s to flip the
  bits on negative inputs), decode is `(n >> 1) ^ -(n & 1)`. This is
  the *recommended* encoding for fields expected to be negative often.
- **A plain (non-zigzag) `int32`/`int64` field with a negative value
  always encodes as exactly 10 bytes** — the spec defines it as
  sign-extended to 64 bits *before* varint encoding, specifically so a
  32-bit and 64-bit negative value round-trip through the same wire
  representation. This is a well-known protobuf wire inefficiency and
  the entire reason `sint32`/`sint64` exist as an alternative. A W
  encoder must reproduce this deliberately: on the x86 default target
  a field declared `int32` lives in a 32-bit `int` host register, so
  sign-extension to 64 bits has to be done explicitly bit by bit (no
  free 64-bit host register to reuse); on x64 the host `int` is already
  64 bits, but a 32-bit protobuf field's value stored in it must still
  be explicitly re-sign-extended from bit 31 (not trusted to already be
  correctly sign-extended, since it could have arrived via a truncating
  store) — the same "don't rely on host word width, mask/extend
  explicitly" discipline `docs/projects/compress.md` §6.1 already
  established for this codebase's other 32-bit-defined wire formats.
- **64-bit fixed** (wire type 1): `fixed64`, `sfixed64`, `double` — 8
  raw little-endian bytes, no varint.
- **32-bit fixed** (wire type 5): `fixed32`, `sfixed32`, `float` — 4
  raw little-endian bytes.
- **Length-delimited** (wire type 2): a varint length followed by that
  many raw bytes. Covers `string`, `bytes`, embedded messages, and
  *packed* repeated scalar fields (proto3's default representation for
  a `repeated int32`-style field: one tag, one length, then the
  varints/fixed-width values back to back with no per-element tag).
  This is the same "declare the length, then don't scan for structure"
  idiom `libs/extras/vcs/delta.w`'s opcode stream and `cas.w`'s object
  framing already use elsewhere in this tree (see §3), just varint-
  length-prefixed instead of decimal-length-prefixed.
- **Unpacked repeated fields**: each occurrence is its own separate
  `(tag, value)` pair with the same field number repeated — the only
  representation for repeated *message*-typed fields (which can't be
  packed), and the pre-proto3 default for repeated scalars. **A
  decoder must accept both packed and unpacked encodings for the same
  field regardless of which one it would itself produce** — this is
  spec-mandated, not optional, because a schema can be shared between
  proto2 (unpacked default) and proto3 (packed default) producers.
- **Maps** are wire-format sugar, not a distinct wire type: `map<K,
  V>` is defined as exactly `repeated MapEntry { K key = 1; V value =
  2; }` under the hood, with unpacked-message-field semantics (each
  entry is its own length-delimited submessage). A codec that already
  supports repeated message fields gets maps for near-free once it
  understands the synthetic two-field `MapEntry` shape.
- **Unknown-field preservation/skipping** is the compatibility
  contract that makes the whole format work across schema versions: a
  decoder that sees a field number it doesn't recognize must skip
  exactly the right number of bytes for that field's wire type (a
  varint: read and discard one varint; fixed64/fixed32: discard 8/4
  bytes; length-delimited: read the length varint, discard that many
  bytes) and continue — never error, never stop. This is JSON's
  "just ignore extra object members" made explicit and wire-type-aware
  rather than free (JSON's text format doesn't need to know how long
  an unrecognized value is before skipping it; protobuf's binary
  format does).
- **proto2 vs proto3 syntax differences** (relevant to §5): proto2
  requires every field to be explicitly `optional` or `required` (plus
  supports `default` values and extensions); proto3 dropped `required`
  entirely (widely regarded, including by Google's own guidance, as a
  design mistake — a required field can never be safely removed or
  turned optional without breaking every existing serialized message,
  the opposite of what wire-compatible evolution is supposed to buy
  you) and made every scalar field implicitly optional with no way to
  distinguish "explicitly set to the zero value" from "never set" —
  until proto3 later (2020) added an explicit `optional` qualifier back
  for scalars via a synthetic one-field `oneof`, as an additive,
  backward-compatible spec change.

## 3. W-specific layout facts that shape this design

`compiler/type_table.w`'s struct layout has one property worth stating
plainly because it changes how "align with struct" should be read:
**W struct fields are byte-packed, with zero alignment padding.**
`type_add_arg()` (`compiler/type_table.w:983-1005`) accumulates the
struct's total size as a running sum of `type_get_size(field_type)` at
declaration time (unions instead take the max field size, `:1001-1003`);
`type_get_field_offset_at()` (`compiler/type_table.w:1070-1080`)
recomputes a field's offset the same way, by summing every preceding
field's size. There is no C-style alignment-to-natural-boundary
anywhere in this path — a `char` field immediately followed by an
`int` field sits at offset 1, not offset 4. (Confirmed by reading the
full function bodies, not inferred from a comment.)

Two consequences for protobuf specifically:

- **In-memory struct layout cannot double as protobuf wire-field
  identity.** Protobuf's field numbers are deliberately decoupled from
  a message's in-memory or declaration order specifically so fields
  can be reordered, renamed, or interleaved with new fields across
  schema versions without breaking wire compatibility — that
  decoupling is the entire point of numbered fields, not an
  implementation detail. Any surface that maps "field declaration
  position" directly to "wire field number" (an implicit, W-struct-
  order-is-the-schema design) would make reordering fields — a change
  every other field in the codebase's own type table already tolerates
  silently — a silent wire-compatibility break. This is materially
  worse than JSON's position-independence: JSON already identifies
  fields by name (stable identity, matches struct field names 1:1), so
  json_codec's approach never had this hazard to begin with. §4
  weighs this explicitly against each surface.
- **Encode order need not match declaration order, and probably
  should be field-number order.** Because the descriptor-blob approach
  (§1.1) already computes and caches each field's descriptor once at
  compile time, sorting the field list by wire number before emitting
  the blob costs nothing at run time and buys deterministic wire
  output (useful for golden-vector tests in §8, and for any consumer
  that wants byte-stable output for hashing/caching, the same
  determinism concern `compress.md` raised for `gzip_compress`'s fixed
  header fields). Real protobuf implementations do not guarantee
  ascending field-number encode order either, but doing so here is
  free and strictly nicer for testing.

## 4. Candidate surfaces

The issue asks directly: "align with struct - or create a new
keyword?" Three surfaces, following `map_default_factory.md`'s per-
surface breakdown shape (syntax, lowering, runtime support, opt-in/
seed cost).

### 4.1 Surface A — annotate the existing `struct`

W has **no attribute, decorator, or pragma syntax at the language
level today** (confirmed by grep of README.md and every
`docs/projects/*.md`; the only "pragma" hits in the tree are
`libs/extras/c_preprocessor/`'s C `#pragma` handling, which exists to
parse *C headers*, not W source, and is irrelevant here). Two
sub-variants:

- **A1 — comment convention** (e.g. a trailing `# proto: 1` per
  field), consumed only by an offline tool, never by the compiler
  itself. Zero grammar/seed cost, but **unenforced**: a typo'd or
  stale comment silently breaks wire compatibility and the type
  checker cannot catch it, because comments are invisible to the
  compiler by definition. This runs directly against this codebase's
  own fixture-driven, frozen-diagnostic culture (CLAUDE.md: diagnostic
  text is pinned, warnings fail `--strict` builds) — a schema-critical
  fact living only in a comment is the kind of silent-drift risk this
  repo otherwise designs against everywhere else.
- **A2 — a real per-field annotation**, e.g. reusing `=` inside a
  `struct` body (`int x = 1` meaning "wire field 1") or a bracket/call
  form (`int x proto(1)`, `int x [1]`). `=` specifically collides with
  a real, already-flagged future feature: `docs/todo.txt`'s "future
  language features" list includes "top-level `int x = 5`
  initialization sugar," and the field-initializer-`=` ambiguity this
  would create for *struct* fields specifically is exactly the kind of
  two-meanings-for-one-token problem the language has avoided so far.
  A bracket/call form avoids that collision but is still new grammar
  surface added to `struct_declaration.w` (seed-compiled, since
  `struct` declarations are parsed by the compiler front end
  regardless of whether the program uses protobuf), for a feature that
  only a fraction of `struct` users would ever touch.

### 4.2 Surface B — a new keyword (e.g. `message`)

A dedicated declaration kind, parallel to `struct`/`union`/`enum`,
whose field syntax *requires* a wire number (`int x = 1` is
unambiguous here, because `message` fields never had a competing
"initializer" meaning to begin with — the collision A2 has with future
struct-initializer sugar doesn't exist for a brand-new keyword).
Gives a natural home for proto2-only concepts (`optional`/`required`)
without touching `struct`'s existing semantics at all, and a clean
place for a `repeated` field qualifier distinct from `list[T]` if the
codegen path (§4.3) wants to emit idiomatic-looking generated code.
Cost: a genuinely new top-level declaration kind in the seed-compiled
grammar and type table (comparable in class, though not necessarily in
size, to what adding `union` previously cost — not measured directly
here, flagged as a sizing unknown in §10) — larger than Surface A's
marginal cost, but the field-number concept gets to be first-class and
compiler-checked (duplicate or malformed field numbers become compile
errors, not silent wire bugs) rather than bolted onto `struct` with a
semantics `struct` never asked for.

### 4.3 Surface C — offline `.proto` → W codegen via the parser generator

`libs/extras/parser_generator/` (milestones 1-2 landed: lexer, token
stream, grammar-rule matching, AST nodes with visitor/listener
traversal per `docs/projects/parser_generator.md`) is a directly
applicable tool for parsing `.proto` IDL text: write a `.pg` grammar
for proto3's `message`/`field`/`enum`/`oneof`/`package`/`import`/
`option` syntax (proto3 first, per §5), generate a lexer+parser+AST
from it the same way `tests/parser_generator/w.pg` generates the W-
in-W parser this repo already tests with, then hand-write a source
emitter — structurally identical to `libs/extras/parser_generator/
generator.w` itself, described in its own header as "a deterministic W
source emitter" — that walks the parsed `.proto` AST and writes out
ordinary W declarations plus whatever descriptor machinery the chosen
underlying surface needs. This needs **no new struct/grammar syntax at
all** in the compiler itself: the `.proto` grammar and its emitter both
live under `libs/extras/`/`tools/`, outside the seed closure entirely
(same placement rationale as `parser_generator` itself, which is only
pulled into the seed graph because the compiler's own `c_import`
feature happens to use it — a `.proto` codegen tool would have no such
coupling).

**Key point, easy to miss**: Surface C is not a fourth independent
alternative to A/B — it is a *front end* that still has to target one
of A's or B's output shape, because generated code has to state field
numbers *somehow*, in a form the runtime encode/decode path can read.
Surface C answers "who writes the annotated declaration, a human or a
tool" — it does not answer "what the annotated declaration looks
like." That question is still A vs. B.

### 4.4 Recommendation

**Adopt Surface B (a new `message` keyword) as the canonical
annotated-declaration shape, with Surface C (`.proto` → W codegen via
the parser generator) as an additive, later front end that targets
it.** Reject Surface A in both sub-forms.

Rationale:

- **Field-number identity needs compiler enforcement, not convention.**
  §3 already showed why "declaration position = wire number" (a form
  A's naive shape would otherwise tempt) is a strictly worse hazard
  here than it would be for JSON. A2's bracket/call annotation on
  `struct` gets the enforcement but at the cost of grafting a
  meaning-heavy annotation onto a declaration kind (`struct`) that
  every existing W program already uses for purposes that have nothing
  to do with wire formats — every `struct` becomes a candidate site for
  a syntax feature 95%+ of structs will never use. A dedicated keyword
  scopes the new grammar surface to exactly the programs that opt into
  it.
- **This is, in spirit, exactly what "align with struct" asks for.**
  The compiler-side machinery a `message` keyword needs — walk fields,
  emit a descriptor blob behind a jump, cache by canonical type index,
  lower two builtins (`to_proto`/`from_proto`) to calls into a runtime
  interpreter of that blob — is a structural copy of
  `json_codec_descriptor()` (§1.1) with one extra word per field (the
  wire number) and a permissive rather than strict decode loop (§1.2).
  `message` would reuse `struct`'s own field-storage type-table
  plumbing (same by-value/by-pointer semantics, same packed layout)
  under the hood; the only new concept is the per-field wire number.
  So the "align with struct" framing is satisfied at the mechanism
  level even though the concrete spelling is a new keyword, not literal
  reuse of the `struct` token.
- **Surface C becomes strictly more valuable once B exists**, because
  hand-written and `.proto`-generated messages become the exact same
  construct and interoperate freely — a hand-written `message` can
  reference a generated one and vice versa, with no separate "was this
  struct built by codegen" distinction anywhere in the type system.
  Building C first and inventing its own separate runtime
  representation (to avoid depending on an unfinished B) would risk
  needing a second migration later; building B first, even minimally,
  gives C a stable target from day one.

## 5. proto2 vs. proto3

**Recommendation: implement proto3 semantics as the only wire dialect
initially; treat proto2 interop as a deferred adapter, not a parallel
implementation, per the issue's own "have an adapter to convert between
the chosen format and the other" phrasing.**

Rationale:

- proto3 is simpler to implement correctly first: no `required`
  fields (Google's own retrospective guidance treats `required` as a
  design mistake — see §2's compatibility argument), no extensions, no
  custom default values to track per field, no wire-format `group`
  legacy to support. Every one of those is strictly additional
  complexity proto2 carries that proto3 does not.
- proto3 is also the more relevant target for whatever this repo would
  actually build against it: modern protobuf usage (gRPC service
  definitions, most public `.proto` schemas written since ~2016) is
  overwhelmingly proto3. There is no concrete proto2 consumer named
  anywhere in this repo's issues or docs today.
- **Recommended presence semantics**: ship without explicit field-
  presence tracking first (proto3's own original 2016 design — a
  scalar field's zero value and "never set" are indistinguishable),
  matching how W already treats zero-initialized struct fields
  elsewhere in this codebase (e.g. a freshly `new`'d struct's fields
  start at their type's zero value with no separate "was this field
  touched" bit). Add proto3's `optional` qualifier (explicit presence
  via a synthetic one-field `oneof`, the real spec's own 2020 addition)
  later as additive, backward-compatible follow-up work if a real
  consumer needs to distinguish "explicitly zero" from "unset" — this
  mirrors the order the actual protobuf spec itself evolved in, so
  this repo is not improvising a sequencing that upstream hasn't
  already validated.
- **proto2 as an adapter, not a dialect**: recommend scoping proto2
  support to the `.proto`-parsing front end (Surface C, §4.3) only —
  accept proto2 `.proto` syntax (`required`/`optional`/`default`,
  extensions) as *input*, and lower it to proto3-shaped `message`
  output, with `required` becoming an advisory-only comment (never
  wire-enforced, since proto3's own decoder wouldn't enforce it either)
  and a diagnostic on anything genuinely lossy (a `default` value with
  no proto3 equivalent, an extension range). A real proto2 wire-
  compatibility mode (needed only to talk to an existing proto2
  producer that behaves differently on the wire — e.g. treats
  unset-vs-zero as observably different) is real, additional scope;
  defer it until a concrete consumer is named, matching this repo's
  general "build what a real caller needs, not speculative breadth"
  bias already visible in `compress.md`'s buffer-vs-streaming call and
  `map_default_factory.md`'s explicit-over-implicit bias.

## 6. API sketch (stage 1 — the wire-format library)

Path: `libs/extras/protobuf/`, mirroring `libs/extras/compress/`'s
placement rationale exactly (§0) — a leaf library, current syntax
throughout, no seed impact.

```
libs/extras/protobuf/varint.w    # varint + zigzag encode/decode
libs/extras/protobuf/wire.w      # tag encode/decode, wire-type
                                  # constants, skip-unknown-field
libs/extras/protobuf/message.w   # generic encode/decode driven by a
                                  # (stage-1: hand-written) field
                                  # descriptor
```

### 6.1 `varint.w` — cannot fail on valid input except at decode

```
int varint_encode(int value, char* out)             # bytes written;
                                                      # value's low 32
                                                      # or 64 bits per
                                                      # the field width
                                                      # the caller has
                                                      # already chosen
int varint_decode(char* data, int length, int* out)  # bytes consumed,
                                                      # 0 on truncated
                                                      # or over-long
                                                      # (>10 bytes)
                                                      # input

int zigzag_encode32(int n)
int zigzag_decode32(int n)
int zigzag_encode64(int n)   # x64 only, mirrors int64's own gating
int zigzag_decode64(int n)
```

Encoding trusted, caller-chosen values cannot semantically fail (same
`docs/error_results.txt` reasoning `compress.md` §5.1 applied to
checksums: "no recovery path for encode a value, only a value to
return"); decoding untrusted bytes can, and returns a sentinel (0 bytes
consumed) rather than a `wresult`, matching the low-level, no-allocation
character of `code_generator/`'s own DWARF LEB128 helpers — reserve
`wresult[T]*` for the message-level API in §6.3, where an error has a
recovery path (reject a malformed message) worth communicating with a
code, not just a boolean.

### 6.2 `wire.w` — tags and the skip-unknown-field primitive

```
int PB_WIRE_VARINT()             # 0
int PB_WIRE_FIXED64()            # 1
int PB_WIRE_LENGTH_DELIMITED()   # 2
int PB_WIRE_FIXED32()            # 5

int wire_tag_encode(int field_number, int wire_type, char* out)
int wire_tag_decode(char* data, int length, int* field_number,
                     int* wire_type)   # bytes consumed, 0 on truncated

# Skips exactly one field's payload for the given wire_type (the
# unknown-field-tolerance primitive every consumer of this library
# needs — see §2's "unknown-field preservation" and §7's decode
# strictness note). Returns bytes skipped, 0 on truncated/malformed.
int wire_skip_field(char* data, int length, int wire_type)
```

### 6.3 `message.w` — the generic encode/decode driven by a descriptor

Stage 1 authors descriptors **by hand**, as literal W data (the task's
own framing: "hand-written descriptors + golden-vector tests"), since
compiler integration is stage 3. Structurally parallel to
`structures/json_codec.w`'s descriptor blob (§1.1), but flattened into
ordinary structs since there is no compile-time code-stream-emission
trick available (or needed) outside the compiler:

```
struct pb_field_desc:
    int number    # wire field number
    int kind       # PB_KIND_* — varint-int, zigzag-int, fixed32,
                   # fixed64, float, double, bytes/string, embedded
                   # message, repeated-of-any-of-the-above
    int offset     # byte offset into the struct
    int aux        # nested message descriptor / element kind, for
                   # message and repeated fields (mirrors json_codec's
                   # 'aux' field exactly, same meaning)

struct pb_message_desc:
    int field_count
    pb_field_desc* fields
    int struct_size

char* pb_encode(pb_message_desc* desc, char* addr, int* out_length)
    # never fails on a well-formed descriptor/struct pair — plain
    # return, no wresult, same reasoning as deflate()/zlib_compress()
    # in compress.md §5.5

wresult[char*]* pb_decode(pb_message_desc* desc, char* data,
                           int length, char* out)
    # out: a pre-sized, zero-initialized buffer of struct_size bytes
    # (mirrors __w_json_decode's own "malloc + zero before decode"
    # step). Untrusted wire bytes get a real wresult error path
    # (docs/error_results.txt: "wresult[T] when the caller can choose
    # what to do next") -- unlike json_codec's strict all-or-nothing
    # decode, a missing field here is NOT an error (§1.2, §7): the
    # wresult only reports genuine malformation (truncated varint,
    # bad wire type, length that overruns the buffer).

int PB_ERR_TRUNCATED()          # input ended mid-field
int PB_ERR_BAD_WIRE_TYPE()      # wire_type not 0/1/2/5
int PB_ERR_BAD_VARINT()         # varint exceeds 10 bytes (no
                                 # terminating byte within the limit)
int PB_ERR_LENGTH_OVERRUN()     # length-delimited field's declared
                                 # length exceeds the remaining buffer
char* pb_error_string(int code)
```

Repeated fields reuse `list[T]` exactly the way `json_codec_kind`'s
kind-6 already does for JSON (§1.1) — same element-kind/element-size
plumbing, no new container machinery. Map fields are scoped out of
stage 1, matching the **existing** JSON codec's own map/set rejection
(§1.1); §2 already noted maps are wire-sugar for a repeated two-field
submessage, so map support becomes a straightforward follow-up once
repeated message fields work, for both codecs symmetrically — this is
not a protobuf-specific gap.

## 7. Non-goals

- **gRPC / RPC services** (`service X { rpc Method(...) returns
  (...); }`). A different scope entirely — network transport (gRPC
  requires HTTP/2 framing, which `libs/standard/web/`'s existing HTTP
  client/TLS stack does not have), streaming semantics, service
  discovery. Out of scope until a concrete consumer needs RPC, and even
  then it deserves its own design doc, not an extension of this one.
- **Full reflection / dynamic messages** (protobuf's `Descriptor`/
  `DynamicMessage` API: introspecting or building a message at run time
  from a schema the program didn't have compiled in). The JSON
  precedent never built this either — `to_json`/`from_json` always
  target a statically-known struct type; `structures/json.w`'s generic
  `json_value*` tree is the closest analog, and even that requires a
  known W struct on the decode side. Consistent with `docs/projects/
  typed_containers.md`'s broader stance that single-pass W resists
  this kind of runtime-schema dynamism structurally, not just by
  choice.
- **Extensions (proto2) and well-known types** (`google.protobuf.Any`,
  `Timestamp`, `Duration`, etc.). Deferred per §5's proto2-as-adapter
  recommendation. Well-known types are not wire-magic — they are
  ordinary messages upstream happens to standardize the shape of — so
  once stage 3 (message keyword) exists, they can be hand-authored
  `message` definitions with no additional codec work; this is
  unscheduled, not blocked.
- **Text format and canonical proto3 JSON mapping.** Both are
  additional serialization formats layered on the same descriptor;
  worth their own follow-up doc once stage 3 ships a descriptor to
  layer them over, not part of this doc's stages.
- **Streaming/incremental encode-decode.** Buffer-to-buffer only, for
  the same reasons `compress.md` §4 gave for DEFLATE: every consumer
  this repo would plausibly have for protobuf (config, build metadata,
  a future IPC or build-cache wire format) is small enough that whole-
  buffer round-trips are the right default, and it matches every
  existing wire-format precedent already in this tree (`json_codec`,
  `cas.w`'s object framing, `delta.w`'s opcode stream, all §1-§3).

## 8. Test strategy (no `protoc` dependency required)

- **Committed hex golden vectors as the mandatory gate**, following
  `tests/compress_corpus_test.w` + `tests/compress/deflate_corpus.txt`'s
  already-shipped precedent almost exactly (that pair exists in-tree
  today, not just as a design proposal — the strongest possible
  evidence this approach works here). Protobuf vectors are naturally
  small and enumerable per wire-type/feature combination rather than
  needing a big corpus sweep, so a hand-written `tests/
  protobuf_wire_test.w` with one `test_*` function per case (varint
  boundary values, zigzag sign handling, fixed32/64, length-delimited
  string, nested message, packed vs. unpacked repeated, unknown-field
  skip, truncated/malformed inputs hitting each `PB_ERR_*` code) is the
  right shape — closer to `compress_inflate_test.w`'s hand-crafted
  block fixtures than to the corpus file. Vectors can be hand-computed
  (varint/tag arithmetic is simple enough to verify by hand for small
  field counts) or generated once with any real protobuf
  implementation at fixture-authoring time and committed as hex text —
  never a build-time dependency, mirroring `tests/asm/corpus_*.txt` and
  `deflate_corpus.txt`'s own "generated once, committed as text" note.
- **Round-trip property tests**, the right invariant stated precisely:
  `decode(encode(x)) == x` (semantic round-trip through this library's
  *own* encoder) is guaranteed; `encode(decode(bytes)) == bytes`
  (byte-identical re-encode) is **not**, because protobuf permits
  multiple valid wire encodings of the same logical value (packed vs.
  unpacked repeated fields, a varint with gratuitous non-minimal
  continuation bytes some encoders — deliberately or buggily — emit).
  Test the guaranteed direction only, using `lib/rand.w`'s seedable
  `rand_state` (`rand_init(seed)`) to generate a few hundred random
  struct instances per message shape with a fixed seed for
  reproducibility, exactly matching `compress.md` §8's fuzz-ish
  round-trip plan.
- **Optional `protoc` cross-validation**, gated on tool availability —
  but the exact gating precedent differs from `compress.md`'s. That
  doc could gate on `python3`'s *standard library* `zlib` module
  (always present, no extra install). Protobuf has no equivalent:
  Python's `protobuf` package is a separate pip dependency, not
  stdlib, so the honest equivalent is `build.base.json`'s
  `openssl_interop_test` shape instead — gate on `command -v protoc`,
  print a "...OK (skipped: no protoc on PATH)" success (not a failure)
  when absent, run under a timeout, never a required target. Because
  this will be skipped on most CI/dev machines (unlike zlib, which is
  essentially always available), **the golden-vector suite above is
  load-bearing, not a nice-to-have supplement** — it is the only test
  layer guaranteed to run everywhere.

## 9. Staged plan and sizing

**Stage 1 — runtime encode/decode library, hand-written descriptors,
golden-vector tests.** `libs/extras/protobuf/{varint,wire,message}.w` +
`tests/protobuf_wire_test.w` + `tests/protobuf/*_corpus.txt` if a
corpus file turns out to help. No compiler or grammar changes, no seed
impact whatsoever — a leaf library exactly like `compress/`'s own
stage 1. Estimated **~600-900 lines including tests**: smaller than
`compress.md`'s 900-1100 estimate for its stage 1 (protobuf's wire
format has no Huffman tables or LZ77 match-finding — it is
mechanically simpler than DEFLATE), but the field-kind dispatch,
packed-vs-unpacked repeated handling, and the permissive-decode/
unknown-field-skip logic (§1.2, §2) add real breadth beyond a bare
varint codec.

**Stage 2 — `.proto` → W codegen** (Surface C, §4.3). A `.pg` grammar
for proto3 IDL syntax (`message`/`field`/`enum`/`oneof`/`package`/
`import`/`option`; proto2 accepted as adapter input per §5) under
`libs/extras/parser_generator/` or a dedicated `tools/protobuf_pg/`,
plus a hand-written emitter parallel to `parser_generator/generator.w`
itself (already described in its own header as "a deterministic W
source emitter") that walks the parsed AST via `ast_node.w`'s existing
visitor/listener hooks and writes `message` declarations (once stage 3
lands) or, if sequenced before stage 3, plain structs plus
`pb_message_desc` literals targeting stage 1's library directly — a
useful intermediate milestone that avoids a hard stage-2-depends-on-
stage-3 ordering, since the codegen tool can ship and be useful before
language integration exists, then get re-targeted at `message` syntax
once it does. Needs only PG's already-landed milestones (1-2: lexer,
grammar rules, AST/listener traversal) — does **not** need milestone 4
(actions/predicates, still future per the wave plan), since the
emitter is a plain post-parse AST walk, the same shape `generator.w`
already uses for the self-hosted W-parses-W case. Estimated
**~800-1200 lines** (grammar + emitter + tests) — larger than stage 1,
comparable to a PG milestone's own sizing, because a real IDL grammar
(proto3's own spec grammar has roughly fifteen keywords, nested
message/enum, options, reserved ranges) has genuine surface area.

**Stage 3 — language integration mirroring JSON.** The `message`
keyword (§4.4), `to_proto`/`from_proto` builtins lowering to a
compiler-emitted descriptor blob (`grammar/protobuf_builtin.w`,
structurally parallel to `grammar/json_builtin.w`) calling into a
runtime module (either a promoted `structures/protobuf_codec.w`, or
stage 1's `libs/extras/protobuf/message.w` imported on demand exactly
like `json_codec.w` is today — an open question in §10). This is the
one stage that actually joins the seed's mandatory-compile graph
(`grammar/protobuf_builtin.w` would need a static `import
grammar.protobuf_builtin` from root `grammar.w`, exactly like
`json_builtin` today), so it needs seed-era-only syntax in that file
and should be treated as this project's **HIGH**-care stage, per this
repo's own wave-execution convention (touches `grammar/`, the compiler
front end) — merges last and alone, gated on `./wbuild verify` (+
`verify_x64`). Estimated **500-700 lines** for the grammar/compiler
side (`json_builtin.w` is 350 lines, `json_codec.w` is 243; protobuf's
extra per-field wire-number bookkeeping and wire-type dispatch pushes
this modestly larger) plus whatever the new `message`-keyword parsing
itself costs in the struct-declaration-equivalent grammar path
(unmeasured here — flagged as a sizing unknown in §10).

**Total across all three stages: roughly 2000-2800 lines including
tests**, split across three independently mergeable pieces of work,
matching `compress.md`'s own "ship a correct thing, then automate,
then integrate" staging philosophy. Stage 1 alone already delivers a
usable wire-format library — any consumer willing to hand-write
descriptors (a build-cache protocol, an IPC format wanting something
more compact than JSON) does not have to wait for stages 2-3.

## 10. Open questions for the maintainer

1. **Keyword spelling, or Surface A after all.** This doc recommends a
   new `message` keyword (§4.4) over annotating `struct`, but the
   issue's own phrasing poses this as a genuinely open question, and
   the seed-graph cost is real (§4.2) — worth an explicit maintainer
   call before stage 3 is scheduled, even though stages 1-2 do not
   need an answer yet.
2. **proto2 scope and timeline.** §5 assumes no concrete proto2
   consumer exists today and recommends deferring real proto2 wire
   compatibility indefinitely, treating it only as adapter input to
   the `.proto` parser. Confirm there's no known near-term need to
   talk to an actual proto2 producer that would change this.
3. **Long-term home of the low-level wire library.** Stage 1 proposes
   `libs/extras/protobuf/` (leaf, matching `compress`/`vcs`). If stage
   3 promotes the message-level codec into `structures/` (auto-imported
   on demand like `json_codec.w`), does the low-level varint/tag layer
   move there too, or stay in `libs/extras/protobuf/` as a dependency
   `structures/protobuf_codec.w` imports? `compress.md` never had to
   answer this because compression has no compiler-integration stage.
4. **Field-number collision checking, and how far to take it.** Within
   one `message`, detecting a duplicate or malformed field number at
   compile time is straightforward (a symbol-table-style check, stage
   3 table stakes, assumed in §9's estimate). Detecting a field-number
   *reuse* across a message's history — the actual compatibility
   promise protobuf schemas rely on, i.e. "don't reassign a retired
   field number to a new field" — needs comparing against some
   previous version of the descriptor and has no analog anywhere in
   this codebase today. This doc scopes only the in-message duplicate
   check into stage 3 and leaves cross-version checking fully
   unscoped; worth a maintainer opinion on whether it's wanted at all,
   and if so, roughly when.
5. **Strict vs. permissive decode, explicitly.** §1.2 and §6.3 both
   flag that a correct protobuf decoder *must* be permissive (missing
   fields keep their zero default, unknown fields are silently
   skipped) — the opposite of `json_codec`'s existing strict-decode
   behavior, which is this codebase's only other wire-codec precedent
   and its own established "explicit over implicit" bias
   (`map_default_factory.md` §3 catalogs several places this bias
   shows up already). This doc recommends permissive-by-default as a
   hard requirement of doing protobuf correctly at all, not a stylistic
   choice — but it is a real, visible divergence from the JSON
   precedent this whole design otherwise leans on, and deserves an
   explicit sign-off rather than an assumed one.
