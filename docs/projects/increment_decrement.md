# `++` / `--` scoping and design pass

Design doc for issue #103, a placeholder that asked for its own
scoping pass before implementation ("this issue is a placeholder to
track the gap and needs its own scoping/design pass before
implementation"). No `++`/`--` tokens exist anywhere today: zero
matches under `grammar/`, and `tests/parser_generator/w.pg` has no
`INCREMENT`/`DECREMENT`-shaped literal. `a++`/`a--` currently parse
as two adjacent unary operators (see "Tokenizer collision" below),
not an error — an important compatibility constraint on any fix.

Status: design only, nothing implemented by the change that adds this
file.

## 1. Current state

### 1.1 Compound assignment (`+=` and friends)

`+=`/`-=`/... is the closest existing feature in shape — it also
reads and writes an lvalue in one expression — and lives in
`grammar/expression.w`:

- `compound_assign_op()` (`grammar/expression.w:52`) peeks the current
  token against each compound-assign spelling and returns a one-char
  marker (`'+'`, `'-'`, ..., `'l'` for `<<=`, `'r'` for `>>=`) or `0`.
- `expression()` (`grammar/expression.w:127`) parses the left side via
  `conditional_expr()` first — at that point `eax` holds the lvalue's
  **address**, not its value (see 1.2) — then checks
  `compound_assign_op()`. On a match it: pushes the address
  (`push_eax()`), promotes to load the current value, pushes that too,
  parses and promotes the right-hand expression, and calls
  `compound_assign_apply(op, left_type, right_type)`
  (`grammar/expression.w:80`), which pops the left value into `ebx` and
  emits the same ALU op the binary operator would (`alu_add`,
  `alu_sub`, ..., or the float/`var` layers first). The result sits in
  `eax`; the address saved earlier is popped into `ebx` and
  `assign_store(type)` (`grammar/expression.w:7`) writes it back at the
  lvalue's declared width (1/2/4/word bytes — narrow types truncate,
  see `test_compound_char_width` in `tests/compound_assign_test.w`).
  The whole expression **yields the new (post-store) value**, exactly
  like plain `=` (`grammar/expression.w:170`).
- The map/set index path is a structural twin:
  `hash_finish_pending_compound(op)` (`grammar/hash_builtin.w:129`)
  does the same read-apply-write sequence through `__w_map_get`/
  `__w_map_set` instead of a raw address, so `m[k] += 1` evaluates the
  key once and reuses the same `compound_assign_apply`.
- `compound_assign_apply` is pure ALU/float lowering; it never inspects
  `type_get_pointer_level`. There is no separate "pointer arithmetic"
  branch anywhere in `grammar/additive_expr.w` or
  `grammar/binary_op.w` either — `additive_op()` just falls through to
  `alu_add()`/`alu_sub()` on raw word values.

### 1.2 Lvalues in the single-pass, no-AST model

There is no AST, so "lvalue" is a convention, not a node kind:
`conditional_expr()` (and everything under it) returns an integer
*type* while leaving an **address** in `eax` for anything assignable
(locals, globals, struct fields, dereferenced pointers, array/slice
elements). `promote(type)` is the function that turns that address
into a loaded value; until it runs, `eax` is a pointer. This is what
lets `&x` short-circuit to `return 3` without calling `promote` at all
(`grammar/unary_expression.w:155`), and it is exactly what
`expression()`'s compound-assign branch exploits: parse once, keep the
raw address on the stack, `promote()` only when you need the value.
`expression_lhs_readonly` and `type_is_value()` gate whether a given
`type` is legally assignable at all (read-only buffer fields, value
types, constants/functions as pseudo-types `3`/`4`).

### 1.3 Pointer arithmetic precedent — **not scaled**

This directly answers the question #103 flags as needing confirmation.
`test_compound_pointer_arithmetic` in `tests/compound_assign_test.w`
states the contract in so many words:

