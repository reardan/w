# C Preprocessor Research

Deep research on the C preprocessor: what the language requires, how the
canonical books describe it, how real implementations in C and Python are
built, and what that means for this repository. This started as the design
groundwork for replacing the old `c_import` behavior that merely skipped
`#...` lines as lexer trivia.

> **Current status:** the subset preprocessor recommended below now exists in
> `libs/extras/c_preprocessor/` (option 2: Prosser hide sets, conditionals,
> include search with `#include_next` and `#pragma once`, GNU comma
> swallowing, placemarkers), and `c_import` uses it for broad system-header
> import. `make tests` covers the preprocessor directly and through
> `c_import_libc_test` on both x86 and x64; see `docs/projects/c_import.md`
> for the importer that consumes it.

Primary sources: K&R "The C Programming Language" 2nd ed. (sections 4.11 and
A.12), ISO C11 draft N1570 (5.1.1.2 and 6.10), Dave Prosser's X3J11/86-196
macro expansion algorithm, GCC cpplib internals documentation, and the source
of eight implementations (Ritchie's cpp in lcc, chibicc, 8cc, tcc, GCC
libcpp, Clang, PLY `cpp.py`, pcpp). All non-obvious semantics claims below
were verified empirically against GNU `cpp` 13.3 and cross-checked with
`pcpp` and PLY's `cpp.py`; the results tables record actual outputs.

## 1. History and role

The preprocessor was added to C around 1972-73, "partly at the urging of Alan
Snyder, but also in recognition of the utility of the file-inclusion
mechanisms available in BCPL and PL/I" (Ritchie, "The Development of the C
Language"). The first version had only `#include` and parameterless
`#define`. Mike Lesk and then John Reiser extended it with function-like
macros and conditional compilation. It was an *optional adjunct* — early
compilers did not even invoke it unless the file began with a `#` — which
explains why its syntax (line-oriented, whitespace-significant, its own
grammar) never integrated with the rest of the language, and why its
semantics stayed vague until ANSI X3J11 pinned them down in 1989. Dave
Prosser was the draft redactor; his pseudocode (section 5 below) became the
standard's wording for macro replacement.

K&R 2nd ed. covers the preprocessor twice:

- **Section 4.11** (tutorial): file inclusion, macro substitution,
  conditional inclusion. Introduces the classic pitfalls — `#define
  square(x) x * x` broken by `square(z+1)`, double evaluation in
  `max(i++, j++)` — plus `#undef`, `#` stringizing with string-literal
  concatenation (`#define dprint(expr) printf(#expr " = %g\n", expr)`),
  `##` pasting, and include guards written as `#if !defined(HDR)`.
- **Appendix A.12** (reference): the phase structure (trigraphs, line
  splicing, tokenization, directive execution), exact `#define` /
  redefinition / argument-collection rules, `#include` forms including the
  macro-expanded form, conditional compilation with the `defined` operator,
  `#line`, `#error`, `#pragma`, the null directive, and the five predefined
  macros `__LINE__` `__FILE__` `__DATE__` `__TIME__` `__STDC__`. A.12.3
  documents the `cat`/`xcat` pasting subtlety verified in section 4.4. K&R
  itself calls some of the ANSI concatenation rules "bizarre".

Two framing facts worth keeping in mind:

- The preprocessor is a **token processor, not a text processor**. Since
  ANSI C, macro replacement is defined over *preprocessing tokens*, never
  over characters. Every correct implementation tokenizes first;
  implementations that string-splice (early cpps, naive regex approaches)
  cannot implement the standard.
- The preprocessing language is designed to **always terminate**. Recursive
  macros do not loop; they stop via the "blue paint" rule (section 4.5).

## 2. The pipeline: translation phases 1-4

ISO C 5.1.1.2 defines translation phases. The preprocessor is phases 1-4;
phases 5-6 (escape-sequence conversion, adjacent string-literal
concatenation) are usually done by the same code before handing tokens to
the parser:

