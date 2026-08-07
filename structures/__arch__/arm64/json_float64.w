# Per-target float64 number engine for structures/json.w: the arm64
# word is 8 bytes, so this target gets the real implementation (see
# structures/json_float64_impl.w; the x86/wasm twins are stubs because
# float64 is a compile error on 4-byte-word targets).
import structures.json_float64_impl
