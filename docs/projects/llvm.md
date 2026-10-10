# LLVM offload experiment (#337)

`bin/wllvm` is an opt-in visitor over the production compiler's retained AST.
It emits LLVM IR text for a bounded scalar subset of W. The production parser
and semantic analyzer remain the source of truth: this tool introduces no
second W parser or type checker and does not use the parser-generator grammar.
The original proposal and dependency tradeoffs are recorded in
[compilation_model.md §3](compilation_model.md#3-337-llvm-offload).

## Build and run

```sh
./wbuild wllvm
bin/wllvm program.w -o bin/program.ll
clang -Wno-override-module -O2 bin/program.ll -o bin/program_llvm
bin/program_llvm
```

Clang is only needed for the last two steps. Emitting `.ll`, bootstrapping W,
and using the existing backends require no LLVM installation. The output uses
the textual format defined by the [LLVM language reference](https://llvm.org/docs/LangRef.html).

This first version uses W's x64 semantics: `int` is a signed 64-bit word,
including W's sign extension of hexadecimal literals with bit 31 set. It is
not a switch on `wv2` and does not replace a production backend.

## Architecture and limits

The CLI invokes the production compiler in a semantic-retaining check session
for the x64 target, then hands the retained forest to the LLVM visitor. The
frontend still performs the existing native lowering needed by its analysis;
this experiment does not establish independent whole-module AST compilation
or a compile-time speedup. See [AST migration](ast_migration.md) for that work.

The visitor resolves local storage and function calls using retained binding
identities, so equal spellings in different scopes remain distinct. It emits
basic blocks for control flow and ordinary LLVM instructions for scalar
expressions. Unsupported source constructs cause a diagnostic and a nonzero
exit instead of being dropped or compiled by a fallback backend.

## Supported subset

- A single input module with a zero-argument `int` or `bool` `main`, scalar `int`/`bool`
  functions and initialized scalar locals.
- Same-module calls, including recursion and forward declarations; parameters
  and return values use the retained semantic signatures. Scalar default
  arguments are materialized by the production frontend before the visitor.
- Integer arithmetic, bitwise operations, comparisons, unary signs and logical
  negation, `int`/`bool` casts, assignments and short-circuit `&&`/`||`.
- `if`/`elif`/`else`, `while`, `break`, `continue`, `pass` and value returns.

Addition, subtraction and multiplication wrap as W words. Shift counts are
masked to six bits. Division and remainder guard zero divisors and signed
minimum divided by minus one before entering LLVM's division instructions;
invalid cases trap. The LLVM trap can report a different host signal from
the production x64 divide instruction. Calls and operands preserve evaluation
order, and logical chains evaluate only the operands required by their result.

Imports, global data, pointers, floats, records, containers, library calls,
generics, deferred calls, range loops and other unsupported constructs are
rejected. Unsupported unreachable code is checked too. This is an intentionally
small executable experiment, not full W library support or LLVM self-hosting.
Locals require initializers and functions require an explicit return on every
path; the visitor conservatively treats loops as able to exit. Expression
visits deeper than 256 nodes are rejected with a diagnostic.

## Tests

```sh
./wbuild wllvm_test
./wbuild tests
```

`wllvm_test` always checks deterministic IR, unsupported-program diagnostics,
CLI errors, input/output identity protection and preservation of existing
output on rejected input. When `clang` is on `PATH`, it also compiles the same
fixture with W's native x64 backend and LLVM at `-O0` and `-O2`, then compares
exit status and output. Without Clang it reports the native comparison as
skipped; the structural and rejection checks still run.

The scalar fixture exercises recursive and forward calls, nested loops,
scope shadowing, short-circuit side effects, argument evaluation order,
64-bit arithmetic, literal sign extension, shift masking and wraparound.
Clang 18 is the initial interoperability test environment. No LLVM dependency
is added to the seed or production compiler import graph.

Validation on 2026-10-09: `env -u NO_COLOR ./wbuild --keep-going tests` passed
all 1,050 targets. The environment override lets the existing forced-color
diagnostic fixtures exercise their intended mode. The new sources also passed
the production checks and parser-generator grammar check. All six LLVM tests
passed with Clang 18.1.3, and with a restricted `PATH` without Clang (native
comparisons explicitly skipped in the latter run).
