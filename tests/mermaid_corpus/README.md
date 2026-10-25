# Pinned upstream Mermaid conformance corpus

Every Mermaid code block (```` ```mermaid ````, ```` ```mermaid-example ````,
```` ```mermaid-nocode ````) of the upstream syntax documentation of one tagged
Mermaid release, one example per file, with its current native classification.
Issue [#821](https://github.com/reardan/w/issues/821).

## Source and license

- Release: tag [`mermaid@12.2.0`](https://github.com/mermaid-js/mermaid/tree/mermaid%4012.2.0/packages/mermaid/src/docs/syntax)
  of [mermaid-js/mermaid](https://github.com/mermaid-js/mermaid).
- Pages: the 33 syntax pages in that release's docs sidebar
  (`packages/mermaid/src/docs/.vitepress/config.ts`, ZenUML included) plus
  `railroad.md`, which ships in the syntax directory without a sidebar entry.
  Each was fetched from
  `https://raw.githubusercontent.com/mermaid-js/mermaid/mermaid%4012.2.0/packages/mermaid/src/docs/syntax/<page>.md`.
- The examples are Copyright (c) Knut Sveidqvist and the Mermaid contributors,
  used under the MIT License; the upstream license text is vendored verbatim in
  [`LICENSE.mermaid`](LICENSE.mermaid). The example bodies are unmodified apart
  from removing the fence's own indentation and trailing blank lines.

## Layout

| Path | Contents | Written by |
| --- | --- | --- |
| `<family>/<page>_<nnn>.mmd` | Example `nnn` (1-based, in page order) of `<page>.md`; `<family>` comes from the diagram header, falling back to the page's family | `tools/mermaid_corpus_extract.py` |
| `index.txt` | `path<TAB>page<TAB>fence line` for every example | `tools/mermaid_corpus_extract.py` |
| `LICENSE.mermaid` | Upstream MIT license | `tools/mermaid_corpus_extract.py` |
| `manifest.txt` | `path<TAB>class<TAB>observed[<TAB>note]` per example | `./wbuild mermaid_corpus_update` |

## Classification

`./wbuild mermaid_corpus_test` (in `./wbuild tests`; source
`libs/extras/mermaid/corpus_test.w`) reads every example with `mm_read`, the
exact path the `wmermaid` CLI uses (frontmatter, `%%{init}%%` directives and
the 1 MiB source budget included), renders it with `mm_render` and exports
`mm_svg`. The observation is one of:

| Observed | Meaning | Class |
| --- | --- | --- |
| `ok` | parses, renders a non-empty scene and an SVG document | `supported`, or `partial` when a note records a known difference |
| `noscene` / `empty` / `nosvg` | parses, but renders no scene, an empty scene, or no SVG | `partial` |
| `error <line:column: message>` | rejected (including family and 1 MiB budgets) | `unsupported` |

For `error` entries the recorded text only has to be a substring of the actual
diagnostic, so it may be trimmed by hand (for example to drop the position).
`supported` means accepted and rendered, not visually identical to upstream.

The test fails on any drift, in both directions: a REGRESSION (worse class), an
IMPROVED example (still recorded as unsupported/partial), a CHANGED diagnostic,
examples missing from or stale in the manifest, an inconsistent class, and a
stale counts block in `docs/projects/mermaid_compatibility.md`.

## Updating after a feature lands

    ./wbuild mermaid_corpus_update

rewrites `manifest.txt` from current behavior and regenerates the
`<!-- corpus-counts:begin -->` block of `docs/projects/mermaid_compatibility.md`.
Notes (4th field) and still-matching diagnostic substrings are kept; an example
recorded `partial` with a note stays `partial` while it still renders. Review
the diff: every REGRESSION must be explained, and examples that became
`supported` but still render a known difference deserve a `partial` class with a
short note (edit the line, then re-run the update to refresh the counts).

## Reviewing an upstream inventory bump

1. Check the new release's docs sidebar (`.vitepress/config.ts`) and syntax
   directory for added, renamed or removed pages and update `DOCS` (and
   `HEADERS` for new diagram headers) in `tools/mermaid_corpus_extract.py`.
2. `python3 -I tools/mermaid_corpus_extract.py --tag mermaid@<version>`
   (or `--from-dir <checkout>/packages/mermaid/src/docs/syntax` offline). It
   deletes and rewrites every `.mmd`, `index.txt` and `LICENSE.mermaid`.
3. `./wbuild mermaid_corpus_update`, then review `git diff --stat` and the
   manifest diff: renumbered examples show up as moved lines, new examples as
   new lines, and newly unsupported examples are the syntax the release added.
4. Update the tag in this README, the inventory baseline and family rows in
   `docs/projects/mermaid_compatibility.md`, and the per-family references.
