# HTML named character reference data

`entities.json` is an unmodified snapshot downloaded on 2026-10-15 from
[WHATWG's HTML entity data](https://html.spec.whatwg.org/entities.json).
It contains 2,231 spellings, including 106 legacy spellings without semicolons.
Its SHA-256 is
`d741d877ac77c4194c4ad526b5b4a19aef8dfe411ab840a466891cdbb9f362e6`.
This content hash pins the exact input; builds never fetch the live URL.

Copyright © WHATWG (Apple, Google, Mozilla, Microsoft). The upstream
[license](https://github.com/whatwg/html/blob/main/LICENSE) is retained verbatim
in `WHATWG-LICENSE.txt`: CC BY 4.0, with BSD 3-Clause licensing for portions
incorporated into source code. `entities.w` is such a source-code incorporation.
The W implementation follows the HTML Standard's
[character reference states](https://html.spec.whatwg.org/multipage/parsing.html#character-reference-state),
including the numeric-reference control substitution table.

`python3 tools/html_entities.py` validates the input hash and value schema, sorts
the names, removes their leading ampersands, encodes values as UTF-8, and emits
immutable packed name/value records with little-endian 16-bit offsets. It adds
no aliases and does not infer missing-semicolon permissions. Every output
includes the input hash and license attribution. Normal W compilation imports
the checked-in `entities.w` and requires neither Python nor external files.

`python3 tools/html_entities.py --check` performs the same transformation without
writing and fails on stale generated output or a changed input hash. The
conventional x86/x64 entity tests include this check and independently read
`entities.json` for expected values through W's JSON parser.

For an intentional update, download and review the new data, update the SHA-256
in the generator and this file, retain the applicable upstream license, then
regenerate and run the HTML/entity targets and full repository suite. Review
changes to spellings, scalar values, legacy counts, and the generated maximum
name length. No network request is part of regeneration or testing.
