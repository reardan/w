# Bitwise numeric coercion

A scripted W debugger session executing unchanged Preact through Win's actual
browser navigation, module loading and DOM runtime found the first-render
failure at `128 & undefined`. The former Number-only guard rejected that flag
test; ECMAScript converts undefined through NaN to the Int32 value zero.

The runtime now applies bounded ordinary ToNumeric conversion to both operands
in order for `&`, `|`, `^`, `<<`, `>>`, and `>>>`, and to the operand of `~`.
Number/null/boolean/undefined values and complete StringNumericLiteral parsing
feed the existing IEEE-bit-based Int32/Uint32 and shift-count implementation.
Ordinary valueOf/toString getter/call order, exceptions, fuel and depth limits
are preserved. Compound bitwise assignment shares the same path.

The existing bounded BigInt arithmetic profile does not implement BigInt
bitwise operations; those remain explicit unsupported completions. Mixed
BigInt/Number operands and BigInt unsigned right shift throw TypeError. Other
numeric operators retain their existing coercion profile. Symbols and exotic
primitive-conversion hooks remain unsupported, as documented for equality's
shared ordinary conversion helper.

Focused normal/debug tests cover the measured Preact flag test, every Number
bitwise operator, null/undefined/boolean/full-string conversions, wrapping and
shift masking, ordinary conversion order/throws, mixed numeric types, and
execution limits. Primary specification: [ToNumeric](https://tc39.es/ecma262/#sec-tonumeric),
[Number bitwise AND](https://tc39.es/ecma262/#sec-number-bitwiseAND), and
[unsigned right shift](https://tc39.es/ecma262/#sec-number-unsignedRightShift).
