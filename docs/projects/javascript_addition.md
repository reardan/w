# Bounded addition coercion

The unchanged Preact workflow failed during its first render at the former
implicit-coercion guard. Its HTTP failure path also uses
`new Error('HTTP ' + response.status)`. Both now use the general addition
operation specified by
[ApplyStringOrNumericBinaryOperator](https://tc39.es/ecma262/#sec-applystringornumericbinaryoperator).

Both operand expressions are evaluated before conversion. Ordinary default-hint
conversion then runs on the left and right operands in order, using the existing
bounded valueOf/toString machinery. If either primitive is a string, both are
converted to strings and concatenated as UTF-16 units. Otherwise Number addition
handles null, booleans, undefined/NaN and signed zero, while BigInt addition uses
the existing exact bounded integer implementation. Mixed BigInt/Number operands
throw; string concatenation preserves BigInt precision. Getter and conversion
exceptions stop subsequent conversion. Compound `+=` shares this operation.

The existing limits on ordinary coercion remain explicit: missing shared
Object/Array/Function primitive-conversion defaults, symbols and native/exotic
coercion are unsupported. This change does not broaden other numeric operators
or update coercion; unsupported string/object `++` is rejected explicitly rather
than accidentally concatenating. BigInt remains the documented signed/unsigned
64-bit subset, with RangeError on unrepresentable arithmetic.
String size, per-unit concatenation fuel, conversion depth and heap limits apply.

Focused normal/debug tests cover the unchanged HTTP message expression, IEEE
Number edge cases, exact BigInt strings, NUL/surrogate preservation, ordinary
conversion and getter ordering, evaluation-before-conversion ordering, thrown
conversions, `+=`, update behavior, and resource limits. Selected regressions
are run together with the immediately preceding generic `some` slice; the
coordinator owns the final integrated full suite and native workflow driver.
