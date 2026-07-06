# Plan: file formats and data persistence

## Target area

Base code directory: `libs/standard/formats/` and `libs/standard/storage/`

Suggested modules:

- `libs.standard.formats.csv`
- `libs.standard.formats.configparser`
- `libs.standard.formats.toml`
- `libs.standard.formats.html`
- `libs.standard.formats.xml`
- `libs.standard.storage.pickle`
- `libs.standard.storage.marshal`
- `libs.standard.storage.sqlite`
- `libs.standard.storage.dbm`

## Python 3.14 reference implementations

Consult these CPython sources first:

- `Lib/csv.py` and `Modules/_csv.c` - CSV dialects and parser state machine.
- `Lib/configparser.py` - INI parsing and interpolation.
- `Lib/tomllib/` - TOML parser behavior.
- `Lib/html/` and `Lib/html/parser.py` - entity escape/unescape and parser.
- `Lib/xml/` and `Modules/pyexpat.c` - XML APIs and Expat-backed parser.
- `Lib/pickle.py` and `Modules/_pickle.c` - object serialization concepts.
- `Python/marshal.c` and `Lib/marshal.py` docs - internal serialization format.
- `Lib/sqlite3/` and `Modules/_sqlite/` - DB-API wrapper over SQLite.
- `Lib/dbm/` - simple key/value database facades.

## Current W starting point

- `structures/json.w` provides a small JSON parser/serializer.
- JSON currently supports objects, arrays, strings, integers, booleans, and null;
  it rejects floating point and exponent numbers.
- `lib/framing.w` and `lib/json_rpc.w` use JSON for protocol work.
- No CSV, config, TOML, XML/HTML, binary serialization, or database wrapper exists.

## Goals

1. Add practical text formats used by tools: CSV, INI, TOML subset.
2. Strengthen JSON or add `formats.json` facade around existing JSON.
3. Add HTML escaping and minimal parsing utilities.
4. Add XML pull/tree parsing only after text/parser foundations mature.
5. Add SQLite via C FFI as the first serious storage backend.

## Non-goals for MVP

- No Python pickle compatibility for arbitrary W values.
- No full XML DOM/SAX suite in the first pass.
- No DB-API compatibility layer until W has richer dynamic typing.
- No custom binary persistence for pointers or process-local addresses.

## API sketch

`formats/csv.w`

- `csv_reader* csv_reader_new(char* text)`
- `csv_reader* csv_reader_new_dialect(char* text, csv_dialect* dialect)`
- `list[char*] csv_read_row(csv_reader* reader)`
- `char* csv_write_row(list[char*] fields)`
- Dialect fields: delimiter, quotechar, escapechar, doublequote, lineterminator.

`formats/configparser.w`

- `config* config_parse(char* text)`
- `char* config_get(config* cfg, char* section, char* key)`
- `int config_get_int(config* cfg, char* section, char* key, int* out)`
- `list[char*] config_sections(config* cfg)`

`formats/toml.w`

- `toml_doc* toml_parse(char* text)`
- `toml_value* toml_get(toml_doc* doc, char* dotted_key)`
- MVP values: string, int, bool, arrays, tables.

`formats/html.w`

- `char* html_escape(char* text)`
- `char* html_unescape(char* text)`
- `html_parser* html_parser_new(html_event_cb* callback, void* ctx)` deferred.

`formats/xml.w`

- `xml_reader* xml_reader_new(char* text)`
- `xml_event xml_next(xml_reader* reader)`
- MVP: start tag, end tag, text, attributes, entity expansion limits.

`storage/sqlite.w`

- `sqlite_db* sqlite_open(char* path)`
- `int sqlite_exec(sqlite_db* db, char* sql)`
- `sqlite_stmt* sqlite_prepare(sqlite_db* db, char* sql)`
- `int sqlite_step(sqlite_stmt* stmt)`
- `char* sqlite_column_text(sqlite_stmt* stmt, int index)`
- `int sqlite_column_int(sqlite_stmt* stmt, int index)`

## Implementation phases

### Phase 1: CSV

- Port the `_csv.c` state machine shape rather than ad hoc splitting.
- Implement delimiter, quote, escaped quote, CRLF/LF, empty fields.
- Tests: Python docs examples, embedded newline, embedded delimiter, malformed
  quoted field, round-trip writer.

### Phase 2: configparser subset

- Parse sections, key/value pairs, comments, blank lines.
- Preserve last value on duplicate keys initially, then add duplicate policy.
- Defer interpolation.
- Tests: defaults, comments, whitespace, missing section/key.

### Phase 3: TOML subset

- Use Python `tomllib` behavior for syntax where supported.
- Start with tables, dotted keys, strings, integers, booleans, arrays.
- Defer dates, floats, inline tables if necessary.
- Tests: valid/invalid fixtures from TOML spec subset.

### Phase 4: JSON facade and improvements

- Add `libs.standard.formats.json` that wraps `structures.json`.
- Decide whether to extend existing parser for floats/exponents or keep strict
  int-only behavior documented.
- Tests should lock current ownership and serialization behavior.

### Phase 5: HTML/XML

- Implement `html_escape`/`unescape` first.
- For XML, prefer a pull parser with entity expansion limits to avoid unsafe
  recursive expansion.
- Tests: entity handling, attributes, malformed tags, deeply nested input limit.

### Phase 6: SQLite

- Use `c_import`/`extern` against `libsqlite3` only if available in environment;
  otherwise gate tests.
- Keep a very small prepared-statement API.
- Tests: open temp db, create table, insert, query, bind params if implemented.

### Phase 7: persistence

- Define W-specific `marshal` for primitive values and JSON-like trees.
- Do not call it Python-compatible unless it reads/writes Python marshal format.
- Pickle can remain a design note until W has reflection or generated serializers.

## Compatibility notes from Python

- CSV compatibility is realistic and high-value; prioritize it.
- `tomllib` is read-only in Python. W should also start parse-only.
- Python `pickle` depends on Python object semantics. W should favor explicit
  serializers, perhaps generated by compiler support later.
- SQLite should follow Python's safety practices: prepared statements and
  parameter binding before encouraging dynamic SQL strings.

## Acceptance criteria

- CSV reader/writer passes a compatibility fixture set.
- INI and TOML subsets parse deterministic structured values.
- HTML escaping is correct for `&`, `<`, `>`, quotes.
- SQLite wrapper can run a complete create/insert/select test when dependency is
  present, and its tests skip clearly when absent.
