# W language reference

This is the reference for what the W compiler accepts and what the
programs it produces do. It describes **current behaviour**: every rule
below was checked by compiling and running small probe programs with
`bin/wv2` built from commit `5bbce83f` (October 2026) on the 32-bit x86
target (default), x64 (`w x64`) and arm64 Linux (`w arm64`, run under
qemu-user). Where the three differ the table says so. The other targets
were not probed: wasm32 shares x86's 4-byte word, while win64 and
arm64_darwin share x64's 8-byte word.

It is a reference, not a tutorial. Where a feature has its own design
document, this page states the rule and links to that document.
Behaviour that is surprising or arguably a bug is documented as it is,
and collected under [Known divergences](#known-divergences). Rules
marked **(#532)** are type-checking holes that issue #532 plans to
turn into diagnostics, so they may become warnings or errors.

The syntax itself is also written down as a grammar in
[`tests/parser_generator/w.pg`](../tests/parser_generator/w.pg), which
`parser_generator_w_test` runs over every tracked `.w` file. That
grammar describes syntax only. This page covers the semantics.

Contents: [Lexical structure](#lexical-structure) ·
[Types](#types) · [Integer model](#integer-model) ·
[Declarations](#declarations) · [Expressions](#expressions) ·
[Pointers and arrays](#pointers-and-arrays) ·
[Statements](#statements) ·
[Containers and strings](#built-in-containers-and-strings) ·
[Modules](#modules-and-programs) · [Type checking](#type-checking) ·
[Undefined behaviour](#undefined-behaviour) ·
[Reserved identifiers](#reserved-identifiers-and-prelude-names) ·
[Known divergences](#known-divergences)

## Lexical structure

| Item | Rule |
|---|---|
| Encoding | UTF-8 source ([utf8_source.md](projects/utf8_source.md)). |
| Indentation | Tabs open blocks. Space indentation is a warning, and so an error under `--strict`. |
| Blocks | A line ending in `:` opens an indented block. A single statement may follow the `:` on the same line (`if x: return 1`). `pass` is the empty statement. |
| Statement end | End of line. `;` also separates statements on one line (`int a = 1; int b = 2`). |
| Line continuation | An expression continues onto the next line after an unclosed `(` or `[`, or after a trailing binary operator (`a +` ⏎ `b`). There is no `\` continuation. |
| Comments | `#` to end of line. `/* ... */` block comments, which may span lines. |
| Final newline | Required; a missing one is a warning. |
| Identifiers | `[A-Za-z_][A-Za-z0-9_]*`. Some names are reserved or collide with runtime names; see [Reserved identifiers](#reserved-identifiers-and-prelude-names). |

### Literals

| Literal | Type | Notes |
|---|---|---|
| `123` | untyped integer constant | Decimal. A leading `0` is still decimal (`017` is 17); there are no octal literals. See [literal widths](#literal-widths). |
| `0x1F`, `0b101` | untyped integer constant | Hex and binary, case-insensitive digits. |
| `'a'`, `'\n'`, `'\x41'`, `'\\'` | untyped integer constant | The byte value of the character. |
| `true`, `false` | `bool` | |
| `1.5`, `1e-3` | float constant | See [float.md](projects/float.md). |
| `"text"` | `string` | UTF-8 checked at compile time. `\u`/`\U` escapes are accepted. Decays to its NUL-terminated `char*` where a `char*` is expected. `s"..."` is an older spelling of the same literal. |
| `c"text"` | `char*` | A legacy NUL-terminated C string. |
| `f"x={x:04x}"` | `string` | Template string ([template_strings.md](projects/template_strings.md)). |
| `list[int]{1, 2}`, `set[int]{1}` | container | See [Containers and strings](#built-in-containers-and-strings). |

## Types

Sizes are in bytes. "Word" is 4 on x86 and wasm32 and 8 on x64, arm64,
win64 and arm64_darwin; the compile-time constant `__word_size__` holds
it.

| Type | x86 | x64 / arm64 | Signed | Notes |
|---|---|---|---|---|
| `int` | 4 | 8 | yes | Word-sized. |
| `uint` | 4 | 8 | no | Word-sized; see [unsigned operations](projects/type_system_p0.md#unsigned-operations). |
| `char` | 1 | 1 | **yes** | `char c = 200` reads back as -56; a `char*` byte `0xff` reads as -1. |
| `byte` | 1 | 1 | **yes** | Same as `char` in arithmetic. Because `byte` is a type name, `byte = 5` cannot start a statement. |
| `int8` / `int16` / `int32` | 1 / 2 / 4 | same | yes | Loads sign-extend into the word. |
| `uint8` / `uint16` / `uint32` | 1 / 2 / 4 | same | no | Loads zero-extend into the word. |
| `int64` / `uint64` | compile error | 8 | yes / no | `int64 requires the x64 target` on x86. |
| `bool` | 1 | 1 | — | Values 0 and 1; `true` and `false`. |
| `float`, `float32` | 4 | 4 | — | |
| `float64` | compile error | 8 | — | Only on 64-bit-word targets. |
| `float16` | 2 | 2 (x64) | — | Storage only; x86 family only. See [float.md](projects/float.md). |
| `T*`, `pointer`, `void*` | 4 | 8 | — | |
| `string` | 4 | 8 | — | One word in a variable. `.length` is in bytes. Representation: [arrays_slices_strings.md](projects/arrays_slices_strings.md). |
| `var` | 4 | 8 | — | A dynamically typed box ([dynamic_var.md](projects/dynamic_var.md)). |
| `T[N]` | N·sizeof(T) | same | — | Fixed array: local, global or struct field. |
| `T[]` | — | — | — | Slice ([arrays_slices_strings.md](projects/arrays_slices_strings.md)). |
| `struct`, `union` | packed | packed | — | Fields have **no alignment padding**: a struct with fields `int x` and `char c` is 5 bytes on x86 and 9 on x64. A union is as large as its largest member. |
| `enum` | 4 | 4 | yes | Backed by a 32-bit integer. |
| `list[T]`, `map[K, V]`, `set[K]` | 4 | 8 | — | References to heap objects ([typed_containers.md](projects/typed_containers.md)). |
| `fn(T, ...) -> U` | — | — | — | A function type, used through an alias: `type op = fn(int, int) -> int`, then `op* f = add`. |

`sizeof(T)` is a compile-time `int` and always equals the indexing
stride of `T`.

## Integer model

### Literal widths

The compiler decodes every integer literal to a **signed 32-bit value**
and then sign-extends it into the target word.

| Literal | x86 | x64 / arm64 | Diagnostic |
|---|---|---|---|
| `2147483647` | 2147483647 | 2147483647 | none |
| `2147483648` .. `4294967295` (decimal) | wraps negative | wraps negative (`4294967295` is -1) | **none** |
| `0x80000000` .. `0xffffffff` | negative | negative (`0xffffffff` is -1) | warning: `integer literal has bit 31 set...`; `cast(int, 0xffffffff)` silences it |
| more than 32 significant bits (`10000000000`, `0x100000000`) | error | error | `integer literal has more than 32 significant bits; ...` |
| `-2147483648` | -2147483648 | **+2147483648** | none. The literal wraps to -2³¹ and the unary minus is applied in the 64-bit word. Write `-2147483647 - 1`. |
| `int64 y = 3000000000` | n/a | -1294967296 | none |

Wide constants must be built at runtime from 32-bit pieces, by shifting
and or-ing the halves. This is also why `x & 0xffffffff`
never truncates on 64-bit targets; `lib/sha256.w` builds its 32-bit mask
at runtime.

### Arithmetic

| Operation | Rule |
|---|---|
| `+ - *` on `int`/`uint` | Two's complement, wrapping at the **word** width. No trap. `2147483647 + 1` (at runtime) is -2147483648 on x86 and 2147483648 on x64/arm64. |
| Sub-word operands (`char`, `int8`..`int32`, `uint8`..`uint32` narrower than the word) | Loaded and widened to the word (sign- or zero-extended by type), computed in the word, and **truncated on store**. On x64, `int32 x = 2147483647` gives `x + 1 == 2147483648`, but `x = x + 1` stores -2147483648. |
| `/`, `%` | Truncate toward zero; the remainder takes the dividend's sign (`-7 / 2 == -3`, `-7 % 2 == -1`, `7 % -2 == 1`). Unsigned when either operand is an unsigned word type. |
| Division by zero | x86 and x64: the process dies with SIGFPE (exit 136, no message). arm64: `a / 0 == 0` and `a % 0 == a`. Constant expressions: compile error. |
| `INT_MIN / -1` | x86 and x64: SIGFPE. arm64: INT_MIN, and `INT_MIN % -1 == 0`. |
| `>>` | Arithmetic (sign-filling) on signed operands, logical when the left operand is an unsigned word type. |
| Shift count ≥ width or negative | The hardware masks the count: x86 uses `count & 31`, so `1 << 40 == 256`; x64 and arm64 use `count & 63`. Constant expressions reject counts outside 0..31. |
| Signed/unsigned mixing | An operation is unsigned when either operand is `uint`, or `uint32`/`uint64` where that is the word size. Narrower unsigned types do not make it unsigned. So `uint32 a = 1; a > -1` is **false on x86 and true on x64**. Full rules: [unsigned operations](projects/type_system_p0.md#unsigned-operations). |
| Pointer comparisons | Signed word comparisons. |
| `print`/f-string of `uint` | Formatted as signed. |

### Conversions

| Conversion | Rule |
|---|---|
| Store into a narrower integer (assignment, initialisation, argument, field) | Truncates to the destination width, silently: `char c = 300` holds 44. **(#532)** |
| Load of a narrower integer | Sign-extends signed types (`char`, `byte`, `intN`) and zero-extends unsigned ones. |
| `cast(T, e)` to an integer type, used as a value | **Changes only the static type; no truncation or extension.** `cast(uint8, -1) + 0 == -1` and `cast(char, 255) + 0 == 255`. The value is narrowed only when it is stored. See [Known divergences](#known-divergences). |
| Integer to `bool` | A constant is normalised to 0/1 (`bool b = 5` holds 1). A non-constant `int` (`bool b = n`) currently crashes the produced program (#525); write `n != 0`. |
| float to int | Truncates toward zero (`int i = 3.9` is 3). Out-of-range results are target-specific ([float.md](projects/float.md), "Known MVP semantic differences"). |

### Constant expressions

Global initialisers, `const` values, parameter defaults and enum values
take a constant expression. The operators allowed are unary `-` `+` `~`,
`* / %`, `+ -`, `<< >>`, `& ^ |`, parentheses, `sizeof(T)` and other
constants. Comparisons and `&&`/`||` are **not** accepted
(`const int D = 3 > 2` is a parse error). Constant expressions are
folded in **signed 32-bit** arithmetic on every target, and these are
compile errors: overflow (`constant expression overflows 32 bits`),
division by zero, and a shift count outside 0..31. The same expression
inside a function body is computed at runtime and is not checked.

## Declarations

| Form | Example | Notes |
|---|---|---|
| Local / global variable | `int x = 1`, `int x` | Locals are block-scoped and may shadow outer names. Redeclaring a name in the same block is silently accepted and shadows the first. |
| Inferred local | `s := 0` | The type comes from the initializer ([golf_ergonomics.md](projects/golf_ergonomics.md)). |
| Constant | `const int PAGE = 4 * KB` | Assigning to it is an error (`assignment to const`). |
| Thread-local global | `thread_local int n` | Has no initializer and starts zeroed ([thread_local.md](projects/thread_local.md)). |
| Function | `int add(int a, int b):` | The return type comes first. `void` means no value. |
| Default arguments, variadics | `int f(int a, int b = 2)`, `int sum(int... v)` | [default_args_variadics.md](projects/default_args_variadics.md) |
| Generic function / struct | `T max[T](T a, T b):`, `struct pair[T]:` | Monomorphized. Instantiation is explicit (`max[int]`) or inferred for calls after the definition ([generics.md](projects/generics.md)). |
| Generator | `generator int count(int n):` with `yield v` | Needs `import lib.generator` ([iteration.md](projects/iteration.md)). |
| Struct | `struct point:` then one field per indented line | Packed layout. Methods are free functions named `point_move(point* p, ...)`, called as `p.move(...)` ([struct_methods.md](projects/struct_methods.md)). |
| Union | `union num:` | Untagged; every field is at offset 0. |
| Enum | `enum color:` then `red`, `green = 4`, `blue` | Enumerator names are **global** (`red`, not `color.red`) and number upward from the previous value (`blue == 5`). `enum_name(e)` returns the name. |
| Type alias | `type size_t = uint` | Transparent. |
| Operator overload | `vec3 operator+(vec3 a, vec3 b):` | Struct operands only ([operator_overloading.md](projects/operator_overloading.md)). |
| FFI | `c_lib "libc.so.6"`, `extern int puts(char* s)`, `c_import ...` | [c_import.md](projects/c_import.md) |
| Wasm export | `export int f(...)` | Accepted and ignored on native targets. |

Initial values:

| Storage | Initial value |
|---|---|
| Globals, `thread_local` | Zero. |
| `new T[n]`, `new T(field: v)`, `T(field: v)` | Zero, apart from the named fields. |
| Locals without an initializer; `new T`; `new T()` | **Indeterminate**: reading them is [undefined](#undefined-behaviour). #530 plans to zero `new T`. |
| A container variable that was declared but never constructed (`list[int] l`) | Null: using it segfaults. Construct it with `new list[int]` or `list[int]{}`. |

## Expressions

### Precedence

Highest first. Binary operators are left-associative except where noted.
This is **C precedence**, not Python's, even though the surface syntax
looks like Python.

| Level | Operators | Notes |
|---|---|---|
| 1 | `f(x)` `a[i]` `a[i:j]` `s.f` `p.f` `e?` | `.` works through pointers too (no `->`). A postfix `?` propagates a `wresult[T]` error ([error_results.txt](error_results.txt)). |
| 2 | unary `-` `+` `!` `!!` `~` `*` `&`, `new`, `cast(T, e)`, `sizeof(T)` | `++`/`--` are statements only, not expressions ([increment_decrement.md](projects/increment_decrement.md)). |
| 3 | `*` `/` `%` | |
| 4 | `+` `-` | `+` on two `string`s concatenates. |
| 5 | `<<` `>>` | |
| 6 | `<` `<=` `>` `>=` `in` | **No chaining**: `3 > 2 > 1` parses as `(3 > 2) > 1`, which is `1 > 1`, so 0. Write `a > b && b > c`. |
| 7 | `==` `!=` | Contents comparison for two `string`s; identity for `char*`, pointers and **structs** (which compare addresses). **(#532)** |
| 8 | `&` | Bitwise; binds looser than `==`, so `x & 1 == 0` means `x & (1 == 0)`. |
| 9 | `^` | |
| 10 | `\|` | |
| 11 | `&&` | Short-circuits; the result is 0 or 1. |
| 12 | `\|\|` | Short-circuits; the result is 0 or 1. |
| 13 | `c ? a : b` | Right-associative. |
| 14 | `=` and `+= -= *= /= %= &= \|= ^= <<= >>=` | Right-associative (`a = b = 5`). An assignment is an expression. Parallel assignment `a, b = b, a` works at statement level only ([golf_ergonomics.md](projects/golf_ergonomics.md)). |

`&` and `|` evaluate both operands and never short-circuit, so use
`&&`/`||` for guards. Comparison and logical operators yield `bool`.
Any integer or pointer is allowed as a condition, and non-zero is true.

### Evaluation order

Binary operands are evaluated left to right, and so are call arguments
(probed on all three targets). `defer` expressions are evaluated when
the function exits, not where the `defer` is written
([defer.md](projects/defer.md)).

### Other expression forms

| Form | Rule |
|---|---|
| `x.f(args)` | A method if `T_f` exists for the receiver's type; otherwise a built-in pseudo-method; otherwise uniform call syntax `f(x, args)` ([golf_ergonomics.md](projects/golf_ergonomics.md)). |
| `l.map(it * 2)` and the other `it`-expressions | Compiled as inline loops. W has no lambdas or closures ([golf_ergonomics.md](projects/golf_ergonomics.md)). |
| `new T`, `new T(a, b)`, `new T(x: 1)`, `new T[n]` | Heap allocation; see [Initial values](#declarations). |
| `cast(T, e)` | The explicit conversion. It silences the type warnings below but rejects struct-value casts and pointer-to-sub-word-integer casts. |

## Pointers and arrays

| Rule | Detail |
|---|---|
| `T* + int`, `T* - int`, `p += n`, `p++` | A **raw, unscaled byte offset** for every pointee type: `int* p; p + 1` moves 1 byte. The result keeps the type `T*`, so `*(p + n)` reads a whole `T` at byte offset `n`. |
| Indexing `p[i]`, `&p[i]` | Scales by `sizeof(T)`. This is the form to use in new code; `lib/ptr.w`'s `ptr_add(p, n)` is `&p[n]` written as a call. |
| `p - q` | A plain integer byte distance. |
| `int` ↔ pointer | Warns unless written with `cast()`. The literal `0` and `&x` are untyped constants and convert silently. |
| `void*` → `T*` | Implicit and silent. **(#532)** |
| Bounds checks | `--bounds=on` (the default) checks indexing of fixed arrays `T[N]` and slices `T[]` (including `int[] s = new int[n]`), and traps with a stack trace. Indexing a raw `T*` is never checked, even when it holds a `new T[n]` result. `--bounds=off` removes the checks ([arrays_slices_strings.md](projects/arrays_slices_strings.md)). |
| Null | There is no null keyword; `0` is the null pointer. Dereferencing it is not checked (Linux delivers SIGSEGV). |

## Statements

| Statement | Notes |
|---|---|
| `if c:` / `elif c:` / `else:` | Parentheses are optional; `else if` also works. |
| `while c:` | |
| `for int i in range(end)` / `range(start, end[, step])` | The range arguments are evaluated once. |
| `for T x in container` | Built-in lists, maps and sets; any `T*` whose module provides `T_iter_begin/done/next/value`; generators ([iteration.md](projects/iteration.md)). |
| `for int cp in s` (`string`) | Iterates over code points. Needs `import lib.utf8`. |
| `switch e:` / `case a, b:` / `default:` | No fallthrough. `break` leaves the switch and `continue` goes to the enclosing loop. Case values are integers, `string` or `char*` (compared by contents). Duplicate labels are accepted silently. **(#532)** |
| `break`, `continue`, `return [e]`, `pass` | |
| `defer call(...)` | Function-scoped, runs LIFO at every exit ([defer.md](projects/defer.md)). |
| `goto name` / `name:` | Function-scoped labels written at the indentation of the statements around them. Native targets only. |
| `yield e` | Only inside a generator. |
| `debugger` | Emits a breakpoint trap (`int3`) for `wdbg` ([debugging.txt](debugging.txt)). |
| `x++`, `x--`, `++x`, `--x` | Statements only. |

## Built-in containers and strings

| Feature | Reference |
|---|---|
| `list[T]`: `push`, `pop`, `.length`, negative indexes, slices, `sort`, `map`/`filter`/`sum` | [typed_containers.md](projects/typed_containers.md), [golf_ergonomics.md](projects/golf_ergonomics.md) |
| `map[K, V]`, `set[K]`: `in`, `m.add(k)`, `keys()`, `values()`, defaults | [hash_maps_sets.md](projects/hash_maps_sets.md), [map_default_factory.md](projects/map_default_factory.md) |
| `string`, slices, `.length` (bytes), UTF-8 rules | [arrays_slices_strings.md](projects/arrays_slices_strings.md) |
| Iteration order | Maps and sets iterate in insertion order. |
| Errors | A missing map key, an out-of-range list index and `pop` on an empty list each trap with a stack trace. |
| Lifetime | Containers live on the heap until `.free()`. There is no garbage collection; using a container after `.free()` is undefined. |

## Modules and programs

| Item | Rule |
|---|---|
| `import a.b` | Compiles `a/b.w` once. Every top-level name it declares lands in **one global namespace** shared with the importer and with everything else imported. |
| `import a.b as m` | Adds the checked qualified spelling `m.name`. Unqualified names stay visible. |
| `__arch__` path segment | Resolves to the target directory (`x86`, `x64`, `arm64`, ...). |
| Search path | The working directory and its parents, then the compiler binary's directory. `--import-root` comes first ([compilation_model.md](projects/compilation_model.md) §7). |
| Entry point | The ELF entry calls `_main`. `lib/lib.w` provides a `_main` that calls `main(argc, argv)`. A program may define `_main` itself instead. |
| Script mode | Top-level statements that are not declarations form an implicit `main` ([golf_ergonomics.md](projects/golf_ergonomics.md)). |
| Compile-time constants | `__word_size__` (4 or 8); `__target_isa__` (0 for the x86 family, 1 for arm64). |

## Type checking

The checker reports some errors, some warnings (which are errors only
under `--strict`), and lets other mismatches through silently. Every
silent row is a candidate diagnostic under #532.

| Construct | Today |
|---|---|
| Assigning to a `const` | error |
| Writing through a pointer to const | error |
| Wrong argument count | warning **(#532)** |
| `int` ↔ pointer, pointer ↔ unrelated pointer | warning **(#532)** |
| `T*` → `const T*`, and `const T*` → `T*` | warning (both directions) |
| Function value to a typed function pointer that does not match | warning |
| `cast(T*, const_ptr)` (removes const) | silent |
| Narrowing an integer store (`char c = 300`) | silent **(#532)** |
| `int` → `enum` (`color c = 5`) | silent **(#532)** |
| `void*` → any `T*` | silent **(#532)** |
| Struct `==` | silent; compares addresses **(#532)** |
| Falling off the end of a non-void function | silent; the return value is garbage **(#532)** |
| `return 5` in a `void` function | silent **(#532)** |
| Calling an `int` variable (`k(1)`) | silent; jumps to that address **(#532)** |
| Duplicate `case` labels | silent **(#532)** |
| Mixed signed/unsigned, bool ↔ int, float → int | silent (defined conversions) |

`w check --all-errors` reports several errors from one run.
`w check --lint` adds the opt-in lint rules ([lint.md](projects/lint.md)).

## Undefined behaviour

Behaviour is **undefined** in the cases below. The compiler does not
diagnose them, and the result can differ by target, by build and from
run to run.

| Case | What happens today |
|---|---|
| Reading an uninitialised local or `new T` memory | Stack or heap garbage. |
| Using a missing return value (falling off a non-void function) | Whatever is in the return register. |
| Dereferencing null, a dangling pointer, or memory after `free`/`.free()`; double free | Usually SIGSEGV. The release allocator detects neither double frees nor bad frees (#530). |
| Out-of-range access through a raw `T*`, or with `--bounds=off` | Reads or corrupts neighbouring memory. |
| Calling a non-function value | Jumps to that address. |
| A data race between threads | W has no memory model ([threads.md](projects/threads.md)). |
| Unbounded recursion | Stack overflow; SIGSEGV with no report (#526). |
| Casting an integer to a pointer that does not point to an object of that type | |

These are **defined** by this reference, so they are not undefined:
signed wrap-around at the word width (hash functions rely on it); the
narrowing store; the hardware shift-count masking above; and integer
division by zero and `INT_MIN / -1`, which follow the table above for
each target (a SIGFPE trap on the x86 family). The last two differ by
target, so portable code must avoid them.

## Reserved identifiers and prelude names

W has no keyword table. Each grammar rule recognises its own words in
the positions where it expects them, so how "reserved" a word is
depends on where it appears. Every result below was probed with a local
declaration, a function name, a struct field, an assignment statement
and a use in an expression.

| Class | Words | Behaviour |
|---|---|---|
| Fully reserved | `new`, `cast`, `sizeof` | Rejected as any declared name; only a struct field may use them. |
| Built-in constants | `true`, `false`, `__word_size__`, `__target_isa__` | A local or global declaration compiles, but every use still reads the built-in value. A function by this name compiles and the program crashes. |
| Statement and type words | `if` `while` `for` `in` `return` `break` `continue` `pass` `switch` `defer` `goto` `debugger` `const` `yield` `raw_asm` `var` `string` `byte` `char` `int` `uint` `bool` `void` `float` `float16` `float32` `float64` `int8`..`int64` `uint8`..`uint64` `function` `constant` `pointer`, and every struct, union, enum or alias name in scope | Accepted as variable, function and field names, but `name = ...` cannot start a statement, because the line is parsed as that statement or declaration. Avoid them. |
| Built-in call names | `print`, `println`, `syscall`, `to_json`, `from_json`, `setjmp`, `longjmp` | Usable as locals, but not as function names (`symbol redefined`). |
| Built-in helpers | `input` `read_all` `ints` `lines` `words` `split` `join` `max` `min` `abs` `len` `any` `all` `enum_name` `mul_hi` `mul_wide` `add_carry` | Usable as any name. A user function with the same name defined **before** the call replaces the built-in. See the prelude collision below. |
| Words with a built-in meaning in one position only | `range` `list` `map` `set` `it` and the container pseudo-method names (`push`, `pop`, `keys`, `add`, ...) | Usable as any name. |
| Contextual words | `elif` `else` `case` `default` `import` `struct` `union` `enum` `type` `extern` `export` `c_lib` `c_import` `kernel` `generator` `thread_local` `operator` `message` `fn` | Usable as ordinary names. |
| Runtime-internal prefixes | `__w_*`, `__ci_*`, and any other `__`-prefixed name | Used by the compiler's runtimes and the C importer. Do not declare them. |

**Runtime-name collisions.** Every program auto-imports the container
runtime (`structures/hash_table.w`, `structures/w_list.w`) and what it
imports. Their top-level names share the program's single namespace, so
a user function or global with the same name is `symbol redefined`. A
local variable may shadow one. Certain features import further modules
on demand, after the user's files, and so reserve their names too:

| Trigger | Modules imported on demand |
|---|---|
| `print`, `println`, `input`, `read_all`, `ints`, `lines`, `words`, `split`, `join`, `max`, `min`, `abs`, `len` (unless shadowed) | `structures/prelude.w`, `lib/lib.w`, `lib/hex.w`, `lib/__arch__/<arch>/context.w` |
| f-strings | the above plus `structures/string.w` and `lib/assert.w` |
| `var` | `structures/w_dynamic.w`, `lib/lib.w`, `lib/hex.w`, `lib/__arch__/<arch>/context.w` |

So a program that calls `println` cannot also define `input`, `ints`,
`read_all`, `strlen`, `atoi` or any other `lib/lib.w` name. The
authoritative list for a given program is
`./bin/wv2 [arch] symbols --json file.w`: every record whose `file` is
not one of the program's own files is reserved for it. The lists below
are what the probe printed on x86. x64 prints the same names, and arm64
lacks the `SYS_*` constants, `linux_syscall`, `sys_futex` and
`sys_set_tid_address` but adds `arm64_at_fdcwd`, `arm64_ppoll` and
`arm64_timespec`.

<details>
<summary>Names every program reserves (x86, 318 public names)</summary>

- `structures/hash_table.w` only `__`-prefixed names (63)
- `structures/w_list.w` only `__`-prefixed names (56)
- `lib/memory.w` (15 names): `free`, `malloc`, `malloc_backend`, `malloc_backend_free`, `malloc_backend_realloc`, `malloc_debug_env_check`, `malloc_debug_mode`, `malloc_force_debug_mode`, `malloc_hook_free`, `malloc_hook_malloc`, `malloc_hook_realloc`, `malloc_hook_set`, `malloc_init_mode`, `malloc_mode_determined`, `realloc`
- `lib/memory_freelist.w` (21 names): `freelist_free`, `freelist_malloc`, `freelist_realloc`, `malloc_bin_clear`, `malloc_bin_count`, `malloc_bin_map_hi`, `malloc_bin_map_lo`, `malloc_bin_push`, `malloc_bins`, `malloc_bins_init`, `malloc_grow`, `malloc_heap_end`, `malloc_heap_extend`, `malloc_heap_ptr`, `malloc_heap_total`, `malloc_low_bit`, `malloc_mmap_mode`, `malloc_next_bin`, `malloc_oom_notice`, `malloc_scan_steps`, `malloc_size_bin`
- `lib/memory_debug.w` (24 names): `debug_alloc_report_leaks`, `debug_fatal`, `debug_free`, `debug_guard_warned`, `debug_malloc`, `debug_page_size`, `debug_pages_for`, `debug_quarantine_budget`, `debug_quarantine_bytes`, `debug_quarantine_cursor`, `debug_quarantine_reclaim_if_needed`, `debug_quarantine_reclaim_to`, `debug_realloc`, `debug_tbl_append`, `debug_tbl_capacity`, `debug_tbl_count`, `debug_tbl_ensure_capacity`, `debug_tbl_find`, `debug_tbl_freed`, `debug_tbl_mmap_failed`, `debug_tbl_ptr`, `debug_tbl_region`, `debug_tbl_region_size`, `debug_tbl_size`
- `lib/stack_trace.w` (64 names): `print_stack_trace`, `st_base`, `st_byte`, `st_call_site`, `st_chain`, `st_chain_fp`, `st_class`, `st_code_address`, `st_collect_from`, `st_cstr_eq`, `st_cursor`, `st_dline_lo`, `st_dline_size`, `st_entry_name`, `st_entry_value`, `st_file_found`, `st_file_name`, `st_find_base`, `st_func_entry`, `st_init`, `st_init_macho`, `st_int16`, `st_int32`, `st_is_main_frame`, `st_is_return`, `st_jmp_buf`, `st_line_found`, `st_line_lookup`, `st_machine`, `st_macho`, `st_macho_func_entry`, `st_mincore_vec`, `st_out_set`, `st_page_readable`, `st_prologue_len`, `st_range_readable`, `st_scan`, `st_scratch`, `st_scratch_ensure`, `st_sh_word`, `st_skip_cstr`, `st_sleb`, `st_slide`, `st_state`, `st_strtab_lo`, `st_symbol_address`, `st_symtab_count`, `st_symtab_entsize`, `st_symtab_lo`, `st_text_hi`, `st_text_lo`, `st_uleb`, `st_unwind`, `st_unwind_exact`, `st_uses_frame_pointers`, `st_word`, `st_write_cstr`, `st_write_dec`, `st_write_frame`, `st_write_hex`, `stack_trace_collect`, `stack_trace_file`, `stack_trace_line`, `stack_trace_symbol`
- `lib/syscalls_linux_x86.w` (84 names): `at_fdcwd`, `at_symlink_nofollow`, `brk`, `chdir`, `chmod`, `chown`, `clock_gettime`, `close`, `create_file`, `dup2`, `epoll_create1`, `epoll_ctl`, `epoll_event_bytes`, `epoll_event_data_offset`, `epoll_wait`, `eventfd2`, `execve`, `exit`, `fchownat`, `fdatasync`, `fork`, `fsync`, `getcwd`, `getdents`, `getgid`, `getpid`, `getuid`, `kill`, `lchown`, `linux_time`, `madvise`, `memfd_create`, `mkdir`, `mmap`, `mprotect`, `munmap`, `nanosleep`, `open`, `pipe`, `poll`, `read`, `readlink`, `rename`, `rmdir`, `rt_sigaction`, `seek`, `statx`, `symlink`, `sys_bind`, `sys_clock_gettime`, `sys_clone`, `sys_connect`, `sys_fcntl`, `sys_flock`, `sys_ftruncate`, `sys_futex`, `sys_getrandom`, `sys_getsockname`, `sys_inotify_add_watch`, `sys_inotify_init1`, `sys_inotify_rm_watch`, `sys_ioctl`, `sys_listen`, `sys_mincore`, `sys_nanosleep`, `sys_poll`, `sys_pread`, `sys_ptrace`, `sys_pwrite`, `sys_recv`, `sys_recvfrom`, `sys_recvmsg`, `sys_sendmsg`, `sys_sendto`, `sys_set_tid_address`, `sys_setsockopt`, `sys_sigaltstack`, `sys_socket`, `sys_socketpair`, `thread_exit`, `unlink`, `utimensat`, `wait4`, `write`
- `lib/__arch__/x86/syscalls.w` (79 names): `SYS_ACCEPT`, `SYS_BIND`, `SYS_BRK`, `SYS_CHDIR`, `SYS_CHMOD`, `SYS_CLOCK_GETTIME`, `SYS_CLONE`, `SYS_CLOSE`, `SYS_CONNECT`, `SYS_CREAT`, `SYS_DUP2`, `SYS_EPOLL_CREATE1`, `SYS_EPOLL_CTL`, `SYS_EPOLL_WAIT`, `SYS_EVENTFD2`, `SYS_EXECVE`, `SYS_EXIT`, `SYS_EXIT_GROUP`, `SYS_FCHOWNAT`, `SYS_FCNTL`, `SYS_FDATASYNC`, `SYS_FLOCK`, `SYS_FORK`, `SYS_FSYNC`, `SYS_FTRUNCATE`, `SYS_FUTEX`, `SYS_GETCWD`, `SYS_GETDENTS`, `SYS_GETGID`, `SYS_GETPID`, `SYS_GETRANDOM`, `SYS_GETSOCKNAME`, `SYS_GETUID`, `SYS_INOTIFY_ADD_WATCH`, `SYS_INOTIFY_INIT1`, `SYS_INOTIFY_RM_WATCH`, `SYS_IOCTL`, `SYS_KILL`, `SYS_LISTEN`, `SYS_LSEEK`, `SYS_MADVISE`, `SYS_MEMFD_CREATE`, `SYS_MINCORE`, `SYS_MKDIR`, `SYS_MMAP`, `SYS_MPROTECT`, `SYS_MUNMAP`, `SYS_NANOSLEEP`, `SYS_OPEN`, `SYS_OPENAT`, `SYS_PIPE`, `SYS_POLL`, `SYS_PREAD64`, `SYS_PTRACE`, `SYS_PWRITE64`, `SYS_READ`, `SYS_READLINK`, `SYS_RECVFROM`, `SYS_RECVMSG`, `SYS_RENAME`, `SYS_RMDIR`, `SYS_RT_SIGACTION`, `SYS_SENDMSG`, `SYS_SENDTO`, `SYS_SETSOCKOPT`, `SYS_SET_TID_ADDRESS`, `SYS_SOCKET`, `SYS_SOCKETPAIR`, `SYS_STATX`, `SYS_SYMLINK`, `SYS_TIME`, `SYS_UNLINK`, `SYS_UTIMENSAT`, `SYS_WAIT4`, `SYS_WRITE`, `linux_syscall`, `mmap_fd`, `sys_accept`, `sys_openat`
- `lib/win32_stubs.w` (16 names): `CloseHandle`, `CreateFileA`, `CreatePipe`, `CreateProcessA`, `FindClose`, `FindFirstFileA`, `FindNextFileA`, `GetExitCodeProcess`, `GetStdHandle`, `PeekNamedPipe`, `SetHandleInformation`, `TerminateProcess`, `WaitForSingleObject`, `os_windows`, `win_callback`, `win_crash_filter_install`
- `code_generator/integer.w` (14 names): `load_i`, `load_int`, `load_int16`, `load_int32`, `load_int64`, `load_int8`, `load_ptr`, `save_i`, `save_int`, `save_int16`, `save_int32`, `save_int64`, `save_int8`, `save_ptr`

</details>

<details>
<summary>Names reserved by the on-demand runtimes (x86)</summary>

- `lib/lib.w` (66 names): `GETCHAR_BUF_CAPACITY`, `GETCHAR_EOF`, `GETCHAR_MAX_FD`, `GETCHAR_READ_ERROR`, `_main`, `atoi`, `cstr_invalid_utf8`, `cstr_utf8_length_or_die`, `ends_with`, `environ_ptr`, `file_size`, `from_hex`, `getchar`, `getchar_buf_addr`, `getchar_checked`, `getchar_kernel_pos`, `getchar_limit`, `getchar_pos`, `getchar_reset`, `getchar_seek`, `getchar_unbuffered`, `getchar_unbuffered_checked`, `hex`, `hex_word`, `intstrlen`, `ip4_from_string`, `itoa`, `load_word`, `open_or_create`, `print`, `print2`, `print_char0`, `print_color`, `print_color_bg`, `print_error`, `print_hex`, `print_hex0`, `print_int`, `print_int0`, `print_int_v1`, `print_n`, `print_string`, `print_string0`, `print_words`, `println`, `println2`, `put_char`, `put_error`, `putc`, `reverse`, `reverse_n`, `save_word`, `starts_with`, `str_from_cstr`, `str_replace`, `strappend`, `strclone`, `strcmp`, `strcpy`, `strjoin`, `strlen`, `strncpy`, `translate_syscall_failure`, `utf8_scan`, `verbosity`, `write_string`
- `structures/prelude.w` (3 names, plus 20 `__`-prefixed): `input`, `ints`, `read_all`
- `structures/string.w` (14 names, plus 12 `__`-prefixed): `string_append`, `string_append_bytes`, `string_append_char`, `string_append_int`, `string_append_string`, `string_builder`, `string_builder_to_string`, `string_clear`, `string_equals`, `string_free`, `string_from`, `string_new`, `string_new_sized`, `string_reserve`
- `structures/w_dynamic.w` (1 name, plus 26 `__`-prefixed): `print_var`
- `lib/assert.w` (11 names): `assert1`, `assert_bytes_equal`, `assert_contains`, `assert_equal`, `assert_equal_hex`, `assert_has`, `assert_lacks`, `assert_strings_equal`, `assert_substring`, `assert_text`, `asserts`
- `lib/hex.w` (10 names): `hex_bytes`, `hex_decode`, `hex_decode_char`, `hex_decode_into`, `hex_decode_loose`, `hex_digit`, `hex_digit_upper`, `hex_encode`, `hex_fixed`, `hex_put_byte`
- `lib/__arch__/x86/context.w` (3 names): `print_registers`, `print_stack`, `register_context`

</details>

## Known divergences

Current behaviour that is surprising, contradicts a document, or is
arguably a bug. This reference does not change the compiler; each row
records what happens today.

| # | Divergence | Status |
|---|---|---|
| 1 | README's language snapshot lists "relational (with chaining)", but comparisons do not chain: `3 > 2 > 1` is 0. | README wording to be fixed. |
| 2 | `-2147483648` is +2147483648 on 64-bit targets, and decimal literals from 2147483648 to 4294967295 wrap negative with no warning (hex literals warn). | Typed literals are planned (type_system_p0 milestone 1). |
| 3 | Numeric literal tokens accept trailing letters and `_`, and the decimal decoder treats them as digits: `1_000` is 57000, `0o17` is 6317, `12abc` is 17451 and `0b1_0` is 98. Hex skips non-hex characters, so `0x7FFF_FFFF` happens to work. | Should be a lexical error. |
| 4 | `cast(T, e)` to a narrower integer type does not truncate or extend the value in a register (`cast(uint8, -1) + 0 == -1`). type_system_p0 milestone 2 says numeric casts define truncation and sign extension. | |
| 5 | `cast(T*, p)` removes `const` silently; type_system_p0 milestone 2 says it must not. | |
| 6 | `T*` → `const T*` warns; type_system_p0 milestone 6 says it is implicit. | |
| 7 | `int` → `enum` is silent; type_system_p0 milestone 10 says it needs a cast. Enumerators are global names, not `color.red`. | #532 |
| 8 | `bool b = n` for a non-constant `int` crashes the program. | #525 |
| 9 | A struct store whose size is not a multiple of the word overwrites the bytes after it (`s[0] = v` for a 5-byte struct corrupts `s[1]`). | #524 |
| 10 | `true`, `false`, `__word_size__` and `__target_isa__` can be declared as names, but every use still reads the built-in, and a function of that name crashes. | |
| 11 | Global constant expressions are checked in 32-bit arithmetic even on 64-bit targets, but the same expressions in a function body wrap at the word width without a diagnostic. | |
| 12 | A program that uses `println` cannot define `input`, `ints`, `read_all` or any `lib/lib.w` name, while a program without it can. | Module privacy is missing (fundamentals audit). |
| 13 | Redeclaring a local in the same block is silently accepted. | |
| 14 | `uint32` comparisons differ by target, because `uint32` is the unsigned word on x86 but a zero-extended sub-word type on x64. | Documented in [type_system_p0.md](projects/type_system_p0.md#unsigned-operations). |
| 15 | Division by zero and `INT_MIN / -1` trap on the x86 family but return a value on arm64. | |
