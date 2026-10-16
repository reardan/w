# Bounded loose equality

The Preact 10.27.2 production module first reached runtime preflight rejection at
`"key"==o` after ordinary `for-in` lowering was implemented. The runtime now accepts
`==` and `!=` using the [ECMA-262 IsLooselyEqual algorithm](https://tc39.es/ecma262/#sec-islooselyequal).
This does not expand arithmetic, relational or property-key coercion.

Supported primitives include null/undefined, booleans, UTF-16 strings, Numbers and
the existing bounded BigInts. Number/string comparison uses the complete trimmed
StringNumericLiteral, including decimal exponents, signed Infinity, and unsigned
binary/octal/hexadecimal integers. It rejects suffixes, separators, embedded NUL,
lone surrogates and signed radix prefixes. Decimal conversion uses W's correctly
rounded parser after grammar validation. Power-of-two radices retain 53 significant
bits plus guard/sticky information and round once, preserving long-input precision.

BigInt/string equality compares mathematical integer magnitude directly. Invalid
and out-of-range strings return false without throwing or wrapping. Number/BigInt
comparison checks finiteness, integrality and the representable bounds before exact
integer conversion; no BigInt is rounded to Number. Consequently
`9007199254740993n == 9007199254740992` is false.

Objects compare by identity when both operands are objects. Null/undefined checks
do not invoke conversion hooks. For object/primitive pairs, explicit ordinary
methods are read and called in `valueOf`, then `toString` order with the original
receiver. Getters, inherited methods, mutation of the later method, thrown values,
and methods returning non-primitives retain observable ordering. Two unsuccessful
explicit methods throw TypeError. The missing shared Object/Array/Function default
prototype conversions and exotic coercion remain explicitly unsupported. Symbols,
`@@toPrimitive`, Date-specific hints and HTMLDDA are outside the current value model.

String processing charges the existing execution fuel and max-properties limit.
Conversion loops have an independent bound, user recursion uses the runtime depth
limit, and no collection occurs inside active execution. Ordinary callback values
therefore share the runtime's existing ownership and asynchronous suspension roots.
No per-runtime native allocations or install-time intrinsic objects are added.

`javascript_runtime_equality_test` covers primitive pairs, whitespace and invalid
numeric grammars, rounding boundaries, BigInt precision/range, object method/getter
order, receiver identity, abrupt completion, recursion/fuel limits and unsupported
conversions. Every case also runs in one of five separate allocator-debug processes
with zero-leak assertions. `runtime_test` no longer treats `1 == 1` as unsupported.
