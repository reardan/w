# Generics with Explicit Instantiation

True generics/templates for W: user-defined generic functions and structs,
monomorphized per instantiation. Instantiation is always explicit
(`name[type-args]`); there is no inference from argument types in v1.

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
- Cross-file use via `import` (definitions record their file); shared
  instantiations deduplicate across files.
- The REPL: generic definitions typed at the prompt persist across
  entries (each entry is staged in its own `/tmp/w_repl_entry_N.w` file so
  recorded spans stay re-parseable), and generics from imported files
  work. The drains are wired into `repl.w` and `debugger/wdbg.w` exactly
  like `template_string_finish_import()`.
- Both targets: x86 and x64 (`generics_test` / `generics_64_test`).

## Limitations (v1)

- **No inference.** `max(3, 5)` on a generic is a compile error with a
  hint to write `max[int](...)`.
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

Asserted by the `generics_test` target (fixture files in `tests/`):

- `unknown type name: 'U'` — a definition uses an undeclared type
  parameter; surfaces at instantiation time when the span is re-parsed
  (an uninstantiated generic is never parsed past its header, like a C++
  template).
- `wrong number of type arguments for generic 'pick': expected 1, got 2`.
- `generic function 'pick' requires explicit type arguments, e.g.
  'pick[int](...)'`.
- `generic function 'f' is not defined (called at file:line)` — a forward
  call whose definition never appeared.

## Build/test wiring

- `Makefile`: `generics_test` (runtime + error fixtures) and
  `generics_64_test`, in the `tests` / `tests_x64` aggregates.
- `build.json`: the same targets and aggregate entries for `./wbuild`.
- `tools/test_map.w`: `tests/generics*` maps to both targets.
- `tests/parser_generator/w.pg`: permissive `generic_opt` / `generic_args`
  rules on struct/function declarations, `type_ref` and postfix
  expressions, so every tracked `.w` file still parses and round-trips.
