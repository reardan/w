# Per-target float64 number engine for structures/json.w: float64 is a
# compile error on the 4-byte wasm word, so this selector binds the
# shared stub (see structures/json_float64_stub.w; the 8-byte-word
# twins bind structures/json_float64_impl.w instead).
import structures.json_float64_stub
