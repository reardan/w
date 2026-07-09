# Plan: package ecosystem and module metadata

## Target area

Base code directory: `libs/standard/pkg/`

Suggested modules:

- `libs.standard.pkg.metadata`
- `libs.standard.pkg.resources`
- `libs.standard.pkg.discovery`
- `libs.standard.pkg.env`
- `libs.standard.pkg.install_manifest`

## Python 3.14 reference implementations

Consult these CPython sources first:

- `Lib/importlib/metadata/` - installed distribution metadata API.
- `Lib/importlib/resources/` - resource readers and package data access.
- `Lib/pkgutil.py` - package/module discovery helpers.
- `Lib/site.py` - site-package path initialization.
- `Lib/sysconfig/` - install path schemes and platform variables.
- `Lib/venv/` - isolated environment layout and activation conventions.
- `Lib/ensurepip/` - bundled bootstrap model.
- `Lib/zipimport.py` - archive-backed import behavior.

Do not copy Python's import machinery wholesale. W imports currently map
directly from dotted module names to files; this plan should add metadata and
discovery around that model.

## Current W starting point

- `docs/package_metadata.txt` describes `package.wmeta` direction.
- `lib/wmeta.w` parses/checks package metadata.
- Imports are file-path based and have no package registry.
- The repo has no package manager or dependency resolver.

## Goals

1. Define a stable package metadata file for W packages.
2. Let tools discover packages and exported modules under configured roots.
3. Provide a resource lookup API for non-code files shipped with a package.
4. Provide install manifests for future package installation without building a
   networked package manager in the first pass.
5. Keep all new public APIs under `libs.standard.pkg`.

## Non-goals for MVP

- No PyPI-compatible index.
- No network downloader.
- No dependency solver beyond exact local dependency names.
- No bytecode/cache/import hooks.
- No virtualenv activation scripts beyond documented directory layout.

## Proposed data model

Package metadata file: `package.wmeta`

Required fields:

- `name`: normalized package name, lowercase with `-`, `_`, and alnum only.
- `version`: dotted numeric version with optional suffix.
- `root`: code root relative to the metadata file, usually `.`.

Optional fields:

- `modules`: explicit list of module paths.
- `resources`: explicit list or glob-like patterns for data files.
- `dependencies`: package name plus version constraint string.
- `authors`, `license`, `description`.

Install manifest file: `w-install-manifest.txt`

- One normalized path per line.
- Paths are relative to install root.
- Used for uninstall/list/check operations.

## API sketch

`metadata.w`

- `package_meta* pkg_read_metadata(char* path)`
- `int pkg_validate(package_meta* meta, string_builder* diagnostics)`
- `char* pkg_normalize_name(char* name)`
- `char* pkg_version(package_meta* meta)`
- `list[char*] pkg_dependencies(package_meta* meta)`

`discovery.w`

- `package_index* pkg_index_new()`
- `int pkg_index_add_root(package_index* index, char* root)`
- `package_meta* pkg_find(package_index* index, char* name)`
- `list[char*] pkg_list_modules(package_meta* meta)`
- `char* pkg_module_path(package_meta* meta, char* dotted_name)`

`resources.w`

- `char* pkg_resource_path(package_meta* meta, char* resource_name)`
- `char* pkg_resource_read_text(package_meta* meta, char* resource_name)`
- `int pkg_resource_exists(package_meta* meta, char* resource_name)`

`env.w`

- `char* pkg_default_root()`
- `list[char*] pkg_search_roots_from_env(char* env_name)`
- `int pkg_is_virtual_root(char* root)`

## Implementation phases

### Phase 1: metadata parser wrapper

- Reuse `lib/wmeta.w` where possible.
- Add a typed `package_meta` wrapper with ownership rules.
- Validate required fields and normalized names.
- Add diagnostics builder output instead of exiting on malformed input.
- Tests: valid metadata, missing fields, invalid names, duplicate fields, empty
  dependencies, malformed version strings.

### Phase 2: local package discovery

- Implement root scanning using existing file/directory syscalls.
- Support explicit `modules` first; add recursive discovery only after directory
  helpers are stable.
- Protect against `..`, absolute resource names, and paths outside the package.
- Tests: multiple roots, shadowing order, package not found, invalid metadata
  ignored with diagnostic.

### Phase 3: resources

- Read package data files through `lib.file`.
- Normalize resource paths to avoid traversal.
- Add binary-read later; MVP text is enough.
- Tests: text resource lookup, missing resource, traversal rejection.

### Phase 4: install manifest

- Generate a manifest for a package tree.
- Parse and verify a manifest against the filesystem.
- Do not delete files in MVP.
- Tests: manifest round trip, duplicate paths, missing files, normalized paths.

### Phase 5: tool integration

- Add a small command-line tool under `tools/` only after library APIs are stable.
- Wire tests into `build.json`.

## Compatibility notes from Python

- `importlib.metadata` exposes distributions, entry points, files, requirements,
  and versions. Start with distribution name/version/files only.
- `importlib.resources` separates package identity from filesystem path. W can
  return paths for now, but keep API names resource-oriented so zip/archive
  packages remain possible.
- `site.py` mutates Python import paths at startup. W should avoid implicit
  global path mutation until the compiler has an explicit package-root option.

## Acceptance criteria

- A W program can locate a local package by name under a configured root.
- It can list declared modules and read declared text resources.
- Invalid package metadata returns diagnostics without crashing.
- Tests are deterministic and require no network.
