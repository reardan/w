# Stateful translator fixtures

`SwiftFin{Lexer,Parser}.g4` and `Properties{Lexer,Parser}.g4` are unmodified
grammars-v4 sources at the commit and SHA-256 hashes in `UPSTREAM.json`.
Swift-fin retains its upstream MIT notice. The properties files have no
file-level license notice in upstream.

`Modes{Lexer,Parser}.g4` and `Priority.g4` are local regression fixtures.
They exercise ordered literal/matcher precedence, implicit literals,
mode-specific token identity, explicit mode-local whitespace, command
ordering, type remapping, and hidden/default channels.

`tests/antlr_to_pg_stateful_test.w` translates the fixtures, generates and
compiles their parsers, and checks runtime token kinds, spans, line/column
positions, source reconstruction, and successful/malformed inputs. The
properties fixture exercises `more` and escaped line continuations.
These are targeted semantic checks, not a whole-language conformance claim.
