# Building and linking libraries

Issue #625 adds separately built W libraries on x64 Linux and uses a
shared or static library for the compiler implementation. The ordinary bootstrap and its
fixpoint checks continue to build a single executable.

## Shared libraries

Mark the public functions with `export`:

```w
import lib.lib

export int add(int a, int b):
	return a + b
```

Build the library without an application `main`:

```sh
./bin/wv2 x64 --shared add.w -o bin/libadd.so
```

A consumer declares the exported signature with `extern`:

```w
import lib.lib

extern int add(int a, int b)

int main(int argc, int argv):
	println(itoa(add(20, 22)))
	return 0
```

Then compile and run it:

```sh
./bin/wv2 x64 --link=./bin/libadd.so consumer.w -o bin/consumer
./bin/consumer
```

`--link=<path>` is repeatable and also works while building a shared
library, so a library can depend on another library. The ELF loader
resolves the dependency at process startup. Paths containing a slash
resolve relative to the process's working directory unless absolute;
keep the example in the project root when running it. Existing `c_lib`
imports continue to work.

An exported function keeps its ordinary W calling convention for calls
inside its library. Its public symbol uses the System V x64 ABI through a
generated adapter. Word-sized integers and pointers, `float32`,
`float64`, and void returns are supported. On x64 a W `int` is 64 bits;
C consumers must use a corresponding 64-bit integer type. Structs passed
or returned by value, variadic functions, and exported globals are outside
this interface. The shared output uses position-independent code and
loader relocations; it requires the x64 Linux target.

Each library has its own W runtime state. An ordinary export does not
execute the executable startup function or application `main`. Interfaces
that need the command-line environment must initialize that state
explicitly, as `compiler_main` does. Ownership of memory crossing a
library boundary should remain with the library that allocated it.

## Static libraries

The same exports can be packaged as a compiled W archive:

```sh
./bin/wv2 x64 --static add.w -o bin/libadd.wa
./bin/wv2 x64 --link=bin/libadd.wa consumer.w -o bin/consumer_static
./bin/consumer_static
```

A `.wa` is W's `WLIB64` compiled archive format, containing machine code,
data, exported symbols, and relocation records. It is not a Unix `ar`
archive and cannot be passed to a system C linker. Linking copies the
compiled code and data into the consumer and patches its references;
the archive is not needed at runtime. The consumer still declares the
exported functions with `extern`, using the same signatures as for the
shared build. Both artifact kinds preserve a library's private runtime
state.

Static producers currently reject dynamic imports, thread-local storage,
and profiling instrumentation. Shared producers also reject thread-local
storage and `extern` data objects. Native library output is limited to
x64 Linux with its Linux syscall ABI. Static libraries cannot be linked
into `--syscall-abi=vmcall` programs. Other target backends keep their existing executable output.

## Source-owned build targets

Put a library declaration in its source, or in its `.w.wbuild` sidecar:

```w
# wbuild: library=add kind=shared arch=x64
```

Use `kind=static` instead to produce `bin/libadd.wa`. The shared target
produces `bin/libadd.so`. `out=` overrides the output path;
`flags=` supplies additional compiler flags. Connect the consumer by the
library target's name:

```w
# wbuild: binary=consumer arch=x64 link=add
```

`link=` adds the producer dependency, the library artifact as an input,
and the corresponding compiler link argument. Repeating it links several
libraries. This makes the build order and cache invalidation follow the
artifact dependencies. Ordinary `dep=` still expresses a dependency
without adding a library to the compiler command. Independent library
targets can build in parallel with the usual `./wbuild -j N` option.

## Compiler subsystem build

```sh
./wbuild compiler_shared
./bin/wcompiler_shared --version
./bin/wcompiler_shared x64 tests/hello.w -o bin/hello_shared
./bin/hello_shared
./wbuild compiler_shared_test
./wbuild compiler_static
./bin/wcompiler_static --version
./wbuild compiler_static_test
```

`compiler/cli.w` owns the `wcompiler` library target and exports
`compiler_main(argc, argv)`. It brings together the compilation,
analysis-command, and debugger implementation. `tools/compiler_shared.w`
is the separate executable launcher and imports that entry point from
`bin/libwcompiler.so`. The usual `w.w` launcher calls the same function
through source imports, preserving bootstrap portability.

The same implementation also owns `wcompiler_static`, producing
`bin/libwcompiler_static.wa`. `compiler_static` links it into
`bin/wcompiler_static`. This executable contains its compiled library and
runs without that archive or any shared-library loader at runtime.

This is the first compiled subsystem boundary: the executable launcher
and compiler implementation are separate artifacts. The parser, symbol
tables, and code generators still share internal state within the
compiler library. `compiler_main` is a process entry point: invoke it once
with the original process `argc` and `argv`. It is not a reentrant or
parallel compilation API, and existing commands can exit the process.

`compiler_shared_test` exercises version reporting, check/deps/symbols,
compilation and execution of a program, and compilation of the compiler
itself through the shared entry point. `compiler_static_test` likewise
compiles a program and the compiler itself, then copies only the static
executable into an empty temporary directory and runs it there.
