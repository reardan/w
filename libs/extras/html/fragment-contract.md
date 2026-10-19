# HTML fragment foundation and integration contract

`html_parse_fragment(data, length, context, scripting)` and
`html_parse_fragment_with_limits(data, length, context, scripting, limits)`
return an independently owned `html_document`. Its root has kind
`HTML_FRAGMENT` (11), no parent, and the parsed children directly underneath it.
The source and recognized lowercase HTML context name need only live through the
call. Release the result once with `html_document_free`, including failure and
partial-tree results. Existing whole-document parse ownership is unchanged.

This first slice implements context initialization for title/textarea RCDATA,
style/xmp/iframe/noembed/noframes raw text, script data, plaintext, and noscript
with the supplied scripting flag. Initial text-state fragments have no last
start-tag token: matching context end-tag spellings stay text. Newline/reference/
NUL processing uses the existing explicit-length tokenizer. A normal plaintext
start tag now consumes literal text through EOF as well.

The html context delegates to the existing document insertion recovery and
returns the synthesized head/body children under a fragment root; discarded
document-level doctypes are never exposed as fragment children. The synthetic
container remains allocated until document teardown and counts against limits.
The div/body/head and scripting-disabled noscript contexts provide the existing
bounded HTML tree recovery without document wrappers, with adjacent text
coalescing, ignored document tags/doctypes and optional p/list-item closure.
They do not establish full in-body/in-head algorithm coverage. The select context
uses the modern in-body algorithm with explicit fragment select/input checks; see
[the separate modern profile](upstream/modern/README.md). Unsupported
contexts (including tables, template and foreign names) return
`failed=1` and a diagnostic. Full insertion modes, foster parenting, formatting
reconstruction/adoption agency, templates, namespaces and exact parse-error
recovery remain mandatory implementation work. Depth/node/token/input caps are
unchanged; fragment nodes count against those caps.

Whole-document and supported fragment parsing now share HTML scope boundaries
for paragraph and block closure, special-element barriers for generic end tags,
and list-item start/end recovery. Unmatched paragraph end tags synthesize a bounded
empty paragraph. Adjacent text tokens coalesce in document trees too. This does
not complete formatting reconstruction, table recovery, foreign namespaces,
form pointers, or the remaining in-body rules.

A leading accepted doctype precedes the HTML element in the document child list.
Consumers must locate the HTML element by kind/name rather than assuming the
first child is an element. Fragment extraction discards document-level nodes
while retaining their allocations until document teardown. The native doctype
still retains declaration text; public/system identifier parsing and quirks-mode
selection are mandatory follow-up work.

The unchanged `upstream/tests4.dat`, `blocks.dat` and `inbody01.dat` corpora come
from html5lib-tests commit `9329e64694e7835d0dcff9811e22856ef6ad16f9`, before tree
fixtures migrated to WPT. The pinned original license and format documentation
accompany them. `manifest.json` records file hashes; `inventory.json` inventories
every .dat file and all fragment contexts at that revision. The adapter selects
all 61 cases from those three files, runs both scripting modes (122 variants),
and retains the other 1,735 cases as NOT_RUN in the 1,796-case denominator. The
selected document cases have no scripting-dependent behavior; this does not
establish a document scripting-flag API. Run
`./wbuild html_tree_test html_fragment_test html_fragment_64_test html_fragment_upstream_test html_test html_64_test`.
Parse-error lists are retained unchanged but are not asserted by the tree-output
adapter. The native fixture serializer currently supports the selected simple
doctype and ASCII attribute-name profile, not full namespace/doctype serialization.
Reports freeze exact HEAD revisions, fresh UTC evidence kind, driver/adapter and
upstream hashes before execution, reject mid-run source/driver changes, and preserve every case and mode on missing-driver/timeout/error.
This is a bounded profile, never a claim of full html5lib or WPT conformance.

Win uses one native allocation identity per node and one rooted JS wrapper per
node per realm. DocumentFragment moves splice children, leave the fragment
empty and detached, and preserve existing child wrappers/listeners. Documents
own detached nodes until realm teardown. Fragment pre-insert validates receiver,
child kinds, reference membership, cycles, depths and traversal budgets before
changing links; failure must not empty the fragment or partially move children.
Cross-document adoption, native DOM prototypes/Web IDL descriptors, observers,
shadow roots and Document child insertion remain mandatory follow-up work.

Parser suspension contract for the later streaming implementation: a parser
instance owns source buffers, tokenizer state, insertion mode/open elements,
active formatting elements, and document lifetime; no token or raw source pointer
may survive a released chunk. Feed/end-of-input and script-blocked are separate
states. A parser-blocking script yields a stable node identity and generation;
only the owning page generation can resume or cancel it. Cancellation unwinds
parser state before freeing the document; resumption cannot replay an executed
script. document.write input goes to the parser insertion point, not to an
already-finalized tree. **These streaming/suspension APIs are a contract only and
are not implemented by the synchronous fragment entry points.**

Before wiring innerHTML, Win must add an explicit inert-script preparation bit
so generic resource discovery cannot execute scripts created by fragment parsing.
Newly adopted parsed nodes must be transferred to the document allocation list
before releasing the temporary fragment document; source spans alone do not
retain source memory. This slice deliberately does not expose innerHTML yet.
