# Native Mermaid agentflow diagrams

The W engine recognizes `agentflow-beta` from the pinned
[Mermaid 12.2.0 agentflow reference](https://github.com/mermaid-js/mermaid/blob/mermaid%4012.2.0/packages/mermaid/src/docs/syntax/agentflow.md).
It adds domain roles and YAML metadata to the native compound-graph model,
so source read/write/edit, native preview and SVG export share one parser and
layout. Connector declarations describe systems; rendering them does not invoke
those systems.

Implemented syntax:

- Optional header direction `TB`, `TD`, `BT`, `LR`, or `RL`.
- Node identifiers, bracket labels and `@{ … }` metadata
  (`libs/extras/mermaid/yaml_meta.w`). The metadata is the YAML subset
  upstream loads with js-yaml's JSON schema: single-line flow mappings,
  multi-line block mappings, nested mappings, block (`- item`) and flow
  (`[a, b]`) sequences, flow mappings, single/double-quoted scalars with
  escapes, `|`/`>` block scalars with `-`/`+` chomping, comments and repeated
  keys (the last one wins). Quoted and block scalars are read by the same
  readers as frontmatter (`mm_yaml_quoted` / `mm_yaml_block_text` in
  `config.w`), in a metadata mode that reads control escapes as a space. Plain scalars resolve to null, booleans, integers and
  floats exactly as in the JSON schema; everything else is a string.
- The shape inventory of upstream `shapes.ts`: the six domain aliases (task,
  tool, input, decision, refdoc, action), the canonical names they stand for
  (`roundedRect`, `subroutine`/`subprocess`/`subproc`/`framed-rectangle`,
  `lean-right`, `diamond`, `lin-doc`/`lined-document`, `hexagon`/`hex`) and
  `collapsedGroup`. Any other shape name, and any other inline bracket shape,
  is coerced to the default rounded rectangle, which upstream reports as a
  non-blocking diagnostic. `[[…]]` resolves to tool, `{{…}}` to action and
  `{…}` to decision, as upstream does.
- Sequence `-->`, reference `-.-`, and failure `--x` edges; edge chains, pipe
  labels, and inline labels such as `check -- yes --> publish`.
- Edge IDs written before the operator (`a e1@--> b`) and edge metadata
  statements (`e1@{ curve: step, animate: true, animation: fast }`). IDs must be
  unique and may not name a node. `curve` accepts `linear`, `step`/`stepBefore`/
  `stepAfter` and the smooth curves (`basis`, `bumpX`, `bumpY`, `cardinal`,
  `catmullRom`, `monotoneX`, `monotoneY`, `natural`, `rounded`).
- Nested `flow … end` containers, per-container directions, metadata and labels.
  `view: collapsed` folds a container into one `collapsedGroup` summary node;
  `view: expanded` is the default. `algorithm` (for example `elk.layered`) is
  stored on the container.
- `global … end` declarations that remain at the top level when other flows
  reference them. A flow declared globally still owns its children.
- `connector id[label]` declarations and opaque connector metadata.
- Shared accessibility metadata, Markdown wrappers and the supported frontmatter
  title handling from the native source compatibility layer.

`mm_node.role` exposes the domain role, `global_node` records global ownership,
and `metadata` owns `mm_property` entries: `key`, `value` and `type`
(`MM_VALUE_STRING`, `INT`, `FLOAT`, `BOOL`, `NULL`, `MAP` or `LIST`). A scalar's
value is its text; a mapping or sequence is stored as canonical JSON. Edges carry
`id`, `metadata` and `curve` (`MM_CURVE_*`). Unknown metadata keys are preserved.
The upstream-reserved keys `__proto__`, `constructor`, and `prototype` are
stripped at every nesting level. Shape, label (`null` keeps the bracket label),
`view` and `curve` affect the visible diagram; contracts, model names,
instructions and connector references remain available to callers without being
executed. `labelType` must be `text`, `string` or `markdown`.

Presentation:

- Collapsed containers (`mm_agent_project` in `agentflow.w`): the outermost
  collapsed ancestor wins, descendants are hidden, edges that cross the boundary
  end on the summary node and edges whose endpoints fold into the same summary
  disappear, as upstream. The scene keeps one bounds entry per original node;
  hidden nodes report their summary's bounds.
- `curve` is rendered statically: `linear` draws a straight diagonal leg, step
  curves an orthogonal route and the smooth curves a cubic bend. Each route ends
  with an axis-aligned leg so arrowheads and failure crosses keep their
  orientation.
- `animate` and `animation` are validated (`true`/`false`, `fast`/`slow`) and kept
  as edge metadata, but the native renderer and SVG export are static: no
  animation runs.
- `algorithm` is recorded but layout is native W; it does not reproduce ELK
  placement.

Limits are 64 unique metadata keys per node or edge, 32 levels of YAML nesting,
32 nested containers/global blocks, the shared 1024-node/edge limits and the
1 MiB source budget. Updating an existing key at the metadata limit is supported.
Invalid or unsupported input produces a source diagnostic and no partial scene;
the original source can still be saved.

Remaining compatibility: the `agentflow.*` configuration keys (`nodeSpacing`,
`rankSpacing`, …) belong to the configuration layer, themes, and upstream's
non-blocking semantic warnings (coerced shapes are accepted silently).

```sh
./wbuild wmermaid wmermaid_editor agentflow_test agentflow_64_test
bin/wmermaid svg examples/mermaid/agentflow.mmd bin/agentflow.svg
bin/wmermaid svg examples/mermaid/agentflow-collapsed.mmd bin/agentflow-collapsed.svg
bin/wmermaid_editor examples/mermaid/agentflow.mmd
```

Tests cover roles, YAML value types and canonical JSON, nested reserved keys,
the shape inventory and coercion, edge IDs/metadata and curve rendering,
collapsed projection, metadata ownership and duplicate keys, nesting and
globals, connector references, all three edge semantics, visible failure
endpoints, limits, source edits, XML escaping and every byte-prefix truncation.
Both x86 and x64 are checked with guard allocator leak detection. Every upstream
12.2.0 documentation example parses and renders except the one that sets
`agentflow.nodeSpacing`/`rankSpacing` configuration.
