# Custom Operators

Design doc for the "minting new operators" half of issue #104: letting
user code introduce new binary, prefix and postfix operator spellings
that lower to ordinary function calls. The other half of #104 —
overloading the *existing* built-in operators (`+`, `==`, ...) for
struct types — is a sibling feature that shares this doc's lowering
machinery and is covered in "Stage 0" below; its full design (which
operators, mixed-type rules) still needs its own pass.

Status: design only, nothing implemented.

## Proposed surface

```w
vec3 vec3_add(vec3 a, vec3 b):
	return vec3(a.x + b.x, a.y + b.y, a.z + b.z)

float vec3_dot(vec3 a, vec3 b):
	return a.x * b.x + a.y * b.y + a.z * b.z

vec3 vec3_neg(vec3 a):
	return vec3(0.0 - a.x, 0.0 - a.y, 0.0 - a.z)

# operator declarations bind a spelling to an existing function
operator @+ = vec3_add
operator @dot = vec3_dot
operator @- = vec3_neg prefix

vec3 c = a @+ b
float d = a @dot b
vec3 n = @- c

# backtick infix needs no declaration at all: any 2-argument
# function can be called infix
vec3 e = a `vec3_add` b
```

Every custom operator starts with `@`. After the `@`, the spelling is
a maximal run of either identifier characters (`@dot`, `@cross`) or
symbolic characters (`@+`, `@><`) — one class per spelling, not mixed.
Spellings may not end in `=` (reserved so custom compound assignment
`a @+= b` stays possible later).

An operator use is sugar for a call:

```w
a @+ b        # vec3_add(a, b)
a @dot b      # vec3_dot(a, b)
@- c          # vec3_neg(c)
n @!          # fact(n), given: operator @! = fact postfix
```

## The three sub-problems

The compiler is single-pass with no AST: operators are recognized by
string-matching the current token inside a fixed chain of grammar
functions, and by the time an operator token is seen the left
operand's code is already emitted and its type known
(`binary1()` in `grammar/binary_op.w`). Custom operators decompose
into lexing the spelling, slotting it into that fixed precedence
ladder, and lowering to a call. The third is largely solved already —
struct method sugar does exactly this dance.

## 1. Lexing

`<+>` lexes as three tokens today: `get_token()` only merges runs of
`< = > | & !` plus the compound-assignment forms
(`compiler/tokenizer.w`). Two designs were considered and one
rejected:

**Rejected: registry-driven lexing.** Letting `operator` declarations
register arbitrary spellings and having the tokenizer maximal-munch
against the registry makes token boundaries depend on which
declarations have been seen — the same file lexes differently
depending on import order (the classic Prolog `op/3` / Haskell fixity
disease). It also breaks a hard repo gate: `parser_generator_w_test`
parses every tracked `.w` file against the *static* grammar
`tests/parser_generator/w.pg`, and a static grammar cannot express
registry-dependent token boundaries.

**Chosen: sigil-led spellings.** Requiring every custom operator to
start with `@` gives a deterministic, declaration-order-independent
lexing rule: on `@`, munch the sigil plus a maximal run of one
character class —

- identifier characters `[A-Za-z0-9_]` (named form: `@dot`), or
- symbolic characters `+ - * / % < > = ! & | ^ ~ .` (symbolic form:
  `@+`, `@><`).

One new branch in `get_token()`, no change to how any existing source
lexes. The PG lexer gets a single `CUSTOM_OP` token class with the
same rule; because the PG is syntax-only and permissive, it never
needs the registry.

`@` is currently source-illegal, which is exactly why
`grammar/generic.w` uses it for internal placeholder *type names*
("a type name mentioning `@` provably depends on a placeholder").
Custom operator tokens live in expression position and never enter
type names, so the invariant survives — but it narrows from "`@`
cannot appear in a source file" to "`@` cannot appear in a type
name", and the comment in `generic.w` must be updated in the same
change. `$` stays reserved for symbol mangling as today.

**Backtick infix** is a separate, even cheaper facility: backtick is
unused, already lexes as a single-character token, and
``a `f` b`` → `f(a, b)` needs no declaration, no registry and no
tokenizer change. It only covers binary and only named functions, but
it is the best cost/benefit first step.