```w
void test_compound_pointer_arithmetic():
	# 'p += n' advances by n bytes, exactly like 'p = p + n'
	char* s = c"hello"
	char* p = s
	p += 2
	assert_equal('l', *p)
```

W's `+`/`-`/`+=`/`-=` on a pointer operand step by **raw bytes**, not
`sizeof(T)` — unlike C. This is a deliberate, tested existing
behavior, not an oversight: `[]` indexing (`postfix_expr.w`,
`for_statement.w`) *does* scale by `type_get_size(element_type)` via
`imul_eax_int32(element_size)`, but plain pointer addition never has.
So the issue's framing ("`p++` on a `T*` should step by `sizeof(T)`")
is the *C* convention, and is **inconsistent with what `+=` already
does here**. Any `++`/`--` design has to pick a side explicitly — see
Open Questions.

## 2. Design options for v1

Three shapes, in increasing cost:

### (a) Statement-position-only, both forms, no value — recommended

`x++`, `x--`, `++x`, `--x` as **statements**, each pure sugar for
`x += 1` / `x -= 1` through the *existing* `compound_assign_apply`
path, with the implicit right-hand side loaded as `mov_eax_int(1)`
instead of parsed from a token stream. No new value semantics: the
construct cannot appear inside a larger expression at all, so there is
no pre/post *value* to define. Reuses `compound_assign_apply`
verbatim — zero new codegen, only new parsing plus a statement-level
dispatch hook (§3).

This also matches how W would actually use `++`/`--`: the language
has no C-style three-clause `for (init; cond; incr)` loop (see
`grammar/for_statement.w`) — only `for x in range(...)` and container
iteration — so the classic C motivating case (the loop-header
increment clause) doesn't exist here. The realistic use is a bare
counter bump in a loop body, which is statement position by
construction. A `grep` over the tracked tree today finds the `x += 1`
/ `x -= 1` idiom already in active (if modest) use, confirming the
statement-only shape covers the real pattern.

### (b) Full pre/post expression forms

`++x`/`x++` (and `--`) as expressions usable anywhere, with real C
pre/post value semantics. Splits into two asymmetric halves:

- **Prefix `++x`** is nearly free: it can live in
  `grammar/unary_expression.w` right next to `accept(c"-")`/
  `accept(c"+")` (`grammar/unary_expression.w:192`,`:207`). Because a
  nested `unary_expression()` call leaves an *address* in `eax` for an
  assignable operand (§1.2, same trick `&` uses), the prefix handler
  is almost a direct copy of `expression()`'s compound-assign block:
  push the address, promote to load, apply `compound_assign_apply('+',
  ...)` against an implicit `1`, store back, return the new value. New
  value is already what compound assignment naturally produces, so
  this is the same cost as (a) plus the wiring to make it a composable
  expression (interacts with `cast_context`/`condition_context`-style
  parser state, and needs its own "not an lvalue" diagnostic when the
  operand isn't assignable — the compound-assign checks are reused,
  but the call site changes).
- **Postfix `x++`** is the genuinely harder half, and the reason this
  issue calls out "different codegen ordering" explicitly. It must
  return the *old* value, so the emission needs to **duplicate the
  loaded value before mutating**: load, push a spare copy, apply the
  operator and store as usual, then pop the spare copy back into `eax`
  to discard the "new value in eax" that compound assignment normally
  leaves. That's a real (if small) new code shape, not a copy of
  existing code. It also has to hook into the compiler's postfix chain
  (`postfix_expr()`, `grammar/postfix_expr.w:474`; the equivalent
  `postfix_tail` rule in the PG model sits at
  `tests/parser_generator/w.pg:223`), which today has no concept of
  "is the thing to my left still an lvalue" — a call result (`f()++`),
  a struct-value temporary, or a chained comparison must all be
  rejected, and nothing currently tracks that distinction at that
  point in the chain.
  `docs/projects/operator_overloading.md`'s staging section (item 4,
  "blocked on #103") independently flags the same postfix-ambiguity
  cost: "a spelling with any binary meaning can never be postfix (after
  a left operand the parse is ambiguous, and the tokenizer tracks no
  whitespace adjacency to break ties)".
