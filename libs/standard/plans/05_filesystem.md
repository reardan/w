# Plan: filesystem and path utilities

## Target area

Base code directory: `libs/standard/fs/`

Suggested modules:

- `libs.standard.fs.path`
- `libs.standard.fs.pathlib`
- `libs.standard.fs.glob`
- `libs.standard.fs.fnmatch`
- `libs.standard.fs.tempfile`
- `libs.standard.fs.shutil`
- `libs.standard.fs.stat`
- `libs.standard.fs.filecmp`

## Python 3.14 reference implementations

Consult these CPython sources first:

- `Lib/pathlib/` - object-oriented path behavior and path parsing.
- `Lib/os.path` variants, especially `Lib/posixpath.py`.
- `Lib/glob.py` - recursive globbing behavior.
- `Lib/fnmatch.py` - shell-style pattern matching.
- `Lib/tempfile.py` - safe temporary file/directory creation.
- `Lib/shutil.py` - high-level copy/remove/archive helpers.
- `Lib/stat.py` - mode bit constants and predicates.
- `Lib/filecmp.py` - shallow/deep file comparison.

## Current W starting point

- `lib/file.w` supports read text, write text, and read lines.
- `lib/path.w` supports join, basename, dirname, and a limited exists check.
- Low-level syscalls expose open/read/write/close/mkdir and directory-related
  functions through arch modules.
- There is no high-level directory traversal or metadata wrapper.

## Goals

1. Provide safer POSIX path manipulation under `libs.standard.fs`.
2. Add file metadata (`stat`) and directory iteration wrappers.
3. Add glob/fnmatch for tools and package discovery.
4. Add temporary files/directories with race-resistant creation.
5. Add common copy/remove helpers, staged carefully to avoid data loss.

## Non-goals for MVP

- No Windows path semantics.
- No symlink-heavy behavior until `lstat`/`readlink` wrappers exist.
- No archive creation here; archive formats belong in compression plans.
- No destructive recursive remove until tests and path-safety guards are strong.

## API sketch

`path.w`

- `char* fs_path_join(char* left, char* right)`
- `char* fs_path_normpath(char* path)`
- `char* fs_path_abspath(char* path)`
- `char* fs_path_basename(char* path)`
- `char* fs_path_dirname(char* path)`
- `int fs_path_isabs(char* path)`
- `int fs_path_samefile(char* a, char* b)`

`stat.w`

- `struct fs_stat { int mode; int size; int mtime; int dev; int ino }`
- `int fs_stat_path(char* path, fs_stat* out)`
- `int fs_is_file(fs_stat* st)`
- `int fs_is_dir(fs_stat* st)`
- `int fs_is_symlink(fs_stat* st)` after `lstat`.

`pathlib.w`

- Use plain functions plus `struct path` instead of Python classes.
- `path* path_new(char* text)`
- `path* path_child(path* p, char* child)`
- `char* path_string(path* p)`
- `int path_exists(path* p)`
- `list[path*] path_iterdir(path* p)`
- `char* path_read_text(path* p)`
- `int path_write_text(path* p, char* text)`

`fnmatch.w` and `glob.w`

- `int fnmatch_match(char* name, char* pattern)`
- `list[char*] glob_glob(char* pattern)`
- `list[char*] glob_iglob(char* pattern)` can be deferred until iterators mature.

`tempfile.w`

- `char* tempfile_mkstemp(char* prefix, char* suffix)`
- `char* tempfile_mkdtemp(char* prefix)`
- `char* tempfile_gettempdir()`

`shutil.w`

- `int shutil_copyfile(char* src, char* dst)`
- `int shutil_copytree(char* src, char* dst)`
- `int shutil_rmtree(char* path)` deferred until safety complete.

## Implementation phases

### Phase 1: syscall and stat foundation

- Add portable x86/x64 wrappers for `stat`, `fstat`, `getdents`, `unlink`,
  `rmdir`, `rename`, and optionally `readlink`.
- Add tests using temporary directories.
- Ensure 32-bit struct layouts are correct with explicit load/store helpers.

### Phase 2: path normalization

- Port POSIX rules from `posixpath.py`: collapse duplicate slashes, process `.`
  and `..`, preserve leading slash.
- Avoid filesystem access in pure path functions.
- Tests: empty path, root, trailing slash, relative parents, absolute paths.

### Phase 3: directory iteration and pathlib facade

- Implement directory entry iteration over `getdents`.
- Build `path_iterdir`, `exists`, `is_file`, `is_dir`.
- Tests: empty dir, files/dirs mixed, nonexistent paths, permission failures if
  easy to create hermetically.

### Phase 4: fnmatch and glob

- Implement `*`, `?`, `[seq]`, `[!seq]`.
- `glob` should split path segments and use directory iteration.
- Add recursive `**` only after basic glob is correct.
- Tests: hidden files, character ranges, no matches, recursive matches.

### Phase 5: tempfile

- Generate random names using crypto secrets if available; otherwise use pid,
  monotonic time, and retry with `O_CREAT|O_EXCL`.
- Do not use predictable names without exclusive create.
- Tests: creates unique files, respects prefix/suffix, cleans up.

### Phase 6: shutil

- Implement copyfile with read/write loops.
- Copy metadata later.
- Recursive copy/remove must reject dangerous roots like `/`, `.`, and empty
  paths unless explicitly forced.
- Tests: copy content, overwrite behavior, missing source, directory errors.

## Compatibility notes from Python

- Python `pathlib` is class-heavy. W should expose structs and functions while
  preserving names and behavior where useful.
- Python glob treats hidden files and recursive globs carefully; document any
  divergence.
- Python tempfile has strong security requirements. W must use exclusive create
  and retries before exposing public helpers.

## Acceptance criteria

- Tools can traverse directories, inspect metadata, and glob files without
  shelling out.
- Path functions match Python POSIX behavior for documented cases.
- Tempfile creation is race-resistant.
- Destructive helpers are either absent or guarded and heavily tested.