## 2. Precedence and fixity

The ladder is a fixed chain:

```
expression → conditional → logical_or → logical_and → bitwise_or
→ bitwise_xor → bitwise_and → equality → relational → shift
→ additive → multiplicative → unary → postfix
```

**Binary: one new level, left-associative, between `relational` and
`shift`.** All custom binary operators (and backtick infix) share it.
`relational_expr` calls `custom_infix_expr()`, which loops on
registered binary spellings and calls `shift_expr()` for operands.
Consequences: `a @dot b > c` groups the operator
(`(a @dot b) > c`), and all arithmetic binds tighter
(`a @+ b << 2` is `a @+ (b << 2)`), which is what vector/matrix DSLs
want (`s * v @+ w` scales first).

A full precedence-climbing rewrite (numeric precedences, per-operator
associativity) was rejected for v1: it is still single-pass-friendly,
but the ladder functions are full of per-operator special cases that
do not table-ize (the float and `var` lowering layers, the bool-`|`
warning, `in` at the relational level, the `*`-on-a-fresh-line rule
in `multiplicative_expr.w`), and this is the most battle-tested code
in `grammar/`. The cheap future extension is *declared level*: the
registry stores which existing ladder level a spelling joins, and
each ladder loop grows one registry check, gated on
`token[0] == '@'` so the cost per ordinary token is one character
compare.

**Prefix:** one branch in `unary_expression()` before the final
`postfix_expr()` fallback — parse the operand with a recursive
`unary_expression()` call (so prefix operators stack and bind tighter
than any binary operator, like built-in `-`), then emit a
one-argument call. A spelling may be both prefix and binary:
grammatical position disambiguates, exactly as it does for `-`.

**Postfix:** one branch in `postfix_expr`'s suffix loop alongside
`(`, `[` and `.` — the operand's value is in eax, emit a one-argument
call. A spelling declared postfix may not also be binary (or prefix):
after a left operand `a @! - b` is genuinely ambiguous, and the
tokenizer tracks no whitespace adjacency (only `token_newline`) to
break the tie. This is a declaration-time error, not a parse-time
heuristic.

Statement/newline interaction needs no special rule: expression
statements end at a newline, so a custom operator on a fresh line
never continues the previous statement — the same behavior as every
built-in binary operator.

## 3. Lowering

An operator use lowers to a call of the bound function, and the hard
part — the first argument was already evaluated before we knew a call
was coming — is precisely what struct method sugar solved. The method
path in `grammar/postfix_expr.w` (the `.method()` branch) is the
template:

1. promote the left operand; push it to save it,
2. `sym_get_value(fn)` — callee address, pushed first per the
   callee-first call layout,
3. if the function returns a struct by value, park the return buffer
   on the stack (`has_return_buffer`), exactly like chained methods,
4. reload the saved left operand esp-relative,
   `check_call_argument` / `coerce` it, push it as argument 0,
5. binary only: parse the right operand at `shift_expr()` level,
   promote, check/coerce, push as argument 1,
6. emit the call tail (`mov_eax_esp_plus(...)`, `call_eax`,
   `be_pop`, return-type handling).

`parse_call_suffix` cannot be reused directly — it parses its
arguments *from source* (`arg, arg, ...)`), and an operator has no
argument list — so the "finish a call whose arguments are already
pushed" tail gets extracted into a helper shared by both paths.
Riding this machinery means argument-count/type warnings, coercions
and struct-by-value returns (`vec3 @+ vec3 → vec3`) all come for
free, on every target, including chaining the result into further
postfix suffixes.

The bound function must take exactly 2 arguments (binary) or 1
(prefix/postfix); w-variadic and generator functions are rejected at
declaration. Generic functions are out of scope for v1 (an operator
binds one concrete instantiation, e.g.
`operator @+ = vadd$vec3` is not supported — bind a wrapper
instead); composing with call-site inference is an open question
below.

## Declarations and the registry

```
operator SPELLING = FUNCTION_NAME [prefix | postfix]
```

