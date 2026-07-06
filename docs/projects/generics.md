# Generics with Explicit Instantiation and Call-Site Inference

True generics/templates for W: user-defined generic functions and structs,
monomorphized per instantiation. Instantiation is explicit
(`name[type-args]`), or — for generic functions defined before the call
site — inferred from the call's argument types (`max(3, 5)`).

```w
# generic function: type parameters in [] after the name
T max[T](T a, T b):
	if (a > b):
		return a
	return b

# generic struct
struct pair[T]:
	T first
	T second

int m = max[int](3, 5)     # explicit instantiation at the call site
int n = max(4, 6)          # inferred: T = int (same max$int instantiation)
pair[int] p                # instantiated struct type
p.first = 1
pair[int]* pp = &p
```

Implementation lives in `grammar/generic.w`, with hooks in
`grammar/program.w` (definition capture), `grammar/struct_declaration.w`
(generic struct capture), `grammar/type_name.w` (type positions),
`grammar/primary_expr.w` / `grammar/postfix_expr.w` (call sites),
`compiler/tokenizer.w` (byte offsets) and `compiler/compiler.w` /
`repl.w` / `debugger/wdbg.w` (the end-of-compilation drain).

## Design

The compiler is single-pass with no AST: grammar rules emit machine code
while parsing a byte stream. Generics therefore work by **span capture and
re-parse**, mirroring what `compile_save()` already does for imports:

