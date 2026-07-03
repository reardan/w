# cc500 changed for the basis of a new language
Modified version of the cc500 compiler from http://homepage.ntlworld.com/edmund.grimley-evans/cc500/

I've added the following features:
- Python-style whitespace syntax with colon and tabs
- Elimination of semicolons
- Addition of single hash as line comments
- Added the rest of the relational operators <=, >, >=
- multiplicative_expr including * / %
- improved error handling and messaging
- self-host fixpoint verification via `make verify`
- `-o` output path support
- pointer-aware `&`, `*`, `[]`, and struct field access
- struct field metadata, mixed-width fields, and `new type()` allocation
- `for int i in range(...)` with optional start/end/step
- `break`, `continue`, `&&`, `||`, `!`, unary `+`/`-`, hex literals, and string escapes
- relational chaining and C-style unary precedence
- deeper type compatibility warnings for assignments, initialization, arguments, and returns
- constructor-style `new type(args)` and by-value struct parameters
- hash map, string builder, array list, linked list, and format helpers
- basic REPL via `make repl`, including compile-error recovery
- DWARF line-number information for gdb
- built-in debugger via `make wdbg`: `./bin/wdbg file.w` traps on `debugger`
  statements into a continue/registers/stack/line command loop
- `lib/args.w` command-line argument parsing helpers

Current major open areas:
- import-scoped type metadata
- REPL local persistence between entries
- full x64 self-hosting
- WebAssembly backend
- debugger stepping and `w --debug` driver integration / web UI
