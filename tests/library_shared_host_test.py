"""Load a W library from a native ABI host, independently of W extern shims."""
import ctypes
import sys

library = ctypes.CDLL(sys.argv[1])
for name in ("shared_relocation_value", "shared_startup_state", "ax"):
    function = getattr(library, name)
    function.argtypes = []
    function.restype = ctypes.c_int64
library.shared_utf8.argtypes = []
library.shared_utf8.restype = ctypes.c_char_p
library.shared_set_state.argtypes = [ctypes.c_int64]
library.shared_set_state.restype = None

# A shared image's application main must never run during dlopen.
assert library.shared_startup_state() == 10
assert library.ax() == 17
# Both the global array and nested array carry relocated descriptor pointers.
assert library.shared_relocation_value() == 93
assert library.shared_utf8() == "shared UTF-8: λ".encode()
# Exercise a void-returning adapter and a value wider than a C int.
library.shared_set_state(1 << 40)
assert library.shared_startup_state() == 1 << 40
print("shared host relocations OK")
