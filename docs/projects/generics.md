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

A registered generic function called as `name(...)` infers type arguments
from the argument types. `T` and pointer-depth shapes such as `T*` bind the
corresponding concrete type. Untyped scalar literals bind `int` when unbound
and coerce to a previous binding; incompatible typed bindings are errors.
Whole-parameter `T` inference preserves checked qualifiers and lifetime groups.

The retained parser resolves the concrete signature before emitting code.
Aggregate results reserve their caller-owned return buffer before argument
evaluation. Arguments evaluate left to right, and temporary aggregate buffers
are compacted after copying their values. Explicit and inferred calls share
specialization identity, ownership effects and lifetime checks.

Checked `ref[a,b] T` and `refmut[a] T` shapes infer a plain record template from
a borrowed wrapper. `ref[a] T[]` infers the element of a checked slice or fixed
array, then performs the ordinary checked descriptor conversion. Concrete
parameters and opaque shapes are checked against the specialized signature.
A parameter used only in an opaque shape or return type still needs explicit
type arguments. A `Name[T, U]*` parameter (optionally checked-qualified, as in
`ref[a] WSafeMutex[T]*`) binds each bare type parameter from the argument's
generic struct instance in both emitters; composite type arguments of the
application stay opaque and are checked by the specialized signature. Raw
container shapes and generic struct constructors retain their existing
inference restrictions.

Definitions must precede inferred calls. Forward generic calls still require
explicit arguments and cannot return aggregates. The streaming emitter retains
its explicit-type-argument requirement for aggregate results and does not admit
the new checked shape or method forms.

## Generic method calls

The retained parser accepts `receiver.function[T](arguments)` and
`receiver.function(arguments)`, passing the receiver as the first argument of
the ordinary specialized function. The latter form includes the receiver in
inference. A record value is addressed when the first parameter requires a
pointer; borrowed inline wrappers otherwise retain their value representation.
The receiver evaluates once, before the remaining arguments. Checked receiver
loans, transfers, return provenance and cleanup match the direct call.

A matching record-prefixed definition (`Record_function`) takes precedence
over unprefixed function syntax. Without explicit type arguments, an ordinary
prefixed definition wins over a generic one, and an ordinary unprefixed function
wins over an unprefixed generic definition. Explicit type arguments select a
generic definition. Fields and built-in container operations retain their
existing precedence. Methods must be defined before use.

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
- `new T` and `new T(arguments)` resolve the active type parameter in both
  retained and streaming emitters. Substitutions take precedence over an
  unrelated global type with the same name. Checked factories preserve
  concrete constructor arity, field contracts, ownership transfers and cleanup;
  specialization does not permit default allocation of pointer-bearing records.
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
  before the call site and functions only. Raw composite parameter shapes
  remain opaque; retained checked borrowed shapes have the rules above.
  The streaming emitter still requires explicit aggregate-return calls.
- Generic definitions must be at the top level (not nested in functions),
  and a generic function/struct cannot share a name with another generic
  of the same kind (one definition per name; no overloading on parameter
  count).
- Forward calls (use before definition) skip call-site argument checks
  and cannot return structs by value; define the generic first for full
  checking.
- `for x in xs` with an *inferred* loop variable does not see the
  substitution; declare the element type explicitly (`for T x in xs`).
- Generic type aliases, variadic generic functions and
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
- In streaming mode: `generic function 'f': inferred call returns a struct
  by value; use explicit type arguments, e.g. 'f[int](...)'`.
- `Cannot find symbol: 'f'` — an inferred (bracket-less) call before the
  definition; forward calls need explicit `f[int](...)`.
- `generic function 'f' is not defined (called at file:line)` — a forward
  call whose definition never appeared.

## Build/test wiring

- `build.json`: `generics_test` and `generics_inference_test` (runtime +
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