parsed in `program()` (`grammar/program.w`) before the general
declaration path, and mirrored in the REPL's entry dispatcher.
Binding to an *existing named function* (rather than an inline
definition form like `vec3 operator @+ (vec3 a, vec3 b):`) keeps v1
small: no mangling scheme, no changes to `function_definition`, the
function stays independently callable and testable, and forward
references follow the existing prototype rules. The inline form can
be added later as pure sugar. Fixity defaults to binary for
2-argument functions and prefix for 1-argument ones; `postfix` opts
in explicitly.

The registry is a small table mapping spelling → fixity + symbol.
Single-pass compilation means declare-before-use, the same rule as
everything else in W; `import` order carries registrations across
files. Everything built on the same grammar — `w check`, `symbols`,
`deps`, the REPL, wdbg — inherits the feature with no extra work.

Diagnostics (new messages, to be frozen by fixtures):

- `unknown operator '@...'` — use of an unregistered spelling,
- `operator function '...' not found` — binding to a missing symbol,
- `operator '...' expects a 1- or 2-argument function`,
- `postfix operator '...' cannot also be binary`,
- `operator spelling may not end in '='`.

## Gates checklist

- **Seed constraint**: the implementation (tokenizer, `grammar/`,
  registry) is inside the seed's import graph, so it may not *use*
  the new syntax — only `tests/` and other leaf consumers can, once
  `bin/wv2` exists. Seed promotion follows `docs/release.md` as
  usual before any library code can use it.
- **`./wbuild verify`**, plus `verify_x64` / `verify_arm64` — the
  lowering rides the call machinery on every target.
- **`tests/parser_generator/w.pg`**: add the `CUSTOM_OP` token class
  and alternatives in `binary_op`, `unary_op` and `postfix_tail`,
  plus `BACKTICK IDENT BACKTICK` in `binary_tail`.
- **Fixtures**: each new diagnostic gets a compile-only fixture with
  `# expect_stderr:` directives; no existing message text changes.
- **Tests**: `tests/custom_operator_test.w` with a `# wbuild: x64`
  twin (struct-valued results, chaining, prefix stacking, precedence
  vs `*` and `==`), then `./wbuild manifest` — never hand-edit
  `build.json`.

## Staging

- **Stage 0 — overload existing operators for struct types** (the
  other half of #104): no lexer work, precedence comes free, and it
  forces building the shared piece — the operator→call lowering
  helper. `additive_op` and friends check "is either operand a
  struct with a registered `+`" before falling through to the
  ALU/float layers. Needs its own short design pass (which operators,
  lookup convention, mixed-type rules).
- **Stage 1 — backtick infix**: ``a `f` b``, one grammar branch, no
  declarations.
- **Stage 2 — `@`-sigil custom operators**: binary at the single
  custom level, plus prefix; declaration + registry as above.
- **Stage 3 — only on demonstrated demand**: postfix operators,
  declared precedence levels, the inline definition form, custom
  compound assignment (`@+=`).

## Open questions

- Should backtick infix (Stage 1) allow struct methods
  (``a `Type_method` b``) or only free functions? (Lean: free
  functions only; methods already have sugar.)
- Interaction with generics: should `operator @+ = vadd` with a
  generic `vadd[T]` defer resolution to each use site's operand
  types? Deferred to the generics doc if wanted.
- Whether Stage 0's struct-operator overloading should use a naming
  convention (`vec3_op_add`, found like method symbols) or explicit
  `operator + = vec3_add for vec3` declarations. Convention matches
  methods; explicit matches this doc. To be decided in Stage 0's
  design pass.

## Related

- #104 — the tracking issue for both halves.
- #101/#102/#103 — missing *built-in* operators (`^`, `~`,
  `++`/`--`); grammar-level completeness, unrelated machinery.
- `docs/projects/struct_methods.md` — the dispatch/lowering pattern
  this design parallels.
- `docs/projects/graphics.md` — the motivating consumer
  (`vec3_add(a, b)` today, `a @+ b` / `a + b` eventually).
- `docs/projects/generics.md` — instantiation machinery a future
  generic-operator story would compose with.
