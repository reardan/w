# Bounded JavaScript module loader

`libs/extras/javascript/modules.w` evaluates ES2020 source text module graphs,
cycles included, using validated parser nodes and the existing runtime AST
evaluator. It is a standalone host API. The Win browser integrates it through
`win/src/win/modules.w`, which prefetches a bounded source graph asynchronously
before invoking the synchronous resolver. Network policy remains the browser
host's responsibility.

## Records, linking and evaluation

The loader is built on `libs/extras/javascript/module_graph.w`'s records: each
module parses into a `js_module_record` (ParseModule's import, local, indirect
and star export entries), and every import and namespace key is resolved with
its ResolveExport (`js_module_graph_resolve_binding`). The runtime `js_module`
is the record's `[[HostDefined]]` and adds the environment, namespace object
and status. The two files share one set of types: `js_module_source` and
`js_module_resolver` are aliases of the graph's `js_module_text` and
`js_module_loader`, and there is no separate runtime name list.

- **Link** (sec-moduledeclarationlinking). Loading parses the whole unloaded
  graph. Then every unlinked reachable record is validated (each import and
  indirect export resolves to one binding: missing and ambiguous names are
  SyntaxErrors). Next every module environment is initialized: var bindings,
  let/const/class bindings in their TDZ, the `*default*` binding, and function
  declarations, all instantiated before any body runs. Last come the import
  bindings, in passes, so they work in either order inside a cycle: first
  namespace imports, then named imports as live read-only aliases of the
  resolved binding.
- **Evaluate** (sec-moduleevaluation). InnerModuleEvaluation's depth-first
  walk in request order, with DFS index/ancestor bookkeeping. A strongly
  connected component (a cycle) is marked evaluated when its root finishes.
  Reading an alias whose binding is not initialized yet throws a
  ReferenceError (TDZ), for example a cyclic import read before the exporting
  module ran. A throw marks every module still on the DFS stack failed with
  the same error, and that error is cached.

## Supported subset

- Named, default (`import x from`), namespace (`import * as ns from`) and
  side-effect imports, with aliases.
- `export` of `var`, `let`, `const` (binding patterns too), function and class
  declarations. `export {a as b}` local clauses. `export {x} from`,
  `export * from` and `export * as ns from` (ES2020) re-exports.
- `export default` of a named or anonymous function or class declaration, or of
  an expression. Anonymous defaults are named `"default"`.
- Module namespace objects (sec-module-namespace-exotic-objects): null
  prototype, `@@toStringTag` `"Module"`, and sorted export names. The names
  come from `js_module_namespace_names`: ambiguous star names are left out and
  `default` is never star-exported. Each name is a live, non-configurable
  alias (accessor tag 2, as for imported environment bindings), and reading one
  in its TDZ throws a ReferenceError, also through `Object.getOwnPropertyDescriptor`
  and super property assignment. Every `[[Set]]` and new property definition
  is rejected (a TypeError in module code). There is one namespace object per
  module.
- Ordinary module bodies within the existing runtime's syntax subset, with
  separate strict environments, private lexical bindings, and undefined
  top-level `this`.

Imports are live aliases that observe the current exported value and are
read-only in the importer. Exported objects keep their shared identity and
mutable properties, and exported functions keep their closure environments.

Not supported, and failing explicitly: dynamic `import()`, `import.meta`,
top-level await, generator/async default exports (or any body syntax) outside
the runtime subset, and post-ES2020 module syntax (string export names, import
attributes, source and defer phases). Namespace keys are ordered by UTF-8
bytes. That is the spec's UTF-16 code unit order, except between supplementary
characters and U+E000..U+FFFF. There is no `Object.keys`/`Reflect` view of a
namespace, because those built-ins are outside the bounded realm. Sloppy-mode
host scripts that hold a namespace object reject writes silently, as the spec
requires.

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
js_value* js_modules_export(js_modules* modules, js_module* entry, char* name)
js_value* js_modules_namespace(js_modules* modules, js_module* entry)
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
Details are in `runtime.completion`: throw/link/resolution failures use status 2
(a link failure throws a SyntaxError), resource limits use 5, and
invalid/unsupported module syntax uses 6.
A reentrant evaluation returns null without changing the active completion.

The complete reachable graph is parsed and linked before any new module body
runs, so unsupported syntax and unresolvable imports do not produce partial
module execution. Dependency bodies then execute in depth-first request order.
Runtime exceptions may leave earlier effects visible. Failed module records
cache their completion, including the original thrown value, and are not
reevaluated through another parent or an already-linked parent. A link failure
is cached on the module that caused it: the unloadable or invalid source and
its partially loaded importers, or the record whose import or re-export does
not resolve. Other records loaded by the same attempt stay unlinked and can
link through another root, as in the spec.

`js_modules_export` resolves the name like an import and returns a borrowed
runtime value. It returns null for an unavailable, ambiguous or uninitialized
name, an unevaluated module, or a foreign record. `js_modules_namespace` returns
a linked module's namespace object. Root retained values with
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
cached failures through different and previously linked parents, reentrancy,
resource limits, cycles (TDZ, link-time function instantiation, DFS order and a
throw failing the whole cycle), default and namespace imports, namespace object
behavior, `export *` and `export * as ns` live bindings, and ambiguous star
names. `javascript_module_graph_test` covers ResolveExport's resolved bindings,
and the Test262 upstream-harness profile runs the pinned
`test/language/module-code/` cases
([test262/README.md](../../tests/javascript/test262/README.md)). Tests also exercise destructured const exports, function
reassignment observed through imports, and imported closures after loader teardown
and collection.

Win's source cache accepts URL-like specifiers, rejects bare and cross-origin
requests, and resolves relative dependencies against the response URL. It limits
concurrency to three cancellable loaders. Source/graph failures are currently
sticky for the document's module context; there are no import maps or CORS module
fetches. Its integration test executes the unchanged `webgl_env.mjs`,
`accessibility.mjs`, and `mobile_input.mjs`, including `makeEnv` and the event queue.
The original `tools/web/index.html` still needs top-level await; the original
`wasi_lite.mjs` additionally needs classes, `super`, `instanceof`, and BigInt
arithmetic. Passing module preflight does not imply every API used by an uncalled
export (for example `Map` or DOM accessibility operations) is available.
