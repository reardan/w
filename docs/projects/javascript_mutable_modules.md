# Mutable named module exports

After `for-in`, loose equality and property presence were enabled, the unchanged
Preact 10.27.2 production module reached the module loader's const-only export
restriction. Named exports now accept `let`, `var`, class and function declarations,
as well as local export lists referencing any parser-validated module binding.
Destructuring declarations export their bound names. Direct re-exports, default
exports, namespaces and cyclic graphs retain their previous unsupported status.

The parser continues to check duplicate exports, undeclared local names, imports
conflicting with local declarations, and block-only names before dependency bodies
execute. This change removes a runtime subset restriction without bypassing module
syntax or binding validation.

Imports were already read-only aliases retaining the defining environment and its
stable binding record. That mechanism now exposes changing local values, including
replacement objects, reassigned functions/classes and values changed after TLA.
Local export lists can forward imported aliases through the existing bounded
acyclic graph. Host `js_modules_export` reads the current binding; callers retaining
a previously returned value still own that value, rather than a mutable handle.

The implementation follows the binding identity described in
[Module Environment GetBindingValue](https://tc39.es/ecma262/#sec-module-environment-records-getbindingvalue-n-s)
and [module export records](https://tc39.es/ecma262/#table-export-forms-mapping-to-exportentry-records).
The runtime's graph, source, parser, execution, alias-depth, asynchronous task and
GC limits remain unchanged. No additional native ownership or roots are introduced.

`javascript_modules_mutable_test` verifies live multi-hop imports/reexports,
immutable imported assignment/update/compound assignment, object replacement,
function/class reassignment, declarations and destructuring, hoisted nested `var`,
TDZ and early rejection, asynchronous dependencies, alias-depth limits, and retained
importing closures after loader destruction and explicit collection. Every case
runs normally and in four allocator-debug groups with zero-leak assertions.

A native probe of the full unchanged Preact module now reaches runtime execution;
its next failure is the absent global `Array` at initial `w=Array.isArray`. This
milestone does not claim that Preact rendering or the workflow fixture works yet.
