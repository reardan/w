# Per-target platform facts for tools/wexec.w, resolved through the
# same lib/__arch__-style per-arch import tools/__arch__/
# wexec_remote_http.w already uses. This x86 file is the default-arch
# resolution (bin/wexec, x86 Linux).


# 1 when wexec_collect_dir can produce a real directory listing on this
# platform: its getdents parsing assumes the classic Linux dirent
# layout, which is exactly this target's own, so directory inputs hash
# correctly here. The arm64_darwin sibling returns 0 (Darwin
# getdirentries64 records use a different layout -- see the NOTE in
# lib/__arch__/arm64_darwin/syscalls.w), making wexec warn and treat
# directory inputs as empty instead of silently misparsing them.
int wexec_dirents_supported():
	return 1
