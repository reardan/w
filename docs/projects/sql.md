# Basic SQL connectivity

For parsing SQL or constructing parameterized queries without opening a
connection, see [SQL parsing and query construction](sql_parsing.md).

Issue [#495](https://github.com/reardan/w/issues/495) has an initial synchronous,
Linux x64 implementation in `libs.standard.sql.client`. It uses each database's
native client library, loaded on demand through `lib.dlcall`. Importing the module
does not require installing all five clients; the executable needs glibc/libdl.
Missing libraries or required symbols produce a failed connection with an error.
No compiler changes, external commands, or ODBC drivers are involved at runtime.

| Database | Client library | Open function | Text parameter markers |
| --- | --- | --- | --- |
| SQLite 3.37+ | `libsqlite3.so.0` | `sql_open_sqlite(path)` | `?`, `?1`, etc. |
| PostgreSQL | `libpq.so.5` | `sql_open_postgres(conninfo)` | `$1`, `$2`, etc. |
| MySQL 8 / MariaDB | `libmysqlclient.so.21`, then `libmariadb.so.3` | `sql_open_mysql(host, user, password, database, port=3306)` | Not implemented |
| SQL Server | FreeTDS `libsybdb.so.5` (native TDS 7.4) | `sql_open_sqlserver(server, user, password, database)` | Not implemented |
| Oracle | Instant Client `libclntsh.so`, then `libclntsh.so.19.1` | `sql_open_oracle(connect_identifier, user, password)` | `:1`, `:2`, etc. |

MySQL and SQL Server currently execute trusted SQL text only. Passing parameters
to either adapter fails before sending a command; it never substitutes or quotes
values into SQL. Native prepared binding for those two clients is follow-up work.

## Example

```w
import libs.standard.sql.client

int main():
	sql_connection* db = sql_open_sqlite(c":memory:")
	if (sql_is_open(db) == 0):
		println2(sql_error(db))
		sql_close(db)
		return 1
	char*[1] values
	values[0] = c"hello ' SQL"
	sql_result* rows = sql_query_params(db, c"SELECT ? AS greeting", 1, &values[0])
	if (rows == 0):
		println2(sql_error(db))
		sql_close(db)
		return 1
	println(sql_value(rows, 0, 0))
	sql_result_free(rows)
	sql_close(db)
	return 0
```

Build with `bin/wv2 x64 example.w -o bin/example`.

## API and ownership

- Open functions return an owned `sql_connection*` even on failure.
  Check `sql_is_open(db)` and read the borrowed `sql_error(db)` string. Free
  successful and failed connections with `sql_close(db)`.
- `sql_query(db, sql)` and `sql_query_params(db, sql, count, char** values)` return
  an owned `sql_result*`, or null on failure. Parameters are NUL-terminated text;
  a null parameter pointer means SQL NULL. Buffers only need to survive the call.
  Convert numeric inputs to text and use native SQL casts where necessary.
- `sql_exec(db, sql)` discards the result and returns 1 for success, 0 for error.
- Results expose `rows`, `columns`, and `affected` (native affected-row count,
  or -1 when unavailable). SQLite counts all changes made by the command,
  including trigger effects. Row and column indexes are zero-based.
- `sql_column_name(result, col)` and `sql_value(result, row, col)` return borrowed
  pointers valid until `sql_result_free(result)`. Values are copied and remain
  valid across queries and after closing the connection.
- `sql_value_length(result, row, col)` returns byte length, -1 for SQL NULL, or
  -2 for an invalid index. NULL and invalid indexes return a null value pointer;
  an empty value has length 0 and a non-null pointer. Every non-null value has an
  extra NUL terminator; use lengths for embedded NULs and binary columns.
- `sql_begin`, `sql_commit`, and `sql_rollback` return 1/0. Transactions cannot nest.
  Use these helpers consistently rather than mixing them with transaction SQL.
  Native DDL/implicit-commit rules still apply. Closing rolls back outstanding
  uncommitted work. Oracle uses commit-on-success outside explicit transactions.
- `sql_query_cursor(db, sql, count, char** values)` (SQLite and PostgreSQL only;
  other clients return 0 with an error) streams rows one at a time with no row
  or total-size limit, and returns an owned `sql_cursor*` or 0. Parameters
  follow `sql_query_params`. `sql_cursor_next(cur)` returns 1 when a row is
  available, 0 at the end and -1 on error (read `sql_error(db)`); both are
  sticky. `sql_cursor_columns`, `sql_cursor_column_name` (borrowed until free),
  `sql_cursor_value(cur, col)` and `sql_cursor_value_length(cur, col)` (-1 NULL,
  -2 no current row or invalid column) read the current row; values are
  borrowed until the next `sql_cursor_next` or free and follow the result
  conventions (non-null empty values, NUL-terminated, lengths for binary data).
  `sql_cursor_free(cur)` finalizes the SQLite statement, or for PostgreSQL
  cancels the query (outside a transaction; inside one it drains, so the
  transaction is not aborted) and discards the remaining rows. While a cursor
  is open, every other query, cursor, `sql_begin`, `sql_commit` or
  `sql_rollback` on its connection fails with "connection has an open cursor";
  the connection is released as soon as `sql_cursor_next` returns 0 or -1, or
  on free. `sql_close` with an open cursor ends it; the cursor then returns -1
  and must still be freed. PostgreSQL uses libpq single-row mode, so a cursor
  that fails partway may already have returned rows; SQLite reports errors
  from the statement at `sql_cursor_next`.
- Errors belong to the connection and are replaced by the next operation.
  Connections, initialization, and queries are **single-threaded**. FreeTDS uses
  process-wide callbacks; do not combine this adapter with another DB-Library
  callback owner. Client libraries and ABI trampolines stay loaded for the
  lifetime of the process.

## Connection configuration

PostgreSQL accepts a libpq connection string or URI, for example
`host=localhost dbname=app user=app connect_timeout=5 sslmode=verify-full`.
Credentials, certificates, and server identity validation follow libpq's options.
See the [libpq connection parameters](https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-PARAMKEYWORDS).

MySQL sets a five-second connect timeout, disables LOCAL INFILE and multi-statement
execution, and selects `utf8mb4`. This initial API does not expose TLS policy or
certificate settings; it uses the native client's defaults. It does not promise
a verified encrypted connection. See the
[MySQL connection API](https://dev.mysql.com/doc/c-api/8.0/en/mysql-real-connect.html).

SQL Server accepts a FreeTDS server alias or `host:port`. Configure authentication,
connection/query timeouts, encryption, and certificate verification through
[`freetds.conf`](https://www.freetds.org/userguide/freetdsconf.html). The adapter
uses SQL authentication and UTF-8; it captures native errors instead of allowing
the default DB-Library error handler to exit the process.

Oracle accepts an Oracle Net alias or Easy Connect identifier such as
`localhost:1521/FREEPDB1`. Install Instant Client and its required dependencies in
the dynamic loader's search path. Oracle Net configuration controls transport,
wallets, and timeouts. The client character set is AL32UTF8. See the
[OCI connection APIs](https://docs.oracle.com/en/database/oracle/oracle-database/19/lnoci/session-and-connection-functions.html).

## Scope and limits

This is a small connection/query interface, not an ORM or a portable SQL dialect.
Scalars are returned in their client's textual representation; dates, decimals,
and numerics are not coerced into W machine integers or floats. SQLite, MySQL,
and FreeTDS preserve binary columns; PostgreSQL uses its text-format encoding
(e.g. bytea), and OCI preserves RAW data. Oracle treats empty strings as NULL.

The W result collector accepts at most 1,024 columns, 100,000 rows, 1 MiB per
cell, and approximately 64 MiB of copied result data and cell bookkeeping. Use
`sql_query_cursor` (SQLite and PostgreSQL) for larger results: cursors keep one
row at a time and have only the 1,024-column limit.
Oracle's scalar define buffers have a smaller 32,767-byte per-cell limit and
reject truncation. These bounds do not limit allocations inside libpq or
`mysql_store_result`, which buffer results themselves. Use bounded queries.

SQLite and PostgreSQL accept one statement per call. MySQL disables multiple
statements; FreeTDS follows native batch semantics. Multiple row-bearing result
sets are rejected and pending results drained/cancelled. Already executed writes
are not undone by a result-conversion/size error; use explicit transactions when
that matters. PostgreSQL COPY is unsupported and closes the connection to avoid
leaving it in COPY protocol mode. Oracle LOB/LONG/object/cursor columns and
PL/SQL blocks are unsupported. There is no statement cache, pooling, async I/O,
streaming for MySQL/SQL Server/Oracle, output parameter API, or non-Linux-x64 ABI support yet.

## Validation

- `./wbuild sql_test`: real SQLite create/insert/select, bound values, maximum
  signed 64-bit integer text, NULL/empty/binary data, commit/rollback, errors,
  single-statement enforcement, result limits and result ownership. Clearly skips
  if the native library is unavailable.
- `./wbuild sql_cursor_test`: SQLite cursor streaming 150,000 rows past the
  collector limit, NULL/empty/binary values, parameters, the open-cursor lock,
  early free, transactions, mid-stream errors and close with an open cursor.
  `sql_cursor_postgres_local_test` does the same on PostgreSQL (non-root only,
  via `bin/sql_postgres_fixture` (tests/sql_postgres_fixture.w)), including cancel on early free.
- `./wbuild sql_native_abi_test`: actual libpq/MySQL failed-open paths when
  installed; C shared-library fixtures validate MySQL, FreeTDS and OCI calls,
  native output widths, stack arguments, callbacks, binding, truncation, cleanup,
  and missing-symbol handling. The fixture portion requires `cc` and Python 3;
  it skips clearly if `cc` is absent. Fixtures are not real-server certification.
- `./wbuild sql_postgres_local_test`: starts an isolated temporary PostgreSQL
  cluster over a private Unix socket, runs CRUD/parameter/transaction/error
  checks, and stops/removes it. Skips if `initdb` is absent or running as root.
  Alternatively, `W_SQL_POSTGRES='...' bin/sql_postgres_test` exercises an
  existing server using a temporary table only.
- All three targets belong to `./wbuild tests`. SQLite and PostgreSQL have been
  tested against real local databases. MySQL, SQL Server, and Oracle success
  paths currently have native ABI fixture coverage; live-server validation
  remains necessary for their supported client/server combinations.
