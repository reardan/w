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
- `break`, `continue`, `&&`, `||`, `!`, unary `-`, hex literals, and string escapes
- hash map, string builder, array list, linked list, and format helpers
- basic REPL via `make repl`
- DWARF line-number information for gdb

Current major open areas:
- REPL recovery after compile errors
- deeper type compatibility checks and import-scoped type metadata
- full x64 self-hosting
- WebAssembly backend
- built-in debugger / web UI
