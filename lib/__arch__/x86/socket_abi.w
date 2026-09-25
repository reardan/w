# Per-target socket ABI values for lib/net.w (plan 11 phase 2 darwin
# socket audit, issue #200): the parts of the BSD socket interface that
# Linux and Darwin define differently. lib/net.w imports this module
# through the reserved __arch__ path segment, so one import line binds
# the right values for whichever target is being compiled.
#
# Linux x86 values: lib/socket_abi_linux.w, shared with x64 and arm64.
import lib.socket_abi_linux
