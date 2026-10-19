# Bounded JavaScript regular expressions

`libs/extras/javascript/runtime_regexp.w` provides a deliberately partial native
RegExp implementation. It is independent of `lib.regex`: JavaScript strings are
UTF-16 unit arrays, whereas that library operates on sentinel-terminated bytes.
Embedded NUL, supplementary characters, and lone surrogates remain intact.
The existing JavaScript lexer/lowerer/printer already preserve regex literals;
only runtime admission, evaluation, ownership, and intrinsic installation need
hooks in `runtime.w`.

## Supported surface

- Fresh regex objects for each literal evaluation; `RegExp()` / `new RegExp()`
  with primitive pattern and flag arguments. An undefined pattern is empty.
- Ordered alternatives, capturing and `(?:noncapturing)` groups, literals,
  dot, bracket classes and ranges (including negation), `^` and `$`.
- Greedy/lazy `*`, `+`, and `?`. Repetition clears captures inside the repeated
  atom; unmatched captures are `undefined`. Nullable optional atoms skip
  zero-width iterations. Repeated nullable `*`/`+` atoms remain unsupported.
- Atomic positive and negative lookahead, including nested assertions, preserve
  the input position, ordered captures and outer backtracking.
- `\d`, `\D`, `\w`, `\W`, `\s`, `\S`, control escapes `\n\r\t\f\v`,
  `\0` without a following digit, fixed-width `\xHH`/`\uHHHH`, escaped
  punctuation/identity escapes, and class backspace `\b`.
- Flags `g`, `i`, `m`, `s`, `y`, returned in canonical order. **Ignore-case is
  ASCII only**: non-ASCII pattern literals, decoded escapes/ranges, or input
  cause terminal unsupported status rather than an incorrect match.
- `test` and `exec`; match arrays contain captures, `index`, `input`, and
  `groups: undefined`. Global/sticky `lastIndex` reads, writes, reset on failed
  match, and zero-width exec behavior follow the supported non-Unicode rules.
  `lastIndex` accepts number/boolean/null/undefined primitives; other coercions
  are explicitly unsupported.
- `source`, `flags`, `global`, `ignoreCase`, `multiline`, `dotAll`, and `sticky`
  prototype getters; getter-only properties cannot be assigned. `lastIndex`
  is writable, non-enumerable, and non-configurable. Writes required by exec
  throw when it is made read-only through the native descriptor API.
- `String.replace` with string or native regex search and primitive replacement
  text or callable replacement. Callbacks receive the match, captures, UTF-16
  offset and input; global matches are collected before callbacks run. Substitutions include `$$`, `$&`, prefix/suffix, and numbered captures,
  including two-digit fallback and unmatched captures. Global empty matches
  advance one UTF-16 unit; replacement output has the runtime string limit.
- `String.prototype.split` with an intrinsic RegExp separator uses a fresh sticky
  matcher, preserves the separator's `lastIndex`, inserts captures (including
  unmatched `undefined` entries), and advances empty matches by UTF-16 code unit.
  Receiver conversion, constructor/flags access and `ToUint32(limit)` preserve
  observable order and exceptions. The default clone uses the internal pattern;
  an own `source` getter and the original separator's own `exec` are not invoked.
  String separators use the separate bounded string-split implementation.

The unchanged W host's `/\n$/`, Preact 10.27.2's unitless-style-property pattern,
`/(PointerCapture)$|Capture$/i`, `/xlink(H|:h)/`, and `/sName$/` use these general
operations without source rewriting. This does **not** establish full Preact
execution: its other JavaScript syntax and DOM requirements are separate work.

## Explicit gaps

Unsupported features terminate with runtime status 6. They include counted
quantifiers/brace syntax, repeated nullable atoms with `*` or `+`, lookbehind,
word-boundary assertions, backreferences, named groups, legacy octal/control
escapes, Unicode property escapes, `d`/`u`/`v` flags, non-ASCII ignore-case,
RegExp-object constructor arguments, custom callable `exec` overrides,
object coercion in RegExp construction and `test`/`exec`, and string/object
`lastIndex` coercion. Symbol protocols (including `Symbol.split`), custom
subclass/species construction, custom callable `exec` on the split clone,
match/search, `toString`, and generic getter behavior are not implemented.
RegExp split supports the intrinsic separator path; this does not implement the
full `RegExp.prototype[Symbol.split]` protocol or Unicode `u`/`v` semantics.
The intrinsic `flags` getter reads native flags, not user-overridden flag
properties. This is a bounded subset, not an ECMAScript conformance claim.

Malformed supported constructor grammar and duplicate/invalid flags throw a
runtime error with the intrinsic `SyntaxError.prototype`. Unsupported failures
and resource limits are terminal and cannot be caught by JavaScript. Literal feature rejection happens
at evaluation; the runtime syntax preflight does not compile all regex patterns
before earlier statements execute.

## Resource and ownership contract

Patterns are limited to 1,024 UTF-16 units, 32 nested groups, 16 captures,
2,048 parse nodes, and 4,096 instructions. A runtime may retain at most 65,536
pattern units including one unit of accounting per regex. Compilation, search,
VM instructions, replacement flag scans and construction, split cloning and
output construction consume the existing execution budget. Split output is
bounded by the runtime array/property limit and all emitted strings retain the
runtime string limit. The backtracking stack is explicit: at most 4,097 live
states, including the current state, are shared across nested assertions. Assertion/group nesting is
limited to 32; no recursive matching depends on input length. Budget/stack/storage/output
exhaustion reports status 5, never a false “no match.” Per-instruction class
scans are additionally bounded by the pattern-size cap.

Compiled programs contain no managed JavaScript references. Each regex value
owns its program; collection and runtime teardown release instructions, parse
nodes, ranges, and UTF-16 source and return its storage charge. Partially
compiled programs and abandoned backtracking states are freed on every error.
The prototype is an explicit runtime GC root.

## Validation

`./wbuild javascript_runtime_regexp_test` checks the host/Preact patterns,
capture ordering and reset, greedy/lazy matching, classes and anchors,
UTF-16/NUL, `lastIndex`, replacements, descriptors, explicit rejection, budget
and storage limits, partial compile cleanup, GC, and forced debug-allocator
leak detection. The memory-mode run focuses on native limit/cleanup and
retained-regex lifetime paths; the complete parser-heavy semantic suite runs
normally to avoid exhausting the debug allocator's virtual-memory map table.

`javascript_runtime_regexp_lookahead_test` checks assertion capture ordering,
negative clearing, nesting, zero-width optional behavior and shared limit cleanup.
`javascript_runtime_string_replace_test` checks callback ordering, arguments,
exceptions, UTF-16 offsets, quotas, foreign values and collection ownership.
`javascript_runtime_regexp_split_test` checks capture insertion, empty matches,
limits, UTF-16, coercion/access order, preserved separator state, exceptions,
foreign values, GC and resource exhaustion; `javascript_runtime_string_split_test`
checks the string-separator path. A fresh explicit-path reference refresh at
W `4a948ab3` confirmed the retained split comparison's 162 cases (18 patterns by
9 inputs) against Node 20.19.3, recording `process.execPath` and `process.version`.
Earlier runs did not retain enough executable provenance to attribute their
Node version independently. These focused
tests passed normally and in their guard allocator paths. Complete upstream
String.split audits still contain failures and unsupported cases; full pinned
RegExp-family conformance remains unverified.

The semantic JavaScript snippets were also evaluated in Node as a reference.
Rules were checked against the [ECMAScript RegExp and String text-processing
algorithms](https://tc39.es/ecma262/multipage/text-processing.html).
