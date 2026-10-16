# Pinned ANTLR Unicode data

`generate.py` extracts property intervals and aliases from the exact ANTLR
4.13.2 jar used by the conformance oracle. It also records Java 17
`Character.toLowerCase(int)` / `toUpperCase(int)` mappings, which the reference
ANTLR tool uses for case-insensitive lexer range endpoints. These are simple
case mappings, not locale-dependent or full multi-character case folding.

Run explicitly with Java 17 on PATH:

```sh
PATH=/usr/lib/jvm/java-17-openjdk-amd64/bin:$PATH \
  python3 tools/antlr_unicode/generate.py /path/to/antlr-4.13.2-complete.jar
```

The jar SHA-256 must be
`eae2dfa119a64327444672aff63e9ec35a20180dc5b8090b7a6ab85125df4d76`.
The expected canonical extractor stream SHA-256 is
`866e7aa3a82fa98b5ce14e0b635fb3b25e1d8a51b3e4589026fe5929dcba550d`:
1,185 properties, 2,558 aliases, 2,799 changed case mappings. Normal W builds
and tests read only committed W data; they do not require Java or a network.

Property normalization and range-case behavior match ANTLR 4.13.2's
`UnicodeData.normalize`, `LexerATNFactory`, and `RangeBorderCharactersData`.
The generated property data originates from ANTLR's Unicode/ICU data, while
case mappings are explicitly tied to the Java 17 reference. Regeneration under
another Java major is rejected rather than silently changing semantics.

ANTLR is BSD-3-Clause licensed; its license is reproduced in
`ANTLR-LICENSE.txt`. Unicode data terms are reproduced in `UNICODE-LICENSE.txt`.