1. **Byte offsets.** The tokenizer tracks `byte_offset` (bytes consumed in
   the current file) and `token_start_offset` (offset of the current
   token's first byte, corrected for the one-character `nextc` lookahead).
   Both are saved/restored across nested imports like `line_number` is.

2. **Definition capture, no codegen.** When a top-level declaration turns
   out to be generic (`identifier [` after the return type, scanned by
   `generic_declaration_scan()`; `struct name[` in
   `struct_declaration()`), the definition is *not* compiled. Its name,
   kind, file path, span start offset, line/column and type-parameter
   names go into a registry, and the definition's tokens are skipped
   (rest of the header line, then every line indented past tab level 0 —
   strings and comments are already opaque to `get_token()`).

3. **Instantiation = nested re-parse.** An instantiation re-opens the
   recorded file on a fresh fd, seeks to the span start, and runs the
   ordinary declaration parser with a **substitution table** active:
   a block of (parameter name → type index) bindings consulted by
   `type_name()` before the normal type lookup. The outer tokenizer state
   (fd, lookahead, current token, positions) is saved and restored
   verbatim, so the outer parse resumes as if nothing happened.

4. **Structs instantiate eagerly.** Struct layout is needed immediately
   (locals, fields, pointers), and struct parsing only fills the type
   table — no code is emitted — so the nested re-parse is safe even in the
   middle of compiling a function body.

5. **Functions instantiate at a top-level boundary.** Function bodies emit
   code, which must not interleave with the function currently being
   compiled. A call site `max[int](a, b)`:
   - parses the type arguments, builds the mangled name, and interns an
     instantiation record (deduplicated by mangled name);
   - parses the *signature* via a nested re-parse of just the definition
     header (safe: no code emitted), so the call gets full arity/type
     checks and the correct return type — including struct returns;
   - emits a `mov $imm` slot linked into the instantiation's backpatch
     chain (the `json_codec_finish_import()` pattern).
   `generic_finish_instantiations()` drains the queue at the end of
   compilation (`link_impl()` in `compiler/compiler.w`, before and after
   the on-demand runtime imports), compiling each pending body through the
   ordinary `function_definition()` path under the mangled name and
   patching the chain. Bodies may request further instantiations (a
   generic calling a generic); they land at the end of the queue and the
   drain loops until a fixpoint.

6. **Forward calls.** A call to a generic whose definition appears later
   in the file (or in a later file) sees a name that is not registered
   yet. If an identifier followed by `[` matches no symbol, type, or
   import alias, the call is recorded speculatively: type arguments plus a
   private backpatch chain, resolved at the drain after all definitions
   have been seen. Forward calls skip argument checks at the call site (no
   signature exists yet) and reject instantiations that return structs by
   value (the call site pushed no return buffer); defining the generic
   before the call lifts both restrictions.

## Type-argument inference

When a registered generic *function* name is followed directly by `(`
instead of `[`, the type arguments are inferred from the call's argument
types (`generic_call_infer_expr()` in `grammar/generic.w`):

1. **Parameter shapes.** The definition's header is re-parsed once per
   definition (the same header-only nested re-parse the signature uses)
   with every type parameter bound to a distinct word-sized *placeholder*
   type instead of a concrete one. Placeholder names start with `@`,
   which cannot appear in a source identifier or in any
   compiler-generated type name, so a parsed parameter type provably
   depends on a placeholder iff its name mentions `@`. Each parameter
   classifies as a **type-parameter reference** with a pointer depth
   (`T` = depth 0, `T**` = depth 2 — pointer records store the base
   type's name, so the chain reduces by name), a **concrete** type, or
   **opaque** (mentions a placeholder in a position v1 cannot invert:
   `list[T]`, `T[]`, `pair[T]*`, `const T*`). The shapes are cached per
   definition.
2. **Binding.** Arguments are parsed (and pushed) left to right. A
   type-parameter shape strips its pointer depth from the argument's
   promoted type (a non-pointer argument for a `T*` parameter is a
   compile error) and binds the parameter; the first binding wins and a
   conflicting later binding is a compile error naming the parameter and
   both types. Untyped constants (integer/char literals, `&` addresses)
   bind `int` when the parameter is still unbound, and coerce to the
   existing binding otherwise (`max(1.5, 2)` works like
   `max[float32](1.5, 2)`; `max(2, 1.5)` binds `int` first and then
   errors). Value pseudo-types map back to their storage types
   (`string value` binds `string`, a slice value binds `T[]` itself —
   binding never digs into container element types). Concrete shapes
   constrain nothing and get the ordinary argument check and coercion;
   opaque shapes are checked against the instantiated signature
   afterwards. Every type parameter must end up bound, else a compile
   error suggests the explicit syntax.
3. **Call emission.** After binding, the call proceeds exactly like an
   explicit instantiation — mangle, intern (so `max(3, 5)` and
   `max[int](3, 5)` share one `max$int`), signature parse, argument-count
   check, and the same mov-imm backpatch chain, drained by
   `generic_finish_instantiations()`. Because the arguments were parsed
   before the callee was known, the callee's mov-imm slot is emitted
   after them (no callee word on the stack) and no struct return buffer
   can be pushed below the arguments: inferred calls whose instantiation
   returns a struct by value are rejected with a hint to use explicit
   type arguments, the same restriction forward calls have.

Inference limits (v1): the definition must appear before the call site —
an unregistered name followed by `(` is an ordinary unknown symbol, so
forward calls keep requiring explicit `name[T](...)` (mirroring the
forward-call restriction above); inference covers generic *functions*
only (generic struct constructors keep explicit arguments); parameters
whose shape only mentions a type parameter inside another type
(`pair[T]*`, `list[T]`, `T[]`) do not bind it, so a parameter used only
in such positions (or only in the return type) needs explicit arguments;
generic definitions cannot have defaults or variadics (already rejected),
so those interactions do not arise.

## Name mangling

`name$arg1$arg2`, where each argument is the canonical type-table name
with one `*` appended per pointer level: `max[int]` → `max$int`,
`pick[char*, int]` → `pick$char*$int`, `pair[int]` → `pair$int`,
`same[pair[int]]` → `same$pair$int`. `$` is not a legal identifier
character in W source, so mangled names cannot collide with user symbols.
Instantiations are deduplicated by mangled name: the same instantiation
in two files compiles once.

## What works (covered by `tests/generics_test.w`)

- Generic functions with any word-sized type argument (`int`, `char`,
  `char*`, pointers, struct types), including struct-by-value parameters
  and returns.
- Multiple type parameters (`K pick_first[K, V](K key, V value)`).
- `T` and `T*` locals, `T[]` slice parameters (`xs.length`, indexing,
  `for T x in xs`), `list[T]` / `map[K, T]` / `set[T]` parameters.
- Generic structs: locals, fields, pointers, by-value parameters and
  returns, `char*` and struct type arguments, and generic struct fields
  inside other generic structs (`box[T]` inside `wrapped[T]`).
- Generics calling generics (`largest3[T]` calls `max[T]`); recursive
  instantiation resolves through the drain fixpoint.
- Instantiation before or after the definition in file order.
- Type-argument inference at call sites (`tests/generics_inference_test.w`):
  literals, `int`/`char`/`bool` variables, pointer arguments against `T*`
  shapes, multiple type parameters, mixed generic/concrete parameters,
  inference inside expressions, nested and recursive inferred calls,
  inferred calls inside generic bodies, and inferred + explicit calls
  sharing one instantiation.
- Cross-file use via `import` (definitions record their file); shared
  instantiations deduplicate across files.
- The REPL: generic definitions typed at the prompt persist across
  entries (each entry is staged in its own `/tmp/w_repl_entry_N.w` file so
  recorded spans stay re-parseable), and generics from imported files
  work. The drains are wired into `repl.w` and `debugger/wdbg.w` exactly
  like `template_string_finish_import()`.
- Both targets: x86 and x64 (`generics_test` / `generics_64_test`).

## Limitations (v1)

- **Inference limits.** See "Type-argument inference" above: definition
  before the call site, functions only, no struct-by-value returns on
  inferred calls, and only `T`-with-pointer-depth parameter shapes bind
  (not `pair[T]*` / `list[T]` / `T[]` / `const T*`).
- Generic definitions must be at the top level (not nested in functions),
  and a generic function/struct cannot share a name with another generic
  of the same kind (one definition per name; no overloading on parameter
  count).
- Forward calls (use before definition) skip call-site argument checks
  and cannot return structs by value; define the generic first for full
  checking.
- `for x in xs` with an *inferred* loop variable does not see the
  substitution; declare the element type explicitly (`for T x in xs`).
- Generic methods, generic type aliases, variadic generic functions and
  default parameter values on generic functions are not supported
  (the latter two are rejected with clear errors).
- Type checking happens per instantiation (like C++ templates): a type
  argument that makes the body ill-typed produces the ordinary compiler
  error, with the diagnostic pointing at the definition's file and line.

## Errors

Asserted by the `generics_test` / `generics_inference_test` targets
(fixture files in `tests/`):

- `unknown type name: 'U'` — a definition uses an undeclared type
  parameter; surfaces at instantiation time when the span is re-parsed
  (an uninstantiated generic is never parsed past its header, like a C++
  template).
- `wrong number of type arguments for generic 'pick': expected 1, got 2`.
- `generic function 'pick' requires explicit type arguments, e.g.
  'pick[int](...)'` — a generic function name used without `[` or `(`
  (e.g. taken as a value).
- `generic function 'make': cannot infer type argument 'T'; use explicit
  type arguments, e.g. 'make[int](...)'` — a type parameter no argument
  binds (only in the return type, or only in an opaque shape such as
  `pair[T]*`).
- `generic function 'pick': conflicting types inferred for type parameter
  'T': 'int' vs 'char*'`.
- `generic function 'f': cannot infer type parameter 'T' from argument 1:
  expected a pointer, got 'int'` — a non-pointer argument against a `T*`
  shape.
- `generic function 'f': inferred call returns a struct by value; use
  explicit type arguments, e.g. 'f[int](...)'`.
- `Cannot find symbol: 'f'` — an inferred (bracket-less) call before the
  definition; forward calls need explicit `f[int](...)`.
- `generic function 'f' is not defined (called at file:line)` — a forward
  call whose definition never appeared.

## Build/test wiring

- `Makefile`: `generics_test` and `generics_inference_test` (runtime +
  error fixtures) with `generics_64_test` / `generics_inference_64_test`,
  in the `tests` / `tests_x64` aggregates.
- `build.json`: the same targets and aggregate entries for `./wbuild`.
- `tools/test_map.w`: `tests/generics_infer*` maps to the inference
  targets, other `tests/generics*` to the base targets.
- `tests/parser_generator/w.pg`: permissive `generic_opt` / `generic_args`
  rules on struct/function declarations, `type_ref` and postfix
  expressions, so every tracked `.w` file still parses and round-trips
  (inferred call sites are ordinary calls, so inference needed no grammar
  change).
