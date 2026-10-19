# w-orm example: a small library app

A lending library over every w-orm layer (issue #754, unit U5.2;
[docs/projects/orm.md](../../../docs/projects/orm.md)): generated models,
committed migrations with a two-step (expand/contract) column rename,
users/groups/permissions, session login with CSRF and API tokens, a REST
API with filters and pagination, trigger-based history and an OpenAPI
document. Linux x64 (the SQL client's platform), SQLite or PostgreSQL.

## Run it

```sh
./wbuild build                       # once: bin/wv2
./wbuild orm_library                 # bin/orm_library
bin/orm_library migrate apply --sqlite library.db --force
bin/orm_library createsuperuser --sqlite library.db admin admin@example.org s3cret
bin/orm_library serve --sqlite library.db --port 8000
```

`--postgres "host=... dbname=..."` works wherever `--sqlite <path>` does.
`migrate` is U2.4's command line over this app's migrations:
`migrate status`, `migrate sql [<name>]`, `migrate lint [--postgres]`.
`--force` is needed only on a fresh database, where every migration runs
in one go: the applier otherwise refuses to run a contract migration in
the same run as the expand migration it requires (`0004`/`0005` require
`0002`). Upgrading a release-1 database is two plain `migrate apply`
runs, one per deploy (see below).

Then, against the server:

```sh
curl localhost:8000/api/books/                       # anonymous: published books
curl -c jar localhost:8000/api/auth/csrf/            # {"csrf_token": ...} + session cookie
curl -b jar -c jar -H "X-CSRFToken: <token>" \
     -d '{"username":"admin","password":"s3cret"}' localhost:8000/api/auth/login/
curl -d '{"username":"admin","password":"s3cret","name":"cli"}' localhost:8000/api/auth/token/
curl -H "Authorization: Token <token>" "localhost:8000/api/books/?page_count__gte=300&ordering=-price"
curl localhost:8000/openapi.json
```

The server speaks plain HTTP, so its session cookie is sent without
`Secure`.

## Files

| Path | What |
| --- | --- |
| `library.orm` | The schema (release 2): Author, Book (history), Loan (history). |
| `library_orm.w`, `library_orm_api.w`, `library_schema.json` | `bin/orm_gen library.orm -o examples/orm/library/library`, committed. |
| `v1/library_v1.orm`, `v1/library_v1_orm*.w` | Release 1 of the schema (Book had `pages`), generated the same way; the "old code" of the migration test. |
| `migrations/{auth,session,library}/` | Migrations written by `makemigrations.w` (`orm_makemigrations_next` + `orm_write_migrations`), committed; never edited by hand. |
| `migrations.w` | The app's migration list: auth, session, then library. |
| `app.w` | Viewsets, the `/api/auth/` endpoints, router and `/openapi.json`. |
| `main.w` | `bin/orm_library`: `migrate`, `createsuperuser`, `serve`. |
| `makemigrations.w` | `bin/orm_library_makemigrations`: plans and writes new migrations. |
| `example_cases.w`, `orm_example_test.w`, `orm_example_postgres_test.w` | The end-to-end test. |

## API

| Route | Who |
| --- | --- |
| `GET /api/auth/csrf/` | Anyone: an anonymous session and its CSRF token. |
| `POST /api/auth/login/` | Session cookie + `X-CSRFToken`; rotates the session and returns a new CSRF token. |
| `POST /api/auth/logout/` | Session cookie + `X-CSRFToken`. |
| `POST /api/auth/token/` | `{"username", "password", "name"}`: a named API token (shown once). |
| `/api/books/` | Anonymous: published books, read only. Signed in: every book; writes need Django model permissions (`library.add_book`, ...). Page numbers (`page`, `page_size` up to 50); filters `status`, `author`, `price__gte/lte`, `page_count__gte/lte/isnull`, `author__name__icontains`, `search` (title), `ordering` (price, title, page_count). |
| `/api/books/<id>/history/` | Every version, newest first, with the user and request that wrote it. |
| `POST /api/books/<id>/checkout/` | Signed in: a loan of the book for the caller (409 when it is out). |
| `/api/authors/` | As books; limit/offset pages; `books` as a pk list. |
| `/api/loans/` | Signed in: your loans (staff: all); cursor pages; `borrower_id` is set from the caller; history route. |
| `/openapi.json` | The OpenAPI 3.0.3 document of the three viewsets. |

Viewsets accept the session cookie (with CSRF on unsafe methods) and
`Authorization: Token <token>`.

## The two-step migration

Release 1 stored a book's length in `library_book.pages`; release 2
calls it `page_count`. The change was planned with

```sh
bin/orm_library_makemigrations --rename "library_book.pages->page_count"
```

and became four migrations, each its own deploy:

| Migration | Phase | What | Code running |
| --- | --- | --- | --- |
| `0002_expand_library_book_pages` | expand | add `page_count` (nullable) and a dual-write trigger pair | release 1 and 2 |
| `0003_migrate_library_book_pages` | migrate | copy `pages` into `page_count` in batches | release 1 and 2 |
| `0004_contract_library_book_pages` | contract | mark `pages` deprecated, drop the dual write | release 2 only |
| `0005_contract_library_book_pages` | contract | drop `pages` (refused until `0002` was applied by an earlier run) | release 2 only |

Between `0003` and `0004` both releases read and write the same rows:
an insert or update through either column shows up in the other.

To change the schema yourself: edit `library.orm`, regenerate with
`bin/orm_gen examples/orm/library/library.orm -o examples/orm/library/library`,
then `./wbuild orm_library_makemigrations && bin/orm_library_makemigrations`
(add `--rename table.old->new` for renames; `--dry-run` only prints).
Commit the new `migrations/library/m*.w` files with the schema change.

## Tests

- `orm_example_test` (SQLite file) and `orm_example_postgres_test`
  (`W_SQL_POSTGRES`; `orm_example_postgres_local_test` starts a
  temporary cluster through `bin/sql_postgres_fixture`, which refuses to
  run as root): the whole story in process on two connections, one for
  each release. Static checks first (every migration lints clean on both
  dialects, release 1's migration matches `v1/library_v1.orm`, the
  committed rename is what makemigrations plans on either dialect, nothing
  left to plan); then release 1 with users, groups, permissions, session
  and token login; the expand deploy with both releases working, the REST
  API, history users and `/openapi.json`; the two contract deploys.
- `orm_example_gen_test`: regenerates both generated module sets and
  `cmp`s them with the committed files.
- `orm_example_cli_test`: `bin/orm_library` lint (both dialects), status,
  sql, apply, createsuperuser.
- `orm_library_makemigrations` runs `--dry-run` and expects no new
  migrations.
