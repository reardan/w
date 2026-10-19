# w-orm

A Django-style ORM for W (issue [#754](https://github.com/reardan/w/issues/754)):
models, querysets, migrations with safe expand/contract patterns, users and
groups, authentication and permissions, a REST layer, trigger-based history,
and a thin MVC/admin layer. It lives in `libs/standard/orm/` and is built on
`libs.standard.sql` (docs/projects/sql.md, sql_parsing.md). Nothing in it is
part of the compiler or the seed graph.

Status: being built in waves of parallel units. Each landed unit has its own
page under [`docs/projects/orm/`](orm/); this page is the index and holds the
shared contracts.

Supported today: SQLite (3.37+) and PostgreSQL, Linux x64 (the SQL client's
platform). Tests start with `# wbuild: arch_only=x64` and skip cleanly when a
native client library is missing.

## Layout

| Path | What |
| --- | --- |
| `libs/standard/orm/contract.w` | Shared structs C1-C8 and `orm_db` (below). |
| `tests/orm/fixtures/library.orm` | Fixture schema. |
| `tests/orm/fixtures/library_orm.w` | Hand-written data module equal to what `bin/orm_gen` generates for the fixture. |
| `libs/standard/orm/schema/`, `tools/orm_gen.w` | `.orm` grammar and generator. |
| `libs/standard/orm/{compile,dialect_*}.w` | Query tree to SQL. |
| `libs/standard/orm/{orm,query,expr,load,write,related,atomic}.w` | Runtime API. |
| `libs/standard/orm/migrate/` | Migration state, autodetector, planner, linter, applier. |
| `libs/standard/orm/{auth,history,rest,web,admin}/` | Higher layers. |

## Contracts

`contract.w` is changed only by a contract PR; unit PRs consume it.

- **C1 descriptors.** `orm_model_desc` (name, table, struct size, fields, pk,
  history flag, indexes, checks) and `orm_field_desc` (name, column, kind,
  offset, flags, null flag offset, lengths, default SQL, relation target,
  relation slot offset, on_delete, related name, M2M through table). The
  registry (`orm_register`, `orm_model_lookup`, `orm_registry_resolve`) links
  relation targets by model name.
- **C2 kinds and flags.** Int-backed kinds (`ORM_INT`, `ORM_BIGINT`,
  `ORM_BOOL`, `ORM_FK`) store an `int`; every other column kind stores a
  `char*` in its database text form. SQL NULL is a null pointer for text
  kinds and `<field>__isnull = 1` for nullable int kinds.
- **C3 query tree.** `orm_query` with `orm_where` (and/or/not/lookup),
  `orm_expr` (field path, bound value, function, aggregate, case, subquery,
  exists, window, outer ref, raw), `orm_order`, `orm_annotation`,
  `orm_assignment`, `orm_prefetch`. Paths use `__`. `orm_query_clone` copies
  the lists; nodes are immutable once built, so clones share them.
- **C4 compiler.** `int orm_compile(orm_query*, orm_dialect*, orm_compiled*)`
  fills an `sql_builder` (values always bound, never interpolated) and a
  column map telling the loader which model/field/relation path or
  annotation each result column is.
- **C5 dialect.** `orm_dialect` is an id plus capability flags; the
  per-dialect code lives in `dialect_sqlite.w` / `dialect_postgres.w`.
- **C6 results.** An `orm_result` owns every allocation a query made (rows,
  strings, relation lists); `orm_result_free` releases all of it.
- **C7 migrations.** `orm_migration` is an ordered list of `orm_op`, each
  tagged expand, migrate or contract. Destructive ops are contract-phase and
  name the expand migration that must already be applied.
- **C8 history.** `<table>_history` tables written only by triggers, with
  `history_id/date/type/user_id/reason/context_id`; the context is published
  per transaction via `set_config('w_orm.context', ...)` on PostgreSQL and a
  TEMP table `_w_orm_context` on SQLite. `orm_db.on_begin` (an
  `orm_begin_fn*`) runs after each outermost BEGIN; history uses it to
  republish the transaction-local PostgreSQL context.
- **orm_db** wraps the `sql_connection`, dialect, query counter (used by
  N+1 tests), atomic depth, on-commit callbacks, query log and last error.
  `orm_db_execute` / `orm_db_exec_sql` are the only paths to the database.

### Generated code shape

For an `.orm` file declaring `app library`, `bin/orm_gen` writes two modules:

**Data module** (`library_orm.w`, imports only `contract.w`), per model `M`
in FK dependency order (ties keep declaration order):

- `struct M` — `int id` first unless another pk is declared; scalar fields in
  declaration order; an FK `author` becomes `int author_id` followed by the
  pointer slot `author` (typed `Author*` when `Author` is declared earlier,
  else `void*`); a nullable int field `pages` is followed by
  `int pages__isnull`; M2M fields and reverse relations (`related_name`)
  are `list[void*]` slots. Reverse relations are appended after the
  model's own fields.
- `orm_model_desc* M_desc()` — builds the descriptor once and registers it.
- `char* M_f_<field>()` — field handles; `char* M_<Enum>_<value>()` — enum
  values; typed relation accessors `T* M_<fk>(M*)` and `list[T*] M_<rel>(M*)`.
- `void <app>_register()` — calls every `M_desc()` and resolves relations.

Naming rules: table `<app>_<model lower-case>`; FK column `<field>_id` with
`ORM_F_INDEXED`; M2M through table `<app>_<model>_<field>` with columns
`<model>_id` and `<target>_id`; `index <fields>` is named
`<table>_<fields joined by _>_idx`; enum columns are text with
`max_length` = the longest value.

**API module** (`library_orm_api.w`, imports the data module and
`libs.standard.orm.orm`), per model `M`:

```w
orm_queryset* M_objects(orm_db* db)        # orm_objects(db, M_desc())
list[M*] M_rows(orm_result* r)             # cast(list[M*], r.rows)
M* M_new()                                 # cast(M*, orm_row_new(M_desc()))
int M_save(orm_db* db, M* row)             # orm_save(db, M_desc(), row)
int M_delete(orm_db* db, M* row)           # orm_delete_row(db, M_desc(), row)
void M_free(M* row)                        # orm_row_free(M_desc(), row)
```

Rows the runtime allocates (`orm_row_new`, query results) carry one extra
trailer word after `struct_size` (U1.3's `orm_row_meta*`: annotations and
strings the ORM writes later). Any generated helper that allocates a row,
such as a future `M_clone`, must use `orm_row_new(M_desc())`, never
`malloc(sizeof(M))`, and write functions must not be given stack rows.

so the runtime (U1.3) provides `orm_queryset`, `orm_objects`, `orm_save`,
`orm_delete_row`, `orm_row_new` and `orm_row_free` with those signatures.

## Units

The plan and the wave/unit table are in the project's implementation plan;
landed units are listed here as they merge.

| Unit | Page | Status |
| --- | --- | --- |
| U0.1 typed SQL values | [u0_1](orm/u0_1.md) | landed |
| U0.2 streaming cursor | [u0_2](orm/u0_2.md) | landed |
| U0.3 savepoints | [u0_3](orm/u0_3.md) | landed |
| U0.4 contracts + fixture | this page | landed |
| U1.1 schema generator | [u1_1](orm/u1_1.md) | landed |
| U1.2 SQL compiler | [u1_2](orm/u1_2.md) | landed |
| U1.3 QuerySet API | [u1_3](orm/u1_3.md) | landed |
| U2.1 prefetch, iterator, transactions | [u2_1](orm/u2_1.md) | landed |
| U2.2 migration state, autodetector, writer | [u2_2](orm/u2_2.md) | landed |
| U2.3 migration planner + linter | [u2_3](orm/u2_3.md) | landed |
| U2.4 migration applier, DDL, `bin/orm` | [u2_4](orm/u2_4.md) | landed |
| U3.1 users, groups, permissions | [u3_1](orm/u3_1.md) | landed |
| U3.2 sessions, API tokens, CSRF, throttle | [u3_2](orm/u3_2.md) | landed |
| U3.3 trigger-based history | [u3_3](orm/u3_3.md) | landed |
| U3.4 serializers, filters, pagination | [u3_4](orm/u3_4.md) | landed |
| U4.2 OpenAPI generation | [u4_2](orm/u4_2.md) | landed |
