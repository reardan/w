# c_import: broad C header import

`c_import "soname" "header path"` preprocesses a C header, parses it, and
lowers its declarations into the compiler's type table, symbol table and
dynamic-linking registry, so W code can call shared-library functions and
use the header's types and constants directly:

```w
c_import "libc.so.6" "/usr/include/stdio.h"

int main():
	puts("hello")
	fflush(0)      # W exits via raw syscall; flush libc buffers yourself
	return 0
```

The pipeline has three stages, all implemented in W and compiled into the
compiler itself:

1. **Preprocess** (`libs/extras/c_preprocessor/`): full macro expansion with
   Prosser hide sets, conditionals, `#include` resolution (with
   `#include_next` and `#pragma once`), and predefined platform macros
   keyed off the compile target's word size. Small stub headers under
   `libs/extras/c_preprocessor/include/` provide the compiler-owned
   headers (`stddef.h`, `stdarg.h`, `stdbool.h`) including the glibc
   `__need_*` protocol.
2. **Parse** (`libs/extras/c_import/generated_c_parser.w`, generated from
   `tests/parser_generator/c.pg`): a PEG grammar for the declaration
   subset of C plus enough of the expression and statement grammar to get
   through real glibc headers: abstract declarators, function pointers,
   casts, `sizeof`, bit-fields, and `static inline` function bodies.
   Parse errors report the furthest token any parse attempt reached.
3. **Import** (`libs/extras/c_import/importer.w`): walks the translation
   unit and lowers typedefs, structs/unions/enums, and `extern` function
   declarations. Enum values and array sizes go through an AST
   constant-expression evaluator (operator precedence, `sizeof`, casts,
   character literals, references to earlier enumerators). Object-like
   macros whose expansion is an integer expression are exported as global
   constants (`ENOENT`, `SEEK_END`, `O_CREAT`, ...).

`make tests` imports broad raw libc/system headers on both targets through
`tests/c_import_libc_test.w`: `stdio.h`, `stdlib.h`, `string.h`, `unistd.h`,
`fcntl.h`, `errno.h`, `time.h`, `signal.h`, `ctype.h`, `math.h`, `dirent.h`,
`locale.h`, and `sys/stat.h`. The same test checks imported function calls,
macro constants, symbol-collision handling, and C struct layout against a
kernel-filled `struct stat`.

## Layout

W's own structs pack fields with no padding, so the importer lays imported
structs out explicitly: fields are aligned C-style (natural alignment
capped at the target word size, matching the i386 and x86-64 SysV ABIs)
by inserting `__ci_pad_*` filler fields, arrays become an element field
plus a filler, and the struct is tail-padded to its alignment. C `int`
maps to a 32-bit type on both targets; C `long` follows the target word.
`tests/c_import_libc_test.w` cross-checks the resulting layout against the
kernel via `fstat` on both targets.

## Symbol collisions

Broad headers overlap each other and W's own library, so the importer is
"first definition wins" everywhere:

- functions already defined (W code compiled earlier, or an earlier
  `c_import`) are skipped, so W's `open`/`read`/`write`/`close`/`malloc`
  wrappers keep priority over libc's;
- typedef, struct and enum-constant redefinitions are skipped;
- macro constants are only exported when the name is entirely new.

Imported functions become **weak** dynamic symbols: glibc headers declare
functions the library does not export (`alloca`, `crypt`, ...), and weak
binding lets the loader start the program with those GOT slots null
instead of failing. Explicit `extern` declarations remain strong, so a
typo there still fails at load time.

## Known limitations

- Variadic functions (`printf`), old-style declarations and `static
  inline` bodies are declared-but-skipped; calling them requires a
  fixed-arity wrapper.
- Float/double arguments and returns pass through the integer FFI shims,
  so math functions import but do not follow the floating-point ABI yet.
- `extern` data objects (`stdin`, `environ`) are not imported (functions
  only).
- Bit-field members are skipped (layout drift within the bit-field region
  of a struct).
- A cast of a bare typedef name applied to a literal (`(size_t) 42`)
  parses as a call shape; casts with keyword types or pointer/abstract
  declarators are fully supported.
