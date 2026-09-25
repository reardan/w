# Per-target socket ABI values for lib/net.w (plan 11 phase 2 darwin
# socket audit, issue #200): the parts of the BSD socket interface that
# Linux and Darwin define differently. lib/net.w imports this module
# through the reserved __arch__ path segment, so one import line binds
# the right values for whichever target is being compiled.
#
# Linux-shaped values: lib/net.w has no Windows socket backend today,
# so this module only keeps wasm cross-compiles of net.w importers
# building; nothing exercises these values at runtime.
# The values are lib/socket_abi_linux.w's.
import lib.socket_abi_linux
