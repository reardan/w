# Stream and File Abstractions

Status: **implemented** (`lib/stream.w`, `lib/file.w`).

Motivation: every consumer of IO in the tree hand-rolled it. `getchar` in
`lib/lib.w` costs one `read(2)` syscall per byte; the line reader existed
twice (`wtest_read_line` in `tools/test_map.w`, `repl_read_line` in
`repl.w`); whole-file read/write lived in the parser generator's
`source_writer.w` instead of `lib/`; and `lib/lib.w` carried a TODO for a
growable whole-file reader that works on sockets. This project gives the
stdlib one buffered stream type and builds line reading, whole-file
helpers, and stdio protocol framing on top of it.

## `lib/stream.w`

```
struct wstream:
	int fd
	char* buffer
	int capacity
	int position   # next unread byte (readers only)
	int limit      # end of buffered data (readers) / pending bytes (writers)
	int eof
	int writable
```

The name follows the `wresult` precedent: short, unlikely to collide with
the many local variables already called `stream`. A wstream is either a
reader or a writer, never both on one struct — a socket used both ways
gets two wstreams over the same fd. The default buffer is 4096 bytes;
`stream_reader_sized`/`stream_writer_sized` shrink it for tests that want
to force refill/flush boundaries every few bytes.

- **Constructors**: `stream_reader(fd)`, `stream_writer(fd)`,
  `stream_open_read(path)`, `stream_open_write(path)` (0 on failure).
- **Reads**: `stream_read_byte` / `stream_peek_byte` (−1 at EOF),
  `stream_read(s, out, n)` (reads larger than the buffer go straight to
  `out`), `stream_read_line(s, string_builder*)` (strips the newline,
  returns 0 only when the input is already exhausted — the
  `wtest_read_line` contract), `stream_read_all(s, string_builder*)`
  (chunked append; works on pipes and sockets, unlike the seek-based
  `file_size()` hack).
- **Writes**: `stream_write`, `stream_write_cstr`, `stream_write_byte`,
  `stream_write_int`, `stream_write_string` (the language `string`
  descriptor), `stream_write_line`, `stream_flush`. Writes at least as
  large as the buffer flush and bypass it.
- **Lifecycle**: `stream_close` (flush + close fd + free) and
  `stream_free` (flush + free, keeps the fd — for the std descriptors).
- **Std handles**: `stdin_reader()` / `stdout_writer()` /
  `stderr_writer()` are lazily-created singletons. Writers buffer:
  callers must `stream_flush()` before exiting, because `_main` exits via
  a raw syscall and nothing flushes automatically (the same reason
  c_import programs need `fflush`, see docs/projects/c_import.md).
- **Framing**: `frame_write(out, data, length)` emits the LSP/MCP stdio
  wire format (`Content-Length: N\r\n\r\n` + N payload bytes);
  `frame_read(in, string_builder*)` parses it back, skipping unknown
  header lines and tolerating bare `\n` terminators. Together with
  `lib/process.w` this is the substrate for a W-native MCP/LSP server
  (docs/projects/ai_tooling.md).

## `lib/file.w`

One-call helpers over streams: `file_read_text(path)` (malloc'd
NUL-terminated contents, 0 when the file cannot be opened),
`file_write_text(path, text)` (create-or-truncate, 1 on success), and
`file_read_lines(path)` (a `list[char*]` of malloc'd lines, 0 on open
failure). Because they read through `stream_read_all`, they also work on
non-seekable inputs like `/proc` files.

## Consumers

- `tools/test_map.w` (wtest) reads stdin through `stdin_reader()` +
  `stream_read_line` and emits through `stdout_writer()`. The refactor
  also replaced its ~30 `int target_*` flag globals and 60-line `strcmp`
  dispatch chain with an ordered `list[char*]` target registry plus a
  `map[char*, int]` of enabled targets, so registering a new build
  target is one `push()` plus a mapping rule.
- `libs/extras/parser_generator/source_writer.w`'s `pg_read_file_text` /
  `pg_write_file_text` are stream-backed. They cannot delegate to
  `lib/file.w` yet: source_writer sits in the compiler's import graph
  (via c_import's importer), so it must stay compilable by the committed
  seed, and `lib/file.w` uses `list[T]`, which the current seed does not
  parse. Fold them into `lib.file` after the next `./wbuild update`.

## Constraints and notes

- No new language syntax, so no `tests/parser_generator/w.pg` change and
  no seed dependency for `lib/stream.w` itself (the seed compiles it
  today; `bin/seedstream` smoke-tested this).
- Sets have no insertion method yet (only literals, `in`, `.length`,
  iteration), which is why wtest uses `map[char*, int]` rather than
  `set[char*]` for the enabled-target set.
- `structures/string.w` allocated its `string_builder` header with
  `malloc(12)`, which undersizes it on x64 (three word-sized fields need
  24 bytes) and corrupted the heap when `stream_read_all` grew buffers in
  `stream_64_test`; it now uses `new string_builder()`, which sizes per
  architecture.
- Error model matches the existing lib style: constructors return 0,
  reads treat a failed `read(2)` as EOF. Recoverable errno plumbing
  (`lib/result.w`) can layer on later without changing the struct.

## Follow-ups

- Move `repl_read_line` (`repl.w`) and the tokenizer's `getc` onto
  `stream_read_byte`/`stream_read_line` — behavior-preserving but
  touches REPL/debugger stdin handling, so it should ride separately.
- `stat`/`unlink`/`rename` wrappers and richer `lib/path.w` helpers.
- A W-native MCP server on `frame_read`/`frame_write` + `lib/process.w`
  (since landed as `tools/mcp/w_toolchain_mcp.w`).

## Tests

`stream_test` / `stream_64_test` (`lib/stream_test.w`): byte/peek/EOF,
reads spanning refills with 3–8 byte buffers, line-reader edge cases
(empty lines, missing trailing newline), `stream_read_all` across
buffers, write-helper output, flush visibility, framing round trips
(including empty and truncated bodies) over files and `socket_pair`.
`file_test` (`lib/file_test.w`): round trips, truncation, missing files,
empty files, `file_read_lines`. `wtest_map_test` pins the wtest CLI
behavior, including the new `lib/stream.w` → `stream_test stream_64_test
file_test` mapping.
