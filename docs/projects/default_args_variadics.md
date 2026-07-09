# Default Parameter Values and W-Native Variadic Functions

Design record for two related call-convention features:

```
int greet(char* name, int times = 1, char sep = ',')

int sum(int... values):
	int total = 0
	for int v in values:
		total = total + v
	return total
```

Both features live in the function signature parser
(`grammar/program.w function_definition`), the call-site argument
handler (`grammar/postfix_expr.w parse_call_suffix`), and the symbol
table (`compiler/symbol_table.w`).

## Symbol record growth

The per-symbol record grew from 86 to 134 bytes (`symbol_data_size()`):

```
int: 86:  default-value bitmask: bit i set when parameter i has a default
int: 90:  default parameter values (up to 10 slots of 4 bytes each)
int: 130: W variadic function: number of fixed parameters, -1 otherwise
```

The 10-slot limit mirrors the declared-parameter-type slots at offset 26
(`sym_max_param_slots()`); a default on a parameter past slot 10 is a
compile error. The W-variadic field at offset 130 is deliberately
distinct from the variadic C-import field at offset 78
(`sym_variadic_fixed_args`): C externs are called through the inline
C-ABI path (`emit_ffi_call_inline`), W variadics through the slice
lowering below. All record offsets are encapsulated behind accessors in
`symbol_table.w`; nothing outside it (besides `next_token`
consumers of `symbol_data_size()`) depends on the raw layout, so the
growth is invisible to the REPL's `table_pos` snapshots and the ELF
string/symbol table emitters.

## Default parameter values (v1)

- Syntax: `type name = <constant>` in a function parameter list.
- Allowed constants: decimal and hex integer literals, optionally
  negated; char literals including the `\n \t \r \0` escapes; and named
  enum constants. Enum constants work because an enum member is a
  defined global object of an enum-kind type whose int32 value was
  already emitted into the image at the symbol's address, so
  `parse_constant_default()` reads it straight back out of the `code`
  buffer. Anything else (variables, arithmetic expressions, function
  calls) is rejected with
  "default value for parameter must be a compile-time constant".
- Trailing rule: once a parameter has a default, every following
  parameter must have one ("parameter without a default follows a
  parameter with a default").
- Call sites (`parse_call_suffix`): when fewer arguments than declared
  parameters were passed and every missing trailing parameter has a
  default, the recorded constants are materialized with `mov eax, imm`
  + push (coerced through `coerce(param_type, constant)`, so e.g. bool
  and float parameters convert). If any missing parameter lacks a
  default, the pre-existing arity warning fires unchanged.
- Scope: direct calls only, because defaults are read from the callee's
  symbol. Indirect calls through `fn(...)` pointers keep fixed arity.
  Struct method calls resolve to a direct symbol
  (`typename_method`), so they honor defaults; the hidden receiver
  simply counts as parameter 0.
- Prototypes: defaults live on whichever declaration provided them. A
  declaration that specifies at least one default replaces the whole
  recorded set; one that specifies none keeps what an earlier
  declaration recorded. Hence prototype-only defaults survive the
  definition, and when both specify, the definition wins for every call
  site compiled after it (this is a single-pass compiler, so each call
  site uses the latest declaration seen at that point).

## W-native variadic functions (v1)

- Syntax: `T... name` as the last parameter only ("variadic parameter
  must be the last parameter" otherwise). The symbol records the number
  of fixed parameters in the new field; the parameter itself is
  declared with the ordinary slice type `T[]`.
- Element types must be word-sized (`type_get_size == word_size`, no
  structs/arrays/slices/containers): `int`, `uint`, pointers, `string`.
  `char` and other sub-word types are rejected because the argument
  buffer is built from stack words, and a `char[]` slice would index it
  byte-wise. Note the check is per target word size (e.g. `int32...` is
  accepted on x86 and rejected on x64).
- Callee view: the parameter is a plain `T[]` slice, so `.length`,
  indexing, and `for v in values` reuse the existing buffer machinery —
  zero new callee-side codegen. (Slice iteration itself was added to
  `grammar/for_statement.w` as `for_slice_loop`: hidden stack slots for
  the descriptor pointer and a running index, elements loaded via the
  regular `promote()` width-sized load. Fixed arrays iterate through
  the same path because `promote()` decays them to slice values.)
- Caller lowering (`parse_call_suffix`), all on the caller's stack, no
  heap allocation:
  1. Fixed arguments are parsed and pushed as usual.
  2. Each trailing argument is type-checked/coerced against the element
     type and pushed, producing a contiguous word buffer (in reverse
     memory order, since pushes grow downward).
  3. The buffer is reversed in place with n/2 emitted swaps
     (`store_ebx_stack_var` is a new backend helper for the second
     store), so element 0 sits at the lowest address.
  4. A `{data, length}` descriptor is pushed just below the values.
  5. The fixed argument words are re-pushed as copies: the callee
     addresses its parameters as one contiguous block above the return
     address, and the value buffer + descriptor would otherwise sit in
     the middle of it.
  6. The slice argument (a pointer to the descriptor) is pushed last.
  The caller's existing `be_pop(stack_pos - s)` cleanup discards the
  buffer, descriptor, and copies along with the arguments, so nested
  variadic calls and calls in loops need no extra bookkeeping beyond
  the usual `stack_pos` accounting.
- Zero variadic arguments work: length 0 with a dangling-but-unused
  data pointer.
- Arity: at least the fixed parameters are required
  ("expects at least N arguments" warning otherwise).
- Interaction with defaults: mutually exclusive. A variadic parameter
  may not follow defaulted parameters ("a variadic parameter cannot
  follow parameters with default values") and cannot itself carry a
  default.
- Out of scope (v1): calling a variadic function through a function
  pointer (signatures have no `...` spelling; a matching explicit-slice
  signature would require the caller to pass a ready-made descriptor),
  forwarding an existing slice as the variadic tail (arguments are
  always collected element-wise), and more than 10 total parameters.
- Variadic C imports (`extern int printf(char* fmt, ...)`) are entirely
  unaffected; they keep the offset-78 flag and the inline C-ABI path.

## Tests

- `tests/default_args_test.w` (+ x64 variant): defaults used/overridden,
  multiple defaults, char/negative/hex/enum defaults, struct methods,
  prototype+definition semantics, call sites inside expressions.
- `tests/varargs_w_test.w` (+ x64): 0/1/many arguments, `.length`,
  indexing order, `for v in values`, `char*` elements, fixed+variadic,
  computed arguments, nested variadic calls, calls in loops, variadic
  struct methods.
- Error fixtures: `default_args_nontrailing_error_fixture.w`,
  `default_args_nonconstant_error_fixture.w`,
  `default_args_missing_warning_fixture.w` (arity warning unchanged),
  `varargs_w_not_last_error_fixture.w`,
  `varargs_w_default_error_fixture.w`.
- Targets `default_args_test`, `varargs_w_test` (+ `_64_` variants) in
  `build.json`; registered in `tools/test_map.w`.
- `tests/parser_generator/w.pg` grew `param_default` (`= expression`)
  and the `type_ref ELLIPSIS name_token` parameter form.
