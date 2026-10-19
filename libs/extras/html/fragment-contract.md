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

The div/body/head and scripting-disabled noscript contexts provide the existing
bounded HTML tree recovery without document wrappers, with adjacent text
coalescing, ignored document tags/doctypes and optional p/list-item closure.
They do not establish full in-body/in-head algorithm coverage. Unsupported
contexts (including html, tables, select, template and foreign names) return
`failed=1` and a diagnostic. Full insertion modes, foster parenting, formatting
reconstruction/adoption agency, templates, namespaces and exact parse-error
recovery remain mandatory implementation work. Depth/node/token/input caps are
unchanged; fragment nodes count against those caps.

The unchanged `upstream/tests4.dat` corpus comes from html5lib-tests commit
`9329e64694e7835d0dcff9811e22856ef6ad16f9`, before tree fixtures migrated to WPT.
The pinned original license and format documentation accompany it. `manifest.json`
records file hashes; `inventory.json` inventories every .dat file and all fragment
contexts at that revision, including unexecuted cases. Run
`./wbuild html_fragment_test html_fragment_64_test html_fragment_upstream_test`.
The upstream adapter compares native trees, reports all nine cases, and preserves
unsupported html context in the denominator. Parse-error lists are retained
unchanged but are not asserted by this initial tree-output adapter. This is a
bounded profile and never a claim of full html5lib or WPT conformance.

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
