# Protocol and Server Ergonomics

Design and decision record for the protocol/server work: syscall
primitives (poll, recv/recvfrom, nonblocking, sleep, monotonic clock),
Content-Length framing, JSON-RPC 2.0 helpers, a poll-based event loop,
container ergonomics, and the `to_json` / `from_json` builtins that tie
W structs to JSON ("type <=> json" from `docs/todo.txt`).

## Layering

Everything stacks bottom-up; each layer is usable on its own:

1. **Syscalls** (`lib/__arch__/x86/syscalls.w`, `lib/__arch__/x64/syscalls.w`):
   `sys_poll`, `sys_recv`/`sys_recvfrom` (via the `socketcall` multiplexer
   on x86, native syscalls on x64), `sys_fcntl`, `sys_nanosleep`,
   `sys_clock_gettime`. Seed-safe syntax only, since these files are
   compiled by the committed seed.
2. **Primitives**: `lib/poll.w` (`pollfd`, `poll_wait`, `poll_single`),
   `lib/net.w` (`socket_recv`, `socket_recv_from_ipv4`,
   `socket_set_nonblocking`), `lib/time.w` (`time_monotonic_ms`,
   `sleep_ms`). The x86 monotonic clock wraps a 32-bit millisecond value
   (~24 days); the event loop compares deadlines with wraparound-safe
   subtraction.
3. **Framing** (`lib/framing.w`): `frame_reader` buffers a fd and parses
   `Content-Length: N` headers exactly like the MCP reference server
   (`tools/mcp/w_toolchain_mcp.w`, originally written in Python):
   case-insensitive header names, extra headers tolerated, short reads
   and multiple messages per read handled.
   `frame_take_buffered_message` extracts complete messages without
   blocking, which is what the event-loop path uses; `frame_read_message`
   blocks until a full message arrives.
4. **JSON-RPC 2.0** (`lib/json_rpc.w`): message builders and validation,
   the standard error codes, a `hash_map`-based method dispatch table
   (`type jsonrpc_handler = fn(json_value* params, void* ctx) ->
   json_value*` — no closures, so context travels as an explicit
   pointer), `jsonrpc_serve_blocking` for stdio-style servers, and
   `jsonrpc_attach_connection` / `jsonrpc_serve_listener` for multiplexed
   servers on the event loop. A handler returning 0 produces -32603;
   unknown methods produce -32601; notifications get no reply.
5. **Event loop** (`lib/event_loop.w`): poll(2)-based fd watches plus a
   monotonic-clock timer list (one-shot and repeating, cancellable by
   id). The poll timeout is the nearest timer deadline, so timeouts and
   cancellation need no signals or threads: a per-request timeout is a
   timer that fails the request and is cancelled when the reply arrives.

Tests: `poll_test`, `framing_test`, `event_loop_test`, `json_rpc_test`
(plus x64 variants where the runtime supports them; see below).

## Container ergonomics

Exposed capabilities the runtimes already had or could add with seed-safe
syntax (`structures/hash_table.w`, `structures/w_list.w`):

- `m.remove(key)` / `s.remove(key)` / `s.add(key)` for map/set.
- `for k, v in m` two-variable map iteration (scalar values bind by
  value, struct values bind through a pointer).
- `l.insert(i, v)`, `l.remove(i)`, `l.clear()` for `list[T]`.
- `x in l` membership for lists (content compare for `char*` elements).

Grammar changes live in `grammar/hash_builtin.w`, `grammar/list_builtin.w`,
`grammar/for_statement.w`, `grammar/relational_expr.w`; the parser
generator grammar `tests/parser_generator/w.pg` learned the two-variable
`for` form.

## type <=> json: `to_json` / `from_json`

```
import structures.json

struct point:
	int x
	int y

point p
p.x = 3
json_value* v = to_json(p)        # {"x":3,"y":0}
point* q = from_json(point, v)    # 0 when the value does not decode
```

### Mechanism: descriptors, not reflection or code synthesis

The compiler is single-pass with no AST, so the same philosophy as the
built-in containers applies: monomorphize per struct type at parse time,
run through a small shared runtime. At the first use site per struct
type, the compiler walks its type table (`type_get_field_name_at`,
`type_get_field_type_at`, `type_get_field_offset_at`) and emits a static
descriptor blob into the code stream behind an unconditional jump: field
names, offsets, kinds, widths, and addresses of nested descriptors. The
builtin then lowers to a call:

- `to_json(expr)` -> `__w_json_encode(descriptor, addr)`; the argument
  may be a struct value or a single-level struct pointer.
- `from_json(T, expr)` -> `__w_json_decode(descriptor, value)`, returning
  a freshly allocated zeroed `T*` or 0.

Descriptors are cached per canonical type index, so every use of the same
struct shares one blob. The interpreter loop lives in
`structures/json_codec.w` (descriptor layout documented there); an
alternative — emitting per-field encode/decode machine code inline —
would have duplicated code at every call site and required loop emission
for list fields, for no measurable win.

### Supported field types

`int` and fixed-width ints (signed), `bool`, `char*`, `string`, nested
structs (by value, recursion is impossible because struct fields must be
already-declared types), and `list[T]` of any supported type including
nested lists and structs. Null `char*`/`string`/`list` fields encode as
JSON null and decode back to 0.

Rejected at compile time with a diagnostic: floats (`structures/json.w`
has no float support yet), `map`/`set` (JSON keys would constrain K to
strings; deferred), arrays, slices, unions, enums-as-enums aside, and
pointer fields other than `char*`.

Decode is strict: a missing member or a type mismatch fails the whole
decode and returns 0, so a JSON-RPC handler can answer -32602 invalid
params. Extra members are ignored. Interior allocations made before the
failing field are not individually freed (v1 accepts this leak on the
error path).

### On-demand runtime import

`structures/json_codec.w` is not auto-imported into every program the way
`structures/hash_table.w` is: only programs that use the builtins pay for
it (and for its `structures/json.w` dependency). Importing a module
mid-expression would splice its code into the current function, so the
compiler records that the builtin was used plus a backpatch chain for the
call sites, and the drivers (`link_impl` in `compiler/compiler.w`, the
REPL, wdbg) call `json_codec_finish_import()` at a top-level boundary
after user code is compiled. Call sites must have
`import structures.json` in scope — the builtins produce and consume
`json_value*`, so the type has to exist at the call site anyway.

### JSON-RPC payoff

Handlers decode typed params and encode typed results
(`test_jsonrpc_typed_params_round_trip` in `lib/json_rpc_test.w`):

```
json_value* handle_scale(json_value* params, void* ctx):
	rpc_scale_params* p = from_json(rpc_scale_params, params)
	if (p == 0):
		return 0
	...
	return to_json(result)
```

## x64 status

All syscall wrappers and the compiler-side codec emission are
word-size-clean and build for both targets. `poll_test`, `framing_test`,
`net_test` and `time_test` run on x64. `json_test`, `json_codec_test`,
`json_rpc_test` and `event_loop_test` are x86-only for now: the
`structures/` container stack they sit on (`json.w`, `hash_map.w`,
`array_list.w`) has pre-existing x64 bugs (e.g. `json_object` +
`json_stringify` segfaults on x64 with no codec involvement), tracked
separately from this work.

## Out of scope / follow-ons

General reflection (a `type.w` meta-type), epoll, floats in
`structures/json.w` (blocks float fields in codecs), `map[string, V]`
codec fields, and an HTTP client. The W-native MCP server this stack was
built for has since landed as `tools/mcp/w_toolchain_mcp.w`.
