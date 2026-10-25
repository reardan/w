# wfmt: the rewriting formatter

`bin/wfmt` rewrites W source in one canonical style (issue #716). It goes
beyond `w check --fix`, which only repairs whitespace at line ends and in
indentation: wfmt also normalizes the spacing inside each line.

```sh
./wbuild wfmt                       # builds bin/wfmt
./bin/wfmt file.w                   # formatted file on stdout
./bin/wfmt - < file.w               # stdin to stdout
./bin/wfmt -w a.w b.w               # rewrite in place
./bin/wfmt --check $(git ls-files '*.w')   # list unformatted files, exit 1 if any
```

Exit status: 0 when everything is formatted (or was rewritten), 1 when
`--check` found an unformatted file, 2 on a usage, read or parse error.
A file that does not parse is left untouched.

## Design

**Base: the ParserGenerator W grammar, not the compiler's tokenizer.**
The compiler is single-pass and its tokenizer drops comments and
whitespace as it goes, so it cannot rebuild a file. The ParserGenerator's
generated lexers are lossless (`docs/projects/parser_generator.md`,
"Lossless token stream"): whitespace and comments are hidden-channel
tokens with byte spans, and `tests/parser_generator/w.pg` already parses
every tracked `.w` file (`parser_generator_w_test`). The `wfmt` target
generates `bin/wfmt_w_parser.w` from `w.pg` and links it into the tool,
so wfmt follows every syntax change that `w.pg` must already track.

**Roles from the AST, spacing from the roles.** `tools/wfmt_lib.w`
parses the file, walks the AST and gives each code token a role from its
kind and its parent rule: binary operator, unary prefix (`unary_op`),
postfix `++`/`--`/`?`, pointer `*` (`pointer_part`), call/index/generic
bracket, grouping parenthesis (`grouped_expr`, `paren_expression_opt`),
block brace, block or pair colon, slice colon, ternary `?`/`:`,
`operator+` name, and so on. Then it re-emits the token stream, deciding
the gap between each pair of neighbours on a line from their roles.

**Whitespace only, checked.** Tokens are never added, dropped, reordered
or moved to another line. Before returning, wfmt lexes its own output and
compares the non-whitespace tokens with the input's; on a mismatch it
reports an error and writes nothing. The only inputs known to hit this
are diagnostic fixtures that end inside an unterminated string or char
literal with no final newline, where adding the newline would extend the
literal. A gap the rules want empty
gets a space anyway when the two tokens would otherwise lex as one (`- -b`
stays apart instead of becoming `--b`, a word next to a word or a string
prefix, a number next to `.`).

## Canonical style

- Indentation is tabs. A space indent of at least four columns becomes a
  tab per four columns (the `check --fix` rule; a narrower one, as in
  aligned continuation lines, is left alone).
- No trailing whitespace (comments included), LF line endings, exactly
  one final newline. Blank lines at the start and end of the file go, and
  a run of more than two blank lines shrinks to two (the `check --fix`
  blank-line rules).
- One space: around binary, assignment and comparison operators, `:=`,
  `->` and the ternary `?`/`:`; after `,` and `;`; after a block, label,
  named-argument or map-entry `:` that has something after it; between
  words (`return x`, `if (x)`, `int* p`).
- No space: inside `()` `[]` and literal `{}`; before `,` `;` `:` and a
  closer; around `.`; after a unary prefix (`-x`, `!ok`, `*p`, `&v`);
  before a postfix `++`/`--`/`?`; before a call, index or generic bracket
  (`f(x)`, `a[i]`, `list[int]`, `cast(int, x)`); before a pointer `*`
  (`char**`); in `operator+(`.
- A slice `:` is tight between simple bounds (`a[1:n]`, `a[-3:f(x)]`) and
  spaced when a bound contains a binary operator (`a[i * w : j * w]`).
- Brace blocks get inner spaces: `{ return 1; }`.
- Comments keep their text and their place. A trailing comment keeps its
  original separation from the code (so aligned comment columns survive),
  or gets one space if it had none.
- Strings, char literals and `asm` function bodies are left alone.

### What wfmt does not do

- **No line wrapping or joining.** Long lines stay a `check --lint`
  finding (`line-too-long`). Breaking a line moves the line numbers the
  binary records (DWARF and the runtime's stack-trace table), and W's
  newline-sensitive grammar only allows a break in a few places.
- **No token rewrites**, such as dropping redundant condition
  parentheses (the `condition-parens` lint) or adding blank lines between
  definitions. Both change more than whitespace; the first could be a
  later opt-in mode once the token-preservation check knows about it.
- It does not reflow or re-indent comments; a comment line indented with
  spaces is re-indented by the space-indent rule like any other line.

### Opting out

- A line containing `nolint` is copied verbatim, as `check --fix` does.
- Every line from a `# wfmt: off` comment through the next
  `# wfmt: on` comment is copied verbatim (whitespace fixtures and
  hand-aligned tables).

## Where the permissive grammar needed help

`w.pg` is syntax-only and deliberately permissive, and a few of its
parses do not match the compiler's. wfmt only uses the parse for
spacing, so a misparse costs at most a space, and these cases keep the
canonical spacing:

- `name_token` accepts every keyword, so `if (a) || (b):` parses as a call
  of `if` followed by `|| (b)`. wfmt keeps the space between a control
  keyword (`if`, `elif`, `else`, `while`, `for`, `in`, `switch`, `case`,
  `return`, `yield`, `defer`) and `(`.
- `range` is a keyword, so with a variable named `range`,
  `a / range * n` parses `* n` as a prefix operator. A prefix operator
  straight after an operand keeps its original spacing.
- `gap_many` lets an expression continue across a line break, so a line
  starting `*q = ...` can read as `... * q`. An operator that opens a line
  keeps hugging its operand.
- Factored rule prefixes share leaf nodes with abandoned alternatives,
  so a leaf's `parent` link can name a node outside the final tree. wfmt
  passes the parent down its own walk instead.

Building wfmt also fixed a lexer bug the formatter exposed: the shared
`number` matcher split `1.5e-05` into `1.5e`, `-`, `05`
(`libs/extras/parser_generator/lexer.w`), which made wfmt write
`1.5e - 05`. Decimal exponents with a sign are now one token; a hex
literal's `e` stays a digit (`0x1e-5` is still a subtraction).

## Verification

`./wbuild wfmt_test` (in `tests`) runs two checks:

- `tests/wfmt_test.w`: one case per rule, each formatted, compared with
  the expected text, and formatted again to check idempotence.
- `tools/wfmt_tree_check.w`: the same-binary check on the compiler
  itself. It copies `bin/wv2 deps w.w` (the compiler's whole import
  closure, 266 files) to `bin/wfmt_tree/` with only the blank-line rules
  applied (`wfmt --lines-only`), compiles that copy of `w.w` for x86 and
  x64, formats every file in place (checking idempotence on the way),
  compiles again, and requires byte-identical binaries. The blank-line
  rules are applied to the reference because the lines they drop move
  recorded line numbers; everything else wfmt does must not change a
  byte. 37 of the 266 files get more than blank-line changes.

When this shipped, the whole tree was also checked once by hand, the
same way: every tracked `.w` file in a copy of the repository formatted
(176 of 2876 files change; the 5 unterminated-literal fixtures are
refused by the token check), and all 454 `tests/*_test.w` programs that
compile in a copy compiled to identical binaries before and after.

## Follow-ups

- Formatting the tree itself (`bin/wfmt -w $(git ls-files '*.w')`) is a
  separate, mechanical PR, after which a `wfmt --check` CI gate can keep
  it formatted. Whitespace fixtures (trailing-whitespace, space-indent,
  CRLF, missing-newline tests) need `# wfmt: off` or an exclusion list
  first.
- A thin editor wrapper (`textDocument/formatting` over `wfmt -`) belongs
  with the LSP/MCP integrations in w-private `wtools/`.
