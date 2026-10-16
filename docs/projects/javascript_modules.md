# Bounded JavaScript module foundation

`libs/extras/javascript/modules.w` evaluates an acyclic graph of modules using
validated parser nodes and the existing runtime AST evaluator. It is a standalone
host API. The Win browser integrates it through `win/src/win/modules.w`, which
prefetches a bounded source graph asynchronously before invoking the synchronous
resolver. Network policy remains the browser host's responsibility.

## Supported subset

- Named imports, including aliases: `import {value as local} from './dep.js'`.
- Side-effect imports: `import './setup.js'`.
- Const declaration exports, including binding patterns: `export const {value} = object`.
- Function declaration exports: `export function f() { return 1; }`.
- Local export aliases of const, function, or imported bindings: `export {value as answer}`.
- Ordinary module bodies within the existing runtime's syntax subset, with
  separate strict environments, private lexical bindings, and undefined
  top-level `this`.

Exported `let` and `var` declarations remain rejected, including indirect local
export clauses. Function declarations may be reassigned inside their module;
imports are live aliases and observe the current exported value. Import bindings
remain read-only in the importer. Exported objects retain shared identity and
mutable properties, and exported functions retain their closure environments.
This is not general ECMAScript module support.

Default/namespace imports, default/star exports, `export ... from`, cycles,
dynamic import, import metadata, and unsupported body syntax
produce explicit failures. No source rewriting or synchronous approximation of
`await` is performed.

The implementation extracts import/export metadata from the validated parser
structure and lowers executable statements directly into owned AST nodes. It
never edits JavaScript source text or reparses generated JavaScript.

## Host interface

```w
struct js_module_source:
	char* identifier
	char* source
	int length

type js_module_resolver = fn(void*, char*, char*) -> js_module_source*

js_modules* js_modules_new(js_runtime* runtime, js_module_resolver* resolver, void* context)
js_module* js_modules_evaluate(js_modules* modules, char* specifier, char* referrer, int budget)
js_module* js_modules_evaluate_async(js_modules* modules, char* specifier, char* referrer, int budget)
js_value* js_modules_export(js_modules* modules, js_module* entry, char* name)
void js_modules_free(js_modules* modules)
```

The resolver receives `(context, specifier, referrer)` and returns a canonical
identifier, source buffer, and byte length, or null on failure. Its result and
strings may be borrowed until the next resolver call. Identifiers must be valid
NUL-terminated strings; the source must provide at least `length` readable bytes.
The loader copies the identifier and finishes parsing before calling the resolver
again. Embedded NUL and non-scalar module specifiers are rejected explicitly.

The host controls canonicalization, source acquisition, origin policy, and I/O
limits. Different specifiers resolving to the same identifier share one module
record. Resolution is synchronous and may be called again for cached modules;
module bodies execute at most once. A resolver must continue returning the same
canonical identity to reach the cache. Host callback execution/I/O time is not
bounded by the JavaScript instruction budget. Evaluation and collection cannot
be reentered while the resolver runs.

Evaluation returns a borrowed module record on success and null on failure.
Details are in `runtime.completion`: throw/link/resolution failures use status 2,
resource limits use 5, and invalid/unsupported module syntax or cycles use 6.
A reentrant evaluation returns null without changing the active completion.

The complete reachable graph is parsed and linked before any new module body
runs, so unsupported syntax, cycles, and missing imports do not produce partial
module execution. Dependency bodies then execute in import order. Runtime
exceptions may leave earlier effects visible. Failed module records cache their
completion, including the original thrown value, and are not reevaluated through
another parent or an already-linked parent.

`js_modules_export` returns a borrowed runtime value or null for an unavailable
name, unevaluated module, or foreign record. Root retained values with
`js_runtime_root` across loader destruction or collection. The loader roots each
module's environment and cached exception. Free the loader **before** its borrowed
runtime. Executable ASTs remain runtime-owned, allowing rooted exported closures
to survive loader destruction. Live imported aliases retain their dependency
environments across collection even after the loader has been destroyed. Internal link/execute helpers are not host entry
points.

## Limits and tests

Defaults are 64 unique module records, graph depth 32, 4 MiB cumulative source,
and 256 static import requests per loader. Canonical identifiers are limited to
4096 bytes. Runtime parser, source, AST-count, heap, property, and execution limits
also apply. One execution budget covers dependency linking and all new module
bodies; limits and cached failures are not reset by importing another root.
Create a new loader to retry failed modules. Cached ASTs remain subject to the
runtime's lifetime script-count limit.

Focused validation without running the full suite:

```sh
bin/wv2 x64 check --json tests/javascript/modules_test.w
bin/wv2 x64 --strict tests/javascript/modules_test.w -o bin/javascript_modules_test
bin/javascript_modules_test
W_DEBUG_ALLOC=1 bin/javascript_modules_test
```

The test's build directives register `javascript_modules_test` with the generated
manifest. Tests cover graph caching, aliases, shared identity, private scopes,
strict evaluation, closure lifetime, read-only imports, preflight rejection,
cached failures through different and previously linked parents, reentrancy, and
resource limits. Tests also exercise destructured const exports, function
reassignment observed through imports, and imported closures after loader teardown
and collection.

Win's source cache accepts URL-like specifiers, rejects bare and cross-origin
requests, and resolves relative dependencies against the response URL. It limits
concurrency to three cancellable loaders. Source/graph failures are currently
sticky for the document's module context; there are no import maps or CORS module
fetches. Its integration test executes the unchanged `webgl_env.mjs`,
`accessibility.mjs`, and `mobile_input.mjs`, including `makeEnv` and the event queue.
Top-level await is available through asynchronous evaluation; the original
`wasi_lite.mjs` now loads unchanged: its derived Error class, `super` call,
`instanceof` catch and exact BigInt clock multiplication are exercised together
by `javascript_modules_test`. Passing module preflight does not imply every API used by an uncalled
export (for example `Map` or DOM accessibility operations) is available.


## Asynchronous module evaluation

`js_modules_evaluate_async` opts into validated top-level await and returns a
borrowed module record while its body may still be suspended. The synchronous
API retains the default ES2020 parser profile and rejects top-level await.
Parser clients can explicitly set `js_parse_limits.top_level_await = 1` for a
module; ordinary-function and formal-parameter await early errors remain active.

An asynchronous record exposes `evaluation_promise`, with `state` 2 while
pending, 3 after successful execution, and 4 after failure. Drive existing
`js_runtime_drain_microtasks` checkpoints and inspect the Promise's result.
A rejected module Promise does not itself throw out of a checkpoint. Subsequent
requests for a failed cached module restore its cached error completion.
Exports become available after state 3. Dependencies finish before importer
bodies run, and concurrent roots share a pending dependency's evaluation.
Cycles remain unsupported. The budget covers initial graph loading/execution;
each suspended task preserves its remaining fuel across all later checkpoints.

The loader owns its asynchronous module tasks and tasks spawned during those
bodies. `js_modules_free` cancels them before releasing module records. Cancelled
reactions may remain on a host Promise but their cleared tokens cannot access
freed records. See `javascript.md` for bounded stack/root retention and terminal
cancellation semantics.
