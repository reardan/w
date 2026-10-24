# `w inspect`: ELF sections, symbols and function disassembly

`w inspect` reads a compiled ELF file without running it or invoking binutils.
The architecture comes from the ELF header, so an x86 host can inspect x64 and
ARM64 compiler output, including ARM64 disassembly without qemu.

```sh
./bin/wv2 tests/inspect_probe.w -o bin/example
./bin/wv2 inspect bin/example
./bin/wv2 inspect bin/example --sections
./bin/wv2 inspect bin/example --symbols
./bin/wv2 inspect bin/example --disasm inspect_answer
./bin/wv2 arm64 tests/inspect_probe.w -o bin/example_arm64
./bin/wv2 inspect bin/example_arm64 --disasm main
```

With no selectors the command prints sections and symbols. `--sections`,
`--symbols` and `--disasm FUNCTION` may be combined and placed before or after
the file name. `--help` (or `-h`) prints usage. `--` ends option parsing, for
example `w inspect -- -unusual-file-name`.

Section rows show index, name, ELF section type, virtual address, file offset
and size. Symbol rows show address, size, ELF symbol type, binding, section
index and name; both the ordinary symbol table and dynamic symbol table are
included. Type, binding and section indices use the ELF numeric values. Sizes
are decimal and addresses/offsets hexadecimal. A stripped file still supports
section inspection, but named disassembly requires an available symbol.

Disassembly uses `libs/asm`'s x86/x64 and ARM64 decoders and formatters. It
resolves the function's section before translating its address to a file
offset, and handles section-relative symbols in relocatable ELF objects.
Only symbols in executable sections are eligible. A symbol with size zero
extends to the next symbol in that section, or the end of the section if no
later symbol exists. Unknown encodings retain the decoder's raw-byte/word
notation; a truncated instruction tail is shown as `.byte`. This is a linear
listing of the function's bytes, so inline literal data may appear as
instructions. Relocations in object files are not applied.

Supported inputs are little-endian ELF32 and ELF64. Disassembly supports
ELF32/i386, ELF64/x86-64 and ELF64/AArch64. Other machines can still expose
sections and symbols. Mach-O, PE, big-endian ELF and extended ELF section
numbering are not supported. Like the existing in-tree binary reader, this
initial command accepts only fields within 32 bits, which covers W's ELF
output. A nonzero upper word in a 64-bit offset, address or size produces an
explicit diagnostic instead of truncation, including when the inspector runs
on a 64-bit host. File-backed ranges must fit the loaded file and the host's
positive `int` range.

Invalid arguments, unreadable or malformed files, missing functions and
unsupported disassembly architectures return exit status 1 with a diagnostic
on stderr. Successful inspection and help return 0. Tables and bounded NUL
terminators are validated before names or instruction bytes are accessed.

Implementation: `tools/inspect.w`, dispatched by `compiler/cli.w`. The
`inspect_test` and `inspect_64_test` targets cover the parser, malformed ELF
inputs, symbol ranges, CLI errors and host-side disassembly of all three
architectures.
