/*
wfuzz-found fixture (tools/wfuzz.w, issue #440): compiling a *root*
with checked-pointer fields but no functions used to crash the
compiler. safe_check_finish ran with retained_bindings still null
(retained_semantic only builds a binding table when functions exist)
and dereferenced retained_bindings.length unchecked. The fuzzer's
seed loading hit it on tests/safe_generic_inference_import_fixture.w
in its first campaign (status 139 SIGSEGV at safe_check_finish in
compiler/safe.w), while the tests umbrella never compiles that file
as a root, only as an import, so the suite passed over the crash.
The target compiles this file as the root: it must reach the
ordinary missing-main diagnostic, not a fatal signal.
*/
struct InferredBorrowed:
	ref[data] int* value