1. **Character mapping.** Physical source characters map to the source
   character set; OS line endings become newlines. Trigraphs (`??=` → `#`,
   `??/` → `\`, ... nine total, a concession to ISO 646 terminals) are
   replaced here (removed in C23; GCC ignores them unless `-std=` strict or
   `-trigraphs`).
2. **Line splicing.** Every `backslash newline` pair is deleted, joining
   physical lines into logical lines. Single pass — a line ending in two
   backslashes does not cascade. Because this happens before tokenization,
   a token or a `//` comment can be split mid-word across lines.
3. **Tokenization.** The file becomes *preprocessing tokens* and
   whitespace. Comments are replaced by one space. Pp-token categories:
   header names (only recognized inside `#include`), identifiers,
   **pp-numbers**, character constants, string literals, punctuators, and
   "each non-white-space character that cannot be one of the above".
   Longest-match ("maximal munch") applies.
4. **Directive execution and macro expansion.** Line-oriented: a `#` that is
   the first pp-token on a logical line begins a directive. `#include`d
   files recursively go through phases 1-4.

Notes with implementation consequences:

- **Pp-numbers are weird on purpose.** A pp-number matches
  `.? digit (digit | ident-char | e± | p± | .)*`, so `1e-X` is a *single*
  token (no macro expansion of `X` inside it), while `1 - X` is three.
  Verified: with `#define X 5`, `cpp` leaves `1e-X` and `0x1p+X` untouched
  but rewrites `1 - X` to `1 - 5`, and `GLUE(1e, 3)` pastes to the valid
  pp-number `1e3`. The category exists so the lexer need not understand
  floating syntax; the number only has to be a valid numeric token *after*
  phase 7.
- **Header names are context-sensitive.** `<stdio.h>` is one token only
  while scanning a `#include` (or `__has_include`) line; elsewhere `<` is a
  less-than. Every implementation special-cases the lexer mode for this
  (Clang: `LexIncludeFilename`; chibicc reconstructs the name from `<` ...
  `>` token spellings).
- **Phases are logical, not literal.** GCC performs phases 1-3 in a single
  scan for speed; the standard only requires behaving *as if* ordered.
  Ritchie's cpp does the same inside `fillbuf`/`trigraph`/`foldline`.
- **Whitespace must be tracked per token.** Two bits per token suffice:
  "preceded by space" and "first on line" (chibicc: `has_space`, `at_bol`;
  GCC: `PREV_WHITE`, `BOL`). They are needed for directive detection
  (`#` at line start), for `#` stringizing (interior spaces collapse to
  one), for correct `-E` text output (section 4.7), and for the
  function-like-macro "`(` must directly follow with no space in the
  *definition*" rule.

## 3. Directives

Grammar shape (C11 6.10): a *group* of lines; each directive is one logical
line. `# ` alone is the **null directive** (no effect). A `#` line whose
keyword is unrecognized is a *non-directive* — a conforming preprocessor
diagnoses it; K&R-era cpps often passed it through.

### 3.1 `#include`

Three forms (K&R A.12.4, C11 6.10.2):

1. `#include <name>` — search the implementation-defined system path list.
2. `#include "name"` — search "in association with the original source
   file" (in practice: the includer's directory, then any `-I` paths), then
   fall back to form 1.
3. `#include pp-tokens` — **computed include**: the tokens are
   macro-expanded and must then match form 1 or 2. K&R shows
   `#if SYSTEM == SYSV / #define HDR "sysv.h" / ... / #include HDR`.

Facts and gotchas:

- The quoted filename is *not* a string literal: escape sequences are not
  interpreted (`"C:\foo"` contains a backslash and an `f`). chibicc
  comments this explicitly and re-reads the raw spelling.
- Includes nest; conforming implementations must support at least 15 levels
  of `#include` nesting and 63 levels of conditional nesting (C11 5.2.4.1
  translation limits); real headers rely on far deeper nesting being fine.
- **Include guards** (`#ifndef FOO_H` / `#define FOO_H` / ... / `#endif`)
  are the portable idiom. Serious implementations detect the pattern and
  cache "this file is guarded by macro M" so a re-include whose guard is
  already defined skips even *opening* the file (chibicc
  `detect_include_guard`; GCC's "multiple include optimization"). This is a
  major real-world performance lever.
- `#pragma once` (nonstandard but universal) marks the current file
  include-once; keyed by resolved path (chibicc hashes the path; pcpp keys
  on inode xor size — `__file_unique_id` — so two paths to one file work).
- GNU extensions needed to parse glibc headers: `#include_next`
  (continue the search *after* the directory where the current file was
  found — used by wrapper headers) and `__has_include(...)` (C23 now
  standardizes it).

### 3.2 `#define` and `#undef`

- **Object-like**: `#define name replacement-tokens`. There must be
  whitespace between name and replacement (C11 constraint).
- **Function-like**: `#define name(a, b, ...) replacement` — the `(` must
  *immediately* follow the name with no space, otherwise the `(` belongs to
  the replacement (this is how `#define f (x)` differs from
  `#define f(x)`). Parameters are ordinary identifiers, unique within the
  definition; scope ends at the newline.
- Macro names live in **one namespace**, shared by object-like and
  function-like macros, unrelated to C scopes; a definition lasts from the
  directive to end of translation unit or `#undef`.
- **Redefinition** is an error unless the new definition is
  *token-identical* (same tokens, same spellings, same parameter names,
  whitespace agreeing only in presence/absence). Both K&R A.12.3 and C11
  6.10.3p1-2 state this; GCC warns rather than errors outside strict mode.
- `#undef` of an unknown name is legal and silent.
- Command-line `-D name[=value]` / `-U name` behave as `#define` / `#undef`
  lines before the first source line (`-D name` defaults to `1` — see lcc
  cpp `doadefine`).

### 3.3 Conditionals

`#if expr`, `#ifdef n`, `#ifndef n`, `#elif expr`, `#else`, `#endif`; C23
adds `#elifdef` / `#elifndef`. Semantics (K&R A.12.5, C11 6.10.1):

- Arms are evaluated in order; the first true arm's group is processed;
  remaining arms are *skipped*. Skipped text needs only lexically valid
  pp-tokens and correct conditional nesting — the skipper must still
  recognize nested `#if...#endif` (all implementations have a dedicated
  fast "skip to matching `#elif/#else/#endif`" loop, e.g. chibicc
  `skip_cond_incl`) and must still tokenize enough to not be fooled by
  `#` inside strings or comments.
- The controlling expression: first `defined X` / `defined(X)` is replaced
  by `1` or `0`, then normal macro expansion runs on what remains, then
  **every remaining identifier is replaced by `0`** (so `#if
  UNDEFINED_NAME` is `#if 0`; keywords too — there are no keywords in phase
  4). Then it is evaluated as an integer constant expression with all
  arithmetic in the widest types: `long` in K&R, `intmax_t`/`uintmax_t`
  since C99. No casts, no `sizeof`, no enum constants, no floats;
  character constants allowed (`#if 'A' == 65` is true on ASCII systems but
  implementation-defined in general).
- `defined` produced *by* macro expansion is undefined behavior (GCC
  supports it with a warning; tcc handles it via a `pp_expr` flag).
- Verified locally: `#if UNDEFINED_NAME` took the `#else` arm; `defined()`,
  shifts, division, negatives, and character constants all evaluated as
  expected (`t5_if_eval.c`).

Implementation note: expression evaluation is a miniature expression
compiler. Ritchie's cpp uses an operator-precedence table indexed by token
type driving a value/operator stack (`lcc/cpp/eval.c`, 529 lines); chibicc
reuses the compiler's own `const_expr` on the expanded token line; pcpp
generates a PLY yacc parser with a `Value` class that emulates 64-bit
two's-complement signed/unsigned wraparound.

### 3.4 Line control, diagnostics, pragmas

- `#line 42 "file.c"` — overrides `__LINE__`/`__FILE__` bookkeeping, for
  the benefit of code generators (yacc etc.). The directive's tokens are
  macro-expanded first. Preprocessed output uses *line markers*
  (`# 1 "file.c" 1 3 4` in GNU form) so the compiler proper can map
  positions back; `-P` suppresses them.
- `#error tokens` — mandatory diagnostic, compilation fails. C23 adds
  `#warning` (long-standing GNU extension).
- `#pragma tokens` — implementation-defined escape hatch; unknown pragmas
  are ignored. C99 added the `_Pragma("...")` *operator* form, which —
  unlike the directive — can be produced by macro expansion (C11 6.10.9;
  note 6.10.3.4p3: expansion output is never re-parsed as a directive,
  *except* `_Pragma` unary operator expressions, which are processed).
  `STDC FP_CONTRACT` etc. are standard pragmas.
- `#embed "file" limit(N) prefix(...) suffix(...) if_empty(...)` — C23
  binary resource inclusion (expands to a comma-separated byte list;
  `__has_embed` probes availability). GCC 15 / Clang 19 implement it.

### 3.5 Predefined macros

K&R A.12.10 lists the original five, all unredefinable and un-`#undef`able:
`__LINE__`, `__FILE__`, `__DATE__` (`"Mmm dd yyyy"`), `__TIME__`
(`"hh:mm:ss"`), `__STDC__` (`1`). C99 added `__STDC_VERSION__`,
`__STDC_HOSTED__`, and the special *predeclared identifier* `__func__`
(function scope, not a macro). Real toolchains predefine dozens more —
platform (`__linux__`, `__x86_64__`, `unix`), ABI (`__LP64__`,
`__SIZEOF_POINTER__`), and dialect macros. chibicc's `init_macros` is a
useful minimal list that satisfies glibc headers (~45 entries plus dynamic
handlers for `__FILE__`, `__LINE__`, `__COUNTER__`, `__TIMESTAMP__`,
`__BASE_FILE__`). Dynamic macros are implemented as ordinary macro-table
entries whose value is a callback (chibicc `macro_handler_fn`, 8cc
`MACRO_SPECIAL`, GCC `NODE_BUILTIN`), and `__FILE__`/`__LINE__` must report
the location of the *outermost* macro invocation (chibicc walks
`tok->origin`).

## 4. Macro expansion semantics

This is the hard 20% that costs 80% of the effort. The rules (C11 6.10.3.1-5):

### 4.1 Invocation

An object-like macro name is replaced wherever it appears as an identifier
token (never inside strings — they are single tokens by now). A
function-like macro name is an invocation **only if the next pp-token is
`(`** — otherwise it is left alone (`int (*p)(int) = f;` with
`#define f(x) ...` stays `f`; verified). The `(` may be separated by any
whitespace *including newlines*: an invocation can span lines, and its
argument list ends at the **matching** `)`, with commas at depth 0
separating arguments. Argument counts must match arity exactly (empty
arguments are legal since C99: `EMPTY(,2)` has args `` and `2`; verified
`[|2]`). A directive line inside an argument list is undefined behavior
(GCC errors; some cpps accept).

Subtle consequence of "next token": at end of a replacement list or
argument, whether a function-like macro name is followed by `(` may not be
knowable until *later* context is appended — the name expands or not
depending on what follows in the outer stream. Verified: with
`#define g(x) x` and `#define call g`, the input `call(5)(6)` yields
`5(6)` — the `g` produced by `call` finds its `(` in the *source text after
the invocation*. This is exactly the case naive scanners get wrong
(section 7.1).

### 4.2 Argument prescan

Each use of a parameter in the replacement list is substituted by its
argument **fully macro-expanded first**, *as if the argument formed the
whole rest of the file* — **unless** the parameter is an operand of `#` or
`##`, in which case the *raw* argument tokens are used (C11 6.10.3.1).
Hence the ubiquitous two-level idiom:

```c
#define STR(s)  #s
#define XSTR(s) STR(s)
STR(N)   // "N"    — raw argument
XSTR(N)  // "42"   — N expanded on the way into STR
```

Verified, along with `PASTE(ONE, ONE)` → `ONEONE` but `ID(ONE)` → `1`.
Because prescan expands an argument in isolation, a function-like macro
name at the end of an argument does not expand during prescan (no `(`
available) yet may expand later during rescan — GCC's internals docs call
this out as a deliberately handled corner.

### 4.3 `#` — stringizing

`# param` becomes a single string-literal token spelling the argument's
tokens: interior whitespace runs collapse to one space, leading/trailing
whitespace drops, and `\` is prefixed to every `"` and `\` *inside string
or character literals* in the argument. Empty argument → `""`. Verified:
`STR(a  +   "b\n")` → `"a + \"b\\n\""`. If the result is not a valid
string literal, behavior is undefined. `#` is only meaningful in
function-like replacement lists and must be followed by a parameter
(constraint).

### 4.4 `##` — token pasting

Before rescanning, each `##` in the replacement (not ones that arrived
*from arguments*) is deleted and its neighbor tokens are concatenated into
one new pp-token. Parameters adjacent to `##` substitute raw arguments; an
empty argument substitutes a **placemarker** token (C99 invention) so that
`t(,4,5)` and friends work out; placemarker ⋈ placemarker = placemarker,
placemarker ⋈ T = T, and placemarkers evaporate before rescan. The pasted
result must be a valid pp-token, else UB (`cat(cat(1,2),3)` pastes `)` with
`3` — GCC errors "does not give a valid preprocessing token"; K&R A.12.3
walks this exact example and shows the `xcat` fix, verified:
`xcat(xcat(1,2),3)` → `123`). The paste result **is** available for
further replacement (verified: `cat(A, B)` with `#define AB 99` → `99`).
Evaluation order among multiple `##` is unspecified. The C11 placemarker
example verified end-to-end:

```c
#define t(x,y,z) x ## y ## z
int j[] = { t(1,2,3), t(,4,5), t(6,,7), t(8,9,),
            t(10,,), t(,11,), t(,,12), t(,,) };
// → int j[] = { 123, 45, 67, 89, 10, 11, 12, };
```

Implementation reality: pasting means re-lexing the concatenated spelling
(chibicc: `paste()` re-tokenizes and errors if ≠1 token; Ritchie's cpp
`doconcat` re-lexes and warns; GCC glues spellings then validates). Also
note the C11 6.10.3.3 EXAMPLE 4 (verified): pasting `#` with `#` via
`hash_hash` produces a `##` *token* that is **not** the `##` operator —
operators are positions in the original replacement list, not spellings.

### 4.5 Rescanning and blue paint

After substitution and `#`/`##` processing, the result is rescanned **together
with all subsequent preprocessing tokens of the source file** for more
macros (C11 6.10.3.4). Two protections make this terminate:

> If the name of the macro being replaced is found during this scan of the
> replacement list (not including the rest of the source file's
> preprocessing tokens), it is not replaced. Furthermore, if any nested
> replacements encounter the name of the macro being replaced, it is not
> replaced. These nonreplaced macro name preprocessing tokens are no longer
> available for further replacement even if they are later (re)examined in
> contexts in which that macro name preprocessing token would otherwise
> have been replaced.

Informally: while expanding `M`, occurrences of `M` in the result are
*painted blue* and stay painted forever. Verified: `#define T U` +
`#define U T` leaves `T`; `#define FOO 1 + FOO` leaves `1 + FOO`;
`#define foo(x) bar x` on `foo(foo) (2)` leaves `bar foo (2)` — the inner
`foo` was examined while `foo` was being expanded, painted, and is *still*
unexpandable when the following `(2)` would otherwise complete an
invocation.

The expansion output is never re-interpreted as a directive even if it
looks like one (6.10.3.4p3).

One corner is deliberately **unspecified** (6.10.3.4p4):

```c
#define f(a) a*g
#define g(a) f(a)
f(2)(9)   // either "2*9*g" or "2*f(9)"
```

GCC, chibicc, pcpp all produce `2*9*g` (verified for gcc); the choice
corresponds to using hide-set *intersection* in Prosser's algorithm.

The full C11 6.10.3.5 EXAMPLE 3 "torture" fragment (nested invocations,
`#undef`/redefine, `t(t(g)(0) + t)(1)`, `m(m)`, empty args to `r`) was run
through GNU cpp and pcpp; both produce the standard's answer:

```c
f(2 * (y+1)) + f(2 * (f(2 * (z[0])))) % f(2 * (0)) + t(1);
f(2 * (2+(3,4)-0,1)) | f(2 * (~ 5)) & f(2 * (0,1))^m(0,1);
int i[] = { 1, 23, 4, 5, };
char c[2][6] = { "hello", "" };
```

Any new implementation should adopt this fragment (and the placemarker
example) as a regression test verbatim.

### 4.6 Variadic macros

- **C99**: `#define LOG(fmt, ...)` — trailing arguments merge (with their
  commas) into `__VA_ARGS__`, usable only in variadic replacement lists.
  There must be at least one more argument than named parameters in C99/C11
  (C23 relaxes: zero variadic arguments allowed).
- **GNU** `, ## __VA_ARGS__`: if `__VA_ARGS__` is empty the comma is
  swallowed. Ubiquitous in Linux-ecosystem headers; chibicc, 8cc, tcc, GCC
  all special-case it (verified `LOG3("hi")` → `printf("hi")`).
- **C23/C++20** `__VA_OPT__(tokens)`: expands to its tokens iff variadic
  arguments are non-empty — the standardized fix (verified with
  `-std=c2x`). Also GNU named variadics `args...` exist in old headers.

### 4.7 Output spacing

A preprocessor that prints text (rather than feeding tokens onward) must
not create tokens that were not there: `#define PLUS +` then `1 PLUS+2`
must print `1 + +2`, never `1 ++2`; `F(-)-x` with `#define F(x) x` must
print `- -x` (both verified). GCC dedicates a cpplib chapter ("Token
Spacing") to when a space must be synthesized from the `PREV_WHITE` bits;
Ritchie's cpp carries `wslen` per token for the same reason.

## 5. Prosser's algorithm (the reference solution)

The standard's rescanning prose was *reverse-engineered from an algorithm*:
X3J11/86-196, drafted by Dave Prosser in 1986 so the committee could agree
on behavior, then translated to standardese. Diomidis Spinellis obtained
and republished it (spinellis.gr/blog/20060626/cpp.algo.pdf) after
discovering his ad-hoc CScout expander failed on Linux kernel macros like:

```c
#define A B
#define B C
#define X(val) Y(val)
#define C(a)  D((a))
X((A(1)) | (A(2)));   // must give: Y((D((1))) | (D((2))));
```

(verified against gcc, pcpp, and PLY cpp — all agree). The algorithm
attaches a **hide set** (set of macro names) to every token; a token whose
own name is in its hide set is never expanded. Three mutually recursive
functions over token sequences (`TS`) with hide sets (`HS`):

```text
expand(TS):
  if TS empty                        → {}
  if T.hs contains T                 → T, then expand(rest)          # painted
  if T is object-like macro          → expand( subst(body(T), {}, {},
                                          T.hs ∪ {T}, {}) • rest )
  if T is function-like macro and
     next is ( actuals )HS' ...      → expand( subst(body(T), formals, actuals,
                                          (T.hs ∩ HS') ∪ {T}, {}) • rest' )
  else                               → T, then expand(rest)

subst(IS, FP, AP, HS, OS):           # build output OS from replacement IS
  if IS empty                        → hsadd(HS, OS)                 # paint result
  if IS is '#'  param ...            → OS • stringize(arg)
  if IS is '##' param ...            → OS glued with raw arg (skip if empty)
  if IS is '##' token ...            → OS glued with token
  if IS is param '##' ...            → OS • raw arg (placemarker rules if empty)
  if IS is param ...                 → OS • expand(arg)              # prescan
  else                               → OS • token

glue(LS, RS):   paste last token of LS with first of RS (hide set = ∩)
hsadd(HS, TS):  union HS into every token's hide set in TS
```

Key insights:

- **Object-like:** new hide set = token's hide set ∪ {macro}.
- **Function-like:** new hide set = (macro-name-token's hide set ∩ the
  **closing parenthesis**'s hide set) ∪ {macro}. The intersection is the
  clever part: the invocation's tokens may come from different expansion
  histories, and intersecting yields the *most* replacement possible
  without looping. The standard leaves this choice unspecified; Prosser's
  intersection is what GCC/Clang behavior matches in practice.
- Arguments are expanded (`expand(arg)`) only for plain parameter uses —
  `#`/`##` operands take raw tokens — exactly C11 6.10.3.1.
- Everything terminates because each replacement strictly grows hide sets.

Spinellis's Dr. Dobb's article ("Code Finessing", 2006) is also a
performance war story: transliterating the functional pseudocode gave
correct-but-quadratic behavior (GCC's `strcmp` macro expands to ~900
tokens; 12.2 s), fixed by manual tail-call elimination to iteration
(0.16 s). Lesson: implement Prosser *semantics* with iterative scanning and
cheap set representations, not literal list-copying recursion.

## 6. Implementation survey — C

Line counts from checkouts made for this research (July 2026).

| Implementation | Size (pp part) | Recursion control | Token model | Notable |
|---|---|---|---|---|
| Ritchie cpp (in lcc `cpp/`) | ~2,800 lines total | hide sets (interned ints) | `Tokenrow` arrays over char buffers | the original ANSI-era reference |
| chibicc `preprocess.c` | 1,208 | hide sets (linked list per token) | singly linked `Token` list | cleanest Prosser implementation to read |
| 8cc `cpp.c` | 1,014 | hide sets (`Set`) | pull-based lexer + unget stack | literal Prosser, explicitly cited |
| tcc `tccpp.c` | 3,961 | dynamic `nested_list` + `SYM_FIELD` token marking | int-encoded token stream | fastest; single pass; integrated |
| GCC libcpp | tens of kLoC (whole lib) | `NODE_DISABLED` flag + context stack + `NO_EXPAND` token copies | read-only token runs + contexts | production; documented in "cpplib internals" |
| Clang `lib/Lex` | tens of kLoC (whole lib) | `DisableMacro()`/`EnableMacro()` + `Token::DisableExpand` flag | `TokenLexer` stack | expansion source locations for diagnostics |
| mcpp | ~10k | (conforming; DECUS cpp lineage) | text/token hybrid | ships the standard **Validation Suite** |

### 6.1 Ritchie's cpp (lcc `cpp/`)

Dennis Ritchie's ANSI preprocessor, bundled with lcc (confirmed provenance
via comp.std.c). Architecture: `cpp.c` main loop → `lex.c` (a hand-built
DFA in `expandlex()` that *generates* its state tables at startup; `EOB`
sentinel bytes for buffer refills) → `tokens.c` (`Tokenrow` = resizable
token array windowed by `bp/tp/lp`) → `macro.c` (`expandrow`/`expand`/
`gatherargs`/`substargs`/`doconcat`/`stringify`) → `eval.c` (precedence
table + dual stacks) → `hideset.c`, `include.c`, `nlist.c` (hash table).
Distinctive choices:

- **Interned hide sets**: a hide set is a small `unsigned short` index into
  a global table of sorted `Nlist*` arrays; `newhideset(hs, np)` returns an
  existing index when the union already exists. Cheap to store per token,
  cheap to compare; caps at 32 entries and just stops growing (recursion
  depth beyond that is unreachable in practice).
- Hide sets only on `NAME` tokens (only names can be macros) — but note
  this loses the *rparen* hide set that Prosser's function-like
  intersection wants; Ritchie unions with the macro-name token's set
  instead (`hs = newhideset(trp->tp->hideset, np)` in `expand`).
- `quicklook()` two-character bitmask so non-macro identifiers cost one
  AND, no hash lookup.
- `gatherargs` marks `##` tokens *arriving inside arguments* as `DSHARP1`
  so `doconcat` won't treat them as operators — the positional-operator
  rule of 6.10.3.3 implemented with one token-type bit.

### 6.2 chibicc `preprocess.c` (Rui Ueyama)

The best study text. 1,208 lines implementing the whole thing: hidesets as
per-token linked lists with `hideset_union` / `hideset_intersection` (used
exactly as Prosser specifies at the function-like rparen), `subst()`
handling `#`, `##`, `,##__VA_ARGS__`, `__VA_OPT__`, argument prescan via a
recursive `preprocess2` call; `#if` stack (`CondIncl`), computed includes,
`#include_next`, include-guard detection, `#pragma once`, line markers,
built-in dynamic macros, and final passes `convert_pp_tokens` (pp-number →
real number) and `join_adjacent_string_literals` (phase 6). Pasting
re-tokenizes the concatenated spelling and errors unless exactly one token
results. Every expanded token records its `origin` for `__LINE__`/
`__FILE__` and diagnostics. The header comment states the termination
guarantee informally: "a macro is applied only once for each token".

### 6.3 8cc (same author, earlier)

Pull-model: `read_expand()` asks the lexer for one token at a time and
*ungets* substituted token vectors back onto the input stack
(`unget_all`), so rescanning-with-following-context falls out naturally.
Hide sets via a `Set` ADT; `subst` is a direct transliteration of
Prosser's case analysis over `(t0, t1)` pairs including the GNU comma
rule. Special macros are handler callbacks. Contrast with chibicc's
whole-list model: chibicc materializes the entire token list up front and
splices; 8cc streams. Both are Prosser-faithful.

### 6.4 TinyCC `tccpp.c`

Speed-first integrated design. Tokens are ints (interned identifiers ≥
`TOK_IDENT`) in growable `TokenString` buffers. Recursion control is *not*
hide sets: a `nested_list` of `Sym`s tracks macros currently being
expanded (like the dynamic "disabled" approach), and blocked names get
`SYM_FIELD` OR-ed into the token int — a per-token paint bit — so they
stay unexpandable afterwards. `macro_subst_tok` + `macro_arg_subst` +
`next_argstream` cooperate so a function-like name at the end of one
stream can find its `(` in the next (the `call(5)(6)` case). This is the
pragmatic middle path: no sets, two mechanisms (stack + paint bit), tiny
constant factors, conforming on all the cases tested here.

### 6.5 GCC libcpp

Documented in "The GNU C Preprocessor Internals" (cppinternals). No hide
sets. Instead:

- A **context stack** (`cpp_context` list): the top context is the
  unexpanded replacement list of the innermost macro under expansion; base
  context reads from the lexer. Exhausted contexts pop lazily (only when
  the *next* token is requested), which keeps a macro disabled while its
  last token is being considered — a subtle ordering the docs call out.
- `enter_macro_context` pushes the replacement (with `CPP_MACRO_ARG`
  parameter tokens already replaced; arguments pre-expanded into a
  temporary context first when required) and then sets **`NODE_DISABLED`**
  on the macro's hash node; `_cpp_pop_context` clears it. Disabled-ness is
  therefore a property of the *macro* while its expansion is live — the
  first half of 6.10.3.4p2.
- The second half ("no longer available even if re-examined later") is
  implemented by copying the token and setting **`NO_EXPAND`** on the copy
  when a disabled macro name is encountered (tokens are read-only once
  lexed). Clang does the same with `Token::DisableExpand`, and diagnoses
  it ("disabled expansion of recursive macro" warning).
- Function-like lookahead (`is the next real token '('?`) is complicated
  by *padding tokens* inserted for spacing correctness; cpplib documents
  the one-token backup dance. Output spacing gets its own chapter — avoid
  accidental pasting (`PLUS+` case) with minimal spaces.

GCC also keeps a **traditional (pre-standard) mode** (`-traditional-cpp`,
`cpptrad.c`) replicating K&R-era text-substitution behavior — useful
reading to understand exactly what ANSI changed (no `#`/`##`, arguments
substituted inside strings, different recursion behavior).

### 6.6 Clang `lib/Lex`

`Preprocessor` owns macro tables and include state; each active expansion
is a `TokenLexer` on a stack. On identifier lex: if it is a macro, enabled,
not `DisableExpand`, and (if function-like) followed by `(`
(`isNextPPTokenOneOf<tok::l_paren>`), push a `TokenLexer`;
`Macro->DisableMacro()` *after* argument pre-expansion (ordering required
so arguments can still use the macro), `EnableMacro()` on pop. Every
expanded token gets an *expansion SourceLocation* chunk so diagnostics can
print full macro backtraces — the gold standard for error reporting
through macros.

### 6.7 mcpp and the Validation Suite

mcpp (Kiyoshi Matsui) is the conformance yardstick: a portable standalone
C90/C99/C++98 preprocessor grown from DECUS cpp, shipping a **Validation
Suite** of hundreds of numbered test cases with a published scoring of
other preprocessors (GCC, VC++, Borland, Wave...). Its docs are a catalog
of real-world conformance bugs. pcpp tests against a lightly modified copy
of this suite; any serious new implementation should too. Also notable:
**ucpp** (small embeddable C99 pp, used by some toolchains) and
**Boost.Wave** (C++ iterator-interface preprocessor library, C99/C++11
conformant, built as a reusable component).

## 7. Implementation survey — Python

### 7.1 PLY `example/cpp/cpp.py` (David Beazley)

974 lines; a PLY regex lexer for pp-tokens plus a `Preprocessor` class.
Pipeline: `trigraph()` regex pass → `group_lines()` (line splicing +
per-line token lists) → directive dispatch in a `parsegen` generator →
`expand_macros` over Python lists of `LexToken`s. Design points:

- **Macro prescan at define time** (`macro_prescan`): for each macro,
  precompute patch lists — parameter positions (`('e', argnum, i)` expand,
  `('c', ...)` concat/raw, `str_patch` for `#`, `var_comma_patch` for the
  GNU comma) — so each expansion is "copy value, apply patches", not a
  re-parse. `##` is *deleted during prescan* by marking neighbors as raw
  patches — positional operator handling equivalent to Ritchie's
  `DSHARP1` trick, done once instead of per expansion.
- Recursion control: an `expanded` dict acting as a dynamic
  currently-expanding stack (`expanded[name] = True` ... `del
  expanded[name]`) — the GCC "disabled" half only, with **no per-token
  paint** and **no rescan against following source tokens** (replacements
  are spliced into the list and the cursor jumps past them:
  `tokens[i:j+tokcount] = rep; i += len(rep)`).

Measured consequences (this research, comparing to GNU cpp 13.3):

| input | PLY cpp.py | conforming |
|---|---|---|
| `#define A B`... `X((A(1))\|(A(2)));` (Spinellis) | `Y((D((1))) \| (D((2))));` ✓ | same |
| `foo(foo) (2)` with `#define foo(x) bar x` | `bar foo (2)` ✓ | same |
| `call(5)(6)` with `#define g(x) x`, `#define call g` | `g(5)(6)` ✗ | `5(6)` |
| `cat(A, B)` with `#define cat(x,y) x##y`, `#define AB 99` | `AB` ✗ | `99` |

i.e. the skip-past-replacement strategy silently drops both "rescan along
with subsequent tokens" and "pasted token is available for further
replacement". Fine for its intended use (it was never claimed conforming);
exactly the kind of bug a from-scratch implementation must design against.

### 7.2 pcpp (Niall Douglas, from Beazley's cpp.py)

`preprocessor.py` 1,473 + `evaluator.py` 736 + `parser.py` 381 lines. A
"C99 conforming-ish" rewrite that keeps the PLY lexing base but fixes the
expansion model: every token carries an **`expanded_from` list** (a
per-token hide set) *in addition to* the `expanding_from` dynamic stack,
and after splicing a replacement the cursor **re-examines it in place**
(`continue` without advancing), restoring both halves of 6.10.3.4p2. All
three failing cases above produce conforming output under pcpp (verified),
and it passes the C11 6.10.3.5 torture examples and (a slightly modified)
mcpp validation suite. Other notable engineering:

- `evaluator.py`: PLY-yacc grammar for `#if` expressions with a `Value`
  type wrapping Python ints to emulate 64-bit signed/unsigned
  two's-complement (including `-1U`, mixed-sign comparisons, `/` `%`
  truncation) — the fiddly part of `#if` no one expects.
- Partial-execution hooks (`on_unknown_macro_in_expr`,
  `OutputDirective.IgnoreAndPassThrough`...) so it can *selectively*
  preprocess — pass unknown `#if`s and missing `#include`s through
  unchanged. This "pass-through mode" is pcpp's killer feature for
  header-flattening single-file-amalgamation workflows, and is a directly
  relevant idea for `c_import` (process what we know, surface what we
  don't).
- Self-contained pure Python, no external cpp; ~2.2x faster under PyPy —
  even so, orders of magnitude slower than C implementations; fine for
  build tooling, marginal for compile-hot paths.

### 7.3 pycparser (Eli Bendersky) — the outsourcing strategy

pycparser deliberately implements **no preprocessor**: `parse_file`
shells out to `cpp` / `gcc -E`, and the project ships
`utils/fake_libc_include/` — stub headers with just enough typedefs and
`#define`s to make real code parse — to avoid dragging in true system
headers. That is the third viable architecture: *don't write a
preprocessor; require preprocessed input and control the header surface*.
Cheap, robust, but adds a toolchain dependency and loses macro knowledge
(everything is already expanded; you cannot import `#define` constants).

## 8. Testing resources

- **C11 6.10.3.5 EXAMPLEs 3-7** — free, in the standard, cover the
  worst-known expansion interactions (this research verified EXAMPLEs 3
  and 5 plus the 6.10.3.3 `hash_hash` example against gcc/pcpp). N1570 is
  freely available.
- **mcpp Validation Suite** — the de-facto conformance suite; scored
  comparisons published; pcpp's `tests/` embeds a copy.
- **GCC/Clang testsuites** (`gcc/testsuite/gcc.dg/cpp/`,
  `clang/test/Preprocessor/`) — thousands of small `.c` cases with
  expected diagnostics.
- **Differential testing** — trivially cheap here: run fragments through
  `cpp -P` (and `pcpp`) and diff. All experiments in this document live as
  one-file fragments and reproduce with a shell loop; porting them into a
  `tests/` fixture next to a future W preprocessor is the obvious move.

## 9. Implications for W `c_import`

Current state: `tests/parser_generator/c.pg` declares
`skip C_PREPROCESSOR c_preprocessor`, so generated C lexers *discard*
`#...` lines (continuation-aware); `ci_prepare_header_source` blanks
control characters; the importer then parses declarations only. That is
why only pre-expanded, self-contained headers import today.

Three architecture options, in ascending effort:

1. **Outsource (pycparser strategy).** Run the system `cpp -E` (or vendored
   stubs like `fake_libc_include`) before `c_import`. Pros: near-zero code.
   Cons: contradicts the repo's self-hosted, no-external-toolchain
   bootstrap philosophy; loses `#define` constants (often the thing users
   want imported); adds a runtime dependency on gcc being installed.
2. **Subset preprocessor in W** targeting real glibc/musl headers:
   phases 1-3 (line splicing + pp-token lexer reusing
   `libs/extras/parser_generator/lexer.w` matchers), `#include` with search
   paths + guard/`#pragma once` caching, object- and function-like
   `#define` with Prosser hide sets, `#ifdef`/`#ifndef`/`#if`/`#elif` with
   an `intmax_t` const-expr evaluator (reuse the compiler's expression
   machinery the way chibicc reuses `const_expr`), `defined`, `#undef`,
   `#error`, predefined platform macros (chibicc's `init_macros` list is
   the model), GNU `#include_next` and `,##__VA_ARGS__` (glibc needs
   both). Skippable initially: trigraphs (dead, removed in C23), `#line`,
   `_Pragma`, `#embed`, `__VA_OPT__`, digraphs.
3. **Full conforming preprocessor** — add `#`/`##` with placemarkers,
   computed includes, `__has_include`, `_Pragma`, complete diagnostics,
   and chase the mcpp suite.

Recommendation: option 2, structured so option 3 is incremental. chibicc's
`preprocess.c` proves the whole core fits in ~1,200 lines of C with the
same "no AST, token list in, token list out" shape that matches W's
single-pass philosophy; Prosser hide sets cost one pointer per token
(chibicc) or an interned small-int (Ritchie) — the latter fits W's
flat-struct style well. The W compiler's existing tokenizer is
line/character-based (`compiler/tokenizer.w`), but `c_import` already has
its own pg-token stream, which is the right substrate: preprocess the
header *as pg tokens* before `clang_parse`, keeping the production
compiler untouched (same "extras, not core" rule as ParserGenerator).

Design guardrails distilled from this research, roughly in order of how
often implementations get them wrong:

- Expand over **tokens with paint state**, never text; keep per-token
  `has_space`/`at_bol` bits from day one.
- Rescan replacements **in place, together with following tokens** (the
  `call(5)(6)` and `cat(A,B)`→`99` tests); never "splice and skip".
- Function-like names expand **only when `(` follows**, and the `(` may
  come from outer context or across newlines.
- Argument prescan: expanded for plain uses, **raw for `#`/`##` operands**
  (the `STR`/`XSTR` pair is the 5-second smoke test).
- `##` operators are **positions in the definition**, not spellings
  (`DSHARP1`/prescan-patch trick); paste = re-lex + must-be-one-token.
- `#if`: `defined` first, then expansion, then **identifiers→0**, then
  wide integer arithmetic with unsigned rules.
- Cache include guards / `#pragma once` by resolved path or headers get
  re-lexed hundreds of times.
- Adopt the C11 examples + the table in section 7.1 as fixtures before
  writing any expansion code, and diff against `cpp -P` continuously.

## 10. Sources

- K&R, *The C Programming Language*, 2nd ed.: section 4.11 (tutorial:
  4.11.1 file inclusion, 4.11.2 macro substitution, 4.11.3 conditional
  inclusion) and Appendix A.12.1-A.12.10 (reference manual), including the
  A.12.3 `cat`/`xcat` example and A.12.10 predefined names.
- ISO/IEC 9899:2011 draft N1570: 5.1.1.2 (translation phases), 6.4p3
  (pp-tokens), 6.10 (preprocessing directives), esp. 6.10.3.1-6.10.3.5.
- Dave Prosser, *X3J11/86-196* macro expansion algorithm, annotated by
  D. Spinellis: https://www.spinellis.gr/blog/20060626/cpp.algo.pdf
- D. Spinellis, "Code Finessing", Dr. Dobb's, 2006 (CScout rewrite +
  performance): https://www.spinellis.gr/pubs/jrnl/2006-DDJ-Finessing/html/Spi06j.htm
- D. Ritchie, *The Development of the C Language* (history).
- GNU: *The C Preprocessor* manual + *Cpplib Internals*
  (https://gcc.gnu.org/onlinedocs/cppinternals/).
- Repos studied: `rui314/chibicc` (`preprocess.c`), `rui314/8cc` (`cpp.c`),
  `TinyCC/tinycc` (`tccpp.c`), `drh/lcc` (`cpp/` — Ritchie's cpp),
  `llvm/llvm-project` (`clang/lib/Lex`), `dabeaz/ply`
  (`example/cpp/cpp.py`), `ned14/pcpp`, `eliben/pycparser`,
  mcpp (https://mcpp.sourceforge.net/).
- Tony Finch, "Blue paint in the C preprocessor" (2024):
  https://dotat.at/@/2024-05-21-blue-paint.html
- cppreference: translation phases, replace/conditional/embed pages (C23
  feature status).
