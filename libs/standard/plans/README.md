# W standard library expansion plans

These plans break the missing Python-style standard library surface into
separate work packets for lower-reasoning implementation agents. All new W
standard modules should live under `libs/standard/` and import the existing
systems layer (`lib.*`, `structures.*`) rather than moving or rewriting it.

Use Python 3.14 as the reference API and behavior source, especially CPython's
`Lib/` modules and `Modules/` C accelerators. Match the spirit and edge cases
where practical, but keep W's constraints explicit: manual memory management,
Linux-first syscalls, no package manager today, no closures, and tests driven by
`make`/`wbuild`.

## Shared conventions

- Public imports should use paths like `import libs.standard.text.re`.
- Module tests should live beside the module when possible, for example
  `libs/standard/text/re_test.w`, and also be wired into `build.json`.
- Prefer pure W first. Use `c_import`/`extern` only when a feature is too large
  to implement safely in W at this stage, and document the C dependency.
- MVP APIs should be small, deterministic, and well-tested before adding
  compatibility aliases or high-level conveniences.
- Every plan should add tests for happy paths, invalid inputs, boundary values,
  allocation/free ownership, and Python compatibility cases copied from CPython
  tests where licensing permits.

## Plan index

1. `01_package_ecosystem.md` - package metadata, module discovery, virtual roots.
2. `02_text_processing.md` - regex, diffs, text wrapping, Unicode data, codecs.
3. `03_numeric_data.md` - math, random, decimal/fractions/statistics, algorithms.
4. `04_time_calendar.md` - datetime, calendar, monotonic clocks, zones.
5. `05_filesystem.md` - pathlib-style paths, glob/fnmatch, tempfile, shutil.
6. `06_formats_storage.md` - CSV, config/TOML, markup, persistence, SQLite.
7. `07_compression_crypto.md` - archives, compression, hashes, HMAC, secrets.
8. `08_networking_web.md` - URLs, HTTP clients/servers, TLS, email, IP helpers.
9. `09_concurrency.md` - schedulers, queues, futures, threads/process workers.
10. `10_cli_ui_devtools.md` - argparse, terminal UI, testing, debug/profile tools.
11. `11_native_http_tls.md` - pure-W HTTPS client: HTTP/1.1, SSE, DNS, TLS 1.3,
    X.509, and the crypto primitives (supersedes the FFI/TLS non-goals in
    plans 07 and 08).