- Extending compound assignment's other lvalue shapes (`m[k]++`,
  `arr[i]++`, `p.field++`) to pre/post value semantics multiplies the
  same postfix save/restore logic across
  `hash_finish_pending_compound` and the plain-address path — doable,
  but it's added surface, not shared surface.

### (c) Prefix-only expressions

Just the prefix half of (b): `++x`/`--x` as real expressions (new
value, usable anywhere), no postfix form at all. Materially cheaper
than (b) — it's exactly the "nearly free" prefix bullet above with
none of the postfix save/restore or postfix-chain lvalue-tracking
work — but still a bigger diff than (a): it needs the
`unary_expression()` hook, an "operand is not assignable" diagnostic
independent of the statement-only restriction, and answers questions
(b) doesn't have to, like "does `!++x` parse, does `cast(int, ++x)`
make sense, does it compose with `&`" (`&++x` should presumably be
rejected — taking the address of an expression result — but that
check has to be added deliberately, it isn't free).

### Recommendation

**(a): statement-position-only, both forms, sugar for `+=1`/`-=1`,
no value.** It reuses `compound_assign_apply` with literally zero new
codegen, sidesteps the pre/post value question entirely (per the
issue's own framing: "needs a design decision on scope for v1"), and
matches the repo's established minimal-v1 bias — `defer.md`,
`operator_overloading.md` and `template_strings.md` all deliberately
ship the smallest useful surface first and stage the rest. It also
matches actual W idiom: no C-style for-loop increment clause exists to
motivate the expression form, and the counter-bump-in-a-loop-body
pattern this is meant to replace is already statement position today.
(b)/(c) are real follow-ups once `arr[i++]`-style code shows real
demand, not before.

## 3. Grammar surface

### 3.1 Tokenizer: the `+=`/`-=` merge point, and the collision to avoid

`compiler/tokenizer.w`'s `get_token()` builds multi-character operator
tokens with hand-written character-class loops, not a generic
longest-match table. Two-character operators drawn from
`< = > | & !` (`<=`, `>=`, `==`, `!=`, `&&`, `||`, `<<`, `>>`, and
their `=`-suffixed compound forms `<<=`/`>>=`) fall out "for free" from
one greedy `while` loop at `compiler/tokenizer.w:263-266`, because
every character in that run belongs to the same class. `+`, `-`, `*`,
`%`, `^` are **not** in that class (each is a legal single-char
operator with no doubled form today), so they get a dedicated,
narrower block right after it:

```w
# compiler/tokenizer.w:272-278
if (token_i == 0):
	if ((nextc == '+') | (nextc == '-') | (nextc == '*') |
			(nextc == '%') | (nextc == '^')):
		takechar()
		if (nextc == '='):
			takechar()
```

This is the merge point that needs to grow a second case. The natural
extension, scoped to `+`/`-` only (no `**`/`%%`/`^^` exist or are in
scope here):

```w
if (token_i == 0):
	if ((nextc == '+') | (nextc == '-') | (nextc == '*') |
			(nextc == '%') | (nextc == '^')):
		takechar()
		if (nextc == '='):
			takechar()
		else if ((token[0] == '+') & (nextc == '+')):
			takechar()
		else if ((token[0] == '-') & (nextc == '-')):
			takechar()
```

`peek()`/`accept()` (`compiler/tokenizer.w:349`,`:357`) do exact
string matches against the fully-lexed `token` buffer, so once this
merge exists, `peek(c"++")`/`accept(c"++")` work exactly like the
existing `peek(c"+=")` calls — no other tokenizer change is needed.

**Tokenizer collision** (the thing #103 explicitly calls out to check
for): unary `+`/`-` already exist
(`grammar/unary_expression.w:192,207`), so **`++x`/`--x` are legal
programs today** — they parse as double unary plus/minus
(`+(+x)`/`-(-x)`), which is silly but not an error. The tokenizer
change above re-lexes that same source text as one token, which is a
real, if obscure, behavior change for any existing program spelled
that way with no space. A repo-wide grep found no tracked `.w` file
doing this (`grep -rn -- '++' `/`'--'` over the tree turns up only
comment em-dashes, a C-import lexer's own `"++"`/`"--"` literals for
parsing *C* source, and PEM/base64 fixture noise — nothing in W
source), so it's safe here, but it's worth flagging explicitly as a
compatibility note in the PR, and possibly a `w check` migration
warning if the maintainer wants one. `x = +5` / `x = -5` (single
unary, most common case) are completely unaffected — the collision
only exists for the doubled-prefix spelling.

`x+ +y` (binary plus then unary plus) is unaffected as long as there's
a space; without one (`x++y`) it is genuinely ambiguous between
"increment-then-something" and "binary + then unary +", and the fix
above resolves it in favor of increment/decrement — consistent with
every C-family language's own resolution of the same ambiguity
(maximal munch).

### 3.2 Which `grammar/*.w` file

Per the design in §2, this is a **statement**, not a new
expression-ladder rung, so it does not belong in
`grammar/additive_expr.w` or `grammar/unary_expression.w`. Following
the `grammar/defer.w` precedent (a small, self-contained file for one
statement form, imported from `grammar.w` near `grammar.expression`/
`grammar.statement`), add `grammar/increment.w` with an
`increment_statement()` entry point, wired into `statement()`'s
dispatch chain (`grammar/statement.w:139` — same spot `defer`/`pass`/
`debugger` live, before the generic `else: expression()` fallback at
`grammar/statement.w:325`). Concretely:

- **Prefix**: `peek(c"++")`/`peek(c"--")` at the top of a statement is
  unambiguous today (no existing statement can start with those
  tokens), so it can be its own early `else if` branch, symmetric with
  the `defer`/`pass` branches already there.
- **Postfix**: `x++` can't be distinguished from a bare expression
  statement until after parsing `x`, exactly like compound assignment
  can't be distinguished from `=` until after parsing the left side
  (§1.1). The cleanest option is a small, statement-scoped flag (same
  shape as the existing `condition_context`/`cast_context` globals in
  `grammar/promote.w`) set once by `statement()`'s fallback branch and
  consumed immediately inside `expression()`/`conditional_expr()`'s
  return path, so `++`/`--` are only ever recognized as the *first*
  thing checked at true statement position — never inside a nested
  `expression()` call parsing a sub-expression (a call argument, an
  `if` condition, the right side of `=`). This keeps the "statement
  only" restriction real rather than advisory.

### 3.3 `tests/parser_generator/w.pg`

`parser_generator_w_test` parses every tracked `.w` file and fails on
any token/construct it doesn't recognize, so the new tokens need a
`literal` declaration regardless of scope (`tests/increment_test.w`
below would otherwise fail that gate). Two additions:

1. Two new `literal` lines, following this file's existing
   longest-first grouping convention (compound/multi-char forms listed
   before their single-char prefixes — `SHL_ASSIGN "<<="` before
   `SHIFT_LEFT "<<"`, etc.):

   ```
   literal PLUS_PLUS "++"
   literal MINUS_MINUS "--"
   ```

   Naming matches `tests/parser_generator/c.pg:53-54`, which already
   declares exactly these two literals (for lexing **C** source
   through `libs/extras/c_import`, a separate grammar/lexer from
   `w.pg` — not evidence about W's own grammar, but confirms the
   naming convention and that a longest-match PG lexer handles this
   split cleanly with no ordering tricks needed, mirrored again in
   `libs/extras/c_preprocessor/pp_lexer.w`'s own `"++"`/`"--"`
   matching for the same reason).

2. A grammar rule matching the *actual* v1 shape (statement only, not
   a `unary_op`/`postfix_tail` addition to the expression ladder,
   which would make PG accept `y = x++` even though the compiler
   rejects it). Add alternatives to `base_statement`
   (`tests/parser_generator/w.pg:184`), mirroring how `defer_stmt`
   (`:196`) and `infer_decl` (`:204`) are already their own top-level
   alternatives rather than expression-ladder productions:

   ```
   rule base_statement = ... | incr_stmt | decr_stmt
   rule incr_stmt = postfix_expr PLUS_PLUS | PLUS_PLUS unary_expr
   rule decr_stmt = postfix_expr MINUS_MINUS | MINUS_MINUS unary_expr
   ```

   (PG is intentionally "syntax-only and permissive" per its own
   comments on the `case`/`default`/`operator` contextual keywords, so
   it's fine — and consistent with existing practice — for this rule
   to accept a *slightly* wider postfix operand shape than the
   compiler's real lvalue check allows; it must not, however, leak
   `++`/`--` into arbitrary expression position, which the
   `unary_op`/`postfix_tail` route would.)

## 4. Codegen sketch

Because of §2's recommendation, this is almost entirely reuse:
`increment_statement()` calls the same `compound_assign_apply('+', ...)`
/ `compound_assign_apply('-', ...)` that `+=`/`-=` already call, with
the right-hand operand synthesized as `mov_eax_int(1)` instead of
parsed. `assign_store`, `promote`, `push_eax`/`pop_ebx`, and
`compound_assign_apply` itself are all backend-dispatched *internally*
by `target_isa` (`code_generator/x86.w:638`'s `alu_add()` is
representative: it branches to `wasm_ax_op_bx(0x6a)` for `target_isa
== 2`, `a64(op(0x8b, 0x010000))` for `target_isa == 1`, and the x86/x64
REX-prefixed encoding otherwise, all in one function) — so there is
**no per-backend work at the grammar layer** for x86, x64, or arm64;
the existing dispatch already covers all three. wasm needs a check
that `wasm_ax_op_bx`-style helpers cover the narrow-width truncating
store path the same way the x86 path does (`assign_store`'s 1/2/4-byte
branches) — likely already true since compound assignment on `char`/
`int16` locals is tested today (`test_compound_char_width`), but worth
an explicit wasm-target assertion in the new test (`./wbuild
increment_test x64` / arm64 / wasm variants, mirroring
`compound_assign_test`'s `# wbuild: x64` directive).

If (b)/(c) are picked up later, the *only* new codegen (not parsing)
is postfix's old-value save/restore described in §2(b) — everything
else, including the pointer/no-scaling behavior, is unchanged reuse.

## 5. Test plan

New `tests/increment_test.w` (`# wbuild: x64`, following
`tests/compound_assign_test.w`'s shape and `lib/testing.w` asserts):

- **Basic**: `int a = 5; a++; assert_equal(6, a)`, `a--` back to 5,
  `++a`/`--a` prefix forms, global lvalue (`g_total++`, mirroring
  `test_compound_even_constants`'s local/global split), struct field
  (`p.x++`), array element (`arr[i]++`), pointer dereference
  (`(*p)++`) — all via the same statement-level lvalue path
  `expression()`'s compound-assign branch already exercises.
- **Pointer stepping** (the issue's explicit ask): assert `p++`
  advances by **1 byte**, not `sizeof(T)`, matching
  `test_compound_pointer_arithmetic`'s "'p += n' advances by n bytes"
  contract — e.g. `int* p = &arr[0]; p++; assert(p == cast(int*,
  cast(char*, &arr[0]) + 1))` or the equivalent byte-address
  comparison used in the existing pointer-arithmetic test. If the
  maintainer instead picks the C-scaled convention for `++`/`--` only
  (see Open Questions), this is the test that flips and must document
  the resulting `+=` vs `++` inconsistency explicitly.
- **Narrow width / truncation**: `char c = 255; c++; assert_equal(0,
  c)`, mirroring `test_compound_char_width`'s truncating-store
  assertion.
- **Statement-only enforcement (negative)**: a compile-error fixture
  (`tests/increment_expression_position_error_fixture.w`, `#
  expect_fail` / `# expect_stderr:` per the fixture convention
  `warning_test`/`type_system_*_test` use) asserting `y = x++` and
  `f(x++)` are rejected. Per §3.1's tokenizer trace, without any
  special-cased diagnostic this surfaces through the ordinary
  statement terminator check (`expect_or_newline(c";")` in
  `grammar/statement.w:327`) as something like `';' expected, found
  '++'` — a generic but honest "not valid here" message, consistent
  with how other statement-only constructs fail today. Whether that's
  good enough or deserves a dedicated "'++'/'--' are statement-only in
  this version of W" diagnostic is an open call for the implementing
  PR; either way the fixture's `expect_stderr:` pins whichever text is
  chosen (`warning_test`-style message freezing applies here too).
- **Non-lvalue rejection**: `5++`, `(a + b)++` style fixtures reusing
  the existing `assignment target is not assignable` message
  (`grammar/expression.w:146`) if the implementation routes through
  the same check `compound_assign_apply`'s callers already use.
- **Parser generator**: no bespoke test needed beyond adding
  `tests/increment_test.w` itself to the tracked tree —
  `parser_generator_w_test` picks up every tracked `.w` file
  automatically and will fail if `w.pg` wasn't updated to match (§3.3).

## 6. Seed constraint

`compiler/tokenizer.w` and every file under `grammar/` are in the
seed-compiled closure (`w.w`'s transitive imports, per the top-level
`CLAUDE.md`), so the *implementation* files for this feature must stay
within syntax the currently-pinned seed already understands — same
rule `defer.md` and `template_strings.md` both call out. The `++`/`--`
**syntax itself** can only be exercised in `tests/` (and other leaf
consumers) once `bin/wv2` exists and understands it; it cannot be used
inside `grammar/increment.w` or anywhere else in the seed graph to
implement itself. Landing follows the two-step pattern
`CLAUDE.md`/`docs/release.md` describe: merge the feature PR (still
building under the old pinned seed), tag a release at that commit,
then a follow-up PR bumps `SEEDS`. Per the wave plan
(`docs/projects/sonnet_wave_plan_2026_07.md` §6), implementation is a
later, HIGH-care, seed-graph-touching slot that must merge alone with
`./wbuild verify` (+ `verify_x64`) green — this doc only unblocks
that slot.

## 7. Open questions for the maintainer

1. **Pointer step size**: keep `++`/`--` consistent with `+=`'s
   existing raw-byte pointer stepping (§1.3), or special-case `++`/`--`
   to scale by `sizeof(T)` (matching C, and matching the assumption in
   the original issue text) at the cost of `p++` and `p += 1` meaning
   different things on the same pointer? Recommend staying consistent
   with `+=` (no scaling) for v1 — introducing the *only* scaled
   pointer-arithmetic operator in the language, on the newest/least
   familiar syntax, seems like a bigger footgun than the inconsistency
   with C.
2. **Diagnostic for expression-position use**: is the generic `';'
   expected, found '++'` fallback (§5) acceptable for v1, or does
   attempting `y = x++` deserve a dedicated, friendlier error? Affects
   whether `increment_statement()` needs its own lookahead inside
   `expression()`'s recursive calls purely to produce a better message
   (more surface than the statement-only design otherwise needs).
3. **`operator++` staging**: `docs/projects/operator_overloading.md`
   (staging item 4) is already blocked on this issue for postfix
   struct-value support. Recommendation (a) here — statement-only,
   scalar/pointer lvalues — does **not** unblock that staging item
   (no struct-value operand path, no expression-position value); worth
   the maintainer confirming that's acceptable sequencing (operator
   overloading's postfix stage waits for this doc's own (b)/(c)
   follow-up, not v1).
