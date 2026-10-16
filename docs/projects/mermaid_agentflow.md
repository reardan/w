# Native Mermaid agentflow diagrams

The W engine recognizes `agentflow-beta` from the pinned
[Mermaid 12.2.0 agentflow reference](https://github.com/mermaid-js/mermaid/blob/mermaid%4012.2.0/packages/mermaid/src/docs/syntax/agentflow.md).
It adds domain roles and scalar metadata to the native compound-graph model,
so source read/write/edit, native preview and SVG export share one parser and
layout. Connector declarations describe systems; rendering them does not invoke
those systems.

Implemented syntax:

- Optional header direction `TB`, `TD`, `BT`, `LR`, or `RL`.
- Node identifiers, bracket labels and `@{ key: value }` metadata, including
  multiline blocks and repeated-key updates. Double-quoted text and plain scalar
  text are supported; metadata values are exposed as owned strings.
- The six domain shapes: task, tool, input, decision, refdoc and action. Their
  corresponding canonical shape names also work, as do rectangle and circle.
- Sequence `-->`, reference `-.-`, and failure `--x` edges; edge chains, pipe
  labels, and inline labels such as `check -- yes --> publish`.
- Nested `flow … end` containers, per-container directions, metadata and labels.
- `global … end` declarations that remain at the top level when other flows
  reference them. A flow declared globally still owns its children.
- `connector id[label]` declarations and opaque connector metadata.
- Shared accessibility metadata, Markdown wrappers and the supported frontmatter
  title handling from the native source compatibility layer.

`mm_node.role` exposes the domain role, `global_node` records global ownership,
and `metadata` owns `mm_property` key/value entries. Unknown metadata keys are
preserved. The upstream-reserved keys `__proto__`, `constructor`, and `prototype`
are stripped. Node shape and label metadata affect the visible diagram; scalar
contracts, model names, instructions and connector references remain available
to callers without being executed.

Limits are 64 unique metadata keys per node, 32 nested containers/global blocks,
the shared 1024-node/edge limits and the 1 MiB source budget. Updating an existing
key at the metadata limit is supported. Invalid or unsupported input produces a
source diagnostic and no partial scene; the original source can still be saved.

Remaining compatibility includes general YAML metadata (nested objects, arrays,
multiline strings and typed scalar interpretation), edge IDs and edge metadata,
collapsed containers, ELK algorithm selection, animated/curved edges, the full
canonical shape inventory, themes, and upstream semantic warning diagnostics.
The supported shapes use the native renderer's deterministic geometry; the
reference document is drawn as a ruled document box. Layout is native W and
does not reproduce ELK placement. Presentation keys such as `view`, `algorithm`,
`curve` and animation settings currently report an unsupported diagnostic.

```sh
./wbuild wmermaid wmermaid_editor agentflow_test agentflow_64_test
bin/wmermaid svg examples/mermaid/agentflow.mmd bin/agentflow.svg
bin/wmermaid_editor examples/mermaid/agentflow.mmd
```

Tests cover roles, metadata ownership and duplicate keys, nesting and globals,
connector references, all three edge semantics, visible failure endpoints,
limits, source edits, XML escaping and every byte-prefix truncation. Both x86
and x64 are checked with guard allocator leak detection. Native preview and SVG
export are exercised with the example above. The non-configuration upstream
examples parse except the explicitly unsupported collapsed-container example.
